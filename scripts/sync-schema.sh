#!/usr/bin/env bash
# sync-schema.sh — Copy root esm-schema.json to all language package locations
# and verify that binding package versions stay aligned.
#
# Usage:
#   scripts/sync-schema.sh          # Copy root schema to all packages
#   scripts/sync-schema.sh --check  # Check schema + version drift (exit 1 if any)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANONICAL="${REPO_ROOT}/esm-schema.json"

TARGETS=(
  "pkg/earthsci-ast-go/pkg/esm/esm-schema.json"
  "pkg/earthsci-ast-rs/src/esm-schema.json"
  "pkg/EarthSciAST.jl/data/esm-schema.json"
  "pkg/earthsci-ast-py/src/earthsci_ast/data/esm-schema.json"
)

# Binding manifests that must share a synchronized version string.
# Go (earthsci-ast-go) uses module-path versioning via git tags and is not listed.
VERSION_MANIFESTS=(
  "pkg/earthsci-ast-ts/package.json"
  "pkg/earthsci-ast-py/pyproject.toml"
  "pkg/earthsci-ast-rs/Cargo.toml"
  "pkg/EarthSciAST.jl/Project.toml"
)

if [[ ! -f "$CANONICAL" ]]; then
  echo "ERROR: Canonical schema not found: $CANONICAL" >&2
  exit 1
fi

check_mode=false
if [[ "${1:-}" == "--check" ]]; then
  check_mode=true
fi

drifted=0

for target in "${TARGETS[@]}"; do
  full_path="${REPO_ROOT}/${target}"
  if [[ "$check_mode" == true ]]; then
    if [[ ! -f "$full_path" ]]; then
      echo "MISSING: $target"
      drifted=1
    elif ! diff -q "$CANONICAL" "$full_path" > /dev/null 2>&1; then
      echo "DRIFT:   $target"
      drifted=1
    else
      echo "OK:      $target"
    fi
  else
    mkdir -p "$(dirname "$full_path")"
    cp "$CANONICAL" "$full_path"
    echo "Synced:  $target"
  fi
done

# ---------------------------------------------------------------------------
# TypeScript embedded schema (pkg/earthsci-ast-ts/src/embedded-schema.ts).
#
# The TS binding cannot read a JSON file at runtime (it must work in the
# browser), so it embeds the schema in a TypeScript module that Rollup bundles
# into the published artifact. To keep that embedded copy from silently drifting
# from the canonical schema, src/embedded-schema.ts is GENERATED verbatim from
# esm-schema.json by scripts/generate-embedded-schema.mjs.
#
# --check runs that generator in --check mode: a strict, byte-exact comparison
# over the FULL document (every $def), not a scoped subset. The generator uses
# only Node built-ins, so this runs in the schema-sync CI job with no npm
# install. Plain (non --check) mode regenerates the embedded module, mirroring
# the `cp` of the JSON copies above.
# ---------------------------------------------------------------------------
TS_EMBEDDED="pkg/earthsci-ast-ts/src/embedded-schema.ts"
TS_GENERATOR="${REPO_ROOT}/pkg/earthsci-ast-ts/scripts/generate-embedded-schema.mjs"
if [[ ! -f "$TS_GENERATOR" ]]; then
  echo "MISSING: $TS_EMBEDDED generator (pkg/earthsci-ast-ts/scripts/generate-embedded-schema.mjs)"
  drifted=1
elif [[ "$check_mode" == true ]]; then
  if ts_result=$(node "$TS_GENERATOR" --check 2>&1); then
    echo "OK:      $TS_EMBEDDED (full-document, generated from esm-schema.json)"
  else
    echo "DRIFT:   $TS_EMBEDDED"
    echo "         ${ts_result}"
    echo "         Regenerate with: cd pkg/earthsci-ast-ts && npm run generate-schema"
    drifted=1
  fi
else
  node "$TS_GENERATOR" >/dev/null && echo "Synced:  $TS_EMBEDDED (regenerated from esm-schema.json)"
fi

# Extract the version field from a binding manifest.
# Emits "<file>: <version>" to stdout.
read_version() {
  local manifest="$1"
  local full_path="${REPO_ROOT}/${manifest}"
  local version=""
  case "$manifest" in
    *package.json)
      version=$(python3 -c "import json,sys; print(json.load(open('$full_path'))['version'])")
      ;;
    *pyproject.toml|*Cargo.toml|*Project.toml)
      version=$(grep -m1 -E '^version\s*=' "$full_path" | sed -E 's/^version\s*=\s*"([^"]+)".*/\1/')
      ;;
  esac
  printf '%s' "$version"
}

if [[ "$check_mode" == true ]]; then
  echo ""
  echo "Binding versions:"
  declare -A seen
  for manifest in "${VERSION_MANIFESTS[@]}"; do
    full_path="${REPO_ROOT}/${manifest}"
    if [[ ! -f "$full_path" ]]; then
      echo "MISSING: $manifest"
      drifted=1
      continue
    fi
    v=$(read_version "$manifest")
    if [[ -z "$v" ]]; then
      echo "UNPARSED: $manifest"
      drifted=1
      continue
    fi
    printf '  %-60s %s\n' "$manifest" "$v"
    seen["$v"]=1
  done
  if [[ "${#seen[@]}" -gt 1 ]]; then
    echo "VERSION DRIFT: bindings disagree on version (${!seen[*]})"
    drifted=1
  fi
fi

if [[ "$check_mode" == true && "$drifted" -ne 0 ]]; then
  echo ""
  echo "Drift detected. Fix schema drift by running: scripts/sync-schema.sh"
  echo "Fix version drift by editing the listed manifests to agree."
  exit 1
fi
