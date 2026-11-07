#!/usr/bin/env bash
# sync-lib.sh — Copy the standard library (lib/*.esm) into every place that
# ships it, and verify no copy has drifted.
#
# Usage:
#   scripts/sync-lib.sh          # Copy lib/*.esm into every mirror
#   scripts/sync-lib.sh --check  # Fail (exit 1) if any copy has drifted
#
# WHY THIS EXISTS. `lib/*.esm` is the SHIPPED standard library — real code that
# users mount or import through a §4.7 `ref`, not test fixtures. `lib/` is the
# one source of truth; every other copy is written from it by this script:
#
#   docs/static/lib/                           the documentation site's stable URL
#   pkg/EarthSciAST.jl/data/lib/               Julia, read via pkgdir
#   pkg/earthsci-ast-py/src/earthsci_ast/data/lib/   Python package data
#   pkg/earthsci-ast-rs/src/stdlib/            Rust, include_str! (build.rs lists them)
#   pkg/earthsci-ast-go/pkg/esm/stdlib/        Go, go:embed
#   pkg/earthsci-ast-ts/src/stdlib-bundle.ts   TypeScript, a generated module
#
# The package copies are what an `esm:std/<file>.esm` ref resolves to
# (esm-spec §4.7): each binding must carry the library inside its own published
# artifact, because an installed package cannot reach the repository's lib/.
# Without the --check gate a binding could ship a stale library indefinitely
# and no test would notice (audit 2026-07-14 found exactly that for the docs
# copy).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/lib"
MIRRORS=(
  "docs/static/lib"
  "pkg/EarthSciAST.jl/data/lib"
  "pkg/earthsci-ast-py/src/earthsci_ast/data/lib"
  "pkg/earthsci-ast-rs/src/stdlib"
  "pkg/earthsci-ast-go/pkg/esm/stdlib"
)
TS_BUNDLE="pkg/earthsci-ast-ts/src/stdlib-bundle.ts"
TS_GENERATOR="${REPO_ROOT}/pkg/earthsci-ast-ts/scripts/generate-stdlib-bundle.mjs"

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
  for mirror in "${MIRRORS[@]}"; do
    dst="${REPO_ROOT}/${mirror}/${name}"
    rel="${mirror}/${name}"

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
      mkdir -p "${REPO_ROOT}/${mirror}"
      cp "$src" "$dst"
      echo "Synced:  $rel"
    fi
  done
done

if [[ "$found" -eq 0 ]]; then
  echo "ERROR: No .esm files found in $SOURCE_DIR" >&2
  exit 1
fi

# A file present in a mirror but absent from lib/ is drift too — it means a
# library file was deleted or renamed and the mirror kept the orphan. In copy
# mode the orphan is removed, so a rename never leaves a binding shipping a
# library file that no longer exists.
for mirror in "${MIRRORS[@]}"; do
  [[ -d "${REPO_ROOT}/${mirror}" ]] || continue
  for dst in "${REPO_ROOT}/${mirror}"/*.esm; do
    [[ -e "$dst" ]] || continue
    name="$(basename "$dst")"
    if [[ ! -f "${SOURCE_DIR}/${name}" ]]; then
      if [[ "$check_mode" == true ]]; then
        echo "ORPHAN:  ${mirror}/${name} (no lib/${name})"
        drifted=1
      else
        rm "$dst"
        echo "Removed: ${mirror}/${name} (no lib/${name})"
      fi
    fi
  done
done

# The TypeScript binding embeds the library as a generated module (it also runs
# in the browser, with no filesystem). Its generator needs only node.
if [[ "$check_mode" == true ]]; then
  if ts_result=$(node "$TS_GENERATOR" --check 2>&1); then
    echo "OK:      $TS_BUNDLE"
  else
    echo "DRIFT:   $TS_BUNDLE"
    echo "         ${ts_result}"
    drifted=1
  fi
else
  node "$TS_GENERATOR" > /dev/null
  echo "Synced:  $TS_BUNDLE"
fi

if [[ "$check_mode" == true ]]; then
  if [[ "$drifted" -eq 1 ]]; then
    echo
    echo "Drift detected. Fix it by running: scripts/sync-lib.sh"
    exit 1
  fi
  echo
  echo "Every standard library copy is in sync."
fi
