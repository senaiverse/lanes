# shellcheck shell=bash
# lanes adapters: `lanes check-adapters [file]`, the contract test for the fixed-shape adapter file that /lanes:setup
# writes from templates/adapters.md, and of the lead-only list in lanes-guards' .lanes/guards.md when lanes-guards is
# installed. Setup is done only when this passes, so every refusal names its line and the fix.
# bin/lanes sources this file after its journal helpers; it only defines functions.

ADAPTER_KEYS=(ci_command ci_status_command review_gate test_runner test_command deny_list)
ADAPTER_REQUIRED=" review_gate test_runner test_command "
ADAPTER_COMMANDS=(ci_command ci_status_command test_command)

# first_word <command line>: the program it runs, after any VAR=value words.
first_word() {
  local w
  local -a words
  read -ra words <<<"$1"
  for w in "${words[@]}"; do
    [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { printf '%s' "$w"; return 0; }
  done
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# guard_refuses <scratch dir> <pattern>: true when lanes-guard, given the pattern as its only lead-only command, refuses
# the pattern's own words from an unregistered session. A pattern it lets through is one its parser cannot match.
guard_refuses() {
  local tmp="$1" cmd out
  local -a words
  read -ra words <<<"$2"
  cmd=" ${words[*]:-}"
  cmd="${cmd% @default}"
  printf 'lead_only_commands: %s\n' "$2" >"$tmp/.lanes/guards.md"
  out="$(jq -nc --arg c "${cmd# }" --arg d "$tmp" '{session_id: "lanes-check-adapters", cwd: $d, tool_name: "Bash",
    tool_input: {command: $c}}' | CLAUDE_PROJECT_DIR="$tmp" LANES_DATA_DIR="$tmp/data" lanes-guard lead-only 2>/dev/null)" || true
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<<"$out"
}

cmd_check_adapters() {
  (($# <= 1)) || usage
  local file="${1:-$(journal_root "$PWD")/adapters.md}" top n=0 line key val bad=0 k w runner p scratch guards list
  local -A at=() vals=()
  [[ -f "$file" ]] || die "no adapter file at $file" "run /lanes:setup to write it, or pass the file to check"
  top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  problem() { echo "lanes: ${3:-$file}${2:+:$2}: $1" >&2; bad=1; } # problem <message> [line] [file]

  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^([a-z][a-z_]*):(.*)$ ]]; then
      problem "not a 'key: value' line: write it as 'key: value', or start a comment with #" "$n"
      continue
    fi
    key="${BASH_REMATCH[1]}" val="$(trim "${BASH_REMATCH[2]}")"
    if [[ " ${ADAPTER_KEYS[*]} " != *" $key "* ]]; then
      problem "unknown key '$key': the keys are $(printf '%s, ' "${ADAPTER_KEYS[@]}" | sed 's/, $//')" "$n"
    elif [[ -n "${at[$key]:-}" ]]; then
      problem "key '$key' is repeated (first on line ${at[$key]}): keep one line" "$n"
    else
      at[$key]="$n" vals[$key]="$val"
    fi
  done <"$file"

  for k in "${ADAPTER_KEYS[@]}"; do
    if [[ -z "${at[$k]:-}" ]]; then
      problem "key '$k' is missing: add the line '$k: <value>' (the shape is in the plugin's templates/adapters.md)"
    elif [[ -z "${vals[$k]}" && "$ADAPTER_REQUIRED" == *" $k "* ]]; then
      problem "key '$k' has no value: it is required" "${at[$k]}"
    fi
  done
  runner="${vals[test_runner]:-}"
  [[ -z "$runner" || "$runner" == local || "$runner" == ci ]] || problem "test_runner is '$runner': use local or ci" "${at[test_runner]}"

  # A CI command reaches a remote service and may be installed only where the lead runs it, so a missing one warns;
  # so does the test command when the tests run on CI. A local test command must run here.
  for k in "${ADAPTER_COMMANDS[@]}"; do
    [[ -n "${vals[$k]:-}" ]] || continue
    w="$(first_word "${vals[$k]}")"
    [[ -n "$w" ]] && (cd "$top" && command -v -- "$w" >/dev/null 2>&1) && continue
    if [[ "$k" != test_command || "$runner" == ci ]]; then
      echo "lanes: warning: $file:${at[$k]}: $k: '$w' is not on PATH here: it is a remote CLI, so check it where the lead runs it" >&2
    else
      problem "$k: '$w' is not on PATH: install it, or fix the command (a path is read from the repository root)" "${at[$k]}"
    fi
  done

  # The lead-only list's one home is lanes-guards' config. It is read as lanes-guard reads it: the last line wins.
  guards="$top/.lanes/guards.md"
  if command -v lanes-guard >/dev/null 2>&1 && [[ -f "$guards" ]]; then
    line="$(grep -nE '^[[:space:]]*lead_only_commands:' "$guards" | tail -n 1 || true)"
    n="${line%%:*}" list="$(trim "${line#*lead_only_commands:}")"
    if [[ -n "$list" ]]; then
      scratch="$(mktemp -d)"
      mkdir -p "$scratch/.lanes" "$scratch/data"
      while IFS= read -r p; do
        p="$(trim "$p")"
        [[ -z "$p" ]] || guard_refuses "$scratch" "$p" ||
          problem "lead_only_commands: lanes-guard does not refuse '$p' itself, so it cannot parse that pattern: write it as the plain words of the command, as in 'gh pr merge'" "$n" "$guards"
      done <<<"${list//;/$'\n'}"
      rm -rf "$scratch"
    fi
  fi

  ((bad == 0)) || die "the adapter check failed" "fix each line named above, then run 'lanes check-adapters' again"
  echo "adapters ok: $file"
}
