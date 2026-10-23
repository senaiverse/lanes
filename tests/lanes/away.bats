#!/usr/bin/env bats
# Public seams: `lanes away on|off|status` and the PreToolUse(AskUserQuestion) hook `lanes hook ask`. Away mode belongs
# to one project and refuses the ask tool to that project's registered sessions (its lead and its lanes) only.

load helper

# ask <session id> [cwd]: the PreToolUse hook input for AskUserQuestion, with no session_title (PreToolUse has none).
ask() {
  jq -nc --arg s "$1" --arg c "${2:-$WORK}" '{hook_event_name:"PreToolUse",tool_name:"AskUserQuestion",session_id:$s,cwd:$c,tool_input:{questions:[]}}' |
    "$LANES" hook ask
}

# decision <session id> [cwd]: deny, or allow when the hook printed nothing.
decision() {
  local out
  out="$(ask "$@")"
  if [[ -z "$out" ]]; then echo allow; else jq -r .hookSpecificOutput.permissionDecision <<<"$out"; fi
}

# start_in <dir> <lane> <session> <pane> [VAR=value...]: that session's SessionStart from <dir>.
start_in() {
  local dir="$1" lane="$2" sid="$3" pane="$4"
  shift 4
  jq -nc --arg s "$sid" --arg t "$lane" --arg c "$dir" '{session_id:$s,session_title:$t,cwd:$c,source:"startup"}' |
    env TMUX_PANE="$pane" "$@" "$LANES" register >/dev/null 2>&1
}

# two_projects: repositories A and B, each with a lead and a lane registered from it.
two_projects() {
  local p
  for p in A B; do
    git init -q -b main "$LANES_TEST_TMP/$p"
    git -C "$LANES_TEST_TMP/$p" commit -q --allow-empty -m init
  done
  start_in "$LANES_TEST_TMP/A" leadA sLA %1 LANES_ROLE=lead
  start_in "$LANES_TEST_TMP/A" alphaA sa %11
  start_in "$LANES_TEST_TMP/B" leadB sLB %2 LANES_ROLE=lead
  start_in "$LANES_TEST_TMP/B" betaB sb %21
}

@test "away off: the ask hook prints nothing and allows the call" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  run ask s1
  assert_success
  assert_output ""
}

@test "away on: the project's lane and its lead are denied, with a reason that points at morning.md" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  hook_json SessionStart sl boss startup | TMUX_PANE=%9 LANES_ROLE=lead "$LANES" register >/dev/null
  TMUX_PANE=%9 run "$LANES" away on
  assert_success
  for sid in s1 sl; do
    run ask "$sid"
    assert_success
    out="$output"
    run jq -r '.hookSpecificOutput | [.hookEventName, .permissionDecision] | join(" ")' <<<"$out"
    assert_output "PreToolUse deny"
    run jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out"
    assert_output --partial "$WORK/.lanes/morning.md"
    assert_output --partial "human's own message"
  done
}

@test "away mode is per project: lead A's away refuses A's sessions only, never B's or an unregistered session" {
  two_projects
  run bash -c "cd '$LANES_TEST_TMP/B' && TMUX_PANE=%1 '$LANES' away on"
  assert_success
  assert_output --partial "away mode on for $LANES_TEST_TMP/A/.git"
  run decision sa "$LANES_TEST_TMP/A"
  assert_output deny
  run decision sLA "$LANES_TEST_TMP/A"
  assert_output deny
  run decision sb "$LANES_TEST_TMP/B"
  assert_output allow
  run decision sLB "$LANES_TEST_TMP/B"
  assert_output allow
  # A session in project A that is not registered (no --name, or another tool's session) still asks.
  run decision stranger "$LANES_TEST_TMP/A"
  assert_output allow
  run bash -c "cd '$LANES_TEST_TMP/B' && TMUX_PANE=%2 '$LANES' away status"
  assert_output "away mode off for $LANES_TEST_TMP/B/.git"
  run bash -c "cd '$LANES_TEST_TMP/B' && TMUX_PANE=%2 '$LANES' away off"
  run decision sa "$LANES_TEST_TMP/A"
  assert_output deny
  run bash -c "cd '$LANES_TEST_TMP/A' && '$LANES' away off"
  run decision sa "$LANES_TEST_TMP/A"
  assert_output allow
}

@test "away off lifts it, and status reports both states" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  "$LANES" away on >/dev/null
  run "$LANES" away status
  assert_output --partial "away mode on since"
  assert_output --partial "for $WORK/.git"
  "$LANES" away off >/dev/null
  run "$LANES" away status
  assert_output "away mode off for $WORK/.git"
  run ask s1
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
  f="$(bash -c 'source "$1"; away_file "$2"' _ "$LANES" "$WORK")"
  run jq -r '[.set_by, (.since | test("^[0-9]{4}-")), .project] | @json' "$f"
  assert_output "[\"lead\",true,\"$WORK\"]"
  run "$LANES" away status
  assert_output --regexp "away mode on since [0-9T:Z-]+, set by lead, for $WORK"
  "$LANES" away on >/dev/null
  run jq -r .set_by "$f"
  assert_output "outside a lane pane"
}
