# Shared bats helpers. Load with: load ../helpers/common
# Rule: a test never touches the user's tmux server or data dir, so each gets a private socket and a temp data dir.

LANES_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LANES_TOOLS_DIR="${LANES_TOOLS_DIR:-$LANES_REPO_ROOT/.tools}"

load "$LANES_TOOLS_DIR/bats-support/load"
load "$LANES_TOOLS_DIR/bats-assert/load"

# Call from setup(). Exports LANES_DATA_DIR (temp), LANES_TMUX_SOCKET and an isolated TMUX_TMPDIR.
lanes_test_setup() {
  LANES_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanes-test.XXXXXX")"
  export LANES_DATA_DIR="$LANES_TEST_TMP/data"
  mkdir -p "$LANES_DATA_DIR"
  export TMUX_TMPDIR="$LANES_TEST_TMP/tmux"
  mkdir -p "$TMUX_TMPDIR"
  export LANES_TMUX_SOCKET="lanes-test-$$"
  unset TMUX TMUX_PANE
}

# tmux against the private server only.
lanes_tmux() {
  tmux -L "$LANES_TMUX_SOCKET" "$@"
}

# Call from teardown(). Kills the private tmux server, then removes the temp dir.
lanes_test_teardown() {
  if [ -n "${LANES_TMUX_SOCKET:-}" ]; then
    tmux -L "$LANES_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  if [ -n "${LANES_TEST_TMP:-}" ]; then
    rm -rf "$LANES_TEST_TMP"
  fi
}
