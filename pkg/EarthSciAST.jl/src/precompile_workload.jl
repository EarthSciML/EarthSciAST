# Precompile workload, run while the package precompiles, so that what every
# session does first is compiled into the package image instead of on first
# call: loading a document from JSON text, building it under both the
# interpreter and the native compiler, and evaluating its right-hand side once;
# plus a few native builds that reach the rest of the native pipeline (the
# join-gate builder, a construction-time fill, the affine kernel tier and its
# code generation, a const-array gather). Every document is built in memory;
# nothing reads the network or a file. The builds are single-threaded
# (precompilation runs one thread), so the threaded dispatch is not exercised.
#
# What is cached here survives loading other packages only where the code it
# calls is concretely inferred; `invalidation_barriers.jl` has the helpers that
# keep the less precisely typed parts of the build path that way. Solving and
# the inline tests need the solver packages, so their workload is
# `EarthSciASTSolverWorkloadExt`.

using PrecompileTools: @setup_workload, @compile_workload

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
        "esm" => "1.2.0", "metadata" => Dict{String, Any}("name" => name),
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
    # An array model: `faq` equations with and without a `filter`, an array
    # observed read through `index`, and inline assertions at coordinates.
    array_doc = """
    {"esm": "1.2.0", "metadata": {"name": "workload_array"},
     "index_sets": {"x": {"kind": "interval", "size": 5}},
     "models": {"M": {
       "variables": {
         "a": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
         "b": {"type": "unknown", "units": "1", "shape": ["x"], "default": 0.0},
         "w": {"type": "unknown", "units": "1", "shape": ["x"]}
       },
       "equations": [
         {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "D", "args": [{"op": "index", "args": ["a", "i"]}], "wrt": "t"}},
          "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "+", "args": [{"op": "*", "args": [2, "i"]}, 1]},
                  "filter": {"op": ">=", "args": ["i", 3]}}},
         {"lhs": "w", "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "*", "args": [10, "i"]}, "filter": {"op": "<=", "args": ["i", 2]}}},
         {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "D", "args": [{"op": "index", "args": ["b", "i"]}], "wrt": "t"}},
          "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                  "expr": {"op": "index", "args": ["w", "i"]}}}
       ],
       "tests": [{"id": "t1", "time_span": {"start": 0.0, "end": 1.0},
                  "assertions": [{"variable": "a", "time": 1.0, "expected": 7.0, "coords": {"x": 3}},
                                 {"variable": "w", "time": 1.0, "expected": 10.0, "coords": {"x": 1}}]}]
     }}}
    """
    # A scalar model: a parameter, a state, an observed, and an inline test
    # that overrides the parameter.
    scalar_doc = """
    {"esm": "1.2.0", "metadata": {"name": "workload_scalar"},
     "models": {"M": {
       "variables": {
         "k": {"type": "parameter", "units": "1/s", "default": 0.5},
         "y": {"type": "unknown", "units": "1", "default": 1.0},
         "z": {"type": "unknown", "units": "1"}
       },
       "equations": [
         {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
          "rhs": {"op": "-", "args": [{"op": "*", "args": ["k", "y"]}]}},
         {"lhs": "z", "rhs": {"op": "*", "args": [2, "y"]}}
       ],
       "tests": [{"id": "t1", "time_span": {"start": 0.0, "end": 1.0},
                  "parameter_overrides": {"k": 1.0},
                  "assertions": [{"variable": "y", "time": 1.0, "expected": 0.36787944117144233},
                                 {"variable": "z", "time": 1.0, "expected": 0.7357588823428847}]}]
     }}}
    """
    @compile_workload begin
        # The load and build path every session takes: parse a document from
        # JSON text, build it under both compilers, and evaluate its RHS once.
        for json in (array_doc, scalar_doc)
            file = load_string(json)
            for compiler in (:interpreter, :native)
                prob = esm_problem(file, (0.0, 1.0); compiler)
                du = similar(prob.u0)
                isempty(du) || prob.f!(du, prob.u0, prob.p, 0.0)
            end
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
end
