#!/usr/bin/env bats
# Public seam: `lanes clear <lane>` and `lanes status`. A pane hosts a lane's session only when every check of the one
# identity proof holds: the sessions file at the registered pid exists and names that pid, its procStart is the live
# process's start, its sessionId is the registry's, the pane is on the registered tmux server, and Claude Code's pid
# is the pane's process or a descendant of it. Keys reach that session only while it is also the terminal's
# foreground process group and not stopped. Each test breaks one check; nothing may be typed.

load helper
load lead

keys_typed() { grep -c -E '^(BURST|ESC)' "$FAKE_LOG" || true; }

refused_untouched() { # refused_untouched <message part>
  run as_lead clear alpha --wait 2
  assert_failure
  assert_output --partial "$1"
  run keys_typed
  assert_output 0
}

@test "the proof holds for a live fake: the clear lands (the baseline every test below breaks once)" {
  ready_lane alpha
  run as_lead clear alpha
  assert_success
}

@test "no sessions file at the registered pid: refused" {
  ready_lane alpha
  rm "$(session_file)"
  refused_untouched "no Claude Code session file $(session_file)"
}

@test "a sessions file that names another pid than its file name: refused" {
  ready_lane alpha
  edit_session '.pid = 1'
  refused_untouched "the session file of pid $FAKE_PID names pid 1"
}

@test "a procStart that is not the live process's start (a reused pid, or a file left by a SIGKILL): refused" {
  ready_lane alpha
  edit_session '.procStart = "1"'
  refused_untouched "the session file of pid $FAKE_PID is stale"
}

@test "a sessionId other than the registry's: refused" {
  ready_lane alpha
  edit_session '.sessionId = "someone-else"'
  refused_untouched "pid $FAKE_PID now runs session someone-else, not the registered"
}

@test "a pane on another tmux server than the one the lane registered from: refused" {
  ready_lane alpha
  f="$LANES_DATA_DIR/lanes/alpha.json"
  jq '.tmux_pid = 1' "$f" >"$f.x" && mv "$f.x" "$f"
  refused_untouched "pane $PANE is on another tmux server"
}

@test "a live, proven Claude Code session that is not in the lane's pane: refused" {
  make_repo
  write_resume alpha
  start_fake beta
  other_pid="$FAKE_PID" other_sid="$(reg beta .session_id)"
  start_fake alpha
  "$LANES" clear-ready --lane alpha >/dev/null
  f="$LANES_DATA_DIR/lanes/alpha.json"
  jq --argjson p "$other_pid" --arg s "$other_sid" '.claude_pid = $p | .session_id = $s' "$f" >"$f.x" && mv "$f.x" "$f"
  run as_lead clear alpha --wait 2
  assert_failure
  assert_output --partial "Claude Code pid $other_pid of lane alpha is not the process of pane $PANE or a child of it"
  run keys_typed
  assert_output 0
}

@test "Claude Code as a child of the pane's process (the npm node wrapper) is proven, and its clear lands" {
  make_repo
  write_resume alpha
  # The pane runs a bash that waits on the fake as its child, as node cli-wrapper.cjs does with the native binary.
  lanes_tmux new-session -d -s alpha -x 160 -y 40 -c "$WORK" \
    env LANES_DATA_DIR="$LANES_DATA_DIR" LANES_TMUX_SOCKET="$LANES_TMUX_SOCKET" LANES_BIN="$LANES" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" FAKE_LANE=alpha FAKE_LOG="$FAKE_LOG" \
    bash -c 'bash "$0"; exit $?' "$FAKE"
  PANE="$(lanes_tmux display -p -t alpha '#{pane_id}')"
  wait_for "registered alpha" test -f "$LANES_DATA_DIR/lanes/alpha.json"
  wait_for "prompt drawn" pane_has '❯'
  FAKE_PID="$(reg alpha .claude_pid)"
  [ "$FAKE_PID" != "$(lanes_tmux display -p -t alpha '#{pane_pid}')" ]
  run "$LANES" clear-ready --lane alpha
  assert_success
  run as_lead clear alpha
  assert_success
}

@test "Claude Code started from a shell in the pane, in the foreground, is proven, and its clear lands" {
  make_repo
  write_resume alpha
  shell_pane
  fake_from_shell alpha "bash '$LANES_TEST_TMP/run-fake' alpha"
  "$LANES" clear-ready --lane alpha >/dev/null
  run as_lead clear alpha
  assert_success
}

@test "Claude Code stopped with Ctrl-Z (the shell owns the terminal again) is not proven: nothing is typed" {
  make_repo
  write_resume alpha
  shell_pane
  fake_from_shell alpha "bash '$LANES_TEST_TMP/run-fake' alpha"
  "$LANES" clear-ready --lane alpha >/dev/null
  stop_fake
  refused_untouched "Claude Code pid $FAKE_PID of lane alpha is not the foreground program of pane $PANE"
  refute pane_has '/clear'
  kill -CONT "$FAKE_PID"
}

@test "a nested Claude Code started in the background from the pane's shell is not proven: nothing is typed" {
  make_repo
  write_resume nested
  shell_pane
  # Ignoring SIGTTOU and SIGTTIN lets a background job set up the terminal and poll it, as a tool's child can.
  fake_from_shell nested "(trap '' TTOU TTIN; exec bash '$LANES_TEST_TMP/run-fake' nested) &"
  "$LANES" clear-ready --lane nested >/dev/null
  run as_lead clear nested --wait 2
  assert_failure
  assert_output --partial "Claude Code pid $FAKE_PID of lane nested is not the foreground program of pane $PANE"
  run keys_typed
  assert_output 0
}

# zombie_fake <lane>: a registered fake whose parent, the pane's process, never waits for it, then SIGKILL it, so it
# stays a zombie (ps state Z) with its pid, start time and sessions file. tmux reaps a pane's own process from its
# event loop, after it may already report pane_dead, so a killed Claude Code can be such a zombie for a moment.
zombie_fake() {
  make_repo
  write_resume "$1"
  # An explicit stdin keeps the background fake on the terminal; exec leaves sleep as its parent, which never waits.
  lanes_tmux new-session -d -s "$1" -x 160 -y 40 -c "$WORK" \
    env LANES_DATA_DIR="$LANES_DATA_DIR" LANES_TMUX_SOCKET="$LANES_TMUX_SOCKET" LANES_BIN="$LANES" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" FAKE_LANE="$1" FAKE_LOG="$FAKE_LOG" \
    bash -c 'bash "$0" </dev/tty & exec sleep 300' "$FAKE"
  PANE="$(lanes_tmux display -p -t "$1" '#{pane_id}')"
  wait_for "registered $1" test -f "$LANES_DATA_DIR/lanes/$1.json"
  wait_for "prompt drawn" pane_has '❯'
  FAKE_PID="$(reg "$1" .claude_pid)"
  "$LANES" clear-ready --lane "$1" >/dev/null
  wait_for "parent exec" bash -c "[ \"\$(ps -o args= -p $(lanes_tmux display -p -t "$PANE" '#{pane_pid}'))\" = 'sleep 300' ]"
  kill -9 "$FAKE_PID"
  wait_for "zombie" bash -c "ps -o stat= -p $FAKE_PID | grep -q '^Z'"
  assert [ -f "$(session_file)" ]
}

@test "a killed Claude Code its parent has not reaped yet (a zombie) is gone: status reads its file as stale" {
  zombie_fake alpha
  run bash -c "'$LANES' status --json | jq -r '.[] | select(.lane == \"alpha\") | .activity + \" \" + .activity_detail'"
  assert_output --partial "unknown the session file of pid $FAKE_PID is stale"
}

@test "a zombie Claude Code is not proven: clear refuses it as stale" {
  zombie_fake alpha
  run as_lead clear alpha --wait 2
  assert_failure
  assert_output --partial "the session file of pid $FAKE_PID is stale"
}

@test "a zombie Claude Code does not hold its lane name: a new session takes it" {
  zombie_fake alpha
  run register_lane alpha 00000000-0000-4000-8000-000000000002 %99
  assert_success
  refute_output --partial 'already in use'
  run reg alpha .tmux_pane
  assert_output %99
}

@test "a SIGKILLed session leaves its file behind (as 2.1.309 does), and status reads it as stale, never idle" {
  make_repo
  lanes_tmux new-session -d -s keep -x 80 -y 10 "sleep 300"
  lanes_tmux set-option -g remain-on-exit on
  start_fake alpha
  kill -9 "$FAKE_PID"
  wait_for "pane dead" bash -c "[ \"\$(tmux -L '$LANES_TMUX_SOCKET' display -p -t '$PANE' '#{pane_dead}')\" = 1 ]"
  assert [ -f "$(session_file)" ]
  run bash -c "'$LANES' status --json | jq -r '.[] | select(.lane == \"alpha\") | .activity + \" \" + .activity_detail'"
  assert_output --partial "unknown the session file of pid $FAKE_PID is stale"
}
