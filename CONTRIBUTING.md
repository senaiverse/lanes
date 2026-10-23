# Contributing

Read [`SCOPE.md`](SCOPE.md) first: it says what lanes takes. The rules below are short; the binding ones are in
[`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).

## Set up

Run `scripts/install-hooks.sh` once per clone. It points git at `.githooks`, whose pre-push hook runs the private word
check (`scripts/deny-gate.sh`). CI does not run that check, so the hook is the only gate. Never commit private names:
no product names, hosts, IDs, emails or journal content, in files, authors or commit messages.

## Test

- Write the failing bats test first, then the smallest change that passes.
- `scripts/test.sh` runs shellcheck, then every suite. It fetches pinned bats and shellcheck into `.tools` on the
  first run.
- `scripts/test.sh tests/lanes-plancheck` runs one suite, and shellchecks only the plugin of the same name.
  Pass several directories to run several.
- A test that runs longer than 120 seconds fails. Set `BATS_TEST_TIMEOUT` to change the limit.
- Tests use a private tmux socket and a temporary `LANES_DATA_DIR`. They never touch your tmux server.

## Code

- Bash 4+ and jq only. Every `bin/` script checks the Bash version first and stops with a one-line message on Bash 3.2
  (`tests/scaffold/bash-version.bats` enforces it).
- A comment states the rule and its reason in three sentences or fewer.

## Decisions and conventions

`docs/DECISIONS.md` and `docs/CONVENTIONS.md` change only through a docs-only pull request, never inside a feature
pull request (decision 25).

## Review

Every pull request goes to the `lanes-review` reviewer agent first. Then Greptile reviews it, and it merges once
Greptile scores 5/5 and CI is green on every job (decision 25). A docs-only pull request merges on green CI; read any
Greptile comment on it anyway.
