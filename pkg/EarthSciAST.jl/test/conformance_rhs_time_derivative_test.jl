# Conformance harness adapter — rhs_time_derivative category.
#
# esm-spec §4.2's RIGHT-HAND-SIDE structural `D` rule, in both of its halves.
#
#   RESOLVE — a `D` with `wrt: "t"` (or no `wrt`) whose `args[1]` is a bare
#   reference to an unknown that CARRIES a differential equation names that
#   unknown's tendency, and is substituted during flattening (step 3c), through
#   chained tendencies. So `dxdt ~ D(x, t)` is `-kx*x`, and a model's scoped
#   `D(Chem.A, t)` is the mass-action tendency §7.4 generated for the sibling
#   reaction system — the shape issue #206 needed and could not express.
#
#   REFUSE — a structural `D` that resolves to NOTHING (over an observed, over a
#   parameter, or over a compound expression) is a rewrite-target that reached
#   evaluation, and a conforming runtime MUST report `unlowered_operator` rather
#   than invent a value for it, IN PARTICULAR NOT `0`.
#
# The two halves are gated together on purpose. Before this category all three
# Rust evaluators answered `D(anything) = 0` "for parity" with one another, so
# three shipped documents computed silent zeros; Python and this binding refused
# BOTH halves, so the bindings disagreed in opposite directions on one document.
# Julia's refusal half already conformed — `tree_walk/compile.jl` rejects any `D`
# reaching evaluation — and it is the RESOLUTION that step 3c adds.
#
# Outcome CLASSES are compared, not a numeric golden: a refusal has no actual to
# record, and each binding's diagnostic prose differs while the
# `unlowered_operator` code (§9.6.3 constraint 6) is the cross-binding contract.
# See tests/conformance/rhs_time_derivative/.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RTD_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "rhs_time_derivative")
const _RTD_MANIFEST = joinpath(_RTD_CAT_DIR, "manifest.json")

@testset "Conformance: rhs_time_derivative (manifest-driven)" begin
    @test isfile(_RTD_MANIFEST)
    manifest = JSON3.read(read(_RTD_MANIFEST, String))
    @test manifest.category == "rhs_time_derivative"
    @test !isempty(manifest.fixtures)

    # The manifest is the contract; a binding must not silently drop out of it.
    for b in ("julia", "python", "rust")
        @test b in manifest.bindings_required
    end
    # Every excluded binding must say WHY, so a GAP cannot masquerade as a
    # design decision.
    for (binding, reason) in pairs(manifest.scope_excluded)
        @test !isempty(strip(String(reason)))
    end
    # Both halves are present: dropping the refusal half would leave §4.2's
    # "in particular not `0`" ungated.
    outcomes = Set{String}()
    for fixture in manifest.fixtures, case in fixture.cases
        push!(outcomes, String(case.outcome))
    end
    @test outcomes == Set(["value", "refused"])

    jl = manifest.integrators.julia
    reltol = Float64(jl.reltol)
    abstol = Float64(jl.abstol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path = joinpath(_RTD_CAT_DIR, String(fixture.path))
            @test isfile(esm_path)

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=reltol, abstol=abstol)
            @test length(results) == length(fixture.cases)

            by_idx = Dict{Int,Any}()
            for r in results
                r.test_id == String(fixture.test_id) || continue
                by_idx[Int(r.assertion_idx)] = r
            end

            for case in fixture.cases
                idx = Int(case.assertion_idx)
                @test haskey(by_idx, idx)
                haskey(by_idx, idx) || continue
                r = by_idx[idx]
                @test r.variable == String(case.variable)
                @test r.passed == case.passed

                if String(case.outcome) == "value"
                    @test r.actual !== nothing
                    if r.actual !== nothing
                        want = Float64(case.expected)
                        @test isapprox(Float64(r.actual), want;
                                       rtol=1e-8, atol=1e-8)
                    end
                else
                    # A refusal carries NO number. This is the assertion that
                    # catches a binding inventing `0`.
                    @test r.actual === nothing
                    @test occursin(String(case.diagnostic), r.message)
                end
            end
        end
    end
end

@testset "rhs_time_derivative: the resolve half is not vacuous" begin
    # Guard against the RESOLVE half passing for the wrong reason: every
    # tendency assertion must be non-zero, so a binding still answering
    # `D(anything) = 0` cannot satisfy it.
    manifest = JSON3.read(read(_RTD_MANIFEST, String))
    fixture = only(f for f in manifest.fixtures
                   if String(f.id) == "tendency_resolution")
    seen = 0
    for case in fixture.cases
        String(case.variable) in ("dxdt", "dAdt") || continue
        seen += 1
        @test Float64(case.expected) != 0.0
    end
    @test seen >= 2
end
