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
  goal="$(printf 'g%.0s' $(seq 1 1400))"
  write_resume alpha "$goal" "$(printf 'y%.0s' $(seq 1 6300))"
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
  # A journal path of 980 characters: the file path stays under macOS's PATH_MAX of 1024, and the path, which the
  # wrapper names twice, still pushes a block at the cap over the hook cap.
  local dir="$LANES_TEST_TMP" seg
  seg="$(printf 'd%.0s' $(seq 1 200))"
  while ((${#dir} + 201 < 980)); do dir+="/$seg"; done
  dir+="/${seg:0:$((980 - ${#dir} - 1))}"
  [ "${#dir}" -eq 980 ]
  export LANES_JOURNAL_DIR="$dir"
  make_repo
  mkdir -p "$LANES_JOURNAL_DIR"
  write_resume alpha "ship A1" "$(printf 'y%.0s' $(seq 1 7790))"
  cp "$WORK/.lanes/next-alpha.md" "$LANES_JOURNAL_DIR/"
  register_lane alpha s1 %7 >/dev/null
  ctx="$(clear_context)"
  [ "$(jq -Rs length <<<"$ctx")" -le 10000 ]
  [[ "$ctx" == *"Read that file now"* ]]
}

# moved_lane <state>: alpha's session started in $LANES_TEST_TMP/start (a worktree whose RESUME Goal is "start goal"),
# while its handshake record, in <state> for session s1, names $WORK (Goal "work goal") as the work tree it proved.
moved_lane() {
  make_repo
  write_resume alpha "work goal"
  git -C "$WORK" worktree add -q -b start "$LANES_TEST_TMP/start"
  (WORK="$LANES_TEST_TMP/start" && git -C "$WORK" push -q -u origin start && write_resume alpha "start goal")
  jq -nc --arg c "$LANES_TEST_TMP/start" --arg tp "$LANES_TEST_TMP/t.jsonl" \
    '{session_id:"s1",session_title:"alpha",cwd:$c,source:"startup",transcript_path:$tp}' | TMUX_PANE=%7 "$LANES" register >/dev/null
  local f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq -c --arg w "$WORK" --arg st "$1" '.handshake = {state: $st, session_id: "s1", worktree: $w}' "$f" >"$f.x" && mv "$f.x" "$f"
}
clear_from_start() {
  jq -nc --arg c "$LANES_TEST_TMP/start" '{session_id:"s2",session_title:"alpha",cwd:$c,source:"clear"}' |
    TMUX_PANE=%7 "$LANES" register 2>/dev/null | jq -r .hookSpecificOutput.additionalContext
}

@test "the /clear lanes typed (record sending) injects the RESUME of the work tree clear-ready proved" {
  moved_lane sending
  run clear_from_start
  assert_output --partial "$WORK/.lanes/next-alpha.md"
  assert_output --partial $'### Goal\nwork goal'
}

@test "a human /clear after a done handshake injects the RESUME of the session's own cwd, not the handshake's work tree" {
  moved_lane done
  run clear_from_start
  assert_output --partial "$LANES_TEST_TMP/start/.lanes/next-alpha.md"
  assert_output --partial $'### Goal\nstart goal'
  refute_output --partial "work goal"
}

@test "a lane name that moved to another project never injects the old project's RESUME: the new cwd's is read" {
  local a="$LANES_TEST_TMP/A" b="$LANES_TEST_TMP/B" p
  for p in "$a" "$b"; do git init -q -b main "$p" && mkdir -p "$p/.lanes"; done
  printf '<!-- lanes:resume:start -->\n### Goal\nPROJECT A GOAL\n### Now\nA\n### Next step\nforce-push A\n### Links\nx\n### Running\nx\n### Suggested skills\nx\n<!-- lanes:resume:end -->\n' >"$a/.lanes/next-alpha.md"
  start() { jq -nc --arg s "$1" --arg c "$2" --arg src "$3" '{session_id:$s,session_title:"alpha",cwd:$c,source:$src,transcript_path:"/nonexistent"}' | "$LANES" register; }
  start sA "$a" startup >/dev/null
  # The record a finished handshake in project A leaves behind.
  jq -nc --arg w "$a" '{session_id:"sA",prompts:0,handshake:{state:"done",worktree:$w}}' >"$LANES_DATA_DIR/lanes/state/alpha.json"
  start sB "$b" startup >/dev/null
  run reg alpha .cwd
  assert_output "$b"
  ctx="$(start sB2 "$b" clear | jq -r .hookSpecificOutput.additionalContext)"
  run echo "$ctx"
  assert_output --partial "No RESUME block was found at $b/.lanes/next-alpha.md"
  refute_output --partial "PROJECT A GOAL"
}

@test "a sending record whose work tree is in another project than the lane's is not read: the session's cwd is" {
  moved_lane sending
  local other="$LANES_TEST_TMP/other"
  git init -q -b main "$other"
  local f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq -c --arg w "$other" '.handshake.worktree = $w' "$f" >"$f.x" && mv "$f.x" "$f"
  run clear_from_start
  assert_output --partial "$LANES_TEST_TMP/start/.lanes/next-alpha.md"
}

@test "a session that takes the name from one proven gone starts a fresh handshake record" {
  make_repo
  write_resume alpha
  start_fake alpha
  local f="$LANES_DATA_DIR/lanes/state/alpha.json"
  jq -c --arg w "$WORK" '.handshake = {state: "sending", session_id: "old", worktree: $w}' "$f" >"$f.x" && mv "$f.x" "$f"
  kill -9 "$FAKE_PID"
  wait_for "fake gone" bash -c "! kill -0 $FAKE_PID 2>/dev/null"
  hook_json SessionStart other-session alpha clear | TMUX_PANE=%99 "$LANES" register >/dev/null 2>&1
  run state alpha '.handshake // "none"'
  assert_output none
  run state alpha .session_id
  assert_output other-session
}
