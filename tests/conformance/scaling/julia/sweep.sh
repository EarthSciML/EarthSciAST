#!/bin/bash
# The scaling tier's full Julia sweep on Slurm (README.md in this directory):
# every family at every ladder size, serial and threaded, one exclusive job per
# (family, thread mode), then one job that applies every gate and the ledger to
# the results.
#
#   SCALING_BUILD=/scratch/$USER/scaling-julia tests/conformance/scaling/julia/sweep.sh
#
# Environment:
#   SCALING_BUILD       scratch directory for documents, results and logs (required;
#                       the 10^6 documents and runs need real disk, not a RAM-backed /tmp)
#   SCALING_PARTITION   Slurm partition (default: secondary)
#   SCALING_THREADS     thread count of the threaded run (default: 16)
#   SCALING_FAMILIES    space-separated families (default: every family in manifest.json)
#   SCALING_MAX_BUILD   the adapter's --max-build, seconds (default: 1800)
#   SCALING_TIME        wall-clock limit of each job (default: 04:00:00)
#   SCALING_JULIA       the julia binary (default: the one on PATH here)
#
# The jobs run the adapter out of this checkout, so leave it alone until they
# finish. The environment (pkg/EarthSciAST.jl/scripts/scaling_env) is
# instantiated and precompiled here, once, so no job pays for it or races
# another for the depot. Timings want a clean machine, hence --exclusive.
set -euo pipefail

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
TIER=$REPO/tests/conformance/scaling
: "${SCALING_BUILD:?set SCALING_BUILD to a scratch directory}"
PARTITION=${SCALING_PARTITION:-secondary}
THREADS=${SCALING_THREADS:-16}
MAX_BUILD=${SCALING_MAX_BUILD:-1800}
WALL=${SCALING_TIME:-04:00:00}
JULIA=${SCALING_JULIA:-$(command -v julia)}
FAMILIES=${SCALING_FAMILIES:-$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['families']))" "$TIER/manifest.json")}

mkdir -p "$SCALING_BUILD"/{docs,results,logs}
git -C "$REPO" rev-parse HEAD > "$SCALING_BUILD/commit"
ENV=$REPO/pkg/EarthSciAST.jl/scripts/scaling_env
[ -f "$ENV/Manifest.toml" ] ||
    "$JULIA" --project="$ENV" -e 'import Pkg; Pkg.develop(path=joinpath(ARGS[1], "pkg", "EarthSciAST.jl"))' "$REPO"
"$JULIA" --project="$ENV" -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'

ids=()
for fam in $FAMILIES; do
    for t in 1 "$THREADS"; do
        id=$(sbatch --parsable --partition="$PARTITION" --exclusive --mem=0 --time="$WALL" \
            --job-name="scaling-julia-$fam-t$t" --output="$SCALING_BUILD/logs/%x-%j.out" \
            --chdir="$REPO" \
            --export="ALL,SCALING_REPO=$REPO,SCALING_BUILD=$SCALING_BUILD,SCALING_JULIA=$JULIA,SCALING_FAMILY=$fam,SCALING_RUN_THREADS=$t,SCALING_MAX_BUILD=$MAX_BUILD" \
            "$TIER/julia/sweep.sbatch")
        echo "submitted $id: $fam, $t thread(s)"
        ids+=("$id")
    done
done
deps=$(IFS=:; echo "${ids[*]}")
check=$(sbatch --parsable --partition="$PARTITION" --time=00:10:00 --dependency="afterany:$deps" \
    --job-name=scaling-julia-check --output="$SCALING_BUILD/logs/%x-%j.out" --chdir="$REPO" \
    --wrap="python3 $TIER/check.py $SCALING_BUILD/results/julia-*.json --require sweep --json $SCALING_BUILD/check.json > $SCALING_BUILD/check.txt 2>&1; echo check exit \$?")
echo "submitted $check: check.py over every result, after the sweep ($SCALING_BUILD/check.txt)"
