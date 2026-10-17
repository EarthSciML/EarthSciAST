# Precompile workload: a few small native builds, run while the package
# precompiles, so the native build pipeline's own methods (the join-gate
# builder, a construction-time fill, the affine kernel tier and its code
# generation, a const-array gather) are compiled into the package image instead
# of on a session's first build. Every document is built in memory; nothing
# reads the network or a file. The builds are single-threaded (precompilation
# runs one thread), so neither the threaded dispatch nor any extension is
# exercised.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    _pw_faq(oi, ranges, expr, extra::Pair...) = Dict{String,Any}("op" => "faq",
        "args" => Any[], "output_idx" => Any[oi...], "ranges" => ranges, "expr" => expr,
        extra...)
    _pw_from(s) = Dict{String,Any}("from" => s)
    _pw_idx(a, i...) = Dict{String,Any}("op" => "index", "args" => Any[a, i...])
    _pw_op(op, a...) = Dict{String,Any}("op" => op, "args" => Any[a...])
    # `a mod n`, spelled with `floor` (the subscript form a document uses).
    _pw_mod(a, n) = _pw_op("-", a, _pw_op("*", n, _pw_op("floor", _pw_op("/", a, n))))
    _pw_var(type, extra::Pair...) = Dict{String,Any}("type" => type, "units" => "1", extra...)
    _pw_doc(name, isets, vars, eqs) = Dict{String,Any}(
        "esm" => "1.2.0", "metadata" => Dict{String,Any}("name" => name),
        "index_sets" => Dict{String,Any}(k => Dict{String,Any}("kind" => "interval",
                                                               "size" => v)
                                         for (k, v) in isets),
        "models" => Dict{String,Any}("M" => Dict{String,Any}("variables" => vars,
                                                             "equations" => eqs)))
    # A stencil over a state with a const-array gather at a computed subscript.
    stencil = _pw_doc("pw_stencil", ("cells" => 16,),
        Dict{String,Any}(
            "u" => _pw_var("unknown", "shape" => ["cells"], "default" => 1.0),
            "c" => _pw_var("unknown", "shape" => ["cells"])),
        Any[Dict{String,Any}("lhs" => "c", "rhs" => _pw_faq(["i"],
                 Dict{String,Any}("i" => _pw_from("cells")),
                 _pw_idx(Dict{String,Any}("op" => "const", "args" => Any[],
                                          "value" => Float64[k for k in 1:16]),
                         _pw_op("+", 1, _pw_mod(_pw_op("*", 7, "i"), 16))))),
            Dict{String,Any}("lhs" => _pw_faq(["i"],
                 Dict{String,Any}("i" => _pw_from("cells")),
                 Dict{String,Any}("op" => "D", "args" => Any[_pw_idx("u", "i")], "wrt" => "t")),
             "rhs" => _pw_faq(["i"], Dict{String,Any}("i" => _pw_from("cells")),
                 _pw_op("+", _pw_op("*", -0.1, _pw_idx("u", "i")),
                        _pw_op("*", 0.01, _pw_idx("c", "i")),
                        _pw_op("ifelse", _pw_op(">", "i", 1),
                               _pw_op("*", 0.5, _pw_idx("u", _pw_op("-", "i", 1))), 0.0))))])
    # A join keyed on a computed column, itself computed through a join of its
    # own (a construction-time fill), reading a scalar parameter.
    keyed = _pw_doc("pw_join", ("rows" => 8, "keys" => 4),
        Dict{String,Any}(
            "off" => _pw_var("parameter", "default" => 0.0),
            "row_key" => _pw_var("unknown", "shape" => ["rows"]),
            "kk" => _pw_var("unknown", "shape" => ["keys"]),
            "has" => _pw_var("unknown", "shape" => ["keys"]),
            "pick" => _pw_var("unknown", "shape" => ["keys"]),
            "total" => _pw_var("unknown", "shape" => ["keys"])),
        Any[Dict{String,Any}("lhs" => "row_key", "rhs" => _pw_faq(["r"],
                 Dict{String,Any}("r" => _pw_from("rows")),
                 _pw_op("+", 1, _pw_mod(_pw_op("-", "r", 1), 3)))),
            Dict{String,Any}("lhs" => "kk", "rhs" => _pw_faq(["k"],
                 Dict{String,Any}("k" => _pw_from("keys")), _pw_op("+", "k", "off"))),
            Dict{String,Any}("lhs" => "has", "rhs" => _pw_faq(["k"],
                 Dict{String,Any}("k" => _pw_from("keys"), "r" => _pw_from("rows")), 1.0,
                 "semiring" => "sum_product",
                 "join" => Any[Dict{String,Any}("on" => Any[Any["kk", "row_key"]])])),
            Dict{String,Any}("lhs" => "pick", "rhs" => _pw_faq(["k"],
                 Dict{String,Any}("k" => _pw_from("keys")),
                 _pw_op("ifelse", _pw_op(">", _pw_idx("has", "k"), 0.0), "k", 99.0))),
            Dict{String,Any}("lhs" => "total", "rhs" => _pw_faq(["k"],
                 Dict{String,Any}("k" => _pw_from("keys"), "r" => _pw_from("rows")), 1.0,
                 "semiring" => "sum_product",
                 "join" => Any[Dict{String,Any}("on" => Any[Any["pick", "row_key"]])]))])
    @compile_workload begin
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
