# The coupled wildfire–atmosphere–ocean fixture
# `tests/valid/wildfire_atmosphere_ocean.esm` at the Julia build entry points.
#
# Its `OceanDynamics.SST -> AirSeaFluxCalculator.SST` variable_map declares
# `lifting: "mean"`, a kind esm-spec §10.5 reserves and no compiler here
# implements. A binding that builds a runnable problem MUST refuse it with
# `unsupported_construct`, naming the edge and the kind, rather than read the
# raw array where the document asks for its mean. Validation and flatten accept
# the document; only the build refuses, from the document or from a system
# flattened beforehand. The regrid trajectory is checked on the document with
# that edge dropped in memory, and the last testset pins the refusal on a small
# inline document, for both reserved kinds.
using Test
using EarthSciAST
import SciMLBase
import JSON3
import OrdinaryDiffEqTsit5: Tsit5
const _ESS_WF = EarthSciAST

# The refusal a build of a document with a reserved lifting raises.
function _wf_build_error(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

function _wf_is_lifting_refusal(err, edge, kind)
    err isa _ESS_WF.TreeWalkError || return false
    err.code == _ESS_WF.ERROR_CODES.UNSUPPORTED_CONSTRUCT || return false
    msg = sprint(showerror, err)
    return occursin(edge, msg) && occursin("\"$(kind)\"", msg) &&
        occursin("esm-spec §10.5", msg) && occursin("not supported yet", msg)
end

@testset "wildfire_atmosphere_ocean.esm — the mean variable_map is refused at build" begin
    fixture = joinpath(
        @__DIR__, "..", "..", "..", "tests", "valid",
        "wildfire_atmosphere_ocean.esm"
    )
    @test isfile(fixture)

    file = _ESS_WF.load_path(fixture)
    ocean = file.models["OceanDynamics"]
    @test !isempty(ocean.tests)
    # Validation and flatten are unaffected.
    @test _ESS_WF.validate(file).is_valid
    @test _ESS_WF.flatten(file) isa _ESS_WF.FlattenedSystem

    edge = "OceanDynamics.SST -> AirSeaFluxCalculator.SST"
    @testset "esm_problem [$(c)]" for c in (:interpreter, :native)
        err = _wf_build_error(() -> _ESS_WF.esm_problem(fixture, (0.0, 3600.0); compiler = c))
        @test _wf_is_lifting_refusal(err, edge, "mean")
    end
    @testset "run_inline_tests" begin
        results = _ESS_WF.run_inline_tests(fixture; compiler = :interpreter)
        @test !isempty(results)
        @test all(r -> r.status != _ESS_WF.PASS, results)
        @test all(r -> occursin(edge, something(r.message, "")), results)
    end
end

@testset "wildfire_atmosphere_ocean.esm — a flattened system with the mean edge is refused at build" begin
    fixture = joinpath(
        @__DIR__, "..", "..", "..", "tests", "valid",
        "wildfire_atmosphere_ocean.esm"
    )
    flat = _ESS_WF.flatten(_ESS_WF.load_path(fixture))
    @test flat.metadata.reserved_liftings ==
        [("OceanDynamics.SST", "AirSeaFluxCalculator.SST", "mean")]
    edge = "OceanDynamics.SST -> AirSeaFluxCalculator.SST"
    @testset "esm_problem [$(c)]" for c in (:interpreter, :native)
        err = _wf_build_error(() -> _ESS_WF.esm_problem(flat, (0.0, 3600.0); compiler = c))
        @test _wf_is_lifting_refusal(err, edge, "mean")
    end
end

# Resolve (rel, abs) precedence: assertion → test → model (unset field = 0).
function _wf_resolve_tol(model_tol, test_tol, assertion_tol)
    for cand in (assertion_tol, test_tol, model_tol)
        cand === nothing && continue
        r = cand.rel === nothing ? 0.0 : cand.rel
        a = cand.abs === nothing ? 0.0 : cand.abs
        return (r, a)
    end
    return (1.0e-6, 0.0)
end

# Index of `t` in the saved time grid (the run `saveat`s the assertion times).
function _wf_time_index(times::Vector{Float64}, t::Float64)
    for (i, tv) in enumerate(times)
        isapprox(tv, t; atol = 1.0e-9) && return i
    end
    error("no saved time point at t=$t (saved: $times)")
end

# The fixture without its one reserved-lifting edge
# (`OceanDynamics.SST -> AirSeaFluxCalculator.SST`, `lifting: "mean"`). The edge
# feeds only the 0-D flux calculator's scalar SST, which no assertion below
# reads, so the regrid trajectory is checked on the document without it.
function _wf_without_reserved_lifting(fixture)
    raw = JSON3.read(read(fixture, String), Dict{String, Any})
    kept = [c for c in raw["coupling"] if !(get(c, "lifting", nothing) in ("mean", "integral"))]
    @assert length(kept) == length(raw["coupling"]) - 1
    raw["coupling"] = kept
    return _ESS_WF.load_document(raw)
end

# What this exercises (the whole flatten → build → integrate pipeline for a
# MULTI-model coupled system):
#   * A REAL inline conservative REGRID inside OceanDynamics: the atmosphere-grid
#     sensible-heat flux (`flux_field` = [50,150,250,350] on 4 atmos cells) is
#     remapped onto the 3-cell ocean grid by overlap weights W[a,o]=A[a,o]/A_o
#     computed INLINE from cell geometry. The overlaps are
#     A=[[1,0,0],[1,0,0],[0,1,0],[0,.5,.5]], A_o=[2,1.5,.5], so
#     surface_heat_flux = Σ_a W[a,o]·flux_atmos[a] = [100, 850/3, 350] W/m^2.
#   * A whole-array declared-shape state ODE: D(SST) integrates per ocean cell;
#     `u_ocean` stays 0, so SST(t) = 290 + t·surface_heat_flux/4.18e6, LINEAR.
#     Asserting SST(3600) validates the inline regrid weights indirectly but
#     precisely.
# The OceanDynamics model's inline `tests` block is the source of truth for the
# trajectory; every assertion in it is executed.
@testset "wildfire_atmosphere_ocean.esm without the mean edge — inline regrid + SST trajectory" begin
    fixture = joinpath(
        @__DIR__, "..", "..", "..", "tests", "valid",
        "wildfire_atmosphere_ocean.esm"
    )
    file = _wf_without_reserved_lifting(fixture)
    ocean = file.models["OceanDynamics"]
    @test !isempty(ocean.tests)

    for t in ocean.tests
        @testset "$(t.id)" begin
            atimes = sort!(unique(Float64[a.time for a in t.assertions]))
            tspan = (t.time_span.start, t.time_span.stop)

            prob = _ESS_WF.esm_problem(file, tspan)
            r = SciMLBase.solve(prob, Tsit5(); reltol = 1.0e-9, abstol = 1.0e-11, saveat = atimes)
            @test SciMLBase.successful_retcode(r)

            for a in t.assertions
                # `a.variable` is model-local (e.g. "SST[1]"); the simulated
                # element is namespaced under the OceanDynamics model.
                key = "OceanDynamics." * a.variable
                @test haskey(prob.var_map, key)
                ti = _wf_time_index(r.t, Float64(a.time))
                actual = r.u[ti][prob.var_map[key]]
                rel, abs_ = _wf_resolve_tol(ocean.tolerance, t.tolerance, a.tolerance)
                if rel > 0
                    @test isapprox(actual, a.expected; rtol = rel, atol = abs_)
                else
                    @test isapprox(actual, a.expected; atol = abs_)
                end
            end
        end
    end
end

# A small coupled document whose variable_map declares `lifting`.
function _wf_lifting_doc(kind)
    return Dict{String, Any}(
        "esm" => "2.2.0",
        "metadata" => Dict("name" => "reserved_lifting", "authors" => ["EarthSciAST test suite"]),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => 3)),
        "models" => Dict(
            "Grid" => Dict(
                "variables" => Dict(
                    "q" => Dict(
                        "type" => "parameter", "units" => "1", "default" => 1.0,
                        "shape" => ["x"]
                    )
                ),
                "equations" => []
            ),
            "Box" => Dict(
                "variables" => Dict(
                    "q_in" => Dict("type" => "parameter", "units" => "1", "default" => 0.0),
                    "y" => Dict("type" => "unknown", "units" => "1", "default" => 0.0)
                ),
                "equations" => [
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"),
                        "rhs" => Dict("op" => "*", "args" => [0.1, "q_in"])
                    ),
                ]
            )
        ),
        "coupling" => [
            Dict(
                "type" => "variable_map", "from" => "Grid.q", "to" => "Box.q_in",
                "transform" => "param_to_var", "lifting" => kind
            ),
        ]
    )
end

@testset "a mean or integral variable_map lifting is refused at build (esm-spec §10.5)" begin
    @testset "$(kind)" for kind in ("mean", "integral")
        doc = _wf_lifting_doc(kind)
        file = _ESS_WF.load_document(doc)
        @test _ESS_WF.validate(file).is_valid
        @test _ESS_WF.flatten(file) isa _ESS_WF.FlattenedSystem
        @testset "[$(c)]" for c in (:interpreter, :native)
            err = _wf_build_error(() -> _ESS_WF.esm_problem(doc, (0.0, 1.0); compiler = c))
            @test _wf_is_lifting_refusal(err, "Grid.q -> Box.q_in", kind)
        end
    end
    # `broadcast` and `pointwise` are not refused.
    @testset "$(kind) is not refused" for kind in ("broadcast", "pointwise")
        file = _ESS_WF.load_document(_wf_lifting_doc(kind))
        @test _ESS_WF._refuse_reserved_liftings(file) === nothing
    end
end
