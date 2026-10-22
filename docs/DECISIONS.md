# lanes — decisions

Owner grill, 2026-10-22. Each line is a settled decision; change one only with the owner.

## What and why

- **What:** a Claude Code plugin for running several Claude sessions in tmux: one lead session plans, lane
  sessions build, a durable journal carries state, and lanes are cleared at a context threshold and resume.
- **Why:** contribute to the OSS community and the Claude team.
- **Gap it fills** (landscape check 2026-10-22):
  - Parallel-session managers already exist (claude-squad, ccmanager, vibe-kanban, agent teams).
  - Destructive-command guards already exist (destructive_command_guard, cc-safety-net, hookify).
  - Nothing found covers a lead that clears lanes at a threshold and resumes them from a structured journal.
  - Nothing found covers a tmux job pane pool with STATUS files.
  - Nothing found covers release waves (theme branches → integration branch → one merge).
  - Agent teams cannot resume teammates.
  - The feature request for a context-threshold handoff, anthropics/claude-code#50978, was closed by the stale bot as not planned, not by a maintainer
    (`research/prior-art-handoff.md`).

## Settled

| # | Topic | Decision |
|---|---|---|
| 1 | Name | `lanes` (names starting `claude-`/`anthropic-` are reserved) |
| 2 | Home | Public repo `senaiverse/lanes` from the first commit, MIT. Fully separate from any product repo: no product secrets, hosts, IDs or journal content. |
| 3 | Shape | Pieces plus one recipe: every piece works alone, and one lead/lane skill pair composes them. |
| 4 | Required core | Journal template, the clear handshake, and the lead and lane skills. |
| 5 | Optional | Job pane pool (STATUS files, slots), release waves, plan checker, CI monitors, local-vs-CI test choice, reviewer agent. |
| 6 | Guards | Multi-session guards only: only the lead dispatches CI and merges, only the lead sends plan messages, no edits in the main checkout. Destructive-command guarding is left to destructive_command_guard / cc-safety-net (README points there). Production is fenced by a separate plugin (row 26). |
| 7 | Rules shipped | Mechanism rules only. A project's engineering standards stay in that project; one is linked as an example. |
| 8 | Messaging | Native cross-session messaging (ListAgents/SendMessage, Claude Code ≥ 2.1.224). tmux `send-keys` only for `/clear` and `/goal`, which messages cannot run. |
| 9 | Clear policy | Handshake. At the threshold the lead asks the lane to write its RESUME block. The lane reports clear-ready when it is idle, clean and pushed, and only then is it cleared. A `SessionStart` hook with the `clear` matcher re-injects RESUME and the goal. |
| 10 | Journal location | `.lanes/` folder in the repo by default; its own branch/worktree as an option. |
| 11 | Runtime | Bash + jq; no Node or Python at runtime. |
| 12 | Platforms | Linux, macOS, WSL with tmux. Native Windows, where Claude Code runs hooks through Git Bash, is supported only for plugins that need no tmux and pass the `windows` CI job (`lanes-plancheck` first; owner, 2026-10-23). The tmux plugins stay WSL-only on Windows. A plugin whose hooks run a Bash script is also WSL-only on Windows: exec-form hooks there need a real executable (hooks docs), and Claude Code itself is not exercised in CI, so `lanes-prodfence` is WSL-only on Windows in v0.1, while its suite still runs in the `windows` job as a portability check. |
| 13 | Tests | Script tests in CI (tmux in a container), a small `claude plugin eval` suite for the skills, `claude plugin validate --strict`. |
| 14 | Upstream ask | Filed after the plugin works. One issue proposes two small additions: context-window usage in hook input, and a hook output that can request `/clear` or `/compact`. It attaches a 60-second recording, real numbers from our runs, and links #50978, #27571 (of which #32811 is a duplicate), #96467 and #92853. Filing needs the owner's yes. |
| 15 | First users | The maintainers' own projects first, starting with the lowest-risk one. A project in the middle of a release keeps its own scripts until that release ships. |
| 16 | Builder | The planning session designs, a worker subagent builds, a reviewer subagent reviews. |
| 17 | Asking the human | Every decision goes to the human through the ask tool (`AskUserQuestion`): one question, its facts and costs, the recommended option marked. For a design tree the lead uses Matt Pocock's `grilling` skill (github.com/mattpocock/skills) when it is installed. lanes credits and links it and does not copy it. |
| 18 | Added to v0.1 | Away mode: while the human is away, the lead asks nothing with the ask tool and queues questions to a morning list; only the human's own message lifts it. Done-report form: a lane's done carries ripple, blast radius, pitfalls, edge cases with their tests, review verdicts and evidence paths, and the lead accepts only after reading the full diff. Journal drift check: compares journal rows with open PRs, branch heads and CI runs. |
| 19 | Not in v0.1 | Model tiering is not shipped as a rule. |
| 20 | Recipe pieces | `lanes-waves` is part of the lead/lane recipe and requires the core `lanes` plugin (it cites the core's RULES.md). The other optional pieces work alone. |
| 22 | Code vs goal-based | Hybrid. The hard core ships as tested code: the registry, clear handshake, locks, re-inject and guard command parser. A goal-based `/lanes:setup` skill asks about the project and generates its adapters: CI command, review gate, lead-only command list, test runner (local or CI), deny-list. Shipped contract tests must pass on whatever it generates. |
| 23 | Word check | The private deny-list check runs as a local git pre-push hook (`.githooks/pre-push`, installed by `scripts/install-hooks.sh`). CI does not run it, and there is no GitHub secret. |
| 24 | Repo and skill style | We adopt recommendations 1-12 of `research/mattpocock-skills-structure.md`, crediting mattpocock/skills (MIT): skill layout, the two description voices, the setup-skill phrasing, the README order, the two install paths, SCOPE.md, CREDITS.md and CHANGELOG.md. |
| 25 | PR review | Every PR gets the in-repo reviewer agent first, then Greptile through the owner's existing account, until it scores 5/5. The owner merges. |
| 21 | Plan fields | The plan template in `lanes-plancheck` is the single home of the required plan fields. The checker's default list comes from that template's headings, and skills point to it rather than listing fields. |
| 26 | Production fence | Production fence: a separate plugin, lanes-prodfence, works alone; every session including the lead is refused any tool call naming a configured production marker; only the human acts on production (owner, 2026-10-22). |
## Platform facts this rests on

These were checked against code.claude.com docs on 2026-10-22. They were then verified by experiment on 2.1.308 in
`M0-FINDINGS.md`, which wins on any difference.

- No hook receives live context usage. The statusline JSON has `context_window.used_percentage`.
- Nothing official runs `/clear` or `/compact` from a hook. A cross-session message carrying a slash command arrives as plain
  text.
- `SessionStart` matchers include `clear` and `compact`, and `PreCompact` can block compaction.
- Plugin layout: `.claude-plugin/plugin.json`, `skills/`, `agents/`, `hooks/hooks.json`, `bin/` (on PATH),
  `monitors/monitors.json` (experimental, interactive only), `userConfig`, `${CLAUDE_PLUGIN_ROOT}`,
  `${CLAUDE_PLUGIN_DATA}`.
