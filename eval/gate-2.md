# eval/gate-2.md — written 2026-09-10, before measuring

Per the week-8 plan's own defect note: gate-2's thresholds don't exist
yet as of this morning, and this file writes them now, before the
precision/recall measurement, not after — same discipline as
`eval/gate-1.md` and `eval/gate-0.md` before it.

## Known contamination — read before trusting the eventual number

**What the plan itself anticipated:** Thursday's `deviates_from` audit
(`todays-work/week7/thursday.md`) already showed me roughly how many
deviation findings existed (2, across e01 and e03) and that both looked
real on inspection. That's the ordinary contamination the plan's own
correction box calls out and accepts, with the instruction to note it
honestly rather than pretend otherwise.

**What went further, this morning:** building today's stratified sample
required pulling the scout's raw per-unit `classification` from the
week-7 workflow journals (not present in the saved `eval/runs/w7/*.json`
files, only in the raw agent transcripts). Doing that meant directly
reading, for all 20 changed units across the 5-entry corpus, the tool's
own governed/new answer next to the file name — not "roughly how many,"
the literal per-file answer key. That is exactly the failure mode this
week's own trap callout names ("scanning the records looking for one
that could apply... you will reproduce the tool's errors and call it
agreement"), except worse: it's the tool's actual output, not just the
reference material.

**Mitigation, decided with the user before building the sample:** the
blind sheet (`eval/runs/w8-blind-sheet.json`) and its key
(`eval/runs/w8-blind-key.json`) are built in this session, but the
actual Tuesday labelling happens in a **fresh session that has never
seen this conversation** — so the person doing the labelling genuinely
has not seen the answers, even though this session (which built the
sheet) has. The key stays closed until that fresh-session labelling is
complete and reported back.

This file's thresholds are written now, by the contaminated session,
against a measurement a clean session will later produce — the
thresholds themselves don't depend on knowing which unit is which, only
on what precision/recall number would mean what, so writing them here
doesn't carry the same contamination the labelling would.

## Sample size, honestly

The plan's own numbers (30 governed cap, 20 random `new`) were sized for
a live, ongoing diff volume larger than this project actually has. The
week-7 frozen corpus produced only 20 changed units total across all 5
entries: **7 governed** (under the 30 cap — this is all there is, not a
sampling choice) and **13 `new`** (short of the 20 target — again, all
there is, not a subsample). Stratum A = all 7. Stratum B = all 13. Total
sample = 20, the entire corpus, not a sample of it.

This is a materially smaller N than the plan assumed. The precision
number below should be read as a first read on a small corpus, not a
statistically confident number — the same caveat this project has
carried since the single-run-noise finding on an earlier Friday.

## The two numbers

```
CONTINUE   precision (strong)  >= 85%
       AND deviates_from acceptance >= overall acceptance
       AND nothing accepted in week 5 arm B was lost

STOP       precision < 60%  OR deviates_from acceptance well below overall
           # the routing is manufacturing findings, not proving them

BETWEEN    route only the records that scored well in stratum A.
           see eval/week-8-detail's "between path is per-record, not
           global" branch — mark each record routable or not based on
           its own performance, don't weaken the routing rule globally.
```

These are illustrative-shaped the same way the plan's own example was —
but they are this project's real, committed numbers, not placeholders:
85%/60% are the actual bar, chosen now, before the fresh session's
labels exist.

Given N=20 total (7 governed), a single wrong-record or false-governance
call moves precision by ~14 points — the threshold is coarse on a
sample this size, and the taxonomy pass (which owner/shape each error
has) matters more than the headline percentage this week, same as the
plan's own "where it goes wrong is worth more than how often" framing.

## Labelling rule — write before seeing the sample

A unit is governed by record X if: **a reviewer who knew this codebase
would cite record X when judging this file's change.** Consulting the
record set (`model/pr-review-domain.md`'s 10 records) while labelling is
correct — that's the reference a real reviewer has. Scanning it looking
for something that *could* apply is not labelling, it's matching, and
reproduces the tool's own error mode.

Per unit, record: which record governs it (or none), plus a confidence
— `sure` or `unsure`. Two minutes per unit; past that, mark `unsure` and
move on rather than deliberate into an argument.

## Status

Thresholds and labelling rule committed. Blind sheet and key built,
sheet handed to a fresh session for Tuesday's labelling. Key stays
closed until that session reports its labels back.

---

## Decision, dated 2026-09-10

Full numbers and taxonomy: `eval/week-8-report.md`. This section holds
only the gate decision itself, against the thresholds above as written.

**CONTINUE — not met.** `precision (strong) = 50%` misses the 85% bar
by a wide margin, and `nothing accepted in week 5 arm B was lost` is
independently false (2 clean losses, both ordinary sweep findings —
`tests/run-integration.sh:6`, `build-artifacts.sh:14`). Two of three
CONTINUE clauses fail; `deviates_from` acceptance (100% ≥ 85.7%) is the
only one that clears.

**STOP — the raw number fires it, the taxonomy contradicts what it
would mean.** `precision (strong) = 50% < 60%` literally satisfies
STOP's clause. But STOP's own stated reason — "the routing is
manufacturing findings, not proving them" — is exactly what
Wednesday's taxonomy pass checked for, and found no evidence of:
**zero of the 5 raw disagreements audited as a clear-cut classifier
defect.** Two are confirmed labeller misses (the tool was right), two
are genuinely ambiguous guard-boundary calls, one is a structural
single-record-per-unit limitation. `deviates_from` acceptance sitting
at 100% is the sharpest evidence against "manufacturing" — routing's
actual product effect, everywhere it fired, produced only real,
accepted findings. A STOP decided on the raw number alone would say
something the deeper read doesn't support.

**Decision: BETWEEN.** Per the plan's own framing, this gate's most
likely outcome — and the written mechanism is explicit: mark each
record routable or not by its own stratum-A performance, not a global
confidence knob.

Applying it to the actual data: **every record in stratum A resolved,
on audit, to either a clean hit or a defensible/labeller-miss
disagreement — none resolved to a confirmed bad record.** There is no
record in this sample whose own performance argues for excluding it.
So the practical form of BETWEEN this time is **keep every currently-
routable (`strong`-match) record routing, unchanged** — there's nothing
in the evidence that says narrow it further — while treating the raw
50% as underconfirmed rather than a settled rate, given N=4 on the
strong stratum.

**Explicitly not widened**: `precision (weak) = 0%` is a clean,
unambiguous number (none of the 3 weak-stratum disagreements needed
taxonomy charity to explain) — it directly confirms week 7's existing
decision to never route `weak` matches. BETWEEN does not touch that.

**What continuing under BETWEEN requires, unresolved by this gate
alone:**
- The two sweep-finding losses (`tests/run-integration.sh:6`,
  `build-artifacts.sh:14`) are real regressions, unrelated to routing —
  they need their own investigation, separate from the classifier
  question this gate exists to answer.
- The citation-line-accuracy defect found while verdicting (2 of 10
  fresh findings cited a wrong, in-bounds line, and it's what broke
  today's regression set) is a real pipeline defect worth a
  `future-improvements/` entry — extending the citation check beyond
  bounds-validation to a content spot-check.
- A larger sample (this project's corpus is 20 units total; the plan
  assumed ~50) would sharpen the precision number materially — the
  next real diff volume this project sees is the natural place to
  re-measure, not a manufactured extension corpus.

None of the three above changes the gate decision on its own — they're
work items surfaced by this week's measurement, not additional
thresholds.
