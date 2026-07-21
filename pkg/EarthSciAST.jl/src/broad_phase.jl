# =========================================================================== #
# PLANAR spatial-index broad phase — conservative candidate generation.
# =========================================================================== #
#
# Phase 3a of projection-pushdown. A reusable, deterministic broad-phase seam
# that returns a CONSERVATIVE SUPERSET of the (query × cell) index pairs whose
# 2D bounding boxes (envelopes) intersect. Phase 3b will consume this to replace
# a uniform-grid bin-equality join gate (tree-walk `_join_admits`,
# src/tree_walk/semiring.jl); here we deliver ONLY the primitive + its oracle.
#
# Two layers so there is a reference oracle:
#
#   1. CORE (this file, no heavy deps): the brute-force reference method + the
#      generic seam. `broad_phase_candidates(query_envs, cell_envs; eps)` walks
#      every pair and tests envelope intersection. This method is BOTH the
#      dependency-free fallback AND the conformance oracle for the fast path.
#
#   2. EXT (ext/EarthSciASTGeometryOpsExt.jl): a fast method dispatched on a
#      spatial-index marker (`build_spatial_index(cell_envs)`), using a
#      `SortTileRecursiveTree.STRtree` driven through GeometryOps'
#      `SpatialTreeInterface` dual-tree traversal — the exact machinery
#      `ConservativeRegridding.jl` uses. Over exact envelopes the STRtree yields
#      EXACTLY the envelope-intersecting pairs, so the fast path returns a vector
#      byte-identical to this brute-force method for the same `eps`.
#
# ENVELOPE CONVENTION. A feature envelope is `(xmin, ymin, xmax, ymax)` — any
# 4-element indexable (an `NTuple{4,Float64}`, a length-4 `Vector`, …). Note this
# ORDER differs from geometry.jl's internal `_ring_xybbox` tuple, which is
# `(xmin, xmax, ymin, ymax)`; a Phase-3b consumer deriving envelopes from a cell
# ring must remap. The intersection predicate is CLOSED (edge-touching boxes are
# candidates), matching `Extents.intersects` and the negation of geometry.jl's
# `_bbox_disjoint` planar reject — so at `eps=0` this candidate set is exactly the
# set of pairs `_bbox_disjoint` does not reject.
#
# `eps` SEMANTICS. Both envelopes of a pair are inflated OUTWARD by `eps` before
# testing: `xmin -= eps, ymin -= eps, xmax += eps, ymax += eps`. `eps >= 0` grows
# the candidate set (monotone): `candidates(eps=δ) ⊇ candidates(eps=0)`. `eps` is
# a slack knob to keep near-touching / float-fuzzy pairs conservative.

"""
    broad_phase_candidates(query_envs, cell_envs; eps=0.0) -> Vector{Tuple{Int,Int}}

Return every `(qi, cj)` — 1-based positions in `query_envs` / `cell_envs` — whose
2D envelopes intersect after inflating BOTH outward by `eps`. Envelopes are
`(xmin, ymin, xmax, ymax)` 4-tuples (see file header). The result is sorted
ascending by `(qi, cj)` for determinism.

This is a CONSERVATIVE SUPERSET of true geometric overlaps: any pair of features
whose geometries actually overlap has intersecting envelopes and so appears here
(with `eps >= 0`). Missing a true overlap is impossible by construction — the
envelope of a geometry contains it.

This `(AbstractVector, AbstractVector)` method is the dependency-free brute-force
reference. Loading `GeometryOps` (+ `GeoInterface`, `SortTileRecursiveTree`,
`Extents`) adds a fast `(AbstractVector, <spatial index>)` method — see
[`build_spatial_index`](@ref) — that returns an identical vector.
"""
function broad_phase_candidates end

"""
    build_spatial_index(cell_envs; eps=0.0) -> <spatial index>

Build a spatial index over `cell_envs` (envelopes inflated outward by `eps`) for
the fast [`broad_phase_candidates`](@ref) path. Only available when the
`EarthSciASTGeometryOpsExt` extension is loaded (needs `GeometryOps`,
`SortTileRecursiveTree`, `Extents`); the returned index is passed as the second
argument to `broad_phase_candidates`, which must be called with the SAME `eps`.
"""
function build_spatial_index end

# Coerce any 4-element indexable envelope to `(xmin, ymin, xmax, ymax)::NTuple{4,Float64}`.
@inline _env4(e) = (Float64(e[1]), Float64(e[2]), Float64(e[3]), Float64(e[4]))

# CORE brute-force method: the reference oracle. O(nq·nc) exact envelope test.
function broad_phase_candidates(query_envs::AbstractVector, cell_envs::AbstractVector;
                                eps::Real=0.0)
    out = Tuple{Int,Int}[]
    (isempty(query_envs) || isempty(cell_envs)) && return out
    e = Float64(eps)
    nq = length(query_envs)
    nc = length(cell_envs)
    for qi in 1:nq
        qxmin, qymin, qxmax, qymax = _env4(query_envs[qi])
        qxmin -= e; qymin -= e; qxmax += e; qymax += e
        for cj in 1:nc
            cxmin, cymin, cxmax, cymax = _env4(cell_envs[cj])
            cxmin -= e; cymin -= e; cxmax += e; cymax += e
            # Closed-interval AABB intersection per axis (edge-touching admitted),
            # bit-for-bit the predicate `Extents.intersects` applies to the same
            # eps-inflated endpoints in the fast path.
            if qxmin <= cxmax && cxmin <= qxmax && qymin <= cymax && cymin <= qymax
                push!(out, (qi, cj))
            end
        end
    end
    # Emitted in (qi, cj) ascending order already; sort! pins the determinism
    # contract independent of loop structure / index internals.
    return sort!(out)
end

# =========================================================================== #
# OVERLAP JOIN-GATE broad phase (projection-pushdown Phase 2a).
#
# The shared helper that turns two envelope FACTOR-ARRAYS into the candidate
# `Set{(src_pos, tgt_pos)}` an OVERLAP join gate admits on. Built ONCE per gate
# (cached on the resolved `_JoinGate` / `_ViJoinGate`), then consulted by
# membership per contracted tuple in BOTH join paths — `_join_admits`
# (tree_walk/semiring.jl) and `_vi_join_ok` (value_invention.jl). The narrow
# phase (exact rectangle / polygon test) stays as the aggregate's `filter`; this
# is ONLY the conservative broad phase.
# =========================================================================== #

# Build per-position `(xmin, ymin, xmax, ymax)` envelope 4-tuples from named
# const-array envelope factors. `env_names` is 1, 2, or 4 factor names; `cols`
# is the matching list of factor arrays (each a 1-D column indexed by position,
# except the 1-name ring case which is a `[pos, verts, coord]` 3-D array):
#   4 names → rectangles [xmin, ymin, xmax, ymax],
#   2 names → points [x, y] → degenerate envelope (x, y, x, y),
#   1 name  → polygon-ring factor → AABB via `_ring_xybbox` (remapped).
function _envelope_vectors_from_cols(env_names::AbstractVector, cols::AbstractVector)
    k = length(env_names)
    if k == 4
        a, b, c, d = cols
        n = length(a)
        return NTuple{4,Float64}[
            (Float64(a[p]), Float64(b[p]), Float64(c[p]), Float64(d[p])) for p in 1:n]
    elseif k == 2
        x, y = cols
        n = length(x)
        return NTuple{4,Float64}[
            (Float64(x[p]), Float64(y[p]), Float64(x[p]), Float64(y[p])) for p in 1:n]
    elseif k == 1
        return _ring_envelopes(cols[1])
    else
        throw(ArgumentError(
            "overlap-join env must name 1 (rings), 2 (point [x,y]), or 4 " *
            "(rect [xmin,ymin,xmax,ymax]) const-array factors; got $k"))
    end
end

# A `[pos, verts, coord]` ring factor → one AABB envelope per position, remapping
# `_ring_xybbox`'s `(xmin, xmax, ymin, ymax)` to `(xmin, ymin, xmax, ymax)`.
function _ring_envelopes(rings::AbstractArray)
    ndims(rings) == 3 || throw(ArgumentError(
        "overlap-join single-factor env expects a [pos, verts, coord] 3-D ring " *
        "array; got a $(ndims(rings))-D factor"))
    npos = size(rings, 1)
    out = Vector{NTuple{4,Float64}}(undef, npos)
    for p in 1:npos
        xmin, xmax, ymin, ymax = _ring_xybbox(@view rings[p, :, :])
        out[p] = (Float64(xmin), Float64(ymin), Float64(xmax), Float64(ymax))
    end
    return out
end

# Look each env-factor name up in `arrays` (a const-array registry) → envelope
# vectors. Names are stringified so `Symbol` / `String` keys both resolve.
function _envelope_vectors(env_names::AbstractVector, arrays::AbstractDict)
    cols = Any[arrays[String(n)] for n in env_names]
    return _envelope_vectors_from_cols(env_names, cols)
end

"""
    _overlap_candidate_set(src_envs, tgt_envs; eps=0.0) -> Set{Tuple{Int,Int}}
    _overlap_candidate_set(src_names, tgt_names, arrays; eps=0.0) -> Set{Tuple{Int,Int}}

Build the OVERLAP join-gate candidate set: every `(src_pos, tgt_pos)` whose
envelopes intersect (inflated outward by `eps`), keyed so `src_env` is the query
side and `tgt_env` the indexed cell side. The vector method takes the two
envelope vectors directly; the name+registry method resolves envelope factor
arrays out of `arrays` first (see [`_envelope_vectors`](@ref)).

Uses the exported Phase-3a primitive: the fast STRtree path
([`build_spatial_index`](@ref) on the cell/`tgt` side) when the GeometryOps
extension is loaded, else the dependency-free brute-force
[`broad_phase_candidates`](@ref). Both return an identical pair set, so the gate
is deterministic and backend-independent.
"""
function _overlap_candidate_set(src_envs::AbstractVector, tgt_envs::AbstractVector;
                                eps::Real=0.0)
    e = Float64(eps)
    pairs = if hasmethod(build_spatial_index, Tuple{AbstractVector})
        idx = build_spatial_index(tgt_envs; eps=e)
        broad_phase_candidates(src_envs, idx; eps=e)
    else
        broad_phase_candidates(src_envs, tgt_envs; eps=e)
    end
    return Set{Tuple{Int,Int}}(pairs)
end

function _overlap_candidate_set(src_names::AbstractVector, tgt_names::AbstractVector,
                                arrays::AbstractDict; eps::Real=0.0)
    return _overlap_candidate_set(_envelope_vectors(src_names, arrays),
                                  _envelope_vectors(tgt_names, arrays); eps=eps)
end
