# The lead session that `lanes request`, `lanes clear` and `lanes goal` require as their caller.

# register_lead: register the lead in pane %99 with LANES_ROLE=lead, once per test.
register_lead() {
  [[ -f "$LANES_DATA_DIR/lanes/lead.json" ]] || LANES_ROLE=lead register_lane lead sl %99 >/dev/null 2>&1
}

# as_lead <lanes args...>: run lanes from the lead's pane. A test that signals lanes runs
# `register_lead; TMUX_PANE=%99 "$LANES" ... &` instead, so the pid it kills is lanes itself.
as_lead() {
  register_lead
  TMUX_PANE=%99 "$LANES" "$@"
}
