#!/usr/bin/env bats
# Public seam: the lanes-prodfence executable as the PreToolUse and SessionStart hooks call it.
# Each test builds a project in a temp dir and feeds stdin shaped like the real hook input.

bats_require_minimum_version 1.5.0
load ../helpers/common

PLUGIN="$BATS_TEST_DIRNAME/../../plugins/lanes-prodfence"
BIN="$PLUGIN/bin/lanes-prodfence"

MARKER="example-prod.db.example.com"
PROJECT_MARKER="example-prod-project-42"

setup() {
  lanes_test_setup
  PROJ="$LANES_TEST_TMP/proj"
  mkdir -p "$PROJ/.lanes" "$PROJ/src"
  export CLAUDE_PROJECT_DIR="$PROJ"
  unset CLAUDE_PLUGIN_OPTION_MARKERS CLAUDE_PLUGIN_OPTION_PROTECTED_PATHS
  # Git Bash's ln -s copies by default; real symlinks are what the symlink tests need, and ln fails loudly without them.
  export MSYS="winsymlinks:nativestrict${MSYS:+ $MSYS}"
  cd "$PROJ"
}

teardown() { lanes_test_teardown; }

# config <line>...: writes .lanes/prodfence.md with the given lines.
config() {
  printf '%s\n' "$@" >"$PROJ/.lanes/prodfence.md"
}

# A config with both markers and one protected path, file content off.
default_config() {
  config "# Production fence" "" "protected_paths: deploy/prod/*; .env.production" "" "## Markers" "" \
    "- $MARKER" "- \`$PROJECT_MARKER\`"
}

# hook_input <tool_name> <tool_input-json> [session_id]: a PreToolUse stdin as Claude Code sends it.
hook_input() {
  jq -cn --arg t "$1" --argjson i "$2" --arg s "${3:-sess-lane-1}" --arg cwd "$PWD" '{
    session_id: $s, transcript_path: "/tmp/transcript.jsonl", cwd: $cwd, permission_mode: "default",
    hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i, tool_use_id: "toolu_01TEST"}'
}

bash_input() {
  hook_input Bash "$(jq -cn --arg c "$1" '{command: $c, description: "run it", timeout: 120000, run_in_background: false}')" "${2:-}"
}

guard() {
  run --separate-stderr "$BIN" guard <<<"$1"
}

assert_denied() {
  assert_success
  run jq -er '.hookSpecificOutput | select(.hookEventName == "PreToolUse" and .permissionDecision == "deny") | .permissionDecisionReason' <<<"$output"
  assert_success
  assert_output --partial "This touches production"
  assert_output --partial "Ask the human to run it"
}

assert_allowed() {
  assert_success
  assert_output ""
}

# The marker never appears in anything the fence prints, in any case.
refute_leaks() {
  local all="$output ${stderr:-}"
  all="${all,,}"
  [[ "$all" != *"${MARKER,,}"* && "$all" != *"${PROJECT_MARKER,,}"* ]] || { echo "marker leaked: $output / ${stderr:-}" >&2; false; }
}

@test "a Bash command naming a marker is refused; the same command without it passes" {
  default_config
  guard "$(bash_input "psql -h $MARKER -c 'select 1'")"
  assert_denied
  assert_output --partial "marker in tool_input.command"
  guard "$(bash_input "psql -h localhost -c 'select 1'")"
  assert_allowed
}

@test "the match ignores case" {
  default_config
  guard "$(bash_input "psql -h EXAMPLE-Prod.DB.example.COM")"
  assert_denied
  config "## Markers" "- PROD-Cluster-East"
  guard "$(bash_input "kubectl --context prod-cluster-east get pods")"
  assert_denied
}

@test "a marker inside quotes, a heredoc or unrelated text is still refused" {
  default_config
  guard "$(bash_input "echo \"the host is '$MARKER'\"")"
  assert_denied
  guard "$(bash_input "$(printf 'cat <<EOF >notes.txt\nconnect to %s later\nEOF' "$MARKER")")"
  assert_denied
  guard "$(bash_input "grep -r notes-about-${MARKER}-in-a-comment .")"
  assert_denied
}

@test "an MCP tool input carrying a project ID marker is refused" {
  default_config
  guard "$(hook_input mcp__clouddb__run_query "$(jq -cn --arg p "$PROJECT_MARKER" '{project_id: $p, query: "select 1"}')")"
  assert_denied
  assert_output --partial "marker in tool_input.project_id"
  guard "$(hook_input mcp__clouddb__run_query '{"project_id":"example-staging","query":"select 1"}')"
  assert_allowed
}

@test "a numeric MCP argument is matched as text" {
  config "## Markers" "- 987654321"
  guard "$(hook_input mcp__cloud__get_project '{"project_number":987654321}')"
  assert_denied
}

@test "WebFetch to a production URL is refused" {
  default_config
  guard "$(hook_input WebFetch "$(jq -cn --arg u "https://$MARKER/admin" '{url: $u, prompt: "summarise"}')")"
  assert_denied
  assert_output --partial "marker in tool_input.url"
}

@test "Edit and Write on a protected path are refused, by relative glob or by file name" {
  default_config
  guard "$(hook_input Edit "$(jq -cn --arg f "$PROJ/deploy/prod/app.yaml" '{file_path: $f, old_string: "a", new_string: "b", replace_all: false}')")"
  assert_denied
  assert_output --partial "protected path in tool_input.file_path"
  guard "$(hook_input Write "$(jq -cn --arg f "$PROJ/src/.env.production" '{file_path: $f, content: "X=1"}')")"
  assert_denied
  guard "$(hook_input NotebookEdit "$(jq -cn --arg f "$PROJ/deploy/prod/run.ipynb" '{notebook_path: $f, new_source: "x"}')")"
  assert_denied
  guard "$(hook_input Edit "$(jq -cn --arg f "$PROJ/src/app.ts" '{file_path: $f, old_string: "a", new_string: "b"}')")"
  assert_allowed
}

@test "Edit content naming a marker passes unless fence_file_content is on" {
  default_config
  local edit
  edit="$(hook_input Edit "$(jq -cn --arg f "$PROJ/src/config.ts" --arg n "host = '$MARKER'" '{file_path: $f, old_string: "host", new_string: $n}')")"
  guard "$edit"
  assert_allowed
  printf 'fence_file_content: on\n' >>"$PROJ/.lanes/prodfence.md"
  guard "$edit"
  assert_denied
  assert_output --partial "marker in tool_input.new_string"
}

@test "a markers_file outside the repository supplies the markers" {
  local private="$LANES_TEST_TMP/private/markers.txt"
  mkdir -p "${private%/*}"
  printf '# private production markers\n\n%s\n- %s\n' "$MARKER" "$PROJECT_MARKER" >"$private"
  config "markers_file: $private"
  guard "$(bash_input "kubectl --context $PROJECT_MARKER get pods")"
  assert_denied
  guard "$(bash_input "kubectl --context dev get pods")"
  assert_allowed
}

@test "a markers_file path starting with ~/ is read from HOME" {
  export HOME="$LANES_TEST_TMP/home"
  mkdir -p "$HOME/.config"
  printf '%s\n' "$MARKER" >"$HOME/.config/prod-markers"
  config "markers_file: ~/.config/prod-markers"
  guard "$(bash_input "ping $MARKER")"
  assert_denied
}

@test "userConfig options alone activate the fence, as a ;-list or a JSON array" {
  rm -f "$PROJ/.lanes/prodfence.md"
  export CLAUDE_PLUGIN_OPTION_MARKERS="other-marker; $MARKER"
  guard "$(bash_input "ping $MARKER")"
  assert_denied
  export CLAUDE_PLUGIN_OPTION_MARKERS="[\"other-marker\",\"$PROJECT_MARKER\"]"
  guard "$(bash_input "gcloud --project $PROJECT_MARKER deploy")"
  assert_denied
  export CLAUDE_PLUGIN_OPTION_PROTECTED_PATHS="deploy/prod/*"
  guard "$(hook_input Write "$(jq -cn --arg f "$PROJ/deploy/prod/x.tf" '{file_path: $f, content: ""}')")"
  assert_denied
}

@test "a userConfig option that starts as JSON but is not an array of strings refuses with exit 2" {
  default_config
  local bad
  for bad in '[not json' '[1, 2]' '{"a":1}x'; do
    export CLAUDE_PLUGIN_OPTION_MARKERS="$bad"
    [[ $bad == '['* ]] || export CLAUDE_PLUGIN_OPTION_MARKERS="[$bad"
    guard "$(bash_input "ls")"
    [ "$status" -eq 2 ] || { echo "markers option '$bad' exited $status" >&2; false; }
    [[ "$stderr" == *"refusing every"* ]]
  done
  unset CLAUDE_PLUGIN_OPTION_MARKERS
  export CLAUDE_PLUGIN_OPTION_PROTECTED_PATHS='[oops'
  guard "$(bash_input "ls")"
  assert_failure 2
}

@test "the config is found by walking up from cwd when CLAUDE_PROJECT_DIR has none" {
  default_config
  unset CLAUDE_PROJECT_DIR
  mkdir -p "$PROJ/src/deep"
  cd "$PROJ/src/deep"
  guard "$(bash_input "ping $MARKER")"
  assert_denied
}

@test "malformed config refuses every guarded call with exit 2" {
  local bad
  for bad in "marker_file: /typo/key" "fence_file_content: maybe" "fence_file_content: on"$'\n'"Fence-File-Content: off"; do
    config "$bad" "## Markers" "- $MARKER"
    guard "$(bash_input "ls")"
    assert_failure 2
    [[ "$stderr" == *"lanes-prodfence:"*"refusing every"* ]] || { echo "config '$bad' said: $stderr" >&2; false; }
  done
  [[ "$stderr" == *"repeats the key fence_file_content"* ]] || { echo "repeat said: $stderr" >&2; false; }
  config "## Markers" "- $PROJECT_MARKER" "$MARKER without a dash"
  guard "$(bash_input "ls")"
  assert_failure 2
  config "# Production fence, but no markers yet"
  guard "$(bash_input "ls")"
  assert_failure 2
  guard "$(hook_input Edit "$(jq -cn --arg f "$PROJ/src/a.ts" '{file_path: $f, old_string: "a", new_string: "b"}')")"
  assert_failure 2
  refute_leaks
}

@test "a config path that cannot be read refuses with exit 2" {
  mkdir -p "$PROJ/.lanes/prodfence.md"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"cannot read"* ]]
}

@test "an unreadable or missing markers_file refuses with exit 2" {
  local private="$LANES_TEST_TMP/private/markers.txt"
  config "markers_file: $private"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"markers_file markers.txt"* ]]
  [[ "$stderr" != *"$LANES_TEST_TMP/private"* ]] || { echo "full markers_file path shown: $stderr" >&2; false; }
  mkdir -p "${private%/*}"
  : >"$private"
  config "markers_file: $private" "## Markers" "- $PROJECT_MARKER"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"lists no markers"* ]]
  printf '%s\n' "$MARKER" >"$private"
  chmod 000 "$private"
  [ ! -r "$private" ] || skip "mode 000 does not deny reads here (root, or NTFS under Git Bash); the missing file above covers the same refusal"
  guard "$(bash_input "ls")"
  assert_failure 2
}

@test "without jq a configured fence refuses with exit 2 and an unconfigured one passes" {
  local nojq="$LANES_TEST_TMP/nojq"
  mkdir -p "$nojq"
  ln -s "$(command -v bash)" "$nojq/bash"
  # Under Git Bash, bash.exe needs its msys DLLs from its own directory; elsewhere this glob matches nothing.
  local dll
  for dll in "$(dirname "$(command -v bash)")"/msys-*.dll; do
    [ ! -e "$dll" ] || ln -s "$dll" "$nojq/"
  done
  default_config
  run --separate-stderr env PATH="$nojq" "$BIN" guard <<<'{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  assert_failure 2
  [[ "$stderr" == *"jq"* ]]
  rm "$PROJ/.lanes/prodfence.md"
  run --separate-stderr env PATH="$nojq" "$BIN" guard <<<'{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  assert_success
}

@test "with no config the fence is inactive: calls pass and session start notes it once" {
  rm -f "$PROJ/.lanes/prodfence.md"
  guard "$(bash_input "psql -h $MARKER")"
  assert_allowed
  [ -z "$stderr" ]
  run --separate-stderr "$BIN" session-start <<<"$(jq -cn --arg cwd "$PROJ" '{session_id: "s", cwd: $cwd, hook_event_name: "SessionStart", source: "startup"}')"
  assert_success
  [[ "$stderr" == *"lanes-prodfence: inactive"* ]]
  run jq -er '.systemMessage' <<<"$output"
  assert_output --partial "inactive"
}

@test "session start says nothing when the fence is active and warns when its config is broken" {
  default_config
  local start
  start="$(jq -cn --arg cwd "$PROJ" '{session_id: "s", cwd: $cwd, hook_event_name: "SessionStart", source: "startup"}')"
  run --separate-stderr "$BIN" session-start <<<"$start"
  assert_success
  assert_output ""
  [ -z "$stderr" ]
  config "unknown_key: x"
  run --separate-stderr "$BIN" session-start <<<"$start"
  assert_success
  [[ "$stderr" == *"refusing every"* ]]
}

@test "no refusal or error ever contains the marker text" {
  default_config
  guard "$(bash_input "psql -h ${MARKER^^}")"
  assert_denied
  refute_leaks
  guard "$(hook_input mcp__x__y "$(jq -cn --arg k "$PROJECT_MARKER" '{($k): $k}')")"
  assert_denied
  assert_output --partial "marker in tool_input)"
  refute_leaks
  guard "$(hook_input mcp__x__y "$(jq -cn --arg k "$PROJECT_MARKER" '{($k): 1}')")"
  assert_denied
  refute_leaks
  guard "$(hook_input Write "$(jq -cn --arg f "$PROJ/deploy/prod/$MARKER.conf" '{file_path: $f, content: ""}')")"
  assert_denied
  refute_leaks
}

@test "the lead session gets no exemption: a registered lead and a lane get the same refusal" {
  default_config
  mkdir -p "$LANES_DATA_DIR/lanes"
  jq -cn --arg cwd "$PROJ" '{lane: "lead", session_id: "sess-lead", role: "lead", tmux_pane: "%0", cwd: $cwd, used_pct: 10, clear_ready: false, updated_at: "2026-10-22T00:00:00Z"}' \
    >"$LANES_DATA_DIR/lanes/lead.json"
  local lead lane
  guard "$(bash_input "psql -h $MARKER" sess-lead)"
  assert_denied
  lead="$output"
  guard "$(bash_input "psql -h $MARKER" sess-lane-7)"
  assert_denied
  lane="$output"
  [ -n "$lead" ] && [ "$lead" = "$lane" ]
}

@test "a tool name naming a marker is refused" {
  config "## Markers" "- prodwarehouse"
  guard "$(hook_input mcp__prodwarehouse__list_tables '{}')"
  assert_denied
  assert_output --partial "marker in tool_name"
}

@test "malformed stdin is refused with exit 2" {
  default_config
  local bad
  for bad in 'not json' '' '{"tool_name":"Bash"}' '{"tool_input":{"command":"ls"}}' '{"tool_name":"Bash","tool_input":"ls"}'; do
    guard "$bad"
    [ "$status" -eq 2 ] || { echo "stdin '$bad' exited $status" >&2; false; }
    [[ "$stderr" == *"lanes-prodfence:"* ]]
  done
}

@test "a file tool input without a path is refused with exit 2" {
  default_config
  guard "$(hook_input Write '{"content":"x"}')"
  assert_failure 2
}

@test "a config symlink whose target is gone refuses instead of turning the fence off" {
  ln -s "$LANES_TEST_TMP/unmounted/prodfence.md" "$PROJ/.lanes/prodfence.md" \
    || skip "this filesystem cannot hold a symlink to a missing target, so a dangling config cannot occur here"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"cannot read"* ]]
}

@test "a crash inside the guard blocks the call with exit 2" {
  default_config
  local fake="$LANES_TEST_TMP/fakebin" real
  real="$(command -v jq)"
  mkdir -p "$fake"
  # This jq dies only on the marker-matching call, after the input and config were accepted.
  printf '#!/usr/bin/env bash\ncase "$*" in *LANES_PRODFENCE_NEEDLES*) exit 5 ;; esac\nexec %q "$@"\n' "$real" >"$fake/jq"
  chmod +x "$fake/jq"
  run --separate-stderr env PATH="$fake:$PATH" "$BIN" guard <<<"$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"internal error"*"https://github.com/senaiverse/lanes/issues"* ]]
}

@test "the shipped template parses: its markers and globs apply, its prose does not" {
  export HOME="$LANES_TEST_TMP/home"
  mkdir -p "$HOME/.config/lanes"
  printf 'private-marker-from-file\n' >"$HOME/.config/lanes/prodfence-markers.txt"
  cp "$PLUGIN/templates/prodfence.md" "$PROJ/.lanes/prodfence.md"
  guard "$(bash_input "psql -h $MARKER")"
  assert_denied
  guard "$(bash_input "echo private-marker-from-file")"
  assert_denied
  guard "$(bash_input "echo markers_file fence_file_content globs separated")"
  assert_allowed
  guard "$(hook_input Write "$(jq -cn --arg f "$PROJ/infra/prod/main.tf" '{file_path: $f, content: ""}')")"
  assert_denied
}

# edit_of <path>: an Edit hook input for the given absolute path.
edit_of() {
  hook_input Edit "$(jq -cn --arg f "$1" '{file_path: $f, old_string: "a", new_string: "b"}')"
}

@test "key spellings that differ in case, spaces, hyphens or a BOM are still read as the key" {
  local spelling
  for spelling in "Protected_paths: deploy/prod/*" "protected_paths : deploy/prod/*" "protected-paths: deploy/prod/*" \
    "Protected Paths: deploy/prod/*" $'\xef\xbb\xbf'"protected_paths: deploy/prod/*"; do
    config "$spelling" "## Markers" "- $MARKER"
    guard "$(edit_of "$PROJ/deploy/prod/app.yaml")"
    [ "$status" -eq 0 ] && [[ "$output" == *"protected path in tool_input.file_path"* ]] \
      || { echo "spelling '$spelling' gave status $status: $output $stderr" >&2; false; }
  done
}

@test "an unknown or near-miss key fails closed and names the key" {
  local spelling
  for spelling in "protected_path: deploy/prod/*" "Protected Pathz: deploy/prod/*" "markersfile: /x"; do
    config "$spelling" "## Markers" "- $MARKER"
    guard "$(edit_of "$PROJ/deploy/prod/app.yaml")"
    assert_failure 2
    local want="${spelling%%:*}"
    want="${want,,}"; want="${want//[ -]/_}"
    [[ "$stderr" == *"unknown key $want"* ]] || { echo "'$spelling' said: $stderr" >&2; false; }
  done
}

@test "protected paths are matched on the real path: symlinked project dir, symlinked file, .. and case" {
  default_config
  local real="$PROJ" link="$LANES_TEST_TMP/projlink"
  ln -s "$real" "$link"
  mkdir -p "$real/deploy/prod"
  : >"$real/deploy/prod/app.yaml"
  export CLAUDE_PROJECT_DIR="$link"
  guard "$(edit_of "$real/deploy/prod/app.yaml")"
  assert_denied
  export CLAUDE_PROJECT_DIR="$real"
  guard "$(edit_of "$link/deploy/prod/app.yaml")"
  assert_denied
  guard "$(edit_of "$PROJ/deploy/x/../prod/app.yaml")"
  assert_denied
  ln -s "$real/deploy/prod/app.yaml" "$PROJ/src/alias.yaml"
  guard "$(edit_of "$PROJ/src/alias.yaml")"
  assert_denied
  guard "$(edit_of "$PROJ/Deploy/PROD/app.yaml")"
  assert_denied
  guard "$(edit_of "$PROJ/deploy/staging/../../src/app.ts")"
  assert_allowed
  config "protected_paths: $real/deploy/prod/*" "## Markers" "- $MARKER"
  guard "$(edit_of "$link/deploy/prod/app.yaml")"
  assert_denied
  # An absolute glob written through a symlink (macOS /tmp is /private/tmp) matches the file by its real path.
  config "protected_paths: $link/deploy/prod/*" "## Markers" "- $MARKER"
  guard "$(edit_of "$real/deploy/prod/app.yaml")"
  assert_denied
}

@test "a relative glob whose directory is a symlink out of the project matches the target path" {
  local ops="$LANES_TEST_TMP/ops"
  mkdir -p "$ops/prod" "$PROJ/deploy"
  : >"$ops/prod/app.yaml"
  ln -s "$ops/prod" "$PROJ/deploy/prod"
  default_config
  guard "$(edit_of "$ops/prod/app.yaml")"
  assert_denied
  # A command is matched as text, so it is refused when it names the real path (macOS: /private/tmp, not /tmp).
  guard "$(bash_input "cat $(cd -P "$ops" && pwd -P)/prod/app.yaml")"
  assert_denied
  guard "$(edit_of "$ops/staging.yaml")"
  assert_allowed
}

@test "a .. after a symlinked directory is resolved where the symlink points, as the kernel does" {
  local prod="$LANES_TEST_TMP/production"
  mkdir -p "$prod/subdir"
  : >"$prod/secret"
  ln -s "$prod/subdir" "$PROJ/link"
  ln -s "link/../secret" "$PROJ/alias"
  config "protected_paths: $prod/secret" "## Markers" "- $MARKER"
  guard "$(hook_input Read "$(jq -cn --arg f "$PROJ/alias" '{file_path: $f}')")"
  assert_denied
  guard "$(hook_input Read "$(jq -cn --arg f "$PROJ/link/../secret" '{file_path: $f}')")"
  assert_denied
  guard "$(hook_input Read "$(jq -cn --arg f "$PROJ/link/x" '{file_path: $f}')")"
  assert_allowed
}

@test "a file tool path naming a marker is refused even with fence_file_content off" {
  default_config
  local tool
  for tool in Read Edit Write; do
    guard "$(hook_input "$tool" "$(jq -cn --arg f "$PROJ/config/$MARKER.env" '{file_path: $f, old_string: "a", new_string: "b", content: "x"}')")"
    assert_denied
    assert_output --partial "marker in tool_input.file_path"
    refute_leaks
  done
  guard "$(hook_input NotebookEdit "$(jq -cn --arg f "$PROJ/nb/$PROJECT_MARKER.ipynb" '{notebook_path: $f, new_source: "x"}')")"
  assert_denied
  assert_output --partial "marker in tool_input.notebook_path"
}

@test "an empty JSON list in protected_paths or an option adds nothing and refuses nothing" {
  config "protected_paths: []" "## Markers" "- $MARKER"
  export CLAUDE_PLUGIN_OPTION_MARKERS="[]" CLAUDE_PLUGIN_OPTION_PROTECTED_PATHS="[]"
  guard "$(bash_input "ls")"
  assert_allowed
  guard "$(bash_input "ping $MARKER")"
  assert_denied
}

@test "a shell command naming a protected path is refused even with no marker" {
  config "protected_paths: deploy/prod/*; .env.production; *.pem" "## Markers" "- $MARKER"
  local tool
  for tool in Bash PowerShell Monitor; do
    guard "$(hook_input "$tool" '{"command":"source .env.production && psql \"$DATABASE_URL\""}')"
    assert_denied
    assert_output --partial "protected path in tool_input.command"
  done
  guard "$(bash_input "cat deploy/prod/app.yaml")"
  assert_denied
  guard "$(bash_input "cat key.pem && ls deploy/staging")"
  assert_allowed
}

@test "Read of a protected path is refused" {
  default_config
  guard "$(hook_input Read "$(jq -cn --arg f "$PROJ/.env.production" '{file_path: $f}')")"
  assert_denied
  guard "$(hook_input Read "$(jq -cn --arg f "$PROJ/src/app.ts" '{file_path: $f}')")"
  assert_allowed
}

@test "a comma in the markers option is refused, because only ; separates markers" {
  rm -f "$PROJ/.lanes/prodfence.md"
  export CLAUDE_PLUGIN_OPTION_MARKERS="other-marker, $MARKER"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"separate markers with ';'"* ]]
}

@test "a heading that contains Markers starts a marker list; bullets under another heading fail closed" {
  local heading
  for heading in "# Production markers" "## Markers (private)" "### MARKERS"; do
    config "$heading" "- $MARKER"
    guard "$(bash_input "ping $MARKER")"
    assert_denied
  done
  config "## Markers" "- $PROJECT_MARKER" "## Hosts" "- $MARKER"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"line 4"*"Markers heading"* ]]
}

@test "protected_paths with no markers names the cause" {
  config "protected_paths: deploy/prod/*"
  guard "$(bash_input "ls")"
  assert_failure 2
  [[ "$stderr" == *"protected_paths are set but no markers"* ]]
}

@test "an unknown subcommand is a usage error" {
  run --separate-stderr "$BIN" nope
  assert_failure 2
  [[ "$stderr" == *"usage"* ]]
}

# win_setup: under Git Bash the real cygpath converts paths; elsewhere a stand-in cygpath maps C:\<p> or C:/<p> back to
# /<p>, so the Windows path handling runs on every OS. win_path <posix path> prints the path as Windows writes it.
win_setup() {
  WIN_FAKE=0
  command -v cygpath >/dev/null 2>&1 && return
  WIN_FAKE=1
  mkdir -p "$LANES_TEST_TMP/winbin"
  # shellcheck disable=SC2016  # the stand-in's body is written literally
  printf '%s\n' '#!/usr/bin/env bash' \
    '[ "$1" = -u ] && [ "$2" = -- ] || { echo "stand-in cygpath: unexpected arguments $*" >&2; exit 9; }' \
    'p="${3//\\//}"; printf "%s\n" "${p#[A-Za-z]:}"' >"$LANES_TEST_TMP/winbin/cygpath"
  chmod +x "$LANES_TEST_TMP/winbin/cygpath"
  export PATH="$LANES_TEST_TMP/winbin:$PATH"
}

win_path() {
  if [ "$WIN_FAKE" -eq 0 ]; then cygpath -w "$1"; else local p="${1//\//\\}"; printf 'C:%s\n' "$p"; fi
}

@test "Windows paths in the hook input and CLAUDE_PROJECT_DIR are read in their POSIX form" {
  default_config
  win_setup
  local f
  f="$(win_path "$PROJ/src/.env.production")"
  guard "$(hook_input Write "$(jq -cn --arg f "$f" '{file_path: $f, content: ""}')")"
  assert_denied
  guard "$(hook_input Write "$(jq -cn --arg f "${f//\\//}" '{file_path: $f, content: ""}')")"
  assert_denied
  export CLAUDE_PROJECT_DIR
  CLAUDE_PROJECT_DIR="$(win_path "$PROJ")"
  cd "$LANES_TEST_TMP"
  guard "$(edit_of "$(win_path "$PROJ/deploy/prod/app.yaml")")"
  assert_denied
  guard "$(edit_of "$(win_path "$PROJ/src/app.ts")")"
  assert_allowed
  f="$(win_path "$PROJ")"
  config "protected_paths: ${f//\\//}/deploy/prod/*" "## Markers" "- $MARKER"
  guard "$(edit_of "$PROJ/deploy/prod/app.yaml")"
  assert_denied
  unset CLAUDE_PROJECT_DIR
  guard "$(jq -cn --arg cwd "$(win_path "$PROJ/src")" --arg c "ping $MARKER" \
    '{cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}')"
  assert_denied
}

@test "a Windows path without cygpath to convert it refuses with exit 2" {
  command -v cygpath >/dev/null 2>&1 && skip "cygpath is on PATH (Git Bash); the conversion itself is tested above"
  default_config
  guard "$(edit_of 'C:\proj\deploy\prod\app.yaml')"
  assert_failure 2
  [[ "$stderr" == *"a Windows path needs cygpath"* ]] || { echo "said: $stderr" >&2; false; }
}

@test "jq output with CRLF line ends, as a native jq.exe under Git Bash writes it, is read the same" {
  default_config
  local fake="$LANES_TEST_TMP/crlfbin" real
  real="$(command -v jq)"
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\nset -o pipefail\n%q "$@" | awk '"'"'{ printf "%%s\\r\\n", $0 }'"'"'\n' "$real" >"$fake/jq"
  chmod +x "$fake/jq"
  [ "$(printf '"x"' | "$fake/jq" -r . | od -An -c | tr -d ' ')" = 'x\r\n' ]
  local call
  for call in "$(hook_input Write "$(jq -cn --arg f "$PROJ/src/.env.production" '{file_path: $f, content: ""}')")" \
    "$(edit_of "$PROJ/deploy/prod/app.yaml")" "$(bash_input "cat .env.production")" "$(bash_input "ping $MARKER")"; do
    run --separate-stderr env PATH="$fake:$PATH" "$BIN" guard <<<"$call"
    assert_denied
  done
  run --separate-stderr env PATH="$fake:$PATH" "$BIN" guard <<<"$(bash_input "ls")"
  assert_allowed
}

@test "every refusal the skill quotes is what the guard prints, with <field> standing for the field" {
  default_config
  local printed=() quote pattern n=0
  guard "$(bash_input "psql -h $MARKER")"
  printed+=("$output")
  guard "$(edit_of "$PROJ/deploy/prod/app.yaml")"
  printed+=("$output")
  config "unknown_key: x"
  guard "$(bash_input "ls")"
  printed+=("$stderr")
  while IFS= read -r quote; do
    n=$((n + 1))
    pattern="${quote//<field>/*}"
    local p found=0
    for p in "${printed[@]}"; do
      # shellcheck disable=SC2053  # the quote, with <field> as a wildcard, is matched as a pattern on purpose
      [[ $p == *$pattern* ]] && found=1
    done
    [ "$found" -eq 1 ] || { echo "the skill quotes '$quote' but the guard never prints it" >&2; false; }
  done < <(sed -n '/^## When a call is refused/,/^## /s/^- `\([^`]*\)`.*/\1/p' "$PLUGIN/skills/prodfence/SKILL.md")
  [ "$n" -eq 3 ] || { echo "expected 3 quoted refusals in the skill, found $n" >&2; false; }
}

@test "hooks.json wires every guarded tool to the guard with onFailure block" {
  local hooks="$PLUGIN/hooks/hooks.json"
  run jq -er '[.hooks.PreToolUse[].matcher] | sort | join(" ")' "$hooks"
  assert_output "Bash|PowerShell|Monitor|WebFetch|ReadMcpResourceTool Read|Edit|Write|NotebookEdit mcp__.*"
  run jq -e '[.hooks.PreToolUse[].hooks[]] | length == 3 and all(.command == "${CLAUDE_PLUGIN_ROOT}/bin/lanes-prodfence" and .args == ["guard"] and .onFailure == "block")' "$hooks"
  assert_success
  run jq -e '.hooks.SessionStart[0].hooks[0].args == ["session-start"]' "$hooks"
  assert_success
}
