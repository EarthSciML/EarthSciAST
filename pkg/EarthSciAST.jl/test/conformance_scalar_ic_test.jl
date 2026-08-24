# Conformance harness adapter — scalar_ic category.
#
# esm-spec §11.4 "Initial conditions (the `ic` op)" at rank ZERO: an `ic`-LHS
# equation IS the initial value of its target, a 0-D component's `ic` RHS is a
# scalar, a state with no `ic` falls back to its declared `default`, and a
# test's `initial_conditions` overrides the `ic` for that run. Model PARAMETERS
# bind in the RHS's build-time evaluation scope (§6.6.5). The reference binding
# (Julia) runs the OFFICIAL `run_pde_tests` pathway over the committed fixtures
# and must reproduce the committed goldens (which that same pathway minted).
#
# This is the conformance GATE for the 0-D `ic` fix. Before it, Python dropped
# every 0-D `ic` on BOTH of its pathways and Rust dropped it on its scalar
# interpreter, in each case silently seeding the state from its declared
# `default` and still reporting a test verdict. Every state in `scalar_ic.esm`
# declares a `default` that DIFFERS from its `ic` so that substitution cannot
# hide, and `y` integrates `D(y)/dt = u` so the seeded value must also reach the
# trajectory. See tests/conformance/scalar_ic/.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import SciMLBase: solve, remake
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _SIC_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", "scalar_ic")
const _SIC_MANIFEST = joinpath(_SIC_CAT_DIR, "manifest.json")

@testset "Conformance: scalar_ic (manifest-driven)" begin
    @test isfile(_SIC_MANIFEST)
    manifest = JSON3.read(read(_SIC_MANIFEST, String))
    @test manifest.category == "scalar_ic"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_SIC_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_SIC_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index by (test_id, assertion_idx) and gate each against BOTH the
            # golden actual (the cross-binding anchor) and the fixture's own
            # declared `expected` (author intent, via `r.passed`).
            by_key = Dict((r.test_id, r.assertion_idx) => r for r in results)
            for g in golden.assertions
                key = (String(g.test_id), Int(g.assertion_idx))
                @test haskey(by_key, key)
                r = by_key[key]
                @test r.passed
                @test r.actual !== nothing
                @test isapprox(r.actual, Float64(g.actual); rtol=rtol, atol=atol)
            end
        end
    end
end

# Direct unit coverage of the seeding precedence the category gates, on the
# TYPED build path: an explicit `initial_conditions` entry wins, else the state's
# own `ic` equation (with parameters bound to their override-or-default values),
# else the declared `default`.
@testset "0-D ic seeding precedence (esm-spec §11.4)" begin
    esm_path = joinpath(_SIC_CAT_DIR, "fixtures", "scalar_ic.esm")

    at0(sim, name) = sim[Symbol(name)][1]

    # (1) Defaults: each state takes its own ic; `z` has none and takes 7.0.
    sim = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0)), OrdinaryDiffEqTsit5.Tsit5(); saveat=[0.0])
    @test SciMLBase.successful_retcode(sim)
    @test at0(sim, "M.u") == 3.0
    @test at0(sim, "M.q") == 2.0
    @test at0(sim, "M.w") == 4.0
    @test at0(sim, "M.z") == 7.0

    # (2) A parameter override reaches the ic's build-time scope (§6.6.5),
    # under either spelling of the key (§6.6.2).
    for key in ("A", "M.A")
        sim = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0);
                                   p=Dict(key => 10.0)), OrdinaryDiffEqTsit5.Tsit5(); saveat=[0.0])
        @test SciMLBase.successful_retcode(sim)
        @test at0(sim, "M.w") == 20.0
        @test at0(sim, "M.u") == 3.0   # parameter-free ic unmoved
    end

    # (3) A run-time `initial_conditions` entry beats the ic equation, under
    # either spelling of the key. `u` is the LOCAL name esm-spec §6.6.2 pins for
    # a test's `initial_conditions`; flattening qualifies the state as `M.u`.
    for key in ("u", "M.u")
        sim = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0);
                                   u0=Dict(key => 9.0)), OrdinaryDiffEqTsit5.Tsit5(); saveat=[0.0])
        @test SciMLBase.successful_retcode(sim)
        @test at0(sim, "M.u") == 9.0
        @test at0(sim, "M.w") == 4.0   # a state the override does not name keeps its ic
    end

    # (4) An `initial_conditions` key naming no state is still rejected — the
    # local-name resolution widened what resolves, not what is accepted.
    @test_throws EarthSciAST.SimulateError solve(EarthSciAST.esm_problem(
        esm_path, (0.0, 1.0);
        u0=Dict("not_a_state" => 1.0)), OrdinaryDiffEqTsit5.Tsit5(); saveat=[0.0])
end
