#!/usr/bin/env bats
# Public seams: `lanes monitor-lock <name> <pid>` and `lanes monitor-diff <name>`, the two helpers the watcher loops in
# skills/lead/MONITORS.md call, and the SessionStart line that tells the lead which watchers are down.

load helper

MD="$BATS_TEST_DIRNAME/../../plugins/lanes/skills/lead"

@test "monitor-lock: one live holder per name; a second start is refused; a dead holder is reclaimed" {
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
  run "$LANES" monitor-lock ci 999999
  assert_failure
  assert_output --partial "is not running"
  run "$LANES" monitor-lock "../x" "$$"
  assert_failure 2
}

@test "monitor-diff: the first pass is the baseline, then only changed, new and gone items print" {
  run bash -c "printf '#1\tpending\n#2\tsuccess\n' | '$LANES' monitor-diff ci"
  assert_output "#1: none -> pending
#2: none -> success"
  run bash -c "printf '#1\tpending\n#2\tsuccess\n' | '$LANES' monitor-diff ci"
  assert_output ""
  run bash -c "printf '#1\tfailure\n#3\tpending\n' | '$LANES' monitor-diff ci"
  assert_output "#1: pending -> failure
#3: none -> pending
#2: gone"
  run jq -c . "$LANES_DATA_DIR/monitors/ci.state"
  assert_output '{"#1":"failure","#3":"pending"}'
}

@test "monitor-diff keeps one state file per watcher name" {
  printf 'a\tx\n' | "$LANES" monitor-diff ci >/dev/null
  run bash -c "printf 'a\tx\n' | '$LANES' monitor-diff reviews"
  assert_output "a: none -> x"
}

@test "SessionStart tells the lead which watchers ran here before and are down, and tells a lane nothing" {
  printf 'a\tx\n' | "$LANES" monitor-diff ci >/dev/null
  printf 'a\tx\n' | "$LANES" monitor-diff drift >/dev/null
  sleep 30 &
  live=$!
  "$LANES" monitor-lock drift "$live" >/dev/null
  run bash -c "jq -nc '{session_id:\"sl\",session_title:\"lead\",cwd:\"/\",source:\"startup\"}' | LANES_ROLE=lead TMUX_PANE=%9 '$LANES' register 2>/dev/null | jq -r .hookSpecificOutput.additionalContext"
  kill "$live"
  assert_output --partial "watchers not running: ci reviews context."
  refute_output --partial drift
  run bash -c "jq -nc '{session_id:\"s1\",session_title:\"alpha\",cwd:\"/\",source:\"startup\"}' | TMUX_PANE=%7 '$LANES' register 2>/dev/null"
  refute_output --partial watchers
}

@test "on a fresh install the lead is told all four watchers are down" {
  run bash -c "jq -nc '{session_id:\"sl\",session_title:\"lead\",cwd:\"/\",source:\"startup\"}' | LANES_ROLE=lead TMUX_PANE=%9 '$LANES' register 2>/dev/null | jq -r .hookSpecificOutput.additionalContext"
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
