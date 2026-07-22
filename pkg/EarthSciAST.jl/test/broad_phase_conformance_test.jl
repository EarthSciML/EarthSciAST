# Planar spatial-index broad phase — conformance (projection-pushdown Phase 3a).
#
# The primitive (src/broad_phase.jl core + ext/EarthSciASTGeometryOpsExt.jl fast
# path) returns a CONSERVATIVE SUPERSET of the (query × cell) index pairs whose 2D
# envelopes intersect. Two layers with a reference oracle:
#
#   CORE  broad_phase_candidates(query_envs, cell_envs; eps)  — brute force O(n·m)
#   FAST  broad_phase_candidates(query_envs, build_spatial_index(cell_envs); eps)
#         — SortTileRecursiveTree.STRtree via GeometryOps' SpatialTreeInterface
#           dual-tree traversal (the ConservativeRegridding.jl machinery).
#
# Asserted here, WITHOUT network / S3, RNG always seeded:
#   (a) FAST == BRUTE-FORCE on a grid, seeded-random, touching/degenerate, and
#       disjoint fixtures.
#   (b) CONSERVATIVENESS: an independent O(n·m) exact interior-overlap oracle over
#       random rectangles is a SUBSET of the candidate set (and touching pairs make
#       it a proper superset). A rotated-quad fixture repeats the check against the
#       package's planar clip as narrow-phase truth (AABB ⊋ polygon).
#   (c) eps MONOTONICITY: candidates(eps=δ) ⊇ candidates(eps=0).
#   (d) a small HAND-CHECKED example with known expected pairs (edge/corner touch).

using Test
using EarthSciAST
using Random
# Trigger EarthSciASTGeometryOpsExt (needs all four triggers): the fast STRtree
# broad_phase_candidates + build_spatial_index. Importing GeometryOps already
# loads Extents + SortTileRecursiveTree transitively; import them explicitly so
# the extension trigger is satisfied even standalone.
import GeometryOps
import GeoInterface
import SortTileRecursiveTree
import Extents

const ESS = EarthSciAST

# ---- envelope + oracle helpers (all pure, independent of the broad phase) ----

# Envelope (xmin, ymin, xmax, ymax) from rectangle bounds x∈[x0,x1], y∈[y0,y1].
_env(x0, x1, y0, y1) = (Float64(x0), Float64(y0), Float64(x1), Float64(y1))

# Independent EXACT interior (positive-area) overlap of two axis-aligned envelopes
# — STRICT inequalities, so edge/corner-touching pairs are NOT "true overlaps".
function _interior_overlap(a::NTuple{4,Float64}, b::NTuple{4,Float64})
    axmin, aymin, axmax, aymax = a
    bxmin, bymin, bxmax, bymax = b
    return max(axmin, bxmin) < min(axmax, bxmax) && max(aymin, bymin) < min(aymax, bymax)
end

function _true_interior_overlaps(qs, cs)
    out = Tuple{Int,Int}[]
    for qi in 1:length(qs), cj in 1:length(cs)
        _interior_overlap(qs[qi], cs[cj]) && push!(out, (qi, cj))
    end
    return sort!(out)
end

# BRUTE (core) and FAST (ext) candidate vectors for the same inputs and eps.
function _brute_and_fast(qs, cs; eps=0.0)
    brute = ESS.broad_phase_candidates(qs, cs; eps=eps)
    idx = ESS.build_spatial_index(cs; eps=eps)
    fast = ESS.broad_phase_candidates(qs, idx)   # idx carries eps
    return brute, fast
end

# AABB envelope of an n×2 vertex ring (matches broad-phase (xmin,ymin,xmax,ymax)).
function _ring_env(ring::AbstractMatrix)
    xmin = minimum(@view ring[:, 1]); xmax = maximum(@view ring[:, 1])
    ymin = minimum(@view ring[:, 2]); ymax = maximum(@view ring[:, 2])
    return (xmin, ymin, xmax, ymax)
end

# Rotate an n×2 ring about its centroid by θ (to make AABB ⊋ polygon).
function _rotate(ring::AbstractMatrix, θ)
    cx = sum(@view ring[:, 1]) / size(ring, 1)
    cy = sum(@view ring[:, 2]) / size(ring, 1)
    c, s = cos(θ), sin(θ)
    out = similar(ring, Float64)
    for i in 1:size(ring, 1)
        dx = ring[i, 1] - cx; dy = ring[i, 2] - cy
        out[i, 1] = cx + c * dx - s * dy
        out[i, 2] = cy + s * dx + c * dy
    end
    return out
end

_quad(x0, x1, y0, y1) = Float64[x0 y0; x1 y0; x1 y1; x0 y1]

@testset "Planar broad-phase candidate primitive (Phase 3a)" begin

    # The fast STRtree path only exists when the GeometryOps extension is loaded.
    _EXT = Base.get_extension(EarthSciAST, :EarthSciASTGeometryOpsExt)
    @testset "extension + fast path available" begin
        @test _EXT !== nothing
        @test hasmethod(ESS.build_spatial_index, Tuple{Vector{NTuple{4,Float64}}})
    end

    # ---------------------------------------------------------------------- #
    # (d) HAND-CHECKED example — known expected pairs, incl. edge/corner touch.
    # ---------------------------------------------------------------------- #
    @testset "(d) hand-checked example" begin
        qs = [_env(0, 1, 0, 1), _env(2, 3, 2, 3)]
        cs = [_env(0.5, 1.5, 0.5, 1.5),   # c1 overlaps q1 (interior)
              _env(1, 2, 1, 2),           # c2 corner-touches q1 at (1,1) and q2 at (2,2)
              _env(2.5, 3.5, 2.5, 3.5),   # c3 overlaps q2 (interior)
              _env(10, 11, 10, 11)]       # c4 disjoint from all
        expected = [(1, 1), (1, 2), (2, 2), (2, 3)]
        brute = ESS.broad_phase_candidates(qs, cs)
        @test brute == expected
        idx = ESS.build_spatial_index(cs)
        @test ESS.broad_phase_candidates(qs, idx) == expected
        # the two corner-touch pairs are NOT interior overlaps → broad phase is a
        # proper (conservative) superset of the exact interior-overlap oracle.
        @test _true_interior_overlaps(qs, cs) == [(1, 1), (2, 3)]
        @test issubset(Set(_true_interior_overlaps(qs, cs)), Set(brute))
    end

    # ---------------------------------------------------------------------- #
    # (a) FAST == BRUTE-FORCE across fixtures.
    # ---------------------------------------------------------------------- #
    @testset "(a) fast == brute-force" begin
        @testset "grid of rectangles" begin
            # 6×6 unit-cell grid of cells (36 > nodecapacity ⇒ real tree depth),
            # queries a 5×5 grid shifted by (0.5, 0.5) so overlaps are fractional.
            cs = [_env(i, i + 1, j, j + 1) for i in 0:5 for j in 0:5]
            qs = [_env(i + 0.5, i + 1.5, j + 0.5, j + 1.5) for i in 0:4 for j in 0:4]
            brute, fast = _brute_and_fast(qs, cs)
            @test fast == brute
            @test !isempty(brute)
        end

        @testset "random rectangles (fixed seed)" begin
            Random.seed!(20260721)
            mkrects(n) = [(x0 = 100rand(); y0 = 100rand();
                           _env(x0, x0 + 1 + 9rand(), y0, y0 + 1 + 9rand())) for _ in 1:n]
            cs = mkrects(40)
            qs = mkrects(30)
            brute, fast = _brute_and_fast(qs, cs)
            @test fast == brute
            # non-degenerate fixture: some pairs are candidates, some are not.
            @test !isempty(brute)
            @test length(brute) < length(qs) * length(cs)
        end

        @testset "touching + degenerate boxes" begin
            # shared edges, shared corners, and degenerate (zero-area) point/line boxes.
            cs = [_env(0, 1, 0, 1), _env(1, 2, 0, 1), _env(0, 1, 1, 2),
                  _env(2, 2, 2, 2),          # degenerate point box
                  _env(0, 1, 3, 3)]          # degenerate horizontal line box
            qs = [_env(1, 1, 0, 1),          # degenerate vertical line on the shared edge
                  _env(0.5, 1.5, 0.5, 1.5),  # straddles four cells
                  _env(2, 2, 2, 2)]          # coincides with the degenerate point box
            brute, fast = _brute_and_fast(qs, cs)
            @test fast == brute
            # closed predicate: the degenerate point boxes coincide ⇒ (3,4) is a candidate.
            @test (3, 4) in brute
        end

        @testset "disjoint boxes ⇒ empty candidate set" begin
            cs = [_env(10i, 10i + 1, 0, 1) for i in 0:5]
            qs = [_env(10i + 3, 10i + 4, 0, 1) for i in 0:5]  # each 2 units past a cell's max
            brute, fast = _brute_and_fast(qs, cs)
            @test isempty(brute)
            @test fast == brute
        end

        @testset "empty inputs" begin
            empt = NTuple{4,Float64}[]
            some = [_env(0, 1, 0, 1)]
            @test ESS.broad_phase_candidates(empt, some) == Tuple{Int,Int}[]
            @test ESS.broad_phase_candidates(some, empt) == Tuple{Int,Int}[]
            @test ESS.broad_phase_candidates(some, ESS.build_spatial_index(empt)) == Tuple{Int,Int}[]
            @test ESS.broad_phase_candidates(empt, ESS.build_spatial_index(some)) == Tuple{Int,Int}[]
        end
    end

    # ---------------------------------------------------------------------- #
    # (b) CONSERVATIVENESS — true overlaps ⊆ candidates.
    # ---------------------------------------------------------------------- #
    @testset "(b) conservativeness" begin
        @testset "random rectangles: interior overlaps ⊆ candidates" begin
            Random.seed!(424242)
            mkrects(n) = [(x0 = 50rand(); y0 = 50rand();
                           _env(x0, x0 + 0.5 + 5rand(), y0, y0 + 0.5 + 5rand())) for _ in 1:n]
            cs = mkrects(50)
            qs = mkrects(40)
            cand = ESS.broad_phase_candidates(qs, cs)
            truth = _true_interior_overlaps(qs, cs)
            @test issubset(Set(truth), Set(cand))          # no true overlap is missed
            # closed candidate set ⊇ open-interior truth, and here strictly so.
            @test length(cand) >= length(truth)
            # fast path is equally conservative (identical set).
            @test ESS.broad_phase_candidates(qs, ESS.build_spatial_index(cs)) == cand
        end

        @testset "rotated quads: polygon overlap ⊆ candidates (AABB ⊋ polygon)" begin
            Random.seed!(99)
            quads = Matrix{Float64}[]
            for _ in 1:24
                x0 = 20rand(); y0 = 20rand()
                push!(quads, _rotate(_quad(x0, x0 + 1 + 3rand(), y0, y0 + 1 + 3rand()),
                                     2π * rand()))
            end
            envs = [_ring_env(q) for q in quads]
            cand = ESS.broad_phase_candidates(envs, envs)
            # narrow-phase truth: an actual planar polygon clip with positive area.
            truth = Tuple{Int,Int}[]
            for i in eachindex(quads), j in eachindex(quads)
                ring = ESS.intersect_polygon(quads[i], quads[j], "planar")
                if size(ring, 1) >= 3 && ESS.polygon_area(ring, "planar") > 1e-12
                    push!(truth, (i, j))
                end
            end
            @test issubset(Set(truth), Set(cand))          # every real overlap is a candidate
            @test ESS.broad_phase_candidates(envs, ESS.build_spatial_index(envs)) == cand
        end
    end

    # ---------------------------------------------------------------------- #
    # (c) eps MONOTONICITY — candidates grow with eps, fast == brute at eps>0.
    # ---------------------------------------------------------------------- #
    @testset "(c) eps monotonicity" begin
        Random.seed!(7)
        mkrects(n) = [(x0 = 30rand(); y0 = 30rand();
                       _env(x0, x0 + 1 + 2rand(), y0, y0 + 1 + 2rand())) for _ in 1:n]
        cs = mkrects(35)
        qs = mkrects(25)
        c0 = ESS.broad_phase_candidates(qs, cs; eps=0.0)
        cδ = ESS.broad_phase_candidates(qs, cs; eps=0.75)
        cδδ = ESS.broad_phase_candidates(qs, cs; eps=3.0)
        @test issubset(Set(c0), Set(cδ))
        @test issubset(Set(cδ), Set(cδδ))
        @test length(cδ) >= length(c0)
        # fast path identical to brute at each eps (index built with the same eps).
        for e in (0.0, 0.75, 3.0)
            brute, fast = _brute_and_fast(qs, cs; eps=e)
            @test fast == brute
        end
        # eps mismatch between index and query is a hard error (avoids silent
        # inconsistency with the baked cell inflation).
        idx0 = ESS.build_spatial_index(cs; eps=0.0)
        @test_throws ArgumentError ESS.broad_phase_candidates(qs, idx0; eps=0.75)
    end
end
