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
# proven rewritten and committed since the lead's request, or nothing. The request saw the block where it last knew
# the lane (its hash then), and the lane may have moved work tree since, so the proof is the commit time, which needs
# no path; a journal outside git has one fixed path, where the hash alone proves it.
rewritten_problem() {
  local ct
  [[ "$4" =~ ^[0-9]+$ ]] || return 1
  [[ "$2" != "$3" ]] ||
    { echo "the RESUME block is unchanged since the lead's request: rewrite it with your current state, commit and push"; return; }
  git -C "$(dirname "$1")" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  ct="$(git -C "$(dirname "$1")" log -1 --format=%ct -- "$1" 2>/dev/null)" || return 1
  [[ "$ct" =~ ^[0-9]+$ ]] && ((ct >= $4)) ||
    echo "the RESUME in $1 was last committed before the lead's request: rewrite it with your current state, commit and push"
}

# turn_starts <transcript>: how many turns the transcript shows begun, by the entry each one starts with: a user entry
# that is not only tool results (a prompt, a Stop hook's feedback such as a /goal verdict, a task notification), or a
# goal_status verdict that sends the goal loop on (met false, not the sentinel; 2.1.309). A missing file has none yet.
turn_starts() {
  [[ -n "$1" ]] || return 1
  [[ -e "$1" ]] || { echo 0; return 0; }
  [[ -r "$1" ]] || return 1
  { grep -E '"type":"(user|attachment)"' "$1" || true; } | jq -Rn '[inputs | fromjson? | select(
      (.type == "user" and ((.message.content | type) != "array" or (.message.content | any(.type != "tool_result"))))
      or (.type == "attachment" and .attachment.type == "goal_status" and .attachment.met == false
          and (.attachment.sentinel | not)))] | length'
}

# self_lane [--lane x]: which lane runs this command (the Bash tool carries TMUX_PANE, not the plugin's variables); a
# pane registered to a lane speaks only for that lane.
self_lane() {
  local caller
  if [[ -n "${1:-}" ]]; then
    valid_lane "$1" || die "invalid lane '$1'" "use the name the session was started with" 2
    caller="$(caller_lane)"
    [[ -z "$caller" || "$caller" == "$1" ]] ||
      die "not clear-ready: pane ${TMUX_PANE:-} is lane $caller, not $1" "a lane reports only its own readiness: run 'lanes clear-ready' in $1's own pane" 2
    echo "$1"
  elif lane_for_pane "${TMUX_PANE:-}"; then
    :
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

cmd_request() {
  local lane="${1:-}" e file block="" h="" wt
  if ! valid_lane "$lane" || (($# != 1)); then usage; fi
  require_lead "requests a clear"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "check 'lanes status'; the lane must be started as 'claude --name $lane'"
  # The block is hashed where the lane last was: the work tree the last clear-ready proved, else the session's cwd.
  wt="$(state_read "$lane" | jq -r '.handshake.worktree // ""')"
  file="$(resume_path "$lane" "${wt:-$(jq -r .cwd <<<"$e")}")"
  block="$(resume_block "$file" || true)"
  [[ -n "$block" ]] && h="$(hash_of "$block")"
  mutex_take 5 || die "registry locked" "retry in a moment"
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
  local arg="" lane e st wt file block h goal tp turns
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
  if [[ "$(jq -r '.handshake.state // ""' <<<"$st")" == requested ]]; then
    why_of rewritten_problem "$file" "$h" "$(jq -r '.handshake.request_resume_hash // ""' <<<"$st")" \
      "$(jq -r '.handshake.requested_at // 0' <<<"$st")"
    [[ -z "$WHY" ]] || die "not clear-ready" "$WHY"
  fi
  goal="$(trim "$(section_text "$block" Goal)")"
  # The turns begun so far, this one included: one more later means the lane worked on after reporting ready.
  tp="$(jq -r '.transcript // ""' <<<"$st")"
  turns="$(turn_starts "$tp")" || turns=""
  mutex_take 5 || die "registry locked" "retry in a moment"
  # Ownership is decided under the mutex: a session that took the lane meanwhile is not marked ready for the old one.
  [[ "$(reg_read "$lane" | jq -r .session_id 2>/dev/null)" == "$(jq -r .session_id <<<"$e")" ]] ||
    die "not clear-ready" "lane $lane started a new session while clear-ready ran: run it again"
  state_update "$lane" '.handshake = {state: "ready", ready_at: $now, requested_at: .handshake.requested_at,
      session_id: $sid, worktree: $wt, head: $head, resume_hash: $h, prompts: (.prompts // 0), goal: $goal, attempts: 0,
      transcript: $tp, turns: $turns}' \
    --argjson now "$(now)" --arg sid "$(jq -r .session_id <<<"$e")" --arg wt "$wt" --arg head "$(git -C "$wt" rev-parse HEAD)" \
    --arg h "$h" --arg goal "$goal" --arg tp "$tp" --arg turns "$turns"
  reg_update "$lane" '.clear_ready = true'
  mutex_drop
  echo "clear-ready: $lane at $(git -C "$wt" rev-parse --short HEAD). Tell the lead \"clear-ready\", then stop and wait."
}

# ---- screen: the one fact with no native signal, a human's draft in the input line -------------------------------

# screen_read <pane>: sets COMPOSER (the typed text, all its wrapped lines; empty for the placeholder) and
# COMPOSER_FOUND (0 when no `❯`+NBSP input line is on screen, as under a dialog or another program). The layout is
# Claude Code 2.1.309's (tests/lanes/captures); the last input line counts, and the pattern holds under LC_ALL=C.
screen_read() {
  local pane="$1" raw plain i line idx=-1 body bottom
  COMPOSER="" COMPOSER_FOUND=0
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
  body="${rawlines[idx]#*"$PROMPT_MARK"}"
  [[ "$body" != $'\e[2m'* ]] || return 0
  # The input wraps onto lines indented two spaces, down to the bottom rule; they join with one space.
  COMPOSER="$(sed $'s/\x1b\\[[0-9;]*m//g; s/[[:space:]]*$//' <<<"$body")"
  for ((bottom = idx + 1; bottom < ${#lines[@]}; bottom++)); do
    [[ "${lines[bottom]}" == "─"* ]] && break
    line="${lines[bottom]#  }"
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
# lane alone, or empty. In copy mode they go to tmux, with synchronize-panes to every pane of the window, and while
# Claude Code is not the terminal's foreground program to whatever is; for those three HOLD_FIX names the human's
# step, since the session is still proven and its clear-ready still holds (empty for any other objection).
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
  [[ -z "$WHY" ]] || check_failed ||
    HOLD_FIX="bring Claude Code back to the foreground of pane $2 (fg in the shell it was started from)"
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
# GUARD_SIG (SS_SIG at the proven idle point) and GUARD_READY (1: the clear-ready proof must still hold); <input> is
# what the input line must hold.
GUARD_SID="" GUARD_SIG="" GUARD_READY=0
send_guard() {
  keys_check "$1" "$2" "$GUARD_SID"
  if [[ -z "$WHY" ]] && ((GUARD_READY)); then why_of changed_since_ready "$1" "$(reg_read "$1")" "$(state_read "$1")"; fi
  [[ -n "$WHY" ]] || why_of moved_problem "$1"
  [[ -n "$WHY" ]] || why_of composer_problem "$2" "${@:3}"
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

# erase_if_ours <lane> <pane> <text>: delete our typed text from its end, one burst of at most 64 Backspaces at a
# time. Before each burst the input line is read again and must hold only the part of our text not yet deleted (or
# less of it), and keys_check must pass, so text someone typed meanwhile is never deleted; a screen that still shows
# more than that is read again for up to a second. Sets ERASED to what happened, for the message.
erase_if_ours() {
  local left least len n keys plan sent=0 tries=0 burst=()
  left="$(printf '%s' "$3" | jq -Rs 'explode | length')" ||
    { ERASED="our typed text was left in the input line of $2, because its length could not be counted"; return 0; }
  while :; do
    screen_read "$2"
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
    keys_check "$1" "$2" "$GUARD_SID"
    [[ -z "$WHY" ]] || { ERASED="our typed text was left in the input line of $2, because $WHY"; return 0; }
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
  # A kill (the Bash tool's timeout) deletes what was typed so far while the input line holds only that, and says so.
  TYPED="" SUBMIT_PANE="$2" SUBMIT_LANE="$1"
  trap 'if [[ -n "$TYPED" ]]; then erase_if_ours "$SUBMIT_LANE" "$SUBMIT_PANE" "$TYPED"; else ERASED="nothing was typed"; fi
    echo "lanes: stopped while typing into $SUBMIT_PANE: $ERASED" >&2; exit 143' TERM INT
  submit_keys "$@" || rc=$?
  trap 'exit 143' TERM INT # bin/lanes' own handler again
  return "$rc"
}

submit_keys() {
  local lane="$1" pane="$2" text="$3"
  shift 3
  ERASED="nothing was typed" MOVED_FIX=""
  send_guard "$lane" "$pane"
  MOVED="$WHY" MOVED_FIX="$HOLD_FIX"
  [[ -z "$MOVED" ]] || return 2
  if ! send_text "$lane" "$pane" "$text"; then
    erase_if_ours "$lane" "$pane" "$TYPED"
    return 2
  fi
  sleep 0.3
  screen_read "$pane"
  # The composer is compared whole and without spaces, since Claude Code wraps a long line at any space.
  if [[ "$(squash "$COMPOSER")" != "$(squash "$text")" ]]; then
    [[ "$(squash "$COMPOSER")" != *"$(squash "$text")" ]] ||
      die "$REFUSAL: text arrived in the input line of $pane ahead of ours" "nothing was submitted or deleted: the line holds that text with ours after it; look at the pane"
    die "typed text did not arrive intact (input line shows '${COMPOSER:0:60}')" "look at pane $pane; nothing was submitted and the input line was left as it is"
  fi
  send_guard "$lane" "$pane" "$text"
  MOVED="$WHY" MOVED_FIX="$HOLD_FIX"
  if [[ -n "$MOVED" ]]; then
    erase_if_ours "$lane" "$pane" "$text"
    return 2
  fi
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
  local path="$STATE/$1.clear.lnk"
  mkdir -p "$STATE"
  lock_take "$path" 0 ||
    die "another 'lanes clear $1' is running (or 'lanes goal $1'; pid $(lock_holder "$path"))" "let it finish; never run two at once"
  # shellcheck disable=SC2034 # on_exit in bin/lanes releases it
  CLEAR_LOCK="$path" CLEAR_MINE="$LOCK_MINE"
}

hs_set() { # hs_set <lane> <jq filter on .handshake> [args]
  local lane="$1" filter="$2"
  shift 2
  mutex_take 5 || die "registry locked" "retry in a moment"
  state_update "$lane" ".handshake |= ($filter)" "$@"
  mutex_drop
}

refuse_clear() { # refuse_clear <lane> <reason> <what to do>: drops clear-ready so the lane must report it again
  mutex_take 5 && {
    reg_update "$1" '.clear_ready = false' || true
    state_update "$1" '.handshake.state = "stale" | .handshake.stale_reason = $r' --arg r "$2"
    mutex_drop
  }
  die "not cleared: $2" "$3"
}

# refuse_keys <lane> <reason> <hold fix> <what to do>: a key-path hold (keys_check's HOLD_FIX) leaves the lane
# clear-ready, since its session and work are unchanged, and names the human's step; anything else is refuse_clear's.
refuse_keys() {
  [[ -n "$3" ]] || refuse_clear "$1" "$2" "$4"
  hs_set "$1" '.state = "ready"'
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
  while IFS= read -r other; do
    [[ "$other" != "$1" && "$(reg_read "$other" | jq -r '.tmux_pane // ""' 2>/dev/null)" == "$2" ]] &&
      { echo "pane $2 is also registered to lane $other"; return; }
  done < <(each_lane)
  return 0
}

# target_checks <lane> <entry>: the registered pane exists, is not this pane, and keys sent to it reach this lane's
# session alone (keys_check). Sets PANE_T.
target_checks() {
  local lane="$1" e="$2"
  PANE_T="$(jq -r '.tmux_pane // ""' <<<"$e")"
  [[ -n "$PANE_T" ]] || die "lane $lane has no tmux pane registered" "start it inside tmux as 'claude --name $lane'"
  [[ "$PANE_T" != "${TMUX_PANE:-}" ]] || die "lane $lane is this pane" "a session never clears itself or types into its own pane; the human clears the lead"
  pane_exists "$PANE_T" || die "pane $PANE_T of lane $lane does not exist" "the lane is gone; restart it as 'claude --name $lane'"
  keys_check "$lane" "$PANE_T" "$(jq -r .session_id <<<"$e")"
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

# final_verify <lane> <pane>: after the wait, prove again everything clear-ready proved and that the pane still hosts
# this session; a failure drops clear-ready, except a key-path hold (refuse_keys). Activity is send_guard's, before
# each key.
final_verify() {
  local lane="$1" pane="$2" e st
  e="$(reg_read "$lane")" || refuse_clear "$lane" "the registry entry became unreadable" "check 'lanes status'"
  st="$(state_read "$lane")"
  why_of changed_since_ready "$lane" "$e" "$st"
  [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "ask the lane to finish, push and report clear-ready again"
  keys_check "$lane" "$pane" "$(jq -r .handshake.session_id <<<"$st")"
  [[ -z "$WHY" ]] || refuse_keys "$lane" "$WHY" "$HOLD_FIX" "check 'lanes status'; a pane belongs to the lane that registered last in it"
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
  [[ "$WAIT_S" =~ ^[0-9]+$ ]] || die "--wait '$WAIT_S' is not a number of seconds" "pass a whole number" 2
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
  local lane="${1:-}" wait_s e st hs pane sid goal new_sid rc=0 age
  valid_lane "$lane" || usage
  shift
  wait_arg "$@"
  wait_s="$WAIT_S"
  require_lead "clears a lane"
  clear_lock "$lane"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane' (missing, half-written or corrupt)" "the lane re-registers on its next session start; check 'lanes status'"
  st="$(state_read "$lane")"
  hs="$(jq -r '.handshake.state // "none"' <<<"$st")"
  sid="$(jq -r .session_id <<<"$e")"
  target_checks "$lane" "$e"
  pane="$PANE_T"

  # A clear that stopped part-way is resumed only while its record is young, and its goal only into the session the
  # /clear created, before anyone has prompted it.
  case "$hs" in
    sending)
      age=$(($(now) - $(jq -r '.handshake.sent_at // 0' <<<"$st")))
      ((age <= REQUEST_TIMEOUT)) ||
        refuse_clear "$lane" "an earlier clear stopped at sending $age s ago, older than LANES_REQUEST_TIMEOUT ($REQUEST_TIMEOUT s)" "start a new handshake with 'lanes request $lane'"
      if [[ "$sid" != "$(jq -r .handshake.session_id <<<"$st")" ]]; then
        why_of restart_problem "$lane" "$sid"
        [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "the goal is not sent into a session no /clear created; start a new handshake with 'lanes request $lane'"
        hs_set "$lane" '.state = "cleared" | .cleared_at = $now | .cleared_session = $sid' --argjson now "$(now)" --arg sid "$sid"
        st="$(state_read "$lane")"
        hs=cleared
      else
        echo "lanes: an earlier clear of $lane stopped before /clear landed; checking again from the start" >&2
        hs=ready
      fi
      ;;
    cleared | ready) ;;
    *) die "lane $lane is not clear-ready (handshake: $hs)" "ask the lane to finish, push and run 'lanes clear-ready'" ;;
  esac
  if [[ "$hs" == cleared ]]; then
    [[ "$(jq -r '.handshake.cleared_session // ""' <<<"$st")" == "$sid" ]] ||
      die "lane $lane cleared or restarted in another session since this handshake's /clear" "the goal is not resent into it; start a new handshake with 'lanes request $lane'"
    age=$(($(now) - $(jq -r '.handshake.cleared_at // 0' <<<"$st")))
    ((age <= REQUEST_TIMEOUT)) ||
      die "the handshake's /clear landed $age s ago, older than LANES_REQUEST_TIMEOUT ($REQUEST_TIMEOUT s)" "the goal is not resent so late; set it with 'lanes goal $lane' or start a new handshake"
    (($(jq -r '.prompts // 0' <<<"$st") == 0)) ||
      die "the session the /clear created already has $(jq -r .prompts <<<"$st") prompt(s)" "the goal is not typed into a session in use; set it with 'lanes goal $lane \"<goal>\"'"
  fi

  # /clear also removes an active /goal (code.claude.com/docs/en/goal; measured on 2.1.309), so none is cleared first.
  # No Escape goes before it: an idle session with an empty input line needs none, and Escape interrupts a turn.
  if [[ "$hs" == ready ]]; then
    why_of changed_since_ready "$lane" "$e" "$st"
    [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "ask the lane to finish, push and report clear-ready again"
    idle_point "$lane" "$pane" "$wait_s" "$sid" 1
    final_verify "$lane" "$pane"
    hs_set "$lane" '.state = "sending" | .attempts = ((.attempts // 0) + 1) | .sent_at = $now' --argjson now "$(now)"
    rc=0
    submit "$lane" "$pane" "/clear" wait_new_session "$lane" "$sid" || rc=$?
    ((rc != 2)) || refuse_keys "$lane" "$MOVED before /clear was sent" "${MOVED_FIX:+nothing was submitted ($ERASED); $MOVED_FIX}" "nothing was submitted ($ERASED); ask the lane to report clear-ready again"
    # The record is left at sending: a rerun finds whether /clear landed late (a new session) or starts over.
    ((rc != 3)) || die "/clear was sent to $pane once, then $MOVED" "it may have been taken late ($ERASED); run 'lanes status', then 'lanes clear $lane' again, which resumes from the record"
    if ((rc != 0)); then
      hs_set "$lane" '.state = "failed" | .failed = "clear not confirmed"'
      die "/clear was sent to $pane but no new session appeared in its sessions file and the registry" "look at the pane; the clear is not confirmed and was not retried further"
    fi
  fi

  e="$(reg_read "$lane")" || die "registry entry for '$lane' unreadable after /clear" "check 'lanes status'"
  new_sid="$(jq -r .session_id <<<"$e")"
  if [[ "$hs" == ready ]]; then
    why_of restart_problem "$lane" "$new_sid"
    [[ -z "$WHY" ]] || refuse_clear "$lane" "$WHY" "the goal is not sent into a session no /clear created; look at the pane, then start a new handshake with 'lanes request $lane'"
  fi
  [[ "$hs" != ready ]] || hs_set "$lane" '.state = "cleared" | .cleared_at = $now | .cleared_session = $sid' --argjson now "$(now)" --arg sid "$new_sid"
  goal="$(state_read "$lane" | jq -r '.handshake.goal // ""')"
  if [[ -n "$goal" ]]; then
    wait_composer_empty "$pane" || die "the cleared session in $pane shows no empty input line" "look at the pane; the goal was not sent"
    idle_point "$lane" "$pane" "$wait_s" "$new_sid" 0
    rc=0
    send_goal "$lane" "$pane" "$new_sid" "$goal" || rc=$?
    ((rc != 2)) || die "goal not sent: $MOVED" "nothing was submitted ($ERASED); run 'lanes clear $lane' again to send it"
    ((rc != 3)) || die "/goal was sent to $pane once, then $MOVED" "it may have been taken late ($ERASED); look at the pane and 'lanes status' before sending it again"
    if ((rc != 0)); then
      hs_set "$lane" '.state = "failed" | .failed = "goal not confirmed"'
      die "/goal was typed into $pane but the session never received it" "look at the pane and set the goal with 'lanes goal $lane'"
    fi
  fi
  hs_set "$lane" '.state = "done" | .done_at = $now' --argjson now "$(now)"
  mutex_take 5 && { reg_update "$lane" '.clear_ready = false' || true; mutex_drop; }
  echo "cleared: $lane (pane $pane) has a new session${goal:+ and its goal is set}"
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
