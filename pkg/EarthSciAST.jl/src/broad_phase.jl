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
