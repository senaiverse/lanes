#!/usr/bin/env bats
# Public seams: `lanes clear <lane>` for a lane with an active /goal, and `lanes goal <lane> <text>`. /clear removes an
# active goal itself (code.claude.com/docs/en/goal; measured on 2.1.309), so `lanes clear` types no `/goal clear`, and
# a goal loop keeps the sessions file busy across its turns, so clear waits for the loop to hand control back.

load helper
load lead

submits() { grep -E '^SUBMIT ' "$FAKE_LOG" | cut -d' ' -f2- || true; }

# goal_lane [VAR=value...]: a ready lane whose goal loop has run FAKE_GOAL_TURNS extra turns and given control back
# with the goal still set.
goal_lane() {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=2 "$@"
  wait_for "goal loop handed back" bash -c "[ \$(grep -c '^GOAL-CONTINUE$' '$FAKE_LOG') -eq 2 ]"
  wait_status idle
  wait_for "goal footer" pane_has '◎ /goal active'
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "a lane with an active goal is cleared by /clear alone, then the RESUME Goal is set, never the live one" {
  goal_lane
  run as_lead clear alpha
  assert_success
  assert_output --partial "cleared: alpha"
  run submits
  assert_output "/clear
/goal finish item A1 and report done"
  run state alpha .handshake.state
  assert_output done
}

@test "a goal the human cleared never comes back: only the RESUME Goal is re-sent" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="an old goal"
  wait_status idle
  lanes_tmux send-keys -t "$PANE" -l -- "/goal clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "goal footer gone" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q '◎ /goal active'"
  run "$LANES" clear-ready --lane alpha
  assert_success
  run state alpha .handshake.goal
  assert_output "finish item A1 and report done"
  run as_lead clear alpha
  assert_success
  run grep -c '^SUBMIT /goal an old goal' "$FAKE_LOG"
  assert_output 0
  run grep -c '^SUBMIT /goal finish item A1 and report done$' "$FAKE_LOG"
  assert_output 1
}

@test "a goal loop that goes on after clear-ready (turns with no prompt) refuses /clear: nothing is typed" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=3 FAKE_TURN_MS=400
  # clear-ready runs inside a goal turn, as the lane's Bash tool would run it; the loop then goes on.
  "$LANES" clear-ready --lane alpha >/dev/null
  n="$(grep -c '^GOAL-CONTINUE$' "$FAKE_LOG" || true)"
  wait_for "another goal turn" bash -c "[ \$(grep -c '^GOAL-CONTINUE$' '$FAKE_LOG') -gt $n ]"
  run as_lead clear alpha --wait 5
  assert_failure
  assert_output --partial "began another turn since clear-ready"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}

@test "a running goal loop keeps the lane busy (one busy span), so clear waits and then refuses: nothing is typed" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=1000 FAKE_TURN_MS=60000
  "$LANES" clear-ready --lane alpha >/dev/null
  run as_lead clear alpha --wait 2
  assert_failure
  assert_output --partial "stayed busy for 2 s"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
  run sess .status
  assert_output busy
}

@test "the request message does not ask the lane to clear its own goal, which only typed input can do" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  run as_lead request alpha
  assert_success
  refute_output --partial "goal"
}

# ---- lanes goal <lane> "<text>": the lead sets or replaces a lane's goal without clearing it -----------------------

goal_setup() {
  make_repo
  write_resume alpha
  LANES_ROLE=lead register_lane lead sl %99 >/dev/null 2>&1
  start_fake alpha "$@"
}

@test "lanes goal sets the goal on an idle lane and confirms it through UserPromptSubmit" {
  goal_setup
  run as_lead goal alpha "ship B2 and its tests"
  assert_success
  assert_output --partial "goal set: alpha"
  run grep -c '^SUBMIT /goal ship B2 and its tests$' "$FAKE_LOG"
  assert_output 1
  run state alpha .last_command
  assert_output "/goal ship B2 and its tests"
}

@test "lanes goal refuses a busy lane and types nothing" {
  goal_setup FAKE_BUSY_FOREVER=1
  run as_lead goal alpha "ship B2" --wait 1
  assert_failure
  assert_output --partial "stayed busy"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "lanes goal refuses a multi-line goal before anything is typed" {
  goal_setup
  run as_lead goal alpha $'ship B2\nand B3'
  assert_failure 2
  assert_output --partial "one line"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "a goal over 256 characters is typed in chunks of at most 256, never pasted" {
  goal_setup
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 20))"
  long="${long%; }"
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$LANES_TEST_TMP/tmux.log" "$(command -v tmux)" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead goal alpha "$long"
  assert_success
  run grep -c 'paste-buffer\|load-buffer' "$LANES_TEST_TMP/tmux.log"
  assert_output 0
  run bash -c "grep -o 'send-keys -t %[0-9]* -l -- .*' '$LANES_TEST_TMP/tmux.log' | sed 's/^send-keys -t %[0-9]* -l -- //' | awk '{ n++; if (length(\$0) > m) m = length(\$0) } END { print n, m }'"
  assert_output "3 256"
  run grep -c "^SUBMIT /goal $long\$" "$FAKE_LOG"
  assert_output 1
}

@test "lanes goal from a caller that is not the lead is refused" {
  goal_setup
  register_lane beta sb %98 >/dev/null 2>&1
  TMUX_PANE=%98 run "$LANES" goal alpha "ship B2"
  assert_failure
  assert_output --partial "only the lead"
  run "$LANES" goal alpha "ship B2"
  assert_failure
  assert_output --partial "only the lead"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "a goal replaced with lanes goal is re-sent after a clear once the lane copied it into its RESUME Goal" {
  goal_setup
  run as_lead goal alpha "ship B2 instead"
  assert_success
  wait_status idle
  write_resume alpha "ship B2 instead"
  run "$LANES" clear-ready --lane alpha
  assert_success
  run as_lead clear alpha
  assert_success
  run submits
  assert_output "/goal ship B2 instead
/clear
/goal ship B2 instead"
}

@test "lanes goal checks the pane again right before typing: a session that took the pane during the wait gets nothing" {
  goal_setup
  export LANES_IDLE_GAP=3
  as_lead goal alpha "ship B2" >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  sleep 1
  register_lane beta sb "$PANE" >/dev/null 2>&1
  rc=0
  wait "$pid" || rc=$?
  assert [ "$rc" -ne 0 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "no longer holds pane"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "a draft that lands ahead of a long goal wrapped over several lines: nothing is deleted or submitted" {
  goal_setup FAKE_DRAFT_AT_FIRST_KEY=1
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  run as_lead goal alpha "$long"
  assert_failure
  assert_output --partial "ahead of ours"
  assert_output --partial "nothing was submitted or deleted"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯\xc2\xa0human draft/goal finish item B2'"
  assert_output 1
}

@test "a goal is trimmed where it enters: lanes goal types and confirms the same string" {
  goal_setup
  run as_lead goal alpha "   ship B2 and its tests   "
  assert_success
  run grep -c '^SUBMIT /goal ship B2 and its tests$' "$FAKE_LOG"
  assert_output 1
}

@test "a RESUME Goal with spaces around it is typed trimmed after a clear, and confirmed" {
  make_repo
  write_resume alpha "   ship A1 with spaces   "
  start_fake alpha
  "$LANES" clear-ready --lane alpha >/dev/null
  run as_lead clear alpha
  assert_success
  run grep -c '^SUBMIT /goal ship A1 with spaces$' "$FAKE_LOG"
  assert_output 1
}

@test "a goal check that crashes (its character count killed) is a refusal, never a pass" {
  goal_setup
  jq_shim 'explode[] | if . > 65535' 1+
  PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead goal alpha "ship B2"
  assert_failure
  assert_output --partial "check failed: goal_problem"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "a goal of only spaces is refused before anything is typed" {
  goal_setup
  run as_lead goal alpha "    "
  assert_failure 2
  assert_output --partial "is empty"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "lanes goal sets the goal of a lane with a background shell running (only /clear refuses one, which the shell would outlive)" {
  goal_setup FAKE_SHELL_MS=60000
  lanes_tmux send-keys -t "$PANE" -l -- "start a shell"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_status shell
  run as_lead goal alpha "ship B2"
  assert_success
  run grep -c '^SUBMIT /goal ship B2$' "$FAKE_LOG"
  assert_output 1
}

@test "lanes goal refuses an unknown argument or a --wait without its value with usage, and types nothing" {
  goal_setup
  run as_lead goal alpha "ship B2" --bogus
  assert_failure 2
  assert_output --partial "usage"
  run as_lead goal alpha "ship B2" --wait
  assert_failure 2
  assert_output --partial "usage"
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 0
}

@test "semicolons at the end of a typed chunk reach the input line: tmux never reads them as separators" {
  goal_setup
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec %s "$@"\n' "$LANES_TEST_TMP/tmux.log" "$(command -v tmux)" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
  # With 8-character chunks, "/goal " leaves room for two characters of the goal in the first chunk.
  for g in 'ship A1;' 'ship A1\;' 'ab;' 'a;bcdefgh;ij;;' 'x\\;'; do
    LANES_SEND_CHUNK=8 PATH="$LANES_TEST_TMP/shim:$PATH" run as_lead goal alpha "$g"
    assert_success
    run grep -cxF "SUBMIT /goal $g" "$FAKE_LOG"
    assert_output 1
    wait_status idle
  done
  # No typed argument ends in ';', so none is a lone ';' either.
  run bash -c "grep -E -- ' -l -- ' '$LANES_TEST_TMP/tmux.log' | grep -c ';\$'"
  assert_output 0
}

# shim_hold_after_chunk [human text]: a tmux shim that, after the first typed chunk, marks it in $LANES_TEST_TMP/typed
# and holds 2 s, so a test can kill lanes there; given a human text, it types that text into the pane right after the
# first Backspace burst, as a human typing during the deletion would.
shim_hold_after_chunk() {
  mkdir -p "$LANES_TEST_TMP/shim"
  cat >"$LANES_TEST_TMP/shim/tmux" <<SHIM
#!/usr/bin/env bash
"$(command -v tmux)" "\$@"
rc=\$?
if [[ " \$* " == *" -l -- "* && ! -f "$LANES_TEST_TMP/typed" ]]; then : >"$LANES_TEST_TMP/typed"; sleep 2; fi
if [[ -n "${1:-}" && " \$* " == *" BSpace "* && ! -f "$LANES_TEST_TMP/human" ]]; then
  : >"$LANES_TEST_TMP/human"
  "$(command -v tmux)" -L "$LANES_TMUX_SOCKET" send-keys -t "$PANE" -l -- "${1:-}"
  sleep 0.3
fi
exit \$rc
SHIM
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

# kill_goal_after_first_chunk <goal>: start lanes goal through the shim, kill it while the shim holds after the first
# chunk, and leave its exit code in RC and its output in OUT.
kill_goal_after_first_chunk() {
  register_lead
  TMUX_PANE=%99 PATH="$LANES_TEST_TMP/shim:$PATH" "$LANES" goal alpha "$1" >"$LANES_TEST_TMP/out" 2>&1 &
  local pid=$!
  wait_for "first chunk typed" test -f "$LANES_TEST_TMP/typed"
  kill -TERM "$pid"
  RC=0
  wait "$pid" || RC=$?
  OUT="$(cat "$LANES_TEST_TMP/out")"
}

# composer_squashed: the input line as the fake draws it, its wrapped lines joined and every space removed (capture-pane
# drops a wrapped line's trailing space).
composer_squashed() {
  local line out="" on=0
  while IFS= read -r line; do
    if [[ "$line" == "❯"$'\xc2\xa0'* ]]; then on=1; out="${line#"❯"$'\xc2\xa0'}"; continue; fi
    ((on)) || continue
    [[ "$line" == "─"* ]] && break
    out+="$line"
  done < <(lanes_tmux capture-pane -p -t "$PANE")
  printf '%s' "${out// /}"
}

@test "a lead killed between two typed chunks deletes the chunk it typed and says so" {
  goal_setup
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  shim_hold_after_chunk
  kill_goal_after_first_chunk "$long"
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"stopped while typing into $PANE: our typed text was deleted"* ]]
  wait_for "typed chunk deleted" pane_has 'Try "refactor'
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "text a human types while our text is being deleted is never deleted: the deletion stops and says so" {
  goal_setup
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  shim_hold_after_chunk HUMANDRAFT
  kill_goal_after_first_chunk "$long"
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"stopped while typing into $PANE: deleting our typed text stopped"* ]]
  # The first chunk was 256 characters; one burst of 64 Backspaces went before the human typed.
  typed="/goal $long"
  typed="${typed:0:192}"
  run composer_squashed
  assert_output "${typed// /}HUMANDRAFT"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "a line that keeps showing more of our text than is left (a human retyping our next characters) stops the deletion" {
  goal_setup
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  typed="/goal $long"
  # After the first burst of 64 Backspaces the human types back five of the characters it deleted.
  shim_hold_after_chunk "${typed:192:5}"
  kill_goal_after_first_chunk "$long"
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"kept showing more of it than was left"* ]]
  run composer_squashed
  kept="${typed:0:197}"
  assert_output "${kept// /}"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "a kill while a slow screen still draws our chunks deletes all of our text: the plan waits for the screen to settle" {
  goal_setup FAKE_DRAW_LAG_MS=100
  mkdir -p "$LANES_TEST_TMP/shim"
  # The last chunk of "/goal abc" in chunks of 3 is "abc": right after it, lanes is killed, as the Bash tool does.
  printf '#!/usr/bin/env bash\n%q "$@"\nrc=$?\n[[ " $* " == *" -l -- abc "* ]] && kill -TERM $PPID\nexit $rc\n' \
    "$(command -v tmux)" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
  register_lead
  RC=0
  LANES_SEND_CHUNK=3 TMUX_PANE=%99 PATH="$LANES_TEST_TMP/shim:$PATH" "$LANES" goal alpha abc >"$LANES_TEST_TMP/out" 2>&1 || RC=$?
  assert [ "$RC" -eq 143 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "stopped while typing into $PANE: our typed text was deleted"
  wait_for "all of our text deleted" pane_has 'Try "refactor'
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
}

@test "our typed text is never erased into another session of the same process: a kill after an in-place switch leaves it" {
  goal_setup
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  shim_hold_after_chunk
  register_lead
  TMUX_PANE=%99 PATH="$LANES_TEST_TMP/shim:$PATH" "$LANES" goal alpha "$long" >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  wait_for "first chunk typed" test -f "$LANES_TEST_TMP/typed"
  # The same Claude Code process now runs another session (as /resume does), in its sessions file and the registry.
  edit_session '.sessionId = "s-switched"'
  hook_json SessionStart s-switched alpha resume | TMUX="$(server_tmux)" TMUX_PANE="$PANE" CLAUDE_PID="$FAKE_PID" "$LANES" register >/dev/null 2>&1
  kill -TERM "$pid"
  RC=0
  wait "$pid" || RC=$?
  OUT="$(cat "$LANES_TEST_TMP/out")"
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"our typed text was left in the input line of $PANE, because the session of lane alpha changed"* ]]
  typed="/goal $long"
  typed="${typed:0:256}"
  run composer_squashed
  assert_output "${typed// /}"
}

# kill_after_enter <lanes args...>: start lanes from the lead's pane, wait until the fake got the Enter of a /goal or
# /clear, type HUMAN_KEYS (if set) as a human, then kill lanes while it waits for the confirmation; RC and OUT as
# kill_goal_after_first_chunk.
kill_after_enter() {
  register_lead
  LANES_CLEAR_TIMEOUT=10 TMUX_PANE=%99 "$LANES" "$@" >"$LANES_TEST_TMP/out" 2>&1 &
  local pid=$!
  wait_for "Enter received" grep -qE '^(SUBMIT|ENTER-SWALLOWED)' "$FAKE_LOG"
  sleep 0.5
  if [[ -n "${HUMAN_KEYS:-}" ]]; then
    lanes_tmux send-keys -t "$PANE" -l -- "$HUMAN_KEYS"
    wait_for "human keys drawn" pane_has "❯"$'\xc2\xa0'"$HUMAN_KEYS"
  fi
  kill -TERM "$pid"
  RC=0
  wait "$pid" || RC=$?
  OUT="$(cat "$LANES_TEST_TMP/out")"
}

@test "a kill after the Enter of /goal never deletes: a human's '/' typed into the empty line stays" {
  goal_setup FAKE_GOAL_NO_HOOK=1
  HUMAN_KEYS=/ kill_after_enter goal alpha "ship B2"
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"stopped after pressing Enter in $PANE: the text may have been submitted, so nothing was deleted"* ]]
  run composer_squashed
  assert_output "/"
}

@test "a kill after an Enter that was not taken leaves the /goal in the input line: it is no longer ours to delete" {
  goal_setup FAKE_SWALLOW_ENTERS=2
  kill_after_enter goal alpha "ship B2"
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"nothing was deleted"* ]]
  run composer_squashed
  assert_output "/goalshipB2"
}

@test "a kill after the Enter of /clear never deletes: the /clear left in the input line stays" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_SWALLOW_ENTERS=2
  run "$LANES" clear-ready --lane alpha
  assert_success
  kill_after_enter clear alpha
  assert [ "$RC" -eq 143 ]
  [[ "$OUT" == *"stopped after pressing Enter in $PANE"*"nothing was deleted"* ]]
  run composer_squashed
  assert_output "/clear"
}
