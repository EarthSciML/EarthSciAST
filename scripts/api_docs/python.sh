#!/usr/bin/env bash
# Python half of the generated API reference (docs/api/README.md §1).
#
#   scripts/api_docs/python.sh                  extract docs, then run examples
#   scripts/api_docs/python.sh --extract-only   write build/api-docs/python.json
#   scripts/api_docs/python.sh --examples-only  run docs/api/examples/python/*.py
#
# A virtual environment under build/api-docs/venv-python holds the pinned
# extractor and the in-repo package (editable, with the `simulate` extra so the
# simulation examples can solve). It is rebuilt when the package's
# pyproject.toml or the pinned griffe version changes.
#
# Environment:
#   PYTHON           interpreter used to create the venv (default: python3;
#                    needs >= 3.10, which griffe requires)
#   API_DOCS_VENV    venv location (default: build/api-docs/venv-python)
set -euo pipefail

GRIFFE_VERSION="2.3.2"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

mode="all"
case "${1:-}" in
  "") ;;
  --extract-only) mode="extract" ;;
  --examples-only) mode="examples" ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

mkdir -p build/api-docs build/tmp
export TMPDIR="${TMPDIR:-$ROOT/build/tmp}"

PYTHON="${PYTHON:-python3}"
VENV="${API_DOCS_VENV:-$ROOT/build/api-docs/venv-python}"
VPY="$VENV/bin/python"

stamp="griffe==$GRIFFE_VERSION $(sha256sum pkg/earthsci-ast-py/pyproject.toml | cut -d' ' -f1)"
if [[ ! -x "$VPY" || "$(cat "$VENV/.api-docs-stamp" 2>/dev/null)" != "$stamp" ]]; then
  echo "python.sh: creating $VENV" >&2
  "$PYTHON" -m venv --clear "$VENV"
  "$VPY" -m pip install --quiet --upgrade pip
  "$VPY" -m pip install --quiet "griffe==$GRIFFE_VERSION" -e "pkg/earthsci-ast-py[simulate]"
  echo "$stamp" > "$VENV/.api-docs-stamp"
fi

if [[ "$mode" != "examples" ]]; then
  "$VPY" scripts/api_docs/extract_python.py --repo-root "$ROOT" --output "$ROOT/build/api-docs/python.json"
fi

if [[ "$mode" != "extract" ]]; then
  # Run from a scratch directory so an example that found its fixtures through
  # the working directory, rather than its own location, fails here.
  rundir="$ROOT/build/api-docs/python-examples-run"
  rm -rf "$rundir"
  mkdir -p "$rundir"
  failed=()
  shopt -s nullglob
  examples=("$ROOT"/docs/api/examples/python/*.py)
  if [[ ${#examples[@]} -eq 0 ]]; then
    echo "python.sh: no examples under docs/api/examples/python" >&2
    exit 1
  fi
  for ex in "${examples[@]}"; do
    name="$(basename "$ex")"
    if (cd "$rundir" && "$VPY" -W "error::DeprecationWarning:__main__" "$ex") > "$rundir/${name%.py}.log" 2>&1; then
      echo "ok    $name"
    else
      echo "FAIL  $name"
      sed 's/^/      /' "$rundir/${name%.py}.log"
      failed+=("$name")
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "python.sh: ${#failed[@]} of ${#examples[@]} examples failed: ${failed[*]}" >&2
    exit 1
  fi
  echo "python.sh: all ${#examples[@]} examples passed"
fi
