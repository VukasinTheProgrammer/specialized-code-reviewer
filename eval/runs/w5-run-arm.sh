#!/usr/bin/env bash
# Week 5 gate-1: build artifacts for one arm (control or model) over every
# frozen eval/corpus.md entry, via PR_REVIEW_HEAD. Bash 3.2 compatible
# (macOS ships it, this repo's own build-artifacts.sh already avoids
# associative arrays for the same reason). Corpus SHAs and the per-entry
# walk live in _corpus.sh, shared with w6-run-width.sh — not hand-copied.
#
#   usage: bash eval/runs/w5-run-arm.sh <control|model>
# Exit codes: 0 ok   3 bad args
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_corpus.sh"

ARM="${1:-}"
case "$ARM" in
  control) PACK=tests/packs/empty.md ;;
  model)   PACK=model/pr-review-domain.md ;;
  *) echo "usage: w5-run-arm.sh <control|model>" >&2; exit 3 ;;
esac

export PR_REVIEW_PACK="$PACK"
run_corpus "$ARM"
