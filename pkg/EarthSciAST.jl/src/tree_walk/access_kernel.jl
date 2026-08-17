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
# the deleted `_VecNode` overlay used, and for the same reason. A per-kernel descriptor
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
# `delta`/`idx`/… as the kind dictates), the way `_Node` shares `payload`/`idx`.
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
# that ordinal. `outs` is the same O(#cells) data the deleted `_VecKernel` out_slots
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
        return _read_param(p, nd.sym, nd.idx)
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
# (`_eval_node_op` / `_eval_acc_op` / `_oop_op`), so a mechanical op added to
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
        elseif pl isa Tuple{String,_FnTypedCoreSpec}
            # Registry-declared typed scalar core — MIRRORS compile.jl's `:fn`
            # arm: `T === Float64` folds at compile time and calls the unary
            # core directly (no `Any[]` box, bit-identical to the boxed
            # registry by construction); every other `T` keeps the boxed
            # route below verbatim (AD/traced widening unchanged).
            if T === Float64
                return _fn_typed_core_call(pl[2].id, ev(ch[1]))
            end
            args_evaluated = Any[ev(ci) for ci in ch]
            return convert(T, _eval_closed_fn(pl[1], args_evaluated, T))
        elseif pl isa Tuple{String,Nothing}
            # Undeclared all-scalar closed fn (none in the v0.3.0 set — kept
            # as the registry's boxed fallback contract). `_eval_closed_fn`
            # selects the pinned vs. AD registry on the compile-time `T` —
            # mirrors compile.jl's `:fn` arm, and keeps this arm's inference
            # (and the affine kernel's zero-alloc property) identical at
            # `T === Float64`.
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

# Content identity for a closed-function (`:fn`) payload in the vn key. Keying by
# `objectid` was sound but needlessly conservative: `_compile_fn_node` mints a fresh
# spec object per SOURCE `fn` node, so two calls over content-equal const tables
# never shared a slot. A shared slot is sound iff content-equal payloads always
# compute equal values — true here: every admitted function is a pure, deterministic
# function of (spec, scalar args), and the args are already pinned by `childvns`.
# Collision-proofing is structural, not probabilistic: `key_to_vn` is a `Dict`, which
# confirms `isequal` after the hash bucket, and this wrapper's `isequal` re-checks
# spec CONTENT — a hash collision degrades to a duplicate slot, never to aliasing
# two different tables. (`==` follows `isequal` — same NaN-tolerant contract as the
# merge guard; a table holding a NaN must still share with its content-twin.)
struct _AccFnPayKey
    fname::String
    spec::Any
end
Base.hash(k::_AccFnPayKey, h::UInt) = hash(k.fname, hash(_acc_fn_spec_hash0(k.spec), h))
Base.isequal(a::_AccFnPayKey, b::_AccFnPayKey) =
    a.fname == b.fname && _acc_fn_spec_eq(a.spec, b.spec)
Base.:(==)(a::_AccFnPayKey, b::_AccFnPayKey) = isequal(a, b)

# Spec content hash/equality behind `_AccFnPayKey`. The `Nothing`/`_Interp*Spec`
# families delegate to acc_merge.jl's `_fn_spec_hash`/`_fn_spec_content_equal` — the
# SAME matched (hash, isequal) pair the merge guard trusts. The `_Interp*LaneSpec`
# families never reach that guard (they are minted AFTER grouping, by
# `_oop_merge_fn_payload`), so acc_merge deliberately does not model them; they are
# keyed here on (per-lane spec content, s1/s2/s3/off lane addressing) — the derived
# `*_cols` fields are pure functions of `specs`, so they carry no extra identity,
# while the addressing decides WHICH lane a cell reads and so must split the key.
# `isequal ⇒ equal hash` holds arm by arm: each eq/hash pair folds the same fields.
_acc_fn_spec_hash0(s) = _fn_spec_hash(s)
_acc_fn_spec_eq(a, b) = _fn_spec_content_equal(a, b)
for (LS, seed) in ((:_InterpLinearLaneSpec, 0x44), (:_InterpBilinearLaneSpec, 0x55),
                   (:_InterpSearchsortedLaneSpec, 0x66))
    @eval function _acc_fn_spec_hash0(h::$LS)
        x = UInt($seed)
        for s in h.specs
            x = hash(_fn_spec_hash(s), x)
        end
        return hash(h.off, hash(h.s3, hash(h.s2, hash(h.s1, x))))
    end
    @eval _acc_fn_spec_eq(a::$LS, b::$LS) =
        a.s1 == b.s1 && a.s2 == b.s2 && a.s3 == b.s3 && a.off == b.off &&
        length(a.specs) == length(b.specs) &&
        all(i -> _fn_spec_content_equal(a.specs[i], b.specs[i]), eachindex(a.specs))
end

# The closed set of spec types `_acc_fn_pay_key` content-keys. Anything else —
# a spec type added without updating the methods above — stays on the IDENTITY
# path below (the pre-content behavior): declining to share costs a recompute,
# guessing costs correctness. Deliberately NOT `_acc_fn_spec_hash0 !== objectid`
# introspection — an explicit list fails closed under method-table drift too.
_acc_fn_spec_keyable(::Nothing) = true
_acc_fn_spec_keyable(::_InterpLinearSpec) = true
_acc_fn_spec_keyable(::_InterpBilinearSpec) = true
_acc_fn_spec_keyable(::_InterpSearchsortedSpec) = true
_acc_fn_spec_keyable(::_InterpLinearLaneSpec) = true
_acc_fn_spec_keyable(::_InterpBilinearLaneSpec) = true
_acc_fn_spec_keyable(::_InterpSearchsortedLaneSpec) = true
# A typed-core spec is a pure function of the fname (isbits `id`/`arity` row
# handle) — content IS the two ints, so `_fn_spec_hash`/`_fn_spec_content_equal`
# (acc_merge.jl) key it exactly.
_acc_fn_spec_keyable(::_FnTypedCoreSpec) = true
_acc_fn_spec_keyable(::Any) = false

function _acc_fn_pay_key(payload)
    if payload isa Tuple{String,Any}
        fname, spec = payload
        _acc_fn_spec_keyable(spec) && return _AccFnPayKey(fname, spec)
    end
    return objectid(payload)       # unmodelled payload — fail closed on identity
end

# Structural key: two nodes share a value number iff their keys are equal. ACCESS
# keys on descriptor CONTENT (`_desc_key`); an OP with a payload (interp `:fn`)
# keys on the payload's CONTENT (`_AccFnPayKey`, above) so content-equal specs
# minted as distinct objects still merge; unmodelled payloads key on identity.
function _acc_vn_key(n::_Node, childvns::Vector{Int}, acc::Vector{_AccDesc})
    k = n.kind
    k === _NK_ACCESS  && return (0x1, _desc_key(acc[n.idx]))
    k === _NK_LITERAL && return (0x2, reinterpret(UInt64, n.literal))
    k === _NK_PARAM   && return (0x3, n.sym)
    k === _NK_TIME    && return (0x4, :t)
    k === _NK_OP      && return (0x5, n.op,
                                 n.payload === nothing ? UInt(0) :
                                                         _acc_fn_pay_key(n.payload),
                                 childvns)
    return (0xff, objectid(n))     # _NK_CACHED / anything else — never merged
end

# A descriptor read is CELL-INVARIANT (same for every cell in the box, though it
# may vary per call) iff it is a fixed state slot, a fixed forcing read, or a
# scalar. Everything else (STATE_AFFINE, CONST_BOX/CELL/EDGE, FORCING_BOX, LOOP_IDX,
# STATE_INDIRECT[_COL]) is addressed by the cell.
@inline _acc_desc_invariant(k::UInt8) =
    k === _AK_STATE_FIXED || k === _AK_ARR_FIXED || k === _AK_SCALAR

# A `:fn` payload carrying a per-LANE spec table (`_Interp*LaneSpec` — minted
# by the direct class emitter in `_acc_merge_nodes`, or reaching a hand-built
# spine) selects per-lane data by the CELL multi-index, so the node is
# cell-VARYING even when every scalar child is invariant: hoisting it to the
# invariant tier — evaluated ONCE per call at the dummy midx (1,1,1) — would
# read lane 1's table for every lane. The post-hoc class merge pins the same
# hazard on its side (the kept-inv `nacc0` assert, oop_merge.jl); this is the
# scalarizer-side twin. Ordinary scalar specs stay hoistable exactly as before
# (no lane spec existed pre-CSE before direct emission, so the disabled build
# is byte-identical).
@inline function _acc_fn_pay_lane_varying(pl)
    pl isa Tuple && length(pl) >= 2 || return false
    s = pl[2]
    return s isa _InterpLinearLaneSpec || s isa _InterpBilinearLaneSpec ||
           s isa _InterpSearchsortedLaneSpec
end

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
                  k === _NK_OP     ? (all(v -> is_inv[v], childvns) &&
                                      !_acc_fn_pay_lane_varying(n.payload)) :
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

# ---- Threading infrastructure (RFC threaded-eval-tier) ----------------------
#
# The consumer of everything below is the CODEGEN tier's chunked cell axis
# ("Threaded cell axis for the codegen tier", codegen_kernel.jl): the section
# builder proves at build time that every emitted `du` slot is globally unique,
# and the runtime then runs the generated function as `nchunks` static
# contiguous cell-ordinal chunks. (This infrastructure predates that tier — it
# was built for the retired Float64 lane tape's per-kernel cell axis — but the
# pieces are tier-agnostic: an env-gated batch-runner hook, a verdict tally,
# and the static partition arithmetic.)
#
# WHY THE CELL AXIS IS THE SAFE ONE. Every ⊕-fold a kernel hosts is WITHIN a
# cell (`_NK_REDUCE` / `_NK_CONTRACTION` loops are per-cell); nothing
# accumulates across cells or into `du` — each cell's value is computed from
# `u`/`p`/`t` alone and stored to exactly one `du` slot. So chunk boundaries
# are not observable (any split of the ordinal axis reproduces the serial
# values BIT FOR BIT), and chunks race only if two cells target the same `du`
# slot — which the codegen build's `_cg_covered_outs_disjoint` rules out up
# front.
#
# OPT-IN, and deliberately so. Threading the cell axis is a large WIN on an
# isolated RHS but can be a LOSS inside the ODE solve that RHS actually lives
# in (measured on the native ReSEACT runner: the stiff half calls the RHS in
# short bursts separated by linear-algebra work, so the pool sleeps between
# calls and each dispatch pays a wake-up latency). The default is therefore
# OFF, and the opt-in is LOADING POLYESTER: the batch runner lives in
# `EarthSciASTPolyesterExt` and is null until the user does `using Polyester`
# (which activates the extension and calls `_set_batch_runner!`).
# `ESS_THREADS_DISABLE=1` is the hard kill switch that forces serial even with
# Polyester loaded (the `ESS_*_DISABLE` convention). Enable it (by loading
# Polyester) for RHS-dominated workloads with cell counts far above
# `ESS_THREADS_MIN_CELLS`, where per-dispatch work amortizes the wake-up;
# measure the SOLVE, not the RHS, before trusting it.
_threads_disabled() = get(ENV, "ESS_THREADS_DISABLE", "") == "1"

# The `nchunks`-way static batch runner, supplied by EarthSciASTPolyesterExt when
# Polyester is loaded. Signature: `runner(chunkbody, nchunks)` calls
# `chunkbody(c)` for `c in 1:nchunks`, in parallel, with a barrier at the end.
# Null (⇒ serial path) until the extension installs it.
const _BATCH_RUNNER = Ref{Any}(nothing)
_set_batch_runner!(f) = (_BATCH_RUNNER[] = f; nothing)
@inline _polyester_loaded() = _BATCH_RUNNER[] !== nothing

# One-time threading verdicts, in the `_CASCADE_TALLY` spirit: bumped once per
# generated SECTION (not per eval) by `_sec_prep_threads!` (codegen_kernel.jl).
# Read it via `EarthSciAST._THREAD_TALLY`, reset with
# `EarthSciAST._reset_thread_tally!()`.
#   :cg_threaded              — the section's cell axes run as static chunks
#   :cg_serial_small          — fewer than 2 chunks' worth of cells (summed
#                               across the section's emitted kernels)
#   :cg_serial_shared_outs    — two emitted cells (same or different kernel)
#                               target the same `du` slot; the section never
#                               chunks (see `_cg_covered_outs_disjoint`)
const _THREAD_TALLY = Dict{Symbol,Int}()
_tally_thread!(k::Symbol) = (_THREAD_TALLY[k] = get(_THREAD_TALLY, k, 0) + 1; nothing)
_reset_thread_tally!() = (empty!(_THREAD_TALLY); nothing)

# Minimum cells per chunk. Below this a section is not worth a thread dispatch
# (a whole section below it stays serial), which keeps small models on the
# untouched serial path.
_thread_min_cells() =
    something(tryparse(Int, get(ENV, "ESS_THREADS_MIN_CELLS", "")), 512)

@inline _threads_available() =
    Threads.nthreads() > 1 && _polyester_loaded() && !_threads_disabled()

# Total cells in a cell set, in the runners' own enumeration.
function _cellset_ncells(cs::_CellSet)
    _is_outs(cs) && return length(cs.outs)
    _is_contig(cs) && return length(cs.ranges[1])
    n = 1
    for r in cs.ranges
        n *= length(r)
    end
    return n
end

# The static partition itself: chunk `c` of `nchunks` covers the half-open
# 0-based ordinal range `[a, b)` of `n` cells, sizes differing by at most one.
# A pure function of `(n, nchunks, c)` — identical run to run, no dynamic work
# stealing, nothing that could reorder a fold. Consumed by the codegen tier's
# chunked loop emission (codegen_kernel.jl, "Threaded cell axis"): every
# emitted loop nest computes its own `[a, b)` from this exact arithmetic.
@inline function _chunk_ordinals(n::Int, c::Int, nchunks::Int)
    base = div(n, nchunks)
    rem = n - base * nchunks
    a = (c - 1) * base + min(c - 1, rem)
    b = c * base + min(c, rem)
    return a, b
end
