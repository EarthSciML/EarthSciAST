# ========================================================================
# tree_walk/access_kernel.jl — part of the tree-walk evaluator.
#
# The UNIFIED array-kernel IR (ess-affine). A vectorized array equation is
# evaluated as one or more `_AccKernel`s: a parallel loop over an output cell
# SET, evaluating a spine (an op tree over `_Node`) once per cell, reading every
# input through an ACCESS DESCRIPTOR that resolves a slot/value AT RUNTIME.
#
# WHY THIS EXISTS. The previous array paths materialised a per-lane slot vector
# for every gather (and, in the symbolic-stencil path, re-stencilised the whole
# rule body once per structural "branch"). Both are O(#cells): a 1e6-cell mesh
# builds 1e6-long vectors, and the monotone-PPM rule — whose lowered body is a
# ~160k-node DAG — took tens of minutes because ~343 branches each re-walked it.
# Here the BUILD is O(#structural groups): a gather stores ONE descriptor, never
# a per-lane array, and the runtime computes the slot on the fly. See
# scratchpad prototypes (affine + unstructured) for the measured 15000x build
# speedups and the bit-identical differential checks this design reproduces.
#
# TWO ACCESS FAMILIES, ONE EVALUATOR:
#   * STRUCTURED (Cartesian) — a gather is affine in the cell index, so the
#     source slot is `out_lin(c) + Δ` for a Δ that is CONSTANT within a group
#     (a periodic wrap only shifts Δ by ±N·stride). Groups are the wrap/region
#     boxes, found polyhedrally (O(stencil width), not O(cells)). A const array
#     on its OWN (possibly reduced-rank) grid is read by the cell's multi-index
#     through per-dim strides (`_AccConstBox`).
#   * UNSTRUCTURED / VARIABLE-VALENCE — a neighbour gather is INDIRECT through a
#     connectivity array (`u[conn[(c-1)*w + n]]`), and a neighbour reduction runs
#     over `n in 1:valence[c]` with the bound read at runtime. One kernel covers
#     every valence — the bound is data, not a structural split. The connectivity
#     and valence arrays are INPUTS (const arrays), never built here.
#
# The spine reuses `_Node` (compile.jl). Two extra node kinds appear ONLY in an
# access spine and are handled ONLY by `_eval_acc` (the scalar `_eval_node` never
# sees them): `_NK_ACCESS` (a leaf; `idx` indexes the kernel's access table) and
# `_NK_REDUCE` (children = [body]; `payload` = the `_Bound`; the ⊕-fold runs over
# the neighbour index). Everything else is an ordinary `_NK_OP`/`_NK_LITERAL`.
#
# CELL COORDINATES. The evaluator threads, per output cell: `oln` the output
# linear slot (== the state grid's linear index, since state shares the output
# grid); `c` the cell ordinal (== `oln` for a Cartesian box, the running index
# for a contiguous/unstructured set) used by per-cell/edge descriptors and the
# `_VarBound`; `n` the neighbour index inside a reduction (0 outside); and `midx`
# the cell's up-to-3D loop multi-index (i,j,k), used ONLY by `_AccConstBox` to
# address a const on a different grid. `midx` is padded with 1s for absent dims.
# ========================================================================

# New spine kinds (disjoint from _NK_LITERAL..._NK_PARAM_GATHER = 1..8).
const _NK_ACCESS = UInt8(20)   # gather/const via access descriptor (idx = table slot)
const _NK_REDUCE = UInt8(21)   # ⊕-reduction over the neighbour index (payload = _Bound)
# Out-of-line template sub-kernel call (esm-spec §9.6.4 Option B / RFC
# out-of-line-expression-templates §7.7 "compile references natively"). `payload`
# is a SHARED `_AccKernel` holding the template body's access spine, descriptor
# table, and CSE — compiled once per (use site, region class) and referenced from
# every box/kernel whose lanes lower to the same descriptors. The evaluator arm
# recurses into it with the SAME (u, p, t, c, n, oln, midx) cell context, so the
# body computes exactly the scalar sequence the fused (expanded) spine would.
const _NK_SUBCALL = UInt8(22)  # template-body sub-kernel (payload = _AccKernel)

# ---- Access descriptors: how one leaf resolves to a value at (cell c, nbr n) ----
#
# ONE CONCRETE TAGGED STRUCT, not an abstract-type hierarchy — the same design as
# `_VecNode` (vectorize.jl), and for the same reason. A per-kernel descriptor
# TABLE is a `Vector{_AccDesc}`; if the element type were an abstract `_Access`,
# every `_fetch(table[i], …)` would be a DYNAMIC DISPATCH on the boxed subtype,
# which infers as `Any`, boxes each gathered value, and allocates O(#access-nodes
# × #cells) per RHS call (measured ~140 B/cell — fatal at 1e6 cells). A concrete
# struct dispatched by a `kind::UInt8` tag makes `_fetch` a branch ladder with
# concrete field reads: no dynamic dispatch, no boxing, zero allocation at
# `Float64`, and a small `Union{Float64,eltype(u)}` result under AD that the
# operators promote — exactly `_eval_node`'s discipline.
#
# The named constructors below preserve the old per-descriptor call sites verbatim
# (`_AccStateAffine(Δ)`, `_AccConstBox(arr, s1, s2, s3, off)`, …); only the storage
# and `_fetch` changed. Fields are shared across kinds (an `Int` slot serves
# `delta`/`idx`/… as the kind dictates), the way `_VecNode` shares `payload`/`idx`.
const _AK_STATE_AFFINE       = UInt8(1)   # u[oln + delta]              (Cartesian stencil workhorse)
const _AK_CONST_AFFINE       = UInt8(2)   # arr[oln + delta]            (const, full-grid layout)
const _AK_CONST_BOX          = UInt8(3)   # arr[off + Σ(midx_d-1)·s_d]  (const on its own reduced-rank grid)
const _AK_STATE_FIXED        = UInt8(4)   # u[idx]                      (invariant pinned state slot)
const _AK_LOOP_IDX           = UInt8(5)   # Float64(midx[dim])          (loop index as a value)
const _AK_SCALAR             = UInt8(6)   # v                           (hoisted invariant / literal leaf)
const _AK_CONST_CELL         = UInt8(7)   # arr[c]                      (per-cell const)
const _AK_CONST_EDGE         = UInt8(8)   # arr[(c-1)·width + n]        (per-edge, variable valence)
const _AK_ARR_FIXED          = UInt8(9)   # arr[idx]                    (invariant forcing gather)
const _AK_STATE_INDIRECT     = UInt8(10)  # u[conn[(c-1)·width + n]]    (unstructured neighbour gather)
const _AK_STATE_INDIRECT_COL = UInt8(11)  # u[conn[(c-1)·width + col]]  (unstructured fixed column)
const _AK_FORCING_BOX        = UInt8(12)  # flat[off + Σ(midx_d-1)·s_d] (LIVE forcing on its own grid)
# Unstructured state gather over a Cartesian box: a per-box SLOT TABLE addressed
# by the cell multi-index (`conn[off + Σ(midx_d-1)·s_d]`, box-local dense
# layout), holding the state slot each cell reads — or 0 for a ghost, which
# fetches the ghost literal 0.0. Emitted by the box processor when a state
# lane's slot is NOT an affine function of the loop indices (a gather indirect
# through a connectivity const, a boundary-fold pattern past the Δ-cut cap):
# the table entries are `_eval_recipe`'s per-cell outputs, so a fetch is
# bit-identical to the per-cell resolve. The table is O(box) Ints — the same
# order as the connectivity input itself, and strictly less than the per-cell
# fallback's per-lane slot vectors.
const _AK_STATE_TBL_BOX      = UInt8(13)  # u[conn[off + Σ(midx_d-1)·s_d]] (0 ⇒ ghost 0.0)
# A Float64 buffer read through an Int index table, box-addressed. The per-cell
# merge (acc_merge.jl) emits it for a LIVE forcing gather whose linear offset
# varies per cell (`_NK_PARAM_GATHER` lanes): `arr` is the aliased
# `_PGatherArray.flat` buffer — refreshed in place, so the read must stay live,
# which is why the VALUES are never materialized the way a const lane's are.
const _AK_ARR_TBL_BOX        = UInt8(14)  # arr[conn[off + Σ(midx_d-1)·s_d]] (LIVE forcing table)

struct _AccDesc
    kind::UInt8
    arr::Vector{Float64}   # CONST_*, ARR_FIXED, FORCING_BOX (empty sentinel otherwise)
    conn::Vector{Int}      # STATE_INDIRECT[_COL] (empty sentinel otherwise)
    delta::Int             # STATE_AFFINE, CONST_AFFINE
    idx::Int               # STATE_FIXED, ARR_FIXED
    width::Int             # STATE_INDIRECT[_COL], CONST_EDGE
    col::Int               # STATE_INDIRECT_COL
    dim::Int               # LOOP_IDX
    s1::Int                # CONST_BOX per-dim strides + offset
    s2::Int
    s3::Int
    off::Int
    v::Float64             # SCALAR
end

const _AK_NO_ARR  = Float64[]
const _AK_NO_CONN = Int[]

@inline _mkacc(kind::UInt8; arr::Vector{Float64}=_AK_NO_ARR, conn::Vector{Int}=_AK_NO_CONN,
               delta::Int=0, idx::Int=0, width::Int=0, col::Int=0, dim::Int=0,
               s1::Int=0, s2::Int=0, s3::Int=0, off::Int=0, v::Float64=0.0) =
    _AccDesc(kind, arr, conn, delta, idx, width, col, dim, s1, s2, s3, off, v)

# Named constructors — the descriptor call sites (stencil_affine.jl, tests) use
# these and are unchanged by the tagged-struct storage.
_AccStateAffine(delta::Int)                      = _mkacc(_AK_STATE_AFFINE; delta=delta)
_AccStateIndirect(conn::Vector{Int}, width::Int) = _mkacc(_AK_STATE_INDIRECT; conn=conn, width=width)
_AccStateIndirectCol(conn::Vector{Int}, width::Int, col::Int) =
    _mkacc(_AK_STATE_INDIRECT_COL; conn=conn, width=width, col=col)
_AccConstAffine(arr::Vector{Float64}, delta::Int) = _mkacc(_AK_CONST_AFFINE; arr=arr, delta=delta)
_AccConstBox(arr::Vector{Float64}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_CONST_BOX; arr=arr, s1=s1, s2=s2, s3=s3, off=off)
# LIVE forcing gather with a lane-affine flat index. Same addressing as CONST_BOX
# but `arr` MUST be the aliased `_PGatherArray.flat` buffer (a data-refresh mutates
# it in place, so a captured reference stays live) — never a copy. A distinct kind
# from CONST_BOX so an invariant/const-hoisting analysis can never freeze it.
_AccForcingBox(arr::Vector{Float64}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_FORCING_BOX; arr=arr, s1=s1, s2=s2, s3=s3, off=off)
_AccConstCell(arr::Vector{Float64})              = _mkacc(_AK_CONST_CELL; arr=arr)
_AccConstEdge(arr::Vector{Float64}, width::Int)  = _mkacc(_AK_CONST_EDGE; arr=arr, width=width)
_AccStateFixed(idx::Int)                         = _mkacc(_AK_STATE_FIXED; idx=idx)
_AccArrFixed(arr::Vector{Float64}, idx::Int)     = _mkacc(_AK_ARR_FIXED; arr=arr, idx=idx)
_AccLoopIdx(dim::Int)                            = _mkacc(_AK_LOOP_IDX; dim=dim)
_AccScalar(v::Float64)                           = _mkacc(_AK_SCALAR; v=v)
_AccStateTblBox(conn::Vector{Int}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_STATE_TBL_BOX; conn=conn, s1=s1, s2=s2, s3=s3, off=off)
_AccArrTblBox(arr::Vector{Float64}, conn::Vector{Int}, s1::Int, s2::Int, s3::Int, off::Int) =
    _mkacc(_AK_ARR_TBL_BOX; arr=arr, conn=conn, s1=s1, s2=s2, s3=s3, off=off)

# One `_fetch`, dispatched by the kind tag — concrete field reads throughout, so
# no dynamic dispatch and no boxing. Hot Cartesian cases first. The result is
# `eltype(u)` for a state read and `Float64` for a const/scalar/loop-index read; a
# small `Union` the caller's operators promote (identical to `_eval_node`).
@inline function _fetch(a::_AccDesc, u, c, n, oln, midx)
    k = a.kind
    if k === _AK_STATE_AFFINE
        return @inbounds u[oln + a.delta]
    elseif k === _AK_CONST_AFFINE
        return @inbounds a.arr[oln + a.delta]
    elseif k === _AK_CONST_BOX
        return @inbounds a.arr[a.off + (midx[1]-1)*a.s1 + (midx[2]-1)*a.s2 + (midx[3]-1)*a.s3]
    elseif k === _AK_STATE_FIXED
        return @inbounds u[a.idx]
    elseif k === _AK_LOOP_IDX
        return Float64(midx[a.dim])
    elseif k === _AK_SCALAR
        return a.v
    elseif k === _AK_CONST_CELL
        return @inbounds a.arr[c]
    elseif k === _AK_CONST_EDGE
        return @inbounds a.arr[(c-1)*a.width + n]
    elseif k === _AK_ARR_FIXED
        return @inbounds a.arr[a.idx]
    elseif k === _AK_FORCING_BOX
        return @inbounds a.arr[a.off + (midx[1]-1)*a.s1 + (midx[2]-1)*a.s2 + (midx[3]-1)*a.s3]
    elseif k === _AK_STATE_INDIRECT
        return @inbounds u[a.conn[(c-1)*a.width + n]]
    elseif k === _AK_STATE_INDIRECT_COL
        return @inbounds u[a.conn[(c-1)*a.width + a.col]]
    elseif k === _AK_STATE_TBL_BOX
        s = @inbounds a.conn[a.off + (midx[1]-1)*a.s1 + (midx[2]-1)*a.s2 + (midx[3]-1)*a.s3]
        return s == 0 ? 0.0 : @inbounds u[s]     # 0 ⇒ ghost literal, as per cell
    elseif k === _AK_ARR_TBL_BOX
        return @inbounds a.arr[a.conn[a.off + (midx[1]-1)*a.s1 + (midx[2]-1)*a.s2 + (midx[3]-1)*a.s3]]
    end
    throw(TreeWalkError("E_TREEWALK_ACC_BAD_DESC", "unknown access kind $(Int(k))"))
end

# ---- Reduction bound (fixed structured count vs runtime per-cell valence) ----
abstract type _Bound end
struct _FixedBound <: _Bound; k::Int; end
struct _VarBound   <: _Bound; valence::Vector{Int}; end   # per-cell edge count (an input)
@inline _nbrcount(b::_FixedBound, c) = b.k
@inline _nbrcount(b::_VarBound,   c) = @inbounds b.valence[c]

# ---- Output cell set ----
# STRUCTURED (Cartesian box): `strides` are the state grid's per-loop-dim linear
# slot strides and `ranges[d]` is the box's index range in loop dim d. The output
# slot of cell (i₁,…,i_d) is the AFFINE map `base + Σ_d i_d·strides[d]`, walked
# with no stored per-lane out_slots. `base` and the strides are DERIVED from the
# state layout (var_map) and verified — the state ordering is a lexicographic sort
# of the index tuples (row-major for a full grid), NOT a fixed convention. A box
# may restrict ANY subset of dims (longitude wrap in i, poles in j, vertical
# regions in k), so it is a general strided box, not a slab.
# UNSTRUCTURED / CONTIGUOUS: `strides` is empty; `ranges[1]` is the cell range
# 1:ncell, `base` unused, and the out slot == the cell ordinal.
# INDIRECT (`outs` non-empty): the per-cell merge (acc_merge.jl) hosts a group
# of arbitrary output slots — cell ordinal c ∈ 1:length(outs) writes `du[outs[c]]`,
# `midx == (c, 1, 1)`, and the box-addressed descriptors (CONST_BOX /
# STATE_TBL_BOX / ARR_TBL_BOX with s1=1, off=1) index their per-cell tables by
# that ordinal. `outs` is the same O(#cells) data the `_VecKernel` out_slots
# vector always carried — no new memory class.
struct _CellSet
    strides::Vector{Int}
    ranges::Vector{UnitRange{Int}}
    base::Int
    outs::Vector{Int}
end
_CellSet(strides::Vector{Int}, ranges::Vector{UnitRange{Int}}, base::Int) =
    _CellSet(strides, ranges, base, Int[])
_contig_cells(ncell::Int) = _CellSet(Int[], UnitRange{Int}[1:ncell], 0)
_outs_cells(outs::Vector{Int}) = _CellSet(Int[], UnitRange{Int}[1:length(outs)], 0, outs)
@inline _is_contig(cs::_CellSet) = isempty(cs.strides) && isempty(cs.outs)
@inline _is_outs(cs::_CellSet) = !isempty(cs.outs)

# ---- Per-cell CSE scratch ----
# The affine spine is walked as a TREE once per cell (`_build_branch_template`
# compiles with no memo, so structurally-shared subexpressions are distinct
# nodes). For a big operator — monotone PPM is a 160k-unique-node DAG that expands
# to ~2M as a tree — that re-walks each shared subtree many times per cell. The CSE
# pass (`_build_acc_cse`) slices the shared subtrees into ORDERED recipes; the box
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
    spine::_Node               # op tree with _NK_ACCESS / _NK_REDUCE / _NK_CACHED leaves
    acc::Vector{_AccDesc}      # descriptor table (spine `_NK_ACCESS.idx` indexes this)
    bound::_Bound              # reduction bound (for any _NK_REDUCE in the spine)
    zerobar::Float64           # ⊕ identity seed for the reduction (0.0 for sum)
    cse::_AccCSE               # per-cell common-subexpression recipes + scratch
    # Distinct template-body sub-kernels reachable from `spine`/`cse` (through
    # `_NK_SUBCALL` payloads, transitively, nested-first). The kernel runners fill
    # each sub-kernel's loop-invariant CSE tier once per call here, so the subcall
    # arm only fills the per-cell tier. A sub-kernel shared by several parent
    # kernels is prepped once per parent — recomputing an invariant is the same
    # value, never a different one. Empty for every reference-free kernel.
    subs::Vector{_AccKernel}
end
# 5-/6-arg convenience: a kernel with no CSE / no sub-kernels (tests, direct
# construction, and every reference-free build).
_AccKernel(cells::_CellSet, spine::_Node, acc::Vector{_AccDesc}, bound::_Bound, zerobar::Float64) =
    _AccKernel(cells, spine, acc, bound, zerobar, _ACC_NO_CSE, _AccKernel[])
_AccKernel(cells::_CellSet, spine::_Node, acc::Vector{_AccDesc}, bound::_Bound,
           zerobar::Float64, cse::_AccCSE) =
    _AccKernel(cells, spine, acc, bound, zerobar, cse, _AccKernel[])

# ---- The evaluator ----
# ELTYPE-GENERIC in the value type `T`, exactly as the scalar `_eval_node`
# (compile.jl) is, and for the same reason: the in-place `f!` must DIFFERENTIATE
# through these kernels (ForwardDiff over state OR over parameters), not just
# integrate them. `T` is threaded and passed down but leaves are NEVER converted
# to it — the type flows naturally from the leaves (a state read yields
# `eltype(u)`, a const/literal yields `Float64`) and promotes at the operators.
# That duck-typing is load-bearing: it is what keeps a LITERAL `^` exponent a
# `Float64` (see the `:^` arm of `_eval_acc_op`), and it makes the `T === Float64`
# path bit-identical to the pre-AD walker, instruction for instruction. Matches
# `_eval_node`'s discipline arm for arm — the differential + AD tests pin it.
#
# `t` current time, `c` cell ordinal, `n` neighbour index (0 outside a
# reduction), `oln` output slot, `midx` the cell's (i,j,k) loop multi-index
# (padded with 1s). The 9-arg form derives `T` from the runtime inputs (the
# build-time / test entry point), mirroring `_eval_node`'s 4-arg convenience form.
@inline _eval_acc(nd::_Node, u, p, t, c::Int, n::Int, oln::Int,
                  midx::NTuple{3,Int}, K::_AccKernel) =
    _eval_acc(nd, u, p, t, c, n, oln, midx, K, _rhs_value_type(u, p, t))

function _eval_acc(nd::_Node, u, p, t, c::Int, n::Int, oln::Int,
                   midx::NTuple{3,Int}, K::_AccKernel, ::Type{T}) where {T}
    k = nd.kind
    if k === _NK_ACCESS
        return _fetch(K.acc[nd.idx], u, c, n, oln, midx)
    elseif k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_REDUCE
        body = nd.children[1]
        s = K.zerobar
        cnt = _nbrcount(K.bound, c)
        @inbounds for m in 1:cnt
            s += _eval_acc(body, u, p, t, c, m, oln, midx, K, T)
        end
        return s
    elseif k === _NK_CONTRACTION
        # Fixed-width runtime ⊕-fold (the per-cell merge hosts einsum groups on
        # the access spine). MIRRORS `_eval_contraction` (compile.jl) arm for
        # arm — seeded from the 0̄ identity on the node, sequential child-order
        # fold — so the value is bit-identical to the per-cell reference.
        return _eval_acc_contraction(nd, u, p, t, c, n, oln, midx, K, T)
    elseif k === _NK_PARAM
        return getfield(p, nd.sym)
    elseif k === _NK_TIME
        return t
    elseif k === _NK_CACHED
        # A CSE reference: the value was computed once for THIS cell by the box
        # loop's prelude (`_fill_cse!`) into the per-cell scratch captured in
        # `payload` — or, for an inv-tier def the cross-kernel sharing pass
        # (xcse.jl, plan B4) rewrote, once per CALL into the SCALAR prelude's
        # `_CSECache` (filled by `_make_rhs` before any kernel runs). The `isa`
        # split keeps both reads monomorphic; kernels a build never rewrites
        # only ever see the `_AccScratch` branch.
        pl = nd.payload
        pl isa _AccScratch && return _acc_scratch_read(pl, nd.idx, T)
        return _cse_read(pl::_CSECache, nd.idx, T)
    elseif k === _NK_SUBCALL
        # Template-body sub-kernel (RFC out-of-line-expression-templates): fill the
        # body's per-cell CSE scratch for THIS cell, then evaluate its spine
        # against its OWN descriptor table. The invariant tier was filled once per
        # call by the runner prologue (`K.subs`). Evaluation is single-threaded and
        # the template DAG is acyclic (esm-spec §9.7.3), so a body is never
        # re-entered mid-evaluation and its scratch buffers are race-free.
        S = nd.payload::_AccKernel
        cse = S.cse
        if _has_cse(cse)
            buf = _acc_scratch_buf(cse.scratch, T)
            rs = cse.recipes
            @inbounds for i in eachindex(rs)
                buf[i] = _eval_acc(rs[i], u, p, t, c, n, oln, midx, S, T)
            end
        end
        return _eval_acc(S.spine, u, p, t, c, n, oln, midx, S, T)
    else # _NK_OP
        return _eval_acc_op(nd, u, p, t, c, n, oln, midx, K, T)
    end
end

# Runtime ⊕-fold over an access-spine contraction node's children, seeded from
# `nd.literal` (the 0̄ identity baked on at build time) — byte-for-byte the
# `_eval_contraction` (compile.jl) fold shape, with `_eval_acc` as the child
# walker.
function _eval_acc_contraction(nd::_Node, u, p, t, c::Int, n::Int, oln::Int,
                               midx::NTuple{3,Int}, K::_AccKernel, ::Type{T}) where {T}
    op = nd.op
    ch = nd.children
    if op === :+
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s += _eval_acc(ch[k], u, p, t, c, n, oln, midx, K, T)
        end
        return s
    elseif op === :*
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s *= _eval_acc(ch[k], u, p, t, c, n, oln, midx, K, T)
        end
        return s
    elseif op === :max
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s = max(s, _eval_acc(ch[k], u, p, t, c, n, oln, midx, K, T))
        end
        return s
    else  # :min
        s = nd.literal
        @inbounds for k in eachindex(ch)
            s = min(s, _eval_acc(ch[k], u, p, t, c, n, oln, midx, K, T))
        end
        return s
    end
end

# ---- Generated mechanical arms (op-registry tables, src/op_registry.jl) ----
#
# The MECHANICAL arms of `_eval_acc_op` — unary elementwise, comparisons,
# fixed-2-ary `/`/`^`/`pow`/`atan2`, and the n-ary `min`/`max` folds — are
# GENERATED from the same registry tables that grow the other three ladders
# (`_eval_node_op` / `_eval_vec_op` / `_oop_op`), so a mechanical op added to
# `_OP_TABLE` reaches the access spine automatically. Probe protocol as
# everywhere: `nothing` ⇒ not in the table ⇒ the ladder falls through.
# DELIBERATELY NO ARITY GUARDS on the unary/comparison/binary arms — the
# hand-written access arms had none (the spine is compiled from an
# already-validated tree), and adding them would change the failure mode of a
# malformed spine. `min`/`max` keep their historical `< 2` guard.
let arms = :(return nothing)
    for row in reverse(_UNARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             return $(row.sym)(_eval_acc(ch[1], u, p, t, c, n, oln, midx, K, T))
                         end,
                         arms)
    end
    @eval @inline function _eval_acc_unary_elementwise(op::Symbol, ch::Vector{_Node},
                                                       u, p, t, c::Int, n::Int, oln::Int,
                                                       midx::NTuple{3,Int}, K::_AccKernel,
                                                       ::Type{T}) where {T}
        $arms
    end
end

let arms = :(return nothing)
    for row in reverse(_COMPARISON_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             return $(row.fnsym)(
                                 _eval_acc(ch[1], u, p, t, c, n, oln, midx, K, T),
                                 _eval_acc(ch[2], u, p, t, c, n, oln, midx, K, T)) ? 1.0 : 0.0
                         end,
                         arms)
    end
    @eval @inline function _eval_acc_comparison(op::Symbol, ch::Vector{_Node},
                                                u, p, t, c::Int, n::Int, oln::Int,
                                                midx::NTuple{3,Int}, K::_AccKernel,
                                                ::Type{T}) where {T}
        $arms
    end
end

let arms = :(return nothing)
    for row in reverse(_BINARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             return $(row.fnsym)(
                                 _eval_acc(ch[1], u, p, t, c, n, oln, midx, K, T),
                                 _eval_acc(ch[2], u, p, t, c, n, oln, midx, K, T))
                         end,
                         arms)
    end
    @eval @inline function _eval_acc_binary_elementwise(op::Symbol, ch::Vector{_Node},
                                                        u, p, t, c::Int, n::Int, oln::Int,
                                                        midx::NTuple{3,Int}, K::_AccKernel,
                                                        ::Type{T}) where {T}
        $arms
    end
end

let arms = :(return nothing)
    for row in reverse(_NARY_MINMAX_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             length(ch) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY",
                                 $(row.name * " needs ≥2 args")))
                             s = _eval_acc(ch[1], u, p, t, c, n, oln, midx, K, T)
                             @inbounds for i in 2:length(ch)
                                 s = $(row.fnsym)(s, _eval_acc(ch[i], u, p, t, c, n, oln, midx, K, T))
                             end
                             return s
                         end,
                         arms)
    end
    @eval @inline function _eval_acc_minmax(op::Symbol, ch::Vector{_Node},
                                            u, p, t, c::Int, n::Int, oln::Int,
                                            midx::NTuple{3,Int}, K::_AccKernel,
                                            ::Type{T}) where {T}
        $arms
    end
end

# Op application over an access spine. MIRRORS `_eval_node_op` (compile.jl) arm for
# arm — same arities, same n-ary folds, same `^`/comparison/logical/elementary-fn
# semantics — because the affine path must be bit-identical to the per-cell path,
# whose spine is the SAME compiled `_Node` tree evaluated by `_eval_node_op`. The
# only difference is the leaf recursion (`_eval_acc`, which resolves `_NK_ACCESS` /
# `_NK_REDUCE`). The mechanical arms are generated from the SAME registry tables
# as `_eval_node_op`'s (see above), so those cannot drift by construction; the
# hand-written remainder is still caught by the differential test.
function _eval_acc_op(nd::_Node, u, p, t, c::Int, n::Int, oln::Int,
                      midx::NTuple{3,Int}, K::_AccKernel, ::Type{T}) where {T}
    op = nd.op
    ch = nd.children
    @inline ev(x) = _eval_acc(x, u, p, t, c, n, oln, midx, K, T)
    if op === :+
        length(ch) == 1 && return ev(ch[1])
        s = ev(ch[1]); @inbounds for i in 2:length(ch); s += ev(ch[i]); end
        return s
    elseif op === :*
        length(ch) == 1 && return ev(ch[1])
        s = ev(ch[1]); @inbounds for i in 2:length(ch); s *= ev(ch[i]); end
        return s
    elseif op === :-
        length(ch) == 1 && return -ev(ch[1])
        length(ch) == 2 && return ev(ch[1]) - ev(ch[2])
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        return -ev(ch[1])

    # Fixed-2-ary elementwise (`/`, `^`, `pow`, `atan2`) — GENERATED (registry).
    elseif (bin = _eval_acc_binary_elementwise(op, ch, u, p, t, c, n, oln, midx, K, T)) !== nothing
        return bin

    # Comparisons → 1.0/0.0 — GENERATED (registry).
    elseif (cmp = _eval_acc_comparison(op, ch, u, p, t, c, n, oln, midx, K, T)) !== nothing
        return cmp

    # Logical
    elseif op === :and
        @inbounds for x in ch; ev(x) == 0 && return 0.0; end
        return 1.0
    elseif op === :or
        @inbounds for x in ch; ev(x) != 0 && return 1.0; end
        return 0.0
    elseif op === :not
        return ev(ch[1]) == 0 ? 1.0 : 0.0

    elseif op === :ifelse
        return ev(ch[1]) != 0 ? ev(ch[2]) : ev(ch[3])

    # Elementary functions — the mechanical unary arms (`sin` … `ceil`) are
    # GENERATED (registry); `atan` (1-or-2-ary) stays hand-written, `atan2` is
    # handled by the binary probe above.
    elseif (unary = _eval_acc_unary_elementwise(op, ch, u, p, t, c, n, oln, midx, K, T)) !== nothing
        return unary
    elseif op === :atan
        length(ch) == 1 && return atan(ev(ch[1]))
        length(ch) == 2 && return atan(ev(ch[1]), ev(ch[2]))
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))

    # n-ary min/max (arity ≥ 2) — GENERATED (registry).
    elseif (mm = _eval_acc_minmax(op, ch, u, p, t, c, n, oln, midx, K, T)) !== nothing
        return mm
    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)
    elseif op === :Pre
        return ev(ch[1])

    elseif op === :fn
        # Interp / closed function. MIRRORS `_eval_node_op`'s `:fn` arm
        # (compile.jl) exactly — SAME `(fname, spec)` payload dispatch, SAME
        # validation-free `_interp_*_core` kernels, SAME const tables — so the
        # affine path stays bit-identical on interp leaves. The scalar query
        # children are `ev`'d (through the access evaluator) instead of
        # `_eval_node`'d; everything else is identical. `isa`-matching the whole
        # concrete tuple type keeps the inline spec unboxed (see compile.jl).
        pl = nd.payload
        if pl isa Tuple{String,_InterpLinearSpec}
            spec = pl[2]
            return _interp_linear_core(spec.table, spec.axis, ev(ch[1]))
        elseif pl isa Tuple{String,_InterpBilinearSpec}
            spec = pl[2]
            return _interp_bilinear_core(spec.table, spec.axis_x, spec.axis_y,
                                         ev(ch[1]), ev(ch[2]))
        elseif pl isa Tuple{String,_InterpSearchsortedSpec}
            spec = pl[2]
            # `convert(T, …)` not `Float64(…)` — same reasoning as the mirrored
            # `:fn` arm in compile.jl: keep the arm in the evaluator's value type
            # so it stays AD-clean and concretely inferred.
            return convert(T, _interp_searchsorted_core("interp.searchsorted",
                                                        ev(ch[1]), spec.xs))
        elseif pl isa Tuple{String,_InterpLinearLaneSpec}
            # Per-LANE spec table (kernel-class merge): select THIS cell's
            # member spec by the box lane addressing, then call the SAME core
            # the member kernel called — bit-identical per lane by construction.
            h = pl[2]
            sp = @inbounds h.specs[_interp_lane(h, midx)]
            return _interp_linear_core(sp.table, sp.axis, ev(ch[1]))
        elseif pl isa Tuple{String,_InterpBilinearLaneSpec}
            h = pl[2]
            sp = @inbounds h.specs[_interp_lane(h, midx)]
            return _interp_bilinear_core(sp.table, sp.axis_x, sp.axis_y,
                                         ev(ch[1]), ev(ch[2]))
        elseif pl isa Tuple{String,_InterpSearchsortedLaneSpec}
            h = pl[2]
            sp = @inbounds h.specs[_interp_lane(h, midx)]
            return convert(T, _interp_searchsorted_core("interp.searchsorted",
                                                        ev(ch[1]), sp.xs))
        elseif pl isa Tuple{String,Nothing}
            # `_eval_closed_fn` selects the pinned vs. AD registry on the
            # compile-time `T` — mirrors compile.jl's `:fn` arm, and keeps this
            # arm's inference (and the affine kernel's zero-alloc property)
            # identical at `T === Float64`.
            fname = pl[1]
            args_evaluated = Any[ev(ci) for ci in ch]
            return convert(T, _eval_closed_fn(fname, args_evaluated, T))
        end
        throw(TreeWalkError("E_TREEWALK_UNKNOWN_CLOSED_FUNCTION",
            "fn payload $(typeof(pl)) is neither a typed interp spec tuple nor (String, Nothing)"))
    end
    throw(TreeWalkError("E_TREEWALK_ACC_UNSUPPORTED_OP", String(op)))
end

# One cell's output value: fill the per-cell CSE scratch (each shared subtree
# evaluated ONCE), then evaluate the output spine, whose `_NK_CACHED` leaves read
# the scratch. With no CSE (`_has_cse` false) this is exactly the bare spine walk —
# zero extra work, so non-CSE kernels are byte-identical to before. `n = 0`: CSE is
# only built for reduce-free spines, so the neighbour index never matters here.
@inline function _eval_cell(K::_AccKernel, u, p, t, c::Int, oln::Int,
                            midx::NTuple{3,Int}, ::Type{T}) where {T}
    cse = K.cse
    if _has_cse(cse)
        buf = _acc_scratch_buf(cse.scratch, T)
        rs = cse.recipes
        @inbounds for i in eachindex(rs)
            buf[i] = _eval_acc(rs[i], u, p, t, c, 0, oln, midx, K, T)
        end
    end
    return _eval_acc(K.spine, u, p, t, c, 0, oln, midx, K, T)
end

# ---- Run one kernel into du (in place) ----
# `T` is the value type (`_rhs_value_type(u, p, t)`); a compile-time constant at
# the call site, so at `T === Float64` every `_eval_acc` below is the monomorphic
# Float64 walk it always was, and under AD the SAME loop evaluates in `Dual`. The
# 5-arg form derives `T` (test / standalone entry point).
_run_acc_kernel!(du, u, p, t, K::_AccKernel) =
    _run_acc_kernel!(du, u, p, t, K, _rhs_value_type(u, p, t))

# Fill the loop-invariant scratch ONCE per call (before the cell loop). The recipes
# have no cell-varying access, so the cell context is irrelevant — dummy `(1,0,1,
# (1,1,1))` is passed. A no-op (compiles away) when the kernel has no invariants.
@inline function _fill_invariant!(K::_AccKernel, u, p, t, ::Type{T}) where {T}
    cse = K.cse
    if _has_inv(cse)
        buf = _acc_scratch_buf(cse.inv_scratch, T)
        rs = cse.inv_recipes
        @inbounds for i in eachindex(rs)
            buf[i] = _eval_acc(rs[i], u, p, t, 1, 0, 1, (1, 1, 1), K, T)
        end
    end
    return nothing
end

function _run_acc_kernel!(du, u, p, t, K::_AccKernel, ::Type{T}) where {T}
    # Sub-kernel prologue (nested-first): each template body's loop-invariant tier
    # is filled once per call, exactly as the parent's is below.
    for S in K.subs
        _fill_invariant!(S, u, p, t, T)
    end
    _fill_invariant!(K, u, p, t, T)
    cs = K.cells
    if _is_outs(cs)                                 # indirect out slots (per-cell merge)
        outs = cs.outs
        @inbounds for c in eachindex(outs)
            oln = outs[c]
            du[oln] = _eval_cell(K, u, p, t, c, oln, (c, 1, 1), T)
        end
    elseif _is_contig(cs)                           # contiguous / unstructured
        @inbounds for c in cs.ranges[1]
            du[c] = _eval_cell(K, u, p, t, c, c, (c, 1, 1), T)
        end
    else                                            # structured: strided box walk
        _run_box_kernel!(du, u, p, t, K, cs, T)
    end
    return du
end

# Nested loop over a Cartesian box; rank ≤ 3 (the latlon3d ceiling) is unrolled
# for a tight `oln`, with a product-based fallback for higher rank.
function _run_box_kernel!(du, u, p, t, K::_AccKernel, cs::_CellSet, ::Type{T}) where {T}
    st = cs.strides
    rg = cs.ranges
    b  = cs.base
    nd = length(st)
    if nd == 1
        s1 = st[1]
        @inbounds for i in rg[1]
            oln = b + i*s1
            du[oln] = _eval_cell(K, u, p, t, oln, oln, (i, 1, 1), T)
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2
            du[oln] = _eval_cell(K, u, p, t, oln, oln, (i, j, 1), T)
        end
    elseif nd == 3
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2 + k*s3
            du[oln] = _eval_cell(K, u, p, t, oln, oln, (i, j, k), T)
        end
    else
        @inbounds for idxs in Iterators.product(rg...)
            oln = b
            for d in 1:nd; oln += idxs[d]*st[d]; end
            mi = (idxs[1], nd >= 2 ? idxs[2] : 1, nd >= 3 ? idxs[3] : 1)
            du[oln] = _eval_cell(K, u, p, t, oln, oln, mi, T)
        end
    end
    return du
end

# ---- Per-cell CSE builder (ess-affine) ----
# Value-number the access spine structurally; any OP subtree that occurs ≥2 times
# is sliced into an ordered recipe list and every occurrence replaced by an
# `_NK_CACHED` read of a per-cell scratch slot. Bit-identity is automatic: the SAME
# subexpression is computed with the SAME inputs, just once instead of many times.
# Recipes are emitted in ascending value-number order, and a child's value number
# is always < its parent's (post-order numbering), so a recipe only ever reads
# LOWER slots — the box loop fills them front-to-back. Skipped for any spine with a
# `_NK_REDUCE` (its body reads the neighbour index `n`, which the per-cell prelude —
# run at n=0 — cannot capture).
# Identity-deduped existence predicate (ESS-0hh): the spine is a DAG (its
# builders memoize by node identity), and the per-path recursion was
# exponential on a doubling chain. A predicate is path-multiplicity-
# insensitive, so a visited set is exactly equivalent.
_acc_has_reduce(n::_Node) = _acc_has_reduce(n, IdDict{_Node,Nothing}())
function _acc_has_reduce(n::_Node, seen::IdDict{_Node,Nothing})
    n.kind === _NK_REDUCE && return true
    haskey(seen, n) && return false
    seen[n] = nothing
    for c in n.children
        _acc_has_reduce(c, seen) && return true
    end
    return false
end

# Structural key: two nodes share a value number iff their keys are equal. ACCESS
# keys on descriptor CONTENT (`_desc_key`); an OP with a payload (interp `:fn`)
# keys on the payload's identity, so distinct specs never merge (conservative).
function _acc_vn_key(n::_Node, childvns::Vector{Int}, acc::Vector{_AccDesc})
    k = n.kind
    k === _NK_ACCESS  && return (0x1, _desc_key(acc[n.idx]))
    k === _NK_LITERAL && return (0x2, reinterpret(UInt64, n.literal))
    k === _NK_PARAM   && return (0x3, n.sym)
    k === _NK_TIME    && return (0x4, :t)
    k === _NK_OP      && return (0x5, n.op,
                                 n.payload === nothing ? UInt(0) : objectid(n.payload),
                                 childvns)
    return (0xff, objectid(n))     # _NK_CACHED / anything else — never merged
end

# A descriptor read is CELL-INVARIANT (same for every cell in the box, though it
# may vary per call) iff it is a fixed state slot, a fixed forcing read, or a
# scalar. Everything else (STATE_AFFINE, CONST_BOX/CELL/EDGE, FORCING_BOX, LOOP_IDX,
# STATE_INDIRECT[_COL]) is addressed by the cell.
@inline _acc_desc_invariant(k::UInt8) =
    k === _AK_STATE_FIXED || k === _AK_ARR_FIXED || k === _AK_SCALAR

function _build_acc_cse(spine::_Node, acc::Vector{_AccDesc})
    _acc_has_reduce(spine) && return (spine, _ACC_NO_CSE)
    key_to_vn = Dict{Any,Int}()
    counts = Int[]; is_op = Bool[]; is_inv = Bool[]; rep = _Node[]
    # Occurrence counting must stay PER PATH (a value occurring on ≥2 paths is
    # exactly what earns a CSE slot — collapsing to distinct-node visits would
    # change slot decisions on shared spines), but the spine is a DAG whose
    # per-path recursion was exponential (ESS-0hh). Mirror `_cse_count!`
    # (compile.jl): number each UNIQUE node once in identity-deduped postorder
    # (a child's vn stays < its parent's, preserving the dependency-order
    # invariant the recipe tiers rely on), then propagate saturating path
    # multiplicities parent→child in reverse postorder and tally each unique
    # node's multiplicity into its value number — identical totals to the full
    # path enumeration, O(nodes + edges).
    #
    # DENSE-POSITION KEYING (perf): number every UNIQUE node with a dense
    # postorder position `pos_of[n] ∈ 1:P` (ONE identity dict, built once), so the
    # value-number, path-multiplicity, and rewrite passes below index plain
    # `Vector`s by position instead of hashing each freshly-lowered `_Node`
    # through a SEPARATE `IdDict` per pass — `IdDict` get/set over these spines was
    # the build's top self-time. Entry-marking + `order` are byte-identical to the
    # prior `seen`-set walk, so vn/mult/slot decisions are unchanged.
    order = _Node[]
    pos_of = IdDict{_Node,Int}()
    function collect_postorder(n::_Node)
        haskey(pos_of, n) && return
        pos_of[n] = 0                  # mark in-progress (entry-marked, as prior `seen`)
        for c in n.children
            collect_postorder(c)
        end
        push!(order, n)
        pos_of[n] = length(order)      # final dense position (spine ends up == P)
    end
    collect_postorder(spine)
    P = length(order)
    vn_by_pos = Vector{Int}(undef, P)
    for (p, n) in enumerate(order)    # postorder ⇒ children already numbered
        childvns = Int[vn_by_pos[pos_of[c]] for c in n.children]
        key = _acc_vn_key(n, childvns, acc)
        vn = get(key_to_vn, key, 0)
        if vn == 0
            vn = length(counts) + 1
            key_to_vn[key] = vn
            k = n.kind
            inv = k === _NK_LITERAL || k === _NK_PARAM || k === _NK_TIME ?  true :
                  k === _NK_ACCESS ? _acc_desc_invariant(acc[n.idx].kind) :
                  k === _NK_OP     ? all(v -> is_inv[v], childvns) :
                  false                       # _NK_REDUCE excluded upstream; be safe
            push!(counts, 0); push!(is_op, k === _NK_OP); push!(is_inv, inv); push!(rep, n)
        end
        vn_by_pos[p] = vn
    end
    mult_by_pos = zeros(Int, P)
    mult_by_pos[pos_of[spine]] = 1     # spine is the last postorder node
    for i in P:-1:1                    # reverse postorder = parents before children
        m = mult_by_pos[i]
        for c in order[i].children
            pc = pos_of[c]
            mult_by_pos[pc] = _sat_add(mult_by_pos[pc], m)
        end
    end
    for p in 1:P
        counts[vn_by_pos[p]] = _sat_add(counts[vn_by_pos[p]], mult_by_pos[p])
    end
    # Two-tier slot assignment, in value-number order (a child's vn is always below
    # its parent's, so each tier's recipes end up dependency-ordered): every
    # invariant OP is hoisted to a per-call slot (once per call beats once per
    # cell); every remaining SHARED cell-varying OP gets a per-cell CSE slot.
    inv_slot = Dict{Int,Int}(); cell_slot = Dict{Int,Int}()
    for vn in 1:length(counts)
        is_op[vn] || continue
        if is_inv[vn]
            inv_slot[vn] = length(inv_slot) + 1
        elseif counts[vn] >= 2
            cell_slot[vn] = length(cell_slot) + 1
        end
    end
    (isempty(inv_slot) && isempty(cell_slot)) && return (spine, _ACC_NO_CSE)
    inv_scratch = _AccScratch(length(inv_slot))
    cell_scratch = _AccScratch(length(cell_slot))
    # Identity-memoized rewrite: `rw`'s output depends only on the node (its vn
    # and rewritten children), so a shared input node maps to ONE shared output
    # node — without the memo the per-path rebuild re-inflated a shared spine
    # into an exponentially large tree (ESS-0hh). Values are unchanged: the
    # runner evaluates the same ops on the same inputs either way.
    rw_cache = Vector{Union{Nothing,_Node}}(nothing, P)
    function rw(n::_Node)
        p = pos_of[n]
        cached = rw_cache[p]
        cached === nothing || return cached
        vn = vn_by_pos[p]
        s = get(inv_slot, vn, 0)
        result = if s != 0
            _mknode(kind=_NK_CACHED, idx=s, payload=inv_scratch)
        else
            s = get(cell_slot, vn, 0)
            if s != 0
                _mknode(kind=_NK_CACHED, idx=s, payload=cell_scratch)
            elseif isempty(n.children)
                n
            else
                _mknode(kind=n.kind, op=n.op, literal=n.literal, idx=n.idx,
                        sym=n.sym, payload=n.payload,
                        children=_Node[rw(c) for c in n.children])
            end
        end
        rw_cache[p] = result
        return result
    end
    _recipe(vn) = (r = rep[vn];
        _mknode(kind=r.kind, op=r.op, literal=r.literal, idx=r.idx, sym=r.sym,
                payload=r.payload, children=_Node[rw(c) for c in r.children]))
    inv_recipes = Vector{_Node}(undef, length(inv_slot))
    for (vn, s) in inv_slot; inv_recipes[s] = _recipe(vn); end
    cell_recipes = Vector{_Node}(undef, length(cell_slot))
    for (vn, s) in cell_slot; cell_recipes[s] = _recipe(vn); end
    return (rw(spine), _AccCSE(cell_recipes, cell_scratch, inv_recipes, inv_scratch))
end

# ---- Small builders (used by tests and, later, the polyhedral build) ----
_acc(id::Int) = _mknode(kind=_NK_ACCESS, idx=id)
_areduce(body::_Node) = _mknode(kind=_NK_REDUCE, children=_Node[body])
_aop(op::Symbol, kids::_Node...) = _mknode(kind=_NK_OP, op=op, children=collect(_Node, kids))
_alit(v::Real) = _mknode(kind=_NK_LITERAL, literal=Float64(v))

# ========================================================================
# THE LANE TAPE (ess-affine de-scalarization) — a strided/whole-box runner.
# ========================================================================
#
# `_run_acc_kernel!` walks the access SPINE once per cell: correct, zero-alloc,
# eltype-generic — and per-cell interpretive (one dynamic `_Node` dispatch per
# node PER CELL). The lane tape removes the per-cell interpretation where a
# strided formulation exists: at build time a qualifying kernel is compiled ONCE
# into a linear TAPE of per-NODE instructions, each a tight typed loop over a
# TILE of cells (gather `u[oln+Δ]` / const-box reads, then elementwise op loops
# over preallocated lane buffers). Per-node dispatch happens once per tile
# instead of once per cell; the arithmetic per lane is the SAME scalar op
# sequence `_eval_acc` performs per cell, in the same fold order, so the result
# is BIT-IDENTICAL (the stencil_affine differential tests are the oracle).
#
# Design constraints, all load-bearing:
#   * ZERO ALLOCATION per RHS call: every buffer (lane temporaries, literal /
#     scalar slots, the tile's oln/multi-index vectors) is preallocated at plan
#     build. Post-CSE the spine is a TREE (shared subtrees are `_NK_CACHED`
#     reads), so temporaries are single-use and recycle by stack discipline —
#     peak lane buffers ≈ tree depth + #cell-CSE recipes, NOT #nodes.
#   * TILED, so memory stays O(#live-buffers × tile) — never O(#cells) — and the
#     O(#structural groups) build property of the affine path is preserved: no
#     per-lane slot vector is ever materialized.
#   * Float64 ONLY. `_make_rhs` routes `T === Float64` (a compile-time constant)
#     through the tape and every other value type (ForwardDiff `Dual`) through
#     the scalar `_run_acc_kernel!`, which stays the eltype-generic reference.
#   * GUARD OPS (`ifelse`/`and`/`or`) ARE supported (gordian total-vectorize):
#     the tape evaluates them EAGERLY as select/blend instructions. Eager and
#     lazy agree in VALUE (a guard's result depends only on which branch is
#     taken); they differ only in that eager could enter a branch that THROWS a
#     `DomainError`, which `_acc_sanitize_guards` removes by rewriting each
#     throwing op under a guard to run on a safe neutral off its taken mask. The
#     scalar `_eval_acc` reference keeps the unsanitized spine and stays lazy, so
#     an UNguarded domain violation still raises on both paths.
#   * DECLINES (returns `nothing`, scalar runner keeps the kernel) anything whose
#     vector semantics could diverge from the scalar walk: `_NK_REDUCE`
#     (n-dependent), template sub-kernels, and the unstructured n-indexed
#     descriptors. Interp `:fn` leaves ARE supported (a per-lane loop over the
#     SAME `_interp_*_core` kernels, bit-identical by construction); BOXED closed
#     `:fn` leaves (`datetime.*`) are ALSO supported (gordian total-vectorize) —
#     a per-lane `_eval_closed_fn` loop, safe because a closed function is total
#     by contract (never throws on real inputs), so an eager eval under a guard
#     matches the lazy walk bit for bit and any off-domain NaN is discarded by
#     the guard's select. A lane-varying boxed fn boxes its args per lane exactly
#     as the scalar walk does (the ONE place the tape is not zero-alloc).

# Tape opcodes.
const _TC_GATHER_STATE   = UInt8(1)   # d[l] = u[oln[l] + delta]
const _TC_GATHER_ARR_OLN = UInt8(2)   # d[l] = arr[oln[l] + delta]
const _TC_GATHER_ARR_BOX = UInt8(3)   # d[l] = arr[off + (mi1[l]-1)s1 + (mi2[l]-1)s2 + (mi3[l]-1)s3]
const _TC_LOOP_IDX       = UInt8(4)   # d[l] = Float64(mi{delta}[l])
const _TC_GATHER_ARR_CELL= UInt8(5)   # d[l] = arr[cell[l]]  (contiguous: cell == oln)
const _TC_OP             = UInt8(6)   # elementwise / fold op over operand buffers
const _TC_INTERP_LINEAR  = UInt8(7)   # d[l] = _interp_linear_core(spec, q[l])
const _TC_INTERP_BILINEAR= UInt8(8)   # d[l] = _interp_bilinear_core(spec, x[l], y[l])
const _TC_INTERP_SEARCH  = UInt8(9)   # d[l] = Float64(_interp_searchsorted_core(spec, q[l]))
const _TC_GATHER_STATE_TBL=UInt8(10)  # s = conn[boxaddr(l)]; d[l] = s == 0 ? 0.0 : u[s]
const _TC_GATHER_ARR_TBL = UInt8(11)  # d[l] = arr[conn[boxaddr(l)]]  (LIVE forcing table)
const _TC_FN             = UInt8(12)  # d[l] = _eval_closed_fn(name, args[·], Float64)  (boxed closed fn)
# Per-LANE spec tables (kernel-class merge, oop_merge.jl): lane l's spec is
# `specs[boxaddr(l)]` (same box addressing as GATHER_*_TBL), evaluated by the
# SAME `_interp_*_core` the scalar walk calls — bit-identical per lane.
const _TC_INTERP_LINEAR_TBL   = UInt8(13)  # d[l] = _interp_linear_core(specs[·(l)], q[l])
const _TC_INTERP_BILINEAR_TBL = UInt8(14)  # d[l] = _interp_bilinear_core(specs[·(l)], x[l], y[l])
const _TC_INTERP_SEARCH_TBL   = UInt8(15)  # d[l] = Float64(_interp_searchsorted_core(specs[·(l)], q[l]))

# One instruction. Operand `args[k]` is a buffer id into the plan's `bufs`;
# `strides[k]` is 0 (a length-1 scalar/literal slot, broadcast) or 1 (a lane
# buffer). `1 + (l-1)*stride` is the branch-free unified read (the classic
# broadcast trick), so every op loop serves scalar and lane operands alike.
struct _AccInstr
    code::UInt8
    op::Symbol
    dest::Int
    args::Vector{Int}
    strides::Vector{Int}
    delta::Int                 # gather Δ (GATHER_*) / loop dim (LOOP_IDX)
    arr::Vector{Float64}       # gather source (empty sentinel otherwise)
    conn::Vector{Int}          # slot table (GATHER_STATE_TBL; empty sentinel otherwise)
    s1::Int; s2::Int; s3::Int; off::Int   # box addressing (GATHER_ARR_BOX / _STATE_TBL)
    payload::Any               # typed interp spec (INTERP_*), else nothing
end
_mkinstr(code::UInt8; op::Symbol=Symbol(""), dest::Int=0, args::Vector{Int}=Int[],
         strides::Vector{Int}=Int[], delta::Int=0, arr::Vector{Float64}=_AK_NO_ARR,
         conn::Vector{Int}=_AK_NO_CONN,
         s1::Int=0, s2::Int=0, s3::Int=0, off::Int=0, payload=nothing) =
    _AccInstr(code, op, dest, args, strides, delta, arr, conn, s1, s2, s3, off, payload)

# Per-call scalar sources: lane-INVARIANT leaves, read once per RHS call into a
# length-1 buffer (stride-0 operand). `_SS_ARR` re-reads its (possibly LIVE
# forcing) array on every call — never folded at plan time.
const _SS_PARAM = UInt8(1)     # Float64(getfield(p, sym))
const _SS_TIME  = UInt8(2)     # Float64(t)
const _SS_STATE = UInt8(3)     # u[idx]           (invariant pinned state slot)
const _SS_ARR   = UInt8(4)     # arr[idx]         (invariant — possibly live — gather)
const _SS_INV   = UInt8(5)     # inv-CSE scratch f64[idx] (filled by _fill_invariant!)
struct _AccScalarSrc
    kind::UInt8
    idx::Int
    sym::Symbol
    arr::Vector{Float64}
    scratch::_AccScratch
    dest::Int                  # 1-length buffer id
end
const _SS_NO_SCRATCH = _AccScratch(0)

# Threading state for one plan's CELL axis (see `_run_acc_plan_threaded!`).
# Built lazily on the first threaded call and then reused for the life of the
# plan, so the steady-state RHS never allocates: `state` is the one-time verdict
# (0 unexamined, 1 threadable, -1 serial-only) and `ws` holds one scratch clone
# per chunk. `ws` is `Vector{Any}` only to break the `_AccPlan` ↔ cache
# definition cycle; every read re-tightens it with `::_AccPlan`, so the walk
# stays as concretely typed as the serial one.
mutable struct _PlanTCache
    state::Int
    ncells::Int
    nchunks::Int
    ws::Vector{Any}
end
_PlanTCache() = _PlanTCache(0, 0, 0, Any[])

struct _AccPlan
    tile::Int
    bufs::Vector{Vector{Float64}}
    scalars::Vector{_AccScalarSrc}
    instrs::Vector{_AccInstr}
    result::Int                # spine result buffer id
    result_stride::Int         # 0 ⇒ lane-invariant spine value
    oln::Vector{Int}           # per-tile output slots (c == oln, see _run_box_kernel!)
    mi1::Vector{Int}           # per-tile loop multi-index (padded with 1s)
    mi2::Vector{Int}
    mi3::Vector{Int}
    tcache::_PlanTCache        # cell-axis threading state (lazily built)
end
# Pre-threading positional form: every existing construction site (and the tests)
# builds a plan with a fresh, unexamined thread cache.
_AccPlan(tile::Int, bufs::Vector{Vector{Float64}}, scalars::Vector{_AccScalarSrc},
         instrs::Vector{_AccInstr}, result::Int, result_stride::Int,
         oln::Vector{Int}, mi1::Vector{Int}, mi2::Vector{Int}, mi3::Vector{Int}) =
    _AccPlan(tile, bufs, scalars, instrs, result, result_stride,
             oln, mi1, mi2, mi3, _PlanTCache())

# Plan-build decline: the kernel keeps the scalar runner. Never an error.
struct _AccPlanDecline <: Exception end

mutable struct _AccPlanBuilder
    tile::Int
    bufs::Vector{Vector{Float64}}
    free::Vector{Int}                  # recyclable lane-buffer ids
    lit_cache::Dict{Float64,Int}
    scal_cache::Dict{Any,Int}
    scalars::Vector{_AccScalarSrc}
    instrs::Vector{_AccInstr}
    recipe_bufs::Vector{Int}           # cell-CSE slot → buffer id
    recipe_strides::Vector{Int}
end
_AccPlanBuilder(tile::Int) =
    _AccPlanBuilder(tile, Vector{Float64}[], Int[], Dict{Float64,Int}(),
                    Dict{Any,Int}(), _AccScalarSrc[], _AccInstr[], Int[], Int[])

function _plan_newlane!(B::_AccPlanBuilder)
    isempty(B.free) || return pop!(B.free)
    push!(B.bufs, Vector{Float64}(undef, B.tile))
    return length(B.bufs)
end
function _plan_lit!(B::_AccPlanBuilder, v::Float64)
    get!(B.lit_cache, v) do
        push!(B.bufs, Float64[v])
        length(B.bufs)
    end
end
function _plan_scalar!(B::_AccPlanBuilder, kind::UInt8; idx::Int=0, sym::Symbol=Symbol(""),
                       arr::Vector{Float64}=_AK_NO_ARR,
                       scratch::_AccScratch=_SS_NO_SCRATCH)
    key = (kind, idx, sym, objectid(arr), objectid(scratch))
    get!(B.scal_cache, key) do
        push!(B.bufs, Float64[0.0])
        d = length(B.bufs)
        push!(B.scalars, _AccScalarSrc(kind, idx, sym, arr, scratch, d))
        d
    end
end

# Is a box-addressed gather's index SEQUENTIAL within a tile? True when the
# addressing uses only `mi1` (s2 == s3 == 0) and the kernel's cell walk fills
# `mi1` consecutively per tile — an indirect-outs set, a contiguous set, or a
# 1-D box (see the corresponding fills in `_run_acc_plan!`). The run loop then
# derives lane l's index as `idx0 + (l-1)*s1` from the tile's first lane
# instead of loading `mi1[l]` — a strided window LLVM can vectorize.
@inline _tbl_seq(K::_AccKernel, s2::Int, s3::Int) =
    s2 == 0 && s3 == 0 &&
    (_is_outs(K.cells) || _is_contig(K.cells) || length(K.cells.strides) == 1)

# Emit one node; returns `(buf, stride, istemp)`. `istemp` ⇒ the buffer is a
# single-use lane temporary the CALLER may recycle once consumed.
function _plan_emit!(B::_AccPlanBuilder, nd::_Node, K::_AccKernel)
    k = nd.kind
    if k === _NK_ACCESS
        a = K.acc[nd.idx]
        ak = a.kind
        if ak === _AK_STATE_AFFINE
            d = _plan_newlane!(B)
            push!(B.instrs, _mkinstr(_TC_GATHER_STATE; dest=d, delta=a.delta))
            return (d, 1, true)
        elseif ak === _AK_CONST_AFFINE
            d = _plan_newlane!(B)
            push!(B.instrs, _mkinstr(_TC_GATHER_ARR_OLN; dest=d, delta=a.delta, arr=a.arr))
            return (d, 1, true)
        elseif ak === _AK_CONST_BOX || ak === _AK_FORCING_BOX
            # Same addressing; a FORCING_BOX arr is the aliased LIVE buffer and is
            # re-gathered per tile, so an in-place refresh is always seen.
            # `delta=2` marks a tile-sequential index (see `_tbl_seq`).
            d = _plan_newlane!(B)
            push!(B.instrs, _mkinstr(_TC_GATHER_ARR_BOX; dest=d, arr=a.arr,
                                     delta=(_tbl_seq(K, a.s2, a.s3) ? 2 : 0),
                                     s1=a.s1, s2=a.s2, s3=a.s3, off=a.off))
            return (d, 1, true)
        elseif ak === _AK_LOOP_IDX
            d = _plan_newlane!(B)
            push!(B.instrs, _mkinstr(_TC_LOOP_IDX; dest=d, delta=a.dim))
            return (d, 1, true)
        elseif ak === _AK_STATE_TBL_BOX
            # Unstructured slot-table gather (gather-of-gather): a tight per-lane
            # loop over the box-addressed table, ghost slot 0 → 0.0. Two
            # PLAN-TIME facts ride `delta` as a bitmask so the run loop is
            # specialized: bit 1 (value 1) = the table is ghost-free
            # (branch-free loop); bit 2 (value 2) = the table index is
            # tile-sequential (`_tbl_seq` — no per-lane mi1 load).
            d = _plan_newlane!(B)
            fl = (any(==(0), a.conn) ? 0 : 1) | (_tbl_seq(K, a.s2, a.s3) ? 2 : 0)
            push!(B.instrs, _mkinstr(_TC_GATHER_STATE_TBL; dest=d, conn=a.conn,
                                     delta=fl, s1=a.s1, s2=a.s2, s3=a.s3, off=a.off))
            return (d, 1, true)
        elseif ak === _AK_ARR_TBL_BOX
            # LIVE forcing through a per-cell index table: `arr` is the aliased
            # buffer, re-read every tile so an in-place refresh is always seen.
            d = _plan_newlane!(B)
            push!(B.instrs, _mkinstr(_TC_GATHER_ARR_TBL; dest=d, arr=a.arr, conn=a.conn,
                                     delta=(_tbl_seq(K, a.s2, a.s3) ? 2 : 0),
                                     s1=a.s1, s2=a.s2, s3=a.s3, off=a.off))
            return (d, 1, true)
        elseif ak === _AK_CONST_CELL
            # The ARR_CELL instruction reads `arr[oln[l]]` (cell ordinal == oln
            # holds for contiguous sets only) — an indirect-outs kernel's ordinal
            # rides mi1 instead, so decline there (the builder never emits
            # CONST_CELL into an outs kernel; this guards hand-built ones).
            _is_outs(K.cells) && throw(_AccPlanDecline())
            d = _plan_newlane!(B)
            push!(B.instrs, _mkinstr(_TC_GATHER_ARR_CELL; dest=d, arr=a.arr))
            return (d, 1, true)
        elseif ak === _AK_SCALAR
            return (_plan_lit!(B, a.v), 0, false)
        elseif ak === _AK_STATE_FIXED
            return (_plan_scalar!(B, _SS_STATE; idx=a.idx), 0, false)
        elseif ak === _AK_ARR_FIXED
            return (_plan_scalar!(B, _SS_ARR; idx=a.idx, arr=a.arr), 0, false)
        else
            throw(_AccPlanDecline())   # CONST_EDGE / STATE_INDIRECT[_COL]: n-indexed
        end
    elseif k === _NK_LITERAL
        return (_plan_lit!(B, nd.literal), 0, false)
    elseif k === _NK_PARAM
        return (_plan_scalar!(B, _SS_PARAM; sym=nd.sym), 0, false)
    elseif k === _NK_TIME
        return (_plan_scalar!(B, _SS_TIME), 0, false)
    elseif k === _NK_CACHED
        pl = nd.payload
        if pl === K.cse.scratch
            return (B.recipe_bufs[nd.idx], B.recipe_strides[nd.idx], false)
        elseif pl === K.cse.inv_scratch
            return (_plan_scalar!(B, _SS_INV; idx=nd.idx, scratch=K.cse.inv_scratch), 0, false)
        end
        throw(_AccPlanDecline())       # foreign scratch (a sub-kernel context)
    elseif k === _NK_CONTRACTION
        # Fixed-width ⊕-fold as a tape op: the 0̄ identity rides as a stride-0
        # first operand, so the n-ary fold loop computes ((0̄ ⊕ c1) ⊕ c2)… —
        # exactly `_eval_acc_contraction`'s (and `_eval_contraction`'s) seeded
        # sequential fold, bit for bit.
        ch = nd.children
        isempty(ch) && return (_plan_lit!(B, nd.literal), 0, false)
        seedbuf = _plan_lit!(B, nd.literal)
        ops = Tuple{Int,Int,Bool}[_plan_emit!(B, c, K) for c in ch]
        d = _plan_newlane!(B)
        push!(B.instrs, _mkinstr(_TC_OP; op=nd.op, dest=d,
                                 args=Int[seedbuf; Int[o[1] for o in ops]],
                                 strides=Int[0; Int[o[2] for o in ops]]))
        for o in ops
            o[3] && push!(B.free, o[1])
        end
        return (d, 1, true)
    elseif k === _NK_OP
        return _plan_emit_op!(B, nd, K)
    end
    throw(_AccPlanDecline())           # _NK_REDUCE / _NK_SUBCALL / anything else
end

# Ops with lazy scalar semantics (`ifelse`/`and`/`or`). NO LONGER declined: the
# tape evaluates them EAGERLY as select/blend instructions, and
# `_acc_sanitize_guards` (called by `_build_acc_plan`) rewrites any throwing op
# under a guard so eager evaluation cannot raise — see the header. `:Pre` and
# arity-1 `+`/`*` are pass-through (no instruction).
const _PLAN_LAZY_OPS = (:ifelse, :and, :or)

function _plan_emit_op!(B::_AccPlanBuilder, nd::_Node, K::_AccKernel)
    op = nd.op
    ch = nd.children
    if op === :pi || op === :π
        return (_plan_lit!(B, Float64(pi)), 0, false)
    elseif op === :e
        return (_plan_lit!(B, Float64(ℯ)), 0, false)
    elseif op === :Pre
        length(ch) == 1 || throw(_AccPlanDecline())
        return _plan_emit!(B, ch[1], K)
    elseif (op === :+ || op === :*) && length(ch) == 1
        return _plan_emit!(B, ch[1], K)
    elseif op === :fn
        return _plan_emit_fn!(B, nd, K)
    end
    _plan_op_supported(op, length(ch)) || throw(_AccPlanDecline())
    # Children first (left→right, same order as the scalar walk), THEN the dest,
    # THEN recycle: a temp freed before a sibling is emitted could be clobbered.
    ops = Tuple{Int,Int,Bool}[_plan_emit!(B, c, K) for c in ch]
    d = _plan_newlane!(B)
    push!(B.instrs, _mkinstr(_TC_OP; op=op, dest=d,
                             args=Int[o[1] for o in ops],
                             strides=Int[o[2] for o in ops]))
    for o in ops
        o[3] && push!(B.free, o[1])
    end
    return (d, 1, true)
end

function _plan_emit_fn!(B::_AccPlanBuilder, nd::_Node, K::_AccKernel)
    pl = nd.payload
    ch = nd.children
    if pl isa Tuple{String,Nothing}
        # BOXED closed fn (`datetime.*`): no typed interp spec, so evaluate it
        # per lane through `_eval_closed_fn` (gordian total-vectorize, Stage 2).
        # Totality is the AUTHOR'S CONTRACT — a closed function must be total over
        # real inputs (never throw; return NaN off-domain), so eager per-lane eval
        # under a guard is safe and the guard's select discards any off-domain
        # NaN. Args box into a reused per-instruction `Any` buffer (exactly the
        # scalar walk's boxing); a lane-invariant fn is evaluated once per tile.
        ops = Tuple{Int,Int,Bool}[_plan_emit!(B, c, K) for c in ch]
        d = _plan_newlane!(B)
        argbuf = Vector{Any}(undef, length(ops))
        push!(B.instrs, _mkinstr(_TC_FN; dest=d,
                                 args=Int[o[1] for o in ops],
                                 strides=Int[o[2] for o in ops],
                                 payload=(pl[1]::String, argbuf)))
        for o in ops
            o[3] && push!(B.free, o[1])
        end
        return (d, 1, true)
    end
    code = pl isa Tuple{String,_InterpLinearSpec} ? _TC_INTERP_LINEAR :
           pl isa Tuple{String,_InterpBilinearSpec} ? _TC_INTERP_BILINEAR :
           pl isa Tuple{String,_InterpSearchsortedSpec} ? _TC_INTERP_SEARCH :
           pl isa Tuple{String,_InterpLinearLaneSpec} ? _TC_INTERP_LINEAR_TBL :
           pl isa Tuple{String,_InterpBilinearLaneSpec} ? _TC_INTERP_BILINEAR_TBL :
           pl isa Tuple{String,_InterpSearchsortedLaneSpec} ? _TC_INTERP_SEARCH_TBL :
           throw(_AccPlanDecline())    # unknown payload shape
    ops = Tuple{Int,Int,Bool}[_plan_emit!(B, c, K) for c in ch]
    d = _plan_newlane!(B)
    if code === _TC_INTERP_LINEAR_TBL || code === _TC_INTERP_BILINEAR_TBL ||
       code === _TC_INTERP_SEARCH_TBL
        # Per-lane spec table: the spec's box lane addressing rides the instr
        # fields exactly as GATHER_*_TBL's does.
        h = pl[2]
        push!(B.instrs, _mkinstr(code; dest=d,
                                 args=Int[o[1] for o in ops],
                                 strides=Int[o[2] for o in ops], payload=pl[2],
                                 s1=h.s1, s2=h.s2, s3=h.s3, off=h.off))
    else
        push!(B.instrs, _mkinstr(code; dest=d,
                                 args=Int[o[1] for o in ops],
                                 strides=Int[o[2] for o in ops], payload=pl[2]))
    end
    for o in ops
        o[3] && push!(B.free, o[1])
    end
    return (d, 1, true)
end

# Which ops the tape's `_TC_OP` runner handles (mirrors `_eval_acc_op` minus the
# lazy ops, `:fn` and the plan-time constants — those have their own emit arms).
function _plan_op_supported(op::Symbol, nargs::Int)
    (op === :+ || op === :*) && return nargs >= 1
    op === :- && return nargs == 1 || nargs == 2
    op === :neg && return nargs == 1
    op === :not && return nargs == 1
    op === :ifelse && return nargs == 3
    (op === :and || op === :or) && return nargs >= 2
    op === :atan && return nargs == 1 || nargs == 2
    any(r -> r.sym === op, _BINARY_ELEMENTWISE_OPS) && return nargs == 2
    any(r -> r.sym === op, _COMPARISON_ELEMENTWISE_OPS) && return nargs == 2
    any(r -> r.sym === op, _UNARY_ELEMENTWISE_OPS) && return nargs == 1
    any(r -> r.sym === op, _NARY_MINMAX_OPS) && return nargs >= 2
    return false
end

# ---- Guard-operand sanitization (gordian total-vectorize, Stage 1) ----------
#
# The tape evaluates `ifelse`/`and`/`or` EAGERLY (both arms per lane). That is
# value-identical to the scalar short-circuit EXCEPT that an op which raises a
# `DomainError` off its domain (`log(-x)`, `sqrt(-x)`, `asin(|x|>1)`, `(-x)^0.5`,
# …) would throw when the eager walk enters a branch the scalar walk skips. This
# pass makes eager evaluation TOTAL: for each such op sitting under a guard, its
# DOMAIN operand is rewritten to `select(mask, operand, SAFE)` where `mask` is
# the conjunction of the enclosing guard predicates (computed BEFORE the branch,
# by construction: the mask node is a child of the select the op reads) and
# `SAFE` is a per-op in-domain neutral. Where `mask` is TRUE the select returns
# the authored operand, so `op(select(m,x,SAFE)) == op(x)` bit for bit; where it
# is FALSE the op runs on `SAFE` (no throw) and the guard above discards it.
#
# Operates on a TAPE-ONLY copy of the spine — the scalar `_eval_acc` reference
# keeps the unsanitized spine and stays lazy. Ops that produce NaN/Inf WITHOUT
# throwing (`/`, `log(0)`) need nothing: the select discards their garbage.
#
# `(operand_index, SAFE)` for every op whose real-domain evaluation can raise.
# `^`/`pow` sanitize the BASE (operand 1); `1.0 ^ y` is always finite.
const _ACC_GUARD_SAFE = Dict{Symbol,Tuple{Int,Float64}}(
    :log => (1, 1.0), :log2 => (1, 1.0), :log10 => (1, 1.0), :log1p => (1, 0.0),
    :sqrt => (1, 1.0),
    :asin => (1, 0.0), :acos => (1, 0.0), :atanh => (1, 0.0),
    :acosh => (1, 1.0),
    :^ => (1, 1.0), :pow => (1, 1.0),
)

# Conjoin the running guard mask with a predicate node (`nothing` ⇒ top level,
# unguarded — no mask yet). `and` is eager-total on the tape, so the conjunction
# is safe to evaluate; a false conjunct dominates regardless of later garbage.
@inline _acc_guard_conj(mask, pred::_Node) = mask === nothing ? pred : _aop(:and, mask, pred)

# Rewrite `nd` so every throwing op under `mask` reads a sanitized operand.
# `mask::Union{Nothing,_Node}` is the enclosing guard conjunction (truthy exactly
# where the scalar walk would evaluate this subtree).
function _acc_sanitize_guards(nd::_Node, mask)
    nd.kind === _NK_OP || return nd            # leaves: nothing to guard
    op = nd.op
    ch = nd.children
    if op === :ifelse                          # ifelse(cond, a, b)
        cond = _acc_sanitize_guards(ch[1], mask)
        a = _acc_sanitize_guards(ch[2], _acc_guard_conj(mask, cond))
        b = _acc_sanitize_guards(ch[3], _acc_guard_conj(mask, _aop(:not, cond)))
        return _aop(:ifelse, cond, a, b)
    elseif op === :and                         # xi guarded by x1..x_{i-1} all truthy
        run = mask
        kids = _Node[]
        for c in ch
            cs = _acc_sanitize_guards(c, run)
            push!(kids, cs)
            run = _acc_guard_conj(run, cs)
        end
        return _aop(:and, kids...)
    elseif op === :or                          # xi guarded by x1..x_{i-1} all falsy
        run = mask
        kids = _Node[]
        for c in ch
            cs = _acc_sanitize_guards(c, run)
            push!(kids, cs)
            run = _acc_guard_conj(run, _aop(:not, cs))
        end
        return _aop(:or, kids...)
    end
    safe = get(_ACC_GUARD_SAFE, op, nothing)
    kids = _Node[_acc_sanitize_guards(c, mask) for c in ch]
    if safe !== nothing && mask !== nothing
        (di, sv) = safe
        di <= length(kids) &&
            (kids[di] = _aop(:ifelse, mask, kids[di], _alit(sv)))
    end
    # Rebuild via `_mknode` (NOT `_aop`, which drops payload) so an op carrying a
    # payload — notably `:fn` (closed-function name / typed interp spec) — keeps
    # it; otherwise a guarded `fn` would lose its identity and decline the tape.
    return _mknode(kind=_NK_OP, op=op, payload=nd.payload, children=kids)
end

"""
    _build_acc_plan(K::_AccKernel; tile=1024) -> Union{_AccPlan,Nothing}

Compile `K` into a lane tape, or return `nothing` when the kernel has no strided
formulation (reduction, sub-kernel call, n-indexed descriptor) — the scalar
`_run_acc_kernel!` then keeps the kernel. Lazy guard ops (`ifelse`/`and`/`or`)
ARE compiled: eager select/blend on a spine copy sanitized by
`_acc_sanitize_guards` so eager evaluation cannot throw. Boxed closed `fn`
(`datetime.*`) leaves ARE compiled: a per-lane `_eval_closed_fn` loop, total by
the closed-function contract.
"""
function _build_acc_plan(K::_AccKernel; tile::Int=1024)
    isempty(K.subs) || return nothing
    length(K.cells.strides) <= 3 || return nothing   # >3-D box: scalar fallback
    B = _AccPlanBuilder(tile)
    try
        cse = K.cse
        for r in cse.recipes
            (b, s, _) = _plan_emit!(B, r, K)   # recipe results are multi-read: never recycled
            push!(B.recipe_bufs, b)
            push!(B.recipe_strides, s)
        end
        # Guard-bearing spines are sanitized (tape-only) so their eager selects
        # are total; a guard-free spine is emitted verbatim (byte-for-byte the
        # pre-Stage-1 plan). Guard-bearing kernels carry no CSE (acc_merge skips
        # it so the scalar reference stays lazy), so only the spine is rewritten.
        spine = _acc_node_has_lazy(K.spine) ? _acc_sanitize_guards(K.spine, nothing) : K.spine
        (rb, rs, _) = _plan_emit!(B, spine, K)
        mi2 = fill(1, tile); mi3 = fill(1, tile)
        return _AccPlan(tile, B.bufs, B.scalars, B.instrs, rb, rs,
                        Vector{Int}(undef, tile), Vector{Int}(undef, tile), mi2, mi3)
    catch err
        err isa _AccPlanDecline && return nothing
        rethrow()
    end
end

# ---- Tape op loops (generated from the op-registry tables, like every ladder) ----
#
# STRIDE-SPECIALIZED map kernels. An operand's stride is 0 (a length-1
# scalar/literal slot, broadcast) or 1 (a lane buffer); the branch is hoisted
# OUT of the lane loop so each variant is a plain unit-stride loop LLVM can
# SIMD-vectorize — the unified `1 + (l-1)*stride` read inside the loop
# defeated vectorization and made the tape measurably slower than the
# broadcast overlay it replaces. Same per-lane arithmetic in the same order,
# so values are bit-identical (`@simd` on an elementwise map has no
# cross-iteration dependence to reassociate).
@inline function _tape_map1!(f::F, d::Vector{Float64},
                             a::Vector{Float64}, sa::Int, L::Int) where {F}
    if sa == 1
        @inbounds @simd for l in 1:L
            d[l] = f(a[l])
        end
    else
        v = f(@inbounds a[1])
        @inbounds for l in 1:L
            d[l] = v
        end
    end
    return nothing
end
@inline function _tape_map2!(f::F, d::Vector{Float64},
                             a::Vector{Float64}, sa::Int,
                             b::Vector{Float64}, sb::Int, L::Int) where {F}
    if sa == 1
        if sb == 1
            @inbounds @simd for l in 1:L
                d[l] = f(a[l], b[l])
            end
        else
            bv = @inbounds b[1]
            @inbounds @simd for l in 1:L
                d[l] = f(a[l], bv)
            end
        end
    elseif sb == 1
        av = @inbounds a[1]
        @inbounds @simd for l in 1:L
            d[l] = f(av, b[l])
        end
    else
        v = f(@inbounds(a[1]), @inbounds(b[1]))
        @inbounds for l in 1:L
            d[l] = v
        end
    end
    return nothing
end
# In-place accumulate `d[l] = f(d[l], ck[·])` — the ⊕-fold's k ≥ 3 legs.
@inline function _tape_acc2!(f::F, d::Vector{Float64},
                             ck::Vector{Float64}, sk::Int, L::Int) where {F}
    if sk == 1
        @inbounds @simd for l in 1:L
            d[l] = f(d[l], ck[l])
        end
    else
        v = @inbounds ck[1]
        @inbounds @simd for l in 1:L
            d[l] = f(d[l], v)
        end
    end
    return nothing
end

let arms = :(return false)
    for row in reverse(_UNARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _tape_map1!($(row.sym), d, a, sa, L)
                             return true
                         end, arms)
    end
    @eval @inline function _tape_unary!(op::Symbol, d::Vector{Float64},
                                        a::Vector{Float64}, sa::Int, L::Int)
        $arms
    end
end

let arms = :(return false)
    for row in reverse(_BINARY_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _tape_map2!($(row.fnsym), d, a, sa, b, sb, L)
                             return true
                         end, arms)
    end
    @eval @inline function _tape_binary!(op::Symbol, d::Vector{Float64},
                                         a::Vector{Float64}, sa::Int,
                                         b::Vector{Float64}, sb::Int, L::Int)
        $arms
    end
end

let arms = :(return false)
    for row in reverse(_COMPARISON_ELEMENTWISE_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _tape_map2!((x, y) -> $(row.fnsym)(x, y) ? 1.0 : 0.0,
                                         d, a, sa, b, sb, L)
                             return true
                         end, arms)
    end
    @eval @inline function _tape_comparison!(op::Symbol, d::Vector{Float64},
                                             a::Vector{Float64}, sa::Int,
                                             b::Vector{Float64}, sb::Int, L::Int)
        $arms
    end
end

let arms = :(return false)
    for row in reverse(_NARY_MINMAX_OPS)
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _tape_map2!($(row.fnsym), d, bufs[args[1]], sts[1],
                                         bufs[args[2]], sts[2], L)
                             for k in 3:length(args)
                                 _tape_acc2!($(row.fnsym), d, bufs[args[k]], sts[k], L)
                             end
                             return true
                         end, arms)
    end
    @eval @inline function _tape_minmax!(op::Symbol, d::Vector{Float64},
                                         bufs::Vector{Vector{Float64}},
                                         args::Vector{Int}, sts::Vector{Int}, L::Int)
        $arms
    end
end

# Fold order mirrors `_eval_acc_op`'s `:+`/`:*` arms exactly: ((c1 ⊕ c2) ⊕ c3)…
@inline function _tape_fold!(op::Symbol, d::Vector{Float64},
                             bufs::Vector{Vector{Float64}},
                             args::Vector{Int}, sts::Vector{Int}, L::Int)
    if op === :+
        _tape_map2!(+, d, bufs[args[1]], sts[1], bufs[args[2]], sts[2], L)
        for k in 3:length(args)
            _tape_acc2!(+, d, bufs[args[k]], sts[k], L)
        end
    else # :*
        _tape_map2!(*, d, bufs[args[1]], sts[1], bufs[args[2]], sts[2], L)
        for k in 3:length(args)
            _tape_acc2!(*, d, bufs[args[k]], sts[k], L)
        end
    end
    return nothing
end

# ---- Guard ops as EAGER SELECT/blend (gordian total-vectorize) --------------
#
# `ifelse`/`and`/`or` are LAZY per cell in `_eval_acc_op` (the scalar reference
# still short-circuits). On the tape they are EAGER: both arms are computed for
# every lane and blended by `Base.ifelse` (branch-free). The value is identical
# to the scalar walk because (a) a guard's RESULT depends only on which branch
# is taken (`false & x == false`, `true | x == true`), and (b) any operand that
# could THROW under an unentered branch has been rewritten to
# `op(select(mask, operand, SAFE))` by `_acc_sanitize_guards` at plan build, so
# eager evaluation of the discarded branch cannot raise — see the sanitizer.
# Where a mask is TRUE the operand is unchanged (`select(m,x,1)` returns `x`), so
# the taken value is bit-identical to the lazy path; where it is FALSE the op
# runs on the safe neutral and the select at the guard discards the result.

# `d[l] = c ? a : b`, condition truthy iff `!= 0` (matching `_eval_acc_op`'s
# `ifelse` arm). `Base.ifelse` reads both already-computed operand buffers — no
# throw is possible here, they hold finite blends. Stride-1 fast path is the hot
# case (a comparison result over two lane buffers); the unified read serves the
# rarer broadcast operands.
@inline function _tape_select!(d::Vector{Float64},
                               c::Vector{Float64}, sc::Int,
                               a::Vector{Float64}, sa::Int,
                               b::Vector{Float64}, sb::Int, L::Int)
    if sc == 1 && sa == 1 && sb == 1
        @inbounds @simd for l in 1:L
            d[l] = ifelse(c[l] != 0, a[l], b[l])
        end
    else
        @inbounds for l in 1:L
            d[l] = ifelse(c[1 + (l-1)*sc] != 0, a[1 + (l-1)*sa], b[1 + (l-1)*sb])
        end
    end
    return nothing
end

# `and`/`or` as an eager 0.0/1.0 fold: `d = (x1!=0) ⊗ (x2!=0) ⊗ …`, ⊗ = `&`/`|`.
# Boolean-associative, so the fold order is irrelevant to the (exact 0.0/1.0)
# result — it matches the scalar short-circuit result bit for bit (only the
# side effect of THROWING differed, and the sanitizer removed that).
@inline function _tape_bool_fold!(isand::Bool, d::Vector{Float64},
                                  bufs::Vector{Vector{Float64}},
                                  args::Vector{Int}, sts::Vector{Int}, L::Int)
    a1 = bufs[args[1]]; s1 = sts[1]
    if s1 == 1
        @inbounds @simd for l in 1:L
            d[l] = ifelse(a1[l] != 0, 1.0, 0.0)
        end
    else
        v = ifelse(@inbounds(a1[1]) != 0, 1.0, 0.0)
        @inbounds for l in 1:L
            d[l] = v
        end
    end
    for k in 2:length(args)
        ak = bufs[args[k]]; sk = sts[k]
        if isand
            if sk == 1
                @inbounds @simd for l in 1:L
                    d[l] = ifelse((d[l] != 0) & (ak[l] != 0), 1.0, 0.0)
                end
            else
                bv = @inbounds ak[1]
                @inbounds @simd for l in 1:L
                    d[l] = ifelse((d[l] != 0) & (bv != 0), 1.0, 0.0)
                end
            end
        else
            if sk == 1
                @inbounds @simd for l in 1:L
                    d[l] = ifelse((d[l] != 0) | (ak[l] != 0), 1.0, 0.0)
                end
            else
                bv = @inbounds ak[1]
                @inbounds @simd for l in 1:L
                    d[l] = ifelse((d[l] != 0) | (bv != 0), 1.0, 0.0)
                end
            end
        end
    end
    return nothing
end

function _run_acc_tape_op!(ins::_AccInstr, bufs::Vector{Vector{Float64}}, L::Int)
    op = ins.op
    d = bufs[ins.dest]
    args = ins.args; sts = ins.strides
    if op === :+ || op === :*
        _tape_fold!(op, d, bufs, args, sts, L)
        return nothing
    elseif op === :ifelse
        _tape_select!(d, bufs[args[1]], sts[1], bufs[args[2]], sts[2],
                      bufs[args[3]], sts[3], L)
        return nothing
    elseif op === :and || op === :or
        _tape_bool_fold!(op === :and, d, bufs, args, sts, L)
        return nothing
    end
    a = bufs[args[1]]; sa = sts[1]
    if op === :- && length(args) == 2
        _tape_map2!(-, d, a, sa, bufs[args[2]], sts[2], L)
        return nothing
    elseif (op === :- || op === :neg)
        _tape_map1!(-, d, a, sa, L)
        return nothing
    elseif op === :not
        _tape_map1!(x -> x == 0 ? 1.0 : 0.0, d, a, sa, L)
        return nothing
    elseif op === :atan
        if length(args) == 1
            _tape_map1!(atan, d, a, sa, L)
        else
            _tape_map2!(atan, d, a, sa, bufs[args[2]], sts[2], L)
        end
        return nothing
    end
    if length(args) == 2
        b = bufs[args[2]]; sb = sts[2]
        _tape_binary!(op, d, a, sa, b, sb, L) && return nothing
        _tape_comparison!(op, d, a, sa, b, sb, L) && return nothing
    end
    length(args) == 1 && _tape_unary!(op, d, a, sa, L) && return nothing
    _tape_minmax!(op, d, bufs, args, sts, L) && return nothing
    throw(TreeWalkError("E_TREEWALK_ACC_UNSUPPORTED_OP", String(op)))  # unreachable: plan-gated
end

function _run_acc_instr!(ins::_AccInstr, bufs::Vector{Vector{Float64}}, u,
                         P::_AccPlan, L::Int)
    c = ins.code
    if c === _TC_OP
        _run_acc_tape_op!(ins, bufs, L)
    elseif c === _TC_GATHER_STATE
        d = bufs[ins.dest]; oln = P.oln; Δ = ins.delta
        @inbounds for l in 1:L
            d[l] = u[oln[l] + Δ]
        end
    elseif c === _TC_GATHER_ARR_OLN
        d = bufs[ins.dest]; arr = ins.arr; oln = P.oln; Δ = ins.delta
        @inbounds for l in 1:L
            d[l] = arr[oln[l] + Δ]
        end
    elseif c === _TC_GATHER_ARR_BOX
        d = bufs[ins.dest]; arr = ins.arr
        mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
        s1 = ins.s1; s2 = ins.s2; s3 = ins.s3; off = ins.off
        if ins.delta >= 2                    # tile-sequential index: strided copy
            idx0 = off + (@inbounds(mi1[1]) - 1)*s1
            @inbounds @simd for l in 1:L
                d[l] = arr[idx0 + (l-1)*s1]
            end
        else
            @inbounds for l in 1:L
                d[l] = arr[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]
            end
        end
    elseif c === _TC_LOOP_IDX
        d = bufs[ins.dest]
        mi = ins.delta === 1 ? P.mi1 : ins.delta === 2 ? P.mi2 : P.mi3
        @inbounds for l in 1:L
            d[l] = Float64(mi[l])
        end
    elseif c === _TC_GATHER_ARR_CELL
        d = bufs[ins.dest]; arr = ins.arr; oln = P.oln    # cell ordinal == oln
        @inbounds for l in 1:L
            d[l] = arr[oln[l]]
        end
    elseif c === _TC_GATHER_STATE_TBL
        d = bufs[ins.dest]; conn = ins.conn
        mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
        s1 = ins.s1; s2 = ins.s2; s3 = ins.s3; off = ins.off
        fl = ins.delta                        # bit 1: ghost-free; bit 2: sequential
        if fl == 3
            idx0 = off + (@inbounds(mi1[1]) - 1)*s1
            @inbounds for l in 1:L
                d[l] = u[conn[idx0 + (l-1)*s1]]
            end
        elseif fl == 2
            idx0 = off + (@inbounds(mi1[1]) - 1)*s1
            @inbounds for l in 1:L
                s = conn[idx0 + (l-1)*s1]
                d[l] = s == 0 ? 0.0 : u[s]
            end
        elseif fl == 1
            @inbounds for l in 1:L
                d[l] = u[conn[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]]
            end
        else
            @inbounds for l in 1:L
                s = conn[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]
                d[l] = s == 0 ? 0.0 : u[s]
            end
        end
    elseif c === _TC_GATHER_ARR_TBL
        d = bufs[ins.dest]; arr = ins.arr; conn = ins.conn
        mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
        s1 = ins.s1; s2 = ins.s2; s3 = ins.s3; off = ins.off
        if ins.delta >= 2
            idx0 = off + (@inbounds(mi1[1]) - 1)*s1
            @inbounds for l in 1:L
                d[l] = arr[conn[idx0 + (l-1)*s1]]
            end
        else
            @inbounds for l in 1:L
                d[l] = arr[conn[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]]
            end
        end
    elseif c === _TC_INTERP_LINEAR
        d = bufs[ins.dest]; spec = ins.payload::_InterpLinearSpec
        q = bufs[ins.args[1]]; sq = ins.strides[1]
        @inbounds for l in 1:L
            d[l] = _interp_linear_core(spec.table, spec.axis, q[1 + (l-1)*sq])
        end
    elseif c === _TC_INTERP_BILINEAR
        d = bufs[ins.dest]; spec = ins.payload::_InterpBilinearSpec
        x = bufs[ins.args[1]]; sx = ins.strides[1]
        y = bufs[ins.args[2]]; sy = ins.strides[2]
        @inbounds for l in 1:L
            d[l] = _interp_bilinear_core(spec.table, spec.axis_x, spec.axis_y,
                                         x[1 + (l-1)*sx], y[1 + (l-1)*sy])
        end
    elseif c === _TC_INTERP_SEARCH
        d = bufs[ins.dest]; spec = ins.payload::_InterpSearchsortedSpec
        q = bufs[ins.args[1]]; sq = ins.strides[1]
        @inbounds for l in 1:L
            d[l] = Float64(_interp_searchsorted_core("interp.searchsorted",
                                                     q[1 + (l-1)*sq], spec.xs))
        end
    elseif c === _TC_INTERP_LINEAR_TBL
        # Per-lane spec table (kernel-class merge): lane l uses ITS member's
        # spec, selected by the same box addressing as GATHER_*_TBL, and the
        # SAME core the member kernel called — bit-identical per lane.
        d = bufs[ins.dest]; h = ins.payload::_InterpLinearLaneSpec
        q = bufs[ins.args[1]]; sq = ins.strides[1]
        mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
        s1 = ins.s1; s2 = ins.s2; s3 = ins.s3; off = ins.off
        specs = h.specs
        @inbounds for l in 1:L
            sp = specs[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]
            d[l] = _interp_linear_core(sp.table, sp.axis, q[1 + (l-1)*sq])
        end
    elseif c === _TC_INTERP_BILINEAR_TBL
        d = bufs[ins.dest]; h = ins.payload::_InterpBilinearLaneSpec
        x = bufs[ins.args[1]]; sx = ins.strides[1]
        y = bufs[ins.args[2]]; sy = ins.strides[2]
        mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
        s1 = ins.s1; s2 = ins.s2; s3 = ins.s3; off = ins.off
        specs = h.specs
        @inbounds for l in 1:L
            sp = specs[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]
            d[l] = _interp_bilinear_core(sp.table, sp.axis_x, sp.axis_y,
                                         x[1 + (l-1)*sx], y[1 + (l-1)*sy])
        end
    elseif c === _TC_INTERP_SEARCH_TBL
        d = bufs[ins.dest]; h = ins.payload::_InterpSearchsortedLaneSpec
        q = bufs[ins.args[1]]; sq = ins.strides[1]
        mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
        s1 = ins.s1; s2 = ins.s2; s3 = ins.s3; off = ins.off
        specs = h.specs
        @inbounds for l in 1:L
            sp = specs[off + (mi1[l]-1)*s1 + (mi2[l]-1)*s2 + (mi3[l]-1)*s3]
            d[l] = Float64(_interp_searchsorted_core("interp.searchsorted",
                                                     q[1 + (l-1)*sq], sp.xs))
        end
    else # _TC_FN — boxed closed fn (datetime.*), per-lane through _eval_closed_fn
        d = bufs[ins.dest]
        name, argbuf = ins.payload::Tuple{String,Vector{Any}}
        args = ins.args; sts = ins.strides; na = length(args)
        allinv = true
        for k in 1:na
            sts[k] == 0 || (allinv = false; break)
        end
        if allinv                       # lane-invariant fn: ONE call, broadcast
            @inbounds for k in 1:na
                argbuf[k] = bufs[args[k]][1]
            end
            v = Float64(_eval_closed_fn(name, argbuf, Float64))
            @inbounds for l in 1:L
                d[l] = v
            end
        else                            # lane-varying args: per-lane (boxes, as scalar)
            @inbounds for l in 1:L
                for k in 1:na
                    argbuf[k] = bufs[args[k]][1 + (l-1)*sts[k]]
                end
                d[l] = Float64(_eval_closed_fn(name, argbuf, Float64))
            end
        end
    end
    return nothing
end

@inline function _flush_acc_tile!(du, u, P::_AccPlan, L::Int)
    bufs = P.bufs
    instrs = P.instrs
    @inbounds for i in eachindex(instrs)
        _run_acc_instr!(instrs[i], bufs, u, P, L)
    end
    r = bufs[P.result]; rs = P.result_stride
    oln = P.oln
    @inbounds for l in 1:L
        du[oln[l]] = r[1 + (l-1)*rs]
    end
    return nothing
end

# Run one planned kernel in place. Bit-identical to `_run_acc_kernel!` at
# Float64 (same per-lane op sequence, same fold order, same write order) and
# zero-allocation (all buffers preallocated on the plan) — the ONE exception is
# a boxed closed `fn` (`datetime.*`) with lane-varying args, which boxes those
# args per lane exactly as the scalar `:fn` arm does. `Float64` only —
# `_make_rhs` gates on `T === Float64` and sends every other value type to the
# scalar runner.
# Per-call scalar sources → their 1-length stride-0 buffers. Reads only `u`,
# `p`, `t` and the ALREADY-FILLED invariant scratch, so it is safe to run
# concurrently once per chunk against that chunk's private `bufs`.
@inline function _plan_fill_scalars!(bufs::Vector{Vector{Float64}},
                                     scs::Vector{_AccScalarSrc}, u, p, t)
    @inbounds for i in eachindex(scs)
        s = scs[i]
        v = s.kind === _SS_PARAM ? Float64(getfield(p, s.sym)) :
            s.kind === _SS_TIME  ? Float64(t) :
            s.kind === _SS_STATE ? Float64(u[s.idx]) :
            s.kind === _SS_ARR   ? s.arr[s.idx] :
                                   _acc_scratch_read(s.scratch, s.idx, Float64)
        bufs[s.dest][1] = v
    end
    return nothing
end

function _run_acc_plan!(du, u, p, t, K::_AccKernel, P::_AccPlan)
    _fill_invariant!(K, u, p, t, Float64)
    cs = K.cells
    # Threaded cell axis (opt-in; `_plan_prep_threads!` decides ONCE per plan).
    # The invariant scratch above is filled before any chunk starts and is only
    # read from here on, so the chunks share it safely.
    if _threads_available()
        tc = _plan_prep_threads!(P, cs)
        tc.state == 1 && return _run_acc_plan_threaded!(du, u, p, t, P, cs, tc)
    end
    # ---- serial path: unchanged, instruction for instruction ----
    _plan_fill_scalars!(P.bufs, P.scalars, u, p, t)
    oln = P.oln; mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
    tile = P.tile
    if _is_outs(cs)
        # Indirect out slots (per-cell merge): cell ordinal rides mi1, so the
        # box-addressed per-cell tables (s1=1, off=1) index by ordinal.
        outs = cs.outs
        nc = length(outs)
        i = 1
        while i <= nc
            L = min(tile, nc - i + 1)
            @inbounds for l in 1:L
                oln[l] = outs[i + l - 1]
                mi1[l] = i + l - 1
            end
            _flush_acc_tile!(du, u, P, L)
            i += L
        end
        return du
    end
    if _is_contig(cs)
        rng = cs.ranges[1]
        i = first(rng); hi = last(rng)
        while i <= hi
            L = min(tile, hi - i + 1)
            @inbounds for l in 1:L
                oln[l] = i + l - 1
                mi1[l] = i + l - 1        # midx == (c, 1, 1) for a contiguous set
            end
            _flush_acc_tile!(du, u, P, L)
            i += L
        end
        return du
    end
    # Strided box, in the EXACT `_run_box_kernel!` iteration order.
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    L = 0
    if nd == 1
        s1 = st[1]
        @inbounds for i in rg[1]
            L += 1; oln[L] = b + i*s1; mi1[L] = i
            L == tile && (_flush_acc_tile!(du, u, P, L); L = 0)
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            L += 1; oln[L] = b + i*s1 + j*s2; mi1[L] = i; mi2[L] = j
            L == tile && (_flush_acc_tile!(du, u, P, L); L = 0)
        end
    else # nd == 3 (plan build capped rank at 3)
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            L += 1; oln[L] = b + i*s1 + j*s2 + k*s3; mi1[L] = i; mi2[L] = j; mi3[L] = k
            L == tile && (_flush_acc_tile!(du, u, P, L); L = 0)
        end
    end
    L > 0 && _flush_acc_tile!(du, u, P, L)
    return du
end

# ---- Threaded cell axis (RFC threaded-eval-tier) ----------------------------
#
# WHY THE CELL AXIS IS THE SAFE ONE. Every tape instruction is per-LANE (`for l
# in 1:L`) and every ⊕-fold the tape hosts is WITHIN a lane: `_plan_emit!`
# declines `_NK_REDUCE` and `_NK_SUBCALL` outright, and an `_NK_CONTRACTION`
# folds a FIXED set of operand buffers at the same lane. Nothing accumulates
# across lanes, across tiles, or into `du` — each cell's value is computed from
# `u`/`p`/`t` alone and stored to exactly one `du` slot. Two consequences:
#
#   1. Tile boundaries are not observable. A cell computes the same instruction
#      sequence on the same inputs whichever tile it lands in, so splitting the
#      ordinal axis anywhere reproduces the serial values BIT FOR BIT. (This is
#      what makes a static chunk partition safe without reordering any fold.)
#   2. Chunks race only if two cells target the same `du` slot, which
#      `_plan_output_disjoint` rules out up front (see below).
#
# The KERNEL axis is deliberately NOT parallelized: separate kernels can share
# `du` slots through indirect-out / scatter merges. One `@batch` per kernel keeps
# an implicit barrier between kernels, exactly matching the serial write order.
# OPT-IN, and deliberately so. Threading the cell axis is a large WIN on an
# isolated RHS (the ReSEACT chemistry half: 4.82 -> 2.00 ms/eval at 4 threads)
# but a LOSS inside the ODE solve that RHS actually lives in: measured on the
# native ReSEACT runner at 8 threads, a 60 s window solves in 38.96 s serial and
# 67.83 s threaded (1.74x SLOWER), with identical results. The cause is the call
# PATTERN, not the kernels — the stiff half calls the RHS in short bursts
# separated by linear-algebra work, so the pool has gone to sleep by each call
# and every per-kernel dispatch pays a wake-up latency that dwarfs the few
# hundred microseconds of per-kernel work it parallelizes.
#
# So the default is OFF, and the opt-in is LOADING POLYESTER: the batch runner
# lives in `EarthSciASTPolyesterExt` and is null until the user does
# `using Polyester` (which activates the extension and calls `_set_batch_runner!`).
# `ESS_THREADS_DISABLE=1` is the hard kill switch that forces serial even with
# Polyester loaded (the `ESS_*_DISABLE` convention). Enable it (by loading
# Polyester) for RHS-dominated workloads with cell counts far above
# `ESS_THREADS_MIN_CELLS`, where per-kernel work amortizes the dispatch; measure
# the SOLVE, not the RHS, before trusting it.
_threads_disabled() = get(ENV, "ESS_THREADS_DISABLE", "") == "1"

# The `nchunks`-way static batch runner, supplied by EarthSciASTPolyesterExt when
# Polyester is loaded. Signature: `runner(chunkbody, nchunks)` calls
# `chunkbody(c)` for `c in 1:nchunks`, in parallel, with a barrier at the end.
# Null (⇒ serial path) until the extension installs it.
const _BATCH_RUNNER = Ref{Any}(nothing)
_set_batch_runner!(f) = (_BATCH_RUNNER[] = f; nothing)
@inline _polyester_loaded() = _BATCH_RUNNER[] !== nothing

# One-time per-plan threading verdicts, in the `_CASCADE_TALLY` spirit: bumped
# once per PLAN (not per eval) by `_plan_prep_threads!`. Read it via
# `EarthSciAST._THREAD_TALLY`, reset with `EarthSciAST._reset_thread_tally!()`.
#   :threaded                 — cell axis runs as `nchunks` static chunks
#   :serial_small             — fewer than 2 chunks' worth of cells
#   :serial_overlapping_outs  — two cells target the same `du` slot
const _THREAD_TALLY = Dict{Symbol,Int}()
_tally_thread!(k::Symbol) = (_THREAD_TALLY[k] = get(_THREAD_TALLY, k, 0) + 1; nothing)
_reset_thread_tally!() = (empty!(_THREAD_TALLY); nothing)

# Minimum cells per chunk. Below this a kernel is not worth a thread dispatch
# (and a whole plan below it stays serial), which keeps the many tiny kernels of
# a chemistry mechanism on the untouched serial path.
_thread_min_cells() =
    something(tryparse(Int, get(ENV, "ESS_THREADS_MIN_CELLS", "")), 512)

@inline _threads_available() =
    Threads.nthreads() > 1 && _polyester_loaded() && !_threads_disabled()

# Total cells in a cell set, in the runners' own enumeration.
function _plan_ncells(cs::_CellSet)
    _is_outs(cs) && return length(cs.outs)
    _is_contig(cs) && return length(cs.ranges[1])
    n = 1
    for r in cs.ranges
        n *= length(r)
    end
    return n
end

# Are the kernel's output slots pairwise DISTINCT? Only then may two chunks run
# concurrently: a repeated slot would make two cells read-modify-write the same
# `du` entry and the last writer would win non-deterministically. A contiguous
# set writes `du[c]` for distinct `c`, so it is disjoint by construction; a box
# is an affine map that is injective for ordinary grid strides but NOT provably
# so for arbitrary ones, and an indirect-outs set is an arbitrary scatter — both
# are checked explicitly, once, at first-call. Any duplicate ⇒ serial forever.
function _plan_output_disjoint(cs::_CellSet, ncells::Int)
    _is_contig(cs) && return true
    seen = Set{Int}()
    sizehint!(seen, ncells)
    if _is_outs(cs)
        for o in cs.outs
            o in seen && return false
            push!(seen, o)
        end
        return true
    end
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    if nd == 1
        s1 = st[1]
        for i in rg[1]
            o = b + i*s1
            o in seen && return false
            push!(seen, o)
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        for j in rg[2], i in rg[1]
            o = b + i*s1 + j*s2
            o in seen && return false
            push!(seen, o)
        end
    else
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        for k in rg[3], j in rg[2], i in rg[1]
            o = b + i*s1 + j*s2 + k*s3
            o in seen && return false
            push!(seen, o)
        end
    end
    return true
end

# One instruction clone carrying a PRIVATE boxed-fn arg buffer. `_TC_FN` is the
# only opcode with mutable per-lane state inside the instruction itself; every
# other instruction is a pure descriptor and is shared between chunks as-is.
function _clone_fn_instr(ins::_AccInstr)
    name, argbuf = ins.payload::Tuple{String,Vector{Any}}
    return _AccInstr(ins.code, ins.op, ins.dest, ins.args, ins.strides, ins.delta,
                     ins.arr, ins.conn, ins.s1, ins.s2, ins.s3, ins.off,
                     (name, copy(argbuf)))
end

# A per-chunk scratch clone of `P`: a full `_AccPlan` that SHARES every immutable
# descriptor (tile/result ids, the scalar-source table, the interp spec tables
# and the connectivity/forcing arrays hanging off the instructions) and OWNS
# every mutable per-call buffer — the lane buffers, the length-1 scalar/literal
# slots, and the oln/mi index vectors. Sharing the descriptors is what keeps a
# clone O(tile · #bufs) instead of a copy of the model's tables.
#
# Allocated ONCE per plan (first threaded call) and reused for every subsequent
# eval, which is what keeps the threaded RHS free of per-eval allocation.
function _clone_plan_scratch(P::_AccPlan)
    bufs = Vector{Vector{Float64}}(undef, length(P.bufs))
    @inbounds for i in eachindex(P.bufs)
        bufs[i] = copy(P.bufs[i])
    end
    instrs = P.instrs
    if any(ins -> ins.code === _TC_FN, instrs)
        instrs = _AccInstr[ins.code === _TC_FN ? _clone_fn_instr(ins) : ins
                           for ins in instrs]
    end
    tile = P.tile
    return _AccPlan(tile, bufs, P.scalars, instrs, P.result, P.result_stride,
                    Vector{Int}(undef, tile), Vector{Int}(undef, tile),
                    fill(1, tile), fill(1, tile), _PlanTCache())
end

# Decide once whether this plan may run threaded, and if so build its per-chunk
# scratch. Runs on the first threaded call (single-threaded, before any chunk
# starts) and short-circuits on `state != 0` thereafter.
function _plan_prep_threads!(P::_AccPlan, cs::_CellSet)
    tc = P.tcache
    tc.state == 0 || return tc
    ncells = _plan_ncells(cs)
    tc.ncells = ncells
    minc = _thread_min_cells()
    nchunks = min(Threads.nthreads(), max(1, div(ncells, max(minc, 1))))
    if nchunks < 2
        tc.state = -1                 # too few cells to be worth a dispatch
        _tally_thread!(:serial_small)
        return tc
    end
    if !_plan_output_disjoint(cs, ncells)
        tc.state = -1                 # overlapping out-slots: chunks would race
        _tally_thread!(:serial_overlapping_outs)
        return tc
    end
    ws = Any[_clone_plan_scratch(P) for _ in 1:nchunks]
    tc.ws = ws
    tc.nchunks = nchunks
    tc.state = 1
    _tally_thread!(:threaded)
    return tc
end

# Walk cell ordinals `[t0, t1)` (0-based, half-open) of `cs` with `P`'s scratch,
# tiling by `P.tile` exactly as the serial walk does. Mirrors the serial cell
# enumeration order per kind, so `[0, ncells)` reproduces it exactly; a chunk
# just takes a contiguous slice of the same ordinal axis.
function _plan_walk!(du, u, P::_AccPlan, cs::_CellSet, t0::Int, t1::Int)
    tile = P.tile
    oln = P.oln; mi1 = P.mi1; mi2 = P.mi2; mi3 = P.mi3
    t = t0
    if _is_outs(cs)
        outs = cs.outs
        while t < t1
            L = min(tile, t1 - t)
            @inbounds for l in 1:L
                c = t + l                      # 1-based cell ordinal
                oln[l] = outs[c]; mi1[l] = c
            end
            _flush_acc_tile!(du, u, P, L)
            t += L
        end
        return du
    elseif _is_contig(cs)
        lo = first(cs.ranges[1])
        while t < t1
            L = min(tile, t1 - t)
            @inbounds for l in 1:L
                s = lo + t + l - 1
                oln[l] = s; mi1[l] = s
            end
            _flush_acc_tile!(du, u, P, L)
            t += L
        end
        return du
    end
    # Strided box, in the EXACT `_run_box_kernel!` iteration order (k-outer,
    # i-inner), reached by decoding the flat ordinal instead of nesting loops.
    st = cs.strides; rg = cs.ranges; b = cs.base; nd = length(st)
    if nd == 1
        i0 = first(rg[1]); s1 = st[1]
        while t < t1
            L = min(tile, t1 - t)
            @inbounds for l in 1:L
                i = i0 + t + l - 1
                oln[l] = b + i*s1; mi1[l] = i
            end
            _flush_acc_tile!(du, u, P, L)
            t += L
        end
    elseif nd == 2
        i0 = first(rg[1]); j0 = first(rg[2]); ni = length(rg[1])
        s1 = st[1]; s2 = st[2]
        while t < t1
            L = min(tile, t1 - t)
            @inbounds for l in 1:L
                o = t + l - 1
                i = i0 + o % ni; j = j0 + o ÷ ni
                oln[l] = b + i*s1 + j*s2; mi1[l] = i; mi2[l] = j
            end
            _flush_acc_tile!(du, u, P, L)
            t += L
        end
    else # nd == 3 (plan build capped rank at 3)
        i0 = first(rg[1]); j0 = first(rg[2]); k0 = first(rg[3])
        ni = length(rg[1]); nj = length(rg[2])
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        while t < t1
            L = min(tile, t1 - t)
            @inbounds for l in 1:L
                o = t + l - 1
                i = i0 + o % ni; r = o ÷ ni
                j = j0 + r % nj; k = k0 + r ÷ nj
                oln[l] = b + i*s1 + j*s2 + k*s3
                mi1[l] = i; mi2[l] = j; mi3[l] = k
            end
            _flush_acc_tile!(du, u, P, L)
            t += L
        end
    end
    return du
end

# Run the plan's cells as `nchunks` STATIC contiguous ordinal ranges, one private
# scratch clone each. The partition is a pure function of `(ncells, nchunks)`, so
# it is identical run to run — no dynamic work stealing, nothing that could
# reorder a fold.
function _run_acc_plan_threaded!(du, u, p, t, P::_AccPlan, cs::_CellSet,
                                 tc::_PlanTCache)
    ncells = tc.ncells
    nchunks = tc.nchunks
    ws = tc.ws
    scs = P.scalars
    base = div(ncells, nchunks)
    rem = ncells - base * nchunks
    # Body for one static chunk `c`; the Polyester `@batch` over `1:nchunks` lives
    # in EarthSciASTPolyesterExt (installed via `_set_batch_runner!`). This is only
    # reached when `_threads_available()` was true, so the runner is non-null.
    run_chunk = function (c::Int)
        W = ws[c]::_AccPlan
        a = (c - 1) * base + min(c - 1, rem)
        b = c * base + min(c, rem)
        _plan_fill_scalars!(W.bufs, scs, u, p, t)
        _plan_walk!(du, u, W, cs, a, b)
        return nothing
    end
    _BATCH_RUNNER[](run_chunk, nchunks)
    return du
end
