#!/usr/bin/env bats
# Contract between the core skills and the code: every `lanes` subcommand a skill names exists, every RULES.md rule a
# skill cites exists, and the lead skill lists exactly the handshake states the code produces. Also `lanes journal-dir`.

load helper

P="$BATS_TEST_DIRNAME/../../plugins/lanes"

skill_files() { printf '%s\n' "$P"/skills/*/*.md; }

@test "every lanes subcommand named in the core skills is in the usage of bin/lanes" {
  usage="$("$LANES" 2>&1 || true)"
  usage="${usage#*usage: lanes }"
  usage="${usage%% *}"
  missing=""
  while IFS= read -r cmd; do
    [[ "|$usage|" == *"|$cmd|"* ]] || missing+=" $cmd"
  done < <(skill_files | xargs grep -ohE '`lanes [a-z][a-z-]*' | sed 's/^`lanes //' | sort -u)
  [ -z "$missing" ] || { echo "named in a skill but not in usage:$missing" >&2; false; }
}

@test "every RULES.md rule number a core skill cites exists" {
  have="$(grep -oE '^[0-9]+\.' "$P/templates/journal/RULES.md" | tr -d . | sort -n)"
  cited="$(skill_files | xargs grep -ohE 'rules? [0-9]+((, | and )[0-9]+)*' | grep -oE '[0-9]+' | sort -un)"
  [ -n "$cited" ]
  for n in $cited; do
    grep -qx "$n" <<<"$have" || { echo "rule $n is cited but RULES.md has no rule $n" >&2; false; }
  done
}

@test "the lead skill lists exactly the handshake states the code produces" {
  code="$( {
    grep -ohE '(\.state = |state: )"[a-z-]+"' "$P/bin/lanes" "$P/lib/"*.bash | grep -oE '"[a-z-]+"' | tr -d '"'
    grep -ohE '"request-timed-out"|state // "none"' "$P/bin/lanes" | grep -oE 'request-timed-out|none'
  } | sort -u)"
  skill="$(grep -E '^- \*\*handshake\*\*' "$P/skills/lead/SKILL.md" | grep -oE '`[a-z-]+`' | tr -d '`' | sort -u)"
  [ "$code" = "$skill" ] || { echo "code: $(echo $code) / skill: $(echo $skill)" >&2; false; }
}

@test "lanes init is gone: /lanes:setup does its work, so the command is a usage error and no shipped file names it" {
  run "$LANES" init
  assert_failure 2
  assert_output --partial "usage"
  run grep -rlF 'lanes init' "$P"
  assert_output ""
}

@test "the setup skill is user-invoked with a one-line human description" {
  run grep -cxF 'disable-model-invocation: true' "$P/skills/setup/SKILL.md"
  assert_output 1
  run grep -xE 'description: [^.]+\.' "$P/skills/setup/SKILL.md"
  assert_success
}

@test "lanes journal-dir: relative to the work tree's top level, an absolute override as is" {
  make_repo
  mkdir -p "$WORK/sub"
  run bash -c "cd '$WORK/sub' && '$LANES' journal-dir"
  assert_success
  assert_output "$WORK/.lanes"
  LANES_JOURNAL_DIR=/elsewhere/journal run "$LANES" journal-dir
  assert_output /elsewhere/journal
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=journal "$LANES" register >/dev/null
  run "$LANES" journal-dir
  assert_output "$WORK/journal"
}
