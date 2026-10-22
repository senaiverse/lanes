---
name: waves-lane
description: A lane's procedure for building its theme branch in a release wave. Use when a lane starts or resumes wave work, receives the lead's plan, finishes a fix, needs a review or CI, gets review findings on its theme, or hits an integration conflict. Lanes only; the lead uses waves-lead.
---

# Waves: a lane

This skill requires the core `lanes` plugin and its `.lanes/RULES.md` (who may dispatch CI, merge or send a plan; the
clear handshake; your journal files). Without them, stop and tell the lead.

Your wave work is ONE theme branch, named in the wave's "plan table" with its items in order. You build, test and review
on it. The lead merges it with the other themes onto the integration branch and merges once. You write your theme
branch, your own journal files and your own item rows. Everything else is the lead's.

## Settings and rules, found at run time

- Project settings are in `.lanes/waves.md`. Names in quotes below, such as "local gates", are settings there.
- Mechanism rules (who may dispatch CI, merge or send a plan; the clear handshake; your journal files) are in
  `.lanes/RULES.md`. Follow them; this skill does not restate them.
- Run any project script with `--help` before its first use in a session.

## Per item, in order

### 1. Read the goal

Read the item's row in the "item source" and the rulings it cites. Done when you can state the outcome in one sentence
and name the ruling behind each requirement.

### 2. Confirm the lead's plan in code

The lead plans every item. You confirm each premise with file:line and build inside the plan's limits.

- When the code disagrees, stop and send the lead the evidence. The lead decides. You never redesign.
- An item with no plan, or a gap the plan leaves, goes to the lead as "check and plan <ID>" with the file:line facts.
- A layer, a second home for one fact, or custom code where an installed library or the platform already does the job
  goes back to the lead.
- Your reply is facts only, each with evidence or "none, because ...":
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
- Check every load-bearing fact in code or a primary document. Mark `UNVERIFIED` only what cannot be read, and keep that
  mark in your reply or the journal, never in a source comment.

Done when the lead has said go.

### 3. Red first

Write the failing test at the public seam and run it. Record the failing assertion. Done when it fails for the reason the
item names. One test per rule, on behaviour a caller sees. When a change deletes a mechanism, delete the tests that pin it.

### 4. Build and gate each commit

Make the smallest change that turns the test green. Then run the "local gates" for the commit. Done when every gate's
last line is green.

### 5. Simplify, then review

1. Run a simplify pass on the branch diff against the base branch.
2. Run a review on the same diff with a reviewer agent.
3. Give each finding a verdict, real or not a bug, with file:line evidence. Send the lead the review output verbatim
   with your verdicts.
4. Wait for the lead's yes on every verdict that dismisses, skips or defers a finding. A real finding's fix list goes to
   the lead as a notice and you start it.

Done when every finding has a verdict the lead confirmed and every approved fix is in.

### 6. Theme done

Merge the current base branch into your theme branch. Push it. Tell the lead "theme done" with:

- the head SHA,
- the last line of each gate,
- the review verdicts,
- ripple, blast radius, pitfalls, and edge cases with their tests.

The same applies to every fix-round head. The lead dispatches CI ("ci command"); you never do (RULES.md). While CI runs,
take the next item the lead gives you.

Done when the lead has your head and the CI verdict on it.

## When the lead sends findings or a conflict

- **Review findings on your theme.** Give each one a root-cause pass (cause, edge cases, ripple, blast radius), then a red
  test, the fix on your theme branch, a review of the fix diff, and steps 4 to 6. There is one fix round per wave. Fix the
  class of the finding: search every sibling site, not only the flagged line. A fix removes the cause. A fix that adds a
  guard, flag, state value, counter, retry, lock or timeout carries a `Why not remove the cause:` line that holds in
  code, or the lead sends it back. A finding below "blocking severity" is fixed only when it changes behaviour, a test's
  power to fail, or a reader's understanding.
- **CI stuck or red on your branch.** A stuck run goes to the lead with the run id. A red run is a finding: diagnose it
  red first, then send the lead the fixed head.
- **Integration conflict.** The lead names the files and the other branch. Resolve it on your theme branch and keep both
  sides' behaviour. Add a test for the combined behaviour when the conflict is in code. Your branch stays off the base
  branch; the integration branch is the only place the base and the themes meet.
- **A contract changed by a fix** (a function's result shape, a status value). Search the tests for every assertion on it
  before you push.

## Your calls and the lead's calls

Which calls need the lead's yes and which go as one-line notices is in `.lanes/RULES.md`; this skill does not restate
it. Log each call as one line in your journal file. While a yes is pending, take your next item.
Never wait idle: before you stop, send the lead one message with what you finished, what you wait on, and "next item?".

## Guardrails

- The lead opens PRs, requests reviews, dispatches CI, integrates and merges. You deliver a reviewed, gated theme head.
- Your tooling, test-only and docs items go into the lead's batch branch, not into their own runs.
- Other lanes' files and branches are theirs. The plan table, the item source and the rulings are the lead's.
- A subagent of yours creates its report file early and appends as it goes. Resume a stopped one; never relaunch it from
  zero. Verify its claims in code before you act on them.
- Keep your journal files and item rows synced at every step. Clearing follows the handshake in RULES.md.
