#!/usr/bin/env bats
# Public seam: `lanes clear <lane>` against a fake Claude pane. Everything clear-ready proved is proved again at the
# last moment: after the wait for idle, before typing and before every Enter. Where keys go (copy mode,
# synchronize-panes, the identity proof) is checked before every key, each typed chunk and each Backspace burst too.

load helper

submitted() { grep -c "^SUBMIT $1" "$FAKE_LOG" || true; }
# keys_sent: key bursts the fake received (it logs each one); none means nothing was typed.
keys_sent() { grep -c -E '^(BURST|ESC)' "$FAKE_LOG" || true; }

# hold_background / release_background: a background shell (status shell in the sessions file) keeps clear waiting.
hold_background() { edit_session '.status = "shell" | .statusUpdatedAt = (now * 1000 | floor)'; }
release_background() { edit_session '.status = "idle" | .statusUpdatedAt = (now * 1000 | floor)'; }

# clear_during_wait <change command...>: start `lanes clear alpha` while a background shell holds it waiting for idle,
# run the change, release the shell, and leave the clear's exit code in RC and its output in OUT.
clear_during_wait() {
  hold_background
  "$LANES" clear alpha --wait 20 >"$LANES_TEST_TMP/out" 2>&1 &
  local pid=$!
  sleep 1
  "$@"
  release_background
  RC=0
  wait "$pid" || RC=$?
  OUT="$(cat "$LANES_TEST_TMP/out")"
}

dirty_tree() { printf 'z\n' >>"$WORK/file"; }
commit_and_push() { git -C "$WORK" commit -q --allow-empty -m during-wait && git -C "$WORK" push -q; }
register_beta_on_pane() { register_lane beta sb "$PANE" >/dev/null 2>&1; }

@test "a tree made dirty while clear waits for idle is refused before any key" {
  ready_lane alpha
  clear_during_wait dirty_tree
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"uncommitted changes"* ]]
  run keys_sent
  assert_output 0
  run submitted /clear
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
  run reg alpha .clear_ready
  assert_output false
}

@test "a commit pushed while clear waits for idle is refused before any key" {
  ready_lane alpha
  clear_during_wait commit_and_push
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"HEAD moved since clear-ready"* ]]
  run keys_sent
  assert_output 0
  run submitted /clear
  assert_output 0
}

@test "a lane restarted after clear-ready (a new session, the same pane, no prompt yet) is refused as a changed session" {
  ready_lane alpha
  edit_session '.sessionId = "restarted"'
  hook_json SessionStart restarted alpha startup | CLAUDE_PID="$FAKE_PID" TMUX_PANE="$PANE" "$LANES" register >/dev/null 2>&1
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the session changed since clear-ready"
  run keys_sent
  assert_output 0
}

@test "a human prompt while /clear is typed stops the clear before Enter, and the typed /clear is deleted" {
  ready_lane alpha
  shim_on_keys "-l -- /clear" "jq -nc --arg s '$(reg alpha .session_id)' '{session_id:\$s,session_title:\"alpha\",prompt:\"a human message\"}' | '$LANES' hook prompt"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane received a new prompt"
  assert_output --partial "our typed text was deleted"
  run submitted /clear
  assert_output 0
  wait_for "typed /clear deleted" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q $'^❯ /clear'"
  run state alpha .handshake.state
  assert_output stale
}

# flip_after_screen_reads <n> <prompt|busy>: a tmux shim on PATH that, right after the n-th capture-pane (the draft
# check that ends the wait for idle), fires a real UserPromptSubmit for alpha, or starts a turn in its sessions file
# with no prompt at all (a /goal check-in or a finished background shell does that).
flip_after_screen_reads() {
  mkdir -p "$LANES_TEST_TMP/shim"
  echo "$1" >"$LANES_TEST_TMP/flip-count"
  cat >"$LANES_TEST_TMP/shim/tmux" <<EOF
#!/usr/bin/env bash
"$(command -v tmux)" "\$@"
rc=\$?
if [[ " \$* " == *" capture-pane "* && -f "$LANES_TEST_TMP/flip-count" ]]; then
  n=\$((\$(cat "$LANES_TEST_TMP/flip-count") - 1))
  if ((n > 0)); then echo "\$n" >"$LANES_TEST_TMP/flip-count"; else
    rm -f "$LANES_TEST_TMP/flip-count"
    if [[ "$2" == prompt ]]; then
      jq -nc --arg s "\$(jq -r .session_id "$LANES_DATA_DIR/lanes/alpha.json")" '{session_id:\$s,session_title:"alpha",prompt:"late"}' | "$LANES" hook prompt
    else
      f="$(session_file)"
      jq -c '.status = "busy" | .statusUpdatedAt = (now * 1000 | floor)' "\$f" >"\$f.x" && mv "\$f.x" "\$f"
    fi
  fi
fi
exit \$rc
EOF
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

# shim_on_capture <action>: a tmux shim that runs <action> once, right after the first capture-pane (the draft check
# that ends the wait for idle).
shim_on_capture() { shim_on_keys " capture-pane " "$1"; }

@test "a prompt arriving after the wait for idle is refused before any key" {
  ready_lane alpha
  flip_after_screen_reads 1 prompt
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane received a new prompt since clear-ready"
  run keys_sent
  assert_output 0
}

@test "nothing is typed once a turn started with no prompt after the idle check (the signature moved)" {
  ready_lane alpha
  flip_after_screen_reads 1 busy
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane's state moved after the idle check"
  assert_output --partial "before /clear was sent: nothing was submitted (nothing was typed)"
  run keys_sent
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
}

@test "a self-started turn that already ended (busy, then idle again) still stops the clear before any key" {
  ready_lane alpha
  mkdir -p "$LANES_TEST_TMP/shim"
  shim_on_capture "f='$(session_file)'; jq -c '.statusUpdatedAt += 1' \"\$f\" >\"\$f.x\" && mv \"\$f.x\" \"\$f\""
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane's state moved after the idle check (now idle"
  run keys_sent
  assert_output 0
}

@test "a draft typed after the wait for idle is caught by the check before typing: the draft left as typed" {
  ready_lane alpha
  shim_on_capture "'$(command -v tmux)' -L '$LANES_TMUX_SOCKET' send-keys -t '$PANE' -l -- 'late'; sleep 0.3"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "holds text ('late')"
  assert_output --partial "before /clear was sent"
  run keys_sent # the human's own "late" only
  assert_output 1
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c '^❯.*[^a-z]late\$'"
  assert_output 1
}

@test "register takes the pane away from any other lane entry that holds it" {
  ready_lane alpha
  register_beta_on_pane
  run reg alpha '[.tmux_pane, .clear_ready] | @json'
  assert_output '[null,false]'
  run reg beta .tmux_pane
  assert_output "$PANE"
}

@test "a second lane registered on alpha's pane: lanes clear alpha refuses and types nothing" {
  ready_lane alpha
  register_beta_on_pane
  run "$LANES" clear alpha
  assert_failure
  run keys_sent
  assert_output 0
  run submitted /clear
  assert_output 0
}

@test "clear refuses when another registry entry names the lane's pane" {
  ready_lane alpha
  jq -nc --arg p "$PANE" '{lane:"beta",session_id:"sb",role:"lane",tmux_pane:$p,cwd:"/",used_pct:null,clear_ready:false}' \
    >"$LANES_DATA_DIR/lanes/beta.json"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "is also registered to lane beta"
  run keys_sent
  assert_output 0
}

@test "a registration on the lane's pane while clear waits is refused before any key" {
  ready_lane alpha
  clear_during_wait register_beta_on_pane
  assert [ "$RC" -ne 0 ]
  run keys_sent
  assert_output 0
  run submitted /clear
  assert_output 0
}

@test "a draft typed during the idle gap is caught by the final screen check: nothing is typed into it" {
  ready_lane alpha
  export LANES_IDLE_GAP=2
  "$LANES" clear alpha >"$LANES_TEST_TMP/out" 2>&1 &
  pid=$!
  sleep 1
  lanes_tmux send-keys -t "$PANE" -l -- "draft"
  rc=0
  wait "$pid" || rc=$?
  assert [ "$rc" -ne 0 ]
  run cat "$LANES_TEST_TMP/out"
  assert_output --partial "holds text ('draft')"
  run keys_sent # the human's own "draft" only
  assert_output 1
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯ draft\$'"
  assert_output 1
}

@test "a RESUME block rewritten after clear-ready, with HEAD and tree unchanged, is refused" {
  export LANES_JOURNAL_DIR="$LANES_TEST_TMP/journal"
  make_repo
  mkdir -p "$LANES_JOURNAL_DIR"
  write_resume alpha
  cp "$WORK/.lanes/next-alpha.md" "$LANES_JOURNAL_DIR/next-alpha.md"
  start_fake alpha
  run "$LANES" clear-ready --lane alpha
  assert_success
  printf '\n' >>"$LANES_JOURNAL_DIR/next-alpha.md"
  sed 's/run the tests for A1/a newer next step/' "$LANES_JOURNAL_DIR/next-alpha.md" >"$LANES_TEST_TMP/n" &&
    mv "$LANES_TEST_TMP/n" "$LANES_JOURNAL_DIR/next-alpha.md"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the RESUME block changed since clear-ready"
  run keys_sent
  assert_output 0
}

@test "under LC_ALL=C a clear still reads the input line and lands" {
  ready_lane alpha
  LC_ALL=C run "$LANES" clear alpha
  assert_success
  run submitted /clear
  assert_output 1
}

@test "a human draft that lands just before our first key: nothing is deleted, since a Backspace count could eat it" {
  ready_lane alpha FAKE_DRAFT_AT_FIRST_KEY=1
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "ahead of ours"
  assert_output --partial "nothing was submitted or deleted"
  run submitted /clear
  assert_output 0
  run grep -c '^BURST' "$FAKE_LOG"
  assert_output 1
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯ human draft/clear\$'"
  assert_output 1
}

# still_ready <advice>: the refusal in OUT names <advice> and not the pane-ownership advice, nothing was typed, and
# alpha is still clear-ready, so the rerun after the fix needs no new handshake.
still_ready() {
  [[ "$OUT" == *"$1"*"then run 'lanes clear alpha' again"* ]]
  [[ "$OUT" != *"registered last"* ]]
  run keys_sent
  assert_output 0
  run reg alpha .clear_ready
  assert_output true
  run state alpha .handshake.state
  assert_output ready
}

@test "copy mode entered while clear waits for idle is refused before any key, and clear-ready is kept" {
  ready_lane alpha
  clear_during_wait lanes_tmux copy-mode -t "$PANE"
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"is in copy mode"* ]]
  still_ready "leave copy mode in pane $PANE"
  lanes_tmux send-keys -t "$PANE" -X cancel
  run "$LANES" clear alpha
  assert_success
}

@test "synchronize-panes turned on while clear waits for idle is refused before any key, and clear-ready is kept" {
  ready_lane alpha
  lanes_tmux split-window -d -t "$PANE" "sleep 300"
  clear_during_wait lanes_tmux set-window-option -t "$PANE" synchronize-panes on
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"has synchronize-panes on"* ]]
  still_ready "turn synchronize-panes off"
  lanes_tmux set-window-option -t "$PANE" synchronize-panes off
  run "$LANES" clear alpha
  assert_success
}

@test "Claude Code stopped (Ctrl-Z) while clear waits for idle is refused before any key, and clear-ready is kept" {
  make_repo
  write_resume alpha
  shell_pane
  fake_from_shell alpha "bash '$LANES_TEST_TMP/run-fake' alpha"
  run "$LANES" clear-ready --lane alpha
  assert_success
  clear_during_wait stop_fake
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"is not the foreground program of pane $PANE"* ]]
  still_ready "bring Claude Code back to the foreground of pane $PANE"
  # The shell's fg resumes the job in the foreground, as a human does.
  lanes_tmux send-keys -t "$PANE" -l -- fg
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "the fake took the terminal back" grep -qx CONT "$FAKE_LOG"
  run "$LANES" clear alpha
  assert_success
}

@test "a pane found on another tmux server while clear waits is refused, and clear-ready is dropped" {
  ready_lane alpha
  other_server() { local f="$LANES_DATA_DIR/lanes/alpha.json"; jq '.tmux_pid = 1' "$f" >"$f.x" && mv "$f.x" "$f"; }
  clear_during_wait other_server
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"is on another tmux server"*"registered last"* ]]
  run keys_sent
  assert_output 0
  run reg alpha .clear_ready
  assert_output false
  run state alpha .handshake.state
  assert_output stale
}

@test "a recycled pane id: after a tmux restart another claude has the registered pane id, and nothing is sent" {
  ready_lane alpha
  lanes_tmux kill-server
  sleep 0.3
  lanes_tmux new-session -d -s foreign -x 160 -y 40 -c "$WORK" env LANES_DATA_DIR="$LANES_DATA_DIR" \
    LANES_TMUX_SOCKET="$LANES_TMUX_SOCKET" LANES_BIN="$LANES" FAKE_LANE=zzz FAKE_LOG="$FAKE_LOG" FAKE_NO_REGISTER=1 \
    bash -c 'exec -a claude bash "$0"' "$FAKE"
  wait_for "foreign prompt" pane_has '❯'
  [ "$(lanes_tmux display -p '#{pane_id}')" = "$(reg alpha .tmux_pane)" ]
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "no Claude Code session file"
  run keys_sent
  assert_output 0
  run submitted /clear
  assert_output 0
}

@test "register records the tmux server pid, the pane pid and Claude Code's pid (here the pane's own process)" {
  ready_lane alpha
  run reg alpha '[.tmux_pid, .pane_pid, .claude_pid] | map(type) | @json'
  assert_output '["number","number","number"]'
  run reg alpha '[.pane_pid, .claude_pid] | map(tostring) | join(" ")'
  assert_output "$FAKE_PID $FAKE_PID"
}

# shim_on_keys <match> <action>: a tmux shim that runs <action> once, right after a tmux call whose arguments contain
# <match> (for example "-l -- /clear" or " Enter").
shim_on_keys() {
  local m="$LANES_TEST_TMP/shim-fired"
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\n%q "$@"\nrc=$?\nif [[ " $* " == *%q* && ! -f %q ]]; then : >%q; %s; fi\nexit $rc\n' \
    "$(command -v tmux)" "$1" "$m" "$m" "$2" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

@test "a turn that starts between two typed chunks stops the typing, and the chunk already typed is deleted" {
  ready_lane alpha
  shim_on_keys "-l -- /cl" "f='$(session_file)'; jq -c '.statusUpdatedAt += 1' \"\$f\" >\"\$f.x\" && mv \"\$f.x\" \"\$f\""
  LANES_SEND_CHUNK=3 PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane's state moved after the idle check"
  assert_output --partial "our typed text was deleted"
  # Two bursts: the first chunk "/cl" and the Backspaces that delete it; the chunk "ear" is never sent.
  run bash -c "grep '^BURST' '$FAKE_LOG'"
  assert_output "BURST 3
BURST 3"
  wait_for "typed chunk deleted" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q '/cl'"
  run submitted /clear
  assert_output 0
}

@test "our typed text is never erased into a pane that entered copy mode: it is left and reported" {
  ready_lane alpha
  shim_on_keys "-l -- /clear" "'$(command -v tmux)' -L '$LANES_TMUX_SOCKET' copy-mode -t '$PANE'"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "our typed text was left in the input line of $PANE, because pane $PANE is in copy mode"
  assert_output --partial "leave copy mode in pane $PANE"
  run reg alpha .clear_ready
  assert_output true
  run state alpha .handshake.state
  assert_output ready
  lanes_tmux send-keys -t "$PANE" -X cancel
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c '/clear\$'"
  assert_output 1
  run submitted /clear
  assert_output 0
}

@test "a tree edit while /clear is typed stops it before Enter, and the typed /clear is deleted" {
  ready_lane alpha
  shim_on_keys "-l -- /clear" "printf 'z\\\\n' >>'$WORK/file'"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "uncommitted changes"
  run submitted /clear
  assert_output 0
  wait_for "typed /clear deleted" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q $'^❯ /clear'"
  run state alpha .handshake.state
  assert_output stale
}

@test "the Enter retry checks again too: a tree edit after a lost Enter means no second Enter, and the message says it may land late" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=1
  shim_on_keys " Enter" "printf 'z\\\\n' >>'$WORK/file'"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "/clear was sent to $PANE once, then the tree stopped being clean"
  assert_output --partial "it may have been taken late"
  run grep -c ENTER-SWALLOWED "$FAKE_LOG"
  assert_output 1
  run submitted /clear
  assert_output 0
  # The record stays at sending, so a rerun finds out whether the /clear landed.
  run state alpha .handshake.state
  assert_output sending
}

# shim_key_after_verify <keys>: a tmux shim that, once /clear has been typed, waits for the next screen read (the
# arrival check) and then types <keys> into the pane, as a human would, before the last check and Enter.
shim_key_after_verify() {
  local typed="$LANES_TEST_TMP/typed" done="$LANES_TEST_TMP/human-typed"
  mkdir -p "$LANES_TEST_TMP/shim"
  cat >"$LANES_TEST_TMP/shim/tmux" <<SHIM
#!/usr/bin/env bash
"$(command -v tmux)" "\$@"
rc=\$?
[[ " \$* " == *"-l -- /clear"* ]] && : >"$typed"
if [[ " \$* " == *" capture-pane "* && -f "$typed" && ! -f "$done" ]]; then
  : >"$done"
  "$(command -v tmux)" -L "$LANES_TMUX_SOCKET" send-keys -t "$PANE" -l -- "$1"
  sleep 0.3
fi
exit \$rc
SHIM
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

@test "a human key added after the arrival check stops Enter, and the human's text is never erased" {
  ready_lane alpha
  shim_key_after_verify "x"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the input line changed"
  run submitted /clear
  assert_output 0
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯ /clearx\$'"
  assert_output 1
}
