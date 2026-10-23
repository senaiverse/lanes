# lanes rules

Mechanism rules for a lead session and its lane sessions. Your project's engineering standards live in your project,
not here. The lead and lane skills say how to follow these rules; this file says what holds.

1. **Names.** Start every session inside tmux as `claude --name <lane>`; start the lead with `LANES_ROLE=lead` set.
   The name is the lane's identity in the registry, in messages and in the journal, and it survives `/clear`.
2. **One home per fact.** `tracker.md` holds every item's state. Each lane writes only its own `next-<lane>.md`, its own
   `done-<lane>.md` and its own tracker rows; the lead writes plans, the tracker's other rows and `morning.md`.
3. **One RESUME block.** `next-<lane>.md` holds open work and ONE RESUME block between the `lanes:resume` markers,
   replaced in place, never stacked. It links to plans, commits and files instead of copying them, carries no secret,
   and stays under 8,000 characters. Its Goal is one line.
4. **Messages.** Sessions talk through cross-session messages. tmux keys are only for `/clear` and `/goal`, which a
   message cannot run, and only the lead's `lanes clear` and `lanes goal` send them.
5. **Threshold.** A lane at or above the threshold (`lanes status`) is asked to hand off. An unknown or stale context
   percentage is not "safe": ask the lane.
6. **Clear handshake.** The lead runs `lanes request <lane>` and messages the lane. The lane finishes the change in
   hand, rewrites its RESUME block, commits and pushes, runs `lanes clear-ready` from its work tree, tells the lead
   "clear-ready", and stops; every later turn (its `/goal` going on, a notification) it answers "clear-ready" with no
   tool call at all, never `lanes clear-ready` again, since any tool call cancels the readiness. The lead then runs
   `lanes clear <lane>`, which refuses until a lane that worked again reports clear-ready again.
   `/clear` removes an active goal, so `lanes clear` types `/clear`, then the RESUME Goal, the one source of the goal
   after a clear: keep it equal to the goal you work toward. The goal is typed only while nobody has used the new
   session. A lead runs request, clear and goal only on the lanes of its own project, never on a lead.
7. **A refusal is an answer.** `lanes clear-ready` and `lanes clear` refuse unless the tree and the lane's own journal
   files are clean and pushed, the RESUME block is valid and the block itself was rewritten and committed since the
   request, the lane runs no background shell, Monitor or subagent (on `lanes clear`), and the lane is idle, called no
   tool and is unchanged since clear-ready. Fix the named cause; never retry blindly and never send `/clear` by hand
   around a refusal.
8. **Idle comes from Claude Code.** Busy, idle, waiting and a running background shell come from the session's own
   state file, never from screen text or a hook count; a lane is idle only once it stayed idle for a short gap. The
   screen is read only for the input line (a human's draft, never typed over, and whether lanes' own typed text
   arrived) and, in vim mode, the `-- INSERT --` footer.
9. **Done report.** A finished unit moves from `next-<lane>.md` to `done-<lane>.md` in the done-report form. The lead
   accepts it only after reading the full diff.
10. **Asking the human.** Only the lead asks the human, through the ask tool: one question, its facts and costs, the
    recommended option marked. Lanes send their questions to the lead.
11. **Away mode.** While `lanes away on` holds for a project, no session registered in that project (its lead and its
    lanes) uses the ask tool; questions go to `morning.md`. Other projects and unregistered sessions are not affected.
    It records who set it and when. Only the human's own message lifts it (`lanes away off`); a lane, a tick or a hook never does.
12. **Never idle silently.** A lane that has nothing unblocked tells the lead what it finished, what it waits on, and
    asks for the next item.
13. **Lead-only actions.** Only the lead dispatches CI, merges, pushes to the default branch and sends plans; lanes ask
    the lead.
