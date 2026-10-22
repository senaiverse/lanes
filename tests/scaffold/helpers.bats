#!/usr/bin/env bats

load ../helpers/common

setup() { lanes_test_setup; }
teardown() { lanes_test_teardown; }

@test "setup gives a temp LANES_DATA_DIR that exists" {
  [ -d "$LANES_DATA_DIR" ]
  case "$LANES_DATA_DIR" in /tmp/lanes-test.*) ;; *) false ;; esac
}

@test "the tmux socket path stays under the 104-byte macOS limit even with a long TMPDIR" {
  [ "${#TMUX_TMPDIR}" -lt 60 ]
}

@test "lanes_tmux runs on a private server, not the user's" {
  lanes_tmux new-session -d -s probe
  run lanes_tmux list-sessions -F '#{session_name}'
  assert_success
  assert_output "probe"
  # The socket name carries the test pid, so a default-socket tmux does not see it.
  run tmux -L "other-$$" list-sessions
  assert_failure
}

@test "teardown kills the private server and removes the temp dir" {
  lanes_tmux new-session -d -s probe
  local tmp="$LANES_TEST_TMP"
  lanes_test_teardown
  run lanes_tmux list-sessions
  assert_failure
  [ ! -e "$tmp" ]
}
