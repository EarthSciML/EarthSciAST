# End-to-end simulation of the coupled wildfire–atmosphere–ocean fixture
# `tests/valid/wildfire_atmosphere_ocean.esm` through the Julia tree-walk runner
# (`EarthSciAST.simulate`).
#
# What this exercises (the whole flatten → build_evaluator → integrate pipeline
# for a MULTI-model coupled system):
#   * A REAL inline conservative REGRID inside OceanDynamics: the atmosphere-grid
#     sensible-heat flux (`flux_field` = [50,150,250,350] on 4 atmos cells) is
#     remapped onto the 3-cell ocean grid by overlap weights W[a,o]=A[a,o]/A_o
#     computed INLINE from cell geometry — bin-skolem broad phase (value
#     invention: `rg_src_bin`/`rg_tgt_bin`/`rg_pairs`) + fused
#     `polygon_intersection_area` narrow phase (esm-spec §8.6.1). The overlaps are
#     A=[[1,0,0],[1,0,0],[0,1,0],[0,.5,.5]], A_o=[2,1.5,.5], so
#     surface_heat_flux = Σ_a W[a,o]·flux_atmos[a] = [100, 850/3, 350] W/m^2
#     (conservative: Σ_o A_o·shf_o = Σ_a A_a·flux_a = 800).
#   * SPATIAL LIFTING of a whole-array declared-shape state ODE: D(SST) integrates
#     per ocean cell; `u_ocean` (a declared array state with an `ic` and no
#     D-equation) stays 0, so −u_ocean·grad(SST) vanishes and
#     SST(t) = 290 + t·surface_heat_flux/4.18e6 — LINEAR. Asserting SST(3600)
#     therefore validates the inline regrid weights indirectly but precisely.
#   * MULTI-MODEL coupling + flatten namespacing: the 5 models flatten into one
#     system; the atmosphere/fire 0-D scalar states (T, phi, fuel, winds) have
#     grad terms that correctly evaluate to 0 over a structurally-0-D field, so
#     they stay constant (T=288, phi=1, fuel=10) and inject no spurious dynamics.
#
# The OceanDynamics model's inline `tests` block is the source of truth for the
# trajectory; this runner executes every assertion in it, and additionally spot-
# checks the constant atmosphere/fire states.
using Test
using EarthSciAST
import OrdinaryDiffEqTsit5: Tsit5
const _ESS_WF = EarthSciAST

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
        isapprox(tv, t; atol = 1e-9) && return i
    end
    error("no saved time point at t=$t (saved: $times)")
end

@testset "wildfire_atmosphere_ocean.esm — inline regrid + coupled SST simulation" begin
    fixture = joinpath(@__DIR__, "..", "..", "..", "tests", "valid",
                       "wildfire_atmosphere_ocean.esm")
    @test isfile(fixture)

    file = _ESS_WF.load(fixture)
    # The trajectory `tests` block lives on the OceanDynamics model.
    ocean = file.models["OceanDynamics"]
    @test !isempty(ocean.tests)

    for t in ocean.tests
        @testset "$(t.id)" begin
            atimes = sort!(unique(Float64[a.time for a in t.assertions]))
            tspan = (t.time_span.start, t.time_span.stop)

            r = _ESS_WF.simulate(fixture, tspan; alg = Tsit5(),
                                 reltol = 1e-9, abstol = 1e-11,
                                 saveat = atimes)
            @test r.success && r.retcode == :Success

            for a in t.assertions
                # `a.variable` is model-local (e.g. "SST[1]"); the flattened /
                # simulated element is namespaced under the OceanDynamics model.
                key = "OceanDynamics." * a.variable
                @test haskey(r.var_map, key)
                ti = _wf_time_index(r.t, Float64(a.time))
                actual = r[key][ti]
                rel, abs_ = _wf_resolve_tol(ocean.tolerance, t.tolerance, a.tolerance)
                if rel > 0
                    @test isapprox(actual, a.expected; rtol = rel, atol = abs_)
                else
                    @test isapprox(actual, a.expected; atol = abs_)
                end
            end

            # Spot-check the coupled 0-D scalar states: the wildfire/atmosphere
            # side has grad terms over structurally-0-D fields (→ 0) and no
            # activating dynamics, so it stays at its initial condition. This
            # guards the grad-on-scalar zeroing and the flatten coupling.
            for (k, expected) in ("AtmosphericDynamics.T" => 288.0,
                                  "WildfirePropagation.phi" => 1.0,
                                  "WildfirePropagation.fuel" => 10.0)
                if haskey(r.var_map, k)
                    @test isapprox(r[k][end], expected; atol = 1e-8)
                end
            end
        end
    end
end
