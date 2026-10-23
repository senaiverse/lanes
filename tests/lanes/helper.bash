# Shared setup for the lanes core suite: a temp data dir, a private tmux socket, a git work tree with a pushed
# upstream, and a fake Claude pane (fake-claude) that fires the lanes hooks. Never the user's tmux server or data.

load ../helpers/common

# shellcheck disable=SC2034 # used by the suites that load this helper
LANES="$LANES_REPO_ROOT/plugins/lanes/bin/lanes"
STATUSLINE="$LANES_REPO_ROOT/plugins/lanes/bin/lanes-statusline"
FAKE="$BATS_TEST_DIRNAME/fake-claude"

setup() {
  lanes_test_setup
  # The physical path, as git and getcwd report it: on macOS /tmp is a link to /private/tmp.
  LANES_TEST_TMP="$(cd "$LANES_TEST_TMP" && pwd -P)"
  # bin/ must work with no Claude Code variables at all.
  unset CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE \
    CLAUDE_PLUGIN_OPTION_THRESHOLD CLAUDE_PLUGIN_OPTION_JOURNAL_DIR LANES_THRESHOLD LANES_JOURNAL_DIR LANES_ROLE
  export LANES_IDLE_GAP=0.3 LANES_CLEAR_TIMEOUT=4 LANES_SEND_GAP=0.01
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  WORK="$LANES_TEST_TMP/work"
  REMOTE="$LANES_TEST_TMP/remote.git"
  FAKE_LOG="$LANES_TEST_TMP/fake.log"
  : >"$FAKE_LOG"
}

teardown() {
  lanes_test_teardown
}

# make_repo: a work tree whose branch tracks a bare remote, everything pushed. The test then runs inside it, as a
# lane's Bash tool does, because clear-ready checks the work tree it is run from.
make_repo() {
  git init -q --bare "$REMOTE"
  git init -q -b main "$WORK"
  git -C "$WORK" remote add origin "$REMOTE"
  printf 'x\n' >"$WORK/file"
  git -C "$WORK" add file
  git -C "$WORK" commit -q -m init
  git -C "$WORK" push -q -u origin main
  cd "$WORK" || return 1
}

# write_resume <lane> [goal] [next]: a valid RESUME block in .lanes/next-<lane>.md, committed and pushed.
write_resume() {
  local lane="$1" goal="${2:-finish item A1 and report done}" next="${3:-run the tests for A1}"
  mkdir -p "$WORK/.lanes"
  cat >"$WORK/.lanes/next-$lane.md" <<EOF
# next-$lane

<!-- lanes:resume:start -->
## RESUME

### Goal
$goal

### Now
Branch main, item A1, step 2 of 3.

### Next step
$next

### Links
Plan: docs/plan.md

### Running
Nothing.

### Suggested skills
lane
<!-- lanes:resume:end -->
EOF
  git -C "$WORK" add .lanes
  git -C "$WORK" commit -q -m "resume $lane"
  git -C "$WORK" push -q
}

# hook_json <event> <session_id> <lane> [source]: the hook input Claude Code sends.
hook_json() {
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --arg c "$WORK" --arg src "${4:-startup}" \
    '{hook_event_name:$e,session_id:$s,session_title:$t,cwd:$c,source:$src}'
}

# register_lane <lane> <session_id> [pane]: run the SessionStart hook as Claude Code would.
register_lane() {
  local pane="${3:-}"
  hook_json SessionStart "$2" "$1" startup | TMUX_PANE="$pane" "$LANES" register
}

# start_fake <lane> [VAR=value...]: a fake Claude pane in its own tmux session, registered as <lane>.
# Sets PANE to its pane id.
start_fake() {
  local lane="$1"
  shift
  lanes_tmux new-session -d -s "$lane" -x 160 -y 40 -c "$WORK" \
    env LANES_DATA_DIR="$LANES_DATA_DIR" LANES_TMUX_SOCKET="$LANES_TMUX_SOCKET" LANES_BIN="$LANES" \
    FAKE_LANE="$lane" FAKE_LOG="$FAKE_LOG" "$@" bash -c 'exec -a claude bash "$0"' "$FAKE"
  PANE="$(lanes_tmux display -p -t "$lane" '#{pane_id}')"
  wait_for "registered $lane" test -f "$LANES_DATA_DIR/lanes/$lane.json" || { cat "$FAKE_LOG.err" >&2; return 1; }
  wait_for "prompt drawn" pane_has '❯' || { cat "$FAKE_LOG.err" >&2; return 1; }
}

# wait_for <what> <cmd...>: poll up to 5 s.
wait_for() {
  local what="$1" i
  shift
  for i in $(seq 1 50); do
    "$@" && return 0
    sleep 0.1
  done
  echo "timed out waiting for $what" >&2
  return 1
}

pane_has() { lanes_tmux capture-pane -p -t "$PANE" | grep -qF -- "$1"; }

reg() { jq -r "$2" "$LANES_DATA_DIR/lanes/$1.json"; }
state() { jq -r "$2" "$LANES_DATA_DIR/lanes/state/$1.json"; }

# ready_lane <lane> [VAR=value...]: repo, RESUME, a fake pane, and a successful clear-ready.
ready_lane() {
  local lane="$1"
  shift
  make_repo
  write_resume "$lane"
  start_fake "$lane" "$@"
  run "$LANES" clear-ready --lane "$lane"
  assert_success
}
