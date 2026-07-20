# Differential oracle for the B1 Julia-codegen tier (tree_walk/codegen_kernel.jl).
#
# Build the SAME model two ways and require BIT-identical du (`===` on every
# element, so NaN and -0.0 count) across several (u, t) probes, at Float64 AND
# under ForwardDiff Dual:
#   * default                 → the codegen tier (RuntimeGeneratedFunctions)
#   * ESS_CODEGEN_DISABLE=1   → the pre-codegen runners (lane tape / scalar walk)
# Every case asserts the codegen tier actually FIRED (`:codegen_kernel` in
# `_CASCADE_TALLY`), so a silent decline cannot make the comparison pass
# trivially. Fixtures deliberately span the descriptor/op surface: affine
# stencils (1-D/2-D, ghosts), makearray regions, const-array coefficients,
# lazy guards over singular ops, scalar parameters, constant-bound
# contractions (unrolled einsum), interp.* closed functions, and the
# compile-once template sub-kernel fixture (transport_3axis_7cubed_fullrank).
using Test
using JSON3
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

# Build with the codegen tier on (default) or off (the differential reference).
# Returns (f!, u0, p, vmap, diag, tally-snapshot).
function _cgk_build(model, ics; codegen::Bool, const_arrays=Dict(), form=:inplace)
    withenv("ESS_CODEGEN_DISABLE" => (codegen ? nothing : "1")) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics, const_arrays=const_arrays, form=form)
        (f!, u0, p, vm, diag, copy(ESM._CASCADE_TALLY))
    end
end

_cgk_fired(tally) = get(tally, :codegen_kernel, 0)

_cgk_du(f!, u, p, t) = (d = similar(u); fill!(d, 0.0); f!(d, u, p, t); d)

# Deterministic "random" probe states (no Random dep): k-th draw over n cells.
_cgk_probe(n, k) =
    Float64[1.4 + 0.9 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.05i for i in 1:n]

_cgk_bitsame(a, b) = size(a) == size(b) && all(a .=== b)

# The full differential: several (u, t) probes bit-compared at Float64, plus
# the ForwardDiff Jacobian over the state bit-compared (the Dual axis).
function _cgk_differential(model, ics; const_arrays=Dict(), jacobian::Bool=true)
    fc, u0, p, _, _, tally = _cgk_build(model, ics; codegen=true,
                                        const_arrays=const_arrays)
    fr, v0, q, _, _, rtally = _cgk_build(model, ics; codegen=false,
                                         const_arrays=const_arrays)
    @test _cgk_fired(tally) >= 1            # the tier fired, not a silent decline
    @test _cgk_fired(rtally) == 0           # …and the kill switch really kills it
    @test u0 == v0
    for k in 1:5, t in (0.0, 0.7, 3.25)
        u = k == 1 ? copy(u0) : _cgk_probe(length(u0), k)
        @test _cgk_bitsame(_cgk_du(fc, u, p, t), _cgk_du(fr, u, q, t))
    end
    if jacobian
        Jc = ForwardDiff.jacobian(uu -> _cgk_du(fc, uu, p, 0.4), u0)
        Jr = ForwardDiff.jacobian(uu -> _cgk_du(fr, uu, q, 0.4), v0)
        @test _cgk_bitsame(Jc, Jr)
    end
    return nothing
end

# ---- fixture models (locally prefixed to avoid clashes under runtests.jl) ----

function _cgk_2d_model(N)
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

function _cgk_makearray_model(N)
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

function _cgk_const_coef_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("*", _idx("K", _v("i")), lap), "i", 1, N))])
end

# Guarded singularities: the codegen emission must stay LAZY (`ifelse` as a
# ternary), so out-of-domain cells never evaluate log/sqrt off their domains.
function _cgk_guarded_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    ui = _idx("u", _v("i"))
    guarded = _op("+",
        _op("ifelse", _op(">", ui, _n(0.0)), _op("log", ui), _n(-1.0)),
        _op("ifelse", _op(">=", ui, _n(0.25)),
            _op("sqrt", _op("-", ui, _n(0.25))), _n(0.0)),
        _op("ifelse", _op("and", _op(">", ui, _n(0.0)), _op("<", ui, _n(10.0))),
            _op("^", ui, _n(0.5)), _n(0.0)))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), ui),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("+", guarded, lap), "i", 1, N))])
end

function _cgk_param_model(N)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.StateVariable),
        "alpha" => ESM.ModelVariable(ESM.ParameterVariable; default=0.35))
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("*", _v("alpha"), lap), "i", 1, N))])
end

function _cgk_reduce_model(statevars, ybody, ni, klo, khi; reduce="+", filt=nothing)
    vars = Dict(v => ESM.ModelVariable(ESM.StateVariable) for v in statevars)
    rhs = ESM.OpExpr("arrayop", ESM.ASTExpr[]; output_idx=Any["i"], expr_body=ybody,
        ranges=Dict("i" => [1, ni], "k" => [klo, khi]), reduce=reduce, filter=filt)
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx(statevars[1], _v("i")), "i", 1, ni), rhs)])
end

const _CGK_LT = [10.0, 20.0, 40.0, 80.0, 160.0]
const _CGK_LA = [0.0, 1.0, 2.0, 3.0, 4.0]

function _cgk_interp_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    itp = _op("fn", _const(_CGK_LT), _const(_CGK_LA),
              _idx("u", _op("+", _v("i"), _i(1))); name="interp.linear")
    lap = _op("+", _idx("u", _op("-", _v("i"), _i(1))),
                   _op("*", _n(-2.0), _idx("u", _v("i"))),
                   _idx("u", _op("+", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(_op("+", itp, lap), "i", 1, N))])
end

function _cgk_searchsorted_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("fn", _idx("u", _v("i")), _const(_CGK_LA); name="interp.searchsorted")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

const _CGK_BT = Any[Any[1.0, 1.5, 2.0], Any[1.1, 1.6, 2.1], Any[1.2, 1.7, 2.2]]
function _cgk_bilinear_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    body = _op("fn", _const(_CGK_BT), _const([0.0, 1.0, 2.0]), _const([0.0, 1.0, 2.0]),
               _idx("u", _v("i")), _idx("u", _op("+", _v("i"), _i(1)));
               name="interp.bilinear")
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

@testset "codegen tier ≡ pre-codegen runners (differential, B1)" begin

    @testset "1D second-difference stencil (N=$N)" for N in (8, 33)
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        _cgk_differential(_stencil_model(N), ics)
    end

    @testset "2D 5-point Laplacian (N=$N)" for N in (5, 16)
        ics = Dict("u[$i,$j]" => sin(0.3i) * cos(0.2j) + 0.05i for i in 1:N, j in 1:N)
        _cgk_differential(_cgk_2d_model(N), ics)
    end

    @testset "makearray regions (N=$N)" for N in (8, 32)
        ics = Dict("u[$k]" => cos(0.4k) + 0.02k for k in 1:N)
        _cgk_differential(_cgk_makearray_model(N), ics)
    end

    @testset "const-array coefficient (_AccConstBox)" begin
        N = 24
        ics = Dict("u[$k]" => sin(0.5k) for k in 1:N)
        K = [1.0 + 0.1k for k in 1:N]
        _cgk_differential(_cgk_const_coef_model(N), ics; const_arrays=Dict("K" => K))
    end

    @testset "lazy guards over singular ops" begin
        # Half the cells sit OUT of log/sqrt domain — the lazy reference never
        # evaluates the singular op there, and neither may the emitted ternary.
        N = 16
        ics = Dict("u[$k]" => (isodd(k) ? -1.0 : 0.5) + 0.01k for k in 1:N)
        _cgk_differential(_cgk_guarded_model(N), ics)
    end

    @testset "scalar parameter (_NK_PARAM) + AD" begin
        N = 12
        ics = Dict("u[$k]" => 0.3k for k in 1:N)
        _cgk_differential(_cgk_param_model(N), ics)
    end

    @testset "constant-bound contraction: matvec Σ A[i,k]·x[k]" begin
        A = [1.0 2.0 3.0; 4.0 5.0 6.0]
        body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
        m = _cgk_reduce_model(["y", "x"], body, 2, 1, 3)
        ics = Dict("y[1]" => 0.0, "y[2]" => 0.0,
                   "x[1]" => 1.0, "x[2]" => 2.0, "x[3]" => 3.0)
        _cgk_differential(m, ics; const_arrays=Dict("A" => A))
    end

    @testset "min/max/filtered reductions" begin
        for (red, filt) in (("min", nothing), ("max", nothing),
                            ("+", _op("<=", _v("k"), _i(2))))
            body = _op("*", _idx("u", _v("i")), _v("k"))
            m = _cgk_reduce_model(["w", "u"], body, 6, 1, 4; reduce=red, filt=filt)
            ics = Dict{String,Float64}()
            for k in 1:6
                ics["w[$k]"] = 0.0
                ics["u[$k]"] = 0.5k - 1.6
            end
            _cgk_differential(m, ics)
        end
    end

    @testset "interp.linear / searchsorted / bilinear fn leaves" begin
        N = 16
        ics = Dict("u[$k]" => 2.0 + sin(0.3k) for k in 1:N)
        _cgk_differential(_cgk_interp_model(N), ics)
        _cgk_differential(_cgk_searchsorted_model(N), ics; jacobian=false)
        _cgk_differential(_cgk_bilinear_model(N), ics)
    end

    @testset "template sub-kernels (_NK_SUBCALL): 7³ transport fixture" begin
        FIX = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench",
                       "transport_3axis_7cubed_fullrank.esm")
        if !isfile(FIX)
            @test_skip "bench fixture transport_3axis_7cubed_fullrank.esm missing"
        else
            flat = ESM.flatten(ESM.load(FIX))
            build(codegen) = withenv("ESS_CODEGEN_DISABLE" => (codegen ? nothing : "1")) do
                ESM._reset_cascade_tally!()
                f!, u0, p, _, _ = ESM.build_evaluator(flat)
                (f!, u0, p, copy(ESM._CASCADE_TALLY))
            end
            fc, u0, p, tally = build(true)
            fr, v0, q, rtally = build(false)
            @test _cgk_fired(tally) >= 1
            @test _cgk_fired(rtally) == 0
            for k in 1:4, t in (0.0, 0.7, 3.25)
                u = k == 1 ? copy(u0) : _cgk_probe(length(u0), k)
                duc = _cgk_du(fc, u, p, t)
                dur = _cgk_du(fr, u, q, t)
                @test _cgk_bitsame(duc, dur)
                # u0 is a uniform field, whose advection derivative is exactly
                # zero — only the non-trivial probes must be non-zero.
                k > 1 && @test sum(abs, duc) > 0
            end
            # Dual axis through the sub-kernel inlining (a single directional
            # derivative keeps the 343-state Jacobian affordable).
            seed = _cgk_probe(length(u0), 7)
            gc = ForwardDiff.derivative(s -> sum(_cgk_du(fc, u0 .+ s .* seed, p, 0.4)), 0.0)
            gr = ForwardDiff.derivative(s -> sum(_cgk_du(fr, v0 .+ s .* seed, q, 0.4)), 0.0)
            @test gc === gr
        end
    end

    @testset "per-kernel decline: mixed emit/fallback section" begin
        # Hand-built kernels driven straight through `_make_kernel_section`:
        # kernel 1 (1-D affine box) is emittable; kernel 2 (a rank-4 box) is
        # NOT (`:box_rank` decline) and must silently keep the scalar runner.
        N = 24
        mk1d(lo, hi, dW, dE) = begin
            acc = ESM._AccDesc[ESM._AccStateAffine(dW), ESM._AccStateAffine(0),
                               ESM._AccStateAffine(dE)]
            sp = ESM._aop(:+, ESM._aop(:-, ESM._acc(1),
                                       ESM._aop(:*, ESM._alit(2.0), ESM._acc(2))),
                          ESM._acc(3))
            ESM._AccKernel(ESM._CellSet([1], UnitRange{Int}[lo:hi], 0), sp, acc,
                           ESM._FixedBound(0), 0.0)
        end
        K1 = mk1d(2, N - 1, -1, 1)
        # Rank-4 box over a 2×2×2×3 slab (strides for a 2×2×2×3 row-major-ish
        # layout; 24 slots): the emitter caps box rank at 3 and must decline.
        acc4 = ESM._AccDesc[ESM._AccStateAffine(0)]
        sp4 = ESM._aop(:*, ESM._alit(0.5), ESM._acc(1))
        K2 = ESM._AccKernel(
            ESM._CellSet([1, 2, 4, 8], UnitRange{Int}[1:2, 1:2, 1:2, 1:3], -1),
            sp4, acc4, ESM._FixedBound(0), 0.0)
        kernels = ESM._AccKernel[K1, K2]
        plans = Union{Nothing,ESM._AccPlan}[ESM._build_acc_plan(K) for K in kernels]
        ESM._reset_cascade_tally!()
        section = ESM._make_kernel_section(kernels, plans)
        tally = copy(ESM._CASCADE_TALLY)
        @test get(tally, :codegen_kernel, 0) == 1
        @test get(tally, :codegen_decline_box_rank, 0) == 1
        @test length(section.kernels) == 1          # K2 kept its scalar runner
        u = _cgk_probe(N, 3)
        du = zeros(N)
        section(du, u, nothing, 0.0, Float64)
        ref = zeros(N)
        ESM._run_acc_kernel!(ref, u, nothing, 0.0, K1)
        ESM._run_acc_kernel!(ref, u, nothing, 0.0, K2)
        @test _cgk_bitsame(du, ref)
    end

    @testset "zero allocations at Float64 (codegen path)" begin
        N = 32
        ics = Dict("u[$k]" => sin(0.3k) + 0.1k for k in 1:N)
        f!, u0, p, _, _, tally = _cgk_build(_stencil_model(N), ics; codegen=true)
        @test _cgk_fired(tally) >= 1
        du = zero(u0)
        f!(du, u0, p, 0.0)                       # warm up
        @test (@allocated f!(du, u0, p, 0.0)) == 0
    end
end
