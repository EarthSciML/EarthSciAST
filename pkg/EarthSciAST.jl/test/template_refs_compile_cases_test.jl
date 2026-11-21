# Template references the build compiles as calls (no expansion) in shapes
# EarthSciDiscretizations problems use, each of which the build refused or
# mis-read after references stopped being expanded (#754):
#   * validation reading a reference's bindings through a SHARED frame (two
#     callers whose bindings have one key share the callee's frame);
#   * a makearray region whose value is a PARAMETER bound to an array-valued
#     reference (read through that reference's own view);
#   * an aggregate body with a literal output index (`output_idx: [1, "s"]`);
#   * an elementwise array observed (`K = 1 + ze`) bound by name to an array
#     parameter (materialized, passed as an array);
#   * a parameterless template whose body is a literal table, read in a body
#     under the native emitter.
# Under both compilers the right-hand side must be bit for bit the build of the
# expanded document's, and no reference may be expanded.

using Test
using JSON3
using EarthSciAST
const _TC = EarthSciAST

_tc_d(p...) = Dict{String, Any}(p...)
_tc_op(o, a...; kw...) = _tc_d("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_tc_ix(a, s...) = _tc_op("index", a, s...)
_tc_ref(n; b...) = _tc_d(
    "op" => "apply_expression_template", "args" => Any[], "name" => n,
    "bindings" => _tc_d((String(k) => v for (k, v) in b)...)
)
_tc_tpl(params, body) = _tc_d("params" => Any[params...], "body" => body)
_tc_D(x) = _tc_d("op" => "D", "args" => Any[x], "wrt" => "t")

function _tc_doc(vars, eqs, templates, sets)
    return _tc_d(
        "esm" => "2.3.0", "metadata" => _tc_d("name" => "tc"),
        "index_sets" => _tc_d((k => _tc_d("kind" => "interval", "size" => n) for (k, n) in sets)...),
        "models" => _tc_d("M" => _tc_d("variables" => vars, "equations" => eqs, "expression_templates" => templates))
    )
end
function _tc_path(doc)
    path = joinpath(mktempdir(), "doc.esm")
    write(path, JSON3.write(doc))
    return path
end
function _tc_du(path, compiler)
    (prob, c) = _TC.Internal.counting(() -> _TC.esm_problem(path, (0.0, 1.0); compiler = compiler))
    u = copy(prob.u0) .+ 0.01 .* (1:length(prob.u0))
    d = similar(u); fill!(d, NaN)
    prob.f!(d, u, prob.p, 0.3)
    return d, c
end
# Native, interpreter and the expanded document's native build agree bit for
# bit; the build expands nothing.
# `ref`: the document whose native build is the reference (default: the
# expanded document).
function _tc_check(doc; ref = nothing)
    path = _tc_path(doc)
    a, ca = _tc_du(path, :native)
    b, cb = _tc_du(path, :interpreter)
    exp = ref === nothing ?
        _tc_path(JSON3.read(JSON3.write(_TC.serialize_esm_file(_TC.expand_document(_TC.load_path(path)))), Dict{String, Any})) :
        _tc_path(ref)
    e, _ = _tc_du(exp, :native)
    @test all(isfinite, a)
    @test all(a .=== b)
    @test all(a .=== e)
    @test get(ca, :tpl_expanded, 0) == 0
    @test get(cb, :tpl_expanded, 0) == 0
    return a
end

@testset "a reference's bindings are read in its own caller's frame" begin
    # Q's frame is shared by V's and W's calls (their bindings have one key);
    # each call's binding names its own caller's parameter.
    T = _tc_d(
        "P" => _tc_tpl(["s"], _tc_op("*", "s", "s")),
        "E" => _tc_tpl(["kn"], _tc_op("+", "kn", 1)),
        "Q" => _tc_tpl(["s"], _tc_ref("P"; s = "s")),
        "V" => _tc_tpl(["j"], _tc_op("-", _tc_ref("Q"; s = _tc_ref("E"; kn = "j")), _tc_ref("Q"; s = _tc_ref("E"; kn = _tc_op("-", "j", 1))))),
        "W" => _tc_tpl(["k"], _tc_ref("Q"; s = _tc_ref("E"; kn = _tc_op("-", "k", 1)))),
    )
    vars = _tc_d(
        "y" => _tc_d("type" => "unknown", "default" => 1.0, "units" => "1"),
        "x" => _tc_d("type" => "unknown", "units" => "1"),
    )
    eqs = Any[
        _tc_d("lhs" => "x", "rhs" => _tc_op("+", _tc_ref("V"; j = 3), _tc_ref("W"; k = 3))),
        _tc_d("lhs" => _tc_D("y"), "rhs" => _tc_op("*", "x", "y")),
    ]
    doc = _tc_doc(vars, eqs, T, Dict{String, Int}())
    @test isempty(_TC.validate_structural(_TC.load_path(_tc_path(doc))))
    _tc_check(doc)
end

@testset "a makearray region whose value is a parameter bound to an array-valued reference" begin
    N = 8
    T = _tc_d(
        "interior" => _tc_tpl(["u"], _tc_op(
            "faq", "u"; output_idx = Any["i"], ranges = _tc_d("i" => Any[2, N - 1]),
            expr = _tc_op("-", _tc_op("+", _tc_ix("u", _tc_op("-", "i", 1)), _tc_ix("u", _tc_op("+", "i", 1))), _tc_op("*", 2, _tc_ix("u", "i")))
        )),
        "frame" => _tc_tpl(["u", "inner"], _tc_d(
            "op" => "makearray", "args" => Any[],
            "regions" => Any[Any[Any[2, N - 1]], Any[Any[1, 1]], Any[Any[N, N]]],
            "values" => Any["inner", _tc_op("-", _tc_ix("u", 1)), _tc_op("-", _tc_ix("u", N))]
        )),
        "op" => _tc_tpl(["u"], _tc_ref("frame"; u = "u", inner = _tc_ref("interior"; u = "u"))),
    )
    vars = _tc_d("u" => _tc_d("type" => "unknown", "shape" => Any["x"], "default" => 1.0))
    eqs = Any[_tc_d("lhs" => _tc_D("u"), "rhs" => _tc_ref("op"; u = "u"))]
    _tc_check(_tc_doc(vars, eqs, T, Dict("x" => N)))
end

@testset "an aggregate body with a literal output index" begin
    N, S = 6, 3
    T = _tc_d(
        "lap_s" => _tc_tpl(["u"], _tc_d(
            "op" => "makearray", "args" => Any[],
            "regions" => Any[Any[Any[2, N], Any[1, S]], Any[Any[1, 1], Any[1, S]]],
            "values" => Any[
                _tc_op("faq", "u"; output_idx = Any["i", "s"], ranges = _tc_d("i" => Any[2, N], "s" => _tc_d("from" => "tr")),
                    expr = _tc_op("-", _tc_ix("u", _tc_op("-", "i", 1), "s"), _tc_ix("u", "i", "s"))),
                _tc_op("faq", "u"; output_idx = Any[1, "s"], ranges = _tc_d("s" => _tc_d("from" => "tr")),
                    expr = _tc_op("-", _tc_op("*", 0.5, _tc_ix("u", 1, "s")))),
            ]
        )),
    )
    vars = _tc_d("u" => _tc_d("type" => "unknown", "shape" => Any["x", "tr"], "default" => 1.0))
    eqs = Any[_tc_d("lhs" => _tc_D("u"), "rhs" => _tc_ref("lap_s"; u = "u"))]
    _tc_check(_tc_doc(vars, eqs, T, Dict("x" => N, "tr" => S)))
end

@testset "an elementwise array observed bound by name to an array parameter" begin
    N = 7
    T = _tc_d(
        "edges" => _tc_tpl(String[], _tc_op("faq"; output_idx = Any["k"], ranges = _tc_d("k" => _tc_d("from" => "xn")),
            expr = _tc_op("/", _tc_op("-", "k", 1), N))),
        # K on the N + 1 edges, read at both edges of cell i.
        "edge_mean" => _tc_tpl(["u", "K"], _tc_op(
            "faq", "u", "K"; output_idx = Any["i"], ranges = _tc_d("i" => _tc_d("from" => "x")),
            expr = _tc_op("*", _tc_op("+", _tc_ix("K", "i"), _tc_ix("K", _tc_op("+", "i", 1))), _tc_ix("u", "i"))
        )),
    )
    vars = _tc_d(
        "u" => _tc_d("type" => "unknown", "shape" => Any["x"], "default" => 1.0),
        "ze" => _tc_d("type" => "unknown", "shape" => Any["xn"]),
        "K" => _tc_d("type" => "unknown", "shape" => Any["xn"]),
    )
    eqs = Any[
        _tc_d("lhs" => "ze", "rhs" => _tc_ref("edges")),
        _tc_d("lhs" => "K", "rhs" => _tc_op("+", 1.0, "ze")),
        _tc_d("lhs" => _tc_D("u"), "rhs" => _tc_ref("edge_mean"; u = "u", K = "K")),
    ]
    path = _tc_path(_tc_doc(vars, eqs, T, Dict("x" => N, "xn" => N + 1)))
    a, ca = _tc_du(path, :native)
    b, cb = _tc_du(path, :interpreter)
    @test all(a .=== b)
    @test get(ca, :tpl_expanded, 0) == 0 && get(cb, :tpl_expanded, 0) == 0
    # The right-hand side in closed form, K[k] = 1 + (k - 1) / N.
    u = 1.0 .+ 0.01 .* (1:N)
    K = [1.0 + (k - 1) / N for k in 1:(N + 1)]
    @test isapprox(a, [(K[i] + K[i + 1]) * u[i] for i in 1:N]; rtol = 1.0e-14)
    # K is not folded into its reader (the reference would receive `1 + ze`,
    # an expression it cannot pass as an array): its definition is the
    # producer it denotes, materialized and passed by name.
    model = _TC.load_path(path).models["M"]
    eqs_t = _TC.Equation[_TC.Equation(_TC.expression_from_json(e["lhs"]), _TC.expression_from_json(e["rhs"])) for e in eqs]
    out, folded = _TC._fold_elementwise_array_observeds(eqs_t, model)
    @test !("K" in folded)
    kd = only(e.rhs for e in out if e.lhs isa _TC.VarExpr && e.lhs.name == "K")
    @test kd isa _TC.OpExpr && kd.op == "faq" && kd.output_idx !== nothing && length(kd.output_idx) == 1
end

@testset "a literal table template read in a body (native emitter)" begin
    N = 5
    T = _tc_d(
        "table" => _tc_tpl(String[], _tc_op("const"; value = Any[Any[1.0, 2.0], Any[-1.0, 0.5], Any[0.25, 3.0]])),
        "mix" => _tc_tpl(["r"], _tc_op(
            "faq", "r"; output_idx = Any["t", "i"], ranges = _tc_d("t" => _tc_d("from" => "tt"), "i" => _tc_d("from" => "x")),
            expr = _tc_op("+", _tc_ix(_tc_ref("table"), "t", 1), _tc_op("*", _tc_ix(_tc_ref("table"), "t", 2), _tc_ix("r", "i")))
        )),
    )
    vars = _tc_d(
        "r" => _tc_d("type" => "unknown", "shape" => Any["x"]),
        "m" => _tc_d("type" => "unknown", "shape" => Any["tt", "x"]),
        "u" => _tc_d("type" => "unknown", "shape" => Any["tt", "x"], "default" => 1.0),
    )
    eqs = Any[
        _tc_d("lhs" => "r", "rhs" => _tc_op("faq"; output_idx = Any["i"], ranges = _tc_d("i" => _tc_d("from" => "x")), expr = _tc_op("*", 0.1, "i"))),
        _tc_d("lhs" => "m", "rhs" => _tc_ref("mix"; r = "r")),
        _tc_d("lhs" => _tc_D("u"), "rhs" => _tc_op("faq", "u", "m"; output_idx = Any["t", "i"],
            ranges = _tc_d("t" => _tc_d("from" => "tt"), "i" => _tc_d("from" => "x")),
            expr = _tc_op("*", _tc_ix("m", "t", "i"), _tc_ix("u", "t", "i")))),
    ]
    _tc_check(_tc_doc(vars, eqs, T, Dict("x" => N, "tt" => 3)))
end
