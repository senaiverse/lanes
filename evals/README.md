# Plugin evals

Trigger and behaviour checks for the four plugins (`docs/DECISIONS.md` row 13). Each case is one `case.yaml` under
`evals/<plugin>/<case>/`; its `plugins:` key points at the plugin under test, so the suite runs from the repo root.
Docs: https://code.claude.com/docs/en/plugin-evals

| Case | Checks |
|---|---|
| `prodfence/marker-refusal-asks-human` | After "This touches production" the agent asks the human; no Bash retry. |
| `prodfence/broken-config-do-not-edit` | A broken-config refusal is reported; the config is not edited. |
| `review/review-branch-delegates` | "Review this branch" calls the `reviewer` agent. |
| `review/plain-question-no-reviewer` | A plain git question does not. |

## Running

```bash
# Cases that need no shell (prodfence, review):
claude plugin eval . --tag prodfence review --trust-plugin --runs 1 --model haiku --judge-model haiku --no-publish \
  --max-cost-usd 4 --output-dir /tmp/lanes-evals

# Cases that assert a Bash call (plancheck, jobs) need the OS sandbox:
claude plugin eval . --tag plancheck jobs --trust-plugin --runs 1 --model haiku --judge-model haiku --no-publish \
  --max-cost-usd 4 --allow-tools Write Bash
```

- Bash and Write are granted only by `--allow-tools`; without a sandbox backend (Linux: `bubblewrap` and `socat`, and a
  `~/.docker` with no symlink inside it) every Bash-granting run fails with a run error and scores 0.
- Each case runs once per arm. Raise `--runs` to see flakiness; `llm` graders are the least stable.
- `tool_used: Skill` graders are indicators, not scored, in the with/without comparison. A `Δ` of 0 on the prodfence
  cases means the base model already behaves that way; they guard against a regression in the skill's wording, not a
  gain over no plugin. The refusal text is pasted into the prompt because a run loads no project fence config.
- Results go to `evals/results/`; pass `--output-dir` outside the repo, as above, to keep the tree clean.
