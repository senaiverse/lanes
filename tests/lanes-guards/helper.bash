# Shared setup for the lanes-guards suite: a temp data dir with a fixture registry and session index, and PreToolUse stdin
# as a live `claude -p` probe showed it: session_id, cwd, tool_name, tool_input, and no session_title.

load ../helpers/common

# shellcheck disable=SC2034 # used by the suites that load this helper
GUARD="$BATS_TEST_DIRNAME/../../plugins/lanes-guards/bin/lanes-guard"

setup() {
  lanes_test_setup
  PROJECT="$LANES_TEST_TMP/project"
  mkdir -p "$PROJECT/.lanes" "$LANES_DATA_DIR/lanes"
  export CLAUDE_PROJECT_DIR="$PROJECT"
  unset CLAUDE_PLUGIN_OPTION_LEAD_ONLY_COMMANDS CLAUDE_PLUGIN_OPTION_PLAN_MARKER
  register lead lead sid-lead
  register lane1 lane sid-lane1
}

teardown() {
  lanes_test_teardown
}

# register <lane> <role> <session_id>: a registry file and its session index line, as CONVENTIONS.md "State" defines them.
register() {
  mkdir -p "$LANES_DATA_DIR/sessions"
  echo "$1" >"$LANES_DATA_DIR/sessions/$3"
  jq -n --arg lane "$1" --arg role "$2" --arg sid "$3" \
    '{lane:$lane,session_id:$sid,role:$role,tmux_pane:"%1",cwd:"/x",used_pct:null,clear_ready:false,updated_at:"2026-10-22T10:00:00Z"}' \
    >"$LANES_DATA_DIR/lanes/$1.json"
}

# write_guards <dir> <text>: a project's .lanes/guards.md.
write_guards() {
  mkdir -p "$1/.lanes"
  printf '%s\n' "$2" >"$1/.lanes/guards.md"
}

# bash_input <session_id> <command> [cwd]: PreToolUse stdin for a Bash call.
bash_input() {
  jq -nc --arg sid "$1" --arg cmd "$2" --arg cwd "${3:-$PROJECT}" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}'
}

# file_input <tool_name> <session_id> <path> <cwd>: PreToolUse stdin for Edit, Write or NotebookEdit.
file_input() {
  local field=file_path
  [ "$1" = NotebookEdit ] && field=notebook_path
  jq -nc --arg tool "$1" --arg sid "$2" --arg path "$3" --arg cwd "$4" --arg field "$field" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{($field):$path}}'
}

# message_input <session_id> <message>: PreToolUse stdin for SendMessage.
message_input() {
  jq -nc --arg sid "$1" --arg msg "$2" \
    '{session_id:$sid,cwd:"/x",hook_event_name:"PreToolUse",tool_name:"SendMessage",tool_input:{to:"lead",message:$msg}}'
}

# run_guard <guard name> <stdin text>: runs the guard with the stdin and keeps stdout in $output, stderr in $stderr.
run_guard() {
  local name="$1" input="$2"
  run --separate-stderr "$GUARD" "$name" <<<"$input"
}

# assert_denied: exit 0 plus the PreToolUse deny JSON on stdout; an optional text must be in the reason.
assert_denied() {
  [ "$status" -eq 0 ] || { echo "exit $status; stderr: $stderr"; return 1; }
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ] || { echo "not denied; stdout: $output; stderr: $stderr"; return 1; }
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = PreToolUse ] || return 1
  if [ -n "${1:-}" ]; then
    local reason
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
    [[ "$reason" == *"$1"* ]] || { echo "reason lacks '$1': $reason"; return 1; }
  fi
}

# assert_untouched: the guard stayed silent and exited 0, which hands the call to the normal permission flow.
assert_untouched() {
  [ "$status" -eq 0 ] || { echo "exit $status; stderr: $stderr"; return 1; }
  [ -z "$output" ] || { echo "unexpected stdout: $output"; return 1; }
}

# bash_denied <session_id> <command> [cwd]: runs the lead-only guard and asserts a denial.
bash_denied() {
  run_guard lead-only "$(bash_input "$@")"
  assert_denied "lead-only" || { echo "command: $2"; return 1; }
}

# bash_untouched <session_id> <command> [cwd]: runs the lead-only guard and asserts silence.
bash_untouched() {
  run_guard lead-only "$(bash_input "$@")"
  assert_untouched || { echo "command: $2"; return 1; }
}

# make_repo: a main checkout with one linked worktree for lane1 and one nested inside the main checkout.
make_repo() {
  REPO="$LANES_TEST_TMP/repo"
  WT="$LANES_TEST_TMP/wt-lane1"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/src"
  echo one >"$REPO/README.md"
  echo two >"$REPO/src/app.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  git -C "$REPO" worktree add -q "$WT" -b lane1
  git -C "$REPO" worktree add -q "$REPO/.wt/nested" -b nested
  REPO="$(cd -P "$REPO" && pwd -P)"
  WT="$(cd -P "$WT" && pwd -P)"
}
