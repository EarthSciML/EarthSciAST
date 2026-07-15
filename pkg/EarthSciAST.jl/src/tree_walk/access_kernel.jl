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

struct _AccDesc
    kind::UInt8
    arr::Vector{Float64}   # CONST_*, ARR_FIXED (empty sentinel otherwise)
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
_AccConstCell(arr::Vector{Float64})              = _mkacc(_AK_CONST_CELL; arr=arr)
_AccConstEdge(arr::Vector{Float64}, width::Int)  = _mkacc(_AK_CONST_EDGE; arr=arr, width=width)
_AccStateFixed(idx::Int)                         = _mkacc(_AK_STATE_FIXED; idx=idx)
_AccArrFixed(arr::Vector{Float64}, idx::Int)     = _mkacc(_AK_ARR_FIXED; arr=arr, idx=idx)
_AccLoopIdx(dim::Int)                            = _mkacc(_AK_LOOP_IDX; dim=dim)
_AccScalar(v::Float64)                           = _mkacc(_AK_SCALAR; v=v)

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
    elseif k === _AK_STATE_INDIRECT
        return @inbounds u[a.conn[(c-1)*a.width + n]]
    elseif k === _AK_STATE_INDIRECT_COL
        return @inbounds u[a.conn[(c-1)*a.width + a.col]]
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
    acc::Vector{_AccDesc}      # descriptor table (spine `_NK_ACCESS.idx` indexes this)
    bound::_Bound              # reduction bound (for any _NK_REDUCE in the spine)
    zerobar::Float64           # ⊕ identity seed for the reduction (0.0 for sum)
end

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
    elseif k === _NK_PARAM
        return getfield(p, nd.sym)
    elseif k === _NK_TIME
        return t
    else # _NK_OP
        return _eval_acc_op(nd, u, p, t, c, n, oln, midx, K, T)
    end
end

# Op application over an access spine. MIRRORS `_eval_node_op` (compile.jl) arm for
# arm — same arities, same n-ary folds, same `^`/comparison/logical/elementary-fn
# semantics — because the affine path must be bit-identical to the per-cell path,
# whose spine is the SAME compiled `_Node` tree evaluated by `_eval_node_op`. The
# only difference is the leaf recursion (`_eval_acc`, which resolves `_NK_ACCESS` /
# `_NK_REDUCE`). Drift between the two tables is caught by the differential test.
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
# `T` is the value type (`_rhs_value_type(u, p, t)`); a compile-time constant at
# the call site, so at `T === Float64` every `_eval_acc` below is the monomorphic
# Float64 walk it always was, and under AD the SAME loop evaluates in `Dual`. The
# 5-arg form derives `T` (test / standalone entry point).
_run_acc_kernel!(du, u, p, t, K::_AccKernel) =
    _run_acc_kernel!(du, u, p, t, K, _rhs_value_type(u, p, t))

function _run_acc_kernel!(du, u, p, t, K::_AccKernel, ::Type{T}) where {T}
    cs = K.cells
    if _is_contig(cs)                               # contiguous / unstructured
        @inbounds for c in cs.ranges[1]
            du[c] = _eval_acc(K.spine, u, p, t, c, 0, c, (c, 1, 1), K, T)
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
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, 1, 1), K, T)
        end
    elseif nd == 2
        s1 = st[1]; s2 = st[2]
        @inbounds for j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, j, 1), K, T)
        end
    elseif nd == 3
        s1 = st[1]; s2 = st[2]; s3 = st[3]
        @inbounds for k in rg[3], j in rg[2], i in rg[1]
            oln = b + i*s1 + j*s2 + k*s3
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, (i, j, k), K, T)
        end
    else
        @inbounds for idxs in Iterators.product(rg...)
            oln = b
            for d in 1:nd; oln += idxs[d]*st[d]; end
            mi = (idxs[1], nd >= 2 ? idxs[2] : 1, nd >= 3 ? idxs[3] : 1)
            du[oln] = _eval_acc(K.spine, u, p, t, oln, 0, oln, mi, K, T)
        end
    end
    return du
end

# ---- Small builders (used by tests and, later, the polyhedral build) ----
_acc(id::Int) = _mknode(kind=_NK_ACCESS, idx=id)
_areduce(body::_Node) = _mknode(kind=_NK_REDUCE, children=_Node[body])
_aop(op::Symbol, kids::_Node...) = _mknode(kind=_NK_OP, op=op, children=collect(_Node, kids))
_alit(v::Real) = _mknode(kind=_NK_LITERAL, literal=Float64(v))
