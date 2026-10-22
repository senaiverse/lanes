# Conventions every lanes piece follows

`DECISIONS.md` says what and why. `PLAN-v0.1.md` says the order. This file is the shared contract between pieces.

## Code

- Runtime is Bash 4+ and jq only. Scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`, and must pass shellcheck.
  macOS ships Bash 3.2, so the README tells users to install Bash 4+. Scripts use no GNU-only flags (`sed -i`, `readlink -f`,
  `date -d`, `stat -c`); prefer portable forms. Every `bin/` script fails fast on Bash < 4 with a one-line check placed
  before `set -euo pipefail`. `tests/scaffold/bash-version.bats` enforces it.
- Every executable lives in a plugin's `bin/`, which Claude Code puts on PATH. Name it `lanes` or `lanes-<piece>`.
- Code paths come from `${CLAUDE_PLUGIN_ROOT}` in hooks, and from the script's own location (`$0`) in `bin/`.
- State lives in one directory shared by every lanes plugin, hooks and `bin/` alike:
  `DATA="${LANES_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lanes}"`. `${CLAUDE_PLUGIN_DATA}` is not used, for
  two reasons. It is absent from the Bash tool's environment (docs "Where each variable resolves"; lanes-jobs probe).
  It also differs per plugin, so one plugin could not read another's registry.
- Failures are loud and specific. Print `lanes-<piece>: <what failed>: <what to do>` to stderr with a non-zero exit. A
  refusing guard names the rule and the allowed path.
- State writes are atomic: write a temp file in the same directory, then `mv`.
- Comments state the rule and its reason in three sentences or fewer.

## State

- Session registry: `$DATA/lanes/<lane>.json` holds
  `{"lane":"<name>","session_id":"<current>","role":"lead|lane","tmux_pane":"%N","cwd":"<abs>","used_pct":<int|null>,"clear_ready":<bool>,"updated_at":"<ISO-8601 UTC>"}`.
  It is keyed by lane name because `/clear` rotates `session_id`. Every session is launched as `claude --name <lane>`,
  and the lane name is the hook input's `session_title` (`docs/M0-FINDINGS.md` Q2, Q4). The core plugin owns this
  file. Other pieces only read it.
- The registry also records `tmux_pid` and `pane_pid` at register, so `lanes clear` can prove the pane still holds
  that session after a tmux or host restart reuses the pane id.
- Core working state: `$DATA/lanes/state/` holds `<lane>.json` (activity, handshake record), `config.json` (plugin
  options the hook records for `bin/`, which cannot see userConfig) and `away.json`. `$DATA/monitors/` holds each
  watcher's single-instance lock and last-seen state. The core plugin owns both.
- Hook commands call `"${CLAUDE_PLUGIN_ROOT}/bin/<tool>"` by absolute path, because `bin/` is not on PATH for hooks
  (M0 Q5). Skills and agents call the bare name.
- Slot locks: `$DATA/locks/<pool>-<i>.lock`, a symlink whose target is the holder's pid. Creating it is atomic, and a
  dead holder's lock is replaced on the next acquire. A slot outlives one process (separate `acquire` and `release`
  calls), which a flock cannot express. A short mutex guards each lock decision, the same on every platform so every
  caller excludes every other: a symlink `$DATA/locks/.mutex.owner` → holder pid, created with one `ln -s`, so no
  mutex exists without its owner, and a waiter breaks it only when that owner is dead.

## Layout and tests

- Plugins live under `plugins/<name>/` and each has `.claude-plugin/plugin.json`. The root
  `.claude-plugin/marketplace.json` lists exactly the plugins that exist; `tests/scaffold/marketplace.bats` enforces it.
- Tests: bats-core suites in `tests/<plugin>/*.bats`, run by `scripts/test.sh`. That script fetches pinned bats-core and
  shellcheck into the gitignored `.tools/` when they are missing. Write the failing test first. Tests use a temp
  `LANES_DATA_DIR` and their own tmux socket (`tmux -L lanes-test-$$`), and never touch the user's tmux server.
- `scripts/deny-gate.sh` fails when the path or contents of a tracked or untracked non-ignored file contain a word from the
  private deny-list. It reads the list from
  `docs/PORT-SOURCES.local.md` when that file is present, or from `LANES_DENY_LIST` otherwise. It runs as the local
  pre-push hook, not in CI (DECISIONS 23). The hook also checks the author, committer and message of every commit being
  pushed (`deny-gate.sh --commits`).

## Process

- Workers write files only inside their owned paths. They never commit. The planning session reviews and commits.
- No product names, hosts, IDs or emails from any source project.
