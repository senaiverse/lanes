---
name: jobs
description: Run heavy commands (test suites, builds) in a shared tmux server so parallel lane sessions do not run too many at once, and read the result from a STATUS file. Use before running a test suite, build or other command over about 2 minutes when other lane sessions share the machine; for a single long command with no other sessions, use a native background command.
---

# Heavy commands as shared jobs

Parallel lanes that each start a heavy suite can exhaust the machine. Run heavy work as a job in one shared tmux
server, where every session can see how many jobs already run. Commands under about 2 minutes run in the foreground.

## Start a job

Name the job `<your lane>-<what>` (letters, digits, `.`, `_`, `-`), so two lanes never share a name. The limit is two
jobs at once unless the human set another number.

1. **Claim the job's folder.** `mkdir` is atomic, so only one session can create it:

   ```bash
   J=~/.cache/lanes-jobs; d="$J/<name>"; mkdir -p "$J/slots"
   mkdir "$d" || echo "taken"
   ```

   "taken" with no `$d/STATUS` means that job still runs: wait for it, never start it twice. With a STATUS it is a
   finished run: `rm -rf "$d"` and claim again.
2. **Take a slot**, also by `mkdir`: `for n in 1 2; do mkdir "$J/slots/$n" 2>/dev/null && { echo <name> >"$J/slots/$n/job"; break; }; done`.
   No slot taken means the limit is reached: `rm -rf "$d"`, do other work and try later; never loop on it. A slot
   whose job has neither a STATUS nor a tmux window (`tmux -L lanes list-windows -t lanes-jobs -F '#W'`) was left by
   a killed job: remove it.
3. **Write the runner**, so the command keeps its quotes and `$` exactly, and your `PATH` and directory travel with it:

   ```bash
   { printf 'export PATH=%q\ncd %q\n' "$PATH" "$PWD"; cat <<'CMD'
   <command, exactly as you would type it>
   CMD
   } >"$d/cmd.sh"
   cat >"$d/run.sh" <<RUN
   s=\$(date -u +%FT%TZ); bash '$d/cmd.sh' >'$d/log' 2>&1; e=\$?
   printf 'EXIT:%s\nSTART:%s\nEND:%s\nLOG:%s\n' "\$e" "\$s" "\$(date -u +%FT%TZ)" '$d/log' >'$d/STATUS.tmp'
   mv '$d/STATUS.tmp' '$d/STATUS'; rm -rf '$J/slots/$n'
   RUN
   ```

4. **Start it** in the shared server:

   ```bash
   tmux -L lanes has-session -t lanes-jobs 2>/dev/null || tmux -L lanes new-session -d -s lanes-jobs -n idle
   tmux -L lanes new-window -d -t lanes-jobs -n <name> "bash '$d/run.sh'"
   ```

The job runs in the shared server, not your own, and outlives your session. Other variables go inside the command
(`env CI=1 npm test`). To watch it: `tmux -L lanes attach -t lanes-jobs`.

## Get the result

- Check `~/.cache/lanes-jobs/<name>/STATUS`. It exists only once the job ended; `EXIT:0` means the command passed.
- While it runs, do other work. If you must wait, wait in slices shorter than the Bash tool's timeout (120 s unless you
  raise it).
- Read the log's tail only when `EXIT` is not 0: `tail -n 60 <LOG path>`.
- No STATUS and no window named `<name>` means the job was lost (a kill or restart): start it again.
