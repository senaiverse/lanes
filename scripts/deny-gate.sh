#!/usr/bin/env bash
# Fails when a tracked or untracked-non-ignored file, by its path or its contents, holds a word from the private deny-list.
# The list comes from docs/PORT-SOURCES.local.md (line "Grep gate deny-list") or else from LANES_DENY_LIST.
# With --commits it scans no files: it checks the author, committer and message of each commit that
# `git rev-list <rev-list-args>` yields, and names the short sha and the field, never the word.
# Usage: deny-gate.sh [repo-dir] [--commits <rev-list-args>...]
# Exit 0 clean, 1 hits, 2 no usable list, not a git repo, or an unreadable file.
set -euo pipefail

die() { echo "lanes-deny-gate: $1: $2" >&2; exit 2; }

ROOT=""
if [ "$#" -gt 0 ] && [ "$1" != "--commits" ]; then ROOT="$1"; shift; fi
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMMITS=0; REV_ARGS=()
if [ "${1:-}" = "--commits" ]; then
  COMMITS=1; shift
  [ "$#" -gt 0 ] || die "--commits needs a revision range" "pass rev-list arguments after --commits"
  REV_ARGS=("$@")
fi
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $ROOT" "pass the repo dir as the first argument"

LOCAL_REL="docs/PORT-SOURCES.local.md"
LOCAL="$ROOT/$LOCAL_REL"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanes-deny.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
WORDS="$TMP/words"   # one entry per line, literal
: > "$WORDS"

# A backtick entry, optionally a range `L-2`..`L-4` that expands over the trailing number.
parse_local_line() {
  local line="$1" entry a b prefix lo hi i
  # shellcheck disable=SC2016  # the backticks are literal characters in the list file
  while IFS= read -r entry; do
    case "$entry" in
      *'..'*)
        a="${entry%%..*}"; b="${entry#*..}"
        a="${a//\`/}"; b="${b//\`/}"
        prefix="${a%"${a##*[!0-9]}"}"
        lo="${a#"$prefix"}"; hi="${b#"$prefix"}"
        case "$lo$hi" in *[!0-9]*|'') die "bad range in deny-list: $entry" "write a range as \`L-1\`..\`L-5\`" ;; esac
        i="$lo"
        while [ "$i" -le "$hi" ]; do printf '%s%s\n' "$prefix" "$i"; i=$((i + 1)); done
        ;;
      *) printf '%s\n' "${entry//\`/}" ;;
    esac
  done < <(printf '%s\n' "$line" | grep -oE '`[^`]+`(\.\.`[^`]+`)?')
}

if [ -f "$LOCAL" ]; then
  line="$(grep -m1 '^Grep gate deny-list' "$LOCAL" || true)"
  [ -n "$line" ] || die "no 'Grep gate deny-list' line in $LOCAL_REL" "add the line or unset the file and use LANES_DENY_LIST"
  parse_local_line "$line" >> "$WORDS"
elif [ -n "${LANES_DENY_LIST:-}" ]; then
  printf '%s\n' "$LANES_DENY_LIST" | tr ',' '\n' >> "$WORDS"
else
  die "no deny-list" "create $LOCAL_REL or set LANES_DENY_LIST (comma-separated)"
fi

# Trim blanks and drop empty entries: an empty pattern would match every line.
CLEAN="$TMP/clean"
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WORDS" | grep -v '^$' > "$CLEAN" || true
[ -s "$CLEAN" ] || die "the deny-list is empty" "an empty list would pass everything; fix the list"

# "L-1" style session names match whole words only; everything else is a literal substring.
FIXED="$TMP/fixed"; REGEX="$TMP/regex"
: > "$FIXED"; : > "$REGEX"
while IFS= read -r w; do
  if printf '%s' "$w" | grep -qE '^[A-Za-z]+-[0-9]+$'; then
    printf '(^|[^[:alnum:]])%s([^[:alnum:]]|$)\n' "$w" >> "$REGEX"
  else
    printf '%s\n' "$w" >> "$FIXED"
  fi
done < "$CLEAN"

if [ "$COMMITS" -eq 1 ]; then
  CHIT="$TMP/commit-hits"; : > "$CHIT"
  field_hit() { # $1 text, $2 sha, $3 field label; same -F/-E rules and error handling as scan()
    local pf mode rc
    for mode in -F -E; do
      if [ "$mode" = "-F" ]; then pf="$FIXED"; else pf="$REGEX"; fi
      [ -s "$pf" ] || continue
      rc=0; grep -qi "$mode" -f "$pf" <<< "$1" || rc=$?
      [ "$rc" -le 1 ] || die "grep failed on commit $2 (exit $rc)" "fix the deny-list pattern"
      if [ "$rc" -eq 0 ]; then printf '%s %s\n' "$2" "$3" >> "$CHIT"; return 0; fi
    done
  }
  revs="$(git -C "$ROOT" rev-list "${REV_ARGS[@]}")" || die "git rev-list failed for: ${REV_ARGS[*]}" "check the pushed refs exist locally"
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    short="$(git -C "$ROOT" rev-parse --short "$sha")"
    field_hit "$(git -C "$ROOT" log -1 --format='%an%n%ae' "$sha")" "$short" author
    field_hit "$(git -C "$ROOT" log -1 --format='%cn%n%ce' "$sha")" "$short" committer
    field_hit "$(git -C "$ROOT" log -1 --format='%B' "$sha")" "$short" message
  done <<< "$revs"
  if [ -s "$CHIT" ]; then
    echo "lanes-deny-gate: deny-listed word found in a commit (short sha, field): rewrite the commit before pushing:" >&2
    sed 's/^/  /' "$CHIT" >&2
    exit 1
  fi
  echo "lanes-deny-gate: commits clean"
  exit 0
fi

# Existing files to scan, one path per line: tracked and untracked-not-ignored, minus the private list itself.
LIST="$TMP/list"; : > "$LIST"
while IFS= read -r f; do
  if [ -f "$ROOT/$f" ] && [ "$f" != "$LOCAL_REL" ]; then printf '%s\n' "$f" >> "$LIST"; fi
done < <({ git -C "$ROOT" ls-files -z; git -C "$ROOT" ls-files -z --others --exclude-standard; } | tr '\0' '\n' | sort -u)

# Scans every listed file's path and contents. grep exits 0 on a match, 1 on none and 2+ on an error, so an
# error is told apart from "no hit" and fails the gate instead of passing it.
HITS="$TMP/hits"; : > "$HITS"
scan() { # $1 pattern file, $2 grep mode (-F or -E)
  local pf="$1" mode="$2" f rc
  [ -s "$pf" ] || return 0
  while IFS= read -r f; do
    rc=0; grep -qi "$mode" -f "$pf" <<< "$f" || rc=$?
    [ "$rc" -le 1 ] || die "grep failed on the path $f (exit $rc)" "fix the deny-list pattern"
    [ "$rc" -ne 0 ] || printf '%s:(path)\n' "$f" >> "$HITS"
    [ -r "$ROOT/$f" ] || die "cannot read $f" "fix its permissions: an unreadable file cannot be scanned"
    rc=0; (cd "$ROOT" && grep -HnIi "$mode" -f "$pf" -- "$f") >> "$HITS" || rc=$?
    [ "$rc" -le 1 ] || die "grep failed on $f (exit $rc)" "check the file and the deny-list pattern"
  done < "$LIST"
}
scan "$FIXED" -F
scan "$REGEX" -E

if [ -s "$HITS" ]; then
  echo "lanes-deny-gate: deny-listed word found in a file name or its contents: remove or rewrite each occurrence:" >&2
  sort -u "$HITS" | cut -d: -f1,2 | sed 's/^/  /' >&2
  exit 1
fi
echo "lanes-deny-gate: clean"
