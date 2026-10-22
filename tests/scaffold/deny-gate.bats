#!/usr/bin/env bats

load ../helpers/common

GATE="$BATS_TEST_DIRNAME/../../scripts/deny-gate.sh"

setup() {
  lanes_test_setup
  REPO="$LANES_TEST_TMP/repo"
  mkdir -p "$REPO/docs"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name t
  unset LANES_DENY_LIST
}
teardown() { lanes_test_teardown; }

write_list() {
  printf 'Grep gate deny-list (case-insensitive): %s\n' "$1" > "$REPO/docs/PORT-SOURCES.local.md"
}

@test "clean tree passes" {
  echo "hello world" > "$REPO/a.txt"
  git -C "$REPO" add a.txt
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  assert_success
}

@test "tracked hit fails with file:line" {
  printf 'one\nuse Acme here\n' > "$REPO/a.txt"
  git -C "$REPO" add a.txt
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "a.txt:2"
}

@test "untracked non-ignored hit fails, ignored file does not" {
  echo "acme" > "$REPO/new.txt"
  echo "acme" > "$REPO/skip.log"
  echo "*.log" > "$REPO/.gitignore"
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "new.txt:1"
  refute_output --partial "skip.log"
}

@test "every hit is reported, across words and files" {
  echo "acme" > "$REPO/a.txt"
  echo "globex" > "$REPO/b.txt"
  git -C "$REPO" add .
  LANES_DENY_LIST="acme, globex" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "a.txt:1"
  assert_output --partial "b.txt:1"
}

@test "list in the local file wins over the env and the file itself is excluded" {
  write_list '`acme`, `globex`.'
  echo "globex" > "$REPO/b.txt"
  git -C "$REPO" add .
  LANES_DENY_LIST="unrelated" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "b.txt:1"
  refute_output --partial "PORT-SOURCES"
}

@test "local file is excluded even when untracked and not ignored" {
  write_list '`acme`'
  run "$GATE" "$REPO"
  assert_success
}

@test "session-name pattern matches whole words only" {
  write_list '`L-1`'
  printf 'see L-1 for more\n' > "$REPO/hit.txt"
  printf 'BUL-12 and L-10 and ABL-1\n' > "$REPO/miss.txt"
  git -C "$REPO" add .
  run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "hit.txt:1"
  refute_output --partial "miss.txt"
}

@test "range L-2..L-4 expands to every session name" {
  write_list '`L-2`..`L-4` session names.'
  echo "lane L-3 owns it" > "$REPO/a.txt"
  git -C "$REPO" add .
  run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "a.txt:1"
}

@test "word with regex characters is matched literally" {
  echo "see a.b" > "$REPO/a.txt"
  echo "see axb" > "$REPO/b.txt"
  git -C "$REPO" add .
  LANES_DENY_LIST="a.b" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "a.txt:1"
  refute_output --partial "b.txt"
}

@test "no list anywhere fails loudly" {
  echo "x" > "$REPO/a.txt"
  run "$GATE" "$REPO"
  assert_failure 2
  assert_output --partial "lanes-deny-gate:"
  assert_output --partial "LANES_DENY_LIST"
}

@test "an empty list is refused, not treated as pass" {
  LANES_DENY_LIST=" , " run "$GATE" "$REPO"
  assert_failure 2
}

@test "binary files are skipped" {
  printf 'acme\0bin' > "$REPO/blob.bin"
  git -C "$REPO" add .
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  assert_success
}

@test "tracked file deleted from the work tree does not crash the gate" {
  echo "ok" > "$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" commit -qm init
  rm "$REPO/a.txt"
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  assert_success
}

@test "a deny-listed word in a tracked file's name fails and names the path" {
  echo "clean content" > "$REPO/acme-notes.txt"
  git -C "$REPO" add .
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "acme-notes.txt"
}

@test "a deny-listed word in an untracked file's directory name fails" {
  mkdir -p "$REPO/globex-tools"
  echo "clean content" > "$REPO/globex-tools/a.txt"
  LANES_DENY_LIST="globex" run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "globex-tools/a.txt"
}

@test "a session-name pattern in a path matches whole words only" {
  write_list '`L-1`'
  echo "clean" > "$REPO/notes-L-1.txt"
  echo "clean" > "$REPO/notes-L-10.txt"
  git -C "$REPO" add .
  run "$GATE" "$REPO"
  assert_failure 1
  assert_output --partial "notes-L-1.txt"
  refute_output --partial "notes-L-10.txt"
}

@test "an unreadable file fails with exit 2 and names the file" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  echo "acme" > "$REPO/secret.txt"
  git -C "$REPO" add .
  chmod 000 "$REPO/secret.txt"
  LANES_DENY_LIST="acme" run "$GATE" "$REPO"
  chmod 644 "$REPO/secret.txt"
  assert_failure 2
  assert_output --partial "secret.txt"
  assert_output --partial "lanes-deny-gate:"
}
