# Differential oracle for structural AST interning (perf plan A1, src/intern.jl):
# build the SAME model with interning ON (the default) and OFF
# (ESS_INTERN_DISABLE=1, byte-for-byte the pre-interning build) and require
#   * identical state maps (var_map) and initial states (u0/p),
#   * BIT-identical du at several (u, t) probes,
# across the representative gridded shapes: the compile-once template-reference
# fixture (tests/bench/transport_3axis_7cubed_fullrank.esm — the tier whose
# `_TemplateCtx.sites` / variant keys the interning pre-audit re-keys), the
# affine-stencil fixtures (2-D Laplacian, makearray regions, const-coefficient
# diffusion), an observed-chain model (the `_resolve_observed` splice path),
# and the per-cell reference (ESS_STENCIL_DISABLE=1) and :oop emitters.
# Also pins the interner's own merge/no-merge semantics (bit-egal literals,
# Int-vs-Float `const` values, `wrt`/field discrimination, DAG idempotence).

using Test
using EarthSciAST
using EarthSciAST: _InternCtx, _intern_expr, _intern_model

include("testutils.jl")
const ESM = EarthSciAST

# Deterministic probe states.
_probe_states(n) = (
    Float64[sin(0.1 * i) + 1.5 for i in 1:n],
    Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n],
    Float64[1.5 + 0.25 * sin(0.7 * i) * cos(0.05 * i) for i in 1:n],
)

# Build `model` under `env` and return (du probes, u0, p, var_map).
function _intern_probe_model(model; env=(), form::Symbol=:inplace,
                             ics=Dict{String,Float64}(), const_arrays=Dict())
    withenv(env...) do
        f, u0, p, _, vmap = ESM.build_evaluator(model; initial_conditions=ics,
                                                form=form, const_arrays=const_arrays)
        dus = Vector{Float64}[]
        for (ti, u) in zip((0.0, 0.7, 3.25), _probe_states(length(u0)))
            if form === :oop
                push!(dus, Vector{Float64}(f(u, p, ti)))
            else
                du = similar(u0)
                f(du, u, p, ti)
                push!(dus, copy(du))
            end
        end
        (dus, u0, p, vmap)
    end
end

# The on/off differential for one model: interning default vs disabled.
function _intern_oracle(model; form=:inplace, ics=Dict{String,Float64}(),
                        const_arrays=Dict())
    on = _intern_probe_model(model; env=(("ESS_INTERN_DISABLE" => nothing),),
                             form=form, ics=ics, const_arrays=const_arrays)
    off = _intern_probe_model(model; env=(("ESS_INTERN_DISABLE" => "1"),),
                              form=form, ics=ics, const_arrays=const_arrays)
    @test on[4] == off[4]                    # identical state map
    @test on[2] == off[2]                    # identical u0 (bitwise: Float64 ==)
    @test on[3] === off[3] || isequal(on[3], off[3])   # identical params
    for k in eachindex(on[1])
        @test on[1][k] == off[1][k]          # bit-identical du
    end
    @test any(du -> sum(abs, du) > 0, on[1]) # and not trivially zero
    return nothing
end

# ---- gridded fixture builders (mirrors stencil_affine_diff_test.jl) ----

function _int_stencil2d_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable; shape=["i", "j"]))
    body = _op("+",
        _idx("u", _op("-", _v("i"), _i(1)), _v("j")),
        _op("*", _n(-4.0), _idx("u", _v("i"), _v("j"))),
        _idx("u", _op("+", _v("i"), _i(1)), _v("j")),
        _idx("u", _v("i"), _op("-", _v("j"), _i(1))),
        _idx("u", _v("i"), _op("+", _v("j"), _i(1))))
    lhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=_Didx("u", _v("i"), _v("j")), ranges=Dict("i" => [1, N], "j" => [1, N]))
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i", "j"],
        expr_body=body, ranges=Dict("i" => [1, N], "j" => [1, N]))
    ESM.Model(vars, [ESM.Equation(lhs, rhs)])
end

function _int_makearray_region_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    fwd = _op("-", _idx("u", _op("+", _v("i"), _i(1))), _idx("u", _v("i")))
    ctr = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    bwd = _op("-", _idx("u", _v("i")), _idx("u", _op("-", _v("i"), _i(1))))
    mk = ESM.OpExpr("makearray", ESM.ASTExpr[];
        regions=[[[1, 1]], [[2, N - 1]], [[N, N]]],
        values=ESM.ASTExpr[fwd, ctr, bwd])
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("index", mk, _v("i")), "i", 1, N))])
end

function _int_const_coef_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    body = _op("*", _idx("K", _v("i")), lap)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# Observed-chain model: two observeds share a subtree, one feeds the other, and
# the RHS references both — the `_resolve_observed` splice + prelude-slot path.
# The DUPLICATED template-free spelling (`k*(u+v)` written out twice in `w2`)
# is what interning must merge without changing a bit.
function _int_observed_model()
    kuv = _op("*", _v("k"), _op("+", _v("u"), _v("v")))
    w1 = ESM.ModelVariable(ESM.ObservedVariable; expression=kuv)
    w2 = ESM.ModelVariable(ESM.ObservedVariable;
        expression=_op("+", _op("*", _v("k"), _op("+", _v("u"), _v("v"))),
                       _op("sin", _v("w1"))))
    vars = Dict(
        "u" => ESM.ModelVariable(ESM.StateVariable; default=1.25),
        "v" => ESM.ModelVariable(ESM.StateVariable; default=0.5),
        "k" => ESM.ModelVariable(ESM.ParameterVariable; default=2.0),
        "w1" => w1, "w2" => w2)
    eqs = [ESM.Equation(_D("u"), _op("-", _v("w2"), _v("u"))),
           ESM.Equation(_D("v"), _op("*", _n(-0.5), _v("w1")))]
    ESM.Model(vars, eqs)
end

@testset "intern differential oracle (A1)" begin

    @testset "interner unit semantics" begin
        ctx = _InternCtx()
        # structurally identical subtrees merge; the DAG is idempotent
        a = _op("+", _op("*", _v("x"), _i(2)), _op("*", _v("x"), _i(2)))
        ai = _intern_expr(a, ctx)
        @test ai.args[1] === ai.args[2]
        @test _intern_expr(ai, ctx) === ai
        b = _intern_expr(_op("*", _v("x"), _i(2)), ctx)
        @test b === ai.args[1]
        # bit-egal literal discrimination: 2 (Int) vs 2.0 (Float), 0.0 vs -0.0
        @test _intern_expr(_op("*", _v("x"), _n(2.0)), ctx) !== b
        z1 = _intern_expr(_op("+", _v("x"), _n(0.0)), ctx)
        z2 = _intern_expr(_op("+", _v("x"), _n(-0.0)), ctx)
        @test z1 !== z2
        # const-op payload type discrimination (Int 1 vs Float 1.0 on the wire)
        c1 = _intern_expr(ESM.OpExpr("const", ESM.ASTExpr[]; value=1), ctx)
        c2 = _intern_expr(ESM.OpExpr("const", ESM.ASTExpr[]; value=1.0), ctx)
        c3 = _intern_expr(ESM.OpExpr("const", ESM.ASTExpr[]; value=1), ctx)
        @test c1 !== c2
        @test c1 === c3
        # nested const arrays merge by content, split by content
        v1 = _intern_expr(ESM.OpExpr("const", ESM.ASTExpr[]; value=Any[1, 2, 3]), ctx)
        v2 = _intern_expr(ESM.OpExpr("const", ESM.ASTExpr[]; value=Any[1, 2, 3]), ctx)
        v3 = _intern_expr(ESM.OpExpr("const", ESM.ASTExpr[]; value=Any[1, 2, 4]), ctx)
        @test v1 === v2
        @test v1 !== v3
        # non-child field discrimination: wrt, output_idx, ranges, filter
        @test _intern_expr(_op("D", _v("u"); wrt="t"), ctx) !==
              _intern_expr(_op("D", _v("u"); wrt="x"), ctx)
        @test _intern_expr(_op("D", _v("u"); wrt="t"), ctx) ===
              _intern_expr(_op("D", _v("u"); wrt="t"), ctx)
        r1 = _intern_expr(_ao1(_v("i"), "i", 1, 7), ctx)
        r2 = _intern_expr(_ao1(_v("i"), "i", 1, 8), ctx)
        r3 = _intern_expr(_ao1(_v("i"), "i", 1, 7), ctx)
        @test r1 !== r2
        @test r1 === r3
        # expression-valued range bounds are interned and discriminated
        d1 = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
            expr_body=_v("i"), ranges=Dict{String,Any}("i" => Any[1, _op("+", _v("n"), _i(1))]))
        d2 = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
            expr_body=_v("i"), ranges=Dict{String,Any}("i" => Any[1, _op("+", _v("n"), _i(1))]))
        d3 = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"],
            expr_body=_v("i"), ranges=Dict{String,Any}("i" => Any[1, _op("+", _v("n"), _i(2))]))
        @test _intern_expr(d1, ctx) === _intern_expr(d2, ctx)
        @test _intern_expr(d1, ctx) !== _intern_expr(d3, ctx)
        # the model pass does not mutate the input model
        m = _int_observed_model()
        w2_before = m.variables["w2"].expression
        eq1_before = m.equations[1]
        mi = _intern_model(m, _InternCtx())
        @test m.variables["w2"].expression === w2_before
        @test m.equations[1] === eq1_before
    end

    @testset "1D second-difference stencil (N=$N)" for N in (8, 33)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        _intern_oracle(_stencil_model(N); ics=ics)
    end

    @testset "2D 5-point Laplacian (N=$N)" for N in (5, 16)
        ics = Dict("u[$i,$j]" => sin(0.2i) * cos(0.3j) + 0.05i * j
                   for i in 1:N, j in 1:N)
        _intern_oracle(_int_stencil2d_model(N); ics=ics)
    end

    @testset "makearray region stencil (N=$N)" for N in (8, 32)
        ics = Dict("u[$k]" => 0.3 + sin(0.4k)^2 for k in 1:N)
        _intern_oracle(_int_makearray_region_model(N); ics=ics)
    end

    @testset "const-coefficient diffusion" begin
        N = 16
        ics = Dict("u[$k]" => cos(0.2k) + 0.1k for k in 1:N)
        K = Dict("K" => Float64[0.5 + 0.1 * sin(0.9k) for k in 1:N])
        _intern_oracle(_int_const_coef_model(N); ics=ics, const_arrays=K)
    end

    @testset "observed chain (splice + slots)" begin
        _intern_oracle(_int_observed_model())
    end

    @testset "per-cell reference path (ESS_STENCIL_DISABLE)" begin
        N = 8
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        model = _stencil_model(N)
        on = withenv("ESS_STENCIL_DISABLE" => "1", "ESS_INTERN_DISABLE" => nothing) do
            _intern_probe_model(model; ics=ics)
        end
        off = withenv("ESS_STENCIL_DISABLE" => "1", "ESS_INTERN_DISABLE" => "1") do
            _intern_probe_model(model; ics=ics)
        end
        @test on[4] == off[4]
        @test on[2] == off[2]
        for k in eachindex(on[1])
            @test on[1][k] == off[1][k]
        end
    end

    @testset "compile-once template fixture (7³, references)" begin
        FIX = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench",
                       "transport_3axis_7cubed_fullrank.esm")
        function bp(env)
            withenv(env...) do
                flat = ESM.flatten(ESM.load(FIX))
                f, u0, p, _, vmap = ESM.build_evaluator(flat)
                dus = Vector{Float64}[]
                for (ti, u) in zip((0.0, 0.7, 3.25), _probe_states(length(u0)))
                    du = similar(u0)
                    f(du, u, p, ti)
                    push!(dus, copy(du))
                end
                (dus, u0, vmap)
            end
        end
        on = bp((("ESS_INTERN_DISABLE" => nothing),))
        off = bp((("ESS_INTERN_DISABLE" => "1"),))
        @test length(on[2]) == 343
        @test on[3] == off[3]
        @test on[2] == off[2]
        for k in eachindex(on[1])
            @test on[1][k] == off[1][k]
            @test sum(abs, on[1][k]) > 0
        end
        # :oop emitter, both ways
        oop_on = withenv("ESS_INTERN_DISABLE" => nothing) do
            flat = ESM.flatten(ESM.load(FIX))
            f, u0, p, _, _ = ESM.build_evaluator(flat; form=:oop)
            [Vector{Float64}(f(u, p, ti))
             for (ti, u) in zip((0.0, 0.7, 3.25), _probe_states(length(u0)))]
        end
        for k in eachindex(on[1])
            @test oop_on[k] == off[1][k]
        end
    end
end
