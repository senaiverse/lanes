#!/usr/bin/env bash
# Fetches pinned bats-core and shellcheck into the gitignored .tools/ when missing (no sudo), then runs
# Shellcheck on plugin bin/ files and scripts/*.sh, then the bats suites. Pins live in this file only.
# Usage: scripts/test.sh [suite-dir...]. With none, every suite and every plugin runs. With suite directories (for
# example tests/lanes-plancheck), only those suites run and only the plugins of the same name are shellchecked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"

BATS_CORE_TAG=v1.14.0;    BATS_CORE_SHA=eb7f42f8d608ac693d7a4b67474f6714ea68cfc5
BATS_SUPPORT_TAG=v0.3.0;  BATS_SUPPORT_SHA=24a72e14349690bcbf7c151b9d2d1cdd32d36eb1
BATS_ASSERT_TAG=v2.2.4;   BATS_ASSERT_SHA=f1e9280eaae8f86cbe278a687e6ba755bc802c1a
SHELLCHECK_VERSION=v0.11.0

die() { echo "lanes-test: $1: $2" >&2; exit 1; }

# Clone a pinned tag and verify the commit, so a moved tag fails loudly.
fetch_git() { # name repo tag sha
  local dir="$TOOLS/$1"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$4" ]; then return 0; fi
  rm -rf "$dir"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "https://github.com/$2.git" "$dir" \
    || die "cannot clone $2 $3" "check the network and retry"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$4" ] \
    || { rm -rf "$dir"; die "$2 $3 is not the pinned commit $4" "the tag moved; verify upstream before updating the pin"; }
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Unpack a zip with unzip, else with Windows' own bsdtar (Git Bash's tar cannot read zip).
unzip_to() { # zip dest
  if command -v unzip >/dev/null 2>&1; then unzip -q "$1" -d "$2"
  elif [ -n "${SYSTEMROOT:-}" ] && [ -x "$SYSTEMROOT/System32/tar.exe" ]; then "$SYSTEMROOT/System32/tar.exe" -xf "$1" -C "$2"
  else return 1
  fi
}

fetch_shellcheck() {
  local os arch plat sum dir tarball url stage exe=shellcheck
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os/$arch" in
    MINGW64_NT-*/x86_64|MSYS_NT-*/x86_64) plat=zip; exe=shellcheck.exe; sum=8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e ;;
    Linux/x86_64)  plat=linux.x86_64;  sum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
    Linux/aarch64|Linux/arm64) plat=linux.aarch64; sum=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
    Darwin/arm64)  plat=darwin.aarch64; sum=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
    Darwin/x86_64) plat=darwin.x86_64;  sum=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
    *) die "unsupported platform $os/$arch" "use Linux, macOS or Git Bash on x86_64 Windows" ;;
  esac
  dir="$TOOLS/shellcheck-$SHELLCHECK_VERSION"
  [ -x "$dir/$exe" ] && return 0
  stage="$(mktemp -d "$TOOLS/.stage.XXXXXX")"
  if [ "$plat" = zip ]; then
    tarball="$stage/sc.zip"
    url="https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VERSION/shellcheck-$SHELLCHECK_VERSION.zip"
  else
    tarball="$stage/sc.tar.xz"
    url="https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VERSION/shellcheck-$SHELLCHECK_VERSION.$plat.tar.xz"
  fi
  curl -fsSL -o "$tarball" "$url" \
    || { rm -rf "$stage"; die "cannot download shellcheck $SHELLCHECK_VERSION" "check the network and retry"; }
  [ "$(sha256_of "$tarball")" = "$sum" ] \
    || { rm -rf "$stage"; die "shellcheck checksum mismatch for $plat" "do not use the download; verify the release"; }
  if [ "$plat" = zip ]; then
    # The zip holds shellcheck.exe at its top level, so it unpacks into the final directory name directly.
    mkdir "$stage/shellcheck-$SHELLCHECK_VERSION"
    unzip_to "$tarball" "$stage/shellcheck-$SHELLCHECK_VERSION" || { rm -rf "$stage"; die "cannot unpack shellcheck" "install unzip and retry"; }
    [ -x "$stage/shellcheck-$SHELLCHECK_VERSION/$exe" ] || { rm -rf "$stage"; die "$exe is not in the shellcheck zip" "the release layout changed; verify upstream"; }
  else
    tar -xJf "$tarball" -C "$stage" || { rm -rf "$stage"; die "cannot unpack shellcheck" "install xz and retry"; }
  fi
  rm -rf "$dir"
  mv "$stage/shellcheck-$SHELLCHECK_VERSION" "$dir"   # same filesystem, so the move is atomic
  rm -rf "$stage"
}

cd "$ROOT"   # suite arguments are relative to the repository root (absolute paths work too)
suites=()
for s in "$@"; do
  [ -d "$s" ] || die "suite directory $s not found" "pass a directory of .bats files, for example tests/lanes-plancheck"
  suites+=("$s")
done

mkdir -p "$TOOLS"
fetch_git bats-core    bats-core/bats-core    "$BATS_CORE_TAG"    "$BATS_CORE_SHA"
fetch_git bats-support bats-core/bats-support "$BATS_SUPPORT_TAG" "$BATS_SUPPORT_SHA"
fetch_git bats-assert  bats-core/bats-assert  "$BATS_ASSERT_TAG"  "$BATS_ASSERT_SHA"
fetch_shellcheck

SHELLCHECK="$TOOLS/shellcheck-$SHELLCHECK_VERSION/shellcheck"
[ -x "$SHELLCHECK" ] || SHELLCHECK="$SHELLCHECK.exe"
export LANES_TOOLS_DIR="$TOOLS"

# Whole run: every plugin. Suite run: the plugin named like each suite directory, when it exists.
bins=()
if [ "${#suites[@]}" -eq 0 ]; then
  bins=("$ROOT"/plugins/*/bin/*)
else
  for s in "${suites[@]}"; do bins+=("$ROOT/plugins/$(basename "$s")"/bin/*); done
fi
targets=()
for f in "${bins[@]}" "$ROOT"/scripts/*.sh "$ROOT"/.githooks/*; do
  [ -f "$f" ] && targets+=("$f")
done
echo "lanes-test: shellcheck ${#targets[@]} files"
if [ "${#targets[@]}" -gt 0 ]; then "$SHELLCHECK" -x "${targets[@]}"; fi

[ "${#suites[@]}" -gt 0 ] || suites=(tests/)
# A test that hangs fails after this many seconds instead of holding the run (and the machine) indefinitely.
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-120}"
"$TOOLS/bats-core/bin/bats" -r "${suites[@]}"
