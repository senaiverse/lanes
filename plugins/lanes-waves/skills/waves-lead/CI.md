# Waves lead: CI queue, stuck or red runs, and the batch

Read this before you dispatch, queue or cancel a run, and before you merge or rebuild the batch.

## Dispatch queue

- Keep the queue in the lead's journal file, ordered by critical path: theme heads first, then the batch. Fill a free CI
  slot as soon as it frees.
- A dispatcher refusal is the rule working. Wait. Never start a second run on one branch.

## CI that is stuck or red

- Stuck (queued with no runner, a lost build): read the run's branch and head with the "ci status command", then cancel
  and re-run only that run.
- Red: a failure is a finding with a root cause. Apply the "flake rule"; never retry until green and never raise a
  timeout as the fix.

## Batch work that never ships to users

Tooling, test-only and docs items go into the "batch branch", read or reviewed first, with one CI and one merge. A
rebuilt batch gets a new branch name; never force-push over the old one. Give the batch a full review only when it
touches money, sign-in, data deletion or the command guard.

## A merged batch moves the base under the integration branch

Before merging one mid-wave, build the integration branch locally and check the themes still merge. Never cancel a running
integration CI before the rebuild is proven.
