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

@test "bin works with no CLAUDE_* variables and no LANES_DATA_DIR: state goes under XDG_STATE_HOME" {
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

@test "a stale index of a cleared session no longer resolves: its Stop changes nothing" {
  register_lane alpha s1 %7 >/dev/null
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  jq -nc '{session_id:"s2",session_title:"alpha",prompt:"x"}' | "$LANES" hook prompt
  printf 'alpha\n' >"$LANES_DATA_DIR/sessions/s1"
  jq -nc '{session_id:"s1",background_tasks:[]}' | "$LANES" hook stop
  run state alpha .busy
  assert_output true
  jq -nc '{session_id:"s2",background_tasks:[]}' | "$LANES" hook stop
  run state alpha .busy
  assert_output false
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

@test "a dead pane's lane name is taken over by the new session" {
  register_lane alpha s1 %98
  run register_lane alpha s2 %99
  assert_success
  run reg alpha .tmux_pane
  assert_output %99
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
