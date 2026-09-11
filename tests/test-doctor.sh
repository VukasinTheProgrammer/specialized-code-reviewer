#!/usr/bin/env bash
# Spec for .claude/skills/pr-review/scripts/doctor.sh (week 12) — same
# check()/fail pattern as tests/run.sh and tests/test-baseline.sh, driving
# real throwaway repos and a stripped PATH through it rather than trusting
# the implementation by inspection.
set -u
ROOT="$(git rev-parse --show-toplevel)"
DOCTOR="$ROOT/.claude/skills/pr-review/scripts/doctor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() {
  desc="$1"; got="$2"; want="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc (got [$got], want [$want])"
    fail=1
  fi
}

# --- fixture: a clean repo, a real base branch, no pack, no graphify ---
(
  cd "$TMP" || exit 1
  git init -q
  git config user.email test@test.com
  git config user.name test
  echo one > f.txt
  git add -A && git commit -q -m init
  git branch base HEAD
)
CLEAN_OUT="$(cd "$TMP" && bash "$DOCTOR" base 2>&1 </dev/null)"
CLEAN_RC=$?
check "clean repo, real base: exits 0" "$CLEAN_RC" "0"
check "clean repo: base branch reported ok" "$(echo "$CLEAN_OUT" | grep -c "ok.*base branch 'base' resolves locally")" "1"
check "clean repo: no pack warns, doesn't fail" "$(echo "$CLEAN_OUT" | grep -c "warn.*model/pr-review-domain.md not found")" "1"
check "clean repo: nothing reported MISSING" "$(echo "$CLEAN_OUT" | grep -c '^MISSING')" "0"

# --- fixture: same repo, a base branch that doesn't resolve ---
NOBASE_OUT="$(cd "$TMP" && bash "$DOCTOR" nonexistent-branch 2>&1 </dev/null)"
NOBASE_RC=$?
check "missing base branch: exits 1" "$NOBASE_RC" "1"
check "missing base branch: MISSING line names it" "$(echo "$NOBASE_OUT" | grep -c "MISSING base branch 'nonexistent-branch'")" "1"

# --- fixture: not a git repo at all ---
NOTGIT_DIR="$(mktemp -d)"
NOTGIT_OUT="$(cd "$NOTGIT_DIR" && bash "$DOCTOR" 2>&1 </dev/null)"
NOTGIT_RC=$?
rm -rf "$NOTGIT_DIR"
check "not a git repo: exits 2" "$NOTGIT_RC" "2"
check "not a git repo: names it" "$(echo "$NOTGIT_OUT" | grep -c 'MISSING a git repository')" "1"

# --- fixture: hard tools missing from PATH (git present, awk/grep/sed/find/jq not) ---
FAKEBIN="$(mktemp -d)"
ln -s "$(command -v git)" "$FAKEBIN/git"
ln -s "$(command -v bash)" "$FAKEBIN/bash"
NOTOOLS_OUT="$(cd "$TMP" && PATH="$FAKEBIN" bash "$DOCTOR" base 2>&1 </dev/null)"
NOTOOLS_RC=$?
rm -rf "$FAKEBIN"
check "missing hard tools: exits 1" "$NOTOOLS_RC" "1"
check "missing hard tools: awk named" "$(echo "$NOTOOLS_OUT" | grep -c 'MISSING awk not found')" "1"
check "missing hard tools: grep named" "$(echo "$NOTOOLS_OUT" | grep -c 'MISSING grep not found')" "1"
check "missing hard tools: jq absence only warns (optional)" "$(echo "$NOTOOLS_OUT" | grep -c 'warn.*jq not found')" "1"

# --- the un-checkable line is always printed, never silently skipped ---
check "clean repo: names the un-checkable Claude Code requirement" "$(echo "$CLEAN_OUT" | grep -c 'cannot check   Claude Code')" "1"

# --- license key: warns when absent, never fails; ok and shows the line when present ---
check "clean repo: no .precedent-license warns, doesn't fail" "$(echo "$CLEAN_OUT" | grep -c 'warn.*\.precedent-license not found')" "1"
ACTIVATE="$ROOT/.claude/skills/pr-review/scripts/activate-license.sh"
(cd "$TMP" && bash "$ACTIVATE" "tester@example.com" >/dev/null)
LICENSED_OUT="$(cd "$TMP" && bash "$DOCTOR" base 2>&1 </dev/null)"
LICENSED_RC=$?
check "with .precedent-license: still exits 0" "$LICENSED_RC" "0"
check "with .precedent-license: ok line names it" "$(echo "$LICENSED_OUT" | grep -c 'ok.*\.precedent-license present (licensed-to: tester@example.com)')" "1"
rm -f "$TMP/.precedent-license"

exit "$fail"
