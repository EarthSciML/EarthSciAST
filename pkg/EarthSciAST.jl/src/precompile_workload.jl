# Precompile workload: documents loaded from JSON text, and a few more small
# builds, all native, run while the package precompiles,
# so the native build pipeline's own methods (the join-gate builder, a
# construction-time fill, the affine kernel tier and its code generation, a
# const-array gather, a standard-library template under an overlap join) are
# compiled into the package image instead of on a session's first build. Every
# document is built in memory; nothing reads the network, and the only file
# read is the bundled standard library. The builds are single-threaded (precompilation
# runs one thread), so neither the threaded dispatch nor any extension is
# exercised.

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

@setup_workload begin
    _pw_faq(oi, ranges, expr, extra::Pair...) = Dict{String, Any}(
        "op" => "faq",
        "args" => Any[], "output_idx" => Any[oi...], "ranges" => ranges, "expr" => expr,
        extra...
    )
    _pw_from(s) = Dict{String, Any}("from" => s)
    _pw_idx(a, i...) = Dict{String, Any}("op" => "index", "args" => Any[a, i...])
    _pw_op(op, a...) = Dict{String, Any}("op" => op, "args" => Any[a...])
    # `a mod n`, spelled with `floor` (the subscript form a document uses).
    _pw_mod(a, n) = _pw_op("-", a, _pw_op("*", n, _pw_op("floor", _pw_op("/", a, n))))
    _pw_var(type, extra::Pair...) = Dict{String, Any}("type" => type, "units" => "1", extra...)
    _pw_doc(name, isets, vars, eqs) = Dict{String, Any}(
        "esm" => SCHEMA_VERSION, "metadata" => Dict{String, Any}("name" => name),
        "index_sets" => Dict{String, Any}(
            k => Dict{String, Any}(
                "kind" => "interval",
                "size" => v
            )
                for (k, v) in isets
        ),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => vars,
                "equations" => eqs
            )
        )
    )
    # A stencil over a state with a const-array gather at a computed subscript.
    stencil = _pw_doc(
        "pw_stencil", ("cells" => 16,),
        Dict{String, Any}(
            "u" => _pw_var("unknown", "shape" => ["cells"], "default" => 1.0),
            "c" => _pw_var("unknown", "shape" => ["cells"])
        ),
        Any[
            Dict{String, Any}(
                "lhs" => "c", "rhs" => _pw_faq(
                    ["i"],
                    Dict{String, Any}("i" => _pw_from("cells")),
                    _pw_idx(
                        Dict{String, Any}(
                            "op" => "const", "args" => Any[],
                            "value" => Float64[k for k in 1:16]
                        ),
                        _pw_op("+", 1, _pw_mod(_pw_op("*", 7, "i"), 16))
                    )
                )
            ),
            Dict{String, Any}(
                "lhs" => _pw_faq(
                    ["i"],
                    Dict{String, Any}("i" => _pw_from("cells")),
                    Dict{String, Any}("op" => "D", "args" => Any[_pw_idx("u", "i")], "wrt" => "t")
                ),
                "rhs" => _pw_faq(
                    ["i"], Dict{String, Any}("i" => _pw_from("cells")),
                    _pw_op(
                        "+", _pw_op("*", -0.1, _pw_idx("u", "i")),
                        _pw_op("*", 0.01, _pw_idx("c", "i")),
                        _pw_op(
                            "ifelse", _pw_op(">", "i", 1),
                            _pw_op("*", 0.5, _pw_idx("u", _pw_op("-", "i", 1))), 0.0
                        )
                    )
                )
            ),
        ]
    )
    # A join keyed on a computed column, itself computed through a join of its
    # own (a construction-time fill), reading a scalar parameter.
    keyed = _pw_doc(
        "pw_join", ("rows" => 8, "keys" => 4),
        Dict{String, Any}(
            "off" => _pw_var("parameter", "default" => 0.0),
            "row_key" => _pw_var("unknown", "shape" => ["rows"]),
            "kk" => _pw_var("unknown", "shape" => ["keys"]),
            "has" => _pw_var("unknown", "shape" => ["keys"]),
            "pick" => _pw_var("unknown", "shape" => ["keys"]),
            "total" => _pw_var("unknown", "shape" => ["keys"])
        ),
        Any[
            Dict{String, Any}(
                "lhs" => "row_key", "rhs" => _pw_faq(
                    ["r"],
                    Dict{String, Any}("r" => _pw_from("rows")),
                    _pw_op("+", 1, _pw_mod(_pw_op("-", "r", 1), 3))
                )
            ),
            Dict{String, Any}(
                "lhs" => "kk", "rhs" => _pw_faq(
                    ["k"],
                    Dict{String, Any}("k" => _pw_from("keys")), _pw_op("+", "k", "off")
                )
            ),
            Dict{String, Any}(
                "lhs" => "has", "rhs" => _pw_faq(
                    ["k"],
                    Dict{String, Any}("k" => _pw_from("keys"), "r" => _pw_from("rows")), 1.0,
                    "semiring" => "sum_product",
                    "join" => Any[Dict{String, Any}("on" => Any[Any["kk", "row_key"]])]
                )
            ),
            Dict{String, Any}(
                "lhs" => "pick", "rhs" => _pw_faq(
                    ["k"],
                    Dict{String, Any}("k" => _pw_from("keys")),
                    _pw_op("ifelse", _pw_op(">", _pw_idx("has", "k"), 0.0), "k", 99.0)
                )
            ),
            Dict{String, Any}(
                "lhs" => "total", "rhs" => _pw_faq(
                    ["k"],
                    Dict{String, Any}("k" => _pw_from("keys"), "r" => _pw_from("rows")), 1.0,
                    "semiring" => "sum_product",
                    "join" => Any[Dict{String, Any}("on" => Any[Any["pick", "row_key"]])]
                )
            ),
        ]
    )
    # The ISRM binning shape: records summed onto the grid cells their
    # envelopes overlap, each pair's area by the library's planar overlap
    # template, materialized at construction (an observed of const rings).
    _pw_ring(x0, y0, x1, y1) = [x0 y0; x1 y0; x1 y1; x0 y1]
    _pw_stack(rs) = permutedims(cat(rs...; dims = 3), (3, 1, 2))
    cells = [_pw_ring(i, 0.0, i + 1.0, 1.0) for i in 0.0:1.0]
    recs = [_pw_ring(0.25, 0.25, 0.75, 0.5), _pw_ring(0.5, 0.5, 1.5, 0.75)]
    _pw_env(rs, k) = Float64[r[k <= 2 ? 1 : 3, 2 - k % 2] for r in rs]
    binning_arrays = Dict{String, Any}("cring" => _pw_stack(cells), "pring" => _pw_stack(recs))
    for (k, n) in enumerate(("x0", "y0", "x1", "y1"))
        binning_arrays["c" * n] = _pw_env(cells, k)
        binning_arrays["p" * n] = _pw_env(recs, k)
    end
    binning = _pw_doc(
        "pw_binning", ("cells" => 2, "recs" => 2, "vert" => 4, "xy" => 2),
        merge(
            Dict{String, Any}(
                "cring" => _pw_var("parameter", "default" => 0.0, "shape" => ["cells", "vert", "xy"]),
                "pring" => _pw_var("parameter", "default" => 0.0, "shape" => ["recs", "vert", "xy"]),
                "out" => _pw_var("unknown", "shape" => ["cells"])
            ),
            Dict{String, Any}(
                s * n => _pw_var("parameter", "default" => 0.0, "shape" => [s == "c" ? "cells" : "recs"])
                    for s in ("c", "p") for n in ("x0", "y0", "x1", "y1")
            )
        ),
        Any[
            Dict{String, Any}(
                "lhs" => "out", "rhs" => _pw_faq(
                    ["c"], Dict{String, Any}("c" => _pw_from("cells"), "r" => _pw_from("recs")),
                    Dict{String, Any}(
                        "op" => "apply_expression_template", "args" => Any[],
                        "name" => "overlap_area_planar",
                        "bindings" => Dict{String, Any}(
                            "ring_a" => "pring", "cell_a" => "r", "nv_a" => 4,
                            "ring_b" => "cring", "cell_b" => "c", "nv_b" => 4
                        )
                    ),
                    "reduce" => "+",
                    "join" => Any[
                        Dict{String, Any}(
                            "overlap" => Dict{String, Any}(
                                "src_env" => ["px0", "py0", "px1", "py1"],
                                "tgt_env" => ["cx0", "cy0", "cx1", "cy1"], "eps" => 0.0
                            )
                        ),
                    ]
                )
            ),
        ]
    )
    binning["models"]["M"]["expression_template_imports"] = Any[
        Dict{String, Any}("ref" => "esm:std/geometry.esm", "only" => ["overlap_area_planar"]),
    ]
    @compile_workload begin
        observed_field(
            esm_problem(binning, (0.0, 0.0); compiler = :native, const_arrays = binning_arrays),
            "M.out"
        )
        for json in _WORKLOAD_DOCS
            prob = esm_problem(load_string(json), (0.0, 1.0); compiler = :native)
            prob.f!(similar(prob.u0), prob.u0, prob.p, 0.0)
        end
        for doc in (stencil, keyed)
            prob = esm_problem(doc, (0.0, 1.0); compiler = :native)
            du = similar(prob.u0)
            isempty(du) || prob.f!(du, prob.u0, prob.p, 0.0)
        end
        observed_field(esm_problem(keyed, (0.0, 0.0); compiler = :native), "M.total")
    end
    # The process-wide counters and build-scoped tables the builds above touched
    # start empty in a session, as they would without the workload.
    empty!(_CASCADE_TALLY)
    empty!(_STATE_SLOT_TABLES)
    empty!(_LOOPVAR_REFS)
    _CELLWISE_FASTPATH_HITS[] = 0
    _CELLWISE_FASTPATH_MISS[] = 0
    _VI_ENUM_VISITS[] = 0
    _SETUP_MAP_FASTPATH_HITS[] = 0
    for r in (
            _GEOM_SWEEP_FAST, _GEOM_SWEEP_REF, _GEOM_OVERLAP_DRIVE,
            _GEOM_OVERLAP_GATE_ONLY, _GEOM_OVERLAP_NONE, _GEOM_EQ_DRIVE,
        )
        r[] = 0
    end
end
