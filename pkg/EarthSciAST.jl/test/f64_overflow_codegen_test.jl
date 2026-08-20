# The Float64 overflow routing (ess-f64ofl, codegen_kernel.jl).
#
# Kernels the PRIMARY codegen emission declines on the node budget used to run
# the per-cell interpreter at Float64. The dual overflow tier (ess-dualfp)
# re-emits them into a second generated function for non-Float64 `T`;
# ess-f64ofl routes Float64 calls through that SAME function too — unless
# ESS_F64_OVERFLOW_CODEGEN=0 (the kill switch: residual Float64 kernels run
# the per-cell interpreter — since the lane-tape retirement, the slower but
# bit-identical differential oracle for this routing).
#
# Pinned here, on the dual_fast_path_test overflow-class fixture (primary
# codegen declined via a forced zero budget):
#   1. ROUTING — the build tally shows the primary decline
#      (`:codegen_decline_budget`), the overflow acceptance
#      (`:dual_codegen_kernel`), and the Float64 arming (`:f64_overflow_armed`);
#      the section carries `f64cg == true` with the feature on and
#      `f64cg == false` with it off; and a RUNTIME witness: with the feature
#      on and the overflow function covering every residual kernel, emptying
#      the section's `kernels` vector does not change the Float64
#      output — proof the interpreter loop never runs.
#   2. FLOAT64 BIT-IDENTITY — du is `===` per element (NaN/-0.0 count) across
#      feature-on, feature-off (interpreter oracle), and ESS_CODEGEN_DISABLE=1
#      (pre-codegen interpreter oracle).
#   3. SANITY — at the default budget nothing declines, so the overflow
#      function does not exist and the feature changes nothing at all.
#   4. ALLOCATIONS — a warmed Float64 f! call on the overflow routing
#      allocates 0 bytes (analogous to dual_fast_path_test's Dual pin).
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

function _fof_build(model, ics; env...)
    withenv((String(k) => v for (k, v) in pairs(env))...) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics)
        (f!, u0, p, vm, diag, copy(ESM._CASCADE_TALLY))
    end
end

_fof_du(f!, u, p, t) = (d = similar(u); fill!(d, zero(eltype(u))); f!(d, u, p, t); d)
_fof_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
# Deterministic probe states inside the interp axis span [0, 4]; values
# straddle the `> 2` guard threshold so both ifelse branches are exercised.
_fof_probe(n, k) =
    Float64[2.0 + 1.3 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.01i for i in 1:n]

const _FOF_AX = [0.0, 1.0, 2.0, 3.0, 4.0]
const _FOF_TBL = [10.0, 20.0, 40.0, 80.0, 160.0]

# Overflow-class fixture (same shape as dual_fast_path_test's): elementwise
# arrayed equations (guards, unary fns, an interp leaf, cross-variable reads) —
# a zero primary budget forces every kernel off
# the primary codegen tier onto the overflow path.
function _fof_model(N)
    ubody = _op("+",
        _op("ifelse", _op(">", _idx("u", _v("i")), _n(2.0)),
            _op("log", _idx("u", _v("i"))),
            _op("sin", _idx("u", _v("i")))),
        _op("fn", _const(_FOF_TBL), _const(_FOF_AX), _idx("u", _v("i"));
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

_fof_ics(N) = Dict("$x[$k]" => 2.0 + sin(0.3k + 0.1j)
                   for (j, x) in enumerate(("u", "v")), k in 1:N)

@testset "f64 overflow codegen: compiled overflow serves budget-declined Float64 kernels" begin
    N = 48
    model = _fof_model(N)
    ics = _fof_ics(N)

    # A: primary codegen forced off (budget 0), feature at its default (ON) —
    #    the overflow function serves Float64. B: same, feature killed —
    #    interpreter at Float64, the oracle. C: codegen disabled
    #    wholesale (pre-codegen build; must also keep the routing off).
    fA, uA, pA, vmA, _, tallyA = _fof_build(model, ics;
        ESS_CODEGEN_NODE_BUDGET="0")
    fB, uB, pB, _, _, tallyB = _fof_build(model, ics;
        ESS_CODEGEN_NODE_BUDGET="0", ESS_F64_OVERFLOW_CODEGEN="0")
    fC, uC, pC, _, _, tallyC = _fof_build(model, ics;
        ESS_CODEGEN_DISABLE="1")

    @testset "routing: tally + section introspection" begin
        ksA = getfield(fA, :kernel_section)
        ksB = getfield(fB, :kernel_section)
        ksC = getfield(fC, :kernel_section)

        # Primary tier really declined on the budget; overflow tier accepted;
        # Float64 routing armed.
        @test get(tallyA, :codegen_decline_budget, 0) >= 1
        @test get(tallyA, :codegen_kernel, 0) == 0
        @test get(tallyA, :dual_codegen_kernel, 0) >= 1
        @test get(tallyA, :f64_overflow_armed, 0) == 1
        @test getfield(ksA, :f64cg) === true
        @test getfield(ksA, :dualf) !== nothing
        @test getfield(ksA, :n_dual_emitted) == length(getfield(ksA, :kernels))
        @test isempty(getfield(ksA, :dual_resid))

        # The kill switch: same section shape, routing disarmed — the
        # residual kernels then serve Float64 through the interpreter.
        @test getfield(ksB, :f64cg) === false
        @test get(tallyB, :f64_overflow_armed, 0) == 0
        @test !isempty(getfield(ksB, :kernels))

        # ESS_CODEGEN_DISABLE=1 keeps every codegen tier off: no overflow
        # function, nothing to arm.
        @test getfield(ksC, :dualf) === nothing
        @test getfield(ksC, :f64cg) === false
        @test get(tallyC, :f64_overflow_armed, 0) == 0
    end

    @testset "Float64 bit-identity (overflow ≡ interpreter ≡ no codegen)" begin
        @test uA == uB && uA == uC
        for k in 1:5, t in (0.0, 0.7, 3.25)
            u = k == 1 ? copy(uA) : _fof_probe(length(uA), k)
            duA = _fof_du(fA, u, pA, t)
            @test _fof_bitsame(duA, _fof_du(fB, u, pB, t))
            @test _fof_bitsame(duA, _fof_du(fC, u, pC, t))
        end
    end

    @testset "runtime witness: the interpreter loop is never consulted" begin
        # The overflow function covers EVERY residual kernel (dual_resid is
        # empty), so with the feature on the Float64 call must not touch
        # `kernels` at all. Empty it: if the interpreter loop ran it would
        # compute nothing (du stays zero) — instead the output must still be
        # bit-identical to the interpreter oracle. (This mutation is why this
        # build is a throwaway: build it fresh, poison it, compare, drop it.)
        fW, uW, pW, _, _, _ = _fof_build(model, ics; ESS_CODEGEN_NODE_BUDGET="0")
        ksW = getfield(fW, :kernel_section)
        @test isempty(getfield(ksW, :dual_resid))
        empty!(getfield(ksW, :kernels))
        u = _fof_probe(length(uW), 2)
        duW = _fof_du(fW, u, pW, 0.7)
        @test _fof_bitsame(duW, _fof_du(fB, u, pB, 0.7))
        @test any(x -> x !== 0.0, duW)   # and it really computed something
    end

    @testset "sanity: default budget keeps the overflow function absent" begin
        fD, _, _, _, _, tallyD = _fof_build(model, ics)
        ksD = getfield(fD, :kernel_section)
        @test getfield(ksD, :n_emitted) >= 1        # primary tier covers all
        @test isempty(getfield(ksD, :kernels))
        @test getfield(ksD, :dualf) === nothing     # nothing left to overflow
        @test get(tallyD, :f64_overflow_armed, 0) == 0
    end

    @testset "allocations: warmed Float64 call on the overflow routing is 0 B" begin
        du = similar(uA)
        u = _fof_probe(length(uA), 3)
        for _ in 1:3
            fA(du, u, pA, 0.3)
            fB(du, u, pB, 0.3)
        end
        allocA = @allocated fA(du, u, pA, 0.3)
        allocB = @allocated fB(du, u, pB, 0.3)
        @info "f64-call allocations" overflow = allocA interp = allocB
        @test allocA == 0
        @test allocA <= allocB
    end
end
