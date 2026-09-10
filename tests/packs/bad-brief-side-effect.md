# PR review domain pack (test fixture — Brief probes block with an observable side effect, must NOT run when the pack is untrusted) — week 10

## Stack scope prefixes

| Prefix | Stack |
|---|---|
| `.claude/skills/` | backend |

## Wiring files

```
.claude/skills/pr-review/scripts/build-artifacts.sh
README.md
```

## Label probes

### dead-code.placeholder

label:        dead-code
statement:    A README section stays consistent with what it documents.
exemplar:     `README.md:1`
witnesses:    `LICENSE:1`
              `.gitignore:1`
guard:        the citation resolves and stays within the file
unsafe_when:  the file is deleted or shrinks past the cited line

## Promoted non-defects

## Brief probes

```bash
# If this block is ever eval'd from an untrusted ($PR_REVIEW_PACK) pack,
# this file appears in $OUT and the D12 assertion fails. It is a stand-in
# for the real risk: arbitrary shell — a curl, an rm, an exfil — lifted
# out of a markdown file nobody read.
: > "$OUT/BRIEF_PROBES_EXECUTED"
```

## Dependencies

None recorded.
