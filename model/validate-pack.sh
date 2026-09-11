#!/usr/bin/env bash
# Validates a domain pack's format contract, defined in model/FORMAT.md.
# Never repairs, never stops at the first problem — prints every finding it
# can, same doctrine the reviewer itself is held to.
#
#   usage: bash model/validate-pack.sh <pack-file> [repo-root]
# Exit codes: 0 valid   1 invalid (findings printed)   2 pack file missing   3 bad usage
set -u

PACK="${1:-}"
[ -n "$PACK" ] || { echo "usage: validate-pack.sh <pack-file> [repo-root]" >&2; exit 3; }
[ -r "$PACK" ] || { echo "error: cannot read '$PACK'" >&2; exit 2; }

# Resolved relative to this script's own location, not $PWD — this script is
# invoked from varied working directories (an absolute path from tests/run.sh,
# a copy inside a throwaway repo from tests/run-integration.sh), and the
# headings list (and the sourced check function below) must always be the
# copy sitting next to this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HEADINGS_FILE="$SCRIPT_DIR/pack-headings.txt"

# Citations in a record (`exemplar`/`witnesses`/`deviations`) are repo-relative
# — but relative to whichever repo the pack is actually FOR, which is this
# script's own repo only in the common case where the pack was written for it.
# Week 9's partner packs break that assumption on purpose (model/partners/
# <name>/pr-review-domain.md lives here, cites a repo that isn't this one) —
# so an explicit second arg overrides the default, and build-artifacts.sh
# passes $ROOT (the repo actually under review) so this stays correct there
# too, not just when called standalone on this repo's own pack.
PACK_REPO_ROOT="${2:-$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null)}"

# missing_pack_headings() — shared with build-artifacts.sh, not duplicated
# (see model/pack-heading-check.sh for why).
. "$SCRIPT_DIR/pack-heading-check.sh"

INVALID=0
fail() { echo "invalid: $1"; INVALID=1; }

# ---- check: all five section headings present, exact match — list shared
# with build-artifacts.sh via model/pack-headings.txt, not duplicated ----
# A missing headings file makes missing_pack_headings() return 1 rather
# than silently printing nothing, so this validator fails loudly instead
# of exiting 0 (valid) for a pack it never actually checked.
if ! MISSING_HEADINGS="$(missing_pack_headings "$HEADINGS_FILE" "$PACK")"; then
  echo "error: $HEADINGS_FILE not found — validator cannot check required headings" >&2
  exit 2
fi
while IFS= read -r h; do
  [ -n "$h" ] || continue
  fail "missing or renamed heading (model/FORMAT.md §1): $h"
done <<<"$MISSING_HEADINGS"

# ---- check: Wiring files section has a fenced block, closed before the
# next heading — the exact shape D1 breaks (build-artifacts.sh's own
# ---- check: Stack scope prefixes resolves to at least one table row or a
# single-stack: line (model/FORMAT.md §1b) — anything else (empty, or prose
# that reads fine to a person but matches neither shape) is invalid, not
# merely stale: build-artifacts.sh silently falls back to the hardcoded
# ^Backend//^Frontend/ defaults in exactly this case, which is coincidence
# for a given repo's manifest, never a real signal. ----
STACK_SCOPE_ROWS=$(awk '/^## Stack scope prefixes/{f=1;next} /^## /{f=0} f' "$PACK" | grep -E '^\|' | grep -vE '^\|[- |]+\|$' | grep -vc 'Prefix')
STACK_SCOPE_SINGLE=$(awk '/^## Stack scope prefixes/{f=1;next} /^## /{f=0} f' "$PACK" | grep -cE '^single-stack:[[:space:]]*(backend|frontend)[[:space:]]*$')
if [ "$STACK_SCOPE_ROWS" -eq 0 ] && [ "$STACK_SCOPE_SINGLE" -eq 0 ]; then
  fail "Stack scope prefixes: no parseable table row and no single-stack: backend|frontend line (model/FORMAT.md §1b)"
fi

# extraction resets on the next fence, not the next heading, so an unclosed
# fence there swallows everything up to the next ```) ----
WIRING_FENCES=$(awk '/^## Wiring files/{f=1;next} /^## /{f=0} f' "$PACK" | grep -c '^```')
if [ "$WIRING_FENCES" -eq 0 ]; then
  fail "Wiring files: no fenced block found (model/FORMAT.md §2)"
elif [ $((WIRING_FENCES % 2)) -ne 0 ]; then
  fail "Wiring files: fenced block not closed before the next heading (model/FORMAT.md §2)"
fi

# ---- check: Label probes records — week 3 format (model/FORMAT.md §3): every
# required field present, no unknown field name, id unique + matches the slug
# grammar, witnesses >= 2, closed label list (§4), every citation resolves.
# Structural parsing (multi-line field continuation) lives in
# model/parse_conventions.py, same reasoning as build-artifacts.sh's renderer
# using it instead of another awk one-liner — this script consumes its output
# rather than re-parsing records itself. Citation existence/line-bounds stays
# here in bash, on disk, not reimplemented a second time in python. ----
PARSE_CONVENTIONS="$SCRIPT_DIR/parse_conventions.py"
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not found — cannot validate Label probes records (model/FORMAT.md §3)"
elif [ ! -f "$PARSE_CONVENTIONS" ]; then
  fail "$PARSE_CONVENTIONS not found — cannot validate Label probes records (model/FORMAT.md §3)"
else
  while IFS= read -r vline; do
    [ -n "$vline" ] || continue
    case "$vline" in
      invalid:*)
        fail "${vline#invalid: }"
        ;;
      citation*)
        rid="$(printf '%s' "$vline" | cut -f2)"
        field="$(printf '%s' "$vline" | cut -f3)"
        cpath_rel="$(printf '%s' "$vline" | cut -f4)"
        cline="$(printf '%s' "$vline" | cut -f5)"
        celine="$(printf '%s' "$vline" | cut -f6)"
        cpath="${PACK_REPO_ROOT:-.}/$cpath_rel"
        if [ ! -e "$cpath" ]; then
          fail "record \`$rid\` ($field): citation does not resolve — no such file: $cpath_rel (model/FORMAT.md §3)"
        elif [ -n "$cline" ]; then
          # awk 'END{print NR}', not wc -l — wc -l undercounts a file with no
          # trailing newline, the same off-by-one SKILL.md §5.3b guards against.
          CCOUNT=$(awk 'END{print NR}' "$cpath" 2>/dev/null); CCOUNT="${CCOUNT:-0}"
          # Both ends of a `path:line-line2` range, not just the start — a
          # start still inside a shrunk file with the end now past EOF is
          # still stale (same bounds citation_ok() in build-artifacts.sh
          # already applies for staleness).
          if [ "$celine" -gt "$CCOUNT" ] 2>/dev/null; then
            fail "record \`$rid\` ($field): citation line $celine is past EOF — $cpath_rel has $CCOUNT lines (model/FORMAT.md §3)"
          fi
        fi
        ;;
    esac
  done < <(python3 "$PARSE_CONVENTIONS" "$PACK" validate)
fi

# ---- check: Brief probes has a ```bash fence, and the extracted block
# passes `bash -n` — D3, where a syntax error there is currently swallowed
# by build-artifacts.sh's `eval ... 2>/dev/null` with no flag raised ----
BRIEF_HAS_FENCE=$(awk '/^## Brief probes/{f=1;next} /^## /{f=0} f&&/^```bash/{print "yes"; exit}' "$PACK")
if [ "$BRIEF_HAS_FENCE" != "yes" ]; then
  fail "Brief probes: no \`\`\`bash fence found (model/FORMAT.md §5)"
else
  BRIEF_BLOCK=$(extract_brief_probes_block "$PACK")
  if [ -n "$BRIEF_BLOCK" ]; then
    BRIEF_ERR=$(printf '%s\n' "$BRIEF_BLOCK" | bash -n 2>&1 >/dev/null)
    [ -n "$BRIEF_ERR" ] && fail "Brief probes: bash syntax error (model/FORMAT.md §5) — $(printf '%s' "$BRIEF_ERR" | head -1)"
  fi
fi

# ---- check: every path.ext[:line] citation containing a '/' is backtick-
# wrapped — D4. Scanned outside fenced code blocks only: the Wiring files
# and Brief probes blocks legitimately hold bare paths/shell code, not
# citations. A bare URL (`https://example.com/foo`) is stripped first —
# its own scheme:// prefix already marks it as not a repo-relative
# citation, and without this the bare-citation regex matches the
# "//example.com" fragment and rejects an otherwise-valid pack. ----
STRIPPED=$(awk '/^```/{f=!f;next} !f' "$PACK" | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*##g')
BARE_CITES=$(printf '%s\n' "$STRIPPED" \
  | grep -oE '`[^`]*`|[A-Za-z0-9_./-]+\.[a-zA-Z]+(:[0-9]+(-[0-9]+)?)?' \
  | grep -v '^`' | grep '/')
if [ -n "$BARE_CITES" ]; then
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    fail "citation not backtick-wrapped, invisible to staleness checking (model/FORMAT.md §6): $c"
  done <<CITES_EOF
$BARE_CITES
CITES_EOF
fi

[ "$INVALID" = 1 ] && exit 1
exit 0
