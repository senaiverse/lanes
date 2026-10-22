---
name: waves-lead
description: The lead's procedure for running a release wave end to end. Use when the lead cuts or starts a wave, assigns theme branches to lanes, builds or rebuilds the integration branch, dispatches CI or finds a run stuck, opens, triages or closes review PRs, runs a fix round, or merges the integration PR. Lead only; lanes use waves-lane.
---

# Waves: the lead

This skill requires the core `lanes` plugin and its `.lanes/RULES.md` (who may dispatch CI, merge or send a plan; the
clear handshake; journal files). Without them, stop and tell the user to install `lanes` first.

A wave turns a set of items into ONE merge. Each lane builds its theme on one branch. The lead merges the themes onto an
integration branch, reviews that head once through review-only PRs grouped by area, sends fixes back to the theme
branches, and merges the integration branch once. The lead plans and integrates; lanes write the code.

## Settings and rules, found at run time

- Project settings are in `.lanes/waves.md` (template: this plugin's `templates/waves.md`). Names in quotes below, such
  as "ci command", are settings there. A blank setting means its default. When the file is missing, copy the template
  and tell the user before the first step.
- Mechanism rules (who may dispatch CI and merge, who may message a plan, the clear handshake, journal files) are in
  `.lanes/RULES.md`. This skill cites them and never restates them. When this skill and RULES.md disagree, follow RULES.md
  and report the skill as stale.
- Item state lives in the "item source" file only. Every other file points to it.
- Run any project script with `--help` before its first use in a session.

## The wave, in order

Each step ends on a done-when. Start the next step only after it holds.

### 1. Cut the wave

Write the wave's rows into the "plan table": wave | theme branch | lane | items | depends-on.

- Take items from the "item source" only. An item the user has not ruled into the wave stays out.
- One theme branch per lane per theme.
- Two items that touch one file sit in one theme, or in two rows whose depends-on says which lands first.
- Announce the freeze (the "freeze" setting) to every lane.

Done when every item is in exactly one row, every known file crossing is ordered by depends-on, and each lane has been
told its branch and items.

### 2. Plan every item, then hand it over

The lead writes every plan. A lane confirms it in code and builds it. The plan follows the `lanes-plancheck` plugin's
`templates/plan.md`, the single home of the required fields; a project may override them in `.lanes/plan-fields`.

Read every premise in code before sending. Run `lanes-plancheck` on the plan; the plan is sent only after it passes. A plan the code contradicts is redesigned, never approved with conditions. A lane's message that the code
disagrees comes back to the lead, who decides. A lane's "check and plan <ID>" gets a plan back. A value that belongs to
the user (a limit, a price, a retention, what a customer sees) is marked OPEN and asked of the user with the facts.

Done when every item has a plan and every report back has a decision.

### 3. Theme CI, once per head

When a lane reports "theme done", check the report before dispatching. It needs the head SHA, which contains current
base; the gates' last lines; review verdicts; and the lane's ripple, blast radius, pitfalls and edge cases. A report
without them goes back.

- Dispatch with the "ci command" on the theme branch and that sha. Lanes never dispatch (RULES.md).
- A theme's first done head gets one CI. A fix-round head gets none and rides the rebuilt integration CI.
- Start CI on a head only after every review of that head is finished.
- Keep a dispatch queue in the lead's journal file, ordered by critical path: theme heads first, then the batch. Fill a
  free CI slot as soon as it frees.
- A dispatcher refusal is the rule working. Wait. Never start a second run on one branch.
- Give an idle lane its next unblocked item in the same message that hands over a head. A lane waits on nothing.

Done when every theme head has a green verdict.

**Batch work that never ships to users.** Tooling, test-only and docs items go into the "batch branch", read or reviewed
first, with one CI and one merge. A rebuilt batch gets a new branch name; never force-push over the old one. Give the
batch a full review only when it touches money, sign-in, data deletion or the command guard.

**A merged batch moves the base under the integration branch.** Before merging one mid-wave, build the integration
branch locally and check the themes still merge. Never cancel a running integration CI before the rebuild is proven.

### 4. Integrate

Run the "integration builder". It merges the theme rows in depends-on order onto a fresh branch from base.

- On a conflict it names the files and both branches. The lane that owns the later row resolves it on its own theme
  branch. If depends-on was wrong, reorder the table. Then rebuild.
- Read the wave's total line count and pass it to the user.
- A rebuild whose tree differs from the dispatched one is a new CI run. Push, then dispatch once every review of the head
  is finished.

Done when the integration branch holds every theme row, is pushed, and its CI is green.

### 5. Review once per wave

Open review-only PRs on the integration head, grouped by "review scope". With `all=**` that is one PR carrying the
whole wave. A review-only PR is never merged.

1. Give the user the line count per area before opening.
2. Before the "review gate" runs, one reviewer agent reads the head's full diff for reuse, simplification and dead code.
   Each real finding goes to the owning theme's fix round.
3. Open the PRs with the "review builder" or plain `gh`, and request the review with "review request". Check that the
   files are in the reviewer's scope first.

Done when every area has an open review PR with its review requested.

### 6. Triage

Give each finding one verdict, with evidence:

- Real: file:line that shows the failure. Run a root-cause pass naming cause, edge cases, ripple, blast radius.
- Not a bug: file:line that shows why.

The round carries every finding at or above "blocking severity". Lower findings go in the integration PR body. Each real
finding goes to the theme branch that owns the file, as one fix round per wave. A fix removes the cause. A fix that adds
a guard, flag, state value, counter, retry, lock or timeout goes back unless the lane shows in code why the cause
stays.

Done when every thread has a verdict with evidence, and every real finding has an owning lane and a named red test.

### 7. Fix round

Lanes fix red first and review their own fix diff. A fix-round head gets no theme CI; it rides the rebuilt integration
CI.

- A re-review of a fix follows the "rescore rule": all fixes of the round in one review-only PR whose base is the
  reviewed integration head and whose head is a child of that base (`git commit-tree <rebuilt head>^{tree} -p <reviewed
  head>`), because a rebuilt head's merge base is the base branch and its PR would show the whole wave.
- Work that never ships belongs in the batch, not in a round.
- A round past "fix rounds" with new blocking findings means re-plan: split or redesign. Never run another.

Done when every fix is reviewed at its tier and the rebuilt integration CI is green.

### 8. Prove, then merge once

1. Rebuild, push, open the integration PR (integration branch into base) from the "pr template", and run one CI on the new
   head. A dispatch before the PR exists can pass where the PR's own run fails.
2. If "proof environment" is set, hand that head to the "proof owner" and wait for the result. A change that claims a
   speed or capacity gain stays off base until its measured number exists.
3. Write the evidence into the "wave report" before merging: gates with counts, the CI run, review verdicts, the proof,
   what was not run. The PR body links it.
4. Merge pinned: `gh pr merge <n> <merge method> --match-head-commit <sha>`.
5. Close the review PRs with a comment naming the merge. Record the merge commit as the wave's `Batch base:`, and update
   the item rows in the "item source".

Done when the evidence is in the PR and the report before the merge, base holds the merge, the review PRs are closed,
and the item rows name the merge commit.

## CI that is stuck or red

- Stuck (queued with no runner, a lost build): read the run's branch and head, then cancel and re-run only that run.
- Red: a failure is a finding with a root cause. Apply the "flake rule"; never retry until green and never raise a
  timeout as the fix.

## Each tick

1. Check the item source for rows that name merged work but are still open, and close them.
2. Check for unreviewed merges: code that ships, merged since the last `Batch base:` with no review PR, means a review
   batch is owed. Build one.
3. Close any review PR whose fix has merged.
4. Answer every pending lane confirmation before anything else. Then read each lane's open-work file for blocked items.

## Approvals

Which calls the lead decides, which go to the user and which arrive as notices is in `.lanes/RULES.md`. This skill does
not restate it. A call RULES.md does not cover goes to the user.

## Context and clearing

At the clear threshold (RULES.md), run the handshake for each lane and for the lead. Before the lead's own clear, write the
lead's RESUME: each lane's branch, head, CI state and next step. Rewrite the block in place.

## Guardrails

- Lanes build; the lead reviews, integrates and merges. The lead writes code only in work that never ships.
- Deployed code reaches base only through the integration PR.
- Report outcomes in this order: what is broken, blocked or not done; then size trend; then progress. A number given to
  the user comes from the newest verified report, with its file:line.
- Search for a build, a record or a doc before telling the user it does not exist.
