---
name: prodfence
description: Explains why the production fence refused a tool call and how to set the fence up. Use when a call is refused with "This touches production", when lanes-prodfence refuses every call because its config is broken, or when setting up production markers for a project.
---

# lanes production fence

Only the human acts on production. The fence refuses any session's Bash, PowerShell, Monitor, MCP, WebFetch or
ReadMcpResourceTool call whose input mentions a production marker, a shell command that mentions a protected path, and
any Read, Edit, Write or NotebookEdit of a protected path. The lead gets no exemption. It is a mistake fence, not a
sandbox: it matches any mention, ignoring case, and does not parse commands.

## When a call is refused

- `This touches production (marker in <field>). Ask the human to run it.` Stop. Tell the human the exact command or
  request and why it is needed, and let them run it. Do not rephrase, split, encode or route the call through another
  tool to get past the fence; a near miss is the mistake the fence exists for.
- `protected path in tool_input.<field>`: the file, or a command that names it, belongs to production. Ask the human.
- A false refusal (the call does not touch production) is still the human's call: say why you think it is safe and
  ask them to run it, or to narrow the marker.
- `refusing every guarded call until it is fixed`: the config is broken, a markers_file is unreadable, or jq is missing.
  Report the message to the human; do not edit the fence's config to get unblocked.

The refusal never repeats the marker, because markers can be private.

## Setup

Copy `${CLAUDE_PLUGIN_ROOT}/templates/prodfence.md` to `.lanes/prodfence.md` and replace its examples. The template
documents each key: `markers_file`, `fence_file_content` and `protected_paths`. The userConfig options `markers` and
`protected_paths` add to the file. With no file and no options the fence is off, and each session start says so.

Add a marker for each way production can be named:

- Database hosts, connection URLs and pooler hosts.
- Cloud project IDs and numbers, account IDs, regions only used by production.
- Kubernetes contexts and cluster names.
- Deploy and migration commands that target production or a linked or remote project (`deploy --env production`,
  `db push --linked`).
- Production environment names, production env file names (`.env.production`), and production secret and env var names.
- Production URLs and dashboards.

Keep private markers (real hosts and IDs) in an external `markers_file`, outside the repository, so they are never
committed. Prefer specific markers: a short one such as `prod` refuses far more than production.

## Limits

- Text that never names a marker or a protected path passes: a variable holding the host, a script file, an alias, a
  remote shell. `source .env.production && psql "$DATABASE_URL"` names no host, so list `.env.production` as a marker
  or protected path, and the linked or remote deploy commands as markers.
- `fence_file_content: off` (the default) lets an edit write a marker into a file; turn it on to refuse that too.
- Case is ignored for ASCII letters only.
