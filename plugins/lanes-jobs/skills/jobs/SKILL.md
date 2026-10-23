---
name: jobs
description: Run heavy commands (test suites, builds) in a shared tmux server so parallel lane sessions do not run too many at once, and read the result from a STATUS file. Use before running a test suite, build or other command over about 2 minutes when other lane sessions share the machine; for a single long command with no other sessions, use a native background command.
---

# Heavy commands as shared jobs

Parallel lanes that each start a heavy suite can exhaust the machine. Run heavy work as a job in one shared tmux
server, where every session can see how many jobs already run. Commands under about 2 minutes run in the foreground.

## Start a job

1. See what runs: `tmux -L lanes list-windows -t lanes-jobs -F '#W' 2>/dev/null`. Each window except `idle` is one job.
2. If two jobs already run (or the number the human set), do not start a third: do other work and check again later.
   Never loop on the check.
3. Start it, with a name of letters, digits, `.`, `_` or `-`, and a folder for its files:

```bash
d=~/.cache/lanes-jobs/<name>; mkdir -p "$d"; rm -f "$d/STATUS"
tmux -L lanes has-session -t lanes-jobs 2>/dev/null || tmux -L lanes new-session -d -s lanes-jobs -n idle
tmux -L lanes new-window -d -t lanes-jobs -n <name> -c "$PWD" \
  "s=\$(date -u +%FT%TZ); <command> >'$d/log' 2>&1; e=\$?; printf 'EXIT:%s\nSTART:%s\nEND:%s\nLOG:%s\n' \$e \$s \$(date -u +%FT%TZ) '$d/log' >'$d/STATUS.tmp' && mv '$d/STATUS.tmp' '$d/STATUS'"
```

The job runs in the shared server, not your own, and outlives your session. Variables you need go inside the command
(`env CI=1 npm test`). To watch it: `tmux -L lanes attach -t lanes-jobs`.

## Get the result

- Check `~/.cache/lanes-jobs/<name>/STATUS`. It exists only once the job ended; `EXIT:0` means the command passed.
- While it runs, do other work. If you must wait, wait in slices shorter than the Bash tool's timeout (120 s unless you
  raise it).
- Read the log's tail only when `EXIT` is not 0: `tail -n 60 <LOG path>`.
- No STATUS and no window named `<name>` means the job was lost (a kill or restart): start it again.
