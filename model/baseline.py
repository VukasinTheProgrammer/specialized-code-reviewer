#!/usr/bin/env python3
"""Fingerprint a review run's findings as pre-existing debt, and suppress
matches on later runs — week 11's baseline (Twelve Weeks to a Plugin,
Phase 3: "the first run on a real legacy repo will find a lot. Without
this, that is where every demo dies.").

The fingerprint is `file::line::label` — the same dedup key
`pr-review-verify.js` already uses to collapse a sweep finding and a proven
hypothesis into one row, reused rather than invented a second time.

usage: baseline.py create <findings.json> <out-json> <out-md> <base-sha>
  Snapshots every finding in <findings.json>'s `findings` array as baseline
  debt: writes <out-json> (the fingerprint set `apply` matches against) and
  <out-md> (grouped by label, one line per finding — the browsable form
  week 11 asks for, so existing debt is visible without being in the way).
  Both are written to a temp file in the same directory first, then
  os.replace'd into place — same atomic-publish discipline as everywhere
  else in this pipeline (`.claude/skills/pr-review/SKILL.md`'s own
  `mv "$OUT/findings.json" .git/pr-review/findings.json`), so a concurrent
  reader (a normal run's Step 5.3c) never observes a half-written baseline.
  Overwrites any existing baseline at those paths — this is the explicit
  "accept everything found so far" step, run deliberately by a person,
  never invoked as a side effect of a normal review.

usage: baseline.py apply <findings.json> <baseline.json>
  Splits <findings.json>'s `findings` array into what's new (not in the
  baseline) and what's pre-existing (fingerprint matches). Prints one JSON
  object to stdout:
    {findings: [...new, renumbered from 1...],
     suppressed_baseline: [...matched entries, unrenumbered...],
     suppressed_count: N,
     baseline_created_at: "...", baseline_base_sha: "..."}
  A missing OR corrupt <baseline.json> is not an error — degrades the same
  way (findings pass through unchanged, suppressed_count 0, both baseline
  fields null), same doctrine as this pipeline's other stale/invalid
  degrades (PACK_INVALID, LEDGER_STALE): never block a review over one bad
  file, warn on stderr and continue. A corrupt <baseline.json> warns
  distinctly from a missing one, so the difference is visible without
  being fatal.

Exit codes: 0 ok (including every degrade above)   1 <findings.json> itself
is missing or not valid JSON — this is this run's own just-built input, not
a stale artifact to degrade around, so there is nothing safe to fall back
to   2 wrong argument count, or a mode that isn't `create`/`apply`

A fingerprint is exact-match only, and that's a known, named limitation,
not an oversight: a genuinely unrelated line added above a baselined
finding renumbers it, so the fingerprint no longer matches and the same
pre-existing defect reports again as "new". This is the same class of
staleness `model/validate-pack.sh`'s citation check already lives with for
domain-pack citations — bounded, not solved, and named here so a future
reader doesn't mistake the gap for a bug.
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timezone


def fingerprint(f):
    return f"{f['file']}::{f['line']}::{f['label']}"


def write_atomic(path, content):
    """Write via a same-directory temp file + os.replace, never straight to
    `path` — the atomic-publish convention this project already holds every
    other pipeline artifact to (`.claude/skills/pr-review/SKILL.md`'s own
    `mv "$OUT/findings.json" .git/pr-review/findings.json`). Same directory
    matters: os.replace is only atomic within one filesystem."""
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".baseline-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def load_findings_or_die(findings_path):
    """<findings.json> is this run's own just-built output (Step 5.1-5.3b),
    not a stale artifact from a prior run — there is nothing safe to degrade
    to if it's missing or malformed, unlike a baseline file. Exit 1 with a
    clear reason on stderr rather than an uncaught traceback."""
    try:
        with open(findings_path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        sys.stderr.write(f"error: cannot read '{findings_path}'\n")
        sys.exit(1)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"error: '{findings_path}' is not valid JSON — {e}\n")
        sys.exit(1)


def create(findings_path, out_json_path, out_md_path, base_sha):
    run = load_findings_or_die(findings_path)
    findings = run.get("findings", [])

    entries = {}
    for f in findings:
        entries[fingerprint(f)] = {
            "file": f["file"],
            "line": f["line"],
            "label": f["label"],
            "failure_mode": f.get("failure_mode", ""),
        }

    created_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    baseline = {
        "created_at": created_at,
        "base_sha": base_sha,
        "count": len(entries),
        "findings": entries,
    }
    write_atomic(out_json_path, json.dumps(baseline, indent=2, sort_keys=True) + "\n")

    by_label = {}
    for entry in entries.values():
        by_label.setdefault(entry["label"], []).append(entry)
    for label_entries in by_label.values():
        label_entries.sort(key=lambda e: (e["file"], e["line"]))

    lines = [
        "# Baseline — pre-existing findings, accepted as debt",
        "",
        f"Created {created_at} at `{base_sha}`. {len(entries)} finding(s).",
        "",
        "Suppressed on every run after this one, matched by `file:line:label` "
        "— see `model/baseline.py`'s own docstring for what a fingerprint "
        "match does and doesn't survive.",
        "",
    ]
    for label in sorted(by_label):
        lines.append(f"## {label}")
        lines.append("")
        for entry in by_label[label]:
            first_sentence = entry["failure_mode"].split(". ")[0].rstrip(".") + "."
            lines.append(f"- `{entry['file']}:{entry['line']}` — {first_sentence}")
        lines.append("")

    write_atomic(out_md_path, "\n".join(lines).rstrip("\n") + "\n")

    sys.stderr.write(
        f"baseline: {len(entries)} finding(s) snapshotted from {findings_path} "
        f"-> {out_json_path}, {out_md_path}\n"
    )


def apply(findings_path, baseline_path):
    run = load_findings_or_die(findings_path)
    findings = run.get("findings", [])

    try:
        with open(baseline_path, encoding="utf-8") as fh:
            baseline = json.load(fh)
    except FileNotFoundError:
        print(json.dumps({
            "findings": findings,
            "suppressed_baseline": [],
            "suppressed_count": 0,
            "baseline_created_at": None,
            "baseline_base_sha": None,
        }))
        return
    except json.JSONDecodeError as e:
        # Degrade like any other stale/invalid pipeline artifact (PACK_INVALID,
        # LEDGER_STALE) — never block a review over one corrupt file. Warned
        # distinctly from "missing" so the difference is visible, not silent.
        sys.stderr.write(
            f"warning: '{baseline_path}' exists but is not valid JSON ({e}) — "
            f"treating as no baseline this run\n"
        )
        print(json.dumps({
            "findings": findings,
            "suppressed_baseline": [],
            "suppressed_count": 0,
            "baseline_created_at": None,
            "baseline_base_sha": None,
        }))
        return

    baseline_keys = set(baseline.get("findings", {}).keys())

    new_findings = []
    suppressed = []
    for f in findings:
        if fingerprint(f) in baseline_keys:
            suppressed.append(f)
        else:
            new_findings.append(f)

    for i, f in enumerate(new_findings):
        f["n"] = i + 1

    print(json.dumps({
        "findings": new_findings,
        "suppressed_baseline": suppressed,
        "suppressed_count": len(suppressed),
        "baseline_created_at": baseline.get("created_at"),
        "baseline_base_sha": baseline.get("base_sha"),
    }))


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    mode = sys.argv[1]

    if mode == "create":
        if len(sys.argv) != 6:
            sys.stderr.write(__doc__)
            sys.exit(2)
        create(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        return

    if mode == "apply":
        if len(sys.argv) != 4:
            sys.stderr.write(__doc__)
            sys.exit(2)
        apply(sys.argv[2], sys.argv[3])
        return

    sys.stderr.write(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
