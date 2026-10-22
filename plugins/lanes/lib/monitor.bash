# shellcheck shell=bash
# jq programs are single-quoted on purpose: their $names are jq variables, not shell ones.
# shellcheck disable=SC2016
# lanes monitors: two helpers for the read-only watchers in skills/lead/MONITORS.md, which are shell loops the lead
# runs through the Monitor tool. They hold what a snippet would get wrong: one live instance per name, and a per-item
# state diff written atomically. bin/lanes sources this file after its lock and JSON helpers; it only defines functions.

MON="$DATA/monitors"

valid_monitor() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }

# cmd_monitor_lock <name> <pid>: the watcher loop (its own $$) holds <name> while it lives. A second start is refused
# while that pid is alive; a dead holder's lock is reclaimed. The lock is never released: the holder's death frees it.
cmd_monitor_lock() {
  local name="${1:-}" pid="${2:-}"
  if ! valid_monitor "$name" || [[ ! "$pid" =~ ^[0-9]+$ ]]; then usage; fi
  kill -0 "$pid" 2>/dev/null || die "monitor $name: pid $pid is not running" "pass the watcher loop's own pid (\$\$)"
  mkdir -p "$MON"
  lock_take "$MON/$name.lnk" 0 "$pid" ||
    die "monitor $name is already running (pid $(lock_holder "$MON/$name.lnk"))" "leave it running; one watcher per signal"
  echo "monitor $name: running as pid $pid"
}

# cmd_monitor_diff <name>: stdin is the whole current set, one "<item><TAB><state>" line per item. Prints
# "<item>: <old> -> <new>" for each changed or new item (old "none") and "<item>: gone" for each item that left, then
# stores the set. The first pass prints every item once, as the baseline.
cmd_monitor_diff() {
  local name="${1:-}" cur old
  valid_monitor "$name" || usage
  mkdir -p "$MON"
  cur="$(jq -Rnc '[inputs | select(test("\t")) | split("\t") | {key: .[0], value: (.[1:] | join("\t"))}] | from_entries')"
  old="$(jq -c 'select(type == "object")' "$MON/$name.state" 2>/dev/null || true)"
  [[ -n "$old" ]] || old='{}'
  jq -rn --argjson a "$old" --argjson b "$cur" '
    ($b | to_entries[] | select($a[.key] != .value) | "\(.key): \($a[.key] // "none") -> \(.value)"),
    ($a | keys[] | select(. as $k | $b | has($k) | not) | "\(.): gone")'
  write_atomic "$MON/$name.state" "$cur"
}

# monitors_down: the watchers that ran here before (a state file exists) and have no live holder now.
monitors_down() {
  local f name down=()
  for f in "$MON"/*.state; do
    [[ -e "$f" ]] || continue
    name="${f##*/}"
    name="${name%.state}"
    kill -0 "$(lock_holder "$MON/$name.lnk")" 2>/dev/null || down+=("$name")
  done
  echo "${down[*]}"
}
