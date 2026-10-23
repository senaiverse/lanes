# Watchers

A watcher observes and reports; poll with the Monitor tool and wait with the loop's own sleep. Run each one as one
long-running command through the Monitor tool, so every line it prints reaches you as an event; acting on it is your
job.

## Rules every watcher follows

- **One watcher per signal:** CI, review score, lane context, journal drift. Never chain two waits in one script.
- **Endless and complete:** each pass re-reads the whole set (every open PR, every registered lane), and the loop never
  exits on an event. `gh pr list` returns 30 items by default, so every call passes `--limit 1000`.
- **Changes only:** the pass pipes `<item><TAB><state>` lines into `lanes monitor-diff <name>`, which prints only the
  items whose state changed and keeps the last set under the lanes data dir (`monitors/<name>.state`).
- **One instance per name:** the loop starts with `lanes monitor-lock <name> $$`, which refuses a second start while
  the first is alive and reclaims the name from a dead one.
- **Back off, never die:** when `gh` fails, skip the diff for that pass (a partial set would report items as gone),
  print one line, double the wait up to 10 minutes, and keep looping.
- **Start:** at the start of each lead session. The SessionStart context lists every watcher that is down (all four on
  a fresh install); start those. Starting one that is already running is harmless: it prints a refusal and exits.
- **Stop:** stop the Monitor when the human ends the session. Nothing else stops a watcher.

Bash and Git Bash run the loops as written (Git Bash needs `jq` and `gh` on its PATH). PowerShell: `lanes` is a Bash
script, so save the loop as a `.sh` file in your scratch folder and run `bash <file>`; quoting jq inside PowerShell
breaks easily.

## The loop shape

Every watcher below is this loop with its own name, interval and `pass` command:

```bash
name=ci every=60                     # the watcher's name and its interval in seconds
lanes monitor-lock "$name" $$ || exit 0
wait_s=$every failing=0
while :; do
  if out="$(pass)"; then
    printf '%s\n' "$out" | lanes monitor-diff "$name"
    wait_s=$every failing=0
  else
    ((failing)) || echo "$name: gh failed; retrying with back-off"
    failing=1 wait_s=$((wait_s * 2 > 600 ? 600 : wait_s * 2))
  fi
  sleep "$wait_s"
done
```

Define `pass` above the loop, as a function, from one of the four sections that follow.

## 1. CI runs (name `ci`, every 60 s)

```bash
pass() { gh pr list --state open --limit 1000 --json number,headRefOid,statusCheckRollup --jq '.[] | "#\(.number)\t\(.headRefOid[0:7]) \(
  [.statusCheckRollup[] | (.conclusion // .state // .status // "") | ascii_downcase] |
  if length == 0 then "no checks" elif any(. == "failure" or . == "error" or . == "timed_out" or . == "cancelled")
  then "failing" elif all(. == "success" or . == "skipped" or . == "neutral") then "passed" else "running" end)"'; }
```

It reports `#12: 3f2a1c0 running -> 3f2a1c0 failing`. Read the failed run with `gh run view <id> --log-failed`, and
tell the lane that owns the PR. To wait for one run you just started, `gh run watch <id> --exit-status` as a
background command also works (PowerShell: `Start-Job { gh run watch <id> --exit-status }`); it reports by exit code.

## 2. Review-bot re-score (name `reviews`, every 120 s)

A bot such as Greptile edits its summary comment in place, so a new comment's `created_at` never moves. Its review's
`submittedAt` does; watch that. Replace `greptile` with your bot's login.

```bash
pass() { gh pr list --state open --limit 1000 --json number,reviews --jq '.[] | "#\(.number)\t\(
  [.reviews[] | select(.author.login | test("greptile"; "i"))] | last |
  if . == null then "no review" else "\(.state) at \(.submittedAt)" end)"'; }
```

For one PR: `gh api repos/<owner>/<repo>/pulls/<n>/reviews --jq 'map(.submitted_at) | last'`. A line means a fresh
score; read the bot's comment on the PR, then route its findings.

## 3. Lane context levels (name `context`, every 30 s)

```bash
pass() { lanes status --json | jq -r '.[] | select(.error == null) | "\(.lane)\t\(
  if .at_threshold then "at threshold" elif .ctx != "fresh" then "context \(.ctx)" else "below threshold" end)"'; }
```

On `alpha: below threshold -> at threshold`, run `lanes request alpha` and send the message it prints (lead skill,
step 4). On `context unknown` or `context stale`, ask the lane; never treat it as safe.

## 4. Journal drift (name `drift`, every 300 s)

Each in-flight row in `tracker.md` and `next-<lane>.md` names its PR as `#<n>`. The pass reads every PR those files
name, in the journal folder `lanes journal-dir` prints (it follows the `journal_dir` option):

```bash
pass() { local n j
  j="$(lanes journal-dir)"
  for n in $(cat "$j/tracker.md" "$j"/next-*.md | grep -oE '#[0-9]+' | tr -d '#' | sort -un); do
    gh pr view "$n" --json state,headRefOid,statusCheckRollup --jq '"#'"$n"'\t\(.state) \(.headRefOid[0:7]) \(
      [.statusCheckRollup[] | (.conclusion // .state // "") | ascii_downcase | select(. != "")] | unique | join(","))"' ||
      printf '#%s\tunreadable\n' "$n"
  done; }
```

Run it inside the repository. Compare each line with the row that names the PR: state, head and CI must match. List
the rows that do not, and fix them at an idle point (yours, and the lane's for its own rows). Never edit a lane's row
while that lane is mid-step.
