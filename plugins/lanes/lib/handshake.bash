# shellcheck shell=bash
# jq programs are single-quoted on purpose: their $names are jq variables, not shell ones.
# shellcheck disable=SC2016
# lanes handshake: request, clear-ready, the screen veto, typed sends, and the clear and goal commands. bin/lanes
# sources it after defining the registry, state, lock and RESUME helpers used here; this file only defines functions.

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

# self_lane [--lane x]: which lane runs this command (the Bash tool carries TMUX_PANE, not the plugin's variables).
self_lane() {
  if [[ -n "${1:-}" ]]; then
    valid_lane "$1" || die "invalid lane '$1'" "use the name the session was started with" 2
    echo "$1"
  elif lane_for_pane "${TMUX_PANE:-}"; then
    :
  else
    die "cannot tell which lane this is" "run it inside the lane's tmux pane, or pass --lane <name>"
  fi
}

cmd_request() {
  local lane="${1:-}" e file block="" h="" wt
  valid_lane "$lane" || usage
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "check 'lanes status'; the lane must be started as 'claude --name $lane'"
  # One RESUME location for request and clear-ready: the work tree the last clear-ready proved, else the session's cwd.
  wt="$(state_read "$lane" | jq -r '.handshake.worktree // ""')"
  file="$(resume_path "$lane" "${wt:-$(jq -r .cwd <<<"$e")}")"
  block="$(resume_block "$file" || true)"
  [[ -n "$block" ]] && h="$(hash_of "$block")"
  mutex_take 5 || die "registry locked" "retry in a moment"
  [[ "$(state_read "$lane" | jq -r '.handshake.state // ""')" != sending ]] ||
    die "a clear of $lane is in flight (handshake: sending)" "run 'lanes clear $lane' to finish or settle it before a new request"
  state_update "$lane" '.handshake = {state: "requested", requested_at: $now, request_file: $f, request_resume_hash: $h,
      worktree: .handshake.worktree}' --argjson now "$(now)" --arg f "$file" --arg h "$h"
  reg_update "$lane" '.clear_ready = false'
  mutex_drop
  echo "requested: message $lane: \"Context is at threshold. Finish the change in hand, rewrite your RESUME block in $file, commit and push, run 'lanes clear-ready' from your work tree, tell me 'clear-ready', then stop.\""
}

# cmd_clear_ready: the work tree is the one the lane runs this from (its Bash tool's directory), not the directory the
# session started in. The goal recorded is the lane's current /goal, else the RESUME Goal.
cmd_clear_ready() {
  local arg="" lane e st wt file block problems prob h goal req
  [[ "${1:-}" == "--lane" ]] && arg="${2:-}"
  lane="$(self_lane "$arg")"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "restart the session as 'claude --name $lane' inside tmux"
  wt="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" ||
    die "not clear-ready" "$PWD is not a git work tree: run 'lanes clear-ready' from the work tree you work in"
  prob="$(git_problem "$wt")"
  [[ -z "$prob" ]] || die "not clear-ready" "$prob"
  file="$(resume_path "$lane" "$wt")"
  block="$(resume_block "$file")" || die "not clear-ready" "no RESUME block in $file: run 'lanes init $lane' and fill it in"
  problems="$(resume_problems "$block")"
  [[ -z "$problems" ]] || die "not clear-ready" "$(tr '\n' ';' <<<"$problems")"
  h="$(hash_of "$block")"
  st="$(state_read "$lane")"
  if [[ "$(jq -r '.handshake.state // ""' <<<"$st")" == requested ]]; then
    req="$(jq -r '.handshake.request_file // ""' <<<"$st")"
    [[ -z "$req" || "$req" == "$file" ]] ||
      die "not clear-ready" "the lead's request read RESUME at $req, but this work tree's is $file: run clear-ready where $req lives, or ask the lead to request again"
    [[ "$(jq -r '.handshake.request_resume_hash // ""' <<<"$st")" != "$h" ]] ||
      die "not clear-ready" "the RESUME block is unchanged since the lead's request: rewrite it with your current state, commit and push"
  fi
  goal="$(jq -r '.goal // ""' <<<"$st")"
  [[ -n "$goal" ]] || goal="$(section_text "$block" Goal)"
  mutex_take 5 || die "registry locked" "retry in a moment"
  state_update "$lane" '.handshake = {state: "ready", ready_at: $now, requested_at: .handshake.requested_at,
      session_id: $sid, worktree: $wt, head: $head, resume_hash: $h, prompts: (.prompts // 0), goal: $goal, attempts: 0}' \
    --argjson now "$(now)" --arg sid "$(jq -r .session_id <<<"$e")" --arg wt "$wt" --arg head "$(git -C "$wt" rev-parse HEAD)" \
    --arg h "$h" --arg goal "$goal"
  reg_update "$lane" '.clear_ready = true'
  mutex_drop
  echo "clear-ready: $lane at $(git -C "$wt" rev-parse --short HEAD). Tell the lead \"clear-ready\", then stop and wait."
}

# ---- screen (a second, vetoing check; idle itself comes from the hook flag) ---------------------------------------

# screen_read <pane>: sets COMPOSER (typed text, empty for the placeholder), COMPOSER_FOUND, VETO and GOAL_ACTIVE.
# Transcript text can quote anything, so only three zones count: the spinner and queue lines just above the box's top
# rule, the box itself (dialogs), and the footer below the input line (the goal indicator). Every pattern is a
# byte-exact literal or tolerates a multibyte glyph read as several bytes, so LC_ALL=C still works.
screen_read() {
  local pane="$1" raw plain i top line idx=-1 body
  COMPOSER="" COMPOSER_FOUND=0 VETO="" GOAL_ACTIVE=0
  raw="$(tm capture-pane -p -e -t "$pane" 2>/dev/null)" || { VETO="cannot read pane $pane"; return; }
  # shellcheck disable=SC2001 # a regex over many lines; parameter expansion has no portable regex form
  plain="$(sed $'s/\x1b\\[[0-9;]*m//g' <<<"$raw")"
  local -a lines rawlines
  mapfile -t lines <<<"$plain"
  mapfile -t rawlines <<<"$raw"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    if [[ "${lines[i]}" == "$PROMPT_MARK"* ]]; then idx=$i; break; fi
  done
  if ((idx < 0)); then
    VETO="no input prompt on screen (a dialog or another program may be showing)"
    return
  fi
  COMPOSER_FOUND=1
  body="${rawlines[idx]#*"$PROMPT_MARK"}"
  if [[ "$body" == $'\e[2m'* ]]; then COMPOSER=""; else COMPOSER="$(sed $'s/\x1b\\[[0-9;]*m//g; s/[[:space:]]*$//' <<<"$body")"; fi
  top=$idx
  for ((i = idx - 1; i >= 0 && i >= idx - 3; i--)); do
    if [[ "${lines[i]}" == "─"* ]]; then top=$i; break; fi
  done
  for ((i = (top >= 3 ? top - 3 : 0); i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    case "$line" in
      *"queued messages"* | *"Press up to edit queued"*) VETO="queued messages on screen"; return ;;
      *[Rr]"unning stop hook"* | *"running Stop hook"*) VETO="a Stop hook is running"; return ;;
    esac
    if ((i < top)); then
      [[ "$line" =~ ^[^[:alnum:][:space:]]+\ [[:alpha:]-]+… ]] && { VETO="a working spinner is on screen"; return; }
      continue
    fi
    case "$line" in *"Enter to confirm"* | *"Esc to cancel"* | *"Do you want to"*) VETO="a dialog is open"; return ;; esac
    ((i > idx)) && [[ "$line" == *"/goal active"* ]] && GOAL_ACTIVE=1
  done
  return 0
}

# screen_clear_to_send <pane> <allow goal 0|1>: refuse on a screen veto, on an active goal unless allowed, and on text
# in the input line, which may be a human's draft.
screen_clear_to_send() {
  screen_read "$1"
  [[ -z "$VETO" ]] || die "$REFUSAL: $VETO" "wait for the lane's turn to end, then run the command again"
  ((GOAL_ACTIVE == 0 || ${2:-0} == 1)) || die "$REFUSAL: a /goal is still active in $1" "look at the pane; nothing was typed"
  [[ -z "$COMPOSER" ]] || die "$REFUSAL: the input line of $1 holds text ('${COMPOSER:0:40}')" "a human may be typing; it is never overwritten"
}

# ---- typed sends -------------------------------------------------------------------------------------------------

# send_text <pane> <text>: one line typed with send-keys -l in chunks of SEND_CHUNK characters (split by jq, so a
# multibyte character is never cut under any locale), never a paste: Claude Code turns a burst of about 800
# characters into "[Pasted text]", which does not dispatch a slash command (measured on 2.1.308).
send_text() {
  local pane="$1" chunk
  [[ "$2" != *[[:cntrl:]]* ]] || die "refusing to type text with a newline or control character" "the goal must be one line"
  while IFS= read -r chunk; do
    tm send-keys -t "$pane" -l -- "$chunk"
    sleep "$SEND_GAP"
  done < <(printf '%s' "$2" | jq -Rrs --argjson n "$SEND_CHUNK" 'explode as $c | range(0; $c | length; $n) | $c[.:. + $n] | implode')
}

# erase_typed <pane> <text>: delete text this command typed and did not submit, in small key bursts.
erase_typed() {
  local n i keys=()
  n="$(char_count "$2")"
  for ((i = 0; i < n; i++)); do
    keys+=(BSpace)
    if ((${#keys[@]} == 64 || i == n - 1)); then tm send-keys -t "$1" "${keys[@]}"; keys=(); sleep "$SEND_GAP"; fi
  done
}

# activity_sig <lane>: what must not move between the last check and Enter.
activity_sig() { state_read "$1" | jq -c '[.session_id, (.prompts // 0), (.stops // 0), (.busy // false), (.background // 0)]'; }

# activity_moved <lane> <signature>: why the lane is no longer where the signature found it, or nothing.
activity_moved() {
  jq -rn --argjson a "$2" --argjson b "$(activity_sig "$1")" --arg act "$(activity_of "$(state_read "$1")")" '
    if $a[0] != $b[0] then "the session changed"
    elif $a[1] != $b[1] then "the lane received a new prompt"
    elif $a[2] != $b[2] then "a turn ended (a /goal may have started another)"
    elif $act == "busy" or $act == "background" then "the lane is \($act)"
    else empty end'
}

# submit <lane> <pane> <text> <signature> <confirm cmd...>: type the line and prove it arrived; just before Enter,
# re-read the hook flag, the counters and the screen, and on any move delete the typed text and return 2 with MOVED
# set. After Enter the effect confirms it; a lost Enter (text still in the input line) gets one more press, then 1.
submit() {
  local lane="$1" pane="$2" text="$3" sig="$4"
  shift 4
  MOVED=""
  screen_read "$pane"
  ((COMPOSER_FOUND)) && [[ -z "$COMPOSER" ]] ||
    die "$REFUSAL: the input line of $pane is not empty just before typing ('${COMPOSER:0:40}')" "nothing was typed; a human may be typing, and a draft is never touched"
  send_text "$pane" "$text"
  sleep 0.3
  screen_read "$pane"
  if [[ "$COMPOSER" != "${text:0:20}"* ]]; then
    # Text that arrived ahead of ours is someone's draft: delete only the characters we typed, which end the line.
    if [[ "$COMPOSER" == *"$text" ]]; then
      erase_typed "$pane" "$text"
      die "$REFUSAL: text arrived in the input line of $pane ahead of ours" "our typed text was deleted and the rest left as it is; nothing was submitted"
    fi
    die "typed text did not arrive intact (input line shows '${COMPOSER:0:60}')" "look at pane $pane; nothing was submitted and the input line was left as it is"
  fi
  MOVED="$(activity_moved "$lane" "$sig")"
  [[ -n "$MOVED" ]] || MOVED="$VETO"
  if [[ -n "$MOVED" ]]; then
    erase_typed "$pane" "$text"
    return 2
  fi
  tm send-keys -t "$pane" Enter
  "$@" && return 0
  screen_read "$pane"
  if [[ "$COMPOSER" == "${text:0:20}"* ]]; then
    echo "lanes: Enter was not taken for '${text:0:20}'; pressing it once more" >&2
    tm send-keys -t "$pane" Enter
    "$@" && return 0
  fi
  return 1
}

# ---- waits -------------------------------------------------------------------------------------------------------

# wait_idle <lane> <seconds>: the hook flag says idle (busy-expired counts, since Stop does not fire on an interrupt)
# and no background task is running.
wait_idle() {
  local lane="$1" deadline n
  deadline=$(($(now) + $2))
  while :; do
    n="$(now)"
    case "$(activity_of "$(state_read "$lane")")" in
      busy) ((n < deadline)) || die "$REFUSAL: lane $lane stayed busy for $2 s" "wait for its turn to end; if it never does, look at the pane" ;;
      background) ((n < deadline)) || die "$REFUSAL: lane $lane has background tasks running" "ask the lane to stop them; a background shell outlives /clear" ;;
      *) return 0 ;;
    esac
    sleep 0.5
  done
}

# settle <lane> <pane> <seconds> <allow goal 0|1>: idle by the hook flag, a screen with no veto, the same activity
# after LANES_IDLE_GAP, then the final screen check. Leaves GOAL_ACTIVE from that check.
settle() {
  local lane="$1" pane="$2" before after
  wait_idle "$lane" "$3"
  screen_clear_to_send "$pane" "$4"
  before="$(activity_sig "$lane")"
  sleep "$IDLE_GAP"
  after="$(activity_sig "$lane")"
  [[ "$before" == "$after" ]] || die "$REFUSAL: lane $lane became busy during the idle re-check" "run the command again when it is idle"
  screen_clear_to_send "$pane" "$4"
}

wait_new_session() { # wait_new_session <lane> <old session id>
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    [[ "$(reg_read "$1" | jq -r .session_id 2>/dev/null)" != "$2" ]] && return 0
    sleep 0.2
  done
  return 1
}

# wait_goal_seen <lane> <session id> <goal> <prompts before>: that session's UserPromptSubmit recorded this goal.
wait_goal_seen() {
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    state_read "$1" | jq -e --arg s "$2" --arg g "$3" --argjson p "$4" '.session_id == $s and .goal == $g and (.prompts // 0) > $p' >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

wait_goal_footer_gone() { # wait_goal_footer_gone <pane>: the input line is back, empty, with no /goal footer
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    screen_read "$1"
    ((COMPOSER_FOUND && !GOAL_ACTIVE)) && [[ -z "$COMPOSER" ]] && return 0
    sleep 0.2
  done
  return 1
}

wait_composer_empty() { # the new session has drawn an empty input line
  local i
  for ((i = 0; i < CLEAR_TIMEOUT * 5; i++)); do
    screen_read "$1"
    ((COMPOSER_FOUND)) && [[ -z "$COMPOSER" && -z "$VETO" ]] && return 0
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

# pane_owner_problem <lane> <pane> <session id>: why the pane no longer belongs to that session of the lane. A pane id
# alone is not proof: after a tmux restart another claude can hold %0, so the tmux server pid and the pane's own pid
# recorded at register must still match.
pane_owner_problem() {
  local e other
  e="$(reg_read "$1")" || { echo "the registry entry for $1 is unreadable"; return; }
  [[ "$(jq -r .session_id <<<"$e")" == "$3" ]] || { echo "the session of lane $1 changed"; return; }
  [[ "$(jq -r '.tmux_pane // ""' <<<"$e")" == "$2" ]] || { echo "lane $1 no longer holds pane $2"; return; }
  [[ "$(pane_identity "$2")" == "$(jq -r '"\(.tmux_pid) \(.pane_pid)"' <<<"$e")" ]] ||
    { echo "pane $2 now runs another process than the one lane $1 registered from (tmux restarted, or the pane id was reused)"; return; }
  while IFS= read -r other; do
    [[ "$other" != "$1" && "$(reg_read "$other" | jq -r '.tmux_pane // ""' 2>/dev/null)" == "$2" ]] &&
      { echo "pane $2 is also registered to lane $other"; return; }
  done < <(each_lane)
  return 0
}

# target_checks <lane> <entry>: the registered pane exists, runs Claude, is not this pane or in copy mode, and belongs
# to this lane's session alone. Sets PANE_T.
target_checks() {
  local lane="$1" e="$2" why
  PANE_T="$(jq -r '.tmux_pane // ""' <<<"$e")"
  [[ -n "$PANE_T" ]] || die "lane $lane has no tmux pane registered" "start it inside tmux as 'claude --name $lane'"
  [[ "$PANE_T" != "${TMUX_PANE:-}" ]] || die "lane $lane is this pane" "a session never clears itself or types into its own pane; the human clears the lead"
  pane_exists "$PANE_T" || die "pane $PANE_T of lane $lane does not exist" "the lane is gone; restart it as 'claude --name $lane'"
  [[ "$(pane_command "$PANE_T")" == "$CLAUDE_COMMAND" ]] || die "pane $PANE_T is running '$(pane_command "$PANE_T")', not $CLAUDE_COMMAND" "never type into another program; check the pane"
  [[ "$(tm display -p -t "$PANE_T" '#{pane_in_mode}')" == 0 ]] || die "pane $PANE_T is in copy mode" "leave copy mode (q) first; keys would go to tmux"
  why="$(pane_owner_problem "$lane" "$PANE_T" "$(jq -r .session_id <<<"$e")")"
  [[ -z "$why" ]] || die "$REFUSAL: $why" "check 'lanes status'; a pane belongs to the lane that registered last in it"
}

# changed_since_ready <lane> <entry> <state>: what changed since clear-ready (session, head, tree, RESUME, prompts).
changed_since_ready() {
  local e="$2" st="$3" wt block prob
  wt="$(jq -r '.handshake.worktree // ""' <<<"$st")"
  [[ "$(jq -r .session_id <<<"$e")" == "$(jq -r .handshake.session_id <<<"$st")" ]] || { echo "the session changed"; return; }
  [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" == "$(jq -r .handshake.head <<<"$st")" ]] || { echo "HEAD moved"; return; }
  prob="$(git_problem "$wt")"
  [[ -z "$prob" ]] || { echo "the tree stopped being clean and pushed ($prob)"; return; }
  block="$(resume_block "$(resume_path "$1" "$wt")" || true)"
  [[ "$(hash_of "$block")" == "$(jq -r .handshake.resume_hash <<<"$st")" ]] || { echo "the RESUME block changed"; return; }
  [[ "$(jq -r '.prompts // 0' <<<"$st")" == "$(jq -r '.handshake.prompts // 0' <<<"$st")" ]] || echo "the lane received a new prompt"
}

# final_verify <lane> <pane>: after every wait and the final screen check, prove again everything clear-ready proved,
# that the pane is still this session's, and that the hook flag is idle; only then may Escape be sent.
final_verify() {
  local lane="$1" pane="$2" e st why act
  e="$(reg_read "$lane")" || refuse_clear "$lane" "the registry entry became unreadable" "check 'lanes status'"
  st="$(state_read "$lane")"
  why="$(changed_since_ready "$lane" "$e" "$st")"
  [[ -z "$why" ]] || refuse_clear "$lane" "$why since clear-ready" "ask the lane to finish, push and report clear-ready again"
  why="$(pane_owner_problem "$lane" "$pane" "$(jq -r .handshake.session_id <<<"$st")")"
  [[ -z "$why" ]] || refuse_clear "$lane" "$why" "check 'lanes status'; a pane belongs to the lane that registered last in it"
  act="$(activity_of "$st")"
  case "$act" in busy | background) die "not cleared: lane $lane is $act at the moment of sending" "run lanes clear again when it is idle" ;; esac
}

# clear_goal <lane> <pane>: an active /goal re-prompts the lane after each turn and the model cannot clear it, while
# /clear removes it anyway (code.claude.com/docs/en/goal). So lanes types /goal clear at the proven idle point and
# takes the footer going away as the confirmation, before the final checks.
clear_goal() {
  local rc=0
  submit "$1" "$2" "/goal clear" "$(activity_sig "$1")" wait_goal_footer_gone "$2" || rc=$?
  ((rc != 2)) || die "not cleared: $MOVED before /goal clear was sent" "the typed text was deleted; run lanes clear again when the lane is idle"
  ((rc == 0)) || die "not cleared: /goal clear was typed into $2 but the /goal footer stayed" "look at the pane; /clear was not sent"
  GOAL_CLEARED=1
}

# send_goal <lane> <pane> <session id> <goal>: type /goal <goal> into the idle input line; the session's
# UserPromptSubmit recording that goal confirms it. Returns submit's code (2 with MOVED set when the lane moved).
send_goal() {
  local base
  base="$(state_read "$1" | jq -r '.prompts // 0')"
  submit "$1" "$2" "/goal $4" "$(activity_sig "$1")" wait_goal_seen "$1" "$3" "$4" "$base"
}

cmd_clear() {
  local lane="${1:-}" wait_s=60 e st hs pane sid goal new_sid sig rc=0 age why
  valid_lane "$lane" || usage
  shift
  [[ "${1:-}" == "--wait" ]] && wait_s="${2:-60}"
  [[ "$wait_s" =~ ^[0-9]+$ ]] || die "--wait '$wait_s' is not a number of seconds" "pass a whole number" 2
  int_in_range "$SEND_CHUNK" 1 512 ||
    die "LANES_SEND_CHUNK=$SEND_CHUNK is outside 1-512" "larger key bursts become a paste that does not dispatch /goal; unset it" 2
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

  if [[ "$hs" == ready ]]; then
    why="$(changed_since_ready "$lane" "$e" "$st")"
    [[ -z "$why" ]] || refuse_clear "$lane" "$why since clear-ready" "ask the lane to finish, push and report clear-ready again"
    settle "$lane" "$pane" "$wait_s" 1
    if ((GOAL_ACTIVE)); then
      clear_goal "$lane" "$pane"
      settle "$lane" "$pane" "$wait_s" 0
    fi
    final_verify "$lane" "$pane"
    sig="$(activity_sig "$lane")"
    hs_set "$lane" '.state = "sending" | .attempts = ((.attempts // 0) + 1) | .sent_at = $now' --argjson now "$(now)"
    tm send-keys -t "$pane" Escape
    sleep 0.3
    submit "$lane" "$pane" "/clear" "$sig" wait_new_session "$lane" "$sid" || rc=$?
    ((rc != 2)) || refuse_clear "$lane" "$MOVED before /clear was sent" "the typed /clear was deleted; ask the lane to report clear-ready again"
    if ((rc != 0)); then
      hs_set "$lane" '.state = "failed" | .failed = "clear not confirmed"'
      die "/clear was sent to $pane but no new session registered" "look at the pane; the clear is not confirmed and was not retried further"
    fi
    # shellcheck disable=SC2034 # die in bin/lanes reads it; /clear landed, so what remains is the goal
    GOAL_CLEARED=0
  fi

  e="$(reg_read "$lane")" || die "registry entry for '$lane' unreadable after /clear" "check 'lanes status'"
  new_sid="$(jq -r .session_id <<<"$e")"
  [[ "$hs" != ready ]] || hs_set "$lane" '.state = "cleared" | .cleared_at = $now | .cleared_session = $sid' --argjson now "$(now)" --arg sid "$new_sid"
  goal="$(state_read "$lane" | jq -r '.handshake.goal // ""')"
  if [[ -n "$goal" ]]; then
    wait_composer_empty "$pane" || die "the cleared session in $pane shows no empty input line" "look at the pane; the goal was not sent"
    settle "$lane" "$pane" "$wait_s" 1
    rc=0
    send_goal "$lane" "$pane" "$new_sid" "$goal" || rc=$?
    ((rc != 2)) || die "goal not sent: $MOVED before Enter" "the typed goal was deleted; run 'lanes clear $lane' again to send it"
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
# code.claude.com/docs/en/goal) through the same checks as lanes clear. The hook records it as the lane's goal.
cmd_goal() {
  local lane="${1:-}" goal="${2:-}" wait_s=60 caller e prob rc=0
  if ! valid_lane "$lane" || (($# < 2)); then usage; fi
  shift 2
  [[ "${1:-}" == "--wait" ]] && wait_s="${2:-60}"
  [[ "$wait_s" =~ ^[0-9]+$ ]] || die "--wait '$wait_s' is not a number of seconds" "pass a whole number" 2
  prob="$(goal_problem "$goal")"
  [[ -z "$prob" ]] || die "goal not sent: the goal $prob" "pass it as one line of at most $GOAL_CAP characters" 2
  int_in_range "$SEND_CHUNK" 1 512 ||
    die "LANES_SEND_CHUNK=$SEND_CHUNK is outside 1-512" "larger key bursts become a paste that does not dispatch /goal; unset it" 2
  caller="$(caller_lane)"
  [[ -n "$caller" && "$(reg_read "$caller" | jq -r .role 2>/dev/null)" == lead ]] ||
    die "only the lead sets a lane's goal" "run it from the lead's pane (a session started with LANES_ROLE=lead)"
  REFUSAL="goal not sent"
  clear_lock "$lane"
  e="$(reg_read "$lane")" || die "no valid registry entry for '$lane'" "check 'lanes status'"
  target_checks "$lane" "$e"
  settle "$lane" "$PANE_T" "$wait_s" 1
  send_goal "$lane" "$PANE_T" "$(jq -r .session_id <<<"$e")" "$goal" || rc=$?
  ((rc != 2)) || die "goal not sent: $MOVED before Enter" "the typed goal was deleted; run lanes goal again when the lane is idle"
  ((rc == 0)) || die "/goal was typed into $PANE_T but the session never received it" "look at the pane"
  echo "goal set: $lane (pane $PANE_T)"
}
