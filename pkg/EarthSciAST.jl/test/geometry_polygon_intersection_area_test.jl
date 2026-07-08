# polygon_intersection_area — the FUSED clip+area scalar leaf (esm-spec §4.2 / §8.6.1).
#
# `polygon_intersection_area(a, b)` returns the SCALAR overlap area of two polygon
# vertex rings under a declared `manifold`, defined to equal
# `polygon_area(intersect_polygon(a, b))` at the same manifold — but with NO exposed
# clip ring / derived index set. It is the fused composition of the two existing
# constituent kernels: the `intersect_polygon` Sutherland–Hodgman clip and the
# `polygon_area` shoelace FAQ (`_polygon_area_via_faq`). Because it evaluates to an
# ordinary Float64 scalar, it drops into any expression — here an ODE RHS — with no
# ragged intermediate.
#
# The shared conformance fixture `polygon_intersection_area_planar.esm` overlaps two
# unit-aligned squares (src (0,0)-(2,0)-(2,2)-(0,2), tgt (1,1)-(3,1)-(3,3)-(1,3)) in
# the [1,2]×[1,2] box, so the planar overlap area is exactly 1.0. The model consumes
# it as `d(area_state)/dt = overlap_area` from a zero IC, so `area_state(1) = 1.0`.

using Test
using EarthSciAST
import OrdinaryDiffEqTsit5
# GeometryOps + GeoInterface trigger EarthSciASTGeometryOpsExt so the
# padded-ring pin (esm-spec §8.6.1) is exercised on the spherical clip too.
import GeometryOps
import GeoInterface

const _PIA = EarthSciAST
include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _PIA_REPO_ROOT = TESTUTILS_REPO_ROOT
const _PIA_VALID_GEOM = joinpath(_PIA_REPO_ROOT, "tests", "valid", "geometry")

# Two unit-aligned squares overlapping in the [1,2]×[1,2] box → overlap area 1.0.
const _PIA_SQUARE_A = [0.0 0.0; 2.0 0.0; 2.0 2.0; 0.0 2.0]
const _PIA_SQUARE_B = [1.0 1.0; 3.0 1.0; 3.0 3.0; 1.0 3.0]

@testset "polygon_intersection_area — fused clip+area scalar leaf (§8.6.1)" begin

    # --- the fused kernel reuses intersect_polygon + the polygon_area FAQ ---
    @testset "fused kernel equals polygon_area(intersect_polygon(...))" begin
        area = _PIA._polygon_intersection_area(_PIA_SQUARE_A, _PIA_SQUARE_B, "planar")
        @test isapprox(area, 1.0; atol=1e-12)
        # Definitionally equal to the unfused clip → shoelace-area composition.
        oracle = _PIA.polygon_area(
            _PIA.intersect_polygon(_PIA_SQUARE_A, _PIA_SQUARE_B, "planar"), "planar")
        @test isapprox(area, oracle; atol=1e-12)
        # A disjoint pair has zero overlap area (degenerate clip → 0.0).
        far = [5.0 5.0; 6.0 5.0; 6.0 6.0; 5.0 6.0]
        @test _PIA._polygon_intersection_area(_PIA_SQUARE_A, far, "planar") == 0.0
    end

    # --- padded (consecutive-duplicate) operand rings, esm-spec §8.6.1 ---
    # Mixed-valence meshes (MPAS pentagons in a hexagon-shaped [cells, NVERT, 2]
    # ring stack) pad each ring by repeating its final vertex. The op MUST accept
    # such rings and evaluate them as the DEDUPLICATED ring — dedup happens in
    # the operand coercion (_as_ring), before any backend kernel, because S2
    # (the Python/Rust spherical backend) rejects zero-length edges outright.
    @testset "padded rings evaluate as the deduplicated ring (§8.6.1)" begin
        pad(m, k) = vcat(m, repeat(m[end:end, :], k))
        # Squares padded 1× and 2×: planar overlap unchanged, exactly.
        a1, b2 = pad(_PIA_SQUARE_A, 1), pad(_PIA_SQUARE_B, 2)
        @test _PIA._polygon_intersection_area(a1, b2, "planar") ==
              _PIA._polygon_intersection_area(_PIA_SQUARE_A, _PIA_SQUARE_B, "planar")
        # Pentagon (the mixed-valence cell) padded to 6 and 7 slots against a
        # covering square: area equals the unpadded pentagon's, exactly.
        pent = vcat(([cosd(90 + 72k) sind(90 + 72k)] for k in 0:4)...)
        big = [-3.0 -3.0; 3.0 -3.0; 3.0 3.0; -3.0 3.0]
        area5 = _PIA._polygon_intersection_area(pent, big, "planar")
        @test isapprox(area5, 2.5 * sind(72.0); atol=1e-12)   # analytic pentagon area
        @test _PIA._polygon_intersection_area(pad(pent, 1), big, "planar") == area5
        @test _PIA._polygon_intersection_area(pad(pent, 2), big, "planar") == area5
        # Padding in the CLIP operand (same operand order as its unpadded
        # baseline — swapping subject/clip roles reorders the FP sums) and an
        # interior (non-trailing) duplicate.
        @test _PIA._polygon_intersection_area(big, pad(pent, 2), "planar") ==
              _PIA._polygon_intersection_area(big, pent, "planar")
        middup = [0.0 0.0; 2.0 0.0; 2.0 0.0; 2.0 2.0; 0.0 2.0]
        @test _PIA._polygon_intersection_area(middup, big, "planar") == 4.0
        # intersect_polygon's returned ring is in normal form (distinct verts).
        @test size(_PIA.intersect_polygon(pad(pent, 2), big, "planar"), 1) == 5
        # Spherical manifold (GeometryOps ext): padded == unpadded, exactly.
        sqs = [0.0 0.0; 10.0 0.0; 10.0 10.0; 0.0 10.0]
        bigs = [-20.0 -20.0; 30.0 -20.0; 30.0 30.0; -20.0 30.0]
        @test _PIA._polygon_intersection_area(pad(sqs, 2), bigs, "spherical") ==
              _PIA._polygon_intersection_area(sqs, bigs, "spherical")
        @test size(_PIA.intersect_polygon(pad(sqs, 1), bigs, "spherical"), 1) == 4
        # Fewer than 3 DISTINCT vertices after dedup is a degenerate operand.
        allpad = [1.5 1.5; 1.5 1.5; 1.5 1.5; 1.5 1.5]
        @test_throws _PIA.GeometryError _PIA.intersect_polygon(allpad, big, "planar")
        twodistinct = [0.0 0.0; 1.0 0.0; 1.0 0.0; 0.0 0.0]
        @test_throws _PIA.GeometryError _PIA.intersect_polygon(twodistinct, big, "planar")
    end

    # --- the padded-ring conformance fixture through build_evaluator + solve ---
    @testset "fixture: padded rings, area_state(1.0) == 1.0" begin
        path = joinpath(_PIA_VALID_GEOM, "polygon_intersection_area_padded_ring.esm")
        @test isfile(path)
        file = EarthSciAST.load(path)
        f!, u0, p, tspan, vmap =
            build_evaluator(file; model_name="PolygonIntersectionAreaPaddedRing")
        du = similar(u0)
        f!(du, u0, p, 0.0)
        # The fused leaf const-folds the PADDED rings to the deduplicated-ring
        # overlap: the [1.5,2.5]×[1.5,2.5] box, exactly 1.0.
        @test isapprox(du[vmap["area_state"]], 1.0; atol=1e-9)
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, tspan, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-10, abstol=1e-12)
        @test isapprox(sol.u[end][vmap["area_state"]], 1.0; atol=1e-9)
    end

    # --- the shared conformance fixture through build_evaluator + solve ---
    @testset "fixture: area_state(1.0) == 1.0 (build_evaluator → solve)" begin
        path = joinpath(_PIA_VALID_GEOM, "polygon_intersection_area_planar.esm")
        @test isfile(path)
        file = EarthSciAST.load(path)

        f!, u0, p, tspan, vmap =
            build_evaluator(file; model_name="PolygonIntersectionAreaPlanar")
        @test haskey(vmap, "area_state")
        @test u0[vmap["area_state"]] == 0.0        # ic(area_state) = 0.0
        @test tspan == (0.0, 1.0)

        # The fused leaf const-folds to the scalar overlap area: d(area_state)/dt =
        # overlap_area = polygon_intersection_area(src_poly, tgt_poly) = 1.0.
        du = similar(u0)
        f!(du, u0, p, 0.0)
        @test isapprox(du[vmap["area_state"]], 1.0; atol=1e-9)

        # Integrate to t = 1: area_state(1) = ∫₀¹ overlap_area dt = 1.0.
        prob = OrdinaryDiffEqTsit5.ODEProblem(f!, u0, tspan, p)
        sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
                                        reltol=1e-10, abstol=1e-12)
        @test isapprox(sol.u[end][vmap["area_state"]], 1.0; atol=1e-9)
    end
end
