#!/usr/bin/env bats
# Live probe of the Claude Code facts lanes builds on: the sessions file at <CLAUDE_PID>.json and its statuses,
# procStart, Esc, /clear and a background shell, a /goal loop, a SIGKILL, and real `lanes clear` and `lanes goal`
# runs, a `--continue` registration and a Ctrl-Z. Opt-in: LANES_LIVE=1 and a logged-in `claude` on PATH. It runs real
# sessions (`--model haiku`) on a private tmux server, in a fresh work tree it creates and trusts, with the lanes plugin
# loaded from this checkout and a temp lanes data dir; it spends a few cents.
# Your own plugins, hooks and settings still load into these sessions. They write the real Claude Code config dir:
# the transcripts folder of the fresh work tree (removed at the end), and the history, trust and per-session entries
# Claude Code keeps outside it (left in place). Run it on each Claude Code version bump:
#   LANES_LIVE=1 BATS_TEST_TIMEOUT=300 .tools/bats-core/bin/bats tests/lanes/live

load ../../helpers/common

PLUGIN="$(cd "$BATS_TEST_DIRNAME/../../../plugins/lanes" && pwd)"
LANES="$PLUGIN/bin/lanes"
GOAL1="you have replied with the single word done; reply only done, never use tools"
GOAL2="you have replied with the single word again; reply only again, never use tools"

setup_file() {
  [[ "${LANES_LIVE:-}" == 1 ]] || skip "live probe: set LANES_LIVE=1 to run it against the installed claude"
  command -v claude >/dev/null || skip "no claude on PATH"
  # The suite trusts its work tree and deletes that tree's transcripts, so it only ever uses a folder it made itself.
  [[ -z "${LANES_LIVE_DIR:-}" ]] ||
    { echo "LANES_LIVE_DIR is refused: the suite runs only in a fresh folder it creates, trusts and cleans up" >&2; return 1; }
  # The SIGKILL probe ends the session, so the tests run one at a time and in file order.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  export LIVE_SOCK="lanes-live-$$"
  # LANES_LIVE_OUT keeps the hook log and the report; by default they go with the run.
  export LIVE_OUT="${LANES_LIVE_OUT:-$BATS_FILE_TMPDIR}"
  mkdir -p "$LIVE_OUT"
  : >"$LIVE_OUT/report.txt"
  LIVE_ROOT="$(mktemp -d "$BATS_FILE_TMPDIR/live.XXXXXX")"
  export LIVE_ROOT LIVE_DIR="$LIVE_ROOT/work"
  export LIVE_PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  export LIVE_SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  # The lanes registry and state of these sessions, never the contributor's own.
  export LANES_DATA_DIR="$LIVE_ROOT/data" LANES_TMUX_SOCKET="$LIVE_SOCK"
  mkdir -p "$LANES_DATA_DIR"
  live_repo
  cat >"$LIVE_OUT/hook.sh" <<'EOF'
#!/usr/bin/env bash
# One line per hook: the event, the session's name, CLAUDE_PID, CLAUDE_CODE_SESSION_ID, the hook's ancestor pids and
# the input's source.
in="$(cat)"
chain="" p=$$
for _ in 1 2 3 4 5 6 7 8; do p="$(ps -o ppid= -p "$p" | tr -d ' ')"; [[ -z "$p" || "$p" == 1 ]] && break; chain+="$p "; done
jq -nc --argjson in "$in" --arg pid "${CLAUDE_PID:-}" --arg sid "${CLAUDE_CODE_SESSION_ID:-}" --arg chain "$chain" \
  '{ev: $in.hook_event_name, name: ($in.session_title // null), pid: $pid, sid: $sid, chain: $chain,
    src: ($in.source // $in.reason // null), prompt: ($in.prompt // null), tp: ($in.transcript_path // null),
    sid_in: $in.session_id}' >>"$(dirname "$0")/hooks.log"
EOF
  chmod +x "$LIVE_OUT/hook.sh"
  : >"$LIVE_OUT/hooks.log"
  jq -nc --arg h "$LIVE_OUT/hook.sh" '{hooks: (["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"]
    | map({key: ., value: [{hooks: [{type: "command", command: $h}]}]}) | from_entries)}' >"$LIVE_OUT/settings.json"
  # The environment every session gets: the temp lanes data dir and this tmux server, and never the caller's role.
  export LIVE_ENV
  LIVE_ENV="env -u LANES_ROLE LANES_DATA_DIR=$(printf %q "$LANES_DATA_DIR") LANES_TMUX_SOCKET=$(printf %q "$LIVE_SOCK")"
  export LIVE_CLAUDE
  LIVE_CLAUDE="claude --model haiku --permission-mode default --plugin-dir $(printf %q "$PLUGIN") --settings $(printf %q "$LIVE_OUT/settings.json")"
  tmux -L "$LIVE_SOCK" new-session -d -s live -x 160 -y 45 -c "$LIVE_DIR" "$LIVE_ENV $LIVE_CLAUDE --name lanes-live"
  export MAIN
  MAIN="$(tmux -L "$LIVE_SOCK" display -p -t live '#{pane_id}')"
  # Ready means SessionStart ran and the input line is drawn. The trust prompt is answered only for the fresh folder
  # made above, and its cursor starts on "No, exit" (2.1.309), so "Yes" is selected before Enter.
  local i s
  for ((i = 0; i < 150; i++)); do
    s="$(tmux -L "$LIVE_SOCK" capture-pane -p -t "$MAIN" 2>/dev/null)"
    if grep -q 'Yes, I trust this folder' <<<"$s" && grep -qxF " $LIVE_DIR" <<<"$s"; then
      if grep -q '❯ Yes, I trust this folder' <<<"$s"; then
        tmux -L "$LIVE_SOCK" send-keys -t "$MAIN" Enter
      else
        tmux -L "$LIVE_SOCK" send-keys -t "$MAIN" Down
      fi
    fi
    started lanes-live >/dev/null && grep -q $'^❯\xc2\xa0' <<<"$s" && break
    sleep 0.2
  done
  export LIVE_PID
  LIVE_PID="$(started lanes-live || true)"
  [[ "$LIVE_PID" =~ ^[0-9]+$ ]] || { echo "no SessionStart with CLAUDE_PID within 30 s; the screen: $s" >&2; return 1; }
}

teardown_file() {
  [[ -n "${LIVE_SOCK:-}" ]] && tmux -L "$LIVE_SOCK" kill-server 2>/dev/null
  # A session this suite SIGKILLed leaves its file behind; remove that one file, never another.
  [[ -n "${LIVE_PID:-}" ]] && ! kill -0 "$LIVE_PID" 2>/dev/null && rm -f "$LIVE_SESSIONS/$LIVE_PID.json"
  # The transcripts folder Claude Code made for the fresh work tree, by its exact name, and only when the hooks
  # reported transcripts in that very folder.
  if [[ -n "${LIVE_DIR:-}" && -s "${LIVE_OUT:-}/hooks.log" ]]; then
    local want d
    want="$LIVE_PROJECTS/${LIVE_DIR//[^A-Za-z0-9]/-}"
    while IFS= read -r d; do
      if [[ "$d" == "$want" && -d "$d" ]]; then
        rm -rf -- "$d"
      else
        echo "# left in place: transcripts in $d, not the folder $want this suite made" >&3
      fi
    done < <(jq -r 'select(.tp != null) | .tp' "$LIVE_OUT/hooks.log" | sed 's|/[^/]*$||' | sort -u)
  fi
  return 0
}

# live_repo: LIVE_DIR as a lane's work tree: a branch that tracks a bare remote, and the lane's RESUME, all pushed.
live_repo() {
  local g=(git -c user.name=lanes-live -c user.email=lanes-live@example.invalid -c commit.gpgsign=false)
  git init -q --bare "$LIVE_ROOT/remote.git"
  git init -q -b main "$LIVE_DIR"
  mkdir -p "$LIVE_DIR/.lanes"
  cat >"$LIVE_DIR/.lanes/next-lanes-live.md" <<EOF
# next-lanes-live

<!-- lanes:resume:start -->
## RESUME

### Goal
$GOAL1

### Now
Branch main, the live probe.

### Next step
Reply done.

### Links
None.

### Running
Nothing.

### Suggested skills
none
<!-- lanes:resume:end -->
EOF
  "${g[@]}" -C "$LIVE_DIR" add .lanes
  "${g[@]}" -C "$LIVE_DIR" commit -q -m "resume lanes-live"
  "${g[@]}" -C "$LIVE_DIR" remote add origin "$LIVE_ROOT/remote.git"
  "${g[@]}" -C "$LIVE_DIR" push -q -u origin main
}

# started <name>: the CLAUDE_PID of the first SessionStart of the session named <name>.
started() {
  local p
  p="$(jq -r --arg n "$1" 'select(.ev == "SessionStart" and .name == $n) | .pid' "$LIVE_OUT/hooks.log" | head -n 1)"
  [[ -n "$p" ]] && echo "$p"
}
f() { printf '%s/%s.json' "$LIVE_SESSIONS" "${1:-$LIVE_PID}"; }
st() { jq -r '[.status, (.waitingFor // "-")] | join(" ")' "$(f "$@")"; }
screen() { tmux -L "$LIVE_SOCK" capture-pane -p -t "${1:-$MAIN}"; }
key() { tmux -L "$LIVE_SOCK" send-keys -t "$MAIN" "$1"; }
hooks() { jq -r '.ev' "$LIVE_OUT/hooks.log" | wc -l | tr -d ' '; }
count() { jq -r --arg e "$1" 'select(.ev == $e) | .ev' "$LIVE_OUT/hooks.log" | wc -l | tr -d ' '; }
# note <text>: a recorded fact, shown in the bats output and kept in report.txt.
note() { echo "# $*" >&3; echo "$*" >>"$LIVE_OUT/report.txt"; }

# type_line <text> [pane]: type it, wait until its start shows in the input line, press Enter, and wait until it left.
type_line() {
  local head="${1:0:24}" p="${2:-$MAIN}" i
  tmux -L "$LIVE_SOCK" send-keys -t "$p" -l -- "$1"
  for ((i = 0; i < 25; i++)); do screen "$p" | grep -qF -- "❯"$'\xc2\xa0'"$head" && break; sleep 0.2; done
  tmux -L "$LIVE_SOCK" send-keys -t "$p" Enter
  for ((i = 0; i < 25; i++)); do screen "$p" | grep -qF -- "❯"$'\xc2\xa0'"$head" || return 0; sleep 0.2; done
  echo "the typed line '$head...' never left the input line" >&2
  return 1
}

# approve <command>: on a Bash permission prompt whose command box holds exactly <command>, press Enter (option 1,
# Yes). Any other prompt is cancelled with Esc and fails, so the suite never approves a command the model chose.
approve() {
  local box
  box="$(screen | awk '/^ *Bash command *$/ {on = 1; next} /Do you want to proceed\?/ {on = 0} on' | sed 's/^ *//; s/ *$//')"
  if grep -qxF -- "$1" <<<"$box" && screen | grep -qF -- "❯ 1. Yes"; then
    key Enter
    return 0
  fi
  key Escape
  echo "the permission prompt does not ask for exactly '$1'; cancelled. It shows: $box" >&2
  return 1
}

# descendants <pid>: every process under <pid>, from one ps snapshot (pid ppid args per line).
descendants() {
  ps -A -o pid= -o ppid= -o args= | awk -v root="$1" '
    {pid[NR] = $1; ppid[NR] = $2; $1 = $2 = ""; args[NR] = substr($0, 3)}
    END {
      want[root] = 1
      do { grew = 0; for (i = 1; i <= NR; i++) if (!(pid[i] in want) && (ppid[i] in want)) { want[pid[i]] = 1; grew = 1; print pid[i], args[i] } } while (grew)
    }'
}

# wait_st <regex> <seconds> [pid]: the file's "status waitingFor" matches.
wait_st() {
  local i
  for ((i = 0; i < $2 * 5; i++)); do [[ "$(st "${3:-}")" =~ $1 ]] && return 0; sleep 0.2; done
  echo "status stayed '$(st "${3:-}")', not /$1/, for $2 s" >&2
  return 1
}

# gone <pid> <seconds>: the process exited.
gone() {
  local i
  for ((i = 0; i < $2 * 5; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  return 1
}

# close_window <window> <pid>: close a probe's window; the session's own pid gets SIGTERM if it outlived SIGHUP.
close_window() {
  tmux -L "$LIVE_SOCK" kill-window -t "live:$1" 2>/dev/null
  [[ -n "$2" ]] || return 0
  gone "$2" 10 || { kill -TERM "$2" 2>/dev/null; gone "$2" 10; }
}

# keep_goal_lines: copy the goal_status lines of transcript $tp (only those) to the suite's output dir, for diagnosis,
# since teardown deletes the transcript.
keep_goal_lines() {
  { grep -F '"goal_status"' "$tp" || true; } >"$LIVE_OUT/goal-status.jsonl"
  echo "the transcript's goal_status lines are kept in $LIVE_OUT/goal-status.jsonl" >&2
}

# goal_agrees <when>: goal_state of transcript $tp matches the last goal_status verdict read here from the whole file
# (met true: none; met false: active), and the report records which verdict it was.
goal_agrees() {
  local met want
  met="$(jq -Rrn '[inputs | fromjson? | select(.type == "attachment" and .attachment.type == "goal_status")
    | .attachment.met] | last | tostring' "$tp")"
  case "$met" in
    true) want=none ;;
    false) want=active ;;
    *) keep_goal_lines; echo "no goal_status verdict in $tp $1 (last met: '$met')" >&2; return 1 ;;
  esac
  note "goal verdict $1: met=$met, so goal_state must be $want"
  run bash -c 'source "$1"; goal_state "$2"' _ "$LANES" "$tp"
  [[ "$output" == "$want" ]] || { keep_goal_lines; echo "goal_state $1 is '$output', the transcript's last verdict met=$met" >&2; return 1; }
}

# Each probe starts from an idle session, so one that fails does not leave the next a running turn.
setup() {
  kill -0 "$LIVE_PID" 2>/dev/null ||
    { echo "the live session is gone: the SIGKILL probe ends it and runs last, so run this file whole and in order" >&2; return 1; }
  wait_st '^idle' 30 || { key Escape; wait_st '^idle' 5; }
}

@test "the file at <CLAUDE_PID>.json has the pinned keys and starts idle, and CLAUDE_PID is an ancestor of the hook" {
  wait_st '^idle' 20
  run jq -r '[(.pid | type), (.procStart | type), (.sessionId | type), (.status | type), (.statusUpdatedAt | type), has("waitingFor")] | join(" ")' "$(f)"
  assert_output "number string string string number false"
  run jq -r .pid "$(f)"
  assert_output "$LIVE_PID"
  run jq -r 'select(.ev == "SessionStart" and .name == "lanes-live") | [.sid == .sid_in, (.chain | split(" ") | index($p) != null)] | @json' --arg p "$LIVE_PID" "$LIVE_OUT/hooks.log"
  assert_output '[true,true]'
  run bash -c 'source "$1"; session_read "$2" "$3" && echo "$SS_STATUS $SS_SID"' _ "$LANES" "$LIVE_PID" "${CLAUDE_CONFIG_DIR:-}"
  assert_output "idle $(jq -r .sessionId "$(f)")"
}

@test "procStart equals lanes' proc_start of the live process" {
  run bash -c 'source "$1"; proc_start "$2"' _ "$LANES" "$LIVE_PID"
  assert_output "$(jq -r .procStart "$(f)")"
}

@test "a prompt is busy within seconds; a Bash approval is waiting (permission prompt); Esc on a running tool is idle with no hook" {
  type_line "Use the Bash tool to run exactly this command and nothing else: sleep 45"
  wait_st '^(busy|waiting)' 10
  wait_st '^(waiting permission prompt|busy)' 30
  if [[ "$(st)" == waiting* ]]; then
    approve "sleep 45"
    wait_st '^busy' 10
  fi
  sleep 3
  n="$(hooks)"
  key Escape
  wait_st '^idle' 2
  sleep 3
  [ "$(hooks)" = "$n" ] || { echo "a hook fired after Esc: $(tail -n 1 "$LIVE_OUT/hooks.log")" >&2; false; }
}

@test "AskUserQuestion is waiting (input needed), /model is waiting (dialog open), and Esc on each is idle" {
  type_line "Use the AskUserQuestion tool once to ask me: red or blue? Do nothing else."
  wait_st '^waiting input needed' 45
  key Escape
  wait_st '^idle' 3
  type_line "/model"
  wait_st '^waiting dialog open' 10
  key Escape
  wait_st '^idle' 3
}

@test "a background shell is shell; /clear keeps pid and procStart, changes sessionId, fires no UserPromptSubmit, and the shell outlives it" {
  type_line "Use the Bash tool with run_in_background set to true to run exactly: sleep 299. Then reply ok and stop."
  wait_st '^(shell|waiting permission prompt)' 60
  if [[ "$(st)" == waiting* ]]; then
    approve "sleep 299"
    wait_st '^shell' 60
  fi
  # The shell is found under this session's own process, never by name across the machine.
  shell_pid="$(descendants "$LIVE_PID" | awk '$2 == "sleep" && $3 == "299" {print $1}' | head -n 1)"
  [[ "$shell_pid" =~ ^[0-9]+$ ]] || { echo "no 'sleep 299' under claude pid $LIVE_PID" >&2; false; }
  before="$(jq -c '{pid, procStart, sessionId}' "$(f)")"
  prompts="$(count UserPromptSubmit)"
  type_line "/clear"
  for _ in $(seq 1 50); do [ "$(jq -r .sessionId "$(f)")" != "$(jq -r .sessionId <<<"$before")" ] && break; sleep 0.2; done
  run jq -c --argjson b "$before" '[.pid == $b.pid, .procStart == $b.procStart, .sessionId != $b.sessionId, .status] ' "$(f)"
  assert_output '[true,true,true,"shell"]'
  sleep 1
  run bash -c "jq -r 'select(.ev == \"SessionEnd\" or .ev == \"SessionStart\") | .ev + \" \" + (.src // \"\")' '$LIVE_OUT/hooks.log' | tail -n 2"
  assert_output "SessionEnd clear
SessionStart clear"
  [ "$(count UserPromptSubmit)" = "$prompts" ]
  kill -0 "$shell_pid"
  kill "$shell_pid"
  wait_st '^busy' 20
  wait_st '^idle' 60
}

@test "a /goal loop is one busy span while Stop fires after each goal turn; Esc leaves the goal active; /clear removes it" {
  stops="$(count Stop)"
  type_line "/goal you have replied with the single word tick in at least four separate turns; reply only tick, never use tools"
  wait_st '^busy' 10
  idle_seen=0
  for _ in $(seq 1 300); do
    [[ "$(st)" == idle* ]] && { idle_seen=1; break; }
    sleep 0.2
  done
  turns=$(($(count Stop) - stops))
  [ "$idle_seen" = 1 ] || { echo "the goal loop never handed back within 60 s" >&2; false; }
  [ "$turns" -ge 3 ] || { echo "only $turns Stop hooks during the goal loop" >&2; false; }
  tp="$(jq -r 'select(.ev == "SessionStart" and .name == "lanes-live") | .tp' "$LIVE_OUT/hooks.log" | tail -n 1)"
  # The evaluator may judge the goal met or not when the loop hands back, so goal_state must agree with the verdict
  # the transcript itself shows last: met is none, unmet is active.
  goal_agrees "after the loop handed back"
  type_line "/goal you have replied tick in fifty separate turns; reply only tick, never use tools"
  wait_st '^busy' 10
  sleep 6
  key Escape
  wait_st '^idle' 3
  run bash -c 'source "$1"; goal_state "$2"' _ "$LANES" "$tp"
  [[ "$output" == active ]] || { keep_goal_lines; echo "goal_state after Esc is '$output', not active" >&2; false; }
  type_line "/clear"
  sleep 3
  type_line "/goal"
  sleep 2
  run bash -c "tmux -L '$LIVE_SOCK' capture-pane -p -t '$MAIN' | grep -c 'No goal set'"
  assert_output 1
}

@test "lanes clear and lanes goal against the real session: what lanes types lands, and every guard passes on the way" {
  wait_st '^idle' 20
  run jq -r '[.tmux_pane, (.claude_pid | tostring)] | join(" ")' "$LANES_DATA_DIR/lanes/lanes-live.json"
  assert_output "$MAIN $LIVE_PID"
  # A lead to send from: registered as the lead role on a pane id that is not the lane's.
  jq -nc --arg c "$LIVE_DIR" '{hook_event_name: "SessionStart", session_id: "00000000-0000-4000-8000-000000000099",
    session_title: "live-lead", cwd: $c, source: "startup"}' | LANES_ROLE=lead TMUX_PANE=%99 CLAUDE_PID=$$ "$LANES" register >/dev/null
  run bash -c 'cd "$1" && "$2" clear-ready --lane lanes-live' _ "$LIVE_DIR" "$LANES"
  assert_success
  old_sid="$(jq -r .sessionId "$(f)")"
  # A tmux first on PATH logs every call lanes makes, so the keys it sent can be read back.
  mkdir -p "$LIVE_ROOT/shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\nexec %q "$@"\n' "$LIVE_ROOT/tmux-calls" "$(command -v tmux)" >"$LIVE_ROOT/shim/tmux"
  chmod +x "$LIVE_ROOT/shim/tmux"
  : >"$LIVE_ROOT/tmux-calls"
  PATH="$LIVE_ROOT/shim:$PATH" run "$LANES" clear lanes-live --wait 60
  note "lanes clear: status $status: $output"
  assert_success
  assert_output --partial "cleared: lanes-live"
  # The clear types /clear as its first key and never sends Escape, the one key that interrupts a turn.
  run grep -m 1 -- ' send-keys ' "$LIVE_ROOT/tmux-calls"
  assert_output --partial " -l -- /clear"
  run grep -c -E -- ' send-keys .*(Escape|C-\[)' "$LIVE_ROOT/tmux-calls"
  assert_output 0
  new_sid="$(jq -r .sessionId "$(f)")"
  [ "$new_sid" != "$old_sid" ]
  run jq -r .session_id "$LANES_DATA_DIR/lanes/lanes-live.json"
  assert_output "$new_sid"
  run jq -r --arg s "$new_sid" 'select(.ev == "UserPromptSubmit" and .sid_in == $s) | .prompt' "$LIVE_OUT/hooks.log"
  assert_line "/goal $GOAL1"
  # The RESUME goal runs its loop and hands back; then the lead replaces the goal without a /clear.
  wait_st '^idle' 90
  run env TMUX_PANE=%99 "$LANES" goal lanes-live "$GOAL2" --wait 60
  note "lanes goal: status $status: $output"
  assert_success
  assert_output --partial "goal set: lanes-live"
  run jq -r --arg s "$new_sid" 'select(.ev == "UserPromptSubmit" and .sid_in == $s) | .prompt' "$LIVE_OUT/hooks.log"
  assert_line "/goal $GOAL2"
  wait_st '^idle' 90
}

@test "a session started with --continue --name registers under that name, with the hook input's session_id" {
  # Proves register takes the session from the hook input of a resumed session, and records how CLAUDE_CODE_SESSION_ID
  # compares with it on this version.
  tmux -L "$LIVE_SOCK" new-window -d -t live -n cont -c "$LIVE_DIR" "$LIVE_ENV $LIVE_CLAUDE --continue --name lanes-cont"
  for _ in $(seq 1 150); do started lanes-cont >/dev/null && break; sleep 0.2; done
  cpid="$(started lanes-cont)"
  [[ "$cpid" =~ ^[0-9]+$ ]] || { close_window cont ""; echo "no SessionStart from the --continue session within 30 s" >&2; false; }
  run jq -c 'select(.ev == "SessionStart" and .name == "lanes-cont") | {src, same_sid: (.sid == .sid_in)}' "$LIVE_OUT/hooks.log"
  note "--continue SessionStart: $output"
  sid_in="$(jq -r 'select(.ev == "SessionStart" and .name == "lanes-cont") | .sid_in' "$LIVE_OUT/hooks.log" | head -n 1)"
  for _ in $(seq 1 25); do [[ -f "$LANES_DATA_DIR/lanes/lanes-cont.json" ]] && break; sleep 0.2; done
  run jq -r .session_id "$LANES_DATA_DIR/lanes/lanes-cont.json"
  close_window cont "$cpid"
  assert_output "$sid_in"
}

@test "Ctrl-Z on a claude started from a shell in the pane: what the process, the terminal and the sessions file show" {
  tmux -L "$LIVE_SOCK" new-window -d -t live -n tstp -c "$LIVE_DIR" "$LIVE_ENV bash --noprofile --norc -i"
  tp_pane="$(tmux -L "$LIVE_SOCK" display -p -t live:tstp '#{pane_id}')"
  shell_pid="$(tmux -L "$LIVE_SOCK" display -p -t live:tstp '#{pane_pid}')"
  tmux -L "$LIVE_SOCK" send-keys -t "$tp_pane" -l -- "$LIVE_CLAUDE --name lanes-tstp"
  tmux -L "$LIVE_SOCK" send-keys -t "$tp_pane" Enter
  for _ in $(seq 1 150); do started lanes-tstp >/dev/null && screen "$tp_pane" | grep -q $'^❯\xc2\xa0' && break; sleep 0.2; done
  zpid="$(started lanes-tstp)"
  [[ "$zpid" =~ ^[0-9]+$ ]] || { close_window tstp ""; echo "no SessionStart from the shell-started session within 30 s" >&2; false; }
  note "shell-started claude: pane pid $shell_pid (the shell), claude pid $zpid, ps pgid,tpgid,stat: $(ps -o pgid= -o tpgid= -o stat= -p "$zpid"), file: $(st "$zpid")"
  tmux -L "$LIVE_SOCK" send-keys -t "$tp_pane" C-z
  stopped=0
  for _ in $(seq 1 25); do [[ "$(ps -o stat= -p "$zpid" | tr -d ' ')" == T* ]] && { stopped=1; break; }; sleep 0.2; done
  note "after Ctrl-Z: stopped=$stopped, ps pgid,tpgid,stat: $(ps -o pgid= -o tpgid= -o stat= -p "$zpid"), file: $(st "$zpid")"
  if ((!stopped)); then
    kill -TSTP "$zpid"
    for _ in $(seq 1 25); do [[ "$(ps -o stat= -p "$zpid" | tr -d ' ')" == T* ]] && { stopped=1; break; }; sleep 0.2; done
    note "after kill -TSTP: stopped=$stopped, ps pgid,tpgid,stat: $(ps -o pgid= -o tpgid= -o stat= -p "$zpid"), file: $(st "$zpid")"
  fi
  read -r pgid tpgid stat < <(ps -o pgid= -o tpgid= -o stat= -p "$zpid")
  tmux -L "$LIVE_SOCK" send-keys -t "$tp_pane" -l -- "fg"
  tmux -L "$LIVE_SOCK" send-keys -t "$tp_pane" Enter
  sleep 2
  note "after fg: ps pgid,tpgid,stat: $(ps -o pgid= -o tpgid= -o stat= -p "$zpid"), file: $(st "$zpid")"
  close_window tstp "$zpid"
  [[ "$stat" == T* ]]
  [ "$pgid" != "$tpgid" ]
}

@test "a SIGKILL leaves the file behind, and lanes reads it as stale: proc_start of the dead pid gives nothing (runs last)" {
  kill -9 "$LIVE_PID"
  sleep 1
  assert [ -f "$(f)" ]
  run bash -c 'source "$1"; proc_start "$2" || echo gone' _ "$LANES" "$LIVE_PID"
  assert_output gone
}
