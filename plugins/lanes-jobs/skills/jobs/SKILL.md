---
name: jobs
description: Run heavy commands (test suites, builds) as lanes-job jobs that share a machine-wide limit with other sessions, and read the result from a STATUS file. Use before running a test suite, build or other command over about 2 minutes when other lane sessions share the machine; for a single long command with no shared cap, use a native background command.
---

# Heavy commands as pooled jobs

`lanes-job` exists for one thing native background commands cannot do: cap how many heavy jobs run at once across
every session on the machine, so parallel lanes do not exhaust memory. Each job also outlives your session, shows in
tmux, and leaves its result in one small STATUS file.

For a single long command that needs no shared cap, run it as a native background command and wait for its
completion notice. Use `lanes-job` when the work is heavy and other sessions may be running heavy work too.

## Start

```bash
lanes-job run <name> -- <command> [args...]
```

- `<name>`: letters, digits, `.`, `_`, `-`; it starts with a letter or digit. One running job per name.
- `--slot <pool>` picks the pool (default `jobs`). Each pool runs at most `LANES_POOL_SIZE` jobs at once (default 2).
- A full pool is refused with exit 75 and nothing starts. Wait for a running job to end, then retry. Do not loop on it.
- `run` returns once the job's own process owns its slot, so a launcher that dies afterwards cannot lose the job. If
  that handoff does not happen within `LANES_CLAIM_TIMEOUT` seconds (default 10), `run` fails and nothing starts.
- The command runs in your current directory with your `PATH`. Other shell variables do not follow you: the job sees
  the environment of the dedicated tmux server, which keeps what it had when the first job started. Pass a variable
  with `--env NAME` (copies its current value; repeat for several) or set it for one command:
  `lanes-job run t --env NODE_ENV -- npm test`, `lanes-job run t -- env CI=1 npm test`.
- Jobs run on their own tmux server (socket `lanes`, session `lanes-jobs`), never your own. To watch one:
  `tmux -L lanes attach -t lanes-jobs`.

## Get the result

```bash
lanes-job wait <name> --timeout 100   # prints STATUS; exit 0 finished, 124 timeout, 4 lost, 2 unknown name
lanes-job status <name>               # exit 0 finished, 3 running, 4 lost, 2 unknown
lanes-job list
```

The Bash tool kills a call after 120 s unless you raise its `timeout` (maximum 600000 ms). The `wait` timeout must be
shorter than the tool timeout, so `wait` returns its exit 124 before the tool kills the call: either wait in short
slices (`--timeout 100`, repeat on exit 124), or raise the Bash `timeout` above a longer wait (`--timeout 590` with
`timeout: 600000`).

STATUS has four lines: `EXIT:<code>`, `START:`, `END:` and `LOG:<path>`. It is written last, even when the job was
killed (`EXIT:143` for TERM, `129` for a closed window). `EXIT:0` means the command passed.

## Rules

- Use `wait` (or read STATUS once) to learn whether a job ended; the log tells you only what it printed so far.
- Read the log's tail only when `EXIT` is not 0: `tail -n 60 <LOG path>`.
- A wait that times out leaves the job running. Wait again, or do other work first.
- `LOST` means the job process vanished without a STATUS (SIGKILL, a restart). Start it again.
- Check a running or finished job with `status` or `wait`. Starting a finished name again replaces its log and STATUS.
- Run commands under about 2 minutes in the foreground; a job adds overhead for no gain.

## Slots for your own scripts

A script that is not a job can hold a slot in the same pools: see [SLOTS.md](SLOTS.md).
