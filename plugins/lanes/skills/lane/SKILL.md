---
name: lane
description: Work as a lane session under a lead - keep a RESUME block, commit and push, and report clear-ready when the lead asks so the lead can clear you and you resume. Use when the session was started as a lane, the lead messages you, or you are asked to write your RESUME or report clear-ready.
---

# Lane

The lead started you in your own tmux pane on a `/goal`. Work on that goal in your own work tree. The lead may clear you
when your context is high; after the clear you remember nothing but your RESUME block, so keep it true.

## RESUME block

Keep one in your work tree, in the file the lead names (default `.lanes/next-<lane>.md`), between these markers:

```markdown
<!-- RESUME -->
Goal: <one line, at most 1400 characters: what you are finishing, as the /goal to set again>
Done: <what is committed and pushed>
Next step: <the first thing to do after a clear>
Open items: <anything waiting on someone>
<!-- /RESUME -->
```

After a clear, read it first and continue from "Next step".

## When the lead asks you to get ready for a clear

1. Finish the change in hand. Do not start a new one.
2. Stop or finish any background shell or Monitor you started (it would outlive the clear unseen), and let background
   subagents finish.
3. Rewrite the RESUME block with your current state. Commit and push everything, so the work tree is clean and your
   branch is not ahead of its upstream.
4. Tell the lead "clear-ready" (SendMessage to the lead's session) and stop.
5. If your goal starts another turn after that, answer only "clear-ready" and call no tool. Claude Code hands an unmet
   goal back after a few turns with no tool use, and then the lead can clear you.

If you must work again after reporting ready, tell the lead first; it will wait for a new "clear-ready".
