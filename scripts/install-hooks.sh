#!/usr/bin/env bash
# Points this clone's git hooks at .githooks (the pre-push deny-list gate). Safe to run again.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$root" config core.hooksPath .githooks
echo "lanes-install-hooks: core.hooksPath = .githooks"
