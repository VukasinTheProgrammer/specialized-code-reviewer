#!/usr/bin/env bash
# Locks in D1 and D3's fixes against build-artifacts.sh itself (not just
# validate-pack.sh's static checks). Builds a throwaway git repo, copies the
# real scripts in, and asserts on the artifacts produced.
set -u
ROOT="$(git rev-parse --show-toplevel)"
SCRIPTS="$ROOT/.claude/skills/pr-review/scripts"
PACKS="$ROOT/tests/packs"
fail=0

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cd "$TMP"
git init -q
git config user.email test@test.com
git config user.name test
mkdir -p .claude/skills/pr-review/scripts model
cp "$SCRIPTS/build-artifacts.sh" .claude/skills/pr-review/scripts/
cp "$ROOT/model/validate-pack.sh" "$ROOT/model/pack-headings.txt" "$ROOT/model/pack-heading-check.sh" "$ROOT/model/parse_conventions.py" model/
# README.md/LICENSE/.gitignore: the week-3 record-format test packs
# (bad-wiring-stray-word.md, bad-wiring-unfenced.md, bad-brief-runtime-err.md)
# cite these three as a record's exemplar/witnesses — validate-pack.sh checks
# every citation resolves (model/FORMAT.md §3), against whatever repo build-
# artifacts.sh's CWD is when it runs, which is this throwaway repo, not the
# real one these packs live in. Without them here, every one of those packs
# reads as PACK_INVALID for a reason that has nothing to do with what each
# test actually exercises.
echo "# readme" > README.md
echo "MIT" > LICENSE
echo "*.log" > .gitignore
echo one > file.txt
git add -A && git commit -q -m init
echo two >> file.txt
git add -A && git commit -q -m change
git branch base HEAD~1

# Aborts the whole suite loudly if build-artifacts.sh failed to report a
# usable $OUT (crashed, or the OUT= line never printed). Must be called
# directly, never via $(...) — `exit` inside a command-substitution
# subshell only kills the subshell, not this script (confirmed: an earlier
# version of this guard did exactly that and silently kept running with an
# empty $OUT instead of aborting). Without this guard at all, an empty
# $OUT turned "$OUT/wiring.txt" into the literal path /wiring.txt, whose
# absence made every check below pass or fail on the wrong grounds instead
# of catching that build-artifacts.sh itself was broken.
require_out() {
  if [ -z "$1" ] || [ ! -d "$1" ]; then
    echo "FATAL: build-artifacts.sh produced no usable \$OUT — aborting suite" >&2
    exit 1
  fi
}

# ---- D1: wiring.txt must never carry the Label-probes table it used to
# swallow when the wiring fence went unclosed ----
OUT="$(PR_REVIEW_PACK="$PACKS/bad-wiring-unfenced.md" PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$OUT"
if grep -qE '\$\(|echo' "$OUT/wiring.txt" 2>/dev/null; then
  echo "FAIL D1: wiring.txt contaminated with shell code"; cat "$OUT/wiring.txt" | sed 's/^/       /'
  fail=1
else
  echo "ok   D1: wiring.txt clean for bad-wiring-unfenced.md"
fi

# ---- D3: a Brief-probes runtime error (bash -n can't see it — bad -n only
# catches syntax, not "command not found") must set BRIEF_DEGRADED=1.
# PR_REVIEW_EVAL_BRIEF_PROBES=1 because this pack comes via $PR_REVIEW_PACK
# and its Brief probes block is deliberately-broken test content we wrote
# and have read — the D12 block below covers the opposite case (an
# untrusted override pack's block must NOT run). ----
OUT="$(PR_REVIEW_PACK="$PACKS/bad-brief-runtime-err.md" PR_REVIEW_EVAL_BRIEF_PROBES=1 PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$OUT"
if grep -qxF 'BRIEF_DEGRADED=1' "$OUT/run.env" 2>/dev/null; then
  echo "ok   D3: BRIEF_DEGRADED=1 for bad-brief-runtime-err.md"
else
  echo "FAIL D3: BRIEF_DEGRADED not set"; cat "$OUT/run.env" | sed 's/^/       /'
  fail=1
fi

# ---- wiring.txt must be empty when the pack is invalid, even if the
# Wiring files section itself is perfectly well-formed — it used to skip
# the STALE gate every other pack-derived artifact respects ----
OUT="$(PR_REVIEW_PACK="$PACKS/bad-unknown-label.md" PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$OUT"
if [ -s "$OUT/wiring.txt" ]; then
  echo "FAIL wiring-gate: wiring.txt non-empty for an invalid pack"; cat "$OUT/wiring.txt" | sed 's/^/       /'
  fail=1
else
  echo "ok   wiring-gate: wiring.txt empty for bad-unknown-label.md (valid wiring section, invalid pack)"
fi

# ---- a stray word before the wiring fence (e.g. "TBD") must never be
# treated as a citation and must never set PACK_STALE — nothing in
# model/FORMAT.md §2 forbids prose before the fence, so this pack is valid
# and its one real wiring path (README.md) genuinely exists ----
OUT="$(PR_REVIEW_PACK="$PACKS/bad-wiring-stray-word.md" PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$OUT"
if grep -qxF 'PACK_STALE=1' "$OUT/run.env" 2>/dev/null; then
  echo "FAIL wiring-stray-word: PACK_STALE=1 from a stray word outside the fence"; cat "$OUT/run.env" | sed 's/^/       /'
  fail=1
else
  echo "ok   wiring-stray-word: PACK_STALE=0 despite a stray word before the fence"
fi

# ---- week 3 Friday: round trip — three records, one per slice, each field
# carrying a marker distinct to that record. Every marker must land in
# exactly the slice its label maps to (auth->access, db->data, a11y->
# structure) and nowhere else — proves a record's fields reach a verifier's
# prompt unmangled, not just that *a* record renders somewhere. ----
OUT="$(PR_REVIEW_PACK="$PACKS/roundtrip.md" PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$OUT"
roundtrip_fail=0
# record -> (its own slice file, its own markers, the three OTHER slice files it must never reach)
check_marker() {
  file="$1"; marker="$2"; want="$3"  # want: present | absent
  got="absent"
  grep -qF "$marker" "$file" 2>/dev/null && got="present"
  if [ "$got" != "$want" ]; then
    echo "FAIL roundtrip: $marker $got in $file, want $want"
    roundtrip_fail=1
  fi
}
for rec in "A auth access" "B db data" "C a11y structure"; do
  set -- $rec; label_letter="$1"; slice_file="probes-$3.txt"
  for field in STATEMENT GUARD UNSAFE; do
    marker="MARKER_${label_letter}_${field}"
    for slice in access data answer structure; do
      want="absent"; [ "probes-$slice.txt" = "$slice_file" ] && want="present"
      check_marker "$OUT/probes-$slice.txt" "$marker" "$want"
    done
  done
done
if [ "$roundtrip_fail" = 0 ]; then
  echo "ok   roundtrip: all 9 markers (3 records x statement/guard/unsafe_when) landed in exactly their own slice"
else
  fail=1
fi

# ---- D9 (week 9): build-artifacts.sh, invoked by its REAL absolute path —
# never copied into the reviewed repo, unlike every check above — must still
# find its own model/ assets (pack-heading-check.sh, pack-headings.txt,
# validate-pack.sh, parse_conventions.py) when the reviewed repo is a
# genuinely foreign checkout with no model/ dir of its own. Before this
# fix, those four call sites referenced "model/..." as a bare path relative
# to $ROOT (the reviewed repo, post-cd), which every other check in this
# suite masks by copying this tool's own model/ files into the throwaway
# repo's own model/ dir (see the setup above) — that shim happens to sit at
# exactly the relative depth build-artifacts.sh's own $SCRIPT_DIR-based
# resolution now expects too, so it stays passing either way. This check
# exists specifically to catch what those shims cannot: a foreign repo that
# never had a model/ dir at all, invoked the way a real design-partner repo
# actually is. ----
D9_TMP="$(mktemp -d)"
(
  cd "$D9_TMP"
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo "# readme" > README.md
  echo "MIT" > LICENSE
  echo "*.log" > .gitignore
  mkdir -p .claude/skills/pr-review/scripts
  echo "#!/usr/bin/env bash" > .claude/skills/pr-review/scripts/build-artifacts.sh
  git add -A && git commit -q -m init
  echo two >> README.md
  git add -A && git commit -q -m change
  git branch base HEAD~1
)
D9_OUT="$(cd "$D9_TMP" && PR_REVIEW_PACK="$PACKS/good.md" PR_REVIEW_NO_GRAPH=1 \
  bash "$SCRIPTS/build-artifacts.sh" base 2>&1)"
rm -rf "$D9_TMP"
D9_ENV_LINE="$(printf '%s\n' "$D9_OUT" | grep -E '^(PACK_PRESENT|PACK_STALE|PACK_INVALID)=')"
if printf '%s\n' "$D9_ENV_LINE" | grep -qxF 'PACK_PRESENT=1' \
  && printf '%s\n' "$D9_ENV_LINE" | grep -qxF 'PACK_STALE=0' \
  && printf '%s\n' "$D9_ENV_LINE" | grep -qxF 'PACK_INVALID=0'; then
  echo "ok   D9: build-artifacts.sh resolves its own model/ assets from a foreign repo with no model/ dir"
else
  echo "FAIL D9: expected PACK_PRESENT=1/PACK_STALE=0/PACK_INVALID=0 from outside this repo"
  printf '%s\n' "$D9_OUT" | sed 's/^/       /'
  fail=1
fi

# ---- D10 (week 9): `human_approved: true` on a record waives the witnesses
# >= 2 rule (model/FORMAT.md §3d) — the `learn` skill's whole reason to exist
# is a human vouching for a real single-witness pattern an unattended agent
# would otherwise have to drop. Two packs, structurally identical down to the
# `id` slug's suffix, differing only in that one field — proves the flag
# itself gates the behavior, not merely that "some one-witness pack now
# passes" for an unrelated reason. bad-one-witness.md already exists and is
# exercised elsewhere in this suite by inference (it's a fixture, not wired
# into a check above) — assert it directly here as the negative case. ----
D10_APPROVED="$(bash "$ROOT/model/validate-pack.sh" "$PACKS/good-human-approved-one-witness.md" "$ROOT" 2>&1)"
D10_APPROVED_EXIT=$?
D10_UNAPPROVED="$(bash "$ROOT/model/validate-pack.sh" "$PACKS/bad-one-witness.md" "$ROOT" 2>&1)"
D10_UNAPPROVED_EXIT=$?
if [ "$D10_APPROVED_EXIT" = 0 ] && [ "$D10_UNAPPROVED_EXIT" != 0 ]; then
  echo "ok   D10: human_approved:true waives witnesses>=2 (pass), the same shape without it still fails"
else
  echo "FAIL D10: expected approved-pack exit 0 (got $D10_APPROVED_EXIT) and unapproved-pack exit != 0 (got $D10_UNAPPROVED_EXIT)"
  echo "       approved output:"; printf '%s\n' "$D10_APPROVED" | sed 's/^/         /'
  echo "       unapproved output:"; printf '%s\n' "$D10_UNAPPROVED" | sed 's/^/         /'
  fail=1
fi

# ---- D11 (week 9, /code-review pass): two contract mismatches between
# model/FORMAT.md §3d's prose and parse_conventions.py's actual check,
# found by an independent code review, not by this suite. §3d says a
# human-approved record "may carry as few as one real witness (or, in
# principle, none)" — but REQUIRED_FIELDS used to run unconditionally
# before the human_approved waiver, rejecting an empty `witnesses` list
# even when approved, making the documented zero-witness case
# unreachable. Separately, §3d says the field "must be exactly `true` or
# `false`... any other value is rejected as a typo" — but the check used
# to `.lower()` the value first, silently accepting `True`/`TRUE`. Both
# fixed by computing human_approved before REQUIRED_FIELDS and comparing
# it case-sensitively. ----
D11_ZERO="$(bash "$ROOT/model/validate-pack.sh" "$PACKS/good-human-approved-zero-witness.md" "$ROOT" 2>&1)"
D11_ZERO_EXIT=$?
D11_CASE="$(bash "$ROOT/model/validate-pack.sh" "$PACKS/bad-human-approved-wrong-case.md" "$ROOT" 2>&1)"
D11_CASE_EXIT=$?
if [ "$D11_ZERO_EXIT" = 0 ] && [ "$D11_CASE_EXIT" != 0 ]; then
  echo "ok   D11: human_approved:true with zero witnesses passes; human_approved:True (wrong case) fails as a typo"
else
  echo "FAIL D11: expected zero-witness pack exit 0 (got $D11_ZERO_EXIT) and wrong-case pack exit != 0 (got $D11_CASE_EXIT)"
  echo "       zero-witness output:"; printf '%s\n' "$D11_ZERO" | sed 's/^/         /'
  echo "       wrong-case output:"; printf '%s\n' "$D11_CASE" | sed 's/^/         /'
  fail=1
fi

# ---- D12 (week 10): the Brief probes `eval` is arbitrary shell from a
# markdown file — an accepted risk only while the pack's author is the one
# running it (future-improvements/week-12-remove-brief-probes-eval.md).
# Phase 3's cold-onboarding test breaks that assumption: a fresh operator
# runs against a partner pack an agent generated over a codebase nobody
# read. So a pack supplied via $PR_REVIEW_PACK must NOT have its Brief
# probes block eval'd unless the caller opts in with
# PR_REVIEW_EVAL_BRIEF_PROBES=1. bad-brief-side-effect.md's block writes an
# observable marker file; run it untrusted and assert the marker never
# appears and brief.txt is still valid (presence-only fallback). ----
D12_OUT="$(PR_REVIEW_PACK="$PACKS/bad-brief-side-effect.md" PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$D12_OUT"
if [ ! -e "$D12_OUT/BRIEF_PROBES_EXECUTED" ] \
  && grep -qxF 'BRIEF_PROBES_TRUSTED=0' "$D12_OUT/run.env" 2>/dev/null \
  && grep -q '^migrations:' "$D12_OUT/brief.txt" 2>/dev/null; then
  echo "ok   D12: an untrusted \$PR_REVIEW_PACK pack's Brief probes block is not eval'd; brief.txt falls back cleanly"
else
  echo "FAIL D12: untrusted pack's Brief probes block ran, or fallback brief.txt is malformed"
  [ -e "$D12_OUT/BRIEF_PROBES_EXECUTED" ] && echo "       marker file WAS created — block executed"
  cat "$D12_OUT/run.env" 2>/dev/null | grep BRIEF | sed 's/^/       /'
  cat "$D12_OUT/brief.txt" 2>/dev/null | sed 's/^/       /'
  fail=1
fi

# ---- D12b: the same pack WITH PR_REVIEW_EVAL_BRIEF_PROBES=1 does run the
# block — proves the opt-in flag is the thing that gates it, not some
# unrelated property of the pack. (Marker is written into the throwaway
# repo's own $OUT under .git/, cleaned up with $TMP by the suite's trap.) ----
D12B_OUT="$(PR_REVIEW_PACK="$PACKS/bad-brief-side-effect.md" PR_REVIEW_EVAL_BRIEF_PROBES=1 PR_REVIEW_NO_GRAPH=1 \
  bash .claude/skills/pr-review/scripts/build-artifacts.sh base 2>/dev/null | grep '^OUT=' | cut -d= -f2)"
require_out "$D12B_OUT"
if [ -e "$D12B_OUT/BRIEF_PROBES_EXECUTED" ] \
  && grep -qxF 'BRIEF_PROBES_TRUSTED=1' "$D12B_OUT/run.env" 2>/dev/null; then
  echo "ok   D12b: PR_REVIEW_EVAL_BRIEF_PROBES=1 opts the same pack back in — the flag is the gate"
else
  echo "FAIL D12b: opt-in flag did not enable eval for the override pack"
  cat "$D12B_OUT/run.env" 2>/dev/null | grep BRIEF | sed 's/^/       /'
  fail=1
fi

exit "$fail"
