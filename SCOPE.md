# Scope

lanes adds a feature when both of these hold.

1. **A failure seen in a real session.** You can point to a session where the thing went wrong: a lane cleared while
   busy, a RESUME note lost, a lead and a lane editing the same checkout. "It might happen" does not count.
2. **A fit with the philosophy.** Code only where something is enforced, holds state, or acts on a session. Everything
   else is an instruction in a skill (`docs/DECISIONS.md`, row 28). A watcher that only observes is an instruction, not
   a plugin (row 27).

A request that fails either test is declined, with the reason on record.

## What lanes will not do

- Sandbox a session. The guards catch mistakes, not attacks.
- Guard against destructive commands such as `rm -rf` or `git reset --hard`. Use
  [destructive_command_guard](https://github.com/Dicklesworthstone/destructive_command_guard) or
  [cc-safety-net](https://github.com/kenryu42/claude-code-safety-net).
- Run its tmux plugins on native Windows. They need WSL there.
- Clear a lane without the handshake.

## Declined requests: `.out-of-scope/`

When a request is declined, the maintainer records it in `.out-of-scope/<concept>.md`, one file per concept. A file
holds the reason, the failed test above, and a "Prior requests" list with a link to each issue or pull request that
asked. The next person who asks for the same thing reads the file first and adds a line to it. The folder does not
exist until the first decline.
