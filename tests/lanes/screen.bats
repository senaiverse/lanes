#!/usr/bin/env bats
# Seam: screen_read, fed real screens. The files in captures/ are `tmux capture-pane -p -e` output from Claude Code
# 2.1.309 (scratch paths replaced), so the one screen fact lanes reads, the input line, is checked against the producer.

load helper

CAPS="$BATS_TEST_DIRNAME/captures"

# verdict <capture>: "prompt=<0|1> composer=<text>" for one real screen.
verdict() {
  bash -c '
    source "$1"
    cap="$2"
    tm() { cat "$cap"; }
    screen_read x
    printf "prompt=%s composer=%s\n" "$COMPOSER_FOUND" "$COMPOSER"
  ' _ "$LANES" "$CAPS/$1.ansi"
}

@test "idle input line with its dim placeholder: an empty composer" {
  run verdict 01-idle
  assert_output "prompt=1 composer="
}

@test "typed text in the input line is the composer" {
  run verdict 02a-typed
  assert_output "prompt=1 composer=Run the shell command: sleep 20 && echo done. Then reply with one word."
}

@test "busy, queued, goal and just-cleared screens: the input line is found and a dim hint reads as empty" {
  # Queued messages show only while a turn runs, which the sessions file reports as busy, so no screen veto is needed.
  for cap in 02b-busy 03-queued 05b-goal-busy 05e-goal-idle-later 05f-goal-cleared 09-after-clear 09b-goal-stopped; do
    run verdict "$cap"
    assert_output "prompt=1 composer="
  done
}

@test "a permission dialog leaves no readable input line (lanes then refuses to type)" {
  run verdict 04-dialog
  assert_output "prompt=0 composer="
}

@test "after a turn the empty input line is the bare prompt, with no placeholder: an empty composer" {
  for cap in 10-vim-08-normal-empty-after-turn 10-vim-09-insert-empty-after-turn; do
    run verdict "$cap"
    assert_output "prompt=1 composer="
  done
}

# insert_of <capture>: "insert=<0|1> composer=<text>", the footer's vim INSERT indicator as screen_read reads it.
insert_of() {
  bash -c '
    source "$1"
    cap="$2"
    tm() { cat "$cap"; }
    screen_read x
    printf "insert=%s composer=%s\n" "$SCREEN_INSERT" "$COMPOSER"
  ' _ "$LANES" "$CAPS/$1.ansi"
}

@test "vim INSERT mode is read from the footer, whose words are separate colour runs; NORMAL shows nothing there" {
  for cap in 10-vim-01-insert-empty 10-vim-09-insert-empty-after-turn; do
    run insert_of "$cap"
    assert_output "insert=1 composer="
  done
  run insert_of 10-vim-05-insert-typed-goal
  assert_output "insert=1 composer=/goal abc"
  for cap in 10-vim-02-normal-empty 10-vim-08-normal-empty-after-turn; do
    run insert_of "$cap"
    assert_output "insert=0 composer="
  done
  run insert_of 10-vim-06-normal-with-text
  assert_output --partial "insert=0 composer="
  # Without vim mode the footer has no indicator either.
  run insert_of 01-idle
  assert_output "insert=0 composer="
}

@test "a long composer wrapped over several lines is read whole" {
  run verdict 07-long-typed
  assert_output --partial "composer=/goal word001 word002"
  assert_output --partial "word040 word041 word042"
  assert_output --partial "word075 END"
}
