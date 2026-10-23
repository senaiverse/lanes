#!/usr/bin/env bats
# Contract checks on the plugin's static files: manifest, hooks, skills and the journal template.

load helper

P="$BATS_TEST_DIRNAME/../../plugins/lanes"

@test "plugin.json: name, author, homepage, repository, MIT and the two options with their defaults" {
  run jq -e '.name == "lanes" and .author.name == "senaiverse"
    and .homepage == "https://github.com/senaiverse/lanes" and .repository == "https://github.com/senaiverse/lanes"
    and .license == "MIT"
    and .userConfig.threshold.type == "number" and .userConfig.threshold.default == 70
    and .userConfig.journal_dir.type == "string" and .userConfig.journal_dir.default == ".lanes"' "$P/.claude-plugin/plugin.json"
  assert_success
}

@test "hooks.json: every command is the absolute plugin-root path, quoted, with a timeout" {
  run jq -r '.hooks[][] | .hooks[] | select((.command | startswith("\"${CLAUDE_PLUGIN_ROOT}/bin/lanes\" ") | not) or (.timeout | type != "number")) | .command' "$P/hooks/hooks.json"
  assert_success
  assert_output ""
}

@test "hooks.json wires the three events the core needs, and no Stop hook (activity comes from the sessions file)" {
  run jq -r '[.hooks | to_entries[] | "\(.key)=\(.value[0].matcher // "*")=\(.value[0].hooks[0].command | split(" ")[1:] | join(" "))"] | sort | .[]' "$P/hooks/hooks.json"
  assert_output 'PreToolUse=AskUserQuestion=hook ask
SessionStart=startup|resume|clear|compact|fork=register
UserPromptSubmit=*=hook prompt'
}

@test "each skill is under 200 lines, has a description, and cites RULES.md" {
  for s in lead lane; do
    f="$P/skills/$s/SKILL.md"
    [ "$(wc -l <"$f")" -lt 200 ]
    grep -q '^description: ' "$f"
    grep -q 'RULES.md' "$f"
  done
}

@test "the lead skill calls grilling through the Skill tool, and CREDITS.md alone credits mattpocock/skills" {
  grep -q 'call the Skill tool with "grilling" if it is installed' "$P/skills/lead/SKILL.md"
  run grep -c mattpocock "$P/skills/lead/SKILL.md"
  assert_output 0
  grep -q 'https://github.com/mattpocock/skills' "$P/skills/lead/CREDITS.md"
  grep -q 'MIT' "$P/skills/lead/CREDITS.md"
}

@test "the RESUME template carries the credit line, the redaction line and stays far under the cap" {
  f="$P/templates/journal/next-lane.md"
  grep -q 'mattpocock/skills' "$f"
  grep -qi 'secret' "$f"
  [ "$(wc -c <"$f")" -lt 4000 ]
}

@test "the RESUME template's sections are exactly the ones clear-ready requires" {
  run bash -c "awk '/lanes:resume:start/{on=1} /lanes:resume:end/{on=0} on && /^### /{sub(/^### /,\"\"); print}' '$P/templates/journal/next-lane.md'"
  assert_output "Goal
Now
Next step
Links
Running
Suggested skills"
}

@test "the done template carries the done-report form" {
  f="$P/templates/journal/done-lane.md"
  for word in Ripple 'Blast radius' Pitfalls 'Edge cases' 'Review verdicts' Evidence 'full diff'; do
    grep -qi "$word" "$f"
  done
}

@test "RULES.md is short and numbered" {
  f="$P/templates/journal/RULES.md"
  [ "$(grep -cE '^[0-9]+\. ' "$f")" -ge 8 ]
  [ "$(wc -l <"$f")" -lt 80 ]
}

@test "no lanes test starts a process group with a tool macOS lacks, so none skips there for want of it" {
  # The name is split so this line does not match itself.
  run grep -rnE '^[^#]*(^|[^[:alnum:]_])set''sid([^[:alnum:]_]|$)' "$BATS_TEST_DIRNAME"
  assert_failure 1
  assert_output ""
}
