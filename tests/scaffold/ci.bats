#!/usr/bin/env bats
# The workflow is the project's trust boundary: pinned actions, a time limit, and a deny-gate that
# does not fail fork pull requests (their secret is empty).

CI="$BATS_TEST_DIRNAME/../../.github/workflows/ci.yml"

@test "every action is pinned by a full commit SHA with a version comment" {
  run grep -E '^\s*-?\s*uses:' "$CI"
  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [[ "$line" =~ uses:\ [^@]+@[0-9a-f]{40}\ \#\ v[0-9] ]] || { echo "not SHA-pinned with a version comment: $line" >&2; false; }
  done <<< "$output"
}

@test "the job has a timeout" {
  grep -qE '^\s+timeout-minutes: 15$' "$CI"
}

@test "CI neither runs the deny-gate nor reads its secret (it is a local pre-push hook)" {
  run grep -E 'deny-gate|LANES_DENY_LIST|secrets\.' "$CI"
  [ "$status" -eq 1 ]
}

@test "macOS runs the Bash 3.2 guard test" {
  grep -q 'bash-version.bats' "$CI"
}
