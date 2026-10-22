#!/usr/bin/env bash
# Runs `claude plugin validate --strict` on every plugin that has a plugin.json, then on the marketplace.
# The CLI is not installed in CI, so its absence is a notice, not a failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v claude >/dev/null 2>&1; then
  echo "lanes-validate: claude CLI not found: skipping plugin validation (run it locally before a commit)"
  exit 0
fi

status=0
for manifest in "$ROOT"/plugins/*/.claude-plugin/plugin.json; do
  [ -e "$manifest" ] || continue
  plugin_dir="${manifest%/.claude-plugin/plugin.json}"
  echo "lanes-validate: $plugin_dir"
  claude plugin validate --strict "$plugin_dir" || status=1
done

echo "lanes-validate: marketplace"
claude plugin validate --strict "$ROOT" || status=1

exit "$status"
