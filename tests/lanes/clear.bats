#!/usr/bin/env bats
# Public seam: `lanes clear <lane>`, run by the lead against a fake Claude pane on a private tmux server.
# It refuses unless the lane is clear-ready, idle by its sessions file for LANES_IDLE_GAP, free of a human draft and
# unchanged, and it confirms each send by its effect: a new session for /clear, a UserPromptSubmit of "/goal ..." for
# the goal.

load helper
load lead

submitted() { grep -c "^SUBMIT $1" "$FAKE_LOG" || true; }
keys_sent() { grep -c -E '^(BURST|ESC)' "$FAKE_LOG" || true; }

# mark_sending: the lead was killed after it recorded sending (the Bash tool's SIGKILL), now.
mark_sending() {
  local f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq '.handshake.state = "sending" | .handshake.sent_at = (now | floor)' "$f" >"$f.x" && mv "$f.x" "$f"
}

@test "the happy path: /clear lands (new session), then the goal from RESUME is set" {
  ready_lane alpha
  old="$(reg alpha .session_id)"
  run as_lead clear alpha
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
  as_lead clear alpha >/dev/null
  run jq -r '.hookSpecificOutput.additionalContext' "$FAKE_LOG.hookout"
  assert_output --partial "run the tests for A1"
}

@test "a lane that is not clear-ready is refused and nothing is typed" {
  make_repo
  write_resume alpha
  start_fake alpha
  run as_lead clear alpha
  assert_failure
  assert_output --partial "not clear-ready"
  run submitted /clear
  assert_output 0
}

# tmux_shim <version>: a tmux in $LANES_TEST_TMP/shim (put it first on PATH) whose -V reports <version>; every other
# call goes to the real tmux.
tmux_shim() {
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == -V ]] && { echo %q; exit 0; }; done\nexec %q "$@"\n' \
    "$1" "$(command -v tmux)" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

@test "on tmux older than 3.0 (no send-keys -H) lanes clear and lanes goal refuse before any key" {
  ready_lane alpha
  tmux_shim "tmux 2.9a"
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_failure 2
  assert_output --partial "tmux 2.9a is older than 3.0"
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead goal alpha "ship it"
  assert_failure 2
  assert_output --partial "tmux 2.9a is older than 3.0"
  run keys_sent
  assert_output 0
  run submitted /
  assert_output 0
  run state alpha .handshake.state
  assert_output ready
}

@test "tmux versions: 3.0 and later in every form tmux prints pass; older or unreadable ones are refused" {
  for v in "tmux 3.0" "tmux 3.0a" "tmux 3.4" "tmux 10.1" "tmux next-3.6" "tmux master" "tmux openbsd-7.6"; do
    tmux_shim "$v"
    run env PATH="$LANES_TEST_TMP/shim:$PATH" bash -c 'source "$1"; tmux_check && echo ok' _ "$LANES"
    assert_output ok
  done
  for v in "tmux 2.9" "tmux 1.8" "tmux next-2.9" "" "screen 4.0"; do
    tmux_shim "$v"
    run env PATH="$LANES_TEST_TMP/shim:$PATH" bash -c 'source "$1"; tmux_check && echo ok' _ "$LANES"
    assert_failure 2
    assert_output --partial "lanes: tmux"
  done
}

@test "missing pane: the registered pane is gone" {
  ready_lane alpha
  lanes_tmux kill-pane -t "$PANE"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "does not exist"
}

@test "a pane with no registered pane id is refused" {
  make_repo
  write_resume alpha
  register_lane alpha s1 "" >/dev/null 2>&1
  "$LANES" clear-ready --lane alpha >/dev/null
  run as_lead clear alpha
  assert_failure
  assert_output --partial "no tmux pane registered"
}

@test "registry_half_written_is_rejected by clear" {
  ready_lane alpha
  printf '{"lane":"alpha","session_id":' >"$LANES_DATA_DIR/lanes/alpha.json"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "half-written or corrupt"
}

@test "clear_refuses_pane_not_running_claude: a shell in the pane is never typed into (Claude Code's file is gone)" {
  ready_lane alpha
  lanes_tmux respawn-pane -k -t "$PANE" "bash --norc"
  wait_for "sessions file removed on exit" bash -c "[ ! -e '$(session_file)' ]"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "no Claude Code session file"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "clear_refuses_pane_in_copy_mode" {
  ready_lane alpha
  lanes_tmux copy-mode -t "$PANE"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "copy mode"
}

@test "a new prompt after clear-ready is refused before any wait" {
  ready_lane alpha FAKE_TURN_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "more work"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_status busy
  run as_lead clear alpha --wait 1
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
  run as_lead clear alpha --wait 1
  assert_failure
  assert_output --partial "stayed busy for 1 s"
  assert_output --partial "look at the pane"
  run submitted /clear
  assert_output 0
}

@test "clear_rechecks_idle_after_gap: idle for less than LANES_IDLE_GAP is not idle yet, and --wait runs out" {
  ready_lane alpha
  LANES_IDLE_GAP=30 run as_lead clear alpha --wait 1
  assert_failure
  assert_output --partial "did not stay idle for 30 s"
  run keys_sent
  assert_output 0
}

@test "a lane that went idle just now is cleared once it has stayed idle for LANES_IDLE_GAP" {
  ready_lane alpha
  edit_session '.statusUpdatedAt = (now * 1000 | floor)'
  SECONDS=0
  LANES_IDLE_GAP=2 run as_lead clear alpha --wait 10
  assert_success
  [ "$SECONDS" -ge 2 ]
}

@test "a busy status refuses after --wait, whatever the screen shows" {
  ready_lane alpha
  edit_session '.status = "busy" | .statusUpdatedAt = (now * 1000 | floor)'
  run as_lead clear alpha --wait 1
  assert_failure
  assert_output --partial "stayed busy for 1 s"
  run keys_sent
  assert_output 0
}

@test "clear_refuses_if_head_or_resume_changed_since_ready: a new commit drops clear-ready" {
  ready_lane alpha
  git -C "$WORK" commit -q --allow-empty -m after && git -C "$WORK" push -q
  run as_lead clear alpha
  assert_failure
  assert_output --partial "HEAD moved since clear-ready"
  run reg alpha .clear_ready
  assert_output false
}

@test "a RESUME rewritten and committed after clear-ready moves HEAD and drops clear-ready" {
  ready_lane alpha
  write_resume alpha "a newer goal"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "HEAD moved since clear-ready"
  run reg alpha .clear_ready
  assert_output false
}

@test "dirty tree at clear time is refused" {
  ready_lane alpha
  printf 'z\n' >>"$WORK/file"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "uncommitted changes"
}

@test "clear_refuses_nonempty_composer: a human's draft is never overwritten" {
  ready_lane alpha FAKE_DRAFT="half a thought"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "holds text"
  run submitted /clear
  assert_output 0
}

@test "clear_refuses_when_permission_prompt_open: the sessions file says waiting, and names what for" {
  ready_lane alpha FAKE_DIALOG=1
  run as_lead clear alpha --wait 1
  assert_failure
  assert_output --partial "is waiting for its human (permission prompt)"
  run keys_sent
  assert_output 0
}

@test "a background shell (status shell) refuses after --wait: it would outlive /clear" {
  ready_lane alpha FAKE_SHELL_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "start a shell"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_status shell
  "$LANES" clear-ready --lane alpha >/dev/null
  before="$(keys_sent)"
  run as_lead clear alpha --wait 1
  assert_failure
  assert_output --partial "has a background shell running"
  run keys_sent
  assert_output "$before"
}

@test "no Escape is sent: the first key of a clear is the typed /clear, which a turn only queues" {
  ready_lane alpha
  as_lead clear alpha >/dev/null
  run grep -c '^ESC$' "$FAKE_LOG"
  assert_output 0
  run bash -c "grep -E '^(BURST|SUBMIT)' '$FAKE_LOG' | head -n 3"
  assert_output "BURST 6
BURST 1
SUBMIT /clear"
}

@test "clear_detects_enter_swallowed_and_retries_once" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=1
  run as_lead clear alpha
  assert_success
  assert_output --partial "pressing it once more"
  run grep -c ENTER-SWALLOWED "$FAKE_LOG"
  assert_output 1
  run submitted /clear
  assert_output 1
}

@test "clear_fails_loud_after_max_retries: Enter lost twice is a loud failure, no third Enter" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=5
  run as_lead clear alpha
  assert_failure
  assert_output --partial "no new session appeared"
  run grep -c ENTER-SWALLOWED "$FAKE_LOG"
  assert_output 2
  run state alpha .handshake.state
  assert_output failed
}

@test "goal_confirmed_by_prompt_hook: a goal the session never receives is a loud failure" {
  ready_lane alpha FAKE_GOAL_NO_HOOK=1
  run as_lead clear alpha
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
  LANES_SEND_CHUNK=64 PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_success
  run grep -c 'paste-buffer\|load-buffer' "$LANES_TEST_TMP/tmux.log"
  assert_output 0
  run bash -c "grep -o 'send-keys -t %[0-9]* -l -- .*' '$LANES_TEST_TMP/tmux.log' | sed 's/^send-keys -t %[0-9]* -l -- //' | awk '{ if (length(\$0) > m) m = length(\$0) } END { print m }'"
  assert_output 64
  run submitted "/goal $long"
  assert_output 1
}

@test "second_clear_while_locked_refused" {
  ready_lane alpha
  sleep 30 &
  holder=$!
  ln -s "$(lock_tag_of "$holder")" "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk"
  run as_lead clear alpha
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
  run as_lead clear alpha
  assert_success
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk" ]
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk.break" ]
}

@test "a clear lock whose holder's pid now runs another process is dead and is taken over" {
  ready_lane alpha
  sleep 30 &
  other=$!
  # The lead died and the system gave its pid to another process: the pid runs, with another start time.
  ln -s "$other.1234" "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk"
  run as_lead clear alpha
  kill "$other"
  assert_success
  assert_output --partial "cleared: alpha"
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/alpha.clear.lnk" ]
}

@test "lead_restart_resumes_handshake_from_record: /clear landed, the goal did not; a rerun sends only the goal" {
  ready_lane alpha
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  # start_source is register's last state write, so mark_sending cannot race it.
  wait_for "new session recorded" bash -c "[ \"\$(jq -r .start_source '$LANES_DATA_DIR/lanes/state/alpha.json')\" = clear ]"
  mark_sending
  run as_lead clear alpha
  assert_success
  run submitted /clear
  assert_output 1
  run submitted "/goal finish item A1"
  assert_output 1
}

@test "lead restarted before /clear landed: the record says sending, the session is unchanged, so it starts over" {
  ready_lane alpha
  mark_sending
  run as_lead clear alpha
  assert_success
  assert_output --partial "checking again from the start"
  run submitted /clear
  assert_output 1
}

@test "the lead never clears itself: it is a lead, and a lead never acts on a lead" {
  ready_lane alpha
  run as_lead clear lead
  assert_failure
  assert_output --partial "lane lead is a lead"
}

# project_b_lane <lane>: a live, clear-ready lane in a second project (its own repository and remote). WORK and the
# current directory are project A's again afterwards.
project_b_lane() {
  local a="$WORK" r="$REMOTE"
  WORK="$LANES_TEST_TMP/workB" REMOTE="$LANES_TEST_TMP/remoteB.git"
  make_repo
  write_resume "$1"
  start_fake "$1"
  "$LANES" clear-ready --lane "$1" >/dev/null
  WORK="$a" REMOTE="$r"
  cd "$WORK" || return 1
}

# refused_untouched_at <lane> <message part>: request, clear and goal at <lane> from the lead are each refused with the
# message, and the lane's state file and registry entry are as before.
refused_untouched_at() {
  local before_s before_r
  before_s="$(cat "$LANES_DATA_DIR/lanes/state/$1.json" 2>/dev/null || true)"
  before_r="$(cat "$LANES_DATA_DIR/lanes/$1.json")"
  run as_lead request "$1"
  assert_failure
  assert_output --partial "$2"
  run as_lead clear "$1"
  assert_failure
  assert_output --partial "$2"
  run as_lead goal "$1" "take over this lane"
  assert_failure
  assert_output --partial "$2"
  assert [ "$(cat "$LANES_DATA_DIR/lanes/state/$1.json" 2>/dev/null || true)" = "$before_s" ]
  assert [ "$(cat "$LANES_DATA_DIR/lanes/$1.json")" = "$before_r" ]
  assert [ ! -e "$LANES_DATA_DIR/lanes/state/$1.clear.lnk" ]
}

@test "a lead acts only on lanes of its own project: request, clear and goal at another project's lane write and type nothing" {
  make_repo
  project_b_lane betab
  register_lead
  refused_untouched_at betab "not the project of this lead"
  run reg betab .clear_ready
  assert_output true
  run keys_sent
  assert_output 0
}

@test "a lead never acts on another lead, of its own project or another: request, clear and goal write and type nothing" {
  make_repo
  start_fake lead2 LANES_ROLE=lead
  mkdir -p "$LANES_TEST_TMP/workB"
  jq -nc --arg c "$LANES_TEST_TMP/workB" '{session_id:"sB",session_title:"leadb",cwd:$c,source:"startup"}' |
    LANES_ROLE=lead TMUX_PANE=%97 "$LANES" register >/dev/null 2>&1
  register_lead
  run reg lead2 .role
  assert_output lead
  refused_untouched_at lead2 "lane lead2 is a lead"
  refused_untouched_at leadb "lane leadb is a lead"
  run keys_sent
  assert_output 0
}

@test "lanes clear from a caller that is not the lead is refused and types nothing" {
  ready_lane alpha
  register_lane beta sb %98 >/dev/null 2>&1
  TMUX_PANE=%98 run "$LANES" clear alpha
  assert_failure
  assert_output --partial "only the lead"
  TMUX_PANE="$PANE" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "only the lead"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "only the lead"
  run keys_sent
  assert_output 0
  run reg alpha .clear_ready
  assert_output true
}

@test "lanes clear refuses an unknown argument or a --wait without its value with usage, and types nothing" {
  ready_lane alpha
  run as_lead clear alpha --bogus
  assert_failure 2
  assert_output --partial "usage"
  run as_lead clear alpha --wait
  assert_failure 2
  assert_output --partial "usage"
  run as_lead clear alpha --wait 5 extra
  assert_failure 2
  assert_output --partial "usage"
  run keys_sent
  assert_output 0
}

@test "a RESUME Goal ending in ';' is typed whole: tmux never reads the semicolon as a separator" {
  make_repo
  write_resume alpha 'ship item A1;'
  start_fake alpha
  "$LANES" clear-ready --lane alpha >/dev/null
  run as_lead clear alpha
  assert_success
  run grep -cx 'SUBMIT /goal ship item A1;' "$FAKE_LOG"
  assert_output 1
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c 'Try \"refactor'"
  assert_output 1
}

@test "a sending record and a lane restarted, not cleared, is refused: the new session gets no goal" {
  ready_lane alpha
  mark_sending
  lanes_tmux kill-session -t alpha
  start_fake alpha
  run state alpha .start_source
  assert_output startup
  run as_lead clear alpha
  assert_failure
  assert_output --partial "the lane restarted (source startup) instead of clearing"
  run submitted /
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
  run reg alpha .clear_ready
  assert_output false
}

@test "a lane restarted while lanes clear waits for its /clear to land is refused, not cleared: no goal is typed" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=2
  as_lead clear alpha >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  wait_for "first Enter swallowed" grep -q ENTER-SWALLOWED "$FAKE_LOG"
  lanes_tmux kill-session -t alpha
  start_fake alpha
  rc=0
  wait "$pid" || rc=$?
  assert [ "$rc" -ne 0 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "the lane restarted (source startup) instead of clearing"
  run submitted /
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}

@test "the no-flock mutex: a live holder is waited for and never broken; once it dies the lock is taken over" {
  register_lane alpha s1 %7 >/dev/null
  export LANES_NO_FLOCK=1
  sleep 30 &
  holder=$!
  tag="$(lock_tag_of "$holder")"
  ln -s "$tag" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt 2>/dev/null
  run state alpha .prompts
  assert_output 0
  assert [ "$(readlink "$LANES_DATA_DIR/lanes/state/.mutex.lnk")" = "$tag" ]
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  run state alpha .prompts
  assert_output 1
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/.mutex.lnk" ]
}

@test "the no-flock mutex: a holder whose pid now runs another process is dead, and the lock is taken over at once" {
  register_lane alpha s1 %7 >/dev/null
  export LANES_NO_FLOCK=1
  sleep 30 &
  other=$!
  ln -s "$other.1234" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  SECONDS=0
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  kill "$other"
  [ "$SECONDS" -lt 2 ] || { echo "waited $SECONDS s for a dead holder" >&2; false; }
  run state alpha .prompts
  assert_output 1
  assert [ ! -L "$LANES_DATA_DIR/lanes/state/.mutex.lnk" ]
}

@test "the no-flock mutex: a zombie holder (exited, not reaped) is dead, and the lock is taken over" {
  register_lane alpha s1 %7 >/dev/null
  export LANES_NO_FLOCK=1
  zombie_child
  ln -s "$ZTAG" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt
  kill "$ZPARENT"
  wait "$ZPARENT" 2>/dev/null || true
  run state alpha .prompts
  assert_output 1
}

@test "a dead mutex holder is taken over by exactly one of many racing processes: no update is lost" {
  register_lane alpha s1 %7 >/dev/null
  export LANES_NO_FLOCK=1
  local pids
  SECONDS=0
  for round in 1 2 3 4 5; do
    ln -s "999999.$round" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
    pids=()
    for i in $(seq 1 30); do
      (jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' | "$LANES" hook prompt 2>>"$LANES_TEST_TMP/err") &
      pids+=("$!")
    done
    # Only these pids: a bare `wait` also waits for the BATS_TEST_TIMEOUT watchdog bats runs in this shell.
    wait "${pids[@]}"
  done
  [ "$SECONDS" -lt 60 ] || { echo "150 racing hooks took $SECONDS s" >&2; false; }
  # Under load a hook may give up waiting for the mutex (a timeout, reported as "locked"); that is
  # allowed. What must never happen is a lost update: every call either counted or reported its timeout.
  local timeouts prompts
  timeouts="$(grep -c locked "$LANES_TEST_TMP/err" || true)"
  prompts="$(state alpha .prompts)"
  [ $((prompts + timeouts)) -eq 150 ] || { echo "prompts=$prompts timeouts=$timeouts" >&2; false; }
}

# bounded_hook: one `hook prompt` under the no-flock mutex, killed at 20 s (RC 124) by a bash watchdog, since macOS
# has no `timeout`; sets RC, OUT and ELAPSED.
bounded_hook() {
  local pid i
  SECONDS=0
  RC=0
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"hi"}' |
    PATH="$LANES_TEST_TMP/shim:$PATH" LANES_NO_FLOCK=1 "$LANES" hook prompt >"$LANES_TEST_TMP/hook.out" 2>&1 &
  pid=$!
  for ((i = 0; i < 200; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; RC=124; fi
  wait "$pid" 2>/dev/null || ((RC)) || RC=$?
  OUT="$(cat "$LANES_TEST_TMP/hook.out")"
  ELAPSED=$SECONDS
}

@test "the mutex acquire is bounded: a dead holder's lock that comes back after every removal ends in 'locked' within 3 s" {
  register_lane alpha s1 %7 >/dev/null
  mkdir -p "$LANES_TEST_TMP/shim"
  # rm that never removes the lock link: the worst case, a dead-holder lock that is back at once after each break.
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ "$a" == *.mutex.lnk ]] && exit 0; done\nexec %q "$@"\n' "$(command -v rm)" >"$LANES_TEST_TMP/shim/rm"
  chmod +x "$LANES_TEST_TMP/shim/rm"
  ln -s 999999.1 "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  bounded_hook
  [ "$RC" -ne 124 ] || { echo "the hook never returned" >&2; false; }
  [ "$ELAPSED" -le 5 ] || { echo "took $ELAPSED s" >&2; false; }
  [[ "$OUT" == *"registry locked"* ]]
}

@test "the mutex acquire is bounded: a live holder and a live break marker end in 'locked' within 3 s" {
  register_lane alpha s1 %7 >/dev/null
  mkdir -p "$LANES_TEST_TMP/shim"
  sleep 30 &
  live=$!
  ln -s "$(lock_tag_of "$live")" "$LANES_DATA_DIR/lanes/state/.mutex.lnk"
  ln -s "$(lock_tag_of "$live")" "$LANES_DATA_DIR/lanes/state/.mutex.lnk.break"
  bounded_hook
  kill "$live"
  [ "$RC" -ne 124 ]
  [ "$ELAPSED" -le 5 ] || { echo "took $ELAPSED s" >&2; false; }
  [[ "$OUT" == *"registry locked"* ]]
  run state alpha .prompts
  assert_output 0
}

@test "a cleared record older than the request timeout is not resumed: no goal is typed" {
  ready_lane alpha
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "new session" bash -c "[ \$(grep -c '^SUBMIT /clear' '$FAKE_LOG') = 1 ]"
  sleep 0.5
  sid="$(reg alpha .session_id)"
  jq --arg s "$sid" '.handshake.state = "cleared" | .handshake.cleared_at = 1000 | .handshake.cleared_session = $s' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "older than"
  run submitted "/goal"
  assert_output 0
}

@test "a cleared record from another session is not resumed: the lane cleared or restarted since" {
  ready_lane alpha
  mark_sending
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "cleared" bash -c "[ \"\$(jq -r .handshake.state '$LANES_DATA_DIR/lanes/state/alpha.json')\" = cleared ]"
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "second session" bash -c "[ \$(grep -c '^SUBMIT /clear' '$FAKE_LOG') = 2 ]"
  sleep 0.5
  run as_lead clear alpha
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
  run as_lead clear alpha
  assert_failure
  assert_output --partial "lanes goal alpha"
  run submitted "/goal"
  assert_output 0
}

@test "a sending record older than the request timeout is not resumed, and the record goes stale" {
  ready_lane alpha
  f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq '.handshake.state="sending" | .handshake.session_id="old-session" | .handshake.sent_at=1000000000 | .handshake.goal="three day old goal"' "$f" >"$f.n" && mv "$f.n" "$f"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "older than"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}

@test "synchronize-panes on the lane's window is refused: keys would reach every pane of it" {
  ready_lane alpha
  lanes_tmux split-window -d -t "$PANE" "sleep 300"
  lanes_tmux set-window-option -t "$PANE" synchronize-panes on
  run as_lead clear alpha
  assert_failure
  assert_output --partial "has synchronize-panes on"
  run keys_sent
  assert_output 0
}

# add_turn_entry <json>: one transcript line, as Claude Code appends it when a turn begins without a prompt.
add_turn_entry() { printf '%s\n' "$1" >>"$(state alpha .transcript)"; }

@test "a Stop hook's feedback after clear-ready (a /goal verdict sending the loop on) is a new turn: refused" {
  ready_lane alpha
  add_turn_entry '{"type":"user","isMeta":true,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"Stop hook feedback:\n[ship A1]: not yet"}}'
  run as_lead clear alpha
  assert_failure
  assert_output --partial "began another turn since clear-ready"
  run keys_sent
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}

@test "a background task's notification after clear-ready is a new turn: refused" {
  ready_lane alpha
  add_turn_entry '{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"<task-notification>\n<status>completed</status>\n</task-notification>"}}'
  run as_lead clear alpha
  assert_failure
  assert_output --partial "began another turn since clear-ready"
  run keys_sent
  assert_output 0
}

@test "the rest of clear-ready's own turn (its tool result and the reply) is not a new turn: the clear lands" {
  ready_lane alpha
  add_turn_entry '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fake","content":"clear-ready: alpha","is_error":false}]}}'
  add_turn_entry '{"type":"assistant","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"clear-ready"}]}}'
  add_turn_entry '{"type":"system","subtype":"turn_duration","timestamp":"2026-01-01T00:00:01.100Z"}'
  run as_lead clear alpha
  assert_success
}

@test "a transcript that cannot be read is refused: a new turn could not be ruled out" {
  ready_lane alpha
  f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq '.handshake.turns = ""' "$f" >"$f.n" && mv "$f.n" "$f"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "could not be read"
  run keys_sent
  assert_output 0
}

@test "a check that crashes is a refusal, never a pass: nothing is typed" {
  ready_lane alpha
  jq_shim '(.tmux_pid // "" | tostring)' 1+
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_failure
  assert_output --partial "check failed: identity_problem"
  run keys_sent
  assert_output 0
}

@test "one unreadable sessions file read while waiting for idle is read again, and the clear lands" {
  ready_lane alpha
  # The first read is the identity proof; the second is the wait for idle, the one a torn write can hit.
  jq_shim "/sessions/$FAKE_PID.json" 2
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_success
  run submitted /clear
  assert_output 1
}

@test "two unreadable sessions file reads in a row while waiting for idle are refused" {
  ready_lane alpha
  jq_shim "/sessions/$FAKE_PID.json" 2+
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_failure
  assert_output --partial "is not valid JSON"
  run keys_sent
  assert_output 0
}

@test "a lead killed while its typed /clear waits in the input line deletes it and says so" {
  ready_lane alpha
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\n%q "$@"\nrc=$?\nif [[ " $* " == *"-l -- /clear"* ]]; then : >%q; sleep 2; fi\nexit $rc\n' \
    "$(command -v tmux)" "$LANES_TEST_TMP/typed" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
  register_lead
  TMUX_PANE=%99 PATH="$LANES_TEST_TMP/shim:$PATH" "$LANES" clear alpha >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  wait_for "typed /clear" test -f "$LANES_TEST_TMP/typed"
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  assert [ "$rc" -eq 143 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "stopped while typing into $PANE: our typed text was deleted"
  wait_for "typed /clear deleted" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q $'^❯ /clear'"
  run submitted /clear
  assert_output 0
}

# The transcript entry 2.1.309 writes for a message another Claude session sends: meta, origin peer, string content.
PEER_ENTRY='{"type":"user","isMeta":true,"origin":{"kind":"peer"},"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"Another Claude session sent a message:\n<cross-session-message from=\"lead\">start on B2</cross-session-message>"}}'

# use_after_clear <n> <prompt|message>: a tmux shim that, at the n-th screen read once the registry names a session
# other than the one in $LANES_TEST_TMP/old-sid (the waits after /clear, then the check before typing), uses that new
# session: a human prompt through its UserPromptSubmit, or a cross-session message written to its transcript alone.
use_after_clear() {
  mkdir -p "$LANES_TEST_TMP/shim"
  echo "$1" >"$LANES_TEST_TMP/use-count"
  printf '%s\n' "$PEER_ENTRY" >"$LANES_TEST_TMP/peer.json"
  cat >"$LANES_TEST_TMP/shim/tmux" <<EOS
#!/usr/bin/env bash
"$(command -v tmux)" "\$@"
rc=\$?
sid="\$(jq -r .session_id "$LANES_DATA_DIR/lanes/alpha.json")"
if [[ " \$* " == *" capture-pane "* && -f "$LANES_TEST_TMP/use-count" && "\$sid" != "\$(cat "$LANES_TEST_TMP/old-sid")" ]]; then
  n=\$((\$(cat "$LANES_TEST_TMP/use-count") - 1))
  if ((n > 0)); then echo "\$n" >"$LANES_TEST_TMP/use-count"; else
    rm -f "$LANES_TEST_TMP/use-count"
    if [[ "$2" == prompt ]]; then
      jq -nc --arg s "\$sid" '{session_id:\$s,session_title:"alpha",prompt:"a human prompt"}' | "$LANES" hook prompt
    else
      cat "$LANES_TEST_TMP/peer.json" >>"\$(jq -r .transcript "$LANES_DATA_DIR/lanes/state/alpha.json")"
    fi
    : >"$LANES_TEST_TMP/used"
  fi
fi
exit \$rc
EOS
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

# goal_refused_after_use <n> <prompt|message> <message part>: lanes clear on a ready lane, with the new session used at
# the n-th screen read after /clear; the goal is never typed and the record stays cleared.
goal_refused_after_use() {
  ready_lane alpha
  reg alpha .session_id >"$LANES_TEST_TMP/old-sid"
  use_after_clear "$1" "$2"
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_failure
  assert_output --partial "$3"
  assert_output --partial "lanes goal alpha"
  assert [ -f "$LANES_TEST_TMP/used" ]
  run submitted /clear
  assert_output 1
  run submitted "/goal"
  assert_output 0
  run state alpha .handshake.state
  assert_output cleared
}

@test "the goal goes only into an unused session: a human prompt while clear waits for the new input line gets no goal" {
  goal_refused_after_use 1 prompt "already took 1 prompt"
}

@test "the goal goes only into an unused session: a cross-session message at the end of the wait for idle gets no goal" {
  goal_refused_after_use 2 message "already began 1 turn"
}

@test "the goal goes only into an unused session: a prompt at the last screen read before typing gets no goal" {
  goal_refused_after_use 3 prompt "already took 1 prompt"
}

@test "/clear's own transcript entries (its caveat and the command) are not use: the goal is typed" {
  ready_lane alpha
  run as_lead clear alpha
  assert_success
  run grep -c 'command-name>/clear' "$(state alpha .transcript)"
  assert_output 1
  run submitted "/goal finish item A1"
  assert_output 1
}

# resume_cleared: /clear typed by hand and the lead killed after it recorded sending, so a rerun resumes at cleared.
resume_cleared() {
  ready_lane alpha
  reg alpha .session_id >"$LANES_TEST_TMP/old-sid"
  lanes_tmux send-keys -t "$PANE" -l -- "/clear"
  lanes_tmux send-keys -t "$PANE" Enter
  # start_source is register's last state write, so mark_sending cannot race it.
  wait_for "new session recorded" bash -c "[ \"\$(jq -r .start_source '$LANES_DATA_DIR/lanes/state/alpha.json')\" = clear ]"
  mark_sending
}

@test "a resumed clear checks again after its waits: a human prompt during the wait for the input line gets no goal" {
  resume_cleared
  use_after_clear 1 prompt
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_failure
  assert_output --partial "already took 1 prompt"
  run submitted "/goal"
  assert_output 0
}

@test "a resumed clear checks again after its waits: a cross-session message during the wait for idle gets no goal" {
  resume_cleared
  use_after_clear 2 message
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead clear alpha
  assert_failure
  assert_output --partial "already began 1 turn"
  run submitted "/goal"
  assert_output 0
}
