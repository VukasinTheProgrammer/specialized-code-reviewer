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
  Always exits 0. Overwrites any existing baseline at those paths — this is
  the explicit "accept everything found so far" step, run deliberately by
  a person, never invoked as a side effect of a normal review.

usage: baseline.py apply <findings.json> <baseline.json>
  Splits <findings.json>'s `findings` array into what's new (not in the
  baseline) and what's pre-existing (fingerprint matches). Prints one JSON
  object to stdout:
    {findings: [...new, renumbered from 1...],
     suppressed_baseline: [...matched entries, unrenumbered...],
     suppressed_count: N,
     baseline_created_at: "...", baseline_base_sha: "..."}
  A missing <baseline.json> is not an error — no baseline yet is the normal
  state for a repo that has never run `/pr-review baseline` — and the input
  findings pass through unchanged (suppressed_count 0, both baseline fields
  null). Always exits 0; the caller decides what to render, same doctrine
  as every other check in this pipeline.

A fingerprint is exact-match only, and that's a known, named limitation,
not an oversight: a genuinely unrelated line added above a baselined
finding renumbers it, so the fingerprint no longer matches and the same
pre-existing defect reports again as "new". This is the same class of
staleness `model/validate-pack.sh`'s citation check already lives with for
domain-pack citations — bounded, not solved, and named here so a future
reader doesn't mistake the gap for a bug.
"""
import json
import sys
from datetime import datetime, timezone


def fingerprint(f):
    return f"{f['file']}::{f['line']}::{f['label']}"


def create(findings_path, out_json_path, out_md_path, base_sha):
    with open(findings_path, encoding="utf-8") as fh:
        run = json.load(fh)
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
    with open(out_json_path, "w", encoding="utf-8") as fh:
        json.dump(baseline, fh, indent=2, sort_keys=True)
        fh.write("\n")

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

    with open(out_md_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines).rstrip("\n") + "\n")

    sys.stderr.write(
        f"baseline: {len(entries)} finding(s) snapshotted from {findings_path} "
        f"-> {out_json_path}, {out_md_path}\n"
    )


def apply(findings_path, baseline_path):
    with open(findings_path, encoding="utf-8") as fh:
        run = json.load(fh)
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
