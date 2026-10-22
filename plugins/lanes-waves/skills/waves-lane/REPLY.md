# Waves lane: the reply to the lead's plan

Your reply is facts only, each with evidence or "none, because ...":

- Premises: each confirmed or contradicted, with file:line.
- Tests: the red tests you wrote, one per listed behaviour.
- Pitfalls in your diff, common and rare.
- Edge cases your diff handles beyond the plan's list: empty, null, duplicate, concurrent, out of order, timed out,
  partial failure, interrupted. Each has its test.
- Ripple: `git grep -l <name> -- <subtree>` for every name you add, change or remove, plus the docs and journal rows
  that describe the old behaviour. A list from memory is not a ripple.
- Blast radius: who is hurt if this is wrong, how fast it shows, how reversible it is.
- Compounding: how this combines with your other items and the other themes of the wave.
- Proof and undo: the evidence that it works and the exact undo.

Check every load-bearing fact in code or a primary document. Mark `UNVERIFIED` only what cannot be read, and keep that
mark in your reply or the journal, never in a source comment.
