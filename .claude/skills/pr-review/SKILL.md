---
name: pr-review
description: Review what the current branch adds against a base branch. A scout maps every changed file and hands over a ranked, capped list of hunches; four specialists (Read, plus Grep/Glob to close a trace) each sweep their own defect labels across the whole diff, then settle those hunches, and report proven defects only. Numbered index — label, file, line and one line of what is wrong — with the full failure mode and evidence trace persisted for `/explain-bug <n>`. Never edits anything. Use before opening or merging a pull request.
---

Review a branch diff for defects. Reports only; never edits.

Step numbers below are stable — agents, the workflow script and the rationale cite them as `§1.5`, `§3.2`, `§5.4`.

| Where | What |
|---|---|
| `scripts/build-artifacts.sh` | Steps 0.1, 1, 2, 4 — everything deterministic. Run it; don't retype it. |
| `generate-domain-pack` skill | Step 0.2 — how to (re)generate the domain pack. Standalone-invocable, not only from here. |
| `references/pipeline-internals.md` | What the Workflow script does inside Step 3 and Step 5.1–5.3, and the numbers to watch. |
| `references/report-format.md` | Step 5.5–5.6 — the exact render templates. |

## Usage

```
/pr-review              # against dev, the integration branch
/pr-review main         # against another base
```

## Step 0 — Domain pack

`model/pr-review-domain.md` supplies this repo's own probes. Without one, a label with no local precedent goes unraised silently — that is the miss this reviewer exists to avoid.

**0.1** The script (Step 1) checks existence and staleness and reports `PACK_PRESENT` / `PACK_STALE` in `run.env` — same check, same fields, for the ledger's `LEDGER_PRESENT` / `LEDGER_STALE`. Stale means a repo-relative citation the pack (or the ledger's Known non-defects/Label corrections) cites no longer resolves: the path is gone from the tree, or a `path:line` citation's line number now exceeds the file — a pack or ledger written for another repo, another point in this one's history, or a citation that drifted after the file it points at moved. This bounds-checks line numbers; it does not read the cited line's content, so a citation pointing at a *different but still valid* line in the same file is not caught here — that needs a human or LLM read. **The two staleness flags degrade differently.** `PACK_STALE=1` empties `wiring.txt`/`probes-*.txt` — every verifier falls back to its own generic probes, a safe degrade (weaker evidence, not more noise). `LEDGER_STALE=1` only warns; `known-non-defects.txt` still gets the full text regardless. A drifted citation is evidence for one rule, not the other six — gating all of them on one bad line number would re-introduce the false positives the ledger exists to suppress.

Separately, the script also exact-matches all five of the pack's `## Heading` strings before extracting anything — every extraction below is an `awk` scoped to one heading, and a heading retyped even slightly (a capital letter, an extra space) makes that `awk` match nothing, degrading the section to silently empty with `PACK_STALE` still `0` (a heading edit has no citation to flag as stale). A missing/renamed heading warns by name on stderr; nothing gates on it — the same section just stays empty, same as if the pack lacked it entirely.

**0.1c** The script also runs `validate-pack.sh` against the pack — wiring section properly fenced, every `## Label probes` row splits into exactly one label and one probe cell, every label is one of the closed 15, `## Brief probes` has a `bash` fence whose content passes `bash -n`, and every `path/file.ext[:line]` citation is backtick-wrapped. A failure here sets `PACK_INVALID=1` **and** `PACK_STALE=1` — an invalid pack degrades exactly like a stale one (this is the same flag, not a second gate to check separately), with every finding printed to stderr. Run `bash model/validate-pack.sh <pack>` directly to see the full list.

**0.2** `PACK_PRESENT=0` or `PACK_STALE=1` (which `PACK_INVALID=1` also sets) → invoke the `generate-domain-pack` skill, which re-runs this script itself once it's done so the brief and wiring list come from the new pack. Do not regenerate a pack that passed the check.

**0.3** Existing, regenerated, or partially empty for lack of precedent — continue either way.

## Step 1 — Build the diff (also Steps 2 and 4)

```bash
bash .claude/skills/pr-review/scripts/build-artifacts.sh "${1:-dev}"
```

One deterministic script, no model in it. It resolves the base (§1.1), diffs `BASE...HEAD` at 15 lines of context (§1.2–1.3), excludes non-code (§1.4), writes the artifacts into a fresh run-scoped directory (§1.5), derives the stack scope (§2) and assembles the orientation brief (§4). It prints `run.env` and `brief.txt`.

| Artifact in `$OUT` | Is | Is not |
|---|---|---|
| `patch.diff` | The hunks, 15 lines of context | — |
| `manifest.txt` | Changed paths, one per line | File contents |
| `brief.txt` | Fixed fields, values from grep/awk | Anything a model wrote; anything phrased as a suspicion |
| `wiring.txt` | The pack's `## Wiring files` block verbatim (empty when no pack, or stale) | A list you invented |
| `probes-access.txt`, `-data.txt`, `-answer.txt`, `-structure.txt` | The pack's `## Label probes` rows, pre-split by slice, plus its `## Dependencies` block appended verbatim under an `IN-BOUNDS DEPENDENCIES` heading (empty when no pack, or stale) | Anything the fallback prose in a verifier's own file already carries. The deps block is deliberately not label-shaped — it is reference material, never a 16th label |
| `probes-all.txt` | The four files above, concatenated — the scout's copy, since it has no slice restriction | A re-parse of the pack; it's just `cat` of the four |
| `impacted-candidates.txt` | Unchanged files that reference something this diff changed, one `caller<TAB>changed-file` per line, capped and deduped (§1.9). Built by word-boundary `git grep` at `HEAD`, **independent of `GRAPH`** | Proof of a call, or a finding. A reference is a candidate; the scout confirms it against the file and drops what doesn't hold |
| `candidates.txt` | Week 6's deterministic pre-pass: one `file<TAB>id:score<TAB>id:score...` (or `file<TAB>(none)`) per changed file, every record scored on structural signals derived from its own `exemplar`/`witnesses`/`guard` (empty when no pack or a stale one), capped (`PR_REVIEW_MATCH_CAP`, default 40) | A classification. A score >= 3 is a candidate; the scout still confirms `governed` against the actual code or rejects it back to `new` |
| `records.json` | Week 7: `[{id, label, exemplar, guard, unsafe_when, stack}, ...]`, one object per stack-allowed record (`[]` when no pack, a stale one, or `stack` excludes every record this run) | Prose. This is the per-id lookup the workflow script uses to render a governed unit's own record into its verifier's prompt — `probes-*.txt` stays the label-indexed prose for job 1 |
| `known-non-defects.txt` | The ledger's `## Known non-defects` + `## Label corrections` sections only (empty when no ledger, or the heading has nothing under it — **not** gated on `LEDGER_STALE`, see 0.1) | `## Run tally` onward — that grows every verdicted run, the scout doesn't need it |
| `run.env` | `OUT REPO_ROOT READ_ROOT BASE HEAD SCOPE BE FE GRAPH CHANGED FILES EMPTY DIRTY LARGE_DIFF IMPACTED_CANDIDATES IMPACTED_TRUNCATED CANDIDATES PACK_PRESENT PACK_STALE PACK_INVALID LEDGER_PRESENT LEDGER_STALE BASE_NOTE BRIEF_DEGRADED BRIEF_PROBES_TRUSTED` | — |

**Read `run.env` and act on it before spawning anything:**

- Non-zero exit → the script already said why (base doesn't resolve, no merge base, can't create `$OUT`). **Stop. Never substitute another base.**
- `EMPTY=1` → report "nothing to review" with the reason the script gave and **stop — do not spawn.** Empty findings from an empty patch render as a false clean report.
- `BASE_NOTE` non-empty → repeat it in the report (only `origin/<base>` resolved, or HEAD is detached).
- `DIRTY=1` → say "uncommitted changes are not in this diff" and continue. `READ_ROOT` already gets pinned to a worktree at plain `HEAD` in this case (same mechanism as a `PR_REVIEW_HEAD` replay, see below) — a verifier's Read/Grep/Glob calls see the committed tree the diff was computed against, not the uncommitted edits sitting on top of it, so this is not something the report needs to work around further.
- `BRIEF_DEGRADED=1` → the domain pack's `## Brief probes` block errored partway through (stderr captured, see build-artifacts.sh's warning) — `brief.txt` may be missing a field it should have; say so and continue, same as any other degrade.
- `BRIEF_PROBES_TRUSTED=0` → the pack came in via `PR_REVIEW_PACK` (a partner pack, or any non-default pack) and its `## Brief probes` block was **not** `eval`'d — `brief.txt` carries only the presence-only fields, with a `note:` line saying so. This is the correct, safe default for a pack whose shell you have not read (`future-improvements/week-12-remove-brief-probes-eval.md`); treat it as an ordinary degrade, not an error. Only after reading that pack's `## Brief probes` block should a run set `PR_REVIEW_EVAL_BRIEF_PROBES=1` to opt it back in. The built-in `model/pr-review-domain.md` is always trusted (`BRIEF_PROBES_TRUSTED=1`), no flag needed.
- `LARGE_DIFF=1` → say the diff is large (`CHANGED` lines, `FILES` files) and that a review this size is slower and costlier than usual; continue and spawn normally — this is a warning, not a bail, and never changes what gets reviewed.
- `GRAPH=on` means `graphify update` ran and succeeded (unconditional, every non-empty run once `graphify-out/graph.json` exists), and the scout/verifiers have live graphify MCP tools (`get_node`, `get_neighbors`, `query_graph`, `shortest_path` — registered in `.mcp.json`) to call themselves; `off` means no index exists yet, `graphify` isn't installed, `graphify update` failed, or `PR_REVIEW_NO_GRAPH=1` — the scout then resolves `related` through Grep/Glob and stamps `graph_coverage: "none"`, the correct path, not a degradation. `impacted` does **not** depend on this flag either way: the script's own `impacted-candidates.txt` (§1.9) is built by grep at `HEAD` and is handed to the scout on both paths — graph-on only sharpens it, by letting the scout prefer a real incoming edge where the two disagree.
- `READ_ROOT` differs from `REPO_ROOT` on a `PR_REVIEW_HEAD` replay or a dirty tree (`DIRTY=1`) — a scoped `git worktree` checked out at the diffed head (historical SHA, or plain `HEAD` when dirty), so a verifier's own Read/Grep/Glob calls see the tree the diff was computed against, not whatever the live tree looks like right now. Use `READ_ROOT` (not `REPO_ROOT`) as the `repoRoot` value in Step 3's payload; keep using `REPO_ROOT` for anything git-dir-relative (§5.4's `.git/pr-review/findings.json`), since a worktree's `.git` is a file, not a directory, and that path resolves wrong from inside one.

Why these choices are what they are — three dots not two, `--unified=8`, which files are excluded, why `$OUT` is per-run — is in the rationale, §1. Change the script, not the run.

## Step 2 — Stack scope

Computed by the script from the domain pack's `## Stack scope prefixes` (or, with no pack, from the repo layout). `SCOPE` selects which probe column a spawn leads with. **It never restricts reading** — every spawn gets the whole patch and manifest whatever the scope. `neither` (docs/config/`.claude/`-only branch) is ordinary and still spawns all four verifiers.

## Step 3 — Scout, then verify

**One call to the Workflow tool**, `name: "pr-review-verify"` (script at `.claude/workflows/pr-review-verify.js`). Build the payload from `run.env`, `brief.txt`, `wiring.txt`, the four `probes-*.txt` files, `probes-all.txt` and `known-non-defects.txt` — every value is this run's real one, never a placeholder:

```json
{
  "outDir": "<OUT>", "repoRoot": "<READ_ROOT>", "base": "<BASE>", "head": "<HEAD>",
  "scope": "<SCOPE>", "be": <BE as 0|1>, "fe": <FE as 0|1>, "graph": "<GRAPH>",
  "briefText": "<contents of $OUT/brief.txt, verbatim>",
  "wiringFilesText": "<contents of $OUT/wiring.txt, verbatim — \"\" when empty>",
  "probesAccessText": "<contents of $OUT/probes-access.txt, verbatim — \"\" when empty>",
  "probesDataText": "<contents of $OUT/probes-data.txt, verbatim — \"\" when empty>",
  "probesAnswerText": "<contents of $OUT/probes-answer.txt, verbatim — \"\" when empty>",
  "probesStructureText": "<contents of $OUT/probes-structure.txt, verbatim — \"\" when empty>",
  "probesAllText": "<contents of $OUT/probes-all.txt, verbatim — \"\" when empty>",
  "knownNonDefectsText": "<contents of $OUT/known-non-defects.txt, verbatim — \"\" when empty>",
  "impactedCandidatesText": "<contents of $OUT/impacted-candidates.txt, verbatim — \"\" when empty>",
  "candidatesText": "<contents of $OUT/candidates.txt, verbatim — \"\" when empty>",
  "recordsText": "<contents of $OUT/records.json, verbatim — \"[]\" when empty>"
}
```

The four `probes-*.txt` files are this run's domain-pack `## Label probes` rows, pre-split by slice, each with the pack's `## Dependencies` block appended (§1.5, in the script) — empty on no pack or a stale one, same signal as an empty `wiring.txt`. Passing them inline means a verifier never opens the domain pack itself; it already carries its own fallback prose for the empty case. That appended block is why every pack section now reaches a prompt: no agent may open the pack, so a section landing in no `probes-*.txt` reaches nobody — which is what happened to `## Dependencies` when it was first added. `probes-all.txt` is the same rows, unsplit, for the scout — it has no slice restriction, so it needs the union, not one verifier's quarter. `known-non-defects.txt` is the ledger's evergreen sections only, same reasoning — scout never opens the ledger itself, and its cost doesn't grow as the ledger's run history does. `impacted-candidates.txt` is the graph-independent caller list — the scout's `impacted` array used to be empty on every `GRAPH=off` run, which is every repo that hasn't installed graphify, so the check with the highest value to a new adopter was the one switched off for them by default. `candidates.txt` (week 6) is the deterministic pre-pass: every record scored per changed file on structural signals derived from its own `exemplar`/`witnesses`/`guard` (model/FORMAT.md §3c) — the scout's `classification`/`matched_convention`/`match_strength` fields are restricted to what this list actually proposes, plus a narrow scout-names-a-miss exception (`governed`/`weak`, one line stated), never invented from the probes text alone, so a candidate is confirmed or rejected, not guessed. `records.json` (week 7) is the per-id counterpart: the workflow script parses it once, and for every `context` entry the scout classified `governed`/`strong`, looks its `matched_convention` up there and inlines that one record — statement-free, just `exemplar`/`guard`/`unsafe_when` — into the one verifier whose slice owns the record's `label` (`labelToSlice`, the same table a hypothesis routes through). `weak` matches route nowhere this week (`todays-work/week7/monday.md`'s decision); a record whose `stack` the run doesn't own is dropped the same way a stack-gated hypothesis is.

`be`/`fe` must be the numbers from `run.env`, not literals — a hard-coded `0` silently drops every `ownership`/`db`/`state`/`a11y` hypothesis (that bug shipped once).

Inside, the script runs one `pr-review-scout` (Grep/Glob plus live graphify MCP tools, no verdicts) that emits `context` for every changed unit, up to 12 ranked `hypotheses`, and up to 12 `impacted` unchanged-file callers (confirmed from the script's own candidate list, plus the incoming edges the `related` lookups already return when the graph is on), then four `pr-verify-*` specialists in parallel (Read, plus Grep/Glob and narrow graphify tools to close a trace on a named finding — never to explore), each sweeping its own labels cold first and settling its hypotheses second, then merges, dedupes and sorts. The return value is already the object §5.4 persists — **skip to §5.4 when it returns.** What happens inside, the label→verifier routing, and how to read the hypothesis/sweep numbers: `references/pipeline-internals.md`.

Two things the return value can carry that must reach the report:

- `scout_failed: true` → the scout crashed and every verifier ran unassisted. Say so ("scout stage failed — findings below are sweep-only") instead of rendering the normal `Scout context:`/`Scout classification:`/`Conventions:` lines — an empty `context` array means `scout_classification` is `{governed:0, new:0}` too, which reads as "nothing to classify," not as a real zero.
- `failed`, `degraded`, `slice_mismatch` → slices or labels that were **not reliably reviewed**. Named separately, never folded into "clean" (§5.6).

## Step 4 — Orientation brief

Built by the script, handed identically to every spawn — the facts a spawn would otherwise re-derive on its own first reads.

**4.1 Assembly.** With a domain pack, its `## Brief probes` block runs verbatim over a code-only patch (`code.diff`, added lines from the stack-scope prefixes only — a probe over the whole patch false-matches a markdown file that merely quotes the code it documents). Without one, presence-only fields (`migrations`, `lockfiles/deps touched`) so nothing false-matches a foreign repo's vocabulary.

**4.2 Facts only, never suspicions.** `money/amount lines: 10` ships; "watch the rounding" does not. A spawn told what to suspect confirms the suspicion instead of reading the code, and its findings then describe the hint rather than the branch.

The domain pack may also emit deterministic semantic-probe counts for patterns
such as `ORDER BY` plus `LIMIT`, date-window arithmetic, tie-breakers, and
read-modify-write code. These are mandatory inspection prompts for the scout,
not findings or verdicts. A non-zero count means inspect the changed lines and
raise a hypothesis when the code presents a concrete risk; a zero count never
clears a different implementation shape.

**4.3 No model writes it.** Every value comes from grep/awk, so two runs against the same diff produce a byte-identical brief.

**4.4 A fixed set of fields.** Same fields every run, values filled in — never a paragraph, never a per-file list, never a field that appears only when interesting. A mostly-zero brief on a small fix is fine and informative.

## Step 5 — Merge and render

**5.1–5.3 already happened inside the Workflow script** (parse, validate, dedupe on `file`+`line`+`label`, sort by slice → label → file → line, number). Details and the `degraded` / `slice_mismatch` / `dropped_unreachable` semantics: `references/pipeline-internals.md`.

### 5.3b Validate line numbers

The workflow script never opens a file — no filesystem access there (see `workflow-authoring`) — so a `line` is whatever the spawn said, unchecked. You do have Read/Bash now: for every unique `file` across `findings`, run `git show $HEAD:<file> | awk 'END{print NR}'` from `REPO_ROOT` (`HEAD` from `run.env` — `git show` reads objects, so `REPO_ROOT` is correct here even on a `PR_REVIEW_HEAD` replay; no need for `READ_ROOT`) — **not `wc -l`**, which counts newlines and undercounts by one on a file with no trailing newline, silently dropping a genuine finding on that file's last line. A missing file (non-zero exit) counts as 0 lines. Drop any finding whose `line` exceeds that count, or is `<= 0`; count the drops as `dropped_invalid_line`. Renumber the survivors' `n` sequentially — the same rule as the script's own numbering, just re-run after this drop.

This is the same silent-drop rule as everywhere else in this pipeline: a hallucinated line number is not correctable from here (no re-derivation, no "closest line" guess) — it is dropped, exactly as a malformed or unreachable candidate is.

### 5.4 Persist before rendering — write local, publish atomic

Write the returned object to `$OUT/findings.json` **before printing anything** — even when `findings` is empty, even if rendering then fails. Then:

```bash
mkdir -p .git/pr-review && mv "$OUT/findings.json" .git/pr-review/findings.json
```

`.git/pr-review/findings.json` is the one fixed path `/explain-bug` reads. `mv` on one filesystem is atomic; a `test -e` plus a separate write is a race with extra steps. `n` is the sort position — derived, never invented — so the same diff numbers the same defect the same way every run.

### 5.5 Render

Follow `references/report-format.md` exactly. In short: a numbered index, one line per finding — `[label] file:line` (`· deviates <id>` on the chip, plus a `Guard dropped:` line, when the finding carries `deviates_from` — week 7) and the **first sentence of `failure_mode`, verbatim**; then the closing lines naming what ran, the hypothesis numbers, a `Conventions:` line when the run had a pack, and every `failed` / `degraded` / `slice_mismatch` / `dropped_unreachable` / `dropped_invalid_line` / `hypotheses.dropped` value that is non-zero. Evidence traces are deferred to `/explain-bug <n>`, not dropped.

### 5.6 A clean report names what was checked

"No findings" is only meaningful next to "Verified clean: Access, Data, Answer, Structure — 4 spawns". A failed, degraded or label-mismatched slice is always named on its own line, never counted as clean — its silence must never read as a clean bill on its labels.

### 5.7 What this step must never do

- **Add** a finding the spawns did not return, however obvious it looks from the patch.
- **Soften** one they did — no "possibly", no "consider", no downgrade to a suggestion.
- **Reinstate** a hypothesis or sweep finding a spawn dropped, because the report looks short.
- **Soften a finding into a dismissal.** There is no dismissal list — a spawn either proved a defect or said nothing, and this step has no third bucket to move an entry into.
- **Rewrite** a summary line — the first sentence of `failure_mode` renders as it stands; a bad one shows the spawn's gap rather than smoothing it over here.
- **Edit any file.** Reporting only — fixing a finding is separate work taking `findings.json` as input.

## Error handling

| Situation | Do |
|---|---|
| Script exits non-zero | Stop; relay its message. Never substitute a base. |
| `EMPTY=1` | Report it with the script's reason (exclusions, or HEAD matches base). Do not spawn. |
| Only `origin/<base>` resolved / HEAD detached | Proceed; say so in the report (`BASE_NOTE`). |
| Scout crashed or drifted off schema | Workflow degrades to empty `context`/`hypotheses`; all four verifiers still sweep. Report `scout_failed`. |
| A verifier returned nothing parseable | `failed` — name the slice and its labels as not reviewed. Never clean. |
| A finding's `line` doesn't exist in the file at `HEAD` | Drop it (§5.3b), count it in `dropped_invalid_line`. Never guess the intended line. |
| A verifier returned only malformed findings | `degraded` — name it the same way. Never clean. |
| A verifier's `slice` echo missed a label | `slice_mismatch` — name the label as unreviewed this run. |
| `$OUT/findings.json` can't be written | Print the report anyway; say the numbers aren't resolvable and `/explain-bug` has nothing to read. |
| Final `mv` fails | Report already printed with real numbers; say the publish step failed. Never retry with a non-atomic write. |
