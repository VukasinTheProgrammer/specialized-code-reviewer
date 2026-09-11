#!/usr/bin/env bash
# Spec for validate-pack.sh (written before the validator — see todays-work/).
# Each bad-*.md pack must exit 1; good.md must exit 0.
set -u
ROOT="$(git rev-parse --show-toplevel)"
VALIDATOR="$ROOT/model/validate-pack.sh"
PACKS="$ROOT/tests/packs"
fail=0

check() {
  pack="$1"; want="$2"
  out="$(bash "$VALIDATOR" "$PACKS/$pack" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   $pack (exit $got)"
  else
    echo "FAIL $pack (exit $got, want $want)"
    echo "$out" | sed 's/^/       /'
    fail=1
  fi
}

check "good.md"                  0
check "good-pipe-in-prose.md"    0
check "bad-heading-case.md"      1
check "bad-wiring-unfenced.md"   1
check "bad-brief-syntax.md"      1
check "bad-citation-unquoted.md" 1
check "bad-unknown-label.md"     1

# week 3: record-format checks (model/FORMAT.md §3) — bad-pipe-in-cell.md
# retired above it: a `|` inside a probe cell can't split a row that no
# longer has cells.
check "bad-one-witness.md"       1
check "bad-unknown-field.md"     1
check "bad-duplicate-id.md"      1
check "bad-empty-unsafe-when.md" 1
check "bad-citation-eof.md"      1
check "bad-citation-range-eof.md" 1

# week 11: Stack scope prefixes (model/FORMAT.md §1b) — found live in
# model/partners/headroom/pr-review-domain-transforms-py.md: prose that
# reads correctly to a person parses to zero table rows.
check "good-single-stack.md"     0
check "bad-stack-scope-prose.md" 1

# week 12: single-stack: both — found live in this repo's own
# model/pr-review-domain.md: an empty table plus prose claiming "SCOPE
# resolves both" that build-artifacts.sh never actually implemented,
# silently degrading BE/FE to 0/0 (SCOPE=neither) instead.
check "good-single-stack-both.md" 0

exit "$fail"
