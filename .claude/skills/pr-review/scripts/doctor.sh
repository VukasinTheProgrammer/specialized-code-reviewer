#!/usr/bin/env bash
# Preflight check for this reviewer's own prerequisites — README.md's
# "Requirements" table, made runnable instead of just read. Never stops at
# the first problem — prints every finding it can, same doctrine
# validate-pack.sh and build-artifacts.sh are already held to
# (core/doctrine.md's control-flow.no-errexit-for-collect-all-findings).
#
# Deliberately a plain script, not a skill: the whole point is to work
# before trusting that skills/subagents/the Workflow tool are wired up at
# all — run it straight from a shell right after copying `.claude/` in,
# before ever invoking `/pr-review`. That also means it cannot check the
# one hard requirement that isn't a shell-inspectable fact (Claude Code
# itself, with skills/subagents/Workflow) — noted below as un-checkable,
# never faked as a pass.
#
#   usage: bash .claude/skills/pr-review/scripts/doctor.sh [base]
# Exit codes: 0 every hard requirement met (optional gaps don't fail it)
#             1 one or more hard requirements failed — named above, fix and re-run
#             2 not a git repository
set -u

FAIL=0
ok()   { echo "ok      $1"; }
warn() { echo "warn    $1"; }
bad()  { echo "MISSING $1"; FAIL=1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "MISSING a git repository — run this from inside one (README.md's own first hard requirement)" >&2
  exit 2
}
cd "$ROOT"

echo "Checking this reviewer's prerequisites (README.md's Requirements table) —"
echo "every line printed, never stopping at the first problem."
echo

# ---- hard: the usual tools every script here assumes ----
for tool in git awk grep sed find; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool found ($(command -v "$tool"))"
  else
    bad "$tool not found on PATH — every script here assumes it"
  fi
done

# ---- hard: bash 3.2+ — the scripts are deliberately macOS-bash-3.2
# compatible (no associative arrays, no mapfile, "${arr[@]}" on an empty
# array under set -u is handled explicitly throughout); report the real
# version rather than just checking $BASH_VERSION exists, since a version
# that's too old is the actual failure mode this warns about ----
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"; BASH_MINOR="${BASH_VERSINFO[1]:-0}"
if [ "$BASH_MAJOR" -gt 3 ] || { [ "$BASH_MAJOR" -eq 3 ] && [ "$BASH_MINOR" -ge 2 ]; }; then
  ok "bash $BASH_VERSION (>= 3.2 required)"
else
  bad "bash $BASH_VERSION is older than 3.2 — these scripts are written against 3.2's behavior and untested below it"
fi

# ---- optional: jq, only for the eval tooling (add-regression-case.sh,
# check-regression-case.sh, run-regression-set.sh) — the review itself
# never calls it, so its absence warns, never fails the whole check ----
if command -v jq >/dev/null 2>&1; then
  ok "jq found ($(command -v jq)) — needed for the eval/ regression-set scripts"
else
  warn "jq not found — /pr-review itself still runs; add-regression-case.sh, check-regression-case.sh and run-regression-set.sh (eval/ tooling) need it"
fi

# ---- hard: a base branch that resolves — build-artifacts.sh's own
# BASE_ARG default is "dev"; accept an override the same way /pr-review
# does, so this checks the actual base an adopter will run against ----
BASE_ARG="${1:-dev}"
if git rev-parse --verify --quiet "$BASE_ARG" >/dev/null; then
  ok "base branch '$BASE_ARG' resolves locally"
elif git rev-parse --verify --quiet "origin/$BASE_ARG" >/dev/null; then
  ok "base branch '$BASE_ARG' resolves as origin/$BASE_ARG (not local — a git pull/fetch would make it local too)"
else
  bad "base branch '$BASE_ARG' resolves neither locally nor as origin/$BASE_ARG — pass your real integration branch: doctor.sh <base>"
fi

# ---- un-checkable from here, named rather than silently skipped: Claude
# Code itself, with skills/subagents/the Workflow tool. This script being
# invoked at all through Claude Code's own bash tool is weak evidence that
# part works; a user running it from a plain terminal gets no signal
# either way, and that's the honest limit of what a shell script can see ----
echo
echo "cannot check   Claude Code (or Cowork) with skills, subagents and the Workflow"
echo "               tool — no shell-inspectable signal for this; if /pr-review"
echo "               itself fails to run at all, this is the first thing to check by hand"

# ---- optional: graphify — absent is a fully supported path (GRAPH=off),
# never a failure; report which of the two ways it's missing so an
# adopter who does want it knows what to fix ----
echo
if command -v graphify >/dev/null 2>&1; then
  ok "graphify found ($(command -v graphify))"
  if [ -f "graphify-out/graph.json" ]; then
    ok "graphify-out/graph.json present — GRAPH=on this run"
  else
    warn "graphify is installed but graphify-out/graph.json doesn't exist yet — run 'graphify update .' to build it, or leave it: GRAPH=off is a supported path, not a degraded one"
  fi
else
  warn "graphify not found — optional; GRAPH=off is a supported path (related/impacted fall back to Grep/Glob and the deterministic candidate list)"
fi

# ---- neither hard nor optional in the pass/fail sense — presence and
# absence are both fine, this just orients an adopter to which state
# they're in and what the next step is either way ----
echo
if [ -f "model/pr-review-domain.md" ]; then
  ok "model/pr-review-domain.md present — /pr-review will use it (run bash model/validate-pack.sh model/pr-review-domain.md to check it's well-formed)"
else
  warn "model/pr-review-domain.md not found — /pr-review still runs generic, uncited probes; /generate-domain-pack or /learn is the step that makes findings actually cite your own code"
fi

# ---- neither hard nor optional, same as the pack check above: an honor-
# system marker (LICENSE-KEY.md), never enforced — absence never fails
# this or anything else ----
echo
if [ -f ".precedent-license" ]; then
  ok ".precedent-license present ($(head -1 .precedent-license 2>/dev/null))"
else
  warn ".precedent-license not found — not required, see LICENSE-KEY.md; bash .claude/skills/pr-review/scripts/activate-license.sh <name-or-email> to write one"
fi

echo
if [ "$FAIL" = 1 ]; then
  echo "One or more hard requirements are missing — fix the MISSING lines above before running /pr-review."
else
  echo "Every hard requirement is met. warn lines above are optional gaps, not blockers."
fi
exit "$FAIL"
