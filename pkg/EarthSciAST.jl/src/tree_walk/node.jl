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
const _NK_CACHED = UInt8(7)   # common-subexpression ref: read cache[idx] (ess-r7h)
const _NK_PARAM_GATHER = UInt8(8)   # read a captured live forcing buffer: payload[idx] (ess-14f.3)
const _NK_CONST_GATHER = UInt8(9)   # read a captured const/provider array at an EVAL-TIME-computed offset (wall2 Phase B)
const _NK_LOOPVAR = UInt8(10)  # read the current value of an enclosing runtime contraction loop counter (ess-runtime-contraction)
const _NK_CONTRACTION_LOOP = UInt8(11)  # compile-once ⊕-reduction: iterate a static range, fold ONE body per iteration (ess-runtime-contraction)
const _NK_STATE_GATHER = UInt8(12)  # read u at a slot computed at eval time from loop-var-dependent subscripts (ess-runtime-contraction)
const _NK_RECUR_GATHER = UInt8(13)  # a recurrence's causal self-read: a PUBLISHED cell of its own buffer, or a fault (recurrence_sweep.jl)
const _NK_RAGGED_LOOP = UInt8(14)  # ⊕-reduction over a range whose bounds are evaluated per call (a ragged `offsets` bound), seeded from 0̄
const _NK_LIVE_GATHER = UInt8(15)  # read a captured live forcing buffer at an EVAL-TIME-computed offset (a loop-var subscript)

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
#     forcing buffer (`_PGatherArray.flat`, ess-14f.3); `idx` holds the
#     pre-linearized column-major offset.
#   * `_NK_CONST_GATHER` — a `_ConstGatherArray` (wall2 Phase B): the flattened
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
#   * `_NK_CACHED` — the shared CSE scratch (`_CSECache`, ess-r7h); `idx` holds
#     the value-number slot.
#   * `_NK_CONTRACTION_LOOP` — `_ContractLoop`; `_NK_RAGGED_LOOP` — `_RaggedLoop`;
#     `_NK_STATE_GATHER` — `_StateGather`; `_NK_RECUR_GATHER` — the recurrence's
#     gather; `_NK_LOOPVAR` — the loop counter's `Base.RefValue{Int}`.
#   * the access-kernel kinds (access_kernel.jl): `_NK_REDUCE` — a `_Bound`,
#     `_NK_SUBCALL` — an `_AccKernel`, `_NK_AREDUCE` — an `_AReduceSpec`.
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

# Build-time side channel from `_resolve_indices` to `_compile` (ess-14f.3): a
# RESOLVED live-forcing gather, carried in the `value` slot of a synthetic
# argless `index` node. It exists only between the resolve and compile passes of
# one build and never reaches the SERIALIZER — but it does reach `canonical_json`,
# which is a different thing and was the bug (ess-qic): the `index` op being
# CSE-opaque only stops the gather from being hoisted ITSELF; `_cse_key` still
# canonicalizes every hoistable ANCESTOR of it, and a canonical node emits its
# `value` field. A raw `_PGatherRef` there is not a JSON type, so `canonical_json`
# threw `E_CANONICAL_BAD_CONST`, `_cse_key` caught it and declined — silently
# switching CSE off for every expression built over a live forcing buffer. The
# gather therefore carries a CANONICALIZABLE identity (`name`, below) alongside its
# runtime payload; `_cse_key` swaps the ref for a stand-in node built from it.
#
# A dedicated wrapper type (not a raw `(Vector{Float64}, Int)` tuple) makes the
# payload type-checkable and greppable at both ends of the channel.
struct _PGatherRef
    flat::Vector{Float64}   # aliased flat view of the caller's live buffer
    lin::Int                # pre-linearized column-major offset into `flat`
    # The buffer's registry name — its key in the build's `pgather` dict, which is
    # what makes it the gather's CSE identity (see `_pgather_key_expr`). Distinct
    # buffers necessarily have distinct names (they are Dict KEYS), so two gathers
    # collide on `(name, lin)` iff they read the same offset of the same buffer.
    # That distinctness is a Dict invariant rather than a hand-maintained counter,
    # which matters: a collision here would not lose sharing, it would MERGE two
    # different reads and produce silently wrong numbers.
    name::String
end

# Build-time side channel from `_resolve_indices` to `_compile` (wall2 Phase C):
# the const/provider-array analogue of `_PGatherRef`. A `_ConstGatherRef` is
# emitted for a `index(const_array, subs…)` read whose subscripts are NOT all
# build-time constants — at least one references a BOUND OUTPUT-INDEX symbol kept
# SYMBOLIC through the aggregate unrolling (the compile-once `evaluate_cellwise`
# fast path binds the output indices as parameters). It is carried in the `value`
# slot of an `index` node whose `args` are the RESOLVED subscript expressions
# (concrete `IntExpr` for constant dims, the bound `VarExpr` / arithmetic for the
# runtime dim(s)); `_compile`'s `index` branch compiles each subscript arg as a
# child and lowers the node to a `_NK_CONST_GATHER` via `_const_gather_node`, so
# the column-major offset is recomputed AT EVAL TIME from the (now runtime) output
# index — no per-cell re-resolve/re-compile.
#
# Unlike `_PGatherRef` (a LIVE buffer read at a FIXED offset) this reads a FROZEN
# const array at a RUNTIME-computed offset. Like `_PGatherRef` it exists only
# between the resolve and compile passes of one build. It is created for any
# subscript that is not a build-time constant (`_subscript_is_runtime`): a bound
# output index on the compile-once `evaluate_cellwise` path, and a parameter, a
# state or `t` on the right-hand side, where it reaches the CSE keying, which
# keys it by the array's identity (`_cse_value_key`).
struct _ConstGatherRef
    vals::AbstractArray   # the frozen const/provider source array (read at eval time)
    name::String          # its `const_arrays` registry name — diagnostics / identity
end

# Build-time side channel from `_resolve_indices` to `_compile`: a live forcing
# gather (`_PGatherArray`) whose subscripts are NOT all build-time constants — a
# loop counter of a symbolic resolve (`F[i]` in a contraction's term) reaches
# one. The `index` node's `args` are the resolved subscripts and `_compile`
# lowers it to a `_NK_LIVE_GATHER` (`_live_gather_node`). Like `_ConstGatherRef`
# it is made only under a non-empty `bound_syms`.
struct _LiveGatherRef
    flat::Vector{Float64}   # the aliased flat buffer (`_PGatherArray.flat`), read at eval time
    dims::Vector{Int}       # its shape: each subscript is checked against its own axis
    name::String            # its `pgather` registry name, for `E_TREEWALK_PGATHER_OOB`
end

# ── Runtime contraction loop (ess-runtime-contraction) ──────────────────────
# A uniform reduction Σ_{k∈lo:step:hi} body(k, u, …) COMPILED ONCE into a single
# loop node instead of unrolled into `length(k)` scalar terms. The tree-walk
# default UNROLLS a contracted (reduction) index at build time — O(N) IR nodes
# per output cell, O(N²) for a 2-D contraction — which makes `prepare` blow up
# quadratically in the reduction size. This node keeps the body as ONE compiled
# subtree and iterates the range at EVALUATION time, so build IR size is O(1) in
# the reduction length and the numeric result matches the unrolled fold (the
# accumulation order is identical; see `_eval_contraction_loop`).
#
# `_ContractLoop` is the eval-time payload of an `_NK_CONTRACTION_LOOP` node.
# `ref` is the shared loop counter — the SAME `Ref{Int}` object every
# `_NK_LOOPVAR` leaf in the body reads (its per-iteration integer value). The
# fold's ⊕ rides on the node's `op`, seeded from 0̄ on the node's `literal`.
struct _ContractLoop
    ref::Base.RefValue{Int}
    lo::Int
    hi::Int
    step::Int
end

# Build-time side channel carrying the loop metadata from `_resolve_scalar_faq`
# (resolve pass) to `_compile` (compile pass) on a synthetic `__contract_loop`
# marker op's `.value` slot — the exact pattern `_ConstGatherRef` uses. A resolved
# body is never re-substituted (`_sub_preserving` runs BEFORE resolution), so the
# `.value` survives to `_compile` intact, the same guarantee `_ConstGatherRef`
# relies on. The single child arg of the marker op is the loop body expression.
struct _ContractLoopBuild
    ref::Base.RefValue{Int}
    lo::Int
    hi::Int
    step::Int
    oplus::Symbol
    zerobar::Float64
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

# Build→compile side channel for `_NK_RAGGED_LOOP`, carried on a `__ragged_loop`
# marker op's `.value`; the marker's args are `[body, lo, hi]`.
struct _RaggedLoopBuild
    ref::Base.RefValue{Int}
    step::Int
    reach::Int
    oplus::Symbol
    zerobar::Float64
end

# ── Runtime STATE gather in a contraction-loop body (ess-runtime-contraction) ──
# The state-source case: a loop body reads STATE at a slot that depends on the
# (symbolic) contracted index — `q[donor(i,k)]`, where `donor` may be plain
# arithmetic in the loop var OR an indirect const-connectivity gather
# `index(conn, i, k)`. The unroll bakes a distinct `_NK_STATE` per k; the loop
# instead computes the slot AT EVAL TIME from the current loop counter and reads
# `u` there. `_StateGather` is the eval-time payload of an `_NK_STATE_GATHER` node
# (analogous to `_ConstGatherArray`, but the frozen table holds STATE SLOTS and
# the final read hits `u`, so the value carries a derivative). `slot_flat[off+1]`
# is the flat `u` index of the state cell whose per-dim subscript is
# `lo[d] + local_d` (column-major `off`); a subscript outside `[lo,hi]` is a ghost
# cell and yields 0̄ (the state-array ghost convention, matching the unroll's
# out-of-bounds → `NumExpr(0.0)`). The subscript expressions are the node's
# `children` (loop-var-dependent `_Node`s), evaluated and bounds-checked here.
struct _StateGather
    slot_flat::Vector{Int}
    strides::Vector{Int}
    lo::Vector{Int}
    hi::Vector{Int}
    len::Int
end

# Build→compile side channel (like `_ConstGatherRef`): carries the resolved state
# slot table on a `__state_gather` marker op's `.value`; `_compile` compiles the
# subscript `args` as children and lowers the node to `_NK_STATE_GATHER`.
struct _StateGatherRef
    slot_flat::Vector{Int}
    strides::Vector{Int}
    lo::Vector{Int}
    hi::Vector{Int}
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
struct _RecurGather
    name::String
    lo::Vector{Int}
    dims::Vector{Int}
    sweep_w::Vector{Int}
    base::Int
    strides::Vector{Int}
    cur::Base.RefValue{Int}
end

# Build→compile side channel for it, like `_StateGatherRef`: rides on a
# `__recur_read` marker op's `.value`, whose `args` are the subscripts.
struct _RecurGatherRef
    gather::_RecurGather
end

function _mknode(;
        kind::UInt8, op::Symbol = Symbol(""),
        literal::Float64 = 0.0, idx::Int = 0,
        sym::Symbol = Symbol(""), payload = nothing,
        children::Vector{_Node} = _Node[]
    )
    return _Node(kind, op, literal, idx, sym, payload, children)
end

# Payload of a `_NK_CONST_GATHER` node (wall2 Phase B). Unlike `_NK_PARAM_GATHER`
# — which reads a live buffer at a FIXED offset baked at build time — this carries
# the whole flattened source array plus its column-major strides, and the offset is
# recomputed on every eval from the node's subscript `children`. That is what lets a
# runtime-varying subscript (Phase C will bind output-index parameters here) select a
# different element WITHOUT re-resolving/re-compiling the AST. All fields are concrete
# so the eval arm stays monomorphic + allocation-free (mirroring how the
# `_NK_PARAM_GATHER` arm asserts `payload::Vector{Float64}`).
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

# Build-time constructor for a `_NK_CONST_GATHER` node (wall2 Phase B). Flattens `A`
# column-major into a fresh `Vector{Float64}`, derives its column-major strides from
# `size(A)`, and captures them in a `_ConstGatherArray`; `subscript_nodes` become the
# node's subscript `children` (one per dimension, in dimension order). Phase C calls
# this to lower a `index(const_array, subs...)` gather whose subscripts are not all
# build-time constants. `subscript_nodes` must have one entry per dimension of `A`.
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
    # SHARE the source array's buffer rather than COPY it. A dense `Float64` array
    # `vec`s to a `Vector{Float64}` ALIASING the same memory (no data copy), so every
    # gather into the same const array references ONE buffer. A plain
    # `Vector{Float64}(vec(A))` copies the WHOLE array on every call — and an unrolled
    # contraction lowers one `_const_gather_node` PER reduced term, so that copy is
    # O(N_terms · sizeof(A)): at model scale (1520 terms × a ~0.6 GiB SR slab ≈ 1 TiB)
    # it OOMs the machine (wall2 Phase C regression). Const arrays are build-time
    # read-only, so aliasing is safe (the same sharing `_NK_PARAM_GATHER` relies on
    # for a live buffer). Non-dense / non-`Float64` inputs fall back to one
    # convert-copy — bounded, since those are not the hot contraction path.
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
    return _mknode(
        kind = _NK_CONST_GATHER,
        payload = _ConstGatherArray(
            flat, strides, collect(Int, sz),
            boundary, String(name)
        ),
        children = subscript_nodes
    )
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
