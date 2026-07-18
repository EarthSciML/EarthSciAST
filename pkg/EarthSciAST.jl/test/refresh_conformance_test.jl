# Cross-language REFRESH-PATH conformance (CONFORMANCE_SPEC.md §5.10). Shared
# fixture + analytic golden live under `tests/conformance/refresh/`; the Python
# (`test_refresh_conformance.py`) and Rust (`refresh_conformance.rs`) runners
# reproduce the same golden.
#
# A discretized, COUPLED, non-PDE model reads forcing from data loaders at a
# discrete cadence and REGRIDS it from the coarse 6-cell native grid onto the
# 3-cell sim grid — IN-MODEL, as a const-`W` coupling contraction
# (`F_tgt[j] = sum_i W[i,j]*F_src[i]`), NOT through a regrid seam (the obsolete
# RegridApplier was removed in v0.8.0). `F_src` is DISCRETE (loader `emis` has a
# `temporal` block) so `F_tgt` is a DISCRETE-materialized field refreshed at each
# cadence anchor; `scale_src` is CONST (loader `factors`, no temporal) so
# `scale_tgt` is build-once. `D(c[j]) = scale_tgt[j]*F_tgt[j]`, `D(d[j]) = c[j]`.
#
# TWO-VIEW contract: the loader-fed `F_src`/`scale_src` are declared
# `discrete`+`data_ingest` for the cadence classifier, but the typed RHS compiler
# has no Discrete VariableType — this adapter STRIPS them (and `data_loaders`)
# from the doc so they resolve through the forcing buffers (`param_arrays` for the
# DISCRETE `F_src`, `const_arrays` for the CONST `scale_src`). Julia's idiom is a
# single `solve` over a `build_refresh_callback` whose `post_refresh =
# dm.materialize!` refreshes `F_tgt` per anchor. Two bands are asserted: the
# regridded fields (`F_tgt`/`scale_tgt`) and the integrated trajectory.
using Test
using EarthSciAST
using DiffEqCallbacks            # loads EarthSciASTDataRefreshExt
using SciMLBase                  # ext co-trigger (u_modified!)
import OrdinaryDiffEqTsit5 as ODE  # Tsit5 + ODEProblem + solve (test-only solver dep)
using JSON3
const _ESS_RG = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT + _require_fixture (idempotent)

# Recursively convert a parsed JSON3 tree into a mutable nested Dict/Vector so the
# loader-fed `discrete` declarations can be stripped for the simulate view.
_rg_mutable(x::JSON3.Object) = Dict{String,Any}(String(k) => _rg_mutable(v) for (k, v) in x)
_rg_mutable(x::JSON3.Array) = Any[_rg_mutable(v) for v in x]
_rg_mutable(x) = x

# A minimal offline mock Provider returning `F_src` at each interior anchor from
# the golden's `native_fields` (the 6-cell native grid). No network.
mutable struct _RGConfProvider
    times::Vector{Float64}
    fields::Dict{Float64,Dict{String,Vector{Float64}}}
end
_ESS_RG.provider_refresh_times(p::_RGConfProvider) = p.times
_ESS_RG.provider_sample(p::_RGConfProvider, t::Real) = p.fields[Float64(t)]

@testset "refresh conformance — discrete-cadence loader + in-model regrid (§5.10)" begin
    root = joinpath(@__DIR__, "..", "..", "..", "tests", "conformance", "refresh")
    fixture = joinpath(root, "fixtures", "coupled_refresh_regrid.esm")
    golden_path = joinpath(root, "golden", "coupled_refresh_regrid.json")
    if _require_fixture(fixture) && _require_fixture(golden_path)
        golden = JSON3.read(read(golden_path, String))

        # Native 6-cell loader fields (offline, from the golden).
        scale_native = Float64.(golden["native_fields"]["M.scale_src"]["values"])
        fsrc_anchor(t) = Float64.(golden["native_fields"]["M.F_src"]["by_anchor"][Symbol(string(t))])
        ftgt_anchor(t) = Float64.(golden["regridded_fields"]["M.F_tgt"]["by_anchor"][Symbol(string(t))])
        scale_tgt_want = Float64.(golden["regridded_fields"]["M.scale_tgt"])
        anchors = sort!(Float64[parse(Float64, String(k))
                                for k in keys(golden["native_fields"]["M.F_src"]["by_anchor"])])
        field_atol = 1e-9

        # Simulate view: strip the loader-fed `discrete` declarations (+ the
        # `data_loaders` block) so the typed RHS resolves F_src/scale_src as
        # forcing names. The cadence classifier's view is the raw doc (unstripped);
        # the executor here is driven by the provider directly.
        sim_doc = _rg_mutable(JSON3.read(read(fixture, String)))
        for v in ("F_src", "scale_src")
            delete!(sim_doc["models"]["M"]["variables"], v)
        end
        delete!(sim_doc, "data_loaders")

        ics = Dict{String,Float64}()
        for s in ("c", "d"), j in 1:3
            ics["$s[$j]"] = 0.0
        end

        # (a) build: F_src -> param_arrays (DISCRETE, live buffer), scale_src ->
        # const_arrays (CONST, materialized once). F_tgt reads F_src -> a discrete
        # cache; scale_tgt reads only const data -> build-once.
        fsrc_buf = copy(fsrc_anchor(0.0))
        dm = _ESS_RG.DiscreteMaterializer()
        f!, u0, p, _ts, vm = _ESS_RG.build_evaluator(sim_doc;
            initial_conditions = ics,
            const_arrays = Dict("scale_src" => scale_native),
            param_arrays = Dict("F_src" => fsrc_buf),
            materialize_out = dm)

        # (b) regrid band — the in-model regrid reproduces the golden regridded
        # fields. F_tgt (DISCRETE cache) at each anchor; scale_tgt (CONST) once.
        @test haskey(dm.caches, "F_tgt")          # forcing-tainted -> discrete cache
        @test !haskey(dm.caches, "scale_tgt")     # const-fed -> build-once/inlined (not a cache)
        for t in anchors
            fsrc_buf .= fsrc_anchor(t)
            dm.materialize!()
            @test vec(Float64.(dm.caches["F_tgt"])) ≈ ftgt_anchor(t) atol = field_atol
        end
        # scale_tgt is CONST (inlined into the RHS, not a named cache): recover it
        # from the derivative. At anchor 0, F_tgt = [1,1,1], so
        # du[c] = scale_tgt .* F_tgt = scale_tgt — the const in-model regrid.
        fsrc_buf .= fsrc_anchor(0.0); dm.materialize!()
        @test vec(Float64.(dm.caches["F_tgt"])) ≈ [1.0, 1.0, 1.0] atol = field_atol
        du0 = zero(u0); f!(du0, u0, p, 0.0)
        @test [du0[vm["c[$j]"]] for j in 1:3] ≈ scale_tgt_want atol = field_atol

        # (c) trajectory band — ONE solve over a refresh callback that refreshes
        # F_src at each interior anchor and fires post_refresh = dm.materialize!
        # (the integrated discrete-materialization path). scale_src is CONST (no
        # provider, no tstop). Forcing frozen per segment -> closed form to tol.
        fsrc_buf2 = copy(fsrc_anchor(0.0))
        dm2 = _ESS_RG.DiscreteMaterializer()
        f2!, u02, p2, _ts2, vm2 = _ESS_RG.build_evaluator(sim_doc;
            initial_conditions = ics,
            const_arrays = Dict("scale_src" => scale_native),
            param_arrays = Dict("F_src" => fsrc_buf2),
            materialize_out = dm2)
        interior = [t for t in anchors if t > 0.0]
        prov = _RGConfProvider(interior, Dict(t => Dict("F_src" => fsrc_anchor(t)) for t in interior))
        model = _ESS_RG.coerce_esm_file(JSON3.read(JSON3.write(sim_doc))).models["M"]
        cb, tstops = _ESS_RG.build_refresh_callback(;
            providers = Dict("F_src" => prov),
            buffers = _ESS_RG.RefreshBuffers(Dict("F_src" => fsrc_buf2)),  # SAME buffer object
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
            for s in ("c", "d"), j in 1:3
                want = Float64(traj[tk][Symbol("M.$s[$j]")])
                @test isapprox(sol.u[ti][vm2["$s[$j]"]], want; rtol = rtol, atol = atol)
            end
        end
    end
end
