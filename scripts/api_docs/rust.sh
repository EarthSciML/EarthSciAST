#!/usr/bin/env bash
# API reference, Rust half (docs/api/README.md §1):
#   1. extract docs for every Rust spelling in api-surface.json from rustdoc's
#      JSON output -> build/api-docs/rust.json
#   2. build and run every example program in docs/api/examples/rust/
#
# Usage: scripts/api_docs/rust.sh [--extract-only | --examples-only]
#
# Rustdoc's JSON output is a nightly-only flag. The toolchain that runs it is
# $RUSTDOC_TOOLCHAIN, default the pinned nightly below; CI installs exactly
# that one. Locally, when the pinned nightly is not installed and
# RUSTDOC_TOOLCHAIN is unset, the script falls back to the default stable
# toolchain with RUSTC_BOOTSTRAP=1, which unlocks the same flag.
#
# The examples build with the default toolchain, or $EXAMPLES_TOOLCHAIN.
#
# All build output (cargo target dirs, temporary files) goes under build/.
set -euo pipefail

PINNED_NIGHTLY="nightly-2026-10-01"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

mode=all
case "${1:-}" in
    "") ;;
    --extract-only) mode=extract ;;
    --examples-only) mode=examples ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--extract-only | --examples-only]" >&2; exit 2 ;;
esac

BUILD="$ROOT/build"
mkdir -p "$BUILD/api-docs" "$BUILD/tmp"
export TMPDIR="$BUILD/tmp"
export CARGO_INCREMENTAL=0

have_toolchain() {
    command -v rustup >/dev/null 2>&1 && rustup run "$1" rustc --version >/dev/null 2>&1
}

# `cargo` with an optional `+toolchain`, as an array so an empty one vanishes.
cargo_cmd() {
    if [[ -n "$1" ]]; then
        echo "cargo +$1"
    else
        echo "cargo"
    fi
}

extract() {
    local tc="${RUSTDOC_TOOLCHAIN:-$PINNED_NIGHTLY}"
    local bootstrap=0
    if ! have_toolchain "$tc"; then
        if [[ -n "${RUSTDOC_TOOLCHAIN:-}" ]]; then
            echo "rust.sh: toolchain '$tc' is not installed (rustup toolchain install $tc --profile minimal)" >&2
            exit 1
        fi
        echo "rust.sh: $PINNED_NIGHTLY is not installed; using the default toolchain with RUSTC_BOOTSTRAP=1" >&2
        tc=""
        bootstrap=1
    elif [[ "$tc" != nightly* ]]; then
        bootstrap=1
    fi

    local cargo rustdoc_version
    cargo="$(cargo_cmd "$tc")"
    if [[ -n "$tc" ]]; then
        rustdoc_version="$(rustup run "$tc" rustdoc --version)"
    else
        rustdoc_version="$(rustdoc --version)"
    fi
    echo "rust.sh: extracting with $rustdoc_version" >&2

    local target="$BUILD/api-docs/rust-rustdoc-target"
    # `parallel` and `custom_alloc` gate three root exports in the manifest;
    # building with them documents every listed spelling.
    if [[ "$bootstrap" == 1 ]]; then export RUSTC_BOOTSTRAP=1; fi
    CARGO_TARGET_DIR="$target" $cargo rustdoc \
        --manifest-path pkg/earthsci-ast-rs/Cargo.toml \
        --lib --locked --features parallel,custom_alloc \
        -- -Z unstable-options --output-format json
    unset RUSTC_BOOTSTRAP

    local note=""
    if [[ "$bootstrap" == 1 ]]; then note=", RUSTC_BOOTSTRAP=1"; fi
    python3 scripts/api_docs/rust_extract.py \
        --rustdoc-json "$target/doc/earthsci_ast.json" \
        --manifest api-surface.json \
        --cargo-toml pkg/earthsci-ast-rs/Cargo.toml \
        --extractor "rustdoc JSON ($rustdoc_version$note)" \
        --out "$BUILD/api-docs/rust.json"
}

examples() {
    local dir="docs/api/examples/rust"
    local cargo
    cargo="$(cargo_cmd "${EXAMPLES_TOOLCHAIN:-}")"
    local target="$BUILD/api-docs/rust-examples-target"

    # Every program in the directory must be declared as an [[example]], or
    # it would silently never run.
    local declared names=() missing=0
    declared="$(sed -n 's/^path = "\(.*\.rs\)"$/\1/p' "$dir/Cargo.toml")"
    for f in "$dir"/*.rs; do
        local base
        base="$(basename "$f")"
        [[ "$base" == support.rs ]] && continue
        if ! grep -qx "$base" <<<"$declared"; then
            echo "rust.sh: $dir/$base is not declared as an [[example]] in $dir/Cargo.toml" >&2
            missing=1
        fi
        names+=("${base%.rs}")
    done
    [[ "$missing" == 0 ]] || exit 1

    CARGO_TARGET_DIR="$target" $cargo build --manifest-path "$dir/Cargo.toml" --examples --locked

    # Run from an unrelated directory: the examples find their fixtures
    # relative to their own source, never the working directory.
    local failed=()
    for name in "${names[@]}"; do
        echo "--- example: $name" >&2
        if ! (cd "$TMPDIR" && "$target/debug/examples/$name"); then
            failed+=("$name")
        fi
    done
    if (( ${#failed[@]} )); then
        echo "rust.sh: ${#failed[@]} of ${#names[@]} examples failed: ${failed[*]}" >&2
        exit 1
    fi
    echo "rust.sh: all ${#names[@]} examples passed" >&2
}

if [[ "$mode" != examples ]]; then extract; fi
if [[ "$mode" != extract ]]; then examples; fi
