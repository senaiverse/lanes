# Prior art: context-threshold handoff and tmux key delivery

Read 2026-10-22. Labels: Verified (read in code/issue), Reported, Inferred, OPEN. No live Claude Code was driven; M0 probes
still apply. Clones (shallow): Continuous-Claude-v3 `d07ff4b`, Tmux-Orchestrator `7193530`, claude-tmux-orchestration
`3c4a790`, claude_code_agent_farm `d88ba78`. `#N` = anthropics/claude-code issue unless a repo is named
(https://github.com/anthropics/claude-code/issues/N).

## Answer first

1. **Nobody does our handshake.** Continuous-Claude asks the model to hand off; the other three restart on a timer or
   a screen-scraped number. None checks idle + clean + pushed, verifies the clear landed, or re-keys state after `/clear`.
2. **Premise check on DECISIONS.md.** #50978 was closed `not_planned` by the stale bot on 2026-06-11 ("inactive for too
   long"), not rejected by a maintainer, and is now locked (Verified, #50978 comments). #32811 was closed as a
   duplicate of #27571 (Verified). The upstream ask should link #27571, #96467 and #92853 too. The fact "a message with
   a slash command arrives as plain text" is confirmed by a maintainer comment (bcherny, 2026-08-17, #85289).
3. **Biggest:** the plan sends the goal through tmux. A multi-line or long paste collapses to
   `[Pasted text #N]` and a slash command inside it is *not dispatched*; it goes to the model as a message. Open bug,
   reproduced up to 2.1.301 (#85654). The goal must be typed as one line, never `paste-buffer`.
4. **Also:** a custom statusline removes `esc to interrupt` from the footer (docs), so screen-scraped idle detection breaks.
   Idle must come from hooks.

## 1. Continuous-Claude-v3 (parcadei) — handoff by the model, clear by the human

**Time to hand off.** `.claude/scripts/status.py:148-168` writes the context % to `$TMP/claude-context-pct-<session_id[:8]>.txt`
(plain `write_text`, not atomic). Stop hook `hooks/auto-handoff-stop.py:12-60`: at >= 85 returns `decision: block, reason:
"Run: /create_handoff"`; skips on `stop_hook_active` or a missing file (fails open); no latch. Verified.

**Handoff file.** The model writes YAML under `thoughts/shared/handoffs/<session-name>/YYYY-MM-DD_HH-MM_<slug>.yaml`
(`skills/create_handoff/SKILL.md`): `goal`, `now`, `test`, `done_this_session`, `blockers`, `questions`, `status`,
`outcome`. Target ~400 tokens. Also a PreCompact hook (`hooks/pre_compact_continuity.py`) builds an automatic handoff
from the transcript (last todos, last 5 tool calls, last assistant message cut to 500 chars, files edited). Verified.

**Resume.** `hooks/session_start_continuity.py:660-800`, matcher `resume|compact|clear` (`.claude/settings.json:115-117`):
for `clear|compact` it returns the newest handoff YAML as `additionalContext`. It picks the session by the *terminal shell
PID*, "stable across /clear" (lines 305-317). No tmux code: the human types `/clear`. Verified.

**Failure modes.**
- Pct file keyed by an 8-char session-id prefix; `/clear` changes the session id (#70606, Reported), so the file for
  the new session does not exist until the statusline runs again. Prefix collision is possible (Inferred).
- Handoff quality: users ask the model to review its handoff 2-3 times (#151, open). Reported.
- A hook with no timeout hung every tool call when its database was down (#109, fixed with `timeout: 5000`).
- `additionalContext` over 10,000 chars is silently replaced by a 2,000-char preview (see section 5). Their YAML is
  small, ours must be capped.

## 2. Tmux-Orchestrator (Jedward23) — timers and prompts, no context logic

No context threshold: check-ins are fixed timers (`schedule_with_note.sh:24`, a `nohup bash -c "sleep N && tmux
send-keys ... && sleep 1 && tmux send-keys ... Enter" &`), and agents are told to commit every 30 minutes by prompt only
(`CLAUDE.md:40-71`; its issue #12 asks for hooks instead). The "handoff" is one rewritten `next_check_note.txt`.
Keys (`send-claude-message.sh:17-23`): `send-keys "$MSG"`, `sleep 0.5`, `send-keys Enter`; not literal (`-l`), so tmux
key names inside a message are interpreted (Inferred); no busy check, echo check or chunking. `CLAUDE.md:556-562` records
the one lesson: send Enter as a separate call. Detached timers are lost on reboot and can stack or fire mid-turn
(Inferred). `tmux_utils.py:109-123` returns `{'error':...}` dicts, which callers miss (its issue #13). Verified.

## 3. claude-tmux-orchestration (primeline-ai) — closest to a robust tmux sender

**Time to hand off.** Heartbeat loop `_orchestrator/heartbeat.sh`: sleeps 30/120/300 s by worker state, reads
worker status JSON files, and sends `/orchestrate-cycle` to the lead pane only if it looks idle. Stuck = status file
older than 3x the normal interval (heartbeat.sh:165-175). No context threshold in code; the README lists a worker
state `CONTEXT_LOW_CONTINUE` (README.md:93) but no script computes it. Verified.

**File protocol.** `workers/<id>.json`, `inbox/<id>/escalation.json`, `log.jsonl`, `.ready`, `.stop`, `heartbeat.pid`;
state rewrites use `mktemp` then `mv`; a stale PID file is taken over after `kill -0` (heartbeat.sh:87-100, 262-272).

**Keys (`heartbeat.sh:103-157`, `spawn-worker.sh:60-120`, `rate-limit-watchdog.sh:170-180`).**
- `send-keys -l "$msg"`, `sleep 0.5`, `send-keys Enter`, `sleep 1`, then `capture-pane -S -5`, strip ANSI, and grep
  the first 40 chars of the message to "verify". Up to 3 retries, `send_ok/send_retry/send_fail` logged.
- Multi-line: `tmux load-buffer -b <name> -` then `paste-buffer -p -d -b <name>`, then a pause and Enter
  (spawn-worker.sh:180-190). `-p` is bracketed paste, which is the path that collapses long text (#85654).
- Idle: last 12 lines of `capture-pane`; spinner words `Running|thinking|Searching|Reading|Writing|Editing` mean
  busy and override; prompt glyph `❯` or `>$` means idle; unknown means busy (safe default).
- Blind "Double-Enter Protocol" at boot to dismiss trust prompts.

**Defects I see (Inferred from the code, not reproduced):**
- The send "verify" passes when Enter was lost: the text is still in the input box, so the grep finds it. It proves
  delivery to the composer, not submission. That is exactly the stuck-composer failure in #78177/#67760/#77017.
- Spinner words match prose in the last 12 lines; `>$` matches many non-prompt lines.
- Worth copying: the rate-limit watchdog's 30 s minimum gap and capped back-off (rate-limit-watchdog.sh:140-176).

## 4. claude_code_agent_farm (Dicklesworthstone) — screen-scraped context and `/clear`

**Detect.** `detect_context_percentage` (agent_farm.py:290-306) regexes the pane for `Context left until auto-compact: N%`
and three other wordings; default threshold 20% remaining (line 219); `needs_restart` returns `"context"`, the loop calls
`clear_agent_context` (~line 1953) with back-off 10 s x 2^n, max 300 s. **Handoff:** none; state survives only in a shared
problems file and periodic `git commit/push`. Heartbeat files hold an ISO time; older than 120 s flags a hang (512-545).
**Keys** (`tmux_send`, 133-190): temp file, `load-buffer -b agentfarm_<uuid8>`, `paste-buffer -d`, `sleep 0.2`
("CRITICAL: Small delay between pasting and Enter"), `send-keys C-m`; 3 retries with 0.5/1/2 s back-off. A Ctrl+R macro
broadcasts `/clear` + Enter to every pane (1549-1563). **Busy/ready** (308-340): substring lists (`esc to interrupt`,
`✻ Thinking`, `? for shortcuts`, `❯ Try `); error = "API key", "Permission denied", "TypeError", "Unauthorized"... anywhere
on screen. All Verified.

**Failure modes.** Error words match prose (Inferred). `esc to interrupt` and `? for shortcuts` vanish under a custom
statusline (docs: it "stops showing most of the footer's keyboard hints"), so working and ready both read unknown. `/clear`
has no clean/pushed or echo check. A wording change makes the regex return None and the old value persists (405-408).

## 5. Claude Code platform facts that bear on the handshake

**Statusline** (https://code.claude.com/docs/en/statusline, read 2026-10-22). Runs once at start/resume, after each
assistant message, after `/compact`, on mode changes, and on an optional `refreshInterval`. Debounced 300 ms; a new
update **cancels the in-flight script**. `context_window.used_percentage` counts input tokens only (not output) and
"may be `null` early in the session"; `current_usage` is `null` before the first API call and again after `/compact`.
So: an idle lane's file is not refreshed (no events), a slow script can be killed mid-write, and `null` is normal.
Number bugs are listed under finding 6.

**SessionStart** (https://code.claude.com/docs/en/hooks, read 2026-10-22). `source` is `startup|resume|clear|compact|fork`.
`additionalContext` is wrapped in a system reminder and inserted into the conversation. **Hook text is capped at 10,000
characters**: above that Claude Code writes it to a file and injects only the path plus the first 2,000 characters, with
no error to the hook (docs; #84021 open; an older doc said 50K, #42369). For interactive starts, hooks run in the
background but the first response waits for them. Message display: `SessionStart:clear` `systemMessage` is not drawn in
the default renderer (0/17) though `additionalContext` reached the model 17/17 (#96699, open); `fork` drops
`additionalContext` (#93458, open); `startup` display is intermittent (#98162). Hook JSON is not a UI you can read back.

**Sending commands.** A cross-session message cannot run `/clear` (maintainer, #85289). A built-in slash command typed
mid-turn is queued as plain text (#76523); queued input can be dropped at turn end (#85603).

## 5b. Matt Pocock handoff skills (mattpocock/skills)

Licence: **MIT**, https://github.com/mattpocock/skills/blob/main/LICENSE (GitHub licence API, read 2026-10-22). Files
read: `skills/productivity/handoff/SKILL.md` and `skills/in-progress/claude-handoff/SKILL.md` (local copies match).

- **What a handoff holds.** Free prose, no schema: a summary of the conversation plus a "suggested skills" section.
  Rules: reference specs, plans, ADRs, issues, commits and diffs by path or URL instead of copying them; redact secrets
  and personal data; tailor to an optional argument ("what the next session is for"). `handoff` saves to the OS temp
  directory, not the workspace; `claude-handoff` instead starts `claude --bg --name "<name>" "<summary>"`, so the
  summary becomes the new agent's prompt.
- **How resume reads it.** It does not: no hook, no registry, no clear. The human or the launcher passes the file or
  the prompt. `disable-model-invocation: true` means the model never starts a handoff itself. No context threshold.
- **Borrow (credit Matt Pocock, MIT, in the template):** (1) link, do not copy: RESUME points at plan/tracker/commit
  paths, which also keeps it under the 10,000-char cap; (2) the redaction line, since RESUME is injected into context
  and may be committed to a public repo; (3) an optional "what is next" argument; (4) a "suggested skills" line, so a
  cleared lane reloads the right skill; (5) a descriptive name per lane.
- **Avoid.** Temp-dir storage (lost on reboot, not shared with the lead, not in git; ours must live in `.lanes/`);
  free-form prose with no required sections (nothing to validate, finding 11); the prompt-as-handoff path
  `claude --bg "<summary>"`, which has no size cap handling and a shell-quoting hazard for long text (Inferred).

## 6. Ranked failure modes for the M1 handshake

Ranking = damage x likelihood. `Test:` names are bats cases against a real tmux server with a fake `claude`.

**1. `/clear` reaches a busy lane, or is queued as text.** Lost work, or a `/clear` message fed to the model.
Evidence: #76523 and #85603. The maintainers have also seen a `/clear` queued into a busy lane after a stale
clear-ready. Their earlier private script refused when the screen showed a spinner, "queued messages" or "running
Stop hook" text, and re-checked after a 3 s pause. Handle: re-check idle at the instant of
send (not at clear-ready time), twice, with a gap; prefer a hook-driven busy flag over screen text (see 8).
Test: `clear_refuses_when_lane_busy_at_send_time`, `clear_rechecks_idle_after_gap`.

**2. Activity between clear-ready and clear.** The lead sends a follow-up, a goal Stop hook re-prompts, or a human
types; the clear then discards work the RESUME block does not cover. Evidence: #100634; in-house incident (lane
answering a follow-up when cleared). The plan's "unchanged since clear-ready" covers it; define "unchanged" as: HEAD
sha, tree status, RESUME mtime and a transcript/hook activity counter. A goal that never lets the turn end blocks
idle forever, so the lane must lift its goal before reporting clear-ready (in-house order: push, report, goal clear).
Test: `clear_refuses_if_head_or_resume_changed_since_ready`, `clear_times_out_when_goal_blocks_idle`.

**3. Enter lost, text stranded in the composer, or a ghost render.** `/clear` sits unsent; the next send appends to
it. Evidence: #78177 (10 hits in a day, tmux, closed stale), #77017 (stranded 13.4 h), #67760 (ghost: empty buffer,
Enter and C-u do nothing), #52812 (REPL ignoring submit in tmux, v2.1.119), in-house note (Enter lost while lane busy
leaves the goal in the input line). primeline's verify cannot see this (it matches the stranded text). Handle: after
Enter, confirm the *effect* (pane no longer shows the typed text on the prompt line AND the session id changed, or the
SessionStart(clear) register fired), else bounded retry then loud failure; check the composer is empty before typing
(never `C-u` a human's draft).
Test: `clear_detects_enter_swallowed_and_retries_once`, `clear_fails_loud_after_max_retries`, `clear_refuses_nonempty_composer`.

**4. Goal (or any slash command) sent as a paste.** Collapsed paste is not dispatched; no error. Evidence: #85654 (open;
reproduced on 2.1.233, 2.1.252, 2.1.263 Windows, 2.1.301; threshold about 4 lines or about 800+ chars). Also a newline
inside `send-keys -l` text acts as Enter (Inferred). Handle: type a single line with `send-keys -l --` in small
chunks with a short sleep (in-house finding: 4-char chunks, 30 ms apart), never `paste-buffer` for slash commands, cap
goal length, confirm "goal active" appears. The chunk size is empirical; OPEN whether larger chunks work on current
builds. Test: `goal_sent_as_single_line_chunks_not_paste`, `goal_with_newline_is_rejected`, `goal_active_echo_checked`.

**5. RESUME injection dropped or truncated.** The lane wakes with no context and says nothing. Evidence: 10,000-char cap
with 2,000-char preview (docs, #84021); `fork` drop (#93458); display bugs mean you cannot confirm by eye (#96699).
Handle: enforce a size cap when the RESUME block is written (reject over ~8,000 chars so the goal and wrapper fit),
emit valid JSON on stdout only (any stray stdout breaks it), keep the hook fast with a timeout (Continuous-Claude #109),
and verify landing by a marker the lane echoes or the registry records (OPEN how; M0 probe 3).
Test: `session_start_clear_output_is_valid_json_under_cap`, `oversize_resume_block_refused_at_write`,
`hook_missing_resume_file_emits_notice_not_error`.

**6. Context % wrong, stale, null or absent.** The lane silently auto-compacts, or is cleared too early/late.
Evidence: docs (null early; input tokens only; no refresh while idle), #86785 (0 after compact), #73399 (200K vs 1M),
#17959 (19-point gap), #92853 (no statusline), Continuous-Claude status.py fails open (pct missing means no action).
Handle: three states, never collapse them: a number, `unknown` (null/missing/older than N minutes), and `stale`. Treat
`unknown` as "ask the lane / do not assume safe". Pick the threshold with headroom so the lane can still write RESUME
(the model's own estimate is off 15-20%, #32811; PreCompact fires near 95%, #50978). Record the model/context size if
available. Write via temp file then `mv` and always exit 0, because an update cancels the running script.
Test: `status_marks_null_pct_unknown_not_zero`, `status_marks_old_file_stale`, `threshold_at_exactly_70_triggers`,
`statusline_cancelled_mid_write_leaves_old_file_intact` (kill -TERM the script).

**7. Identity changes on `/clear`; registry keyed wrongly.** The lead reads the old session's % or loses the lane.
Evidence: #70606 (new session id), Continuous-Claude keys by 8-char session prefix and falls back to terminal shell PID.
Handle: key a lane by pane id plus a registered claude PID, store the current session id as an attribute re-written by
SessionStart(clear), and never read a % file belonging to another session id; after clear, treat % as unknown until the
first statusline write. OPEN: does `$TMUX_PANE` reach the hook (M0 probe 2).
Test: `register_rekeys_session_on_clear`, `old_session_pct_ignored_after_clear`, `register_without_tmux_pane_explains`.

**8. Idle detected from screen text.** Wrong busy/idle verdicts. Evidence: agent_farm lists (error words match prose;
`esc to interrupt` gone with a custom statusline), primeline regexes (spinner words in prose), prompt glyph and spinner
wording change per version. Handle (Inferred design): lanes keep a busy flag via hooks (UserPromptSubmit sets, Stop
clears, a heartbeat timestamp) and screen text is only a second, vetoing check. Stop may not fire on interrupt or API
error; a stale flag must age out. OPEN: which hook events fire on interrupt/error (probe).
Test: `idle_from_hook_flag_ignores_spinner_words_in_transcript`, `busy_flag_expires_after_ttl`.

**9. Wrong target.** `/clear` typed into a shell, the lead, or another lane. Evidence: primeline comment that a bare
session name targets whichever window is active (heartbeat.sh ~line 28); Tmux-Orchestrator uses `session:window`
indexes that shift; plan already lists "two lanes with the same name" and "missing pane". Handle: address by pane id
`%N` from the registry, check `#{pane_pid}` has the registered claude process as a child and the pane is not in copy
mode (send-keys goes to the copy-mode key table; Inferred from tmux behaviour, OPEN) before any send.
Test: `clear_refuses_pane_not_running_claude`, `two_lanes_same_name_refused`, `clear_refuses_pane_in_copy_mode`.

**10. Dialog or prompt on screen at clear time.** Esc/`/clear` keystrokes answer a permission or question prompt.
Evidence: primeline's blind Double-Enter; #70577 (AskUserQuestion keyboard input unreliable); Esc interrupts a running
turn (Inferred; the plan sends Esc, so it must come only after idle is proven). Handle: refuse when a dialog is
detected (hook `Notification`/permission event if available, else screen veto) and say why; send Esc only once.
Test: `clear_refuses_when_permission_prompt_open`, `clear_sends_single_escape_only_after_idle`.

**11. RESUME block missing, stale or hollow.** The lane reports clear-ready with an unusable block, or cannot write one
because it is already near auto-compact. Evidence: Continuous-Claude #151 (needs several passes); #32811 (model
cannot judge its own context); the message may reach a lane only at end of turn (#103260 Desktop, Reported — OPEN
for CLI). Handle: `lanes clear-ready` validates the block (file mtime newer than the request, required headings,
non-empty "next step", under the size cap) and refuses otherwise; the lead times out the request and escalates to the
owner instead of clearing. Test: `clear_ready_refused_when_resume_older_than_request`, `clear_ready_refused_missing_sections`,
`lead_times_out_when_lane_never_answers`.

**12. Lead dies or two leads race mid-handshake.** Double clear, or a lane left half-cleared. Evidence: primeline
PID file with stale takeover and `.stop` file; Tmux-Orchestrator detached timers can stack; plan test "lead restarted
mid-handshake". Handle: one handshake record per lane (state, request time, expected HEAD sha, attempt count) written
atomically; transitions are idempotent; a flock held while `lanes clear` runs; `/clear` already done is detected from
the session id change, not assumed.
Test: `lead_restart_resumes_handshake_from_record`, `second_clear_while_locked_refused`, `registry_half_written_is_rejected`.

## 7. Do not

Paste-buffer or multi-line text for `/clear` or the goal (4); screen text as the only idle/error signal (8); verifying a
send by grepping the sent text (3); failing open on a null % (6); trusting the model to judge context or run `/clear`;
a hook without a timeout or with stray stdout (5); blind Enters to dismiss prompts (10).

## 8. OPEN (what settles each)

- SessionStart `source=clear` re-run and its `session_id` (#70606 vs docs); `$TMUX_PANE` in hooks: M0 probes 2-3.
- Largest `send-keys -l` chunk that still dispatches `/goal`; whether a typed long goal collapses: scratch-pane test.
- Hook events on interrupt, API error, rate limit (busy flag); does `/clear` drop an active `/goal`: probe.
- Cross-session messages to a busy CLI lane (M0 probe 4); `used_percentage` after `/clear`: probe.
## Primary web sources (read 2026-10-22)

- https://code.claude.com/docs/en/statusline and https://code.claude.com/docs/en/hooks (SessionStart, 10,000-char cap)
- Issues cited by number above (all anthropics/claude-code).
- https://github.com/mattpocock/skills (handoff, claude-handoff, LICENSE)
- https://github.com/parcadei/Continuous-Claude-v3 (issues 9, 63, 109, 151), https://github.com/Jedward23/Tmux-Orchestrator
  (issues 12, 13), https://github.com/primeline-ai/claude-tmux-orchestration,
  https://github.com/Dicklesworthstone/claude_code_agent_farm
