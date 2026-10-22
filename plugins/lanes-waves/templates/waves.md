# Wave settings

Copy this file to `.lanes/waves.md` and edit the values. The waves-lead and waves-lane skills read the value after each
"Setting" name. A blank value means the default. `<N>` is the wave number, `<theme>` a theme's short name.

## Branches

| Setting | Default | Meaning |
|---|---|---|
| base branch | `main` | The branch the wave merges into. |
| theme branch | `theme/w<N>-<theme>` | One branch per lane per theme. |
| integration branch | `int/w<N>` | Built by the lead from every theme branch. Merges once. |
| batch branch | `theme/w<N>-batch` | One branch for work that never ships to users (tooling, test-only, docs). |
| merge method | `--merge` | The `gh pr merge` flag. The lead pins the head with `--match-head-commit`. |

## Wave plan

| Setting | Default | Meaning |
|---|---|---|
| plan table | `.lanes/waves/W<N>.md` | The wave's rows: wave, theme branch, lane, items, depends-on. |
| item source | `.lanes/tracker.md` | The only place an item's state lives. Only items listed there enter a wave. |
| freeze | on | While a wave runs, the base branch takes only the integration PR and the batch branch. |

## CI

| Setting | Default | Meaning |
|---|---|---|
| ci command | `gh workflow run ci.yml --ref <branch>` | How the lead dispatches CI for one branch head. |
| ci status command | `gh run list --branch <branch> --limit 1 --json status,conclusion,headSha` | How the lead reads the verdict. |
| ci per head | one | One CI run per head. A fix-round head rides the rebuilt integration CI. |
| local gates | `.lanes/gates.md` | The commands a lane runs before it reports a head. Lanes run no whole-suite checks. |
| flake rule | rerun once | A job that fails before any test runs is rerun once. The same failure twice is a defect. |

## Review

| Setting | Default | Meaning |
|---|---|---|
| review gate | any reviewer | Who must have looked at a head before the merge: a bot, a reviewer agent, a person. Name the check or the command. |
| review request | a PR comment `@<reviewer> review` | How the lead asks for the review. |
| review scope | `all=**` | Review areas as `name=glob` pairs, comma separated. `all=**` opens one review PR for the whole wave. Split by area when the diff is too large for one review, for example `api=src/api/**,app=src/app/**`. |
| rescore rule | once per wave | A reviewed head is re-reviewed after fixes at most this often. |
| fix rounds | 2 | A third round that still finds blocking findings means re-plan. |
| blocking severity | P1, P2 | Findings that enter the fix round. Lower severities enter it only when they change behaviour, a test's power to fail, or a reader's understanding. |

## Builders

The lead may use a script for each job below. When a value is blank the lead performs the job with plain `git`.

| Setting | Default | Meaning |
|---|---|---|
| integration builder | plain git: merge each theme branch into a fresh branch from base | Builds the integration branch and names conflicting files and branches. |
| review builder | plain git and `gh`: one PR per area, base = reviewed head's parent | Opens and closes review-only PRs. |
| pr template | `.github/pull_request_template.md` | Integration PR body follows it. |

## Evidence

| Setting | Default | Meaning |
|---|---|---|
| wave report | `.lanes/reports/W<N>.md` | Tracked file that holds the merge evidence: gates, CI run, review verdicts, proof. |
| proof environment | none | Where the integration head is proven before merge (a staging deploy, a preview, a smoke run). Blank means CI is the proof. |
| proof owner | the lead | Who runs or requests the proof. |
