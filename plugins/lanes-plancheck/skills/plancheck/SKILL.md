---
name: plancheck
description: Check a plan file has every required field before sending it to a lane. Use when writing or sending a plan.
---

# Plan check

A lane that gets a plan with a missing field guesses at it. Check the plan yourself before you send it.

Start a plan from [the template](../../templates/plan.md). Its level-2 headings are the required fields, the only list
of them. A project can replace that list with `.lanes/plan-fields` (one heading per line, the nearest one walking up
from the current directory to the git root).

Before sending, read the plan and confirm every required field:

- is a level-2 heading (`## Goal`), compared ignoring case;
- is outside code fences and HTML comments (the template's placeholder comments do not count);
- has a body that is not empty.

If any field is missing or empty, fill it and check again. Send the plan only when every field passes, and say in your
message to the lane that it does.
