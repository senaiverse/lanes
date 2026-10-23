---
name: lead
description: "Run lane sessions in tmux with a shared journal: hand a lane its work, read lanes status, clear a lane at its context threshold, set a lane's goal, accept a done report, ask the human, or go into away mode. Lead only; a lane session uses lane."
---

# Lead

You plan, the lanes build, and the journal carries the state. The rules are in the journal's `RULES.md` (default
`.lanes/RULES.md`); this skill is the procedure. Every `lanes` command below is on your PATH while the plugin is on.

## 1. Set up once per project

1. Run `lanes init <lane>...` from the repository, one name per lane. It writes the journal and never overwrites.
2. Ask the human (step 6) whether to add `@.lanes/RULES.md` to the project's `CLAUDE.md`, then run
   `lanes init --claude-md yes` or `--claude-md no`.
3. Show the human the `statusLine` block that `lanes init` printed and ask them to add it to their settings. Without it,
   context percentages stay `unknown`.
4. Ask the human to start each lane in its own tmux pane as `claude --name <lane>`, and yourself as
   `LANES_ROLE=lead claude --name <lead>`.

Done when `lanes status` lists every lane with a live pane, and the journal is committed.

## 2. Hand out work

1. Write each item into `tracker.md` and its plan where your project keeps plans. Link the plan; do not paste it.
2. Message the lane by its name with a pointer: the tracker row, the plan path, and what done means.
3. Read the lane's reply. A question about the design comes back to you; a fact it found goes into the plan.

Done when every lane has one item in flight and a tracker row that names it.

## 3. Watch the lanes

At the start of each session, start every watcher the SessionStart context lists as down: CI, review score, lane
context and journal drift, one endless Monitor each. Their commands are in [MONITORS.md](MONITORS.md).

Run `lanes status` at each check. A row reads lane, role, pane, context, activity, goal, readiness and handshake:

```text
alpha	lane	%3	ctx 72% AT-THRESHOLD	idle	goal active	clear-ready	handshake ready
```

- **ctx**: a number, `unknown` or `stale`. Treat `unknown` and `stale` as "ask the lane", never as safe.
- **AT-THRESHOLD**: start the handshake (step 4).
- **activity**, from Claude Code's own session state: `idle`, `settling` (idle for under a few seconds), `busy`,
  `waiting (<what for>)` (a question, dialog or permission prompt a human must answer), `shell` (a background shell
  runs) or `unknown (<why>)`. Treat `unknown` as "look at the pane".
- **goal**: `active`, `none` or `unknown`, from the lane's transcript.
- **handshake**: `none`, `requested`, `request-timed-out`, `ready`, `sending`, `cleared`, `stale`, `failed`, `done`.

`sending` and `cleared` are a clear in flight: run `lanes clear <lane>` again to finish it. `stale` and `failed` need a
new `lanes request`.

Done when every lane at or above the threshold has a handshake in progress.

## 4. Run the clear handshake

The handshake is RULES.md rule 6; these are its commands.

1. Run `lanes request <lane>`. It records the request and prints the message to send.
2. Send that message to the lane.
3. Wait for the lane's "clear-ready". Use `lanes status`: the row shows `clear-ready`.
4. Run `lanes clear <lane>` with the Bash tool's `timeout` set to 300000 (5 minutes): it waits up to `--wait` seconds
   (default 60) for idle twice and up to 20 s for each confirmation, about 4 minutes at worst, while the tool's
   default is 2 minutes. It re-checks everything before every key it sends. It types `/clear`, which also ends an
   active `/goal`, then the RESUME Goal recorded at clear-ready, and confirms each by its effect.
5. Read its last line. `cleared: <lane> ...` means the lane has a new session, its RESUME block, and its goal.

Done when `lanes status` shows the lane with handshake `done` and the lane has answered its first message.

When `lanes clear` refuses, its message names the cause and the fix; act on that cause. See
[HANDSHAKE.md](HANDSHAKE.md) for each refusal. When a request times out (`request-timed-out`), ask the human
(step 6) instead of clearing.

### Set or replace a lane's goal

Run `lanes goal <lane> "<one line>"` when a lane should work toward a new end state without losing its context: a new
item, a narrower target, or a goal that ended early. It refuses unless you are the lead, the goal is one line of at
most 4,000 characters, and the lane is idle (a background shell may run). It types the goal through the same checks as
`lanes clear` and confirms it by the lane's own prompt hook; give it a Bash `timeout` of 180000 (it can wait `--wait`
seconds and then up to 40 s for the confirmation). It sets the live goal only: ask the lane to copy it into its RESUME
Goal, the goal a later `lanes clear` sets again. To give a lane a plain instruction, message it instead.

## 5. Accept a done report

1. Read the lane's entry in `done-<lane>.md`. It follows the form there: ripple, blast radius, pitfalls, edge cases
   with their tests, review verdicts and evidence paths.
2. Read the full diff of the unit, and the tests it names.
3. Write your verdict into the entry, and move the tracker row on.

Done when the entry says "Lead accepted" with the date, written after you read the whole diff.

## 6. Ask the human

Every decision goes to the human through the ask tool (`AskUserQuestion`), in the form of RULES.md rule 10. Read what
the journal already records before you ask, and name any earlier answer the question would change.

For a design tree (decisions that depend on each other), call the Skill tool with "grilling" if it is installed.

Done when the answer is recorded where the work reads it (plan, tracker or the journal's own decisions file).

## 7. Away mode

Away mode is RULES.md rule 11; only the human's own message lifts it.

- When the human says they are going away, run `lanes away on` from your own pane. `lanes away status` shows who set
  it and when.
- While away, write each question into `morning.md` in its entry form, take the recommended option where the work can
  proceed safely and reversibly, and mark that choice in the entry. Keep work that needs the human blocked.
- When the human's own message arrives, run `lanes away off`, then ask the queued questions one at a time (step 6).

Done when `morning.md` holds every open question and `lanes away status` matches whether the human is present.

## 8. Your own threshold

When your own context reaches the threshold, sync `tracker.md`, write your own `next-<lead>.md` RESUME block, commit
and push, and tell the human you are clear-ready. The human clears you; a session never clears itself.
