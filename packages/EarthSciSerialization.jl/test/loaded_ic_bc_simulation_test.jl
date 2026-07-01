# End-to-end simulation of the worked scoped-reference-`ic` fixture
# `tests/valid/advection_reaction_loaded_ic_bc.esm` through the Julia tree-walk
# runner (`EarthSciSerialization.simulate`), with every loaded field injected
# through the data-**Provider** seam (DESIGN pde_simulation_pipeline §2).
#
# What this exercises:
#   * A REAL `reaction_systems` Chemistry (O3/NO/NO2, R1/R2) lowered to generic
#     per-species ODEs, then SPATIALLY LIFTED onto the 4×2 lon/lat grid by
#     `operator_compose(Chemistry, Advection)` + `lifting:"pointwise"`. The
#     flattener's pointwise lift (`_apply_pointwise_lift!`) array-ifies the merged
#     reaction+advection state ODEs so the reaction network runs per grid cell.
#   * SCOPED-REFERENCE `ic` resolution (spec §11.4.1): `ChemistryICs` hosts
#     `ic(Chemistry.O3) ~ InitialConditions.O3_init` (and NO, NO2). Each RHS is a
#     LOADED FIELD served by the stub provider; `_resolve_field_ic` folds the
#     provider-seeded [lon,lat] field into u0 cell-by-cell at build time.
#   * The loader→consumer `variable_map` bindings (spec §11.5): the wind field
#     (`Meteorology.u_wind → Advection.u_wind`) and the per-species western
#     inflow BCs (`BoundaryConditions.{O3,NO,NO2}_inflow → Advection.*_inflow`)
#     bind their consumer parameters from the loaders; the flattener routes the
#     lifted gather to the loader name, satisfied by the provider-seeded field.
#
# Provider injection (NOT raw const_arrays keyed by consumer name): a static
# stub provider serves the fixture's DECLARED loader variables (keyed
# `<Loader>.<var>`) from the manifest `inputs` arrays. Every provider is CONST
# (empty `provider_refresh_times`), so `simulate` materializes each field once at
# build time into `const_arrays` under its loader name — reachable when the
# scoped-`ic` fold seeds u0 (R2) and when the `variable_map` binding resolves the
# consumer gather. The reaction system's own inline `tests` block is the source
# of truth: this runner executes every assertion in it.
using Test
using EarthSciSerialization
import OrdinaryDiffEqTsit5: Tsit5
const _ESS_IC = EarthSciSerialization

# ---------------------------------------------------------------------------- #
# Static stub Provider (DESIGN §2). Serves the fixture's declared loader
# variables from the manifest `inputs` arrays. CONST: empty `refresh_times` ⇒
# `provider_is_const` is true ⇒ materialized once at build time, contributes no
# tstops. `provider_sample` returns the full `<Loader>.<var> => field` table;
# `simulate` extracts each variable's field by name. [lon,lat] = [4,2]; Julia is
# column-major, so row = lon index, column = lat index — the same numeric values
# the const-array runner used, re-keyed onto the declared loader names.
# ---------------------------------------------------------------------------- #
struct _StubLoaderProvider
    fields::Dict{String,Array{Float64}}
end
_ESS_IC.provider_refresh_times(::_StubLoaderProvider) = Float64[]           # CONST
_ESS_IC.provider_sample(p::_StubLoaderProvider, ::Real) = p.fields

const _LOADED_PROVIDER_FIELDS = Dict{String,Array{Float64}}(
    # Initial-condition fields — RHS of the scoped-reference `ic` equations.
    "InitialConditions.O3_init"  => [38.0 42.0; 39.0 43.0; 41.0 45.0; 43.0 47.0],
    "InitialConditions.NO_init"  => [0.10 0.12; 0.11 0.13; 0.09 0.14; 0.12 0.15],
    "InitialConditions.NO2_init" => [1.0  1.2;  1.1  1.3;  0.9  1.4;  1.2  1.5],
    # Meteorology wind field bound to Advection.u_wind by `variable_map`.
    "Meteorology.u_wind" => [2.0 2.2; 2.1 2.3; 2.2 2.4; 2.3 2.5],
    # Per-species western-inflow fields (over the lat boundary) bound to
    # Advection.*_inflow by `variable_map` (spec §11.5 "BCs from data").
    "BoundaryConditions.O3_inflow"  => [35.0, 36.0],
    "BoundaryConditions.NO_inflow"  => [0.20, 0.25],
    "BoundaryConditions.NO2_inflow" => [1.5, 1.6],
)

# `providers` maps each declared loader variable to the stub that serves it. One
# stub object backs every variable; it is sampled once per variable at build time.
function _loaded_providers()
    stub = _StubLoaderProvider(_LOADED_PROVIDER_FIELDS)
    return Dict{String,Any}(k => stub for k in keys(_LOADED_PROVIDER_FIELDS))
end

# Resolve (rel, abs) precedence: assertion → test → model (unset field = 0).
function _ic_bc_resolve_tol(model_tol, test_tol, assertion_tol)
    for cand in (assertion_tol, test_tol, model_tol)
        cand === nothing && continue
        r = cand.rel === nothing ? 0.0 : cand.rel
        a = cand.abs === nothing ? 0.0 : cand.abs
        return (r, a)
    end
    return (1.0e-6, 0.0)
end

# Index of `t` in the saved time grid (exact match; the run `saveat`s the
# assertion times so a stored point exists).
function _time_index(times::Vector{Float64}, t::Float64)
    for (i, tv) in enumerate(times)
        isapprox(tv, t; atol = 1e-9) && return i
    end
    error("no saved time point at t=$t (saved: $times)")
end

@testset "advection_reaction_loaded_ic_bc.esm — scoped-ref ic + loaded BC simulation (provider)" begin
    fixture = joinpath(@__DIR__, "..", "..", "..", "tests", "valid",
                       "advection_reaction_loaded_ic_bc.esm")
    @test isfile(fixture)

    file = _ESS_IC.load(fixture)
    # The lifted reaction network's `tests` block lives on the reaction system.
    chem = file.reaction_systems["Chemistry"]
    @test !isempty(chem.tests)

    # Every loaded field is CONST — no field is injected by internal consumer name.
    stub = _StubLoaderProvider(_LOADED_PROVIDER_FIELDS)
    @test _ESS_IC.provider_is_const(stub)

    for t in chem.tests
        @testset "$(t.id)" begin
            # `saveat` the exact assertion times so each is a stored point.
            atimes = sort!(unique(Float64[a.time for a in t.assertions]))
            tspan = (t.time_span.start, t.time_span.stop)

            r = _ESS_IC.simulate(fixture, tspan; alg = Tsit5(),
                                 providers = _loaded_providers(),
                                 reltol = 1e-9, abstol = 1e-11,
                                 saveat = atimes)
            @test r.success && r.retcode == :Success

            for a in t.assertions
                # `a.variable` is model-local (e.g. "O3[1,1]"); the flattened /
                # simulated element is namespaced under the Chemistry model.
                key = "Chemistry." * a.variable
                @test haskey(r.var_map, key)
                ti = _time_index(r.t, Float64(a.time))
                actual = r[key][ti]
                rel, abs_ = _ic_bc_resolve_tol(chem.tolerance, t.tolerance, a.tolerance)
                if rel > 0
                    @test isapprox(actual, a.expected; rtol = rel, atol = abs_)
                else
                    @test isapprox(actual, a.expected; atol = abs_)
                end
            end
        end
    end
end
