---
name: learn
description: Assisted domain-pack authoring — proposes candidate `## Label probes` records with real citations from a repo's own hub files, and asks a human to accept/edit/reject each one before anything is written. Unlike `generate-domain-pack` (fully autonomous), this is the human-in-the-loop mode from the plan's week 9-10 slice — the witness count doesn't come from an agent judging its own citation, it comes from the person reviewing the diff. Use when onboarding a new repo (especially one not yours) where you want a person in the loop, or when `generate-domain-pack`'s output needs a second, skeptical pass.
---

Produces the same six-section domain-pack shape `generate-domain-pack` does (`model/FORMAT.md`), but never writes a candidate the human hasn't seen and accepted. The scan and the draft are automated; the judgment call ("is this actually a convention, not just one file with an opinion") stays human. Target: 15-30 proposed candidates, and — per the plan's own "done when" — a usable model file in under an hour of the reviewer's own time, beating week 4's hand-authored baseline of ~19 minutes per record (`todays-work/week4/friday.md`).

## Step 0 — Preflight

Same collision check as `generate-domain-pack`, same reason:

```bash
git worktree list | grep -F "<tmp>" && echo "STOP: <tmp> already a worktree — pick a different path or remove it first"
```

Ask, if not already given: which repo, which base branch, which subtree/scope (a whole small repo, or one stack of a larger one — narrower is better for a first pass; a bounded sample beats a shallow full-repo skim), and whether the target is a fresh pack or additions to an existing one (`model/pr-review-domain.md` for this repo itself, or `model/partners/<name>/pr-review-domain.md` for a foreign one, same convention as `generate-domain-pack`'s partner-pack extension).

## Step 1 — Worktree and graph

Identical to `generate-domain-pack` Step 1 — a base-branch-scoped worktree, `graphify update <tmp>` (or the in-scope subtree if the target is narrower, e.g. `<tmp>/crates` — an unscoped whole-repo index dilutes discovery on anything short of the whole repo; confirmed this costs real quality in `future-improvements/week-9-code-review-graph-as-a-view-on-graphifys-map.md`'s scoped-follow-up section):

```bash
git worktree add <tmp> <BASE>
graphify update <tmp>[/<scope>]
```

Continue without it if it fails or isn't installed — Step 2 falls back to Grep/Glob.

## Step 2 — Import-graph scan for hub candidates

Find the files worth drafting a record *from*, not yet the records themselves. A hub file (high import fan-in, a router/dispatch aggregation point, a shared error/enum map) is more likely to hold an established convention than a leaf file, and its inbound edges give you witnesses for free.

- **Graphify available**: `graphify explain "<candidate>"` and its `Degree:` line, or `graphify query "router registration and dependency wiring"`, the same discovery move `generate-domain-pack` Step 2's Wiring-files bullet already uses.
- **No graphify**: grep for import fan-in (`grep -rn "^(import|use|from) " | sort | uniq -c | sort -rn`, adapted to the stack's own import syntax) and `mod.rs`/`lib.rs`/`index.ts`-shaped re-export hubs.

Bound the sample — the plan's own number is 15-30 candidates, not "every file." Pick enough hub files that a handful of genuinely-repeated patterns can surface, not so many that Step 3 drafts more than a person can review in one sitting.

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

Same two rules as `generate-domain-pack` Step 2: cite only patterns that exist on `<BASE>`, and a candidate names a correct pattern to compare against, never a defect currently in the tree. **A draft with only one witness is still worth proposing** — the whole point of putting a human in the loop here is that they can supply the "have I seen this elsewhere" judgment an agent can't verify by grepping alone; mark those clearly (`witnesses: 1 found — needs your second`) rather than silently padding to two or silently dropping. This is the one place `learn` and `generate-domain-pack` genuinely diverge: the auto skill drops anything under 2 witnesses because nobody's there to supply a missing one; here, someone is.

The proposer never writes a file. Its return value is the candidate list, held in this conversation, not on disk — nothing exists yet that `validate-pack.sh` or a stray `git status` could trip over.

## Step 4 — Accept / edit / reject, in conversation

Present candidates in batches (5-8 at a time, not all 15-30 at once — a person reviewing citations needs to actually open some of them). For each: show the drafted fields plus the exemplar's real surrounding code (a short excerpt, not just the citation) so the reviewer isn't asked to trust a `path:line` blind.

Use plain conversational review, not a constrained-choice tool — this content is multi-paragraph and citation-heavy, a poor fit for a short-label picker. Ask the reviewer to reply per-candidate: accept as-is, accept with a specific edit (a different exemplar, a corrected guard, a supplied second witness), or reject with why. Log every rejection's reason briefly — a same-shape candidate rejected twice for the same reason is worth naming as a promoted non-defect (`model/FORMAT.md` §4b) instead of drafting a third time.

Do not move to Step 5 for a candidate still pending a reply — half-reviewed is not accepted.

## Step 5 — Verify every accepted citation, independently

Same discipline as `generate-domain-pack` Step 3, run by you (not trusted from the proposer or the reviewer's own memory) before anything is written:

- Every citation containing a `/` resolves against the **worktree**: `git -C <tmp> show <BASE>:<path>` succeeds and the cited line is within the file's real line count.
- If the reviewer supplied an edit (a new exemplar, a new second witness), that new citation gets the same check — an edit is not exempt from verification just because a human typed it.

A citation that fails this is dropped, not patched — re-derive it from the worktree or drop the candidate, the same two-rules-above discipline as everywhere else in this pipeline.

## Step 6 — Write the accepted records

Append (or create, if no pack exists yet at the target path) the accepted records into the target pack file's `## Label probes` section, in `model/FORMAT.md` §3's exact shape. Leave every other section (`Stack scope prefixes`, `Wiring files`, `Brief probes`, `Dependencies`) to `generate-domain-pack` or a manual pass — `learn`'s scope is label probes, the section where a human's judgment on "is this really a convention" earns its keep; the other five sections are mechanical enough that the auto skill already handles them without a witness-count risk.

## Step 7 — Verify format and refresh artifacts

```bash
bash model/validate-pack.sh <target-pack> [<repo-root-if-foreign>]
bash .claude/skills/pr-review/scripts/build-artifacts.sh <BASE>   # only if the target is this repo's own pack
```

Non-zero exit on either → the write introduced a format problem Step 5's citation check doesn't catch (a malformed `id` slug, a missing required field) — fix the record shape, don't touch the citations again.

## Step 8 — Remove the worktree (mandatory, verified, never skipped)

```bash
git worktree remove --force <tmp>
git worktree list | grep -F "<tmp>" && echo "FAILED: <tmp> still listed" || echo "worktree removed"
```

Same as `generate-domain-pack` Step 5 — run this even if Steps 2-6 failed partway.

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
