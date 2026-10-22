# CLAUDE.md — lanes

lanes is a Claude Code plugin marketplace for running several Claude sessions in tmux: a lead, lanes, a journal, and
clear-and-resume. This file routes you to the documents that hold the rules; it does not restate them.

| Need | Go here |
|---|---|
| What lanes is, and every settled decision | `docs/DECISIONS.md` |
| Build order and milestone scope | `docs/PLAN-v0.1.md` |
| Code, state, test and process conventions (binding) | `docs/CONVENTIONS.md` |
| Verified Claude Code platform facts | `docs/M0-FINDINGS.md` |
| Prior art and the failure modes we test for | `docs/research/` |

## Working here

- Runtime is Bash and jq only. Each plugin lives under `plugins/<name>/` and is listed in `.claude-plugin/marketplace.json`.
- Write the failing bats test first, then the smallest change. `scripts/test.sh` runs shellcheck and every suite;
  `scripts/validate.sh` runs `claude plugin validate --strict`; `scripts/deny-gate.sh` must report clean.
- Tests use a private tmux socket and a temp `LANES_DATA_DIR`. Never touch the user's tmux server.
- Nothing from any product project goes into this repo: no names, hosts, IDs, emails or journal content.
- A comment states the rule and its reason in three sentences or fewer.
- A decision changes only in `docs/DECISIONS.md`. Code that disagrees with a doc is a bug in one of them; fix both in
  the same change.
