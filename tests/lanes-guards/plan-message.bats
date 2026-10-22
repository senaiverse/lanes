#!/usr/bin/env bats
# Public seam: `lanes-guard plan-message`, fed PreToolUse stdin for the SendMessage tool.
bats_require_minimum_version 1.5.0

load helper

@test "a lane's message that starts with the plan marker is refused, naming the rule and the allowed path" {
  run_guard plan-message "$(message_input sid-lane1 'PLAN: split the work in three')"
  assert_denied "plan-message"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"PLAN:"* ]]
  [[ "$reason" == *"send the lead facts"* ]]
}

@test "the lead may send a plan" {
  run_guard plan-message "$(message_input sid-lead 'PLAN: split the work in three')"
  assert_untouched
}

@test "a lane's message without the marker passes untouched" {
  run_guard plan-message "$(message_input sid-lane1 'done: tests pass at src/a.ts:12')"
  assert_untouched
}

@test "the marker mid-message passes, and leading whitespace or newlines do not hide it" {
  run_guard plan-message "$(message_input sid-lane1 'the lead wrote PLAN: earlier')"
  assert_untouched
  run_guard plan-message "$(message_input sid-lane1 $'  \n\tPLAN: sneaky')"
  assert_denied "plan-message"
}

@test "the marker is configurable in guards.md and by userConfig, and guards.md wins" {
  export CLAUDE_PLUGIN_OPTION_PLAN_MARKER='PROPOSAL:'
  run_guard plan-message "$(message_input sid-lane1 'PROPOSAL: do x')"
  assert_denied "PROPOSAL:"
  run_guard plan-message "$(message_input sid-lane1 'PLAN: do x')"
  assert_untouched
  write_guards "$PROJECT" 'plan_marker: >>PLAN'
  run_guard plan-message "$(message_input sid-lane1 '>>PLAN do x')"
  assert_denied ">>PLAN"
  run_guard plan-message "$(message_input sid-lane1 'PROPOSAL: do x')"
  assert_untouched
}

@test "an unregistered session with a marked message is refused, with how to register" {
  run_guard plan-message "$(message_input sid-stranger 'PLAN: x')"
  assert_denied "not in the lanes registry"
}

@test "an unregistered session with an unmarked message passes" {
  run_guard plan-message "$(message_input sid-stranger 'status: idle')"
  assert_untouched
}

@test "a non-string message, a missing message or another tool passes untouched" {
  run_guard plan-message '{"session_id":"sid-lane1","tool_name":"SendMessage","tool_input":{"to":"lead","message":{"a":1}}}'
  assert_untouched
  run_guard plan-message '{"session_id":"sid-lane1","tool_name":"SendMessage","tool_input":{"to":"lead"}}'
  assert_untouched
  run_guard plan-message '{"session_id":"sid-lane1","tool_name":"Bash","tool_input":{"message":"PLAN: x"}}'
  assert_untouched
}

@test "malformed stdin fails open with a stderr note" {
  run --separate-stderr "$GUARD" plan-message <<<'{"tool_input":'
  assert_untouched
  [[ "$stderr" == *"lanes-guard:"* ]]
}
