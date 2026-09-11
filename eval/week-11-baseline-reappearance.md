# Week 11 — baseline reappearance-rate measurement

Written 2026-09-11. Closes a gap week 12's own detail page ("Ship,
Don't Port") assumes is already filled: its README-content instructions
cite "the baseline reappearance rate from week 11 — the measured
number, on a 2,300-file repo across twenty commits" as "the single most
credible sentence you can put in a README." Week 11's own work
(`todays-work/week11/monday.md`) produced one synthetic single-diff
baseline snapshot, not a reappearance-rate study — this closes that gap
with a real one.

## What "reappearance rate" actually measures here

`model/baseline.py`'s fingerprint is `file::line::label`, exact-match
only — its own docstring names the limitation: "a genuinely unrelated
line added above a baselined finding renumbers it, so the fingerprint
no longer matches and the same pre-existing defect reports again as
'new'." That was a stated risk, never a measured one. This measures it:
given a fixed baseline, how often does ordinary, unrelated commit
churn on the same file break the fingerprint before the underlying
code (and the real defect) has changed at all?

**Scope, honestly smaller than the plan's placeholder number.** The
plan's own text ("a 2,300-file repo across twenty commits") was written
before any measurement existed — a directional guess, not a literal
target. What's measured here: the 3 real findings from
`model/partners/headroom/pr-review-baseline.json` (headroom's
`headroom/transforms/`, 38 files, not the whole ~2,300-file repo),
walked forward through 23 real commits (not exactly 20 — the real
number the repository's own history gave, not fudged to match). Same
repo, same real commits, narrower scope than the plan's placeholder —
stated plainly rather than let the number imply more coverage than it
has.

## Method

Zero LLM spawns — pure git archaeology, cheaper and more direct than
re-running the full scout+verifier pipeline at each commit for a
question that's really about line-number stability, not review
quality.

1. Fresh clone of `headroomlabs-ai/headroom` (`--depth 200`, since the
   week-10/week-11 baseline runs used shallow single-commit clones with
   no history to walk).
2. Every commit touching `headroom/transforms/` within that depth: 24
   commits, oldest to newest, real HEAD (`04cdf79`) matching the exact
   commit the baseline's 3 findings were taken against (confirmed: each
   finding's exact line content at real HEAD matches the baseline
   verbatim before this measurement started).
3. `6147883` (the oldest of the 24) set as the hypothetical "baseline
   commit." For each finding, recorded its exact line content's line
   number there.
4. Walked forward through the remaining 23 commits in order. After
   each, checked (by literal content match via `git show
   <sha>:<path> | grep -nF`, not by trusting a stored line number) where
   that same line's content now sits — same line, a different line
   (drifted), or gone entirely.
5. Compared every checkpoint against the **original** baseline line,
   never a running/updated one — `apply()`'s real fingerprint check
   always compares against what was stored at baseline time, never a
   sliding value, so that's the fair comparison for "would this still
   suppress correctly right now."

## Result

| finding | file | size | stability across 23 commits |
|---|---|---|---|
| `content_router.py:4822` (concurrency) | `headroom/transforms/content_router.py` | 6,751 lines, the pack's own hottest file | drifted after the **1st** commit (4724→4738), never realigned — mismatched at all 23 checkpoints |
| `read_maturation.py:65` (duplication) | `headroom/transforms/read_maturation.py` | 464 lines | stable for **20** commits, then shifted exactly 1 line (64→65) the moment a commit touching that file itself landed (`85f58a9`, titled `fix(read-maturation): ...`) |
| `read_lifecycle.py:58` (dead-code) | `headroom/transforms/read_lifecycle.py` | 515 lines | stable across **all 23** commits — file never touched in this window |

**By real HEAD, 23 real commits later: 1 of 3 findings (33%) still
fingerprint-matches the original baseline.** The other 2 would report
as new findings on a real second run, despite the underlying pattern
never having changed.

**Drift correlates with file churn/size, not with anything about the
finding itself.** The one finding that drifted almost immediately sits
in the pack's largest, most actively edited file (13 of the 23 commits
touch `content_router.py` somewhere above line 4822); the two stable
findings sit in smaller files that were touched rarely or never in this
window. This is a plausible, not yet independently confirmed,
mechanism — n=3 findings is not enough to separate "large file" from
"this specific file happens to be a hotspot" as the real driver, and
this measurement doesn't try to.

## What this is, and isn't, evidence for

**Is:** a real, measured instance of the fingerprint's own named
limitation, on real commit history, not a hypothetical. Confirms the
risk `model/baseline.py`'s docstring already flags is not theoretical —
it fired twice in 23 commits on a 3-finding sample.

**Isn't:** a general reappearance rate for this reviewer, this repo, or
any repo. n=3 findings, one file subtree, one specific 23-commit
window. A different baseline (more findings, a quieter file set, a
different repo's churn pattern) would very plausibly measure
differently. Report the number as what was measured — 2 of 3 drifted
within 23 commits on this specific sample — not generalized to "this
reviewer's baseline decays at rate X."

**For week 12's README:** cite this measurement directly, scoped
honestly (headroom's `headroom/transforms/`, 3 findings, 23 real
commits — not the plan's placeholder "2,300-file repo, twenty
commits"), rather than either skipping the number or overstating its
reach. The limitation itself — exact-match fingerprinting doesn't
survive unrelated line-shifting churn — is the real, generalizable
claim; this measurement is one honest data point for it, not a
statistically powered study.

## Cleanup

Throwaway clone and scratch scripts removed after the measurement;
nothing left on disk outside this write-up and the (unchanged)
existing baseline files.
