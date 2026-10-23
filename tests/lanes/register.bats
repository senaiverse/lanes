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

@test "a lane name is unique on this machine: a session of another project with a held name is refused, and told so" {
  make_repo
  start_fake alpha
  first="$PANE"
  mkdir -p "$LANES_TEST_TMP/other"
  run bash -c "jq -nc --arg c '$LANES_TEST_TMP/other' '{session_id:\"o1\",session_title:\"alpha\",cwd:\$c,source:\"startup\"}' | TMUX_PANE=%99 '$LANES' register"
  assert_success
  assert_output --partial "already in use by session"
  assert_output --partial "pane $first), which still runs: a lane name is unique on this machine, across projects"
  run reg alpha .cwd
  assert_output "$WORK"
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

@test "the same Claude Code process takes its own name back with a new session, in another pane or none" {
  register_lane alpha s1 %98
  run register_lane alpha s2 %99
  assert_success
  run reg alpha '[.tmux_pane, .session_id] | @json'
  assert_output '["%99","s2"]'
}

@test "a dead lane's name is taken over: its sessions file is left behind, but its process is gone" {
  make_repo
  start_fake alpha
  kill -9 "$FAKE_PID"
  wait_for "fake gone" bash -c "! kill -0 $FAKE_PID 2>/dev/null"
  [ -f "$(session_file)" ]
  run register_lane alpha other-session %99
  assert_success
  run reg alpha '[.tmux_pane, .session_id] | @json'
  assert_output '["%99","other-session"]'
}

# strip_entry <jq filter>: rewrite alpha's registry entry, as an older lanes version or a test of it would have left it.
strip_entry() { local f="$LANES_DATA_DIR/lanes/alpha.json"; jq -c "$1" "$f" >"$f.x" && mv "$f.x" "$f"; }

@test "an entry with no Claude Code pid proves no live session, so a new session takes the name" {
  make_repo
  start_fake alpha
  strip_entry 'del(.claude_pid)'
  run register_lane alpha other-session %99
  assert_success
  run reg alpha '[.tmux_pane, .session_id] | @json'
  assert_output '["%99","other-session"]'
}

@test "a name check that fails is a refusal, never a pass: the new session is not registered and is told why" {
  make_repo
  start_fake alpha
  first="$PANE"
  jq_shim '(.claude_pid // "" | tostring), .session_id' 1+
  PATH="$LANES_TEST_TMP/shim:$PATH" run register_lane alpha other-session %99
  assert_success
  assert_output --partial "check failed: reading the registry entry"
  assert_output --partial "this session was not registered"
  run reg alpha .tmux_pane
  assert_output "$first"
}

@test "a live lane on another tmux server keeps its name: a session on this server does not take it" {
  make_repo
  start_fake alpha
  first="$PANE"
  # A second private server (TMUX_TMPDIR is the test's own); its first pane id can equal the lane's own.
  tmux -L "$LANES_TMUX_SOCKET-other" new-session -d -s other -x 80 -y 20 "sleep 30"
  other_pane="$(tmux -L "$LANES_TMUX_SOCKET-other" display -p -t other '#{pane_id}')"
  run bash -c "LANES_TMUX_SOCKET='$LANES_TMUX_SOCKET-other' TMUX_PANE='$other_pane' '$LANES' register <<<'$(hook_json SessionStart o1 alpha startup)'"
  tmux -L "$LANES_TMUX_SOCKET-other" kill-server 2>/dev/null || true
  assert_success
  assert_output --partial "already in use by session"
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

@test "plugin options reach the hook and are recorded for bin/ commands, under the session's project" {
  register_lane alpha s1 %7 >/dev/null
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_OPTION_THRESHOLD=55 CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=journal "$LANES" register
  run jq -c . "$LANES_DATA_DIR/lanes/state/config.json"
  assert_output "{\"$WORK\":{\"threshold\":55,\"journal_dir\":\"journal\"}}"
}

# two_projects: repositories A, with a second worktree A-wt, and B. start_in <dir> <lane> <session> [source]
# [VAR=value...]: that lane's SessionStart from <dir>, with the given plugin options in its environment.
two_projects() {
  local p
  for p in A B; do
    git init -q -b main "$LANES_TEST_TMP/$p"
    git -C "$LANES_TEST_TMP/$p" commit -q --allow-empty -m init
  done
  git -C "$LANES_TEST_TMP/A" worktree add -q -b wt "$LANES_TEST_TMP/A-wt"
}
start_in() {
  local dir="$1" lane="$2" sid="$3" src="$4"
  shift 4
  jq -nc --arg s "$sid" --arg t "$lane" --arg c "$dir" --arg src "$src" '{session_id:$s,session_title:$t,cwd:$c,source:$src}' |
    env TMUX_PANE="%$RANDOM" "$@" "$LANES" register 2>/dev/null
}

@test "two projects keep their own journal_dir: each lane's journal is its project's, whichever session started last" {
  two_projects
  start_in "$LANES_TEST_TMP/A" alpha a1 startup CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=ja >/dev/null
  start_in "$LANES_TEST_TMP/B" beta b1 startup CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=jb >/dev/null
  run jq -c 'keys' "$LANES_DATA_DIR/lanes/state/config.json"
  assert_output "[\"$LANES_TEST_TMP/A/.git\",\"$LANES_TEST_TMP/B/.git\"]"
  run bash -c "cd '$LANES_TEST_TMP/A' && '$LANES' journal-dir"
  assert_output "$LANES_TEST_TMP/A/ja"
  run bash -c "cd '$LANES_TEST_TMP/A-wt' && '$LANES' journal-dir"
  assert_output "$LANES_TEST_TMP/A-wt/ja"
  run bash -c "cd '$LANES_TEST_TMP/B' && '$LANES' journal-dir"
  assert_output "$LANES_TEST_TMP/B/jb"
  ctx="$(start_in "$LANES_TEST_TMP/A" alpha a2 clear | jq -r .hookSpecificOutput.additionalContext)"
  run echo "$ctx"
  assert_output --partial "No RESUME block was found at $LANES_TEST_TMP/A/ja/next-alpha.md"
}

@test "register keeps how each session began as start_source: startup, then resume, compact and fork, then clear" {
  register_lane alpha s1 %7 >/dev/null
  run state alpha .start_source
  assert_output startup
  for src in resume compact fork; do
    hook_json SessionStart s1 alpha "$src" | TMUX_PANE=%7 "$LANES" register >/dev/null
    run state alpha .start_source
    assert_output "$src"
  done
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  run state alpha .start_source
  assert_output clear
}

@test "only a clear turns a sending handshake into cleared: a new session that restarted, resumed or forked leaves it sending" {
  register_lane alpha s1 %7 >/dev/null
  f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq -c '.handshake = {state: "sending", session_id: "s1"}' "$f" >"$f.x" && mv "$f.x" "$f"
  for src in startup resume fork; do
    hook_json SessionStart "s-$src" alpha "$src" | TMUX_PANE=%7 "$LANES" register >/dev/null
    run state alpha '[.handshake.state, .session_id, .start_source] | @json'
    assert_output "[\"sending\",\"s-$src\",\"$src\"]"
  done
  hook_json SessionStart s3 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  run state alpha '[.handshake.state, .handshake.cleared_session, .start_source] | @json'
  assert_output '["cleared","s3","clear"]'
}

@test "/branch in the lane's own pane registers the new session, while the sessions file still names the old one" {
  make_repo
  start_fake alpha
  old="$(reg alpha .session_id)"
  # During the SessionStart(fork) hook of /branch the process is the same and its sessions file lags (Claude Code 2.1.309).
  [ "$(sess .sessionId)" = "$old" ]
  run bash -c "TMUX_PANE='$PANE' CLAUDE_PID='$FAKE_PID' '$LANES' register <<<'$(hook_json SessionStart b1 alpha fork)'"
  assert_success
  refute_output --partial "already in use"
  run reg alpha '[.session_id, .tmux_pane, (.claude_pid | tostring)] | @json'
  assert_output "[\"b1\",\"$PANE\",\"$FAKE_PID\"]"
  run state alpha .start_source
  assert_output fork
}

@test "a nested claude --name <lane> from the lane's own Bash tool (same pane, new process) never takes the name" {
  make_repo
  start_fake alpha
  sid="$(reg alpha .session_id)"
  sleep 30 &
  nested=$!
  for src in startup fork; do
    run bash -c "TMUX_PANE='$PANE' CLAUDE_PID='$nested' '$LANES' register <<<'$(hook_json SessionStart n-$src alpha $src)'"
    assert_success
    assert_output --partial "already in use by session $sid"
    run reg alpha .session_id
    assert_output "$sid"
  done
  kill "$nested"
  run state alpha .start_source
  assert_output startup
}

# other_pid_register <session id> [source] [PATH prefix]: a SessionStart for alpha from another live process in the
# lane's pane; sets OUTPUT and STATUS as run does.
other_pid_register() {
  local other
  sleep 30 &
  other=$!
  run bash -c "PATH='${3:+$3:}$PATH' TMUX_PANE='$PANE' CLAUDE_PID='$other' '$LANES' register <<<'$(hook_json SessionStart "$1" alpha "${2:-startup}")'"
  kill "$other"
}

@test "a second process resuming the lane's own session id (no --fork-session) is refused; the same process registers" {
  make_repo
  start_fake alpha
  sid="$(reg alpha .session_id)"
  for src in resume startup; do
    other_pid_register "$sid" "$src"
    assert_success
    assert_output --partial "already in use by session $sid"
    run reg alpha '(.claude_pid | tostring)'
    assert_output "$FAKE_PID"
  done
  run bash -c "TMUX_PANE='$PANE' CLAUDE_PID='$FAKE_PID' '$LANES' register <<<'$(hook_json SessionStart "$sid" alpha compact)'"
  assert_success
  refute_output --partial "lane name"
  run state alpha .start_source
  assert_output compact
}

@test "a name check that cannot decide never frees the name: a partly written or missing sessions file, a failing ps" {
  make_repo
  start_fake alpha
  sid="$(reg alpha .session_id)"
  f="$(session_file)"
  cp "$f" "$LANES_TEST_TMP/sess"
  for bad in '{"pid":' 'not json' '{"pid":1}' ''; do
    printf '%s' "$bad" >"$f"
    other_pid_register o1
    assert_success
    assert_output --partial "could not be checked against its registered session"
    assert_output --partial "restart this session"
    run reg alpha .session_id
    assert_output "$sid"
  done
  # No file while the registered process still runs proves nothing either.
  rm -f "$f"
  other_pid_register o1
  assert_output --partial "could not be checked against its registered session"
  cp "$LANES_TEST_TMP/sess" "$f"
  # A ps that fails for the registered Claude Code only, in the non-Linux form of the start time read (uname answers
  # Darwin); lanes still names itself, so a symlink mutex (macOS, no flock) is taken.
  ps_fails_for "$FAKE_PID"
  export LANES_NO_FLOCK=1
  other_pid_register o1 startup "$LANES_TEST_TMP/shim"
  refute_output --partial "registry lock"
  assert_output --partial "(check failed: lane_session: the start time of pid $FAKE_PID could not be read"
  run reg alpha .session_id
  assert_output "$sid"
}

@test "register records Claude Code's start time, read by proc_start, beside its pid" {
  make_repo
  start_fake alpha
  run reg alpha .claude_start
  refute_output null
  assert_output "$(bash -c 'source "$1"; proc_start "$2"' _ "$LANES" "$FAKE_PID")"
}

@test "a pid now running another process (a start time other than the recorded one) is proven gone, with no sessions file or a foreign one" {
  make_repo
  start_fake alpha
  f="$(session_file)"
  cp "$f" "$LANES_TEST_TMP/sess"
  sid="$(jq -r .sessionId "$LANES_TEST_TMP/sess")"
  for kind in missing foreign; do
    case "$kind" in
      missing) rm -f "$f" ;;
      foreign) jq -c '.pid = 1' "$LANES_TEST_TMP/sess" >"$f" ;;
    esac
    # The recorded start time unchanged stays undecided, and so does an entry written before the time was recorded.
    for rec in same none; do
      [[ "$rec" == none ]] && strip_entry 'del(.claude_start)'
      other_pid_register "o-$kind-$rec"
      assert_output --partial "could not be checked against its registered session"
      run reg alpha .session_id
      assert_output "$sid"
    done
    strip_entry '.claude_start = "1"'
    other_pid_register "o-$kind"
    assert_success
    run reg alpha .session_id
    assert_output "o-$kind"
    # The fake's own process takes its lane back, recording its start time again, for the next case.
    bash -c "TMUX_PANE='$PANE' CLAUDE_PID='$FAKE_PID' '$LANES' register <<<'$(hook_json SessionStart "$sid" alpha startup)'" >/dev/null 2>&1
  done
}

@test "a name the old session is proven not to hold is free: another session in its file, a stale procStart, a gone pid" {
  make_repo
  for proof in sid procstart gone; do
    start_fake alpha
    case "$proof" in
      sid) edit_session '.sessionId = "someone-else"' ;;
      procstart) edit_session '.procStart = "1"' ;;
      gone)
        kill -9 "$FAKE_PID"
        wait_for "gone" bash -c "! kill -0 $FAKE_PID 2>/dev/null"
        rm -f "$(session_file)"
        ;;
    esac
    other_pid_register "new-$proof"
    assert_success
    run reg alpha .session_id
    assert_output "new-$proof"
    lanes_tmux kill-session -t alpha 2>/dev/null || true
    rm -f "$LANES_DATA_DIR/lanes/alpha.json"
  done
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

@test "a register that cannot name itself for the symlink mutex says so, never 'locked by another lanes process'" {
  ps_fails_for self
  sleep 30 &
  cpid=$!
  run bash -c "PATH='$LANES_TEST_TMP/shim:$PATH' LANES_NO_FLOCK=1 CLAUDE_PID=$cpid TMUX_PANE=%7 '$LANES' register <<<'$(hook_json SessionStart s1 alpha startup)'"
  kill "$cpid"
  assert_success
  assert_output --regexp "registry lock not taken: the start time of pid [0-9]+, this lock's holder, could not be read"
  refute_output --partial "another"
  assert [ ! -e "$LANES_DATA_DIR/lanes/alpha.json" ]
}

@test "a new session on a pane takes it from the lane that held it: that lane has no pane and is no longer clear-ready" {
  register_lane alpha s1 %7 >/dev/null
  strip_entry '.clear_ready = true'
  run register_lane beta b1 %7
  assert_output --partial "pane %7 was registered to lane 'alpha', which now has no pane"
  run reg alpha '[.tmux_pane, .clear_ready] | @json'
  assert_output '[null,false]'
  run reg beta .tmux_pane
  assert_output %7
}

@test "a new session of a lane resets clear_ready; the same session registering again keeps it" {
  register_lane alpha s1 %7 >/dev/null
  strip_entry '.clear_ready = true'
  hook_json SessionStart s1 alpha resume | TMUX_PANE=%7 "$LANES" register >/dev/null 2>&1
  run reg alpha .clear_ready
  assert_output true
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null 2>&1
  run reg alpha .clear_ready
  assert_output false
}

# server_pane <socket>: start a tmux server on <socket> whose first pane (%0) prints its own TMUX, and set SRV_TMUX to it.
server_pane() {
  rm -f "$LANES_TEST_TMP/tmux-env"
  tmux -L "$1" new-session -d -s run -x 80 -y 20 "printf '%s %s\n' \"\$TMUX\" \"\$TMUX_PANE\" >'$LANES_TEST_TMP/tmux-env.x'; mv '$LANES_TEST_TMP/tmux-env.x' '$LANES_TEST_TMP/tmux-env'; sleep 60"
  wait_for "pane of $1" test -s "$LANES_TEST_TMP/tmux-env"
  read -r SRV_TMUX pane <"$LANES_TEST_TMP/tmux-env"
  [ "$pane" = %0 ]
}

# from <socket> <TMUX> <lanes args...>: run lanes as a command in that server's %0 does.
from() { local s="$1" t="$2"; shift 2; LANES_TMUX_SOCKET="$s" TMUX="$t" TMUX_PANE=%0 "$LANES" "$@"; }

@test "a second tmux server with the same %0 neither takes the lead's pane nor acts as the lead" {
  make_repo
  A="$LANES_TMUX_SOCKET" B="$LANES_TMUX_SOCKET-b"
  server_pane "$A"
  TA="$SRV_TMUX"
  server_pane "$B"
  TB="$SRV_TMUX"
  for order in lead-first lane-first; do
    rm -rf "$LANES_DATA_DIR/lanes"
    for who in $([[ $order == lead-first ]] && echo "lead laneb" || echo "laneb lead"); do
      if [[ "$who" == lead ]]; then
        LANES_ROLE=lead run from "$A" "$TA" register <<<"$(hook_json SessionStart sl lead startup)"
      else
        run from "$B" "$TB" register <<<"$(hook_json SessionStart sb laneb startup)"
      fi
      refute_output --partial "now has no pane"
    done
    run jq -r '"\(.lane) \(.tmux_pane) \(.tmux_pid)"' "$LANES_DATA_DIR/lanes/lead.json" "$LANES_DATA_DIR/lanes/laneb.json"
    assert_output "lead %0 $(tmux -L "$A" display -p '#{pid}')
laneb %0 $(tmux -L "$B" display -p '#{pid}')"
  done
  # From B's %0 the caller is laneb: not the lead, and away mode records laneb as its setter.
  run from "$B" "$TB" request laneb
  assert_failure
  assert_output --partial "only the lead requests a clear"
  run from "$B" "$TB" away on
  assert_success
  run jq -r .set_by "$(bash -c 'source "$1"; away_file "$2"' _ "$LANES" "$WORK/.git")"
  assert_output laneb
  # From A's %0 the caller is the lead.
  run from "$A" "$TA" request laneb
  refute_output --partial "only the lead"
  tmux -L "$B" kill-server 2>/dev/null || true
}

@test "a pane matches no lane when the caller's TMUX does not name a tmux server" {
  register_lane alpha s1 %7 >/dev/null
  for t in "" "garbage" "/s,x,0"; do
    run bash -c "TMUX='$t' TMUX_PANE=%7 '$LANES' clear-ready"
    assert_output --partial "cannot tell which lane this is"
  done
  # The server is TMUX's pid, read from the right of a socket path that holds commas, session -1 included.
  run bash -c "TMUX='/s,7,x,41,-1' TMUX_PANE=%7 '$LANES' register <<<'$(hook_json SessionStart s1 alpha startup)'"
  refute_output --partial "not tmux's"
  run reg alpha '.tmux_pid | @json'
  assert_output 41
  run bash -c "env -u TMUX TMUX_PANE=%7 '$LANES' register <<<'$(hook_json SessionStart s1 alpha startup)'"
  assert_output --partial "TMUX is '', not tmux's '<socket>,<server pid>,<session>'"
  run reg alpha '.tmux_pid | @json'
  assert_output null
  # An unknown server on both sides is no match.
  run bash -c "env -u TMUX TMUX_PANE=%7 '$LANES' clear-ready"
  assert_output --partial "cannot tell which lane this is"
}

# hook_with <jq object fields>: alpha's SessionStart input with the given fields over the usual ones.
hook_with() { jq -c --argjson o "$1" '. + $o' <<<"$(hook_json SessionStart s1 alpha startup)"; }

@test "a newline in any register field never shifts the next: cwd, transcript path and source are kept whole" {
  dir=$'/tmp/a\nb'
  run bash -c "TMUX_PANE=%7 '$LANES' register <<<'$(hook_with "$(jq -nc --arg c "$dir" '{cwd: $c, transcript_path: "/t/x\ny.jsonl", source: "start\nup"}')")'"
  assert_success
  refute_output --partial "not a JSON object"
  run reg alpha '.cwd | @json'
  assert_output '"/tmp/a\nb"'
  run state alpha '[.transcript, .start_source] | @json'
  assert_output '["/t/x\ny.jsonl","start\nup"]'
  # A title with a newline is an unusable lane name, said as such.
  run bash -c "TMUX_PANE=%7 '$LANES' register <<<'$(hook_with '{"session_title": "al\npha"}')'"
  assert_output --partial "lane name 'al"
  assert_output --partial "is not usable"
  refute_output --partial "not a JSON object"
}

@test "a newline in any prompt hook field never shifts the next, and a NUL in a prompt reads as U+FFFD" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id: "s1", session_title: "alpha", cwd: "/x\ny", prompt: "/goal one\ntwo", transcript_path: "/t/p\nq.jsonl"}' |
    "$LANES" hook prompt
  run state alpha '[.prompts, .last_command, .transcript] | @json'
  assert_output '[1,"/goal one\ntwo","/t/p\nq.jsonl"]'
  # A title with a newline names no lane, so the session index finds it.
  jq -nc '{session_id: "s1", session_title: "al\npha", prompt: "/x\u0000y"}' | "$LANES" hook prompt
  run state alpha '[.prompts, .last_command] | @json'
  assert_output "[2,\"/x$(printf '\357\277\275')y\"]"
}
