#!/usr/bin/env bats
# Public seam: `lanes check-adapters [file]`, the contract test for the adapter file that /lanes:setup writes. It
# refuses a missing, unknown, repeated or empty key, a malformed line, a local command that is not on PATH, and a
# lead-only pattern in .lanes/guards.md that lanes-guard cannot match; a remote CLI that is missing only warns.

load helper

TEMPLATE="$LANES_REPO_ROOT/plugins/lanes/templates/adapters.md"

# A stub bin dir on PATH, so the valid file names commands that exist on every machine that runs the suite.
stub_bin() {
  mkdir -p "$LANES_TEST_TMP/bin"
  local c
  for c in "$@"; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$LANES_TEST_TMP/bin/$c"
    chmod +x "$LANES_TEST_TMP/bin/$c"
  done
  PATH="$LANES_TEST_TMP/bin:$PATH"
}

# write_adapters [key=value...]: a valid adapter file in .lanes/adapters.md, with each given key's line replaced
# (key= with nothing after it empties the value; key=- removes the line).
write_adapters() {
  mkdir -p "$WORK/.lanes"
  local -A v=(
    [ci_command]="ci-tool run ci.yml" [ci_status_command]="ci-tool run list --limit 1"
    [review_gate]="the reviewer agent passes, then the human approves"
    [test_runner]="local" [test_command]="test-tool --all" [deny_list]=""
  )
  local kv
  for kv in "$@"; do v[${kv%%=*}]="${kv#*=}"; done
  {
    echo "# lanes adapters"
    local k
    for k in ci_command ci_status_command review_gate test_runner test_command deny_list; do
      [[ "${v[$k]}" == - ]] || echo "$k: ${v[$k]}"
    done
  } >"$WORK/.lanes/adapters.md"
}

setup_valid() {
  make_repo
  stub_bin ci-tool test-tool
}

@test "a valid adapter file passes, read from the journal folder by default" {
  setup_valid
  write_adapters
  run "$LANES" check-adapters
  assert_success
  assert_output "adapters ok: $WORK/.lanes/adapters.md"
}

@test "an explicit file argument is checked instead of the default" {
  setup_valid
  write_adapters
  mv "$WORK/.lanes/adapters.md" "$WORK/other.md"
  run "$LANES" check-adapters other.md
  assert_success
  assert_output --partial "adapters ok: other.md"
}

@test "no file: refused with the path and the way to write it" {
  make_repo
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "no adapter file at $WORK/.lanes/adapters.md"
  assert_output --partial "/lanes:setup"
}

@test "a missing key is refused by name" {
  setup_valid
  write_adapters review_gate=-
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "key 'review_gate' is missing"
}

@test "an unknown key is refused with its line and the list of keys" {
  setup_valid
  write_adapters
  echo "ci_comand: ci-tool run" >>"$WORK/.lanes/adapters.md"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "adapters.md:8: unknown key 'ci_comand'"
  assert_output --partial "ci_command, ci_status_command, review_gate"
}

@test "a repeated key is refused with both lines" {
  setup_valid
  write_adapters
  echo "test_runner: ci" >>"$WORK/.lanes/adapters.md"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "adapters.md:8: key 'test_runner' is repeated (first on line 5)"
}

@test "an empty value is refused where one is required, and allowed where it is not" {
  setup_valid
  write_adapters test_command=
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "key 'test_command' has no value"
  write_adapters ci_command= ci_status_command= deny_list=
  run "$LANES" check-adapters
  assert_success
}

@test "a line that is not 'key: value' is refused" {
  setup_valid
  write_adapters
  echo "run the tests before merging" >>"$WORK/.lanes/adapters.md"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "adapters.md:8: not a 'key: value' line"
}

@test "test_runner takes local or ci only" {
  setup_valid
  write_adapters test_runner=sometimes
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "test_runner is 'sometimes': use local or ci"
}

@test "a local test command that is not on PATH is refused" {
  setup_valid
  write_adapters test_command="no-such-tool-x9 --all"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "test_command: 'no-such-tool-x9' is not on PATH"
}

@test "a missing remote CLI warns and passes: the CI commands, and the test command when tests run on CI" {
  setup_valid
  write_adapters ci_command="no-such-ci-x9 run" test_runner=ci test_command="no-such-ci-x9 run tests"
  run "$LANES" check-adapters
  assert_success
  assert_output --partial "warning"
  assert_output --partial "ci_command: 'no-such-ci-x9' is not on PATH here"
  assert_output --partial "test_command: 'no-such-ci-x9' is not on PATH here"
  assert_output --partial "adapters ok"
}

@test "a command given as a path is resolved from the repository root, and env assignments are skipped" {
  setup_valid
  mkdir -p "$WORK/scripts"
  printf '#!/usr/bin/env bash\n' >"$WORK/scripts/test.sh"
  chmod +x "$WORK/scripts/test.sh"
  write_adapters test_command="CI=1 scripts/test.sh --fast"
  mkdir -p "$WORK/sub"
  cd "$WORK/sub"
  run "$LANES" check-adapters
  assert_success
  write_adapters test_command="CI=1 scripts/missing.sh"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "'scripts/missing.sh' is not on PATH"
}

@test "CRLF line endings are read as plain lines: the values carry no carriage return" {
  setup_valid
  write_adapters
  sed 's/$/\r/' "$WORK/.lanes/adapters.md" >"$LANES_TEST_TMP/crlf" && mv "$LANES_TEST_TMP/crlf" "$WORK/.lanes/adapters.md"
  run grep -c $'\r' "$WORK/.lanes/adapters.md"
  assert_output 7
  run "$LANES" check-adapters
  assert_success
  assert_output "adapters ok: $WORK/.lanes/adapters.md"
}

@test "every problem is reported in one run, not only the first" {
  setup_valid
  write_adapters review_gate=- test_command=
  echo "extra_key: 1" >>"$WORK/.lanes/adapters.md"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "key 'review_gate' is missing"
  assert_output --partial "key 'test_command' has no value"
  assert_output --partial "unknown key 'extra_key'"
}

@test "the shipped template has exactly the keys the check knows: only its empty values are refused" {
  make_repo
  run "$LANES" check-adapters "$TEMPLATE"
  assert_failure 1
  refute_output --partial "missing"
  refute_output --partial "unknown key"
  refute_output --partial "repeated"
  refute_output --partial "not a 'key: value' line"
  assert_output --partial "key 'review_gate' has no value"
}

# A stand-in lanes-guard with the PreToolUse contract: a deny decision for a Bash command it matches. It matches a
# command equal to one of its plain-word patterns, so a pattern with a quote in it is one it cannot parse.
stub_guard() {
  stub_bin
  cat >"$LANES_TEST_TMP/bin/lanes-guard" <<'EOF'
#!/usr/bin/env bash
[ "$1" = lead-only ] || exit 2
cmd="$(jq -r .tool_input.command)"
list="$(sed -n 's/^lead_only_commands: *//p' "$CLAUDE_PROJECT_DIR/.lanes/guards.md")"
IFS=';' read -ra pats <<<"$list"
for p in "${pats[@]}"; do
  p="$(echo $p)"
  [[ "$p" == *'"'* ]] && continue
  [ "${p% @default}" = "$cmd" ] && { jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny"}}'; exit 0; }
done
exit 0
EOF
  chmod +x "$LANES_TEST_TMP/bin/lanes-guard"
}

# write_guards <lines...>: the project's lanes-guards config, one line per argument.
write_guards() {
  mkdir -p "$WORK/.lanes"
  printf '%s\n' "$@" >"$WORK/.lanes/guards.md"
}

@test "the adapter file has no lead-only key: its one home is .lanes/guards.md" {
  setup_valid
  write_adapters
  echo "lead_only_commands: ci-tool run" >>"$WORK/.lanes/adapters.md"
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "unknown key 'lead_only_commands'"
}

@test "with lanes-guard installed, each lead-only pattern in .lanes/guards.md must be one the guard refuses" {
  setup_valid
  stub_guard
  write_adapters
  write_guards "# guards" "lead_only_commands: ci-tool run; git push @default"
  run "$LANES" check-adapters
  assert_success
  write_guards "# guards" 'lead_only_commands: ci-tool run; gh pr "merge"'
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "$WORK/.lanes/guards.md:2: lead_only_commands: lanes-guard does not refuse 'gh pr \"merge\"'"
  refute_output --partial "'ci-tool run'"
}

@test "the guards file is read as lanes-guard reads it: the last lead_only_commands line wins" {
  setup_valid
  stub_guard
  write_adapters
  write_guards 'lead_only_commands: gh pr "merge"' "lead_only_commands: ci-tool run"
  run "$LANES" check-adapters
  assert_success
  write_guards "lead_only_commands: ci-tool run" 'lead_only_commands: gh pr "merge"'
  run "$LANES" check-adapters
  assert_failure 1
  assert_output --partial "guards.md:2:"
}

@test "with lanes-guard installed, no guards file or an empty list keeps the guard's default and probes nothing" {
  setup_valid
  stub_guard
  write_adapters
  run "$LANES" check-adapters
  assert_success
  assert_output "adapters ok: $WORK/.lanes/adapters.md"
  write_guards "lead_only_commands:"
  run "$LANES" check-adapters
  assert_success
}

@test "without lanes-guard on PATH the lead-only list is not probed" {
  setup_valid
  write_adapters
  write_guards 'lead_only_commands: gh pr "merge"'
  run "$LANES" check-adapters
  assert_success
}

@test "more than one argument is a usage error" {
  make_repo
  run "$LANES" check-adapters a b
  assert_failure 2
}
