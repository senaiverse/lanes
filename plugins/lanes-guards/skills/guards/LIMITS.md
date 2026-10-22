# What the lanes guards do not do

- A lane's `git push` passes only in the explicit form in SKILL.md. A push with no refspec, `--all`, `--mirror`, `--repo`,
  `--delete`, a glob, `HEAD`, `+`, `:`, several refspecs, another option, or a word with `$` is refused rather than
  predicted, because git config or the checkout decides what it pushes.
- The remote must be one configured in the checkout (`remote.<name>.url`); a URL or a path is refused. Its default
  branches are the `default_branch` setting plus the remote's head (`refs/remotes/<remote>/HEAD`). When neither is known
  the push is refused: run `git remote set-head <remote> --auto` once, or set `default_branch`.
- The checkout is the session directory, followed through a literal `cd` or `pushd` and `-C`. After a `cd` the guard
  cannot resolve (none, `-`, `~`, a `$` word), `popd`, a `GIT_DIR` or `GIT_COMMON_DIR` prefix, an `export` of one of
  those or of a `GIT_CONFIG_*` variable, `env -C` or `sudo -D`, a lane push is refused. A `cd` inside `( )` or `$( )` is
  read as if it changed the directory for the rest of the line.
- git maps a plain `<name>` through `remote.<remote>.push`, `push.default=upstream` (or `tracking`) and a symref
  branch, so the plain form passes only when none of those is set in the target checkout and the command has no
  `GIT_CONFIG_*` prefix. Otherwise use `git push <remote> <name>:<name>`, which passes unless `<name>` is a symref to a
  default branch. A config change made earlier in the same command line, or a variable exported before the session,
  is not seen.
- It parses `&&`, `;`, `|`, env prefixes, `bash -c`, `eval`, `$(...)`, backticks, quotes (`$'...'` decoded) and line
  continuations. It reads a script fed to a shell by its own heredoc or here-string, a piped bare `cat` heredoc or a
  piped `echo` of literal words. Any other producer (`printf`, `cat file`, `curl`) is refused when its text names a
  lead-only command, and otherwise passes. It does not follow a variable it cannot resolve, `ssh`, `find -exec`, a
  script file or process substitution. It is a mistake guard, not a sandbox.
- Value-taking global flags are known for `gh` and `git` only.
- Malformed hook input passes with a stderr note, unless the text still names a lead-only command. The same holds when
  `jq` is not installed: a call naming a lead-only command is refused (exit 2), anything else passes with a note.
- Destructive commands (`rm -rf`, `git reset --hard`) are not covered: use destructive_command_guard or cc-safety-net.
