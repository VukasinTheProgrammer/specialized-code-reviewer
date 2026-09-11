# Domain pack format contract

`model/pr-review-domain.md` (and any pack a foreign repo drops
in via `PR_REVIEW_PACK`) has always been read against these six rules —
`build-artifacts.sh`'s `awk`/`grep` extraction assumed every one of them
without ever writing them down. `validate-pack.sh` enforces all six; its
error messages cite the section below by number. Author against this file,
not against what the parser happens to tolerate today.

## §1 — Section headings, exact match

The pack has exactly six sections, each introduced by one of these
headings, byte-for-byte:

```
## Stack scope prefixes
## Wiring files
## Label probes
## Promoted non-defects
## Brief probes
## Dependencies
```

A retyped heading (wrong case, an extra space, a rename) doesn't error —
every extraction below is an `awk` scoped to that exact string, so a miss
just degrades the whole section to silently empty. `validate-pack.sh` is
what turns that silence into a named error.

## §1b — Stack scope prefixes: table rows, or the single-stack line

`build-artifacts.sh` derives `BE`/`FE` (which of `ownership`/`db` vs.
`state`/`a11y` may fire this run) from this section, and it only reads two
shapes — anything else silently degrades to `BE=0 FE=0` even with a present,
otherwise-valid pack:

**A multi-stack repo** — one table row per prefix, first backtick token is
the path prefix, second column its stack:

```
## Stack scope prefixes

| Prefix | Stack |
|---|---|
| `Backend/` | backend |
| `Frontend/` | frontend |
```

**A single-stack repo** — no split to make, so no table: one bare line,
`single-stack: backend` or `single-stack: frontend`, and every changed
file counts as that stack:

```
## Stack scope prefixes

single-stack: backend
```

**A section with neither a valid row nor a valid `single-stack:` line is
invalid**, not merely stale — free-form prose (however clear it reads to a
person) parses to nothing, and nothing here is optional the way `##
Promoted non-defects` legitimately being empty is. `validate-pack.sh`
checks this directly rather than letting it degrade silently to the
hardcoded `^Backend/`/`^Frontend/` defaults, which is real evidence for
one repo, not a fallback: those defaults matching or not matching a given
repo's manifest is coincidence, not signal.

## §2 — Wiring files: fenced, closed before the next heading

The `## Wiring files` section holds one fenced block of plain repo-relative
paths, one per line:

````
## Wiring files

```
Backend/app/dependencies.py
Frontend/src/api/client.ts
```
````

The fence must close (an even, non-zero count of `` ``` `` lines) before the
next `## ` heading. An unclosed fence doesn't stay contained — the real
parser's extraction used to keep reading straight past the heading and into
whatever section followed, stopping only at that section's own fence
(fixed, but the shape is still worth knowing when authoring).

## §3 — Label probes: one record per convention, not one row per label

**v2, week 3.** The old shape was one table row per label — a label got
exactly one probe cell for the whole codebase, no matter how many different
ways it actually shows up. The new shape inverts that: any number of
records, each independently tagged with a `label`. Many records can share a
label; that's the point — `ownership` can carry a record for repository
scoping, a separate one for the admin exception, another for the
background-job path, instead of being crammed into one sentence.

A record is a `### <id>` heading, followed by `key: value` lines. A value
may continue onto the next line(s) by indenting them — a wrapped sentence
for `statement`/`guard`/`unsafe_when`, or one citation per line for
`witnesses`/`deviations`:

```
### ownership.repository-user-scope

label:       ownership
stack:       be
statement:   A repository lookup is scoped to the caller by joining to the
             owning row's user_id, never resolved by public id alone.
exemplar:    `Backend/app/crud/payment_repository.py:88`
witnesses:   `Backend/app/crud/account_repository.py:41`
             `Backend/app/crud/statement_repository.py:63`
guard:       the join to PaymentAccount.user_id in the WHERE clause
unsafe_when: the lookup takes an id straight from the request body and
             re-resolves nothing under the caller's identity
deviations:  `Backend/app/crud/legacy_card_repo.py:31`
```

Fields, and who needs each one:

| Field | Required | What it is |
|---|---|---|
| `id` | yes | The `### ` heading text. A stable slug (`label.short-name`, lowercase, `.`/`-` only) — never renumbered once authored, so a citation or regression case naming it stays valid. |
| `label` | yes | Exactly one of the closed 15 (§4). Routes the record to a slice — replaces row position as the routing key. |
| `statement` | yes | One sentence: what correct looks like. Never what the defect looks like — a probe phrased as a defect shape turns the reviewer into a pattern-matcher for that one shape. |
| `exemplar` | yes | One `path:line` that does it right — what a verifier quotes to close an evidence trace. For a structurally-scoped label (`layering`, `a11y`, `dead-code`) whose convention is a property of a whole file rather than one line, `exemplar` names a representative anchor line and `guard` carries the actual scope — a single line can't prove "this file contains no bash" on its own. |
| `witnesses` | ≥ 2 | Other sites that independently conform. Below two, it's one piece of code with an opinion attached, not a convention — the validator (Wednesday) rejects it. |
| `guard` | yes | The specific mechanism that makes the pattern safe — the join, the quantize, the lock, the alias, the enforcement script. This is what lets a finding say *which protection was dropped*. |
| `unsafe_when` | yes | What would make the same shape a real defect. Mirrors the ledger's two-halves dismissal rule (`eval/review-corrections.md`); without it a record silences the genuine version of its own pattern. |
| `deviations` | no | Known non-conforming sites, already triaged. Empty is normal. |
| `stack` | no | `be` / `fe` / unset. Feeds the existing stack gate — a frontend record never fires on a backend-only diff. |
| `human_approved` | no | Exactly `true` or `false` if present at all — see §3d. Waives the `witnesses` ≥ 2 rule; nothing else. |

An unknown field name is a typo, not a new field, and `id` must match the
slug grammar (`label.short-name`, lowercase, `.`/`-` only) and be unique
across the file — `validate-pack.sh` rejects any of these rather than
silently ignoring them. Every `exemplar`/`witnesses`/`deviations` citation
must resolve: the file exists, and a `:line` (or `:line-line2`) is within
the file's actual line count — the same bounds check `build-artifacts.sh`
already runs for staleness, applied here at authoring time instead of
diff-review time.

## §3c — The matcher: which record governs a changed file

Week 6's deterministic pre-pass (`model/parse_conventions.py`'s `match`
mode, run before the scout ever sees the diff). No author-set field — every
signal is derived structurally from a record's own `exemplar`, `witnesses`
and `guard`, which is the real reason §3 requires at least two witnesses:
one citation gives you a file, three give you a pattern.

| Signal | How it's computed | Weight |
|---|---|---|
| `directory` | The changed file shares a directory with the exemplar or a witness | 2 |
| `filename` | Every exemplar/witness basename shares a common trailing name-shape word with the changed file's basename (`*_repository.py`, `*_service_impl.py`) | 2 |
| `symbol` | A changed file's added function/method shares a leading name-shape with the function enclosing the exemplar's own cited line (`get_by_*`, `create_*`) | 1 |
| `tokens` | A distinctive identifier-shaped word from the record's `guard` text appears literally in the changed file's added lines | 1 |
| `stack` | The record's `stack` against the run's `BE`/`FE` — **a veto, not a score** | veto |

A record becomes a candidate at **score ≥ 3** — no single signal (max
weight 2) can nominate on its own. Rank by score, cap at 3 per changed
file, written to `$OUT/candidates.txt` (`file<TAB>id:score<TAB>...`, or
`file<TAB>(none)`).

**Either signal may veto; only agreement may assert.** The scout confirms
or rejects every candidate against the actual code — a high score is a
proposal, never a verdict. When the matcher proposes nothing but the scout
still names a record it recognizes, that's allowed (`governed · weak`) but
only when the scout states in one line why; when the matcher and the scout
disagree on which record applies, or the matcher's literal hit doesn't
correspond to what the code actually does, the unit is `new` — a wrong
`governed` is the expensive failure this asymmetry exists to prevent.

## §3d — `human_approved`: a person's judgment stands in for the second witness

Week 9. `generate-domain-pack` runs unattended — nobody is present to vouch
for a pattern the agent could only find once, so a record under two
witnesses is dropped rather than trusted on an agent's own say-so (§3's own
reasoning: "one piece of code with an opinion attached, not a convention").
The `learn` skill (`.claude/skills/learn/SKILL.md`) exists specifically to
put a person in that loop — proposing candidates for a human to accept,
edit, or reject before anything is written. Without `human_approved`, that
review step couldn't do anything a fully-automated run doesn't already do:
a real, single-witness pattern the reviewer has personally judged sound
still hit the same ≥2 gate and got dropped regardless of the review.

`human_approved: true` on a record waives §3's `witnesses` ≥ 2 requirement
— a record may carry as few as one real witness (or, in principle, none,
though a record with zero evidence beyond its exemplar is a thin case a
reviewer should think twice about approving). It waives nothing else:
`exemplar` and every listed `witnesses` citation still must resolve
against the real file (§3's own citation-bounds check), the label must
still be one of the closed 15, the `id` slug rule is unchanged. This field
lowers the evidence bar for one specific record a person actually looked
at; it does not loosen validation generally, and it is never set by an
agent on its own authority — only by a human's explicit accept during a
`learn` review, or by a human hand-editing the pack directly with the same
intent.

`human_approved: false` (or omitting the field) is the default and behaves
exactly as before this section existed — §3's ≥2 rule applies normally.
The field must be exactly `true` or `false` when present at all; any other
value is rejected as a typo, not silently ignored (same doctrine as every
other field-value check in this file).

## §4 — Label probes: closed label list

Every record's `label` field must be exactly one of these 15 — no others,
no invented ones:

```
auth, ownership, security, data-exposure, db, concurrency,
logic, validation, control-flow, state, contract,
layering, duplication, dead-code, a11y
```

A label outside this list isn't an error either — the record is dropped
from every `probes-*.txt` with a warning on stderr, and it never reaches
any verifier. If a real pattern doesn't fit one of the 15, it isn't a
record's business; see `future-improvements/Waiting for decision/week-7-label-taxonomy.md`
for extending the list itself.

**Each label's scope is defined in exactly one place — the slice's own
`verify-*.body.md`, not this list.** A label passing membership here says
nothing about whether it's the *right* label; that reading has bitten this
project once already (`db.durable-atomic-write` called a mislabel by
inferring `db`'s scope from a sibling pack's SQL examples instead of
checking the line below — see
`future-improvements/Applied/label-scope-defining-source.md`). Before
labeling or reviewing a label-fit call, read the defining line, not a
worked example:

| label | slice | defined at |
|---|---|---|
| `auth` | access | `core/agents/verify-access.body.md:11` |
| `ownership` | access | `core/agents/verify-access.body.md:15` |
| `security` | access | `core/agents/verify-access.body.md:21` |
| `data-exposure` | access | `core/agents/verify-access.body.md:26` |
| `db` | data | `core/agents/verify-data.body.md:11` |
| `concurrency` | data | `core/agents/verify-data.body.md:21` |
| `logic` | answer | `core/agents/verify-answer.body.md:11` |
| `validation` | answer | `core/agents/verify-answer.body.md:17` |
| `control-flow` | answer | `core/agents/verify-answer.body.md:23` |
| `state` | answer | `core/agents/verify-answer.body.md:31` |
| `contract` | answer | `core/agents/verify-answer.body.md:37` |
| `layering` | structure | `core/agents/verify-structure.body.md:11` |
| `duplication` | structure | `core/agents/verify-structure.body.md:17` |
| `dead-code` | structure | `core/agents/verify-structure.body.md:21` |
| `a11y` | structure | `core/agents/verify-structure.body.md:24` |

## §4b — Promoted non-defects: this repo's own, and only this repo's own

Week 3, Thursday. Free-form prose, the same two-halves shape
`eval/review-corrections.md`'s `## Known non-defects` section already
requires — what makes the pattern safe, and what would make it unsafe —
extracted verbatim (no field parsing, no validation of that shape; same as
the ledger's own section). Not validated beyond the heading itself being
present.

```
## Promoted non-defects

- **A router file with no auth dependency is not missing auth.** Auth is
  applied at the aggregate router (`Backend/app/api.py:25`). The
  registration line is where the mistake would be. Unsafe when a route
  hand-rolls its own session/cookie read that skips it.
```

This section exists so a rule that only makes sense on one particular
codebase (a specific aggregate-router file, a specific screen's staleness
pattern) has somewhere repo-specific to live, instead of getting hardcoded
into `core/agents/scout.md` — every agent definition in `core/` is meant to
carry zero repo-specific knowledge (`core/README.md`'s own test: would this
survive a rewrite in a different language, on a different repo). **Never
carry a rule here that you haven't watched come back at least twice** —
that's what "promoted" means; a first-sighting dismissal belongs in the
ledger's `## Known non-defects`, not here. Empty is normal and expected on a
repo with no history yet, exactly like every other section.

## §5 — Brief probes: fenced as bash, syntactically valid

The `## Brief probes` section holds one ```` ```bash ```` fenced block,
`eval`'d verbatim by `build-artifacts.sh` with `added()`/`removed()`/`$OUT`
in scope:

````
## Brief probes

```bash
ROUTERS=$(added | grep -cE '@(app|router)\.(get|post|put|delete|patch)\(')
```
````

Missing the `bash` tag on the fence means the block is never captured at
all — silently, no error. A syntax error inside it aborts the `eval`
mid-block; `bash -n` on the extracted block is the offline version of that
same failure, without needing a diff to trigger it.

## §6 — Citations: backtick-wrapped

Any `path/file.ext` or `path/file.ext:line` reference containing a `/`
outside a fenced code block — in `## Label probes` prose, `##
Dependencies`, anywhere — must be backtick-wrapped:

```
`Backend/app/dependencies.py:40`
```

An unwrapped citation is invisible to `/pr-review`'s own staleness check
(`extract_citations` in `build-artifacts.sh` only greps inside backticks) —
the file could be deleted or the line could drift years out of date and
nothing would ever flag it.
