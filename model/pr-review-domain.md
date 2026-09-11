# PR review domain pack

Repo-specific knowledge for `/pr-review`. The skill and every agent it spawns
check for this file before falling back to their built-in, stack-agnostic
default. Delete or rename this file to run the reviewer generic on this repo
(useful for testing the fallback path); this copy ships empty — run the
`generate-domain-pack` skill to fill in the six sections below for whatever
repo it's dropped into, or edit them by hand.

Every section below is intentionally empty, with no explanatory prose under
any heading — this file's own overview is the only place that documents what
each section is for, since anything written directly under a `## Heading`
gets read verbatim by an agent, prose included. An empty section behaves
exactly like "no domain pack" for that one check — every fallback downstream
already handles it (verified in the upstream repo this copy was cut from:
`PACK_STALE` does not fire on an empty-but-present section, only on a
missing/renamed `## Heading` or a citation that no longer resolves).

**Stack scope prefixes** computes `SCOPE`/`BE`/`FE` and gates which labels can
fire. **Wiring files** are pinned as readable-without-asking in every
verifier's prompt. **Label probes** hold this repo's own convention records —
any number tagged with a label, not one row per label (`model/FORMAT.md`
§3). **Promoted non-defects** holds this repo's own dismissal rules that
have come back twice (`model/FORMAT.md` §4b) — never a rule copied in from
another codebase. **Brief probes** are the regexes behind `brief.txt`.
**Dependencies** is a fast first-pass check before flagging an import as
newly-added — a curated shortlist, never a substitute for reading the actual
manifest.

## Stack scope prefixes

single-stack: both

## Wiring files

Paths pinned as readable-without-asking in every verifier's prompt, alongside its own hypothesis `related` list (`SKILL.md` §3.3):

```
```

## Label probes

Concrete, cited convention records — the "Probes" half of the table in
`pr-review-scout.md` and the "How to verify in this codebase" section of each
`pr-verify-*` agent. Read the label table in `pr-review-scout.md` for the label
names, the slice routing, and the `Use for` column, which stay generic and
live there permanently — only the citation-heavy records below move with the
domain pack. Format: `model/FORMAT.md` §3. No precedent found for a label →
leave it uncovered entirely, never fabricate a record.

### contract.upstream-claim-reverified

label:       contract
statement:   A claim asserted by an upstream step, a spawn's structured
             output or a shell loop that should have written files, is
             independently re-verified downstream before being trusted,
             never accepted on the upstream step's own say-so.
exemplar:    `.claude/skills/pr-review/SKILL.md:135`
witnesses:   `harness/build-agents.sh:44-45`
             `tests/run-integration.sh:48-53`
guard:       the re-derivation reads ground truth via a fresh command every
             time (`git show $HEAD:<file>`, a real directory check), never
             a cached flag the upstream step set on success
unsafe_when: a new consumer reads the upstream claim directly, a report
             step trusting a finding's line without a bounds check, or a
             script using a claimed output path without checking it is
             real, and skips the re-derivation

### concurrency.atomic-publish

label:       concurrency
statement:   A file another process, or the next run, may observe is never
             written in place at its final, predictable path. Either it is
             written to a private location first and made visible by a
             single atomic rename, or the location itself is created
             atomically unique so no two runs can collide on it.
exemplar:    `.claude/skills/pr-review/SKILL.md:144`
witnesses:   `.claude/skills/pr-review/scripts/add-regression-case.sh:56-62`
             `.claude/skills/pr-review/scripts/build-artifacts.sh:315`
guard:       the atomic primitive itself, `mv` for a same-filesystem
             rename or `mktemp`/`mktemp -d` for unique-path creation, is
             what is load-bearing, never a test-then-write pattern
unsafe_when: a new artifact is written straight to its final shared path
             with no mktemp and no rename, so the next reader can observe
             a partial write, or two concurrent runs can interleave
             writes to the same path

### layering.core-holds-doctrine

label:       layering
statement:   Anything that would survive a rewrite of this tool in a
             different language or orchestration mechanism, the verifier
             contract, the label taxonomy, the report format, lives in
             core/; a harness/ file may run that doctrine but never state
             new doctrine of its own.
exemplar:    `core/doctrine.md:1`
witnesses:   `harness/build-agents.sh:1`
             `harness/compose-verifier.py:1`
guard:       `harness/check-generated.sh` regenerates `.claude/agents/*.md`
             from core/ into a scratch dir and diffs it byte-identical
             against the committed copy, so core/ and harness/ cannot
             drift apart silently
unsafe_when: a harness/ file starts encoding what counts as a defect, a
             label's rule hardcoded into a build script instead of
             `core/doctrine.md` or a `core/agents/*.body.md`, which would
             not survive a future rewrite, defeating the split's point

### validation.git-root-guard

label:       validation
statement:   A script that resolves its own operating root via
             `git rev-parse --show-toplevel` and then uses it as a cd
             target guards the resolution failing, printing an error and
             exiting a documented code, rather than continuing with an
             empty or wrong root.
exemplar:    `.claude/skills/pr-review/scripts/build-artifacts.sh:38`
witnesses:   `.claude/skills/pr-review/scripts/add-regression-case.sh:21`
             `.claude/skills/pr-review/scripts/run-regression-set.sh:20`
guard:       the `|| { echo ...; exit 2; }` right after the assignment,
             the command substitution's own exit status is checked, never
             assumed
unsafe_when: ROOT is used bare right after the assignment with nothing
             checking that git rev-parse actually succeeded, an empty
             ROOT can cd somewhere unintended, and "not inside a git
             repo" is a real runtime case here since a foreign checkout
             can be reviewed via a dropped-in pack
deviations:  `harness/build-agents.sh:12`
             `harness/check-generated.sh:8`

### duplication.agents-generated-not-hand-duplicated

label:       duplication
statement:   Every file under `.claude/agents/` is generated from a core/
             source by `harness/build-agents.sh`, a verbatim copy for
             scout.md, a doctrine-composed build for the four
             verify-*.body.md files, never hand-maintained as a second
             copy of core/'s content.
exemplar:    `.claude/agents/pr-verify-access.md:2`
witnesses:   `.claude/agents/pr-verify-answer.md:2`
             `.claude/agents/pr-verify-data.md:2`
             `.claude/agents/pr-verify-structure.md:2`
             `.claude/agents/pr-review-scout.md:2`
guard:       `harness/check-generated.sh` regenerates into a scratch dir
             and diffs it against `.claude/agents/`, non-zero exit on any
             divergence; every generated file's banner line points back to
             core/ (the same generic line in all five, not each file's own
             specific source) and says not to hand-edit
unsafe_when: a file under `.claude/agents/` is edited directly instead of
             its core/ source, the edit survives until the next core/
             change triggers a regeneration that silently overwrites it,
             and nothing catches the drift unless check-generated.sh is
             actually run

### logic.line-count-excludes-wc-l

label:       logic
statement:   A file's line count, wherever it feeds a bounds check or a
             citation/EOF check, is computed with `awk 'END{print NR}'` or
             an equivalent FNR-based awk pass, never `wc -l` — `wc -l`
             counts newlines and undercounts by one on a file with no
             trailing final newline, which silently misjudges a citation
             on that file's real last line as past EOF.
exemplar:    `model/validate-pack.sh:91`
witnesses:   `.claude/skills/pr-review/scripts/build-artifacts.sh:169-172`
             `.claude/skills/pr-review/SKILL.md:135`
guard:       the specific awk idiom, `END{print NR}` or the
             `FNR==1 && NR>1` file-boundary batch, is what is load-bearing,
             never a plain `wc -l` on the target file
unsafe_when: a new line-count check is added with `wc -l` instead of one
             of these awk forms — it passes for every file that happens to
             end with a trailing newline and only misfires on the ones
             that don't, which is exactly the kind of bug that survives
             testing on a few files and then fires on a real one

### contract.script-header-documents-interface

label:       contract
statement:   A script meant to be invoked from another script or from
             tests documents its own calling interface, a usage line and
             every meaningful exit code, in a header comment block near
             the top, next to the shebang.
exemplar:    `.claude/skills/pr-review/scripts/build-artifacts.sh:4`
witnesses:   `model/validate-pack.sh:6`
             `.claude/skills/pr-review/scripts/add-regression-case.sh:4`
             `.claude/skills/pr-review/scripts/run-regression-set.sh:6`
             `.claude/skills/pr-review/scripts/check-regression-case.sh:4`
guard:       the header comment itself, read by a caller before it ever
             needs to catch a specific code or guess an argument order
unsafe_when: a script gains a new required argument or a new meaningful
             exit code without updating this header, so a caller has to
             read the script body to know what changed
deviations:  `harness/build-agents.sh:1`
             `harness/check-generated.sh:1`

### control-flow.no-errexit-for-collect-all-findings

label:       control-flow
statement:   A script that must report every problem it finds in one
             pass, a validator, a review pipeline artifact builder, uses
             set -u without -e, so one failed check does not abort the
             run before later checks get a chance to report; each risky
             point handles its own failure explicitly instead of relying
             on errexit.
exemplar:    `model/validate-pack.sh:8`
witnesses:   `.claude/skills/pr-review/scripts/build-artifacts.sh:36`
             `.claude/skills/pr-review/scripts/add-regression-case.sh:20`
             `.claude/skills/pr-review/scripts/run-regression-set.sh:19`
guard:       every risky command in these scripts is explicitly checked
             (`|| { ...; exit N; }` or an if) rather than left to set -e
             to catch, and validate-pack.sh's fail() accumulates INVALID=1
             and keeps going instead of exiting on the first bad heading
unsafe_when: a new check is added to one of these scripts as a bare
             command with no explicit guard, trusting set -e to catch a
             failure that -e was deliberately left off to catch — the
             whole point of "print every finding" is then defeated the
             first time an unrelated command's exit code would abort the
             script under an accidentally-added -e later

### validation.missing-args-usage-exit-3

label:       validation
statement:   A script with required positional arguments checks every one
             is present before doing anything else, printing a one-line
             "usage: <script> <args>" to stderr and exiting 3 when any is
             missing or empty, rather than proceeding and failing later on
             an empty variable.
exemplar:    `model/validate-pack.sh:11`
witnesses:   `.claude/skills/pr-review/scripts/add-regression-case.sh:24-27`
             `.claude/skills/pr-review/scripts/check-regression-case.sh:38-42`
guard:       the presence check runs before any other work, no file reads,
             no git calls, and always exits the same documented code (3),
             so a caller can distinguish a bad invocation from every other
             failure
unsafe_when: a new required argument is added without adding it to this
             check — the script then proceeds with an empty variable and
             fails later, at whatever line first dereferences it, with a
             message that does not say "you forgot an argument"

### duplication.shared-matching-logic-sourced-not-copied

label:       duplication
statement:   Matching or parsing logic used by two independent scripts to
             check the same thing lives in one sourced file, dot-sourced
             by each caller, never hand-copied into each script with its
             own message wording.
exemplar:    `model/pack-heading-check.sh:1`
witnesses:   `model/validate-pack.sh:29`
             `.claude/skills/pr-review/scripts/build-artifacts.sh:58`
guard:       neither caller reimplements the matching loop itself, only
             its own reporting of the result — `missing_pack_headings()`'s
             actual matching logic exists exactly once on disk
unsafe_when: a second copy of the same check gets hand-written instead of
             sourced — the two copies drift in what they check or how
             they word an error, exactly the shape of the one accepted
             defect this file itself replaced (`eval/review-corrections.md`,
             week 1, before this file existed)

## Promoted non-defects

## Brief probes

Regex used by `SKILL.md` §4.1 to assemble `brief.txt`. Content-matching, so
they only ever run against `code.diff` (added lines from this repo's own
stack-scope prefixes, never the whole patch). Leave this block empty to fall
back to the generic presence-only fields (`migrations`, `lockfiles/deps
touched`):

```bash
```

## Dependencies
