# done-<lane>

Finished units of lane `<lane>`, newest first, append-only. Each entry uses the done-report form below; the lead
accepts a unit only after reading its full diff, never from this report alone.

## Done-report form

```
### <ID> <one-line title> (<date>)
- Branch / head / PR: <branch> <sha> <PR link>
- What changed: <one or two lines>
- Ripple: <every caller, test, doc and config that described the old behaviour, and what happened to each>
- Blast radius: <who is hurt if this is wrong, and how fast>
- Pitfalls: <the common and the rare ways this can still go wrong>
- Edge cases: <each case, with the test that covers it>
- Review verdicts: <each review run and its verdict>
- Evidence: <paths to logs, test output and run links>
- Lead accepted: <date, after reading the full diff>
```

## Entries
