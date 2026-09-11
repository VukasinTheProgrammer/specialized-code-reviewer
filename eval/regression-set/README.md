# PR reviewer — regression set

The second measurement source. Where the [corrections ledger](../review-corrections.md)
measures what the reviewer reports and how much survives a human read, this
measures whether a *change to the reviewer* loses ground it already held.

Every finding a human marks **accepted** becomes a case: the parent diff as
input, that finding as ground truth — never a human fix commit, and see the
ledger's "Why not score against past fix commits" for why.

## Growing the set

At no authoring cost — pulled from the run's own persisted output, never
hand-typed:

```bash
bash .claude/skills/pr-review/scripts/add-regression-case.sh <label> <file> <line>
```

Run this right after recording an **accepted** verdict in the ledger. It
reads `.git/pr-review/findings.json` (the fixed path the last `/pr-review`
run persisted), pulls the matching finding verbatim, and writes
`cases/<head-short>-<label>-<line>.json`. Re-running for the same finding is
a no-op — cases are never duplicated.

## Case format

```json
{
  "id": "<head-short>-<label>-<file-with-slashes-as-underscores>-<line>",
  "base": "<sha the review ran against>",
  "head": "<sha reviewed>",
  "added": "2026-09-04",
  "finding": { "label": "logic", "file": "...", "line": 58, "failure_mode": "..." }
}
```

`failure_mode` is kept for a human skimming `FAIL` cases; `evidence` is
dropped — the check below never compares it, and it's the field most likely
to run long.

## Re-running the whole set

Required after any change to the reviewer (SKILL.md, an agent definition, a
label probe) — a change that recovers one finding while losing another is
not progress, and only a full re-run reveals it.

```bash
bash .claude/skills/pr-review/scripts/run-regression-set.sh
```

For each case this rebuilds the artifacts for `base...head` (`build-artifacts.sh`
already supports replaying a fixed historical head via `PR_REVIEW_HEAD`,
without checking anything out). It cannot spawn the four verifier subagents
itself — that's the Workflow step in `/pr-review`'s own pipeline, not
shell-scriptable — so it prints, per case, the artifacts directory and the
two remaining steps: run the Workflow against that directory, then

```bash
bash .claude/skills/pr-review/scripts/check-regression-case.sh <case.json> <findings.json>
```

`check-regression-case.sh` matches on label+file+line only — a reworded
`failure_mode` is not a loss — and refuses to compare a case against a
findings.json built from a different base/head (`NOT COMPARABLE`, exit 2)
rather than silently reporting a false pass or fail.

## Retiring a case

A case can stop being able to pass for reasons that have nothing to do
with review quality — most concretely, a diff old enough that today's
domain pack's own citations no longer resolve against that historical
tree, degrading every probe to empty regardless of what the pipeline's
prompts say (`retired/README.md` has a worked example). When a `FAIL`
traces to that instead of a real regression, move the case file from
`cases/` to `retired/` with a note explaining why — `run-regression-set.sh`
only globs `cases/`, so a retired case stops being re-run without being
silently deleted. Never retire a case just because it's inconvenient to
fix; retiring is for a case that is structurally unable to pass, not one
that's merely still failing.

## Reading the set

Once the set is large enough to argue from (10+ accumulated cases), open
questions about slice boundaries, the description pass, or per-label
behaviour get decided from the counts here and in the run tally — not from
argument. The phase-2 versions of those calls (the classifier schema, the
routing, the Structure slice) were settled that way in weeks 6–8; the rule
stands for whatever comes next.
