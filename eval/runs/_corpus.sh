# Sourced by eval/runs/w5-run-arm.sh and eval/runs/w6-run-width.sh — the
# one place that names the frozen eval/corpus.md SHAs and walks them. Each
# caller supplies its own per-entry env (PR_REVIEW_PACK for the control/
# model split, PR_REVIEW_UNIFIED for the diff-width A/B) and its own label
# for the "===" banner; the corpus list and the walk itself live here once,
# not hand-copied into every new A/B script this project adds — same
# duplication class model/pack-heading-check.sh exists to prevent for the
# pack-format checks.
#
#   usage: . eval/runs/_corpus.sh
#   provides: corpus_entry() and run_corpus() <label>
#   run_corpus's <label> is used only for the "=== id (<label>): base..head ==="
#   banner; the caller must already have exported whatever PR_REVIEW_* env
#   var its own arm needs before calling it.

corpus_entry() {
  case "$1" in
    e01-monday)    echo "87a033d 18276dc" ;;
    e02-tuesday)   echo "18276dc 43f3f8e" ;;
    e03-wednesday) echo "43f3f8e a42f5e6" ;;
    e04-thursday)  echo "a42f5e6 270c8e9" ;;
    e05-friday)    echo "270c8e9 2887944" ;;
  esac
}

run_corpus() {
  label="$1"
  for id in e01-monday e02-tuesday e03-wednesday e04-thursday e05-friday; do
    entry="$(corpus_entry "$id")"
    base="${entry% *}"
    head="${entry#* }"
    echo "=== $id ($label): $base..$head ==="
    PR_REVIEW_HEAD="$head" PR_REVIEW_NO_GRAPH=1 \
      bash .claude/skills/pr-review/scripts/build-artifacts.sh "$base"
    echo
  done
}
