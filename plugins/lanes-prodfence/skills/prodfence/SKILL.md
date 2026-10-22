---
name: prodfence
description: Explains why the production fence refused a tool call and how to set the fence up. Use when a call is refused with "This touches production" (marker or protected path), when lanes-prodfence refuses every call because its config is broken, or when setting up production markers.
---

# lanes production fence

Only the human acts on production. The fence refuses any session's Bash, PowerShell, Monitor, MCP, WebFetch or
ReadMcpResourceTool call whose input mentions a production marker, a shell command that mentions a protected path, and
any Read, Edit, Write or NotebookEdit of a protected path or of a path that mentions a marker. The lead gets no
exemption. It is a mistake fence, not a sandbox: it matches any mention, ignoring case, and does not parse commands.

## When a call is refused

- `This touches production (marker in <field>). Ask the human to run it.` Stop. Tell the human the exact command or
  request and why it is needed, and let them run it. Do not rephrase, split, encode or route the call through another
  tool to get past the fence; a near miss is the mistake the fence exists for.
- `This touches production (protected path in <field>). Ask the human to run it.` The file, or a command that names
  it, belongs to production. Ask the human.
- A false refusal (the call does not touch production) is still the human's call: say why you think it is safe and
  ask them to run it, or to narrow the marker.
- `refusing every guarded call until it is fixed`: the config is broken, a markers_file is unreadable, or jq is missing.
  Report the message to the human; do not edit the fence's config to get unblocked.

The refusal never repeats the marker, because markers can be private.

## Setup

See [SETUP.md](SETUP.md) to turn the fence on and choose markers.

## Limits

- Text that never names a marker or a protected path passes: a variable holding the host, a script file, an alias, a
  remote shell. `source .env.production && psql "$DATABASE_URL"` names no host, so list `.env.production` as a marker
  or protected path, and the linked or remote deploy commands as markers.
- `fence_file_content: off` (the default) lets an edit write a marker into a file; turn it on to refuse that too.
- Case is ignored for ASCII letters only.
