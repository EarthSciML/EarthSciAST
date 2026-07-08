# Discrete-cadence materialization (the middle cadence phase; DiscreteMaterializer).
# A state-free array observed transitively tainted by a live `param_arrays` forcing
# buffer is cut out of the per-step RHS into a cache buffer filled once per refresh,
# gathered live by the hot RHS — instead of inlined + recomputed every step (which,
# for a deep regrid->physics chain, collapses into an un-lowerable RHS). Opt-in via
# the `materialize_out` sink; without it, the pre-cut inline path is byte-identical.
#
# This is solver-free (builds the RHS, evaluates it directly): the fill/cache
# semantics and the classification are the contract, not the integration.
using Test
using EarthSciAST
const _DM_ESS = EarthSciAST

_dm_fixture() = joinpath(@__DIR__, "fixtures", "discrete_materialize.esm")

# g[j] = sum_i W[i,j]*src[i]   (param-tainted -> discrete);  k[j] = sum_i W[i,j]*offset
const _DM_W = [1.0 2.0 3.0; 4.0 5.0 6.0]     # W[i,j], i=1..2, j=1..3
_dm_g(src)     = [sum(_DM_W[i, j] * src[i] for i in 1:2) for j in 1:3]
_dm_k(offset)  = [sum(_DM_W[i, j] * offset for i in 1:2) for j in 1:3]

@testset "discrete-cadence materialization (DiscreteMaterializer)" begin
    file = _DM_ESS.load(_dm_fixture())
    ics = Dict{String,Float64}("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0)

    @testset "cut matches the inline baseline; only the param-tainted var is cached" begin
        # Inline baseline (no sink): g and k are both inlined into the state RHS.
        srcA = [1.0, 1.0]
        f0!, u00, p0, _, vm0 = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => srcA))
        du0 = zero(u00); f0!(du0, u00, p0, 0.0)
        base = [du0[vm0["c[$j]"]] for j in 1:3]
        @test base ≈ _dm_g([1.0, 1.0]) .+ _dm_k(1.0)   # offset default = 1.0

        # Cut (sink): g becomes a discrete cache; k (const-fed) stays inline.
        srcB = [1.0, 1.0]
        dm = _DM_ESS.DiscreteMaterializer()
        f!, u0, p, _, vm = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => srcB),
            materialize_out=dm)
        @test haskey(dm.caches, "g")             # param-tainted, state-free -> cached
        @test !haskey(dm.caches, "k")            # const-fed -> NOT cached (regression guard)
        @test dm.caches["g"] == _dm_g([1.0, 1.0])
        du = zero(u0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] == base   # cut is numerically identical
    end

    @testset "the cache is discrete: stale until materialize!, then tracks" begin
        srcB = [1.0, 1.0]
        dm = _DM_ESS.DiscreteMaterializer()
        f!, u0, p, _, vm = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => srcB),
            materialize_out=dm)
        du = zero(u0); f!(du, u0, p, 0.0)
        initial = [du[vm["c[$j]"]] for j in 1:3]

        # Refresh the raw buffer in place but DON'T re-materialize: the RHS reads the
        # cache, so it must be STALE — it did NOT recompute g from the new src.
        srcB .= [2.0, 3.0]
        fill!(du, 0.0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] == initial

        # Re-materialize (what the refresh callback's post_refresh hook does): the
        # cache updates and the RHS tracks.
        dm.materialize!()
        @test dm.caches["g"] == _dm_g([2.0, 3.0])
        fill!(du, 0.0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] ≈ _dm_g([2.0, 3.0]) .+ _dm_k(1.0)
    end

    @testset "no sink ⇒ no discrete cut (opt-in), build still succeeds" begin
        # Without the sink the param-tainted g stays inlined — the pre-cut path.
        src = [1.0, 1.0]
        f!, u0, p, _, vm = _DM_ESS.build_evaluator(file; initial_conditions=ics,
            const_arrays=Dict("W" => _DM_W), param_arrays=Dict("src" => src))
        du = zero(u0); f!(du, u0, p, 0.0)
        @test [du[vm["c[$j]"]] for j in 1:3] ≈ _dm_g([1.0, 1.0]) .+ _dm_k(1.0)
    end
end
