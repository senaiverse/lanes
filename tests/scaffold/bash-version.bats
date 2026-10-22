#!/usr/bin/env bats
# Every plugin bin/ script needs Bash 4+ (docs/CONVENTIONS.md) and must say so at once on an older Bash.
# BASH_VERSINFO is read-only, so the test raises the script's minimum instead of faking the running version.

load ../helpers/common

ROOT="$BATS_TEST_DIRNAME/../.."

setup() { lanes_test_setup; }
teardown() { lanes_test_teardown; }

@test "every bin script refuses a Bash older than its minimum with an actionable message" {
  local f copy
  for f in "$ROOT"/plugins/*/bin/*; do
    [ -f "$f" ] || continue
    copy="$LANES_TEST_TMP/$(basename "$f")"
    sed 's/-ge 4 \]/-ge 99 ]/' "$f" > "$copy"
    cmp -s "$f" "$copy" && { echo "no 'BASH_VERSINFO[0] -ge 4' guard in $f" >&2; false; }
    run bash "$copy"
    [ "$status" -eq 2 ] || { echo "$f exited $status, want 2" >&2; false; }
    [[ "$output" == *"requires Bash 4 or newer"* && "$output" == *"brew install bash"* ]] || { echo "$f said: $output" >&2; false; }
  done
}

@test "on a system Bash older than 4 the real scripts fail fast (macOS /bin/bash 3.2)" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ] || skip "/bin/bash is 4 or newer on this system"
  local f
  for f in "$ROOT"/plugins/*/bin/*; do
    [ -f "$f" ] || continue
    run /bin/bash "$f"
    [ "$status" -eq 2 ] || { echo "$f exited $status under /bin/bash" >&2; false; }
    [[ "$output" == *"requires Bash 4 or newer"* ]] || { echo "$f said: $output" >&2; false; }
  done
}
