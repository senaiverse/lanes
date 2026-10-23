#!/usr/bin/env bats
# Public seam: `lanes clear <lane>` against a fake Claude pane. Everything clear-ready proved is proved again at the
# last moment: after the waits and the final screen check (before Escape), and again just before Enter.

load helper

submitted() { grep -c "^SUBMIT $1" "$FAKE_LOG" || true; }
escapes() { grep -c '^ESC$' "$FAKE_LOG" || true; }

# hold_background / release_background: a Stop that reports a running background task keeps wait_idle waiting.
hold_background() {
  jq -nc --arg s "$(reg alpha .session_id)" '{session_id:$s,background_tasks:[{"id":"b1"}]}' | "$LANES" hook stop
}
release_background() {
  jq -nc --arg s "$(reg alpha .session_id)" '{session_id:$s,background_tasks:[]}' | "$LANES" hook stop
}

# clear_during_wait <change command...>: start `lanes clear alpha` while a background task holds it in wait_idle, run
# the change, release the task, and leave the clear's exit code in RC and its output in OUT.
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

@test "a tree made dirty while clear waits for idle is refused before Escape" {
  ready_lane alpha
  clear_during_wait dirty_tree
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"uncommitted changes"* ]]
  run escapes
  assert_output 0
  run submitted /clear
  assert_output 0
  run state alpha .handshake.state
  assert_output stale
  run reg alpha .clear_ready
  assert_output false
}

@test "a commit pushed while clear waits for idle is refused before Escape" {
  ready_lane alpha
  clear_during_wait commit_and_push
  assert [ "$RC" -ne 0 ]
  [[ "$OUT" == *"HEAD moved since clear-ready"* ]]
  run escapes
  assert_output 0
  run submitted /clear
  assert_output 0
}

@test "a lane restarted after clear-ready (a new session, the same pane, no prompt yet) is refused as a changed session" {
  ready_lane alpha
  hook_json SessionStart restarted alpha startup | TMUX_PANE="$PANE" "$LANES" register >/dev/null 2>&1
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the session changed since clear-ready"
  run escapes
  assert_output 0
}

@test "a human prompt right after the Escape stops the clear before Enter, and the typed /clear is deleted" {
  ready_lane alpha FAKE_ON_ESC=prompt FAKE_TURN_MS=60000
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane received a new prompt"
  run grep -c '^HUMAN-PROMPT$' "$FAKE_LOG"
  assert_output 1
  run submitted /clear
  assert_output 0
  wait_for "typed /clear deleted" bash -c "! tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q $'^❯ /clear'"
  run state alpha .handshake.state
  assert_output stale
}

# flip_after_screen_reads <n> <prompt|busy>: a tmux shim on PATH that, right after the n-th capture-pane (the final
# screen check), fires a real UserPromptSubmit for alpha, or only sets the busy flag.
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
      f="$LANES_DATA_DIR/lanes/state/alpha.json"
      jq '.busy = true | .busy_since = (now | floor)' "\$f" >"\$f.x" && mv "\$f.x" "\$f"
    fi
  fi
fi
exit \$rc
EOF
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

@test "a prompt arriving after the final screen check is refused before Escape" {
  ready_lane alpha
  flip_after_screen_reads 2 prompt
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the lane received a new prompt since clear-ready"
  run escapes
  assert_output 0
}

@test "Escape is never sent while the hook flag says busy, even with the prompt count unchanged" {
  ready_lane alpha
  flip_after_screen_reads 2 busy
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "busy at the moment of sending"
  run escapes
  assert_output 0
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
  run escapes
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
  run escapes
  assert_output 0
}

@test "a registration on the lane's pane while clear waits is refused before Escape" {
  ready_lane alpha
  clear_during_wait register_beta_on_pane
  assert [ "$RC" -ne 0 ]
  run escapes
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
  run escapes
  assert_output 0
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯ draft\$'"
  assert_output 1
}

@test "a busy flag older than LANES_BUSY_TTL counts as idle (Stop never fired after an interrupt)" {
  ready_lane alpha
  jq '.busy = true | .busy_since = (now - 100 | floor)' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" &&
    mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  LANES_BUSY_TTL=50 run "$LANES" clear alpha --wait 1
  assert_success
  run submitted /clear
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
  run escapes
  assert_output 0
}

@test "under LC_ALL=C a multibyte spinner glyph above the input box still vetoes" {
  make_repo
  write_resume alpha
  start_fake alpha FAKE_TRANSCRIPT=$'● reply\n✶ Perusing… (3s · ↓ 175 tokens)'
  "$LANES" clear-ready --lane alpha >/dev/null
  LC_ALL=C run "$LANES" clear alpha
  assert_failure
  assert_output --partial "spinner"
  run escapes
  assert_output 0
}

@test "transcript text that quotes '/goal active' above the box does not veto the clear" {
  ready_lane alpha FAKE_TRANSCRIPT="Note: the footer says /goal active here"
  run "$LANES" clear alpha
  assert_success
  run submitted /clear
  assert_output 1
}

@test "transcript text that ends with 'Do you want to' above the box does not veto the clear" {
  ready_lane alpha FAKE_TRANSCRIPT="I changed it. Do you want to review?"
  run "$LANES" clear alpha
  assert_success
}

@test "a human draft that appears at the Escape is left exactly as typed, and nothing is typed into it" {
  ready_lane alpha FAKE_ON_ESC=draft
  run "$LANES" clear alpha
  assert_failure
  run submitted /clear
  assert_output 0
  run bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -c $'^❯ human draft\$'"
  assert_output 1
}

@test "a human draft that lands just before our first key: only our characters are erased" {
  ready_lane alpha FAKE_ON_ESC=draft-late
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "our typed text was deleted"
  run submitted /clear
  assert_output 0
  wait_for "draft restored" bash -c "tmux -L '$LANES_TMUX_SOCKET' capture-pane -p -t '$PANE' | grep -q $'^❯ human draft\$'"
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
  assert_output --partial "now runs another process"
  run escapes
  assert_output 0
  run submitted /clear
  assert_output 0
}

@test "register records the tmux server pid and the pane pid of the lane's pane" {
  ready_lane alpha
  run reg alpha '[.tmux_pid, .pane_pid] | map(type) | @json'
  assert_output '["number","number"]'
  run reg alpha .pane_pid
  assert_output "$(lanes_tmux display -p -t "$PANE" '#{pane_pid}')"
}

# shim_on_keys <match> <action>: a tmux shim that runs <action> once, right after a tmux call whose arguments contain
# <match> (for example " Escape" or " Enter").
shim_on_keys() {
  local m="$LANES_TEST_TMP/shim-fired"
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\n%q "$@"\nrc=$?\nif [[ " $* " == *%q* && ! -f %q ]]; then : >%q; %s; fi\nexit $rc\n' \
    "$(command -v tmux)" "$1" "$m" "$m" "$2" >"$LANES_TEST_TMP/shim/tmux"
  chmod +x "$LANES_TEST_TMP/shim/tmux"
}

@test "a tree edit at the Escape stops /clear before anything is typed" {
  ready_lane alpha
  shim_on_keys " Escape" "printf 'z\\\\n' >>'$WORK/file'"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "uncommitted changes"
  run grep -c '^BURST' "$FAKE_LOG"
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

@test "the Enter retry checks again too: a tree edit after a lost Enter means no second Enter" {
  ready_lane alpha FAKE_SWALLOW_ENTERS=1
  shim_on_keys " Enter" "printf 'z\\\\n' >>'$WORK/file'"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear alpha
  assert_failure
  assert_output --partial "uncommitted changes"
  run grep -c ENTER-SWALLOWED "$FAKE_LOG"
  assert_output 1
  run submitted /clear
  assert_output 0
}
