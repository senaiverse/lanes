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
  rm -rf "$WORK"
}

# status_file <name>: where a job's STATUS lives.
status_file() { printf '%s/jobs/%s/STATUS' "$LANES_DATA_DIR" "$1"; }
