# Shared setup for the lanes core suite: a temp data dir, a private tmux socket, a git work tree with a pushed
# upstream, and a fake Claude pane (fake-claude) that fires the lanes hooks. Never the user's tmux server or data.

load ../helpers/common

# shellcheck disable=SC2034 # used by the suites that load this helper
LANES="$LANES_REPO_ROOT/plugins/lanes/bin/lanes"
# shellcheck disable=SC2034 # used by the suites that load this helper
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
  # Claude Code's config dir, where the fake writes its sessions file: never the real ~/.claude. A hook run straight
  # from a test gets this shell as its CLAUDE_PID, which has no sessions file, so such a lane is never proven in a pane.
  export CLAUDE_CONFIG_DIR="$LANES_TEST_TMP/claude-config" CLAUDE_PID=$$
  unset CLAUDE_CODE_SESSION_ID
  # The test shell acts as a pane of a pretend tmux server (pid $$), in tmux's "<socket>,<server pid>,<session>" form,
  # so a lane it registers and a command it runs with one TMUX_PANE are one pane. A fake pane gets its real server's.
  export TMUX="$TMUX_TMPDIR/test-shell,$$,0"
  # Claude Code's managed settings (vim mode) are read from here, never the machine's /etc/claude-code.
  export LANES_MANAGED_SETTINGS_DIR="$LANES_TEST_TMP/managed"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  WORK="$LANES_TEST_TMP/work"
  REMOTE="$LANES_TEST_TMP/remote.git"
  FAKE_LOG="$LANES_TEST_TMP/fake.log"
  : >"$FAKE_LOG"
  # Every test starts in the project its lanes register from (hook_json's cwd), since lanes acts on the caller's
  # project only; make_repo turns this folder into the repository.
  mkdir -p "$WORK"
  cd "$WORK" || return 1
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

# write_resume <lane> [goal] [next]: a valid RESUME block in .lanes/next-<lane>.md, committed and pushed. While the
# lane has an open request, the commit is dated after it unless the caller sets GIT_COMMITTER_DATE: a host's wall
# clock can step back seconds (WSL2 here, -2.9 s every 27 s), which would date a commit made after the request before it.
write_resume() {
  local lane="$1" goal="${2:-finish item A1 and report done}" next="${3:-run the tests for A1}" at t
  at="$(jq -r 'select(.handshake.state == "requested") | .handshake.requested_at' "$LANES_DATA_DIR/lanes/state/$lane.json" 2>/dev/null || true)"
  if [[ -z "${GIT_COMMITTER_DATE:-}" && "$at" =~ ^[0-9]+$ ]]; then
    t="$(date +%s)"
    ((t > at)) || t=$((at + 1))
    local -x GIT_COMMITTER_DATE="$t +0000"
  fi
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

# hook_json <event> <session_id> <lane> [source]: the hook input Claude Code sends, with a transcript path that holds
# nothing yet (a session no one has used).
hook_json() {
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --arg c "$WORK" --arg src "${4:-startup}" \
    --arg tp "$LANES_TEST_TMP/transcripts/$2.jsonl" \
    '{hook_event_name:$e,session_id:$s,session_title:$t,cwd:$c,source:$src,transcript_path:$tp}'
}

# register_lane <lane> <session_id> [pane]: run the SessionStart hook as Claude Code would, with the TMUX of the test's
# tmux server when the pane is one of its own (server_tmux), else the test shell's.
register_lane() {
  local pane="${3:-}" t="$TMUX"
  # tmux falls back to another pane for a missing target, so the printed id must be the pane's own.
  [[ -n "$pane" && "$(lanes_tmux display -p -t "$pane" '#{pane_id}' 2>/dev/null)" == "$pane" ]] && t="$(server_tmux)"
  hook_json SessionStart "$2" "$1" startup | TMUX="$t" TMUX_PANE="$pane" "$LANES" register
}

# start_fake <lane> [VAR=value...]: a fake Claude pane in its own tmux session, registered as <lane>. Sets PANE to
# its pane id and FAKE_PID to its process, the pane's own process as with a native install.
start_fake() {
  local lane="$1"
  shift
  # shellcheck disable=SC2016 # "$0" expands in the inner bash, not here
  lanes_tmux new-session -d -s "$lane" -x 160 -y 40 -c "$WORK" \
    env LANES_DATA_DIR="$LANES_DATA_DIR" LANES_TMUX_SOCKET="$LANES_TMUX_SOCKET" LANES_BIN="$LANES" \
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
    FAKE_LANE="$lane" FAKE_LOG="$FAKE_LOG" "$@" bash -c 'exec -a claude bash "$0"' "$FAKE"
  PANE="$(lanes_tmux display -p -t "$lane" '#{pane_id}')"
  FAKE_PID="$(lanes_tmux display -p -t "$lane" '#{pane_pid}')"
  wait_for "registered $lane" test -f "$LANES_DATA_DIR/lanes/$lane.json" || { cat "$FAKE_LOG.err" >&2; return 1; }
  wait_for "prompt drawn" pane_has '❯' || { cat "$FAKE_LOG.err" >&2; return 1; }
}

# shell_pane: the pane runs an interactive bash with job control, as a human's terminal does, and a launcher at
# $LANES_TEST_TMP/run-fake <lane> starts the fake from it. Sets PANE.
shell_pane() {
  # shellcheck disable=SC2016 # "$1" expands in the launcher script, not here
  printf '#!/usr/bin/env bash\nexport LANES_DATA_DIR=%q LANES_TMUX_SOCKET=%q LANES_BIN=%q CLAUDE_CONFIG_DIR=%q FAKE_LOG=%q FAKE_LANE="$1"\nexec -a claude bash %q\n' \
    "$LANES_DATA_DIR" "$LANES_TMUX_SOCKET" "$LANES" "$CLAUDE_CONFIG_DIR" "$FAKE_LOG" "$FAKE" >"$LANES_TEST_TMP/run-fake"
  lanes_tmux new-session -d -s shell -x 160 -y 40 -c "$WORK" "bash --norc --noprofile -i"
  PANE="$(lanes_tmux display -p -t shell '#{pane_id}')"
  wait_for "shell prompt" pane_has '$'
}

# fake_from_shell <lane> <command line>: type the command into the shell, wait for the lane's registration, and set
# FAKE_PID to the Claude Code pid it registered.
fake_from_shell() {
  lanes_tmux send-keys -t "$PANE" -l -- "$2"
  lanes_tmux send-keys -t "$PANE" Enter
  wait_for "registered $1" test -f "$LANES_DATA_DIR/lanes/$1.json"
  wait_for "prompt drawn" pane_has '❯'
  FAKE_PID="$(reg "$1" .claude_pid)"
}

# stop_fake: stop the fake with SIGTSTP, as Ctrl-Z does, and wait until ps shows it stopped. A pane's own process is
# in an orphaned process group, where the kernel discards SIGTSTP, so the fake must run from shell_pane.
stop_fake() {
  kill -TSTP "$FAKE_PID"
  wait_for "stopped" bash -c "ps -o stat= -p $FAKE_PID | grep -q '^T'"
}

# jq_shim <match> <count>: a jq in $LANES_TEST_TMP/shim (put it first on PATH) that fails as a killed jq does, exit
# 137, on the <count>-th call whose arguments contain <match>, and on every one after it when <count> ends in "+".
jq_shim() {
  mkdir -p "$LANES_TEST_TMP/shim"
  : >"$LANES_TEST_TMP/jq-calls"
  cat >"$LANES_TEST_TMP/shim/jq" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *$(printf '%q' "$1")* ]]; then
  echo x >>"$LANES_TEST_TMP/jq-calls"
  n=\$(wc -l <"$LANES_TEST_TMP/jq-calls")
  want="$2"
  if [[ "\$want" == *+ ]]; then ((n >= \${want%+})) && exit 137; else ((n == want)) && exit 137; fi
fi
exec $(command -v jq) "\$@"
EOF
  chmod +x "$LANES_TEST_TMP/shim/jq"
}

# ps_fails_for <pid|self>: shims in $LANES_TEST_TMP/shim (put it first on PATH): uname answers Darwin, so lanes reads
# start times through ps, and ps fails for <pid> only, or with "self" for any of its ancestors (lanes and its
# subshells), so a test fails exactly the read it names, on Linux and macOS alike.
ps_fails_for() {
  mkdir -p "$LANES_TEST_TMP/shim"
  printf '#!/usr/bin/env bash\necho Darwin\n' >"$LANES_TEST_TMP/shim/uname"
  cat >"$LANES_TEST_TMP/shim/ps" <<EOF
#!/usr/bin/env bash
pid="\${!#}" bad="$1"
if [[ "\$bad" == self ]]; then
  p=\$PPID
  for _ in 1 2 3 4 5 6; do
    [[ "\$pid" == "\$p" ]] && exit 1
    p="\$($(command -v ps) -o ppid= -p "\$p" | tr -d ' ')"
    [[ -n "\$p" ]] || break
  done
elif [[ "\$pid" == "\$bad" ]]; then
  exit 1
fi
exec $(command -v ps) "\$@"
EOF
  chmod +x "$LANES_TEST_TMP/shim/uname" "$LANES_TEST_TMP/shim/ps"
}

# wait_for <what> <cmd...>: poll up to 5 s.
wait_for() {
  local what="$1" _
  shift
  for _ in $(seq 1 50); do
    "$@" && return 0
    sleep 0.1
  done
  echo "timed out waiting for $what" >&2
  return 1
}

# darwin_ps <ps args...>: the ps behind bin/lanes' non-Linux start time read, for a test that runs that form. On a
# Linux host it answers `-o stat= -o lstart= -p <pid>` from /proc/<pid>/stat (state; start ticks over a fixed boot
# time), since procps prints /proc/stat btime plus ticks and btime moves when the clock is stepped, while macOS ps prints
# the kernel's p_starttime. Any other call, or a non-Linux host, runs the real ps.
darwin_ps() {
  local s hz
  local -a f
  if [[ "$(uname -s)" != Linux || "$*" != "-o stat= -o lstart= -p "* ]]; then
    command ps "$@"
    return
  fi
  { IFS= read -r s <"/proc/${!#}/stat"; } 2>/dev/null || return 1
  read -ra f <<<"${s##*) }"
  hz="$(getconf CLK_TCK)"
  printf '%s %s\n' "${f[0]}" "$(LC_ALL=C date -u -d "@$((1700000000 + f[19] / hz))" '+%a %b %e %H:%M:%S %Y')"
}

# DARWIN: the lines that put a sourced bin/lanes into its non-Linux form, with darwin_ps as its ps.
# shellcheck disable=SC2034 # used by the suites that load this helper
DARWIN="$(declare -f darwin_ps); ps() { darwin_ps \"\$@\"; }; OS_NAME=Darwin"

# lock_tag_of <pid>: the lock target that names <pid> as a live holder, built by the lanes function itself.
lock_tag_of() { bash -c 'source "$1"; lock_tag "$2"' _ "$LANES" "$1"; }

# zombie_child: a child that has exited but is never reaped (its parent became a sleep, which never waits; the child is
# killed only after that exec, since bash itself would reap it). Sets ZPID, ZTAG (its lock tag while it ran) and
# ZPARENT; the test kills ZPARENT.
zombie_child() {
  bash -c 'sleep 30 & echo "$!" >"$1"; exec sleep 30' _ "$LANES_TEST_TMP/zpid" &
  ZPARENT=$!
  wait_for "child pid" test -s "$LANES_TEST_TMP/zpid"
  ZPID="$(<"$LANES_TEST_TMP/zpid")"
  wait_for "parent exec" bash -c "[ \"\$(ps -o args= -p $ZPARENT)\" = 'sleep 30' ]"
  # shellcheck disable=SC2034 # read by the test that calls it
  ZTAG="$(lock_tag_of "$ZPID")"
  kill -9 "$ZPID"
  wait_for "zombie" bash -c "ps -o stat= -p $ZPID | grep -q '^Z'"
}

# server_tmux: the TMUX value a pane of the test's tmux server carries, for a hook or command a test runs from the
# test shell as if from that pane (a restart or a second session in a fake's pane).
server_tmux() { lanes_tmux display -p '#{socket_path},#{pid},#{session_id}' | tr -d '$'; }

pane_has() { lanes_tmux capture-pane -p -t "$PANE" | grep -qF -- "$1"; }

reg() { jq -r "$2" "$LANES_DATA_DIR/lanes/$1.json"; }
state() { jq -r "$2" "$LANES_DATA_DIR/lanes/state/$1.json"; }

# session_file [pid]: a sessions file (default the fake's); sess <jq filter>: read the fake's.
session_file() { printf '%s/sessions/%s.json' "$CLAUDE_CONFIG_DIR" "${1:-$FAKE_PID}"; }
sess() { jq -r "$1" "$(session_file)"; }
# edit_session <jq filter>: change the fake's sessions file in place, to test what lanes trusts in it.
edit_session() { local f; f="$(session_file)"; jq -c "$1" "$f" >"$f.x" && mv "$f.x" "$f"; }
# wait_status <status>: the fake's sessions file shows it.
wait_status() { wait_for "status $1" bash -c "[ \"\$(jq -r .status '$(session_file)')\" = '$1' ]"; }

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
