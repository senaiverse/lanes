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
    [[ "$opening" == *"requires the core \`lanes\` plugin"* && "$opening" == *"RULES.md"* ]] \
      || { echo "opening of $f lacks the core requirement" >&2; false; }
  done
}

@test "the waves plugin.json declares the core lanes plugin as a dependency" {
  run jq -c .dependencies "$WAVES/.claude-plugin/plugin.json"
  assert_output '["lanes"]'
}

@test "neither skill restates a RULES.md rule: every citation carries a rule number" {
  # A bare "(RULES.md)" says which file, not which rule; the section naming the rules lists none.
  run grep -nE 'RULES\.md\)' "$LEAD" "$LANE"
  assert_failure
  run grep -c 'RULES.md rule 13' "$LEAD" "$LANE"
  assert_output --partial "waves-lead/SKILL.md:1"
  assert_output --partial "waves-lane/SKILL.md:1"
}

@test "waves-lead names the settings template by CLAUDE_PLUGIN_ROOT and the plan template by its plugin" {
  run grep -c 'CLAUDE_PLUGIN_ROOT}/templates/waves.md' "$LEAD"
  assert_output 1
  run grep -c "this plugin's" "$LEAD"
  assert_output 0
}

@test "every setting a waves skill quotes exists in the settings template" {
  local s
  for s in "ci command" "ci status command" "ci per head" "batch base" "batch branch" "flake rule"; do
    grep -qF "| $s |" "$WAVES/templates/waves.md" || { echo "template lacks $s" >&2; false; }
  done
  grep -qF '"ci status command"' "$LEAD"
  grep -qF '"ci per head"' "$LEAD"
  grep -qF '"batch base"' "$LEAD"
}

@test "waves-lane points to its journal folder through lanes journal-dir, not a literal .lanes/ path" {
  run grep -c '\.lanes/' "$LANE"
  assert_output 0
  run grep -c 'lanes journal-dir' "$LANE"
  [ "$output" -ge 1 ]
}

@test "waves-lead does not list plan fields: it points to the template and lanes-plancheck" {
  run section "$LEAD" "2. Plan every item"
  assert_output --partial "lanes-plancheck"
  assert_output --partial "plan template shipped with"
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
