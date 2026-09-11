# Retired cases

Not re-run by `run-regression-set.sh` (it only globs `../cases/`). A case
lands here when replaying its diff can never pass again for reasons that
have nothing to do with review quality — moved out rather than left in
`cases/` to permanently fail, or silently deleted and forgotten.

## `18276dc4-duplication-.claude_skills_pr-review_scripts_validate-pack.sh-18.json`

Retired 2026-09-11. The underlying defect (the pack-format heading list
hand-duplicated between `build-artifacts.sh` and the newly-added
`validate-pack.sh`) was real and was genuinely fixed for real, months
later, by sourcing both from `model/pack-heading-check.sh`
(`duplication.shared-matching-logic-sourced-not-copied` in this repo's
own domain pack cites the fix directly).

The case cannot pass on replay, structurally, regardless of any prompt or
doctrine change: this diff is from week 1, before this repo's own
`core/`/`harness/`/`model/`/`eval/` restructure. Today's domain pack cites
paths (`.claude/skills/pr-review/SKILL.md`, `harness/build-agents.sh`,
`core/doctrine.md`, `model/pack-heading-check.sh`...) that don't exist yet
at that commit — confirmed directly:
`bash model/validate-pack.sh model/pr-review-domain.md <replay-worktree>`
against this case's historical tree prints 30 `invalid:` lines, one per
record whose citation can't resolve. `PACK_INVALID=1`/`PACK_STALE=1`
degrades every probe to empty, unconditionally, by design — the exact
record that would flag this pattern
(`duplication.shared-matching-logic-sourced-not-copied`) can never reach
a verifier on this replay, no matter what the pipeline's prompts say.

Discovered while investigating a real, separate bug this case surfaced:
`known-non-defects.txt` was never wired into any verifier's own prompt,
only the scout's (fixed the same day — see `pr-review-verify.js`,
`core/doctrine.md`, and `git log` for `core/doctrine.md` and
`.claude/agents/pr-verify-*.md` around this date). That fix is real and
verified independently of this case's own fate — confirmed clean across
3 consecutive re-runs of this exact case before its structural ceiling
was understood and it was retired here.

Replaced by `../cases/3662e6ea-concurrency-model_baseline.py-72.json` — a
real, currently-accepted finding from a recent, post-restructure commit,
so the regression set has something that can actually protect this fix
(and everything else) going forward.
