---
name: generate-domain-pack
description: (Re)generate `model/pr-review-domain.md`, the domain pack `/pr-review` reads for this repo's own cited probes, wiring files and dependencies. Runs from a base-branch-scoped worktree so citations never point at the diff under review, and enforces worktree cleanup as its own verified step rather than a step to remember. Use when `/pr-review` reports `PACK_PRESENT=0` or `PACK_STALE=1`, when a citation has been found to have drifted, or whenever asked to build/regenerate/refresh the domain pack — standalone, no need to run `/pr-review` first.
---

Produces a complete replacement for `model/pr-review-domain.md`. Six sections, each citation a real `file:line` on the base branch. Never regenerate a pack that already passed `/pr-review`'s staleness check (`PACK_PRESENT=1 PACK_STALE=0`) — that rewrites the reviewer's own probe corpus mid-run and makes two reviews of the same diff different experiments.

**Partner packs.** A pack generated for a repo other than this one lives at `model/partners/<name>/pr-review-domain.md` in *this* repo, never committed into the foreign repo — pass it to `/pr-review` via `PR_REVIEW_PACK`. Everything else in this skill (worktree, citation rules, verification, cleanup) applies unchanged; the only difference is the output path in Step 2 and the worktree's `<BASE>` pointing at the foreign repo's own branch.

## Step 0 — Preflight

Pick `<tmp>` — a path outside the repo, e.g. `/tmp/domain-pack-worktree-<repo-name>`. Before anything else:

```bash
git worktree list | grep -F "<tmp>" && echo "STOP: <tmp> already a worktree — pick a different path or remove it first"
```

A collision here means a previous run of this skill didn't reach Step 5. Resolve that (Step 5, below) before starting a new one — never `git worktree add` over an existing entry.

## Step 1 — Base-branch-scoped worktree and graph

This is a separate index from the one `/pr-review` itself uses — the main repo's `graphify-out/graph.json` reflects the *current* branch, and citing base-branch `file:line` against a current-branch index risks citing the wrong version of a file.

```bash
git worktree add <tmp> <BASE>
graphify update <tmp>          # bootstraps a fresh graph from nothing in ~5-10s, no LLM needed
```

If `graphify update` fails or isn't installed, continue anyway — Step 2's spawn falls back to Grep/Glob, the same fallback `/pr-review` itself uses when `graphify` is unavailable. This is not a reason to skip Step 5.

## Step 2 — Spawn the generation agent

One `general-purpose` agent (Read, Grep, Glob, Write, and Bash — **restricted by instruction to `graphify query|explain|path --graph <tmp>/graphify-out/graph.json` inside `<tmp>` only**, never a write or any other shell command) produces the six sections, each cited with a real `file:line`:

1. **Stack scope prefixes** — one top-level dir per stack (`package.json` here, `requirements.txt`/`go.mod` there). Single-stack repo → leave empty, `SCOPE` resolves `both`. No graphify use here — plain directory listing.
2. **Wiring files** — router/handler aggregation point, shared DI/dependency module, frontend api client, error-code and enum maps. **Graphify first**: these are structurally the highest-connectivity nodes in the graph — `graphify explain "<candidate>"` and read its `Degree:`, or `graphify query "router registration and dependency wiring"`, to find hub candidates faster than cold-grepping for import fan-in. Still confirm every candidate by reading it — a high `Degree:` is a signal, not a citation.
3. **Label probes** — any number of `### id` records, each independently tagged with a `label` (`auth, ownership, security, data-exposure, db, concurrency, logic, validation, control-flow, state, contract, duplication, dead-code, layering, a11y`) and citing one real existing guard/pattern in this repo — format and required fields: `model/FORMAT.md` §3. Many records can share a label; a label can also carry zero. **Graphify first** to narrow the search: `graphify query "<label's pattern, e.g. 'ownership check on a repository lookup'>"` surfaces the community/files most likely to hold a precedent, before falling to Grep/Glob cold. Graphify only narrows *where to look* — it has no notion of "correct guard pattern," so the actual citation still comes from reading the code and judging it, same as always. **No precedent found → leave the label uncovered entirely**, never fabricate a record. **Read every `CLAUDE.md` in the worktree (root and stack-specific) as a source here** — a "Review Grounding" section or equivalent names conventions in prose (aggregate-router auth, per-row ownership filters, shared-component locations) that are real probe material once turned into a cited record; re-verify every line number against the worktree rather than copying the prose's own citation, since that citation can itself have drifted (this is exactly the failure this skill exists to stop from reaching the scout).
4. **Promoted non-defects** — leave empty unless `eval/review-corrections.md`'s own ledger already has an entry seen twice on *this* repo; that promotion is what `model/FORMAT.md` §4b governs, not something this skill invents from a first read of the code.
5. **Brief probes** — this repo's own regexes for `SKILL.md` §4.1: router registration, route-component tag, money/amount type, error-code/enum map touch, migration path. No graphify use here — pattern authoring, not discovery.
6. **Dependencies** — per stack, the direct third-party packages the app code actually imports (backend: grep top-level `import`/`from` statements under the app's own source dir, map back to manifest package names; frontend: the manifest's own `dependencies` object needs no grepping) — never the full transitive manifest, which defeats the point of a short first-pass list. Note any dependency invoked without a matching import (a migration tool run only via CLI, a driver pulled in transitively but load-bearing) separately.

Hand the spawn `pr-review-domain.md`'s own six `##` headings as the schema to fill, not their content to copy. Output is a complete replacement file at `model/pr-review-domain.md`, written in the **main repo**, not the worktree.

Two rules for the spawn, both about what a probe **is**:

- **Cite only patterns that exist on the base branch.** Never cite code introduced by the diff under review. Generate from the base-branch worktree, not the working tree — a pack that names the branch's own defects hands every verifier the answers and measures the pack instead of the reviewer. The same rule applies to graphify: query/explain only the worktree's own graph, never the main repo's `graphify-out/graph.json` — that one is the current branch, not the base.
- **A probe names a correct pattern to compare against, never a defect to find.** "Real defect currently in the tree" is a finding, and findings come from verifiers with evidence, not from a reference file every spawn is told to trust. Graphify narrowing the search space doesn't change this — it never supplies the citation, only where to read next.

Cite full repo-relative paths (`Backend/app/routers/api.py:25`), at least once per row — `/pr-review`'s staleness check only validates citations that contain a `/`; a bare `api.py:24` later in the same row is fine as shorthand.

## Step 3 — Verify the spawn's own output

Before touching the worktree, confirm the written file is usable:

- **Format contract**: `bash model/validate-pack.sh model/pr-review-domain.md` — all six headings, wiring fenced, label probe records well-formed and closed-list, brief probes bash-clean, citations backtick-wrapped. Exit 0 required before continuing; a non-zero exit prints every problem, none of them fixable by hand-editing (see the two-rules discipline below) — go back to Step 2. This is the exact check `/pr-review` runs on every pack, so the two paths can never disagree on what "valid" means.
- **Citation resolution against the worktree** — `validate-pack.sh` checks *shape* (backtick-wrapped), not *truth* (does the path exist, is the line in range); that still needs a targeted check here: every citation containing a `/` resolves against the **worktree** tree (`git -C <tmp> show <BASE>:<path>` succeeds, and the cited line is within the file's line count) — a citation that fails this is worse than an empty row, catch it here rather than leaving it for `/pr-review`'s own staleness check to find later.
- No row cites a path or line that only exists on the working tree, not `<BASE>` — the giveaway is a citation to a file the manifest of *this diff* touches.

A row that fails either check gets dropped, not patched — the two-rules-above discipline means a bad citation isn't fixable by editing it, only by re-deriving it from the worktree.

## Step 4 — Refresh the run-scoped artifacts

```bash
bash .claude/skills/pr-review/scripts/build-artifacts.sh <BASE>
```

D8: `<BASE>` is required here — the script defaults to `dev` with no argument, which exits 3 on any repo whose integration branch isn't named `dev` (this one included, base `main`). Pass the same `<BASE>` Step 1 used.

So `brief.txt`, `wiring.txt` and the `probes-*.txt`/`known-non-defects.txt` files (consumed by `/pr-review` Step 3) come from the new pack on the next run. Confirm the printed `run.env` shows `PACK_PRESENT=1 PACK_STALE=0` — a non-zero `PACK_STALE` here is not automatically a Step 3 miss, see the Error handling table below before assuming it is.

## Step 5 — Remove the worktree (mandatory, verified, never skipped)

```bash
git worktree remove --force <tmp>
git worktree list | grep -F "<tmp>" && echo "FAILED: <tmp> still listed — remove it manually before finishing" || echo "worktree removed"
```

D7: `--force` is required — Step 1's `graphify update <tmp>` leaves `<tmp>/graphify-out/` as untracked files inside the worktree, and a plain `git worktree remove` refuses to remove a worktree with untracked or modified content. Without it, cleanup fails *exactly* when graphify succeeded — the one case this step exists to guarantee never gets skipped.

Run this **even if Step 2 or Step 3 failed** — an abandoned worktree's `graphify-out/` is scoped to a point-in-time base checkout and must never be mistaken for the main repo's index by a later, unrelated task. A failed generation is reported as a failure; a failed generation that also leaves a stray worktree is two problems. Do not report this skill as finished until the `grep` above comes back empty.

## Error handling

| Situation | Do |
|---|---|
| Step 0's collision check finds `<tmp>` already registered | Stop before Step 1. Resolve the stray worktree (Step 5) first — never add over it. |
| `graphify update <tmp>` fails or `graphify` isn't installed | Continue — Step 2 falls back to Grep/Glob, same as `/pr-review` itself does with no graph. |
| Step 2's spawn crashes or times out | Go straight to Step 5 (cleanup), then report the failure. The old pack, if any, is untouched — Step 2 only writes on completion. |
| Step 3 finds every row fails its own citation check | The generation ran against the wrong branch or a stale worktree graph — do not write a pack this empty; go to Step 5, then re-run from Step 1. |
| `PACK_STALE=1` after Step 4 | Not necessarily a Step 3 miss — Step 3 validates citations against `<BASE>` in the **worktree**, Step 4 runs `build-artifacts.sh` against the **current branch's working tree**, and those can legitimately disagree: a file deleted on the current branch but still present on `<BASE>` resolves fine in Step 3 and reads as stale in Step 4. Check whether the citation actually still exists on the current branch before assuming Step 3 erred; only re-run Step 3 if it does. |
