#!/usr/bin/env bats
# Public seams: `lanes clear <lane>` for a lane with an active /goal, and `lanes goal <lane> <text>`. /clear removes an
# active goal itself (code.claude.com/docs/en/goal; measured on 2.1.309), so `lanes clear` types no `/goal clear`, and
# a goal loop keeps the sessions file busy across its turns, so clear waits for the loop to hand control back.

load helper

submits() { grep -E '^SUBMIT ' "$FAKE_LOG" | cut -d' ' -f2- || true; }

# goal_lane [VAR=value...]: a ready lane whose goal loop has run FAKE_GOAL_TURNS extra turns and given control back
# with the goal still set.
goal_lane() {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=2 "$@"
  wait_for "goal loop handed back" bash -c "[ \$(grep -c '^GOAL-CONTINUE$' '$FAKE_LOG') -eq 2 ]"
  wait_status idle
  wait_for "goal footer" pane_has '◎ /goal active'
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "a lane with an active goal is cleared by /clear alone, then the RESUME Goal is set, never the live one" {
  goal_lane
  run "$LANES" clear alpha
  assert_success
  assert_output --partial "cleared: alpha"
  run submits
  assert_output "/clear
/goal finish item A1 and report done"
  run state alpha .handshake.state
  assert_output done
}

@test "a goal the human cleared never comes back: only the RESUME Goal is re-sent" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="an old goal"
  wait_status idle
  lanes_tmux send-keys -t "$PANE" -l -- "/goal clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "goal footer gone" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q '◎ /goal active'"
  run "$LANES" clear-ready --lane alpha
  assert_success
  run state alpha .handshake.goal
  assert_output "finish item A1 and report done"
  run "$LANES" clear alpha
  assert_success
  run grep -c '^SUBMIT /goal an old goal' "$FAKE_LOG"
  assert_output 0
  run grep -c '^SUBMIT /goal finish item A1 and report done$' "$FAKE_LOG"
  assert_output 1
}

@test "a goal loop that goes on after clear-ready (turns with no prompt) refuses /clear: nothing is typed" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=3 FAKE_TURN_MS=400
  # clear-ready runs inside a goal turn, as the lane's Bash tool would run it; the loop then goes on.
  "$LANES" clear-ready --lane alpha >/dev/null
  n="$(grep -c '^GOAL-CONTINUE$' "$FAKE_LOG" || true)"
  wait_for "another goal turn" bash -c "[ \$(grep -c '^GOAL-CONTINUE$' '$FAKE_LOG') -gt $n ]"
  run "$LANES" clear alpha --wait 5
  assert_failure
  assert_output --partial "began another turn since clear-ready"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}

@test "a running goal loop keeps the lane busy (one busy span), so clear waits and then refuses: nothing is typed" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=1000 FAKE_TURN_MS=60000
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" clear alpha --wait 2
  assert_failure
  assert_output --partial "stayed busy for 2 s"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
  run sess .status
  assert_output busy
}

@test "the request message does not ask the lane to clear its own goal, which only typed input can do" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" request alpha
  assert_success
  refute_output --partial "goal"
}

# ---- lanes goal <lane> "<text>": the lead sets or replaces a lane's goal without clearing it -----------------------

as_lead() { TMUX_PANE=%99 "$LANES" "$@"; }

goal_setup() {
  make_repo
  write_resume alpha
  LANES_ROLE=lead register_lane lead sl %99 >/dev/null 2>&1
  start_fake alpha "$@"
}

@test "lanes goal sets the goal on an idle lane and confirms it through UserPromptSubmit" {
  goal_setup
  run as_lead goal alpha "ship B2 and its tests"
  assert_success
  assert_output --partial "goal set: alpha"
  run grep -c '^SUBMIT /goal ship B2 and its tests$' "$FAKE_LOG"
  assert_output 1
  run state alpha .last_command
  assert_output "/goal ship B2 and its tests"
}

@test "lanes goal refuses a busy lane and types nothing" {
  goal_setup FAKE_BUSY_FOREVER=1
  run as_lead goal alpha "ship B2" --wait 1
  assert_failure
  assert_output --partial "stayed busy"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "lanes goal refuses a multi-line goal before anything is typed" {
  goal_setup
  run as_lead goal alpha $'ship B2\nand B3'
  assert_failure 2
  assert_output --partial "one line"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "a goal over 256 characters is typed in chunks of at most 256, never pasted" {
  goal_setup
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 20))"
  long="${long%; }"
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$LANES_TEST_TMP/tmux.log" "$(command -v tmux)" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead goal alpha "$long"
  assert_success
  run grep -c 'paste-buffer\|load-buffer' "$LANES_TEST_TMP/tmux.log"
  assert_output 0
  run bash -c "grep -o 'send-keys -t %[0-9]* -l -- .*' '$LANES_TEST_TMP/tmux.log' | sed 's/^send-keys -t %[0-9]* -l -- //' | awk '{ n++; if (length(\$0) > m) m = length(\$0) } END { print n, m }'"
  assert_output "3 256"
  run grep -c "^SUBMIT /goal $long\$" "$FAKE_LOG"
  assert_output 1
}

@test "lanes goal from a caller that is not the lead is refused" {
  goal_setup
  register_lane beta sb %98 >/dev/null 2>&1
  TMUX_PANE=%98 run "$LANES" goal alpha "ship B2"
  assert_failure
  assert_output --partial "only the lead"
  run "$LANES" goal alpha "ship B2"
  assert_failure
  assert_output --partial "only the lead"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "a goal replaced with lanes goal is re-sent after a clear once the lane copied it into its RESUME Goal" {
  goal_setup
  run as_lead goal alpha "ship B2 instead"
  assert_success
  wait_status idle
  write_resume alpha "ship B2 instead"
  run "$LANES" clear-ready --lane alpha
  assert_success
  run "$LANES" clear alpha
  assert_success
  run submits
  assert_output "/goal ship B2 instead
/clear
/goal ship B2 instead"
}

@test "lanes goal checks the pane again right before typing: a session that took the pane during the wait gets nothing" {
  goal_setup
  export LANES_IDLE_GAP=3
  as_lead goal alpha "ship B2" >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  sleep 1
  register_lane beta sb "$PANE" >/dev/null 2>&1
  rc=0
  wait "$pid" || rc=$?
  assert [ "$rc" -ne 0 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "no longer holds pane"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "a draft that lands ahead of a long goal wrapped over several lines: nothing is deleted or submitted" {
  goal_setup FAKE_DRAFT_AT_FIRST_KEY=1
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  run as_lead goal alpha "$long"
  assert_failure
  assert_output --partial "ahead of ours"
  assert_output --partial "nothing was submitted or deleted"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯\xc2\xa0human draft/goal finish item B2'"
  assert_output 1
}

@test "a goal is trimmed where it enters: lanes goal types and confirms the same string" {
  goal_setup
  run as_lead goal alpha "   ship B2 and its tests   "
  assert_success
  run grep -c '^SUBMIT /goal ship B2 and its tests$' "$FAKE_LOG"
  assert_output 1
}

@test "a RESUME Goal with spaces around it is typed trimmed after a clear, and confirmed" {
  make_repo
  write_resume alpha "   ship A1 with spaces   "
  start_fake alpha
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" clear alpha
  assert_success
  run grep -c '^SUBMIT /goal ship A1 with spaces$' "$FAKE_LOG"
  assert_output 1
}

@test "a goal check that crashes (its character count killed) is a refusal, never a pass" {
  goal_setup
  jq_shim 'explode[] | if . > 65535' 1+
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead goal alpha "ship B2"
  assert_failure
  assert_output --partial "check failed: goal_problem"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "a goal of only spaces is refused before anything is typed" {
  goal_setup
  run as_lead goal alpha "    "
  assert_failure 2
  assert_output --partial "is empty"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "lanes goal sets the goal of a lane with a background shell running (only /clear refuses one, which the shell would outlive)" {
  goal_setup FAKE_SHELL_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "start a shell"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_status shell
  run as_lead goal alpha "ship B2"
  assert_success
  run grep -c '^SUBMIT /goal ship B2$' "$FAKE_LOG"
  assert_output 1
}
