# Waves lane: when the lead sends findings or a conflict

- **Review findings on your theme.** Give each one a root-cause pass (cause, edge cases, ripple, blast radius), then a red
  test, the fix on your theme branch, a review of the fix diff, and steps 4 to 6 of SKILL.md. There is one fix round per
  wave. Fix the class of the finding: search every sibling site, not only the flagged line. A fix removes the cause. A fix
  that adds a guard, flag, state value, counter, retry, lock or timeout carries a `Why not remove the cause:` line that
  holds in code, or the lead sends it back. A finding below "blocking severity" is fixed only when it changes behaviour, a
  test's power to fail, or a reader's understanding.
- **CI stuck or red on your branch.** A stuck run goes to the lead with the run id. A red run is a finding: diagnose it
  red first, then send the lead the fixed head.
- **Integration conflict.** The lead names the files and the other branch. Resolve it on your theme branch and keep both
  sides' behaviour. Add a test for the combined behaviour when the conflict is in code. Your branch stays off the base
  branch; the integration branch is the only place the base and the themes meet.
- **A contract changed by a fix** (a function's result shape, a status value). Search the tests for every assertion on it
  before you push.
