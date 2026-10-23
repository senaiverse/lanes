#!/usr/bin/env bats
# Public seam: `lanes clear <lane>` for a lane with an active /goal. The model cannot run /goal clear, the goal's Stop
# hook re-prompts the lane (no UserPromptSubmit), and /clear removes a goal (code.claude.com/docs/en/goal). So
# `lanes clear` types `/goal clear` itself at a proven idle point, confirms the footer is gone, then clears.

load helper

submits() { grep -E '^SUBMIT ' "$FAKE_LOG" | cut -d' ' -f2- || true; }

# goal_lane [VAR=value...]: a ready lane whose goal loop has run FAKE_GOAL_TURNS extra turns and given control back.
goal_lane() {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=2 "$@"
  wait_for "goal loop handed back" bash -c "[ \$(grep -c '^GOAL-CONTINUE$' '$FAKE_LOG') -eq 2 ] && [ \"\$(jq -r .stops '$LANES_DATA_DIR/lanes/state/alpha.json')\" = 3 ]"
  wait_for "goal footer" pane_has '◎ /goal active'
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "a lane with an active goal is cleared: /goal clear, then /clear, then the RESUME Goal, never the live one" {
  goal_lane
  run "$LANES" clear alpha
  assert_success
  assert_output --partial "cleared: alpha"
  run submits
  assert_output "/goal clear
/clear
/goal finish item A1 and report done"
  run state alpha .handshake.state
  assert_output done
}

@test "a goal the human cleared never comes back: /goal clear fires no hook, and only the RESUME Goal is re-sent" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_GOAL="an old goal"
  wait_for "goal turn ended" bash -c "[ \"\$(jq -r .busy '$LANES_DATA_DIR/lanes/state/alpha.json')\" = false ]"
  lanes_tmux send-keys -t "$PANE" -l -- "/goal clear"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "goal footer gone" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q '◎ /goal active'"
  run "$LANES" clear-ready --lane alpha
  assert_success
  run state alpha .handshake.goal
  assert_output "finish item A1 and report done"
  run "$LANES" clear alpha
  assert_success
  run grep -c '^SUBMIT /goal an old goal' "$FAKE_LOG"
  assert_output 0
  run grep -c '^SUBMIT /goal finish item A1 and report done$' "$FAKE_LOG"
  assert_output 1
}

@test "a /goal clear that fires UserPromptSubmit neither counts as a prompt nor sets busy" {
  goal_lane FAKE_GOAL_CLEAR_HOOK=1
  run "$LANES" clear alpha
  assert_success
  run submits
  assert_output --partial "/clear"
}

@test "the goal footer that will not go away is a loud refusal, and /clear is never sent" {
  goal_lane FAKE_SWALLOW_ENTERS=2
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "/goal clear"
  run grep -c '^SUBMIT /clear' "$FAKE_LOG"
  assert_output 0
}

@test "goal-driven re-prompting during the clear stops it: the idle re-check sees the Stop count move" {
  make_repo
  write_resume alpha
  export LANES_IDLE_GAP=1.5
  start_fake alpha FAKE_GOAL="ship A1" FAKE_GOAL_TURNS=1000 FAKE_TURN_MS=200
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" clear alpha --wait 2
  assert_failure
  assert_output --regexp "(became busy during the idle re-check|spinner)"
  run grep -c '^SUBMIT /clear' "$FAKE_LOG"
  assert_output 0
}

@test "hook prompt: /goal clear and its aliases do not start a turn, so they set no busy flag and count no prompt" {
  register_lane alpha s1 %7 >/dev/null
  for p in "/goal clear" "/goal stop" "/goal cancel" "/goal"; do
    jq -nc --arg p "$p" '{session_id:"s1",session_title:"alpha",prompt:$p}' | "$LANES" hook prompt
  done
  run state alpha '[.busy, .prompts] | @json'
  assert_output '[false,0]'
  jq -nc '{session_id:"s1",session_title:"alpha",prompt:"/goal ship it"}' | "$LANES" hook prompt
  run state alpha '[.busy, .prompts, .last_command, has("goal")] | @json'
  assert_output '[true,1,"/goal ship it",false]'
}

@test "the request message does not ask the lane to clear its own goal, which only typed input can do" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" request alpha
  assert_success
  refute_output --partial "goal"
}

# ---- lanes goal <lane> "<text>": the lead sets or replaces a lane's goal without clearing it -----------------------

as_lead() { TMUX_PANE=%99 "$LANES" "$@"; }

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
  wait_for "goal turn ended" bash -c "[ \"\$(jq -r .busy '$LANES_DATA_DIR/lanes/state/alpha.json')\" = false ]"
  write_resume alpha "ship B2 instead"
  run "$LANES" clear-ready --lane alpha
  assert_success
  run "$LANES" clear alpha
  assert_success
  run submits
  assert_output "/goal ship B2 instead
/goal clear
/clear
/goal ship B2 instead"
}

# shim_on_goal_clear <action>: a tmux shim that runs <action> right after the Enter that submits `/goal clear`.
shim_on_goal_clear() {
  local m="$LANES_TEST_TMP/goal-clear-typed"
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\n%q "$@"\nrc=$?\n[[ "$*" == *"-l -- /goal clear"* ]] && : >%q\nif [[ "$*" == *" Enter" && -f %q ]]; then rm -f %q; %s; fi\nexit $rc\n' \
    "$(command -v tmux)" "$m" "$m" "$m" "$1" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

@test "a refusal after lanes cleared the goal says so (refused path)" {
  goal_lane
  shim_on_goal_clear "printf 'z\\\\n' >>'$WORK/file'"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "uncommitted changes"
  assert_output --partial "its /goal was cleared"
}

@test "a plain failure after lanes cleared the goal says so too (busy at the moment of sending)" {
  goal_lane
  shim_on_goal_clear "f='$LANES_DATA_DIR/lanes/state/alpha.json'; jq '.busy = true | .busy_since = (now | floor)' \"\$f\" >\"\$f.x\" && mv \"\$f.x\" \"\$f\""
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha --wait 1
  assert_failure
  assert_output --partial "its /goal was cleared"
}

@test "lanes goal checks the pane again right before typing: a session that took the pane during settle gets nothing" {
  goal_setup
  export LANES_IDLE_GAP=2
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

@test "a draft that lands ahead of a long goal wrapped over several lines: only our characters are erased" {
  goal_setup FAKE_ON_ESC=draft-next
  long="$(printf 'finish item B2 and its tests%.0s; ' $(seq 1 10))"
  long="${long%; }"
  run as_lead goal alpha "$long"
  assert_failure
  assert_output --partial "our typed text was deleted"
  run grep -c '^SUBMIT' "$FAKE_LOG"
  assert_output 0
  wait_for "draft left alone" bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q $'^❯ human draft\$'"
}
