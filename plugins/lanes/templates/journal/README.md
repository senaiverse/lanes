# Journal

The durable state of a lanes project: what each session is doing, what is next, and what is done. Sessions read and
write these files; a cleared lane resumes from its RESUME block. The rules are in `RULES.md`.

| File | Written by | Holds |
|------|------------|-------|
| `RULES.md` | nobody (template) | The mechanism rules every session follows |
| `tracker.md` | lead, and each lane for its own rows | Every item's state, one row per item |
| `next-<lane>.md` | that lane | Open work and ONE RESUME block |
| `done-<lane>.md` | that lane | Finished units in the done-report form |
| `morning.md` | lead | Questions queued for the human while away mode is on |
| `adapters.md` | `/lanes:setup` | This project's CI, review gate and tests; `lanes check-adapters` checks it |

`/lanes:setup` creates these files and a new lane's files; it never overwrites a file that exists. Commit the journal
like code: `lanes clear-ready` refuses a lane whose tree is dirty or whose head is not pushed.
