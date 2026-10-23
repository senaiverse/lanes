#!/usr/bin/env bats
# Seam: every file under fixtures/, which ships in a public repo. A capture from a real session carries this machine's
# and this account's ids, so each one is replaced by a fixed fake of the same shape before it is committed.

load helper

FIXTURES="$BATS_TEST_DIRNAME/fixtures"
# Read before setup, which may point HOME at a temp dir.
REAL_HOME="$HOME"

# found <extended regex>: print file:line:match for every match in the fixtures; exit 1 when there is none.
found() { grep -rnoE -- "$1" "$FIXTURES"; }

@test "the fixtures exist, so every scan below reads something" {
  run found '"pidDomain"'
  assert_success
  run found '"sessionId"'
  assert_success
}

@test "no fixture holds this machine's /etc/machine-id" {
  [[ -r /etc/machine-id ]] || skip "no /etc/machine-id on this host"
  id="$(tr -d '[:space:]' </etc/machine-id)"
  [[ -n "$id" ]] || skip "/etc/machine-id is empty"
  run grep -rnoiF -- "$id" "$FIXTURES"
  assert_failure 1
}

@test "every pidDomain has an all-zero machine part" {
  run bash -c 'grep -rhoE "\"pidDomain\":\"[^\"]*\"" "$1" | grep -vE "^\"pidDomain\":\"linux:0{32}:pid:\[[0-9]+\]\"$"' _ "$FIXTURES"
  assert_failure 1
}

@test "no fixture holds a real API request, message or tool-use id" {
  run found 'req_[A-Za-z0-9]{10,}'
  assert_failure 1
  run found 'msg_[A-Za-z0-9]{10,}'
  assert_failure 1
  run found 'toolu_[A-Za-z0-9]{10,}'
  assert_failure 1
}

@test "every UUID in a fixture is one of the 00000000-0000-4000-8000- fakes" {
  run bash -c 'grep -rhoiE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" "$1" | grep -vE "^00000000-0000-4000-8000-[0-9]{12}$"' _ "$FIXTURES"
  assert_failure 1
}

@test "no fixture names a home directory" {
  run found '/(home|Users)/[^/" ]+|/root/'
  assert_failure 1
  [[ -n "$REAL_HOME" && "$REAL_HOME" != / ]] || return 0
  run grep -rnoF -- "$REAL_HOME" "$FIXTURES"
  assert_failure 1
}
