#!/usr/bin/env bats
# Public seam: `lanes init`. It writes the journal template, never overwrites, prints the statusLine block, and edits
# CLAUDE.md only on an explicit yes, at most once.

load helper

@test "init writes the journal files and per-lane files with the lane name filled in" {
  make_repo
  cd "$WORK"
  run "$LANES" init alpha
  assert_success
  for f in README.md RULES.md tracker.md morning.md next-alpha.md done-alpha.md; do
    assert [ -s "$WORK/.lanes/$f" ]
  done
  run grep -c '<lane>' "$WORK/.lanes/next-alpha.md"
  assert_output 0
  run grep -qF '# next-alpha' "$WORK/.lanes/next-alpha.md"
  assert_success
}

@test "a fresh next-<lane>.md has the markers and every required section, but is not yet clear-ready" {
  make_repo
  cd "$WORK"
  "$LANES" init alpha >/dev/null
  git add .lanes && git commit -qm journal && git push -q
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  refute_output --partial "section"
  assert_output --partial "is empty"
}

@test "init is idempotent: a second run keeps every existing file byte for byte" {
  make_repo
  cd "$WORK"
  "$LANES" init alpha >/dev/null
  printf 'my own tracker\n' >"$WORK/.lanes/tracker.md"
  run "$LANES" init alpha
  assert_success
  assert_output --partial "kept (already there)"
  run cat "$WORK/.lanes/tracker.md"
  assert_output "my own tracker"
}

@test "init prints a statusLine block that points at the stable link under the data dir" {
  make_repo
  cd "$WORK"
  run "$LANES" init
  assert_success
  assert_output --partial '"statusLine"'
  assert_output --partial "$LANES_DATA_DIR/lanes-statusline"
  run readlink "$LANES_DATA_DIR/lanes-statusline"
  assert_output "$LANES_REPO_ROOT/plugins/lanes/bin/lanes-statusline"
}

@test "without an answer and without a terminal, CLAUDE.md is not touched and the command to add it is printed" {
  make_repo
  cd "$WORK"
  run "$LANES" init </dev/null
  assert_success
  assert_output --partial "lanes init --claude-md yes"
  assert [ ! -e "$WORK/CLAUDE.md" ]
}

@test "--claude-md yes adds the import once; a second run says it is already there" {
  make_repo
  cd "$WORK"
  printf '# project\n' >"$WORK/CLAUDE.md"
  run "$LANES" init --claude-md yes
  assert_success
  run grep -cxF '@.lanes/RULES.md' "$WORK/CLAUDE.md"
  assert_output 1
  run "$LANES" init --claude-md yes
  assert_output --partial "already imports"
  run grep -cxF '@.lanes/RULES.md' "$WORK/CLAUDE.md"
  assert_output 1
  run head -1 "$WORK/CLAUDE.md"
  assert_output "# project"
}

@test "--claude-md no leaves CLAUDE.md alone" {
  make_repo
  cd "$WORK"
  run "$LANES" init --claude-md no
  assert_success
  assert [ ! -e "$WORK/CLAUDE.md" ]
}

@test "--claude-md with no value prints the usage and writes nothing" {
  make_repo
  cd "$WORK"
  run "$LANES" init --claude-md
  assert_failure 2
  assert_output --partial "lanes: usage:"
  assert [ ! -e "$WORK/.lanes" ]
}

@test "init writes the journal into the folder recorded for its own project" {
  make_repo
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=journal "$LANES" register 2>/dev/null >/dev/null
  mkdir -p "$LANES_TEST_TMP/other"
  jq -nc --arg c "$LANES_TEST_TMP/other" '{session_id:"o1",session_title:"beta",cwd:$c,source:"startup"}' |
    TMUX_PANE=%8 CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=elsewhere "$LANES" register 2>/dev/null >/dev/null
  cd "$WORK"
  run "$LANES" init --claude-md no
  assert_success
  assert_output --partial "journal: $WORK/journal"
  assert [ -f "$WORK/journal/RULES.md" ]
}

@test "init from a subdirectory writes the journal at the git top level" {
  make_repo
  mkdir -p "$WORK/sub/dir"
  cd "$WORK/sub/dir"
  "$LANES" init >/dev/null
  assert [ -f "$WORK/.lanes/RULES.md" ]
}

@test "an invalid lane name is refused" {
  make_repo
  cd "$WORK"
  run "$LANES" init '../x'
  assert_failure 2
}
