#!/usr/bin/env bats
# Public seams: `lanes-statusline` (writes used_pct), `lanes hook prompt`, and `lanes status` (context % with the
# threshold, activity from the sessions file, goal from the transcript, handshake). Context % has three states, never
# collapsed: a number, unknown and stale.

load helper
load lead

# statusline_input <lane> <session> <pct|null>
statusline_input() {
  jq -nc --arg n "$1" --arg s "$2" --argjson p "$3" '{session_name:$n,session_id:$s,context_window:{used_percentage:$p}}'
}

# sl <lane> <session> <pct> [command]: one status line update through the given command (default the plugin's).
sl() { statusline_input "$1" "$2" "$3" | "${4:-$STATUSLINE}"; }

# in_new_group <input file> <command...>: run the command in the background as the leader of a new process group, so a
# TERM to the group reaches every process of it. Job control (set -m) does that in Bash on Linux and macOS alike, where
# macOS has no setsid. Sets GROUP_PID.
in_new_group() {
  local in="$1"
  shift
  set -m
  "$@" <"$in" >/dev/null &
  GROUP_PID=$!
  set +m
}

@test "statusline records used_pct for the registered session and prints one line" {
  register_lane alpha s1 %7 >/dev/null
  run sl alpha s1 42.7
  assert_success
  assert_output "lanes alpha ctx 42%"
  run reg alpha .used_pct
  assert_output 42
}

@test "statusline through the stable link in the data dir finds the plugin" {
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_ROOT="$LANES_REPO_ROOT/plugins/lanes" "$LANES" register
  run sl alpha s1 10 "$LANES_DATA_DIR/lanes-statusline"
  assert_success
  assert_output "lanes alpha ctx 10%"
}

@test "old_session_pct_ignored_after_clear: a status line from the old session id does not write" {
  register_lane alpha s1 %7 >/dev/null
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register >/dev/null
  sl alpha s1 88 >/dev/null
  run reg alpha .used_pct
  assert_output null
}

@test "statusline with garbage input still prints a line and exits 0" {
  run bash -c "printf 'not json' | '$STATUSLINE'"
  assert_success
  assert_output "lanes ? ctx ?%"
}

@test "statusline never writes a corrupt registry entry and never fails on one" {
  mkdir -p "$LANES_DATA_DIR/lanes"
  printf '{"lane":' >"$LANES_DATA_DIR/lanes/alpha.json"
  run sl alpha s1 50
  assert_success
  run cat "$LANES_DATA_DIR/lanes/alpha.json"
  assert_output '{"lane":'
}

@test "statusline_cancelled_mid_write_leaves_old_file_intact: TERM at random points never leaves half a file" {
  register_lane alpha s1 %7 >/dev/null
  for i in $(seq 1 60); do
    statusline_input alpha s1 "$i" >"$LANES_TEST_TMP/in"
    in_new_group "$LANES_TEST_TMP/in" "$STATUSLINE"
    sleep "0.0$((RANDOM % 4))$((RANDOM % 10))"
    kill -TERM -- "-$GROUP_PID" 2>/dev/null || true
    wait "$GROUP_PID" 2>/dev/null || true
    jq -e '.lane == "alpha" and .session_id == "s1"' "$LANES_DATA_DIR/lanes/alpha.json" >/dev/null
  done
  run bash -c "ls -A '$LANES_DATA_DIR/lanes' | grep -c '^\.tmp' || true"
  assert_output 0
}

@test "a status line cancelled between its temp write and the rename leaves no temp file and the old entry" {
  register_lane alpha s1 %7 >/dev/null
  mkdir -p "$LANES_TEST_TMP/slow"
  printf '#!/usr/bin/env bash\nsleep 2\nexec %s "$@"\n' "$(command -v mv)" >"$LANES_TEST_TMP/slow/mv"
  chmod +x "$LANES_TEST_TMP/slow/mv"
  statusline_input alpha s1 61 >"$LANES_TEST_TMP/in"
  in_new_group "$LANES_TEST_TMP/in" env PATH="$LANES_TEST_TMP/slow:$PATH" "$STATUSLINE"
  wait_for "temp file" bash -c "ls -A '$LANES_DATA_DIR/lanes' | grep -q '^\.tmp'"
  [ "$(ps -o pgid= -p "$GROUP_PID" | tr -d ' ')" = "$GROUP_PID" ]
  kill -TERM -- "-$GROUP_PID"
  wait "$GROUP_PID" 2>/dev/null || true
  run reg alpha .used_pct
  assert_output null
  run bash -c "ls -A '$LANES_DATA_DIR/lanes' | grep -c '^\.tmp' || true"
  assert_output 0
}

@test "status_marks_null_pct_unknown_not_zero" {
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" status
  assert_success
  assert_output --partial "ctx unknown"
  refute_output --partial "ctx 0%"
  run bash -c "'$LANES' status --json | jq -r '.[0].ctx'"
  assert_output unknown
}

@test "status_marks_old_file_stale: a percentage older than LANES_PCT_STALE is flagged" {
  register_lane alpha s1 %7 >/dev/null
  sl alpha s1 30 >/dev/null
  run "$LANES" status
  refute_output --partial stale
  jq '.pct_at -= 1000' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run "$LANES" status
  assert_output --partial "ctx 30% stale"
}

@test "threshold_at_exactly_70_triggers, and 69 does not" {
  register_lane alpha s1 %7 >/dev/null
  sl alpha s1 69 >/dev/null
  run "$LANES" status
  refute_output --partial AT-THRESHOLD
  run sl alpha s1 70
  assert_output "lanes alpha ctx 70% at threshold"
  run "$LANES" status
  assert_output --partial "ctx 70% AT-THRESHOLD"
}

@test "the threshold comes from the recorded plugin option, and LANES_THRESHOLD overrides it" {
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_OPTION_THRESHOLD=50 "$LANES" register
  sl alpha s1 55 >/dev/null
  run "$LANES" status
  assert_output --partial "ctx 55% AT-THRESHOLD"
  run bash -c "'$LANES' status --json | jq -r '.[0].threshold'"
  assert_output 50
  LANES_THRESHOLD=60 run "$LANES" status
  refute_output --partial AT-THRESHOLD
}

@test "each lane's threshold is its own project's option, in status and in its status line, whichever started last" {
  mkdir -p "$LANES_TEST_TMP/A" "$LANES_TEST_TMP/B"
  for p in A:alpha:a1:50 B:beta:b1:90; do
    IFS=: read -r dir lane sid thr <<<"$p"
    jq -nc --arg s "$sid" --arg t "$lane" --arg c "$LANES_TEST_TMP/$dir" '{session_id:$s,session_title:$t,cwd:$c,source:"startup"}' |
      TMUX_PANE="%$thr" CLAUDE_PLUGIN_OPTION_THRESHOLD="$thr" "$LANES" register 2>/dev/null
  done
  run sl alpha a1 60
  assert_output "lanes alpha ctx 60% at threshold"
  run sl beta b1 60
  assert_output "lanes beta ctx 60%"
  run bash -c "cd '$LANES_TEST_TMP/A' && '$LANES' status --json | jq -c 'map([.lane, .threshold, .at_threshold])'"
  assert_output '[["alpha",50,true]]'
  run bash -c "cd '$LANES_TEST_TMP/B' && '$LANES' status --json | jq -c 'map([.lane, .threshold, .at_threshold])'"
  assert_output '[["beta",90,false]]'
  run bash -c "cd '$LANES_TEST_TMP/A' && '$LANES' status | grep '^alpha'"
  assert_output --partial "ctx 60% AT-THRESHOLD"
  run bash -c "cd '$LANES_TEST_TMP/B' && '$LANES' status | grep '^beta'"
  assert_output --partial "ctx 60%"
  refute_output --partial AT-THRESHOLD
}

# lead_and_lane <project dir> <lead> <lead pane> <lane>: a lead and a lane registered from that project.
lead_and_lane() {
  jq -nc --arg c "$1" --arg t "$2" '{session_id:("s-" + $t),session_title:$t,cwd:$c,source:"startup"}' |
    TMUX_PANE="$3" LANES_ROLE=lead "$LANES" register >/dev/null 2>&1
  jq -nc --arg c "$1" --arg t "$4" '{session_id:("s-" + $t),session_title:$t,cwd:$c,source:"startup"}' |
    TMUX_PANE="%9${3#%}" "$LANES" register >/dev/null 2>&1
}

@test "status lists the caller's project only: each lead sees its own lead and lanes, whatever directory it runs in" {
  for p in A B; do
    git init -q -b main "$LANES_TEST_TMP/$p"
    git -C "$LANES_TEST_TMP/$p" commit -q --allow-empty -m init
  done
  git -C "$LANES_TEST_TMP/A" worktree add -q -b wt "$LANES_TEST_TMP/A-wt"
  lead_and_lane "$LANES_TEST_TMP/A" leadA %1 alphaA
  lead_and_lane "$LANES_TEST_TMP/B" leadB %2 betaB
  # The lead's project is its registered one, even from the other project's directory.
  run bash -c "cd '$LANES_TEST_TMP/B' && TMUX_PANE=%1 '$LANES' status --json | jq -c 'map(.lane) | sort'"
  assert_output '["alphaA","leadA"]'
  run bash -c "cd '$LANES_TEST_TMP/A' && TMUX_PANE=%2 '$LANES' status --json | jq -c 'map(.lane) | sort'"
  assert_output '["betaB","leadB"]'
  run bash -c "cd '$LANES_TEST_TMP/A' && TMUX_PANE=%2 '$LANES' status"
  refute_output --partial alphaA
  refute_output --partial leadA
  # Outside a registered pane the project is the directory's; a worktree is its repository's project.
  run bash -c "cd '$LANES_TEST_TMP/A-wt' && '$LANES' status --json | jq -c 'map(.lane) | sort'"
  assert_output '["alphaA","leadA"]'
  mkdir -p "$LANES_TEST_TMP/C"
  run bash -c "cd '$LANES_TEST_TMP/C' && '$LANES' status"
  assert_output --partial "no lanes registered for $LANES_TEST_TMP/C"
}

@test "each timing and chunk variable, not a plain number in its range, is refused before the command reads it" {
  register_lane alpha s1 %7 >/dev/null
  for spec in LANES_CLEAR_TIMEOUT:0 LANES_PCT_STALE:0 LANES_SEND_GAP:0 LANES_REQUEST_TIMEOUT:-1 LANES_SEND_CHUNK:0 \
    LANES_CLEAR_TIMEOUT:3601 LANES_PCT_STALE:604801 LANES_REQUEST_TIMEOUT:604801 LANES_SEND_GAP:5.001 LANES_SEND_CHUNK:513; do
    for v in "${spec#*:}" abc 1e3 1.2.3 ' 5' 12x; do
      run env "${spec%%:*}=$v" "$LANES" status
      assert_failure 2
      assert_output --partial "${spec%%:*}=$v is not a"
    done
  done
  # A leading zero is decimal, never octal: 08 is eight seconds, not an arithmetic error.
  for ok in LANES_CLEAR_TIMEOUT=1 LANES_CLEAR_TIMEOUT=08 LANES_PCT_STALE=0900 LANES_PCT_STALE=604800 LANES_REQUEST_TIMEOUT=0 LANES_SEND_GAP=0.001 LANES_SEND_GAP=5 \
    LANES_SEND_CHUNK=1 LANES_SEND_CHUNK=0512; do
    run env "$ok" "$LANES" status
    assert_success
  done
}

@test "a bad timing or chunk variable stops lanes clear and lanes goal before any key reaches the lane" {
  ready_lane alpha
  before="$(cat "$LANES_DATA_DIR/lanes/state/alpha.json")"
  for bad in LANES_CLEAR_TIMEOUT=abc LANES_SEND_GAP=abc LANES_REQUEST_TIMEOUT=abc LANES_SEND_CHUNK=900; do
    run env "$bad" "$LANES" clear alpha
    assert_failure 2
    run env "$bad" "$LANES" goal alpha "ship it"
    assert_failure 2
  done
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
  refute pane_has '/clear'
  refute pane_has 'ship it'
  [ "$(cat "$LANES_DATA_DIR/lanes/state/alpha.json")" = "$before" ]
}

# tmux_v <tmux -V output>: tmux_check against that version line; prints ok or the refusal.
tmux_v() { bash -c 'source "$1"; V="$2"; tm() { echo "$V"; }; tmux_check && echo ok' _ "$LANES" "$1" 2>&1; }

@test "tmux openbsd-X.Y is an OpenBSD release: 6.6 (its tmux has 3.0's features) or newer passes, older is refused" {
  for v in "tmux openbsd-6.6" "tmux openbsd-6.10" "tmux openbsd-7.6" "tmux openbsd-10.0"; do
    run tmux_v "$v"
    assert_output ok
  done
  for v in "tmux openbsd-6.5" "tmux openbsd-5.9" "tmux openbsd-6.0"; do
    run tmux_v "$v"
    assert_failure 2
    assert_output --partial "$v is the tmux of OpenBSD"
    assert_output --partial "older than the tmux 3.0 of OpenBSD 6.6"
  done
  for v in "tmux openbsd-x.y" "tmux openbsd-6" "tmux foo-3.4"; do
    run tmux_v "$v"
    assert_failure 2
    assert_output --partial "not a tmux version"
  done
}

@test "empty journal and empty registry: status says how to start a lane" {
  run "$LANES" status
  assert_success
  assert_output --partial "no lanes registered for $WORK"
  run bash -c "'$LANES' status --json"
  assert_output "[]"
}

@test "a corrupt registry entry shows as an error row and does not hide the others" {
  register_lane beta s2 %8 >/dev/null
  printf '{"lane' >"$LANES_DATA_DIR/lanes/alpha.json"
  run "$LANES" status
  assert_success
  assert_output --partial "alpha	ERROR: corrupt registry entry"
  assert_output --partial beta
}

@test "hook prompt counts the prompt, keeps a slash command's first 200 characters, and prints nothing to the model" {
  register_lane alpha s1 %7 >/dev/null
  run bash -c "jq -nc '{session_id:\"s1\",session_title:\"alpha\",prompt:\"hi\"}' | '$LANES' hook prompt"
  assert_success
  assert_output ""
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"/goal ship it"}' | "$LANES" hook prompt
  run state alpha '[.prompts, .last_command, has("busy"), has("goal")] | @json'
  assert_output '[2,"/goal ship it",false,false]'
}

@test "a hook from an unregistered session changes nothing and exits 0" {
  register_lane alpha s1 %7 >/dev/null
  run bash -c "jq -nc '{session_id:\"other\",prompt:\"hi\"}' | '$LANES' hook prompt"
  assert_success
  run state alpha .prompts
  assert_output 0
}

@test "after /rename, to a free name or to another lane's, the session's prompts and context % still record under its lane" {
  register_lane alpha s1 %7 >/dev/null
  register_lane beta s2 %8 >/dev/null
  for title in renamed beta; do
    jq -nc --arg t "$title" '{session_id:"s1",session_title:$t,prompt:"hi"}' | "$LANES" hook prompt
  done
  run state alpha .prompts
  assert_output 2
  run state beta .prompts
  assert_output 0
  run sl renamed s1 44
  assert_output "lanes alpha ctx 44%"
  run reg alpha .used_pct
  assert_output 44
  run reg beta .used_pct
  assert_output null
}

@test "lead_times_out_when_lane_never_answers: an old request shows as timed out" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  as_lead request alpha >/dev/null
  run bash -c "'$LANES' status --json | jq -r '.[] | select(.lane == \"alpha\") | .handshake'"
  assert_output requested
  LANES_REQUEST_TIMEOUT=0 run bash -c "sleep 1; '$LANES' status --json | jq -r '.[] | select(.lane == \"alpha\") | .handshake'"
  assert_output request-timed-out
}

@test "a 200 KB prompt keeps the state file intact (the hook input never rides on argv)" {
  register_lane alpha s1 %7 >/dev/null
  big() { head -c 200000 /dev/zero | tr '\0' p; }
  { printf '{"session_id":"s1","session_title":"alpha","prompt":"/'; big; printf '"}'; } >"$LANES_TEST_TMP/in.json"
  run bash -c "'$LANES' hook prompt <'$LANES_TEST_TMP/in.json'"
  assert_success
  run state alpha '[.prompts, (.last_command | length)] | @json'
  assert_output '[1,200]'
}

# prompt_jq_shim <mode>: a jq on PATH that misbehaves only for the prompt update: "empty" prints nothing and exits 0,
# "fail" prints half a document and exits 5 (helper.bash's jq_shim only fails outright).
prompt_jq_shim() {
  mkdir -p "$LANES_TEST_TMP/jqshim"
  cat >"$LANES_TEST_TMP/jqshim/jq" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *".prompts = "* ]]; then
  [[ "$1" == fail ]] && printf '{"prompts":' && exit 5
  exit 0
fi
exec "$(command -v jq)" "\$@"
SHIM
  chmod +x "$LANES_TEST_TMP/jqshim/jq"
}

@test "write_atomic refuses empty content: a jq that prints nothing leaves the state file as it was" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  prompt_jq_shim empty
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"/goal x"}' | PATH="$LANES_TEST_TMP/jqshim:$PATH" "$LANES" hook prompt || true
  run state alpha '[.prompts, .last_command] | @json'
  assert_output '[1,null]'
}

@test "a failing jq update leaves the state file as it was, never half a document" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  prompt_jq_shim fail
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"/goal x"}' | PATH="$LANES_TEST_TMP/jqshim:$PATH" "$LANES" hook prompt || true
  run state alpha '[.prompts, .last_command] | @json'
  assert_output '[1,null]'
}

@test "a missing jq is reported by name, and a hook does not exit 2 (which would block the prompt)" {
  mkdir -p "$LANES_TEST_TMP/nojq"
  ln -s "$(command -v bash)" "$LANES_TEST_TMP/nojq/bash"
  PATH="$LANES_TEST_TMP/nojq" run "$LANES" status
  assert_failure
  assert_output --partial "jq is not installed"
  PATH="$LANES_TEST_TMP/nojq" run "$LANES" hook prompt </dev/null
  assert_failure 1
  assert_output --partial "jq is not installed"
  run bash -c "PATH='$LANES_TEST_TMP/nojq' '$LANES' statusline </dev/null 2>/dev/null"
  assert_output "lanes: jq is not installed"
}

# old_writer_after_new_session <command...>: a hook of session s1 passes its session lookup, then waits for the mutex
# (held by a live process); meanwhile s2 takes the lane. Once the mutex is free, the old hook must write nothing.
old_writer_after_new_session() {
  local holder writer f s
  export LANES_NO_FLOCK=1
  sleep 30 &
  holder=$!
  ln -s "$(lock_tag_of "$holder")" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  "$@" &
  writer=$!
  sleep 0.5
  f="$LANES_DATA_DIR/lanes/alpha.json"
  jq '.session_id = "s2" | .used_pct = 5' "$f" >"$f.x" && mv "$f.x" "$f"
  s="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq '.session_id = "s2" | .prompts = 1 | .last_command = "/goal new"' "$s" >"$s.x" && mv "$s.x" "$s"
  kill "$holder"
  wait "$writer" || true
}

@test "an old session's prompt hook that waited on the mutex never overwrites the new session's record" {
  register_lane alpha s1 %7 >/dev/null
  old_writer_after_new_session bash -c "jq -nc '{session_id:\"s1\",session_title:\"alpha\",prompt:\"/goal old\"}' | '$LANES' hook prompt"
  run state alpha '[.session_id, .prompts, .last_command] | @json'
  assert_output '["s2",1,"/goal new"]'
}

@test "an old session's status line that waited on the mutex never overwrites the new session's context %" {
  register_lane alpha s1 %7 >/dev/null
  old_writer_after_new_session bash -c "jq -nc '{session_id:\"s1\",session_name:\"alpha\",context_window:{used_percentage:91}}' | '$LANES' statusline >/dev/null"
  run reg alpha .used_pct
  assert_output 5
}

# ---- activity and goal, from the session's own state (the fake keeps its sessions file as 2.1.309 does) ----------

activity() { "$LANES" status --json | jq -r '.[0] | .activity + (if .activity_detail then " (" + .activity_detail + ")" else "" end)'; }

@test "activity follows the sessions file: settling right after a change, idle once LANES_IDLE_GAP has passed" {
  make_repo
  start_fake alpha
  export LANES_IDLE_GAP=30
  run activity
  assert_output settling
  export LANES_IDLE_GAP=0.1
  sleep 0.2
  run activity
  assert_output idle
}

@test "LANES_IDLE_GAP outside 0.1 to 600 seconds, or not a plain number, is refused loudly, never read as no gap" {
  register_lane alpha s1 %7 >/dev/null
  for v in -5 0 0.05 601 nan 1e400 abc 1.2.3; do
    LANES_IDLE_GAP="$v" run "$LANES" status
    assert_failure 2
    assert_output --partial "LANES_IDLE_GAP=$v is not a number of seconds from 0.1 to 600"
  done
  for v in 0.1 3 600; do
    LANES_IDLE_GAP="$v" run "$LANES" status
    assert_success
  done
}

@test "a lane's sessions file is read from the config dir the lane registered with, not the caller's" {
  make_repo
  start_fake alpha
  [ "$(reg alpha .claude_config_dir)" = "$CLAUDE_CONFIG_DIR" ]
  CLAUDE_CONFIG_DIR="$LANES_TEST_TMP/lead-profile" run activity
  assert_output --regexp '^(idle|settling)$'
}

@test "a prompt makes the lane busy, and Esc makes it idle at once with no hook (no Stop, as in 2.1.309)" {
  make_repo
  start_fake alpha FAKE_TURN_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "a long task"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_status busy
  run activity
  assert_output busy
  lanes_tmux send-keys -t "$PANE" Escape
  wait_status idle
  sleep 0.2
  LANES_IDLE_GAP=0.1 run activity
  assert_output idle
}

@test "a dialog is waiting, with what it waits for; a background shell is shell" {
  make_repo
  start_fake alpha FAKE_DIALOG=1
  run activity
  assert_output "waiting (permission prompt)"
  lanes_tmux kill-session -t alpha
  start_fake alpha FAKE_SHELL_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "start a background shell"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_status shell
  run activity
  assert_output shell
}

@test "no sessions file, a stale one, or another session in it is unknown, with the reason" {
  make_repo
  start_fake alpha
  edit_session '.sessionId = "someone-else"'
  run activity
  assert_output --partial "unknown (pid $FAKE_PID now runs session someone-else"
  edit_session '.procStart = "1"'
  run activity
  assert_output --partial "unknown (the session file of pid $FAKE_PID is stale"
  rm "$(session_file)"
  run activity
  assert_output --partial "unknown (no Claude Code session file"
  run "$LANES" status
  assert_output --partial "unknown (no Claude Code session file"
}

@test "a lane registered without a sessions file of its own (no Claude Code pid file) is unknown, never idle" {
  register_lane alpha s1 %7 >/dev/null
  run activity
  assert_output --partial "unknown (no Claude Code session file $CLAUDE_CONFIG_DIR/sessions/$$.json"
}

@test "the goal column comes from the transcript's goal_status entries: active while set, none once cleared" {
  make_repo
  start_fake alpha FAKE_GOAL="ship A1"
  run bash -c "'$LANES' status --json | jq -r '.[0].goal'"
  assert_output active
  run "$LANES" status
  assert_output --partial "goal active"
  wait_status idle
  lanes_tmux send-keys -t "$PANE" -l -- "/goal clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "goal cleared" grep -q '^SUBMIT /goal clear$' "$FAKE_LOG"
  run bash -c "'$LANES' status --json | jq -r '.[0].goal'"
  assert_output none
}
