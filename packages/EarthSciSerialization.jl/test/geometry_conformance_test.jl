# Conservative-regridding geometry kernel — Julia evaluator conformance.
#
# Bead ess-my4.4.3 (the Julia intersect_polygon kernel). RFC
# semiring-faq-unified-ir §8.1 / Appendix B.2; CONFORMANCE_SPEC.md §5.8. Mirrors
# the Python sibling ess-my4.4.4 so the two bindings agree on the SAME shared
# fixtures under the B.5 / §5.8.2 tolerance gate.
#
# Three layers are exercised:
#
#  1. intersect_polygon leaf — the planar Sutherland–Hodgman clip (dependency-free)
#     and the spherical clip via GeometryOps (Spherical() / ConvexConvex…). The
#     overlap of two unit-aligned squares is the unit square (area 1.0).
#  2. polygon_area as an ordinary sum_product FAQ over the derived clip-ring index
#     set — the shared planar fixture's actual AST evaluated through
#     build_evaluator, reusing the M1 aggregate machinery: with the tracer IC = 1,
#     d(tracer)/dt = −area·tracer = −1.0 confirms the FAQ area is exactly 1.0.
#  3. Spherical area (closed-form Van Oosterom–Strackee excess — needs no backend)
#     against known values (octant = π/2) and cross-checked against GeometryOps'
#     own Girard area for the same clipped ring; plus the B.5 tolerance gate.

using Test
using EarthSciSerialization
# Loading GeometryOps + GeoInterface triggers EarthSciSerializationGeometryOpsExt,
# which supplies the spherical / geodesic clip. The planar path and the area FAQ
# need no backend.
import GeometryOps as GO
import GeoInterface as GI

const ESS = EarthSciSerialization
const _GEOM_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const _VALID_GEOM = joinpath(_GEOM_REPO_ROOT, "tests", "valid", "geometry")

# Two unit-aligned squares overlapping in the [1,2]×[1,2] box → overlap area 1.0.
const _SQUARE_A = [0.0 0.0; 2.0 0.0; 2.0 2.0; 0.0 2.0]
const _SQUARE_B = [1.0 1.0; 3.0 1.0; 3.0 3.0; 1.0 3.0]

# Unordered vertex set of a ring (rounded), so a clip's rotation/orientation does
# not matter for the comparison.
_vertset(ring) = Set((round(ring[i, 1]; digits=9), round(ring[i, 2]; digits=9))
                     for i in 1:size(ring, 1))

@testset "M4 geometry kernel — intersect_polygon + polygon_area (ess-my4.4.3)" begin

    @testset "shared geometry fixtures load" begin
        @test isdir(_VALID_GEOM)
        for f in readdir(_VALID_GEOM)
            endswith(f, ".esm") || continue
            @test (EarthSciSerialization.load(joinpath(_VALID_GEOM, f)); true)
        end
    end

    # --- intersect_polygon leaf — planar clip ---
    @testset "planar clip of overlapping squares" begin
        ring = ESS.intersect_polygon(_SQUARE_A, _SQUARE_B, "planar")
        @test _vertset(ring) == Set([(1.0, 1.0), (2.0, 1.0), (2.0, 2.0), (1.0, 2.0)])
        @test isapprox(ESS.polygon_area(ring, "planar"), 1.0; atol=1e-12)
    end

    @testset "planar clip of disjoint cells is empty" begin
        far = [5.0 5.0; 6.0 5.0; 6.0 6.0; 5.0 6.0]
        ring = ESS.intersect_polygon(_SQUARE_A, far, "planar")
        @test size(ring) == (0, 2)
        @test ESS.polygon_area(ring, "planar") == 0.0
    end

    @testset "planar clip is orientation-robust" begin
        # A clockwise operand still yields the correct (positive) overlap area.
        a_cw = _SQUARE_A[end:-1:1, :]
        b_cw = _SQUARE_B[end:-1:1, :]
        ring = ESS.intersect_polygon(a_cw, b_cw, "planar")
        @test isapprox(ESS.polygon_area(ring, "planar"), 1.0; atol=1e-12)
    end

    @testset "intersect_polygon requires a manifold (parse)" begin
        bad = Dict("op" => "intersect_polygon", "args" => ["a", "b"])
        @test_throws EarthSciSerialization.ParseError parse_expression(bad)
    end

    @testset "unknown manifold is rejected" begin
        @test_throws ESS.GeometryError ESS.intersect_polygon(_SQUARE_A, _SQUARE_B, "flat")
    end

    # --- polygon_area as a sum_product FAQ over the derived clip ring ---
    @testset "planar fixture clip + area FAQ evaluate to 1.0 (build_evaluator)" begin
        path = joinpath(_VALID_GEOM, "intersect_polygon_planar_area.esm")
        @test isfile(path)
        file = EarthSciSerialization.load(path)
        # The clip runs at setup: src_poly / tgt_poly are supplied as const_arrays
        # (RFC App. B.1). tracer IC = 1 so d(tracer)/dt = −area·tracer = −area.
        f!, u0, p, _, vmap = build_evaluator(
            file; model_name="PolygonClipAreaPlanar",
            initial_conditions=Dict("tracer" => 1.0),
            const_arrays=Dict("src_poly" => _SQUARE_A, "tgt_poly" => _SQUARE_B))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        # area = polygon_area(clip) = 1.0  ⇒  d(tracer)/dt = −1.0·1.0 = −1.0.
        @test isapprox(du[vmap["tracer"]], -1.0; atol=1e-12)
    end

    @testset "derived clip-ring index set requires materialization" begin
        # A polygon_area FAQ over a derived index set whose producer was not
        # evaluated must fail clearly (no silent empty reduction).
        bad = Dict(
            "esm" => "0.6.0",
            "metadata" => Dict("name" => "derived_unmaterialized"),
            "models" => Dict("M" => Dict(
                "index_sets" => Dict(
                    "coord" => Dict("kind" => "interval", "size" => 2),
                    "ghost_ring" => Dict("kind" => "derived", "from_faq" => "missing_clip"),
                ),
                "variables" => Dict(
                    "y" => Dict("type" => "state", "shape" => []),
                ),
                "equations" => [Dict(
                    "lhs" => Dict("op" => "D", "args" => ["y"], "wrt" => "t"),
                    "rhs" => Dict(
                        "op" => "aggregate", "semiring" => "sum_product",
                        "output_idx" => [], "args" => [],
                        "ranges" => Dict("v" => Dict("from" => "ghost_ring")),
                        "expr" => 1.0,
                    ),
                )],
            )),
        )
        @test_throws EarthSciSerialization.TreeWalkError build_evaluator(bad; model_name="M")
    end

    # --- spherical / geodesic area (closed-form excess, no backend) ---
    @testset "spherical area of an octant is π/2 (unit sphere)" begin
        octant = [0.0 0.0; 90.0 0.0; 0.0 90.0]
        @test isapprox(ESS.polygon_area(octant, "spherical"), π / 2; atol=1e-12)
    end

    @testset "spherical area ≈ planar area for a tiny cell" begin
        cell = [0.0 0.0; 1e-3 0.0; 1e-3 1e-3; 0.0 1e-3]
        sph = ESS.polygon_area(cell, "spherical")
        planar_rad2 = ESS.polygon_area(cell, "planar") * deg2rad(1.0)^2
        @test isapprox(sph, planar_rad2; rtol=1e-3)
    end

    @testset "geodesic reuses the spherical (great-circle) area" begin
        octant = [0.0 0.0; 90.0 0.0; 0.0 90.0]
        @test ESS.polygon_area(octant, "geodesic") == ESS.polygon_area(octant, "spherical")
    end

    # --- spherical polygon_area as a sum_product FAQ over the clip ring ---
    # The polygon_area FAQ routes the area through the generic aggregate machinery
    # (_polygon_area_via_faq → _resolve_indices → evaluate_expr); the imperative
    # polygon_area / _spherical_signed_area loops are now only the cross-check
    # oracle. The spherical sibling of the planar shoelace FAQ (ess-d4g.1).
    @testset "spherical area FAQ (Van Oosterom–Strackee fan) evaluates octant to π/2" begin
        octant = [0.0 0.0; 90.0 0.0; 0.0 90.0]
        faq = ESS._polygon_area_via_faq(ESS.close_ring(octant), "spherical")
        @test isapprox(faq, π / 2; atol=1e-12)
    end

    @testset "area FAQ matches the imperative oracle (planar + spherical + geodesic)" begin
        # A general (non-rectangular, non-degenerate) ring exercises every fan term.
        ring = [10.0 20.0; 30.0 22.0; 28.0 40.0; 8.0 38.0]
        closed = ESS.close_ring(ring)
        for manifold in ("planar", "spherical", "geodesic")
            faq = ESS._polygon_area_via_faq(closed, manifold)
            oracle = ESS.polygon_area(ring, manifold)
            @test isapprox(faq, oracle; rtol=1e-12, atol=1e-14)
        end
    end

    @testset "spherical clip area: FAQ over the clipped ring matches the oracle" begin
        # With GeometryOps the spherical clip of two squares is the [1,2]² box,
        # whose spherical-excess area the FAQ path (_polygon_area_via_faq) and the
        # imperative polygon_area oracle agree on to the great-circle tolerance.
        if ESS._spherical_clip_available()
            clipped = ESS.intersect_polygon(_SQUARE_A, _SQUARE_B, "spherical")
            faq = ESS._polygon_area_via_faq(ESS.close_ring(clipped), "spherical")
            @test ESS.area_tolerance_ok(faq, ESS.polygon_area(clipped, "spherical"); rtol=1e-9)
        else
            @test_skip "GeometryOps spherical clip extension not loaded"
        end
    end

    # --- polar-edge densification — great-circle-edge accuracy (ess-my4.4.9) ---
    # Exact area of a lon-lat cell on the unit sphere (small-circle parallel
    # edges): A = Δλ·(sinφ₂ − sinφ₁). The great-circle-edge model (the spherical
    # clip and the spherical area) mis-models the parallels, so a coarse polar
    # cell carries a real area error (RFC §B.4); densifying the parallel edges
    # into short great-circle segments drives it toward zero.
    _true_cell_area(lo1, lo2, la1, la2) = deg2rad(lo2 - lo1) * (sind(la2) - sind(la1))

    @testset "densification reduces coarse polar-cell area error (B.4)" begin
        cell = [0.0 60.0; 30.0 60.0; 30.0 80.0; 0.0 80.0]  # 30°-wide high-latitude cell
        a_true = _true_cell_area(0.0, 30.0, 60.0, 80.0)
        a_coarse = ESS.polygon_area(cell, "spherical")
        err_coarse = abs(a_coarse - a_true) / a_true
        # The undensified great-circle cell is off by a few percent (≈3.6% here —
        # the ~4% the RFC quotes for a 30° polar cell).
        @test err_coarse > 0.02
        dense = ESS.densify_parallel_edges(cell, 1.0)  # ≤1° segments
        @test size(dense, 1) > size(cell, 1)           # vertices were inserted
        a_dense = ESS.polygon_area(dense, "spherical")
        err_dense = abs(a_dense - a_true) / a_true
        @test err_dense < err_coarse                   # densification reduces the error
        @test err_dense < 1e-3                          # and converges to the true area
        # Monotone: finer densification ⇒ smaller error.
        err_5 = abs(ESS.polygon_area(ESS.densify_parallel_edges(cell, 5.0), "spherical") - a_true) / a_true
        @test err_dense < err_5 < err_coarse
    end

    @testset "densification only touches parallel edges and is opt-in" begin
        # Two meridian edges (constant lon) + two 1°-wide parallel edges.
        quad = [0.0 0.0; 0.0 10.0; 1.0 10.0; 1.0 0.0]
        dense = ESS.densify_parallel_edges(quad, 0.5)
        # Only the two parallels split (1° > 0.5° ⇒ one interior point each); the
        # two 10° meridians are left whole — a meridian is already a great circle.
        @test size(dense, 1) == 4 + 2
        # A cell already finer than the segment cap is unchanged.
        @test size(ESS.densify_parallel_edges(quad, 5.0), 1) == 4
        # Off-by-default opt-in: a non-positive cap is rejected.
        @test_throws ESS.GeometryError ESS.densify_parallel_edges(quad, 0.0)
        # Inserted vertices lie exactly on the parallel (constant latitude).
        cell = [0.0 70.0; 40.0 70.0; 40.0 71.0; 0.0 71.0]
        d2 = ESS.densify_parallel_edges(cell, 10.0)
        @test Set(round(d2[i, 2]; digits=9) for i in 1:size(d2, 1)) == Set([70.0, 71.0])
    end

    # --- spherical clip via GeometryOps + Girard cross-check ---
    @testset "spherical clip via GeometryOps + Girard cross-check" begin
        ring = ESS.intersect_polygon(_SQUARE_A, _SQUARE_B, "spherical")
        @test size(ring, 1) >= 3
        # The overlap is the ~unit box, slightly bowed by the great-circle edges.
        @test isapprox(ESS.polygon_area(ring, "planar"), 1.0; atol=1e-3)
        # The closed-form spherical excess (unit sphere) must agree with
        # GeometryOps' own Girard area of the SAME ring (also unit sphere) — both
        # use the great-circle-edge model (B.5 / §5.8.2 S2-vs-GeometryOps band).
        a_excess = ESS.polygon_area(ring, "spherical")
        to_unit = GO.UnitSphereFromGeographic()
        pts = [to_unit((ring[i, 1], ring[i, 2])) for i in 1:size(ring, 1)]
        push!(pts, pts[1])
        gi = GI.Polygon([GI.LinearRing(pts)])
        a_go = GO.area(GO.Spherical(radius=1.0), gi)
        @test ESS.area_tolerance_ok(a_excess, a_go; rtol=1e-9)
    end

    # --- B.5 / §5.8.2 area-tolerance gate ---
    @testset "area-tolerance gate" begin
        @test ESS.area_tolerance_ok(1.0, 1.0; rtol=1e-12)
        # "present-but-tiny" and "absent" both pass (sub-sliver floor).
        @test ESS.area_tolerance_ok(1e-20, 0.0; rtol=1e-12)
        @test ESS.area_tolerance_ok(0.0, 1e-20; rtol=1e-12)
        @test !ESS.area_tolerance_ok(1.0, 2.0; rtol=1e-9)
        # A 1e-6 relative error passes at rtol 1e-5 but fails at rtol 1e-7.
        @test ESS.area_tolerance_ok(1.0 + 1e-6, 1.0; rtol=1e-5)
        @test !ESS.area_tolerance_ok(1.0 + 1e-6, 1.0; rtol=1e-7)
    end

    # --- manifold / id parse + serialize round-trip ---
    @testset "manifold + id survive the typed round-trip" begin
        path = joinpath(_VALID_GEOM, "intersect_polygon_clip_area.esm")
        file = EarthSciSerialization.load(path)
        clip_expr = file.models["PolygonClipArea"].variables["clip"].expression
        @test clip_expr isa OpExpr
        @test clip_expr.op == "intersect_polygon"
        @test clip_expr.manifold == "spherical"
        @test clip_expr.id == "overlap_clip"
        d = EarthSciSerialization.serialize_expression(clip_expr)
        @test d["manifold"] == "spherical"
        @test d["id"] == "overlap_clip"
        # A non-geometry node carries neither key (byte-identical round-trip).
        plain = EarthSciSerialization.serialize_expression(OpExpr("+", [VarExpr("a"), NumExpr(1.0)]))
        @test !haskey(plain, "manifold")
        @test !haskey(plain, "id")
    end
end
