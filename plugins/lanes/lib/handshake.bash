# shellcheck shell=bash
# jq programs are single-quoted on purpose: their $names are jq variables, not shell ones.
# shellcheck disable=SC2016
# lanes handshake: request, clear-ready, the draft check, typed sends, and the clear and goal commands. bin/lanes
# sources it after defining the registry, state, lock, RESUME and why_of helpers used here; this file only defines
# functions.

# ---- request and clear-ready -------------------------------------------------------------------------------------

# git_problem <dir>: why the tree cannot be cleared, or nothing when it is clean and pushed.
git_problem() {
  local dir="$1" ahead
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$dir is not a git work tree, so 'pushed' cannot be proven"; return; }
  [[ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] || { echo "the work tree $dir has uncommitted changes: commit them"; return; }
  git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 ||
    { echo "the branch in $dir has no upstream: push it with 'git push -u'"; return; }
  ahead="$(git -C "$dir" rev-list --count '@{u}..HEAD')"
  [[ "$ahead" == 0 ]] || echo "the branch in $dir has $ahead unpushed commit(s): push them"
}

# journal_problem <lane> <lane work tree>: in a journal inside a git work tree of its own (another worktree or branch),
# the lane's own files (next-<lane>.md, done-<lane>.md) must be committed and pushed; other lanes' files there are
# theirs. A journal outside any work tree has nothing to push.
journal_problem() {
  local jr jt ahead files=()
  jr="$(journal_root "$2")"
  jt="$(git -C "$jr" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ "$jt" != "$2" ]] || return 0
  files=("$jr/next-$1.md" "$jr/done-$1.md")
  [[ -z "$(git -C "$jt" status --porcelain -- "${files[@]}" 2>/dev/null)" ]] ||
    { echo "the journal's work tree $jt: next-$1.md or done-$1.md has uncommitted changes: commit them"; return; }
  git -C "$jt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 ||
    { echo "the journal's work tree $jt: its branch has no upstream: push it with 'git push -u'"; return; }
  ahead="$(git -C "$jt" rev-list --count '@{u}..HEAD' -- "${files[@]}")"
  [[ "$ahead" == 0 ]] || echo "the journal's work tree $jt: $ahead unpushed commit(s) change next-$1.md or done-$1.md: push them"
}

# tree_problem <lane> <work tree>: the work tree and the lane's files in the journal's own work tree are clean and
# pushed, or why not.
tree_problem() {
  why_of git_problem "$2"
  [[ -n "$WHY" ]] || why_of journal_problem "$1" "$2"
  printf '%s' "$WHY"
}

# rewritten_problem <file> <block hash> <hash the request saw> <requested at>: why the RESUME block in <file> is not
# proven rewritten since the lead's request, or nothing. The block must differ from the one the request hashed and, in
# git, from the block in the file's last commit before the request (one in the request's own second counts as after),
# so the proof needs no path: the history of the tree the lane now works in decides. Outside git the hash alone does.
rewritten_problem() {
  local dir c old tmp
  [[ "$4" =~ ^[0-9]+$ ]] || return 1
  [[ "$2" != "$3" ]] ||
    { echo "the RESUME block is unchanged since the lead's request: rewrite it with your current state, commit and push"; return; }
  dir="$(dirname "$1")"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  c="$(git -C "$dir" log -1 --format=%H --before="@$(($4 - 1))" -- "$1")" || return 1
  [[ -n "$c" ]] || return 0
  old=""
  if git -C "$dir" cat-file -e "$c:./${1##*/}" 2>/dev/null; then
    tmp="$(mktemp)" || return 1
    git -C "$dir" show "$c:./${1##*/}" >"$tmp" || { rm -f "$tmp"; return 1; }
    old="$(resume_block "$tmp" || true)"
    rm -f "$tmp"
  fi
  [[ -z "$old" || "$(hash_of "$old")" != "$2" ]] ||
    echo "the RESUME block in $1 is the same as in its last commit before the lead's request (a change elsewhere in the file does not count): rewrite the block with your current state, commit and push"
}

# turn_starts <transcript>: how many turns the transcript shows begun, by the entry each one starts with: a user entry
# that is not only tool results (a prompt, a Stop hook's feedback such as a /goal verdict, a task notification, a
# cross-session message), or a goal_status verdict that sends the goal loop on (met false, not the sentinel). A
# local-command caveat and the /clear command entry begin none (2.1.309 writes both first after /clear). A missing
# file has none yet.
turn_starts() {
  [[ -n "$1" ]] || return 1
  [[ -e "$1" ]] || { echo 0; return 0; }
  [[ -r "$1" ]] || return 1
  { grep -E '"type":"(user|attachment)"' "$1" || true; } | jq -Rn '[inputs | fromjson? | select(
      (.type == "user" and ((.message.content | type) != "array" or (.message.content | any(.type != "tool_result")))
       and (if (.message.content | type) == "string"
            then (.message.content | startswith("<local-command-caveat>") or startswith("<command-name>/clear</command-name>")) | not
            else true end))
      or (.type == "attachment" and .attachment.type == "goal_status" and .attachment.met == false
          and (.attachment.sentinel | not)))] | length'
}

# unused_problem <lane> <session id>: why that session of the lane is not unused, or nothing. Unused means no prompt
# reached it (the prompt hook's count) and its transcript shows no turn begun (turn_starts), so a message or
# notification that fired no hook counts too; the goal is typed only into an unused session.
unused_problem() {
  local st n tp
  st="$(state_read "$1")"
  [[ "$(jq -r '.session_id // ""' <<<"$st")" == "$2" ]] || { echo "the lane's record is not yet that of session $2"; return; }
  n="$(jq -r '.prompts // 0' <<<"$st")"
  [[ "$n" == 0 ]] || { echo "the session the /clear created already took $n prompt(s)"; return; }
  tp="$(jq -r '.transcript // ""' <<<"$st")"
  n="$(turn_starts "$tp")" ||
    { echo "the transcript '$tp' of the session the /clear created could not be read, so its use cannot be ruled out"; return; }
  [[ "$n" == 0 ]] || echo "the session the /clear created already began $n turn(s) (a message or notification arrived)"
}

# self_lane [--lane x]: which lane runs this command (the Bash tool carries TMUX_PANE, not the plugin's variables); a
# pane registered to a lane speaks only for that lane.
self_lane() {
  local caller
  caller="$(caller_lane)"
  if [[ -n "${1:-}" ]]; then
    valid_lane "$1" || die "invalid lane '$1'" "use the name the session was started with" 2
    [[ -z "$caller" || "$caller" == "$1" ]] ||
      die "not clear-ready: pane ${TMUX_PANE:-} is lane $caller, not $1" "a lane reports only its own readiness: run 'lanes clear-ready' in $1's own pane" 2
    echo "$1"
  elif [[ -n "$caller" ]]; then
    echo "$caller"
  else
    die "cannot tell which lane this is" "run it inside the lane's tmux pane, or pass --lane <name>"
  fi
}

# require_lead <what the lead does>: refuse unless the caller's pane is registered to the lead.
require_lead() {
  local caller
  caller="$(caller_lane)"
  [[ -n "$caller" && "$(reg_read "$caller" | jq -r .role 2>/dev/null)" == lead ]] ||
    die "only the lead $1" "run it from the lead's pane (a session started with LANES_ROLE=lead)"
}

# require_own_lane <lane>: a lead acts only on lanes of its own project and never on a lead, so refuse a target whose
# role is lead or whose project (lane_project) is not the caller's (caller_project). Callers run it before any state
# write or key.
require_own_lane() {
  local e mine theirs
  e="$(reg_read "$1")" ||
    die "no valid registry entry for '$1' (missing, half-written or corrupt)" "check 'lanes status'; the lane must be started as 'claude --name $1'"
  [[ "$(jq -r '.role // "lane"' <<<"$e")" != lead ]] ||
    die "lane $1 is a lead: a lead never acts on a lead, itself included" "the human clears or sets the goal of a lead"
  mine="$(caller_project)"
  theirs="$(lane_project "$1")"
  [[ -n "$theirs" && "$theirs" == "$mine" ]] ||
    die "lane $1 is in project '${theirs:-unknown}', not the project of this lead ($mine)" "a lead acts only on lanes of its own project: run it from that project's lead"
}

cmd_request() {
  local lane="${1:-}" e file block="" h="" wt rc=0
  if ! valid_lane "$lane" || (($# != 1)); then usage; fi
  require_lead "requests a clear"
  require_own_lane "$lane"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "check 'lanes status'; the lane must be started as 'claude --name $lane'"
  # The block is hashed where the lane last was: the work tree the last clear-ready proved, else the session's cwd.
  wt="$(state_read "$lane" | jq -r '.handshake.worktree // ""')"
  file="$(resume_path "$lane" "${wt:-$(jq -r .cwd <<<"$e")}")"
  block="$(resume_block "$file" || true)"
  [[ -n "$block" ]] && h="$(hash_of "$block")"
  mutex_take 5 || rc=$?
  ((rc == 0)) || die "$(mutex_refusal "$rc")" "retry in a moment; nothing was requested"
  [[ "$(state_read "$lane" | jq -r '.handshake.state // ""')" != sending ]] ||
    die "a clear of $lane is in flight (handshake: sending)" "run 'lanes clear $lane' to finish or settle it before a new request"
  state_update "$lane" '.handshake = {state: "requested", requested_at: $now, request_resume_hash: $h,
      worktree: .handshake.worktree}' --argjson now "$(now)" --arg h "$h"
  reg_update "$lane" '.clear_ready = false'
  mutex_drop
  echo "requested: message $lane: \"Context is at threshold. Finish the change in hand, rewrite your RESUME block (last seen at $file) in the work tree you work in, commit and push, run 'lanes clear-ready' from your work tree, tell me 'clear-ready', then stop.\""
}

# cmd_clear_ready: the work tree is the one the lane runs this from (its Bash tool's directory), not the directory the
# session started in. The goal re-sent after /clear is the RESUME Goal, its one source (RULES.md rule 6).
cmd_clear_ready() {
  local arg="" lane e st wt file block h goal tp turns rc=0
  [[ "${1:-}" == "--lane" ]] && arg="${2:-}"
  lane="$(self_lane "$arg")"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "restart the session as 'claude --name $lane' inside tmux"
  wt="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" ||
    die "not clear-ready" "$PWD is not a git work tree: run 'lanes clear-ready' from the work tree you work in"
  why_of tree_problem "$lane" "$wt"
  [[ -z "$WHY" ]] || die "not clear-ready" "$WHY"
  file="$(resume_path "$lane" "$wt")"
  block="$(resume_block "$file")" || die "not clear-ready" "no RESUME block in $file: run 'lanes init $lane' and fill it in"
  why_of resume_problems "$block"
  [[ -z "$WHY" ]] || die "not clear-ready" "$(tr '\n' ';' <<<"$WHY")"
  h="$(hash_of "$block")"
  st="$(state_read "$lane")"
  # The record proved here is the one ready replaces: a request that lands meanwhile stands (hs_cas_locked).
  HS_WAS="$(jq -c '.handshake // null' <<<"$st")"
  if [[ "$(jq -r '.handshake.state // ""' <<<"$st")" == requested ]]; then
    why_of rewritten_problem "$file" "$h" "$(jq -r '.handshake.request_resume_hash // ""' <<<"$st")" \
      "$(jq -r '.handshake.requested_at // 0' <<<"$st")"
    [[ -z "$WHY" ]] || die "not clear-ready" "$WHY"
  fi
  goal="$(trim "$(section_text "$block" Goal)")"
  # The turns begun so far, this one included: one more later means the lane worked on after reporting ready.
  tp="$(jq -r '.transcript // ""' <<<"$st")"
  turns="$(turn_starts "$tp")" || turns=""
  mutex_take 5 || rc=$?
  ((rc == 0)) || die "not clear-ready: $(mutex_refusal "$rc")" "run 'lanes clear-ready' again in a moment"
  # Ownership is decided under the mutex: a session that took the lane meanwhile is not marked ready for the old one.
  [[ "$(reg_read "$lane" | jq -r .session_id 2>/dev/null)" == "$(jq -r .session_id <<<"$e")" ]] ||
    die "not clear-ready" "lane $lane started a new session while clear-ready ran: run it again"
  hs_cas_locked "$lane" "$HS_SAME" '{state: "ready", ready_at: $now, requested_at: (. // {}).requested_at,
      session_id: $sid, worktree: $wt, head: $head, resume_hash: $h, prompts: $prompts, goal: $goal, attempts: 0,
      transcript: $tp, turns: $turns}' \
    --argjson now "$(now)" --arg sid "$(jq -r .session_id <<<"$e")" --arg wt "$wt" --arg head "$(git -C "$wt" rev-parse HEAD)" \
    --arg h "$h" --arg goal "$goal" --arg tp "$tp" --arg turns "$turns" \
    --argjson prompts "$(state_read "$lane" | jq '.prompts // 0')" ||
    die "not clear-ready" "$HS_WHY: run 'lanes clear-ready' again (after a new request, rewrite the RESUME block first)"
  reg_update "$lane" '.clear_ready = true'
  mutex_drop
  echo "clear-ready: $lane at $(git -C "$wt" rev-parse --short HEAD). Tell the lead \"clear-ready\", then stop and wait."
}

# ---- screen: the one fact with no native signal, a human's draft in the input line -------------------------------

# screen_read <pane>: sets COMPOSER (the typed text, all its wrapped lines; empty for the placeholder),
# COMPOSER_FOUND (0 when no `❯`+NBSP input line is on screen, as under a dialog or another program) and SCREEN_INSERT
# (1 when a footer line below the input box starts with vim's `-- INSERT --`). The layout is Claude Code 2.1.309's
# (tests/lanes/captures); the last input line counts, and the pattern holds under LC_ALL=C.
screen_read() {
  local pane="$1" raw plain i line idx=-1 body bottom
  COMPOSER="" COMPOSER_FOUND=0 SCREEN_INSERT=0
  raw="$(tm capture-pane -p -e -t "$pane" 2>/dev/null)" || return 0
  # shellcheck disable=SC2001 # a regex over many lines; parameter expansion has no portable regex form
  plain="$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$raw")"
  local -a lines rawlines
  mapfile -t lines <<<"$plain"
  mapfile -t rawlines <<<"$raw"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    if [[ "${lines[i]}" == "$PROMPT_MARK"* ]]; then idx=$i; break; fi
  done
  ((idx >= 0)) || return 0
  COMPOSER_FOUND=1
  for ((bottom = idx + 1; bottom < ${#lines[@]}; bottom++)); do
    [[ "${lines[bottom]}" == "─"* ]] && break
  done
  for ((i = bottom + 1; i < ${#lines[@]}; i++)); do
    line="${lines[i]#"${lines[i]%%[![:space:]]*}"}"
    [[ "$line" != "-- INSERT --"* ]] || SCREEN_INSERT=1
  done
  body="${rawlines[idx]#*"$PROMPT_MARK"}"
  [[ "$body" != $'\e[2m'* ]] || return 0
  # The input wraps onto lines indented two spaces, down to the bottom rule; they join with one space.
  COMPOSER="$(sed $'s/\x1b\\[[0-9;]*m//g; s/[[:space:]]*$//' <<<"$body")"
  for ((i = idx + 1; i < bottom; i++)); do
    line="${lines[i]#  }"
    COMPOSER+=" ${line%"${line##*[![:space:]]}"}"
  done
}

squash() { printf '%s' "${1//[[:space:]]/}"; }
# trim <text>: without leading and trailing whitespace; a goal is trimmed where it enters, so the text typed and the
# text the prompt hook confirms are the same string.
trim() { local s="${1#"${1%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# composer_problem <pane> [input]: why the input line does not hold exactly <input> (default: nothing), or nothing.
# An unreadable line is a refusal: lanes never types where it cannot see that no human draft is there.
composer_problem() {
  screen_read "$1"
  if ((!COMPOSER_FOUND)); then
    echo "the input line of $1 cannot be read (no input prompt on screen: a dialog or another program may be showing)"
  elif (($# >= 2)); then
    [[ "$(squash "$COMPOSER")" == "$(squash "$2")" ]] ||
      echo "the input line changed after it was checked (it now shows '${COMPOSER:0:60}')"
  elif [[ -n "$COMPOSER" ]]; then
    echo "the input line of $1 holds text ('${COMPOSER:0:40}'): a human may be typing, and a draft is never touched"
  fi
}

# ---- typed sends -------------------------------------------------------------------------------------------------

# keys_check <lane> <pane> <session id>: sets WHY to why keys sent to the pane now would not reach that session of the
# lane alone as typed text, or empty. In copy mode they go to tmux, with synchronize-panes to every pane of the window,
# while Claude Code is not the terminal's foreground program to whatever is, and in vim NORMAL mode they run as vim
# commands; for those HOLD_FIX names the human's step, since the session is still proven and its clear-ready still
# holds (empty for any other objection).
keys_check() {
  HOLD_FIX=""
  case "$(tm display -p -t "$2" '#{pane_in_mode} #{pane_synchronized}' 2>/dev/null)" in
    "0 0") ;;
    "1 "*)
      WHY="pane $2 is in copy mode: leave it (q) first, or keys would go to tmux"
      HOLD_FIX="leave copy mode in pane $2 (press q there)"
      return 0
      ;;
    *" 1")
      WHY="pane $2 has synchronize-panes on, so keys would reach every pane of its window: turn it off"
      HOLD_FIX="turn synchronize-panes off for the window of pane $2"
      return 0
      ;;
    *) WHY="the mode of pane $2 cannot be read"; return 0 ;;
  esac
  why_of identity_problem "$1" "$2" "$3"
  [[ -z "$WHY" ]] || return 0
  why_of foreground_problem "$1" "$2"
  if [[ -n "$WHY" ]]; then
    check_failed || HOLD_FIX="bring Claude Code back to the foreground of pane $2 (fg in the shell it was started from)"
    return 0
  fi
  vim_problem "$1" "$2"
  WHY="$VIM_WHY" HOLD_FIX="$VIM_FIX"
}

# vim_setting <lane>: prints "<editorMode> <statusLine.hideVimModeIndicator>" as the lane's Claude Code reads them,
# the highest level that sets each winning (code.claude.com/docs/en/settings "Settings precedence": managed, then
# --settings, project local, shared project, user). The files are the user settings under the lane's config dir, the
# project's in its cwd, its local file there and at the repository root, then managed-settings.json and
# managed-settings.d/*.json in alphabetical order (code.claude.com/docs/en/managed-settings); --settings, MDM and
# server-managed settings are not visible to lanes. A file that exists but is not a JSON object fails, naming it.
vim_setting() {
  local e cfg cwd root mdir f files=() order=()
  e="$(reg_read "$1")" || { echo "the registry entry for $1 is unreadable"; return 1; }
  cfg="$(jq -r '.claude_config_dir // ""' <<<"$e")"
  cwd="$(jq -r '.cwd // ""' <<<"$e")"
  # The local file sits at the main checkout's root, which a worktree's common git dir names (settings docs).
  root="$(cd "$cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P || true)"
  root="${root%/.git}"
  mdir="${LANES_MANAGED_SETTINGS_DIR:-}"
  if [[ -z "$mdir" ]]; then
    if [[ "$OS_NAME" == Darwin ]]; then mdir="/Library/Application Support/ClaudeCode"; else mdir=/etc/claude-code; fi
  fi
  order=("${cfg:-$HOME/.claude}/settings.json" "$cwd/.claude/settings.json" "$cwd/.claude/settings.local.json")
  [[ -z "$root" || "$root" == "$cwd" ]] || order+=("$root/.claude/settings.local.json")
  order+=("$mdir/managed-settings.json")
  # A glob skips hidden files and sorts by LC_COLLATE, here byte order.
  local LC_COLLATE=C
  for f in "$mdir"/managed-settings.d/*.json; do [[ -e "$f" ]] && order+=("$f"); done
  for f in "${order[@]}"; do
    [[ -e "$f" ]] || continue
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 ||
      { echo "the settings file $f is not a readable JSON object"; return 1; }
    files+=("$f")
  done
  ((${#files[@]})) || { echo "normal false"; return 0; }
  jq -rs '(map(.editorMode | strings) | last // "normal") + " "
    + (map(.statusLine | objects | .hideVimModeIndicator | booleans) | last // false | tostring)' "${files[@]}"
}

# vim_problem <lane> <pane>: sets VIM_WHY to why keys typed into the pane would not be taken as text under vim mode
# (empty when they would) and VIM_FIX to the human's step, empty for a check that crashed. With editorMode vim the
# footer must show `-- INSERT --` (NORMAL shows nothing, and its keys run as commands), so a hidden indicator is
# always a refusal: the mode cannot be proven.
VIM_WHY="" VIM_FIX=""
vim_problem() {
  local v mode hidden
  VIM_WHY="" VIM_FIX=""
  if ! v="$(vim_setting "$1")"; then
    if [[ -z "$v" ]]; then VIM_WHY="check failed: vim_setting"; return 0; fi
    VIM_WHY="$v, so vim mode cannot be ruled out" VIM_FIX="fix that settings file of lane $1"
    return 0
  fi
  read -r mode hidden <<<"$v"
  [[ "$mode" == vim ]] || return 0
  if [[ "$hidden" == true ]]; then
    VIM_WHY="lane $1 runs Claude Code in vim mode with its mode indicator hidden, so lanes cannot prove the input line takes text"
    VIM_FIX="show the vim mode indicator (drop statusLine.hideVimModeIndicator) or set editorMode to normal for lane $1"
    return 0
  fi
  screen_read "$2"
  ((SCREEN_INSERT)) && return 0
  VIM_WHY="lane $1 runs Claude Code in vim mode and pane $2 does not show -- INSERT --, so typed keys would run as vim commands"
  VIM_FIX="press i in pane $2"
}

# foreground_problem <lane> <pane>: why the lane's Claude Code would not read keys typed into the pane now, or nothing.
# Keys reach the terminal's foreground process group, so a stopped Claude Code (Ctrl-Z) or one a tool started in its
# own group does not read them. pgid, tpgid and stat are ps keywords in procps and in BSD and macOS ps(1), given one
# -o each, since BSD ps reads the text after a keyword's "=" as its header, commas included.
foreground_problem() {
  local pid pg="" tpg="" stat=""
  pid="$(reg_read "$1" | jq -r '.claude_pid // "" | tostring')" || return 1
  read -r pg tpg stat _ <<<"$(ps -o pgid= -o tpgid= -o stat= -p "$pid" 2>/dev/null)" || true
  [[ -n "$pg" && "$pg" == "$tpg" && "$stat" != [Tt]* ]] ||
    echo "Claude Code pid $pid of lane $1 is not the foreground program of pane $2 (stopped, or started from a shell or tool in the pane; ps says pgid '$pg', terminal group '$tpg', state '$stat')"
}

# moved_problem <lane>: why the lane's session state is no longer the one proven idle (GUARD_SIG), or nothing.
moved_problem() {
  if ! lane_session "$1"; then
    echo "$SS_PROBLEM"
  elif [[ "$SS_SIG" != "$GUARD_SIG" ]]; then
    # GUARD_SIG was taken from an idle observation, so an equal one is still that idle state.
    echo "the lane's state moved after the idle check (now $SS_STATUS since ${SS_AGE_MS} ms)"
  fi
}

# send_guard <lane> <pane> [input]: sets WHY to why no key may be sent now, or empty; it runs before typing and before
# every Enter, and leaves keys_check's HOLD_FIX. The caller sets GUARD_SID (the session the pane must still hold),
# GUARD_SIG (SS_SIG at the proven idle point), GUARD_READY (1: the clear-ready proof must still hold) and GUARD_UNUSED
# (1: the session must still be unused, checked last); <input> is what the input line must hold.
GUARD_SID="" GUARD_SIG="" GUARD_READY=0 GUARD_UNUSED=0
send_guard() {
  keys_check "$1" "$2" "$GUARD_SID"
  if [[ -z "$WHY" ]] && ((GUARD_READY)); then why_of changed_since_ready "$1" "$(reg_read "$1")" "$(state_read "$1")"; fi
  [[ -n "$WHY" ]] || why_of moved_problem "$1"
  [[ -n "$WHY" ]] || why_of composer_problem "$2" "${@:3}"
  if [[ -z "$WHY" ]] && ((GUARD_UNUSED)); then why_of unused_problem "$1" "$GUARD_SID"; fi
}

# send_literal <pane> <text>: the one place that types text. tmux reads a `;` that ends an argument as a command
# separator, and turns a trailing `\;` into `;` (tmux(1) PARSING SYNTAX; no other trailing character is special), so
# trailing semicolons are sent as their key code (send-keys -H 3b) and never end a literal argument.
send_literal() {
  local head="$2" codes=()
  while [[ "$head" == *";" ]]; do
    head="${head%;}"
    codes+=(3b)
  done
  [[ -z "$head" ]] || tm send-keys -t "$1" -l -- "$head"
  ((${#codes[@]} == 0)) || tm send-keys -t "$1" -H "${codes[@]}"
}

# send_text <lane> <pane> <text>: one line typed in chunks of SEND_CHUNK characters (split by jq, so a multibyte
# character is never cut under any locale), never a paste: Claude Code turns a burst of about 800 characters into
# "[Pasted text]", which does not dispatch a slash command (measured on 2.1.308). Before each chunk after the first,
# keys_check and moved_problem run again; an objection returns 2 with MOVED and MOVED_FIX set.
send_text() {
  local chunk
  TYPED=""
  [[ "$3" != *[[:cntrl:]]* ]] || die "refusing to type text with a newline or control character" "the goal must be one line"
  while IFS= read -r chunk; do
    if [[ -n "$TYPED" ]]; then
      keys_check "$1" "$2" "$GUARD_SID"
      [[ -n "$WHY" ]] || why_of moved_problem "$1"
      MOVED="$WHY" MOVED_FIX="$HOLD_FIX"
      [[ -z "$MOVED" ]] || return 2
    fi
    # TYPED takes the chunk before it is sent, so after a kill at any point the input line holds a leading part of it.
    TYPED+="$chunk"
    send_literal "$2" "$chunk"
    sleep "$SEND_GAP"
  done < <(printf '%s' "$3" | jq -Rrs --argjson n "$SEND_CHUNK" 'explode as $c | range(0; $c | length; $n) | $c[.:. + $n] | implode')
}

# erase_plan <text> <input line> <left>: for an input line that holds only a leading part of <text> (whitespace
# ignored, since the screen wraps at spaces), prints "<least> <len> <n> <keys>": that part is at least <least> code
# points long, <len> is its length capped at <left>, and its last <n> code points take <keys> Backspaces, at most 64
# (an astral one counts two, as char_count does). Prints nothing when the line holds anything else.
erase_plan() {
  jq -rn --arg t "$1" --arg c "$2" --argjson left "$3" '
    def ws: . == 32 or (. >= 9 and . <= 13);
    ($t | explode) as $o | [$c | explode[] | select(ws | not)] as $cs | ($cs | length) as $m
    | [$o | to_entries[] | select(.value | ws | not)] as $nz
    | if ($nz | length) < $m or [$nz[0:$m][].value] != $cs then empty else
        (if $m == 0 then 0 else $nz[$m - 1].key + 1 end) as $least
        | ([(if ($nz | length) > $m then $nz[$m].key else ($o | length) end), $left] | min) as $len
        | (reduce ($o[0:$len] | reverse[]) as $x ({n: 0, keys: 0, full: false};
            (if $x > 65535 then 2 else 1 end) as $w
            | if .full or .keys + $w > 64 then .full = true else .n += 1 | .keys += $w end)) as $b
        | "\($least) \($len) \($b.n) \($b.keys)"
      end'
}

# screen_settled <pane>: screen_read until two reads 0.2 s apart show the same input line (at most 10 reads), so no
# plan starts from a screen still drawing our keys, which would show less than was typed; 1 when it kept changing.
screen_settled() {
  local i prev
  screen_read "$1"
  for ((i = 0; i < 9; i++)); do
    prev="$COMPOSER_FOUND/$COMPOSER"
    sleep 0.2
    screen_read "$1"
    [[ "$COMPOSER_FOUND/$COMPOSER" != "$prev" ]] || return 0
  done
  return 1
}

# erase_if_ours <lane> <pane> <text>: delete our typed text from its end, one burst of at most 64 Backspaces at a
# time. Before each burst keys_check runs, then the input line is read until it settles and must hold only the part
# of our text not yet deleted (or less of it), and the burst follows that read at once: a key typed after the read is
# all a burst can reach. A screen that still shows more than is left is read again for up to a second. Sets ERASED.
erase_if_ours() {
  local left least len n keys plan sent=0 tries=0 burst=() keys_why
  left="$(printf '%s' "$3" | jq -Rs 'explode | length')" ||
    { ERASED="our typed text was left in the input line of $2, because its length could not be counted"; return 0; }
  while :; do
    keys_check "$1" "$2" "$GUARD_SID"
    keys_why="$WHY"
    if ! screen_settled "$2"; then
      ERASED="our typed text was left in the input line of $2, because the line kept changing (it shows '${COMPOSER:0:60}')"
      return 0
    fi
    plan=""
    ((!COMPOSER_FOUND)) || plan="$(erase_plan "$3" "$COMPOSER" "$left")"
    if [[ -z "$plan" ]] && ((!sent)); then
      ERASED="the input line did not hold only our text, so it was left as it is (it shows '${COMPOSER:0:60}')"
      return 0
    elif [[ -z "$plan" ]]; then
      ERASED="deleting our typed text stopped, because the input line no longer held only what was left of it (it shows '${COMPOSER:0:60}'); that was left as it is"
      return 0
    fi
    read -r least len n keys <<<"$plan"
    if ((least > left)); then
      # The screen has not drawn the last burst yet, or someone typed our next characters again.
      if ((++tries <= 10)); then sleep 0.1; continue; fi
      ERASED="deleting our typed text stopped, because the input line kept showing more of it than was left (it shows '${COMPOSER:0:60}'); that was left as it is"
      return 0
    fi
    tries=0
    if ((len == 0)); then
      ERASED="our typed text was deleted"
      ((sent)) || ERASED="none of our typed text was in the input line"
      return 0
    fi
    [[ -z "$keys_why" ]] || { ERASED="our typed text was left in the input line of $2, because $keys_why"; return 0; }
    burst=()
    for ((; keys > 0; keys--)); do burst+=(BSpace); done
    tm send-keys -t "$2" "${burst[@]}"
    sent=1 left=$((len - n))
    sleep "$SEND_GAP"
  done
}

# submit <lane> <pane> <text> <confirm cmd...>: type the line and prove it arrived, then press Enter and confirm the
# effect; a lost Enter (text still in the input line) gets one more press, then 1. A guard objection returns 2 before
# the first Enter and 3 after it (the text may have been taken late), with MOVED, MOVED_FIX (keys_check's HOLD_FIX)
# and ERASED set.
submit() {
  local rc=0
  # A kill (the Bash tool's timeout) deletes what was typed and not yet submitted while the input line holds only
  # that, and says so. Text an Enter went to may have been submitted, so it is no longer ours to delete (ENTERED).
  TYPED="" ENTERED=0 SUBMIT_PANE="$2" SUBMIT_LANE="$1"
  trap 'if ((ENTERED)); then
      echo "lanes: stopped after pressing Enter in $SUBMIT_PANE: the text may have been submitted, so nothing was deleted; look at the pane and run '"'lanes status'"'" >&2
      exit 143
    fi
    if [[ -n "$TYPED" ]]; then erase_if_ours "$SUBMIT_LANE" "$SUBMIT_PANE" "$TYPED"; else ERASED="nothing was typed"; fi
    echo "lanes: stopped while typing into $SUBMIT_PANE: $ERASED" >&2; exit 143' TERM INT
  submit_keys "$@" || rc=$?
  trap 'exit 143' TERM INT # bin/lanes' own handler again
  return "$rc"
}

# arrived <pane> <text>: the input line shows exactly <text>, read 0.3 s after typing and then every 0.1 s for up to a
# second more, since the screen can lag the keys; a line that ends in our text after other text is final at once. The
# line is compared whole and without spaces, since Claude Code wraps a long line at any space. COMPOSER is the last read.
arrived() {
  local i
  sleep 0.3
  for ((i = 0; ; i++)); do
    screen_read "$1"
    [[ "$(squash "$COMPOSER")" != "$(squash "$2")" ]] || return 0
    [[ "$(squash "$COMPOSER")" != *"$(squash "$2")" ]] || return 1
    ((i < 10)) || return 1
    sleep 0.1
  done
}

submit_keys() {
  local lane="$1" pane="$2" text="$3" shown
  shift 3
  ERASED="nothing was typed" MOVED_FIX=""
  send_guard "$lane" "$pane"
  MOVED="$WHY" MOVED_FIX="$HOLD_FIX"
  [[ -z "$MOVED" ]] || return 2
  if ! send_text "$lane" "$pane" "$text"; then
    erase_if_ours "$lane" "$pane" "$TYPED"
    return 2
  fi
  if ! arrived "$pane" "$text"; then
    [[ "$(squash "$COMPOSER")" != *"$(squash "$text")" ]] ||
      die "$REFUSAL: text arrived in the input line of $pane ahead of ours" "nothing was submitted or deleted: the line holds that text with ours after it; look at the pane"
    shown="${COMPOSER:0:60}"
    erase_if_ours "$lane" "$pane" "$text"
    die "typed text did not arrive intact (input line showed '$shown')" "nothing was submitted, and $ERASED; look at pane $pane"
  fi
  send_guard "$lane" "$pane" "$text"
  MOVED="$WHY" MOVED_FIX="$HOLD_FIX"
  if [[ -n "$MOVED" ]]; then
    erase_if_ours "$lane" "$pane" "$text"
    return 2
  fi
  # From here the text may be submitted, so the kill trap deletes nothing (submit).
  # shellcheck disable=SC2034 # read by submit's trap
  TYPED="" ENTERED=1
  tm send-keys -t "$pane" Enter
  "$@" && return 0
  screen_read "$pane"
  if [[ "$(squash "$COMPOSER")" == "$(squash "$text")" ]]; then
    send_guard "$lane" "$pane" "$text"
    MOVED="$WHY"
    if [[ -n "$MOVED" ]]; then
      erase_if_ours "$lane" "$pane" "$text"
      return 3
    fi
    echo "lanes: Enter was not taken for '${text:0:20}'; pressing it once more" >&2
    tm send-keys -t "$pane" Enter
    "$@" && return 0
  fi
  return 1
}

# ---- waits -------------------------------------------------------------------------------------------------------

# settle <lane> <pane> <seconds> [shell]: wait until the sessions file says idle (or shell, when passed) for
# LANES_IDLE_GAP, keep that observation's SS_SIG in IDLE_SIG, then check that no draft is in the input line. Busy,
# waiting or a background shell after <seconds> is refused, and an unreadable session file read twice in a row at once.
IDLE_SIG=""
settle() {
  local lane="$1" pane="$2" deadline unknown=0
  deadline=$(($(now) + $3))
  while :; do
    lane_activity "$lane"
    case "$ACT" in
      idle) IDLE_SIG="$SS_SIG"; break ;;
      shell)
        if [[ "${4:-}" == shell ]]; then
          if ((SS_AGE_MS >= IDLE_GAP_MS)); then IDLE_SIG="$SS_SIG"; break; fi
          ACT=settling
        fi
        ;;
      unknown)
        # One unreadable read may be a write caught midway, so the file is read once more after a pause.
        ((!unknown)) || die "$REFUSAL: $ACT_DETAIL" "check 'lanes status'; nothing was typed"
        unknown=1
        sleep 0.1
        continue
        ;;
    esac
    unknown=0
    if (($(now) >= deadline)); then
      case "$ACT" in
        waiting) die "$REFUSAL: lane $lane is waiting for its human ($ACT_DETAIL)" "look at the pane; a human answers it" ;;
        shell) die "$REFUSAL: lane $lane has a background shell running" "ask the lane to stop it; a background shell outlives /clear" ;;
        settling) die "$REFUSAL: lane $lane did not stay idle for $IDLE_GAP s within $3 s" "run the command again when the lane is quiet" ;;
        *) die "$REFUSAL: lane $lane stayed busy for $3 s" "wait for its turn to end; if it never does, look at the pane" ;;
      esac
    fi
    sleep 0.2
  done
  why_of composer_problem "$pane"
  [[ -z "$WHY" ]] || die "$REFUSAL: $WHY" "nothing was typed"
}

# wait_new_session <lane> <old session id>: the sessions file and the registry (SessionStart(clear)) agree on a new one.
wait_new_session() {
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    [[ "$(reg_read "$1" | jq -r .session_id 2>/dev/null)" != "$2" ]] && lane_session "$1" && return 0
    sleep 0.2
  done
  return 1
}

# wait_composer_empty <pane>: the session /clear created has drawn its empty input line (the screen can lag the file).
wait_composer_empty() {
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    why_of composer_problem "$1"
    [[ -z "$WHY" ]] && return 0
    sleep 0.2
  done
  return 1
}

# wait_goal_seen <lane> <session id> <goal> <prompts before>: that session's UserPromptSubmit received `/goal <goal>`
# (the hook keeps the first 200 characters of a slash command) as a new prompt.
wait_goal_seen() {
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    state_read "$1" | jq -e --arg s "$2" --arg g "/goal $3" --argjson p "$4" \
      '.session_id == $s and .last_command == $g[0:200] and (.prompts // 0) > $p' >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# ---- clear and goal ----------------------------------------------------------------------------------------------

REFUSAL="not cleared"

# clear_lock <lane>: one send at a time per lane, for lanes clear and lanes goal alike.
clear_lock() {
  local path="$STATE/$1.clear.lnk" rc=0
  mkdir -p "$STATE"
  lock_take "$path" 0 || rc=$?
  ((rc != 2)) || die "the clear lock of $1 was not taken: $LOCK_WHY" "check that ps works, then run the command again; nothing was typed"
  ((rc == 0)) ||
    die "another 'lanes clear $1' is running (or 'lanes goal $1'; pid $(lock_holder "$path"))" "let it finish; never run two at once"
  # shellcheck disable=SC2034 # on_exit in bin/lanes releases it
  CLEAR_LOCK="$path" CLEAR_MINE="$LOCK_MINE"
}

# Every handshake write of clear-ready and lanes clear is a compare-and-set: the record must still be HS_WAS, the one
# the command last proved (read or wrote), so a request or another lanes command that changed it meanwhile is never
# overwritten. HS_SAME is the usual test; HS_WHY says why a write did not happen.
HS_WAS=null HS_WHY=""
HS_SAME='. == $was'
# The one change register makes on its own: SessionStart(clear) moves a sending record to cleared for the new session.
HS_SAME_OR_CLEARED='. == $was or ($was.state == "sending" and .state == "cleared" and .cleared_session == $sid
  and del(.state, .cleared_at, .cleared_session) == ($was | del(.state, .cleared_at, .cleared_session)))'

# hs_cas_locked <lane> <test> <filter> [jq args]: under the caller's mutex, apply <filter> to the handshake record when
# <test> holds for it ($was is HS_WAS), and make the result HS_WAS; else return 1 with HS_WHY set and the record left.
hs_cas_locked() {
  local lane="$1" test="$2" filter="$3" cur
  shift 3
  cur="$(state_read "$lane")"
  if ! jq -e --argjson was "$HS_WAS" "$@" "(.handshake // null) | $test" <<<"$cur" >/dev/null; then
    why_of ready_problem "$lane" "$(jq -r '.handshake.state // "none"' <<<"$cur")"
    HS_WHY="${WHY:-another lanes command changed the handshake of $lane while this one ran}"
    return 1
  fi
  state_update "$lane" ".handshake |= ($filter)" --argjson was "$HS_WAS" "$@" ||
    { HS_WHY="the handshake record of $lane could not be written"; return 1; }
  HS_WAS="$(state_read "$lane" | jq -c '.handshake // null')"
}

# hs_cas <lane> <test> <filter> [jq args]: hs_cas_locked under its own mutex.
hs_cas() {
  local rc=0
  mutex_take 5 || rc=$?
  ((rc == 0)) || die "$(mutex_refusal "$rc")" "retry in a moment"
  hs_cas_locked "$@" || rc=$?
  mutex_drop
  return "$rc"
}

# refuse_clear <lane> <reason> <what to do>: drops clear-ready so the lane must report it again; a record another
# command changed meanwhile is left to it, and the message says so.
refuse_clear() {
  local note="" rc=0
  mutex_take 5 || rc=$?
  if ((rc == 0)); then
    if hs_cas_locked "$1" "$HS_SAME" '.state = "stale" | .stale_reason = $r' --arg r "$2"; then
      reg_update "$1" '.clear_ready = false' || true
    else
      note=" (the record was left as it is: $HS_WHY)"
    fi
    mutex_drop
  else
    note=" ($(mutex_refusal "$rc"), so the record was not changed)"
  fi
  die "not cleared: $2$note" "$3"
}

# refuse_keys <lane> <reason> <hold fix> <what to do>: a key-path hold (keys_check's HOLD_FIX) leaves the lane
# clear-ready, since its session and work are unchanged, and names the human's step; anything else is refuse_clear's.
refuse_keys() {
  [[ -n "$3" ]] || refuse_clear "$1" "$2" "$4"
  hs_cas "$1" "$HS_SAME" '.state = "ready"' ||
    die "not cleared: $2" "$3; the record was left as it is: $HS_WHY"
  die "not cleared: $2" "$3, then run 'lanes clear $1' again; the lane is still clear-ready"
}

# identity_problem <lane> <pane> <session id>: why the pane does not host that session of the lane, or nothing. All
# must hold: the registry names the session and the pane, the session file is current (lane_session), the pane is on
# the tmux server the lane registered from, Claude Code runs as the pane's process or under it, and no other lane
# names the pane.
identity_problem() {
  local e f=() live=() other
  e="$(reg_read "$1")" || { echo "the registry entry for $1 is unreadable"; return; }
  jq_fields 4 '.session_id, (.tmux_pane // ""), (.tmux_pid // "" | tostring), (.claude_pid // "" | tostring)' "$e" || return 1
  f=("${FIELDS[@]}")
  [[ "${f[0]}" == "$3" ]] || { echo "the session of lane $1 changed"; return; }
  [[ "${f[1]}" == "$2" ]] || { echo "lane $1 no longer holds pane $2"; return; }
  lane_session "$1" || { echo "$SS_PROBLEM"; return; }
  read -r -a live <<<"$(pane_identity "$2")"
  [[ "${live[0]:-}" == "${f[2]}" ]] ||
    { echo "pane $2 is on another tmux server than the one lane $1 registered from (tmux restarted, or the pane id was reused)"; return; }
  pid_within "${f[3]}" "${live[1]:-}" ||
    { echo "Claude Code pid ${f[3]} of lane $1 is not the process of pane $2 or a child of it"; return; }
  # Another lane on this pane of this server (entry_on_pane); the same pane id on another server is another pane.
  while IFS= read -r other; do
    [[ "$other" != "$1" ]] && e="$(reg_read "$other")" && entry_on_pane "$e" "${f[2]}" "$2" &&
      { echo "pane $2 is also registered to lane $other"; return; }
  done < <(each_lane)
  return 0
}

# target_checks <lane> <entry>: the registered pane exists, is not this pane (the caller's pane on the caller's server,
# entry_on_pane), and keys sent to it reach this lane's session alone (keys_check). Sets PANE_T.
target_checks() {
  local lane="$1" e="$2"
  PANE_T="$(jq -r '.tmux_pane // ""' <<<"$e")"
  [[ -n "$PANE_T" ]] || die "lane $lane has no tmux pane registered" "start it inside tmux as 'claude --name $lane'"
  ! entry_on_pane "$e" "$(caller_server)" "${TMUX_PANE:-}" || die "lane $lane is this pane" "a session never clears itself or types into its own pane; the human clears the lead"
  pane_exists "$PANE_T" || die "pane $PANE_T of lane $lane does not exist" "the lane is gone; restart it as 'claude --name $lane'"
  keys_check "$lane" "$PANE_T" "$(jq -r .session_id <<<"$e")"
  [[ -z "$WHY" || -z "$HOLD_FIX" ]] || die "$REFUSAL: $WHY" "$HOLD_FIX, then run the command again; nothing was typed or written"
  [[ -z "$WHY" ]] || die "$REFUSAL: $WHY" "check 'lanes status'; never type into a pane whose session is not proven"
}

# changed_since_ready <lane> <entry> <state>: what changed since clear-ready (session, head, tree, RESUME, prompts, a
# turn begun without a prompt), each reason ending "since clear-ready", or nothing.
changed_since_ready() {
  local e="$2" st="$3" wt block tp n
  wt="$(jq -r '.handshake.worktree // ""' <<<"$st")"
  [[ "$(jq -r .session_id <<<"$e")" == "$(jq -r .handshake.session_id <<<"$st")" ]] || { echo "the session changed since clear-ready"; return; }
  [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" == "$(jq -r .handshake.head <<<"$st")" ]] || { echo "HEAD moved since clear-ready"; return; }
  why_of tree_problem "$1" "$wt"
  [[ -z "$WHY" ]] || { echo "the tree stopped being clean and pushed ($WHY) since clear-ready"; return; }
  block="$(resume_block "$(resume_path "$1" "$wt")" || true)"
  [[ "$(hash_of "$block")" == "$(jq -r .handshake.resume_hash <<<"$st")" ]] || { echo "the RESUME block changed since clear-ready"; return; }
  [[ "$(jq -r '.prompts // 0' <<<"$st")" == "$(jq -r '.handshake.prompts // 0' <<<"$st")" ]] ||
    { echo "the lane received a new prompt since clear-ready"; return; }
  # A turn can begin with no prompt (a /goal loop going on, a finished background shell), so the transcript is read.
  tp="$(jq -r '.handshake.transcript // ""' <<<"$st")"
  n=""
  if [[ "$(jq -r '.handshake.turns // ""' <<<"$st")" =~ ^[0-9]+$ ]]; then n="$(turn_starts "$tp")" || n=""; fi
  [[ -n "$n" ]] ||
    { echo "the lane's transcript '$tp' could not be read, so a turn begun since clear-ready cannot be ruled out"; return; }
  [[ "$n" == "$(jq -r .handshake.turns <<<"$st")" ]] ||
    echo "the lane began another turn since clear-ready (its /goal went on, a background shell finished, or a message arrived)"
}

# final_verify <lane> <pane>: after the wait, the record is still ready (it becomes HS_WAS, the one hs_sending moves)
# and the pane still hosts this session; a failure drops clear-ready, except a key-path hold (refuse_keys). What
# clear-ready proved (changed_since_ready) and activity are send_guard's, run before each key.
final_verify() {
  local lane="$1" pane="$2" e st
  st="$(state_read "$lane")"
  HS_WAS="$(jq -c '.handshake // null' <<<"$st")"
  e="$(reg_read "$lane")" || refuse_clear "$lane" "the registry entry became unreadable" "check 'lanes status'"
  why_of ready_problem "$lane" "$(jq -r '.handshake.state // "none"' <<<"$st")"
  [[ -z "$WHY" ]] || die "$REFUSAL: $WHY" "nothing was typed; the record was left as it is"
  keys_check "$lane" "$pane" "$(jq -r .handshake.session_id <<<"$st")"
  [[ -z "$WHY" ]] || refuse_keys "$lane" "$WHY" "$HOLD_FIX" "check 'lanes status'; a pane belongs to the lane that registered last in it"
}

# ready_problem <lane> <handshake state>: why a clear may not go on from that record, or nothing when it is ready. A
# record that changed while the command ran belongs to whoever changed it, so the caller leaves it as it is.
ready_problem() {
  case "$2" in
    ready) ;;
    requested) echo "a new 'lanes request $1' arrived while this command ran; the request stands, so the lane reports clear-ready again first" ;;
    *) echo "the handshake of $1 changed to '$2' while this command ran" ;;
  esac
}

# hs_sending <lane>: move the ready record final_verify proved to sending, or refuse and leave it as it is (a request
# that landed after final_verify stands).
hs_sending() {
  hs_cas "$1" "$HS_SAME" '.state = "sending" | .attempts = ((.attempts // 0) + 1) | .sent_at = $now' \
    --argjson now "$(now)" || die "$REFUSAL: $HS_WHY" "nothing was typed; the record was left as it is"
}

# idle_point <lane> <pane> <seconds> <session id> <ready 0|1> [shell]: settle, then arm send_guard with the
# signature of the observation that proved the lane idle, so any change after it stops the next key.
idle_point() {
  settle "$1" "$2" "$3" "${6:-}"
  GUARD_SID="$4" GUARD_READY="$5" GUARD_SIG="$IDLE_SIG"
}

# send_goal <lane> <pane> <session id> <goal>: type /goal <goal> into the idle input line; the session's
# UserPromptSubmit recording that goal confirms it. Returns submit's code, with MOVED and ERASED set on 2 and 3.
send_goal() {
  local base
  base="$(state_read "$1" | jq -r '.prompts // 0')"
  submit "$1" "$2" "/goal $4" wait_goal_seen "$1" "$3" "$4" "$base"
}

# wait_arg <args...>: sets WAIT_S from an optional `--wait <seconds>` (default 60); anything else is a usage error.
wait_arg() {
  WAIT_S=60
  while (($#)); do
    if [[ "$1" != --wait ]] || (($# < 2)); then usage; fi
    WAIT_S="$2"
    shift 2
  done
  # The rule of the LANES_ timers (settings_check): a plain whole number in range, read as decimal.
  int_in_range "$WAIT_S" 0 3600 || die "--wait '$WAIT_S' is not a whole number of seconds from 0 to 3600" "pass one in that range" 2
  WAIT_S=$((10#$WAIT_S))
}

# restart_problem <lane> <session id>: why that session of the lane is not the one a /clear created, or nothing.
# register records each session's SessionStart source as .start_source; the state is read under the mutex, so a
# register still writing it is waited for.
restart_problem() {
  local src
  mutex_take 5 || return 1
  src="$(state_read "$1" | jq -r --arg s "$2" 'if .session_id == $s then .start_source // "unknown" else "unknown" end')" ||
    { mutex_drop; return 1; }
  mutex_drop
  [[ "$src" == clear ]] || echo "the lane restarted (source $src) instead of clearing"
}

cmd_clear() {
  local lane="${1:-}" wait_s e st hs pane sid goal new_sid rc=0 age note
  valid_lane "$lane" || usage
  shift
  wait_arg "$@"
  wait_s="$WAIT_S"
  require_lead "clears a lane"
  require_own_lane "$lane"
  clear_lock "$lane"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane' (missing, half-written or corrupt)" "the lane re-registers on its next session start; check 'lanes status'"
  st="$(state_read "$lane")"
  HS_WAS="$(jq -c '.handshake // null' <<<"$st")"
  hs="$(jq -r '.state // "none"' <<<"$HS_WAS")"
  sid="$(jq -r .session_id <<<"$e")"
  target_checks "$lane" "$e"
  pane="$PANE_T"

  # A clear that stopped part-way is resumed only while its record is young, and its goal only into the session the
  # /clear created, before anyone has prompted it.
  case "$hs" in
    sending)
      age=$(($(now) - $(jq -r '.sent_at // 0' <<<"$HS_WAS")))
      ((age <= REQUEST_TIMEOUT)) ||
        refuse_clear "$lane" "an earlier clear stopped at sending $age s ago, older than LANES_REQUEST_TIMEOUT ($REQUEST_TIMEOUT s)" "start a new handshake with 'lanes request $lane'"
      if [[ "$sid" != "$(jq -r .session_id <<<"$HS_WAS")" ]]; then
        why_of restart_problem "$lane" "$sid"
        [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "the goal is not sent into a session no /clear created; start a new handshake with 'lanes request $lane'"
        hs_cas "$lane" "$HS_SAME" '.state = "cleared" | .cleared_at = $now | .cleared_session = $sid' \
          --argjson now "$(now)" --arg sid "$sid" || die "$REFUSAL: $HS_WHY" "nothing was typed; the record was left as it is"
        hs=cleared
      else
        echo "lanes: an earlier clear of $lane stopped before /clear landed; checking again from the start" >&2
        hs_cas "$lane" "$HS_SAME" '.state = "ready"' || die "$REFUSAL: $HS_WHY" "nothing was typed; the record was left as it is"
        hs=ready
      fi
      ;;
    cleared | ready) ;;
    *) die "lane $lane is not clear-ready (handshake: $hs)" "ask the lane to finish, push and run 'lanes clear-ready'" ;;
  esac
  if [[ "$hs" == cleared ]]; then
    [[ "$(jq -r '.cleared_session // ""' <<<"$HS_WAS")" == "$sid" ]] ||
      die "lane $lane cleared or restarted in another session since this handshake's /clear" "the goal is not resent into it; start a new handshake with 'lanes request $lane'"
    age=$(($(now) - $(jq -r '.cleared_at // 0' <<<"$HS_WAS")))
    ((age <= REQUEST_TIMEOUT)) ||
      die "the handshake's /clear landed $age s ago, older than LANES_REQUEST_TIMEOUT ($REQUEST_TIMEOUT s)" "the goal is not resent so late; set it with 'lanes goal $lane' or start a new handshake"
    why_of unused_problem "$lane" "$sid"
    [[ -z "$WHY" ]] || die "goal not sent: $WHY" "the goal is not typed into a session in use; set it with 'lanes goal $lane \"<goal>\"'"
  fi

  # /clear also removes an active /goal (code.claude.com/docs/en/goal; measured on 2.1.309), so none is cleared first.
  # No Escape goes before it: an idle session with an empty input line needs none, and Escape interrupts a turn.
  if [[ "$hs" == ready ]]; then
    why_of changed_since_ready "$lane" "$e" "$st"
    [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "ask the lane to finish, push and report clear-ready again"
    idle_point "$lane" "$pane" "$wait_s" "$sid" 1
    final_verify "$lane" "$pane"
    hs_sending "$lane"
    rc=0
    submit "$lane" "$pane" "/clear" wait_new_session "$lane" "$sid" || rc=$?
    ((rc != 2)) || refuse_keys "$lane" "$MOVED before /clear was sent" "${MOVED_FIX:+nothing was submitted ($ERASED); $MOVED_FIX}" "nothing was submitted ($ERASED); ask the lane to report clear-ready again"
    # The record is left at sending: a rerun finds whether /clear landed late (a new session) or starts over.
    ((rc != 3)) || die "/clear was sent to $pane once, then $MOVED" "it may have been taken late ($ERASED); run 'lanes status', then 'lanes clear $lane' again, which resumes from the record"
    if ((rc != 0)); then
      hs_cas "$lane" "$HS_SAME" '.state = "failed" | .failed = "clear not confirmed"' || true
      die "/clear was sent to $pane but no new session appeared in its sessions file and the registry" "look at the pane; the clear is not confirmed and was not retried further"
    fi
  fi

  e="$(reg_read "$lane")" || die "registry entry for '$lane' unreadable after /clear" "check 'lanes status'"
  new_sid="$(jq -r .session_id <<<"$e")"
  if [[ "$hs" == ready ]]; then
    # A restarted session leaves the record at sending (register moves it only on a /clear), so refuse_clear finds it.
    why_of restart_problem "$lane" "$new_sid"
    [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "the goal is not sent into a session no /clear created; look at the pane, then start a new handshake with 'lanes request $lane'"
    # The sending record, or register's cleared one for this session, is what this clear proved; anything else (a
    # request that landed after /clear) stands, and no goal is sent from it.
    hs_cas "$lane" "$HS_SAME_OR_CLEARED" '.state = "cleared" | .cleared_at = $now | .cleared_session = $sid' \
      --argjson now "$(now)" --arg sid "$new_sid" ||
      die "$REFUSAL: /clear landed in $pane, then $HS_WHY" "the goal was not sent and the record was left as it is; wait for the lane's new 'clear-ready', or set the goal with 'lanes goal $lane'"
  fi
  goal="$(jq -r '.goal // ""' <<<"$HS_WAS")"
  if [[ -n "$goal" ]]; then
    wait_composer_empty "$pane" || die "the cleared session in $pane shows no empty input line" "look at the pane; the goal was not sent"
    idle_point "$lane" "$pane" "$wait_s" "$new_sid" 0
    # The goal goes only into an unused session, checked last before the goal is typed and before its Enter.
    GUARD_UNUSED=1
    rc=0
    send_goal "$lane" "$pane" "$new_sid" "$goal" || rc=$?
    if ((rc == 2)); then
      why_of unused_problem "$lane" "$new_sid"
      [[ -z "$WHY" ]] || die "goal not sent: $WHY" "nothing was submitted ($ERASED); the goal is not typed into a session in use; set it with 'lanes goal $lane \"<goal>\"'"
      die "goal not sent: $MOVED" "nothing was submitted ($ERASED); run 'lanes clear $lane' again to send it"
    fi
    ((rc != 3)) || die "/goal was sent to $pane once, then $MOVED" "it may have been taken late ($ERASED); look at the pane and 'lanes status' before sending it again"
    if ((rc != 0)); then
      hs_cas "$lane" "$HS_SAME" '.state = "failed" | .failed = "goal not confirmed"' || true
      die "/goal was typed into $pane but the session never received it" "look at the pane and set the goal with 'lanes goal $lane'"
    fi
  fi
  # A record another command changed meanwhile (a new request) keeps its own clear_ready.
  note=""
  rc=0
  mutex_take 5 || rc=$?
  ((rc == 0)) || die "$(mutex_refusal "$rc")" "the clear landed${goal:+ and its goal is set}, but its record was not closed; check 'lanes status'"
  if hs_cas_locked "$lane" "$HS_SAME" '.state = "done" | .done_at = $now' --argjson now "$(now)"; then
    reg_update "$lane" '.clear_ready = false' || true
  else
    note="; its record was left as it is: $HS_WHY"
  fi
  mutex_drop
  echo "cleared: $lane (pane $pane) has a new session${goal:+ and its goal is set}$note"
}

# cmd_goal <lane> <text> [--wait s]: the lead sets or replaces a lane's /goal (a new /goal replaces an active one,
# code.claude.com/docs/en/goal) through the same checks as lanes clear; the prompt hook's last_command confirms it
# arrived. A background shell does not stop it, since unlike /clear a new goal leaves the shell's session in place.
cmd_goal() {
  local lane="${1:-}" goal wait_s e rc=0 sid
  if ! valid_lane "$lane" || (($# < 2)); then usage; fi
  goal="$(trim "$2")"
  shift 2
  wait_arg "$@"
  wait_s="$WAIT_S"
  why_of goal_problem "$goal"
  [[ -z "$WHY" ]] || die "goal not sent: the goal $WHY" "pass it as one line of at most $GOAL_CAP characters" 2
  require_lead "sets a lane's goal"
  REFUSAL="goal not sent"
  require_own_lane "$lane"
  clear_lock "$lane"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "check 'lanes status'"
  target_checks "$lane" "$e"
  sid="$(jq -r .session_id <<<"$e")"
  idle_point "$lane" "$PANE_T" "$wait_s" "$sid" 0 shell
  send_goal "$lane" "$PANE_T" "$sid" "$goal" || rc=$?
  ((rc != 2)) || die "goal not sent: $MOVED" "nothing was submitted ($ERASED); run lanes goal again when the lane is idle"
  ((rc != 3)) || die "/goal was sent to $PANE_T once, then $MOVED" "it may have been taken late ($ERASED); look at the pane before sending it again"
  ((rc == 0)) || die "/goal was typed into $PANE_T but the session never received it" "look at the pane"
  echo "goal set: $lane (pane $PANE_T)"
}
