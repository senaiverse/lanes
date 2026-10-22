#!/usr/bin/env bats
# Public seam: the lanes-plancheck executable. Each test builds plan files in a temp dir and
# runs the checker from that dir, so a `.lanes/plan-fields` file there acts as the project's override.

PLUGIN="$BATS_TEST_DIRNAME/../../plugins/lanes-plancheck"
BIN="$PLUGIN/bin/lanes-plancheck"
TEMPLATE="$PLUGIN/templates/plan.md"

setup() {
  WORK="$(mktemp -d)"
  cd "$WORK"
  unset LANES_PLAN_FIELDS
}

teardown() {
  rm -rf "$WORK"
}

# write_plan <file> <heading>...: every named heading gets one body line.
write_plan() {
  local file="$1" h
  shift
  : >"$file"
  for h in "$@"; do
    printf '## %s\n\nbody of %s\n\n' "$h" "$h" >>"$file"
  done
}

# The fields DECISIONS 21 names; the template is their single home.
DEFAULTS=(Goal "Done when" Scope "Must not" Steps Tests "Edge cases" Risks)

# without <name>...: DEFAULTS minus the named fields.
without() {
  local f x skip
  for f in "${DEFAULTS[@]}"; do
    skip=
    for x in "$@"; do [ "$f" = "$x" ] && skip=1; done
    [ -n "$skip" ] || printf '%s\n' "$f"
  done
}

@test "a complete plan passes" {
  write_plan plan.md "${DEFAULTS[@]}"
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "one missing field is named and fails" {
  mapfile -t some < <(without Risks)
  write_plan plan.md "${some[@]}"
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Risks" ]
}

@test "several missing fields are each reported" {
  write_plan plan.md Goal Steps
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan.md: missing field: Scope"* ]]
  [[ "$output" == *"plan.md: missing field: Done when"* ]]
  [[ "$output" == *"plan.md: missing field: Must not"* ]]
  [[ "$output" == *"plan.md: missing field: Edge cases"* ]]
}

@test "an empty section counts as missing" {
  { printf '## Goal\n\n\n'; for f in "${DEFAULTS[@]:1}"; do printf '## %s\nx\n' "$f"; done; } >plan.md
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Goal" ]
}

@test "a section holding only an HTML comment counts as empty" {
  { printf '## Goal\n<!-- say what -->\n<!--\nmore\n-->\n'; for f in "${DEFAULTS[@]:1}"; do printf '## %s\nx\n' "$f"; done; } >plan.md
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Goal" ]
}

@test "a heading at the wrong level does not count" {
  mapfile -t some < <(without "Done when")
  write_plan plan.md "${some[@]}"
  printf '### Done when\n\nsome text\n' >>plan.md
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Done when" ]
}

@test "a sub-heading and its text belong to the section above" {
  { printf '## Goal\n### Detail\ntext\n'; for f in "${DEFAULTS[@]:1}"; do printf '## %s\nx\n' "$f"; done; } >plan.md
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "heading match ignores case and surrounding spaces" {
  write_plan plan.md goal "DONE WHEN" SCOPE "must not" Steps Tests "edge CASES" Risks
  sed 's/^## /##   /' plan.md >plan2.md
  run "$BIN" plan.md plan2.md
  [ "$status" -eq 0 ]
}

@test "a heading inside a code fence is not a field" {
  mapfile -t some < <(without "Done when")
  write_plan plan.md "${some[@]}"
  printf '```\n## Done when\nx\n```\n' >>plan.md
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Done when" ]
}

@test "a tilde fence is closed only by a tilde fence" {
  mapfile -t some < <(without "Done when")
  write_plan plan.md "${some[@]}"
  printf '~~~\n```\n## Done when\nx\n~~~\n' >>plan.md
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Done when" ]
}

@test "a backtick fence is closed only by a backtick fence" {
  mapfile -t some < <(without "Done when")
  write_plan plan.md "${some[@]}"
  printf '```\n~~~\n## Done when\nx\n```\n' >>plan.md
  run "$BIN" plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Done when" ]
}

@test "text after a closed fence counts again" {
  mapfile -t some < <(without "Done when")
  write_plan plan.md "${some[@]}"
  printf '~~~\nx\n~~~\n## Done when\nreal\n' >>plan.md
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "a custom fields file replaces the defaults" {
  mkdir .lanes
  printf 'Context\nDecision\n\n' >.lanes/plan-fields
  write_plan plan.md Context Decision
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
  write_plan plan.md Context
  run "$BIN" plan.md
  [ "$output" = "plan.md: missing field: Decision" ]
}

@test "the default fields are the template's headings, not a list in the script" {
  mkdir -p fake/bin fake/templates
  cp "$BIN" fake/bin/lanes-plancheck
  printf '# Plan: t\n\n## Alpha\n\n<!-- a -->\n\n## Beta\n\n<!-- b -->\n' >fake/templates/plan.md
  write_plan plan.md Alpha Beta
  run fake/bin/lanes-plancheck plan.md
  [ "$status" -eq 0 ]
  write_plan plan.md Alpha
  run fake/bin/lanes-plancheck plan.md
  [ "$status" -eq 1 ]
  [ "$output" = "plan.md: missing field: Beta" ]
}

@test "a missing template is refused loudly" {
  mkdir -p fake/bin
  cp "$BIN" fake/bin/lanes-plancheck
  write_plan plan.md "${DEFAULTS[@]}"
  run fake/bin/lanes-plancheck plan.md
  [ "$status" -eq 2 ]
  [[ "$output" == "lanes-plancheck: "*"plan.md"* ]]
}

@test "the checker finds the template when run through a symlink" {
  mkdir -p linkbin
  ln -s "$BIN" linkbin/lanes-plancheck
  write_plan plan.md "${DEFAULTS[@]}"
  run linkbin/lanes-plancheck plan.md
  [ "$status" -eq 0 ]
}

@test "the fields file is found by walking up to the git root" {
  git init -q .
  mkdir -p .lanes deep/er
  printf 'Context\n' >.lanes/plan-fields
  write_plan deep/er/plan.md Context
  cd deep/er
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "the walk stops at the git root: a fields file above it is ignored" {
  mkdir -p outer/repo/sub
  mkdir outer/.lanes
  printf 'Context\n' >outer/.lanes/plan-fields
  git init -q outer/repo
  write_plan outer/repo/sub/plan.md "${DEFAULTS[@]}"
  cd outer/repo/sub
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "outside a git repository only the current directory is searched" {
  mkdir -p .lanes sub
  printf 'Context\n' >.lanes/plan-fields
  write_plan sub/plan.md "${DEFAULTS[@]}"
  cd sub
  run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "LANES_PLAN_FIELDS names the fields file explicitly" {
  printf 'Context\n' >elsewhere.txt
  write_plan plan.md Context
  LANES_PLAN_FIELDS=elsewhere.txt run "$BIN" plan.md
  [ "$status" -eq 0 ]
}

@test "a duplicate name in the fields file is refused" {
  mkdir .lanes
  printf 'Goal\nSteps\ngoal\n' >.lanes/plan-fields
  write_plan plan.md Goal Steps
  run "$BIN" plan.md
  [ "$status" -eq 2 ]
  [[ "$output" == "lanes-plancheck: "*"duplicate"*"goal"* ]]
}

@test "a fields path that is a directory is refused with a specific message" {
  mkdir -p .lanes/plan-fields
  write_plan plan.md "${DEFAULTS[@]}"
  run "$BIN" plan.md
  [ "$status" -eq 2 ]
  [[ "$output" == "lanes-plancheck: "*"is a directory"* ]]
}

@test "an empty fields file is refused loudly" {
  mkdir .lanes
  : >.lanes/plan-fields
  write_plan plan.md "${DEFAULTS[@]}"
  run "$BIN" plan.md
  [ "$status" -eq 2 ]
  [[ "$output" == "lanes-plancheck: "* ]]
}

@test "a missing file fails and is named" {
  run "$BIN" nope.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"nope.md"* ]]
  [[ "$output" == *"cannot read"* ]]
}

@test "multiple files are all checked and the verdict covers every one" {
  write_plan good.md "${DEFAULTS[@]}"
  write_plan bad.md Goal
  run "$BIN" good.md bad.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.md: missing field: Scope"* ]]
  [[ "$output" != *"good.md:"* ]]
}

@test "CRLF line endings are accepted" {
  write_plan plan.md "${DEFAULTS[@]}"
  sed 's/$/\r/' plan.md >crlf.md
  run "$BIN" crlf.md
  [ "$status" -eq 0 ]
}

@test "no arguments prints usage and exits 2" {
  run "$BIN"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "the shipped template carries exactly the eight fields, structurally valid but unfilled" {
  run "$BIN" "$TEMPLATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing field: Goal"* ]]
  run grep '^## ' "$TEMPLATE"
  [ "$output" = "## Goal
## Done when
## Scope
## Must not
## Steps
## Tests
## Edge cases
## Risks" ]
}
