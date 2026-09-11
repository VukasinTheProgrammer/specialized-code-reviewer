# Report format — Step 5.5 and 5.6

The exact render. Every value comes from the object the Workflow returned (persisted as
`findings.json`); nothing here is composed at render time. Section numbers match `SKILL.md`.

### 5.5 Render

```
1. [ownership] Backend/app/crud/card_repository.py:61
   Any authenticated user reaches another user's card row by sending its public_id.

2. [logic] Frontend/src/pages/user/components/TransactionsTable.jsx:88
   Amount arrives from the API as a string and toFixed reintroduces float error.

3. [ownership · deviates ownership.repository-user-scope] Backend/app/crud/other_repository.py:44
   Any authenticated user reaches another org's record by sending its public_id.
   Guard dropped: the join to PaymentAccount.user_id in the WHERE clause — cf. Backend/app/crud/payment_repository.py:88
```

Summary line is the **first sentence of `failure_mode`, verbatim** — never rewritten. Evidence trace is deferred (not dropped) to `/explain-bug <n>`; a finding without an `evidence` array is stored without one, never reconstructed.

**A finding carrying `deviates_from` (week 7)** gets two additions, both sourced, neither composed: the label chip gains `· deviates <id>` (the field, verbatim), and one line follows the summary — `Guard dropped: <the record's own \`guard\` field, verbatim> — cf. <the record's own \`exemplar\` citation>`. Look the record up by `id` in `model/pr-review-domain.md` (or the run's own `records.json` if still on disk) to get `guard`/`exemplar` — both come from the record as authored, never paraphrased or invented here, the same "nothing here is composed at render time" rule as every other line. Record not found (renamed or removed since the run) — say so on that line instead of guessing: `Guard dropped: record <id> not found in the current pack.`

**The numbered findings are the whole body of the report.** There is no dismissal section: a verifier either proved a defect or dropped it silently, so nothing arrives here describing something that was ruled out. Never add such a section, and never describe a finding as ruled out.

Close every report with what ran:

```
4 findings.  /explain-bug <n> for the trace and the reasoning.
Slices run: Access, Data, Answer, Structure — 4 spawns, scope backend.
Hypotheses: 12 raised, 11 routed, 3 proven, 1 also found by sweep, 0 left unread.
Scout context: graph off this run (no graphify-out/graph.json yet) — related resolved via grep.
Scout classification: 7 governed (6 strong, 1 weak), 4 new.
```

`scout_classification`/`scout_match_strength` (week 6): every changed unit's own answer to *which record governs this code* — never *does it follow that record*, which is a verifier's job (week 7). `governed` (a record applies, `strong` when the matcher and the scout agreed, `weak` when the scout named a record the matcher missed), `new` (no record applies, or the two signals disagreed). A `governed`/`strong` unit's record is routed to its verifier (week 7) — a `weak` one is not; see a finding's own `deviates_from` for whether that comparison actually produced anything.

When the run had a domain pack (`records.json` non-empty), one more closing line, same "printed only when non-zero" discipline as every counter here — a count, never a per-unit list:

```
Conventions: 10 loaded, 4 matched strong, 1 deviation proven. 5 units unprecedented.
```

`loaded` is `records.json`'s own array length (the pack this run actually had, stack-gated — not the pack's total record count if `be`/`fe` excluded some). `matched strong` is `scout_match_strength.strong`. `deviations proven` is how many entries in `findings` itself carry `deviates_from` — count it from the rendered findings, not from a separate tally, so it can never drift from what the report actually shows. `units unprecedented` is `scout_classification.new`. Zero conventions loaded (no pack, or a stale one): skip this line entirely, same as every other zero-count closing line in this file. `scout_failed: true`: skip it too — an empty `context` makes every sub-count a real zero for the wrong reason (the scout crashed, not "nothing governed"), same caution as the `Scout classification:` line above.

`routed` (hypotheses that actually reached a verifier, after the router dropped any outside every slice or outside this repo's stack) is the denominator for precision — read it as `proven ÷ routed`, never `proven ÷ raised`, since `raised` still counts hypotheses no verifier ever saw.

When `dropped_unreachable` is non-zero, add one more closing line:

```
3 candidates dropped as unreachable (closing file not named).
```

When `dropped_invalid_line` is non-zero (§5.3b), add one more closing line:

```
1 finding dropped — line number does not exist in the file at HEAD.
```

When `hypotheses.dropped` is non-zero, add one more closing line:

```
2 hypotheses dropped before reaching a verifier — label outside the closed 15, or outside this repo's stack.
```

When `suppressed_count` is non-zero (week 11, `/pr-review baseline` has run before), add one more closing line:

```
Baseline: 3 pre-existing finding(s) suppressed (model/pr-review-baseline.md, created 2026-09-11T00:00:00Z).
```

No baseline yet (`model/pr-review-baseline.json` doesn't exist): skip this line entirely, same as every other zero-count closing line in this file — most repos are in this state, and it is not a degrade to name.

`raised` minus `routed` already implies this number, but only to a reader who
knows to subtract. Name it: a non-zero count on a run whose scope should own
those labels is the signature of a scout emitting a label that does not exist
(a typo, or a reference block in its prompt misread as a 16th label), and that
is a lost hypothesis, not a filtered one.

When `degraded` is non-empty, name it right after `verified_clean`/`failed`, never silently folded into either:

```
Degraded: Data — 3 findings returned, none renderable (missing fields). db and concurrency were not reliably reviewed.
```

When `slice_mismatch` is non-empty, name the labels a verifier's own echo didn't cover:

```
Warning: Answer echoed its slice without state — treat state as unreviewed this run.
```

### 5.6 A clean report names what was checked

```
No findings.

Verified clean: Access, Data, Answer, Structure — 4 spawns, scope frontend.
Hypotheses: 7 raised, 7 routed, 0 proven, 0 also found by sweep, 0 left unread.
Scout context: graph off this run (no graphify-out/graph.json yet) — related resolved via grep.
Scout classification: 3 governed (3 strong), 2 new.
```

A failed spawn is always named separately, never silent:

```
Verified clean: Access, Answer, Structure — 3 spawns.
Failed:         Data — returned nothing parseable. db and
                concurrency were not reviewed on this branch.
```

