#!/usr/bin/env bats
# The deny-list gate runs as a local pre-push hook (CI does not run it).

load ../helpers/common

ROOT="$BATS_TEST_DIRNAME/../.."

setup() {
  lanes_test_setup
  REPO="$LANES_TEST_TMP/repo"; REMOTE="$LANES_TEST_TMP/remote.git"
  git init -q --bare "$REMOTE"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name t
  mkdir -p "$REPO/scripts" "$REPO/.githooks"
  cp "$ROOT"/scripts/*.sh "$REPO/scripts/"
  cp "$ROOT/.githooks/pre-push" "$REPO/.githooks/"
  git -C "$REPO" remote add origin "$REMOTE"
  unset LANES_DENY_LIST
}
teardown() { lanes_test_teardown; }

@test "install-hooks sets core.hooksPath and is idempotent" {
  run "$REPO/scripts/install-hooks.sh"
  assert_success
  run "$REPO/scripts/install-hooks.sh"
  assert_success
  run git -C "$REPO" config --get-all core.hooksPath
  assert_output ".githooks"
}

@test "the hook blocks a push when a listed word is present" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  echo "use Acme here" > "$REPO/a.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial "a.txt:1"
  run git -C "$REMOTE" rev-parse --verify main
  assert_failure
}

@test "the hook lets a clean push through" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  echo "fine" > "$REPO/a.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_success
  run git -C "$REMOTE" rev-parse --verify main
  assert_success
}

@test "the hook is fail-closed: with no list the push is refused" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  echo "fine" > "$REPO/a.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial "no deny-list"
}

# Commit metadata: the hook also checks author, committer and message of the pushed commits.
commit_file() { # $1 file, $2 message
  echo "fine $1" > "$REPO/$1"; git -C "$REPO" add .
  git -C "$REPO" commit -qm "$2"
}

@test "a commit authored with a listed email is blocked" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  echo fine > "$REPO/a.txt"; git -C "$REPO" add .
  git -C "$REPO" -c user.email=bob@acme.example commit -qm one
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial "author"
  refute_output --partial "acme"
  run git -C "$REMOTE" rev-parse --verify main
  assert_failure
}

@test "a listed word in the committer field is blocked" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  echo fine > "$REPO/a.txt"; git -C "$REPO" add .
  GIT_COMMITTER_NAME="Acme Person" git -C "$REPO" commit -qm one
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial "committer"
  refute_output --partial "Acme"
}

@test "a listed word in the commit message is blocked" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  echo fine > "$REPO/a.txt"; git -C "$REPO" add .
  git -C "$REPO" commit -qm "subject" -m "body mentions ACME here"
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial "message"
  assert_output --partial "$(git -C "$REPO" rev-parse --short HEAD)"
  refute_output --partial "ACME"
}

@test "clean commits pass" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  commit_file a.txt first
  commit_file b.txt second
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_success
}

@test "a new branch is checked" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  commit_file a.txt first
  LANES_DENY_LIST="acme" git -C "$REPO" push -q origin main
  git -C "$REPO" checkout -q -b feature
  commit_file b.txt "acme in message"
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin feature
  assert_failure
  assert_output --partial "message"
  run git -C "$REMOTE" rev-parse --verify feature
  assert_failure
}

@test "an already-pushed commit is not re-flagged" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  commit_file a.txt "mentions acme"
  LANES_DENY_LIST="zqxv" git -C "$REPO" push -q origin main
  commit_file b.txt clean
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin main
  assert_success
  git -C "$REPO" checkout -q -b feature
  commit_file c.txt clean2
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin feature
  assert_success
}

@test "a commit known only from another remote is still checked when pushed to a new branch" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  commit_file a.txt first
  LANES_DENY_LIST="acme" git -C "$REPO" push -q origin main
  PRIVATE="$LANES_TEST_TMP/private.git"; git init -q --bare "$PRIVATE"
  git -C "$REPO" remote add private "$PRIVATE"
  git -C "$REPO" checkout -q -b feature
  git -C "$REPO" -c user.email=bob@acme.example commit -q --allow-empty -m private-work
  LANES_DENY_LIST="zqxv" git -C "$REPO" push -q private feature
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin feature
  assert_failure
  assert_output --partial "author"
  run git -C "$REMOTE" rev-parse --verify feature
  assert_failure
}

# Conflict markers: the hook refuses a push whose tip tree holds an unresolved merge conflict.
conflict_text() { printf 'keep\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/main\n'; }

@test "a pushed commit with conflict markers is refused and names each file:line" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  conflict_text > "$REPO/.gitignore"
  printf 'Title\n=======\n' > "$REPO/notes.md"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  LANES_DENY_LIST="zqxv" run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial ".gitignore:2"
  assert_output --partial ".gitignore:4"
  assert_output --partial ".gitignore:6"
  refute_output --partial "notes.md"
  run git -C "$REMOTE" rev-parse --verify main
  assert_failure
}

@test "the pushed commit is checked, not the work tree" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  conflict_text > "$REPO/a.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  echo resolved > "$REPO/a.txt"
  LANES_DENY_LIST="zqxv" run git -C "$REPO" push origin main
  assert_failure
  assert_output --partial "a.txt:2"
  run git -C "$REMOTE" rev-parse --verify main
  assert_failure
}

@test "a clean push passes the conflict-marker check" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  printf 'text\n  <<<<<<< indented\n<<<<<<<\n========\n' > "$REPO/a.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  conflict_text > "$REPO/b.txt"   # untracked in the work tree: not pushed, so not checked
  LANES_DENY_LIST="zqxv" run git -C "$REPO" push origin main
  assert_success
  run git -C "$REMOTE" rev-parse --verify main
  assert_success
}

@test "a markdown setext underline of seven = with no other marker passes" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  printf 'Title\n=======\n\nLonger heading\n==============\n' > "$REPO/README.md"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm one
  LANES_DENY_LIST="zqxv" run git -C "$REPO" push origin main
  assert_success
}

@test "only the tip tree is checked: a marker fixed by a later pushed commit passes" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  conflict_text > "$REPO/a.txt"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm broken
  echo resolved > "$REPO/a.txt"
  git -C "$REPO" commit -qam fixed
  LANES_DENY_LIST="zqxv" run git -C "$REPO" push origin main
  assert_success
}

@test "deleting a branch passes" {
  "$REPO/scripts/install-hooks.sh" >/dev/null
  commit_file a.txt first
  git -C "$REPO" branch feature
  LANES_DENY_LIST="acme" git -C "$REPO" push -q origin main feature
  LANES_DENY_LIST="acme" run git -C "$REPO" push origin --delete feature
  assert_success
  run git -C "$REMOTE" rev-parse --verify feature
  assert_failure
}
