# `broadcast` (esm-spec §4.3.4) + name-based operand alignment.
#
# Two semantics land here, both pinned against the SAME oracle: the explicit
# `aggregate` spelling with per-cell `index` gathers, which this binding has
# always evaluated correctly.
#
#  1. `broadcast(fn=F, args)` ≡ `{"op":F,"args":args}`. The build lowers the node
#     to its `fn` op, so the identity holds by construction; the `fn` contract
#     (missing / unknown / structural / wrong arity) is a HARD error from both
#     `validate()` and the build.
#  2. An element-wise array operand aligns with the result by index-set NAME:
#     a lower-rank operand broadcasts along the missing axes, a name-PERMUTED
#     operand transposes (it is not reinterpreted positionally), and an operand
#     naming an axis the result does not have is a hard error.
#
# Anonymous shapes (an `aggregate`/`arrayop`/`makearray` producer, whose
# `output_idx` symbols are node-local) keep POSITIONAL semantics — pinned below
# so the name rule can never silently widen to them.
using Test
using JSON3
import EarthSciAST as ESS
import ModelingToolkit          # loads EarthSciASTMTKExt (exporter `fn` vocabulary)
import Symbolics
const E = ESS
include("testutils.jl")

# ---------------------------------------------------------------------------
# Wire-form builders (these documents are authored as JSON, like the bug
# reproducers, so the whole load → flatten → build path is exercised).
# ---------------------------------------------------------------------------
_bc_op(o, a...) = Dict{String,Any}("op" => o, "args" => collect(Any, a))
_bc_idx(a...)   = _bc_op("index", a...)
_bc_bcast(fn, a...) = fn === nothing ?
    Dict{String,Any}("op" => "broadcast", "args" => collect(Any, a)) :
    Dict{String,Any}("op" => "broadcast", "fn" => fn, "args" => collect(Any, a))
_bc_agg(out, ranges, body) = Dict{String,Any}(
    "op" => "aggregate", "output_idx" => collect(Any, out),
    "ranges" => Dict{String,Any}(k => Dict{String,Any}("from" => v)
                                 for (k, v) in ranges),
    "args" => Any[], "expr" => body)
_bc_D(v) = Dict{String,Any}("op" => "D", "wrt" => "t", "args" => Any[v])
_bc_eq(lhs, rhs) = Dict{String,Any}("lhs" => lhs, "rhs" => rhs)

const _BC_SETS = ("lon" => 3, "lat" => 2, "lev" => 2)

function _bc_doc(name, vars, eqs; sets = _BC_SETS)
    Dict{String,Any}(
        "esm" => "0.6.0",
        "metadata" => Dict{String,Any}("name" => name),
        "index_sets" => Dict{String,Any}(
            k => Dict{String,Any}("kind" => "interval", "size" => v) for (k, v) in sets),
        "models" => Dict{String,Any}(name => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
end

# RHS at t = 0 from the built evaluator, as a name → value map.
function _bc_rhs(doc::AbstractDict)
    f!, u0, p, _t, vm = E.build_evaluator(doc)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return Dict{String,Float64}(k => du[i] for (k, i) in vm)
end

_bc_validate(doc::AbstractDict) = E.validate(E.coerce_esm_file(JSON3.read(JSON3.write(doc))))
_bc_types(res) = sort!(String[e.error_type for e in res.structural_errors])
_bc_err(f) = try; f(); nothing; catch e; e; end

# The §4.3.4 fixture family from GitHub #100: a 3×2×2 `[lon,lat,lev]` state fed
# by lower-rank observeds. `w1[lat] = 10j`, `w2[lon,lat] = i + 10j`,
# `z1[lev] = 100k`, and `wT[lat,lon] = i + 10j` — the SAME field as `w2` with its
# axes declared in the opposite order.
function _bc_vars()
    Dict{String,Any}(
        "dp" => Dict{String,Any}("type" => "unknown", "units" => "1",
            "shape" => Any["lon", "lat", "lev"], "default" => 0),
        "w1" => Dict{String,Any}("type" => "observed", "units" => "1",
            "shape" => Any["lat"],
            "expression" => _bc_agg(("j",), ("j" => "lat",), _bc_op("*", 10, "j"))),
        "w2" => Dict{String,Any}("type" => "observed", "units" => "1",
            "shape" => Any["lon", "lat"],
            "expression" => _bc_agg(("i", "j"), ("i" => "lon", "j" => "lat"),
                                    _bc_op("+", "i", _bc_op("*", 10, "j")))),
        "wT" => Dict{String,Any}("type" => "observed", "units" => "1",
            "shape" => Any["lat", "lon"],
            "expression" => _bc_agg(("j", "i"), ("i" => "lon", "j" => "lat"),
                                    _bc_op("+", "i", _bc_op("*", 10, "j")))),
        "z1" => Dict{String,Any}("type" => "observed", "units" => "1",
            "shape" => Any["lev"],
            "expression" => _bc_agg(("k",), ("k" => "lev",), _bc_op("*", 100, "k"))))
end

# `D(dp) = <rhs>` over the #100 variable set, under a given model name.
_bc_model(name, rhs) = _bc_doc(name, _bc_vars(), Any[_bc_eq(_bc_D("dp"), rhs)])

# The explicit per-cell oracle: `aggregate` over (i,j,k) with `body` written in
# those index symbols.
_bc_oracle(name, body) = _bc_model(name, _bc_agg(("i", "j", "k"),
    ("i" => "lon", "j" => "lat", "k" => "lev"), body))

@testset "broadcast + name-based operand alignment (esm-spec §4.3.4)" begin

@testset "unary broadcast(fn=F,[x]) ≡ F(x)" begin
    # Scalar model: the identity is about the OPERATOR, so pin it on the
    # cheapest carrier, over every unary op the issue enumerates.
    for f in ["-", "neg", "log", "exp", "sqrt", "abs", "sin", "cos", "tanh",
              "log10", "sign", "floor", "ceil"]
        vars = Dict{String,Any}(
            "x" => Dict{String,Any}("type" => "unknown", "units" => "1", "default" => 0.7))
        plain = _bc_doc("P", vars, Any[_bc_eq(_bc_D("x"), _bc_op(f, "x"))])
        bcast = _bc_doc("P", vars, Any[_bc_eq(_bc_D("x"), _bc_bcast(f, "x"))])
        @test _bc_rhs(bcast)["x"] === _bc_rhs(plain)["x"]
    end
    # #101 end to end: `dp' = broadcast(fn="-",[div_h])` with `div_h = a*dp`,
    # a = -0.3 — the case Rust/Python answered with exp(-0.3). The RHS at t=0
    # must be `+0.3·dp`, i.e. the NEGATION of div_h, not div_h itself.
    vars = Dict{String,Any}(
        "dp" => Dict{String,Any}("type" => "unknown", "units" => "1",
            "shape" => Any["lon", "lat", "lev"], "default" => 1),
        "a" => Dict{String,Any}("type" => "parameter", "units" => "1", "default" => -0.3),
        "div_h" => Dict{String,Any}("type" => "observed", "units" => "1",
            "shape" => Any["lon", "lat", "lev"],
            "expression" => _bc_op("*", "a", "dp")))
    bc = _bc_rhs(_bc_doc("N", vars, Any[_bc_eq(_bc_D("dp"), _bc_bcast("-", "div_h"))]))
    pl = _bc_rhs(_bc_doc("N", vars, Any[_bc_eq(_bc_D("dp"), _bc_op("-", "div_h"))]))
    @test bc == pl
    @test bc["dp[1,1,1]"] ≈ 0.3
    @test bc["dp[3,2,2]"] ≈ 0.3
end

@testset "n-ary broadcast ≡ the same n-ary scalar op" begin
    vars = Dict{String,Any}(
        "x" => Dict{String,Any}("type" => "unknown", "units" => "1", "default" => 0.7),
        "b" => Dict{String,Any}("type" => "parameter", "units" => "1", "default" => 2.5),
        "c" => Dict{String,Any}("type" => "parameter", "units" => "1", "default" => 4.0))
    for (f, args) in [("*", Any["x", "b"]), ("-", Any["x", "b"]),
                      ("+", Any["x", "b", "c"]), ("/", Any["x", "b"]),
                      ("max", Any["x", "b"]), ("min", Any["x", "b", "c"]),
                      ("atan2", Any["x", "b"]), ("ifelse", Any["x", "b", "c"]),
                      # The degenerate 1-operand n-ary forms: legal exactly
                      # because `{op:"+",args:[x]}` is, and equal to it (the
                      # identity). The shared property corpus emits this node.
                      ("+", Any["x"]), ("*", Any["x"])]
        plain = _bc_doc("P", vars, Any[_bc_eq(_bc_D("x"), _bc_op(f, args...))])
        bcast = _bc_doc("P", vars, Any[_bc_eq(_bc_D("x"), _bc_bcast(f, args...))])
        @test _bc_rhs(bcast)["x"] === _bc_rhs(plain)["x"]
    end
    # `broadcast(fn:"+",[1])` — the exact shape of tests/property_corpus/
    # expressions/expr_039.json — lowers to `+(1)` and validates clean.
    lit = E.OpExpr("broadcast", E.ASTExpr[E.IntExpr(1)]; fn="+")
    low = E._lower_broadcast(lit)
    @test low isa E.OpExpr && low.op == "+" && length(low.args) == 1
    @test E._broadcast_fn_problem("+", 1) === nothing
    @test E._broadcast_fn_problem("*", 1) === nothing
end

@testset "multi-operand broadcast over NAME-ALIGNED array operands" begin
    # `broadcast(fn="*", [w2[lon,lat], z1[lev]])` in a [lon,lat,lev] result must
    # equal the explicit aggregate — case B of #100 through the broadcast door.
    oracle = _bc_rhs(_bc_oracle("B", _bc_op("*", _bc_idx("w2", "i", "j"),
                                                 _bc_idx("z1", "k"))))
    got = _bc_rhs(_bc_model("B", _bc_bcast("*", "w2", "z1")))
    @test got == oracle
end

@testset "case A: [lat] operand replicates over lon and lev" begin
    oracle = _bc_rhs(_bc_oracle("A", _bc_idx("w1", "j")))
    bare   = _bc_rhs(_bc_model("A", "w1"))
    @test bare == oracle
    # dp[i,j,k] = 10·j for every i,k (the values Rust reports as correct).
    for i in 1:3, k in 1:2
        @test bare["dp[$i,1,$k]"] ≈ 10.0
        @test bare["dp[$i,2,$k]"] ≈ 20.0
    end
end

@testset "case B: [lon,lat] × [lev] broadcast over the missing axes" begin
    oracle = _bc_rhs(_bc_oracle("B", _bc_op("*", _bc_idx("w2", "i", "j"),
                                                 _bc_idx("z1", "k"))))
    bare   = _bc_rhs(_bc_model("B", _bc_op("*", "w2", "z1")))
    @test bare == oracle
    # (i + 10j)·100k — the reference values Rust and Python also produce.
    @test bare["dp[1,1,1]"] ≈ 1100.0
    @test bare["dp[2,1,1]"] ≈ 1200.0
    @test bare["dp[3,1,1]"] ≈ 1300.0
    @test bare["dp[1,2,1]"] ≈ 2100.0
    @test bare["dp[2,2,1]"] ≈ 2200.0
    @test bare["dp[3,2,1]"] ≈ 2300.0
    @test bare["dp[1,1,2]"] ≈ 2200.0
    @test bare["dp[2,1,2]"] ≈ 2400.0
    @test bare["dp[3,1,2]"] ≈ 2600.0
end

@testset "case C: equal-rank NAME-PERMUTED operand transposes, not reinterprets" begin
    # `wT` is declared [lat,lon]; the result is [lon,lat,lev]. Both ranks and
    # both name SETS overlap, so every rank guard passes — this is the silent
    # transpose. The oracle indexes wT by NAME order: index(wT, j, i).
    oracle = _bc_rhs(_bc_oracle("C", _bc_idx("wT", "j", "i")))
    bare   = _bc_rhs(_bc_model("C", "wT"))
    @test bare == oracle
    # wT[j,i] = i + 10j, so dp[i,j,k] = i + 10j. Under the OLD positional
    # gather dp[2,1,k] would have read wT[2,1] = 1 + 20 = 21.
    @test bare["dp[2,1,1]"] ≈ 12.0
    @test bare["dp[3,1,2]"] ≈ 13.0
    @test bare["dp[1,2,1]"] ≈ 21.0
end

@testset "operand over an index set ABSENT from the result is a hard error" begin
    vars = _bc_vars()
    vars["wq"] = Dict{String,Any}("type" => "observed", "units" => "1",
        "shape" => Any["qux"],
        "expression" => _bc_agg(("q",), ("q" => "qux",), _bc_op("*", 7, "q")))
    doc = _bc_doc("X", vars, Any[_bc_eq(_bc_D("dp"), _bc_op("*", "w1", "wq"))];
                  sets = (_BC_SETS..., "qux" => 4))

    res = _bc_validate(doc)
    @test !res.is_valid
    @test "array_shape_mismatch" in _bc_types(res)
    hit = only([e for e in res.structural_errors
                if e.error_type == "array_shape_mismatch"])
    @test hit.details["variable"] == "wq"
    @test hit.details["index_set"] == "qux"
    @test hit.path == "/models/X/equations/0/rhs"

    err = _bc_err(() -> E.build_evaluator(doc))
    @test err isa E.TreeWalkError
    @test err.code == "E_TREEWALK_ARRAY_SHAPE_MISMATCH"
end

@testset "broadcast `fn` contract — validate() findings" begin
    mk(node) = _bc_doc("F", Dict{String,Any}(
        "x" => Dict{String,Any}("type" => "unknown", "units" => "1", "default" => 0.7)),
        Any[_bc_eq(_bc_D("x"), node)])

    # ONE cross-binding diagnostic code — `invalid_broadcast_fn`, registered in
    # esm-spec §9.6.6 — for all four defects; `details["reason"]` distinguishes.
    cases = [
        (_bc_bcast("not_a_real_op", "x"), "unknown"),
        (_bc_bcast(nothing, "x"),         "missing"),
        (_bc_bcast("aggregate", "x"),     "non_scalar"),
        (_bc_bcast("index", "x"),         "non_scalar"),
        (_bc_bcast("makearray", "x"),     "non_scalar"),
        (_bc_bcast("grad", "x"),          "non_scalar"),
        (_bc_bcast("sin", "x", "x"),      "arity"),
        (_bc_bcast("/", "x"),             "arity"),
        (_bc_bcast("ifelse", "x", "x"),   "arity"),
        (_bc_bcast("pi", "x"),            "arity"),
        # esm-spec §4.2: a binding MUST reject `min`/`max` below two arguments,
        # and `broadcast` inherits that floor from the registry arity.
        (_bc_bcast("min", "x"),           "arity"),
        (_bc_bcast("max", "x"),           "arity"),
    ]
    for (node, reason) in cases
        res = _bc_validate(mk(node))
        @test !res.is_valid
        hits = [e for e in res.structural_errors
                if e.error_type == "invalid_broadcast_fn"]
        @test length(hits) == 1
        @test hits[1].details["reason"] == reason
        @test hits[1].path == "/models/F/equations/0/rhs"
    end
    # A well-formed broadcast produces no finding at all — INCLUDING the
    # degenerate 1-operand `+`/`*`, which is legal precisely because
    # `{op:"+",args:[x]}` is (the shared property corpus emits it).
    for node in [_bc_bcast("-", "x"), _bc_bcast("+", "x"), _bc_bcast("*", "x"),
                 _bc_bcast("min", "x", "x"), _bc_bcast("+", "x", "x", "x")]
        @test isempty([e for e in _bc_validate(mk(node)).structural_errors
                       if e.error_type == "invalid_broadcast_fn"])
    end
    # The contract is enforced in NESTED positions too (an observed's
    # `expression`, not only an equation RHS).
    nested = _bc_doc("F", Dict{String,Any}(
        "x" => Dict{String,Any}("type" => "unknown", "units" => "1", "default" => 0.7),
        "y" => Dict{String,Any}("type" => "observed", "units" => "1",
            "expression" => _bc_op("+", 1, _bc_bcast("nope", "x")))),
        Any[_bc_eq(_bc_D("x"), "y")])
    res = _bc_validate(nested)
    hits = [e for e in res.structural_errors if e.error_type == "invalid_broadcast_fn"]
    @test length(hits) == 1
    @test hits[1].path == "/models/F/variables/y/expression"
end

@testset "broadcast `fn` contract — build-time rejection" begin
    mk(node) = _bc_doc("F", Dict{String,Any}(
        "x" => Dict{String,Any}("type" => "unknown", "units" => "1", "default" => 0.7)),
        Any[_bc_eq(_bc_D("x"), node)])
    for (node, code) in [(_bc_bcast("not_a_real_op", "x"), "E_TREEWALK_BROADCAST_FN"),
                         (_bc_bcast(nothing, "x"),         "E_TREEWALK_BROADCAST_FN"),
                         (_bc_bcast("aggregate", "x"),     "E_TREEWALK_BROADCAST_FN"),
                         (_bc_bcast("sin", "x", "x"),      "E_TREEWALK_BROADCAST_FN"),
                         (_bc_bcast("/", "x"),             "E_TREEWALK_BROADCAST_FN"),
                         (_bc_bcast("min", "x"),           "E_TREEWALK_BROADCAST_FN")]
        err = _bc_err(() -> E.build_evaluator(mk(node)))
        @test err isa E.TreeWalkError
        @test err.code == code
    end
end

@testset "anonymous shapes keep POSITIONAL semantics" begin
    # A producer in element-wise position carries node-local `output_idx`
    # symbols (`p`/`q`/`r`), NOT index-set names, so it is gathered positionally
    # over the result loops. Value = p + 10q + 100r at (i,j,k).
    prod = _bc_agg(("p", "q", "r"),
                   ("p" => "lon", "q" => "lat", "r" => "lev"),
                   _bc_op("+", "p", _bc_op("+", _bc_op("*", 10, "q"),
                                                _bc_op("*", 100, "r"))))
    got = _bc_rhs(_bc_model("An", prod))
    @test got["dp[2,1,2]"] ≈ 2 + 10 + 200
    @test got["dp[3,2,1]"] ≈ 3 + 20 + 100
    # …and the same producer multiplied by a NAME-aligned lower-rank operand:
    # the producer stays positional while `w1[lat]` aligns by name.
    got2 = _bc_rhs(_bc_model("An2", _bc_op("*", prod, "w1")))
    @test got2["dp[2,1,2]"] ≈ (2 + 10 + 200) * 10
    @test got2["dp[3,2,1]"] ≈ (3 + 20 + 100) * 20
end

@testset "reshape / transpose / concat still reach the unsupported-op gate" begin
    vars = Dict("u" => ESS.ModelVariable(ESS.UnknownVariable))
    ics = Dict("u" => 1.0)
    for node in [_op("reshape", _v("u"); shape=Any[1, 1]),
                 _op("transpose", _v("u"); perm=Any[0]),
                 _op("concat", _v("u"), _v("u"); axis=0)]
        m = ESS.Model(vars, [ESS.Equation(_D("u"), node)])
        err = _bc_err(() -> E.build_evaluator(m; initial_conditions=ics))
        @test err isa E.TreeWalkError
        @test err.code == "E_TREEWALK_UNSUPPORTED_OP"
    end
    # …while a typed `broadcast` node with a legal `fn` now LOWERS and runs.
    m = ESS.Model(vars, [ESS.Equation(_D("u"), _op("broadcast", _v("u"); fn="-"))])
    f!, u0, p, _t, vm = E.build_evaluator(m; initial_conditions=ics)
    du = similar(u0); f!(du, u0, p, 0.0)
    @test du[vm["u"]] == -1.0
end

@testset "explicit over-subscription still hits the ndim guard" begin
    # Name-based alignment fixes what the LIFT generates; an EXPLICIT gather
    # with the wrong number of subscripts is still a hard error (the guards were
    # narrowed to their real job, not widened into acceptance).
    doc = _bc_oracle("G", _bc_idx("w1", "i", "j", "k"))   # 3 subscripts into 1-D w1
    err = _bc_err(() -> E.build_evaluator(doc))
    @test err isa E.TreeWalkError
    @test err.code == "E_TREEWALK_INDEX_NDIM"
end

@testset "the element-wise descent set is the non-structural half of the registry" begin
    # `_is_scalar_op` IS the descent predicate for name-based alignment, in both
    # the build rewrite (`_wrap_bare_array_refs`) and `validate()`
    # (`_check_broadcast_axes!`). Rust's `is_elementwise_op` and Python's
    # scalar-fn category derivation cover the same vocabulary; the ops below are
    # the ones every binding must REFUSE to descend through, because each
    # consumes its operands whole under its own contract.
    for n in ["aggregate", "arrayop", "index", "makearray", "broadcast",
              "reshape", "transpose", "concat",
              "skolem", "intersect_polygon", "polygon_intersection_area",
              "grad", "div", "laplacian", "D", "ic", "fn", "call",
              "const", "enum", "some_open_tier_user_op"]
        @test !E._is_scalar_op(n)
    end
    # A non-element-wise consumer's operand is NOT axis-checked: `clip[ring,coord]
    # = intersect_polygon(src[verts,coord], …)` is a kernel contract, not a
    # broadcast, and must stay valid.
    vars = Dict{String,Any}(
        "dp" => Dict{String,Any}("type" => "unknown", "units" => "1",
            "shape" => Any["lon", "lat", "lev"], "default" => 0),
        "src" => Dict{String,Any}("type" => "parameter", "units" => "1",
            "shape" => Any["qux"]))
    doc = _bc_doc("K", vars,
        Any[_bc_eq(_bc_D("dp"), _bc_op("some_open_tier_user_op", "src"))];
        sets = (_BC_SETS..., "qux" => 4))
    @test isempty([e for e in _bc_validate(doc).structural_errors
                   if e.error_type == "array_shape_mismatch"])
end

@testset "MTK exporter speaks the same `fn` vocabulary" begin
    # The shared `tests/fixtures/arrayop/` corpus runs through the MTK exporter,
    # not the tree-walk evaluator, so its `broadcast` vocabulary must be the same
    # one `validate()` accepts. It used to be a hand-listed dozen ops; it is now
    # derived from the registry (arithmetic + elementary rows with a scalar fn).
    MTKExt = Base.get_extension(EarthSciAST, :EarthSciASTMTKExt)
    @test MTKExt !== nothing
    fns = MTKExt._BROADCAST_FNS
    for n in ["+", "-", "*", "/", "^", "pow", "neg", "exp", "log", "log10",
              "sin", "cos", "tan", "sqrt", "abs", "sign", "floor", "ceil",
              "tanh", "asin", "atan", "atan2", "min", "max"]
        @test haskey(fns, n)
    end
    # Comparison / logical / control rows stay OUT: broadcasting them would
    # yield symbolic Booleans, not the spec's 1.0/0.0 comparison values.
    for n in ["<", "==", "and", "or", "not", "ifelse", "Pre", "pi",
              "aggregate", "index", "makearray", "broadcast"]
        @test !haskey(fns, n)
    end
    # A unary broadcast lowers through the exporter to the plain unary op — the
    # shape `tests/fixtures/arrayop/27_broadcast_unary.esm` exercises.
    vd = Dict{String,Any}("u" => Symbolics.variable(:u))
    dd = Dict{String,Any}()
    for f in ["-", "exp", "sqrt", "abs", "sin", "tan"]
        bc = MTKExt._build_broadcast(
            ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn=f), vd, nothing, dd)
        plain = MTKExt._esm_to_symbolic(_op(f, _v("u")), vd, nothing, dd)
        @test isequal(bc, plain)
    end
    # The derived vocabulary is a strict SUPERSET of this exporter's plain-op
    # ladder, which has no arm for the canonicalize-internal aliases `neg`/`pow`
    # (nor for `floor`/`ceil`/`sign`) — `broadcast(fn:"neg")` still lowers, to
    # the same symbolic as unary `-`.
    @test isequal(MTKExt._build_broadcast(
                      ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn="neg"),
                      vd, nothing, dd),
                  MTKExt._esm_to_symbolic(_op("-", _v("u")), vd, nothing, dd))
    # …and the §4.3.4 `fn` contract is enforced there too.
    for bad in [ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn="not_a_real_op"),
                ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]),
                ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn="aggregate"),
                ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u"), _v("u")]; fn="sin"),
                ESS.OpExpr("broadcast", ESS.ASTExpr[_v("u")]; fn="min")]
        @test_throws ArgumentError MTKExt._build_broadcast(bad, vd, nothing, dd)
    end
end

@testset "degenerate 1-operand `+`/`*` renders in call form" begin
    # Cross-binding display pin (Rust `join_or_call`: infix only at ≥ 2 args).
    x = E.VarExpr("x")
    for op in ("+", "*")
        n = E.OpExpr(op, E.ASTExpr[x])
        @test E.format_expression(n, :ascii) == "$op(x)"
        @test E.format_expression(n, :unicode) == "$op(x)"
    end
end

@testset "op registry: the scalar-operator predicate behind `fn`" begin
    for n in ["+", "-", "*", "/", "^", "neg", "pow", "sin", "log", "min", "max",
              "<", "==", "and", "not", "ifelse", "pi"]
        @test E._is_scalar_op(n)
    end
    for n in ["aggregate", "arrayop", "index", "makearray", "broadcast",
              "reshape", "transpose", "concat", "D", "ic", "grad", "div",
              "laplacian", "fn", "call", "const", "enum", "skolem",
              "intersect_polygon", "polygon_intersection_area",
              "definitely_not_an_op"]
        @test !E._is_scalar_op(n)
    end
    @test E._broadcast_fn_problem("-", 1) === nothing
    @test E._broadcast_fn_problem("-", 2) === nothing
    @test E._broadcast_fn_problem("-", 3).kind === :arity
    @test E._broadcast_fn_problem(nothing, 1).kind === :missing
    @test E._broadcast_fn_problem("", 1).kind === :missing
    @test E._broadcast_fn_problem("zzz", 1).kind === :unknown
    @test E._broadcast_fn_problem("aggregate", 1).kind === :non_scalar
end

end
