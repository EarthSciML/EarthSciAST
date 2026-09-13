#!/usr/bin/env bash
# Fetch and unpack the prebuilt `xla_extension` release the Rust crate's `xla`
# feature links against (pkg/earthsci-ast-rs, feature `xla`).
#
# The binary is NEVER vendored into this repository: it is 144 MB (CPU) /
# 259 MB (CUDA 12) of prebuilt shared library and headers. This script
# downloads the PINNED release, checks it against a SHA-256 recorded below,
# unpacks it into a directory the caller chooses OUTSIDE the repository, and
# prints the `export XLA_EXTENSION_DIR=…` line to paste.
#
# Usage:
#   scripts/fetch-xla-extension.sh [--variant cpu|cuda12] [--dest <dir>]
#                                  [--cache <dir>] [--force]
#
#   --variant  cpu (default) or cuda12
#   --dest     where to unpack; default "$HOME/.cache/earthsci/xla"
#   --cache    where to keep the downloaded archive; default "<dest>/download"
#   --force    re-download and re-unpack even if the target already exists
#
# The unpacked tree is <dest>/xla_extension-<version>-<variant>/xla_extension,
# which is the value XLA_EXTENSION_DIR must hold (its `lib/` and `include/`
# subdirectories are what the `xla` crate's build script consumes).
set -euo pipefail

VERSION="0.10.0"
PLATFORM="x86_64-linux-gnu"
BASE_URL="https://github.com/elixir-nx/xla/releases/download/v${VERSION}"

# SHA-256 of the two pinned archives. Recorded from the files downloaded on
# 2026-09-12 (`sha256sum xla_extension-0.10.0-x86_64-linux-gnu-*.tar.gz`).
# Bump VERSION and BOTH checksums together, never one alone.
SHA256_cpu="d5a1f138af13795c48c245561dcb76e1007afe5237baad5c828a704de619fc1d"
SHA256_cuda12="f3941f1317e38a8b1c8bf36f603b17e060a7bc4c0f22bce8f548c93fd17ae3bc"

variant="cpu"
dest="${HOME}/.cache/earthsci/xla"
cache=""
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) variant="${2:?--variant needs a value}"; shift 2 ;;
    --dest)    dest="${2:?--dest needs a value}"; shift 2 ;;
    --cache)   cache="${2:?--cache needs a value}"; shift 2 ;;
    --force)   force=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "fetch-xla-extension: unexpected argument $1" >&2; exit 2 ;;
  esac
done

case "$variant" in
  cpu)    expected="$SHA256_cpu" ;;
  cuda12) expected="$SHA256_cuda12" ;;
  *) echo "fetch-xla-extension: unknown --variant $variant (want cpu|cuda12)" >&2; exit 2 ;;
esac

archive="xla_extension-${VERSION}-${PLATFORM}-${variant}.tar.gz"
url="${BASE_URL}/${archive}"
[ -n "$cache" ] || cache="${dest}/download"
target="${dest}/xla_extension-${VERSION}-${variant}"

# Refuse to unpack inside the repository: the tree is a build input, not a
# source artifact, and a stray 144 MB directory under a checkout is exactly
# what "never vendor the binary" is about.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$dest"
dest_abs="$(cd "$dest" && pwd -P)"
case "$dest_abs/" in
  "$repo_root"/*) echo "fetch-xla-extension: --dest must be OUTSIDE the repository ($repo_root)" >&2; exit 2 ;;
esac

if [ -d "${target}/xla_extension/lib" ] && [ "$force" -eq 0 ]; then
  echo "already unpacked: ${target}/xla_extension"
else
  mkdir -p "$cache"
  if [ ! -f "${cache}/${archive}" ] || [ "$force" -eq 1 ]; then
    echo "downloading ${url}"
    curl --fail --location --progress-bar --output "${cache}/${archive}.part" "$url"
    mv "${cache}/${archive}.part" "${cache}/${archive}"
  else
    echo "using cached ${cache}/${archive}"
  fi

  echo "verifying sha256"
  got="$(sha256sum "${cache}/${archive}" | cut -d' ' -f1)"
  if [ "$got" != "$expected" ]; then
    echo "fetch-xla-extension: SHA-256 MISMATCH for ${archive}" >&2
    echo "  expected ${expected}" >&2
    echo "  got      ${got}" >&2
    echo "  refusing to unpack; delete ${cache}/${archive} and retry" >&2
    exit 1
  fi

  echo "unpacking into ${target}"
  rm -rf "$target"
  mkdir -p "$target"
  tar -xzf "${cache}/${archive}" -C "$target"
fi

if [ ! -d "${target}/xla_extension/lib" ]; then
  echo "fetch-xla-extension: ${target}/xla_extension/lib is missing after unpack" >&2
  exit 1
fi

cat <<MSG

xla_extension ${VERSION} (${variant}) ready. Export this before building or
running anything with the Rust crate's \`xla\` feature:

  export XLA_EXTENSION_DIR=${target}/xla_extension

Build:  cargo build --manifest-path pkg/earthsci-ast-rs/Cargo.toml --features xla
MSG
