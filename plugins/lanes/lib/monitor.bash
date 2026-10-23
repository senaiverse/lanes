# shellcheck shell=bash
# jq programs are single-quoted on purpose: their $names are jq variables, not shell ones.
# shellcheck disable=SC2016
# lanes monitors: two helpers for the read-only watchers in skills/lead/MONITORS.md, which are shell loops the lead
# runs through the Monitor tool. They hold what a snippet would get wrong: one live instance per name and project, and
# a per-item state diff written atomically. bin/lanes sources this file after its lock and JSON helpers.

MON="$DATA/monitors"

valid_monitor() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }

# monitor_dir <project>: the folder of that project's watchers (caller_project, lane_project), so two projects each run
# their own `ci`. The folder is named by a checksum of the project path, which can hold any character.
monitor_dir() { printf '%s/%s' "$MON" "$(hash_of "$1")"; }

# monitor_live <lock>: the watcher holding <lock> is proven to run (holder_state, the rule of every lock).
monitor_live() { holder_state "$(readlink "$1" 2>/dev/null || true)"; }

# cmd_monitor_lock <name> <pid>: the watcher loop (its own $$) holds <name> in the caller's project (caller_project)
# while it lives. A second start is refused while that holder runs; a lock whose holder is proven dead is reclaimed
# (lock_take). The lock is never released: the holder's death frees it.
cmd_monitor_lock() {
  local name="${1:-}" pid="${2:-}" lock
  if ! valid_monitor "$name" || [[ ! "$pid" =~ ^[0-9]+$ ]]; then usage; fi
  lock_tag "$pid" >/dev/null || die "monitor $name: pid $pid is not running" "pass the watcher loop's own pid (\$\$)"
  lock="$(monitor_dir "$(caller_project)")/$name.lnk"
  mkdir -p "${lock%/*}"
  lock_take "$lock" 0 "$pid" ||
    die "monitor $name is already running (pid $(lock_holder "$lock"))" "leave it running; one watcher per signal"
  echo "monitor $name: running as pid $pid"
}

# cmd_monitor_diff <name>: stdin is the whole current set, one "<item><TAB><state>" line per item. Prints
# "<item>: <old> -> <new>" for each changed or new item (old "none") and "<item>: gone" for each item that left, then
# stores the set for the caller's project (caller_project). The first pass prints every item once, as the baseline.
cmd_monitor_diff() {
  local name="${1:-}" cur old dir
  valid_monitor "$name" || usage
  dir="$(monitor_dir "$(caller_project)")"
  mkdir -p "$dir"
  cur="$(jq -Rnc '[inputs | select(test("\t")) | split("\t") | {key: .[0], value: (.[1:] | join("\t"))}] | from_entries')"
  old="$(jq -c 'select(type == "object")' "$dir/$name.state" 2>/dev/null || true)"
  [[ -n "$old" ]] || old='{}'
  jq -rn --argjson a "$old" --argjson b "$cur" '
    ($b | to_entries[] | select($a[.key] != .value) | "\(.key): \($a[.key] // "none") -> \(.value)"),
    ($a | keys[] | select(. as $k | $b | has($k) | not) | "\(.): gone")'
  write_atomic "$dir/$name.state" "$cur"
}

# The four watchers of skills/lead/MONITORS.md, so a fresh install reports them all as down.
MONITOR_NAMES=(ci reviews context drift)

# monitors_down <project>: in that project, the four watchers plus any other that ran there before (a state file
# exists), with no live holder.
monitors_down() {
  local f name names=("${MONITOR_NAMES[@]}") down=() dir
  dir="$(monitor_dir "$1")"
  for f in "$dir"/*.state; do
    [[ -e "$f" ]] || continue
    name="${f##*/}"
    name="${name%.state}"
    [[ " ${names[*]} " == *" $name "* ]] || names+=("$name")
  done
  for name in "${names[@]}"; do
    monitor_live "$dir/$name.lnk" || down+=("$name")
  done
  echo "${down[*]}"
}
