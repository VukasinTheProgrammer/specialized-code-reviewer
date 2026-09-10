# PR review domain pack (test fixture — human_approved value wrong-cased, must fail as a typo not silently pass) — week 9

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

### dead-code.wrong-case-human-approved

label:        dead-code
statement:    A README section stays consistent with what it documents.
exemplar:     `README.md:1`
guard:        the citation resolves and stays within the file
unsafe_when:  the file is deleted or shrinks past the cited line
human_approved: True

## Promoted non-defects

## Brief probes

```bash
echo "ok"
```

## Dependencies

None recorded.
