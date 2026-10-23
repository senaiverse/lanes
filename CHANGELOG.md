# Changelog

lanes has no release yet. This list is what is on `main` today (up to `a357a96`).

## Unreleased

### lanes-plancheck

- `lanes-plancheck <plan-file>` checks that a plan file carries its required fields. The fields are the level-2
  headings of the plugin's `templates/plan.md`, and a project can override them with `.lanes/plan-fields`.
- A `plancheck` skill says when to run it.

### lanes-jobs

- `lanes-job` runs a long command in a pooled tmux window and reports the result in a STATUS file. Subcommands: `run`,
  `status`, `wait`, `list`, `slot`.
- A machine-wide pool caps how many heavy jobs run at once across sessions.
- A `jobs` skill says when to use it, and when a native background command is enough.

### lanes-review

- A `reviewer` agent reviews a branch range or a pull request. It is instructed not to edit, and it is not sandboxed.
- The agent says when to delegate a review to it.

### lanes-prodfence

- `lanes-prodfence` hooks refuse a session's tool call that mentions a configured production marker, or that touches a
  protected path. Only the human acts on production.
- It fails closed: a broken config, a missing `jq` or malformed input blocks the call.
- A `prodfence` skill explains a refusal, and `SETUP.md` explains how to choose markers.
- WSL-only on Windows.

### Repository

- `scripts/test.sh` runs shellcheck and the bats suites, fetching pinned tools into `.tools`. A test that runs longer
  than 120 seconds fails.
- `scripts/deny-gate.sh` and the pre-push hook check files, and also commit authors, committers and messages, against a
  private word list.
- CI runs the suites on Linux and macOS, and on native Windows for the plugins supported there (`lanes-plancheck`).
- A contract test checks every skill and agent.
- The test tmux socket path stays under macOS's 104-byte limit.
- Docs: `docs/DECISIONS.md`, `docs/PLAN-v0.1.md`, `docs/CONVENTIONS.md`, `docs/M0-FINDINGS.md`, prior-art research, a
  plain-words README with badges, a plugin icon and a social preview image.

Not yet available: the core `lanes` plugin, `lanes-guards` and `lanes-waves`.
