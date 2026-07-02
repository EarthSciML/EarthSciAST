# Conservative-regridding geometry kernel — the M4 `intersect_polygon` leaf.
#
# RFC `semiring-faq-unified-ir` §8.1 / Appendix B (B.2 Julia); `CONFORMANCE_SPEC.md`
# §5.8. Bead ess-my4.4.3 (the Julia kernel); the Python sibling is ess-my4.4.4.
#
# The conservative-regridding overlap-area factor `A_ij = area(cell_i ∩ cell_j)`
# splits at the same boundary that makes `acos` a leaf but `Σ coeff·acos(…)` a FAQ:
#
#   * `intersect_polygon` — the REQUIRED kernel leaf. It clips two lon-lat polygon
#     rings and returns the overlap vertex ring of *data-dependent* length. Polygon
#     clipping (Sutherland–Hodgman / great-circle overlay) is iterative,
#     control-flow-heavy and robustness-critical, so it genuinely cannot be written
#     as a semiring aggregate — the IR orchestrates it, the binding supplies the
#     implementation (the same status as `acos`/`sqrt`). It carries a `manifold`
#     flag and its cross-binding conformance is tolerance-based, not bit-for-bit
#     (§5.8.2 / B.5).
#   * `polygon_area` — NOT a new op. The area of a vertex ring is an ordinary
#     `sum_product` FAQ over the ring index set (planar shoelace / Gauss–Green, or
#     the spherical-excess sum), evaluated by the existing aggregate machinery in
#     `tree_walk.jl`. The pure helper [`polygon_area`](@ref) here is the *reference*
#     area used to cross-check that FAQ and to back the spherical manifolds — the
#     same formula the FAQ body encodes, not a parallel implementation of the op.
#
# Manifolds (CONFORMANCE_SPEC.md §5.8.4 — bindings compare only same-manifold):
#
#   `planar`   Flat lon-lat plane. Sutherland–Hodgman convex clip + planar shoelace
#              area. Dependency-free (no GeometryOps); the portable path the
#              conformance fixtures exercise. A flat plane is wrong at the
#              poles/antimeridian (RFC §B.4) — that is the modelling error the
#              spherical manifolds avoid, not a bug in this path.
#   `spherical` / `geodesic`
#              True great-circle clipping via `GeometryOps.jl` — `Spherical()`
#              manifold, `ConvexConvexSutherlandHodgman` clip (the stack
#              `ConservativeRegridding.jl` uses). The clip is delegated to the
#              `EarthSciSerializationGeometryOpsExt` extension so the core package
#              never has to load the heavy geometry stack; the planar path and the
#              rest of the toolkit never require it. The area uses the closed-form
#              spherical-excess sum (Van Oosterom–Strackee), so it needs no backend
#              and matches an S2 / GeometryOps Girard area for the same ring.

"""
Closed set of `manifold` values the `intersect_polygon` leaf understands. Mirrors
the schema enum on the op (esm-schema.json; additive in ess-my4.4.2).
"""
const GEOMETRY_MANIFOLDS = ("planar", "spherical", "geodesic")

"""
B.5 / §5.8.2 sliver floor: `atol ≈ 1e-15·R²`. Near-tangent overlaps are the regime
where two clippers legitimately disagree on whether a tiny intersection even
exists, so sub-`atol` areas are treated as equal-to-zero.
"""
const SLIVER_ATOL_FACTOR = 1e-15

"""
    GeometryError(msg)

A polygon-clip / area evaluation failed (bad operand, degenerate input, or a
spherical clip requested without the GeometryOps extension loaded).
"""
struct GeometryError <: Exception
    msg::String
end
Base.showerror(io::IO, e::GeometryError) = print(io, "GeometryError: ", e.msg)

# Spherical / geodesic clip hook. The real method is added by
# `ext/EarthSciSerializationGeometryOpsExt.jl` when `GeometryOps` + `GeoInterface`
# are loaded. Calling it without the extension raises a clear, actionable error —
# the planar manifold needs no backend.
function _spherical_clip_geometryops end

# --------------------------------------------------------------------------- #
# Operand coercion
# --------------------------------------------------------------------------- #

# Coerce a clip operand to an `n×2` Float64 matrix of lon-lat vertices. Accepts a
# 2-column matrix (the `[verts, coord]` polygon shape) or a vector of length-2
# rows. Provided by the evaluator as a const-array matrix.
function _to_matrix(poly)::Matrix{Float64}
    if poly isa AbstractMatrix
        return Matrix{Float64}(poly)
    elseif poly isa AbstractVector && !isempty(poly) && poly[1] isa Union{AbstractVector,Tuple}
        n = length(poly)
        m = Matrix{Float64}(undef, n, 2)
        for i in 1:n
            row = poly[i]
            length(row) == 2 || throw(GeometryError(
                "polygon vertex $i has $(length(row)) coordinates, expected 2 (lon, lat)"))
            m[i, 1] = Float64(row[1]); m[i, 2] = Float64(row[2])
        end
        return m
    end
    throw(GeometryError("cannot coerce polygon operand of type $(typeof(poly)) to an [n, 2] lon-lat ring"))
end

# np.allclose-matching point comparison (atol=1e-8, rtol=1e-5) so the closing-vertex
# drop and consecutive-dedup decisions match the Python sibling exactly.
@inline _allclose_pt(ax, ay, bx, by) =
    abs(ax - bx) <= 1e-8 + 1e-5 * abs(bx) && abs(ay - by) <= 1e-8 + 1e-5 * abs(by)

"""
    _as_ring(poly, who) -> Matrix{Float64}

Coerce a clip operand to an `n×2` array of *distinct* lon-lat vertices. A closing
duplicate final vertex (`ring[end] == ring[1]`) is dropped so closure is implicit —
the convention the schema fixtures use (a 4-vertex quad, edge 4→1 implied) — and
**consecutive duplicate vertices are removed** (esm-spec §8.6.1): a padded ring —
e.g. an MPAS pentagon stored in a hexagon-shaped `[cells, NVERT, 2]` array with
its final vertex repeated to fill the rectangular slot — MUST be accepted and
evaluated as the deduplicated ring. Dedup happens HERE, before any backend
kernel, because backend tolerance differs (this package's planar clip and
GeometryOps tolerate zero-length edges; S2 — the Python/Rust spherical backend —
rejects them as degenerate edges), and the op's cross-binding contract cannot
depend on that. A ring with fewer than 3 *distinct* vertices is degenerate and
rejected.
"""
function _as_ring(poly::AbstractMatrix, who::AbstractString)::Matrix{Float64}
    size(poly, 2) == 2 || throw(GeometryError(
        "intersect_polygon $who must be an [verts, 2] lon-lat ring, got array of shape $(size(poly))"))
    # _dedup_consecutive drops consecutive duplicates AND the wrap pair (a
    # closing first==last duplicate), so padding and explicit closure both
    # collapse to the n distinct vertices with implicit closure.
    arr = _dedup_consecutive(Matrix{Float64}(poly))
    size(arr, 1) >= 3 || throw(GeometryError(
        "intersect_polygon $who needs ≥3 distinct vertices, got $(size(arr, 1))"))
    return arr
end

# --------------------------------------------------------------------------- #
# Planar clip — Sutherland–Hodgman (convex clip polygon)
# --------------------------------------------------------------------------- #

# Signed area of the o→a, o→b parallelogram (z of the cross product); the inside
# test against a CCW clip edge (positive ⇒ left of the directed edge).
@inline _cross(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])

# Intersection of the infinite clip line a→b with subject segment p→q.
@inline function _segment_intersection(a, b, p, q)
    rx = b[1] - a[1]; ry = b[2] - a[2]
    sx = q[1] - p[1]; sy = q[2] - p[2]
    denom = rx * sy - ry * sx
    if abs(denom) < 1e-300
        # Parallel / degenerate: fall back to the segment endpoint inside the
        # half-plane (the caller only reaches here when p,q straddle the line).
        return q
    end
    t = ((p[1] - a[1]) * sy - (p[2] - a[2]) * sx) / denom
    return (a[1] + t * rx, a[2] + t * ry)
end

# Planar shoelace signed area of an n×2 ring (implicit closure).
function _signed_area(ring::AbstractMatrix)
    n = size(ring, 1)
    n < 3 && return 0.0
    acc = 0.0
    for i in 1:n
        j = i == n ? 1 : i + 1
        acc += ring[i, 1] * ring[j, 2] - ring[j, 1] * ring[i, 2]
    end
    return 0.5 * acc
end

# Drop consecutive duplicate vertices (incl. the wrap pair) a clip can emit.
function _dedup_consecutive(ring::Matrix{Float64})::Matrix{Float64}
    n = size(ring, 1)
    n <= 1 && return ring
    keep = Int[1]
    for i in 2:n
        last = keep[end]
        if !_allclose_pt(ring[i, 1], ring[i, 2], ring[last, 1], ring[last, 2])
            push!(keep, i)
        end
    end
    out = ring[keep, :]
    if size(out, 1) >= 2 && _allclose_pt(out[1, 1], out[1, 2], out[end, 1], out[end, 2])
        out = out[1:end-1, :]
    end
    return out
end

"""
    _planar_clip(subject, clip) -> Matrix{Float64}

Sutherland–Hodgman clip of `subject` against the **convex** `clip` ring. Both are
`n×2` distinct vertices. Returns the overlap ring as distinct vertices, or an empty
`0×2` array when the polygons do not overlap. Conservative-regridding cells are
convex quads, so the convex-clipper restriction is satisfied; a non-convex clip
operand would silently give the convex-edge intersection and is out of contract.
"""
function _planar_clip(subject::AbstractMatrix, clip::AbstractMatrix)::Matrix{Float64}
    # Orient the clip ring CCW so "inside == left of each directed edge" holds.
    cl = _signed_area(clip) < 0 ? clip[end:-1:1, :] : clip
    output = Tuple{Float64,Float64}[(subject[i, 1], subject[i, 2]) for i in 1:size(subject, 1)]
    nclip = size(cl, 1)
    for i in 1:nclip
        isempty(output) && break
        a = (cl[i, 1], cl[i, 2])
        inext = i == nclip ? 1 : i + 1
        b = (cl[inext, 1], cl[inext, 2])
        prev = output
        output = Tuple{Float64,Float64}[]
        m = length(prev)
        for j in 1:m
            p = prev[j]
            q = prev[j == m ? 1 : j + 1]
            p_in = _cross(a, b, p) >= 0.0
            q_in = _cross(a, b, q) >= 0.0
            if p_in
                push!(output, p)
                if !q_in
                    push!(output, _segment_intersection(a, b, p, q))
                end
            elseif q_in
                push!(output, _segment_intersection(a, b, p, q))
            end
        end
    end
    isempty(output) && return zeros(Float64, 0, 2)
    ring = Matrix{Float64}(undef, length(output), 2)
    for (k, pt) in enumerate(output)
        ring[k, 1] = pt[1]; ring[k, 2] = pt[2]
    end
    return _dedup_consecutive(ring)
end

# --------------------------------------------------------------------------- #
# Public clip entry point
# --------------------------------------------------------------------------- #

"""
    intersect_polygon(poly_a, poly_b, manifold) -> Matrix{Float64}

Clip two lon-lat polygon rings; return the overlap ring (RFC §8.1).

`poly_a` / `poly_b` are `[verts, 2]` lon-lat coordinate arrays. `manifold` is one of
[`GEOMETRY_MANIFOLDS`](@ref) and is **required** — the geometry interpretation is
part of the op's contract and is never inferred (CONFORMANCE_SPEC.md §5.8.4).
Returns the overlap as `n×2` *distinct* lon-lat vertices (data-dependent `n`), or an
empty `0×2` array when the cells do not overlap. `planar` is dependency-free;
`spherical` / `geodesic` delegate the clip to `GeometryOps.jl` via the
`EarthSciSerializationGeometryOpsExt` extension.
"""
# True when the GeometryOps backend (the `EarthSciSerializationGeometryOpsExt`
# extension) is loaded, so the spherical / geodesic clip is callable. The area FAQ
# needs no backend — only the spherical *clip* does.
_spherical_clip_available() =
    hasmethod(_spherical_clip_geometryops, Tuple{Matrix{Float64},Matrix{Float64},String})

function intersect_polygon(poly_a, poly_b, manifold::AbstractString)::Matrix{Float64}
    manifold in GEOMETRY_MANIFOLDS || throw(GeometryError(
        "unknown manifold $(repr(manifold)); the closed set is $(GEOMETRY_MANIFOLDS)"))
    a = _as_ring(_to_matrix(poly_a), "poly_a")
    b = _as_ring(_to_matrix(poly_b), "poly_b")
    if manifold == "planar"
        return _planar_clip(a, b)
    end
    # spherical / geodesic — great-circle clip via GeometryOps (extension). Both
    # share the great-circle-edge model (RFC §B.4), so geodesic reuses the
    # spherical clip, matching the Python sibling.
    if !_spherical_clip_available()
        throw(GeometryError(
            "$(manifold) intersect_polygon requires the GeometryOps backend; " *
            "load it with `import GeometryOps, GeoInterface` to trigger the " *
            "EarthSciSerializationGeometryOpsExt extension. The planar manifold needs no backend."))
    end
    return _spherical_clip_geometryops(a, b, String(manifold))
end

"""
    close_ring(ring) -> Matrix{Float64}

Append the first vertex so edge `n→1` is addressable as `ring[n+1]`. The area FAQ
ranges over the `n` distinct vertices but its shoelace body reads `ring[v]` and
`ring[v+1]`; closing the ring makes the wrap edge an ordinary `v+1` lookup with no
modular arithmetic in the AST.
"""
function close_ring(ring::AbstractMatrix)::Matrix{Float64}
    size(ring, 1) == 0 && return Matrix{Float64}(ring)
    return vcat(Matrix{Float64}(ring), reshape(Float64.(ring[1, :]), 1, 2))
end

# --------------------------------------------------------------------------- #
# Polar-edge densification — great-circle-edge accuracy (RFC §B.4 / §5.8.4)
# --------------------------------------------------------------------------- #

"""
    densify_parallel_edges(ring, max_segment_deg; lat_atol=1e-9) -> Matrix{Float64}

Subdivide each *parallel* edge (constant latitude) of a lon-lat `ring` into
great-circle segments at most `max_segment_deg` degrees of longitude wide,
inserting the intermediate vertices **on the parallel** (linear in lon-lat).

The `spherical` / `geodesic` manifolds model every polygon edge — the clip's and
the `polygon_area` FAQ's — as a **great-circle geodesic** (RFC §B.4 / §5.8.4). A
lon-lat cell edge running along a parallel is a *small circle*, not a great
circle, so a single wide great-circle edge bows off the parallel and a coarse
polar cell carries a real area error: ≈4% for a 30° cell next to the pole, ≈1% at
15°, scaling with the **square of the cell's longitude width**. Replacing one
wide parallel edge with many short great-circle chords that each stay on the
parallel drives that error toward zero — the standard mitigation (XIOS) for
coarse polar lat-lon grids.

This is an **opt-in pre-clip** step: apply it to each operand before
[`intersect_polygon`](@ref) (and the `polygon_area` FAQ) when polar accuracy
matters. It is **off by default** — nothing in the evaluator calls it — so the
default clip / area behaviour is unchanged. Only parallel edges are touched: a
meridian already lies on a great circle, and a slanted edge is not a parallel, so
both are returned whole. `max_segment_deg` must be positive; `lat_atol` (degrees)
is the tolerance for judging an edge to lie along a parallel. The result is the
densified ring as `n×2` *distinct* lon-lat vertices (implicit closure preserved).
"""
function densify_parallel_edges(ring, max_segment_deg::Real; lat_atol::Real=1e-9)::Matrix{Float64}
    max_segment_deg > 0 || throw(GeometryError(
        "densify_parallel_edges max_segment_deg must be positive, got $(max_segment_deg)"))
    r = _as_ring(_to_matrix(ring), "ring")
    n = size(r, 1)
    out = Tuple{Float64,Float64}[]
    for i in 1:n
        ax = r[i, 1]; ay = r[i, 2]
        j = i == n ? 1 : i + 1
        bx = r[j, 1]; by = r[j, 2]
        push!(out, (ax, ay))
        dlon = bx - ax
        if abs(ay - by) <= lat_atol && abs(dlon) > max_segment_deg
            nseg = ceil(Int, abs(dlon) / max_segment_deg)
            for k in 1:nseg-1
                t = k / nseg
                push!(out, (ax + t * dlon, ay + t * (by - ay)))
            end
        end
    end
    m = Matrix{Float64}(undef, length(out), 2)
    for (k, pt) in enumerate(out)
        m[k, 1] = pt[1]; m[k, 2] = pt[2]
    end
    return m
end

# --------------------------------------------------------------------------- #
# Reference area (the same formula the polygon_area FAQ body encodes)
# --------------------------------------------------------------------------- #

# Lon-lat (degrees) → unit vector on the sphere.
@inline function _lonlat_to_unit(lon_deg, lat_deg)
    lon = deg2rad(lon_deg); lat = deg2rad(lat_deg)
    cl = cos(lat)
    return (cl * cos(lon), cl * sin(lon), sin(lat))
end

# Signed solid angle (spherical excess) of triangle a,b,c on the unit sphere.
# Van Oosterom–Strackee: E = 2·atan2(a·(b×c), 1 + a·b + b·c + c·a). Exact for
# great-circle edges, so it matches an S2 / GeometryOps Girard area — the same
# geodesic-edge model the spherical clip uses (CONFORMANCE_SPEC.md §5.8.4).
@inline function _spherical_triangle_excess(a, b, c)
    cx = b[2] * c[3] - b[3] * c[2]
    cy = b[3] * c[1] - b[1] * c[3]
    cz = b[1] * c[2] - b[2] * c[1]
    triple = a[1] * cx + a[2] * cy + a[3] * cz
    dot_ab = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    dot_bc = b[1] * c[1] + b[2] * c[2] + b[3] * c[3]
    dot_ca = c[1] * a[1] + c[2] * a[2] + c[3] * a[3]
    return 2.0 * atan(triple, 1.0 + dot_ab + dot_bc + dot_ca)
end

# Spherical-excess signed area via a great-circle fan triangulation:
# A = R²·Σ_{i=2}^{n-1} E(v_1, v_i, v_{i+1}). The spherical-excess form RFC §8.1
# names (great-circle edges, matching S2), built from the atan2/sqrt scalar-leaf
# family — the same fan a spherical polygon_area FAQ ranges over.
function _spherical_signed_area(ring::AbstractMatrix, radius::Real)
    n = size(ring, 1)
    n < 3 && return 0.0
    verts = [_lonlat_to_unit(ring[i, 1], ring[i, 2]) for i in 1:n]
    total = 0.0
    for i in 2:n-1
        total += _spherical_triangle_excess(verts[1], verts[i], verts[i+1])
    end
    return radius * radius * total
end

"""
    polygon_area(ring, manifold; radius=1.0) -> Float64

Imperative **cross-check oracle** for the `sum_product` `polygon_area` FAQ. Planar
⇒ shoelace / Gauss–Green; spherical / geodesic ⇒ the spherical-excess sum
(`radius` = sphere radius / characteristic length, default the unit sphere).
Returns `0.0` for a degenerate (< 3 vertex) ring — an empty clip. The production
polygon area now routes through the FAQ ([`_polygon_area_via_faq`](@ref)) for both
manifolds; this function encodes the same formula the FAQ body does, kept as the
independent oracle.
"""
function polygon_area(ring::AbstractMatrix, manifold::AbstractString; radius::Real=1.0)::Float64
    r = Matrix{Float64}(ring)
    if size(r, 1) >= 2 && _allclose_pt(r[1, 1], r[1, 2], r[end, 1], r[end, 2])
        r = r[1:end-1, :]
    end
    size(r, 1) < 3 && return 0.0
    if manifold == "planar"
        return abs(_signed_area(r))
    elseif manifold == "spherical" || manifold == "geodesic"
        return abs(_spherical_signed_area(r, radius))
    end
    throw(GeometryError("unknown manifold $(repr(manifold)); the closed set is $(GEOMETRY_MANIFOLDS)"))
end

# --------------------------------------------------------------------------- #
# B.5 / §5.8.2 tolerance gate
# --------------------------------------------------------------------------- #

"""
    area_tolerance_ok(area_x, area_ref; rtol, radius=1.0, atol=nothing) -> Bool

Combined rel+abs area-agreement gate with a sliver floor (B.5 / §5.8.2):
`|A_x − A_ref| ≤ atol + rtol·A_ref` with `atol ≈ 1e-15·R²` the sliver floor. Sub-
`atol` areas are treated as equal-to-zero, so a "present-but-tiny" overlap and an
"absent" one **both pass**. `rtol` is empirically calibrated per the loosest binding
pair (GeometryOps-vs-S2). Pass an explicit `atol` to override the floor.
"""
function area_tolerance_ok(area_x::Real, area_ref::Real; rtol::Real,
                           radius::Real=1.0, atol::Union{Nothing,Real}=nothing)::Bool
    at = atol === nothing ? SLIVER_ATOL_FACTOR * radius * radius : atol
    ax = abs(area_x) <= at ? 0.0 : float(area_x)
    ar = abs(area_ref) <= at ? 0.0 : float(area_ref)
    return abs(ax - ar) <= at + rtol * abs(ar)
end
