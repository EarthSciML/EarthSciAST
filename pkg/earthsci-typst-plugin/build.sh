#!/usr/bin/env bash
# Build the Typst plugin and install it next to the Typst package.
#
# A Typst host resolves only the two `typst_env` protocol imports; any other
# import (wasm-bindgen's `__wbindgen_*`, WASI) makes `plugin()` fail to load
# the module. A new dependency can reintroduce one silently, so this script
# refuses to install a module that imports anything else.
set -euo pipefail
cd "$(dirname "$0")"

cargo build --release
wasm=target/wasm32-unknown-unknown/release/earthsci_typst_plugin.wasm

if command -v wasm-objdump >/dev/null; then
  foreign=$(wasm-objdump -x -j Import "$wasm" | grep -- ' <- ' | grep -v ' <- typst_env\.' || true)
  if [[ -n "$foreign" ]]; then
    echo "error: the plugin imports functions a Typst host does not provide:" >&2
    echo "$foreign" >&2
    exit 1
  fi
else
  echo "warning: wasm-objdump (wabt) not found; skipping the import check" >&2
fi

dest=../../typst/earthsci-spike/earthsci.wasm
cp "$wasm" "$dest"
echo "installed $dest ($(wc -c <"$dest" | tr -d ' ') bytes)"
