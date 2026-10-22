#!/usr/bin/env bats
# Public seam: the lanes-job executable. Each test uses a temp LANES_DATA_DIR and its own tmux socket.

load helper

@test "a job that succeeds writes STATUS with EXIT:0, start, end and the log path" {
  run "$JOB" run ok -- bash -c 'echo hello-from-job'
  [ "$status" -eq 0 ]
  run "$JOB" wait ok --timeout 20
  [ "$status" -eq 0 ]
  run cat "$(status_file ok)"
  [[ "$output" == *"EXIT:0"* ]]
  [[ "$output" == *"START:"* ]]
  [[ "$output" == *"END:"* ]]
  [[ "$output" == *"LOG:$LANES_DATA_DIR/jobs/ok/log"* ]]
  run cat "$LANES_DATA_DIR/jobs/ok/log"
  [[ "$output" == *"hello-from-job"* ]]
}

@test "a job that fails records its exact exit code" {
  "$JOB" run bad -- bash -c 'echo boom >&2; exit 7'
  "$JOB" wait bad --timeout 20
  run cat "$(status_file bad)"
  [[ "$output" == *"EXIT:7"* ]]
  run cat "$LANES_DATA_DIR/jobs/bad/log"
  [[ "$output" == *"boom"* ]]
}

@test "arguments with spaces and quotes reach the command unchanged" {
  "$JOB" run args -- printf '%s|' 'a b' "it's"
  "$JOB" wait args --timeout 20
  [ "$(cat "$LANES_DATA_DIR/jobs/args/log")" = "a b|it's|" ]
}

@test "a job killed mid-run still gets a STATUS" {
  "$JOB" run victim -- sleep 60
  [ ! -e "$(status_file victim)" ]
  tmux -L "$LANES_TMUX_SOCKET" kill-window -t "lanes-jobs:victim"
  run "$JOB" wait victim --timeout 20
  [ "$status" -eq 0 ]
  run cat "$(status_file victim)"
  [[ "$output" =~ EXIT:(129|143) ]]
  [[ "$output" == *"END:"* ]]
}

@test "status reports RUNNING, then the finished state" {
  "$JOB" run slow -- sleep 60
  run "$JOB" status slow
  [ "$status" -eq 3 ]
  [[ "$output" == *"RUNNING"* ]]
  tmux -L "$LANES_TMUX_SOCKET" kill-window -t "lanes-jobs:slow"
  "$JOB" wait slow --timeout 20
  run "$JOB" status slow
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXIT:"* ]]
}

@test "status of an unknown job is an error" {
  mkdir -p "$LANES_DATA_DIR"
  run "$JOB" status nothing
  [ "$status" -eq 2 ]
  [[ "$output" == *"lanes-job:"* ]]
}

@test "a job whose runner died without a STATUS is reported LOST" {
  mkdir -p "$LANES_DATA_DIR/jobs/ghost"
  sleep 0.01 &
  dead=$!
  wait "$dead"
  echo "$dead" >"$LANES_DATA_DIR/jobs/ghost/pid"
  run "$JOB" status ghost
  [ "$status" -eq 4 ]
  [[ "$output" == *"LOST"* ]]
}

@test "list shows each job with its state" {
  "$JOB" run one -- true
  "$JOB" run two -- sleep 60
  "$JOB" wait one --timeout 20
  run "$JOB" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"one"*"EXIT:0"* ]]
  [[ "$output" == *"two"*"RUNNING"* ]]
}

@test "a full pool refuses the next job with exit 75 and starts nothing" {
  export LANES_POOL_SIZE=1
  "$JOB" run first -- sleep 60
  run "$JOB" run second -- true
  [ "$status" -eq 75 ]
  [[ "$output" == *"lanes-job:"*"pool"* ]]
  [ ! -e "$LANES_DATA_DIR/jobs/second" ]
}

@test "a slot is free again when its job ends" {
  export LANES_POOL_SIZE=1
  "$JOB" run first -- true
  "$JOB" wait first --timeout 20
  run "$JOB" run second -- true
  [ "$status" -eq 0 ]
}

@test "pools are independent: --slot names the pool" {
  export LANES_POOL_SIZE=1
  "$JOB" run a --slot build -- sleep 60
  run "$JOB" run b --slot test -- true
  [ "$status" -eq 0 ]
  run "$JOB" run c --slot build -- true
  [ "$status" -eq 75 ]
}

@test "a stale lock left by a crashed holder is recovered" {
  export LANES_POOL_SIZE=1
  mkdir -p "$LANES_DATA_DIR/locks"
  sleep 0.01 &
  dead=$!
  wait "$dead"
  ln -s "$dead" "$LANES_DATA_DIR/locks/jobs-1.lock"
  run "$JOB" run after-crash -- true
  [ "$status" -eq 0 ]
  "$JOB" wait after-crash --timeout 20
  grep -q 'EXIT:0' "$(status_file after-crash)"
}

@test "slot acquire and release: a held slot refuses, a released one is free" {
  export LANES_POOL_SIZE=1
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 75 ]
  run "$JOB" slot release p --pid $$
  [ "$status" -eq 0 ]
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 0 ]
}

@test "slot release exits 0 for a held slot in a larger pool, and is a no-op for a pid that holds none" {
  export LANES_POOL_SIZE=2
  run "$JOB" slot acquire p --pid $$
  [ "$output" = "1" ]
  run "$JOB" slot release p --pid $$
  [ "$status" -eq 0 ]
  [ ! -e "$LANES_DATA_DIR/locks/p-1.lock" ]
  run "$JOB" slot release p --pid $$
  [ "$status" -eq 0 ]
}

@test "slot acquire hands out distinct slots up to the pool size" {
  export LANES_POOL_SIZE=2
  run "$JOB" slot acquire p --pid $$
  [ "$output" = "1" ]
  sleep 30 &
  other=$!
  run "$JOB" slot acquire p --pid "$other"
  [ "$output" = "2" ]
  kill "$other"
}

@test "slot acquire takes a stale slot from a dead pid" {
  export LANES_POOL_SIZE=1
  mkdir -p "$LANES_DATA_DIR/locks"
  sleep 0.01 &
  dead=$!
  wait "$dead"
  ln -s "$dead" "$LANES_DATA_DIR/locks/p-1.lock"
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "the symlink mutex fallback behaves the same when flock is unavailable" {
  export LANES_NO_FLOCK=1 LANES_POOL_SIZE=1
  "$JOB" run first -- sleep 60
  run "$JOB" run second -- true
  [ "$status" -eq 75 ]
  tmux -L "$LANES_TMUX_SOCKET" kill-window -t "lanes-jobs:first"
  "$JOB" wait first --timeout 20
  run "$JOB" run third -- true
  [ "$status" -eq 0 ]
  [ ! -L "$LANES_DATA_DIR/locks/.mutex.owner" ]
}

@test "a duplicate running name is refused" {
  "$JOB" run dup -- sleep 60
  run "$JOB" run dup -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"already running"* ]]
}

@test "a finished name can be run again and starts a fresh log" {
  "$JOB" run again -- echo first
  "$JOB" wait again --timeout 20
  "$JOB" run again -- echo second
  "$JOB" wait again --timeout 20
  [ "$(cat "$LANES_DATA_DIR/jobs/again/log")" = "second" ]
}

@test "names with spaces, slashes or a leading dot are rejected" {
  for bad in "a b" "a/b" "../x" ".hidden" "" 'a;b'; do
    run "$JOB" run "$bad" -- true
    [ "$status" -eq 2 ]
    [[ "$output" == *"lanes-job:"*"name"* ]]
  done
  [ ! -e "$LANES_DATA_DIR/jobs" ] || [ -z "$(ls "$LANES_DATA_DIR/jobs")" ]
}

@test "wait times out with exit 124 while the job still runs" {
  "$JOB" run sleeper -- sleep 60
  run "$JOB" wait sleeper --timeout 1
  [ "$status" -eq 124 ]
  [[ "$output" == *"lanes-job:"*"timed out"* ]]
}

@test "missing tmux is a clear error" {
  # The suite's own Bash runs the script: macOS /bin/bash is 3.2, which stops at the Bash 4 guard before tmux is checked.
  run env PATH=/nonexistent "$BASH" "$JOB" run x -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"tmux"* ]]
}

@test "without LANES_DATA_DIR state lives under XDG_STATE_HOME/lanes, created on demand" {
  unset LANES_DATA_DIR
  export XDG_STATE_HOME="$WORK/xdg"
  run "$JOB" list
  [ "$status" -eq 0 ]
  "$JOB" run xdg -- true
  "$JOB" wait xdg --timeout 20
  [ -s "$XDG_STATE_HOME/lanes/jobs/xdg/STATUS" ]
}

@test "without LANES_DATA_DIR and XDG_STATE_HOME state lives under HOME/.local/state/lanes" {
  unset LANES_DATA_DIR XDG_STATE_HOME
  export HOME="$WORK/home"
  mkdir -p "$HOME"
  "$JOB" run home -- true
  "$JOB" wait home --timeout 20
  [ -s "$HOME/.local/state/lanes/jobs/home/STATUS" ]
}

@test "run without a command is a usage error" {
  run "$JOB" run nocmd
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "status and wait reject a name that is a path" {
  mkdir -p "$LANES_DATA_DIR/jobs" "$LANES_DATA_DIR/x"
  echo "EXIT:0" >"$LANES_DATA_DIR/x/STATUS"
  run "$JOB" status ../x
  [ "$status" -eq 2 ]
  [[ "$output" == *"lanes-job:"*"name"* ]]
  run "$JOB" wait ../x --timeout 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"lanes-job:"*"name"* ]]
}

# race_six: six concurrent runs against a pool of two; exactly two may start.
race_six() {
  export LANES_POOL_SIZE=2
  local i pids=()
  for i in 1 2 3 4 5 6; do
    ("$JOB" run "race$i" -- sleep 60 >/dev/null 2>&1 && echo 0 >"$WORK/rc$i" || echo $? >"$WORK/rc$i") &
    pids+=($!)
  done
  wait "${pids[@]}"
  local started=0 full=0 rc
  for i in 1 2 3 4 5 6; do
    rc="$(cat "$WORK/rc$i")"
    if [ "$rc" -eq 0 ]; then started=$((started + 1)); elif [ "$rc" -eq 75 ]; then full=$((full + 1)); fi
  done
  [ "$started" -eq 2 ]
  [ "$full" -eq 4 ]
}

@test "six concurrent runs against a pool of two start exactly two (flock)" {
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  race_six
}

@test "six concurrent runs against a pool of two start exactly two (symlink fallback)" {
  export LANES_NO_FLOCK=1
  race_six
}

@test "symlink mutex held by a live owner is not broken, and the wait fails loudly" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1
  mkdir -p "$LANES_DATA_DIR/locks"
  sleep 30 &
  owner=$!
  ln -s "$owner" "$LANES_DATA_DIR/locks/.mutex.owner"
  run "$JOB" slot acquire p --pid $$
  kill "$owner"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"mutex"* ]]
  [ "$(readlink "$LANES_DATA_DIR/locks/.mutex.owner")" = "$owner" ]
}

@test "symlink mutex left by a dead owner is broken and released afterwards" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1
  mutex_of_dead_owner
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$LANES_DATA_DIR/locks" | grep '^\.mutex')" ]
}

@test "two waiters that read the same dead symlink-mutex owner never both hold the mutex" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1 JOB
  fake_tmux hold
  mutex_of_dead_owner
  # Waiter B pauses after reading the dead owner; waiter A then breaks the mutex and holds it inside fake tmux.
  write_hook '[ "$1" = before-break ] && [ ! -e "$HOOK_DIR/a.pid" ] || exit 0
LANES_TEST_HOOK= "$JOB" run a -- true >"$HOOK_DIR/a.out" 2>&1 &
echo "$!" >"$HOOK_DIR/a.pid"
for _ in $(seq 200); do [ -e "$HOOK_DIR/inside" ] && exit 0; sleep 0.05; done
exit 1'
  export LANES_TEST_HOOK="$WORK/hook"
  run "$JOB" slot acquire p --pid $$
  unset LANES_TEST_HOOK
  [ -e "$WORK/inside" ]
  [ "$(readlink "$LANES_DATA_DIR/locks/.mutex.owner")" = "$(cat "$WORK/a.pid")" ]
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"mutex"* ]]
  [ ! -e "$LANES_DATA_DIR/locks/p-1.lock" ]
  touch "$WORK/go"
  wait_for 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$WORK/a.pid")"
  [ ! -L "$LANES_DATA_DIR/locks/.mutex.owner" ]
}

@test "two breakers of one dead symlink-mutex owner never both hold the mutex" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1 JOB
  fake_tmux hold
  mutex_of_dead_owner
  # Breaker B pauses after its own check of the dead owner, just before the removal; breaker C runs meanwhile.
  write_hook '[ "$1" = before-remove ] && [ ! -e "$HOOK_DIR/c.pid" ] || exit 0
LANES_TEST_HOOK= "$JOB" run c -- true >"$HOOK_DIR/c.out" 2>&1 &
c=$!
echo "$c" >"$HOOK_DIR/c.pid"
for _ in $(seq 200); do { [ -e "$HOOK_DIR/inside" ] || ! kill -0 "$c" 2>/dev/null; } && exit 0; sleep 0.05; done
exit 1'
  export LANES_TEST_HOOK="$WORK/hook"
  run "$JOB" slot acquire p --pid $$
  unset LANES_TEST_HOOK
  touch "$WORK/go"
  [ -e "$WORK/c.pid" ]
  # B took the mutex and the slot, so C must never have got inside, and it gave up loudly.
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/inside" ]
  [[ "$(cat "$WORK/c.out")" == *"lanes-job:"*"mutex"* ]]
}

@test "a breaker killed between its marker and the removal does not wedge the symlink mutex" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1
  mutex_of_dead_owner
  breaker_killed_before_remove
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 0 ]
  [ "$(readlink "$LANES_DATA_DIR/locks/p-1.lock")" = "$$" ]
  [ -z "$(ls -A "$LANES_DATA_DIR/locks" | grep '^\.mutex')" ]
}

@test "two breakers that take over a dead breaker's marker never both hold the mutex" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1 JOB
  fake_tmux hold
  mutex_of_dead_owner
  breaker_killed_before_remove
  # Breaker C takes over the dead breaker's marker and pauses just before the removal; breaker D runs meanwhile.
  write_hook '[ "$1" = before-remove ] && [ ! -e "$HOOK_DIR/d.pid" ] || exit 0
LANES_TEST_HOOK= "$JOB" run d -- true >"$HOOK_DIR/d.out" 2>&1 &
d=$!
echo "$d" >"$HOOK_DIR/d.pid"
for _ in $(seq 200); do { [ -e "$HOOK_DIR/inside" ] || ! kill -0 "$d" 2>/dev/null; } && exit 0; sleep 0.05; done
exit 1'
  export LANES_TEST_HOOK="$WORK/hook"
  run "$JOB" slot acquire p --pid $$
  unset LANES_TEST_HOOK
  touch "$WORK/go"
  [ -e "$WORK/d.pid" ]
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/inside" ]
  [[ "$(cat "$WORK/d.out")" == *"lanes-job:"*"mutex"* ]]
}

@test "a live holder that has just taken the fallback mutex is never broken by a waiter that reaches its timeout" {
  sleep 30 &
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1 JOB KEEPER=$!
  # Holder H pauses as soon as it has the mutex; waiter W runs its whole timeout meanwhile, wanting a slot for KEEPER.
  write_hook '[ "$1" = after-acquire ] && [ ! -e "$HOOK_DIR/w.pid" ] || exit 0
LANES_TEST_HOOK= "$JOB" slot acquire p --pid "$KEEPER" >"$HOOK_DIR/w.out" 2>&1 &
w=$!
echo "$w" >"$HOOK_DIR/w.pid"
wait "$w"
echo "$?" >"$HOOK_DIR/w.status"'
  export LANES_TEST_HOOK="$WORK/hook"
  run "$JOB" slot acquire p --pid $$
  unset LANES_TEST_HOOK
  kill "$KEEPER"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/w.status")" -ne 0 ]
  [[ "$(cat "$WORK/w.out")" == *"lanes-job:"*"mutex"* ]]
  [ "$(readlink "$LANES_DATA_DIR/locks/p-1.lock")" = "$$" ]
  [ ! -e "$LANES_DATA_DIR/locks/p-2.lock" ]
}

# mutex_of_dead_owner: a fallback mutex whose owner pid has exited.
mutex_of_dead_owner() {
  local dead
  mkdir -p "$LANES_DATA_DIR/locks"
  sleep 0.01 &
  dead=$!
  wait "$dead"
  ln -s "$dead" "$LANES_DATA_DIR/locks/.mutex.owner"
}

# breaker_killed_before_remove: a breaker dies by SIGKILL after taking its marker and before removing the mutex.
breaker_killed_before_remove() {
  write_hook '[ "$1" = before-remove ] || exit 0
kill -9 "$PPID"'
  LANES_TEST_HOOK="$WORK/hook" run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 137 ]
  [ -L "$LANES_DATA_DIR/locks/.mutex.owner" ]
}

# fake_tmux <mode>: a tmux on PATH that behaves per mode (see the script).
fake_tmux() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
args=" $* "
case "$FAKE_TMUX_MODE" in
  hold) # the caller holds its mutex here until the test creates "go"
    touch "$FAKE_TMUX_DIR/inside"
    for _ in $(seq 400); do [ -e "$FAKE_TMUX_DIR/go" ] && break; sleep 0.05; done
    exit 1 ;;
  noclaim) # a window opens, but its runner never takes ownership
    [[ "$args" == *" new-window "* ]] && echo @1
    [[ "$args" == *" kill-window "* ]] && touch "$FAKE_TMUX_DIR/killed"
    exit 0 ;;
esac
[[ "$args" == *" has-session "* ]] && { [ "$FAKE_TMUX_MODE" = window ] && exit 0; exit 1; }
if [ "$FAKE_TMUX_MODE" = steal ]; then ln -sfn 999999 "$LANES_DATA_DIR/locks/.mutex.owner"; fi
exit 1
FAKE
  chmod +x "$WORK/bin/tmux"
  export PATH="$WORK/bin:$PATH" FAKE_TMUX_MODE="$1" FAKE_TMUX_DIR="$WORK"
}

# launcher_killed_after_window: the launcher dies by SIGKILL right after it opens the window, before any handoff.
launcher_killed_after_window() {
  export LANES_POOL_SIZE=1
  write_hook '[ "$1" = after-window ] || exit 0
echo "$PPID" >"$HOOK_DIR/launcher"
kill -9 "$PPID"'
  local jd="$LANES_DATA_DIR/jobs/live" runner pidfile slot
  export LANES_TEST_HOOK="$WORK/hook"
  # The command records, at its own start, its runner's pid and who the job record and the slot name as owner.
  run "$JOB" run live -- bash -c 'echo "$PPID $(cat "$1") $(readlink "$2")"; sleep 60' _ "$jd/pid" "$LANES_DATA_DIR/locks/jobs-1.lock"
  unset LANES_TEST_HOOK
  [ "$status" -eq 137 ]
  wait_for 10 test -s "$jd/log"
  read -r runner pidfile slot <"$jd/log"
  [ "$runner" != "$(cat "$WORK/launcher")" ]
  [ "$pidfile" = "$runner" ]
  [ "$slot" = "$runner" ]
  run "$JOB" status live
  [ "$status" -eq 3 ]
  run "$JOB" run live -- true
  [[ "$output" == *"lanes-job:"*"already running"* ]]
  run "$JOB" run other -- true
  [ "$status" -eq 75 ]
}

@test "a launcher killed right after it opens the window leaves the job owned by its live runner (flock)" {
  command -v flock >/dev/null 2>&1 || skip "flock not installed"
  launcher_killed_after_window
}

@test "a launcher killed right after it opens the window leaves the job owned by its live runner (symlink fallback)" {
  export LANES_NO_FLOCK=1
  launcher_killed_after_window
}

# late_claim_hook: kill the first launcher right after it opens its window, and hold the first runner's claim until
# the test creates "claim-go". The tmux server keeps the environment it started with, so the runner sees the hook.
late_claim_hook() {
  write_hook 'case "$1" in
  after-window) mkdir "$HOOK_DIR/killed-once" 2>/dev/null && kill -9 "$PPID" ;;
  before-claim)
    mkdir "$HOOK_DIR/paused-once" 2>/dev/null || exit 0
    for _ in $(seq 200); do [ -e "$HOOK_DIR/claim-go" ] && exit 0; sleep 0.05; done ;;
esac
exit 0'
  export LANES_TEST_HOOK="$WORK/hook"
  run "$JOB" run live -- touch "$WORK/ran"
  [ "$status" -eq 137 ]
  wait_for 10 test -d "$WORK/paused-once"
}

# live_windows <n>: the private tmux server has exactly n windows named "live".
live_windows() {
  [ "$(tmux -L "$LANES_TMUX_SOCKET" list-windows -t "=lanes-jobs" -F '#W' | grep -cx live)" -eq "$1" ]
}

@test "a runner whose dead launcher's slot was reclaimed never starts its command" {
  export LANES_POOL_SIZE=1
  late_claim_hook
  sleep 60 &
  holder=$!
  run "$JOB" slot acquire jobs --pid "$holder"
  [ "$output" = "1" ]
  touch "$WORK/claim-go"
  wait_for 10 live_windows 0
  kill "$holder"
  [ ! -e "$WORK/ran" ]
  [ "$(readlink "$LANES_DATA_DIR/locks/jobs-1.lock")" = "$holder" ]
}

@test "a runner whose name was run again after its launcher died never starts its command" {
  late_claim_hook
  run "$JOB" run live --slot other -- sleep 60
  [ "$status" -eq 0 ]
  second="$(cat "$LANES_DATA_DIR/jobs/live/pid")"
  touch "$WORK/claim-go"
  wait_for 10 live_windows 1
  [ ! -e "$WORK/ran" ]
  [ "$(cat "$LANES_DATA_DIR/jobs/live/pid")" = "$second" ]
}

@test "a runner that never takes ownership is cleaned up and the launch fails loudly" {
  export LANES_CLAIM_TIMEOUT=1
  fake_tmux noclaim
  run "$JOB" run ghost -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"ownership"* ]]
  [ ! -e "$LANES_DATA_DIR/jobs/ghost" ]
  [ -z "$(ls "$LANES_DATA_DIR/locks" | grep -v '^\.mutex')" ]
  [ -e "$WORK/killed" ]
}

@test "a mutex another process now owns is not freed by the first holder" {
  export LANES_NO_FLOCK=1
  fake_tmux steal
  run "$JOB" run stolen -- true
  [ "$status" -ne 0 ]
  [ "$(readlink "$LANES_DATA_DIR/locks/.mutex.owner")" = "999999" ]
}

@test "a failed session start leaves no job directory and no slot" {
  fake_tmux session
  run "$JOB" run nosession -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"session"* ]]
  [ ! -e "$LANES_DATA_DIR/jobs/nosession" ]
  [ -z "$(ls "$LANES_DATA_DIR/locks" | grep -v '^\.mutex')" ]
}

@test "a failed window start leaves no job directory and no slot" {
  fake_tmux window
  run "$JOB" run nowindow -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"window"* ]]
  [ ! -e "$LANES_DATA_DIR/jobs/nowindow" ]
  [ -z "$(ls "$LANES_DATA_DIR/locks" | grep -v '^\.mutex')" ]
}

@test "without LANES_TMUX_SOCKET the job runs on the dedicated 'lanes' socket" {
  unset LANES_TMUX_SOCKET
  export TMUX_TMPDIR="$WORK/tmux"
  mkdir -p "$TMUX_TMPDIR"
  "$JOB" run dflt -- sleep 60
  [ -S "$TMUX_TMPDIR/tmux-$(id -u)/lanes" ]
  [ ! -e "$TMUX_TMPDIR/tmux-$(id -u)/default" ]
  tmux -L lanes has-session -t "=lanes-jobs"
}

@test "--env NAME passes the caller's variable to the job; unlisted ones do not arrive" {
  # The tmux server keeps the environment it was started with, so start it before the variables exist.
  "$JOB" run warm -- true
  "$JOB" wait warm --timeout 20
  export PASS_ME=visible HIDE_ME=secret
  "$JOB" run envjob --env PASS_ME -- bash -c 'echo "${PASS_ME:-none}|${HIDE_ME:-none}"'
  "$JOB" wait envjob --timeout 20
  [ "$(cat "$LANES_DATA_DIR/jobs/envjob/log")" = "visible|none" ]
}

@test "--env with an invalid variable name is a usage error" {
  run "$JOB" run badenv --env 'A B' -- true
  [ "$status" -eq 2 ]
  [[ "$output" == *"lanes-job:"* ]]
}
