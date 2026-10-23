# Guards

Copy this file to `.lanes/guards.md` in your project. Each `key: value` line is read by `lanes-guards`; other text is
ignored. A key left out falls back to the plugin's userConfig option of the same name, then to the default shown.

```
lead_only_commands: gh workflow run; gh pr merge; git push @default
plan_marker: PLAN:
main_checkout_guard: off
lead_exempt_main_checkout: no
default_branch:
```

- `lead_only_commands`: commands only the lead may run, separated by `;`. This list replaces the default, so repeat any
  default you keep. `git push @default` means every push except `git push <remote> <one non-default branch>`; plain
  `git push` means every push.
- `plan_marker`: a `SendMessage` starting with this text is refused unless the sender is the lead.
- `main_checkout_guard`: `on` refuses Edit, Write and NotebookEdit inside the main checkout while linked worktrees exist.
- `lead_exempt_main_checkout`: `yes` lets the lead edit the main checkout.
- `default_branch`: a branch a lane may never name in its explicit push, beside the pushed remote's head. Set it when a
  remote has no head (`refs/remotes/<remote>/HEAD`); with neither, a lane's push to that remote is refused.
