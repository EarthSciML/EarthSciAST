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

# ---- Access descriptors: how one leaf resolves to a value at (cell c, nbr n) ----
# Signature `_fetch(a, u, c, n, oln, midx)`; every method takes all coordinates
# and uses only what it needs, so `_eval_acc` dispatches monomorphically per
# descriptor type without branching on which coordinates are live.
abstract type _Access end

# STATE, structured: u[oln + delta]. The workhorse of a Cartesian stencil.
struct _AccStateAffine <: _Access
    delta::Int
end
# STATE, unstructured: u[conn[(c-1)*width + n]]. Indirect neighbour gather.
struct _AccStateIndirect <: _Access
    conn::Vector{Int}
    width::Int
end
# STATE, unstructured self or fixed column: u[conn[(c-1)*width + col]] (col fixed).
struct _AccStateIndirectCol <: _Access
    conn::Vector{Int}
    width::Int
    col::Int
end
# CONST array, per output cell: arr[oln + delta] (structured, FULL-grid layout).
struct _AccConstAffine <: _Access
    arr::Vector{Float64}
    delta::Int
end
# CONST array on its OWN grid (possibly reduced rank): the flat array read by the
# cell's multi-index through per-dim strides — `arr[off + Σ_d (midx[d]-1)*s_d]`.
# A dim the const does not depend on gets stride 0 (broadcast); e.g. a vertical
# profile K[k] over a 3D grid is `_AccConstBox(K, 0, 0, 1, 1)`.
struct _AccConstBox <: _Access
    arr::Vector{Float64}
    s1::Int
    s2::Int
    s3::Int
    off::Int
end
# CONST array, per cell: arr[c].
struct _AccConstCell <: _Access
    arr::Vector{Float64}
end
# CONST array, per edge: arr[(c-1)*width + n] (variable-valence coefficients).
struct _AccConstEdge <: _Access
    arr::Vector{Float64}
    width::Int
end
# STATE, loop-invariant fixed slot: u[idx] — every cell in the box reads the same
# state slot (a boundary value pinned to one cell). Δ = idx-oln would vary per
# cell, so this is its own descriptor, not an `_AccStateAffine`.
struct _AccStateFixed <: _Access
    idx::Int
end
# a captured array read at a fixed linear offset: arr[idx] — an invariant forcing
# gather (`_NK_PARAM_GATHER`, constant index) broadcast to every cell.
struct _AccArrFixed <: _Access
    arr::Vector{Float64}
    idx::Int
end
# the cell's own loop index in dim `dim`, used as a numeric value: Float64(midx[dim]).
struct _AccLoopIdx <: _Access
    dim::Int
end
# a bare Float64 the cell reads directly (a hoisted invariant / literal-as-leaf).
struct _AccScalar <: _Access
    v::Float64
end

@inline _fetch(a::_AccStateAffine,      u, c, n, oln, midx) = @inbounds u[oln + a.delta]
@inline _fetch(a::_AccStateIndirect,    u, c, n, oln, midx) = @inbounds u[a.conn[(c-1)*a.width + n]]
@inline _fetch(a::_AccStateIndirectCol, u, c, n, oln, midx) = @inbounds u[a.conn[(c-1)*a.width + a.col]]
@inline _fetch(a::_AccStateFixed,       u, c, n, oln, midx) = @inbounds u[a.idx]
@inline _fetch(a::_AccConstAffine,      u, c, n, oln, midx) = @inbounds a.arr[oln + a.delta]
@inline _fetch(a::_AccConstBox,         u, c, n, oln, midx) =
    @inbounds a.arr[a.off + (midx[1]-1)*a.s1 + (midx[2]-1)*a.s2 + (midx[3]-1)*a.s3]
@inline _fetch(a::_AccConstCell,        u, c, n, oln, midx) = @inbounds a.arr[c]
@inline _fetch(a::_AccConstEdge,        u, c, n, oln, midx) = @inbounds a.arr[(c-1)*a.width + n]
@inline _fetch(a::_AccArrFixed,         u, c, n, oln, midx) = @inbounds a.arr[a.idx]
@inline _fetch(a::_AccLoopIdx,          u, c, n, oln, midx) = Float64(midx[a.dim])
@inline _fetch(a::_AccScalar,           u, c, n, oln, midx) = a.v

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
struct _CellSet
    strides::Vector{Int}
    ranges::Vector{UnitRange{Int}}
    base::Int
end
_contig_cells(ncell::Int) = _CellSet(Int[], UnitRange{Int}[1:ncell], 0)
@inline _is_contig(cs::_CellSet) = isempty(cs.strides)

# ---- One kernel ----
struct _AccKernel
    cells::_CellSet
    spine::_Node               # op tree with _NK_ACCESS / _NK_REDUCE leaves
    acc::Vector{_Access}       # descriptor table (spine `_NK_ACCESS.idx` indexes this)
    bound::_Bound              # reduction bound (for any _NK_REDUCE in the spine)
    zerobar::Float64           # ⊕ identity seed for the reduction (0.0 for sum)
end

# ---- The evaluator (foundation: Float64; AD genericity is a later step) ----
# `t` current time, `c` cell ordinal, `n` neighbour index (0 outside a
# reduction), `oln` output slot, `midx` the cell's (i,j,k) loop multi-index
# (padded with 1s).
function _eval_acc(nd::_Node, u, p, t, c::Int, n::Int, oln::Int,
                   midx::NTuple{3,Int}, K::_AccKernel)::Float64
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
            s += _eval_acc(body, u, p, t, c, m, oln, midx, K)
        end
        return s
    elseif k === _NK_PARAM
        return Float64(getproperty(p, nd.sym))
    elseif k === _NK_TIME
        return Float64(t)
    else # _NK_OP
        return _eval_acc_op(nd, u, p, t, c, n, oln, midx, K)
    end
end

# Op application over an access spine. MIRRORS `_eval_node_op` (compile.jl) arm for
# arm — same arities, same n-ary folds, same `^`/comparison/logical/elementary-fn
# semantics — because the affine path must be bit-identical to the per-cell path,
# whose spine is the SAME compiled `_Node` tree evaluated by `_eval_node_op`. The
# only difference is the leaf recursion (`_eval_acc`, which resolves `_NK_ACCESS` /
# `_NK_REDUCE`). Drift between the two tables is caught by the differential test.
function _eval_acc_op(nd::_Node, u, p, t, c::Int, n::Int, oln::Int,
                      midx::NTuple{3,Int}, K::_AccKernel)::Float64
    op = nd.op
    ch = nd.children
    @inline ev(x) = _eval_acc(x, u, p, t, c, n, oln, midx, K)
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
    elseif op === :/
        return ev(ch[1]) / ev(ch[2])
    elseif op === :^ || op === :pow
        return ev(ch[1]) ^ ev(ch[2])

    # Comparisons → 1.0/0.0
    elseif op === :<;            return ev(ch[1]) <  ev(ch[2]) ? 1.0 : 0.0
    elseif op === Symbol("<=");  return ev(ch[1]) <= ev(ch[2]) ? 1.0 : 0.0
    elseif op === :>;            return ev(ch[1]) >  ev(ch[2]) ? 1.0 : 0.0
    elseif op === Symbol(">=");  return ev(ch[1]) >= ev(ch[2]) ? 1.0 : 0.0
    elseif op === Symbol("==");  return ev(ch[1]) == ev(ch[2]) ? 1.0 : 0.0
    elseif op === Symbol("!=");  return ev(ch[1]) != ev(ch[2]) ? 1.0 : 0.0

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

    # Elementary functions
    elseif op === :sin;   return sin(ev(ch[1]))
    elseif op === :cos;   return cos(ev(ch[1]))
    elseif op === :tan;   return tan(ev(ch[1]))
    elseif op === :asin;  return asin(ev(ch[1]))
    elseif op === :acos;  return acos(ev(ch[1]))
    elseif op === :atan
        length(ch) == 1 && return atan(ev(ch[1]))
        length(ch) == 2 && return atan(ev(ch[1]), ev(ch[2]))
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2; return atan(ev(ch[1]), ev(ch[2]))
    elseif op === :sinh;  return sinh(ev(ch[1]))
    elseif op === :cosh;  return cosh(ev(ch[1]))
    elseif op === :tanh;  return tanh(ev(ch[1]))
    elseif op === :asinh; return asinh(ev(ch[1]))
    elseif op === :acosh; return acosh(ev(ch[1]))
    elseif op === :atanh; return atanh(ev(ch[1]))
    elseif op === :exp;   return exp(ev(ch[1]))
    elseif op === :log;   return log(ev(ch[1]))
    elseif op === :log10; return log10(ev(ch[1]))
    elseif op === :sqrt;  return sqrt(ev(ch[1]))
    elseif op === :abs;   return abs(ev(ch[1]))
    elseif op === :sign;  return sign(ev(ch[1]))
    elseif op === :floor; return floor(ev(ch[1]))
    elseif op === :ceil;  return ceil(ev(ch[1]))
    elseif op === :min
        length(ch) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        s = ev(ch[1]); @inbounds for i in 2:length(ch); s = min(s, ev(ch[i])); end
        return s
    elseif op === :max
        length(ch) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        s = ev(ch[1]); @inbounds for i in 2:length(ch); s = max(s, ev(ch[i])); end
        return s
    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)
    elseif op === :Pre
        return ev(ch[1])
    end
    throw(TreeWalkError("E_TREEWALK_ACC_UNSUPPORTED_OP", String(op)))
end

# ---- Run one kernel into du (in place) ----
function _run_acc_kernel!(du, u, p, t, K::_AccKernel)
    cs = K.cells
    if _is_contig(cs)                               # contiguous / unstructured
        @inbounds for c in cs.ranges[1]
            du[c] = _eval_acc(K.spine, u, p, t, c, 0, c, (c, 1, 1), K)
        end
    else                                            # structured: strided box walk
        _run_box_kernel!(du, u, p, t, K, cs)
    end
    return du
end

# Nested loop over a Cartesian box; rank ≤ 3 (the latlon3d ceiling) is unrolled
# for a tight `oln`, with a product-based fallback for higher rank.
function _run_box_kernel!(du, u, p, t, K::_AccKernel, cs::_CellSet)
    st = cs.strides
    rg = cs.ranges
    b  = cs.base
    nd = length(st)
    if nd == 1
        s1 = st[1]
        @inbounds for i in rg[1]
            oln = b + i*s1
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, 1, 1), K)
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, j, 1), K)
        end
    elseif nd == 3
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2 + k*s3
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, j, k), K)
        end
    else
        @inbounds for idxs in Iterators.product(rg...)
            oln = b
            for d in 1:nd; oln += idxs[d]*st[d]; end
            mi = (idxs[1], nd >= 2 ? idxs[2] : 1, nd >= 3 ? idxs[3] : 1)
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, mi, K)
        end
    end
    return du
end

# ---- Small builders (used by tests and, later, the polyhedral build) ----
_acc(id::Int) = _mknode(kind=_NK_ACCESS, idx=id)
_areduce(body::_Node) = _mknode(kind=_NK_REDUCE, children=_Node[body])
_aop(op::Symbol, kids::_Node...) = _mknode(kind=_NK_OP, op=op, children=collect(_Node, kids))
_alit(v::Real) = _mknode(kind=_NK_LITERAL, literal=Float64(v))
