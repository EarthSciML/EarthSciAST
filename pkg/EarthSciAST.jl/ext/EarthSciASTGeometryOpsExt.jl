"""
    EarthSciASTGeometryOpsExt

Spherical / geodesic polygon clipping for the M4 `intersect_polygon` leaf, via
`GeometryOps.jl` (RFC `semiring-faq-unified-ir` §8.1 / Appendix B.2 — the Julia
binding). Loaded automatically when both `GeometryOps` and `GeoInterface` are in
the session; it supplies the `_spherical_clip_geometryops` method the core
`intersect_polygon` calls for the `spherical` / `geodesic` manifolds. The `planar`
manifold and the area FAQ need no backend, so the core package never has to load
this heavy geometry stack.

`GeometryOps` does native, non-approximate spherical clipping — `Spherical()`
manifold, `ConvexConvexSutherlandHodgman` clip (Girard area available) — the stack
`ConservativeRegridding.jl` uses internally. lon-lat operands are transformed to the
unit sphere (`UnitSphereFromGeographic`), clipped, and the overlap ring is
transformed back to lon-lat (`GeographicFromUnitSphere`). Both `spherical` and
`geodesic` use the great-circle clip: per RFC §B.4 the two share the
great-circle-edge model in these bindings, matching the Python sibling.
"""
module EarthSciASTGeometryOpsExt

# Explicit imports so we can add extension methods to these core generics.
import EarthSciAST: _spherical_clip_geometryops, broad_phase_candidates,
                    build_spatial_index, _env4
import GeometryOps as GO
import GeoInterface as GI
import SortTileRecursiveTree as STR
import Extents

# Build a GeoInterface polygon with UnitSphericalPoint coordinates from an `n×2`
# lon-lat matrix, closing the ring (GeometryOps expects a closed exterior ring).
function _unitsphere_polygon(ring::AbstractMatrix, to_unit)
    n = size(ring, 1)
    pts = [to_unit((ring[i, 1], ring[i, 2])) for i in 1:n]
    push!(pts, pts[1])
    return GI.Polygon([GI.LinearRing(pts)])
end

# Tolerances for detecting the closing duplicate vertex when converting a
# clipped ring back to the planar "n distinct vertices, implicit closure"
# convention: tight enough that genuinely distinct lon-lat vertices are never
# merged (1e-7° ≈ 1 cm on Earth), loose enough to absorb the float noise of
# the unit-sphere round-trip.
const _RING_CLOSE_ATOL = 1e-9
const _RING_CLOSE_RTOL = 1e-7

# Extract the exterior-ring lon-lat vertices from a clipped polygon (its coords are
# UnitSphericalPoints), dropping the closing duplicate so the result matches the
# planar convention: `n` distinct vertices, implicit closure.
function _ring_lonlat(poly, to_geo)
    poly === nothing && return zeros(Float64, 0, 2)
    ext = GI.getexterior(poly)
    npt = GI.npoint(ext)
    npt == 0 && return zeros(Float64, 0, 2)
    out = Matrix{Float64}(undef, npt, 2)
    for i in 1:npt
        lonlat = to_geo(GI.getpoint(ext, i))
        out[i, 1] = lonlat[1]
        out[i, 2] = lonlat[2]
    end
    if npt >= 2 &&
       isapprox(out[1, 1], out[npt, 1]; atol=_RING_CLOSE_ATOL, rtol=_RING_CLOSE_RTOL) &&
       isapprox(out[1, 2], out[npt, 2]; atol=_RING_CLOSE_ATOL, rtol=_RING_CLOSE_RTOL)
        out = out[1:npt-1, :]
    end
    return out
end

# Spherical / geodesic clip via GeometryOps `ConvexConvexSutherlandHodgman`. `a` and
# `b` are `n×2` distinct lon-lat vertex matrices; returns the overlap ring as `n×2`
# distinct lon-lat vertices (empty `0×2` when the cells do not overlap).
function _spherical_clip_geometryops(a::AbstractMatrix, b::AbstractMatrix,
                                     manifold::AbstractString)
    to_unit = GO.UnitSphereFromGeographic()
    to_geo = GO.GeographicFromUnitSphere()
    pa = _unitsphere_polygon(a, to_unit)
    pb = _unitsphere_polygon(b, to_unit)
    res = GO.intersection(GO.ConvexConvexSutherlandHodgman(GO.Spherical()), pa, pb;
                          target=GI.PolygonTrait())
    if res isa AbstractVector
        poly = isempty(res) ? nothing : first(res)
    else
        poly = res
    end
    return _ring_lonlat(poly, to_geo)
end

# =========================================================================== #
# Planar spatial-index broad phase — fast STRtree method (projection-pushdown
# Phase 3a). Accelerates the core brute-force `broad_phase_candidates` (see
# src/broad_phase.jl) with a `SortTileRecursiveTree.STRtree` driven through
# GeometryOps' `SpatialTreeInterface` dual-tree traversal — the machinery
# `ConservativeRegridding.jl` uses. Over EXACT (eps-inflated) envelopes the
# STRtree yields exactly the envelope-intersecting pairs, so this returns a
# vector byte-identical to the brute-force reference for the same `eps`.
# =========================================================================== #

"""
    EarthSciASTSpatialIndex

Opaque spatial-index marker returned by [`build_spatial_index`](@ref). Wraps a
`SortTileRecursiveTree.STRtree` built over the cell envelopes inflated outward by
`eps`; `broad_phase_candidates(query_envs, ::EarthSciASTSpatialIndex)` dispatches
on it for the fast path. `tree` is `nothing` for an empty cell set.
"""
struct EarthSciASTSpatialIndex{T}
    tree::T          # STRtree over eps-inflated cell extents, or `nothing` if empty
    n::Int           # number of indexed cells (1-based indices 1:n)
    eps::Float64     # outward inflation baked into the indexed cell extents
end

# Envelope `(xmin, ymin, xmax, ymax)` → eps-inflated `Extents.Extent` with X
# BEFORE Y (the STRtree sort and `Extents.intersects` key dimensions by name;
# X-first matches the tree's split order). The inflated endpoints are the SAME
# floats the core method compares, so the closed-interval predicates agree
# bit-for-bit.
@inline function _env_to_extent(env, eps::Float64)
    xmin, ymin, xmax, ymax = _env4(env)
    return Extents.Extent(X=(xmin - eps, xmax + eps), Y=(ymin - eps, ymax + eps))
end

function build_spatial_index(cell_envs::AbstractVector; eps::Real=0.0)
    e = Float64(eps)
    n = length(cell_envs)
    n == 0 && return EarthSciASTSpatialIndex(nothing, 0, e)
    exts = [_env_to_extent(cell_envs[i], e) for i in 1:n]
    return EarthSciASTSpatialIndex(STR.STRtree(exts), n, e)
end

function broad_phase_candidates(query_envs::AbstractVector,
                                index::EarthSciASTSpatialIndex;
                                eps::Real=index.eps)
    out = Tuple{Int,Int}[]
    Float64(eps) == index.eps || throw(ArgumentError(
        "broad_phase_candidates: eps=$(eps) does not match eps=$(index.eps) baked into " *
        "build_spatial_index; rebuild the index with the query eps"))
    (isempty(query_envs) || index.n == 0) && return out
    e = index.eps
    qexts = [_env_to_extent(query_envs[i], e) for i in 1:length(query_envs)]
    qtree = STR.STRtree(qexts)
    # Dual-tree descent: `f(qi, cj)` fires for each leaf pair whose exact
    # (inflated) extents intersect; `qi`/`cj` are the original 1-based positions.
    GO.SpatialTreeInterface.dual_depth_first_search(Extents.intersects, qtree, index.tree) do qi, cj
        push!(out, (qi, cj))
        nothing
    end
    # Traversal order is tree-internal; sort! pins the (qi, cj)-ascending
    # determinism contract, byte-identical to the brute-force reference.
    return sort!(out)
end

end # module EarthSciASTGeometryOpsExt
