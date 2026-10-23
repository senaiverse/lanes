#!/usr/bin/env bats
# Public seams: `lanes request` (lead) and `lanes clear-ready` (lane). Ready means clean, pushed, and a RESUME block that
# is complete, under the cap and rewritten since the lead's request.

load helper
load lead

setup_lane() {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
}

@test "clear-ready marks the lane ready and records the head, RESUME hash and goal" {
  setup_lane
  run "$LANES" clear-ready --lane alpha
  assert_success
  assert_output --partial "clear-ready: alpha"
  run reg alpha .clear_ready
  assert_output true
  run state alpha '.handshake | [.state, .head, .goal] | join("|")'
  assert_output "ready|$(git -C "$WORK" rev-parse HEAD)|finish item A1 and report done"
}

@test "a request and a clear-ready that cannot name their own process say so, never 'registry locked', and write nothing" {
  setup_lane
  register_lead
  ps_fails_for self
  export LANES_NO_FLOCK=1
  PATH="$LANES_TEST_TMP/shim:$PATH" TMUX_PANE=%99 run "$LANES" request alpha
  assert_failure
  assert_output --regexp "registry lock not taken: the start time of pid [0-9]+, this lock's holder, could not be read"
  refute_output --partial "registry locked"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --regexp "not clear-ready: registry lock not taken: the start time of pid [0-9]+"
  refute_output --partial "registry locked"
  run bash -c "jq -r '.handshake.state // \"none\"' '$LANES_DATA_DIR/lanes/state/alpha.json' 2>/dev/null || echo none"
  assert_output none
  run reg alpha .clear_ready
  assert_output false
}

@test "clear-ready records the transcript and the tool calls it shows: assistant tool_use blocks by id, nothing else" {
  make_repo
  write_resume alpha
  t="$LANES_TEST_TMP/transcript.jsonl"
  {
    echo '{"type":"user","message":{"role":"user","content":"a prompt"}}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'
    echo '{"type":"api-request-blob","message":{"content":[{"type":"tool_result","tool_use_id":"t1"},{"type":"tool_use","id":"blob"}]}}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}'
    echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}'
    echo '{"type":"attachment","attachment":{"type":"goal_status","met":false,"sentinel":true,"condition":"c"}}'
    printf '{"type":"assistant","message":'
  } >"$t"
  hook_json SessionStart s1 alpha startup | jq -c --arg t "$t" '.transcript_path = $t' | TMUX_PANE=%7 "$LANES" register >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_success
  run state alpha '.handshake | [.transcript, .tools] | join("|")'
  assert_output "$t|2"
}

@test "clear-ready refuses a lane whose transcript is unset or unreadable, since lanes clear could never prove it unchanged" {
  make_repo
  write_resume alpha
  hook_json SessionStart s1 alpha startup | jq -c 'del(.transcript_path)' | TMUX_PANE=%7 "$LANES" register >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "not clear-ready: lane alpha has no transcript recorded"
  run reg alpha .clear_ready
  assert_output false
  t="$LANES_TEST_TMP/locked.jsonl"
  echo '{}' >"$t"
  chmod 000 "$t"
  hook_json SessionStart s1 alpha startup | jq -c --arg t "$t" '.transcript_path = $t' | TMUX_PANE=%7 "$LANES" register >/dev/null
  run "$LANES" clear-ready --lane alpha
  chmod 600 "$t"
  assert_failure
  assert_output --partial "the transcript '$t' of lane alpha cannot be read"
  run bash -c "jq -r '.handshake.state // \"none\"' '$LANES_DATA_DIR/lanes/state/alpha.json'"
  assert_output none
}

@test "a RESUME check that crashes (its character count killed) is a refusal, never ready" {
  setup_lane
  jq_shim 'explode[] | if . > 65535' 1+
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "check failed: resume_problems"
  run reg alpha .clear_ready
  assert_output false
}

@test "clear-ready finds its own lane from TMUX_PANE when --lane is absent" {
  setup_lane
  TMUX_PANE=%7 run "$LANES" clear-ready
  assert_success
  TMUX_PANE=%55 run "$LANES" clear-ready
  assert_failure
  assert_output --partial "cannot tell which lane"
}

@test "dirty tree: clear-ready refuses and names the fix" {
  setup_lane
  printf 'y\n' >>"$WORK/file"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "uncommitted changes"
  run reg alpha .clear_ready
  assert_output false
}

@test "unpushed head: clear-ready refuses" {
  setup_lane
  git -C "$WORK" commit -q --allow-empty -m local
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "1 unpushed commit"
}

@test "a branch with no upstream is refused" {
  setup_lane
  git -C "$WORK" checkout -q -b side
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "no upstream"
}

@test "empty journal: no RESUME file means not clear-ready, with the init command" {
  make_repo
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "lanes init alpha"
}

@test "clear_ready_refused_missing_sections" {
  setup_lane
  sed '/### Links/d' "$WORK/.lanes/next-alpha.md" >"$LANES_TEST_TMP/n" && mv "$LANES_TEST_TMP/n" "$WORK/.lanes/next-alpha.md"
  git -C "$WORK" commit -qam drop && git -C "$WORK" push -q
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "no '### Links' section"
}

@test "an empty Next step is refused" {
  make_repo
  write_resume alpha "a goal" "<!-- the one next action -->"
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "'Next step' is empty"
}

@test "goal_with_newline_is_rejected: a two-line Goal is refused at clear-ready" {
  make_repo
  write_resume alpha "first line
second line"
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "'Goal' must be one line"
}

@test "oversize_resume_block_refused_at_write" {
  make_repo
  write_resume alpha "a goal" "$(printf 'x%.0s' $(seq 1 8100))"
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "over the 8000 cap"
}

@test "clear_ready_refused_when_resume_older_than_request: RESUME unchanged since the request" {
  setup_lane
  run as_lead request alpha
  assert_success
  assert_output --partial "clear-ready"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "unchanged since the lead's request"
  write_resume alpha "finish item A1, now with tests"
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "request on an unknown lane fails loudly" {
  run as_lead request ghost
  assert_failure
  assert_output --partial "no valid registry entry for 'ghost'"
}

@test "lanes request does not overwrite a clear that is in flight (handshake sending)" {
  setup_lane
  "$LANES" clear-ready --lane alpha >/dev/null
  jq '.handshake.state = "sending"' "$LANES_DATA_DIR/lanes/state/alpha.json" >"$LANES_TEST_TMP/s" && mv "$LANES_TEST_TMP/s" "$LANES_DATA_DIR/lanes/state/alpha.json"
  run as_lead request alpha
  assert_failure
  assert_output --partial "in flight"
  run state alpha .handshake.state
  assert_output sending
}

@test "clear-ready checks the work tree it is run from, not the session's start directory" {
  make_repo
  write_resume alpha
  mkdir -p "$LANES_TEST_TMP/start"
  hook_json SessionStart s1 alpha startup | jq -c --arg c "$LANES_TEST_TMP/start" '.cwd = $c' | TMUX_PANE=%7 "$LANES" register >/dev/null
  run bash -c "cd '$WORK/.lanes' && '$LANES' clear-ready --lane alpha"
  assert_success
  run state alpha .handshake.worktree
  assert_output "$WORK"
}

@test "clear-ready outside any git work tree is refused and says where to run it" {
  setup_lane
  mkdir -p "$LANES_TEST_TMP/nogit"
  run bash -c "cd '$LANES_TEST_TMP/nogit' && '$LANES' clear-ready --lane alpha"
  assert_failure
  assert_output --partial "not a git work tree"
}

# register_in_start [commit]: the session started in another work tree of the same project (at <commit>, default
# HEAD), so its registry cwd has a different journal.
register_in_start() {
  git -C "$WORK" worktree add -q --detach "$LANES_TEST_TMP/start" "${1:-HEAD}"
  hook_json SessionStart s1 alpha startup | jq -c --arg c "$LANES_TEST_TMP/start" '.cwd = $c' | TMUX_PANE=%7 "$LANES" register >/dev/null
}

start_elsewhere() {
  make_repo
  write_resume alpha
  register_in_start
}

@test "request reads RESUME where the last clear-ready proved it, so 'unchanged since the request' still holds" {
  start_elsewhere
  "$LANES" clear-ready --lane alpha >/dev/null
  run as_lead request alpha
  assert_output --partial "$WORK/.lanes/next-alpha.md"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "unchanged since the lead's request"
}

@test "a RESUME block at another place than the one the request read is ready only once the block itself changed after it" {
  make_repo
  register_in_start
  # The RESUME was committed an hour before the request, at a place the request did not read.
  GIT_COMMITTER_DATE="$(($(date +%s) - 3600)) +0000" write_resume alpha
  as_lead request alpha >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "the same as in its last commit before the lead's request"
  # A commit after the request that changes only the file outside the block proves nothing.
  printf '\n## Open items\n- B2 waits on CI\n' >>"$WORK/.lanes/next-alpha.md"
  git -C "$WORK" commit -q -am "open items" && git -C "$WORK" push -q
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "the same as in its last commit before the lead's request"
  write_resume alpha "finish item A1, now with tests"
  printf '\n## Open items\n- B2 waits on CI\n' >>"$WORK/.lanes/next-alpha.md"
  git -C "$WORK" commit -q -am "open items" && git -C "$WORK" push -q
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "a RESUME file new in the work tree the lane moved to, written after the request, is ready" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  "$LANES" clear-ready --lane alpha >/dev/null
  as_lead request alpha >/dev/null
  # The new work tree starts at the first commit, before the RESUME file existed.
  git -C "$WORK" worktree add -q -b wt2 "$LANES_TEST_TMP/wt2" HEAD~1
  git -C "$LANES_TEST_TMP/wt2" push -q -u origin wt2
  (WORK="$LANES_TEST_TMP/wt2" && write_resume alpha "finish item A1 in the new tree")
  run bash -c "cd '$LANES_TEST_TMP/wt2' && '$LANES' clear-ready --lane alpha"
  assert_success
}

@test "the session that holds the lane is decided under the mutex: a session that took the lane during clear-ready is not marked ready" {
  setup_lane
  mkdir -p "$LANES_TEST_TMP/shim"
  # Right after clear-ready read the entry, while it checks the tree, a new session of alpha registers.
  cat >"$LANES_TEST_TMP/shim/git" <<EOS
#!/usr/bin/env bash
if [[ " \$* " == *" status --porcelain"* && ! -f "$LANES_TEST_TMP/took" ]]; then
  : >"$LANES_TEST_TMP/took"
  jq -nc --arg c "$WORK" --arg tp "$LANES_TEST_TMP/transcripts/s2.jsonl" '{session_id:"s2",session_title:"alpha",cwd:\$c,source:"startup",transcript_path:\$tp}' | TMUX_PANE=%7 "$LANES" register >/dev/null 2>&1
fi
exec "$(command -v git)" "\$@"
EOS
  chmod +x "$LANES_TEST_TMP/shim/git"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "started a new session while clear-ready ran"
  run reg alpha .session_id
  assert_output s2
  run reg alpha .clear_ready
  assert_output false
  run state alpha '.handshake.state // "none"'
  refute_output ready
}

@test "a lane that moved to another work tree completes request then clear-ready there, twice" {
  make_repo
  write_resume alpha
  register_lane alpha s1 %7 >/dev/null
  "$LANES" clear-ready --lane alpha >/dev/null
  git -C "$WORK" worktree add -q -b wt2 "$LANES_TEST_TMP/wt2"
  git -C "$LANES_TEST_TMP/wt2" push -q -u origin wt2
  for i in 1 2; do
    as_lead request alpha >/dev/null
    (WORK="$LANES_TEST_TMP/wt2" && write_resume alpha "finish item A1, round $i")
    run bash -c "cd '$LANES_TEST_TMP/wt2' && '$LANES' clear-ready --lane alpha"
    assert_success
    run state alpha .handshake.worktree
    assert_output "$LANES_TEST_TMP/wt2"
  done
}

@test "a request that lands while clear-ready runs stands: clear-ready refuses, never overwrites it with ready" {
  setup_lane
  register_lead
  mkdir -p "$LANES_TEST_TMP/shim"
  # After clear-ready read the record and before it takes the mutex (its read of the transcript path), the lead requests.
  cat >"$LANES_TEST_TMP/shim/jq" <<EOS
#!/usr/bin/env bash
if [[ "\${1:-}" == -r && "\${2:-}" == '.transcript // ""' && ! -f "$LANES_TEST_TMP/requested" ]]; then
  : >"$LANES_TEST_TMP/requested"
  TMUX_PANE=%99 "$LANES" request alpha >"$LANES_TEST_TMP/request.out" 2>&1
fi
exec "$(command -v jq)" "\$@"
EOS
  chmod +x "$LANES_TEST_TMP/shim/jq"
  PATH="$LANES_TEST_TMP/shim:$PATH" run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "a new 'lanes request alpha' arrived while this command ran"
  assert_output --partial "run 'lanes clear-ready' again"
  run cat "$LANES_TEST_TMP/request.out"
  assert_output --partial "requested:"
  run state alpha .handshake.state
  assert_output requested
  run reg alpha .clear_ready
  assert_output false
}

@test "lanes request from a caller that is not the lead is refused and opens nothing" {
  setup_lane
  "$LANES" clear-ready --lane alpha >/dev/null
  run "$LANES" request alpha
  assert_failure
  assert_output --partial "only the lead"
  TMUX_PANE=%7 run "$LANES" request alpha
  assert_failure
  assert_output --partial "only the lead"
  run state alpha .handshake.state
  assert_output ready
}

@test "clear-ready --lane from a pane registered to another lane is refused" {
  setup_lane
  register_lane beta s2 %8 >/dev/null
  TMUX_PANE=%8 run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "pane %8 is lane beta, not alpha"
  run reg alpha .clear_ready
  assert_output false
  TMUX_PANE=%7 run "$LANES" clear-ready --lane alpha
  assert_success
  TMUX_PANE=%55 run "$LANES" clear-ready --lane alpha
  assert_success
}

# journal_worktree: the journal lives in a second work tree of the same repo, on its own pushed branch. Sets J.
journal_worktree() {
  make_repo
  J="$LANES_TEST_TMP/jwt"
  git -C "$WORK" worktree add -q -b journal "$J"
  git -C "$J" push -q -u origin journal
  (WORK="$J" && write_resume alpha)
  export LANES_JOURNAL_DIR="$J/.lanes"
}

@test "the lane's own journal files in their own work tree must be committed and pushed too, at clear-ready" {
  journal_worktree
  register_lane alpha s1 %7 >/dev/null
  run "$LANES" clear-ready --lane alpha
  assert_success
  printf 'a finished item\n' >>"$J/.lanes/done-alpha.md"
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "the journal's work tree"
  assert_output --partial "done-alpha.md"
  assert_output --partial "uncommitted changes"
  git -C "$J" add .lanes && git -C "$J" commit -q -m done
  run "$LANES" clear-ready --lane alpha
  assert_failure
  assert_output --partial "unpushed"
  git -C "$J" push -q
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "other lanes' work in a shared journal work tree, uncommitted or unpushed, does not block this lane" {
  journal_worktree
  register_lane alpha s1 %7 >/dev/null
  printf 'beta is mid-edit\n' >"$J/.lanes/next-beta.md"
  run "$LANES" clear-ready --lane alpha
  assert_success
  git -C "$J" add .lanes && git -C "$J" commit -q -m "beta's resume"
  printf 'gamma is mid-edit\n' >"$J/.lanes/done-gamma.md"
  run "$LANES" clear-ready --lane alpha
  assert_success
}

@test "a journal work tree whose lane files changed after clear-ready stops lanes clear before anything is typed" {
  journal_worktree
  start_fake alpha
  run "$LANES" clear-ready --lane alpha
  assert_success
  printf 'draft\n' >>"$J/.lanes/done-alpha.md"
  run as_lead clear alpha
  assert_failure
  assert_output --partial "the journal's work tree"
  run grep -c -E '^(BURST|ESC)' "$FAKE_LOG"
  assert_output 0
}
