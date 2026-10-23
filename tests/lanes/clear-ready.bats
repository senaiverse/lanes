#!/usr/bin/env bats
# Public seams: `lanes request` (lead) and `lanes clear-ready` (lane). Ready means clean, pushed, and a RESUME block that
# is complete, under the cap and rewritten since the lead's request.

load helper

setup_lane() {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
}

@test "clear-ready marks the lane ready and records the head, RESUME hash and goal" {
  setup_lane
  run "$LANES" clear-ready --lane alpha
  assert_success
  assert_output --partial "clear-ready: alpha"
  run reg alpha .clear_ready
  assert_output true
  run state alpha '.handshake | [.state, .head, .goal] | join("|")'
  assert_output "ready|$(git -C "$WORK" rev-parse HEAD)|finish item A1 and report done"
}

@test "clear-ready finds its own lane from TMUX_PANE when --lane is absent" {
  setup_lane
  TMUX_PANE=%7 run "$LANES" clear-ready
  assert_success
  TMUX_PANE=%55 run "$LANES" clear-ready
  assert_failure
  assert_output --partial "cannot tell which lane"
}

@test "dirty tree: clear-ready refuses and names the fix" {
  setup_lane
  printf 'y\n' >>"$WORK/file"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "uncommitted changes"
  run reg alpha .clear_ready
  assert_output false
}

@test "unpushed head: clear-ready refuses" {
  setup_lane
  git -C "$WORK" commit -q --allow-empty -m local
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "1 unpushed commit"
}

@test "a branch with no upstream is refused" {
  setup_lane
  git -C "$WORK" checkout -q -b side
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "no upstream"
}

@test "empty journal: no RESUME file means not clear-ready, with the init command" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "lanes init alpha"
}

@test "clear_ready_refused_missing_sections" {
  setup_lane
  sed '/### Links/d' "$WORK/.lanes/next-alpha.md" >"$LANES_TEST_TMP/n" && mv "$LANES_TEST_TMP/n" "$WORK/.lanes/next-alpha.md"
  git -C "$WORK" commit -qam drop && git -C "$WORK" push -q
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "no '### Links' section"
}

@test "an empty Next step is refused" {
  make_repo
  write_resume alpha "a goal" "<!-- the one next action -->"
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "'Next step' is empty"
}

@test "goal_with_newline_is_rejected: a two-line Goal is refused at clear-ready" {
  make_repo
  write_resume alpha "first line
second line"
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "'Goal' must be one line"
}

@test "oversize_resume_block_refused_at_write" {
  make_repo
  write_resume alpha "a goal" "$(printf 'x%.0s' $(seq 1 8100))"
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "over the 8000 cap"
}

@test "clear_ready_refused_when_resume_older_than_request: RESUME unchanged since the request" {
  setup_lane
  run "$LANES" request alpha
  assert_success
  assert_output --partial "clear-ready"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "unchanged since the lead's request"
  write_resume alpha "finish item A1, now with tests"
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "request on an unknown lane fails loudly" {
  run "$LANES" request ghost
  assert_failure
  assert_output --partial "no valid registry entry for 'ghost'"
}

@test "lanes request does not overwrite a clear that is in flight (handshake sending)" {
  setup_lane
  "$LANES" clear-ready --lane alpha >/dev/null
  jq '.handshake.state = "sending"' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run "$LANES" request alpha
  assert_failure
  assert_output --partial "in flight"
  run state alpha .handshake.state
  assert_output sending
}

@test "clear-ready checks the work tree it is run from, not the session's start directory" {
  make_repo
  write_resume alpha
  mkdir -p "$LANES_TEST_TMP/start"
  jq -nc --arg c "$LANES_TEST_TMP/start" '{session_id:"s1",session_title:"alpha",cwd:$c,source:"startup"}' | TMUX_PANE=%7 "$LANES" register >/dev/null
  run bash -c "cd '$WORK/.lanes' && '$LANES' clear-ready --lane alpha"
  assert_success
  run state alpha .handshake.worktree
  assert_output "$WORK"
}

@test "clear-ready outside any git work tree is refused and says where to run it" {
  setup_lane
  mkdir -p "$LANES_TEST_TMP/nogit"
  run bash -c "cd '$LANES_TEST_TMP/nogit' && '$LANES' clear-ready --lane alpha"
  assert_failure
  assert_output --partial "not a git work tree"
}

# start_elsewhere: the session started outside the work tree, so its registry cwd has a different journal.
start_elsewhere() {
  make_repo
  write_resume alpha
  mkdir -p "$LANES_TEST_TMP/start"
  jq -nc --arg c "$LANES_TEST_TMP/start" '{session_id:"s1",session_title:"alpha",cwd:$c,source:"startup"}' | TMUX_PANE=%7 "$LANES" register >/dev/null
}

@test "request reads RESUME where the last clear-ready proved it, so 'unchanged since the request' still holds" {
  start_elsewhere
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" request alpha
  assert_output --partial "$WORK/.lanes/next-alpha.md"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "unchanged since the lead's request"
}

@test "clear-ready refuses a RESUME at another place than the one the lead's request read" {
  start_elsewhere
  "$LANES" request alpha >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "$LANES_TEST_TMP/start/.lanes/next-alpha.md"
}

# journal_worktree: the journal lives in a second work tree of the same repo, on its own pushed branch. Sets J.
journal_worktree() {
  make_repo
  J="$LANES_TEST_TMP/jwt"
  git -C "$WORK" worktree add -q -b journal "$J"
  git -C "$J" push -q -u origin journal
  (WORK="$J" && write_resume alpha)
  export LANES_JOURNAL_DIR="$J/.lanes"
}

@test "a journal in its own work tree must be committed and pushed too, at clear-ready" {
  journal_worktree
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_success
  printf 'draft\n' >>"$J/.lanes/note.md"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "the journal's work tree"
  assert_output --partial "uncommitted changes"
  git -C "$J" add .lanes && git -C "$J" commit -q -m note
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "unpushed"
}

@test "a journal work tree left dirty after clear-ready stops lanes clear before anything is typed" {
  journal_worktree
  start_fake alpha
  run "$LANES" clear-ready --lane alpha
  assert_success
  printf 'draft\n' >>"$J/.lanes/note.md"
  run "$LANES" clear alpha
  assert_failure
  assert_output --partial "the journal's work tree"
  run grep -c '^ESC$' "$FAKE_LOG"
  assert_output 0
}
