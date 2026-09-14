#!/usr/bin/env bash
# Build the CUDA shared-library environment the CUDA-12 `xla_extension` needs
# at RUN time (pkg/earthsci-ast-rs, feature `xla`, EARTHSCI_XLA_PLATFORM=gpu).
#
# Why this exists
# ---------------
# `scripts/fetch-xla-extension.sh --variant cuda12` gives you
# `libxla_extension.so` built against CUDA 12. That library HARD-LINKS its CUDA
# dependencies -- they are DT_NEEDED entries, not `dlopen` calls -- so the
# dynamic loader must find every one of them before `main` runs, whether or not
# the program ever touches cuDNN or NCCL. A stock HPC node with only a driver
# and a CUDA toolkit does not provide them:
#
#   libcudnn.so.9 and its six companion libraries, libnccl.so.2,
#   libnvshmem_host.so.3 (plus its transport plugins), libcublas.so.12,
#   libcublasLt.so.12, libcudart.so.12, libnvrtc.so.12,
#   libnvrtc-builtins.so.12.9, libcufft.so.11, libcusparse.so.12,
#   libnvJitLink.so.12
#
# NVIDIA publishes all of them as Python wheels, which is the only packaging of
# these libraries that needs no root and no module system. So this script makes
# a throwaway virtualenv, installs the pinned wheels into it, and prints the
# two environment lines that point the loader and XLA at the result. The venv is
# a LIBRARY DIRECTORY that happens to be laid out by pip; nothing ever runs its
# Python.
#
# Three details that are not obvious and cost a day each if you miss them:
#
#  1. `ptxas`. XLA compiles GPU kernels to PTX and then needs `ptxas` to
#     assemble them. It does not come with the runtime wheels; it is in
#     `nvidia-cuda-nvcc-cu12`. Without `--xla_gpu_cuda_data_dir` pointing at
#     that wheel's directory EVERY GPU compilation fails with "No PTX
#     compilation provider is available". That is why this script prints an
#     `XLA_FLAGS` line as well as an `LD_LIBRARY_PATH` line.
#  2. The nvshmem transport plugin soname. The extension asks for
#     `nvshmem_transport_ibrc.so.3`; the wheel ships the plugins at ABI 6
#     (`...so.6`). For a single-node run the transport is never used, but the
#     loader still refuses to start without a file of that name, so this script
#     compiles a one-function stub shared object with that soname. A
#     MULTI-NODE nvshmem run would need the real transport and this stub would
#     be wrong -- see the warning it prints.
#  3. TMPDIR. `pip` unpacks multi-hundred-megabyte wheels through TMPDIR, and
#     on a RAM-backed /tmp that is an out-of-memory kill. The script forces
#     TMPDIR under the venv's own parent directory.
#
# Usage:
#   scripts/setup-xla-gpu-libs.sh --prefix <dir-outside-the-repo> [--python python3]
#                                 [--force] [--quiet]
#
#   --prefix  where to create the venv (required). Must be OUTSIDE this
#             repository and on real disk -- the wheels unpack to about 6 GB.
#   --python  interpreter to build the venv with (default: python3).
#   --force   recreate the venv even if it already looks complete.
#   --quiet   print only the export lines, so the output can be `eval`ed:
#               eval "$(scripts/setup-xla-gpu-libs.sh --prefix ... --quiet)"
#
# What it prints (and what you must export before running anything with
# EARTHSCI_XLA_PLATFORM=gpu):
#   export LD_LIBRARY_PATH=...   the extension's own lib/, then every wheel's
#                                nvidia/<pkg>/lib, then the stub directory
#   export XLA_FLAGS=--xla_gpu_cuda_data_dir=...   where ptxas lives
#   export XLA_EXTENSION_DIR=... (only if it is already set in your shell; the
#                                cuda12 tree itself comes from
#                                scripts/fetch-xla-extension.sh --variant cuda12)
set -euo pipefail

# Pinned wheels. These are the versions proven to load the CUDA-12
# xla_extension 0.10.0; bump them only together and only after a GPU run.
# Format: <pip requirement>
WHEELS=(
  "nvidia-cudnn-cu12==9.26.0.51"
  "nvidia-nccl-cu12==2.31.2"
  "nvidia-nvshmem-cu12==3.7.2"
  "nvidia-cublas-cu12==12.9.2.10"
  "nvidia-cuda-runtime-cu12==12.9.79"
  "nvidia-cuda-nvrtc-cu12==12.9.86"
  "nvidia-cufft-cu12==11.4.1.4"
  "nvidia-cusparse-cu12==12.5.10.65"
  "nvidia-nvjitlink-cu12==12.9.86"
  "nvidia-cuda-cccl-cu12==12.9.27"
  "nvidia-cuda-nvcc-cu12==12.9.86"
)
# The per-wheel lib directories, in the order they go on LD_LIBRARY_PATH.
LIBDIRS=(
  cublas cuda_cccl cuda_nvrtc cuda_runtime cudnn cufft cusparse nccl
  nvjitlink nvshmem
)

prefix=""
python_bin="python3"
force=0
quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="${2:?--prefix needs a value}"; shift 2 ;;
    --python) python_bin="${2:?--python needs a value}"; shift 2 ;;
    --force)  force=1; shift ;;
    --quiet)  quiet=1; shift ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
    *) echo "setup-xla-gpu-libs: unexpected argument $1" >&2; exit 2 ;;
  esac
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

if [ -z "$prefix" ]; then
  echo "setup-xla-gpu-libs: --prefix <dir> is required (a directory OUTSIDE the repository)" >&2
  exit 2
fi

# Refuse to build inside the checkout: this is ~6 GB of downloaded binary, the
# same reason fetch-xla-extension.sh refuses an in-repo --dest.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd -P)"
case "$prefix/" in
  "$repo_root"/*)
    echo "setup-xla-gpu-libs: --prefix must be OUTSIDE the repository ($repo_root)" >&2
    exit 2 ;;
esac

venv="$prefix/venv"
stubs="$prefix/stubs"
# pip through a RAM-backed /tmp is an OOM kill on these wheels; keep every
# temporary file beside the venv, on the same real filesystem.
export TMPDIR="$prefix/tmp"
mkdir -p "$TMPDIR" "$stubs"

site=""
find_site() {
  site="$(echo "$venv"/lib/python*/site-packages)"
  [ -d "$site" ]
}

if [ "$force" -eq 1 ]; then
  say "removing $venv"
  rm -rf "$venv"
fi

if find_site && [ -d "$site/nvidia/cudnn/lib" ] && [ -x "$site/nvidia/cuda_nvcc/bin/ptxas" ]; then
  say "reusing the venv already at $venv"
else
  say "creating a venv at $venv with $python_bin"
  "$python_bin" -m venv "$venv"
  say "installing the pinned NVIDIA wheels (about 6 GB; several minutes)"
  # --no-cache-dir: the wheel cache would double the footprint and pip's cache
  # directory is another thing that ends up on a small or RAM-backed volume.
  "$venv/bin/python" -m pip install --no-cache-dir --upgrade pip >/dev/null
  "$venv/bin/python" -m pip install --no-cache-dir "${WHEELS[@]}"
  find_site || { echo "setup-xla-gpu-libs: no site-packages under $venv" >&2; exit 1; }
fi

# The nvshmem transport-plugin stub. See note 3 in the header: the extension
# names ABI 3, the wheel ships ABI 6, and a single-node run never calls into
# the transport -- it only has to exist for the loader.
stub_so="$stubs/nvshmem_transport_ibrc.so.3"
if [ ! -f "$stub_so" ] || [ "$force" -eq 1 ]; then
  say "building the nvshmem transport stub at $stub_so"
  cat > "$stubs/stub.c" <<'STUB'
/* Placeholder for nvshmem_transport_ibrc.so.3.
 *
 * The CUDA-12 xla_extension lists this plugin soname as a hard dependency of
 * libnvshmem_host.so.3, but the nvshmem wheel ships its transports at ABI 6.
 * On a single node nvshmem never initializes a remote transport, so nothing
 * ever calls into this object -- it exists so the dynamic loader can resolve
 * the name. A multi-node nvshmem collective WOULD call in, and would then get
 * a plugin with no entry points; do not reuse this across nodes.
 */
void nvshmem_transport_ibrc_stub(void) {}
STUB
  ${CC:-cc} -shared -fPIC -Wl,-soname,nvshmem_transport_ibrc.so.3 \
    -o "$stub_so" "$stubs/stub.c"
fi

ld=""
for d in "${LIBDIRS[@]}"; do
  [ -d "$site/nvidia/$d/lib" ] || {
    echo "setup-xla-gpu-libs: expected $site/nvidia/$d/lib after install" >&2; exit 1; }
  ld="${ld:+$ld:}$site/nvidia/$d/lib"
done
ld="$ld:$stubs"
nvcc_dir="$site/nvidia/cuda_nvcc"
[ -x "$nvcc_dir/bin/ptxas" ] || {
  echo "setup-xla-gpu-libs: no ptxas at $nvcc_dir/bin/ptxas" >&2; exit 1; }

# The extension's own lib/ goes FIRST when we know where it is, so that
# libxla_extension.so resolves beside its siblings rather than against whatever
# else is on the path.
ext_lib=""
if [ -n "${XLA_EXTENSION_DIR:-}" ] && [ -d "${XLA_EXTENSION_DIR}/lib" ]; then
  ext_lib="${XLA_EXTENSION_DIR}/lib:"
fi

say ""
say "GPU library environment ready under $prefix."
say "Export these (together with the cuda12 XLA_EXTENSION_DIR from"
say "scripts/fetch-xla-extension.sh --variant cuda12) before any GPU run:"
say ""
if [ -n "${XLA_EXTENSION_DIR:-}" ]; then
  echo "export XLA_EXTENSION_DIR=${XLA_EXTENSION_DIR}"
else
  say "# export XLA_EXTENSION_DIR=<the cuda12 tree from fetch-xla-extension.sh>"
fi
echo "export LD_LIBRARY_PATH=${ext_lib}${ld}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
echo "export XLA_FLAGS=--xla_gpu_cuda_data_dir=${nvcc_dir}"
echo "export EARTHSCI_XLA_PLATFORM=gpu"
say ""
say "Also set TMPDIR to a real-disk directory in every batch job; XLA writes"
say "its compilation scratch there and a RAM-backed /tmp will be exhausted."
say "The nvshmem plugin at $stub_so is a SINGLE-NODE stub (see the file's"
say "comment); it is not valid for a multi-node nvshmem collective."
