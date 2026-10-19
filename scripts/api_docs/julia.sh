#!/usr/bin/env bash
# Julia half of the generated API reference (docs/api/README.md §1).
#
#   scripts/api_docs/julia.sh                  extract docstrings, then run the examples
#   scripts/api_docs/julia.sh --extract-only   write build/api-docs/julia.json only
#   scripts/api_docs/julia.sh --examples-only  run docs/api/examples/julia/*.jl only
#
# Both halves use the environment in docs/api/examples/julia/, which dev-links
# the in-repo package through `[sources]` (so Julia >= 1.11 is required).
# Set JULIA to choose the executable; JULIA_THREADS (default 2) sets --threads.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="$REPO_ROOT/docs/api/examples/julia"
OUT_DIR="$REPO_ROOT/build/api-docs"
JULIA="${JULIA:-julia}"
JULIA_FLAGS=(--startup-file=no --threads="${JULIA_THREADS:-2}" --project="$ENV_DIR")

do_extract=1
do_examples=1
case "${1:-}" in
  "") ;;
  --extract-only) do_examples=0 ;;
  --examples-only) do_extract=0 ;;
  *) echo "usage: $0 [--extract-only | --examples-only]" >&2; exit 2 ;;
esac

mkdir -p "$OUT_DIR"

echo "==> instantiating $ENV_DIR"
"$JULIA" "${JULIA_FLAGS[@]}" -e 'using Pkg; Pkg.instantiate()'

if [[ $do_extract == 1 ]]; then
  echo "==> extracting Julia docstrings"
  "$JULIA" "${JULIA_FLAGS[@]}" "$REPO_ROOT/scripts/api_docs/extract_julia.jl" \
    "$OUT_DIR/julia.json"
fi

if [[ $do_examples == 1 ]]; then
  echo "==> running Julia examples"
  (cd "$REPO_ROOT" && "$JULIA" "${JULIA_FLAGS[@]}" \
    "$REPO_ROOT/scripts/api_docs/run_julia_examples.jl")
fi
