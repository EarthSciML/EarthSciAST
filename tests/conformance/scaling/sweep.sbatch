#!/bin/bash
# One job of the scaling sweep: one family, every ladder size, one thread mode.
# Submitted by sweep.sh, which sets the environment below; see its header.
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --time=01:30:00
set -euo pipefail
: "${SCALING_REPO:?}" "${SCALING_BUILD:?}" "${SCALING_BIN:?}" "${SCALING_FAMILY:?}" "${SCALING_RUN_THREADS:?}"
export TMPDIR=${TMPDIR:-$SCALING_BUILD/tmp}
mkdir -p "$TMPDIR"

fam=$SCALING_FAMILY
t=$SCALING_RUN_THREADS
docs=$SCALING_BUILD/docs/$fam-t$t
echo "host $(hostname), $(nproc) cpus, family $fam, $t thread(s), commit $(cat "$SCALING_BUILD/commit")"
echo "exclusive node; load at start: $(cut -d' ' -f1-3 /proc/loadavg)"
python3 "$SCALING_REPO/tests/conformance/scaling/generate.py" --out "$docs" --family "$fam"
SCALING_COMMIT=$(cat "$SCALING_BUILD/commit") "$SCALING_BIN" --index "$docs/index.json" --output "$SCALING_BUILD/results/rust-$fam-t$t.json" \
    --threads "$t" --timeout-s "${SCALING_TIMEOUT_S:-1200}"
# The generated documents are reproducible from the generator; keep only the results.
rm -rf "$docs"
echo done
