# Conformance harness adapter — pde_inline_ic_param_override category.
#
# esm-spec §6.6.5 "Build-time evaluation scope": every reference resolved
# BEFORE the simulation runs — a coordinate-expression `ic` (§11.4.1) and an
# inline analytic assertion `reference` — binds the model's parameters to their
# `parameter_overrides`-or-default values, with the overrides keyed by LOCAL
# parameter name (§6.6). The reference binding (Julia) runs the OFFICIAL
# `run_pde_tests` pathway over the committed fixture and must reproduce the
# committed golden actuals (which that same pathway minted). The manifest
# declares julia/python/rust as bindings_required.
#
# This is the conformance GATE for the `parameter_overrides` key-canonicalization
# fix. Before it, the tree-walk build resolved overrides by EXACT key against the
# flattening-qualified parameter name (`M.A`), so the spec-spelled local key
# (`A`) missed every consumer — the coordinate-expression `ic` seed, the
# parameter NamedTuple, and `inspect.params` (the §6.6.5 reference scope). The
# run silently used the DEFAULT and the inline test still reported a verdict:
# a quiet wrong answer in the test runner itself. Fixture parameter `A` appears
# ONLY in `ic(u)` and in assertion references, never in an equation, so the
# override can change the answer through the build-time scope and nowhere else.
# See tests/conformance/pde_inline_ic_param_override/.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import SciMLBase: solve, remake
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _ICPO_REPO_ROOT = TESTUTILS_REPO_ROOT
const _ICPO_CAT_DIR   = joinpath(_ICPO_REPO_ROOT, "tests", "conformance",
                                 "pde_inline_ic_param_override")
const _ICPO_MANIFEST  = joinpath(_ICPO_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_ic_param_override (manifest-driven)" begin
    @test isfile(_ICPO_MANIFEST)
    manifest = JSON3.read(read(_ICPO_MANIFEST, String))
    @test manifest.category == "pde_inline_ic_param_override"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_ICPO_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_ICPO_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index by (test_id, assertion_idx) — this category has THREE tests
            # in one model, distinguished only by their `parameter_overrides` —
            # and gate each against BOTH the golden actual (cross-binding
            # anchor) and the fixture's own declared `expected` (author intent).
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

# Direct unit coverage of the key canonicalization the category gates, on the
# TYPED build path: a LOCAL-named override must bind a flattening-qualified
# parameter, and an already-qualified key must keep working.
@testset "parameter_overrides key canonicalization (esm-spec §6.6)" begin
    esm_path = joinpath(_ICPO_CAT_DIR, "fixtures", "ic_param_override.esm")

    for (spelling, key) in (("local", "A"), ("qualified", "M.A"))
        @testset "$(spelling) override key" begin
            insp = EarthSciAST.BuildInspection()
            sim = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0); inspect=insp,
                                       p=Dict(key => 0.0)), OrdinaryDiffEqTsit5.Tsit5();
                                       saveat=[0.0])
            @test SciMLBase.successful_retcode(sim)
            # The build resolved the parameter to the OVERRIDE, not the 1.0
            # default, whichever spelling the caller used.
            @test insp.params["M.A"] == 0.0
            # ...and the coordinate-expression ic seeded from that same scope.
            for i in 1:5
                @test sim[Symbol("M.u[$i]")][1] == 0.0
            end
        end
    end

    # An override naming NO parameter of the model is REJECTED (esm-spec §6.6.2
    # "Unrecognized override keys"). This test previously pinned the opposite —
    # that such a key stayed inert — which was the deliberately-preserved
    # pre-existing behaviour when the canonicalization landed. It is the same
    # silent-wrong-answer shape one level up: the author writes an override,
    # nothing happens, and the run measures the configuration they thought they
    # had switched off while still reporting a verdict. Rust already raised
    # `InvalidParameter` here; Julia and Python now match it.
    @test_throws ArgumentError solve(EarthSciAST.esm_problem(
        esm_path, (0.0, 1.0);
        p=Dict("not_a_param" => 7.0)), OrdinaryDiffEqTsit5.Tsit5(); saveat=[0.0])
end
