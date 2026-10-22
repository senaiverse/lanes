# mattpocock/skills: how it is built, and what lanes should take

Researched 2026-10-22. Source: a full clone of https://github.com/mattpocock/skills at head (last commit 2026-10-19,
v1.3.1), plus `gh api` for stars and issues. Labels: Verified = read in the clone or API; Opinion = my judgement.
Licence MIT (`LICENSE`), so structure and wording may be borrowed with credit.

## 1. Repo layout (Verified)

- **Buckets under `skills/`** (`CLAUDE.md`): `engineering/` and `productivity/` are promoted (shipped, documented);
  `misc/` is frozen; `in-progress/` is public beta and not shipped; `deprecated/`. Each bucket has a `README.md`
  listing its skills, grouped "User-invoked" and "Model-invoked". No further nesting.
- **Per skill folder:** `SKILL.md`, optional sibling reference files in CAPS or lowercase (`ADR-FORMAT.md`, `mocking.md`),
  `scripts/` (`diagnosing-bugs/scripts/hitl-loop.template.sh`, `wizard/template.sh`), and `agents/openai.yaml` (Codex UI
  metadata plus `allow_implicit_invocation: false` for user-invoked skills).
- **Human docs:** `docs/<bucket>/<skill>.md`, one page per promoted skill (What it does / When to reach for it / Common
  questions / It's working if), published at aihero.dev/skills-<name>. Rules in `.agents/writing-docs.md`. Pages carry no
  install commands and use absolute links only.
- **Decisions and scope:** `.agents/adr/` (2 ADRs, e.g. `0002-ship-as-a-claude-code-plugin.md`), `.out-of-scope/*.md`
  (one rejected concept per file, each with a "Prior requests" list of issue numbers), `SCOPE.md` (the bar for issues),
  `GLOSSARY.md`.
- **README** (`README.md`): logo, one-line pitch ("Skills For Real Engineers"), positioning against GSD/BMAD/Spec-Kit
  ("they own the process... these are small, composable"), newsletter link, "Installation (30-second setup)" in
  collapsible `<details>` per agent, "run the setup skill once", then "Why These Skills Exist" as four failure modes
  (agent did not do what I want; too verbose; code does not work; ball of mud), each with a quote, a problem, a fix that
  links the skill. Then a Reference list split User-invoked / Model-invoked, every name linked to its `SKILL.md`.
- **Install and versioning:** both channels. `.claude-plugin/plugin.json` lists promoted skills as an explicit array of
  paths (`"skills": ["./skills/engineering/tdd", ...]`) and `.claude-plugin/marketplace.json` makes the repo its own
  one-plugin marketplace (`source: "./"`). README tells Claude Code users to run
  `claude plugin install mattpocock-skills@claude-plugins-official`; Codex and Copilot use `marketplace add`; everyone
  else uses `npx skills@latest add mattpocock/skills -a <agent>` (skills.sh, editable copies). README says pick one per
  agent or every skill appears twice. Versioning: Changesets (`.changeset/*.md`, `.github/workflows/release.yml` opens
  a "chore: version skills" PR) plus `scripts/sync-plugin-version.mjs` keeping `plugin.json` equal to `package.json`
  (`ADR 0002`: Claude uses plugin version to decide when users see an update).
- **CI, tests, evals:** none for skill behaviour. Workflows are only `release.yml`, `needs-info.yml` (auto-closes an
  unclear issue after 14 days) and `triage-label.yml`. The only machine checks are `claude plugin validate . --strict`
  (by hand, per `CLAUDE.md`) and `check-plugin-version`. The rules "every promoted skill is in README and plugin.json"
  are prose in `CLAUDE.md`, not a test.
- **Contribution rules:** new-skill proposals and PRs are closed (`.out-of-scope/new-skills.md`: "if you can compose the
  behaviour from existing skills, it doesn't get a new one"). An issue stays open only with an observed failure from a
  real session and fit with the philosophy (`SCOPE.md`). No em-dashes in repo prose. Changeset per change.

## 2. Skill anatomy (Verified)

- **Frontmatter:** `name`, `description`, optional `disable-model-invocation: true`, `argument-hint`. Nothing else.
- **Two description voices** (`.agents/invocation.md`). Model-invoked: model-facing, with triggers: "Test-driven
  development. Use when the user wants to build features or fix bugs test-first, mentions 'red-green-refactor', or wants
  integration tests." User-invoked: human-facing one-liner, no trigger list: "A relentless interview to sharpen a plan or
  design."
- **Length:** median about 70 lines; most under 120, longest `pr` at 170. Thin wrappers are 7 lines. Detail is pushed to
  sibling files and linked, so `SKILL.md` stays the step list (`writing-for-agents/SKILL.md`: "progressive disclosure").
- **Composition by explicit tool call:** `grill-me/SKILL.md` is the whole skill `Call the Skill tool with "grilling".` A
  user-invoked skill may call model-invoked ones, never another user-invoked one. No cross-folder links.
- **Tone:** imperative, short sentences, bold leading words (**frontier**, **seam**, **tracer bullet**), positive
  phrasing, and every step ends with a checkable completion criterion (`writing-for-agents`).
- **Goal-based, not code-based:** skills state the outcome and the loop, not commands. `diagnosing-bugs` Phase 1 says
  "Build a feedback loop... **This is the skill**" and lists ten ways to build one. `setup-*` is "a prompt-driven skill,
  not a deterministic script".

Excerpt A, the setup skill's opening (`skills/engineering/setup-matt-pocock-skills/SKILL.md`):

> This is a prompt-driven skill, not a deterministic script. Explore, present what you found, confirm with the user, then write.
> ### 1. Explore ... Read whatever exists; don't assume
> Lead each section with the recommended answer so the user can accept it in a word ... skip the section entirely when exploration already settled it
> Never create `AGENTS.md` when `CLAUDE.md` already exists ... If an `## Agent skills` block already exists ... update its contents in-place rather than appending a duplicate.

Shape: Explore, Present findings and ask (one section, one answer, recommended first), Confirm with a draft, Write,
Done. It writes a short pointer block into the project's CLAUDE.md plus `docs/agents/*.md` seeded from sibling template
files in the skill folder (`issue-tracker-github.md`, `triage-labels.md`, `domain.md`). Other skills then read those
files. Escape hatch: "Other: ask the user to describe the workflow in one paragraph; record it as freeform prose".

Excerpt B, a goal-and-criterion sentence (`skills/productivity/grilling/SKILL.md`):

> Word each question so "yes" accepts your recommended answer. ... Finding _facts_ is your job, never the user's. ...
> The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.

Excerpt C, wrapper plus description voices (`skills/productivity/grill-me/SKILL.md`, whole file):

> description: A relentless interview to sharpen a plan or design.
> disable-model-invocation: true
> Call the Skill tool with "grilling".

Lesson on a setup skill: `.out-of-scope/setup-skill-verify-mode.md` rejects a separate verify mode; the user re-runs the
setup skill and says "verify, don't rewrite". No contract tests check what setup generates, so lanes' row 22 goes beyond
the prior art.

## 3. Popularity (Verified via `gh api`, 2026-10-22)

- 300,752 stars, 25,271 forks, created 2026-02-03; pushed the same day I checked. 200 open issues, discussions enabled.
- README claims about 60,000 newsletter subscribers (aihero.dev); distribution through the author's audience.
- Releases: v1.0.0 to v1.3.1; v1.2.2 and v1.2.3 in early August, v1.3.0 and v1.3.1 on 2026-10-04; 72 commits in the last
  33 days. Frequent small fixes, each with a changeset that credits the reporter.
- What users praise: the repo's own README says grilling is "my most popular" skill, and domain language ("ubiquitous
  language") is "the single coolest technique". I found no independent praise threads in the repo; this is the author's
  claim (Reported). What users complain about, by reactions: `/code-review` clashes with a Claude Code built-in
  (issue #483, 43 reactions); finished tickets never marked done (#508, 23); resolved answers not traceable (#341, 18);
  "Codex just asked me 200 questions" (#44, 16). Discussion #1302: plugin install pulled the repo's npm devDependencies
  (changesets) into users' installs.
- Why it spread (Opinion): small composable skills, named failure modes users recognise, one-line install, a famous
  author, and a refusal to own the process.

## 4. Recommendations for lanes (max 12)

1. **Layout (copy).** Put per-skill extras beside `SKILL.md` (`FORMAT.md`-style reference files, `scripts/`). Keep
   `SKILL.md` as the step list. Source: `skills/engineering/tdd/` and `diagnosing-bugs/`. Lanes keeps its
   `plugins/<name>/` layout; this applies inside each plugin.
2. **Two description voices (copy).** Lead and operator-only skills (`/lanes:setup`, clear, accept) get
   `disable-model-invocation: true` and a short human one-liner; reusable disciplines get "Use when..." triggers. Source:
   `.agents/invocation.md`. List them under "You type" vs "Agent reaches for" in the README.
3. **Compose by naming the Skill tool (copy).** Where lanes composes skills (the `grilling` credit in decision 17),
   write `Call the Skill tool with "grilling"`, and "tell the user to run `/lanes:setup`" for user-only ones. Source:
   `invocation.md`.
4. **Phrase `/lanes:setup` as explore, present, confirm, write (copy, strongest fit for row 22).** State "prompt-driven,
   not a deterministic script"; first read what exists (CI config, `git remote`, test scripts, existing hooks); lead each
   question with a recommended answer; skip questions exploration settled; show a draft before writing; edit an existing
   block in place; never create a second file where one exists. Source: `setup-matt-pocock-skills/SKILL.md`.
5. **Adapt: make setup output checkable (go beyond the source).** The source writes free prose and has no tests. For
   lanes, have setup write a small fixed-shape adapter file that has seeded templates beside the skill (as
   `issue-tracker-github.md` does) and give the "Other: describe it in a paragraph" escape only to the prose fields, so
   shipped bats contract tests can parse the structured fields. Keep one verify path: re-running setup with "check only".
   Source: `setup-skill-verify-mode.md` (their reason to reject a second skill holds; a read-only mode stays in one skill).
6. **Pointer block in the project's CLAUDE.md (copy).** Setup appends one `## Lanes` section of one-line summaries that
   point at the generated files, never copying rules into CLAUDE.md. Source: the `## Agent skills` block.
7. **Short, positive, criterion-ended steps (adapt).** Use leading words (frontier, clear-ready), state the target
   behaviour rather than prohibitions, and end each step on a checkable condition. Adopt `writing-for-agents` as lanes'
   skill-writing reference (MIT; credit). Do not copy its 2,000-word length into each skill.
8. **README (adapt).** Open with positioning against named alternatives (claude-squad, agent teams) and one sentence on
   what lanes will not do; then install in collapsible blocks; then "why" as the failure modes lanes fixes (context
   rot at 60%, lost RESUME, lead and lane stepping on each other); then a linked reference list. Avoid: logo and
   newsletter hooks, and 300-line prose before the install line. Source: `README.md`.
9. **Install paths (copy, with one correction).** Document two paths: `claude plugin marketplace add senaiverse/lanes`
   then `claude plugin install lanes@lanes`, and `npx skills@latest add senaiverse/lanes` for skills-only users. State
   plainly that hooks and `bin/` work only through the plugin path (Opinion: the skills CLI copies only SKILL.md trees),
   and "pick one, or you get every skill twice". Source: README install block, `.agents/install-block.md` (one verbatim
   source for install text). Avoid their mistake in discussion #1302: keep dev dependencies out of the plugin root.
10. **Scope file and out-of-scope records (copy).** Add `SCOPE.md` with their two-part bar (observed failure from a real
    session, and fit with the philosophy) and `.out-of-scope/<concept>.md` with "Prior requests". Suits a solo
    maintainer and your DECISIONS.md discipline. Source: `SCOPE.md`, `.out-of-scope/`.
11. **Machine-enforce the manifest rules (go beyond).** Their "every promoted skill is in README and plugin.json" is
    prose and drifts. A bats test that diffs `skills/*/` against `plugin.json`, README links, and the router skill is
    cheaper than the habit. Also test names against Claude Code built-ins: their #483 (43 reactions) came from a
    `/code-review` clash, and their answer was "use `/mattpocock-skills:code-review`". Lanes' namespace `/lanes:` already
    gives this; document it in the README.
12. **Credits (copy the pattern).** A per-skill `CREDITS.md` that names what was copied, from whom, and why it is
    copied rather than depended on (`skills/engineering/pr/CREDITS.md`), plus a README "Credits" line linking
    mattpocock/skills and the MIT licence for any borrowed wording or structure. Where lanes only links (grilling), say
    "not copied" as decision 17 does. Add a changeset-style release note only if releases become frequent; for v0.1 a
    plain `CHANGELOG.md` is enough (Opinion).

## Avoid

- Skills that duplicate the environment (they warn about "cache" docs in `writing-for-agents`).
- Per-harness branches. Lanes is Claude Code only, so skip `agents/openai.yaml` and the Codex and Copilot install blocks.
- Closing the repo to all contributions on day one. They can because of 300k stars; an OSS newcomer wants issues and
  a clear bar (rec 10), not a closed door (Opinion).
