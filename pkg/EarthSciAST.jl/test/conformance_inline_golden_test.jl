# Inline-test conformance categories (esm-spec §6.6) whose gate is "run the
# fixture through `run_inline_tests` and reproduce the committed golden".
#
# Julia is the reference binding for each: its `run_inline_tests` minted the
# goldens, and Python and Rust gate the same goldens from their own runners
# (tests/conformance/<category>/). `check_inline_golden` (testutils.jl) runs one
# category; a category with assertions of its own adds them below its row.
#
# * pde_inline_observed_rank2 — an assertion on a rank-2 array observed.
# * pde_inline_observed_param_rank2 — a rank-2 array observed whose expression
#   reads a model parameter, a load-time constant in the §6.6.5 scope.
# * pde_inline_observed_state_dependent — an array observed that moves with the
#   state (`g = 2*u + rate`), evaluated at the sampled state, beside the
#   state-free one the build materializes.
# * pde_inline_observed_indexed_lhs — array observeds defined by the indexed LHS
#   spelling `y[i] ~ f(…)` (esm-spec §6.3.1), one state-free and one
#   state-dependent; and the refusals of CONFORMANCE_SPEC §5.36.2.
# * pde_inline_reference_dimension_names — a `reference` whose free variables
#   are the asserted field's dimension names (esm-spec §6.6.5).
# * elementwise_observed_gather — an array observed written elementwise over
#   another array and read only through an `index(f, j)` gather; its control
#   fixture spells the same field as an explicit gather, and the two must agree
#   actual for actual.
# * pde_inline_array_overrides — inline array data on a shaped variable's
#   `default`, a test's `parameter_overrides` and `initial_conditions`
#   (esm-spec §6.6.2, §6.3, §11.4).
# * shaped_observed_scalar_broadcast — a shaped observed with a scalar
#   right-hand side fills every cell (esm-spec §4.3.4).
# * shaped_parameter_broadcast — a scalar on a shaped parameter (its `default`
#   or an override) applies to every element (esm-spec §6.3, §6.6.2).

using Test
using JSON3
using EarthSciAST
import SciMLBase
import SciMLBase: solve
import OrdinaryDiffEqTsit5

include("testutils.jl")

const TSIT5 = OrdinaryDiffEqTsit5.Tsit5()

# A fixture's declared assertions name the same variable and expected value as
# the run reports for them. The tolerance argument is unused; it is named
# because Julia 1.10 rejects `_` before keyword arguments.
function declared_match(fixture, by_key, tol; reduce::Bool = false)
    for decl in fixture.assertions
        r = by_key[Int(decl.assertion_idx)]
        @test r.variable == String(decl.variable)
        @test r.expected == Float64(decl.expected)
        reduce && @test String(r.reduce) == String(decl.reduce)
    end
    return nothing
end

@testset "Conformance: pde_inline_observed_rank2" begin
    check_inline_golden("pde_inline_observed_rank2", TSIT5)
end

@testset "Conformance: pde_inline_observed_param_rank2" begin
    check_inline_golden("pde_inline_observed_param_rank2", TSIT5)
end

@testset "Conformance: pde_inline_observed_state_dependent" begin
    check_inline_golden(
        "pde_inline_observed_state_dependent", TSIT5; extra = declared_match
    )
end

@testset "Conformance: pde_inline_observed_indexed_lhs" begin
    check_inline_golden("pde_inline_observed_indexed_lhs", TSIT5; extra = declared_match)

    # CONFORMANCE_SPEC §5.36.2: a document whose indexed definition cannot be
    # evaluated reports, per assertion, a failure naming the diagnostic and
    # the variable, with no actual.
    dir, manifest = conformance_manifest("pde_inline_observed_indexed_lhs")
    @test !isempty(manifest.refusals)
    for ref in manifest.refusals
        @testset "refusal: $(ref.id)" begin
            results = run_inline_tests(
                joinpath(dir, String(ref.path));
                model_name = String(ref.model), alg = TSIT5,
                reltol = 1.0e-12, abstol = 1.0e-14, compiler = :native
            )
            @test length(results) == Int(ref.assertion_count)
            for r in results
                @test !r.passed
                @test r.actual === nothing
                @test occursin(String(ref.diagnostic), r.message)
                @test occursin(String(ref.names_variable), r.message)
            end
        end
    end
end

@testset "Conformance: pde_inline_reference_dimension_names" begin
    check_inline_golden(
        "pde_inline_reference_dimension_names", TSIT5; solver_from_manifest = true,
        extra = (fx, by_key, tol) -> declared_match(fx, by_key, tol; reduce = true)
    )
end

@testset "Conformance: elementwise_observed_gather" begin
    _, manifest = conformance_manifest("elementwise_observed_gather")
    @test String(manifest.reference_binding) == "julia"
    runs = check_inline_golden("elementwise_observed_gather", TSIT5)
    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)
    @testset "both spellings agree actual-for-actual" begin
        ew = get(runs, "elementwise_gather", nothing)
        ex = get(runs, "explicit_gather", nothing)
        @test ew !== nothing && ex !== nothing
        if ew !== nothing && ex !== nothing
            @test sort(collect(keys(ew))) == sort(collect(keys(ex)))
            for k in keys(ew)
                @test isapprox(ew[k].actual, ex[k].actual; rtol = rtol, atol = atol)
            end
        end
    end
end

@testset "Conformance: pde_inline_array_overrides" begin
    check_inline_golden("pde_inline_array_overrides", TSIT5; by_test = true)

    dir, _ = conformance_manifest("pde_inline_array_overrides")
    # The two contracts the category gates, on the typed build path: the
    # row-major nesting of §6.6.2, and the load-time shape check a mismatch
    # trips.
    @testset "row-major nesting" begin
        # Axis 1 of `shape` is the OUTER JSON array, so `data[i][j]` is the
        # element at `(i, j)`. The 2x3 slab has unequal extents and pairwise-
        # distinct values, so a column-major read disagrees on every
        # off-diagonal cell instead of coincidentally agreeing.
        esm_path = joinpath(dir, "fixtures", "slab_array_overrides_rank2.esm")
        raw = JSON3.read(read(esm_path, String), Dict{String, Any})
        file = EarthSciAST.coerce_esm_file(raw)
        declared = file.models["Slab"].variables["kprof"].default
        @test declared isa AbstractArray
        @test size(declared) == (2, 3)
        sim = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0)), TSIT5; saveat = [0.0])
        @test SciMLBase.successful_retcode(sim)
        for i in 1:2, j in 1:3
            @test sim[Symbol("Slab.a[$(i),$(j)]")][1] == declared[i, j]
        end
    end
    @testset "shape mismatch is a load-time error" begin
        # A 2-element column for a `lev`-shaped (=4) parameter is refused,
        # never truncated or broadcast.
        col_path = joinpath(dir, "fixtures", "column_array_overrides.esm")
        @test_throws EarthSciAST.TreeWalkError EarthSciAST.esm_problem(
            col_path, (0.0, 1.0); p = Dict("theta0" => [1.0, 2.0])
        )
    end
end

@testset "Conformance: shaped_observed_scalar_broadcast" begin
    check_inline_golden(
        "shaped_observed_scalar_broadcast", TSIT5;
        extra = function (fixture, by_key, (rtol, atol))
            for a in fixture.assertions
                r = by_key[Int(a.assertion_idx)]
                @test String(r.variable) == String(a.variable)
                @test isapprox(r.actual, Float64(a.expected); rtol = rtol, atol = atol)
            end
        end
    )
end

@testset "Conformance: shaped_parameter_broadcast" begin
    check_inline_golden("shaped_parameter_broadcast", TSIT5; by_test = true)
end
