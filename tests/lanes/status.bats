#!/usr/bin/env bats
# Public seams: `lanes-statusline` (writes used_pct) and `lanes status` (reads it with the threshold, busy flag and
# handshake). Context % has three states, never collapsed: a number, unknown and stale.

load helper

# statusline_input <lane> <session> <pct|null>
statusline_input() {
  jq -nc --arg n "$1" --arg s "$2" --argjson p "$3" '{session_name:$n,session_id:$s,context_window:{used_percentage:$p}}'
}

# sl <lane> <session> <pct> [command]: one status line update through the given command (default the plugin's).
sl() { statusline_input "$1" "$2" "$3" | "${4:-$STATUSLINE}"; }

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
  command -v setsid >/dev/null || skip "setsid is needed to signal the whole process group"
  for i in $(seq 1 60); do
    statusline_input alpha s1 "$i" >"$LANES_TEST_TMP/in"
    setsid "$STATUSLINE" <"$LANES_TEST_TMP/in" >/dev/null &
    pid=$!
    sleep "0.0$((RANDOM % 4))$((RANDOM % 10))"
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    jq -e '.lane == "alpha" and .session_id == "s1"' "$LANES_DATA_DIR/lanes/alpha.json" >/dev/null
  done
  run bash -c "ls -A '$LANES_DATA_DIR/lanes' | grep -c '^\.tmp' || true"
  assert_output 0
}

@test "a status line cancelled between its temp write and the rename leaves no temp file and the old entry" {
  command -v setsid >/dev/null || skip "setsid is needed to signal the whole process group"
  register_lane alpha s1 %7 >/dev/null
  mkdir -p "$LANES_TEST_TMP/slow"
  printf '#!/usr/bin/env bash\nsleep 2\nexec %s "$@"\n' "$(command -v mv)" >"$LANES_TEST_TMP/slow/mv"
  chmod +x "$LANES_TEST_TMP/slow/mv"
  statusline_input alpha s1 61 >"$LANES_TEST_TMP/in"
  PATH="$LANES_TEST_TMP/slow:$PATH" setsid "$STATUSLINE" <"$LANES_TEST_TMP/in" >/dev/null &
  pid=$!
  wait_for "temp file" bash -c "ls -A '$LANES_DATA_DIR/lanes' | grep -q '^\.tmp'"
  kill -TERM -- "-$pid"
  wait "$pid" 2>/dev/null || true
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
  assert_output --partial "threshold 50%"
  assert_output --partial AT-THRESHOLD
  LANES_THRESHOLD=60 run "$LANES" status
  refute_output --partial AT-THRESHOLD
}

@test "empty journal and empty registry: status says how to start a lane" {
  run "$LANES" status
  assert_success
  assert_output --partial "no lanes registered"
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

@test "idle_from_hook_flag: prompt sets busy, stop clears it, and nothing is printed to the model" {
  register_lane alpha s1 %7 >/dev/null
  run bash -c "jq -nc '{session_id:\"s1\",session_title:\"alpha\",prompt:\"hi\"}' | '$LANES' hook prompt"
  assert_success
  assert_output ""
  run bash -c "'$LANES' status --json | jq -r '.[0].activity'"
  assert_output busy
  run bash -c "jq -nc '{session_id:\"s1\",background_tasks:[]}' | '$LANES' hook stop"
  assert_output ""
  run bash -c "'$LANES' status --json | jq -r '.[0].activity'"
  assert_output idle
}

@test "busy_flag_expires_after_ttl: Stop does not fire on an interrupt, so an old busy flag ages out" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  jq '.busy_since -= 100' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  LANES_BUSY_TTL=50 run bash -c "'$LANES' status --json | jq -r '.[0].activity'"
  assert_output busy-expired
}

@test "a Stop with background tasks is not idle" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id:"s1",background_tasks:[{"id":"b1"}]}' | "$LANES" hook stop
  run bash -c "'$LANES' status --json | jq -r '.[0].activity'"
  assert_output background
}

@test "a hook from an unregistered session changes nothing and exits 0" {
  register_lane alpha s1 %7 >/dev/null
  run bash -c "jq -nc '{session_id:\"other\",prompt:\"hi\"}' | '$LANES' hook prompt"
  assert_success
  run state alpha .busy
  assert_output false
}

@test "lead_times_out_when_lane_never_answers: an old request shows as timed out" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  "$LANES" request alpha >/dev/null
  run bash -c "'$LANES' status --json | jq -r '.[0].handshake'"
  assert_output requested
  LANES_REQUEST_TIMEOUT=0 run bash -c "sleep 1; '$LANES' status --json | jq -r '.[0].handshake'"
  assert_output request-timed-out
}

@test "a 200 KB prompt keeps the state file intact (the hook input never rides on argv)" {
  register_lane alpha s1 %7 >/dev/null
  big() { head -c 200000 /dev/zero | tr '\0' p; }
  { printf '{"session_id":"s1","session_title":"alpha","prompt":"/'; big; printf '"}'; } >"$LANES_TEST_TMP/in.json"
  run bash -c "'$LANES' hook prompt <'$LANES_TEST_TMP/in.json'"
  assert_success
  run state alpha '[.busy, .prompts, (.last_command | length)] | @json'
  assert_output '[true,1,200]'
  { printf '{"session_id":"s1","background_tasks":[],"last_assistant_message":"'; big; printf '"}'; } >"$LANES_TEST_TMP/in.json"
  run bash -c "'$LANES' hook stop <'$LANES_TEST_TMP/in.json'"
  assert_success
  run state alpha '[.busy, .stops] | @json'
  assert_output '[false,1]'
}

# jq_shim <mode>: a jq on PATH that misbehaves only for the Stop update: "empty" prints nothing and exits 0, "fail"
# prints half a document and exits 5.
jq_shim() {
  mkdir -p "$LANES_TEST_TMP/jqshim"
  cat >"$LANES_TEST_TMP/jqshim/jq" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *".stops = "* ]]; then
  [[ "$1" == fail ]] && printf '{"busy":' && exit 5
  exit 0
fi
exec "$(command -v jq)" "\$@"
SHIM
  chmod +x "$LANES_TEST_TMP/jqshim/jq"
}

@test "write_atomic refuses empty content: a jq that prints nothing leaves the state file as it was" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  jq_shim empty
  jq -nc '{session_id:"s1",background_tasks:[]}' | PATH="$LANES_TEST_TMP/jqshim:$PATH" "$LANES" hook stop || true
  run state alpha '[.busy, .prompts] | @json'
  assert_output '[true,1]'
}

@test "a failing jq update leaves the state file as it was, never half a document" {
  register_lane alpha s1 %7 >/dev/null
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  jq_shim fail
  jq -nc '{session_id:"s1",background_tasks:[]}' | PATH="$LANES_TEST_TMP/jqshim:$PATH" "$LANES" hook stop || true
  run state alpha '[.busy, .prompts] | @json'
  assert_output '[true,1]'
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
  ln -s "$holder.1" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  "$@" &
  writer=$!
  sleep 0.5
  f="$LANES_DATA_DIR/lanes/alpha.json"
  jq '.session_id = "s2" | .used_pct = 5' "$f" >"$f.x" && mv "$f.x" "$f"
  s="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq '.session_id = "s2" | .busy = true | .prompts = 1' "$s" >"$s.x" && mv "$s.x" "$s"
  kill "$holder"
  wait "$writer" || true
}

@test "an old session's Stop hook that waited on the mutex never overwrites the new session's busy flag" {
  register_lane alpha s1 %7 >/dev/null
  old_writer_after_new_session bash -c "jq -nc '{session_id:\"s1\",background_tasks:[]}' | '$LANES' hook stop"
  run state alpha '[.session_id, .busy] | @json'
  assert_output '["s2",true]'
}

@test "an old session's status line that waited on the mutex never overwrites the new session's context %" {
  register_lane alpha s1 %7 >/dev/null
  old_writer_after_new_session bash -c "jq -nc '{session_id:\"s1\",session_name:\"alpha\",context_window:{used_percentage:91}}' | '$LANES' statusline >/dev/null"
  run reg alpha .used_pct
  assert_output 5
}

activity() { "$LANES" status --json | jq -r '.[0].activity'; }

@test "Esc interrupts a turn and no Stop runs: the transcript's interrupt entry ends the busy flag, the screen alone never does" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_TURN_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "a long task"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "busy flag" bash -c "[ \"\$(jq -r .busy '$LANES_DATA_DIR/lanes/state/alpha.json')\" = true ]"
  sleep 1.2
  run activity
  assert_output busy
  lanes_tmux send-keys -t "$PANE" Escape
  wait_for "interrupt logged" grep -q '^INTERRUPT$' "$FAKE_LOG"
  run state alpha .busy
  assert_output true
  run activity
  assert_output interrupted
}

@test "an interrupt older than the current turn does not end it" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_TURN_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "first"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "busy flag" bash -c "[ \"\$(jq -r .busy '$LANES_DATA_DIR/lanes/state/alpha.json')\" = true ]"
  lanes_tmux send-keys -t "$PANE" Escape
  wait_for "interrupt logged" grep -q '^INTERRUPT$' "$FAKE_LOG"
  sleep 1.2
  jq -nc --arg s "$(reg alpha .session_id)" --arg tp "$FAKE_LOG.transcript.jsonl" \
    '{session_id:$s,session_title:"alpha",prompt:"second",transcript_path:$tp}' | "$LANES" hook prompt
  run activity
  assert_output busy
}
