#!/usr/bin/env bats

load ../helpers/common

ROOT="$BATS_TEST_DIRNAME/../.."
MP="$ROOT/.claude-plugin/marketplace.json"

@test "the reviewer is never advertised as read-only: it keeps unrestricted Bash" {
  run grep -rniE 'read-only adversarial|Read-only reviewer' "$ROOT/.claude-plugin" "$ROOT/plugins/lanes-review"
  assert_failure
  run grep -c 'not sandboxed' "$ROOT/plugins/lanes-review/agents/reviewer.md" "$ROOT/plugins/lanes-review/.claude-plugin/plugin.json" "$MP"
  refute_output --partial ":0"
}
