#!/usr/bin/env bash
# Fails when the tree of one commit holds an unresolved git conflict marker, and names each file:line.
# A line of exactly "=======" counts only in a file that also has a "<<<<<<< x" or ">>>>>>> x" line, so a
# markdown setext underline does not trip it. It reads the commit, not the work tree: that is what a push sends.
# Usage: marker-gate.sh <repo-dir> <commit>
# Exit 0 clean, 1 markers found, 2 bad arguments, a git failure or a Bash older than 4.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "${0##*/}: requires Bash 4 or newer: on macOS run 'brew install bash'" >&2; exit 2; }
set -euo pipefail

die() { echo "lanes-marker-gate: $1: $2" >&2; exit 2; }

[ "$#" -eq 2 ] || die "usage: marker-gate.sh <repo-dir> <commit>" "pass the repo dir and the commit to check"
ROOT="$1"; REV="$2"
sha="$(git -C "$ROOT" rev-parse --verify --quiet "$REV^{commit}")" || die "not a commit: $REV" "pass a commit that exists locally"

# Records are "<sha>:<path>\0<line>\0<text>\n"; -z keeps the path verbatim. -I skips binary files.
out="$(mktemp "${TMPDIR:-/tmp}/lanes-markers.XXXXXX")"
trap 'rm -f "$out"' EXIT
rc=0
git -C "$ROOT" grep -n -z -I -E -e '^<<<<<<< .' -e '^=======$' -e '^>>>>>>> .' "$sha" -- > "$out" || rc=$?
[ "$rc" -le 1 ] || die "git grep failed on $sha (exit $rc)" "check the repository"
[ "$rc" -eq 0 ] || exit 0

declare -A strong=()
paths=(); lines=()
while IFS= read -r -d '' path && IFS= read -r -d '' line && IFS= read -r text; do
  path="${path#"$sha:"}"
  paths+=("$path"); lines+=("$line")
  [ "$text" = "=======" ] || strong["$path"]=1
done < "$out"

hits=()
for i in "${!paths[@]}"; do
  if [ -n "${strong[${paths[$i]}]:-}" ]; then hits+=("${paths[$i]}:${lines[$i]}"); fi
done
[ "${#hits[@]}" -gt 0 ] || exit 0

echo "lanes-marker-gate: unresolved conflict markers in commit $(git -C "$ROOT" rev-parse --short "$sha"): resolve them and commit before pushing:" >&2
printf '  %s\n' "${hits[@]}" >&2
exit 1
