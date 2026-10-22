#!/usr/bin/env bats
# Public seam: `lanes-guard main-edit`, fed PreToolUse stdin for Edit, Write and NotebookEdit against a real git repo
# with linked worktrees.
bats_require_minimum_version 1.5.0

load helper

enable() {
  write_guards "$WT" 'main_checkout_guard: on'
  write_guards "$REPO" 'main_checkout_guard: on'
  export CLAUDE_PROJECT_DIR="$WT"
}

@test "the guard is off until a project enables it" {
  make_repo
  export CLAUDE_PROJECT_DIR="$WT"
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/README.md" "$WT")"
  assert_untouched
}

@test "a lane's Edit, Write and NotebookEdit in the main checkout are refused with the rule and the worktree path" {
  make_repo
  enable
  for tool in Edit Write NotebookEdit; do
    run_guard main-edit "$(file_input "$tool" sid-lane1 "$REPO/README.md" "$WT")"
    assert_denied "main-edit" || { echo "tool: $tool"; return 1; }
  done
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"$REPO/README.md"* ]]
  [[ "$reason" == *"$WT/README.md"* ]]
}

@test "a path in the lane's own worktree is allowed" {
  make_repo
  enable
  run_guard main-edit "$(file_input Edit sid-lane1 "$WT/README.md" "$WT")"
  assert_untouched
  run_guard main-edit "$(file_input Write sid-lane1 "$WT/new/dir/file.txt" "$WT")"
  assert_untouched
}

@test "a new file in a directory that does not exist yet in the main checkout is refused" {
  make_repo
  enable
  run_guard main-edit "$(file_input Write sid-lane1 "$REPO/brand/new/dir/file.txt" "$WT")"
  assert_denied "main-edit"
}

@test "a relative path is resolved against the session's directory" {
  make_repo
  enable
  run_guard main-edit "$(file_input Edit sid-lane1 "../repo/README.md" "$WT")"
  assert_denied "main-edit"
  run_guard main-edit "$(file_input Edit sid-lane1 "README.md" "$WT")"
  assert_untouched
  run_guard main-edit "$(file_input Edit sid-lane1 "src/../../repo/README.md" "$WT")"
  assert_denied "main-edit"
}

@test "a worktree nested inside the main checkout is a worktree, not the main checkout" {
  make_repo
  enable
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/.wt/nested/README.md" "$WT")"
  assert_untouched
}

@test "the main checkout's git directory is part of the main checkout" {
  make_repo
  enable
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/.git/hooks/pre-commit" "$WT")"
  assert_denied "main-edit"
}

@test "a symlink in a worktree that points into the main checkout is refused" {
  make_repo
  enable
  ln -s "$REPO/README.md" "$WT/link.md"
  ln -s "$REPO/src" "$WT/srclink"
  run_guard main-edit "$(file_input Edit sid-lane1 "$WT/link.md" "$WT")"
  assert_denied "main-edit"
  run_guard main-edit "$(file_input Write sid-lane1 "$WT/srclink/app.txt" "$WT")"
  assert_denied "main-edit"
  run_guard main-edit "$(file_input Write sid-lane1 "$WT/srclink/newdir/x.txt" "$WT")"
  assert_denied "main-edit"
}

@test "a symlink that points from the main checkout into a worktree is allowed" {
  make_repo
  enable
  ln -s "$WT/README.md" "$REPO/to-wt.md"
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/to-wt.md" "$WT")"
  assert_untouched
}

@test "a path outside the repository, or in another repository, is allowed" {
  make_repo
  enable
  run_guard main-edit "$(file_input Write sid-lane1 "$LANES_TEST_TMP/elsewhere/notes.md" "$WT")"
  assert_untouched
  git init -q "$LANES_TEST_TMP/other"
  run_guard main-edit "$(file_input Write sid-lane1 "$LANES_TEST_TMP/other/a.txt" "$WT")"
  assert_untouched
}

@test "with no linked worktree there is nothing to protect and an edit passes" {
  make_repo
  git -C "$REPO" worktree remove --force "$WT"
  git -C "$REPO" worktree remove --force "$REPO/.wt/nested"
  write_guards "$REPO" 'main_checkout_guard: on'
  export CLAUDE_PROJECT_DIR="$REPO"
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/README.md" "$REPO")"
  assert_untouched
}

@test "the lead is refused too unless guards.md exempts the lead" {
  make_repo
  enable
  run_guard main-edit "$(file_input Edit sid-lead "$REPO/README.md" "$REPO")"
  assert_denied "lead_exempt_main_checkout"
  write_guards "$WT" $'main_checkout_guard: on\nlead_exempt_main_checkout: yes'
  run_guard main-edit "$(file_input Edit sid-lead "$REPO/README.md" "$REPO")"
  assert_untouched
}

@test "the exemption is for the lead only, and an unregistered session is not exempt" {
  make_repo
  write_guards "$WT" $'main_checkout_guard: on\nlead_exempt_main_checkout: yes'
  export CLAUDE_PROJECT_DIR="$WT"
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/README.md" "$WT")"
  assert_denied "main-edit"
  run_guard main-edit "$(file_input Edit sid-stranger "$REPO/README.md" "$WT")"
  assert_denied "main-edit"
}

@test "a session directory that is not in a git repository passes with a stderr note" {
  make_repo
  write_guards "$PROJECT" 'main_checkout_guard: on'
  export CLAUDE_PROJECT_DIR="$PROJECT"
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/README.md" "$PROJECT")"
  assert_untouched
  [[ "$stderr" == *"not a git"* ]]
}

@test "a missing path, another tool or malformed stdin fails open with a note where stdin is malformed" {
  make_repo
  enable
  run_guard main-edit '{"session_id":"s","cwd":"/x","tool_name":"Edit","tool_input":{}}'
  assert_untouched
  run_guard main-edit '{"session_id":"s","cwd":"/x","tool_name":"Read","tool_input":{"file_path":"/x"}}'
  assert_untouched
  run --separate-stderr "$GUARD" main-edit <<<'{"tool_input":'
  assert_untouched
  [[ "$stderr" == *"lanes-guard:"* ]]
}
