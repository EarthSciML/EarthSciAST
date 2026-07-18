# PreparedModel — preparation as a first-class cached artifact.
#
# `prepare(input; …)` runs everything deterministic-per-document ONCE (load →
# flatten → shape transforms → build_evaluator); `simulate(prep, tspan; …)`
# skips it entirely. Pinned here:
#   • SNAPSHOT + NO RE-DERIVATION — after `prepare`, mutating the input Dict in
#     a way that would change the model must NOT change `simulate(prep, …)`,
#     while a fresh `simulate(input, …)` of the mutated Dict must see it. If
#     simulate(prep, …) secretly re-ran the pipeline, it would pick up the
#     mutation — so matching the pre-mutation fresh runs proves the cache.
#   • parameters belong to `prepare` (they feed build-time constant folding);
#     `simulate(prep, …; parameters = …)` throws with guidance.
#   • per-run independence — IC overrides apply to a COPY of the prepared u0.
#   • discrete providers — repeated `simulate(prep, …)` runs re-seed the live
#     forcing buffers at each run's t0 (fresh refresh state per call), and the
#     one-call `simulate(input, tspan)` path still samples each provider
#     exactly once per anchor (no double seeding).
using Test
using EarthSciAST
using DiffEqCallbacks            # loads EarthSciASTDataRefreshExt (discrete runs)
using SciMLBase                  # ext co-trigger (u_modified!)
import OrdinaryDiffEqTsit5: Tsit5
const ESM_P = EarthSciAST

# A mock DISCRETE Provider that LOGS every sample (the same shape as the
# data_refresh_e2e mock): per-tick (var => field) tables keyed by t.
mutable struct _PrepLogProvider
    times::Vector{Float64}
    fields::Dict{Float64,Dict{String,Vector{Float64}}}
    samples::Vector{Float64}
end
_PrepLogProvider(times, fields) =
    _PrepLogProvider(Float64[t for t in times], fields, Float64[])
ESM_P.provider_refresh_times(p::_PrepLogProvider) = p.times
function ESM_P.provider_sample(p::_PrepLogProvider, t::Real)
    push!(p.samples, Float64(t))
    tf = Float64(t)
    haskey(p.fields, tf) ||
        error("_PrepLogProvider has no sample for t=$tf (have $(sort!(collect(keys(p.fields)))))")
    return p.fields[tf]
end

@testset "PreparedModel — prepare once, simulate many" begin
    _D(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
    scalar_esm(rhs) = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "S"),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "y" => Dict{String,Any}("type" => "state", "default" => 0.0),
                "k" => Dict{String,Any}("type" => "parameter", "default" => 1.0)),
            "equations" => Any[Dict{String,Any}("lhs" => _D("y"), "rhs" => rhs)])))

    @testset "snapshot + no re-derivation: input mutation after prepare is not seen" begin
        esm = scalar_esm("k")
        # Fresh oracles over the PRE-mutation document (deepcopy: `esm` stays pristine).
        fresh2 = ESM_P.simulate(deepcopy(esm), (0.0, 2.0); alg = Tsit5())
        fresh3 = ESM_P.simulate(deepcopy(esm), (0.0, 3.0); alg = Tsit5())
        @test isapprox(fresh2["M.y"][end], 2.0; rtol = 1e-5)   # D(y)=k, k=1

        prep = prepare(esm)
        @test prep isa PreparedModel

        # Mutate the input in a way that WOULD change the model...
        esm["models"]["M"]["variables"]["k"]["default"] = 100.0
        # ...a fresh simulate of the mutated Dict sees it:
        mutated = ESM_P.simulate(esm, (0.0, 2.0); alg = Tsit5())
        @test isapprox(mutated["M.y"][end], 200.0; rtol = 1e-5)
        # ...but the prepared model does NOT: two runs at different tspans both
        # match the pre-mutation fresh runs exactly, proving the prep snapshot
        # was taken AND that neither call re-derived anything from `esm`.
        r2 = ESM_P.simulate(prep, (0.0, 2.0); alg = Tsit5())
        r3 = ESM_P.simulate(prep, (0.0, 3.0); alg = Tsit5())
        @test r2.t == fresh2.t && r2.u == fresh2.u
        @test r3.t == fresh3.t && r3.u == fresh3.u
    end

    @testset "parameters belong to prepare; simulate(prep; parameters=…) throws" begin
        prep = prepare(scalar_esm("k"); parameters = Dict("M.k" => 2.5))
        r = ESM_P.simulate(prep, (0.0, 3.0); alg = Tsit5())
        @test isapprox(r["M.y"][end], 7.5; rtol = 1e-5)
        # Same answer as the one-call form with the same overrides.
        r1c = ESM_P.simulate(scalar_esm("k"), (0.0, 3.0); alg = Tsit5(),
                             parameters = Dict("M.k" => 2.5))
        @test r.u == r1c.u
        # Overrides are baked into the build → the per-run call must refuse them.
        err = try
            ESM_P.simulate(prep, (0.0, 1.0); alg = Tsit5(),
                           parameters = Dict("M.k" => 1.0))
            nothing
        catch e
            e
        end
        @test err isa ESM_P.SimulateError
        @test occursin("prepare", sprint(showerror, err))
        # An explicitly EMPTY parameters dict is fine (the delegating path sends one).
        @test ESM_P.simulate(prep, (0.0, 1.0); alg = Tsit5(),
                             parameters = Dict{String,Float64}()).success
    end

    @testset "per-run independence: IC overrides never leak into the next run" begin
        prep = prepare(scalar_esm(1.0))
        r1 = ESM_P.simulate(prep, (0.0, 1.0); alg = Tsit5(),
                            initial_conditions = Dict("M.y" => 5.0))
        @test isapprox(r1["M.y"][end], 6.0; atol = 1e-6)
        # No override → the PREPARED default (0.0), not the previous run's 5.0.
        r2 = ESM_P.simulate(prep, (0.0, 1.0); alg = Tsit5())
        @test isapprox(r2["M.y"][end], 1.0; atol = 1e-6)
        # seed_ic! runs on the per-run copy too.
        r3 = ESM_P.simulate(prep, (0.0, 1.0); alg = Tsit5(),
                            seed_ic! = (u0, vm) -> (u0[vm["M.y"]] = 2.0))
        @test isapprox(r3["M.y"][end], 3.0; atol = 1e-6)
        r4 = ESM_P.simulate(prep, (0.0, 1.0); alg = Tsit5())
        @test isapprox(r4["M.y"][end], 1.0; atol = 1e-6)
    end

    @testset "show summarizes the prepared model" begin
        prep = prepare(scalar_esm("k"))
        s = sprint(show, prep)
        @test occursin("PreparedModel", s)
        @test occursin("1 state", s)
        @test occursin("1 equations", s)
        @test occursin("1 parameters", s)
    end

    @testset "discrete provider: repeated runs re-seed to fresh refresh state" begin
        # fixtures/refresh/coupled_forced.esm: D(c[i]) = scale[i]*src[i],
        # D(d[i]) = c[i] over i ∈ [1,3]. `scale` CONST via const_arrays; `src`
        # DISCRETE via a provider (live buffer, refreshed at t = 1, 2). Forcing
        # is piecewise-constant, so c(3) = [6,12,18], d(3) = [7,14,21] exactly.
        fixture = joinpath(@__DIR__, "fixtures", "refresh", "coupled_forced.esm")
        scale = [1.0, 2.0, 3.0]
        mkprov() = _PrepLogProvider([1.0, 2.0], Dict(
            0.0 => Dict("src" => [1.0, 1.0, 1.0]),
            1.0 => Dict("src" => [2.0, 2.0, 2.0]),
            2.0 => Dict("src" => [3.0, 3.0, 3.0])))

        # One-call oracle — and the pin that the delegating path samples each
        # provider exactly once per tick (seed at t0, one per anchor; NO double
        # seeding from the prepare/simulate split).
        prov_f = mkprov()
        rf = ESM_P.simulate(fixture, (0.0, 3.0); alg = Tsit5(),
                            const_arrays = Dict{String,Any}("scale" => scale),
                            providers = Dict{String,Any}("src" => prov_f))
        @test rf.success
        @test prov_f.samples == [0.0, 1.0, 2.0]
        c_f = [rf["M.c[$k]"][end] for k in 1:3]
        d_f = [rf["M.d[$k]"][end] for k in 1:3]
        @test isapprox(c_f, [6.0, 12.0, 18.0]; atol = 1e-6)
        @test isapprox(d_f, [7.0, 14.0, 21.0]; atol = 1e-6)

        # prepare once → run twice. Run 1 starts from the prepare-time seed
        # (t0 == sample_time, buffers pristine → no re-sample); run 2 finds the
        # buffers refreshed by run 1's callback and re-seeds them at t0, so the
        # runs are INDEPENDENT — and bit-identical.
        prov = mkprov()
        prep = prepare(fixture; sample_time = 0.0,
                       const_arrays = Dict{String,Any}("scale" => scale),
                       providers = Dict{String,Any}("src" => prov))
        @test prov.samples == [0.0]
        r1 = ESM_P.simulate(prep, (0.0, 3.0); alg = Tsit5())
        @test prov.samples == [0.0, 1.0, 2.0]
        r2 = ESM_P.simulate(prep, (0.0, 3.0); alg = Tsit5())
        @test prov.samples == [0.0, 1.0, 2.0, 0.0, 1.0, 2.0]
        @test r1.success && r2.success
        @test r1.u[end] == r2.u[end]
        @test [r1["M.c[$k]"][end] for k in 1:3] ≈ c_f atol = 1e-9
        @test [r2["M.d[$k]"][end] for k in 1:3] ≈ d_f atol = 1e-9
    end
end
