# M0 findings: platform facts for the lanes plugin

Run 2026-10-22 on Claude Code 2.1.308, Linux (WSL 2), tmux 3.4. Probe plugin: a throwaway `lanes-m0-probe` with
a `settings.json` statusLine, a SessionStart hook that logged stdin and env, a `bin/` script, and a monitor. It was
loaded with `claude --plugin-dir` inside a private tmux server (`tmux -L lanes-m0`), which is now killed. The probe
lives in the session scratchpad, not in this repo. Docs base: https://code.claude.com/docs/en/.

Side effect: the trust prompt for the scratch folder was accepted once, so `~/.claude.json` now trusts it.

## 1. Can a plugin's settings.json set statusLine?

- Ran: `settings.json` at the plugin root with `{"statusLine":{"type":"command","command":"<probe>/bin/lanes-probe-status"}}`.
  `claude plugin validate` printed "Validation passed" with no warning about the key. The script appends its stdin to a log.
- Observed: the status line stayed the user's own (`Haiku 5.5 | 6% ctx | <cwd>`). The probe log was never written, so the
  plugin's statusLine was not applied.
- Docs: plugins-reference "settings": "Only `agent` and `subagentStatusLine` take effect; other keys are dropped at load"
  (plugins-reference#settings, plugins/components#default-settings).
- **Verdict: NO (experiment and docs agree).** The user must wire `statusLine` in their own settings. `lanes init` or the
  README must print the exact block. Validate does not warn, so a test must not assume a plugin statusLine works.

## 2. What does SessionStart input carry, and does $TMUX_PANE reach the hook?

- Ran: a SessionStart hook logging stdin and `env`, in `claude` running in tmux pane `%0`.
- Observed stdin (startup): `session_id`, `transcript_path`, `cwd`, `scratchpad_dir`, `hook_event_name`, `source:"startup"`,
  `model`, and `session_title` (present only because the session was launched with `--name`).
- Observed after `/clear`: `source:"clear"`, a NEW `session_id`, same `cwd`, same `session_title`, no `model` field.
- Observed env in the hook: `TMUX=/tmp/tmux-1000/lanes-m0,627990,0`, `TMUX_PANE=%0`, `CLAUDE_CODE_SESSION_ID`,
  `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, `CLAUDE_PROJECT_DIR`, `CLAUDE_ENV_FILE`, `CLAUDE_CODE_MESSAGING_SOCKET`
  (and a `CLAUDE_CODE_MESSAGING_TOKEN`, which the log redacted). `TMUX_PANE=%0` appeared in all four logged hook runs.
- Docs: hooks#sessionstart lists `source` values `startup|resume|clear|compact|fork`; `model` "can be omitted, for example
  after /clear".
- **Verdict: YES, `$TMUX_PANE` and `cwd` reach the hook. `session_id` changes on every `/clear`.** Plan change: the registry
  file `$DATA/sessions/<session_id>.json` is orphaned by each clear. `lanes register` must run on `source=clear` and
  rewrite or move the entry (key lane identity by lane name or pane, not by session id alone). If `$TMUX_PANE` is empty
  the hook must say so, which is already M1 item 2.

## 3. Does additionalContext from SessionStart(clear) reach the model after /clear?

- Ran: the hook printed `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"LANES-M0-MAGIC: the
  secret word is PINEAPPLE-7421."}}` only when `source=="clear"`. Then `/clear`, then asked "what is the secret word from
  LANES-M0-MAGIC in your context? If none, say NONE."
- Observed: the model answered `PINEAPPLE-7421`.
- Docs: hooks, "SessionStart ... additionalContext adds context for Claude ... at the start of the conversation". One
  caveat there: if SessionStart hooks are still running in the background when `/clear` happens, "nothing they return
  applies to the session".
- **Verdict: YES.** The hook that re-injects RESUME and the goal must be fast and synchronous (read files, print JSON).
  `lanes clear` must wait for the echo, then check the model sees the block, as M1 item 4 already says.

## 4. Does the messaging name match anything derivable inside the session? How does a lane learn its name?

- Ran: `/list-agents` in a session launched with `--name lanes-m0-probe`, and in one launched without a name.
- Observed, named: `This session: lanes-m0-probe [018a7c] (the name other sessions use to message it)`. The name equals
  `session_title` in the SessionStart stdin. It survives `/clear` (same name before and after).
- Observed, unnamed (cwd `.../work`): `This session: work-09 [ce2848]`. The name is the cwd basename plus a two-character
  suffix. The hook stdin had no `session_title` (0 matches in the log), so the name is NOT derivable from hook input.
- The `[xxxxxx]` tag is not the session id (`cd7341ff...` vs `018a7c`). What it derives from is not documented (unverified).
- Docs: cross-session-messaging: "A session answers to the name you set with /rename or the --name flag. When you don't
  set one, Claude Code names the session itself." Same-name sessions get a short id in the address. statusline:
  `session_name` is set from `--name` or `/rename`, otherwise an AI title; "the default display name, such as `my-app-3f`,
  doesn't populate this field". Sessions: `/clear` keeps a `--name` or `/rename` name. `/list-agents` first line is the
  session's own name.
- **Verdict: PARTIAL.** A lane can learn its name from `session_title` (SessionStart) or `session_name` (status line) only
  if it was named. Plan change: `lanes` launches every lane as `claude --name <lane>` (and the lead too), and
  `lanes register` stores `session_title` as the lane name. Without `--name`, the messaging name cannot be derived
  and the lane would have to run `/list-agents` itself. Also check for duplicates: two lanes with one name get a
  `(2)` suffix per agent-view docs, which M1's "two lanes with the same name" test must cover.

## 5. Are bin/ entries on PATH for hook commands and for Bash tool calls?

- Ran: `command -v lanes-probe` inside the SessionStart hook and inside the UserPromptSubmit hook; and the model ran
  `command -v lanes-probe; lanes-probe` through its Bash tool.
- Observed: hooks (both events): `NOT-ON-PATH` (the hook PATH has no plugin dir). Bash tool: `.../plugin/bin/lanes-probe`
  and the script ran (`probe-ok`). In the Bash tool env `CLAUDE_PLUGIN_ROOT` is absent (`env | grep -c` printed 0), while
  `CLAUDE_CODE_SESSION_ID` and `TMUX_PANE` are present.
- Docs: plugins-reference "Executables": files in `bin/` "are on the Bash tool's PATH while the plugin is enabled".
  "The variables aren't present in the environment of commands Claude runs through the Bash tool."
- **Verdict: PARTIAL.** Bash tool: yes. Hooks: no. Plan change: hook commands call
  `"${CLAUDE_PLUGIN_ROOT}/bin/lanes-..."` by absolute path. Skills call `lanes ...` bare. Scripts that need the plugin root
  from the Bash tool must derive it from their own path (`dirname "$0"`), not from `CLAUDE_PLUGIN_ROOT`. The status line
  command (user-wired, see 1) also has no plugin PATH, and `${CLAUDE_PLUGIN_ROOT}` changes on every plugin update
  (plugins-reference "Environment variables"). Proposal for M1: the SessionStart hook refreshes a stable
  `$CLAUDE_PLUGIN_DATA/lanes-statusline` copy or link, and the README wiring points there. `CLAUDE_PLUGIN_DATA`
  is "kept across plugin updates". Not tested.

## 6. Is monitors/monitors.json usable from a plugin today?

- Ran: `monitors/monitors.json` holding `[{"name","command","description"}]` with a command that appended a line to a log
  and printed `tick`.
- Observed: the monitor started at session start (log line written, footer showed "1 monitor"). Its stdout line reached the
  model as `Monitor event: tick`, and the model replied to it. The stream end was reported as a second event (exit code 0).
  Each stdout line is a model turn, which costs usage. `claude plugin validate` accepted the file.
- Docs: plugins-reference "monitors". `experimental.monitors` (path or inline array, default `monitors/monitors.json`).
  Entry is a strict object: `name`, `command`, `description` required; `when` optional (`always` default, or
  `on-skill-invoke:<skill>`). Unknown keys fail. Runs only in interactive sessions, not on Bedrock, Vertex or Foundry.
  `command` runs in the session working directory; it cannot use `${user_config.*}`; plugin variables are resolved in the
  command string but not exported to the process.
- Not run: a `claude -p` session (docs only: monitors do not run there). The `experimental` key means the shape may change.
- **Verdict: YES, usable now, but experimental.** Plan change: ship `lanes-ci` as a normal `bin/` script (testable in
  bats, usable without monitors), and add a thin `monitors/monitors.json` entry whose command is
  `"${CLAUDE_PLUGIN_ROOT}/bin/lanes-ci" watch` (absolute path, since a monitor has no plugin PATH either: unverified, PATH
  of a monitor not tested). Only the lead should run it, via `when: "on-skill-invoke:lead"` so lanes do not each start one.
  `lanes-ci` must print one line per state change, never per poll. The README must say a headless lead gets no monitor.

## Summary of plan changes before M1

1. Status line: user wiring is required (Q1). `lanes init` prints the block.
2. Registry survives `/clear`: `session_id` changes, pane and name do not (Q2).
3. Every lane and the lead start with `claude --name <lane>`; the lane name is `session_title` (Q4).
4. Hooks use absolute `${CLAUDE_PLUGIN_ROOT}` paths, skills use bare `lanes` (Q5).
5. `lanes-ci` is a `bin/` script with an optional monitors entry (Q6).
6. The `SessionStart(clear)` hook must stay fast and synchronous (Q3).
