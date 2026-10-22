#!/usr/bin/env bats
# Public seam: `lanes clear <lane>`, run by the lead against a fake Claude pane on a private tmux server.
# It refuses unless the lane is clear-ready, idle (hook flag, then a screen veto, twice with a gap) and unchanged, and it
# confirms each send by its effect: a new session for /clear, a UserPromptSubmit of "/goal ..." for the goal.

load helper

submitted() { grep -c "^SUBMIT $1" "$FAKE_LOG" || true; }

@test "the happy path: /clear lands (new session), then the goal from RESUME is set" {
  ready_lane alpha
  old="$(reg alpha .session_id)"
  run "$LANES" clear alpha
  assert_success
  assert_output --partial "cleared: alpha"
  refute [ "$(reg alpha .session_id)" = "$old" ]
  run submitted "/clear"
  assert_output 1
  run submitted "/goal finish item A1 and report done"
  assert_output 1
  run state alpha .handshake.state
  assert_output done
  run reg alpha .clear_ready
  assert_output false
}

@test "SessionStart(clear) re-injected the RESUME block into the cleared session" {
  ready_lane alpha
  "$LANES" clear alpha >/dev/null
  run jq -r '.hookSpecificOutput.additionalContext' "$FAKE_LOG.hookout"
  assert_output --partial "run the tests for A1"
}

@test "a lane that is not clear-ready is refused and nothing is typed" {
  make_repo
  write_resume alpha
  start_fake alpha
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "not clear-ready"
  run submitted /clear
  assert_output 0
}

@test "missing pane: the registered pane is gone" {
  ready_lane alpha
  lanes_tmux kill-pane -t "$PANE"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "does not exist"
}

@test "a pane with no registered pane id is refused" {
  make_repo
  write_resume alpha
  register_lane alpha s1 "" >/dev/null 2>&1
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "no tmux pane registered"
}

@test "registry_half_written_is_rejected by clear" {
  ready_lane alpha
  printf '{"lane":"alpha","session_id":' >"$LANES_DATA_DIR/lanes/alpha.json"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "half-written or corrupt"
}

@test "clear_refuses_pane_not_running_claude: a shell in the pane is never typed into" {
  ready_lane alpha
  lanes_tmux respawn-pane -k -t "$PANE" "bash --norc"
  sleep 0.3
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "not claude"
}

@test "clear_refuses_pane_in_copy_mode" {
  ready_lane alpha
  lanes_tmux copy-mode -t "$PANE"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "copy mode"
}

@test "clear_refuses_when_lane_busy_at_send_time: the hook flag says busy and --wait runs out" {
  ready_lane alpha FAKE_TURN_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "more work"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "busy flag" bash -c "[ \"\$(jq -r .busy '$LANES_DATA_DIR/lanes/state/alpha.json')\" = true ]"
  run "$LANES" clear alpha --wait 1
  assert_failure
  assert_output --partial "received a new prompt"
  run submitted /clear
  assert_output 0
}

@test "clear_times_out_when_a_turn_never_ends: a loud refusal after --wait, never a stuck clear" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_BUSY_FOREVER=1
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" clear alpha --wait 1
  assert_failure
  assert_output --partial "stayed busy for 1 s"
  assert_output --partial "look at the pane"
  run submitted /clear
  assert_output 0
}

@test "clear_rechecks_idle_after_gap: a prompt arriving during the gap stops the clear" {
  ready_lane alpha FAKE_TURN_MS=60000
  export LANES_IDLE_GAP=2
  "$LANES" clear alpha >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  sleep 0.8
  jq -nc --arg s "$(reg alpha .session_id)" '{session_id:$s,session_title:"alpha",prompt:"late follow-up"}' | "$LANES" hook prompt
  rc=0
  wait "$pid" || rc=$?
  assert [ "$rc" -ne 0 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "became busy during the idle re-check"
  run submitted /clear
  assert_output 0
}

@test "idle_from_hook_flag_ignores_spinner_words_in_transcript" {
  ready_lane alpha FAKE_TRANSCRIPT=$'✻ Running… (3s · esc to interrupt)\nolder prose that says Thinking… a lot\nline\nline\nline\nline'
  run "$LANES" clear alpha
  assert_success
}

@test "a spinner just above the input box vetoes even when the flag says idle" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_TRANSCRIPT=$'● reply\n✻ Perusing… (3s · ↓ 175 tokens)'
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "spinner"
}

@test "clear_refuses_if_head_or_resume_changed_since_ready: a new commit drops clear-ready" {
  ready_lane alpha
  git -C "$WORK" commit -q --allow-empty -m after && git -C "$WORK" push -q
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "HEAD moved since clear-ready"
  run reg alpha .clear_ready
  assert_output false
}

@test "a RESUME rewritten and committed after clear-ready moves HEAD and drops clear-ready" {
  ready_lane alpha
  write_resume alpha "a newer goal"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "HEAD moved since clear-ready"
  run reg alpha .clear_ready
  assert_output false
}

@test "dirty tree at clear time is refused" {
  ready_lane alpha
  printf 'z\n' >>"$WORK/file"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "uncommitted changes"
}

@test "clear_refuses_nonempty_composer: a human's draft is never overwritten" {
  ready_lane alpha FAKE_DRAFT="half a thought"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "holds text"
  run submitted /clear
  assert_output 0
}

@test "clear_refuses_when_permission_prompt_open" {
  ready_lane alpha FAKE_DIALOG=1
  run "$LANES" clear alpha
  assert_failure
  assert_output --regexp "(dialog|no input prompt)"
  run grep -c ESC "$FAKE_LOG"
  assert_output 0
}

@test "clear_sends_single_escape_only_after_idle" {
  ready_lane alpha
  "$LANES" clear alpha >/dev/null
  run grep -c '^ESC$' "$FAKE_LOG"
  assert_output 1
  run bash -c "grep -n -E '^(ESC|SUBMIT /clear)' '$FAKE_LOG' | cut -d: -f2"
  assert_output "ESC
SUBMIT /clear"
}

@test "clear_detects_enter_swallowed_and_retries_once" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=1
  run "$LANES" clear alpha
  assert_success
  assert_output --partial "pressing it once more"
  run grep -c ENTER-SWALLOWED "$FAKE_LOG"
  assert_output 1
  run submitted /clear
  assert_output 1
}

@test "clear_fails_loud_after_max_retries: Enter lost twice is a loud failure, no third Enter" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=5
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "no new session registered"
  run grep -c ENTER-SWALLOWED "$FAKE_LOG"
  assert_output 2
  run state alpha .handshake.state
  assert_output failed
}

@test "goal_active_echo_checked: a goal the session never receives is a loud failure" {
  ready_lane alpha FAKE_GOAL_NO_HOOK=1
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "/goal was typed"
  run state alpha .handshake.state
  assert_output failed
}

@test "goal_sent_as_single_line_chunks_not_paste: every key burst stays small, no paste-buffer" {
  long="$(printf 'finish item A1 and its tests%.0s; ' $(seq 1 40))"
  long="${long%; }"
  make_repo
  write_resume alpha "$long"
  start_fake alpha
  "$LANES" clear-ready --lane alpha >/dev/null
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$LANES_TEST_TMP/tmux.log" "$(command -v tmux)" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
  LANES_SEND_CHUNK=64 PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_success
  run grep -c 'paste-buffer\|load-buffer' "$LANES_TEST_TMP/tmux.log"
  assert_output 0
  run bash -c "grep -o 'send-keys -t %[0-9]* -l -- .*' '$LANES_TEST_TMP/tmux.log' | sed 's/^send-keys -t %[0-9]* -l -- //' | awk '{ if (length(\$0) > m) m = length(\$0) } END { print m }'"
  assert_output 64
  run submitted "/goal $long"
  assert_output 1
}

@test "a configured chunk over 512 is refused before anything is typed" {
  ready_lane alpha
  LANES_SEND_CHUNK=900 run "$LANES" clear alpha
  assert_failure
  assert_output --partial "LANES_SEND_CHUNK"
  run grep -c ESC "$FAKE_LOG"
  assert_output 0
}

@test "second_clear_while_locked_refused" {
  ready_lane alpha
  sleep 30 &
  holder=$!
  ln -s "$holder.1234" "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk"
  run "$LANES" clear alpha
  kill "$holder"
  assert_failure
  assert_output --partial "another 'lanes clear alpha' is running"
  assert [ -L "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk" ]
  run submitted /clear
  assert_output 0
}

@test "a stale clear lock from a dead lead is taken over, and the lock is gone afterwards" {
  ready_lane alpha
  ln -s 999999.1234 "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk"
  run "$LANES" clear alpha
  assert_success
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk" ]
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk.break" ]
}

@test "lead_restart_resumes_handshake_from_record: /clear landed, the goal did not; a rerun sends only the goal" {
  ready_lane alpha
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "new session recorded" bash -c "[ \"\$(jq -r .session_id '$LANES_DATA_DIR/lanes/state/alpha.json')\" != \"\$(jq -r .handshake.session_id '$LANES_DATA_DIR/lanes/state/alpha.json')\" ]"
  jq '.handshake.state = "sending" | .handshake.sent_at = (now | floor)' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run "$LANES" clear alpha
  assert_success
  run submitted /clear
  assert_output 1
  run submitted "/goal finish item A1"
  assert_output 1
}

@test "lead restarted before /clear landed: the record says sending, the session is unchanged, so it starts over" {
  ready_lane alpha
  jq '.handshake.state = "sending" | .handshake.sent_at = (now | floor)' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run "$LANES" clear alpha
  assert_success
  assert_output --partial "checking again from the start"
  run submitted /clear
  assert_output 1
}

@test "a lane never clears its own pane" {
  ready_lane alpha
  TMUX_PANE="$PANE" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "never clears itself"
}

@test "the no-flock mutex: a live holder is waited for and never broken; once it dies the lock is taken over" {
  register_lane alpha s1 %7 >/dev/null
  export LANES_NO_FLOCK=1
  sleep 30 &
  holder=$!
  ln -s "$holder.1234" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt 2>/dev/null
  run state alpha .prompts
  assert_output 0
  assert [ "$(readlink "$LANES_DATA_DIR/lanes/state/.mutex.lnk")" = "$holder.1234" ]
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  run state alpha .prompts
  assert_output 1
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/.mutex.lnk" ]
}

@test "a dead mutex holder is taken over by exactly one of many racing processes: no update is lost" {
  register_lane alpha s1 %7 >/dev/null
  export LANES_NO_FLOCK=1
  for round in 1 2 3 4 5; do
    ln -s "999999.$round" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
    for i in $(seq 1 30); do
      (jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt 2>>"$LANES_TEST_TMP/err") &
    done
    wait
  done
  run grep -c locked "$LANES_TEST_TMP/err"
  assert_output 0
  run state alpha .prompts
  assert_output 150
}

@test "a cleared record older than the request timeout is not resumed: no goal is typed" {
  ready_lane alpha
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "new session" bash -c "[ \$(grep -c '^SUBMIT /clear' '$FAKE_LOG') = 1 ]"
  sleep 0.5
  sid="$(reg alpha .session_id)"
  jq --arg s "$sid" '.handshake.state = "cleared" | .handshake.cleared_at = 1000 | .handshake.cleared_session = $s' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "older than"
  run submitted "/goal"
  assert_output 0
}

@test "a cleared record from another session is not resumed: the lane cleared or restarted since" {
  ready_lane alpha
  jq '.handshake.state = "sending" | .handshake.sent_at = (now | floor)' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "cleared" bash -c "[ \"\$(jq -r .handshake.state '$LANES_DATA_DIR/lanes/state/alpha.json')\" = cleared ]"
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "second session" bash -c "[ \$(grep -c '^SUBMIT /clear' '$FAKE_LOG') = 2 ]"
  sleep 0.5
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "another session"
  run submitted "/goal"
  assert_output 0
}

@test "a cleared record whose session already has prompts is not resumed: lanes goal is the way" {
  ready_lane alpha
  sid="$(reg alpha .session_id)"
  f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq --arg s "$sid" --argjson n "$(date +%s)" '.handshake.state="cleared" | .handshake.cleared_session=$s | .handshake.cleared_at=$n | .prompts=3 | .goal=null' "$f" >"$f.n" && mv "$f.n" "$f"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "lanes goal alpha"
  run submitted "/goal"
  assert_output 0
}

@test "a sending record older than the request timeout is not resumed, and the record goes stale" {
  ready_lane alpha
  f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq '.handshake.state="sending" | .handshake.session_id="old-session" | .handshake.sent_at=1000000000 | .handshake.goal="three day old goal"' "$f" >"$f.n" && mv "$f.n" "$f"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "older than"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}
