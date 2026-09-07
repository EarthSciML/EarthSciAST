# Conformance harness adapter — pde_inline_observed_indexed_lhs category.
#
# esm-spec §6.3.1 admits TWO LHS spellings for the equation that DEFINES an
# unknown: bare (`y ~ f(…)`) and indexed (`y[i] ~ f(…)`, "which defines the whole
# array `y`"). Neither is restricted by rank — the defining form is read through
# the LHS's BASE NAME, so "an arrayed definition is observed exactly as its
# scalar counterpart is".
#
# This binding's tree-walk build classified equations by the SYNTACTIC
# `lhs isa VarExpr`, so an ARRAY-shaped observed written the indexed way matched
# no owner bucket (not the WS4 fold, not `_collect_array_inline_vars`, not the
# bare-alias path, not clip-ring discovery) and was refused outright in
# `_partition_variables` with `E_TREEWALK_UNSUPPORTED_SHAPE` — on a document
# Rust and Python both ran (issue #232). `_normalize_indexed_observed_lhs`
# rewrites the spelling into the bare one upstream of every classifier.
#
# Both array observeds of the fixture use the indexed spelling: `wf` is
# STATE-FREE and `ws` is STATE-DEPENDENT, the two classes a binding routes
# differently, so passing one path only does not pass this category. Julia is the
# reference binding: this run must reproduce the committed golden actuals (which
# this same pathway minted). See tests/conformance/pde_inline_observed_indexed_lhs/.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _OIL_CAT_DIR  = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "pde_inline_observed_indexed_lhs")
const _OIL_MANIFEST = joinpath(_OIL_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_observed_indexed_lhs (manifest-driven)" begin
    @test isfile(_OIL_MANIFEST)
    manifest = JSON3.read(read(_OIL_MANIFEST, String))
    @test manifest.category == "pde_inline_observed_indexed_lhs"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_OIL_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_OIL_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index by assertion_idx and gate each against BOTH the golden
            # actual (cross-binding anchor) and the fixture's own declared
            # `expected` (author intent), and require pass=true.
            by_idx = Dict(r.assertion_idx => r for r in results)
            for g in golden.assertions
                gi = Int(g.assertion_idx)
                @test haskey(by_idx, gi)
                r = by_idx[gi]
                @test r.variable == String(g.variable)
                @test r.passed
                @test r.actual !== nothing
                @test isapprox(r.actual, Float64(g.actual); rtol=rtol, atol=atol)
            end
            for decl in fixture.assertions
                r = by_idx[Int(decl.assertion_idx)]
                @test r.variable == String(decl.variable)
                @test r.expected == Float64(decl.expected)
            end
        end
    end
end
