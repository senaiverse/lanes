# Handshake refusals

`lanes clear <lane>` and `lanes clear-ready` refuse instead of guessing. Each refusal below names its cause; the
fix is the action in the right column. After the fix, run the same command again.

| Refusal says | Cause | Do this |
|---|---|---|
| not clear-ready (handshake: ...) | The lane has not run `lanes clear-ready` since the request | Wait for its "clear-ready" message, or ask it where it stands |
| HEAD moved / RESUME block changed / tree stopped being clean / new prompt since clear-ready | The lane worked after reporting ready; checked again after every wait, just before Esc | Ask the lane to finish, push and report clear-ready again |
| ... before /clear was sent (the typed /clear was deleted) | A prompt or a turn arrived between Esc and Enter | Ask the lane to report clear-ready again |
| no longer holds pane / pane is also registered to lane X | Another session registered in that pane | Check `lanes status`; restart the lane in its own pane |
| stayed busy for N s | A turn is still running | Wait for it to end; if it never does, look at the pane |
| a working spinner, or a turn ended during the re-check, with a `/goal` footer | The lane's goal keeps starting turns | Ask the lane to answer goal turns without tools; the goal then hands control back |
| /goal clear was typed but the footer stayed | The goal did not clear | Look at the pane; `/clear` was not sent |
| /clear landed in another session / older than LANES_REQUEST_TIMEOUT | The record is too old to resume the goal from | Set the goal with `lanes goal <lane>`, or start a new handshake |
| a clear is in flight (on `lanes request`) | A `lanes clear` stopped at `sending` | Run `lanes clear <lane>` to finish or settle it |
| background tasks running | A background shell or subagent is still going | Ask the lane to stop it or wait for it; it would outlive the clear |
| became busy during the idle re-check | A message or a human arrived during the gap | Wait for the turn to end, then run `lanes clear` again |
| a working spinner / queued messages / a dialog is open | The screen vetoes the hook flag | Look at the pane; wait, or ask the human about the dialog |
| the input line holds text | Someone is typing in the lane | Leave it; ask the human |
| pane ... does not exist / is running X, not claude / copy mode | Wrong or dead target | Check the pane; a dead lane restarts as `claude --name <lane>` |
| another `lanes clear` is running (or `lanes goal`) | A second lead or a second call | Let the first finish |
| no new session registered / the session never received the goal | Enter was lost twice, or the goal was not taken | Look at the pane, finish by hand, and tell the human |

A lead that restarted mid-handshake runs `lanes clear <lane>` again: the record tells it whether `/clear` already
landed, and it sends only what is still missing.
