#!/usr/bin/env bats
# The jobs skill quotes lanes-job's exit codes; these tests keep the two from drifting apart.

BIN="$BATS_TEST_DIRNAME/../../plugins/lanes-jobs/bin/lanes-job"
SKILL_DIR="$BATS_TEST_DIRNAME/../../plugins/lanes-jobs/skills/jobs"

# exit_list <file> <line prefix>: the "exit ..." tail of the one line that starts with the prefix.
exit_list() {
  grep -E "^$2" "$1" | sed -n 's/.*\(exit [0-9].*\)$/\1/p'
}

@test "the skill lists the same exit codes for status and wait as the script's usage header" {
  local sub script skill
  for sub in status wait; do
    script="$(exit_list "$BIN" "#   lanes-job $sub ")"
    skill="$(exit_list "$SKILL_DIR/SKILL.md" "lanes-job $sub ")"
    [ -n "$script" ]
    [ "$skill" = "$script" ] || { echo "$sub: skill '$skill' != script '$script'" >&2; return 1; }
  done
}

@test "every file the skill links to exists" {
  local link found=0
  while read -r link; do
    found=1
    [ -f "$SKILL_DIR/$link" ] || { echo "SKILL.md links to missing $link" >&2; return 1; }
  done < <(grep -o '([A-Za-z0-9_.-]*\.md)' "$SKILL_DIR/SKILL.md" | tr -d '()')
  [ "$found" -eq 1 ]
}
