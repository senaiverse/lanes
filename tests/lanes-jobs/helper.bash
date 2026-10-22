# Shared setup for the lanes-jobs suite: a temp data dir and a private tmux socket, never the user's server.

# shellcheck disable=SC2034 # used by the suite that loads this helper
JOB="$BATS_TEST_DIRNAME/../../plugins/lanes-jobs/bin/lanes-job"

setup() {
  # Under /tmp, not $TMPDIR: macOS's long $TMPDIR pushes a tmux socket path past the 104-byte limit.
  WORK="$(mktemp -d /tmp/lanes-jobs.XXXXXX)"
  export LANES_DATA_DIR="$WORK/data"
  export LANES_TMUX_SOCKET="lanes-test-$$-$BATS_TEST_NUMBER"
  export LANES_POOL_SIZE=2
  unset TMUX TMUX_TMPDIR
}

teardown() {
  if [[ -n "${LANES_TMUX_SOCKET:-}" ]]; then tmux -L "$LANES_TMUX_SOCKET" kill-server 2>/dev/null || true; fi
  # The default-socket test sets TMUX_TMPDIR, so this never reaches the user's own "lanes" server.
  if [[ -n "${TMUX_TMPDIR:-}" ]]; then tmux -L lanes kill-server 2>/dev/null || true; fi
  # kill-server returns before the runners exit, and a dying runner still writes its STATUS; let them finish first.
  local f
  shopt -s globstar nullglob
  for f in "$WORK"/**/jobs/*/pid; do wait_for 5 runner_gone "$(cat "$f")"; done
  rm -rf "$WORK"
}

# runner_gone <pid>: the process is no longer alive.
runner_gone() { ! kill -0 "$1" 2>/dev/null; }

# status_file <name>: where a job's STATUS lives.
status_file() { printf '%s/jobs/%s/STATUS' "$LANES_DATA_DIR" "$1"; }

# wait_for <seconds> <cmd...>: poll until the command succeeds; fail loudly once the bound passes.
wait_for() {
  local limit=$(($1 * 20)) i
  shift
  for ((i = 0; i < limit; i++)); do
    "$@" && return 0
    sleep 0.05
  done
  echo "wait_for: '$*' still false after the bound" >&2
  return 1
}

# warm_server: start the private tmux server with a finished job, so variables set later are not in its environment.
warm_server() {
  "$JOB" run warm -- true
  "$JOB" wait warm --timeout 20
}

# write_hook <body>: an executable LANES_TEST_HOOK script; it gets the point name as $1 and $WORK as HOOK_DIR.
write_hook() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$WORK/hook"
  chmod +x "$WORK/hook"
  export HOOK_DIR="$WORK"
}
