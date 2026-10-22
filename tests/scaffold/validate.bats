#!/usr/bin/env bats

load ../helpers/common

VALIDATE="$BATS_TEST_DIRNAME/../../scripts/validate.sh"

setup() { lanes_test_setup; }
teardown() { lanes_test_teardown; }

@test "without the claude CLI it skips with a notice and succeeds" {
  # A PATH holding only symlinks to what the script needs, and no claude.
  local bin="$LANES_TEST_TMP/bin"
  mkdir -p "$bin"
  local t
  for t in bash env dirname; do ln -s "$(command -v "$t")" "$bin/$t"; done
  PATH="$bin" run "$BASH" "$VALIDATE"
  assert_success
  assert_output --partial "claude CLI not found"
}
