# Shared-prelude (xcse) cache reads in the codegen tier (ess-cgfsc,
# codegen_kernel.jl).
#
# The cross-kernel fn-CSE pass (xcse.jl, plan B4) rewrites kernel
# invariant-tier defs into bare `_NK_CACHED` reads of the build's SCALAR
# prelude `_CSECache` — a payload that is no kernel's scratch. The codegen
# emitter used to decline every such kernel (`:foreign_scratch`), dropping it
# to the interpreter; it now emits the interpreter's exact read
# (`_cse_read(cache, idx, T)` — eltype-generic, Float64 `f64` buffer or the
# Dual `alt` buffer), sound because `_make_rhs` fills every prelude tier into
# that exact cache, at the same `T`, before the kernel section runs.
#
# Pinned here, on a fixture whose two structurally-distinct kernels share one
# expensive invariant interp chain (the FastJX shape xcse exists for):
#   1. ROUTING — the default build compiles the kernels (`:codegen_kernel`,
#      `:cg_foreign_scratch_emit`, zero `:codegen_decline_foreign_scratch`);
#      the kill switch ESS_CG_FOREIGN_SCRATCH_DISABLE=1 restores the decline
#      (`:codegen_decline_foreign_scratch` ≥ 1 — the fixture really does mint
#      the foreign shape, no vacuous pass).
#   2. FLOAT64 BIT-IDENTITY — du `===` per element across the default build,
#      the kill-switch build, and ESS_CODEGEN_DISABLE=1 (interpreter
#      oracle), on several (u, t) probes.
#   3. DUAL BIT-IDENTITY — the ForwardDiff state Jacobian and a direct
#      Dual-seeded in-place call agree bit-for-bit with the interpreter
#      oracle (the emitted read serves the Dual-typed overflow RGF too).
#   4. ALLOCATIONS — a warmed Float64 f! call allocates 0 bytes (the
#      surrounding tier's zero-alloc pin, kept through the new read).
#   5. CORPUS — every repo fixture under tests/valid + tests/conformance
#      builds and evaluates bit-identically with the feature on vs the kill
#      switch (symmetric skips only).
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

function _cfs_build(model, ics; env...)
    withenv((String(k) => v for (k, v) in pairs(env))...) do
        ESM._reset_cascade_tally!()
        f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model;
            initial_conditions=ics)
        (f!, u0, p, vm, diag, copy(ESM._CASCADE_TALLY))
    end
end

_cfs_du(f!, u, p, t) = (d = similar(u); fill!(d, zero(eltype(u))); f!(d, u, p, t); d)
_cfs_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
_cfs_probe(n, k) =
    Float64[1.2 + 0.8 * sin(1.3i + 0.7k) * cos(0.31i * k) + 0.05i for i in 1:n]

_cfs_fn(name, args...) = ESM.OpExpr("fn", ESM.ASTExpr[args...]; name=String(name))

const _CFS_AX = Any[0.0, 0.5, 1.0]
const _CFS_TBL = Any[1.0, 2.0, 4.0]

# The shared lane-invariant chain: interp.linear(tbl, ax, cos(0.1·t)) — one
# expensive def whose value number is identical in both kernels' invariant
# tiers, so xcse mints ONE shared scalar prelude slot and rewrites both
# kernels' inv defs to bare `_CSECache` reads (the foreign shape under test).
_cfs_J() = _cfs_fn("interp.linear", _const(_CFS_TBL), _const(_CFS_AX),
                   _op("cos", _op("*", _n(0.1), _v("t"))))

# Two STRUCTURALLY DISTINCT array equations (so the kernel-class merge cannot
# collapse them into one kernel, which would leave nothing cross-kernel to
# share): D(a[i]) = J·a[i]  and  D(b[i]) = J·(b[i] + 0.5·sin(b[i])).
function _cfs_model(N)
    abody = _op("*", _cfs_J(), _idx("a", _v("i")))
    bbody = _op("*", _cfs_J(),
                _op("+", _idx("b", _v("i")),
                    _op("*", _n(0.5), _op("sin", _idx("b", _v("i"))))))
    eq(x, body) = ESM.Equation(_ao1(_Didx(x, _v("i")), "i", 1, N),
                               _ao1(body, "i", 1, N))
    vars = Dict{String,ESM.ModelVariable}(
        n => ESM.ModelVariable(ESM.UnknownVariable) for n in ("a", "b"))
    ESM.Model(vars, [eq("a", abody), eq("b", bbody)])
end

_cfs_ics(N) = Dict{String,Float64}("$x[$k]" => 0.2j + 0.01k
                                   for (j, x) in enumerate(("a", "b")), k in 1:N)

@testset "codegen shared-prelude reads (ess-cgfsc)" begin
    N = 8
    model, ics = _cfs_model(N), _cfs_ics(N)

    fON, uON, pON, _, dON, tON = _cfs_build(model, ics)
    fKS, uKS, pKS, _, _, tKS = _cfs_build(_cfs_model(N), ics;
                                          ESS_CG_FOREIGN_SCRATCH_DISABLE="1")
    fNC, uNC, pNC, _, _, _ = _cfs_build(_cfs_model(N), ics;
                                        ESS_CODEGEN_DISABLE="1")

    @testset "(1) routing: emit with the feature, decline with the switch" begin
        # The fixture really exercises xcse (a shared slot was minted) …
        @test dON.n_xcse_slots >= 1
        # … the default build compiles the kernels carrying the foreign read …
        @test get(tON, :cg_foreign_scratch_emit, 0) >= 2
        @test get(tON, :codegen_decline_foreign_scratch, 0) +
              get(tON, :dual_codegen_decline_foreign_scratch, 0) == 0
        @test get(tON, :codegen_kernel, 0) >= 2
        # … and the kill switch restores today's decline on the same shape.
        @test get(tKS, :codegen_decline_foreign_scratch, 0) >= 2
        @test get(tKS, :cg_foreign_scratch_emit, 0) == 0
    end

    @testset "(2) Float64 bit-identity: on vs kill switch vs no codegen" begin
        @test uON == uKS == uNC
        for k in 1:4, t in (0.0, 0.7, 3.25)
            u = k == 1 ? copy(uON) : _cfs_probe(length(uON), k)
            a = _cfs_du(fON, u, pON, t)
            @test _cfs_bitsame(a, _cfs_du(fKS, u, pKS, t))
            @test _cfs_bitsame(a, _cfs_du(fNC, u, pNC, t))
        end
    end

    @testset "(3) Dual bit-identity vs the interpreter oracle" begin
        JON = ForwardDiff.jacobian(uu -> _cfs_du(fON, uu, pON, 0.4), uON)
        JKS = ForwardDiff.jacobian(uu -> _cfs_du(fKS, uu, pKS, 0.4), uKS)
        JNC = ForwardDiff.jacobian(uu -> _cfs_du(fNC, uu, pNC, 0.4), uNC)
        @test _cfs_bitsame(JON, JKS)
        @test _cfs_bitsame(JON, JNC)
        # Direct Dual-seeded in-place call (no jacobian scaffolding): values
        # and the one partial, element by element.
        DT = ForwardDiff.Dual{:cfs,Float64,1}
        ud = DT[DT(uON[i], ForwardDiff.Partials((0.5 + 0.01i,)))
                for i in eachindex(uON)]
        da = _cfs_du(fON, ud, pON, 0.4)
        db = _cfs_du(fNC, ud, pNC, 0.4)
        @test all(ForwardDiff.value.(da) .=== ForwardDiff.value.(db))
        @test all(ForwardDiff.partials.(da, 1) .=== ForwardDiff.partials.(db, 1))
    end

    @testset "(4) zero allocation at Float64, warmed" begin
        du = similar(uON)
        fON(du, uON, pON, 0.3); fON(du, uON, pON, 0.3)
        @test rhs_alloc_bytes(fON, du, uON, pON, 0.3) == 0
    end

    # ---- (5) repo fixture-corpus differential: feature on vs kill switch ----
    # Models that cannot build/evaluate standalone are skipped SYMMETRICALLY —
    # the switch may not change what builds or what evaluates.
    @testset "(5) fixture-corpus differential (on vs kill switch)" begin
        roots = [joinpath(TESTUTILS_REPO_ROOT, "tests", "valid"),
                 joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance")]
        esms = String[]
        for r in roots
            isdir(r) || continue
            for (dir, _dirs, files) in walkdir(r), f in files
                endswith(f, ".esm") && push!(esms, joinpath(dir, f))
            end
        end
        sort!(esms)
        @test length(esms) >= 100

        function corpus_build(file, name; on::Bool)
            withenv("ESS_CG_FOREIGN_SCRATCH_DISABLE" => (on ? nothing : "1")) do
                try
                    f!, u0, p, _t, _vm = ESM.build_evaluator(file; model_name=name)
                    return (f=f!, u0=u0, p=p)
                catch
                    return nothing
                end
            end
        end
        function du_or_nothing(f!, u0, p, t)
            du = zeros(length(u0))
            try
                f!(du, u0, p, t)
            catch
                return nothing
            end
            return du
        end

        built = 0
        for path in esms
            file = try
                ESM.load(path)
            catch
                continue
            end
            file.models === nothing && continue
            for name in sort!(collect(String.(keys(file.models))))
                ron = corpus_build(file, name; on=true)
                rof = corpus_build(file, name; on=false)
                @test (ron === nothing) == (rof === nothing)
                (ron === nothing || rof === nothing) && continue
                built += 1
                @test _cfs_bitsame(ron.u0, rof.u0)
                for t in (0.0, 0.7)
                    a = du_or_nothing(ron.f, ron.u0, ron.p, t)
                    b = du_or_nothing(rof.f, rof.u0, rof.p, t)
                    @test (a === nothing) == (b === nothing)
                    (a === nothing || b === nothing) && continue
                    @test _cfs_bitsame(a, b)
                end
            end
        end
        @test built >= 40
    end
end
