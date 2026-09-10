# Week 8 — gate 2 measurement report

Written 2026-09-10. Precision/recall computed Wednesday, findings vs.
week 5 computed Thursday — both from the frozen `v0.7-routing` corpus,
no code changes this week (`eval/gate-2.md`'s Monday note; the plan's
own "no code changes at all" rule for this week).

## Contamination, named up front

Building today's stratified sample required reading the tool's real
per-unit classification for all 20 units before the blind sheet existed
— worse than the plan's own anticipated contamination (`eval/gate-2.md`
has the full account). Mitigated by delegating the actual blind
labelling to a fresh, context-free agent that never saw this
conversation and confirmed it never opened the answer key. The
thresholds and labelling rule (written by the contaminated session, but
not dependent on knowing which unit is which) stand as written.

## Number 1 — classifier precision

| | N | correct | wrong_record | false_governance |
|---|---|---|---|---|
| Stratum A (governed), all | 7 | 2 | 1 | 4 |
| — strong | 4 | 2 | 0 | 2 |
| — weak | 3 | 0 | 1 | 2 |

- **precision (strong) = 50.0%** (2/4) — the number gate-2's thresholds
  gate on, since only `strong` matches route.
- precision (all) = 28.6% (2/7). precision (weak) = 0.0% (0/3).
- Recall = 100% (2/2) against stratum B (13 units, 0 missed) —
  **caveated, not confirmed**: this is against the frozen blind labels,
  not a re-audit of all 13 "new" units, and the same 2-minute-per-unit
  constraint that missed 2 real governed calls in stratum A could
  plausibly under-report missed governance in stratum B too.
- Errors landed on `unsure`-confidence units 4 of 5 times (80%).

**Sample size is smaller than the plan assumed** — 20 total changed
units across the whole frozen 5-entry corpus (7 governed, 13 new), not
30+20=50. A single wrong call moves stratum-A precision by ~14 points.

### The taxonomy pass — the part that changes how the 50% should read

Every one of the 5 raw disagreements was read against its actual diff
and the real record text, not just scored mechanically (full detail:
`eval/runs/w8-scoring.json`):

- **2 confirmed labeller misses** (`u-07`, `u-13`) — the tool was
  right; the 2-minute blind pass missed it. `u-13` is the cleanest:
  `tests/run.sh`'s unguarded `git rev-parse` is the exact line Thursday
  of week 7 independently found and accepted as a real finding.
- **2 genuinely ambiguous guard-boundary calls** (`u-09`, `u-14`) —
  defensible either way depending on how literally a record's guard
  text is read.
- **1 structural single-record-per-unit limitation** (`u-11`) — two
  records honestly apply to the same diff; not a matcher or record bug.

**Zero of the 5 disagreements audited as a clear-cut classifier
defect.** The raw 50% strong-precision number is real (not re-scored —
the frozen blind labels stand), but the taxonomy shows it substantially
understates what a careful read of the same 4 disagreements supports.

### Precision(weak) = 0% is a clean, positive confirmation

Unlike the strong-stratum disagreements, the 3 weak-stratum errors
don't need the same benefit of the doubt — `precision(weak) = 0%` is
exactly consistent with, and reinforces, week 7's own design decision to
never route `weak` matches. No finding here argues for widening routing
to `weak` — the opposite.

## Number 2 — findings, against week 5 arm B

| Measure | Week 5 arm B | Week 7 | Δ |
|---|---|---|---|
| accepted / run | 2.2 | 2.4 | +0.2 |
| acceptance rate | 100% | 85.7% (12/14) | −14.3pp |
| `deviates_from` acceptance | — | **100% (3/3)** | clears gate-2's clause (≥ overall 85.7%) |

Per-label delta (accepted counts): validation 6→5 (−1), duplication
4→3 (−1), contract 1→3 (+2), control-flow 0→1 (+1), logic 0→0 (0).

**Sweep findings lost, named plainly (not buried):**

- `tests/run-integration.sh:6` (validation, unguarded `ROOT=`) — still
  real today, accepted in week 5, **not reproduced anywhere in week
  7's 14 findings.**
- `build-artifacts.sh:14` (contract, undocumented new artifact) —
  accepted in week 5, **not reproduced anywhere in week 7.**
- Week 7's `e05-friday` run itself produced zero findings, where week
  5 arm B's same-corpus run found one accepted finding there — though
  that finding's substance survives elsewhere in week 7.

Neither loss is `deviates_from`-related — both are ordinary sweep
findings, unconnected to routing or classification. Full detail:
`eval/runs/w8-week7-vs-week5.json`.

### A real citation-accuracy defect, found by verifying instead of trusting

2 of the 10 freshly-verdicted week-7 findings cite a valid-but-wrong
line for an otherwise-real defect (the actual code is 2–6 lines away).
This mechanically **fails today's regression set** — the one existing
case expects an exact `file`+`line`+`label` match, and the citation
drift alone breaks it, even though the underlying defect is genuinely
present in the finding list. Root-caused, not softened: `eval/runs/w8-week7-vs-week5.json`'s
`regression_set` block and `citation_line_accuracy` block.

**Regression set: FAIL**, for this reason — not lost coverage.

## Confidence cross (from Wednesday)

The one `sure`-confidence error (`u-09`) turned out to be the *most*
ambiguous of the five on audit, not the most clear-cut — confidence
wasn't a reliable signal on this sample. The other 4 errors, all marked
`unsure`, mostly resolved to labeller misses or genuine ambiguity, per
the plan's own expectation that unsure-marked disagreements are where
"the classifier is failing where a human also struggled."

## What got worse, everything, in one place

- Strong-precision raw score (50%) is well below gate-2's 85% CONTINUE
  bar and at the 60% STOP line — even though the taxonomy suggests the
  true rate is meaningfully higher.
- 2 sweep findings lost since week 5, both ordinary (non-`deviates_from`)
  findings.
- Acceptance rate down 14.3pp from week 5's 100% (12/14 vs 11/11) —
  though still above 2 of 3 new findings' worth of real defects, and the
  2 dismissals were a known-non-defect repeat and a too-narrow gap, not
  fabricated findings.
- Regression set FAILs, for a real (citation-drift) reason, not a
  hypothetical one.
- Sample size (N=20, 7 governed) is smaller than the plan assumed —
  every number above should be read at that confidence, not as a
  confirmed rate.

## What held or improved

- `deviates_from` acceptance is 100% (3/3) — routing's actual product
  effect, where it fired, produced only real findings.
- `contract` and `control-flow` gained ground (+2, +1) — labels that
  had thin or no coverage in week 5.
- `precision(weak) = 0%` positively confirms week 7's decision to never
  route weak matches.
- Zero of the 5 raw precision disagreements audited as a genuine
  classifier defect — the taxonomy found labeller misses, ambiguity,
  and a structural limitation, not evidence the matcher is asserting
  wrong records with confidence.
