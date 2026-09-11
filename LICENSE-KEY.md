# License key

Honest about what this is: an honor-system marker, not protection. This is
a plain-text `.claude/` directory copied into your repo — there is no build
step, no server, nothing to check a key against. Anyone can skip this file
entirely and the reviewer runs exactly the same. DRM on a file copy isn't a
real thing; pretending otherwise here would just be a worse version of not
having a key at all.

What it's actually for: making an install attributable, and giving a real
protection mechanism (a hosted `/learn`, eventually) something to build on
later. Neither of those needs cryptography today.

## Activate

```bash
bash .claude/skills/pr-review/scripts/activate-license.sh "you@example.com"
```

Writes `.precedent-license` at your repo root (gitignore it — it's
per-install, not something to commit or share). `doctor.sh` reports whether
it's present; absence is a `warn`, never a `MISSING` — it has never gated
anything and never will, in this form.

## Format

```
licensed-to: you@example.com
issued:      2026-09-11
```

No checksum, no signature. Editing it by hand does exactly as much as
running the script.
