#!/usr/bin/env bats
# Public seams: `lanes away on|off|status` and the PreToolUse(AskUserQuestion) hook `lanes hook ask`.

load helper

ask() {
  jq -nc --arg c "$WORK" '{hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",session_id:"s1",cwd:$c,tool_input:{questions:[]}}' |
    "$LANES" hook ask
}

reason() { ask | jq -r .hookSpecificOutput.permissionDecisionReason; }

@test "away off: the ask hook prints nothing and allows the call" {
  make_repo
  run ask
  assert_success
  assert_output ""
}

@test "away on: AskUserQuestion is denied with a reason that points at morning.md" {
  make_repo
  run "$LANES" away on
  assert_success
  run ask
  assert_success
  run jq -r '.hookSpecificOutput | [.hookEventName, .permissionDecision] | join(" ")' <<<"$output"
  assert_output "PreToolUse deny"
  run reason
  assert_output --partial "$WORK/.lanes/morning.md"
  assert_output --partial "human's own message"
}

@test "the away hook works with a stdin that has no session_title, from a registered session" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  "$LANES" away on >/dev/null
  run bash -c "jq -nc --arg c '$WORK' '{hook_event_name:\"PreToolUse\",tool_name:\"AskUserQuestion\",session_id:\"s1\",cwd:\$c}' | '$LANES' hook ask | jq -r .hookSpecificOutput.permissionDecision"
  assert_success
  assert_output deny
}

@test "away off lifts it, and status reports both states" {
  "$LANES" away on >/dev/null
  run "$LANES" away status
  assert_output --partial "away mode on since"
  "$LANES" away off >/dev/null
  run "$LANES" away status
  assert_output "away mode off"
  make_repo
  run ask
  assert_output ""
}

@test "an unknown away argument is a usage error" {
  run "$LANES" away maybe
  assert_failure 2
}

@test "away on records who set it and when, and status says both" {
  register_lane lead sl %9 >/dev/null
  TMUX_PANE=%9 run "$LANES" away on
  assert_success
  run jq -r '[.set_by, (.since | test("^[0-9]{4}-"))] | @json' "$LANES_DATA_DIR/lanes/state/away.json"
  assert_output '["lead",true]'
  run "$LANES" away status
  assert_output --regexp "away mode on since [0-9T:Z-]+, set by lead"
  "$LANES" away on >/dev/null
  run jq -r .set_by "$LANES_DATA_DIR/lanes/state/away.json"
  assert_output "outside a lane pane"
}
