---
name: guards
description: Explains why a lanes guard refused a tool call (lead-only command, plan message, edit in the main checkout) and how to configure the guards. Use when a call is refused with "lanes-guards rule", or when setting the guards up for a project.
---

# lanes guards

Three PreToolUse hooks protect a lead-and-lanes setup. Each refusal names its rule and the allowed path. Obey it; do not
rephrase the command to get past the guard.

- `lead-only`: from a lane, a Bash command whose text names every word of a `lead_only_commands` pattern, anywhere
  and however quoted (default `gh workflow run`, `gh pr merge`, `git push @default`). It passes only when the guard
  proves each mention is text (a commit message, a gh pr or issue title or body, an echo, printf or cat, a grep or rg
  pattern, each with no pipe, redirection or substitution taking its output) or, for `git push @default`, the one lane
  push: `git [-C <dir>] push [-u] [--force-with-lease[=...]] <remote> <branch>`
  with one non-default branch, plain or as `<name>:<name>`, as its own command, after at most one leading
  `cd <absolute path> &&`.
- `plan-message`: from a lane, a `SendMessage` that starts with the plan marker (default `PLAN:`).
- `main-edit`: Edit, Write or NotebookEdit on a path in the main checkout while lanes work in linked worktrees.

A lane in a checkout whose `origin` head is `main`:

```
git push origin my-feature     # passes
git push origin main           # refused with:
lanes-guards rule lead-only: this `git push` form is lead-only: a lane pushes only one named non-default branch. This session is lane "lane1" (role lane), not the lead. Allowed path: push explicitly: git push <remote> <your-branch> (with -u or --force-with-lease if needed), as its own command or after one leading cd; ask the lead for any other push, or change lead_only_commands in .lanes/guards.md
```

The guard finds you by session id: `${LANES_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lanes}/sessions/<session_id>` holds
your lane name, and `lanes/<lane>.json` holds your role. `lanes register` writes both on every SessionStart (hooks other
than SessionStart receive no session title). A session with no entry is refused for a matching command: launch it with
`claude --name <lane>` and run `lanes register`.

## Configure

Copy `${CLAUDE_PLUGIN_ROOT}/templates/guards.md` to `.lanes/guards.md` in the project. Precedence: `.lanes/guards.md`,
then the plugin's userConfig, then the defaults. Every key in the template is also a userConfig option
(`lead_only_commands`, `plan_marker`, `main_checkout_guard`, `lead_exempt_main_checkout`, `default_branch`); the hooks
receive it as `CLAUDE_PLUGIN_OPTION_<KEY>`. `main_checkout_guard: on` enables the third rule; it is off until a project
turns it on.

What the guards do not catch, and which push forms are refused rather than predicted:
`${CLAUDE_PLUGIN_ROOT}/skills/guards/LIMITS.md`.
