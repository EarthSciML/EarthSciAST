#!/bin/bash
# One job of the Julia scaling sweep: one family, every ladder size, one thread
# mode. Submitted by sweep.sh, which sets the environment below; see its header.
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --time=04:00:00
set -euo pipefail
: "${SCALING_REPO:?}" "${SCALING_BUILD:?}" "${SCALING_JULIA:?}" "${SCALING_FAMILY:?}" "${SCALING_RUN_THREADS:?}"
export TMPDIR=${TMPDIR:-$SCALING_BUILD/tmp}
mkdir -p "$TMPDIR"

fam=$SCALING_FAMILY
t=$SCALING_RUN_THREADS
tier=$SCALING_REPO/tests/conformance/scaling
docs=$SCALING_BUILD/docs/julia-$fam-t$t
out=$SCALING_BUILD/results/julia-$fam-t$t.json
echo "host $(hostname), $(nproc) cpus, family $fam, $t thread(s), commit $(cat "$SCALING_BUILD/commit")"
lscpu | grep -E '^(Model name|Socket|Core|Thread)' || true
python3 "$tier/generate.py" --out "$docs" --family "$fam"
status=0
"$SCALING_JULIA" --threads="$t" --project="$SCALING_REPO/pkg/EarthSciAST.jl/scripts/scaling_env" \
    "$tier/julia/adapter.jl" --docs "$docs" --output "$out" \
    --max-build "${SCALING_MAX_BUILD:-1800}" || status=$?
# A process that died (out of memory at the top of a ladder, say) leaves the
# sizes it finished; record the rest as errors that say so, so the checker
# reads a complete ladder rather than a silently short one.
python3 - "$docs/index.json" "$out" "$status" "$t" "$SCALING_BUILD/commit" <<'PY'
import json, os, socket, sys
index, out, status, threads, commit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
docs = json.load(open(index))["documents"]
if os.path.exists(out):
    res = json.load(open(out))
else:
    res = {"binding": "julia", "compiler": "native", "threads": threads,
           "commit": open(commit).read().strip(), "host": socket.gethostname(),
           "target": None, "results": []}
have = {(r["family"], r["n"]) for r in res["results"]}
for d in docs:
    if (d["family"], d["n"]) in have:
        continue
    res["results"].append({
        "family": d["family"], "n": d["n"], "n_cells": d["n_cells"], "n_states": d["n_states"],
        "status": "error",
        "reason": f"the adapter process exited with status {status} before reaching this document (see the job log)",
        **{k: None for k in ("build_s", "code_size", "code_size_unit", "first_call_s", "steady_rhs_s",
                             "allocs_per_call", "hand_loop_s", "hand_loop_max_abs_diff", "dy_max_abs",
                             "interpreter_max_abs_diff")}})
json.dump(res, open(out, "w"), indent=1)
PY
# The generated documents are reproducible from the generator; keep only the results.
rm -rf "$docs"
echo "done (adapter exit $status)"
