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
  cp "$ROOT/scripts/deny-gate.sh" "$ROOT/scripts/install-hooks.sh" "$REPO/scripts/"
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
