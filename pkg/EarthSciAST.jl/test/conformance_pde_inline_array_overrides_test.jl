# Conformance harness adapter — pde_inline_array_overrides category.
#
# esm-spec §6.6.2 "Shaped values" + §6.3 + §11.4: a SHAPED variable carries its
# whole field as INLINE ARRAY DATA — a row-major nested JSON array on its
# `default`, in a test's `parameter_overrides`, or in a test's
# `initial_conditions` — and an `ic` may be seeded from a STATE-FREE ARRAY
# OBSERVED, which is resolvable in the §6.6.5 build-time evaluation scope. The
# reference binding (Julia) runs the OFFICIAL `run_pde_tests` pathway over the
# committed fixtures and must reproduce the committed goldens (which that same
# pathway minted). The manifest declares julia/python/rust as bindings_required.
#
# This is the conformance GATE for the shaped-input fix. Before it, all three
# value positions were `number`-only in `esm-schema.json` and a `const`-gather
# `ic` RHS was rejected at build, so a §6.6 inline test could not supply a
# SHAPED input at all: the only escape was a test-injected rewrite-rule library
# (§9.7.10) lowering a rewrite-target op to an inline `const` column — one
# GENERATED `.esm` per test — which is what a column-physics component replaying
# a Fortran kernel dump had to do for every regime, its inputs being columns
# (θ, q_v, u, v, p, dz, K profiles). Each fixture here is ONE shared component
# whose regimes are ordinary tests of the same document.
# See tests/conformance/pde_inline_array_overrides/.

using Test
using JSON3
using EarthSciAST
import SciMLBase
import SciMLBase: solve
import OrdinaryDiffEqTsit5

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _AOV_REPO_ROOT = TESTUTILS_REPO_ROOT
const _AOV_CAT_DIR   = joinpath(_AOV_REPO_ROOT, "tests", "conformance",
                                "pde_inline_array_overrides")
const _AOV_MANIFEST  = joinpath(_AOV_CAT_DIR, "manifest.json")

@testset "Conformance: pde_inline_array_overrides (manifest-driven)" begin
    @test isfile(_AOV_MANIFEST)
    manifest = JSON3.read(read(_AOV_MANIFEST, String))
    @test manifest.category == "pde_inline_array_overrides"
    @test !isempty(manifest.fixtures)
    @test "julia" in manifest.bindings_required
    @test "python" in manifest.bindings_required
    @test "rust" in manifest.bindings_required

    rtol = Float64(manifest.tolerances.assertion_rtol)
    atol = Float64(manifest.tolerances.assertion_atol)

    for fixture in manifest.fixtures
        id = String(fixture.id)
        @testset "$(id)" begin
            esm_path    = joinpath(_AOV_CAT_DIR, String(fixture.path))
            golden_path = joinpath(_AOV_CAT_DIR, String(fixture.golden))
            @test isfile(esm_path)
            @test isfile(golden_path)

            golden = JSON3.read(read(golden_path, String))
            @test String(golden.reference_binding) == "julia"

            results = run_pde_tests(esm_path; model_name=String(fixture.model),
                                    alg=OrdinaryDiffEqTsit5.Tsit5(),
                                    reltol=1e-12, abstol=1e-14)
            @test length(results) == length(golden.assertions)

            # Index by (test_id, assertion_idx) — each fixture carries several
            # tests of ONE model, distinguished only by their inline array data
            # — and gate each against BOTH the golden actual (cross-binding
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

# Direct unit coverage of the two contracts the category gates, on the TYPED
# build path: the ROW-MAJOR nesting order of §6.6.2, and the load-time shape
# check a mismatch must trip.
@testset "inline array data (esm-spec §6.6.2)" begin
    esm_path = joinpath(_AOV_CAT_DIR, "fixtures", "slab_array_overrides_rank2.esm")

    @testset "row-major nesting" begin
        # Axis 1 of `shape` is the OUTER JSON array, so `data[i][j]` is the
        # element at `(i, j)`. The 2x3 slab has unequal extents and pairwise-
        # distinct values, so a column-major read disagrees on every
        # off-diagonal cell instead of coincidentally agreeing.
        raw = JSON3.read(read(esm_path, String), Dict{String,Any})
        file = EarthSciAST.coerce_esm_file(raw)
        declared = file.models["Slab"].variables["kprof"].default
        @test declared isa AbstractArray
        @test size(declared) == (2, 3)

        sim = solve(EarthSciAST.esm_problem(esm_path, (0.0, 1.0)),
                    OrdinaryDiffEqTsit5.Tsit5(); saveat=[0.0])
        @test SciMLBase.successful_retcode(sim)
        for i in 1:2, j in 1:3
            @test sim[Symbol("Slab.a[$(i),$(j)]")][1] == declared[i, j]
        end
    end

    @testset "shape mismatch is a load-time error" begin
        # A 2-element column for a `lev`-shaped (=4) parameter must be REJECTED,
        # never silently truncated or broadcast.
        col_path = joinpath(_AOV_CAT_DIR, "fixtures", "column_array_overrides.esm")
        @test_throws EarthSciAST.TreeWalkError EarthSciAST.esm_problem(
            col_path, (0.0, 1.0); p=Dict("theta0" => [1.0, 2.0]))
    end
end
