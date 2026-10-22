---
name: plancheck
description: Check a plan file has every required field before sending it to a lane. Use when writing or sending a plan.
---

# Plan check

A lane that gets a plan with a missing field guesses at it. Run the checker before you send the plan.

```bash
lanes-plancheck <plan.md> [<plan.md> ...]
```

A field is a level-2 heading (`## Goal`) with a non-empty body. Headings inside code fences and HTML comments do not
count, so the template's placeholder comments leave a field empty until you fill it. Heading names compare ignoring case.

Exit codes:

- `0`: every plan carries every field.
- `1`: a plan is missing a field (one `file: missing field: <name>` line each) or cannot be read.
- `2`: misuse, such as no plan given, or an unreadable or empty fields file.

Fix every reported field and rerun until the exit is `0`; send the plan only then.

## Fields

Start a plan from `${CLAUDE_PLUGIN_ROOT}/templates/plan.md`. Its level-2 headings are the required fields, the only
list of them.

A project replaces that list with `.lanes/plan-fields`: one heading per line, found by walking up from the current
directory to the git root. The variable `LANES_PLAN_FIELDS` names a different file and wins over the walk.
