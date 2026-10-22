#!/usr/bin/env bats
# DECISIONS 20 and 21: lanes-waves requires the core plugin and cites its RULES.md; the plan template
# is the single home of the plan fields.

load ../helpers/common

ROOT="$BATS_TEST_DIRNAME/../.."
WAVES="$ROOT/plugins/lanes-waves"
LEAD="$WAVES/skills/waves-lead/SKILL.md"
LANE="$WAVES/skills/waves-lane/SKILL.md"

# section <file> <heading>: the lines of one "## " or "### " section, up to the next heading of any level 1-3.
section() {
  awk -v h="$2" '
    /^#{1,3} / { on = (index($0, h) > 0 && $0 ~ ("^#+ " h)) ; next }
    on { print }
  ' "$1"
}

@test "the waves plugin.json says it requires the core lanes plugin and its RULES.md" {
  run jq -r .description "$WAVES/.claude-plugin/plugin.json"
  assert_output --partial "core \`lanes\` plugin"
  assert_output --partial ".lanes/RULES.md"
}

@test "both skills open by requiring the core plugin and .lanes/RULES.md" {
  local f opening
  for f in "$LEAD" "$LANE"; do
    opening="$(awk '/^# /{on=1; next} on && /^## /{exit} on' "$f")"
    [[ "$opening" == *"requires the core \`lanes\` plugin"* && "$opening" == *".lanes/RULES.md"* ]] \
      || { echo "opening of $f lacks the core requirement" >&2; false; }
  done
}

@test "waves-lead does not list plan fields: it points to the template and lanes-plancheck" {
  run section "$LEAD" "2. Plan every item"
  assert_output --partial "lanes-plancheck"
  assert_output --partial "templates/plan.md"
  refute_output --partial "Done when:"
  refute_output --partial "Edge cases:"
  refute_output --partial "Must not:"
  refute_output --partial "Premises:"
}

@test "waves-lead's Approvals section cites RULES.md and restates no approval rule" {
  run section "$LEAD" "Approvals"
  assert_output --partial "RULES.md"
  refute_output --partial "I propose"
  refute_output --partial "money"
  refute_output --partial "CI dispatch"
}

@test "the README lists the files lanes uses, including the wave defaults" {
  run sed -n '/^## Files lanes uses/,/^## /p' "$ROOT/README.md"
  assert_output --partial ".lanes/RULES.md"
  assert_output --partial ".lanes/tracker.md"
  assert_output --partial ".lanes/waves/W<N>.md"
}

@test "the waves settings template keeps the tracker and wave-plan defaults" {
  run grep -E '\.lanes/tracker\.md|\.lanes/waves/W<N>\.md' "$WAVES/templates/waves.md"
  assert_success
}
