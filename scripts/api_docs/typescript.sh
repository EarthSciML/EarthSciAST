#!/usr/bin/env bash
# API reference, TypeScript binding (docs/api/README.md §1):
#   1. extract docs for every TypeScript spelling in api-surface.json
#      -> build/api-docs/typescript.json
#   2. check the example region markers (regions.py), then type-check and run
#      every example in docs/api/examples/typescript/
#
# Usage: scripts/api_docs/typescript.sh [--extract-only | --examples-only]
# Needs Node >= 22.6 (examples run with Node's TypeScript type stripping).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$ROOT/pkg/earthsci-ast-ts"
mode="all"
case "${1:-}" in
  --extract-only) mode="extract" ;;
  --examples-only) mode="examples" ;;
  "") ;;
  *) echo "usage: $0 [--extract-only | --examples-only]" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/build/api-docs" "$ROOT/build/tmp"
export TMPDIR="$ROOT/build/tmp"

node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=6)?0:1)' || {
  echo "typescript.sh: Node >= 22.6 required (found $(node --version))" >&2; exit 1; }

if [ ! -d "$PKG/node_modules" ]; then
  (cd "$PKG" && npm ci --no-audit --no-fund)
fi

if [ "$mode" != "examples" ]; then
  node "$ROOT/scripts/api_docs/typescript_extract.mjs" "$ROOT" "$ROOT/build/api-docs/typescript.json"
fi

if [ "$mode" != "extract" ]; then
  # The examples import the built package; rebuild when the build is missing
  # or older than any source file.
  dist="$PKG/dist/esm/index.js"
  if [ ! -f "$dist" ] || [ -n "$(find "$PKG/src" "$PKG/package.json" -newer "$dist" -print -quit)" ]; then
    (cd "$PKG" && npm run --silent build >"$ROOT/build/api-docs/typescript-build.log" 2>&1) || {
      cat "$ROOT/build/api-docs/typescript-build.log" >&2; exit 1; }
  fi
  python3 "$ROOT/scripts/api_docs/regions.py" --root "$ROOT" --binding typescript >/dev/null
  node "$ROOT/scripts/api_docs/typescript_examples.mjs" "$ROOT"
fi
