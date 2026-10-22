# lanes v0.1 — build plan

The decisions are in `DECISIONS.md`; this file only says how to build them. Each milestone ends green: script tests,
`claude plugin validate --strict`, and a review by the reviewer subagent.

## Layout: one marketplace, one plugin per piece

Optional pieces are separate plugins, so users install only what they want. Claude Code has no per-component
enable switch inside a single plugin.

```
lanes/
  .claude-plugin/marketplace.json       lists every plugin below
  plugins/
    lanes/            core (required)
      .claude-plugin/plugin.json        userConfig: threshold (default 70), journal_dir (default .lanes), journal_branch (optional)
      skills/lead/SKILL.md              lead procedure: plan into the journal, message lanes, run the clear handshake
      skills/lane/SKILL.md              lane procedure: build from a plan, keep RESUME current, answer clear-ready
      hooks/hooks.json                  SessionStart(startup|resume|clear|compact) → register pane + re-inject RESUME/goal
      bin/lanes                         init | register | status | clear-ready | clear <lane>
      bin/lanes-statusline              statusline wrapper: writes context % per session to the registry, prints a line
      templates/journal/                README, RULES.md (mechanism rules), tracker.md, next-lane.md, done-lane.md
    lanes-guards/     lead-only CI/merge, lead-only plan messages, no edits in the main checkout
    lanes-jobs/       tmux pane pool + STATUS file + slot locks (bin/lanes-job)
    lanes-waves/      release-waves skill (theme branches → integration branch → one merge)
    lanes-plancheck/  plan field checker (bin/lanes-plancheck)
    lanes-ci/         CI-watch monitor (gh run watch based)
    lanes-review/     read-only adversarial reviewer agent
  tests/              bats-core suites; tmux runs inside the CI container
  evals/              claude plugin eval cases for the lead and lane skills
  docs/               DECISIONS.md, PLAN-v0.1.md, how-it-works.md
  .github/workflows/ci.yml
  README.md  LICENSE (MIT)
```

The registry is the single home for "which pane is which lane, and how full is it". Its format is in `CONVENTIONS.md` "State".
It is keyed by lane name, because `/clear` rotates the session id.

M0 is done (`M0-FINDINGS.md`) and changes M1 as follows:
- A plugin cannot set `statusLine`, so `lanes init` prints the block the user adds to their settings. The block points
  at a stable link under `${CLAUDE_PLUGIN_DATA}` that the SessionStart hook refreshes.
- Sessions start as `claude --name <lane>`.
- `lanes register` runs on every SessionStart source, `clear` included, and re-keys by lane name.
- The `SessionStart(clear)` hook stays fast and synchronous.
- `lanes-ci` is a `bin/` watcher started by a `monitors.json` entry.

## M0 — verify the platform (no product code)

Each fact below gets a 10-line probe in a scratch plugin. The result goes into `DECISIONS.md` "Platform facts" with the
doc URL.

1. Can a plugin's `settings.json` set `statusLine`, or must the user wire `lanes-statusline` themselves? This decides
   the install step.
2. What does `SessionStart` input carry (session_id, source, cwd)? Does `$TMUX_PANE` reach the hook process?
3. Does `additionalContext` from `SessionStart(clear)` land in the new context?
4. Does a cross-session message name equal what ListAgents prints for a tmux pane session? How does a lane learn its
   own name?
5. Are `bin/` entries on PATH for hooks and for Bash calls in the session?
6. Is the monitor config schema stable enough for `lanes-ci`, or does `lanes-ci` ship as a `bin/` watcher run in a
   background shell?

**Exit:** every answer is cited. Any "no" changes this plan before M1 starts.

## M1 — core: journal + clear handshake + skills

1. Write `lanes init` red first. It writes `templates/journal` into `journal_dir`, and it is idempotent: it never overwrites
   existing files. It also does two things that need the user:
   - It prints the `statusLine` block for the user's settings.
   - It offers to add `@.lanes/RULES.md` to the project's `CLAUDE.md`, because a plugin's own `CLAUDE.md` is not loaded
     (M0). It asks before editing, and adds the line at most once.
2. Write `lanes register` (SessionStart hook) red first. It records the pane and the session, and survives a missing
   `$TMUX_PANE` with a clear message.
3. `lanes-statusline` updates `used_pct` atomically (write a temp file, then `mv`). The update must never block the status
   line: on any error it exits 0 and prints the line.
4. The handshake:
   - The lead runs `lanes status` and sees a lane at or above the threshold.
   - The lead messages the lane.
   - The lane writes RESUME and runs `lanes clear-ready`, which refuses unless the tree is clean and the head is pushed.
   - The lead runs `lanes clear <lane>`, which refuses unless the lane is clear-ready, idle and unchanged since then.
   - `lanes clear` sends Esc, `/clear` and the goal through tmux, then confirms the echo.
5. `SessionStart(clear)` re-injects the lane's RESUME block and goal through `additionalContext`.
6. The lead skill covers asking the human (DECISIONS 17) and away mode (18): `lanes away on|off` sets a flag in
   the registry, and a PreToolUse hook on `AskUserQuestion` refuses the call while the flag is on and points to
   `.lanes/morning.md`. The lane skill covers the done-report form (18), and the journal template carries its file.
7. The lead and lane skills cover the procedure only. Mechanism rules live in `templates/journal/RULES.md`, which the
   skills cite and never copy.

**Tests:** bats tests for the paths below, against a real tmux server in CI:
- Empty journal.
- Missing pane.
- Two lanes with the same name.
- Registry file corrupted or half-written.
- Lane busy at clear time.
- Dirty tree.
- Unpushed head.
- Clear sent but the echo is lost.
- Lead restarted mid-handshake.
- Threshold at exactly 70.

The eval cases check that a lane at threshold writes RESUME before it says clear-ready.

## M1.5 — `/lanes:setup` (DECISIONS 22)

This milestone starts after M1, and after `research/mattpocock-skills-structure.md` sets the writing style. It is a
goal-based skill in the core plugin:
- It asks the project's facts one question at a time: CI command, review gate, which commands only the lead may run,
  whether tests run locally or on CI, and the deny-list.
- From the answers it writes the project's adapter files under `.lanes/`.
- It runs `lanes check-adapters`, the shipped contract tests, against what it generated.
- A setup is done only when those tests pass.

Phrasing follows `research/mattpocock-skills-structure.md` recommendations 4-6:
- Explore first, then ask, offering the recommended answer first.
- Show a draft, and write only after the user confirms.
- Edit existing blocks in place and keep fixed-shape adapter templates.
- Offer a "check only" re-run.
- Add one `## Lanes` pointer block to the project's CLAUDE.md.

## M2 — lanes-guards

PreToolUse hooks, red first:
- `gh workflow run`, `gh pr merge` and the configurable CI/merge commands are refused unless the caller is the lead (identity
  from the registry).
- Plan-shaped SendMessage from a lane is refused.
- Edit and Write in the main checkout are refused when the lead runs lanes in worktrees.

Each guard's refusal message names the rule and the allowed path.

## M3 — lanes-jobs

`lanes-job run <name> -- <cmd>` runs a command in a pooled tmux pane and writes STATUS (`EXIT:<code>`, start, end, log
path). Slots are pid-symlink locks under the shared state dir (`CONVENTIONS.md` "Code" and "State"). Tests cover: pool exhausted, a job killed mid-run (STATUS still
written by the trap), a stale lock after a crash, and two jobs with the same name.

## M4 — lanes-waves, lanes-plancheck, lanes-ci, lanes-review

`lanes-ci` also ships `lanes-ci drift`, the journal drift check (DECISIONS 18). It compares each lane's in-flight rows
with `gh` PRs, branch heads and CI runs, and prints only the stale rows.

Port the procedures as written, made generic. No product names, paths or hosts. Each skill is under 200 lines and cites
RULES.md.

## M5 — release

1. Write the README: the 2-minute quickstart, the gap table from `DECISIONS.md`, and pointers to the destructive-command guards.
2. Add `docs/how-it-works.md` with one diagram of the handshake.
3. Make CI green on Linux and macOS runners.
4. Record the 60-second demo.
5. Draft the upstream issue text for the owner's yes.

## Porting sources

The worker reads `PORT-SOURCES.local.md`, which is gitignored and never published, for the private files each piece
generalizes. Every ported file is rewritten, not copied. Before each commit, a grep gate fails the build on any product
name, host or ID listed in that file.

## Out of scope for v0.1

Native Windows, agent-teams integration, and auto-clear without the handshake. Destructive-command guarding is also out;
other plugins own it.
