#!/usr/bin/env bash
# Writes .precedent-license at the repo root — an honor-system marker, not
# enforcement (LICENSE-KEY.md explains why: a file-copy plugin has nothing
# real to check a key against). doctor.sh reports whether this file exists;
# absence only ever warns, never blocks.
#
#   usage: bash .claude/skills/pr-review/scripts/activate-license.sh <name-or-email>
set -u

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "usage: activate-license.sh <name-or-email>" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 2
}

OUT="$ROOT/.precedent-license"
{
  echo "licensed-to: $1"
  echo "issued:      $(date +%Y-%m-%d)"
} > "$OUT"

echo "wrote $OUT (gitignore it — per-install, not something to commit or share)"
