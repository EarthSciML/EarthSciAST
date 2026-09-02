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

# ---------------------------------------------------------------------------
# pkg/earthsci-ast-ts/src/generated-validator.js
#
# NOTE (why a SKIP is a FAILURE in --check mode). Both TS artifacts below need
# `npm install` to verify. This gate used to SKIP them when node_modules was
# absent WITHOUT setting `drifted`, so `--check` exited 0 on a tree where they
# had drifted -- and that is exactly how the `element_type` schema change
# (0bbe8957b) shipped with a stale `generated-validator.js` AND a stale
# `generated.ts`: whoever ran this script ran it without node_modules, saw the
# four JSON copies and `embedded-schema.ts` reported OK (that one needs no
# dependencies), and got exit 0.
#
# `scripts/test-conformance.sh` already learned this lesson -- see
# `check_language_availability`, audit F10: "There is no way to express 'I
# could not check this' in an exit code, so the only honest answer is failure."
# A missing toolchain there is a broken environment, not a smaller test run.
# Same here: a check that did not run has not passed.
#
# Non-check mode still just skips, because regenerating what you cannot
# regenerate is not a thing to fail over.
# ---------------------------------------------------------------------------
# The schema, precompiled by Ajv into a standalone validator so that validating
# a document needs no runtime code generation (and therefore no 'unsafe-eval' in
# a consumer's Content-Security-Policy). Another generated copy of the schema,
# so another thing that can fall behind it.
#
# Unlike the embedded schema above, this generator NEEDS node_modules — it runs
# Ajv to do the compiling. This gate is documented to work without an npm
# install, so the check is skipped when the dependency is absent, and says so
# rather than passing quietly. The authoritative check is the drift test in
# pkg/earthsci-ast-ts/src/generated-validator.test.ts, which runs where the
# dependencies exist.
TS_VALIDATOR="pkg/earthsci-ast-ts/src/generated-validator.js"
TS_VGEN="${REPO_ROOT}/pkg/earthsci-ast-ts/scripts/generate-standalone-validator.mjs"
if [[ ! -f "$TS_VGEN" ]]; then
  echo "MISSING: $TS_VALIDATOR generator"
  drifted=1
elif [[ ! -d "${REPO_ROOT}/pkg/earthsci-ast-ts/node_modules/ajv" ]]; then
  echo "SKIP:    $TS_VALIDATOR (needs pkg/earthsci-ast-ts npm install)"
  if [[ "$check_mode" == true ]]; then
    echo "         --check cannot verify this artifact without node_modules, and a"
    echo "         check that did not run has not passed. Run: (cd pkg/earthsci-ast-ts && npm install)"
    drifted=1
  fi
elif [[ "$check_mode" == true ]]; then
  if v_result=$(node "$TS_VGEN" --check 2>&1); then
    echo "OK:      $TS_VALIDATOR (precompiled from esm-schema.json)"
  else
    echo "DRIFT:   $TS_VALIDATOR"
    echo "         ${v_result}"
    echo "         Regenerate with: cd pkg/earthsci-ast-ts && npm run generate-validator"
    drifted=1
  fi
else
  node "$TS_VGEN" >/dev/null && echo "Synced:  $TS_VALIDATOR (recompiled from esm-schema.json)"
fi

# ---------------------------------------------------------------------------
# pkg/earthsci-ast-ts/src/generated.ts
# ---------------------------------------------------------------------------
# The THIRD generated copy of the schema in the TypeScript binding, and until
# now the only one this gate did not cover. `embedded-schema.ts` and
# `generated-validator.js` were both checked above; the TypeScript TYPES that
# every consumer of `@earthsciml/ast` compiles against were not — and they had
# silently drifted, still declaring a component kind the format removed at
# 1.0.0. A generated artifact nothing compares against is a copy of the schema
# as it was on the day someone last remembered to run the generator.
#
# The generator is `npm run generate-types`: json2ts, then
# scripts/fix-generated-expression.mjs, which repairs json2ts's degenerate
# inlining of `Expression` IN PLACE. Because that repair rewrites the real file,
# a byte-exact check regenerates over the working copy and RESTORES it, whatever
# the outcome — the snapshot is taken first and put back by an EXIT trap, so an
# interrupted run cannot leave a regenerated file behind.
#
# Like the validator above, this needs node_modules (json2ts is a dev
# dependency), so it SKIPS loudly rather than passing quietly when absent.
TS_TYPES="pkg/earthsci-ast-ts/src/generated.ts"
TS_DIR="${REPO_ROOT}/pkg/earthsci-ast-ts"
if [[ ! -f "${REPO_ROOT}/${TS_TYPES}" ]]; then
  echo "MISSING: $TS_TYPES"
  drifted=1
elif [[ ! -x "${TS_DIR}/node_modules/.bin/json2ts" ]]; then
  echo "SKIP:    $TS_TYPES (needs pkg/earthsci-ast-ts npm install: json2ts is a dev dependency)"
  if [[ "$check_mode" == true ]]; then
    echo "         --check cannot verify this artifact without node_modules, and a"
    echo "         check that did not run has not passed. Run: (cd pkg/earthsci-ast-ts && npm install)"
    drifted=1
  fi
elif [[ "$check_mode" == true ]]; then
  ts_types_snapshot="$(mktemp)"
  cp "${REPO_ROOT}/${TS_TYPES}" "$ts_types_snapshot"
  # Restore unconditionally: the generator writes over the working copy, and a
  # --check must never be the reason a file changed.
  trap 'cp "$ts_types_snapshot" "${REPO_ROOT}/${TS_TYPES}"; rm -f "$ts_types_snapshot"' EXIT
  if types_result=$( (cd "$TS_DIR" && npm run --silent generate-types) 2>&1 ); then
    if diff -q "$ts_types_snapshot" "${REPO_ROOT}/${TS_TYPES}" > /dev/null 2>&1; then
      echo "OK:      $TS_TYPES (generated from esm-schema.json)"
    else
      echo "DRIFT:   $TS_TYPES"
      echo "         Regenerate with: cd pkg/earthsci-ast-ts && npm run generate-types"
      drifted=1
    fi
  else
    echo "DRIFT:   $TS_TYPES (generator failed)"
    echo "         ${types_result}"
    drifted=1
  fi
  cp "$ts_types_snapshot" "${REPO_ROOT}/${TS_TYPES}"
  rm -f "$ts_types_snapshot"
  trap - EXIT
else
  (cd "$TS_DIR" && npm run --silent generate-types >/dev/null) \
    && echo "Synced:  $TS_TYPES (regenerated from esm-schema.json)"
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
