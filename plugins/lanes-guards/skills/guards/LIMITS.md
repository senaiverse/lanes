# What the lanes guards do not do

- The lead-only rule matches words, not commands. A lane's command is refused when its text holds every word of a
  lead-only pattern, in any order and anywhere on the line (`gh`, `pr` and `merge` for `gh pr merge`; `git` and `push`
  for `git push @default`). Patterns and command text are read the same way: lowercased, with `$'...'` decoded, line
  continuations joined, quotes and backslashes read both as nothing and as breaks, and a hyphen inside a word read as
  a break (`make deploy-prod` is the words `make`, `deploy` and `prod`).
- Only a full parse lifts a refusal, and only when it proves every mention harmless: the arguments of `git commit`
  and of `gh pr|issue create|comment|edit`, the operands of `grep` and of `rg` without `--pre`, and the arguments and
  stdin of `echo`, `cat` and `printf` (not when its first word is an option or an expansion). Each of these counts
  only when its output reaches no other command: no pipe after it, no output redirection, process substitution or
  coprocess beside it, and any substitution it runs in is itself such an argument. And none counts for a command a
  configured pattern names (`git commit` under `git commit --amend`). The one allowed push form lifts only
  `git push @default`; a pattern such as plain `git push` refuses every push. Each command is read behind what bash
  reads before a command name: reserved words (`{`, `if`, `then`, `!`, `time -p`, `do` ...), assignments, and the
  `builtin`, `command` and `exec` builtins with their options, so `{ git commit -m ...; }` is data and a `cd` inside
  `if ...; then` is seen. A data command behind any other wrapper (`timeout 60 git push ...`, `sudo git commit ...`) is
  not data. A quoted reserved word is read as the reserved word. Nothing is proven when the parse fails, when a
  pattern word sits somewhere the parser does not read (a comment, a redirection target, a heredoc delimiter), or when
  the line defines a function.
- So some normal commands are refused because they name all of a pattern's words: `gh pr view 5 && git merge x`,
  `gh workflow view ci.yml && gh run view 12`, `echo 'gh pr merge' | cat`, `grep -rn 'gh pr merge' docs | head`,
  `bash -c 'git push origin feat'`, `timeout 60 git push origin feat`. Split such a line into separate commands, or
  ask the lead.
- Words the text never holds are not seen: a variable set before the line or outside it, a script file (`bash
  script.sh`, `cat - ./x.sh | bash`), a git or gh alias, `ssh`, a file a previous command wrote. It is a mistake guard,
  not a sandbox.
- A lane's `git push` passes only in the explicit form in SKILL.md. A push with no refspec, `--all`, `--mirror`, `--repo`,
  `--delete`, a glob, `HEAD`, `+`, `:`, several refspecs, another option, or a word with `$` is refused rather than
  predicted, because git config or the checkout decides what it pushes.
- The remote must be one configured in the checkout (`remote.<name>.url`); a URL or a path is refused. Its default
  branches are the `default_branch` setting plus the remote's head (`refs/remotes/<remote>/HEAD`). When neither is known
  the push is refused: run `git remote set-head <remote> --auto` once, or set `default_branch`.
- The checkout is the session directory, or the path of one leading `cd <absolute path> &&` with no `..`, then `-C`.
  Any other directory change anywhere on the line, nested or not and before or after the push, refuses every lane push
  on it: `cd`, `pushd`, `popd`, `eval`, `source`, `.`, a command word with `$`, a `GIT_DIR` or `GIT_COMMON_DIR`
  assignment, or an `export` of one of those or of a `GIT_CONFIG_*`, `HOME` or `XDG_CONFIG_HOME` variable.
- git maps a plain `<name>` through `remote.<remote>.push`, `push.default=upstream` (or `tracking`) and a symref
  branch, so the plain form passes only when none of those is set in the target checkout and the line assigns no
  `GIT_CONFIG_*`, `HOME` or `XDG_CONFIG_HOME` (which move the global config). Otherwise use
  `git push <remote> <name>:<name>`, which passes unless `<name>` is a symref to a default branch. A config change made
  earlier in the same command line, or a variable exported before the session, is not seen.
- Malformed hook input passes with a stderr note, unless the text still names a lead-only command. The same holds when
  `jq` is not installed: a call naming a lead-only command is refused (exit 2), anything else passes with a note.
- Destructive commands (`rm -rf`, `git reset --hard`) are not covered: use destructive_command_guard or cc-safety-net.
