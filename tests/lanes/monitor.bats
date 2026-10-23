#!/usr/bin/env bats
# Public seams: `lanes monitor-lock <name> <pid>` and `lanes monitor-diff <name>`, the two helpers the watcher loops in
# skills/lead/MONITORS.md call, and the SessionStart line that tells the lead which watchers are down. Watchers belong
# to the project of the directory they run in, so each test runs in a project folder, P1 unless it says otherwise.

load helper

MD="$BATS_TEST_DIRNAME/../../plugins/lanes/skills/lead"

# in_p1: make the two project folders P1 and P2 (plain folders, each its own project) and move into P1.
in_p1() {
  P1="$LANES_TEST_TMP/p1" P2="$LANES_TEST_TMP/p2"
  mkdir -p "$P1" "$P2"
  cd "$P1" || return 1
}

# lead_ctx <dir>: what SessionStart tells a lead whose session started in <dir>.
lead_ctx() {
  jq -nc --arg c "$1" '{session_id:"sl",session_title:"lead",cwd:$c,source:"startup"}' |
    LANES_ROLE=lead TMUX_PANE=%9 "$LANES" register 2>/dev/null | jq -r .hookSpecificOutput.additionalContext
}

@test "monitor-lock: one live holder per name; a second start is refused; a dead holder is reclaimed" {
  in_p1
  sleep 30 &
  a=$!
  sleep 30 &
  b=$!
  run "$LANES" monitor-lock ci "$a"
  assert_success
  run "$LANES" monitor-lock ci "$b"
  assert_failure
  assert_output --partial "monitor ci is already running (pid $a)"
  kill "$a"
  wait "$a" 2>/dev/null || true
  run "$LANES" monitor-lock ci "$b"
  assert_success
  kill "$b"
}

@test "monitor-lock refuses a pid that is not running and a name that is not plain" {
  in_p1
  run "$LANES" monitor-lock ci 999999
  assert_failure
  assert_output --partial "is not running"
  run "$LANES" monitor-lock "../x" "$$"
  assert_failure 2
}

@test "a watcher whose pid now belongs to another process is down, and its name can be started again" {
  in_p1
  sleep 30 &
  a=$!
  "$LANES" monitor-lock ci "$a" >/dev/null
  lock="$(printf '%s\n' "$LANES_DATA_DIR"/monitors/*/ci.lnk)"
  [ -L "$lock" ]
  run lead_ctx "$P1"
  assert_output --partial "watchers not running: reviews context drift."
  # The holder died and the system gave its pid to another process: the pid runs, with another start time.
  ln -sfn "$a.1" "$lock"
  run lead_ctx "$P1"
  assert_output --partial "watchers not running: ci reviews context drift."
  sleep 30 &
  b=$!
  run "$LANES" monitor-lock ci "$b"
  assert_success
  run lead_ctx "$P1"
  assert_output --partial "watchers not running: reviews context drift."
  kill "$a" "$b"
}

@test "two projects each run their own ci watcher with its own state, and the lead hears only about its own" {
  in_p1
  sleep 30 &
  a=$!
  sleep 30 &
  b=$!
  run "$LANES" monitor-lock ci "$a"
  assert_success
  cd "$P2"
  run "$LANES" monitor-lock ci "$b"
  assert_success
  kill "$b"
  wait "$b" 2>/dev/null || true
  printf 'x\t1\n' | "$LANES" monitor-diff ci >/dev/null
  cd "$P1"
  run bash -c "printf 'x\t1\n' | '$LANES' monitor-diff ci"
  assert_output "x: none -> 1"
  run lead_ctx "$P1"
  assert_output --partial "watchers not running: reviews context drift."
  run lead_ctx "$P2"
  assert_output --partial "watchers not running: ci reviews context drift."
  kill "$a"
}

@test "a repository and its worktrees are one project: a watcher started in one holds the name for all" {
  in_p1
  git init -q -b main "$P1/repo"
  git -C "$P1/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$P1/repo" worktree add -q -b wt "$P1/repo-wt"
  sleep 30 &
  a=$!
  sleep 30 &
  b=$!
  cd "$P1/repo"
  "$LANES" monitor-lock ci "$a" >/dev/null
  cd "$P1/repo-wt"
  run "$LANES" monitor-lock ci "$b"
  assert_failure
  assert_output --partial "monitor ci is already running (pid $a)"
  kill "$a" "$b"
}

@test "monitor-diff: the first pass is the baseline, then only changed, new and gone items print" {
  in_p1
  run bash -c "printf '#1\tpending\n#2\tsuccess\n' | '$LANES' monitor-diff ci"
  assert_output "#1: none -> pending
#2: none -> success"
  run bash -c "printf '#1\tpending\n#2\tsuccess\n' | '$LANES' monitor-diff ci"
  assert_output ""
  run bash -c "printf '#1\tfailure\n#3\tpending\n' | '$LANES' monitor-diff ci"
  assert_output "#1: pending -> failure
#3: none -> pending
#2: gone"
  run bash -c "jq -c . '$LANES_DATA_DIR'/monitors/*/ci.state"
  assert_output '{"#1":"failure","#3":"pending"}'
}

@test "monitor-diff keeps one state file per watcher name" {
  in_p1
  printf 'a\tx\n' | "$LANES" monitor-diff ci >/dev/null
  run bash -c "printf 'a\tx\n' | '$LANES' monitor-diff reviews"
  assert_output "a: none -> x"
}

@test "SessionStart tells the lead which watchers ran here before and are down, and tells a lane nothing" {
  in_p1
  printf 'a\tx\n' | "$LANES" monitor-diff ci >/dev/null
  printf 'a\tx\n' | "$LANES" monitor-diff drift >/dev/null
  sleep 30 &
  live=$!
  "$LANES" monitor-lock drift "$live" >/dev/null
  run lead_ctx "$P1"
  kill "$live"
  assert_output --partial "watchers not running: ci reviews context."
  refute_output --partial drift
  run bash -c "jq -nc --arg c '$P1' '{session_id:\"s1\",session_title:\"alpha\",cwd:\$c,source:\"startup\"}' | TMUX_PANE=%7 '$LANES' register 2>/dev/null"
  refute_output --partial watchers
}

@test "on a fresh install the lead is told all four watchers are down" {
  in_p1
  run lead_ctx "$P1"
  assert_output --partial "watchers not running: ci reviews context drift."
}

@test "MONITORS.md: under 120 lines, cited by the lead skill, one watcher per signal" {
  [ -f "$MD/MONITORS.md" ]
  [ "$(wc -l <"$MD/MONITORS.md")" -lt 120 ]
  grep -q '(MONITORS.md)' "$MD/SKILL.md"
  grep -q 'lanes monitor-lock "$name" \$\$' "$MD/MONITORS.md"
  for w in ci reviews context drift; do grep -q "(name \`$w\`" "$MD/MONITORS.md"; done
}

@test "MONITORS.md: every gh pr list call fetches the whole set, not the default 30" {
  run bash -c "grep -o 'gh pr list[^|]*' '$MD/MONITORS.md' | grep -vc -- '--limit 1000'"
  assert_output 0
  run bash -c "grep -c 'gh pr list' '$MD/MONITORS.md'"
  refute_output 0
}
