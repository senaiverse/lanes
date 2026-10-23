#!/usr/bin/env bats
# Seams: session_read, proc_start, pid_within and goal_state, the readers of Claude Code's own state, fed files
# captured from Claude Code 2.1.309 (fixtures/2.1.309: a live sessions file per status, and a transcript with
# goal_status attachments). Values keep their serialised form: procStart a string, statusUpdatedAt in ms.

load helper

FIX="$BATS_TEST_DIRNAME/fixtures/2.1.309"

# read_as <fixture or path> [pid]: put the file at <pid>.json under CLAUDE_CONFIG_DIR, passed as the lane's recorded
# config dir, and print session_read's verdict.
read_as() {
  local src="$1" pid="${2:-4242}"
  [[ -f "$src" ]] || src="$FIX/session-$1.json"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
  cp "$src" "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  bash -c 'source "$1"; if session_read "$2" "$3"; then printf "%s|%s|%s|%s|%s|%s\n" "$SS_PID" "$SS_PROCSTART" "$SS_SID" "$SS_STATUS" "$SS_WAITING" "$SS_UPDATED"; else echo "REFUSED: $SS_PROBLEM"; fi' _ "$LANES" "$pid" "$CLAUDE_CONFIG_DIR"
}

# variant <fixture> <jq filter>: a copy of a fixture changed by the filter; prints its path.
variant() { jq -c "$2" "$FIX/session-$1.json" >"$LANES_TEST_TMP/v.json"; echo "$LANES_TEST_TMP/v.json"; }

@test "every 2.1.309 status reads with its waitingFor: idle, busy, shell, and waiting for input, a dialog or a permission" {
  run read_as idle
  assert_output "4242|123456|00000000-0000-4000-8000-000000000001|idle||1792721476190"
  run read_as busy
  assert_output --partial "|busy||"
  run read_as shell
  assert_output --partial "|shell||"
  run read_as shell-after-clear
  assert_output "4242|123456|00000000-0000-4000-8000-000000000002|shell||1792721699402"
  run read_as waiting-input
  assert_output --partial "|waiting|input needed|"
  run read_as waiting-dialog
  assert_output --partial "|waiting|dialog open|"
  run read_as waiting-permission
  assert_output --partial "|waiting|permission prompt|"
}

@test "a missing file is refused with its path" {
  run bash -c 'source "$1"; session_read 4242 "$2" || echo "REFUSED: $SS_PROBLEM"' _ "$LANES" "$CLAUDE_CONFIG_DIR"
  assert_output "REFUSED: no Claude Code session file $CLAUDE_CONFIG_DIR/sessions/4242.json (the process exited, or it is not Claude Code)"
}

@test "a file that is not JSON, or half written, is refused" {
  printf '{"pid":4242,"sessionId":' >"$LANES_TEST_TMP/half.json"
  run read_as "$LANES_TEST_TMP/half.json"
  assert_output --partial "REFUSED: the session file"
  assert_output --partial "is not valid JSON"
  printf '[1,2]' >"$LANES_TEST_TMP/arr.json"
  run read_as "$LANES_TEST_TMP/arr.json"
  assert_output --partial "unknown schema: not a JSON object"
}

@test "each key lanes needs, missing, is refused by name" {
  for k in pid procStart sessionId status statusUpdatedAt; do
    run read_as "$(variant idle "del(.$k)")"
    assert_output --partial "unknown schema: no \"$k\" key"
  done
}

@test "a key of another type is refused: procStart as a number, statusUpdatedAt as a string" {
  run read_as "$(variant idle '.procStart = 123456')"
  assert_output --partial '"procStart" is a number, not a string'
  run read_as "$(variant idle '.statusUpdatedAt = "1792721476190"')"
  assert_output --partial '"statusUpdatedAt" is a string, not a number'
}

@test "a status outside idle|busy|waiting|shell is refused, and waiting without a waitingFor too" {
  run read_as "$(variant idle '.status = "thinking"')"
  assert_output --partial 'unknown status "thinking"'
  run read_as "$(variant waiting-input 'del(.waitingFor)')"
  assert_output --partial "status waiting without a waitingFor string"
  run read_as "$(variant idle '.waitingFor = null')"
  assert_output --partial "|idle||"
}

@test "a lane registered with no config dir is read from ~/.claude, whatever the caller's CLAUDE_CONFIG_DIR is" {
  export HOME="$LANES_TEST_TMP/home"
  mkdir -p "$HOME/.claude/sessions"
  cp "$FIX/session-idle.json" "$HOME/.claude/sessions/4242.json"
  run bash -c 'source "$1"; session_read 4242 "" && echo "$SS_STATUS"' _ "$LANES"
  assert_output idle
}

@test "an empty file is refused as empty, not read as a session with no values" {
  : >"$LANES_TEST_TMP/empty.json"
  run read_as "$LANES_TEST_TMP/empty.json"
  assert_output "REFUSED: the session file $CLAUDE_CONFIG_DIR/sessions/4242.json is empty"
}

@test "a value with a control character, or a sessionId that is not a session id, is refused by name" {
  run read_as "$(variant idle '.sessionId = "00000000-0000-4000-8000-000000000001\nx"')"
  assert_output --partial 'unknown schema: "sessionId" holds a control character'
  run read_as "$(variant waiting-input '.waitingFor = "input\u001fneeded"')"
  assert_output --partial 'unknown schema: "waitingFor" holds a control character'
  for bad in "" "../x" "a b"; do
    run read_as "$(variant idle ".sessionId = \"$bad\"")"
    assert_output --partial "unknown schema: sessionId \"$bad\" is not a session id"
  done
}

# start_odd: a sleeping process whose command name holds spaces and ")", as /proc/<pid>/stat's second field allows.
# Sets ODD to its pid.
start_odd() {
  local exe="$LANES_TEST_TMP/x) y (z"
  cp "$(command -v sleep)" "$exe"
  "$exe" 30 &
  ODD=$!
}

@test "proc_start on Linux is field 22 of /proc/<pid>/stat, counted after the last ')' even when the name holds one" {
  [[ "$(uname -s)" == Linux ]] || skip "Linux only; the macOS form has its own test"
  start_odd
  want="$(sed 's/.*) //' "/proc/$ODD/stat" | cut -d' ' -f20)"
  run bash -c 'source "$1"; proc_start "$2"' _ "$LANES" "$ODD"
  kill "$ODD"
  assert_output "$want"
  [[ "$want" =~ ^[0-9]+$ ]]
}

@test "proc_start elsewhere is 'LC_ALL=C TZ=UTC ps -o lstart=' trimmed, and a gone process gives nothing" {
  start_odd
  want="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$ODD" | sed 's/^ *//; s/ *$//')"
  run bash -c 'source "$1"; OS_NAME=Darwin; proc_start "$2"' _ "$LANES" "$ODD"
  kill "$ODD"
  wait "$ODD" 2>/dev/null || true
  assert_output "$want"
  [[ "$want" =~ ^[A-Z][a-z]{2}\ [A-Z][a-z]{2}\ +[0-9]+\ [0-9:]{8}\ [0-9]{4}$ ]]
  run bash -c 'source "$1"; proc_start "$2" || echo gone' _ "$LANES" "$ODD"
  assert_output gone
  run bash -c 'source "$1"; OS_NAME=Darwin; proc_start "$2" || echo gone' _ "$LANES" "$ODD"
  assert_output gone
}

@test "proc_start of a zombie (exited, not yet reaped by its parent) gives nothing, in both forms" {
  zombie_child
  run bash -c 'source "$1"; proc_start "$2" || echo gone' _ "$LANES" "$ZPID"
  linux="$output"
  run bash -c 'source "$1"; OS_NAME=Darwin; proc_start "$2" || echo gone' _ "$LANES" "$ZPID"
  kill "$ZPARENT"
  wait "$ZPARENT" 2>/dev/null || true
  assert_equal "$linux" gone
  assert_output gone
}

# within <pid> <root> [<pid> <root>...]: pid_within over a fake process table ($LANES_TEST_TMP/ps.txt, "pid ppid"
# lines), with ps answering `ps -o ppid= -p <pid>` from it.
within() {
  bash -c 'source "$1"; T="$2"; shift 2
    ps() { awk -v p="${@: -1}" "\$1 == p {print \"  \" \$2}" "$T"; }
    while (($#)); do if pid_within "$1" "$2"; then echo "$1 within $2"; else echo "$1 outside $2"; fi; shift 2; done' \
    _ "$LANES" "$LANES_TEST_TMP/ps.txt" "$@"
}

@test "the npm install: the pane runs node, Claude Code is its child, and that is within the pane; a stranger is not" {
  # pane 100 (node cli-wrapper.cjs) -> 200 (claude); 300 is another session's claude under the tmux server 50.
  printf '100 50\n200 100\n300 50\n50 1\n' >"$LANES_TEST_TMP/ps.txt"
  run within 200 100 100 100 300 100 50 100 999 100
  assert_output "200 within 100
100 within 100
300 outside 100
50 outside 100
999 outside 100"
}

@test "a cycle in the process table ends the walk as outside, never a hang" {
  printf '200 201\n201 200\n' >"$LANES_TEST_TMP/ps.txt"
  run within 200 100
  assert_output "200 outside 100"
}

# goal_after <n>: goal_state over the first n lines of the captured transcript.
goal_after() {
  head -n "$1" "$FIX/goal-transcript.jsonl" >"$LANES_TEST_TMP/t.jsonl"
  bash -c 'source "$1"; goal_state "$2"' _ "$LANES" "$LANES_TEST_TMP/t.jsonl"
}

@test "goal state from the transcript: set, unmet verdicts, achieved, set again, cleared (a captured 2.1.309 transcript)" {
  run goal_after 15
  assert_output none
  run goal_after 16
  assert_output active
  run goal_after 30
  assert_output active
  run goal_after 37
  assert_output none
  run goal_after 38
  assert_output active
  run goal_after 45
  assert_output active
  run goal_after 46
  assert_output none
  run goal_after 50
  assert_output none
}

@test "the fixture's goal entries are what goal_state relies on: the sentinel, unmet verdicts, achieved and cleared" {
  run jq -c 'select(.type == "attachment" and .attachment.type == "goal_status") | [.attachment.met, (.attachment.sentinel // false)]' "$FIX/goal-transcript.jsonl"
  assert_line --index 0 '[false,true]'
  assert_line --index 1 '[false,false]'
  assert_line --index 8 '[true,false]'
  assert_line --index 9 '[false,true]'
  assert_line --index 12 '[true,true]'
}

@test "no transcript, or one with no goal entries, is unknown and none; a user line quoting goal_status is not an entry" {
  run bash -c 'source "$1"; goal_state ""; goal_state /nonexistent' _ "$LANES"
  assert_output "unknown
unknown"
  head -n 16 "$FIX/goal-transcript.jsonl" >"$LANES_TEST_TMP/t.jsonl"
  jq -nc '{type: "user", message: {content: "the \"goal_status\" entry, met:true"}}' >>"$LANES_TEST_TMP/t.jsonl"
  run bash -c 'source "$1"; goal_state "$2"' _ "$LANES" "$LANES_TEST_TMP/t.jsonl"
  assert_output active
}
