#!/usr/bin/env bats

load ../helpers/common

ROOT="$BATS_TEST_DIRNAME/../.."
MP="$ROOT/.claude-plugin/marketplace.json"

@test "marketplace.json is valid JSON with name, owner and plugins" {
  run jq -e '.name == "lanes" and .owner.name == "senaiverse" and (.plugins | type == "array")' "$MP"
  assert_success
}

@test "every entry has a ./plugins/<name> source and a description" {
  run jq -e '(.plugins | length) as $n | [.plugins[] | select(.source == ("./plugins/" + .name) and (.description | length > 0))] | length == $n' "$MP"
  assert_success
}

@test "every entry's source dir holds a plugin.json with the same name" {
  local name manifest
  while IFS= read -r name; do
    manifest="$ROOT/plugins/$name/.claude-plugin/plugin.json"
    [ -f "$manifest" ] || { echo "no plugin.json for marketplace entry: $name" >&2; false; }
    run jq -r .name "$manifest"
    assert_output "$name"
  done < <(jq -r '.plugins[].name' "$MP")
}

@test "every plugin dir is listed in the marketplace" {
  local dir name
  for dir in "$ROOT"/plugins/*/; do
    [ -f "${dir}.claude-plugin/plugin.json" ] || continue
    name="$(basename "$dir")"
    run jq -e --arg n "$name" '[.plugins[].name] | index($n) != null' "$MP"
    assert_success
  done
}

@test "no two entries share a name" {
  run jq -e '[.plugins[].name] | length == (unique | length)' "$MP"
  assert_success
}

@test "every plugin.json carries homepage and repository" {
  local manifest
  for manifest in "$ROOT"/plugins/*/.claude-plugin/plugin.json; do
    [ -e "$manifest" ] || continue
    run jq -e '.homepage == "https://github.com/senaiverse/lanes" and .repository == "https://github.com/senaiverse/lanes"' "$manifest"
    [ "$status" -eq 0 ] || { echo "homepage/repository missing: $manifest" >&2; false; }
  done
}
