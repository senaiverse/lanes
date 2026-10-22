---
name: lane
description: A lane session's procedure for building from the lead's plan and handing off through the journal. Use when you are a lane (started with claude --name <lane>, not the lead), when you start or resume work, finish a unit, need a decision, have nothing unblocked, or the lead asks you to write RESUME and report clear-ready.
---

# Lane

You build what the lead planned, keep your own journal files current, and hand off cleanly when your context fills.
The rules are in the journal's `RULES.md` (default `.lanes/RULES.md`); this skill is the procedure.

## 1. Start or resume

1. Read your RESUME block in `next-<lane>.md`. After a `/clear` it is already in your context.
2. Read what it links: the plan, the tracker row, the last commits.
3. Load the skills it lists under "Suggested skills".
4. Do its Next step.

Done when you are working on the Next step and your tracker row says so.

## 2. Build

1. Build the item from its plan. A gap or a design question goes to the lead as a message, with file:line evidence.
2. Questions for the human go to the lead (RULES.md rule 10), and so do CI, merges and plans (rule 13).
3. Rewrite your RESUME block in place at each real step: Now, Next step and Running change; it stays one block.
4. Keep your tracker row current: branch, PR, CI and next step.

Done when the RESUME block would let a fresh session continue without asking anything.

## 3. Keep the RESUME block usable

The block sits between the `lanes:resume` markers and has six sections: **Goal** (one line), **Now**, **Next step**,
**Links**, **Running**, **Suggested skills**. The block rules are RULES.md rule 3; `lanes clear-ready` enforces them.
The sample is `${CLAUDE_PLUGIN_ROOT}/templates/journal/next-lane.md`. Under Running, name every job still going and
where its result lands.

Done when `lanes clear-ready` would accept it (run it to check; it changes nothing when it refuses).

## 4. Report done

1. Move the finished unit from `next-<lane>.md` to `done-<lane>.md` in the done-report form there: ripple, blast
   radius, pitfalls, edge cases with their tests, review verdicts and evidence paths.
2. Commit and push.
3. Tell the lead: what is done, the head, where the entry is, and "next item?".

Done when the entry is pushed and the lead has your message.

## 5. Hand off at the threshold (clear-ready)

When the lead asks (or your own context reaches the threshold and you tell the lead):

1. Finish or commit the change in hand.
2. Rewrite your RESUME block with your current state. A block unchanged since the lead's request is refused.
3. Commit and push your branch and the journal.
4. Stop anything running in the background, or name it under Running if it must outlive the clear.
5. Leave an active `/goal` alone. You cannot clear it; `lanes clear` clears it and sets it again after the clear.
6. Run `lanes clear-ready` from the work tree you work in. If it refuses, fix the cause it names and run it again.
7. Send the lead "clear-ready", then stop and wait. A new prompt, a commit or an edit after this cancels the
   readiness. When your goal starts another turn, answer only "waiting for clear" and call no tool: after a few such
   turns the goal hands control back, and the lead can clear you.

Done when `lanes clear-ready` printed `clear-ready: <lane>` and the lead has your message.

## 6. Never wait silently

When nothing is unblocked, or your next step waits on CI, the lead or the human, send the lead the message RULES.md
rule 12 asks for, then wait.

Done when the lead has that message.
