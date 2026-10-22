---
name: guards
description: Explains why a lanes guard refused a tool call (lead-only command, plan message, edit in the main checkout) and how to configure the guards. Use when a call is refused with "lanes-guards rule", or when setting the guards up for a project.
---

# lanes guards

Three PreToolUse hooks protect a lead-and-lanes setup. Each refusal names its rule and the allowed path. Obey it; do not
rephrase the command to get past the guard.

## The rules

| Rule | Refused | Allowed path |
|---|---|---|
| `lead-only` | A Bash command matching `lead_only_commands` (default `gh workflow run`, `gh pr merge`, and every `git push` but the explicit form below) from a lane | Push explicitly: `git [-C <dir>] push [-u] [--force-with-lease[=...]] <remote> <your-branch>`, where the branch is a non-default `<name>:<name>`, or a plain `<name>` when git config cannot remap it (see below). For anything else, message the lead with the branch and the exact command; the lead runs it |
| `plan-message` | A `SendMessage` starting with the plan marker (default `PLAN:`) from a lane | Send the lead facts: file:line, what you ran, what you ruled out |
| `main-edit` | Edit, Write, NotebookEdit on a path in the main checkout while lanes work in linked worktrees | Edit the same file under your own worktree |

The guard finds you by session id: `${LANES_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lanes}/sessions/<session_id>` holds
your lane name, and `lanes/<lane>.json` holds your role. `lanes register` writes both on every SessionStart (hooks other
than SessionStart receive no session title). A session with no entry is refused for a matching command: launch it with
`claude --name <lane>` and run `lanes register`.

## Configure

Copy `templates/guards.md` to `.lanes/guards.md` in the project. Precedence: `.lanes/guards.md`, then the plugin's
userConfig, then the defaults. Every key in the template is also a userConfig option (`lead_only_commands`,
`plan_marker`, `main_checkout_guard`, `lead_exempt_main_checkout`, `default_branch`); the hooks receive it as
`CLAUDE_PLUGIN_OPTION_<KEY>`. `main_checkout_guard: on` enables the third rule; it is off until a project turns it on.

## What it does not do

- A lane's `git push` passes only in the explicit form above. A push with no refspec, `--all`, `--mirror`, `--repo`,
  `--delete`, a glob, `HEAD`, `+`, `:`, several refspecs, another option, or a word with `$` is refused rather than
  predicted, because git config or the checkout decides what it pushes.
- git maps a plain `<name>` through `remote.<remote>.push`, `push.default=upstream` (or `tracking`) and a symref
  branch, so the plain form passes only when none of those is set in the target checkout (`-C` dir, else the session
  directory) and the command has no `GIT_CONFIG_*` prefix. Otherwise use `git push <remote> <name>:<name>`, which
  passes unless `<name>` is a symref to the default branch. A config change made earlier in the same command line, or
  an exported `GIT_CONFIG_*` variable, is not seen.
- It parses `&&`, `;`, `|`, env prefixes, `bash -c`, `eval`, `$(...)`, backticks, quotes (`$'...'` decoded) and line
  continuations. It reads a script fed to a shell by its own heredoc or here-string, a piped bare `cat` heredoc or a
  piped `echo` of literal words. Any other producer (`printf`, `cat file`, `curl`) is refused when its text names a
  lead-only command, and otherwise passes. It does not follow a variable it cannot resolve, `ssh`, `find -exec`, a
  script file or process substitution. It is a mistake guard, not a sandbox.
- Value-taking global flags are known for `gh` and `git` only.
- Malformed hook input passes with a stderr note, unless the text still names a lead-only command. The same holds when
  `jq` is not installed: a call naming a lead-only command is refused (exit 2), anything else passes with a note.
- Destructive commands (`rm -rf`, `git reset --hard`) are not covered: use destructive_command_guard or cc-safety-net.
