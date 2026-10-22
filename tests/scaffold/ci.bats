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

# The lines of the windows job (up to the next top-level job).
windows_job() { awk '/^  windows:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$CI"; }

@test "a windows job runs in Git Bash on windows-latest with a time limit and a SHA-pinned checkout" {
  local job
  job="$(windows_job)"
  [ -n "$job" ] || { echo "no windows job in $CI" >&2; false; }
  grep -qE 'runs-on: windows-latest$' <<< "$job"
  grep -qE 'shell: bash$' <<< "$job"
  grep -qE 'timeout-minutes: 15$' <<< "$job"
  grep -qE 'uses: actions/checkout@[0-9a-f]{40} # v[0-9]' <<< "$job"
}

@test "the windows job runs the plancheck suite, and prodfence only when its suite directory exists" {
  local job
  job="$(windows_job)"
  grep -q 'tests/lanes-plancheck' <<< "$job"
  grep -qE '\[ -d tests/lanes-prodfence \]' <<< "$job"
  grep -q 'scripts/test.sh' <<< "$job"
}

@test "git attributes keep LF in every shell file and the plan template so Windows checkouts run" {
  local pat attrs="$BATS_TEST_DIRNAME/../../.gitattributes"
  for pat in '*.sh' '*.bash' '*.bats' 'plugins/*/bin/*' '.githooks/*' 'plugins/lanes-plancheck/templates/plan.md'; do
    grep -qxF "$pat text eol=lf" "$attrs" || { echo "missing: $pat text eol=lf" >&2; false; }
  done
}

@test "test.sh given a suite directory runs only that suite" {
  local suite="$BATS_TEST_TMPDIR/only-suite"
  mkdir -p "$suite"
  printf '#!/usr/bin/env bats\n@test "only-suite-marker" { true; }\n' > "$suite/a.bats"
  run "$BATS_TEST_DIRNAME/../../scripts/test.sh" "$suite"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [[ "$output" == *"only-suite-marker"* ]]
  [[ "$output" != *"every action is pinned"* ]]
}

@test "test.sh given a missing suite directory fails and names it" {
  run "$BATS_TEST_DIRNAME/../../scripts/test.sh" "$BATS_TEST_TMPDIR/no-such-suite"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-suite"* ]]
}
