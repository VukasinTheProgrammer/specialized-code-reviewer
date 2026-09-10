# PR review domain pack (test fixture — zero witnesses, human_approved: true waives the minimum entirely) — week 9

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

### dead-code.zero-witness-approved

label:        dead-code
statement:    A README section stays consistent with what it documents.
exemplar:     `README.md:1`
guard:        the citation resolves and stays within the file
unsafe_when:  the file is deleted or shrinks past the cited line
human_approved: true

## Promoted non-defects

## Brief probes

```bash
echo "ok"
```

## Dependencies

None recorded.
