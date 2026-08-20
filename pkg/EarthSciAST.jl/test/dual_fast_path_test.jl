# The Dual overflow codegen tier (ess-dualfp, codegen_kernel.jl).
#
# Kernels the PRIMARY codegen emission declines — in practice on the node
# budget (ESS_CODEGEN_NODE_BUDGET), which bounds Float64 build latency — used
# to drop, under non-Float64 value types
# (ForwardDiff `Dual` in a stiff-solver Jacobian), to the
# per-cell interpreter `_run_acc_kernel!`: slow and allocating on the hot AD
# path. The dual overflow tier re-emits those residual kernels into a second
# generated function called under non-Float64 `T` (and, since ess-f64ofl, at
# Float64 too when that routing is armed).
#
# Pinned here, on a fixture whose kernels are all budget-declinable (primary
# codegen declined via a forced zero budget):
#   1. ROUTING — the build tally shows the primary decline
#      (`:codegen_decline_budget`) AND the overflow acceptance
#      (`:dual_codegen_kernel`); the section carries a dual function covering
#      every residual kernel (`n_dual_emitted`, empty `dual_resid`); and
#      ESS_DUAL_CODEGEN_DISABLE=1 restores the pre-dual section exactly
#      (no dual function, no dual tally keys).
#   2. FLOAT64 BIT-IDENTITY — du is `===` per element (NaN/-0.0 count) across
#      the dual-tier build, the kill-switch build, and ESS_CODEGEN_DISABLE=1:
#      the dual tier must never touch the Float64 path.
#   3. DUAL BIT-IDENTITY — a ForwardDiff Jacobian (values AND partials) is
#      `===` per element between the dual-tier build and the kill-switch
#      build, whose Dual path is the per-cell interpreter (the oracle), and
#      the ESS_CODEGEN_DISABLE=1 build too.
#   4. ALLOCATIONS — a warmed Dual-seeded f! call allocates strictly less on
#      the dual tier than on the interpreter routing.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

function _dfp_build(model, ics; env...)
    withenv((String(k) => v for (k, v) in pairs(env))...) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics)
        (f!, u0, p, vm, diag, copy(ESM._CASCADE_TALLY))
    end
end

_dfp_du(f!, u, p, t) = (d = similar(u); fill!(d, zero(eltype(u))); f!(d, u, p, t); d)
_dfp_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
# Deterministic probe states inside the interp axis span [0, 4]; values
# straddle the `> 2` guard threshold so both ifelse branches are exercised.
_dfp_probe(n, k) =
    Float64[2.0 + 1.3 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.01i for i in 1:n]

const _DFP_AX = [0.0, 1.0, 2.0, 3.0, 4.0]
const _DFP_TBL = [10.0, 20.0, 40.0, 80.0, 160.0]

# Fixture: elementwise arrayed equations (guards, unary fns, an
# interp leaf, cross-variable reads) — a
# zero primary budget forces every kernel off the primary codegen tier.
function _dfp_model(N)
    ubody = _op("+",
        _op("ifelse", _op(">", _idx("u", _v("i")), _n(2.0)),
            _op("log", _idx("u", _v("i"))),
            _op("sin", _idx("u", _v("i")))),
        _op("fn", _const(_DFP_TBL), _const(_DFP_AX), _idx("u", _v("i"));
            name="interp.linear"),
        _op("*", _n(-0.5), _idx("u", _v("i"))))
    vbody = _op("*",
        _op("exp", _op("*", _n(-0.3), _idx("v", _v("i")))),
        _op("+", _n(1.0), _op("*", _n(0.25), _op("cos", _idx("u", _v("i"))))))
    eq(x, body) = ESM.Equation(_ao1(_Didx(x, _v("i")), "i", 1, N),
                               _ao1(body, "i", 1, N))
    vars = Dict{String,ESM.ModelVariable}(
        n => ESM.ModelVariable(ESM.UnknownVariable) for n in ("u", "v"))
    ESM.Model(vars, [eq("u", ubody), eq("v", vbody)])
end

_dfp_ics(N) = Dict("$x[$k]" => 2.0 + sin(0.3k + 0.1j)
                   for (j, x) in enumerate(("u", "v")), k in 1:N)

@testset "dual fast path: overflow codegen tier for budget-declined kernels" begin
    N = 48
    model = _dfp_model(N)
    ics = _dfp_ics(N)

    # A: primary codegen forced off (budget 0) — the dual overflow tier is the
    #    ONLY compiled representation. B: same, dual tier killed (the pre-dual
    #    routing: per-cell interpreter under every T — the oracle).
    # C: codegen disabled wholesale (must also keep the dual tier off).
    fA, uA, pA, vmA, _, tallyA = _dfp_build(model, ics;
        ESS_CODEGEN_NODE_BUDGET="0")
    fB, uB, pB, _, _, tallyB = _dfp_build(model, ics;
        ESS_CODEGEN_NODE_BUDGET="0", ESS_DUAL_CODEGEN_DISABLE="1")
    fC, uC, pC, _, _, tallyC = _dfp_build(model, ics;
        ESS_CODEGEN_DISABLE="1")

    @testset "routing: tally + section introspection" begin
        ksA = getfield(fA, :kernel_section)
        ksB = getfield(fB, :kernel_section)
        ksC = getfield(fC, :kernel_section)

        # Primary tier really declined on the budget; overflow tier accepted.
        @test get(tallyA, :codegen_decline_budget, 0) >= 1
        @test get(tallyA, :codegen_kernel, 0) == 0
        @test get(tallyA, :dual_codegen_kernel, 0) >= 1

        # The section: no primary coverage, full dual coverage.
        @test getfield(ksA, :n_emitted) == 0
        @test !isempty(getfield(ksA, :kernels))
        @test getfield(ksA, :dualf) !== nothing
        @test getfield(ksA, :n_dual_emitted) == length(getfield(ksA, :kernels))
        @test isempty(getfield(ksA, :dual_resid))

        # The kill switch really kills: pre-dual section, byte for byte.
        @test getfield(ksB, :dualf) === nothing
        @test getfield(ksB, :n_dual_emitted) == 0
        @test get(tallyB, :dual_codegen_kernel, 0) == 0
        @test getfield(ksB, :dual_resid) == collect(1:length(getfield(ksB, :kernels)))

        # ESS_CODEGEN_DISABLE=1 keeps BOTH tiers off (it must stay a pure
        # pre-codegen oracle build).
        @test getfield(ksC, :dualf) === nothing
        @test get(tallyC, :dual_codegen_kernel, 0) == 0
        @test get(tallyC, :codegen_kernel, 0) == 0
    end

    @testset "sanity: default budget keeps the dual tier idle" begin
        fD, _, _, _, _, tallyD = _dfp_build(model, ics)
        ksD = getfield(fD, :kernel_section)
        @test getfield(ksD, :n_emitted) >= 1        # primary tier covers all
        @test isempty(getfield(ksD, :kernels))
        @test getfield(ksD, :dualf) === nothing     # nothing left to overflow
        @test get(tallyD, :dual_codegen_kernel, 0) == 0
    end

    @testset "Float64 bit-identity (dual tier ≡ kill switch ≡ no codegen)" begin
        @test uA == uB && uA == uC
        for k in 1:5, t in (0.0, 0.7, 3.25)
            u = k == 1 ? copy(uA) : _dfp_probe(length(uA), k)
            duA = _dfp_du(fA, u, pA, t)
            @test _dfp_bitsame(duA, _dfp_du(fB, u, pB, t))
            @test _dfp_bitsame(duA, _dfp_du(fC, u, pC, t))
        end
    end

    @testset "Dual bit-identity vs the interpreter oracle (values + partials)" begin
        JA = ForwardDiff.jacobian(uu -> _dfp_du(fA, uu, pA, 0.4), uA)
        JB = ForwardDiff.jacobian(uu -> _dfp_du(fB, uu, pB, 0.4), uB)
        JC = ForwardDiff.jacobian(uu -> _dfp_du(fC, uu, pC, 0.4), uC)
        @test _dfp_bitsame(JA, JB)
        @test _dfp_bitsame(JA, JC)

        # A direct Dual-seeded in-place call too (no jacobian scaffolding):
        # values and the one partial, element by element.
        DT = ForwardDiff.Dual{:dfp,Float64,1}
        uD = DT[DT(uA[i], ForwardDiff.Partials((0.5 + 0.01i,))) for i in eachindex(uA)]
        dA = _dfp_du(fA, uD, pA, 0.7)
        dB = _dfp_du(fB, uD, pB, 0.7)
        @test all(ForwardDiff.value.(dA) .=== ForwardDiff.value.(dB))
        @test all(ForwardDiff.partials.(dA, 1) .=== ForwardDiff.partials.(dB, 1))
    end

    @testset "Dual allocations: strictly fewer than the interpreter routing" begin
        DT = ForwardDiff.Dual{:dfp,Float64,1}
        uD = DT[DT(uA[i], ForwardDiff.Partials((1.0,))) for i in eachindex(uA)]
        dD = similar(uD)
        # Warm both paths (first call compiles / allocates lazy alt buffers).
        for _ in 1:3
            fA(dD, uD, pA, 0.3)
            fB(dD, uD, pB, 0.3)
        end
        allocA = @allocated fA(dD, uD, pA, 0.3)
        allocB = @allocated fB(dD, uD, pB, 0.3)
        @info "dual-call allocations" dual_tier = allocA interpreter = allocB
        @test allocA < allocB
    end
end
