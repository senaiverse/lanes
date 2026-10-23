# Handshake refusals

`lanes clear <lane>` and `lanes clear-ready` refuse instead of guessing. Each refusal below names its cause; the
fix is the action in the right column. After the fix, run the same command again.

| Refusal says | Cause | Do this |
|---|---|---|
| not clear-ready (handshake: ...) | The lane has not run `lanes clear-ready` since the request | Wait for its "clear-ready" message, or ask it where it stands |
| HEAD moved / RESUME block changed / tree stopped being clean / new prompt since clear-ready | The lane worked after reporting ready; checked again after the wait and before every key | Ask the lane to finish, push and report clear-ready again |
| began another turn since clear-ready | A turn began with no prompt after the lane reported ready: its `/goal` went on, a background shell finished, or a message arrived (read from its transcript) | Ask the lane to report clear-ready again; a lane whose goal keeps going runs `lanes clear-ready` again in each goal turn |
| transcript ... could not be read | The transcript recorded at clear-ready is unreadable, so a later turn cannot be ruled out | Ask the lane to report clear-ready again; if it repeats, check that the file the message names is readable |
| the lane's state moved after the idle check ... before /clear was sent | A turn started (a prompt, a `/goal` check-in, a finished background shell) after the lane was proven idle; any typed text that was still ours alone was deleted, and the message says so | Ask the lane to report clear-ready again |
| no longer holds pane / pane is also registered to lane X | Another session registered in that pane. Found after the wait for idle, this and the two rows below drop clear-ready, since the pane no longer proves to host the lane | Check `lanes status`; restart the lane in its own pane |
| no Claude Code session file / the session file ... is stale / now runs session X / names pid X / has no Claude Code pid registered | The registered Claude Code process exited, was killed, or another session runs there; an entry written by an older lanes has no pid | Check the pane; a dead lane, or one registered before this version, restarts as `claude --name <lane>` |
| on another tmux server / not the process of pane ... or a child of it | The pane id now belongs to something else (tmux restarted, or another program) | Check the pane; never type into it by hand |
| not the foreground program of pane ... | Claude Code is stopped (Ctrl-Z) or runs in the background of the pane, as a session a tool or a shell started does. The lane stays clear-ready | Ask the human to bring it back with `fg`, then run `lanes clear <lane>` again; a session a tool started restarts in its own pane |
| synchronize-panes on | Keys sent to the pane would reach every pane of its window. The lane stays clear-ready | Ask the human to turn it off (`setw synchronize-panes off`), then run `lanes clear <lane>` again |
| check failed: ... | One of the checks itself crashed (a killed `jq`, a failed fork), which never counts as a pass | Run the command again; if it repeats, report it with the full output |
| unknown schema ... | This Claude Code version writes its session file differently | Run `LANES_LIVE=1` tests/lanes/live on this version and report the result |
| not valid JSON | The session file was unreadable twice in a row (one torn read is read again) | Run the command again; if it repeats, look at the file |
| stayed busy for N s | A turn, or a `/goal` loop, is still running | Wait for it to end; if it never does, look at the pane |
| did not stay idle for N s | The lane keeps starting short turns | Wait for it to go quiet, then run the command again |
| is waiting for its human (...) | A question, dialog or permission prompt is open | Ask the human to answer it |
| has a background shell running (on `lanes clear` only) | A background shell is still going; it would outlive `/clear`. `lanes goal` accepts it | Ask the lane to stop it or wait for it |
| /clear landed in another session / older than LANES_REQUEST_TIMEOUT | The record is too old to resume the goal from | Set the goal with `lanes goal <lane>`, or start a new handshake |
| a clear is in flight (on `lanes request`) | A `lanes clear` stopped at `sending` | Run `lanes clear <lane>` to finish or settle it |
| the input line holds text / changed after it was checked / cannot be read | Someone is typing in the lane, or something covers the input line | Leave it; ask the human |
| text arrived in the input line ahead of ours | A human typed just as lanes did; nothing is deleted, since a Backspace count could eat their text | Ask the human to clear the input line, then run the command again |
| pane ... does not exist | Wrong or dead target | Check the pane; a dead lane restarts as `claude --name <lane>` |
| copy mode | The pane scrolled into copy mode (checked before every key). The lane stays clear-ready; if the message says our text was left in the input line, it is still there | Ask the human to leave copy mode (q) and to delete any text of ours left in the input line, then run `lanes clear <lane>` again |
| another `lanes clear` is running (or `lanes goal`) | A second lead or a second call | Let the first finish |
| no new session appeared / the session never received the goal | Enter was lost twice, or the goal was not taken | Look at the pane, finish by hand, and tell the human |
| sent ... once, then ... it may have been taken late | Enter was pressed, nothing confirmed it, and then a check failed, so the second Enter was not sent | Run `lanes status`; `lanes clear <lane>` again resumes from the record whether or not it landed |
| lanes: stopped while typing into ... | `lanes clear` or `lanes goal` was killed (the Bash tool's timeout) with our text possibly in the input line; the line says whether it was deleted | Run it again with a longer Bash timeout (see the lead skill) |

A lead that restarted mid-handshake runs `lanes clear <lane>` again: the record tells it whether `/clear` already
landed, and it sends only what is still missing.
