# Baseline run notes

## e05-friday: findings 1 and 2 are corpus-methodology artifacts, not real defects

`e05-friday` reviews commit `270c8e9..2887944` (both week-1, before the
week-2 `core/`/`harness/` split moved `validate-pack.sh` from
`.claude/skills/pr-review/scripts/` to `model/`). At the time of `2887944`
there was exactly one copy of the file and it was live — no duplicate, no
dead code.

Both findings compare that historical file against `model/validate-pack.sh`
and cite `build-artifacts.sh:75`/`tests/run.sh:6` pointing at the `model/`
path — but that path, and the whole two-copy situation, only exists on the
**current working tree** (this branch is built on top of the week-2 split).
`PR_REVIEW_HEAD` correctly diffs the historical commit pair, but the
verifier's Read/Glob tools see the live filesystem — so a historical diff
reviewed from a working tree that has since restructured can produce a
finding that's true of *now*, not true of *then*.

**Verdict (pre-empting Thursday, since this isn't a normal accept/dismiss
call):** invalid — not a defect in the diff, a byte of methodology leaking
through. Excluded from the per-label acceptance table, not counted as
dismissed (dismissed implies the finding was fairly tested against the
actual diff and failed; this one was tested against the wrong tree
entirely).

Logged generally in `future-improvements/week-5-dirty-tree-stale-citation.md`
(the sibling of this problem — that one was stale-old content on a
dirty tree, this one is live-current content leaking into a historical
diff; same root cause, opposite direction).
