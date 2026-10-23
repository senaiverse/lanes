# What the lanes guards do not do

- A lane's `git push` passes only in the explicit form in SKILL.md. A push with no refspec, `--all`, `--mirror`, `--repo`,
  `--delete`, a glob, `HEAD`, `+`, `:`, several refspecs, another option, or a word with `$` is refused rather than
  predicted, because git config or the checkout decides what it pushes.
- The remote must be one configured in the checkout (`remote.<name>.url`); a URL or a path is refused. Its default
  branches are the `default_branch` setting plus the remote's head (`refs/remotes/<remote>/HEAD`). When neither is known
  the push is refused: run `git remote set-head <remote> --auto` once, or set `default_branch`.
- The checkout is the session directory, or the path of one leading `cd <absolute path> &&` with no `..`, then `-C`.
  Any other directory change anywhere on the line, nested or not and before or after the push, refuses every lane push
  on it: `cd`, `pushd`, `popd`, a command word with `$`, a `GIT_DIR` or `GIT_COMMON_DIR` assignment, an `export` of one
  of those or of a `GIT_CONFIG_*`, `HOME` or `XDG_CONFIG_HOME` variable, `env -C` or `sudo -D`.
- git maps a plain `<name>` through `remote.<remote>.push`, `push.default=upstream` (or `tracking`) and a symref
  branch, so the plain form passes only when none of those is set in the target checkout and the line assigns no
  `GIT_CONFIG_*`, `HOME` or `XDG_CONFIG_HOME` (which move the global config). Otherwise use `git push <remote> <name>:<name>`, which passes unless `<name>` is a symref to a
  default branch. A config change made earlier in the same command line, or a variable exported before the session,
  is not seen.
- It parses `&&`, `;`, `|`, env prefixes, `bash -c`, `eval`, `$(...)`, backticks, quotes (`$'...'` decoded) and line
  continuations. It reads a script fed to a shell by its own heredoc or here-string, a piped bare `cat` heredoc or a
  piped `echo` of literal words. Any other producer (`printf`, `cat file`, `curl`) is refused when its text names a
  lead-only command, and otherwise passes. It does not follow a variable it cannot resolve, `ssh`, `find -exec`, a
  script file or process substitution. It is a mistake guard, not a sandbox.
- Value-taking global flags are known for `gh` and `git` only. For a wrapper (`env`, `sudo`, `timeout`, `xargs` and
  the others in its list), a lone letter, a number and its listed value options are parsed; any other option form (a
  cluster such as `-iu`, an attached value such as `-S'...'`, a long option) adds the rest of the command to the loose
  match. A wrapper outside the list (`stdbuf`, `flock`, `watch`) is not followed.
- Malformed hook input passes with a stderr note, unless the text still names a lead-only command. The same holds when
  `jq` is not installed: a call naming a lead-only command is refused (exit 2), anything else passes with a note.
- Destructive commands (`rm -rf`, `git reset --hard`) are not covered: use destructive_command_guard or cc-safety-net.
