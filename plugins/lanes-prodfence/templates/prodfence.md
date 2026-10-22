# Production fence

Copy this file to `.lanes/prodfence.md` in your project and replace the examples. Each `- item` under a heading that
contains the word Markers is one marker. A line that starts with words and a colon is a key; case, spaces and hyphens in
the key name do not matter. Other prose is ignored. An unknown or repeated key, or a `- item` under any other level-2
heading, stops the fence from passing anything until it is fixed, so a typo cannot open it.

```
markers_file: ~/.config/lanes/prodfence-markers.txt
fence_file_content: off
protected_paths: deploy/production/*; infra/prod/*.tf; .env.production
```

- `markers_file`: a file with one marker per line (`#` lines and blank lines are skipped). Keep private markers there,
  outside the repository. `~/` means your home directory; a relative path is read from `.lanes/`. Leave the key out if
  every marker is listed below.
- `fence_file_content`: `on` also refuses Edit, Write and NotebookEdit whose content mentions a marker. Default `off`,
  because config files and docs legitimately name hosts. A file path that mentions a marker is refused either way.
- `protected_paths`: globs separated by `;`. Read, Edit, Write and NotebookEdit of a matching file are refused, and so
  is a Bash, PowerShell or Monitor command that mentions a glob's text before its first wildcard. A glob matches the
  path as given or its real path (symlinks and `..` resolved), absolute or below the project root, and a glob without
  `/` also matches the file name. A glob's directory is resolved too, so a glob written through a symlink, or naming a
  symlinked directory, also matches the real path. `*` matches across `/`, and case is ignored on every filesystem.

The plugin's userConfig options `markers` and `protected_paths` add to these, as lists separated by `;` (a comma in
`markers` is refused, because it is not a separator).

A command can reach production without naming a host, for example `source .env.production && psql "$DATABASE_URL"`.
List the production env file names and the commands that act on a linked or remote project as markers, as below.

## Markers

- example-prod.db.example.com
- postgres://example-prod
- example-prod-project-123456
- example-prod-cluster
- .env.production
- deploy --env production
- db push --linked
- EXAMPLE_PROD_DATABASE_URL
