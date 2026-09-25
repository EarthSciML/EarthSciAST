#!/bin/bash
# The scaling tier's full sweep on Slurm (README.md): every family at every
# ladder size, serial and threaded, one exclusive job per (family, thread
# mode), then one job that applies every gate and the ledger to the results.
#
#   SCALING_BUILD=/scratch/$USER/scaling tests/conformance/scaling/sweep.sh
#
# Environment:
#   SCALING_BUILD       scratch directory for documents, results and logs (required;
#                       the 10^6 documents and runs need real disk, not a RAM-backed /tmp)
#   SCALING_PARTITION   Slurm partition (default: secondary)
#   SCALING_THREADS     thread count of the threaded run (default: 16)
#   SCALING_FAMILIES    space-separated families (default: every family in manifest.json)
#   SCALING_TIMEOUT_S   per-document timeout inside a job (default: 1200)
#   SCALING_TIME        wall-clock limit of each job (default: 01:30:00; a short limit
#                       backfills sooner, and results are written after every document)
#   CARGO_TARGET_DIR    where the adapter is built (default: the crate's target/)
#
# The adapter is built once here, in release, and copied into SCALING_BUILD,
# so a rebuild while the sweep runs does not change what it measures. Timings
# want a clean machine, hence --exclusive.
set -euo pipefail

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
TIER=$REPO/tests/conformance/scaling
: "${SCALING_BUILD:?set SCALING_BUILD to a scratch directory}"
PARTITION=${SCALING_PARTITION:-secondary}
THREADS=${SCALING_THREADS:-16}
TIMEOUT_S=${SCALING_TIMEOUT_S:-1200}
WALL=${SCALING_TIME:-01:30:00}
FAMILIES=${SCALING_FAMILIES:-$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['families']))" "$TIER/manifest.json")}

mkdir -p "$SCALING_BUILD"/{docs,results,logs}
(cd "$REPO/pkg/earthsci-ast-rs" &&
    cargo build --release --features conformance-adapters,parallel --bin earthsci-scaling-adapter-rust)
TARGET=${CARGO_TARGET_DIR:-$REPO/pkg/earthsci-ast-rs/target}
BIN=$SCALING_BUILD/earthsci-scaling-adapter-rust
cp "$TARGET/release/earthsci-scaling-adapter-rust" "$BIN"
git -C "$REPO" rev-parse HEAD > "$SCALING_BUILD/commit"

ids=()
for fam in $FAMILIES; do
    for t in 1 "$THREADS"; do
        id=$(sbatch --parsable --partition="$PARTITION" --exclusive --mem=0 --time="$WALL" \
            --job-name="scaling-$fam-t$t" --output="$SCALING_BUILD/logs/%x-%j.out" \
            --chdir="$REPO" \
            --export="ALL,SCALING_REPO=$REPO,SCALING_BUILD=$SCALING_BUILD,SCALING_BIN=$BIN,SCALING_FAMILY=$fam,SCALING_RUN_THREADS=$t,SCALING_TIMEOUT_S=$TIMEOUT_S" \
            "$TIER/sweep.sbatch")
        echo "submitted $id: $fam, $t thread(s)"
        ids+=("$id")
    done
done
deps=$(IFS=:; echo "${ids[*]}")
check=$(sbatch --parsable --partition="$PARTITION" --time=00:10:00 --dependency="afterany:$deps" \
    --job-name=scaling-check --output="$SCALING_BUILD/logs/%x-%j.out" --chdir="$REPO" \
    --wrap="python3 $TIER/check.py $SCALING_BUILD/results/*.json --json $SCALING_BUILD/check.json > $SCALING_BUILD/check.txt 2>&1; echo check exit \$?")
echo "submitted $check: check.py over every result, after the sweep ($SCALING_BUILD/check.txt)"
