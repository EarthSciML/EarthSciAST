# Precompile workload: five small documents, written as JSON text and built
# natively while the package precompiles, so the native build pipeline's own
# methods (the join-gate builder, a construction-time fill, the affine kernel
# tier and its code generation, a const-array gather, a standard-library
# template under an overlap join) are compiled into the package image instead
# of on a session's first build. Every document is built in memory; nothing
# reads the network, and the only file read is the bundled standard library.
# The builds are single-threaded (precompilation runs one thread), so neither
# the threaded dispatch nor any extension is exercised.

using PrecompileTools: @setup_workload, @compile_workload

# Two documents, loaded from JSON text here and in `EarthSciASTSolverWorkloadExt`:
# an array model (`faq` with and without a `filter`, an observed read through
# `index`) and a scalar model (a parameter, an observed), each with an inline test.
const _WORKLOAD_DOCS = (
    """{"esm": "$SCHEMA_VERSION", "metadata": {"name": "array"}, "index_sets": {"x": {"kind": "interval", "size": 5}},
    "models": {"M": {"variables": {"a": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
      "w": {"type": "unknown", "units": "1", "shape": ["x"]}}, "equations": [
      {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}}, "expr": {"op": "D", "args": [{"op": "index", "args": ["a", "i"]}], "wrt": "t"}},
       "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}}, "expr": {"op": "+", "args": [{"op": "index", "args": ["w", "i"]}, 1]}, "filter": {"op": ">=", "args": ["i", 3]}}},
      {"lhs": "w", "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}}, "expr": {"op": "*", "args": [10, "i"]}}}],
     "tests": [{"id": "t", "time_span": {"start": 0.0, "end": 1.0}, "assertions": [{"variable": "a", "time": 1.0, "expected": 31.0, "coords": {"x": 3}}]}]}}}""",
    """{"esm": "$SCHEMA_VERSION", "metadata": {"name": "scalar"}, "models": {"M": {"variables": {"k": {"type": "parameter", "units": "1/s", "default": 0.5},
     "y": {"type": "unknown", "units": "1", "default": 1.0}, "z": {"type": "unknown", "units": "1"}}, "equations": [
     {"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": {"op": "-", "args": [{"op": "*", "args": ["k", "y"]}]}}, {"lhs": "z", "rhs": {"op": "*", "args": [2, "y"]}}],
    "tests": [{"id": "t", "time_span": {"start": 0.0, "end": 1.0}, "parameter_overrides": {"k": 1.0}, "assertions": [{"variable": "z", "time": 1.0, "expected": 0.7357588823428847}]}]}}}""",
)

# A stencil over a state with a const-array gather at a computed subscript.
const _WORKLOAD_STENCIL = """{"esm": "$SCHEMA_VERSION", "metadata": {"name": "pw_stencil"}, "index_sets": {"cells": {"kind": "interval", "size": 16}},
"models": {"M": {"variables": {
  "u": {"type": "unknown", "units": "1", "shape": ["cells"], "default": 1.0},
  "c": {"type": "unknown", "units": "1", "shape": ["cells"]}},
"equations": [
  {"lhs": "c", "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "cells"}}, "expr": {"op": "index", "args": [{"op": "const", "args": [], "value": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0]}, {"op": "+", "args": [1, {"op": "-", "args": [{"op": "*", "args": [7, "i"]}, {"op": "*", "args": [16, {"op": "floor", "args": [{"op": "/", "args": [{"op": "*", "args": [7, "i"]}, 16]}]}]}]}]}]}}},
  {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "cells"}}, "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"}}, "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "cells"}}, "expr": {"op": "+", "args": [{"op": "*", "args": [-0.1, {"op": "index", "args": ["u", "i"]}]}, {"op": "*", "args": [0.01, {"op": "index", "args": ["c", "i"]}]}, {"op": "ifelse", "args": [{"op": ">", "args": ["i", 1]}, {"op": "*", "args": [0.5, {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}]}, 0.0]}]}}}]}}}"""

# A join keyed on a computed column, itself computed through a join of its own
# (a construction-time fill), reading a scalar parameter.
const _WORKLOAD_JOIN = """{"esm": "$SCHEMA_VERSION", "metadata": {"name": "pw_join"}, "index_sets": {"rows": {"kind": "interval", "size": 8}, "keys": {"kind": "interval", "size": 4}},
"models": {"M": {"variables": {
  "off": {"type": "parameter", "units": "1", "default": 0.0},
  "row_key": {"type": "unknown", "units": "1", "shape": ["rows"]},
  "kk": {"type": "unknown", "units": "1", "shape": ["keys"]},
  "has": {"type": "unknown", "units": "1", "shape": ["keys"]},
  "pick": {"type": "unknown", "units": "1", "shape": ["keys"]},
  "total": {"type": "unknown", "units": "1", "shape": ["keys"]}},
"equations": [
  {"lhs": "row_key", "rhs": {"op": "faq", "args": [], "output_idx": ["r"], "ranges": {"r": {"from": "rows"}}, "expr": {"op": "+", "args": [1, {"op": "-", "args": [{"op": "-", "args": ["r", 1]}, {"op": "*", "args": [3, {"op": "floor", "args": [{"op": "/", "args": [{"op": "-", "args": ["r", 1]}, 3]}]}]}]}]}}},
  {"lhs": "kk", "rhs": {"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": {"from": "keys"}}, "expr": {"op": "+", "args": ["k", "off"]}}},
  {"lhs": "has", "rhs": {"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": {"from": "keys"}, "r": {"from": "rows"}}, "expr": 1.0, "semiring": "sum_product", "join": [{"on": [["kk", "row_key"]]}]}},
  {"lhs": "pick", "rhs": {"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": {"from": "keys"}}, "expr": {"op": "ifelse", "args": [{"op": ">", "args": [{"op": "index", "args": ["has", "k"]}, 0.0]}, "k", 99.0]}}},
  {"lhs": "total", "rhs": {"op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": {"from": "keys"}, "r": {"from": "rows"}}, "expr": 1.0, "semiring": "sum_product", "join": [{"on": [["pick", "row_key"]]}]}}]}}}"""

# The ISRM binning shape: records summed onto the grid cells their envelopes
# overlap, each pair's area by the library's planar overlap template,
# materialized at construction (an observed of const rings). Its rings and
# envelopes are the const arrays `_workload_binning_arrays` computes.
const _WORKLOAD_BINNING = """{"esm": "$SCHEMA_VERSION", "metadata": {"name": "pw_binning"}, "index_sets": {"cells": {"kind": "interval", "size": 2}, "recs": {"kind": "interval", "size": 2}, "vert": {"kind": "interval", "size": 4}, "xy": {"kind": "interval", "size": 2}},
"models": {"M": {"variables": {
  "cring": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["cells", "vert", "xy"]},
  "pring": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["recs", "vert", "xy"]},
  "out": {"type": "unknown", "units": "1", "shape": ["cells"]},
  "cx0": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["cells"]},
  "cy0": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["cells"]},
  "cx1": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["cells"]},
  "cy1": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["cells"]},
  "px0": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["recs"]},
  "py0": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["recs"]},
  "px1": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["recs"]},
  "py1": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["recs"]}},
"equations": [
  {"lhs": "out", "rhs": {"op": "faq", "args": [], "output_idx": ["c"], "ranges": {"c": {"from": "cells"}, "r": {"from": "recs"}}, "expr": {"op": "apply_operator", "args": [], "name": "overlap_area_planar", "bindings": {"ring_a": "pring", "cell_a": "r", "nv_a": 4, "ring_b": "cring", "cell_b": "c", "nv_b": 4}}, "reduce": "+", "join": [{"overlap": {"src_env": ["px0", "py0", "px1", "py1"], "tgt_env": ["cx0", "cy0", "cx1", "cy1"], "eps": 0.0}}]}}],
"operator_imports": [{"ref": "esm:std/geometry.esm", "only": ["overlap_area_planar"]}]}}}"""

# Two unit squares side by side (the cells) and two rectangles (the records),
# as the ring and envelope arrays the binning document reads.
function _workload_binning_arrays()
    ring(x0, y0, x1, y1) = [x0 y0; x1 y0; x1 y1; x0 y1]
    stack(rs) = permutedims(cat(rs...; dims = 3), (3, 1, 2))
    env(rs, k) = Float64[r[k <= 2 ? 1 : 3, 2 - k % 2] for r in rs]
    cells = [ring(i, 0.0, i + 1.0, 1.0) for i in 0.0:1.0]
    recs = [ring(0.25, 0.25, 0.75, 0.5), ring(0.5, 0.5, 1.5, 0.75)]
    arrays = Dict{String, Any}("cring" => stack(cells), "pring" => stack(recs))
    for (k, n) in enumerate(("x0", "y0", "x1", "y1"))
        arrays["c" * n] = env(cells, k)
        arrays["p" * n] = env(recs, k)
    end
    return arrays
end

@setup_workload begin
    binning_arrays = _workload_binning_arrays()
    @compile_workload begin
        observed_field(
            esm_problem(
                load_string(_WORKLOAD_BINNING), (0.0, 0.0);
                compiler = :native, const_arrays = binning_arrays
            ),
            "M.out"
        )
        for json in _WORKLOAD_DOCS
            prob = esm_problem(load_string(json), (0.0, 1.0); compiler = :native)
            prob.f!(similar(prob.u0), prob.u0, prob.p, 0.0)
        end
        for json in (_WORKLOAD_STENCIL, _WORKLOAD_JOIN)
            prob = esm_problem(load_string(json), (0.0, 1.0); compiler = :native)
            du = similar(prob.u0)
            isempty(du) || prob.f!(du, prob.u0, prob.p, 0.0)
        end
        observed_field(
            esm_problem(load_string(_WORKLOAD_JOIN), (0.0, 0.0); compiler = :native),
            "M.total"
        )
    end
end
