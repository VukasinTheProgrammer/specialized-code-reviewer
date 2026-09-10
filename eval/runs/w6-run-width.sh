#!/usr/bin/env bash
# Week 6 diff-width A/B (future-improvements/week-6-diff-context-width.md):
# build artifacts for one context width over every frozen eval/corpus.md
# entry, via PR_REVIEW_HEAD. Same pack both widths (model/pr-review-domain.md,
# today's real pack) — this A/B varies --unified only, not pack presence, so
# it isn't the control/model split w5-run-arm.sh runs. Bash 3.2 compatible,
# same reason as w5-run-arm.sh. Corpus SHAs and the per-entry walk live in
# _corpus.sh, shared with w5-run-arm.sh — not hand-copied.
#
#   usage: bash eval/runs/w6-run-width.sh <15|8>
# Exit codes: 0 ok   3 bad args
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_corpus.sh"

WIDTH="${1:-}"
case "$WIDTH" in
  15|8) : ;;
  *) echo "usage: w6-run-width.sh <15|8>" >&2; exit 3 ;;
esac

export PR_REVIEW_UNIFIED="$WIDTH"
run_corpus "width=$WIDTH"
