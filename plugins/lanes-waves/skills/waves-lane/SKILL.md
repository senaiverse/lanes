---
name: waves-lane
description: A lane's procedure for building its theme branch in a release wave. Use when a lane starts or resumes wave work, receives the lead's plan, finishes a fix, needs a review or CI, gets review findings on its theme, or hits an integration conflict. Lanes only; the lead uses waves-lead.
---

# Waves: a lane

This skill requires the core `lanes` plugin and its `RULES.md` in the journal folder (`lanes journal-dir`). Without them,
stop and tell the lead.

Your wave work is ONE theme branch, named in the wave's "plan table" with its items in order. You build, test and review
on it. The lead merges it with the other themes onto the integration branch and merges once. You write your theme
branch, your own journal files and your own item rows. Everything else is the lead's.

## Settings and rules, found at run time

- Project settings are in `waves.md` in the journal folder (`lanes journal-dir`). Names in quotes below, such as "local
  gates", are settings there.
- Mechanism rules are in `RULES.md` there. This skill cites them by number and never restates them.
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
- Write your reply in the form of [REPLY.md](REPLY.md): facts only, each with evidence or "none, because ...".

Done when the lead has said go.

### 3. Red first

Write the failing test at the public seam and run it. Record the failing assertion. Done when it fails for the reason the
item names. One test per rule, on behaviour a caller sees. When a change deletes a mechanism, delete the tests that pin it.

### 4. Build and gate each commit

Make the smallest change that turns the test green. Then run the "local gates" for the commit. Done when every gate's
last line is green.

### 5. Simplify, then review

1. Call the Skill tool with "simplify" on the branch diff against the base branch.
2. Delegate to the lanes-review:reviewer agent to review the same diff.
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

The same applies to every fix-round head. CI is the lead's (RULES.md rule 13). While CI runs,
take the next item the lead gives you.

Done when the lead has your head and the CI verdict on it.

## When the lead sends findings or a conflict

Read [FIXES.md](FIXES.md) for review findings on your theme, a CI run stuck or red on your branch, an integration
conflict, and a contract a fix changed.

## Your calls and the lead's calls

A verdict that dismisses, skips or defers a finding needs the lead's yes (step 5); a fix list goes as a notice. Questions
for the human go to the lead (RULES.md rule 10). Log each call as one line in your journal file. While a yes is pending,
take your next item. Before you stop, send the lead the message RULES.md rule 12 asks for, with "next item?".

## Guardrails

- The lead opens PRs, requests reviews, dispatches CI, integrates and merges. You deliver a reviewed, gated theme head.
- Your tooling, test-only and docs items go into the lead's batch branch, not into their own runs.
- Other lanes' files and branches are theirs. The plan table, the item source and the rulings are the lead's.
- A subagent of yours creates its report file early and appends as it goes. Resume a stopped one; never relaunch it from
  zero. Verify its claims in code before you act on them.
- Keep your journal files and item rows synced at every step. Clearing follows the handshake in RULES.md rule 6.
