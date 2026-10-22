#!/usr/bin/env bats
# Public seam: `lanes register` with source "clear". Its stdout is the one JSON object Claude Code reads; the RESUME
# block and goal ride in additionalContext, always under the 10,000-character hook cap.

load helper

clear_output() {
  hook_json SessionStart s2 alpha clear | TMUX_PANE=%7 "$LANES" register 2>/dev/null
}

clear_context() { clear_output | jq -r .hookSpecificOutput.additionalContext; }

@test "session_start_clear_output_is_valid_json_under_cap: the shape is hookSpecificOutput.additionalContext" {
  make_repo
  write_resume alpha "ship A1" "run the A1 tests"
  register_lane alpha s1 %7 >/dev/null
  run clear_output
  assert_success
  run jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | type == "string")' <<<"$output"
  assert_success
  ctx="$(clear_output | jq -r .hookSpecificOutput.additionalContext)"
  [[ "$ctx" == *"### Next step"* ]]
  [[ "$ctx" == *"run the A1 tests"* ]]
  [[ "$ctx" == *$'### Goal\nship A1'* ]]
  [[ "$ctx" == *"you are lane \"alpha\""* ]]
}

@test "a RESUME block at the cap still yields context under 10,000 characters" {
  make_repo
  filler="$(printf 'y%.0s' $(seq 1 7700))"
  write_resume alpha "ship A1" "$filler"
  register_lane alpha s1 %7 >/dev/null
  n="$(clear_output | jq -r '.hookSpecificOutput.additionalContext | length')"
  [ "$n" -lt 10000 ]
}

@test "an over-cap block is not injected; the lane is told to read the file" {
  make_repo
  write_resume alpha "ship A1" "$(printf 'y%.0s' $(seq 1 9000))"
  register_lane alpha s1 %7 >/dev/null
  run clear_context
  assert_output --partial "over the 8000 cap"
  [ "${#output}" -lt 2000 ]
}

@test "hook_missing_resume_file_emits_notice_not_error" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  run clear_output
  assert_success
  run jq -r .hookSpecificOutput.additionalContext <<<"$output"
  assert_output --partial "No RESUME block was found"
  assert_output --partial "Ask the lead"
}

@test "nothing but the JSON object reaches stdout, even with notices" {
  make_repo
  write_resume alpha
  register_lane alpha s1 "" >/dev/null 2>&1
  out="$(hook_json SessionStart s2 alpha clear | TMUX_PANE= "$LANES" register 2>/dev/null)"
  run jq -e 'has("systemMessage") and has("hookSpecificOutput")' <<<"$out"
  assert_success
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]
}

@test "a journal_dir recorded from the plugin option is where RESUME is read" {
  make_repo
  mkdir -p "$WORK/journal"
  write_resume alpha "ship A1"
  git -C "$WORK" mv .lanes/next-alpha.md journal/next-alpha.md && git -C "$WORK" commit -qm mv
  hook_json SessionStart s1 alpha startup | TMUX_PANE=%7 CLAUDE_PLUGIN_OPTION_JOURNAL_DIR=journal "$LANES" register >/dev/null
  run clear_context
  assert_output --partial "$WORK/journal/next-alpha.md"
  assert_output --partial $'### Goal\nship A1'
}

@test "max block plus max goal: the Goal is not repeated and the context stays under 10,000 characters" {
  make_repo
  goal="$(printf 'g%.0s' $(seq 1 4000))"
  write_resume alpha "$goal" "$(printf 'y%.0s' $(seq 1 3700))"
  register_lane alpha s1 %7 >/dev/null
  ctx="$(clear_context)"
  [[ "$ctx" == *"### Next step"* ]]
  n="$(jq -Rs length <<<"$ctx")"
  [ "$n" -lt 10000 ]
  [ "$(grep -o "$goal" <<<"$ctx" | wc -l | tr -d ' ')" = 1 ]
}

@test "under LC_ALL=C a multibyte block of about 7,800 characters is injected, counted in characters, not bytes" {
  make_repo
  write_resume alpha "ship A1" "$(printf 'ሀ%.0s' $(seq 1 7600))"
  register_lane alpha s1 %7 >/dev/null
  ctx="$(hook_json SessionStart s2 alpha clear | LC_ALL=C TMUX_PANE=%7 "$LANES" register 2>/dev/null | jq -r .hookSpecificOutput.additionalContext)"
  [[ "$ctx" == *"### Next step"* ]]
  [ "$(jq -Rs length <<<"$ctx")" -lt 10000 ]
}

@test "a wrapper that would push the context over 10,000 characters falls back to the read-the-file notice" {
  seg="$(printf 'd%.0s' $(seq 1 200))"
  export LANES_JOURNAL_DIR="$LANES_TEST_TMP/$seg/$seg/$seg/$seg/$seg/$seg/$seg"
  make_repo
  mkdir -p "$LANES_JOURNAL_DIR"
  write_resume alpha "ship A1" "$(printf 'y%.0s' $(seq 1 7700))"
  cp "$WORK/.lanes/next-alpha.md" "$LANES_JOURNAL_DIR/"
  register_lane alpha s1 %7 >/dev/null
  ctx="$(clear_context)"
  [ "$(jq -Rs length <<<"$ctx")" -le 10000 ]
  [[ "$ctx" == *"Read that file now"* ]]
}
