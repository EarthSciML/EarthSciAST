#!/bin/bash
# native-coverage.sbatch — the native coverage census on a Slurm cluster.
#
# Runs scripts/native-coverage-census.sh for one or both bindings on one node
# and checks the result against tests/conformance/native_coverage/. Submit from
# the repository root; every path is taken from the environment so the same
# script serves any checkout:
#
#   sbatch --output=<logdir>/native-coverage-%j.out \
#          --export=ALL,NC_OUT=<dir>,NC_MODELS=../EarthSciModels,NC_BINDINGS=julia \
#          scripts/native-coverage.sbatch
#
#   NC_OUT        census output directory (required; keep it off RAM-backed /tmp)
#   NC_MODELS     the EarthSciModels checkout (default: ../EarthSciModels)
#   NC_BINDINGS   julia, rust, or julia,rust (default: julia,rust)
#   NC_JOBS       concurrent documents per sweep (default: 12)
#   NC_TIMEOUT    per-document wall clock, seconds (default: 300)
#   NC_MODE       check (default) or write-ledger (the baseline)
#
# A Julia sweep runs NC_JOBS two-threaded workers per compiler and both
# compilers at once, so it wants about 4 x NC_JOBS cores and several GB per
# worker. The Rust sweep builds the census example in release mode first, in
# CARGO_TARGET_DIR when that is set.
#
#SBATCH --job-name=native-coverage
#SBATCH --partition=secondary
#SBATCH --nodes=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=180G
#SBATCH --time=04:00:00

set -euo pipefail
: "${NC_OUT:?set NC_OUT to the census output directory}"
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "$REPO_ROOT"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-${SLURM_CPUS_PER_TASK:-16}}"

extra=()
[[ "${NC_MODE:-check}" == write-ledger ]] && extra+=(--write-ledger)

echo "[$(date)] $(hostname) native coverage census: bindings ${NC_BINDINGS:-julia,rust}, $(git rev-parse HEAD)"
./scripts/native-coverage-census.sh \
  --earthscimodels "${NC_MODELS:-../EarthSciModels}" \
  --out "$NC_OUT" \
  --bindings "${NC_BINDINGS:-julia,rust}" \
  --jobs "${NC_JOBS:-12}" \
  --timeout "${NC_TIMEOUT:-300}" \
  "${extra[@]}"
echo "[$(date)] done"
