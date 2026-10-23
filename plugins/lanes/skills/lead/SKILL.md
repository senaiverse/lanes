---
name: lead
description: Run several Claude Code lane sessions in tmux as their lead - start each lane on a /goal, watch their context, and clear a lane at a threshold so it resumes from its RESUME block. Use when the user asks you to lead lanes, start a lane, check lanes, or clear a lane.
---

# Lead

You plan and the lanes build. Each lane is a Claude Code session in its own tmux pane, started by you, working on one
`/goal`. Its state lives in a RESUME block in its own work tree, so a lane can be cleared and pick up where it was.

Rules that hold for every step:

- Type into a lane's pane only as written below, and only after the checks in "Before any key". If a check fails or
  you are unsure, stop and tell the human what you saw; never retry blindly.
- Never send Escape (it interrupts a working turn) and never press Enter twice.
- Never type into your own pane, and never into a pane you did not start as a lane.
- Talk to a lane with the SendMessage tool (its session name, from ListAgents). Type into its pane only for `/goal`
  and `/clear`, which only typed input can run.

## 1. Start a lane

From the lane's work tree (one git worktree per lane), in a new tmux window, and keep the pane id it prints:

```bash
tmux new-window -P -F '#{pane_id}' -n <lane> -c <work tree> "claude --name <lane>"
```

Write the lane name, pane id and work tree in your own notes. That record is how you find the lane again.
Then set its goal (section 3).

## 2. Read a lane's state

Claude Code writes `<config dir>/sessions/<pid>.json` for each running session; the config dir is the lane's
`$CLAUDE_CONFIG_DIR`, else `~/.claude`. The file is not documented, so treat any field you do not find as "unknown" and
ask the human. Find the lane's Claude Code pid among the pane's process and its children (an npm install runs Claude
Code under a node wrapper), then read the status:

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # the lane's value, if you started it with another one
pp=$(tmux display -p -t <pane> '#{pane_pid}')
for p in "$pp" $(pgrep -P "$pp"); do [ -f "$cfg/sessions/$p.json" ] && pid=$p; done
jq -r '"\(.status) \(.waitingFor // "") \(.sessionId)"' "$cfg/sessions/$pid.json"
```

`status` is `idle`, `busy`, `waiting` (a permission prompt or a dialog; `waitingFor` says which) or `shell` (a
background shell or Monitor runs). No file means the session is gone: ask the human.

Context used: the lane's last assistant entry in its transcript
(`$cfg/projects/<cwd with / as ->/<sessionId>.jsonl`) carries `message.usage`; input tokens plus cache reads plus
cache writes, over the model's context window (200,000 tokens unless the model runs with a 1M window), is the share
used.

## 3. Set a goal

Only into an idle lane whose input line is empty (see "Before any key"). Keep the goal one line, at most 1400 characters
(longer text scrolls the input line off an 80x24 pane), not ending in `\` (Enter would insert a newline) or in a
`:word` token (the emoji picker takes the Enter), and with no invisible characters (Claude Code strips them).

```bash
tmux send-keys -t <pane> -l -- "/goal <text>"   # in chunks of at most 256 characters, 30 ms apart
tmux send-keys -t <pane> Enter
```

A burst of about 800 characters becomes "[Pasted text]", which does not run a slash command, hence the chunks. If the
text ends in `;`, send the text without it and then `tmux send-keys -t <pane> -H 3b` (tmux reads a trailing `;` as a
command separator). After Enter, read the pane: the lane should go busy and the input line be empty. If the text is
still in the input line, tell the human; do not press Enter again.

## 4. Clear a lane at the threshold

When a lane passes the context threshold (the human's number; 70% if none):

1. Message the lane (SendMessage): "Context is at threshold. Finish the change in hand, rewrite your RESUME block, commit and push,
   then tell me 'clear-ready' and stop."
2. Wait for its "clear-ready". Then check yourself: its work tree is clean and pushed, and its RESUME block is new.
3. Wait until the lane is `idle` for a few seconds (section 2). `shell` means a background shell or Monitor still runs:
   ask the lane to stop it first, since it would outlive the clear unseen. `busy` with a goal still set means the goal
   is still going: the lane answers its goal turns without tools, and Claude Code hands the goal back after a few such
   turns.
4. Run "Before any key", then type `/clear` and Enter as in section 3. `/clear` also removes the lane's goal.
5. Wait for a fresh session in that pane (the sessions file shows a new `sessionId` for the same pid), then set the
   goal (section 3) as `/goal You are lane <lane>. Read the RESUME block in <its exact file path> first and continue
   from its Next step: <the block's Goal line>`. The fresh session remembers nothing, so the goal itself carries the
   lane's name and where its state is.

## Before any key

All of these, right before typing, or stop:

- The pane is the lane's: the pane id from your notes, and the sessions file found from it (section 2) holds the
  session you expect.
- `tmux display -p -t <pane> '#{pane_in_mode} #{synchronize-panes}'` prints `0 0`: no copy mode (keys would go to
  tmux), no synchronize-panes (keys would go to every pane in the window).
- The session is `idle`.
- The input line is empty: `tmux capture-pane -p -e -t <pane>` shows the `❯` line with nothing after it, or only the
  dim placeholder text (`ESC[2m`). Anything else is a human's draft: leave it and ask.
- In vim mode the footer shows `-- INSERT --`; in NORMAL mode typed text runs as commands, so ask the human to press
  `i`.

If anything you typed did not arrive as typed, do not delete it with Backspace (a human may have typed meanwhile):
tell the human what the input line shows.
