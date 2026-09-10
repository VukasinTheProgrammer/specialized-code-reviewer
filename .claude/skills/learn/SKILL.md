---
name: learn
description: Assisted domain-pack authoring — proposes candidate `## Label probes` records with real citations from a repo's own hub files, and asks a human to accept/edit/reject each one before anything is written. Unlike `generate-domain-pack` (fully autonomous), this is the human-in-the-loop mode from the plan's week 9-10 slice. A controlled same-scope comparison (`todays-work/week9/wednesday.md`) found citation quality is not where the human step earns its keep — a well-specified auto prompt already polices that reasonably well; label/taxonomy fit against the closed 15's *canonical* meaning (`core/agents/verify-*.body.md`, not just a sibling pack's existing examples, which can under-sample a label's real scope) is where a genuine miss showed up in testing. Use when onboarding a new repo (especially one not yours) where a person's taxonomy judgment is wanted, or when `generate-domain-pack`'s output needs a second, label-skeptical pass — not merely a citation-skeptical one.
---

Produces the same six-section domain-pack shape `generate-domain-pack` does (`model/FORMAT.md`), but never writes a candidate the human hasn't seen and accepted. The scan and the draft are automated; the judgment call ("is this actually a convention, not just one file with an opinion") stays human. Target: 15-30 proposed candidates, and — per the plan's own "done when" — a usable model file in under an hour of the reviewer's own time, beating week 4's hand-authored baseline of ~19 minutes per record (`todays-work/week4/friday.md`). **That comparison is honestly softer than it sounds** — week 4 was cold-authoring from unfamiliar code, this is accept/edit/reject against pre-drafted, pre-cited candidates; a real speed advantage showed up in the one run so far (`todays-work/week9/tuesday.md`) but it's not a clean apples-to-apples number, and the write-up should say so rather than claim a flat multiple.

## Step 0 — Preflight

Same collision check as `generate-domain-pack`, same reason:

```bash
git worktree list | grep -F "<tmp>" && echo "STOP: <tmp> already a worktree — pick a different path or remove it first"
```

Ask, if not already given: which repo, which base branch, which subtree/scope (a whole small repo, or one stack of a larger one — narrower is better for a first pass; a bounded sample beats a shallow full-repo skim), and whether the target is a fresh pack or additions to an existing one (`model/pr-review-domain.md` for this repo itself, or `model/partners/<name>/pr-review-domain.md` for a foreign one, same convention as `generate-domain-pack`'s partner-pack extension).

## Step 1 — Worktree and graph

Identical to `generate-domain-pack` Step 1 — a base-branch-scoped worktree, `graphify update <tmp>` (or the in-scope subtree if the target is narrower, e.g. `<tmp>/crates` — an unscoped whole-repo index dilutes discovery on anything short of the whole repo; confirmed this costs real quality in `future-improvements/week-9-code-review-graph-as-a-view-on-graphifys-map.md`'s scoped-follow-up section):

```bash
git worktree add <tmp> <BASE>            # <BASE> is a branch name; for a
                                         # detached checkout at a fixed SHA
                                         # use `git worktree add --detach <tmp> <SHA>`
                                         # and treat HEAD as <BASE> everywhere below
graphify update <tmp>[/<scope>]          # graph.json lands at <tmp>[/<scope>]/graphify-out/graph.json
```

Continue without it if it fails or isn't installed — Step 2 falls back to Grep/Glob. Pass that `graphify-out/graph.json` path to every `graphify` call in Steps 2-3 via `--graph`.

## Step 2 — Import-graph scan for hub candidates

Find the files worth drafting a record *from*, not yet the records themselves. A hub file (high import fan-in, a router/dispatch aggregation point, a shared error/enum map) is more likely to hold an established convention than a leaf file, and its inbound edges give you witnesses for free.

- **Graphify available**: `graphify explain "<candidate>" --graph <graph.json>` and its `Degree:` line, or `graphify query "router registration and dependency wiring" --graph <graph.json>`, the same discovery move `generate-domain-pack` Step 2's Wiring-files bullet already uses. (`graphify path "<a>" "<b>" --graph <graph.json>` also exists — a shortest-path trace between two named nodes — but it's rarely the right tool at this stage; `explain`/`query` are what find hubs.)
- **No graphify**: grep for import fan-in (`grep -rn "^(import|use|from) " | sort | uniq -c | sort -rn`, adapted to the stack's own import syntax) and `mod.rs`/`lib.rs`/`index.ts`-shaped re-export hubs.

Bound the sample — aim for **15-30 candidates for a whole small repo or a full stack; scale down for a narrow sub-package** (a single ~20-30k-line module might honestly only hold 8-12 real conventions, and that is a right-sized result, not a low-count finding). Pick enough hub files that a handful of genuinely-repeated patterns can surface, not so many that Step 3 drafts more than a person can review in one sitting. A count well under 10 *for a repo that should have more* is the real finding the error-handling table means.

## Step 3 — Draft candidates (proposer only, never a writer)

One `general-purpose` agent, **Read, Grep, Glob, and Bash restricted to `graphify query|explain|path` inside `<tmp>` only — no Write, no Edit**. Its only job is to return a list of draft candidates as its final message, structured one-per-record:

```
label:       <one of the closed 15>
statement:   <one sentence, what correct looks like>
exemplar:    <path:line>
witnesses:   <path:line>, <path:line>  (at least 1 found independently; 2nd witness may still be missing — that's fine, see below)
guard:       <the specific mechanism, citing lines>
unsafe_when: <what would make the same shape a real defect>
```

Same two rules as `generate-domain-pack` Step 2: cite only patterns that exist on `<BASE>`, and a candidate names a correct pattern to compare against, never a defect currently in the tree. **A draft with only one witness is still worth proposing** — mark it clearly (`witnesses: 1 found — needs your second`) rather than silently padding to two or silently dropping; a reviewer who has actually seen the pattern elsewhere can supply it (`model/FORMAT.md` §3d's `human_approved: true`), and one who hasn't can reject it. Don't overweight this step, though — a well-specified proposer prompt tends to find real second witnesses on its own often enough that this isn't where a human's judgment is most needed (`todays-work/week9/wednesday.md`); Step 4's label-fit check is.

The proposer never writes a file. Its return value is the candidate list, held in this conversation, not on disk — nothing exists yet that `validate-pack.sh` or a stray `git status` could trip over.

## Step 4 — Accept / edit / reject, in conversation

Present candidates in batches (5-8 at a time, not all 15-30 at once — a person reviewing citations needs to actually open some of them). For each: show the drafted fields plus the exemplar's real surrounding code (a short excerpt, not just the citation) so the reviewer isn't asked to trust a `path:line` blind.

Use plain conversational review, not a constrained-choice tool — this content is multi-paragraph and citation-heavy, a poor fit for a short-label picker. Ask the reviewer to reply per-candidate: accept as-is, accept with a specific edit (a different exemplar, a corrected guard, a supplied second witness), or reject with why. Log every rejection's reason briefly — a same-shape candidate rejected twice for the same reason is worth naming as a promoted non-defect (`model/FORMAT.md` §4b) instead of drafting a third time.

**If no separate reviewer is available — you are running `learn` solo:** you still do this step, you just play both sides. Draft the candidates in Step 3, then come back to Step 4 in an explicitly adversarial frame: your job now is to *reject your own drafts*, not defend them. Go candidate by candidate, apply every check below in full (especially the label-fit check), and treat "I already decided this was good in Step 3" as no evidence at all. A solo run that keeps 12 of 12 candidates did not review them. Record which candidates changed outcome between Step 3 and Step 4 — that number is the only real signal that the review happened.

**Two separate questions, not one.** "Is this citation real" and "does this belong under this label" are different judgment calls, and a reviewer moving fast tends to only ask the first. A well-specified proposer prompt already polices citation quality reasonably well on its own — a controlled comparison (`todays-work/week9/wednesday.md`) found a full-auto run's citations as clean as, and on two patterns cleaner than, a human-reviewed one. A follow-up blind test (a fresh reviewer, no hint which candidate to distrust) confirmed the label-fit check catches real things: it independently flagged a candidate labeled `ownership` (a caller-supplied identity header honored only from a verified-local caller) as reading more like `security` next to its only real `ownership` sibling in the repo (a test-substitution pattern for a live credential source) — a genuine, non-obvious mismatch, caught with no worked example to crib from.

**The same test also caught a mistake in this skill's own earlier guidance, which is worth stating plainly rather than quietly fixing.** An earlier version of this section used a local-file atomic-write record filed under `db` as its worked example of a mislabel. It was wrong: `db`'s canonical scope in this project (`core/agents/verify-data.body.md` — the actual defining source, not just whatever one sibling pack happens to show) is explicitly *not* limited to SQL — "a cache, a document store, a checkpointer, anything with its own durability contract" is named in scope, and the label's own guiding question is "does the data survive, exactly once?" An atomic temp-file-then-rename is squarely that. The earlier guidance inferred `db`'s meaning from a single sibling pack that only happened to show SQL examples — under-sampling the label's real scope, the exact mistake this whole check exists to prevent, just one level up. **Check a label's canonical definition in `core/agents/verify-*.body.md` before rejecting a candidate for not matching one sibling pack's narrow sample** — a sibling pack shows *a* usage, not the label's full scope, and treating it as the ceiling repeats this exact error.

So for every candidate, ask explicitly: **does this match the label's canonical definition, and does it read sensibly next to a real sibling if one exists?** Both checks matter; neither alone is sufficient — a sibling-only check can under-sample (as above), and a definition-only check without an example can still misjudge tone/scope. This is the check a citation-verification pass structurally cannot do, and it is the actual reason a human belongs in this loop — treat it as load-bearing, not a nice-to-have on top of citation review.

**When there is no sibling** — a brand-new partner repo, no prior pack under that label anywhere you're allowed to read — the check is definition-only, and the skill just told you that isn't sufficient alone. So raise the bar instead of lowering it: for a would-be *first* record under a label, the canonical definition in `core/agents/verify-*.body.md` has to fit *without stretching* — if you find yourself arguing the pattern "sort of counts" as `contract` or `control-flow`, that's the signal it doesn't. `model/FORMAT.md` §4 is explicit that a real, well-witnessed pattern fitting none of the 15 labels "isn't a record's business" — dropping it is the correct call, not a gap in the pack. The blind test (`todays-work/week9/`, and the week-10 cold run) both had their sharpest catches here: a genuine repo-wide pattern that matched no label's real meaning, which a citation-only or a keep-if-plausible review would have shipped.

Do not move to Step 5 for a candidate still pending a reply — half-reviewed is not accepted.

## Step 5 — Verify every accepted citation, independently

Same discipline as `generate-domain-pack` Step 3, run by you (not trusted from the proposer or the reviewer's own memory) before anything is written:

- Every citation containing a `/` resolves against the **worktree**: `git -C <tmp> show <BASE>:<path>` succeeds and the cited line is within the file's real line count.
- If the reviewer supplied an edit (a new exemplar, a new second witness), that new citation gets the same check — an edit is not exempt from verification just because a human typed it.

A citation that fails this is dropped, not patched — re-derive it from the worktree or drop the candidate, the same two-rules-above discipline as everywhere else in this pipeline.

## Step 6 — Write the accepted records

**If the target pack already exists:** append the accepted records into its `## Label probes` section, in `model/FORMAT.md` §3's exact shape, and touch nothing else.

**If you are creating the pack (a repo with no pack yet — the common `learn` case):** you must still emit all six `## ` headings `model/FORMAT.md` §1 requires, or Step 7's `validate-pack.sh` fails the whole file before it ever looks at a record. `learn`'s *judgment* scope is `## Label probes` only — the section where "is this really a convention" is a human call. The other five headings go in as valid stubs, not real content:

- `## Stack scope prefixes` — the one line of prose the format allows (e.g. "Single-stack (Python) — no prefix split"), or a real prefix table if the repo is genuinely multi-stack and you know the split.
- `## Wiring files` — a **closed** ```` ``` ```` fence (§2). List the hub files Step 2's scan already surfaced, one repo-relative path per line; an empty fenced block is valid if you're unsure.
- `## Promoted non-defects` — just the heading, nothing under it (§4b: empty is normal).
- `## Brief probes` — a ```` ```bash ```` fence that passes `bash -n` (§5). A single `:` (no-op) line is a valid stub; do **not** hand-write real probe shell here — that's `generate-domain-pack`'s job and it carries its own `eval`-trust caveat.
- `## Dependencies` — the heading plus whatever you can read straight off the manifest (`Cargo.toml`/`pyproject.toml` `[dependencies]`), or "None recorded." if you didn't check.

A later `/generate-domain-pack` run fills the stub sections in properly; `learn`'s output is a valid, reviewable pack from the first run, not a fragment that needs a second tool to parse.

**Every record accepted with fewer than 2 witnesses gets `human_approved: true` written into it here** (`model/FORMAT.md` §3d) — this is not optional and not automatic; it is the one concrete trace, in the pack itself, that a person (not the proposer) vouched for that specific record. Forgetting it is a real, silent failure mode: the record fails Step 7's `validate-pack.sh` for a reason ("witnesses < 2") that reads like a citation problem but is actually a missing marker, and re-verifying citations that were already fine wastes the exact effort Step 7's error-handling table warns against. A record the reviewer edited to *supply* a genuine second witness does not need the field — it now has 2 real citations and stands on its own, same as any auto-generated record.

## Step 7 — Verify format and refresh artifacts

```bash
# For this repo's own pack:
bash model/validate-pack.sh model/pr-review-domain.md
bash .claude/skills/pr-review/scripts/build-artifacts.sh <BASE>

# For a partner pack (any repo that isn't this one): the SECOND ARG IS
# REQUIRED and is the worktree path from Step 1 — not optional. Without it
# validate-pack.sh resolves every citation against *its own* repo, where
# none of them exist, and fails the whole pack.
bash model/validate-pack.sh model/partners/<name>/pr-review-domain.md <tmp>
# no build-artifacts.sh run for a partner pack — it targets this repo.
```

Non-zero exit → the write introduced a format problem Step 5's citation check doesn't catch (a malformed `id` slug, a missing required field, a section heading not emitted per Step 6) — fix the record or heading shape, don't touch the citations again.

## Step 8 — Remove the worktree (mandatory, verified, never skipped)

Same command, same `--force` reasoning (an untracked `graphify-out/` from Step 1 blocks a plain remove), same "run even on a partial failure" rule as `generate-domain-pack` Step 5 — see that step for why, rather than restating it here to drift out of sync with it. Run it even if Steps 2-6 failed partway.

## Timing, per the plan's own "done when"

Note wall-clock from Step 0 to Step 8, and separately the reviewer's own active time in Step 4 (not idle time between batches). The bar is under an hour of the reviewer's time, and it should beat week 4's ~19 minutes/record hand-authored baseline — record both numbers in the write-up, honestly, including if it doesn't beat that bar.

## Error handling

| Situation | Do |
|---|---|
| Step 0's collision check finds `<tmp>` already registered | Stop before Step 1. Resolve the stray worktree first. |
| `graphify update` fails or isn't installed | Continue — Step 2 and Step 3 fall back to Grep/Glob. |
| Step 3's proposer returns fewer than ~10 candidates | Report the low count rather than padding — a hub-poor or genuinely convention-light repo is a real finding, not a proposer failure. |
| A candidate is rejected twice across sessions for the same repo, same shape | Consider it for `## Promoted non-defects` on the target pack, not a third re-draft. |
| Step 5 finds an edited citation doesn't resolve | Drop that candidate — a human-supplied citation gets the same bar as an agent-drafted one, no exception. |
| Step 7's `validate-pack.sh` fails after a clean Step 5 | A record-shape defect (bad `id` slug, wrong field name), not a citation defect — fix the shape, don't re-verify citations that already passed. |
| Step 7 fails specifically on `witnesses < 2` for a record you know the reviewer accepted | Step 6's `human_approved: true` marker is missing, not a citation problem — add it (`model/FORMAT.md` §3d) and don't touch the citations. |
