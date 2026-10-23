# Setting up the production fence

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
