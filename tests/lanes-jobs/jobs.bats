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

@test "the mkdir mutex fallback behaves the same when flock is unavailable" {
  export LANES_NO_FLOCK=1 LANES_POOL_SIZE=1
  "$JOB" run first -- sleep 60
  run "$JOB" run second -- true
  [ "$status" -eq 75 ]
  tmux -L "$LANES_TMUX_SOCKET" kill-window -t "lanes-jobs:first"
  "$JOB" wait first --timeout 20
  run "$JOB" run third -- true
  [ "$status" -eq 0 ]
  [ ! -d "$LANES_DATA_DIR/locks/.mutex.d" ]
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
  run env PATH=/nonexistent /bin/bash "$JOB" run x -- true
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

@test "six concurrent runs against a pool of two start exactly two (mkdir fallback)" {
  export LANES_NO_FLOCK=1
  race_six
}

@test "mkdir mutex held by a live owner is not broken, and the wait fails loudly" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1
  mkdir -p "$LANES_DATA_DIR/locks/.mutex.d"
  sleep 30 &
  owner=$!
  echo "$owner" >"$LANES_DATA_DIR/locks/.mutex.d/owner"
  run "$JOB" slot acquire p --pid $$
  kill "$owner"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lanes-job:"*"mutex"* ]]
  [ -d "$LANES_DATA_DIR/locks/.mutex.d" ]
}

@test "mkdir mutex left by a dead owner is broken and released afterwards" {
  export LANES_NO_FLOCK=1 LANES_MUTEX_TIMEOUT=1
  mkdir -p "$LANES_DATA_DIR/locks/.mutex.d"
  sleep 0.01 &
  dead=$!
  wait "$dead"
  echo "$dead" >"$LANES_DATA_DIR/locks/.mutex.d/owner"
  run "$JOB" slot acquire p --pid $$
  [ "$status" -eq 0 ]
  [ ! -d "$LANES_DATA_DIR/locks/.mutex.d" ]
}

# fake_tmux <mode>: a tmux on PATH that behaves per mode (see the script).
fake_tmux() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
args=" $* "
[[ "$args" == *" has-session "* ]] && { [ "$FAKE_TMUX_MODE" = window ] && exit 0; exit 1; }
if [ "$FAKE_TMUX_MODE" = steal ]; then echo 999999 >"$LANES_DATA_DIR/locks/.mutex.d/owner"; fi
exit 1
FAKE
  chmod +x "$WORK/bin/tmux"
  export PATH="$WORK/bin:$PATH" FAKE_TMUX_MODE="$1"
}

@test "a mutex another process now owns is not freed by the first holder" {
  export LANES_NO_FLOCK=1
  fake_tmux steal
  run "$JOB" run stolen -- true
  [ "$status" -ne 0 ]
  [ -d "$LANES_DATA_DIR/locks/.mutex.d" ]
  [ "$(cat "$LANES_DATA_DIR/locks/.mutex.d/owner")" = "999999" ]
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
