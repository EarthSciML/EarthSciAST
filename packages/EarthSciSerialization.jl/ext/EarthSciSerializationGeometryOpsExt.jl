"""
    EarthSciSerializationGeometryOpsExt

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
module EarthSciSerializationGeometryOpsExt

import EarthSciSerialization as ESS
import GeometryOps as GO
import GeoInterface as GI

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
function ESS._spherical_clip_geometryops(a::AbstractMatrix, b::AbstractMatrix,
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

end # module EarthSciSerializationGeometryOpsExt
