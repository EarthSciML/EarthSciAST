# ========================================================================
# tree_walk/access_kernel.jl — part of the tree-walk evaluator.
#
# The array-kernel IR. A vectorized array equation is evaluated as one or more
# `_AccKernel`s: a loop over an output cell SET, evaluating a spine (an op tree
# over `_Node`) once per cell, reading every input through an ACCESS
# DESCRIPTOR that resolves a slot or value at run time. A gather stores one
# descriptor, never a per-lane array, so the build is O(#structural groups),
# not O(#cells).
#
# A gather is affine in the cell index: the source slot is `out_lin(c) + Δ`
# for a Δ that is constant within a group (a periodic wrap only shifts Δ by
# ±N·stride). Groups are the wrap/region boxes (stencil_affine.jl). An array
# on its own (possibly reduced-rank) grid is read by the cell's multi-index
# through per-dim strides (the box-addressed kinds); a gather whose slot is
# not affine in the loop indices reads a per-box slot table.
#
# The spine reuses `_Node` (node.jl). The kinds below appear only in an access
# spine and are handled only by `_eval_acc` (the scalar `_eval_node` never
# sees them): `_NK_ACCESS` (a leaf; `idx` indexes the kernel's access table)
# and `_NK_AREDUCE`. Everything else is an ordinary
# `_NK_OP`/`_NK_LITERAL`.
#
# CELL COORDINATES. The evaluator threads, per output cell: `oln` the output
# linear slot (== the state grid's linear index, since state shares the output
# grid) and `midx` the cell's loop multi-index (i,j,k,…), used by the
# box-addressed descriptors and the loop-index leaf. `midx` has one entry per
# loop dim, padded with 1s to three; inside an affine reduction (`_NK_AREDUCE`)
# it also carries the reduction indices, at the dims after the output's.
# ========================================================================

# Access-spine kinds (disjoint from the scalar node kinds, node.jl).
const _NK_ACCESS = UInt8(20)   # gather/const via access descriptor (idx = table slot)
# Affine reduction: the ⊕-fold of a contraction whose contracted indices are
# extra loop dims of the kernel's box (stencil_affine.jl, `_AffineReduce`). The
# body (`children[1]`) is ONE access spine over the output AND the contracted
# indices, and this node walks the contracted ones at run time — so the kernel
# is the same size at every contraction length, where the unrolled fold it
# replaces holds one term per contracted index. `payload` is the `_AReduceSpec`
# (which `midx` dims to walk, over which ranges; the first dim fastest, the
# order the unroll enumerates its terms in), `op` the ⊕ and `literal` its 0̄
# seed. The fold is sequential from the seed, `s = s ⊕ body` in that order, so
# it is the unrolled fold's arithmetic exactly.
const _NK_AREDUCE = UInt8(23)

struct _AReduceSpec
    dims::Vector{Int}                # `midx` positions of the contracted indices
    ranges::Vector{UnitRange{Int}}   # their ranges, aligned with `dims`
end

# ---- Access descriptors: how one leaf resolves to a value at a cell ----
#
# ONE CONCRETE TAGGED STRUCT, not an abstract-type hierarchy. A per-kernel
# descriptor TABLE is a `Vector{_AccDesc}`; if the element type were abstract,
# every `_fetch(table[i], …)` would be a DYNAMIC DISPATCH on the boxed subtype,
# which infers as `Any`, boxes each gathered value, and allocates O(#access-nodes
# × #cells) per RHS call. A concrete struct dispatched by a `kind::UInt8` tag
# makes `_fetch` a branch ladder with concrete field reads: no dynamic dispatch,
# no boxing, zero allocation at `Float64`, and a small `Union{Float64,eltype(u)}`
# result under AD that the operators promote — exactly `_eval_node`'s
# discipline. Fields are shared across kinds (an `Int` slot serves
# `delta`/`idx`/… as the kind dictates), the way `_Node` shares `payload`/`idx`.
const _AK_STATE_AFFINE = UInt8(1)  # u[oln + delta]              (Cartesian stencil workhorse)
const _AK_CONST_BOX = UInt8(2)     # arr[off + Σ(midx_d-1)·s_d]  (const on its own reduced-rank grid)
const _AK_STATE_FIXED = UInt8(3)   # u[idx]                      (invariant pinned state slot)
const _AK_LOOP_IDX = UInt8(4)      # Float64(midx[dim])          (loop index as a value)
const _AK_ARR_FIXED = UInt8(5)     # arr[idx]                    (invariant forcing gather)
const _AK_FORCING_BOX = UInt8(6)   # flat[off + Σ(midx_d-1)·s_d] (LIVE forcing on its own grid)
# State gather over a Cartesian box through a per-box SLOT TABLE addressed by
# the cell multi-index (`conn[off + Σ(midx_d-1)·s_d]`, box-local dense
# layout), holding the state slot each cell reads — or 0 for a ghost, which
# fetches the ghost literal 0.0. Emitted by the box processor when a state
# lane's slot is NOT an affine function of the loop indices (a gather indirect
# through a connectivity const, a boundary-fold pattern past the Δ-cut cap):
# the table entries are `_eval_recipe`'s per-cell outputs, so a fetch is
# bit-identical to the per-cell resolve.
const _AK_STATE_TBL_BOX = UInt8(7) # u[conn[off + Σ(midx_d-1)·s_d]] (0 ⇒ ghost 0.0)
# A Float64 buffer read through an Int index table, box-addressed. The per-cell
# merge (acc_merge.jl) emits it for a LIVE forcing gather whose linear offset
# varies per cell (`_NK_PARAM_GATHER` lanes): `arr` is the aliased
# `_PGatherArray.flat` buffer — refreshed in place, so the read must stay live,
# which is why the VALUES are never materialized the way a const lane's are.
const _AK_ARR_TBL_BOX = UInt8(8)   # arr[conn[off + Σ(midx_d-1)·s_d]] (LIVE forcing table)

# What each descriptor kind reads and how it is addressed, indexed by the tag.
# The kind lists the passes test (which kinds are box-addressed, cell-invariant,
# lockstep-mergeable, a state / forcing / const family) are derived from these
# two columns, so a new kind is one row plus the ladders that compute with it.
#   source: :state (the ODE state), :const (a frozen array), :forcing (a live
#           buffer, read as it is at the call), :loop (the loop index itself)
#   addr:   :affine (output slot + delta), :box (strided box address),
#           :table (an index table read at a box address), :fixed (one slot),
#           :loop (a loop index)
const _AK_INFO = (
    (source = :state, addr = :affine),   # 1 STATE_AFFINE
    (source = :const, addr = :box),      # 2 CONST_BOX
    (source = :state, addr = :fixed),    # 3 STATE_FIXED
    (source = :loop, addr = :loop),      # 4 LOOP_IDX
    (source = :forcing, addr = :fixed),  # 5 ARR_FIXED
    (source = :forcing, addr = :box),    # 6 FORCING_BOX
    (source = :state, addr = :table),    # 7 STATE_TBL_BOX
    (source = :forcing, addr = :table),  # 8 ARR_TBL_BOX
)
length(_AK_INFO) == _AK_ARR_TBL_BOX ||
    error("access_kernel: _AK_INFO has $(length(_AK_INFO)) rows for $(Int(_AK_ARR_TBL_BOX)) descriptor kinds")
_ak_source(k::UInt8) = _AK_INFO[k].source
_ak_addr(k::UInt8) = _AK_INFO[k].addr
# Addressed through `s1`/`s2`/`s3`/`off` (and `sx` past rank 3).
_ak_box_addressed(k::UInt8) = (a = _ak_addr(k); a === :box || a === :table)

struct _AccDesc
    kind::UInt8
    arr::Vector{Float64}   # CONST_BOX, ARR_FIXED, FORCING_BOX, ARR_TBL_BOX (empty sentinel otherwise)
    conn::Union{Vector{Int}, UnitRange{Int}}  # *_TBL_BOX (empty sentinel otherwise);
    # a range is an identity table (`_state_slot_identity`)
    delta::Int             # STATE_AFFINE
    idx::Int               # STATE_FIXED, ARR_FIXED
    dim::Int               # LOOP_IDX
    s1::Int                # box-addressed kinds: per-dim strides + offset
    s2::Int
    s3::Int
    off::Int
    # Box strides of loop dims 4, 5, … (empty for a box of rank ≤ 3, which is
    # every box but a rank-4+ grid or a contraction's reduction dims past the
    # third). Kept apart from s1..s3 so the rank ≤ 3 descriptor, its fetch and
    # its emitted address need no loop.
    sx::Vector{Int}
end

const _AK_NO_ARR = Float64[]
const _AK_NO_CONN = Int[]

@inline _mkacc(
    kind::UInt8; arr::Vector{Float64} = _AK_NO_ARR,
    conn::Union{Vector{Int}, UnitRange{Int}} = _AK_NO_CONN,
    delta::Int = 0, idx::Int = 0, dim::Int = 0,
    s1::Int = 0, s2::Int = 0, s3::Int = 0, off::Int = 0,
    sx::Vector{Int} = _AK_NO_CONN
) =
    _AccDesc(kind, arr, conn, delta, idx, dim, s1, s2, s3, off, sx)

# A box-addressed descriptor's per-dim strides, any rank: the first three go to
# s1..s3 (zero-padded) and the rest to `sx`.
@inline _box_s(s::AbstractVector{Int}, d::Int) = d <= length(s) ? s[d] : 0
_box_sx(s::AbstractVector{Int}) =
    length(s) > 3 ? _as_type(Vector{Int}, _dynamic(getindex, s, 4:length(s))) : _AK_NO_CONN

# Named constructors, one per kind.
_AccStateAffine(delta::Int) = _mkacc(_AK_STATE_AFFINE; delta = delta)
_AccConstBox(arr::Vector{Float64}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_CONST_BOX; arr = arr, s1 = s1, s2 = s2, s3 = s3, off = off)
_AccConstBox(arr::Vector{Float64}, s::AbstractVector{Int}, off::Int) =
    _mkacc(
    _AK_CONST_BOX; arr = arr, s1 = _box_s(s, 1), s2 = _box_s(s, 2), s3 = _box_s(s, 3),
    off = off, sx = _box_sx(s)
)
# LIVE forcing gather with a lane-affine flat index. Same addressing as CONST_BOX
# but `arr` MUST be the aliased `_PGatherArray.flat` buffer (a data-refresh mutates
# it in place, so a captured reference stays live) — never a copy. A distinct kind
# from CONST_BOX so an invariant/const-hoisting analysis can never freeze it.
_AccForcingBox(arr::Vector{Float64}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_FORCING_BOX; arr = arr, s1 = s1, s2 = s2, s3 = s3, off = off)
_AccForcingBox(arr::Vector{Float64}, s::AbstractVector{Int}, off::Int) =
    _mkacc(
    _AK_FORCING_BOX; arr = arr, s1 = _box_s(s, 1), s2 = _box_s(s, 2), s3 = _box_s(s, 3),
    off = off, sx = _box_sx(s)
)
_AccStateFixed(idx::Int) = _mkacc(_AK_STATE_FIXED; idx = idx)
_AccArrFixed(arr::Vector{Float64}, idx::Int) = _mkacc(_AK_ARR_FIXED; arr = arr, idx = idx)
_AccLoopIdx(dim::Int) = _mkacc(_AK_LOOP_IDX; dim = dim)
_AccStateTblBox(conn::Union{Vector{Int}, UnitRange{Int}}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_STATE_TBL_BOX; conn = conn, s1 = s1, s2 = s2, s3 = s3, off = off)
_AccStateTblBox(conn::Union{Vector{Int}, UnitRange{Int}}, s::AbstractVector{Int}, off::Int) =
    _mkacc(
    _AK_STATE_TBL_BOX; conn = conn, s1 = _box_s(s, 1), s2 = _box_s(s, 2),
    s3 = _box_s(s, 3), off = off, sx = _box_sx(s)
)
_AccArrTblBox(arr::Vector{Float64}, conn::Vector{Int}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_ARR_TBL_BOX; arr = arr, conn = conn, s1 = s1, s2 = s2, s3 = s3, off = off)
_AccArrTblBox(arr::Vector{Float64}, conn::Vector{Int}, s::AbstractVector{Int}, off::Int) =
    _mkacc(
    _AK_ARR_TBL_BOX; arr = arr, conn = conn, s1 = _box_s(s, 1), s2 = _box_s(s, 2),
    s3 = _box_s(s, 3), off = off, sx = _box_sx(s)
)

# A copy of `a` with its box address replaced (strides `s1..s3`/`sx`, offset
# `off`) and, for a loop-index read, its dim.
_acc_with_box(
    a::_AccDesc; dim::Int = a.dim, s1::Int = a.s1, s2::Int = a.s2,
    s3::Int = a.s3, off::Int = a.off, sx::Vector{Int} = a.sx, idx::Int = a.idx,
    conn::Union{Vector{Int}, UnitRange{Int}} = a.conn
) =
    _AccDesc(a.kind, a.arr, conn, a.delta, idx, dim, s1, s2, s3, off, sx)

# The box address `off + Σ_d (midx_d - 1)·s_d` of a box-addressed descriptor.
# `midx` carries one entry per loop dim (padded with 1s to three), so the `sx`
# terms read the dims past the third; at rank ≤ 3 `sx` is empty and this is the
# three-term sum.
@inline function _acc_boxaddr(a::_AccDesc, midx::Tuple{Vararg{Int}})
    x = a.off + (midx[1] - 1) * a.s1 + (midx[2] - 1) * a.s2 + (midx[3] - 1) * a.s3
    sx = a.sx
    @inbounds for d in eachindex(sx)
        x += (midx[d + 3] - 1) * sx[d]
    end
    return x
end

# One `_fetch`, dispatched by the kind tag — concrete field reads throughout, so
# no dynamic dispatch and no boxing. Hot Cartesian cases first. The result is
# `eltype(u)` for a state read and `Float64` for a const/forcing/loop-index read;
# a small `Union` the caller's operators promote (identical to `_eval_node`).
@inline function _fetch(a::_AccDesc, u, oln, midx)
    k = a.kind
    if k === _AK_STATE_AFFINE
        return @inbounds u[oln + a.delta]
    elseif k === _AK_CONST_BOX
        return @inbounds a.arr[_acc_boxaddr(a, midx)]
    elseif k === _AK_STATE_FIXED
        return @inbounds u[a.idx]
    elseif k === _AK_LOOP_IDX
        return Float64(midx[a.dim])
    elseif k === _AK_ARR_FIXED
        return @inbounds a.arr[a.idx]
    elseif k === _AK_FORCING_BOX
        return @inbounds a.arr[_acc_boxaddr(a, midx)]
    elseif k === _AK_STATE_TBL_BOX
        s = @inbounds a.conn[_acc_boxaddr(a, midx)]
        return s == 0 ? 0.0 : @inbounds u[s]     # 0 ⇒ ghost literal, as per cell
    elseif k === _AK_ARR_TBL_BOX
        return @inbounds a.arr[a.conn[_acc_boxaddr(a, midx)]]
    end
    throw(TreeWalkError("E_TREEWALK_ACC_BAD_DESC", "unknown access kind $(Int(k))"))
end

# ---- Output cell set ----
# A Cartesian BOX: `strides` are the state grid's per-loop-dim linear slot
# strides and `ranges[d]` is the box's index range in loop dim d. The output
# slot of cell (i₁,…,i_d) is the AFFINE map `base + Σ_d i_d·strides[d]`, walked
# with no stored per-lane out_slots. `base` and the strides come from the state
# layout. A box may restrict ANY subset of dims (longitude wrap in i, poles in
# j, vertical regions in k), so it is a general strided box, not a slab.
# LISTED SLOTS (`outs` non-empty): the per-cell merge (acc_merge.jl) hosts a
# group of arbitrary output slots — cell ordinal c ∈ 1:length(outs) writes
# `du[outs[c]]`, `midx == (c, 1, 1)`, and the box-addressed descriptors
# (CONST_BOX / STATE_TBL_BOX / ARR_TBL_BOX with s1=1, off=1) index their
# per-cell tables by that ordinal.
# `slab[d]` (a box, or empty for "none"): the box is one cell thick on dim d AT
# THE EDGE of the equation's range there — a boundary slab, which is one cell
# thick at every grid size. The codegen tier keeps that extent a literal (a
# one-cell box elsewhere, an interior that a small grid squeezes to one cell, is
# as wide as the grid lets it be, and stays run-time geometry).
struct _CellSet
    strides::Vector{Int}
    ranges::Vector{UnitRange{Int}}
    base::Int
    outs::Vector{Int}
    slab::Vector{Bool}
end
_CellSet(
    strides::Vector{Int}, ranges::Vector{UnitRange{Int}}, base::Int,
    outs::Vector{Int} = Int[]
) = _CellSet(strides, ranges, base, outs, Bool[])
@inline _cellset_slab(cs::_CellSet, d::Int) = d <= length(cs.slab) && cs.slab[d]
_outs_cells(outs::Vector{Int}) = _CellSet(Int[], UnitRange{Int}[1:length(outs)], 0, outs)
@inline _is_cellless(cs::_CellSet) = isempty(cs.strides) && isempty(cs.outs)
@inline _is_outs(cs::_CellSet) = !isempty(cs.outs)

# ---- Per-cell CSE scratch ----
# The spine is a DAG whose shared subtrees a per-cell walk would evaluate once
# per path. The CSE pass (`_build_acc_cse`) slices the shared subtrees into ORDERED recipes; the box
# loop evaluates each once per cell into this scratch, and every occurrence becomes
# an `_NK_CACHED` read. Two buffers (Float64 + a lazily-allocated `alt` for the
# Dual type ForwardDiff drives `f!` with), exactly like `_CSECache`, so it stays
# zero-alloc and differentiable; the buffer is reused across cells AND calls.
mutable struct _AccScratch
    f64::Vector{Float64}
    alt::Any
end
_AccScratch(n::Int) = _AccScratch(Vector{Float64}(undef, n), nothing)
@inline _acc_scratch_buf(s::_AccScratch, ::Type{Float64}) = s.f64
@inline function _acc_scratch_buf(s::_AccScratch, ::Type{T}) where {T}
    b = s.alt
    b isa Vector{T} && return b
    nb = Vector{T}(undef, length(s.f64))
    s.alt = nb
    return nb
end
@inline _acc_scratch_read(s::_AccScratch, i::Int, ::Type{Float64}) = @inbounds s.f64[i]
@inline _acc_scratch_read(s::_AccScratch, i::Int, ::Type{T}) where {T} =
    @inbounds (s.alt::Vector{T})[i]

# Two recipe/scratch pairs (each ordered so recipe[i] reads only lower slots):
#   * `recipes`/`scratch`         — per-CELL CSE: shared cell-varying subtrees,
#                                    filled once per cell in the box loop.
#   * `inv_recipes`/`inv_scratch` — loop-INVARIANT hoist: subtrees with no
#                                    cell-varying access, filled ONCE per call
#                                    before the box loop (an Arrhenius `exp(-Ea/T)`,
#                                    `g/h`, `sin(2t)`, a fixed-slot `s*s`).
# A per-cell recipe may read an invariant slot (already filled); an invariant
# recipe reads only lower invariant slots. Empty pair ⇒ that tier is absent.
struct _AccCSE
    recipes::Vector{_Node}
    scratch::_AccScratch
    inv_recipes::Vector{_Node}
    inv_scratch::_AccScratch
end
const _ACC_NO_CSE = _AccCSE(_Node[], _AccScratch(0), _Node[], _AccScratch(0))
@inline _has_cse(cse::_AccCSE) = !isempty(cse.recipes)
@inline _has_inv(cse::_AccCSE) = !isempty(cse.inv_recipes)

# ---- One kernel ----
struct _AccKernel
    cells::_CellSet
    spine::_Node               # op tree with _NK_ACCESS / _NK_CACHED leaves
    acc::Vector{_AccDesc}      # descriptor table (spine `_NK_ACCESS.idx` indexes this)
    cse::_AccCSE               # per-cell common-subexpression recipes + scratch
end
# A kernel with no CSE (tests and direct construction).
_AccKernel(cells::_CellSet, spine::_Node, acc::Vector{_AccDesc}) =
    _AccKernel(cells, spine, acc, _ACC_NO_CSE)

# ---- The evaluator ----
# ELTYPE-GENERIC in the value type `T`, exactly as the scalar `_eval_node`
# (scalar_walk.jl) is, and for the same reason: the in-place `f!` must DIFFERENTIATE
# through these kernels (ForwardDiff over state OR over parameters), not just
# integrate them. `T` is threaded and passed down but leaves are NEVER converted
# to it — the type flows naturally from the leaves (a state read yields
# `eltype(u)`, a const/literal yields `Float64`) and promotes at the operators.
# That duck-typing is load-bearing: it is what keeps a LITERAL `^` exponent a
# `Float64` (the power rule under a Dual walk), and it makes the `T === Float64`
# path the plain Float64 walk. Matches `_eval_node`'s discipline arm for arm —
# the differential + AD tests pin it.
#
# `t` current time, `oln` output slot, `midx` the cell's (i,j,k) loop
# multi-index (padded with 1s). The 7-arg form derives `T` from the runtime
# inputs (the build-time / test entry point), mirroring `_eval_node`'s 4-arg
# convenience form.
@inline _eval_acc(
    nd::_Node, u, p, t, oln::Int, midx::Tuple{Vararg{Int}}, K::_AccKernel
) =
    _eval_acc(nd, u, p, t, oln, midx, K, _rhs_value_type(u, p, t))

function _eval_acc(
        nd::_Node, u, p, t, oln::Int,
        midx::Tuple{Vararg{Int}}, K::_AccKernel, ::Type{T}
    ) where {T}
    k = nd.kind
    if k === _NK_ACCESS
        return _fetch(K.acc[nd.idx], u, oln, midx)
    elseif k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_AREDUCE
        return _eval_acc_areduce(nd, u, p, t, oln, midx, K, T)
    elseif k === _NK_CONTRACTION
        # Fixed-width runtime ⊕-fold (the per-cell merge hosts einsum groups on
        # the access spine). MIRRORS `_eval_contraction` (scalar_walk.jl) arm for
        # arm — seeded from the 0̄ identity on the node, sequential child-order
        # fold — so the value is bit-identical to the per-cell reference.
        return _eval_acc_contraction(nd, u, p, t, oln, midx, K, T)
    elseif k === _NK_PARAM
        return _read_param(p, nd.sym, nd.idx)
    elseif k === _NK_TIME
        return t
    elseif k === _NK_CACHED
        # A CSE reference: the value was computed once for THIS cell by the box
        # loop's `cse.recipes` fill into the per-cell scratch captured in
        # `payload` — or, for an inv-tier def the cross-kernel sharing pass
        # (xcse.jl) rewrote, once per CALL into the SCALAR prelude's
        # `_CSECache` (filled by `_make_rhs` before any kernel runs). The `isa`
        # split keeps both reads monomorphic; kernels a build never rewrites
        # only ever see the `_AccScratch` branch.
        pl = nd.payload
        pl isa _AccScratch && return _acc_scratch_read(pl, nd.idx, T)
        return _cse_read(pl::_CSECache, nd.idx, T)
    elseif k === _NK_OP
        return _eval_acc_op(nd, u, p, t, oln, midx, K, T)
    elseif k === _NK_CALL
        # A template call: its arguments in this kernel's cell context, its
        # body (a pure function of them) by the scalar walker.
        return _run_call(c -> _eval_acc(c, u, p, t, oln, midx, K, T), nd, u, p, t, T)
    end
    return _unknown_kind(nd, "the access-kernel walker")
end

# The affine reduction's fold (`_NK_AREDUCE`): `midx` is widened to cover the
# contracted dims, which the nest below binds, the last dim outermost.
function _eval_acc_areduce(
        nd::_Node, u, p, t, oln::Int,
        midx::Tuple{Vararg{Int}}, K::_AccKernel, ::Type{T}
    ) where {T}
    spec = nd.payload::_AReduceSpec
    m = max(length(midx), maximum(spec.dims))
    mi = ntuple(i -> i <= length(midx) ? midx[i] : 1, m)
    return _areduce_fold(
        nd.children[1], spec, length(spec.dims), nd.literal, nd.op,
        u, p, t, oln, mi, K, T
    )
end

function _areduce_fold(
        body::_Node, spec::_AReduceSpec, r::Int, s, op::Symbol,
        u, p, t, oln::Int, midx::Tuple{Vararg{Int}},
        K::_AccKernel, ::Type{T}
    ) where {T}
    d = spec.dims[r]
    for j in spec.ranges[r]
        mi = Base.setindex(midx, j, d)
        if r == 1
            v = _eval_acc(body, u, p, t, oln, mi, K, T)
            s = _oplus_numeric(op, s, v)
        else
            s = _areduce_fold(body, spec, r - 1, s, op, u, p, t, oln, mi, K, T)
        end
    end
    return s
end

# Runtime ⊕-fold over an access-spine contraction node's children, seeded from
# `nd.literal` (the 0̄ identity baked on at build time) — byte-for-byte the
# `_eval_contraction` (scalar_walk.jl) fold shape, with `_eval_acc` as the child
# walker.
function _eval_acc_contraction(
        nd::_Node, u, p, t, oln::Int,
        midx::Tuple{Vararg{Int}}, K::_AccKernel, ::Type{T}
    ) where {T}
    op = nd.op
    ch = nd.children
    if op === :+
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s += _eval_acc(ch[k], u, p, t, oln, midx, K, T)
        end
        return s
    elseif op === :*
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s *= _eval_acc(ch[k], u, p, t, oln, midx, K, T)
        end
        return s
    elseif op === :max
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s = max(s, _eval_acc(ch[k], u, p, t, oln, midx, K, T))
        end
        return s
    elseif op === :or
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s = _or_combine(s, _eval_acc(ch[k], u, p, t, oln, midx, K, T))
        end
        return s
    elseif op === :min
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s = min(s, _eval_acc(ch[k], u, p, t, oln, midx, K, T))
        end
        return s
    end
    return _throw_unknown_reducer(op)
end

# Op application over an access spine: the same generated ladder as
# `_eval_node_op` (`_op_ladder`, tree_walk/op_ladder.jl), so the affine path is
# bit-identical to the per-cell path, whose spine is the SAME compiled `_Node`
# tree. The only difference is the operand recursion (`_eval_acc`, which resolves
# `_NK_ACCESS`).
@eval function _eval_acc_op(
        nd::_Node, u, p, t, oln::Int,
        midx::Tuple{Vararg{Int}}, K::_AccKernel, ::Type{T}
    ) where {T}
    op = nd.op
    ch = nd.children
    $(
        _op_ladder(
            i -> :(_eval_acc(ch[$i], u, p, t, oln, midx, K, T)), :(length(ch)),
            :(throw(TreeWalkError("E_TREEWALK_ACC_UNSUPPORTED_OP", String(op))))
        )
    )
end

# One cell's output value: fill the per-cell CSE scratch (each shared subtree
# evaluated ONCE), then evaluate the output spine, whose `_NK_CACHED` leaves read
# the scratch. With no CSE (`_has_cse` false) this is exactly the bare spine walk.
@inline function _eval_cell(
        K::_AccKernel, u, p, t, oln::Int,
        midx::Tuple{Vararg{Int}}, ::Type{T}
    ) where {T}
    cse = K.cse
    if _has_cse(cse)
        buf = _acc_scratch_buf(cse.scratch, T)
        rs = cse.recipes
        @inbounds for i in eachindex(rs)
            buf[i] = _eval_acc(rs[i], u, p, t, oln, midx, K, T)
        end
    end
    return _eval_acc(K.spine, u, p, t, oln, midx, K, T)
end

# ---- Run one kernel into du (in place) ----
# `T` is the value type (`_rhs_value_type(u, p, t)`); a compile-time constant at
# the call site, so at `T === Float64` every `_eval_acc` below is the monomorphic
# Float64 walk it always was, and under AD the SAME loop evaluates in `Dual`. The
# 5-arg form derives `T` (test / standalone entry point).
_run_acc_kernel!(du, u, p, t, K::_AccKernel) =
    _run_acc_kernel!(du, u, p, t, K, _rhs_value_type(u, p, t))

# Fill the loop-invariant scratch ONCE per call (before the cell loop). The recipes
# have no cell-varying access, so the cell context is irrelevant — dummy `(1,
# (1,1,1))` is passed. A no-op (compiles away) when the kernel has no invariants.
@inline function _fill_invariant!(K::_AccKernel, u, p, t, ::Type{T}) where {T}
    cse = K.cse
    if _has_inv(cse)
        buf = _acc_scratch_buf(cse.inv_scratch, T)
        rs = cse.inv_recipes
        @inbounds for i in eachindex(rs)
            buf[i] = _eval_acc(rs[i], u, p, t, 1, (1, 1, 1), K, T)
        end
    end
    return nothing
end

function _run_acc_kernel!(du, u, p, t, K::_AccKernel, ::Type{T}) where {T}
    _fill_invariant!(K, u, p, t, T)
    cs = K.cells
    if _is_outs(cs)                                 # listed out slots (per-cell merge)
        outs = cs.outs
        @inbounds for c in eachindex(outs)
            oln = outs[c]
            du[oln] = _eval_cell(K, u, p, t, oln, (c, 1, 1), T)
        end
    elseif !_is_cellless(cs)                        # strided box walk
        _run_box_kernel!(du, u, p, t, K, cs, T)
    end
    return du
end

# Nested loop over a Cartesian box; rank ≤ 3 is unrolled for a tight `oln`,
# with a product-based loop for higher rank, whose multi-index carries every
# loop dim (the rank ≤ 3 forms pad theirs to three with 1s).
function _run_box_kernel!(du, u, p, t, K::_AccKernel, cs::_CellSet, ::Type{T}) where {T}
    st = cs.strides
    rg = cs.ranges
    b = cs.base
    nd = length(st)
    if nd == 1
        s1 = st[1]
        @inbounds for i in rg[1]
            oln = b + i * s1
            du[oln] = _eval_cell(K, u, p, t, oln, (i, 1, 1), T)
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            oln = b + i * s1 + j * s2
            du[oln] = _eval_cell(K, u, p, t, oln, (i, j, 1), T)
        end
    elseif nd == 3
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            oln = b + i * s1 + j * s2 + k * s3
            du[oln] = _eval_cell(K, u, p, t, oln, (i, j, k), T)
        end
    else
        @inbounds for idxs in Iterators.product(rg...)
            oln = b
            for d in 1:nd
                oln += idxs[d] * st[d]
            end
            du[oln] = _eval_cell(K, u, p, t, oln, Tuple(idxs), T)
        end
    end
    return du
end

# ---- Per-cell CSE builder ----
# Value-number the access spine structurally; any OP subtree that occurs ≥2 times
# is sliced into an ordered recipe list and every occurrence replaced by an
# `_NK_CACHED` read of a per-cell scratch slot. Bit-identity is automatic: the SAME
# subexpression is computed with the SAME inputs, just once instead of many times.
# Recipes are emitted in ascending value-number order, and a child's value number
# is always < its parent's (post-order numbering), so a recipe only ever reads
# LOWER slots — the box loop fills them front-to-back. A spine with an `_NK_AREDUCE` keeps only the
# loop-invariant tier: its body reads the contracted dims of `midx`, which the
# per-cell prelude does not bind, but an invariant subtree reads no dim at all.
# Structural key: two nodes share a value number iff their keys are equal. ACCESS
# keys on descriptor CONTENT (`_desc_key`); an OP with a payload keys it on
# identity.
function _acc_vn_key(n::_Node, childvns::Vector{Int}, acc::Vector{_AccDesc})
    k = n.kind
    k === _NK_ACCESS  && return (0x01, _desc_key(acc[n.idx]))
    k === _NK_LITERAL && return (0x02, reinterpret(UInt64, n.literal))
    k === _NK_PARAM   && return (0x03, n.sym)
    k === _NK_TIME    && return (0x04, :t)
    k === _NK_OP      && return (
        0x05, n.op,
        n.payload === nothing ? UInt(0) : objectid(n.payload),
        childvns,
    )
    # A template call is a pure function of its arguments (call.jl).
    k === _NK_CALL    && return (0x06, objectid(n.payload), childvns)
    return (0xff, objectid(n))     # _NK_CACHED / anything else — never merged
end

# A descriptor read is CELL-INVARIANT (same for every cell in the box, though it
# may vary per call) iff it is a fixed state slot or a fixed forcing read.
# Every other kind is addressed by the cell.
@inline _acc_desc_invariant(k::UInt8) = _ak_addr(k) === :fixed

# A value-number key (`_acc_vn_key`) with its hash, compared type first. The
# keys are tuples of several types; in a `Dict{Any}` two keys whose hashes share
# a slot are compared with `isequal` on whatever pair of types they have, a
# method compiled on first use. Which pairs meet depends on the hash values, so
# on the document's sizes. Here keys of different types are unequal without a
# call (no key equals one of another type: the leading tag and the payload
# types keep the kinds apart), and `isequal` runs only on full-hash matches of
# one type.
struct _VNKey
    k::Any
    h::UInt
end
_VNKey(k) = _VNKey(k, hash(k))
Base.hash(x::_VNKey, h::UInt) = hash(x.h, h)
Base.isequal(a::_VNKey, b::_VNKey) =
    a.h == b.h && typeof(a.k) === typeof(b.k) && isequal(a.k, b.k)

# The value number of structural key `key` in `tab`: the one it already has, or
# the next free one (numbers are dense, in first-seen order). The one numbering
# of the structural passes here and in the emitters (`_cg_share_key!`,
# array_contraction.jl).
@inline _vn!(tab::Dict{_VNKey, Int}, key) = get!(tab, _VNKey(key), length(tab) + 1)

function _build_acc_cse(spine::_Node, acc::Vector{_AccDesc})
    # Every node reachable from the spine, once each (see the dense-position
    # note below).
    order, pos_of = _dag_postorder(spine, _dag_children, _dag_every)
    inv_only = _anyof(n -> n.kind === _NK_AREDUCE, order)
    key_to_vn = Dict{_VNKey, Int}()
    counts = Int[]; is_op = Bool[]; is_inv = Bool[]; rep = _Node[]
    # Occurrence counting must stay PER PATH (a value occurring on ≥2 paths is
    # exactly what earns a CSE slot — collapsing to distinct-node visits would
    # change slot decisions on shared spines), but the spine is a DAG whose
    # per-path recursion was exponential. Mirror `_cse_count!`
    # (scalar_cse.jl): number each UNIQUE node once in identity-deduped postorder
    # (a child's vn stays < its parent's, preserving the dependency-order
    # invariant the recipe tiers rely on), then propagate saturating path
    # multiplicities parent→child in reverse postorder and tally each unique
    # node's multiplicity into its value number — identical totals to the full
    # path enumeration, O(nodes + edges).
    #
    # DENSE-POSITION KEYING (perf): number every UNIQUE node with a dense
    # postorder position `pos_of[n] ∈ 1:P` (ONE identity dict, built once, by the
    # shared `_dag_postorder`), so the value-number, path-multiplicity, and
    # rewrite passes below index plain `Vector`s by position instead of hashing
    # each freshly-lowered `_Node` through a SEPARATE `IdDict` per pass —
    # `IdDict` get/set over these spines was the build's top self-time.
    P = length(order)
    vn_by_pos = Vector{Int}(undef, P)
    for (p, n) in enumerate(order)    # postorder ⇒ children already numbered
        childvns = Int[vn_by_pos[pos_of[c]] for c in n.children]
        vn = _vn!(key_to_vn, _acc_vn_key(n, childvns, acc))
        if vn > length(counts)
            k = n.kind
            inv = k === _NK_LITERAL || k === _NK_PARAM || k === _NK_TIME ? true :
                k === _NK_ACCESS ? _acc_desc_invariant(acc[n.idx].kind) :
                (k === _NK_OP || k === _NK_CALL) ? all(v -> is_inv[v], childvns) :
                false
            push!(counts, 0); push!(is_op, k === _NK_OP || k === _NK_CALL)
            push!(is_inv, inv); push!(rep, n)
        end
        vn_by_pos[p] = vn
    end
    # Both tiers' recipes run unconditionally (the invariant tier once per call,
    # the cell tier once per cell), while `ifelse`/`and`/`or` evaluate their
    # guarded operands lazily. So only a value with at least one occurrence
    # outside a guarded operand (`_cg_lazy_operand`) may take a slot: hoisting
    # one that occurs only under a guard would evaluate what the lazy walk skips
    # (a guarded `log` or `sqrt` raising outside its domain).
    mult_by_pos, uncond_by_pos =
        _dag_path_counts(order, pos_of, _dag_children, _dag_every, _cg_lazy_operand)
    uncond = zeros(Int, length(counts))
    for p in 1:P
        counts[vn_by_pos[p]] = _sat_add(counts[vn_by_pos[p]], mult_by_pos[p])
        uncond[vn_by_pos[p]] = _sat_add(uncond[vn_by_pos[p]], uncond_by_pos[p])
    end
    # Two-tier slot assignment, in value-number order (a child's vn is always below
    # its parent's, so each tier's recipes end up dependency-ordered): every
    # invariant OP is hoisted to a per-call slot (once per call beats once per
    # cell); every remaining SHARED cell-varying OP gets a per-cell CSE slot.
    inv_slot = Dict{Int, Int}(); cell_slot = Dict{Int, Int}()
    for vn in 1:length(counts)
        (is_op[vn] && uncond[vn] >= 1) || continue
        if is_inv[vn]
            inv_slot[vn] = length(inv_slot) + 1
        elseif counts[vn] >= 2 && !inv_only
            cell_slot[vn] = length(cell_slot) + 1
        end
    end
    (isempty(inv_slot) && isempty(cell_slot)) && return (spine, _ACC_NO_CSE)
    inv_scratch = _AccScratch(length(inv_slot))
    cell_scratch = _AccScratch(length(cell_slot))
    # Identity-memoized rewrite: `rw`'s output depends only on the node (its vn
    # and rewritten children), so a shared input node maps to ONE shared output
    # node — without the memo the per-path rebuild re-inflated a shared spine
    # into an exponentially large tree. Values are unchanged: the
    # runner evaluates the same ops on the same inputs either way.
    rw_cache = Vector{Union{Nothing, _Node}}(nothing, P)
    function rw(n::_Node)
        p = pos_of[n]
        cached = rw_cache[p]
        cached === nothing || return cached
        vn = vn_by_pos[p]
        s = get(inv_slot, vn, 0)
        result = if s != 0
            _mknode(kind = _NK_CACHED, idx = s, payload = inv_scratch)
        else
            s = get(cell_slot, vn, 0)
            if s != 0
                _mknode(kind = _NK_CACHED, idx = s, payload = cell_scratch)
            elseif isempty(n.children)
                n
            else
                _mknode(
                    kind = n.kind, op = n.op, literal = n.literal, idx = n.idx,
                    sym = n.sym, payload = n.payload,
                    children = _Node[rw(c) for c in n.children]
                )
            end
        end
        rw_cache[p] = result
        return result
    end
    _recipe(vn) = (
        r = rep[vn];
        _mknode(
            kind = r.kind, op = r.op, literal = r.literal, idx = r.idx, sym = r.sym,
            payload = r.payload, children = _Node[rw(c) for c in r.children]
        )
    )
    inv_recipes = Vector{_Node}(undef, length(inv_slot))
    for (vn, s) in inv_slot
        inv_recipes[s] = _recipe(vn)
    end
    cell_recipes = Vector{_Node}(undef, length(cell_slot))
    for (vn, s) in cell_slot
        cell_recipes[s] = _recipe(vn)
    end
    return (rw(spine), _AccCSE(cell_recipes, cell_scratch, inv_recipes, inv_scratch))
end

# ---- Small builders (used by tests) ----
_acc(id::Int) = _mknode(kind = _NK_ACCESS, idx = id)
_aop(op::Symbol, kids::_Node...) = _mknode(kind = _NK_OP, op = op, children = collect(_Node, kids))
_alit(v::Real) = _mknode(kind = _NK_LITERAL, literal = Float64(v))

# Total cells in a cell set, in the runners' own enumeration.
function _cellset_ncells(cs::_CellSet)
    _is_outs(cs) && return length(cs.outs)
    _is_cellless(cs) && return 0
    n = 1
    for r in cs.ranges
        n *= length(r)
    end
    return n
end

"""
    _cellsets_outs_unique(css) -> Bool

Whether every output slot of the cell sets `css`, taken together, is distinct
(what `allunique` over the concatenation of their slot lists says, without
the lists). Boxes that share one affine slot map (`base`, `strides`) and whose
map is one-to-one on their joint hull collide exactly when their index boxes
overlap, which is checked box against box; separate maps whose slot hulls do
not overlap cannot collide. Anything else (an `outs` list, overlapping hulls)
is decided exactly on a bit map of the slot range.
"""
function _cellsets_outs_unique(css)
    boxes = Tuple{Int, Vector{Int}, Vector{UnitRange{Int}}}[]
    lists = Vector{Int}[]
    for cs in css
        if _is_outs(cs)
            push!(lists, cs.outs)
        elseif !_is_cellless(cs)
            any(isempty, cs.ranges) || push!(boxes, (cs.base, cs.strides, cs.ranges))
        end
    end
    if isempty(lists)
        r = _boxes_outs_unique(boxes)
        r === nothing || return r
    end
    return _outs_unique_bitmap(boxes, lists)
end

# The slot hull `[lo, hi]` of `base + Σ_d i_d·strides[d]` over the box `ranges`.
function _box_slot_hull(base::Int, strides::Vector{Int}, ranges)
    lo = hi = base
    @inbounds for d in eachindex(strides)
        a = first(ranges[d]) * strides[d]
        b = last(ranges[d]) * strides[d]
        lo += min(a, b)
        hi += max(a, b)
    end
    return lo, hi
end

# Is `i ↦ Σ_d i_d·strides[d]` one-to-one on the box `ranges`? Sufficient test:
# ordered by |stride|, each stride exceeds the largest offset the smaller ones
# can reach (a mixed radix). `false` means "not shown", not "collides".
function _affine_injective_on(strides::Vector{Int}, ranges)
    dims = [d for d in eachindex(strides) if length(ranges[d]) > 1]
    any(d -> strides[d] == 0, dims) && return false
    sort!(dims; by = d -> abs(strides[d]))
    reach = 0
    for d in dims
        abs(strides[d]) > reach || return false
        reach += abs(strides[d]) * (length(ranges[d]) - 1)
    end
    return true
end

# `true`/`false` when box arithmetic decides it, `nothing` when it cannot.
function _boxes_outs_unique(boxes)
    groups = Dict{Tuple{Int, Vector{Int}}, Vector{Int}}()
    for (k, (b, st, _)) in enumerate(boxes)
        push!(get!(groups, (b, st), Int[]), k)
    end
    hulls = Tuple{Int, Int}[]
    for ((b, st), ks) in groups
        length(ks) > 4096 && return nothing
        nd = length(st)
        hull = UnitRange{Int}[boxes[ks[1]][3][d] for d in 1:nd]
        for k in ks
            rg = boxes[k][3]
            length(rg) == nd || return nothing
            for d in 1:nd
                hull[d] = min(first(hull[d]), first(rg[d])):max(last(hull[d]), last(rg[d]))
            end
        end
        _affine_injective_on(st, hull) || return nothing
        for x in 1:length(ks), y in (x + 1):length(ks)
            rx = boxes[ks[x]][3]; ry = boxes[ks[y]][3]
            all(d -> first(rx[d]) <= last(ry[d]) && first(ry[d]) <= last(rx[d]), 1:nd) &&
                return false
        end
        push!(hulls, _box_slot_hull(b, st, hull))
    end
    sort!(hulls)
    for k in 2:length(hulls)
        hulls[k][1] <= hulls[k - 1][2] && return nothing
    end
    return true
end

# The exact test: one bit per slot of the joint slot range.
function _outs_unique_bitmap(boxes, lists)
    lo, hi = typemax(Int), typemin(Int)
    for (b, st, rg) in boxes
        l, h = _box_slot_hull(b, st, rg)
        lo = min(lo, l); hi = max(hi, h)
    end
    for outs in lists, o in outs
        lo = min(lo, o); hi = max(hi, o)
    end
    lo > hi && return true
    seen = falses(hi - lo + 1)
    for (b, st, rg) in boxes
        _mark_box_slots!(
            seen, lo, b, ntuple(d -> st[d], length(st)),
            ntuple(d -> rg[d], length(rg))
        ) || return false
    end
    for outs in lists
        _mark_list_slots!(seen, lo, outs) || return false
    end
    return true
end

function _mark_box_slots!(
        seen::BitVector, lo::Int, b::Int, st::NTuple{N, Int},
        rg::NTuple{N, UnitRange{Int}}
    ) where {N}
    for I in CartesianIndices(rg)
        o = b
        @inbounds for d in 1:N
            o += I[d] * st[d]
        end
        k = o - lo + 1
        @inbounds seen[k] && return false
        @inbounds seen[k] = true
    end
    return true
end

function _mark_list_slots!(seen::BitVector, lo::Int, outs::Vector{Int})
    @inbounds for o in outs
        k = o - lo + 1
        seen[k] && return false
        seen[k] = true
    end
    return true
end
