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

# =========================================================================== #
# CANDIDATE-DRIVEN ENUMERATION (projection-pushdown Wall #1) — the SHARED
# driver policy behind BOTH overlap-gated enumeration paths.
#
# An overlap gate resolves its ENTIRE admissible pair set once. Enumerating the
# full cartesian product and membership-testing each tuple therefore does
# O(∏ranges) work to reach O(|candidates|) surviving tuples. Driving from the
# candidate set instead collapses the cost to O(|candidates|·∏ungated).
#
# The two consumers differ ONLY in loop shape, never in policy:
#
#   * the value-invention producer (`_vi_enumerate_join`, value_invention.jl)
#     enumerates ranges LAZILY (a ragged `of` bound depends on its parent
#     binding), so it recurses; BOTH gated symbols are contracted there.
#   * the dense aggregate expansion (`_foreach_aggregate_term`,
#     tree_walk/resolve.jl) unrolls `Iterators.product` over PRE-EXPANDED
#     iterators once per output cell, and the output cell has usually already
#     bound one of the two gated symbols.
#
# `_overlap_drive_plan` below is the one implementation of the decision both
# make: which symbol(s) the gate drives, and with which values. Everything a
# caller then does is bind those values and recurse/product as it always did.
#
# The driver is a PURE OPTIMISATION. Both callers still run the full membership
# test (`_join_admits` / `_vi_join_ok`) on every leaf, so a shape the planner
# declines to drive (`:none`) falls back to the untouched full product and the
# admitted leaf SET is identical either way.
# =========================================================================== #

# Instrumentation: number of leaf bindings an OVERLAP-GATED enumerator VISITED
# (a tuple its callback was invoked on / a product tuple its unroll entered).
# Reset by callers/tests; proves that an overlap-gated walk — the value-invention
# producer AND the dense aggregate expansion alike — visits
# O(|candidates|·∏ungated) tuples, NOT the full O(∏ranges) product
# (projection-pushdown Wall #1).
#
# Counted ONLY when an overlap gate is present, so every ungated / bin-equality
# expansion (the overwhelming majority, and the engine's hottest loop) keeps its
# exact current instruction stream.
const _VI_ENUM_VISITS = Ref{Int}(0)

const _NO_PARTNERS = Int[]

# The pairs of `oi` ascending by `(pos_src, pos_tgt)` — the deterministic
# PAIR-drive order. Built once, cached on the index.
function _overlap_sorted_pairs(oi::_OverlapIndex)
    oi.sorted === nothing && (oi.sorted = sort!(collect(oi.pairs)))
    return oi.sorted::Vector{Tuple{Int,Int}}
end

# `side == :l` ⇒ `pos_l ⇒ sorted pos_r`s; `side == :r` ⇒ `pos_r ⇒ sorted pos_l`s.
# Built once per side, cached on the index (see the `_OverlapIndex` note).
function _overlap_adjacency(oi::_OverlapIndex, side::Symbol)
    cached = side === :l ? oi.adj_l : oi.adj_r
    cached === nothing || return cached::Dict{Int,Vector{Int}}
    adj = Dict{Int,Vector{Int}}()
    for (pl, pr) in oi.pairs
        k, v = side === :l ? (pl, pr) : (pr, pl)
        push!(get!(() -> Int[], adj, k), v)
    end
    for v in values(adj)
        sort!(v)
    end
    side === :l ? (oi.adj_l = adj) : (oi.adj_r = adj)
    return adj
end

# The SORTED partner positions of `pos` on the side opposite `side`
# (`side` names the side `pos` itself lives on). Empty when `pos` has none.
_overlap_partners(oi::_OverlapIndex, side::Symbol, pos::Int) =
    get(_overlap_adjacency(oi, side), pos, _NO_PARTNERS)

# The first OVERLAP gate (the one carrying a prebuilt candidate index) among a
# resolved gate vector, or `nothing`. Shared by both enumeration paths: this is
# the gate whose candidates DRIVE enumeration. A bin-equality gate cannot drive
# (its admissible pair set is never materialised) and is left as a filter.
function _overlap_driver(gates)
    gates === nothing && return nothing
    for g in gates
        g.candidates === nothing || return g
    end
    return nothing
end

# `vals` restricted to `parts`, ASCENDING — or `nothing` when `vals` is not an
# ascending contiguous integer range and the restriction therefore cannot be
# proven to be the same SUBSEQUENCE the membership test would have admitted.
#
# Preserving the subsequence (not merely the set) is what makes the driven walk
# BIT-IDENTICAL to the filtered full product: the terms it drops are exactly the
# gate-rejected ones, in the same relative order, and each of those contributes
# the semiring identity. A shape this cannot prove returns `nothing`, and the
# caller falls back to the full product.
function _overlap_restrict(vals, parts::Vector{Int})
    isempty(parts) && return Int[]
    if vals isa AbstractUnitRange{<:Integer}
        return Int[Int(p) for p in parts if p in vals]
    elseif vals isa AbstractVector{<:Integer} && !isempty(vals)
        lo = Int(first(vals)); hi = Int(last(vals)); n = length(vals)
        n == hi - lo + 1 || return nothing          # stepped / permuted ⇒ decline
        out = Int[]
        for p in parts
            (lo <= p <= hi) || continue
            @inbounds Int(vals[p - lo + 1]) == p || return nothing   # not 1-strided
            push!(out, p)
        end
        return out
    end
    return nothing
end

# ---- the shared DRIVE PLAN -------------------------------------------------
#
# Decide how `gate` drives an enumeration whose FREE (still-to-be-enumerated)
# symbols are `free_syms` and whose already-bound symbols are `bound` (symbol ⇒
# position). Returns one of:
#
#   `(:none,)`                    — do not drive; walk the full product.
#   `(:reject,)`                  — both gated symbols are already bound and the
#                                   pair is not a candidate: NO leaf is admitted.
#   `(:pairs, sym_l, sym_r, ps)`  — both gated symbols are free: bind them from
#                                   the candidate pairs `ps`, product the rest.
#   `(:restrict, sym, vals)`      — one gated symbol is free and the other is
#                                   bound: the free one enumerates only `vals`.
#
# `valuesof(sym)` supplies a free symbol's full value range; it is consulted
# only for the `:restrict` shape (to prove the restriction is order-preserving).
function _overlap_drive_plan(gate, free_syms, bound, valuesof)
    gate === nothing && return (:none,)
    oi = gate.candidates
    oi === nothing && return (:none,)
    l = gate.sym_l; r = gate.sym_r
    lf = l in free_syms; rf = r in free_syms
    if lf && rf
        return (:pairs, l, r, _overlap_sorted_pairs(oi))
    elseif lf || rf
        free  = lf ? l : r
        fixed = lf ? r : l
        haskey(bound, fixed) || return (:none,)     # unbound ⇒ nothing to drive on
        parts = _overlap_partners(oi, lf ? :r : :l, Int(bound[fixed]))
        vals = _overlap_restrict(valuesof(free), parts)
        vals === nothing && return (:none,)
        return (:restrict, free, vals)
    else
        (haskey(bound, l) && haskey(bound, r)) || return (:none,)
        return (Int(bound[l]), Int(bound[r])) in oi ? (:none,) : (:reject,)
    end
end
