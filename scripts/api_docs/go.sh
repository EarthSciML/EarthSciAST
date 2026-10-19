#!/usr/bin/env bash
# Go half of the generated API reference (docs/api/README.md §1).
#
#   scripts/api_docs/go.sh                  extract docstrings, then run examples
#   scripts/api_docs/go.sh --extract-only   write build/api-docs/go.json only
#   scripts/api_docs/go.sh --examples-only  run docs/api/examples/go only
#
# Needs only a Go toolchain (the version pkg/earthsci-ast-go/go.mod names, or
# newer). Works from any directory; all output goes under build/.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
extract=1
examples=1
case "${1:-}" in
  "") ;;
  --extract-only) examples=0 ;;
  --examples-only) extract=0 ;;
  *) echo "usage: $0 [--extract-only|--examples-only]" >&2; exit 2 ;;
esac

mkdir -p "$root/build/api-docs" "$root/build/tmp"
export TMPDIR="$root/build/tmp"
export GOTMPDIR="$TMPDIR"
tool="$root/scripts/api_docs/extract_go"

if [[ $extract == 1 ]]; then
  go -C "$tool" run . -root "$root" -out "$root/build/api-docs/go.json"
  echo "wrote build/api-docs/go.json"
fi

if [[ $examples == 1 ]]; then
  go -C "$tool" run . -root "$root" -check-examples "$root/docs/api/examples/go"
  ex="$root/docs/api/examples/go"
  go -C "$ex" vet ./...
  go -C "$ex" test -p 2 -count=1 ./...
fi
