#!/usr/bin/env bats
# Public seam: `lanes-guard lead-only`, fed PreToolUse stdin for the Bash tool.
bats_require_minimum_version 1.5.0

load helper

@test "the lead may run a matching command" {
  bash_untouched sid-lead 'gh workflow run ci.yml'
  bash_untouched sid-lead 'gh pr merge 12 --squash'
}

@test "a lane is refused, and the reason names the rule and the allowed path" {
  run_guard lead-only "$(bash_input sid-lane1 'gh pr merge 12')"
  assert_denied "lead-only"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"gh pr merge"* ]]
  [[ "$reason" == *"lane1"* ]]
  [[ "$reason" == *"ask the lead"* ]]
  [[ "$reason" == *"guards.md"* ]]
}

@test "an unregistered session is refused for a matching command, with how to register" {
  run_guard lead-only "$(bash_input sid-stranger 'gh workflow run ci.yml')"
  assert_denied "not in the lanes registry"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"claude --name"* ]]
  [[ "$reason" == *"lanes register"* ]]
}

@test "an unregistered session runs a non-matching command untouched" {
  bash_untouched sid-stranger 'ls -la'
}

@test "an empty registry directory still refuses a matching command and passes the rest" {
  rm -rf "${LANES_DATA_DIR:?}/lanes"
  bash_denied sid-lead 'gh pr merge 1'
  bash_untouched sid-lead 'echo hi'
}

@test "identity is the session id looked up in the session index, with no session_title in the input" {
  bash_untouched sid-lead 'gh pr merge 1'
  run_guard lead-only "$(bash_input sid-lane1 'gh pr merge 1')"
  assert_denied 'lane "lane1"'
}

@test "a rotated session id after /clear is the lane its index line names, whatever the registry file still holds" {
  echo lane1 >"$LANES_DATA_DIR/sessions/sid-after-clear"
  run_guard lead-only "$(bash_input sid-after-clear 'gh pr merge 1')"
  assert_denied 'lane "lane1"'
  echo lead >"$LANES_DATA_DIR/sessions/sid-after-clear"
  bash_untouched sid-after-clear 'gh pr merge 1'
}

@test "the guard does not scan the registry files for a session id" {
  jq -n '{lane:"ghost",session_id:"sid-ghost",role:"lead"}' >"$LANES_DATA_DIR/lanes/ghost.json"
  bash_denied sid-ghost 'gh pr merge 1'
}

@test "an index line that is not a safe lane name, or a session id that is not a safe file name, cannot escape the data directory" {
  jq -n '{lane:"lead",session_id:"x",role:"lead"}' >"$LANES_DATA_DIR/outside.json"
  echo '../outside' >"$LANES_DATA_DIR/sessions/sid-evil"
  bash_denied sid-evil 'gh pr merge 1'
  printf 'lead\n' >"$LANES_DATA_DIR/lead-line"
  bash_denied '../lead-line' 'gh pr merge 1'
}

@test "an index line naming a lane with no registry file is unregistered" {
  echo vanished >"$LANES_DATA_DIR/sessions/sid-v"
  bash_denied sid-v 'gh pr merge 1'
}

@test "a corrupt registry file counts as unregistered for a matching command, with a stderr note" {
  printf '{"role": "lea' >"$LANES_DATA_DIR/lanes/lead.json"
  run_guard lead-only "$(bash_input sid-lead 'gh pr merge 1')"
  assert_denied "not in the lanes registry"
  [[ "$stderr" == *"unreadable"* ]]
}

@test "a registry entry with an unknown role is not the lead" {
  register odd observer sid-odd
  bash_denied sid-odd 'gh pr merge 1'
}

@test "without LANES_DATA_DIR the registry is read from the XDG state directory" {
  unset LANES_DATA_DIR
  export XDG_STATE_HOME="$LANES_TEST_TMP/state"
  mkdir -p "$XDG_STATE_HOME/lanes/lanes" "$XDG_STATE_HOME/lanes/sessions"
  echo lead >"$XDG_STATE_HOME/lanes/sessions/sid-lead"
  jq -n '{lane:"lead",session_id:"sid-lead",role:"lead"}' >"$XDG_STATE_HOME/lanes/lanes/lead.json"
  bash_untouched sid-lead 'gh pr merge 1'
  bash_denied sid-lane1 'gh pr merge 1'
}

@test "every default pattern is refused for a lane" {
  make_repo
  bash_denied sid-lane1 'gh workflow run ci.yml' "$REPO"
  bash_denied sid-lane1 'gh pr merge 12' "$REPO"
  bash_denied sid-lane1 'git push origin main' "$REPO"
}

@test "git push to the default branch in every spelling is refused" {
  make_repo
  for cmd in 'git push' 'git push origin' 'git push origin main' 'git push origin +main' 'git push origin HEAD:main' \
    'git push origin HEAD:refs/heads/main' 'git push origin feature:main' 'git push origin :main' 'git push --all' \
    'git push --mirror origin' 'git push -u origin main' 'git -C /tmp/x push origin main' 'git push origin HEAD'; do
    bash_denied sid-lane1 "$cmd" "$REPO" || return 1
  done
}

@test "a lane may push one named non-default branch to a named remote" {
  make_repo
  for cmd in 'git push origin feature/x' 'git push -u origin my-branch' 'git push --set-upstream origin lane1' \
    'git push --force-with-lease origin lane1' 'git push --force-with-lease=lane1:abc123 origin lane1' \
    'git push origin lane1:lane1' 'git push origin refs/heads/lane1' 'git push origin lane1:refs/heads/lane1' \
    'git push -u --force-with-lease origin lane1'; do
    bash_untouched sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "git -C with an explicit refspec passes, and its default branch comes from the named checkout" {
  make_repo
  bash_untouched sid-lane1 'git -C ../wt-lane1 push origin my-branch' "$REPO"
  bash_untouched sid-lane1 "git -C $WT push origin lane1" "$PROJECT"
  bash_denied sid-lane1 "git -C $WT push origin main" "$PROJECT"
  add_remote upstream develop
  bash_denied sid-lane1 "git -C $REPO push upstream develop" "$PROJECT"
}

@test "every git push form that depends on the checkout, config or a pattern is refused from a lane" {
  make_repo
  for cmd in 'git push' 'git push origin' 'git push origin HEAD' 'git push origin @' 'git push origin head' \
    'git push origin HEAD:lane1' 'git push origin ORIG_HEAD' 'git push origin +lane1' 'git push origin :lane1' \
    'git push origin lane1:other' 'git push origin refs/tags/v1' 'git push origin refs/heads/main' 'git push origin main:main' \
    'git push origin lane1 other' 'git push --all origin' 'git push --mirror origin' 'git push --tags origin' \
    'git push origin --delete lane1' 'git push -d origin lane1' 'git push --repo=origin lane1' 'git push -f origin lane1' \
    'git push origin "$BRANCH"' 'git push origin {lane1,main}' "git push origin 'feat*'" 'git push origin feat?' \
    'git push origin lane1~1:lane1' 'git push "$REMOTE" lane1' 'git push o* lane1' 'git -c push.default=matching push origin lane1' \
    'git --git-dir=.git push origin lane1' 'git -C"$X" push origin lane1' 'git -C "$X" push origin lane1' \
    'echo lane1 | xargs git push origin' 'echo main | xargs git push origin lane1' 'git push -- origin lane1' 'git push -uf origin lane1'; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "a refused git push names the explicit form as the allowed path" {
  make_repo
  run_guard lead-only "$(bash_input sid-lane1 'git push' "$WT")"
  assert_denied "push explicitly: git push <remote> <your-branch>"
}

@test "git -C another checkout with no refspec is refused, whatever the hook directory's branch" {
  make_repo
  bash_denied sid-lane1 "git -C $REPO push origin HEAD" "$WT"
  bash_denied sid-lane1 "git -C $REPO push" "$WT"
}

@test "a glob or matching refspec is refused" {
  make_repo
  for cmd in "git push origin 'refs/heads/*:refs/heads/*'" "git push origin '+refs/heads/*:refs/heads/*'" 'git push origin :' \
    'git push origin +:' "git push origin 'lane*:lane*'"; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "git maps a plain-name push through push.default=upstream and remote.<r>.push, which the guard relies on" {
  make_repo
  bare="$LANES_TEST_TMP/origin.git"
  git init -q --bare "$bare"
  git -C "$REPO" push -q origin main
  git -C "$WT" fetch -q origin
  git -C "$WT" branch -q --set-upstream-to=origin/main lane1
  git -C "$WT" commit -q --allow-empty -m one
  git -C "$WT" -c push.default=upstream push -q origin lane1
  [ "$(git -C "$bare" rev-parse main)" = "$(git -C "$WT" rev-parse lane1)" ]
  git -C "$WT" commit -q --allow-empty -m two
  git -C "$WT" -c remote.origin.push=refs/heads/lane1:refs/heads/main push -q origin lane1
  [ "$(git -C "$bare" rev-parse main)" = "$(git -C "$WT" rev-parse lane1)" ]
}

@test "a plain-name push passes only when config cannot map it, and the same-name form passes anyway" {
  make_repo
  bash_untouched sid-lane1 'git push -u origin lane1' "$WT"
  git -C "$REPO" config remote.origin.push refs/heads/lane1:refs/heads/main
  run_guard lead-only "$(bash_input sid-lane1 'git push origin lane1' "$WT")"
  assert_denied "push explicitly: git push <remote> <name>:<name>"
  bash_denied sid-lane1 "git -C $WT push origin lane1" "$PROJECT"
  bash_untouched sid-lane1 'git push origin lane1:lane1' "$WT"
  git -C "$REPO" config --unset remote.origin.push
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$WT" branch -q --set-upstream-to=origin/main lane1
  for pd in upstream tracking; do
    git -C "$REPO" config push.default "$pd"
    bash_denied sid-lane1 'git push -u origin lane1' "$WT" || return 1
    bash_untouched sid-lane1 'git push -u origin lane1:lane1' "$WT" || return 1
  done
  git -C "$REPO" config push.default simple
  bash_untouched sid-lane1 'git push -u origin lane1' "$WT"
}

@test "a symref branch is refused in the plain form, and in the same-name form when it points at the default branch" {
  make_repo
  git -C "$REPO" symbolic-ref refs/heads/alias refs/heads/main
  git -C "$REPO" symbolic-ref refs/heads/alias2 refs/heads/lane1
  bash_denied sid-lane1 'git push origin alias' "$WT"
  bash_denied sid-lane1 'git push origin alias:alias' "$WT"
  bash_denied sid-lane1 'git push origin alias2' "$WT"
  bash_untouched sid-lane1 'git push origin alias2:alias2' "$WT"
}

@test "a git config environment prefix refuses the plain form" {
  make_repo
  for cmd in 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=push.default GIT_CONFIG_VALUE_0=upstream git push origin lane1' \
    'env GIT_CONFIG_PARAMETERS="x" git push origin lane1' 'GIT_CONFIG_GLOBAL=/tmp/g git push origin lane1' \
    'GIT_CONFIG_SYSTEM=/tmp/s git push -u origin lane1' 'GIT_CONFIG_KEY_3=x git push origin lane1' \
    'HOME=/tmp/h git push origin lane1' 'XDG_CONFIG_HOME=/tmp/x git push origin lane1'; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
  bash_untouched sid-lane1 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=push.default GIT_CONFIG_VALUE_0=upstream git push origin lane1:lane1' "$WT"
  bash_untouched sid-lane1 'FOO=1 git push origin lane1' "$WT"
  bash_untouched sid-lane1 'HOME=/tmp/h git push origin lane1:lane1' "$WT"
  bash_denied sid-lane1 'export HOME=/tmp/h; git push origin lane1:lane1' "$WT"
}

@test "a global config under another HOME maps a plain-name push, which is why a HOME prefix refuses it" {
  make_repo
  bare="$LANES_TEST_TMP/origin.git"
  git init -q --bare "$bare"
  git -C "$REPO" push -q origin main
  git -C "$WT" fetch -q origin
  git -C "$WT" branch -q --set-upstream-to=origin/main lane1
  git -C "$WT" commit -q --allow-empty -m one
  mkdir "$LANES_TEST_TMP/h"
  git config --file "$LANES_TEST_TMP/h/.gitconfig" push.default upstream
  HOME="$LANES_TEST_TMP/h" git -C "$WT" push -q origin lane1
  [ "$(git -C "$bare" rev-parse main)" = "$(git -C "$WT" rev-parse lane1)" ]
}

@test "a push with no refspec is refused whatever remote.<r>.push or push.default says" {
  make_repo
  git -C "$WT" config remote.origin.push HEAD:main
  bash_denied sid-lane1 'git push origin' "$WT"
  git -C "$WT" config --unset remote.origin.push
  git -C "$WT" config push.default matching
  bash_denied sid-lane1 'git push origin' "$WT"
  bash_denied sid-lane1 'git push' "$WT"
}

@test "the lead may run every git push form" {
  make_repo
  for cmd in 'git push' 'git push origin main' 'git push --all origin' "git push origin 'refs/heads/*:refs/heads/*'" \
    "git -C $REPO push origin HEAD" 'git push origin :' 'git push origin +main' 'git push --mirror origin'; do
    bash_untouched sid-lead "$cmd" "$WT" || return 1
  done
}

@test "a lead-only list without git push @default leaves every push to the lane" {
  make_repo
  write_guards "$PROJECT" 'lead_only_commands: gh pr merge'
  bash_untouched sid-lane1 'git push origin main' "$WT"
  bash_untouched sid-lane1 'git push --all' "$WT"
}

@test "the default branch comes from the origin remote head when it is set" {
  make_repo
  git -C "$REPO" update-ref refs/remotes/origin/develop HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  bash_denied sid-lane1 'git push origin develop' "$REPO"
  bash_untouched sid-lane1 'git push origin main' "$REPO"
}

@test "a push is checked against the head of the remote it names" {
  make_repo
  add_remote upstream release
  for cmd in 'git push upstream release:release' 'git push upstream release' 'git push -u upstream release' \
    'git push upstream refs/heads/release'; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
  bash_untouched sid-lane1 'git push upstream lane1:lane1' "$WT"
  bash_untouched sid-lane1 'git push origin release:release' "$WT"
  bash_untouched sid-lane1 'git push upstream main:main' "$WT"
}

@test "a push to a remote whose head is unknown is refused, unless default_branch names the default" {
  make_repo
  add_remote fork
  run_guard lead-only "$(bash_input sid-lane1 'git push fork lane1:lane1' "$WT")"
  assert_denied "git remote set-head fork --auto"
  write_guards "$PROJECT" 'default_branch: main'
  bash_untouched sid-lane1 'git push fork lane1:lane1' "$WT"
  bash_denied sid-lane1 'git push fork main:main' "$WT"
}

@test "default_branch adds to the remote head rather than replacing it" {
  make_repo
  write_guards "$PROJECT" 'default_branch: trunk'
  bash_denied sid-lane1 'git push origin trunk:trunk' "$WT"
  bash_denied sid-lane1 'git push origin main:main' "$WT"
  bash_untouched sid-lane1 'git push origin lane1:lane1' "$WT"
}

@test "a push to a URL, a path or a name that is not a configured remote is refused" {
  make_repo
  for cmd in 'git push git@example.com:o/r.git lane1' 'git push https://example.com/o/r.git lane1:lane1' \
    'git push ../r.git lane1' 'git push . lane1:lane1' 'git push nosuch lane1:lane1'; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
  run_guard lead-only "$(bash_input sid-lane1 'git push nosuch lane1:lane1' "$WT")"
  assert_denied "a remote configured in the checkout"
}

@test "a push after cd is checked in the directory it changed to" {
  make_repo
  other="$LANES_TEST_TMP/other"
  git init -q -b lane1 "$other"
  git -C "$other" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m x
  add_remote origin lane1 "$other"
  bash_untouched sid-lane1 'git push origin lane1:lane1' "$WT"
  for cmd in "cd $other && git push origin lane1:lane1" "pushd $other >/dev/null; git push origin lane1:lane1" \
    "cd -P $other && git push origin lane1:lane1" "cd $LANES_TEST_TMP && cd other && git push origin lane1:lane1"; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
  bash_untouched sid-lane1 "cd $WT && git push origin lane1:lane1" "$PROJECT"
  bash_untouched sid-lane1 "cd $LANES_TEST_TMP && git -C wt-lane1 push origin lane1:lane1" "$PROJECT"
}

@test "a push whose checkout the guard cannot resolve is refused" {
  make_repo
  for cmd in 'cd "$D" && git push origin lane1:lane1' 'cd && git push origin lane1:lane1' \
    'cd - && git push origin lane1:lane1' 'cd ~/x && git push origin lane1:lane1' 'popd; git push origin lane1:lane1' \
    'GIT_DIR=/x/.git git push origin lane1:lane1' 'GIT_COMMON_DIR=/x git push origin lane1:lane1' \
    'env -C /x git push origin lane1:lane1' 'env --chdir=/x git push origin lane1:lane1' \
    'sudo -D /x git push origin lane1:lane1' 'export GIT_DIR=/x/.git; git push origin lane1:lane1'; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
  run_guard lead-only "$(bash_input sid-lane1 'cd "$D" && git push origin lane1:lane1' "$WT")"
  assert_denied "git -C <your-worktree> push"
  bash_untouched sid-lane1 'GIT_TERMINAL_PROMPT=0 git push origin lane1:lane1' "$WT"
}

# other_checkout: a second repository at $LANES_TEST_TMP/other whose origin head is lane1, so lane1 is its default.
other_checkout() {
  OTHER="$LANES_TEST_TMP/other"
  git init -q -b lane1 "$OTHER"
  git -C "$OTHER" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m x
  add_remote origin lane1 "$OTHER"
}

@test "a directory change the guard cannot order before a push refuses the push, wherever it sits on the line" {
  make_repo
  other_checkout
  # Run from WT, where lane1 is not the default: each line changes to OTHER, where it is, before the push runs.
  for cmd in "eval 'cd $OTHER' && git push origin lane1:lane1" "eval \"cd $OTHER\"; git push origin lane1:lane1" \
    "env -C $OTHER bash -c 'git push origin lane1:lane1'" "env --chdir $OTHER sh -c 'git push origin lane1:lane1'" \
    "sudo -D$OTHER git push origin lane1:lane1" "GIT_DIR=$OTHER/.git bash -c 'git push origin lane1:lane1'" \
    "true && cd $OTHER && git push origin lane1:lane1" "builtin cd $OTHER; git push origin lane1:lane1" \
    "\$CD $OTHER; git push origin lane1:lane1"; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
  # Run from OTHER: the directory change happens in a child shell, a subshell, a pipeline or after the push.
  for cmd in "bash -c 'git push origin lane1:lane1'; cd $WT" "eval 'git push origin lane1:lane1'; cd $WT" \
    "(cd $WT); git push origin lane1:lane1" "cd $WT | cat; git push origin lane1:lane1" \
    "cd $WT & git push origin lane1:lane1" "bash -c 'cd $WT'; git push origin lane1:lane1"; do
    bash_denied sid-lane1 "$cmd" "$OTHER" || return 1
  done
  run_guard lead-only "$(bash_input sid-lane1 "eval 'cd $OTHER' && git push origin lane1:lane1" "$WT")"
  assert_denied "git -C <your-worktree> push"
}

@test "a leading cd to a literal absolute path joined by && sets the checkout for the whole line" {
  make_repo
  other_checkout
  bash_untouched sid-lane1 "cd $WT && git push origin lane1:lane1" "$OTHER"
  bash_untouched sid-lane1 "cd -P $WT && git add -A && git commit -qm 'push it' && git push origin lane1:lane1" "$OTHER"
  bash_denied sid-lane1 "cd $OTHER && git push origin lane1:lane1" "$WT"
  # A failed cd before ";" leaves the push in the session directory; a relative path may resolve through CDPATH.
  bash_denied sid-lane1 "cd $WT; git push origin lane1:lane1" "$OTHER"
  bash_denied sid-lane1 "cd wt-lane1 && git push origin lane1:lane1" "$LANES_TEST_TMP"
  # The shell resolves ".." against the link's own path, git -C against its target: here OTHER for the shell, WT for git.
  mkdir "$WT/sub"
  ln -s "$WT/sub" "$OTHER/lnk"
  bash_denied sid-lane1 "cd $OTHER/lnk/.. && git push origin lane1:lane1" "$WT"
}

@test "a git config prefix on a wrapper or shell still refuses the plain form inside it" {
  make_repo
  for cmd in "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=push.default GIT_CONFIG_VALUE_0=upstream bash -c 'git push origin lane1'" \
    "GIT_CONFIG_GLOBAL=/tmp/g eval 'git push origin lane1'" "GIT_CONFIG_PARAMETERS=x env -S 'git push origin lane1'"; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
}

# Every way a review round found to hide a lead-only command, one per line. A new one is a one-line addition.
HIDING_FORMS=(
  # separators and grouping
  'echo ok && gh pr merge 12' 'echo ok; gh pr merge 12' 'false || gh pr merge 12' 'echo ok | gh pr merge 12'
  'sleep 1 & gh pr merge 12' $'echo ok\ngh pr merge 12' '(gh pr merge 12)' '{ gh pr merge 12; }'
  'if true; then gh pr merge 12; fi' 'while true; do gh pr merge 12; done' 'true;gh pr merge 12' 'echo a|&gh pr merge 12'
  'gh pr merge 12 >/dev/null 2>&1' '>/dev/null gh pr merge 12' 'gh pr merge 12 # a comment'
  # substitutions
  'echo $(gh pr merge 12)' 'echo `gh pr merge 12`' 'echo "$(gh pr merge 12)"' 'diff <(gh pr merge 12) /dev/null'
  'git commit -m "$(gh pr merge 12)"' 'source <(echo gh pr merge 12)' 'git commit -m "$(echo gh pr merge > f)"'
  $'echo "$(cat <<EOF | sh\ngh pr merge 12\nEOF\n)"'
  # env prefixes and wrappers
  'GH_TOKEN=x gh pr merge 12' 'A=1 B=2 gh workflow run ci.yml' 'env GH_TOKEN=x gh pr merge 12' 'env -i gh pr merge 12'
  'env -u HOME gh pr merge 12' 'sudo -u bob gh pr merge 12' 'command gh pr merge 12' 'nohup gh pr merge 12'
  'timeout 30 gh pr merge 12' 'timeout -s KILL 30 gh pr merge 12' 'time gh pr merge 12' 'exec gh pr merge 12'
  'nice -n 5 gh pr merge 12' '/usr/bin/gh pr merge 12'
  'echo 12 | xargs gh pr merge' 'echo 12 | xargs -n1 gh pr merge' 'echo "pr merge 12" | xargs gh' 'xargs -0n1 gh pr merge </dev/null'
  # wrapper options the parser read wrongly
  "env -S'gh pr merge 12'" "env --split-string='gh pr merge 12'" "env -iS 'gh pr merge 12'" "env --split 'gh pr merge 12'"
  'env -iu HOME gh pr merge 12' 'sudo -Eu root gh pr merge 12' "env -vS'bash -c \"gh pr merge 12\"'"
  "env -S 'gh pr' merge 12" 'env -Sgh\ pr\ merge\ 12'
  # shells, eval and functions
  "bash -c 'gh pr merge 12'" 'sh -c "gh pr merge 12"' "bash -lc 'gh pr merge 12'" "zsh -ec 'gh pr merge 12'"
  "bash -c \"bash -c 'gh pr merge 12'\"" 'eval "gh pr merge 12"' "bash -o pipefail -c 'gh pr merge 12'"
  "FOO=1 bash -c 'FOO=2 gh pr merge 12'" "bash -c 'echo ok; gh pr merge 12'" "sh -c 'sh -c \"sh -c \\\"gh pr merge 12\\\"\"'"
  'echo() { eval "$*"; }; echo gh pr merge 12' 'function echo { eval "$*"; }; echo gh pr merge 12' 'f () { gh "$@"; }; f pr merge 1'
  # scripts on stdin
  $'bash <<\'EOF\'\ngh pr merge 3\nEOF' $'bash -s <<EOF\ngh pr merge 3\nEOF' "echo 'gh pr merge 3' | sh" "bash <<< 'gh pr merge 3'"
  $'sh <<-EOF\n\tgh workflow run ci.yml\n\tEOF' "printf 'gh pr merge %s' 3 | bash" $'cat <<\'EOF\' | bash\ngh pr merge 3\nEOF'
  "echo ok; echo 'true' | zsh -s; echo 'gh pr merge 3' | dash" "printf '%s' 'gh pr merge 12' | sh" "echo -n 'gh pr merge 12' | sh"
  "/bin/echo 'gh pr merge 12' | bash" "printf 'gh pr merge 12' | tr a a | bash" 'echo "$(echo gh pr merge 12)" | sh'
  $'sed s/x//g <<\'EOF\' | bash\ngh pr merge 12\nEOF' "printf 'gh pr merge 12' | bash /dev/stdin" "printf 'gh pr merge 12' | source /dev/stdin"
  "printf 'gh pr merge 12' | . /dev/fd/0" 'bash <<< "$(printf gh\ pr\ merge\ 12)"' $'bash <<EOF\n$(printf \'gh pr merge 12\')\nEOF'
  "printf '%s\\n' 'git push origin feature/x' | sh" "echo 'true\\ngh pr merge 12' | sh" "printf 'true\\ngh pr merge 12' | sh"
  $'echo \'true\ngh pr merge 12\' | sh' '{ echo gh pr; echo merge; } | sh' 'echo gh pr merge 12 > run.sh'
  # heredocs
  $'cat <<EOF\n$(gh pr merge 12)\nEOF' $'cat <<-EOF\n\t`gh pr merge 12`\n\tEOF' $'cat <<\'EOF\'\nnotes\nEOF\ngh pr merge 12'
  # variables
  "x='gh pr'; \$x merge 12" 'X="pr merge"; gh $X 12' "printf -v c 'gh pr merge 12'; \$c"
  '$GH pr merge 12' '"$GH" workflow run ci.yml' '${GH} pr merge 12' '$(which gh) pr merge 12'
  # quoting, escapes, case and global flags
  '"gh" pr merge 12' "'gh' 'pr' 'merge' 12" 'g\h pr merge 12' 'gh "pr" merge 12' $'gh \\\n pr merge 12' $'gh pr \\\nmerge 12'
  'gh -R owner/repo pr merge 12' 'gh --repo owner/repo pr merge 12' 'gh pr merge 12 --squash' 'gh pr --repo o/r merge 12'
  'gh   pr   merge' $'gh\tpr\tmerge 12' 'g""h pr merge 12' 'GH pr merge 12'
  "gh \$'pr' merge 12" "\$'gh' pr merge 12" "gh \$'p\\x72' \$'\\155erge' 12" "gh pr \$'merge' 12" 'gh $"pr" merge 12'
  "bash -c \$'gh pr merge 12'"
  # data whose escapes count twice in the parsed word, to cancel the live words out of the pool
  'echo g\h g\h p\r p\r m\erge m\erge; gh pr merge 12'
  # data commands that run something
  "rg --pre 'gh pr merge 1' x ." 'gh pr create --title x && gh pr merge 1' $'cat - ./gh-pr-merge.sh <<\'EOF\' | bash\necho hi\nEOF'
)

@test "every known hiding form is refused" {
  for cmd in "${HIDING_FORMS[@]}"; do
    bash_denied sid-lane1 "$cmd" || return 1
  done
}

@test "a mention inside data, or in a command that only names a lead-only one, passes" {
  for cmd in 'echo hello' 'echo gh pr merge' 'echo gh pr merge 12' 'gh pr view' 'gh pr view 12' 'gh pr list --state merged' \
    'gh workflow list' 'gh run list' 'gh --version' 'git commit -m "merge gh docs"' 'git commit -m "gh pr merge is lead-only"' \
    'git commit -am "docs: explain git push rules"' 'gh pr create --title "workflow run fix"' 'gh issue create --title "gh pr merge"' \
    'echo "run: gh workflow run ci.yml"' 'grep -r "pr merge" .' "grep -rn 'gh pr merge' docs/" "rg -n 'gh workflow run' ." \
    'cat README.md | grep "gh pr merge"' 'git log --oneline | grep push' 'git status && git log -1' 'command -v gh' \
    'cat docs/gh-pr-merge.md' 'ls ./gh' 'gh pr checkout 12' 'gh run list --workflow ci.yml' 'echo gh pr merge # a note' \
    $'cat <<\'EOF\'\ngh pr merge 12\nEOF' $'cat <<EOF\nplain text: gh pr merge 12\nEOF' 'echo "unterminated' \
    $'git commit -m "$(cat <<\'EOF\'\nnotes: gh workflow run\nEOF\n)"' \
    $'gh pr create --title t --body "$(cat <<\'EOF\'\nsteps: gh workflow run ci.yml\nEOF\n)"'; do
    bash_untouched sid-lane1 "$cmd" || return 1
  done
}

@test "a lane push passes beside data that names git push" {
  make_repo
  for cmd in 'git push -u origin feat' 'git add -A && git commit -m "x" && git push origin lane1' \
    $'git commit -m "$(cat <<\'EOF\'\nPush the fix to git\nEOF\n)" && git push -u origin lane1' \
    'git status && git push origin lane1' 'npm run build && git push origin lane1'; do
    bash_untouched sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "a normal command the parse cannot prove harmless is refused when its text names a lead-only command" {
  make_repo
  for cmd in 'gh pr view 5 && git merge origin/main' "echo 'gh pr merge 3' | cat" 'gh workflow view ci.yml && gh run view 12' \
    'timeout 60 git push origin lane1' "bash -c 'git push origin lane1'" "echo 'git push origin feature/x' | sh"; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "guards.md replaces the default patterns" {
  write_guards "$PROJECT" $'# Guards\n\nlead_only_commands: terraform apply; kubectl delete'
  bash_denied sid-lane1 'terraform apply -auto-approve'
  bash_denied sid-lane1 'kubectl delete pod x'
  bash_untouched sid-lane1 'gh pr merge 12'
  bash_untouched sid-lane1 'terraform plan'
  bash_untouched sid-lead 'terraform apply'
}

@test "a userConfig value sets the patterns, and guards.md wins over it" {
  export CLAUDE_PLUGIN_OPTION_LEAD_ONLY_COMMANDS='make release'
  bash_denied sid-lane1 'make release'
  bash_untouched sid-lane1 'gh pr merge 12'
  write_guards "$PROJECT" 'lead_only_commands: npm publish'
  bash_denied sid-lane1 'npm publish'
  bash_untouched sid-lane1 'make release'
}

@test "guards.md is found by walking up from the session's directory when there is no project dir" {
  unset CLAUDE_PROJECT_DIR
  write_guards "$PROJECT" 'lead_only_commands: make release'
  mkdir -p "$PROJECT/sub/deeper"
  bash_denied sid-lane1 'make release' "$PROJECT/sub/deeper"
}

@test "default_branch in guards.md sets which push is refused" {
  make_repo
  write_guards "$REPO" 'default_branch: trunk'
  export CLAUDE_PROJECT_DIR="$REPO"
  bash_denied sid-lane1 'git push origin trunk' "$REPO"
  bash_untouched sid-lane1 'git push origin feature/x' "$REPO"
}

@test "a pattern with a push-to-default token works with an extra pattern beside it" {
  make_repo
  write_guards "$REPO" 'lead_only_commands: git push @default; make release'
  export CLAUDE_PROJECT_DIR="$REPO"
  bash_denied sid-lane1 'git push origin main' "$REPO"
  bash_denied sid-lane1 'make release' "$REPO"
  bash_untouched sid-lane1 'gh pr merge 1' "$REPO"
}

@test "malformed stdin fails open with a stderr note" {
  for bad in '' 'not json' '{"tool_name":' '[1,2]' '"hello"'; do
    run --separate-stderr "$GUARD" lead-only <<<"$bad"
    assert_untouched || { echo "stdin: $bad"; return 1; }
    [[ "$stderr" == *"lanes-guard:"* ]] || { echo "no note for: $bad"; return 1; }
  done
}

@test "malformed stdin that names a matching command is still refused" {
  run_guard lead-only '{"session_id":"sid-lead","tool_input":{"command":"gh pr merge 12"'
  assert_denied "lead-only"
  [[ "$stderr" == *"lanes-guard:"* ]]
}

@test "stdin without a command, or for another tool, is not this guard's concern" {
  run_guard lead-only '{"session_id":"s","tool_name":"Bash","tool_input":{}}'
  assert_untouched
  run_guard lead-only '{"session_id":"s","tool_name":"Read","tool_input":{"file_path":"/x"}}'
  assert_untouched
}

@test "an unknown guard name or none is a usage error" {
  run --separate-stderr "$GUARD" nonsense <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage"* ]]
  run --separate-stderr "$GUARD" <<<'{}'
  [ "$status" -eq 2 ]
}

@test "the hooks file wires each guard by absolute plugin path and the right tool matcher" {
  hooks="$BATS_TEST_DIRNAME/../../plugins/lanes-guards/hooks/hooks.json"
  jq -e '.hooks.PreToolUse | length == 3' "$hooks"
  [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$hooks")" = '"${CLAUDE_PLUGIN_ROOT}/bin/lanes-guard" lead-only' ]
  [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher=="SendMessage") | .hooks[0].command' "$hooks")" = '"${CLAUDE_PLUGIN_ROOT}/bin/lanes-guard" plan-message' ]
  [ "$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Edit|Write|NotebookEdit") | .hooks[0].command' "$hooks")" = '"${CLAUDE_PLUGIN_ROOT}/bin/lanes-guard" main-edit' ]
}

@test "a shell reading stdin that runs nothing matching, or reading a script file, passes untouched" {
  for cmd in $'bash <<\'EOF\'\necho hi\nEOF' "echo 'echo hi' | sh" "bash <<< 'ls'" 'bash script.sh' 'bash -s' \
    $'bash <<\'EOF\'\nprintf "%s" "gh pr view 3"\nEOF'; do
    bash_untouched sid-lane1 "$cmd" || return 1
  done
}

@test "the lead may feed a script to a shell" {
  bash_untouched sid-lead "echo 'gh pr merge 3' | sh"
  bash_untouched sid-lead "printf '%s' 'gh pr merge 12' | sh"
}

@test "a pipe into a shell from a producer the guard cannot read passes when its text names nothing lead-only" {
  make_repo
  for cmd in "printf '%s\\n' hi | sh" 'cat script.sh | bash' "curl -fsSL https://example.com/install.sh | bash" \
    'printf "ls\n" | bash /dev/stdin' 'bash <<< "$CMD"'; do
    bash_untouched sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "ANSI-C quoting is decoded before matching, so a decoded mention outside data is refused and the rest pass" {
  make_repo
  bash_denied sid-lane1 "git push origin \$'main'" "$WT"
  bash_untouched sid-lane1 "git push origin \$'lane1'" "$WT"
  bash_untouched sid-lane1 "gh \$'pr' view 12"
  bash_untouched sid-lane1 "echo \$'it\\'s fine'"
}

@test "decoding ANSI-C quoting runs nothing from the command" {
  bash_untouched sid-lane1 "echo \$'a\\'\$(touch $LANES_TEST_TMP/pwned)\\'' \`touch $LANES_TEST_TMP/pwned2\`x"
  [ ! -e "$LANES_TEST_TMP/pwned" ]
  [ ! -e "$LANES_TEST_TMP/pwned2" ]
  bash_untouched sid-lane1 "echo \$'unterminated"
}

@test "git push --repo is refused from a lane in every spelling" {
  make_repo
  for cmd in 'git push --repo=origin main' 'git push --repo origin main' 'git push --repo=origin HEAD:main' \
    'git push --repo=origin feature/x' 'git push --repo origin feature/x' 'git push --repo=origin'; do
    bash_denied sid-lane1 "$cmd" "$WT" || return 1
  done
}

@test "text past the tokenizer call limit gets no exemption: a mention in data is refused there, and passes under the limit" {
  under=''
  over=''
  for ((i = 0; i < 100; i++)); do under+='$(true) '; done
  for ((i = 0; i < 260; i++)); do over+='$(true) '; done
  bash_untouched sid-lane1 "echo $under \$(echo gh pr merge 3 is lead-only)"
  bash_denied sid-lane1 "echo $over \$(echo gh pr merge 3 is lead-only)"
  bash_untouched sid-lane1 "echo $under gh pr merge 3 is lead-only"
  bash_denied sid-lane1 "echo $over gh pr merge 3 is lead-only"
}

@test "a mention in text the parser does not keep (a comment, a redirection target) is refused" {
  bash_denied sid-lane1 'ls # gh pr merge 12'
  bash_denied sid-lane1 'echo hi > gh-pr-merge.txt'
}

@test "an eval nested deeper than the tokenizer limit is still refused" {
  cmd='gh pr merge 3'
  for ((i = 0; i < 230; i++)); do cmd="eval $cmd"; done
  bash_denied sid-lane1 "$cmd"
}

@test "without jq, a call that names a lead-only command exits 2 with a message, and any other call passes with a note" {
  nojq="$LANES_TEST_TMP/nojq"
  mkdir -p "$nojq"
  for t in bash cat sed tr grep tail dirname basename git; do ln -s "$(command -v "$t")" "$nojq/$t"; done
  run --separate-stderr env PATH="$nojq" "$GUARD" lead-only <<<'{"tool_name":"Bash","tool_input":{"command":"gh pr merge 3"}}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"jq"* ]]
  [[ "$stderr" == *"gh pr merge"* ]]
  run --separate-stderr env PATH="$nojq" "$GUARD" lead-only <<<'{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  assert_untouched
  [[ "$stderr" == *"jq"* ]]
  run --separate-stderr env PATH="$nojq" "$GUARD" plan-message <<<'{"tool_name":"SendMessage","tool_input":{"message":"PLAN: x"}}'
  assert_untouched
  [[ "$stderr" == *"jq"* ]]
}

@test "plugin.json defines a userConfig option for every key the guards.md template lists" {
  p="$BATS_TEST_DIRNAME/../../plugins/lanes-guards"
  keys="$(sed -n '/^```$/,/^```$/p' "$p/templates/guards.md" | sed -n 's/^\([a-z_]*\):.*/\1/p')"
  [ -n "$keys" ]
  for k in $keys; do
    jq -e --arg k "$k" '.userConfig[$k].type' "$p/.claude-plugin/plugin.json" >/dev/null || { echo "no userConfig for $k"; return 1; }
  done
}

@test "main_checkout_guard, lead_exempt_main_checkout and default_branch also come from userConfig" {
  make_repo
  export CLAUDE_PROJECT_DIR="$WT"
  export CLAUDE_PLUGIN_OPTION_MAIN_CHECKOUT_GUARD=true
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/README.md" "$WT")"
  assert_denied "main-edit"
  export CLAUDE_PLUGIN_OPTION_MAIN_CHECKOUT_GUARD=false
  run_guard main-edit "$(file_input Edit sid-lane1 "$REPO/README.md" "$WT")"
  assert_untouched
  unset CLAUDE_PLUGIN_OPTION_MAIN_CHECKOUT_GUARD
  export CLAUDE_PLUGIN_OPTION_DEFAULT_BRANCH=trunk
  bash_denied sid-lane1 'git push origin trunk' "$REPO"
  bash_untouched sid-lane1 'git push origin feature/x' "$REPO"
}
