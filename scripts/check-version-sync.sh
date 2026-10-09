#!/usr/bin/env bash
# Every binding ships under ONE version number, and seven files carry it.
#
# Four are the package manifests the release pipeline reads. Two more are
# hand-maintained mirrors that no manifest can derive:
#
#   * TypeScript cannot import package.json (tsconfig `rootDir` is ./src, and a
#     runtime read would break browser hosts), so `LIBRARY_VERSION` is mirrored.
#   * A Go module has no in-tree version manifest at all -- its version is the
#     git tag the proxy resolves -- so `LibraryVersion` is maintained by hand.
#
# v0.2.0 shipped with both mirrors still reading 0.1.1. TypeScript's own
# version.test.ts caught the drift, but only after the package had published;
# Go had no guard whatsoever. This runs in lint, before anything is published.
#
# The seventh is pkg/earthsci-ast-rs/Cargo.lock, which records the crate's own
# version. v0.3.0 bumped Cargo.toml and left the lock at 0.2.0, so the release
# job's `cargo build` rewrote it, and `cargo publish` refused the dirty tree:
# every other registry got 0.3.0 and crates.io did not.
set -euo pipefail

cd "$(dirname "$0")/.."

jl=$(grep -m1 '^version = ' pkg/EarthSciAST.jl/Project.toml | sed 's/.*"\(.*\)".*/\1/')
py=$(grep -m1 '^version = ' pkg/earthsci-ast-py/pyproject.toml | sed 's/.*"\(.*\)".*/\1/')
rs=$(grep -m1 '^version = ' pkg/earthsci-ast-rs/Cargo.toml | sed 's/.*"\(.*\)".*/\1/')
ts=$(node -p "require('./pkg/earthsci-ast-ts/package.json').version")
ts_const=$(sed -n "s/^export const LIBRARY_VERSION = '\(.*\)'$/\1/p" pkg/earthsci-ast-ts/src/version.ts)
go_const=$(sed -n 's/^const LibraryVersion = "\(.*\)"$/\1/p' pkg/earthsci-ast-go/pkg/esm/version.go)
rs_lock=$(awk '/^name = "earthsci-ast"$/ { getline; gsub(/^version = "|"$/, ""); print; exit }' pkg/earthsci-ast-rs/Cargo.lock)

status=0
for pair in \
  "pkg/earthsci-ast-py/pyproject.toml:$py" \
  "pkg/earthsci-ast-rs/Cargo.toml:$rs" \
  "pkg/earthsci-ast-rs/Cargo.lock (earthsci-ast):$rs_lock" \
  "pkg/earthsci-ast-ts/package.json:$ts" \
  "pkg/earthsci-ast-ts/src/version.ts (LIBRARY_VERSION):$ts_const" \
  "pkg/earthsci-ast-go/pkg/esm/version.go (LibraryVersion):$go_const"
do
  file=${pair%:*}; got=${pair##*:}
  if [ "$got" != "$jl" ]; then
    echo "::error file=${file%% *}::version is '$got', expected '$jl'"
    echo "  $file: $got  (expected $jl)"
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo
  echo "All seven version sites must agree. Source of truth:"
  echo "  pkg/EarthSciAST.jl/Project.toml = $jl"
  echo "See RELEASING.md, 'Cutting a release'."
  exit 1
fi

echo "All seven version sites agree on $jl"
