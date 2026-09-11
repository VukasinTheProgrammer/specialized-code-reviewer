# PR reviewer — corrections ledger

What the reviewer got wrong, and the rule that stops it happening again.

The reviewer does not learn from past fix commits. It learns from being corrected here. Every time a run reports something and a human says *that is not a defect*, the dismissal is written down as a **rule**, not as a one-off veto — otherwise the same false finding returns on the next branch that touches the same code.

This copy ships empty — every entry below is repo-specific, learned from actual runs against actual code, and none of that transfers between repos. Start accumulating entries the first time a run against this repo gets a verdict.

## Why not score against past fix commits

The first design fed the reviewer each historical review-fix commit's parent and scored it on finding what a human had found. It was dropped before implementation, for two reasons that do not go away with a bigger sample.

**The answer key would be this team's own past review quality.** A defect class nobody here has ever caught has no entry in it, so the reviewer scores full marks for missing exactly what the humans missed. The number would measure agreement, not correctness.

**Fix commits carry more than fixes.** A rename, a product decision, a feature built in the same commit — under "the fix changed it and the reviewer did not flag it, therefore missed", all of that imports as a penalty for not reporting work that was intended.

What replaces it is below: the reviewer learns from being corrected, and the number comes from what survives a human read.

**This tally cannot count what the reviewer missed, and does not claim to.** A defect nobody noticed appears in neither the ledger nor the tally. The honest measure of a miss is prospective — running on live pull requests and watching what still reaches production — and that is phase-two work.

Neither this tally nor a regression set (see `eval/regression-set/README.md` if this copy has one) substitutes for the other. This tally measures what the reviewer reports and how much of it survives a human read, per label. A regression set measures whether a *change to the reviewer* loses ground it already held — replaying past accepted findings against their original diffs.

## How an entry is made

After a run, every finding gets one of three verdicts from the person who read it:

| Verdict | Meaning | What it writes here |
|---|---|---|
| **accepted** | Real defect, fixed or filed | Nothing here — but if this copy carries the regression-set tooling, record it there too, so the acceptance also becomes ground truth the reviewer can't quietly regress on later. |
| **dismissed** | Not a defect | A new entry, or a `seen:` tick on an existing one. |
| **mislabelled** | Real, wrong label | An entry under *Label corrections*, naming both labels. |

A dismissal is only complete when it answers two questions: **what makes this safe**, and **what would make it unsafe**. A rule with no second half is a rule that suppresses the real version of the same defect later, which is worse than the false positive it prevents.

## Promotion

An entry seen **twice** stops living here and moves into `.claude/agents/pr-review-scout.md` — as a "not this" clause on the label it kept landing on, or as a line in that file's *Known non-defects* section. This ledger holds the evidence; the agent file holds only the rules that earned their place, because every line there is paid for on every spawn.

Nothing here is ever phrased as "never report `<label>`". Rules name a pattern and its guard, never a label to stop looking at.

**Label corrections promote on first sighting.** The two-sighting bar exists because suppression is dangerous: a non-defect rule stops the reviewer reporting something, and one bad call should not silence a check on its own. A label correction suppresses nothing — it moves a finding from one label to a better one — so it can enter the agent file as soon as it is right.

---

## Known non-defects

- **A validator/check with a `TODO` comment naming exactly which checks are deferred, dated to a specific near-term day in a documented multi-day plan, whose own co-shipped test suite asserts the expected *eventual* pass/fail split rather than today's, is not a defect — and neither is that test suite currently reporting `FAIL` against the fixtures those deferred checks would catch.** Same fact, two places it shows up: the validator's own incompleteness, and the red test-runner output that incompleteness produces right now. Both are one dismissed pattern, not two separate observations — a finding naming the test suite's `FAIL` lines instead of the validator's `TODO` is still this rule, not a new one. It's declared, tracked incompleteness, not an oversight. Safe when: the TODO names the specific deferred items (not "more checks later"), a concrete next step exists in project tracking (`todays-work/`, a plan doc) that closes it on a short horizon, and the test suite (its assertions, or its actual run output) landed in the same commit as the TODO — so the incompleteness, and the fixtures currently failing because of it, are provably intentional, not accidentally shipped as done. **Unsafe when**: the TODO is vague or missing, the "next step" has no date or owner, the code ships to a branch presented as complete (a PR titled "implement X" whose X isn't fully implemented) rather than an explicitly incremental commit, or the "next step" never actually lands and the FAILs are still there weeks later — incompleteness stops being declared and tracked the moment nobody's tracking it. (`eval/runs/e01-monday.json` finding 1, dismissed 2026-09-07 — `validate-pack.sh`'s Monday skeleton, TODO named exactly the 5 deferred checks, completed the very next day: see `model/validate-pack.sh`'s full six checks, all present by commit `43f3f8e`. Sharpened 2026-09-11 after `eval/regression-set`'s own replay of this exact diff raised the test-suite-`FAIL` framing as if it were a new, undismissed finding — same fact, evaded the original wording by naming `tests/run.sh` instead of `validate-pack.sh`.)

---

## Label corrections

---

## Run tally

The number that says whether this is working. One row per real run, appended after the verdicts are given. Acceptance rate per label is what a phase-two decision reads: a label dismissed more often than accepted has a probe problem, and the fix goes in the agent file, not here.

| Date | Branch | Findings | Accepted | Dismissed | Mislabelled | Tokens |
|---|---|---|---|---|---|---|
| 2026-09-07 | week-02/baseline (5-entry corpus, `eval/corpus.md`) | 6 (+4 excluded, see note) | 1 | 1 | 0 | 496942 (e01) + 82521 (e02 retry) + 110920 (e03 retry) — partial totals; e02/e03's first (partly-failed) attempts and e04/e05 token counts not separately recorded |

Four findings (`eval/runs/e02-tuesday.json` #1–2, `eval/runs/e05-friday.json`
#1–2) are **excluded from this tally, not verdicted dismissed** — they
compare the diff's historical commit pair against the *current* working
tree (post-`core/`-split), not the tree as it stood at those commits. See
`eval/runs/README.md`. Excluded because a dismissal implies the finding was
fairly tested against its actual diff and failed that test; these weren't
fairly testable at all — a corpus-construction defect, not a reviewer
defect, so counting them either way would misstate the reviewer's real
accuracy.

### Verdict log

One row per finding, appended as verdicts are given. **The tally counts; this log is what makes a per-label rate derivable** — accepted and dismissed totals alone cannot say which label was wrong.

| Run | Finding | Label | Verdict | Note |
|---|---|---|---|---|
| e01-monday | 1 | validation | dismissed | Self-documented incremental WIP — TODO names exactly the 5 deferred checks, dated "Tuesday," completed the next day. See Known non-defects. |
| e01-monday | 2 | duplication | accepted | Real DRY risk (heading list re-declared instead of shared). Independently confirmed the predicted drift already happened: `validate-pack.sh` now cites `model/FORMAT.md §1` in its message, `build-artifacts.sh`'s copy doesn't. |
| e02-tuesday | 1 | duplication | excluded | Methodology artifact — historical diff pre-dates the `core/` split; finding is true of the current tree, not the diffed commits. Not a fair test of the reviewer. |
| e02-tuesday | 2 | dead-code | excluded | Same as above. |
| e05-friday | 1 | duplication | excluded | Same as above. |
| e05-friday | 2 | dead-code | excluded | Same as above. |

### Per-label acceptance

Derived from the verdict log, not maintained by hand. A label dismissed more often than accepted has a probe problem, and the fix goes in the agent file — a probe that keeps pointing at safe code is teaching the reviewer to look in the wrong place.

| Label | Accepted | Dismissed | Mislabelled |
|---|---|---|---|
| duplication | 1 | 0 | 0 |
| validation | 0 | 1 | 0 |

Every label starts with no findings. **No findings is not a passing grade** — it is no data. `dead-code`, and every label besides `duplication`/`validation`, has no verdicted data this run — the 4 excluded findings (2 `duplication`, 2 `dead-code`) are not counted here per the exclusion rule above.
