# PR review domain pack (test fixture — Stack scope prefixes as unparseable prose) — week 11

## Stack scope prefixes

Single stack (Python backend). No prefixes needed.

## Wiring files

```
.claude/skills/pr-review/scripts/build-artifacts.sh
README.md
```

## Label probes

### dead-code.stale-reference

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
echo "ok"
```

## Dependencies

None recorded.
