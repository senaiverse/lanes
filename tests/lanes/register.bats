#!/usr/bin/env bats
# Public seam: `lanes register`, the SessionStart hook. It keys the registry by lane name and never breaks start-up.

load helper

@test "register writes the registry entry keyed by session_title with pane, cwd and session id" {
  run register_lane alpha s1 %7
  assert_success
  run jq -c '{lane,session_id,role,tmux_pane,cwd,used_pct,clear_ready}' "$LANES_DATA_DIR/lanes/alpha.json"
  assert_output "{\"lane\":\"alpha\",\"session_id\":\"s1\",\"role\":\"lane\",\"tmux_pane\":\"%7\",\"cwd\":\"$WORK\",\"used_pct\":null,\"clear_ready\":false}"
  run reg alpha .updated_at
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

@test "bin works with no LANES_DATA_DIR: state goes under XDG_STATE_HOME" {
  unset LANES_DATA_DIR
  export XDG_STATE_HOME="$LANES_TEST_TMP/xdg"
  run register_lane alpha s1 %7
  assert_success
  assert [ -f "$XDG_STATE_HOME/lanes/lanes/alpha.json" ]
  run "$LANES" status
  assert_success
  assert_output --partial alpha
}

@test "register_rekeys_session_on_clear: the same lane keeps one file and takes the new session id" {
  register_lane alpha s1 %7
  jq '.used_pct = 55' "$LANES_DATA_DIR/lanes/alpha.json" >"$LANES_TEST_TMP/x" && mv "$LANES_TEST_TMP/x" "$LANES_DATA_DIR/lanes/alpha.json"
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  run reg alpha .session_id
  assert_output s2
  run reg alpha .used_pct
  assert_output null
  run ls "$LANES_DATA_DIR/lanes"
  assert_output "alpha.json
state"
}

@test "the session index is written on register and replaced on clear" {
  register_lane alpha s1 %7 >/dev/null
  run cat "$LANES_DATA_DIR/sessions/s1"
  assert_output alpha
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  run cat "$LANES_DATA_DIR/sessions/s2"
  assert_output alpha
  assert [ ! -e "$LANES_DATA_DIR/sessions/s1" ]
}

@test "a stale index of a cleared session no longer resolves: its prompt changes nothing" {
  register_lane alpha s1 %7 >/dev/null
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  jq -nc '{session_id:"s2",session_title:"alpha",prompt:"x"}' | "$LANES" hook prompt
  printf 'alpha\n' >"$LANES_DATA_DIR/sessions/s1"
  jq -nc '{session_id:"s1",prompt:"/goal old"}' | "$LANES" hook prompt
  run state alpha '[.session_id, .prompts, .last_command] | @json'
  assert_output '["s2",1,null]'
}

@test "register records Claude Code's pid from CLAUDE_PID, and the transcript path from the hook input" {
  jq -nc --arg c "$WORK" '{session_id:"s1",session_title:"alpha",cwd:$c,source:"startup",transcript_path:"/t/s1.jsonl"}' |
    CLAUDE_PID=4242 CLAUDE_CODE_SESSION_ID=s1 TMUX_PANE=%7 "$LANES" register >/dev/null
  run reg alpha '.claude_pid | [., type] | @json'
  assert_output '[4242,"number"]'
  run state alpha .transcript
  assert_output /t/s1.jsonl
}

@test "no CLAUDE_PID, or one that is not a pid, refuses registration loudly and writes nothing" {
  for v in "" "abc" "0" "-3"; do
    run bash -c "hook_input='$(hook_json SessionStart s1 alpha startup)'; CLAUDE_PID='$v' TMUX_PANE=%7 '$LANES' register <<<\"\$hook_input\""
    assert_success
    assert_output --partial "CLAUDE_PID is '$v'"
    assert_output --partial "not registered"
    assert [ ! -e "$LANES_DATA_DIR/lanes/alpha.json" ]
  done
  run bash -c "env -u CLAUDE_PID TMUX_PANE=%7 '$LANES' register <<<'$(hook_json SessionStart s1 alpha startup)'"
  assert_output --partial "CLAUDE_PID is ''"
  assert [ ! -e "$LANES_DATA_DIR/lanes/alpha.json" ]
}

@test "after --continue or --resume the hook input's session_id is registered, whatever CLAUDE_CODE_SESSION_ID holds" {
  for src in resume startup; do
    run bash -c "CLAUDE_CODE_SESSION_ID=startup-id TMUX_PANE=%7 '$LANES' register <<<'$(hook_json SessionStart s1 alpha "$src")'"
    assert_success
    refute_output --partial "not registered"
    run reg alpha .session_id
    assert_output s1
  done
}

@test "register records the hook's CLAUDE_CONFIG_DIR, or null when Claude Code runs with the default ~/.claude" {
  CLAUDE_CONFIG_DIR=/lane/profile register_lane alpha s1 %7 >/dev/null
  run reg alpha .claude_config_dir
  assert_output /lane/profile
  hook_json SessionStart s2 alpha clear | env -u CLAUDE_CONFIG_DIR TMUX_PANE=%7 "$LANES" register >/dev/null
  run reg alpha '.claude_config_dir | @json'
  assert_output null
}

@test "a session id that is not a safe file name writes no index" {
  run register_lane alpha '../../x' %7
  assert_success
  assert [ ! -e "$LANES_DATA_DIR/x" ]
  run bash -c "ls -A '$LANES_DATA_DIR/sessions' 2>/dev/null"
  assert_output ""
}

@test "register_without_tmux_pane_explains: no TMUX_PANE registers with a null pane and says why, exit 0" {
  run register_lane alpha s1 ""
  assert_success
  assert_output --partial 'systemMessage'
  assert_output --partial 'TMUX_PANE'
  run reg alpha .tmux_pane
  assert_output null
}

@test "missing session_title: exit 0, no registry entry, a message naming claude --name" {
  run bash -c "jq -nc '{hook_event_name:\"SessionStart\",source:\"startup\",session_id:\"s1\",cwd:\"/tmp\"}' | '$LANES' register"
  assert_success
  assert_output --partial 'claude --name'
  run ls "$LANES_DATA_DIR/lanes"
  refute_output --partial '.json'
}

@test "input that is not JSON: exit 0 with a message on stderr" {
  run bash -c "printf 'garbage' | '$LANES' register"
  assert_success
  assert_output --partial 'lanes: hook input'
}

@test "an invalid lane name is refused without a write" {
  run register_lane '../evil' s1 %1
  assert_success
  assert_output --partial 'lane name'
  assert [ ! -e "$LANES_DATA_DIR/evil.json" ]
}

@test "two_lanes_same_name_refused: a second live pane with the same name does not take the entry" {
  make_repo
  start_fake alpha
  first="$PANE"
  run register_lane alpha other-session %99
  assert_success
  assert_output --partial 'already in use'
  run reg alpha .tmux_pane
  assert_output "$first"
}

@test "a lane whose Claude Code a human stopped (Ctrl-Z) keeps its name: a new session does not take it" {
  make_repo
  shell_pane
  fake_from_shell alpha "bash '$LANES_TEST_TMP/run-fake' alpha"
  first="$PANE"
  stop_fake
  run register_lane alpha other-session %99
  kill -CONT "$FAKE_PID"
  assert_success
  assert_output --partial 'already in use'
  run reg alpha .tmux_pane
  assert_output "$first"
}

@test "a dead pane's lane name is taken over by the new session" {
  register_lane alpha s1 %98
  run register_lane alpha s2 %99
  assert_success
  run reg alpha .tmux_pane
  assert_output %99
}

# strip_entry <jq filter>: rewrite alpha's registry entry, as an older lanes version or a test of it would have left it.
strip_entry() { local f="$LANES_DATA_DIR/lanes/alpha.json"; jq -c "$1" "$f" >"$f.x" && mv "$f.x" "$f"; }

@test "an entry with no Claude Code pid keeps its name while its pane runs the process it registered from" {
  make_repo
  start_fake alpha
  first="$PANE"
  for filter in 'del(.claude_pid)' 'del(.tmux_pid, .pane_pid)'; do
    strip_entry "$filter"
    run register_lane alpha other-session %99
    assert_success
    assert_output --partial "recorded no Claude Code pid: this session was not registered"
    assert_output --partial "restart it there as 'claude --name alpha'"
    assert_output --partial "close pane $first or delete $LANES_DATA_DIR/lanes/alpha.json"
    run reg alpha .tmux_pane
    assert_output "$first"
  done
}

@test "an entry with no Claude Code pid whose pane now runs another process is taken over" {
  make_repo
  start_fake alpha
  strip_entry 'del(.claude_pid) | .pane_pid = 1'
  run register_lane alpha other-session %99
  assert_success
  run reg alpha .tmux_pane
  assert_output %99
}

@test "a name check that fails is a refusal, never a pass: the new session is not registered and is told why" {
  make_repo
  start_fake alpha
  first="$PANE"
  jq_shim '.session_id, (.tmux_pane // "")' 1+
  PATH="$LANES_TEST_TMP/shim:$PATH" run register_lane alpha other-session %99
  assert_success
  assert_output --partial "check failed: identity_problem"
  assert_output --partial "this session was not registered"
  run reg alpha .tmux_pane
  assert_output "$first"
}

@test "registry_half_written_is_rejected: a corrupt entry is replaced on register and the hook says so" {
  mkdir -p "$LANES_DATA_DIR/lanes"
  printf '{"lane":"alpha","sess' >"$LANES_DATA_DIR/lanes/alpha.json"
  run register_lane alpha s1 %7
  assert_success
  assert_output --partial 'corrupt'
  run reg alpha .session_id
  assert_output s1
}

@test "LANES_ROLE=lead registers a lead, and the role survives a clear" {
  hook_json SessionStart s1 boss startup | TMUX_PANE=%1 LANES_ROLE=lead "$LANES" register
  hook_json SessionStart s2 boss clear | TMUX_PANE=%1 "$LANES" register >/dev/null
  run reg boss .role
  assert_output lead
}

@test "plugin options reach the hook and are recorded for bin/ commands" {
  register_lane alpha s1 %7 >/dev/null
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_OPTION_THRESHOLD=55 CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=journal "$LANES" register
  run jq -c . "$LANES_DATA_DIR/lanes/state/config.json"
  assert_output '{"threshold":55,"journal_dir":"journal"}'
}

@test "register refreshes the stable statusline link under the data dir when the plugin root is known" {
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_ROOT="$LANES_REPO_ROOT/plugins/lanes" "$LANES" register
  run readlink "$LANES_DATA_DIR/lanes-statusline"
  assert_output "$LANES_REPO_ROOT/plugins/lanes/bin/lanes-statusline"
}

ctx_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }

@test "every start states the session's role to the model: a lane on startup and resume, the lead too" {
  run bash -c "$(declare -f ctx_of); '$LANES' register 2>/dev/null <<<'$(hook_json SessionStart s1 alpha startup)' | ctx_of"
  assert_output --partial 'you are lane "alpha"'
  assert_output --partial "lane skill"
  run bash -c "$(declare -f ctx_of); '$LANES' register 2>/dev/null <<<'$(hook_json SessionStart s1 alpha resume)' | ctx_of"
  assert_output --partial 'you are lane "alpha"'
  run bash -c "$(declare -f ctx_of); LANES_ROLE=lead '$LANES' register 2>/dev/null <<<'$(hook_json SessionStart sl boss startup)' | ctx_of"
  assert_output --partial 'you are the lead "boss"'
  assert_output --partial "lead skill"
}

@test "after a clear the role is stated once, in the RESUME context" {
  register_lane alpha s1 %7 >/dev/null
  ctx="$(hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register 2>/dev/null | ctx_of)"
  [ "$(grep -o 'you are lane "alpha"' <<<"$ctx" | wc -l | tr -d ' ')" = 1 ]
}

# clear_ctx_with <shell code>: lane alpha's SessionStart(clear) context after the code has run in the sourced bin/lanes
# (to make one of its checks fail). The caller has written a valid RESUME block.
clear_ctx_with() {
  bash -c "source \"\$1\"; $1; TMUX_PANE=%7 cmd_register 2>/dev/null" _ "$LANES" \
    <<<"$(hook_json SessionStart "s-$RANDOM" alpha clear)" | ctx_of
}

@test "a RESUME check that fails is reported as a problem in the clear context, never read as a clean block" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  run clear_ctx_with ':'
  refute_output --partial "The block has problems"
  run clear_ctx_with 'goal_problem() { return 1; }'
  assert_output --partial "The block has problems: check failed: goal_problem"
  run clear_ctx_with 'resume_problems() { return 1; }'
  assert_output --partial "The block has problems: check failed: resume_problems"
}

@test "goal_problem fails, never passes, when it cannot count the text" {
  run bash -c 'source "$1"; char_count() { return 1; }; if goal_problem "ship it"; then echo passed; else echo "rc=$?"; fi' _ "$LANES"
  assert_output "rc=1"
}

@test "register garbage-collects session index files that no registry entry names" {
  register_lane alpha s1 %7 >/dev/null
  register_lane beta b1 %8 >/dev/null
  printf 'alpha\n' >"$LANES_DATA_DIR/sessions/old-alpha"
  printf 'ghost\n' >"$LANES_DATA_DIR/sessions/old-ghost"
  printf '\n' >"$LANES_DATA_DIR/sessions/empty"
  register_lane gamma g1 %9 >/dev/null
  run ls "$LANES_DATA_DIR/sessions"
  assert_output "b1
g1
s1"
}
