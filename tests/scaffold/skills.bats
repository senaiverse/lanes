#!/usr/bin/env bats
# Skill contract for every plugin, present and future: plugins/*/skills/*/SKILL.md and plugins/*/agents/*.md.
# Limits: description 1-1024 characters (https://agentskills.io/specification "description field"; Claude Code
# truncates the listing at 1,536, https://code.claude.com/docs/en/skills); SKILL.md under 500 lines (same two pages).
# check_root takes a repo root, so the tests below can run it on a temp copy with a planted defect.

load ../helpers/common

ROOT="$BATS_TEST_DIRNAME/../.."

# One frontmatter field's value: the text between the first two --- lines, quotes removed, a folded or literal
# block (> or |) joined onto one line. Prints nothing when the field is absent.
fm_field() { # file key
  awk -v key="$2" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    block && /^[ \t]+/ { sub(/^[ \t]+/, ""); val = val (val == "" ? "" : " ") $0; next }
    { block = 0 }
    index($0, key ":") == 1 {
      val = substr($0, length(key) + 2); sub(/^[ \t]+/, "", val); sub(/[ \t]+$/, "", val)
      if (val ~ /^[>|][-+]?$/) { block = 1; val = ""; found = 1; next }
      found = 1
    }
    END {
      if (!found) exit
      if (val ~ /^".*"$/ || val ~ /^'"'"'.*'"'"'$/) val = substr(val, 2, length(val) - 2)
      print val
    }' "$1"
}

# The file with fenced code blocks removed, so example snippets are not read as real links or commands.
unfenced() { awk '/^[ \t]*(```|~~~)/ { f = !f; next } !f' "$1"; }

check_root() { # repo root; prints one "file: reason" line per violation
  local root="$1" file plugin pdir kind name desc lines path link target bin cmd sub
  for file in "$root"/plugins/*/skills/*/SKILL.md "$root"/plugins/*/agents/*.md; do
    [ -f "$file" ] || continue
    pdir="${file%%/skills/*}"; pdir="${pdir%%/agents/*}"
    plugin="${pdir##*/}"
    kind=agent; case "$file" in */SKILL.md) kind=skill ;; esac
    name="$(fm_field "$file" name)"; desc="$(fm_field "$file" description)"
    [ -n "$name" ] || echo "$file: frontmatter has no name"
    [ -n "$desc" ] || echo "$file: frontmatter has no description (or it is empty)"
    [ "${#desc}" -le 1024 ] || echo "$file: description is ${#desc} characters, over the 1024 limit"
    if [ "$kind" = skill ]; then
      lines="$(wc -l <"$file")"
      [ "$lines" -le 500 ] || echo "$file: $lines lines, over the 500-line limit"
    fi
    # (d) every ${CLAUDE_PLUGIN_ROOT}/<path> exists in its plugin
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      [ -e "$pdir/${path#'${CLAUDE_PLUGIN_ROOT}'/}" ] || echo "$file: names $path, which is not in $plugin"
    done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[^][:space:])`"'"'"'<>]*[^][:space:])`"'"'"'<>.,;:]' "$file" || true)
    # (e) every relative markdown link resolves from the file's own directory
    while IFS= read -r link; do
      target="${link#\](}"; target="${target%)}"; target="${target%%#*}"
      case "$target" in ''|http://*|https://*|mailto:*|/*) continue ;; esac
      [ -e "$(dirname "$file")/$target" ] || echo "$file: link target $target does not exist"
    done < <(unfenced "$file" | grep -oE '\]\([^)[:space:]]+\)' || true)
    # (f) `<binname> <subcommand>` in backticks appears in that script's case dispatch or usage text
    [ "$kind" = skill ] || continue
    for bin in "$pdir"/bin/*; do
      [ -f "$bin" ] || continue
      cmd="${bin##*/}"
      while IFS= read -r sub; do
        sub="${sub#\`}"; sub="${sub#"$cmd "}"; sub="${sub%%[ \`]*}"
        printf '%s' "$sub" | grep -qE '^[a-z][a-z0-9-]*$' || continue
        grep -qE "(^|[[:space:]|(])$sub[|)]" "$bin" \
          || grep -qE "^[[:space:]]+$sub([[:space:]]|\$)" "$bin" \
          || grep -iE 'usage' "$bin" | grep -qw -- "$sub" \
          || echo "$file: \`$cmd $sub\` is not a subcommand of $cmd (not in its case dispatch or usage text)"
      done < <(unfenced "$file" | grep -oE "\`$cmd [^\`]*\`" || true)
    done
  done
}

# A temp copy of the repo's plugins to plant a defect in.
copy_plugins() {
  COPY="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$COPY"
  cp -R "$ROOT/plugins" "$COPY/plugins"
}

@test "every skill and agent in the repo meets the contract" {
  run check_root "$ROOT"
  assert_output ""
}

@test "the contract finds at least one skill and one agent, so it is not vacuous" {
  run bash -c 'ls "$1"/plugins/*/skills/*/SKILL.md "$1"/plugins/*/agents/*.md | wc -l' _ "$ROOT"
  [ "$output" -ge 2 ]
}

@test "(a) frontmatter without a name is caught" {
  copy_plugins
  sed -i.bak '/^name:/d' "$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  run check_root "$COPY"
  assert_output --partial "frontmatter has no name"
}

@test "(a) a file with no frontmatter is caught" {
  copy_plugins
  sed -i.bak '1d' "$COPY/plugins/lanes-review/agents/reviewer.md"
  run check_root "$COPY"
  assert_output --partial "frontmatter has no name"
}

@test "(b) an empty description is caught" {
  copy_plugins
  sed -i.bak 's/^description:.*/description: /' "$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  run check_root "$COPY"
  assert_output --partial "no description"
}

@test "(b) a description over 1024 characters is caught, and exactly 1024 is not" {
  copy_plugins
  local f="$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  sed -i.bak "s/^description:.*/description: $(printf 'x%.0s' $(seq 1 1024))/" "$f"
  run check_root "$COPY"
  assert_output ""
  sed -i.bak "s/^description: /description: y/" "$f"
  run check_root "$COPY"
  assert_output --partial "1025 characters"
}

@test "(c) a SKILL.md over 500 lines is caught" {
  copy_plugins
  seq 1 500 >>"$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  run check_root "$COPY"
  assert_output --partial "over the 500-line limit"
}

@test "(d) a CLAUDE_PLUGIN_ROOT path that does not exist is caught" {
  copy_plugins
  printf 'See `${CLAUDE_PLUGIN_ROOT}/templates/missing.md`.\n' >>"$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  run check_root "$COPY"
  assert_output --partial 'templates/missing.md, which is not in lanes-plancheck'
}

@test "(e) a relative link to a missing sibling is caught, a fenced one is not" {
  copy_plugins
  local f="$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  printf '\n```\n[example](not-real.md)\n```\n' >>"$f"
  run check_root "$COPY"
  assert_output ""
  printf '\nSee [the guide](guide.md).\n' >>"$f"
  run check_root "$COPY"
  assert_output --partial "link target guide.md does not exist"
}

@test "(f) a subcommand the script does not have is caught" {
  copy_plugins
  mkdir -p "$COPY/plugins/lanes-plancheck/bin"
  printf '#!/usr/bin/env bash\necho "usage: lanes-plancheck <plan>"\n' >"$COPY/plugins/lanes-plancheck/bin/lanes-plancheck"
  printf '\nRun `lanes-plancheck frobnicate` first.\n' >>"$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  run check_root "$COPY"
  assert_output --partial "lanes-plancheck frobnicate"
}

@test "(f) a subcommand in the script's case dispatch passes" {
  copy_plugins
  mkdir -p "$COPY/plugins/lanes-plancheck/bin"
  printf 'case "$1" in\n  start) ;;\nesac\n' >"$COPY/plugins/lanes-plancheck/bin/lanes-plancheck"
  printf '\nRun `lanes-plancheck start` first.\n' >>"$COPY/plugins/lanes-plancheck/skills/plancheck/SKILL.md"
  run check_root "$COPY"
  assert_output ""
}

@test "(f) a plugin with no bin is skipped" {
  copy_plugins
  mkdir -p "$COPY/plugins/lanes-review/skills/x"
  printf -- '---\nname: x\ndescription: Does x. Use for x.\n---\nRun `anything go` now.\n' >"$COPY/plugins/lanes-review/skills/x/SKILL.md"
  run check_root "$COPY"
  assert_output ""
}
