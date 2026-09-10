#!/usr/bin/env python3
"""Parse the '## Label probes' section of a domain pack — week 3's record
format (model/FORMAT.md) — and render each record into $OUT/probes-<slice>.txt.

Multi-line field values (a `statement` wrapped across lines, a `witnesses`
list one citation per line) are why this isn't `awk`: Decision 1 in
todays-work/week3/monday.md set ~30 lines of parsing as the point to switch
to python3 over hand-rolling it, and multi-line continuation crosses that.

usage: parse_conventions.py <pack-file> render <out-dir> [be] [fe]
  Writes/appends one formatted block per record into <out-dir>/probes-<slice>.txt,
  routed by the record's own `label:` field through the same label->slice map
  build-artifacts.sh has always used. Unknown labels warn on stderr and are
  skipped — never block a review, same doctrine as every other pack degrade.
  `be`/`fe` are the same 0/1 stack-scope flags build-artifacts.sh computes
  (model/FORMAT.md §3's `stack` field): a record with `stack: be` is dropped
  when `be` isn't "1", same for `fe`; a record with no `stack` field always
  renders. Both default to "1" (no gating) when omitted, for callers that
  don't have a stack scope to pass.

usage: parse_conventions.py <pack-file> validate
  Prints every problem found, one `invalid: ...` line each (model/validate-pack.sh
  prints these verbatim and never repairs, same rule as week 1's validator) plus
  one `citation\t<id>\t<field>\t<path>\t<line>\t<end_line>` line per exemplar/witness/
  deviation citation, for the caller to bounds-check on disk (existence + line-count
  checking belongs in one place, not reimplemented per language — model/validate-pack.sh
  does it, this script only extracts what to check). `end_line` repeats `line` for a
  bare `path:line` citation (no range). Always exits 0; the caller decides invalid from
  the presence of `invalid:` lines, same as every other check in model/validate-pack.sh.

usage: parse_conventions.py <pack-file> extract-section "<## Heading>"
  Prints the raw lines of one top-level section (same boundary rule as
  render/validate's own `## Label probes` extraction) — shared so a second
  section (`## Promoted non-defects`, `## Dependencies`, ...) doesn't need
  its own hand-rolled awk scan in build-artifacts.sh.

usage: parse_conventions.py <pack-file> match <patch-diff-file> <repo-root> [be] [fe]
  Week 6 deterministic pre-pass (model/FORMAT.md's matcher-spec section):
  for every changed file with added lines, score every record on four
  structural signals derived from its own `exemplar`/`witnesses`/`guard` —
  no author-set field, nothing to keep in sync by hand:
    directory (2)  changed file shares a directory with the exemplar or a witness
    filename  (2)  changed file's basename shares a common suffix with every
                   exemplar/witness basename (e.g. every citation ends `_repository.py`)
    symbol    (1)  a changed file's added function/method definition's name
                   shares a leading-word shape with the exemplar's own symbol
                   (the function enclosing its cited line)
    tokens    (1)  a distinctive word from the record's `guard` field appears
                   literally in the changed file's added lines
  `stack` is a veto, not a score, same rule as render()/classify() before it
  — a record whose stack the run doesn't own never becomes a candidate no
  matter how it scores. A record reaches candidacy at score >= 3, which
  means no single signal can nominate alone (max single weight is 2) — this
  is deliberate, not an artifact of the numbers picked: "either signal may
  veto; only agreement may assert."

usage: parse_conventions.py <pack-file> records-json [be] [fe]
  Week 7: one JSON array on stdout, one object per stack-allowed record —
  `{"id", "label", "exemplar", "guard", "unsafe_when", "stack"}` — the fields
  a verifier's "governed units" block needs to render (model/FORMAT.md §3),
  citations left backtick-wrapped as authored (the render() prose form
  strips them; this is consumed by code, not printed to a human). `be`/`fe`
  gate on `stack` exactly like `render`/`match` do above. This is the only
  place a record's `exemplar`/`guard`/`unsafe_when` reach a verifier
  directly by id — `render()`'s probes-*.txt stays label-indexed prose for
  job 1; this is the per-file, per-id lookup week 7's routing needs for
  job 2's governed units.
  Prints one line per changed file with added lines, ranked highest-first,
  capped at 3 candidates: `file<TAB>id:score<TAB>id:score...`, or
  `file<TAB>(none)` when nothing reached the threshold. This is a cheap,
  deliberately over-inclusive candidate signal, not a verdict — the scout
  confirms or rejects each candidate against the actual code; a high score
  is never itself a classification.
  `<repo-root>` is read-only, used to resolve the exemplar's/witnesses'
  cited files for the symbol signal — pass READ_ROOT (build-artifacts.sh),
  never the live tree on a historical replay or a dirty run.
  `be`/`fe` gate on `stack` exactly like `render` does above.
  <pack-file> itself is never a candidate target: its own diff necessarily
  contains the literal guard text of any record it just introduced or
  edited, which would otherwise self-match via the tokens signal every time.
"""
import json
import os
import re
import sys

LABEL_TO_SLICE = {
    "auth": "access", "ownership": "access", "security": "access", "data-exposure": "access",
    "db": "data", "concurrency": "data",
    "logic": "answer", "validation": "answer", "control-flow": "answer", "state": "answer", "contract": "answer",
    "layering": "structure", "duplication": "structure", "dead-code": "structure", "a11y": "structure",
}
CLOSED_LABELS = set(LABEL_TO_SLICE)
LIST_FIELDS = {"witnesses", "deviations"}
CITATION_FIELDS = ["exemplar", "witnesses", "deviations"]  # exemplar: scalar; other two: list
REQUIRED_FIELDS = ["label", "statement", "exemplar", "witnesses", "guard", "unsafe_when"]
KNOWN_FIELDS = set(REQUIRED_FIELDS) | {"deviations", "stack", "human_approved"}


def stack_allows(record, be, fe):
    """A record with `stack: be` is dropped when `be` isn't "1", same for
    `fe`; no `stack` field always passes. Shared by render() and classify()
    so the gating rule lives once — the exact duplication this project's own
    `duplication.shared-matching-logic-sourced-not-copied` record warns
    against."""
    stack = record.get("stack")
    return not ((stack == "be" and be != "1") or (stack == "fe" and fe != "1"))
ID_RE = re.compile(r"^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$")
CITATION_RE = re.compile(r"^`?([A-Za-z0-9_./-]+)(?::(\d+)(?:-(\d+))?)?`?$")
# Column-0 only — an indented continuation line never starts with a bare word
# character before the colon at position 0, so this can't collide with one.
# Broad char class (not just the known field names) on purpose: a typo'd key
# (wrong case, a hyphen for an underscore) must still parse as *a* field —
# caught as unknown by validate() — never silently vanish into the previous
# field's value or get dropped as stray text (the plan's own "a typo'd key
# must fail loudly, not vanish").
FIELD_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):\s?(.*)$")
HEADING_RE = re.compile(r"^### (.+)$")


def extract_section(text, heading):
    lines = text.splitlines()
    out, in_section = [], False
    for line in lines:
        if line.rstrip() == heading:
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if in_section:
            out.append(line)
    return out


def parse_records(section_lines):
    records = []
    cur = None
    field = None
    for line in section_lines:
        m = HEADING_RE.match(line)
        if m:
            if cur is not None:
                records.append(cur)
            cur = {"id": m.group(1).strip()}
            field = None
            continue
        if cur is None:
            continue  # stray text before the first ### heading — not a record
        m = FIELD_RE.match(line)
        if m:
            field = m.group(1)
            value = m.group(2).strip()
            if field in LIST_FIELDS:
                cur[field] = [value] if value else []
            else:
                cur[field] = value
            continue
        stripped = line.strip()
        if not stripped or field is None:
            continue
        # continuation of the previous field: indented, non-heading line
        if field in LIST_FIELDS:
            cur.setdefault(field, []).append(stripped)
        else:
            cur[field] = (cur.get(field, "") + " " + stripped).strip()
    if cur is not None:
        records.append(cur)
    return records


def strip_ticks(s):
    return s.strip("`")


def render_record(r):
    label = r.get("label", "")
    lines = [f"[{r['id']}] {label}"]
    if r.get("statement"):
        lines.append(f"  {r['statement']}")
    if r.get("exemplar"):
        lines.append(f"  correct:      {strip_ticks(r['exemplar'])}")
    witnesses = r.get("witnesses") or []
    if witnesses:
        lines.append(f"  also:         {', '.join(strip_ticks(w) for w in witnesses)}")
    if r.get("guard"):
        lines.append(f"  guard:        {r['guard']}")
    if r.get("unsafe_when"):
        lines.append(f"  unsafe when:  {r['unsafe_when']}")
    return "\n".join(lines) + "\n"


def records_json(records, be="1", fe="1"):
    """One dict per stack-allowed record — id/label/exemplar/guard/
    unsafe_when. `exemplar` has its wrapping backticks stripped, same as
    render_record()'s own citation display (it's a bare path:line, not a
    code span); `guard`/`unsafe_when` keep any inline backticks they
    author with, same as probes-*.txt's existing prose does."""
    out = []
    for r in records:
        if not stack_allows(r, be, fe):
            continue
        out.append({
            "id": r.get("id", ""),
            "label": r.get("label", ""),
            "exemplar": strip_ticks(r.get("exemplar", "")),
            "guard": r.get("guard", ""),
            "unsafe_when": r.get("unsafe_when", ""),
            "stack": r.get("stack"),
        })
    return out


def validate_records(records, section_lines):
    """Yields ('invalid', message) for a structural problem, or
    ('citation', (id, field, path, line)) for a citation to bounds-check —
    never raises, never repairs, same rule as every other check in
    model/validate-pack.sh."""
    # Decision 2 (todays-work/week3/monday.md): hard-cut to records, no
    # backward compatibility with the old `| label | probe |` table. Without
    # this, a pack still in the old shape parses to zero records and passes
    # as "nothing here" — silently going blank (build-artifacts.sh's
    # renderer sees the same zero records) instead of erroring loudly,
    # exactly the failure mode a hard-cut is supposed to prevent.
    #
    # Specifically an old TABLE ROW (>= 2 `|` on one line), not "any content"
    # — a caption paragraph above the first `### id` (same pattern every
    # other section's own doc caption uses, e.g. "## Stack scope prefixes")
    # is legitimate and already safely ignored by parse_records(), and must
    # not itself read as "still in the old format" (a real false positive
    # this produced once: model/pr-review-domain.md's own caption tripped it).
    looks_like_old_table = any(
        line.strip().startswith("|") and line.strip().endswith("|") and line.count("|") >= 2
        for line in section_lines
    )
    if not records and looks_like_old_table:
        yield "invalid", "Label probes has an old-style `| label | probe |` table row, not `### id` records (model/FORMAT.md §3)"
        return
    seen_ids = {}
    for r in records:
        rid = r.get("id", "(no id)")
        loc = f"record `{rid}`"

        if not ID_RE.match(rid):
            yield "invalid", f"{loc}: id doesn't match the slug grammar `label.short-name`, lowercase, `.`/`-` only (model/FORMAT.md §3): {rid}"
        if rid in seen_ids:
            yield "invalid", f"{loc}: duplicate id, already used by an earlier record in this file (model/FORMAT.md §3)"
        seen_ids[rid] = True

        unknown = [k for k in r if k != "id" and k not in KNOWN_FIELDS]
        for k in unknown:
            yield "invalid", f"{loc}: unknown field `{k}` — not one of the ten defined fields, a typo? (model/FORMAT.md §3)"

        # human_approved is computed before REQUIRED_FIELDS below — §3d
        # explicitly documents a human-approved record may carry as few as
        # zero witnesses ("in principle, none"), which only `witnesses`'
        # own required-ness (not any other required field) may be waived
        # for. Computing it here, ahead of that loop, is what makes the
        # waiver possible instead of merely cosmetic (D-week9-2): the
        # REQUIRED_FIELDS loop used to run unconditionally and reject an
        # empty `witnesses` before the waiver a few lines below ever ran,
        # so the zero-witness case §3d documents as valid was unreachable.
        human_approved_raw = r.get("human_approved")
        human_approved = False
        if human_approved_raw is not None:
            # Case-sensitive on purpose, matching stack_allows()'s own
            # exact-match check on `stack` a few lines up in this file —
            # §3d's doc text promises "must be exactly `true` or `false`",
            # and a case-folded compare (D-week9-2) would silently accept
            # `True`/`TRUE` instead of flagging it the way every other
            # field-value check in this file flags an off-spec value.
            v = human_approved_raw.strip()
            if v not in ("true", "false"):
                yield "invalid", f"{loc}: `human_approved` must be exactly `true` or `false`, not `{human_approved_raw}` (model/FORMAT.md §3d)"
            human_approved = v == "true"

        for field in REQUIRED_FIELDS:
            if field == "witnesses" and human_approved:
                continue  # §3d: a human-approved record may carry zero
            value = r.get(field)
            if not value:  # covers missing, empty string, and empty list alike
                yield "invalid", f"{loc}: missing or empty required field `{field}` (model/FORMAT.md §3)"

        label = r.get("label")
        if label and label not in CLOSED_LABELS:
            yield "invalid", f"{loc}: label `{label}` is not one of the 15 closed labels (model/FORMAT.md §4)"

        witnesses = r.get("witnesses") or []
        if r.get("witnesses") is not None and len(witnesses) < 2 and not human_approved:
            yield "invalid", f"{loc}: `witnesses` has {len(witnesses)} entr{'y' if len(witnesses) == 1 else 'ies'}, needs at least 2 — a record with one witness is one piece of code with an opinion attached, not a convention, unless `human_approved: true` marks it as a person's own judgment call rather than an agent's (model/FORMAT.md §3d)"

        for field in CITATION_FIELDS:
            raw = r.get(field)
            values = raw if isinstance(raw, list) else ([raw] if raw else [])
            for v in values:
                m = CITATION_RE.match(v.strip())
                if not m:
                    yield "invalid", f"{loc}: `{field}` citation doesn't look like a `path` or `path:line` reference: {v}"
                    continue
                path, line, end_line = m.group(1), m.group(2), m.group(3)
                yield "citation", (rid, field, path, line or "", end_line or line or "")


# The `diff --git a/<path> b/<path>` header is ambiguous when a path itself
# contains the literal substring " b/" (both paths are usually identical, so
# the line becomes "...a/x b/y b/x b/y" with no unambiguous split point), so
# it's used only as a state reset below, never to extract a path. The actual
# path comes from `+++ b/<path>`/`+++ /dev/null`, but that text alone is not
# a safe signal either — an *added* line whose own literal content is
# "++ b/x" or "++ /dev/null" renders identically once diff prefixes it with
# "+". What makes a real header line unambiguous is its position: it always
# appears between a `diff --git` line and that file's first `@@` hunk marker,
# never inside a hunk's own content — so header lines are only matched while
# not yet inside a hunk.
DIFF_START_RE = re.compile(r"^diff --git ")
HUNK_START_RE = re.compile(r"^@@ ")
FILE_HEADER_RE = re.compile(r"^\+\+\+ (?:b/(.+)|/dev/null)$")


def added_lines_by_file(diff_text, exclude=None):
    """Split a unified diff into {file: [added-line-text, ...]}, added lines
    only (`+`, never the `+++ b/<path>` header itself) — same shape
    build-artifacts.sh's own added() computes, just per-file instead of one
    concatenated stream, since a matcher hit has to say *which* file it fired
    on. A deleted file's `+++ /dev/null` sets `current` to None — a deletion
    has no added lines to attribute regardless. `exclude`, when given, is
    never given a `by_file` entry at all — no wasted list-building for a file
    whose lines the caller is only going to discard."""
    by_file = {}
    current = None
    in_header = False  # between a `diff --git` line and that file's first `@@`
    for line in diff_text.splitlines():
        if DIFF_START_RE.match(line):
            in_header = True
            current = None
            continue
        if HUNK_START_RE.match(line):
            in_header = False
            continue
        if in_header:
            m = FILE_HEADER_RE.match(line)
            if m:
                current = m.group(1)
                if current is not None and current != exclude:
                    by_file.setdefault(current, [])
                elif current == exclude:
                    current = None
            continue
        if current is None:
            continue
        if line.startswith("+"):
            by_file[current].append(line[1:])
    return by_file


def _normalize_pack_path(pack_path):
    """`+++ b/<path>` is always repo-root-relative (git's own convention);
    `pack_path` (argv, or PR_REVIEW_PACK per build-artifacts.sh) is
    documented the same way but not enforced — an absolute path or a
    `./`-prefixed one would otherwise miss the diff's own key by plain
    string equality, silently reintroducing the self-match bug this
    exclusion exists to close."""
    if os.path.isabs(pack_path):
        try:
            pack_path = os.path.relpath(pack_path)
        except ValueError:
            pass
    return pack_path[2:] if pack_path.startswith("./") else pack_path


DIR_WEIGHT, FILENAME_WEIGHT, SYMBOL_WEIGHT, TOKEN_WEIGHT = 2, 2, 1, 1
MATCH_THRESHOLD = 3
MATCH_CAP = 3

# A handful of common English/SQL words that would otherwise fire the tokens
# signal on nearly every guard sentence — kept short and generic (never
# repo-specific) since a record's own distinctive vocabulary is the signal,
# not its connective prose.
TOKEN_STOPWORDS = {
    "the", "this", "that", "with", "from", "into", "where", "join", "clause",
    "never", "always", "using", "value", "field", "lines", "check", "checks",
    "holds", "held", "absent", "guard", "record", "convention", "when",
    "then", "same", "each", "every", "under", "over", "before", "after",
    "would", "should", "could", "does", "doesn", "does not", "against",
    "another", "other", "which", "what", "have", "has", "not", "and", "for",
}


def citation_paths(record):
    """(path, line_int_or_none) for every exemplar/witness citation on a
    record — malformed citations (already flagged by validate()) are simply
    skipped, this mode degrades rather than crashes on a bad pack."""
    out = []
    raw_exemplar = record.get("exemplar")
    values = ([raw_exemplar] if raw_exemplar else []) + (record.get("witnesses") or [])
    for v in values:
        m = CITATION_RE.match(v.strip())
        if not m:
            continue
        path, line = m.group(1), m.group(2)
        out.append((path, int(line) if line else None))
    return out


def _dirname(path):
    return os.path.dirname(path)


def dir_signal(record, changed_file):
    """The directory signal: the changed file shares a directory with the
    exemplar or any witness. Exact directory match only — 'shares a
    directory family' per the spec's own example (`Backend/app/crud/`), not
    a fuzzy path-prefix guess."""
    changed_dir = _dirname(changed_file)
    return any(_dirname(p) == changed_dir for p, _ in citation_paths(record))


NAME_SPLIT_RE = re.compile(r"[A-Za-z][a-z0-9]*|[0-9]+")


def _basename_no_ext(path):
    base = os.path.basename(path)
    stem, _, _ext = base.rpartition(".")
    return stem if stem else base


def common_suffix_words(names):
    """The longest common trailing run of name-shape words shared by every
    citation's basename (stem, no extension) — e.g. ['payment_repository',
    'account_repository', 'statement_repository'] all end in the word
    'repository'. Splits on underscore/camelCase boundaries so
    `card_repository` and `CardRepository` agree. Returns [] when there's
    no shared tail, or too few citations to call anything a pattern."""
    if len(names) < 2:
        return []
    split = [tuple(w.lower() for w in NAME_SPLIT_RE.findall(n)) for n in names]
    shortest = min(len(s) for s in split)
    if shortest == 0:
        return []
    tail = []
    for i in range(1, shortest + 1):
        words_at_i = {s[-i] for s in split}
        if len(words_at_i) == 1:
            tail.append(next(iter(words_at_i)))
        else:
            break
    return list(reversed(tail))


def filename_signal(record, changed_file):
    """The filename signal: every exemplar/witness basename ends in the same
    run of name-shape words, and the changed file's basename ends in that
    same run too. A single shared word already carries real signal here
    (`repository`, `service_impl`) since it was independently derived from
    >= 3 real citations (week 3's own >= 2 witnesses rule), not guessed."""
    names = [_basename_no_ext(p) for p, _ in citation_paths(record)]
    tail = common_suffix_words(names)
    if not tail:
        return False
    changed_words = tuple(w.lower() for w in NAME_SPLIT_RE.findall(_basename_no_ext(changed_file)))
    return len(changed_words) >= len(tail) and changed_words[-len(tail):] == tuple(tail)


DEF_RES = [
    re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("),        # python
    re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\("),  # js/ts function
    re.compile(r"^\s*(?:export\s+)?const\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?\("),  # js/ts arrow
    re.compile(r"^\s*(?:public|private|protected)?\s*(?:async\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^)]*\)\s*\{"),  # method
]


def _find_symbol_name(line):
    for rx in DEF_RES:
        m = rx.match(line)
        if m:
            return m.group(1)
    return None


def extract_symbol_at(repo_root, path, line):
    """The name of the function/method enclosing a cited line — scans
    upward from `line` to the file's start and returns the first definition
    matched, which is the innermost enclosing one for ordinary (non-nested-
    past-one-level) code. Returns None on any read/parse failure — a
    missing or unreadable exemplar file degrades this one signal, it
    doesn't abort the run."""
    if line is None:
        return None
    try:
        with open(os.path.join(repo_root, path), encoding="utf-8", errors="ignore") as f:
            file_lines = f.read().splitlines()
    except OSError:
        return None
    start = min(line, len(file_lines)) - 1
    for i in range(start, -1, -1):
        name = _find_symbol_name(file_lines[i])
        if name:
            return name
    return None


def symbol_shape(name):
    """The leading 1-2 name-shape words of a symbol, e.g. `get_by_public_id`
    -> ('get', 'by'), `createOrder` -> ('create',). This is the '`get_by_*`'
    prefix the spec names, not the whole identifier."""
    words = NAME_SPLIT_RE.findall(name)
    return tuple(w.lower() for w in words[:2])


def record_symbol_shape(record, repo_root):
    """The shape of the function enclosing the exemplar's own cited line —
    the exemplar alone, per model/FORMAT.md §3c ('shares a leading name-
    shape with the function enclosing the exemplar's own cited line').
    None when the exemplar has no line, or its symbol can't be resolved."""
    exemplar = record.get("exemplar")
    if not exemplar:
        return None
    m = CITATION_RE.match(exemplar.strip())
    if not m:
        return None
    path, line = m.group(1), m.group(2)
    if not line:
        return None
    name = extract_symbol_at(repo_root, path, int(line))
    return symbol_shape(name) if name else None


def symbol_signal(record, changed_file_added_lines, repo_root, record_shape_cache):
    if record["id"] not in record_shape_cache:
        record_shape_cache[record["id"]] = record_symbol_shape(record, repo_root)
    shape = record_shape_cache[record["id"]]
    if not shape:
        return False
    for line in changed_file_added_lines:
        name = _find_symbol_name(line)
        if name and symbol_shape(name) == shape:
            return True
    return False


GUARD_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def distinctive_tokens(guard_text):
    """Identifier-shaped words pulled out of a record's `guard` prose: an
    underscore already marks a word as code rather than English
    (`user_id`, `invalidateQueries`), and a plain word only counts once it's
    long enough and off the small stopword list above. No author input —
    this is the whole point of retiring the hand-authored `matcher` field."""
    out = []
    for tok in GUARD_TOKEN_RE.findall(guard_text or ""):
        if "_" in tok or (len(tok) >= 6 and tok.lower() not in TOKEN_STOPWORDS):
            out.append(tok)
    return out


def token_signal(record, blob, token_cache):
    if record["id"] not in token_cache:
        token_cache[record["id"]] = distinctive_tokens(record.get("guard", ""))
    return any(tok in blob for tok in token_cache[record["id"]])


def score_record_for_file(record, changed_file, lines, blob, repo_root, symbol_cache, token_cache):
    score = 0
    if dir_signal(record, changed_file):
        score += DIR_WEIGHT
    if filename_signal(record, changed_file):
        score += FILENAME_WEIGHT
    if symbol_signal(record, lines, repo_root, symbol_cache):
        score += SYMBOL_WEIGHT
    if token_signal(record, blob, token_cache):
        score += TOKEN_WEIGHT
    return score


def match(records, diff_text, repo_root, pack_path=None, be="1", fe="1"):
    """Yields (file, [(id, score), ...]) — ranked highest-first, capped at
    MATCH_CAP — one entry per changed file, scored against every record this
    run's stack owns, even a file with no added lines at all (a pure
    deletion, or a rename with no content change): the directory and
    filename signals depend only on the file's own path, not its added
    lines, so such a file can still score. Order: diff file order,
    deterministic within a file by (score desc, id asc) — a rerun on the
    same diff and the same tree reproduces the same candidate list
    byte-for-byte. `pack_path` is excluded from `by_file` for the same
    reason it always has been: the pack's own diff contains the literal
    guard text of any record it just introduced or edited."""
    exclude = _normalize_pack_path(pack_path) if pack_path is not None else None
    by_file = added_lines_by_file(diff_text, exclude=exclude)
    candidates = [r for r in records if stack_allows(r, be, fe)]
    symbol_cache, token_cache = {}, {}
    for f, lines in by_file.items():
        blob = "\n".join(lines)
        scored = []
        for r in candidates:
            score = score_record_for_file(r, f, lines, blob, repo_root, symbol_cache, token_cache)
            if score >= MATCH_THRESHOLD:
                scored.append((r["id"], score))
        scored.sort(key=lambda t: (-t[1], t[0]))
        yield f, scored[:MATCH_CAP]


def main():
    if len(sys.argv) < 3 or sys.argv[2] not in ("render", "validate", "extract-section", "match", "records-json"):
        sys.stderr.write(__doc__)
        sys.exit(2)
    pack_path, mode = sys.argv[1], sys.argv[2]
    with open(pack_path, encoding="utf-8") as f:
        text = f.read()

    if mode == "extract-section":
        if len(sys.argv) != 4:
            sys.stderr.write(__doc__)
            sys.exit(2)
        for line in extract_section(text, sys.argv[3]):
            print(line)
        return

    section = extract_section(text, "## Label probes")
    records = parse_records(section)

    if mode == "render":
        if len(sys.argv) not in (4, 5, 6):
            sys.stderr.write(__doc__)
            sys.exit(2)
        out_dir = sys.argv[3]
        be = sys.argv[4] if len(sys.argv) >= 5 else "1"
        fe = sys.argv[5] if len(sys.argv) >= 6 else "1"
        handles = {}
        for r in records:
            rid = r.get("id", "(no id)")
            if not stack_allows(r, be, fe):
                continue
            label = r.get("label", "")
            slice_name = LABEL_TO_SLICE.get(label)
            if slice_name is None:
                sys.stderr.write(
                    f"warning: domain pack record `{rid}` has label `{label}`, "
                    f"not one of the 15 known labels — dropped, not routed to any probes-*.txt\n"
                )
                continue
            if slice_name not in handles:
                handles[slice_name] = open(f"{out_dir}/probes-{slice_name}.txt", "a", encoding="utf-8")
            handles[slice_name].write(render_record(r))
        for h in handles.values():
            h.close()
        return

    if mode == "match":
        if len(sys.argv) not in (5, 6, 7):
            sys.stderr.write(__doc__)
            sys.exit(2)
        with open(sys.argv[3], encoding="utf-8") as f:
            diff_text = f.read()
        repo_root = sys.argv[4]
        be = sys.argv[5] if len(sys.argv) >= 6 else "1"
        fe = sys.argv[6] if len(sys.argv) >= 7 else "1"
        for f_path, scored in match(records, diff_text, repo_root, pack_path=pack_path, be=be, fe=fe):
            if scored:
                cols = "\t".join(f"{rid}:{score}" for rid, score in scored)
            else:
                cols = "(none)"
            print(f"{f_path}\t{cols}")
        return

    if mode == "records-json":
        if len(sys.argv) not in (3, 4, 5):
            sys.stderr.write(__doc__)
            sys.exit(2)
        be = sys.argv[3] if len(sys.argv) >= 4 else "1"
        fe = sys.argv[4] if len(sys.argv) >= 5 else "1"
        print(json.dumps(records_json(records, be=be, fe=fe)))
        return

    # mode == "validate"
    for kind, payload in validate_records(records, section):
        if kind == "invalid":
            print(f"invalid: {payload}")
        else:
            rid, field, path, line, end_line = payload
            print(f"citation\t{rid}\t{field}\t{path}\t{line}\t{end_line}")


if __name__ == "__main__":
    main()
