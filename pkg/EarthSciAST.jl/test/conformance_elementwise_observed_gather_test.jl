# Conformance harness adapter — elementwise_observed_gather category.
#
# An ARRAY-shaped OBSERVED written ELEMENTWISE over another array
# (`f = 1 + cos(pi*zc)`, `zc` shaped `[lev]`) and consumed ONLY through an
# `index(f, j)` gather inside an `aggregate` body. The reference binding (Julia)
# runs the OFFICIAL `run_pde_tests` pathway over the committed fixtures and must
# reproduce the committed goldens (which that same pathway minted). Python and
# Rust gate the same goldens from their own runners.
#
# This is the conformance GATE for issue #175: before the fix, folding `f` into
# its readers turned the gather into `index(1 + cos(pi*zc), j)`, and the
# resolver's push-down branch tested only the IMMEDIATE operands of the
# elementwise combination for array-ness — `1` is a literal, `cos(pi*zc)` is
# neither a producer node nor a variable — so nothing was wrapped, the gather was
# dropped, and the array leaf `zc` reached `_compile` bare as
# `E_TREEWALK_UNBOUND_VARIABLE: zc`. Every assertion below therefore failed to
# even build. See tests/conformance/elementwise_observed_gather/.
#
# The category's second fixture is the CONTROL: the identical field written as an
# explicit `aggregate(k from lev; 1 + cos(pi*index(zc, k)))` gather, which never
# needed the push-down and passed before the fix too. The two fixtures share
# every assertion and every expected value, so this adapter additionally requires
# them to agree with EACH OTHER actual-for-actual — a divergence between the two
# spellings is the push-down and cannot be the physics.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _EOG_REPO_ROOT = TESTUTILS_REPO_ROOT
const _EOG_CAT_DIR   = joinpath(_EOG_REPO_ROOT, "tests", "conformance",
                                "elementwise_observed_gather")
const _EOG_MANIFEST  = joinpath(_EOG_CAT_DIR, "manifest.json")

@testset "Conformance: elementwise_observed_gather (manifest-driven)" begin
    @test isfile(_EOG_MANIFEST)
    manifest = JSON3.read(read(_EOG_MANIFEST, String))
    @test manifest.category == "elementwise_observed_gather"
    @test String(manifest.reference_binding) == "julia"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    # actual-by-assertion-index, per fixture, for the cross-spelling check below.
    actuals = Dict{String,Dict{Int,Float64}}()

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_EOG_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_EOG_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Gate each assertion against BOTH the golden actual (the
            # cross-binding anchor) and the fixture's own declared `expected`
            # (author intent), and require pass=true.
            by_idx = Dict(r.assertion_idx => r for r in results)
            mine = Dict{Int,Float64}()
            for g in golden.assertions
                gi = Int(g.assertion_idx)
                @test haskey(by_idx, gi)
                r = by_idx[gi]
                @test r.passed
                @test r.actual !== nothing
                @test isapprox(r.actual, Float64(g.actual); rtol=rtol, atol=atol)
                mine[gi] = Float64(r.actual)
            end
            actuals[id] = mine
        end
    end

    @testset "both spellings agree actual-for-actual" begin
        ew = get(actuals, "elementwise_gather", nothing)
        ex = get(actuals, "explicit_gather", nothing)
        @test ew !== nothing && ex !== nothing
        if ew !== nothing && ex !== nothing
            @test sort(collect(keys(ew))) == sort(collect(keys(ex)))
            for k in keys(ew)
                @test isapprox(ew[k], ex[k]; rtol=rtol, atol=atol)
            end
        end
    end
end
