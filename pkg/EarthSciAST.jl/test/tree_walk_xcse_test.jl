# Cross-kernel / kernel↔prelude fn-CSE via shared scalar prelude slots
# (perf-gap-closure plan B4; src/tree_walk/xcse.jl).
#
# A lane-invariant fn/interp subtree appearing in several array kernels'
# invariant tiers — the FastJX shape: `interp.linear(tbl, ax, cos_zenith(t))`
# feeding K species balances — used to be evaluated once per kernel per RHS
# call. The pass shares it as ONE scalar prelude slot; each kernel's inv def
# becomes a bare cache read.
#
# Pinned here:
#   * bit-exact differential oracle, pass ON vs ESS_XCSE_DISABLE=1 OFF, on a
#     FastJX-like fixture (many interp.linear over one shared query), an
#     observed-chain fixture, a guard-bearing fixture, and a plain stencil;
#   * the EVALUATE-ONCE property, by counting the `:fn` nodes each RHS call
#     walks: prelude defs run once per call and kernel inv recipes run once
#     per call per kernel (`_fill_invariant!`), so the per-call fn evaluation
#     count is a build-time structural fact — ON it collapses to the number of
#     DISTINCT interp calls, OFF it is the per-kernel multiple;
#   * zero allocation at Float64 with shared slots live, and Dual-eltype
#     bit-identity through them;
#   * the cost gate (bare arithmetic mints no slot), the kill switch, and the
#     N-independence of the shared-slot count.

using Test
using EarthSciAST
using ForwardDiff
const ESM = EarthSciAST

include("testutils.jl")  # zero_alloc_harness.jl → rhs_alloc_bytes

_xc_fn(name, args...) = ESM.OpExpr("fn", ESM.ASTExpr[args...]; name=String(name))

# One RHS call's fn-evaluation count, from the build's own containers: every
# prelude def is evaluated exactly once per call (`_make_rhs`'s two tier loops)
# and every kernel inv recipe exactly once per call (`_fill_invariant!`), so
# counting `:fn` nodes inside those def trees IS the per-call count for a model
# whose spines/cell tiers carry no fn (the fixtures below are built that way —
# asserted via `_xc_count_fn(spine)+cell recipes == 0`). An `_NK_CACHED` leaf
# has no children, so a def rewritten to a cache read contributes nothing.
_xc_count_fn(n::ESM._Node) =
    (n.kind === ESM._NK_OP && n.op === :fn ? 1 : 0) +
    sum(_xc_count_fn(c) for c in n.children; init=0)

function _xc_percall_fn(prelude, kernels)
    total = sum(_xc_count_fn(d) for d in prelude; init=0)
    seen = IdDict{ESM._AccKernel,Nothing}()
    function walk(K)
        haskey(seen, K) && return
        seen[K] = nothing
        total += sum(_xc_count_fn(r) for r in K.cse.inv_recipes; init=0)
        # the per-cell tiers must be fn-free for the count to be per-call
        @test _xc_count_fn(K.spine) == 0
        @test sum(_xc_count_fn(r) for r in K.cse.recipes; init=0) == 0
        foreach(walk, K.subs)
    end
    foreach(walk, kernels)
    return total
end

# Build with the pass ON / OFF (everything else identical).
_xc_build(model; ics=Dict{String,Float64}(), on::Bool=true, kw...) =
    withenv("ESS_XCSE_DISABLE" => (on ? nothing : "1")) do
        ESM._build_evaluator_impl(model; initial_conditions=ics, kw...)
    end

_xc_du(f!, u0, p, t) = (du = zeros(length(u0)); f!(du, u0, p, t); du)

# ---- Fixtures -----------------------------------------------------------------

const _XC_AXIS = Any[0.0, 0.5, 1.0]

# The shared scalar query: cos(0.1·t) — a stand-in for a solar-zenith chain.
_xc_q() = _op("cos", _op("*", _n(0.1), _v("t")))
_xc_J(tbl) = _xc_fn("interp.linear", _const(tbl), _const(_XC_AXIS), _xc_q())

# FastJX-like: K bands, band k an array equation D(c_k[i]) = J_k · c_k[i] with
# its OWN table (distinct interp per band) — but ONE shared query subtree; and
# `nshared` of the bands reuse band 1's table (a fully shared interp).
function _xc_fastjx(K::Int, N::Int; nshared::Int=2)
    vars = Dict{String,ESM.ModelVariable}()
    eqs = ESM.Equation[]
    for k in 1:K
        vars["c$k"] = ESM.ModelVariable(ESM.StateVariable)
        tbl = k <= nshared ? Any[1.0, 2.0, 4.0] : Any[1.0 + k, 2.0 + k, 4.0 + k]
        body = _op("*", _xc_J(tbl), _idx("c$k", _v("i")))
        push!(eqs, ESM.Equation(_ao1(_Didx("c$k", _v("i")), "i", 1, N),
                                _ao1(body, "i", 1, N)))
    end
    ics = Dict{String,Float64}()
    for k in 1:K, i in 1:N
        ics["c$k[$i]"] = 0.1k + 0.01i
    end
    return ESM.Model(vars, eqs), ics
end

@testset "cross-kernel fn-CSE (plan B4, xcse.jl)" begin

    # ----------------------------------------------------------------
    # FastJX-like fixture: bit-exact oracle + evaluate-once counting.
    # ----------------------------------------------------------------
    @testset "FastJX-like: oracle + fn evaluation count" begin
        K, N = 6, 8
        model, ics = _xc_fastjx(K, N)
        fon!, u0, p, _, vm, don = _xc_build(model; ics, on=true)
        foff!, u0f, pf, _, _, doff = _xc_build(_xc_fastjx(K, N)[1]; ics, on=false)

        # The pass fired: the shared query chain (0.1·t, cos) + the interp the
        # first two bands share = 3 shared slots; every kernel's copies of the
        # query defs (6+6) plus the two shared-interp defs collapse to reads.
        @test don.n_xcse_slots == 3
        @test don.n_xcse_kernel_shared == 2K + 2
        @test doff.n_xcse_slots == 0
        @test doff.n_xcse_kernel_shared == 0

        # Bit-exact ON vs OFF at several times, incl. the analytic value.
        for t in (0.0, 0.7, 13.9, -2.5)
            don_du = _xc_du(fon!, u0, p, t)
            @test don_du == _xc_du(foff!, u0f, pf, t)
            J1 = ESM._interp_linear_core([1.0, 2.0, 4.0], [0.0, 0.5, 1.0],
                                         cos(0.1t))
            @test don_du[vm["c1[1]"]] === J1 * u0[vm["c1[1]"]]
        end
    end

    # ----------------------------------------------------------------
    # EVALUATE-ONCE (the counting test). All K bands share ONE table, so the
    # model contains exactly ONE distinct interp call. The per-call fn
    # evaluation count is read off the closure's own captured containers
    # (`_make_rhs`'s `f!` captures `cse_prelude` / `acc_kernels`): prelude
    # defs run once per call, kernel inv recipes once per call per kernel,
    # and `_xc_percall_fn` asserts the spines/cell tiers are fn-free.
    # ON → 1 fn eval per RHS call; OFF → K (one per band's kernel).
    # ----------------------------------------------------------------
    @testset "evaluate-once: per-call fn count, ON == 1, OFF == K" begin
        K, N = 5, 6
        _, ics = _xc_fastjx(K, N; nshared=K)
        for (on, expected_fn) in ((true, 1), (false, K))
            f!, _, _, _, _, diag = _xc_build(_xc_fastjx(K, N; nshared=K)[1];
                                             ics, on=on)
            fields = fieldnames(typeof(f!))
            @test :cse_prelude in fields && :acc_kernels in fields
            prelude = getfield(f!, :cse_prelude)
            kernels = getfield(f!, :acc_kernels)
            @test _xc_percall_fn(prelude, kernels) == expected_fn
            @test diag.n_xcse_slots == (on ? 3 : 0)
        end
    end

    # ----------------------------------------------------------------
    # Kernel↔prelude direction: a named observed slot is REUSED (no new slot).
    # ----------------------------------------------------------------
    @testset "observed chain: kernel def lands on the existing observed slot" begin
        N = 8
        tbl = Any[1.0, 2.0, 4.0]
        vars = Dict{String,ESM.ModelVariable}(
            "a" => ESM.ModelVariable(ESM.StateVariable),
            "s" => ESM.ModelVariable(ESM.StateVariable; default=2.0),
            "Jobs" => ESM.ModelVariable(ESM.ObservedVariable))
        eqs = ESM.Equation[
            ESM.Equation(_v("Jobs"), _xc_J(tbl)),
            ESM.Equation(_D("s"), _op("*", _v("Jobs"), _v("s"))),
            ESM.Equation(_ao1(_Didx("a", _v("i")), "i", 1, N),
                         _ao1(_op("*", _xc_J(tbl), _idx("a", _v("i"))), "i", 1, N)),
        ]
        ics = Dict{String,Float64}("s" => 2.0)
        for i in 1:N
            ics["a[$i]"] = 0.1i
        end
        mk() = ESM.Model(vars, eqs)
        fon!, u0, p, _, _, don = _xc_build(mk(); ics, on=true)
        foff!, u0f, pf, _, _, _ = _xc_build(mk(); ics, on=false)
        # The observed def IS the interp chain: the kernel's whole inv chain
        # rewrites onto existing prelude slots — J onto the observed slot
        # itself — minting NO new slot.
        @test don.n_obs_slots == 1
        @test don.n_xcse_slots == 0
        @test don.n_xcse_kernel_shared >= 1
        for t in (0.0, 0.7, 5.3)
            @test _xc_du(fon!, u0, p, t) == _xc_du(foff!, u0f, pf, t)
        end
    end

    # ----------------------------------------------------------------
    # Kernel↔scalar direction: a scalar RHS singleton reads the new slot.
    # ----------------------------------------------------------------
    @testset "scalar equation joins the kernels' shared slot" begin
        N = 8
        tbl = Any[1.0, 2.0, 4.0]
        vars = Dict{String,ESM.ModelVariable}(
            "a" => ESM.ModelVariable(ESM.StateVariable),
            "b" => ESM.ModelVariable(ESM.StateVariable),
            "s" => ESM.ModelVariable(ESM.StateVariable; default=2.0))
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("a", _v("i")), "i", 1, N),
                         _ao1(_op("*", _xc_J(tbl), _idx("a", _v("i"))), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("b", _v("i")), "i", 1, N),
                         _ao1(_op("*", _xc_J(tbl), _idx("b", _v("i"))), "i", 1, N)),
            ESM.Equation(_D("s"), _op("*", _xc_J(tbl), _v("s"))),
        ]
        ics = Dict{String,Float64}("s" => 2.0)
        for i in 1:N
            ics["a[$i]"] = 0.1i
            ics["b[$i]"] = 0.2i
        end
        mk() = ESM.Model(vars, eqs)
        fon!, u0, p, _, _, don = _xc_build(mk(); ics, on=true)
        foff!, u0f, pf, _, _, _ = _xc_build(mk(); ics, on=false)
        @test don.n_xcse_slots == 3            # 0.1t · cos · interp
        @test don.n_xcse_scalar_shared == 1    # the D(s) site reads the slot
        for t in (0.0, 0.7, 5.3)
            @test _xc_du(fon!, u0, p, t) == _xc_du(foff!, u0f, pf, t)
        end
    end

    # ----------------------------------------------------------------
    # Zero-alloc + Dual bit-identity through shared slots.
    # ----------------------------------------------------------------
    @testset "Float64 zero-alloc and Dual bit-identity" begin
        K, N = 4, 8
        model, ics = _xc_fastjx(K, N)
        fon!, u0, p, _, _, don = _xc_build(model; ics, on=true)
        @test don.n_xcse_slots > 0
        du = zeros(length(u0))
        @test rhs_alloc_bytes(fon!, du, u0, p, 0.3) == 0

        foff!, u0f, pf, _, _, _ = _xc_build(_xc_fastjx(K, N)[1]; ics, on=false)
        DT = ForwardDiff.Dual{Nothing,Float64,1}
        uD = DT.(u0)
        duD = similar(uD)
        fon!(duD, uD, p, 0.3)
        duD2 = similar(uD)
        foff!(duD2, DT.(u0f), pf, 0.3)
        @test duD == duD2
    end

    # ----------------------------------------------------------------
    # Cost gate: bare shared arithmetic mints NO slot.
    # ----------------------------------------------------------------
    @testset "cost gate: shared plain arithmetic is left per-kernel" begin
        N = 8
        vars = Dict{String,ESM.ModelVariable}(
            "a" => ESM.ModelVariable(ESM.StateVariable),
            "b" => ESM.ModelVariable(ESM.StateVariable),
            "g" => ESM.ModelVariable(ESM.ParameterVariable; default=3.0),
            "h" => ESM.ModelVariable(ESM.ParameterVariable; default=7.0))
        gh = _op("/", _v("g"), _v("h"))       # invariant, shared, cheap
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("a", _v("i")), "i", 1, N),
                         _ao1(_op("*", gh, _idx("a", _v("i"))), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("b", _v("i")), "i", 1, N),
                         _ao1(_op("*", gh, _idx("b", _v("i"))), "i", 1, N)),
        ]
        ics = Dict{String,Float64}()
        for i in 1:N
            ics["a[$i]"] = 0.1i
            ics["b[$i]"] = 0.2i
        end
        mk() = ESM.Model(vars, eqs)
        fon!, u0, p, _, _, don = _xc_build(mk(); ics, on=true)
        @test don.n_xcse_slots == 0            # g/h is below the fn cost bar
        @test don.n_xcse_kernel_shared == 0
        foff!, u0f, pf, _, _, _ = _xc_build(mk(); ics, on=false)
        @test _xc_du(fon!, u0, p, 0.4) == _xc_du(foff!, u0f, pf, 0.4)
    end

    # ----------------------------------------------------------------
    # Guard-bearing kernels (lazy spine → no CSE tiers) stay correct.
    # ----------------------------------------------------------------
    @testset "guarded kernel spine: pass declines, oracle still bit-exact" begin
        N = 8
        tbl = Any[1.0, 2.0, 4.0]
        vars = Dict{String,ESM.ModelVariable}(
            "a" => ESM.ModelVariable(ESM.StateVariable),
            "b" => ESM.ModelVariable(ESM.StateVariable))
        guarded(v) = _op("ifelse", _op(">=", _idx(v, _v("i")), _n(0.0)),
                         _op("*", _xc_J(tbl), _idx(v, _v("i"))), _n(0.0))
        eqs = ESM.Equation[
            ESM.Equation(_ao1(_Didx("a", _v("i")), "i", 1, N),
                         _ao1(guarded("a"), "i", 1, N)),
            ESM.Equation(_ao1(_Didx("b", _v("i")), "i", 1, N),
                         _ao1(guarded("b"), "i", 1, N)),
        ]
        ics = Dict{String,Float64}()
        for i in 1:N
            ics["a[$i]"] = 0.1i - 0.4          # mixed signs: both branches taken
            ics["b[$i]"] = 0.3 - 0.05i
        end
        mk() = ESM.Model(vars, eqs)
        fon!, u0, p, _, _, _ = _xc_build(mk(); ics, on=true)
        foff!, u0f, pf, _, _, _ = _xc_build(mk(); ics, on=false)
        for t in (0.0, 0.7, 5.3)
            @test _xc_du(fon!, u0, p, t) == _xc_du(foff!, u0f, pf, t)
        end
    end

    # ----------------------------------------------------------------
    # Plain stencil transport shape: no fn anywhere → pass is a no-op and
    # the compiled RHS is byte-identical (same numbers, zero slots).
    # ----------------------------------------------------------------
    @testset "stencil fixture: no-op, still bit-exact" begin
        N = 16
        model = _stencil_model(N)
        ics = Dict("u[$k]" => sin(0.3k) for k in 1:N)
        fon!, u0, p, _, _, don = _xc_build(_stencil_model(N); ics, on=true)
        foff!, u0f, pf, _, _, _ = _xc_build(_stencil_model(N); ics, on=false)
        @test don.n_xcse_slots == 0
        @test don.n_xcse_kernel_shared == 0
        @test _xc_du(fon!, u0, p, 0.0) == _xc_du(foff!, u0f, pf, 0.0)
    end

    # ----------------------------------------------------------------
    # N-independence: shared-slot count is a property of the document.
    # ----------------------------------------------------------------
    @testset "shared-slot count is N-independent" begin
        counts = map((4, 16, 64)) do N
            model, ics = _xc_fastjx(4, N)
            _xc_build(model; ics, on=true)[6].n_xcse_slots
        end
        @test all(==(counts[1]), counts)
        @test counts[1] > 0
    end

    # ----------------------------------------------------------------
    # ESS_STENCIL_DISABLE reference is untouched by the pass (kill-switch
    # interplay): the per-cell oracle build has no kernels, so the pass is a
    # no-op there, and the default build still matches it bit for bit.
    # ----------------------------------------------------------------
    @testset "per-cell reference oracle (ESS_STENCIL_DISABLE) still matches" begin
        K, N = 3, 6
        model, ics = _xc_fastjx(K, N)
        fon!, u0, p, _, _, _ = _xc_build(model; ics, on=true)
        fref!, u0r, pr, _, _, dref = withenv("ESS_STENCIL_DISABLE" => "1") do
            ESM._build_evaluator_impl(_xc_fastjx(K, N)[1]; initial_conditions=ics)
        end
        @test dref.n_xcse_slots == 0           # no kernels → nothing to share
        for t in (0.0, 0.7, 5.3)
            @test _xc_du(fon!, u0, p, t) == _xc_du(fref!, u0r, pr, t)
        end
    end
end
