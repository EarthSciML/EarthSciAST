# tree_walk/node.jl — the compiled IR's node type `_Node`, its kind constants and
# run-time payloads, the gather node constructors and the two identity maps.

# ============================================================
# 3. Compiled-IR — one-shot compilation to a compact, type-stable tree
# ============================================================
#
# Walking the raw `OpExpr` tree would make every op dispatch a chain of
# String comparisons and every VarExpr lookup a Dict probe. `_compile` walks
# the expression once at build time and produces `_Node` trees where:
#
#   * op is a `Symbol` (pointer compare, not byte compare)
#   * state refs have their u-index baked in
#   * parameter refs have their `Val{sym}` type param baked in for
#     `getfield(p, Val)` — monomorphic NamedTuple access
#   * literals are pre-promoted to Float64
#
# The compiled tree keeps the semantics of the expression it was compiled
# from; `_eval_node` walks it.

# _NKind encodes what a node is. Keeping it as a Bare integer (UInt8)
# gives a fast `kind === K_*` dispatch inside `_eval_node`.
const _NK_LITERAL = UInt8(1)
const _NK_STATE = UInt8(2)   # read u[idx]
const _NK_PARAM = UInt8(3)   # read p.<sym>
const _NK_TIME = UInt8(4)   # return t
const _NK_OP = UInt8(5)   # apply op to children
const _NK_CONTRACTION = UInt8(6)   # runtime ⊕-reduction over children (seq. fold)
const _NK_CACHED = UInt8(7)   # common-subexpression ref: read cache[idx]
const _NK_PARAM_GATHER = UInt8(8)   # read a captured live forcing buffer: payload[idx]
const _NK_CONST_GATHER = UInt8(9)   # read a captured const/provider array at an EVAL-TIME-computed offset
const _NK_LOOPVAR = UInt8(10)  # read the current value of an enclosing runtime contraction loop counter
const _NK_CONTRACTION_LOOP = UInt8(11)  # compile-once ⊕-reduction: iterate a static range, fold ONE body per iteration
const _NK_STATE_GATHER = UInt8(12)  # read u at a slot computed at eval time from loop-var-dependent subscripts
const _NK_RECUR_GATHER = UInt8(13)  # a recurrence's causal self-read: a PUBLISHED cell of its own buffer, or a fault (recurrence_sweep.jl)
const _NK_RAGGED_LOOP = UInt8(14)  # ⊕-reduction over a range whose bounds are evaluated per call (a ragged `offsets` bound), seeded from 0̄
const _NK_LIVE_GATHER = UInt8(15)  # read a captured live forcing buffer at an EVAL-TIME-computed offset (a loop-var subscript)
const _NK_CALL = UInt8(16)  # call a compiled template instance (call.jl): payload = _CallSite, children = its arguments
const _NK_ARG = UInt8(17)   # read argument `idx` of the innermost running call of `payload::_CallTarget` (call.jl)
const _NK_ARG_GATHER = UInt8(18)  # read an ARRAY argument of the running call at the subscripts `children` (payload = _ArgGatherRef, call.jl)

# The ONE compiled IR node — scalar spines and access-kernel spines are both trees
# of these. `kind` selects which fields are live. The catch-all `payload::Any` slot
# carries a KIND-DEPENDENT runtime payload, type-asserted at its read sites
# (`_eval_node` / `_eval_node_op`, `_eval_acc` / `_eval_acc_op`, the out-of-place
# walkers, and the lowerings `_acc_merge_nodes` (acc_merge.jl) / `_lower_to_access`
# (stencil_affine.jl)). NOTE: this `Any` slot is what forces
# `Enzyme.API.strictAliasing!(false)` for reverse-mode AD on the CPU — see
# scripts/enzyme_aliasing/ for the measurement and what a payload-free lowering
# would and would not buy:
#   * `_NK_PARAM_GATHER` — the aliased flat `Vector{Float64}` of a live
#     forcing buffer (`_PGatherArray.flat`); `idx` holds the
#     pre-linearized column-major offset.
#   * `_NK_CONST_GATHER` — a `_ConstGatherArray`: the flattened
#     const/provider array plus its column-major strides. The subscripts are the
#     node's `children` (subscript `_Node`s) and the column-major offset is
#     computed AT EVAL TIME from them, so a runtime-varying subscript (e.g. a
#     bound output index) selects a different element without a rebuild.
#   * `_NK_LIVE_GATHER` — a `_ConstGatherArray` whose `flat` ALIASES a live
#     forcing buffer (`_PGatherArray.flat`) rather than a frozen const array: the
#     offset is computed at eval time from the subscript `children`, like
#     `_NK_CONST_GATHER`, and the element is read from the buffer as it is at
#     that call, like `_NK_PARAM_GATHER`. A kind of its own so that no pass that
#     reads a `_NK_CONST_GATHER` as build-time data (a per-entry value column, a
#     gate fixed while `p` is, the const tier) can take it for one.
#   * `_NK_CACHED` — the shared CSE scratch (`_CSECache`); `idx` holds
#     the value-number slot.
#   * `_NK_CONTRACTION_LOOP` — `_ContractLoop`; `_NK_RAGGED_LOOP` — `_RaggedLoop`;
#     `_NK_STATE_GATHER` — `_StateGather`; `_NK_RECUR_GATHER` — the recurrence's
#     gather; `_NK_LOOPVAR` — the loop counter's `Base.RefValue{Int}`.
#   * the access-kernel kinds (access_kernel.jl): `_NK_SUBCALL` — an `_AccKernel`, `_NK_AREDUCE` — an `_AReduceSpec`.
#   * `_NK_CALL` — the `_CallSite` (target and array arguments) called;
#     `_NK_ARG` — the `_CallTarget` whose argument it reads; `_NK_ARG_GATHER` —
#     an `_ArgGatherRef` (call.jl).
#   * `_NK_OP` — `nothing`, except the setup-time geometry operators
#     (`:geo_gather`, `:geo_agg`, `:geo_count`, `:geomemo`, `:cellmemo`), which exist
#     only in build-time geometry bodies and carry their source or spec.
#   * every other kind — `nothing`.
#
# A pass that branches on `kind` ends in `_unknown_kind`, never in a catch-all
# arm that treats an unlisted kind as an operator.
struct _Node
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    payload::Any
    children::Vector{_Node}
end

# A map keyed by `_Node` with `IdDict` semantics (keys equal iff `===`). An
# `IdDict` hashes an immutable key by its whole content through `objectid`,
# which costs microseconds per `_Node`; this hashes the fields that tell nodes
# apart cheaply (the children vector and the payload by `objectid`, which for a
# mutable object is its address) and compares with `===`. Iteration order is
# unspecified, as for `IdDict`.
struct _NodeKey
    n::_Node
end
Base.:(==)(a::_NodeKey, b::_NodeKey) = a.n === b.n
Base.isequal(a::_NodeKey, b::_NodeKey) = a.n === b.n
Base.hash(k::_NodeKey, h::UInt) = hash(
    objectid(k.n.children),
    hash(objectid(k.n.payload), hash(k.n.op, hash(k.n.idx, hash(reinterpret(UInt64, k.n.literal), h))))
)

struct _NodeMap{V}
    d::Dict{_NodeKey, V}
end
_NodeMap{V}() where {V} = _NodeMap{V}(Dict{_NodeKey, V}())
Base.get(m::_NodeMap, n::_Node, default) = get(m.d, _NodeKey(n), default)
Base.get!(f::Function, m::_NodeMap, n::_Node) = get!(f, m.d, _NodeKey(n))
Base.get!(m::_NodeMap, n::_Node, default) = get!(m.d, _NodeKey(n), default)
Base.getindex(m::_NodeMap, n::_Node) = m.d[_NodeKey(n)]
Base.setindex!(m::_NodeMap, v, n::_Node) = (m.d[_NodeKey(n)] = v; m)
Base.haskey(m::_NodeMap, n::_Node) = haskey(m.d, _NodeKey(n))
Base.empty!(m::_NodeMap) = (empty!(m.d); m)
Base.length(m::_NodeMap) = length(m.d)
Base.isempty(m::_NodeMap) = isempty(m.d)
Base.values(m::_NodeMap) = values(m.d)
Base.keys(m::_NodeMap) = (k.n for k in keys(m.d))
function Base.iterate(m::_NodeMap, st...)
    r = iterate(m.d, st...)
    r === nothing && return nothing
    (k, v), s = r
    return (k.n => v, s)
end

# Resolve's marker for a live forcing gather at a build-constant offset, carried
# in the `value` of an argless `index` node between the resolve and compile
# passes. The `index` op is CSE-opaque, but `_cse_key` still keys its ancestors,
# whose canonical JSON would carry this value; it therefore has a canonicalizable
# identity (`name`), which `_cse_key` swaps in (`_pgather_key_expr`).
struct _PGatherRef
    flat::Vector{Float64}   # aliased flat view of the caller's live buffer
    lin::Int                # pre-linearized column-major offset into `flat`
    # The buffer's `pgather` key, the gather's CSE identity: names are distinct
    # dictionary keys, so two gathers share `(name, lin)` exactly when they read
    # the same offset of the same buffer.
    name::String
end

# Resolve's marker for a const or provider array read at a subscript that is
# not a build constant (`_subscript_is_runtime`): a bound output index of a
# symbolic resolve, or a parameter, a state or `t`. The `index` node's `args`
# are the resolved subscripts, and `_compile` lowers it to a `_NK_CONST_GATHER`
# (`_const_gather_node`). The CSE keyer keys it by the array's identity
# (`_cse_value_key`).
struct _ConstGatherRef
    vals::AbstractArray   # the frozen const/provider source array (read at eval time)
    name::String          # its `const_arrays` registry name — diagnostics / identity
end

# Resolve's marker for a live forcing gather whose subscripts are not all build
# constants (a loop counter of a symbolic resolve): the `index` node's `args`
# are the resolved subscripts, and `_compile` lowers it to a `_NK_LIVE_GATHER`
# (`_live_gather_node`).
struct _LiveGatherRef
    flat::Vector{Float64}   # the aliased flat buffer (`_PGatherArray.flat`), read at eval time
    dims::Vector{Int}       # its shape: each subscript is checked against its own axis
    name::String            # its `pgather` registry name, for `E_TREEWALK_PGATHER_OOB`
end

# Payload of an `_NK_CONTRACTION_LOOP` node: a uniform reduction over
# `lo:step:hi` with one compiled body, iterated at evaluation time, so the build
# is O(1) in the reduction length. `ref` is the counter every `_NK_LOOPVAR` leaf
# of the body reads. The fold's ⊕ is the node's `op`, seeded from 0̄ in its
# `literal`, in the unroll's order (`_eval_contraction_loop`).
struct _ContractLoop
    ref::Base.RefValue{Int}
    lo::Int
    hi::Int
    step::Int
end

# A reduction over ONE contracted index whose bounds are themselves nodes,
# evaluated on every call: a ragged range `[1, index(offsets, i)]` read inside an
# array equation whose output index `i` is a loop counter of the whole-array
# contraction tier (`_resolve_index_of_faq`'s symbolic path). The node is
# `_NK_RAGGED_LOOP` with `children = [body, lo, hi]`; `step` is a build constant.
#
# The fold is the one the per-cell build writes for the same gather,
# `_combine_with_reducer` over the expanded terms: seeded from 0̄, the terms
# folded into it left to right (`acc = acc ⊕ term`), so no term gives 0̄ and an
# all `-0.0` row under `+` gives `+0.0` (esm-spec §4.3.1). `reach` estimates the
# iterations per call for the threading verdict's work count
# (`_node_loop_reach`).
struct _RaggedLoop
    ref::Base.RefValue{Int}
    step::Int
    reach::Int
end

# Payload of an `_NK_STATE_GATHER` node: a state read at a slot computed at eval
# time from the subscript `children` (a loop counter, or an indirect
# `index(conn, i, k)`). The cell at column-major offset `off` from `lo` is slot
# `run_base + off` when the cells are one ascending run of slots (an array laid
# out as one block), else `slot_flat[off + 1]`; `slot_flat` is empty for a run.
# A subscript outside `[lo, hi]` is a ghost cell and reads 0, as the unroll's
# out-of-range read does.
struct _StateGather
    slot_flat::Vector{Int}
    run_base::Int
    strides::Vector{Int}
    lo::Vector{Int}
    hi::Vector{Int}
    len::Int
end

# ── A recurrence's causal self-read (esm-spec §4.3.1.1; recurrence_sweep.jl) ──
# The payload of an `_NK_RECUR_GATHER` node. The subscripts are the node's
# `children`; each is checked against its axis of the box the sweep fills
# (`lo[d]…lo[d]+dims[d]-1`: the recurrence's whole frame, or in a
# range-restricted program the cells it needs, recurrence_sweep.jl), and the
# cell it names is then read only if the sweep has
# already PUBLISHED it — its position in the sweep order (`sweep_w`, the weight of
# each axis in that order) is before `cur[]`, the position of the cell being
# evaluated. Anything else is `E_TREEWALK_RECUR_UNAVAILABLE`: never the zero
# ghost an out-of-range state gather reads (CONFORMANCE_SPEC §5.19.4). `base` and
# `strides` address the observed's buffer block in the extended value vector.
@inline _sg_slot(sg::_StateGather, off::Int) =
    sg.run_base != 0 ? sg.run_base + off : @inbounds(sg.slot_flat[off + 1])

struct _RecurGather
    name::String
    lo::Vector{Int}
    dims::Vector{Int}
    sweep_w::Vector{Int}
    base::Int
    strides::Vector{Int}
    cur::Base.RefValue{Int}
end

# What resolve decided for a run-time loop or gather that the expression
# language cannot spell, carried to `_compile` in the `value` of a marker op
# (`__contract_loop`, `__ragged_loop`, `__state_gather`, `__recur_read`): the
# node's kind, ⊕ and 0̄ for a fold, and its run-time payload. The marker's
# `args` compile as the node's children. It exists only between the resolve and
# compile passes of one build.
struct _Lowered
    kind::UInt8
    op::Symbol
    literal::Float64
    payload::Any
end
_Lowered(kind::UInt8, payload) = _Lowered(kind, Symbol(""), 0.0, payload)

function _mknode(;
        kind::UInt8, op::Symbol = Symbol(""),
        literal::Float64 = 0.0, idx::Int = 0,
        sym::Symbol = Symbol(""), payload = nothing,
        children::Vector{_Node} = _Node[]
    )
    return _Node(kind, op, literal, idx, sym, payload, children)
end

# Payload of a `_NK_CONST_GATHER` node: the source array flattened column-major
# with its strides, so the offset is computed from the subscript `children` at
# each evaluation. All fields are concrete, so the evaluator's arm allocates
# nothing.
struct _ConstGatherArray
    flat::Vector{Float64}   # column-major flattening of the source array (== vec(A))
    strides::Vector{Int}    # column-major strides: strides[d] = prod(size(A)[1:d-1])
    dims::Vector{Int}       # size(A): each subscript is checked against its own axis
    boundary::Vector{Symbol}  # per-axis policy (`_const_dim_boundary`) for an out-of-range subscript
    name::String            # the array's registry name, for `E_TREEWALK_CONSTARRAY_OOB`
    _ConstGatherArray(flat, strides, dims, boundary, name) =
        _new_typed(_ConstGatherArray, flat, strides, dims, boundary, name)
end
_def_new_typed(_ConstGatherArray)

# A `_NK_CONST_GATHER` node reading `A` at `subscript_nodes`, one per dimension
# of `A`, which become the node's children.
function _const_gather_node(
        A::AbstractArray, subscript_nodes::Vector{_Node};
        name::AbstractString = ""
    )
    sz = size(A)
    length(subscript_nodes) == length(sz) || throw(
        ArgumentError(
            "_const_gather_node: expected $(length(sz)) subscript node(s) for a " *
                "$(length(sz))-D array, got $(length(subscript_nodes))"
        )
    )
    return _mknode(
        kind = _NK_CONST_GATHER, payload = _const_gather_payload(A, name),
        children = subscript_nodes
    )
end

# The `_ConstGatherArray` of a const array `A` (registry name `name`).
function _const_gather_payload(A::AbstractArray, name::AbstractString)
    sz = size(A)
    # Share the source array's buffer rather than copy it: an unrolled
    # contraction lowers one gather per term, so a copy per call is
    # O(terms · sizeof(A)). Const arrays are read-only at run time, so aliasing
    # is safe; a non-dense or non-`Float64` input is converted once.
    flat = A isa Vector{Float64} ? A :
        A isa Array{Float64} ? vec(A)::Vector{Float64} :
        Vector{Float64}(vec(A))
    strides = Vector{Int}(undef, length(sz))
    acc = 1
    @inbounds for d in eachindex(sz)
        strides[d] = acc
        acc *= sz[d]
    end
    boundary = Symbol[_const_dim_boundary(A, d) for d in eachindex(sz)]
    return _ConstGatherArray(flat, strides, collect(Int, sz), boundary, String(name))
end

# The `_NK_LIVE_GATHER` of a `_LiveGatherRef`: the buffer itself (never a copy,
# a data refresh writes it in place), its column-major strides, and the `:live`
# boundary on every axis, under which an out-of-range subscript raises the
# forcing gather's own `E_TREEWALK_PGATHER_OOB` when the read is evaluated.
function _live_gather_node(ref::_LiveGatherRef, subscript_nodes::Vector{_Node})
    nd = length(ref.dims)
    length(subscript_nodes) == nd || throw(
        ArgumentError(
            "_live_gather_node: expected $nd subscript node(s), got $(length(subscript_nodes))"
        )
    )
    strides = Vector{Int}(undef, nd)
    acc = 1
    for d in 1:nd
        strides[d] = acc
        acc *= ref.dims[d]
    end
    return _mknode(
        kind = _NK_LIVE_GATHER,
        payload = _ConstGatherArray(
            ref.flat, strides, copy(ref.dims), fill(:live, nd), ref.name
        ),
        children = subscript_nodes
    )
end

# The 1-based position a run-time const gather reads on axis `d` for subscript
# `sub`, resolved exactly as a build-time fold resolves it (`_resolve_const_index`).
# Each axis is checked against its OWN extent: the linearized offset alone lets an
# overflow on one axis land inside the array and read a neighbouring element.
@inline function _const_gather_sub(cg::_ConstGatherArray, d::Int, sub::Int)
    n = @inbounds cg.dims[d]
    (1 <= sub <= n) && return sub
    return _resolve_const_index_oob(@inbounds(cg.boundary[d]), cg.name, d, sub, n)
end

# ---- An identity map over `_Node` keys ------------------------------------------
# `_Node` is immutable, so an `IdDict` keyed by one boxes the node on every
# lookup and insert (a heap object per access) and hashes all of its fields.
# The build's per-box walks (`_lower_to_access`, `_dag_postorder` under
# `_build_acc_cse`) touch every node of a spine several times, which made these
# boxes a large share of the build's allocation. This map files a node under the
# address of its `children` vector, a mutable object every node holds, and
# compares the keys of a bucket with `===`, the same equality an `IdDict` uses:
# two nodes are one key exactly when they are `===`, and nodes that are `===`
# hold the same `children` vector, so they always meet in one bucket.
#
# The bucket spread rests on one invariant: distinct nodes hold distinct
# `children` vectors. Every builder today allocates a fresh vector per node
# (`_mknode`'s default `_Node[]` is evaluated per call, and the rebuilding
# passes allocate `ch`/`kids` per node). A node sharing another's vector costs
# speed only (a longer chain), never a wrong answer. The likely way to break
# it is a constant empty vector shared by many leaves, so a leaf's bucket also
# mixes in its scalar fields: `===` leaves have equal fields, so they still
# meet, while leaves of different kind, index, literal or symbol spread out
# even over one shared vector.
struct _NodeIdMap{V}
    head::Dict{UInt, Int}       # bucket → its newest entry
    keys::Vector{_Node}
    vals::Vector{V}
    next::Vector{Int}           # the bucket's next older entry (0: none)
end
_NodeIdMap{V}() where {V} = _NodeIdMap{V}(Dict{UInt, Int}(), _Node[], V[], Int[])
@inline function _node_bucket(n::_Node)
    h = UInt(pointer_from_objref(n.children))
    isempty(n.children) || return h
    return hash(n.idx, hash(reinterpret(UInt64, n.literal), hash(n.sym, hash(n.op, h ⊻ n.kind))))
end
@inline function _nim_index(m::_NodeIdMap, n::_Node)
    i = get(m.head, _node_bucket(n), 0)
    while i != 0
        @inbounds m.keys[i] === n && return i
        i = @inbounds m.next[i]
    end
    return 0
end
Base.haskey(m::_NodeIdMap, n::_Node) = _nim_index(m, n) != 0
Base.length(m::_NodeIdMap) = length(m.keys)
function Base.getindex(m::_NodeIdMap, n::_Node)
    i = _nim_index(m, n)
    i == 0 && throw(KeyError(n))
    return @inbounds m.vals[i]
end
function Base.get(m::_NodeIdMap, n::_Node, default)
    i = _nim_index(m, n)
    return i == 0 ? default : @inbounds m.vals[i]
end
function Base.setindex!(m::_NodeIdMap, v, n::_Node)
    i = _nim_index(m, n)
    if i != 0
        @inbounds m.vals[i] = v
    else
        h = _node_bucket(n)
        push!(m.keys, n)
        push!(m.vals, v)
        push!(m.next, get(m.head, h, 0))
        m.head[h] = length(m.keys)
    end
    return m
end
# The identity map a walk over nodes of type `N` keys by: `_NodeIdMap` for
# `_Node`, an `IdDict` for the mutable expression types.
_identity_map(::Type{_Node}, ::Type{V}) where {V} = _NodeIdMap{V}()
_identity_map(::Type{N}, ::Type{V}) where {N, V} = IdDict{N, V}()
