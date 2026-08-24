# ESMProblem — the simulation Problem as a first-class artifact
# (esm-libraries-spec §2.5, API_SPEC §5.8).
#
# `esm_problem(input, tspan; …)` runs everything deterministic-per-document ONCE
# (load → flatten → shape transforms → build_evaluator → seed → callbacks);
# `solve(prob, alg)` skips it entirely, and `remake(prob; …)` substitutes without
# redoing any of it. Pinned here:
#   • SNAPSHOT + NO RE-DERIVATION — after construction, mutating the input Dict
#     in a way that would change the model must NOT change `solve(prob, …)`,
#     while a fresh problem over the mutated Dict must see it. If `solve`
#     secretly re-ran the pipeline it would pick up the mutation — so matching
#     the pre-mutation fresh runs proves the snapshot.
#   • `p` belongs to construction (it feeds build-time constant folding);
#     `remake(prob; p = …)` swaps the `:numeric` half and refuses the rest.
#   • per-run independence — the problem's `u0` is copied per run, and
#     `remake(prob; u0 = …)` does not mutate the problem it came from.
#   • discrete providers — repeated `solve(prob, …)` runs re-seed the live
#     forcing buffers at each run's t0 (fresh refresh state per call), and a
#     problem built at its own t0 still samples each provider exactly once per
#     anchor (no double seeding).
using Test
using EarthSciAST
using DiffEqCallbacks            # loads EarthSciASTDataRefreshExt (discrete runs)
using SciMLBase                  # ext co-trigger (u_modified!) + solve/remake/retcodes
import SciMLBase: successful_retcode   # defined, not exported
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

@testset "ESMProblem — build once, solve many" begin
    _D(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
    scalar_esm(rhs) = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "S"),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "y" => Dict{String,Any}("type" => "unknown", "default" => 0.0),
                "k" => Dict{String,Any}("type" => "parameter", "default" => 1.0)),
            "equations" => Any[Dict{String,Any}("lhs" => _D("y"), "rhs" => rhs)])))
    Y = Symbol("M.y")

    @testset "snapshot + no re-derivation: input mutation after construction is not seen" begin
        esm = scalar_esm("k")
        # Fresh oracles over the PRE-mutation document (deepcopy: `esm` stays pristine).
        fresh2 = solve(esm_problem(deepcopy(esm), (0.0, 2.0)), Tsit5())
        fresh3 = solve(esm_problem(deepcopy(esm), (0.0, 3.0)), Tsit5())
        @test isapprox(fresh2[Y][end], 2.0; rtol = 1e-5)   # D(y)=k, k=1

        prob = esm_problem(esm, (0.0, 2.0))
        @test prob isa ESMProblem

        # Mutate the input in a way that WOULD change the model...
        esm["models"]["M"]["variables"]["k"]["default"] = 100.0
        # ...a freshly built problem over the mutated Dict sees it:
        mutated = solve(esm_problem(esm, (0.0, 2.0)), Tsit5())
        @test isapprox(mutated[Y][end], 200.0; rtol = 1e-5)
        # ...but the built problem does NOT: two runs at different tspans both
        # match the pre-mutation fresh runs exactly, proving the snapshot was
        # taken AND that neither call re-derived anything from `esm`. The second
        # tspan rides `remake`, which is §2.5.5's "share everything the
        # substitution cannot have invalidated" — no re-load, no recompile.
        r2 = solve(prob, Tsit5())
        r3 = solve(remake(prob; tspan = (0.0, 3.0)), Tsit5())
        @test r2.t == fresh2.t && r2.u == fresh2.u
        @test r3.t == fresh3.t && r3.u == fresh3.u
        # `remake` did not mutate the original: its tspan is still (0.0, 2.0).
        @test prob.tspan == (0.0, 2.0)
    end

    @testset "a :numeric override rides `p`; a build-consumed one is refused" begin
        prob = esm_problem(scalar_esm("k"), (0.0, 3.0); p = Dict("M.k" => 2.5))
        r = solve(prob, Tsit5())
        @test isapprox(r[Y][end], 7.5; rtol = 1e-5)

        # `M.k` is an ordinary scalar that lives in the runtime `p`, so its
        # class is `:numeric` and `remake(prob; p = …)` is a `p` SWAP, not a
        # rebuild — cheap and AD-transparent (`remake_parameters`). The refusal
        # of the other classes is pinned by class in `parameter_classes_test.jl`.
        @test parameter_classes(prob)["M.k"] === :numeric
        r_swap = solve(remake(prob; p = Dict("M.k" => 1.0)), Tsit5())
        @test isapprox(r_swap[Y][end], 3.0; rtol = 1e-5)   # D(y)=k, k=1
        # The swap is a NEW problem: the original's value is untouched by it.
        @test isapprox(solve(prob, Tsit5())[Y][end], 7.5; rtol = 1e-5)

        # A name the problem does not carry is refused rather than silently dropped.
        err = try
            remake(prob; p = Dict("M.nope" => 1.0))
            nothing
        catch e
            e
        end
        @test err isa ESM_P.SimulateError

        # An explicitly EMPTY `p` is fine (and returns the same carrier).
        @test remake(prob; p = Dict{String,Float64}()).p === prob.p
    end

    @testset "per-run independence: u0 overrides never leak into the next run" begin
        prob = esm_problem(scalar_esm(1.0), (0.0, 1.0))
        r1 = solve(remake(prob; u0 = Dict("M.y" => 5.0)), Tsit5())
        @test isapprox(r1[Y][end], 6.0; atol = 1e-6)
        # No override → the problem's own default (0.0), not the previous run's 5.0.
        r2 = solve(prob, Tsit5())
        @test isapprox(r2[Y][end], 1.0; atol = 1e-6)
        # `seed_ic!` is a construction-time hook and runs on that problem's copy.
        p3 = esm_problem(scalar_esm(1.0), (0.0, 1.0);
                         seed_ic! = (u0, vm) -> (u0[vm["M.y"]] = 2.0))
        @test isapprox(solve(p3, Tsit5())[Y][end], 3.0; atol = 1e-6)
        @test isapprox(solve(prob, Tsit5())[Y][end], 1.0; atol = 1e-6)
        # A whole-vector u0 is accepted too, and is likewise non-mutating.
        @test isapprox(solve(remake(prob; u0 = [4.0]), Tsit5())[Y][end], 5.0; atol = 1e-6)
        @test prob.u0 == [0.0]
    end

    @testset "the SciML integrator interface: init / step! / solve!" begin
        # §2.5.6 — the same lifecycle `solve` performs internally, exposed for a
        # caller that interleaves its own work with the integration. It comes
        # from specializing `SciMLBase.__init`, so what `init` hands back IS the
        # solver package's own integrator.
        prob = esm_problem(scalar_esm(1.0), (0.0, 1.0))
        integ = init(prob, Tsit5())
        @test integ.t == 0.0
        step!(integ)
        @test integ.t > 0.0
        sol = solve!(integ)
        @test sol.retcode == ReturnCode.Success
        @test isapprox(sol[Y][end], 1.0; atol = 1e-6)
    end

    @testset "retcode is a SciML ReturnCode, not a Symbol or a success flag" begin
        # §2.5.3 — a caller MUST be able to distinguish "ran to tspan[2]" from
        # "stopped early, here is why" without parsing prose.
        prob = esm_problem(scalar_esm(1.0), (0.0, 1.0))
        ok = solve(prob, Tsit5())
        @test ok.retcode isa SciMLBase.ReturnCode.T
        @test ok.retcode == ReturnCode.Success && successful_retcode(ok)
        stopped = solve(prob, Tsit5(); maxiters = 2)
        @test stopped.retcode == ReturnCode.MaxIters
        @test !successful_retcode(stopped)
    end

    @testset "callbacks(prob) and the §2.5.4 replacement rule" begin
        prob = esm_problem(scalar_esm(1.0), (0.0, 1.0))
        @test callbacks(prob) === nothing        # no providers, no sinks
        fired = Ref(0)
        mine = DiscreteCallback((u, t, i) -> true, i -> (fired[] += 1))
        solve(prob, Tsit5(); callback = mine)
        @test fired[] > 0
    end

    @testset "solutions are indexed BY NAME (SymbolicIndexingInterface)" begin
        # §2.5.7: the flattened state ordering is an implementation detail that
        # coupling can change, so the documented path is the name.
        prob = esm_problem(scalar_esm(1.0), (0.0, 1.0))
        sol = solve(prob, Tsit5())
        @test SciMLBase.SymbolicIndexingInterface.variable_symbols(sol) == [Y]
        @test sol[Y] == [u[1] for u in sol.u]
        @test SciMLBase.SymbolicIndexingInterface.parameter_symbols(sol) ==
              [Symbol("M.k")]
    end

    @testset "EnsembleProblem sweeps a parameter (§2.5.8)" begin
        prob = esm_problem(scalar_esm("k"), (0.0, 1.0))
        ks = [1.0, 2.0, 4.0]
        ens = EnsembleProblem(prob, (pr, i, repeat) -> remake(pr; p = Dict("M.k" => ks[i])))
        sols = solve(ens, Tsit5(), EnsembleSerial(); trajectories = length(ks))
        @test [s[Y][end] for s in sols] ≈ ks atol = 1e-6
        # The sweep left the base problem alone.
        @test isapprox(solve(prob, Tsit5())[Y][end], 1.0; atol = 1e-6)
    end

    @testset "show summarizes the problem" begin
        prob = esm_problem(scalar_esm("k"), (0.0, 2.0))
        s = sprint(show, prob)
        @test occursin("ESMProblem", s)
        @test occursin("1 state", s)
        @test occursin("1 equations", s)
        @test occursin("1 parameters", s)
        @test occursin("tspan=(0.0, 2.0)", s)
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

        # Oracle — and the pin that construction samples each provider exactly
        # once at t0 and the run once per anchor (NO double seeding).
        prov_f = mkprov()
        prob_f = esm_problem(fixture, (0.0, 3.0);
                             const_arrays = Dict{String,Any}("scale" => scale),
                             providers = Dict{String,Any}("src" => prov_f))
        @test prov_f.samples == [0.0]
        # The refresh callback is the PROBLEM's, composed at construction (§2.5.4).
        @test callbacks(prob_f) !== nothing
        rf = solve(prob_f, Tsit5())
        @test successful_retcode(rf)
        @test prov_f.samples == [0.0, 1.0, 2.0]
        c_f = [rf[Symbol("M.c[$k]")][end] for k in 1:3]
        d_f = [rf[Symbol("M.d[$k]")][end] for k in 1:3]
        @test isapprox(c_f, [6.0, 12.0, 18.0]; atol = 1e-6)
        @test isapprox(d_f, [7.0, 14.0, 21.0]; atol = 1e-6)

        # Build once → run twice. Run 1 starts from the construction-time seed
        # (t0 == sample_time, buffers pristine → no re-sample); run 2 finds the
        # buffers refreshed by run 1's callback and re-seeds them at t0, so the
        # runs are INDEPENDENT — and bit-identical.
        prov = mkprov()
        prob = esm_problem(fixture, (0.0, 3.0); sample_time = 0.0,
                           const_arrays = Dict{String,Any}("scale" => scale),
                           providers = Dict{String,Any}("src" => prov))
        @test prov.samples == [0.0]
        r1 = solve(prob, Tsit5())
        @test prov.samples == [0.0, 1.0, 2.0]
        r2 = solve(prob, Tsit5())
        @test prov.samples == [0.0, 1.0, 2.0, 0.0, 1.0, 2.0]
        @test successful_retcode(r1) && successful_retcode(r2)
        @test r1.u[end] == r2.u[end]
        @test [r1[Symbol("M.c[$k]")][end] for k in 1:3] ≈ c_f atol = 1e-9
        @test [r2[Symbol("M.d[$k]")][end] for k in 1:3] ≈ d_f atol = 1e-9
    end
end
