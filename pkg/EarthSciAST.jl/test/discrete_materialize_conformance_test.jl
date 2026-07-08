# Cross-language conformance for DISCRETE-CADENCE MATERIALIZATION — the middle
# cadence phase (`const ⌷ discrete ⌷ continuous`; CONFORMANCE_SPEC.md §5.13).
# Shared fixture + analytic golden live under
# `tests/conformance/discrete_materialize/`; the Python
# (`test_discrete_materialize_conformance.py`) and Rust
# (`discrete_materialize_conformance.rs`) runners reproduce the same golden.
#
# Model `M` mixes a CONST weight matrix `W` (an in-file `const` observed) with a
# DISCRETE forcing field `src` (a bare forcing name in `param_arrays`) inside a
# conservative-regrid-shaped CONTRACTION `g[j] = sum_i W[i,j]*src[i]`: state-free
# but forcing-tainted, so the `DiscreteMaterializer` cuts it out of the per-step
# RHS into a cache refreshed once per cadence boundary and gathered live by the
# hot RHS. A sibling `k[j] = sum_i W[i,j]*offset` reads only const/parameter data
# — state-free AND forcing-free — so it stays CONST-cadence (build-once/inline)
# and MUST NOT be cached (the regression guard against an over-broad cut). The
# per-cell ODE `D(c[j]) = g[j] + k[j]` couples both into the continuous state.
#
# Unlike the Rust/Python adapters (which drive a manual segment loop), Julia's
# idiom is the integrated one: ONE `solve` over a `build_refresh_callback` whose
# `affect!` refreshes the forcing buffer at each cadence anchor and fires the new
# `post_refresh = dm.materialize!` hook — the exact wiring `simulate` uses. So this
# runner exercises the real materialization ⇄ refresh integration, not just the
# build-time cut. The forcing is piecewise-constant across segments, so the
# trajectory is analytic and exact.
using Test
using EarthSciAST
using DiffEqCallbacks            # loads EarthSciASTDataRefreshExt
using SciMLBase                  # ext co-trigger (u_modified!)
import OrdinaryDiffEqTsit5 as ODE  # Tsit5 + ODEProblem + solve (test-only solver dep)
using JSON3
const _ESS_DM = EarthSciAST

# A minimal offline mock Provider returning `src` at each interior anchor from the
# golden's `forcing.by_anchor` snapshots (the Julia analogue of the Rust
# `ScheduledProvider` / Python provider stub). No network — the CI contract.
mutable struct _DMConfProvider
    times::Vector{Float64}
    fields::Dict{Float64,Dict{String,Vector{Float64}}}
end
_ESS_DM.provider_refresh_times(p::_DMConfProvider) = p.times
_ESS_DM.provider_sample(p::_DMConfProvider, t::Real) = p.fields[Float64(t)]

@testset "discrete_materialize conformance — discrete-cadence materialization (§5.13)" begin
    root = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "discrete_materialize")
    fixture = joinpath(root, "fixtures", "discrete_materialize_contraction.esm")
    golden_path = joinpath(root, "golden", "discrete_materialize_contraction.json")
    if _require_fixture(fixture) && _require_fixture(golden_path)
        golden = JSON3.read(read(golden_path, String))
        ics = Dict{String,Float64}("c[1]" => 0.0, "c[2]" => 0.0, "c[3]" => 0.0)
        anchors = sort!(Float64[parse(Float64, String(k))
                                for k in keys(golden["forcing"]["M.src"]["by_anchor"])])
        src_at(t) = Float64.(golden["forcing"]["M.src"]["by_anchor"][Symbol(string(t))])
        g_at(t) = Float64.(golden["discrete_field"]["M.g"]["by_anchor"][Symbol(string(t))])
        field_atol = 1e-9

        # (a) flatten: W/g/k are observeds (materialized/inlined), not ODE state
        # slots — only `M.c` is a state.
        flat = _ESS_DM.flatten(_ESS_DM.load(fixture))
        obs = Set(String.(keys(flat.observed_variables)))
        for name in ("M.W", "M.g", "M.k")
            @test name in obs
        end
        @test haskey(flat.state_variables, "M.c")
        @test !("M.g" in Set(String.(keys(flat.state_variables))))

        # (b) the const/discrete classification + field band: `g` (const × DISCRETE
        # forcing) is a discrete cache; `k` (const × parameter) is NOT. Re-materialize
        # at each anchor and assert the cache holds the golden contraction.
        srcbuf = copy(src_at(0.0))
        dm = _ESS_DM.DiscreteMaterializer()
        f!, u0, p, _ts, vm = _ESS_DM.build_evaluator(_ESS_DM.load(fixture);
            initial_conditions = ics, param_arrays = Dict("src" => srcbuf),
            materialize_out = dm)
        @test haskey(dm.caches, "g")     # forcing-tainted, state-free -> DISCRETE cache
        @test !haskey(dm.caches, "k")    # const/parameter-fed -> CONST-cadence (regression guard)
        for t in anchors
            srcbuf .= src_at(t)
            dm.materialize!()
            @test vec(Float64.(dm.caches["g"])) ≈ g_at(t) atol = field_atol
        end

        # (c) trajectory band: ONE solve over a refresh callback whose `affect!`
        # refreshes `src` at each interior anchor and fires `post_refresh =
        # dm.materialize!` (the integrated discrete-materialization path). Forcing
        # frozen per segment -> RHS pure -> closed form matched to solver tol.
        model = _ESS_DM.load(fixture).models["M"]
        srcbuf2 = copy(src_at(0.0))
        dm2 = _ESS_DM.DiscreteMaterializer()
        f2!, u02, p2, _ts2, vm2 = _ESS_DM.build_evaluator(_ESS_DM.load(fixture);
            initial_conditions = ics, param_arrays = Dict("src" => srcbuf2),
            materialize_out = dm2)
        interior = [t for t in anchors if t > 0.0]
        prov = _DMConfProvider(interior, Dict(t => Dict("src" => src_at(t)) for t in interior))
        cb, tstops = _ESS_DM.build_refresh_callback(model;
            providers = Dict("src" => prov),
            buffers = _ESS_DM.RefreshBuffers(Dict("src" => srcbuf2)),  # SAME buffer object
            post_refresh = dm2.materialize!)
        @test tstops == interior

        tspan = (Float64(golden["cadence"]["tspan"][1]), Float64(golden["cadence"]["tspan"][2]))
        traj = golden["trajectory"]
        atimes = sort!(Float64[parse(Float64, String(k)) for k in keys(traj) if String(k) != "comment"])
        prob = ODE.ODEProblem(f2!, u02, tspan, p2)
        sol = ODE.solve(prob, ODE.Tsit5(); callback = cb, tstops = tstops,
                        saveat = atimes, reltol = 1e-10, abstol = 1e-12)
        @test sol.retcode == ODE.SciMLBase.ReturnCode.Success

        rtol = 1e-4; atol = 1e-6
        for tk in keys(traj)
            String(tk) == "comment" && continue
            t = parse(Float64, String(tk))
            ti = findfirst(x -> isapprox(x, t; atol = 1e-9), sol.t)
            @test ti !== nothing
            for (jj, cell) in enumerate(("M.c[1]", "M.c[2]", "M.c[3]"))
                want = Float64(traj[tk][Symbol(cell)])
                @test isapprox(sol.u[ti][vm2["c[$jj]"]], want; rtol = rtol, atol = atol)
            end
        end
    end
end
