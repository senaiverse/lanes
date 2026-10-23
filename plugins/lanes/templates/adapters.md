# lanes adapters: this project's facts, written by /lanes:setup and checked by `lanes check-adapters`.
# Fixed shape: one `key: value` line per key, every key present; a line starting with # is a comment.
# The lead-only command list is not here: its one home is lanes-guards' .lanes/guards.md.
# ci_command          the command that starts a CI run; empty when the project has no CI
# ci_status_command   the command that shows the latest CI run's status; empty when there is no CI
# review_gate         what must pass before the lead merges, in one line (required)
# test_runner         local or ci: where the lanes run the tests (required)
# test_command        the command that runs the tests, locally or to start them on CI (required)
# deny_list           the path of the private deny-list file a pre-push check reads; empty when there is none
ci_command:
ci_status_command:
review_gate:
test_runner:
test_command:
deny_list:
