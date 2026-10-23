#!/usr/bin/env bats
# Seam: screen_read, fed real screens. The files in captures/ are `tmux capture-pane -p -e` output from Claude Code
# 2.1.309 (scratch paths replaced), so the screen model is checked against the producer, not against the fake.

load helper

CAPS="$BATS_TEST_DIRNAME/captures"

# verdict <capture>: "prompt=<0|1> goal=<0|1> veto=<none|spinner|dialog|queued> composer=<text>" for one real screen.
verdict() {
  bash -c '
    source "$1"
    cap="$2"
    tm() { cat "$cap"; }
    screen_read x
    case "$VETO" in "") v=none ;; *spinner*) v=spinner ;; *"no input prompt"* | *dialog*) v=dialog ;; *queued*) v=queued ;; *) v="$VETO" ;; esac
    printf "prompt=%s goal=%s veto=%s composer=%s\n" "$COMPOSER_FOUND" "$GOAL_ACTIVE" "$v" "$COMPOSER"
  ' _ "$LANES" "$CAPS/$1.ansi"
}

@test "idle input line with its dim placeholder: an empty composer, nothing vetoes" {
  run verdict 01-idle
  assert_output "prompt=1 goal=0 veto=none composer="
}

@test "typed text in the input line is the composer" {
  run verdict 02a-typed
  assert_output "prompt=1 goal=0 veto=none composer=Run the shell command: sleep 20 && echo done. Then reply with one word."
}

@test "a working spinner two lines above the box vetoes: '*', '✽' and '✢' glyphs" {
  run verdict 02b-busy
  assert_output --partial "veto=spinner"
  run verdict 03-queued
  assert_output --regexp "veto=(spinner|queued)"
  run verdict 09-after-clear
  assert_output --partial "veto=spinner"
}

@test "a permission dialog replaces the input box: no prompt found" {
  run verdict 04-dialog
  assert_output --partial "prompt=0"
  assert_output --partial "veto=dialog"
}

@test "the goal indicator on the notice row above the box is seen, alone or sharing the row, busy or idle" {
  run verdict 05b-goal-busy
  assert_output --partial "goal=1"
  run verdict 05e-goal-idle-later
  assert_output "prompt=1 goal=1 veto=none composer="
  run verdict 09-after-clear
  assert_output --partial "goal=1"
}

@test "no goal indicator after /goal clear or once the goal stopped, even with '/goal clear' in the transcript" {
  run verdict 05f-goal-cleared
  assert_output "prompt=1 goal=0 veto=none composer="
  run verdict 09b-goal-stopped
  assert_output "prompt=1 goal=0 veto=none composer="
}

@test "a long composer wrapped over several lines is read whole" {
  run verdict 07-long-typed
  assert_output --partial "composer=/goal word001 word002"
  assert_output --partial "word040 word041 word042"
  assert_output --partial "word075 END"
}
