# lanes

A Claude Code plugin marketplace for running several Claude sessions in tmux: one lead session plans, lane sessions
build, a durable journal carries state, and lanes are cleared at a context threshold and resume where they left off.

Status: pre-release (v0.1 in progress). The full README comes with the v0.1 release.

## Install

```
/plugin marketplace add senaiverse/lanes
/plugin install <name>@lanes
```

Requirements: tmux, jq and Bash 4+ (macOS ships Bash 3.2: `brew install bash`).

## Files lanes uses

- `.lanes/RULES.md`: the mechanism rules of the core `lanes` plugin. `lanes-waves` requires it.
- `.lanes/tracker.md`: the item source `lanes-waves` reads by default.
- `.lanes/waves/W<N>.md`: a wave's plan table, by default.
- `.lanes/waves.md`: wave settings (template in `lanes-waves`).
- `.lanes/plan-fields`: optional override of the required plan fields (`lanes-plancheck`).

## Contributing

Run `scripts/test.sh` before a push. Run `scripts/install-hooks.sh` once per clone: it installs a pre-push hook that
runs the private word check (`scripts/deny-gate.sh`; CI does not run it).

## Credits

The grilling workflow the lead skill uses is from Matt Pocock's skills (https://github.com/mattpocock/skills).
