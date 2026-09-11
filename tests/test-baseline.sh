#!/usr/bin/env bash
# Spec for model/baseline.py (week 11) — same check()/fail pattern as
# tests/run.sh, driving real findings.json fixtures through create/apply
# rather than trusting the implementation by inspection.
set -u
ROOT="$(git rev-parse --show-toplevel)"
BASELINE_PY="$ROOT/model/baseline.py"
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

# --- fixture: a "first run" with three findings ---
cat > "$TMP/run1.json" <<'EOF'
{"findings": [
  {"n": 1, "file": "a.py", "line": 10, "label": "logic", "failure_mode": "Off-by-one. Detail."},
  {"n": 2, "file": "b.py", "line": 20, "label": "auth", "failure_mode": "Missing check. Detail."},
  {"n": 3, "file": "c.py", "line": 30, "label": "db", "failure_mode": "No retry. Detail."}
]}
EOF

python3 "$BASELINE_PY" create "$TMP/run1.json" "$TMP/baseline.json" "$TMP/baseline.md" "abc123"
CREATE_RC=$?
check "create exits 0" "$CREATE_RC" "0"
check "baseline.json written" "$([ -f "$TMP/baseline.json" ] && echo yes)" "yes"
check "baseline.md written" "$([ -f "$TMP/baseline.md" ] && echo yes)" "yes"
check "baseline.json count field" "$(python3 -c "import json; print(json.load(open('$TMP/baseline.json'))['count'])")" "3"
check "baseline.md lists a.py:10" "$(grep -c 'a.py:10' "$TMP/baseline.md")" "1"

# --- fixture: a "second run" — same 3 findings plus 1 genuinely new one ---
cat > "$TMP/run2.json" <<'EOF'
{"findings": [
  {"n": 1, "file": "a.py", "line": 10, "label": "logic", "failure_mode": "Off-by-one. Detail."},
  {"n": 2, "file": "b.py", "line": 20, "label": "auth", "failure_mode": "Missing check. Detail."},
  {"n": 3, "file": "c.py", "line": 30, "label": "db", "failure_mode": "No retry. Detail."},
  {"n": 4, "file": "d.py", "line": 40, "label": "state", "failure_mode": "Stale cache. Detail."}
]}
EOF

OUT="$(python3 "$BASELINE_PY" apply "$TMP/run2.json" "$TMP/baseline.json")"
check "apply exits 0" "$?" "0"
check "3 pre-existing findings suppressed" "$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['suppressed_count'])")" "3"
check "1 new finding survives" "$(echo "$OUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['findings']))")" "1"
check "surviving finding is d.py" "$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['findings'][0]['file'])")" "d.py"
check "surviving finding renumbered to n=1" "$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['findings'][0]['n'])")" "1"
check "baseline_base_sha echoed back" "$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['baseline_base_sha'])")" "abc123"

# --- fixture: same-file+label but a genuinely different line is NOT a baseline match ---
cat > "$TMP/run3.json" <<'EOF'
{"findings": [
  {"n": 1, "file": "a.py", "line": 11, "label": "logic", "failure_mode": "Off-by-one, shifted one line down. Detail."}
]}
EOF
OUT3="$(python3 "$BASELINE_PY" apply "$TMP/run3.json" "$TMP/baseline.json")"
check "a shifted line is not suppressed (known fingerprint limitation)" \
  "$(echo "$OUT3" | python3 -c "import json,sys; print(json.load(sys.stdin)['suppressed_count'])")" "0"

# --- fixture: no baseline file at all — pass-through, not an error ---
OUT4="$(python3 "$BASELINE_PY" apply "$TMP/run2.json" "$TMP/does-not-exist.json")"
check "missing baseline exits 0" "$?" "0"
check "missing baseline: 0 suppressed" "$(echo "$OUT4" | python3 -c "import json,sys; print(json.load(sys.stdin)['suppressed_count'])")" "0"
check "missing baseline: all 4 findings pass through" "$(echo "$OUT4" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['findings']))")" "4"
check "missing baseline: baseline_created_at is null" "$(echo "$OUT4" | python3 -c "import json,sys; print(json.load(sys.stdin)['baseline_created_at'])")" "None"

# --- fixture: baseline.json exists but is corrupt — degrades like missing, never crashes ---
echo '{not valid json' > "$TMP/corrupt-baseline.json"
OUT5="$(python3 "$BASELINE_PY" apply "$TMP/run2.json" "$TMP/corrupt-baseline.json" 2>"$TMP/corrupt-stderr")"
check "corrupt baseline exits 0 (degrades, doesn't crash)" "$?" "0"
check "corrupt baseline: 0 suppressed" "$(echo "$OUT5" | python3 -c "import json,sys; print(json.load(sys.stdin)['suppressed_count'])")" "0"
check "corrupt baseline: warns on stderr, not silent" "$(grep -c 'not valid JSON' "$TMP/corrupt-stderr")" "1"

# --- fixture: findings.json itself is malformed — this is NOT degradable, exit 1 ---
echo '{not valid json' > "$TMP/corrupt-findings.json"
python3 "$BASELINE_PY" apply "$TMP/corrupt-findings.json" "$TMP/baseline.json" >/dev/null 2>"$TMP/findings-stderr"
check "malformed findings.json exits 1, not 0 or a crash" "$?" "1"
check "malformed findings.json: error named on stderr" "$(grep -c 'not valid JSON' "$TMP/findings-stderr")" "1"

python3 "$BASELINE_PY" create "$TMP/corrupt-findings.json" "$TMP/x.json" "$TMP/x.md" "abc123" >/dev/null 2>"$TMP/create-stderr"
check "create() on malformed findings.json also exits 1" "$?" "1"

# --- create() writes atomically: no .baseline-*.tmp survives a clean run ---
check "no leftover temp file after create" "$(find "$TMP" -maxdepth 1 -name '.baseline-*.tmp' | wc -l | tr -d ' ')" "0"

exit $fail
