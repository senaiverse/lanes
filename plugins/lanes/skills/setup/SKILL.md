---
name: setup
description: Set lanes up in this project.
disable-model-invocation: true
argument-hint: "[check]"
---

# Set up lanes

This is a prompt-driven skill, not a deterministic script. Explore the repository, present what you found, ask only
what exploration left open, confirm a draft, then write. One part is deterministic: `lanes check-adapters` must pass,
and setup is done only then.

Setup owns four things. Each is edited in place and exists at most once:

- **journal**: the folder `lanes journal-dir` prints, seeded from `${CLAUDE_PLUGIN_ROOT}/templates/journal`.
- **status line**: the `statusLine` block in the human's settings. It records each lane's context %, which a plugin
  cannot set up itself.
- **pointer block**: one `## Lanes` section in the project's CLAUDE.md that imports the journal's `RULES.md`.
- **adapters**: `<journal>/adapters.md`, this project's facts in the fixed shape of
  `${CLAUDE_PLUGIN_ROOT}/templates/adapters.md`. Its comment lines define each key.

When lanes-guards is installed, setup also writes the lead-only command list. Its one home is the
`lead_only_commands:` line of lanes-guards' `.lanes/guards.md` at the repository root; the adapter file has no copy.

With the argument `check`, or when the human asks to check only, run step 1 and then step 6, and write nothing.

## 1. Explore

Read what exists and assume nothing:

- The journal: `lanes journal-dir`, which template files are already there, and which lanes have a `next-<lane>.md`.
- `<journal>/adapters.md`, when present: its values are the starting answers.
- The project's CLAUDE.md (repository root, or `.claude/CLAUDE.md`): a `## Lanes` section, or an `@<journal>/RULES.md`
  line outside it.
- `statusLine` in `~/.claude/settings.json`, `.claude/settings.json` and `.claude/settings.local.json`.
- CI: the workflow files (`.github/workflows/`, `.gitlab-ci.yml`, `.circleci/`, and the like), their triggers, and
  `git remote -v`, which tells you the host and so its CLI (`gh`, `glab`).
- Tests: `package.json` scripts, a Makefile, `scripts/test*`, the CI job that runs them, and how long a run takes.
- The review gate: CONTRIBUTING, the PR template, the project's CLAUDE.md.
- Pre-push hooks and the deny-list file they read, if any.
- `command -v lanes-guard`: whether lanes-guards is installed, and its `.lanes/guards.md` at the repository root.

Done when every row of the table in step 2 has a value with its evidence (a file:line or a command's output), or is
marked open.

## 2. Ask

For each open row, in table order, ask one question with the ask tool (`AskUserQuestion`). Put the recommended answer
first, labelled "(Recommended)", so accepting it takes one click, and give the evidence behind it. Skip every row
exploration settled; it appears in the draft instead. Finding facts is your job; the human answers what the repository
cannot.

| Row | Becomes | Recommended when nothing settles it |
|---|---|---|
| Lane names | `next-<lane>.md` and `done-<lane>.md` | none now; run setup again when lanes are added |
| `ci_command` | adapter line | the CLI dispatch of the main workflow; empty when CI starts only on push |
| `ci_status_command` | adapter line | the host CLI's run list, latest run only (`gh run list --limit 1`) |
| `review_gate` | adapter line | what CONTRIBUTING requires; else "the reviewer passes, then the human approves" |
| `lead_only_commands`, only with lanes-guards | `.lanes/guards.md` line | empty, which keeps the lanes-guards default |
| `test_runner`, `test_command` | adapter lines | `local` with the script found, when a run here takes minutes; else `ci` |
| `deny_list` | adapter line | the file the pre-push hook reads; else empty |
| Status line | settings | add it to `~/.claude/settings.json` |
| Pointer block | CLAUDE.md | add it |

Every adapter value is one line. A lane name uses letters, digits, dot, dash and underscore, starts with a letter or
digit, and has at most 64 characters.

Done when every row has an answer.

## 3. Confirm

Show the draft in one message:

- each journal file to create, and each one kept because it exists;
- the whole `adapters.md`;
- the `lead_only_commands:` line for `.lanes/guards.md`, when lanes-guards is installed;
- the `## Lanes` block and the file it goes in;
- the `statusLine` block and the settings file it goes in.

Ask with the ask tool: "Write this (Recommended)" or "Change something". A change goes back to its row in step 2 and
then to a new draft.

Done when the human approved this exact draft.

## 4. Write

1. **Journal.** Copy each file of `${CLAUDE_PLUGIN_ROOT}/templates/journal` except the two lane templates into the
   journal, only when it is absent. For each lane, write `next-<lane>.md` from
   `${CLAUDE_PLUGIN_ROOT}/templates/journal/next-lane.md` and `done-<lane>.md` from
   `${CLAUDE_PLUGIN_ROOT}/templates/journal/done-lane.md`, every `<lane>` replaced by the name, only when absent. A
   file that exists stays byte for byte.
2. **Adapters.** When `adapters.md` is absent, copy `${CLAUDE_PLUGIN_ROOT}/templates/adapters.md` there and fill in
   each value. When it exists, change only the value of each line whose answer changed.
3. **Guards.** When lanes-guards is installed and the answer for `lead_only_commands` is not empty, set the
   `lead_only_commands:` line of `.lanes/guards.md` to it. When that file is absent, call the Skill tool with
   "lanes-guards:guards" for its template first.
4. **Pointer block.** In the CLAUDE.md found in step 1, or a new CLAUDE.md at the repository root when there is none:

   ```markdown
   ## Lanes

   @<journal>/RULES.md

   - `<journal>/`: the journal. Each lane's state is the RESUME block in its `next-<lane>.md`.
   - `<journal>/adapters.md`: CI, review gate and tests, checked by `lanes check-adapters`.
   ```

   `<journal>` is the journal folder as configured (`.lanes` by default). When a `## Lanes` section exists, replace its
   body up to the next heading of level one or two. Remove an `@<journal>/RULES.md` line outside the block, so the
   file imports it once.
5. **Status line.** The command is `"<data>/lanes-statusline"`, where `<data>` is the value of
   `${LANES_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lanes}` in Bash. When `LANES_DATA_DIR` is set, put
   `LANES_DATA_DIR="<its value>" ` before the command. The block is
   `{"statusLine": {"type": "command", "command": "<command>", "refreshInterval": 30}}`. The SessionStart hook keeps
   that link pointing at the installed plugin; when `ls -l <data>/lanes-statusline` finds no link, this session started
   without the plugin, so ask the human to restart it. To add the block, merge it into the settings file with `jq`
   into a temp file in the same folder, then `mv`, keeping every other key.

Done when every file in the draft holds the drafted content: re-read each one.

## 5. Check

Run `lanes check-adapters`. When it refuses, fix the line it names, asking the human when the fix changes an answer,
and run it again. Then tell the human what was written and what was kept, to commit the journal (a lane with a dirty
tree is never clear-ready), and to start each lane in its own tmux pane as `claude --name <lane>` and the lead as
`LANES_ROLE=lead claude --name <lead>`.

Done when `lanes check-adapters` printed `adapters ok` and the human has that summary.

## 6. Check only

Change nothing. Report one line per item, "ok" or the drift found:

- journal files missing, and lanes with a `next-<lane>.md` but no `done-<lane>.md`;
- `adapters.md` absent, or the output of `lanes check-adapters`;
- adapter values the repository now contradicts (a renamed workflow, a removed script);
- the `## Lanes` block absent or repeated, or `RULES.md` imported more than once;
- `statusLine` absent, or pointing at another command.

Done when every item has its line, and any drift ends with "run /lanes:setup to fix it".
