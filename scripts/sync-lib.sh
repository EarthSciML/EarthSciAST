#!/usr/bin/env bash
# sync-lib.sh — Mirror the standard subsystem library (lib/*.esm) into the docs
# site's static assets, and verify the two copies have not drifted.
#
# Usage:
#   scripts/sync-lib.sh          # Copy lib/*.esm to docs/static/lib/
#   scripts/sync-lib.sh --check  # Fail (exit 1) if any copy has drifted
#
# WHY THIS EXISTS. `lib/solar.esm`, `lib/calendar.esm` and `lib/interp.esm` are
# the SHIPPED standard library — real code that users mount as subsystems via a
# §4.7 `ref`, not test fixtures. They are duplicated under `docs/static/lib/` so
# the documentation site can serve them at a stable URL. Nothing enforced that
# duplication, so the docs could ship a stale — or dimensionally broken — copy
# of the standard library indefinitely and no test would notice. The schema has
# had this guard since day one (scripts/sync-schema.sh); the standard library
# did not. Audit 2026-07-14.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/lib"
MIRROR_DIR="${REPO_ROOT}/docs/static/lib"

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "ERROR: Canonical library not found: $SOURCE_DIR" >&2
  exit 1
fi

check_mode=false
if [[ "${1:-}" == "--check" ]]; then
  check_mode=true
fi

drifted=0
found=0

for src in "$SOURCE_DIR"/*.esm; do
  [[ -e "$src" ]] || continue
  found=1
  name="$(basename "$src")"
  dst="${MIRROR_DIR}/${name}"
  rel="docs/static/lib/${name}"

  if [[ "$check_mode" == true ]]; then
    if [[ ! -f "$dst" ]]; then
      echo "MISSING: $rel"
      drifted=1
    elif ! diff -q "$src" "$dst" > /dev/null 2>&1; then
      echo "DRIFT:   $rel"
      drifted=1
    else
      echo "OK:      $rel"
    fi
  else
    mkdir -p "$MIRROR_DIR"
    cp "$src" "$dst"
    echo "Synced:  $rel"
  fi
done

if [[ "$found" -eq 0 ]]; then
  echo "ERROR: No .esm files found in $SOURCE_DIR" >&2
  exit 1
fi

# A file present in the mirror but absent from lib/ is drift too — it means a
# library file was deleted or renamed and the mirror kept the orphan.
if [[ "$check_mode" == true && -d "$MIRROR_DIR" ]]; then
  for dst in "$MIRROR_DIR"/*.esm; do
    [[ -e "$dst" ]] || continue
    name="$(basename "$dst")"
    if [[ ! -f "${SOURCE_DIR}/${name}" ]]; then
      echo "ORPHAN:  docs/static/lib/${name} (no lib/${name})"
      drifted=1
    fi
  done
fi

if [[ "$check_mode" == true ]]; then
  if [[ "$drifted" -eq 1 ]]; then
    echo
    echo "Drift detected. Fix it by running: scripts/sync-lib.sh"
    exit 1
  fi
  echo
  echo "Standard library mirror is in sync."
fi
