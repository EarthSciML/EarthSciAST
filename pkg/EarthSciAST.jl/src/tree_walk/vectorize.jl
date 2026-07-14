# ========================================================================
# tree_walk/vectorize.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4b: the vectorized array-kernel evaluator (ess-dhq) — _VecNode
# templates, structural grouping/merge at build time, and the in-place
# runtime evaluation (_eval_vec*) plus the f! closure generator
# (_make_rhs) — a zero-allocation hot path.
# ========================================================================

# ============================================================
# 4b. Vectorized array-kernel evaluator (ess-dhq)
# ============================================================
#
# DESIGN / FEASIBILITY GATE (ess-dhq acceptance criterion #1)
# -----------------------------------------------------------
# The scalar path above (`build_evaluator` + `_make_rhs`/`_eval_node`) compiles
# every discretized `arrayop`-derivative equation into N per-cell scalar `_Node`
# trees and evaluates them with an O(N) element loop. This section makes the
# per-timestep RHS of those array equations run as **whole-array kernels** whose
# compiled-node count is **independent of the grid size N**, with results
# numerically identical to the scalar runner.
#
# Strategy — TRANSPOSE the per-cell nodes, don't re-derive them.
#   The array-D branch of `build_evaluator` already produces, for each output
#   cell, a fully-resolved scalar `_Node` (ghost cells, const-array inlining,
#   semiring joins/filters, variable-valence reduction bounds — all handled at
#   build time, exactly as before). Instead of pushing N nodes into `rhs_list`,
#   we group those nodes by structural shape and *merge each group* into ONE
#   vectorized template (`_VecNode`) whose leaves carry per-cell vectors:
#       - `index(u, ·)`  STATE leaves whose slot varies per cell → `_VK_GATHER`
#                        (a `u[slots]` offset-slice / gather)
#       - const-array / ghost LITERAL leaves that vary    → `_VK_CONSTVEC`
#       - leaves constant across the group (param, t, a   → `_VK_PARAM/_TIME/
#         scalar state read, a shared literal)              _STATE/_LITERAL`,
#                                                            broadcast over lanes
#       - arithmetic / comparison / transcendental ops    → `_VK_OP` (broadcast)
#       - `_NK_CONTRACTION` reductions                     → `_VK_REDUCE`
#         (axis fold in the same order as the scalar path)
#       - closed `fn` ops with a per-cell query            → `_VK_FN` (per-lane map;
#         a lane-invariant one hoists like any other op — see below)
#   Each merged template evaluates over its whole cell-axis with array ops, then
#   `du[out_slots] .= result` scatters the lane values back.
#
# Why this preserves numeric identity: the merge is a structural transpose of
# the *same* compiled per-cell nodes; a broadcast `f.(a, b)` applies the identical
# scalar `f` to lane j that the scalar node computed for cell j, and reductions
# fold in the same order. Elementwise ops are bit-identical; reductions match the
# scalar Tullio/loop order (≤ rounding, absorbed by the tests' tolerances).
#
# Why the kernel count is N-independent: cells that share a structural signature
# collapse into ONE template regardless of how many there are. Ghost boundaries,
# `makearray` BC regions, and distinct contraction valences each form their own
# (N-independent) group — this IS the "interior kernel + boundary kernels"
# decomposition. Only the embedded slot/value vectors grow with N; the number of
# compiled `_VecNode`s does not.
#
# Functions touched: `build_evaluator` (the `_is_arrayop_D_lhs` branch collects
# per-cell entries then calls `_vectorize_cell_entries`; renamed to
# `_build_evaluator_impl` with a thin `build_evaluator` wrapper so the
# N-independence property is introspectable), `_make_rhs` (drives both scalar
# entries and `_VecKernel`s). The scalar/indexed-D paths, `_resolve_indices`,
# `_compile`, and `_eval_node` are UNCHANGED — non-array equations keep their
# exact scalar evaluation.
#
# Node kinds confirmed vectorizable (no scalar fallback retained):
#   stencil arrayop ✓ (gather + broadcast)   contraction/reduction ✓ (axis fold)
#   integral ✓ (resolves to dx*Σcells = an OP/REDUCE tree, vectorized like any)
#   makearray BC regions ✓ (per-region structural groups)  ghost cells ✓ (gather
#   sentinel groups)  gather/indirect ✓ (STATE-slot gather)  broadcast coeffs ✓
#   (const-array → CONSTVEC).  Closed `fn` ops are a per-lane map — one kernel
#   node, N-independent — not a per-cell scalar evaluation strategy.

# `_VecNode` kinds. Disjoint from the scalar `_NK_*` space to keep dispatch clear.
const _VK_LITERAL  = UInt8(1)   # scalar literal, broadcast across lanes
const _VK_CONSTVEC = UInt8(2)   # per-cell constants (n.vals), length = #cells
const _VK_STATE    = UInt8(3)   # scalar u[idx], broadcast across lanes
const _VK_GATHER   = UInt8(4)   # u[slots] — offset-slice / gather over the axis
const _VK_PARAM    = UInt8(5)   # scalar p.<sym>, broadcast
const _VK_TIME     = UInt8(6)   # scalar t, broadcast
const _VK_OP       = UInt8(7)   # elementwise broadcast of op over child vectors
const _VK_REDUCE   = UInt8(8)   # contraction: axis fold over children (semiring)
const _VK_FN       = UInt8(9)   # closed-function map (interp.* = whole-array)
const _VK_PGATHER  = UInt8(10)  # forcing[slots] — gather over a captured live p-buffer (ess-14f.3)
const _VK_INVARIANT = UInt8(11) # LANE-INVARIANT subtree: `payload` is the representative
                                # scalar `_Node`, evaluated ONCE per RHS call and broadcast.

# ---- Lane-invariant hoisting -------------------------------------------------
# A subtree with no free cell index — `exp(-Ea/T)` written inside an `arrayop`,
# `interp.linear(table, t)`, any pure parameter/time/scalar-state algebra — has
# the SAME value in every lane. Evaluated as an ordinary `_VK_OP` it is recomputed
# per lane AND every interior node materialises a full-length constant buffer.
# `_merge_nodes` instead collapses the whole subtree to one `_VK_INVARIANT` node:
# one scalar `_eval_node` call per RHS, one `fill!`, and every interior buffer in
# it disappears.
#
# Which LOWERED vec kinds count as lane-invariant CHILDREN: a LITERAL that merged equal
# across cells, a STATE whose slot merged equal (a 0-D state read inside an arrayop), a
# PARAM, TIME, and a subtree already hoisted to INVARIANT. Deliberately NOT in that set:
# CONSTVEC and GATHER/PGATHER (per-cell by construction), REDUCE (see below), and — note
# — `_VK_FN` itself, because a `fn` whose query IS per-cell (`interp.linear(tbl, ax, u[i])`)
# is genuinely lane-VARYING and must stay a per-lane `_VK_FN`.
#
# A closed `fn` is nevertheless a HOIST CANDIDATE like any other op: the decision is made
# on its CHILDREN, not on its kind. `interp.linear(tbl, ax, t)` — the const table/axis live
# in the typed spec, so its only child is `_VK_TIME` — is identical in every lane, and is
# hoisted to a single `_VK_INVARIANT` (one table lookup per RHS call, not N). This is the
# same barrier ess-obs removed from the scalar CSE pass (see op_registry.jl): a closed
# function is pure and deterministic, so flagging it opaque only defeats sharing. It is
# hoisted from `_merge_fn_node`, AFTER the const-query fold — an all-literal query folds to
# a `_VK_LITERAL` at build time, which is strictly better than one scalar eval per call.
# `_VK_REDUCE` stays unhoisted: reconstructing it would need an `_NK_CONTRACTION` scalar
# node (a different kind + the identity seed in `literal`), which `_maybe_hoist_invariant`'s
# `_NK_OP` reconstruction does not model.
#
# The hoist is safe precisely BECAUSE the check is on the merged children: `_VK_LITERAL`
# only exists when every cell's literal was equal (an unequal one becomes CONSTVEC) and
# `_VK_STATE` only when every cell's slot was equal (else GATHER). So all-invariant
# children ⇒ every cell's subtree is value-identical ⇒ `nodes[1]` is a faithful
# representative, and the scalar `_eval_node` that built the vec arm in the first place
# is its exact oracle. Bottom-up construction makes the hoist MAXIMAL for free: an
# invariant child becomes INVARIANT, its parent then sees an all-invariant child list
# and absorbs it, so only the outermost invariant node survives.
# (`_vk_lane_invariant` is defined just below `struct _VecNode`, which it annotates.)

# Each node owns a preallocated `buf` (length = the kernel's lane count) into
# which `_eval_vec` writes its lane values IN PLACE at runtime, then returns it.
# This — together with the explicit `du` scatter in `f!` — is what keeps the RHS
# allocation-free (ess-9cc): the only Float64 arrays are these build-time `buf`s
# captured in the closure, none are allocated per call. CONSTVEC has no `buf` and
# is read straight from its stored `vals`. `fnargs`/`cvbufs` are scratch ONLY for
# the boxed all-scalar `fn` path (`datetime.*`): a reused closed-function argument
# vector and the child result buffers, so that map reuses one `Any[]` across lanes
# instead of building a fresh one per cell. The `interp.*` `fn` ops carry a typed
# `_Interp*Spec` in `payload` instead and run zero-box whole-array kernels
# (ess-wrh), leaving `fnargs`/`cvbufs` as shared empty sentinels; every non-`fn`
# node shares those sentinels too.
#
# `altbuf` IS WHAT MAKES `f!` DIFFERENTIABLE, and it is the whole trick of this
# file's AD story, so it is worth being precise about. A `Vector{Float64}` cannot
# hold a `ForwardDiff.Dual`, so `buf` alone pins the evaluator to `Float64` — and
# widening `buf` to a type parameter would mean allocating it per call, i.e. giving
# up the exact property it exists for. Instead each node carries a SECOND,
# LAZILY-CREATED buffer for whatever non-`Float64` value type last drove `f!`
# (`_vbuf`). Consequences, all of them deliberate:
#   * The `Float64` path is untouched: `_vbuf(n, Float64)` IS `n.buf`, a field load
#     the compiler resolves statically (`T` is a compile-time constant — see
#     `_rhs_value_type`). Same buffers, same broadcasts, same zero allocations,
#     same bits.
#   * A model that is only ever INTEGRATED never allocates the Dual buffers at all.
#     This is why the node holds its own lazy slot rather than a
#     `PreallocationTools.DiffCache`, which eagerly reserves
#     `length × (chunk+1)` `Float64`s per node at BUILD time — a large memory tax
#     on the production path for an AD feature it does not use, and it re-allocates
#     inside the RHS whenever ForwardDiff's real chunk exceeds the guess.
#   * `Ref{Any}` + an `isa` narrowing (not a `Dict{DataType,…}`): ForwardDiff drives
#     a whole Jacobian with ONE `Dual{Tag,V,N}`, so a one-slot cache hits every call
#     after the first. Alternating two distinct Dual types would re-allocate each
#     call — correct, just not free.
#   * `_VK_LITERAL`, `_VK_CONSTVEC` and `_VK_PGATHER` deliberately keep NO alt
#     buffer: their lanes are DATA (literals, const arrays, live forcing) whose
#     derivative is genuinely zero, so they stay `Vector{Float64}` and promote at
#     the operator. For `^` that is not merely an optimization but a correctness
#     requirement — see the `:^` arm of `_eval_vec_op`.
#
# Because the buffers are mutable shared state, an evaluator is NON-REENTRANT: a
# given `f!` must not run concurrently for one problem (the ODE integrator calls
# the RHS sequentially, so this holds). Concurrent/ensemble use needs one
# evaluator per task — the same constraint the preallocated MTK reference has.
struct _VecNode
    kind::UInt8
    op::Symbol
    literal::Float64
    idx::Int
    sym::Symbol
    # Per-kind payload:
    #   _VK_PGATHER → the captured live forcing buffer (`Vector{Float64}`,
    #                 aliased — refreshed in place by the loader callback);
    #   _VK_FN      → a typed `_Interp*Spec` (zero-box `interp.*` kernels) or
    #                 the boxed closed-function carrier `Tuple{String,Any}`
    #                 (`(fname, nothing)`) for the all-scalar `datetime.*` path;
    #   _VK_OP      → whatever `_Node.payload` carried through `_merge_nodes`
    #                 (`nothing` for ordinary elementwise ops — closed `fn` ops
    #                 route to `_VK_FN` or `_VK_INVARIANT`, not here);
    #   _VK_INVARIANT → the representative scalar `_Node` (which MAY itself be an
    #                 `op === :fn` node carrying the source `(fname, spec)` payload);
    #   every other kind → `nothing`.
    # Kept `::Any` deliberately: each consumer narrows it with an `isa` split /
    # typeassert (`_eval_vec`'s `_VK_PGATHER` arm, `_eval_vec_fn`,
    # `_eval_vec_fn_boxed`), so a `Union` field type would not improve
    # inference and could only change codegen.
    payload::Any
    vals::Vector{Float64}
    slots::Vector{Int}
    children::Vector{_VecNode}
    buf::Vector{Float64}
    altbuf::Base.RefValue{Any}   # lazily-created `Vector{T}`, T ≠ Float64 (see above)
    fnargs::Vector{Any}
    # Child result buffers for the boxed `fn` path. `Any` rather than
    # `Vector{Float64}` because a child evaluates to `Vector{Float64}` (a data
    # node) or `Vector{T}` (everything else) depending on the value type. The
    # extra dynamic index this costs is free in context: that path already boxes
    # a scalar per lane into `fnargs` to call `evaluate_closed_function`, so it
    # was never allocation-free to begin with (`interp.*`, which IS on the hot
    # path, is lowered to a typed spec and never reaches it).
    cvbufs::Vector{Any}
end

# The node's scratch for value type `T`. `T` is a compile-time constant at every
# call site, so ONE of these two methods is compiled into any given `f!`
# specialization — the `Float64` one to a bare field load.
@inline _vbuf(n::_VecNode, ::Type{Float64}) = n.buf
@inline function _vbuf(n::_VecNode, ::Type{T}) where {T}
    b = n.altbuf[]
    b isa Vector{T} && return b
    nb = Vector{T}(undef, length(n.buf))
    n.altbuf[] = nb
    return nb
end

# What one `_eval_vec` node yields: a `Vector{T}` for a computed node, or a
# `Vector{Float64}` for a DATA node (`_VK_LITERAL` / `_VK_CONSTVEC` /
# `_VK_PGATHER`, whose lanes are never differentiated). At `T === Float64` the two
# collapse into a single concrete type and this alias IS `Vector{Float64}` — the
# vectorized walker is then exactly the pre-AD one. Under AD it is a two-member
# union that Julia union-splits at each broadcast.
const _VecVal{T} = Union{Vector{Float64},Vector{T}}

# Lane-invariant test for a LOWERED child (see the `_VK_INVARIANT` commentary above).
@inline _vk_lane_invariant(n::_VecNode) =
    n.kind === _VK_LITERAL || n.kind === _VK_STATE || n.kind === _VK_PARAM ||
    n.kind === _VK_TIME    || n.kind === _VK_INVARIANT

# Rebuild the scalar `_Node` for an already-LOWERED lane-invariant `_VecNode` subtree.
#
# It reads the values off the LOWERED node, never off the source `_Node`. That is the
# whole point: both vec builders can rewrite a leaf's value on the way down — the
# symbolic-stencil builder (`stencil.jl`'s `_lower_template`) resolves LITERAL/STATE
# leaves through per-lane RECIPES, so the source template's `literal`/`idx` fields are
# placeholders, not lane values. Reconstructing from the lowered node is correct for
# both builders; reconstructing from the source node would silently read a placeholder.
#
# Total over exactly the kinds `_vk_lane_invariant` admits, plus `_VK_OP`. A lowered
# `_VK_FN` is deliberately NOT reconstructible here and never reaches this function: a
# `fn` node is hoisted by its CALLER (`_merge_fn_node`), which still holds the SOURCE
# scalar payload `(fname, spec)` — the exact tuple `_eval_node_op`'s `:fn` arm expects —
# so no lowered→scalar reconstruction of the `fn` node itself is ever needed. Only its
# CHILDREN come through here, and a lane-invariant child is never a `_VK_FN` (a nested
# invariant `fn` has already become `_VK_INVARIANT`, whose payload is a scalar `_Node`).
function _vk_to_scalar(n::_VecNode)::_Node
    k = n.kind
    k === _VK_LITERAL   && return _mknode(kind=_NK_LITERAL, literal=n.literal)
    k === _VK_STATE     && return _mknode(kind=_NK_STATE, idx=n.idx)
    k === _VK_PARAM     && return _mknode(kind=_NK_PARAM, sym=n.sym)
    k === _VK_TIME      && return _mknode(kind=_NK_TIME)
    k === _VK_INVARIANT && return n.payload::_Node
    k === _VK_OP        && return _mknode(kind=_NK_OP, op=n.op, payload=n.payload,
                                          children=_Node[_vk_to_scalar(c) for c in n.children])
    throw(TreeWalkError("E_TREEWALK_INTERNAL",
        "lane-invariant hoist: unexpected vec kind $(k)"))
end

# Shared by BOTH vec builders (`_merge_nodes` and stencil.jl's `_lower_template`, the
# latter via `_merge_fn_node` for `fn`): if every lowered child of this op is
# lane-invariant, collapse the whole subtree to a single `_VK_INVARIANT` node. Returns
# `nothing` when it does not apply, so each caller falls through to its normal `_VK_OP` /
# `_VK_FN`. A childless op is degenerate and left alone.
#
# `payload` MUST be the SOURCE scalar node's payload, since the reconstructed node is a
# scalar `_Node` handed to `_eval_node`. Both callers satisfy this: it is `nothing` for
# every ordinary elementwise op, and `(fname, spec_or_nothing)` for `fn` — and in the
# stencil builder a `fn`'s const table/axis args are loop-INVARIANT, returned verbatim by
# `_stencilize`, so its spec is a real build-time spec and not a lane recipe. (Only
# LITERAL/STATE *leaf* fields are recipe placeholders there, which is why `_vk_to_scalar`
# reads the CHILDREN off the lowered nodes.)
function _maybe_hoist_invariant(op::Symbol, payload, ch::Vector{_VecNode}, len::Int)
    isempty(ch) && return nothing
    all(_vk_lane_invariant, ch) || return nothing
    scalar = _mknode(kind=_NK_OP, op=op, payload=payload,
                     children=_Node[_vk_to_scalar(c) for c in ch])
    return _mkvnode(kind=_VK_INVARIANT, payload=scalar, buf=Vector{Float64}(undef, len))
end

const _VK_NO_VALS   = Float64[]
const _VK_NO_SLOTS  = Int[]
const _VK_NO_BUF    = Float64[]
const _VK_NO_FNARGS = Any[]
const _VK_NO_CVBUFS = Any[]

# `altbuf` is the one field that must NOT be shared — each node needs its own
# empty slot — so it is constructed fresh per call rather than defaulted to a
# module-level sentinel like the others.
function _mkvnode(; kind::UInt8, op::Symbol=Symbol(""), literal::Float64=0.0,
                  idx::Int=0, sym::Symbol=Symbol(""), payload=nothing,
                  vals::Vector{Float64}=_VK_NO_VALS, slots::Vector{Int}=_VK_NO_SLOTS,
                  children::Vector{_VecNode}=_VecNode[],
                  buf::Vector{Float64}=_VK_NO_BUF,
                  fnargs::Vector{Any}=_VK_NO_FNARGS,
                  cvbufs::Vector{Any}=_VK_NO_CVBUFS)
    return _VecNode(kind, op, literal, idx, sym, payload, vals, slots, children,
                    buf, Base.RefValue{Any}(nothing), fnargs, cvbufs)
end

# One vectorized array equation (or one structural sub-group of it): write the
# lane values of `template` into `du[out_slots]`.
struct _VecKernel
    out_slots::Vector{Int}
    template::_VecNode
    len::Int
end

_count_vecnodes(n::_VecNode) =
    1 + sum(_count_vecnodes(ch) for ch in n.children; init=0)

# ---- Structural grouping + merge (build time) ----

# A signature that is equal for two per-cell nodes iff they have an identical
# tree shape ignoring the values that legitimately vary per cell (STATE slot
# index, LITERAL value). Same signature ⇒ unambiguous merge into one template.
# Different signatures (in-bounds STATE vs ghost LITERAL, makearray region A vs
# B, valence-5 vs valence-6 contraction) ⇒ separate kernels.
#
# The signature is written token-by-token into a caller-supplied `IOBuffer` and
# materialised to a `String` exactly ONCE per top-level node (see the reusable
# buffer in `_vectorize_cell_entries`). The earlier `string(…, join(…), …)` form
# allocated an intermediate `String` at every interior node and re-copied every
# descendant's bytes at each level up the tree — O(nodes × depth) garbage. The
# emitted bytes are unchanged, so the grouping is identical.
function _struct_sig!(io::IOBuffer, n::_Node)
    k = n.kind
    if k === _NK_STATE
        print(io, 'S')
    elseif k === _NK_LITERAL
        print(io, 'L')
    elseif k === _NK_PARAM
        print(io, "P:", n.sym)
    elseif k === _NK_PARAM_GATHER
        # Cells gathering from the SAME captured buffer (same `payload` object)
        # merge into one `_VK_PGATHER`, exactly as same-array STATE cells merge to
        # `_VK_GATHER`; the per-lane linear `idx` becomes the gather `slots`.
        # Different buffers ⇒ different `objectid` ⇒ separate kernels.
        print(io, "PG:", objectid(n.payload))
    elseif k === _NK_TIME
        print(io, 'T')
    elseif k === _NK_CONTRACTION
        print(io, "C:", n.op, '(')
        _sig_children!(io, n.children)
        print(io, ')')
    else  # _NK_OP (including closed `fn`)
        print(io, "O:", n.op)
        if n.payload isa Tuple && length(n.payload) >= 1
            print(io, '@', n.payload[1])
        end
        print(io, '(')
        _sig_children!(io, n.children)
        print(io, ')')
    end
    return io
end

function _sig_children!(io::IOBuffer, children)
    first = true
    for ch in children
        first || print(io, ',')
        first = false
        _struct_sig!(io, ch)
    end
    return io
end

# Allocate the closed-function argument vector for a vectorized all-scalar `fn`
# node (e.g. `datetime.*`): one `Any` slot per child, filled per lane in
# `_eval_vec_fn_boxed`. The `interp.*` ops do NOT use this path — they are lowered
# to typed `_Interp*Spec` carriers at build time (`_merge_nodes`) and evaluated
# through the validation-free `_interp_*_core` kernels with a typed `Float64`
# query, so no `Float64`→`Any` box is ever created on the array RHS (ess-wrh). The
# residual box on the all-scalar path is tolerated: those closed functions are a
# cold case off the PDE diffusion RHS.
_make_fnargs(nchildren::Int)::Vector{Any} = Vector{Any}(undef, nchildren)

# Merge a structurally-identical group of per-cell nodes into one `_VecNode`
# template. Precondition: all elements share `_struct_sig`. `len` is the group's
# lane count (number of cells) — every node in the template produces a length-
# `len` lane vector, so each gets a length-`len` scratch `buf` allocated here,
# ONCE at build time (CONSTVEC excepted — it is read from its stored `vals`).
function _merge_nodes(nodes::Vector{_Node}, len::Int)::_VecNode
    n1 = nodes[1]
    k = n1.kind
    if k === _NK_LITERAL
        v1 = n1.literal
        if all(isequal(nd.literal, v1) for nd in nodes)
            return _mkvnode(kind=_VK_LITERAL, literal=v1, buf=Vector{Float64}(undef, len))
        end
        return _mkvnode(kind=_VK_CONSTVEC, vals=Float64[nd.literal for nd in nodes])
    elseif k === _NK_STATE
        i1 = n1.idx
        if all(nd.idx == i1 for nd in nodes)
            return _mkvnode(kind=_VK_STATE, idx=i1, buf=Vector{Float64}(undef, len))
        end
        return _mkvnode(kind=_VK_GATHER, slots=Int[nd.idx for nd in nodes],
                        buf=Vector{Float64}(undef, len))
    elseif k === _NK_PARAM
        return _mkvnode(kind=_VK_PARAM, sym=n1.sym, buf=Vector{Float64}(undef, len))
    elseif k === _NK_PARAM_GATHER
        # All cells share the captured buffer (`payload`, guaranteed equal by
        # `_struct_sig`); the per-lane linear offsets become the gather `slots`.
        # Mirrors the STATE→`_VK_GATHER` lowering, reading the live forcing buffer
        # instead of `u` (ess-14f.3).
        return _mkvnode(kind=_VK_PGATHER, payload=n1.payload,
                        slots=Int[nd.idx for nd in nodes],
                        buf=Vector{Float64}(undef, len))
    elseif k === _NK_TIME
        return _mkvnode(kind=_VK_TIME, buf=Vector{Float64}(undef, len))
    elseif k === _NK_CONTRACTION
        m = length(n1.children)
        ch = _VecNode[_merge_nodes(_Node[nd.children[c] for nd in nodes], len) for c in 1:m]
        return _mkvnode(kind=_VK_REDUCE, op=n1.op, literal=n1.literal, children=ch,
                        buf=Vector{Float64}(undef, len))
    else  # _NK_OP / fn
        m = length(n1.children)
        ch = _VecNode[_merge_nodes(_Node[nd.children[c] for nd in nodes], len) for c in 1:m]
        if n1.op === :fn
            return _merge_fn_node(n1.payload, ch, len, m)
        end
        # Lane-invariant subtree → one scalar eval per RHS call instead of one per lane.
        hoisted = _maybe_hoist_invariant(n1.op, n1.payload, ch, len)
        hoisted === nothing || return hoisted
        return _mkvnode(kind=_VK_OP, op=n1.op, payload=n1.payload, children=ch,
                        buf=Vector{Float64}(undef, len))
    end
end

# Build the vectorized node for a closed-function (`fn`) leaf. `interp.*` ops
# carry a typed `_Interp*Spec` payload — validated + coerced ONCE at compile time
# by `_compile_op` (compile.jl) and reused here as-is — so `_eval_vec_fn` runs a
# zero-box whole-array kernel; all other closed functions (`datetime.*`,
# all-scalar args) keep the boxed per-lane path. As a build-time specialization
# (ess-wrh §4), an interp leaf whose query children are all compile-time constants
# folds to a single `_VK_LITERAL` — the closed-function call (and its box) vanish
# entirely for that leaf.
#
# A closed function is PURE, so it is a lane-invariant hoist candidate exactly like an
# arithmetic op: if every query child is lane-invariant the call has one value for the
# whole kernel. The three lowerings are tried in decreasing strength — build-time fold
# (`_VK_LITERAL`, zero runtime work) ▸ once-per-call hoist (`_VK_INVARIANT`) ▸ per-lane
# map (`_VK_FN`) — and the middle one is what makes `interp.linear(tbl, ax, t)` (a pure
# function of time, the FastJX shape) ONE table lookup per RHS call instead of N, and lets
# its ancestors hoist too (an unhoistable child used to bar every ancestor as well).
# `payload` is the source scalar `(fname, spec)`, i.e. precisely what the scalar `:fn` arm
# of `_eval_node_op` reads, so the hoisted node needs no reconstruction of the `fn` itself.
function _merge_fn_node(payload, ch::Vector{_VecNode}, len::Int, m::Int)::_VecNode
    fname, spec = payload::Tuple{String,Any}
    typed = spec isa _InterpLinearSpec || spec isa _InterpBilinearSpec ||
            spec isa _InterpSearchsortedSpec
    if typed
        # Const-arg closed function — the spec was built once in `_compile_op`
        # (the `(fname, spec)` payload layout is pinned by the same
        # `_FN_CONST_ARG_SPECS` table). Reuse it directly (immutable, share-safe).
        folded = _try_fold_const_interp(spec, ch, len)
        folded === nothing || return folded
    end
    hoisted = _maybe_hoist_invariant(:fn, payload, ch, len)
    hoisted === nothing || return hoisted
    typed && return _mkvnode(kind=_VK_FN, op=:fn, payload=spec, children=ch,
                             buf=Vector{Float64}(undef, len))
    # All-scalar closed functions (e.g. `datetime.*`): boxed per-lane map.
    return _mkvnode(kind=_VK_FN, op=:fn, payload=payload, children=ch,
                    buf=Vector{Float64}(undef, len),
                    fnargs=_make_fnargs(m),
                    cvbufs=Vector{Any}(undef, m))
end

# (ess-wrh §4) On-knot / constant-query lowering. When EVERY query child of an
# interp leaf merged to a `_VK_LITERAL` (i.e. all cells in the group share the
# same compile-time-constant query), the whole closed-function call collapses to a
# single compile-time value — no runtime kernel, no box. The value is computed
# with the SAME validated `_interp_*_core` the runtime would use, so it is exact:
# this subsumes the on-knot w=0 case the bead calls out (a query landing on an
# affine/integer-axis knot folds to its table entry) WITHOUT the `0*Inf=NaN`
# hazard a bare gather would hit on an infinite neighbor, because the full pinned
# blend is evaluated rather than shortcut. A runtime query (`u[i]` → `_VK_STATE` /
# `_VK_GATHER`) is not build-time known, so the prover declines (returns
# `nothing`) and the node falls through to the whole-array kernel. Returns a
# folded `_VK_LITERAL` `_VecNode`, or `nothing` if not foldable.
function _try_fold_const_interp(spec::_InterpLinearSpec, ch::Vector{_VecNode},
                                len::Int)::Union{_VecNode,Nothing}
    (length(ch) == 1 && ch[1].kind === _VK_LITERAL) || return nothing
    v = _interp_linear_core(spec.table, spec.axis, ch[1].literal)
    return _mkvnode(kind=_VK_LITERAL, literal=Float64(v), buf=Vector{Float64}(undef, len))
end
function _try_fold_const_interp(spec::_InterpSearchsortedSpec, ch::Vector{_VecNode},
                                len::Int)::Union{_VecNode,Nothing}
    (length(ch) == 1 && ch[1].kind === _VK_LITERAL) || return nothing
    v = _interp_searchsorted_core("interp.searchsorted", ch[1].literal, spec.xs)
    return _mkvnode(kind=_VK_LITERAL, literal=Float64(v), buf=Vector{Float64}(undef, len))
end
function _try_fold_const_interp(spec::_InterpBilinearSpec, ch::Vector{_VecNode},
                                len::Int)::Union{_VecNode,Nothing}
    (length(ch) == 2 && ch[1].kind === _VK_LITERAL && ch[2].kind === _VK_LITERAL) ||
        return nothing
    v = _interp_bilinear_core(spec.table, spec.axis_x, spec.axis_y,
                              ch[1].literal, ch[2].literal)
    return _mkvnode(kind=_VK_LITERAL, literal=Float64(v), buf=Vector{Float64}(undef, len))
end

# Group an array equation's per-cell `(du_slot, node)` entries by structure and
# build one `_VecKernel` per group. First-seen group order is preserved for
# deterministic kernel ordering (du writes are to disjoint slots regardless).
function _vectorize_cell_entries(entries::Vector{Tuple{Int,_Node}})::Vector{_VecKernel}
    isempty(entries) && return _VecKernel[]
    order = String[]
    groups = Dict{String,Tuple{Vector{Int},Vector{_Node}}}()
    sigbuf = IOBuffer()   # reused across every cell; `take!` empties it each turn
    for (slot, node) in entries
        sig = String(take!(_struct_sig!(sigbuf, node)))
        if !haskey(groups, sig)
            groups[sig] = (Int[], _Node[])
            push!(order, sig)
        end
        slots, nds = groups[sig]
        push!(slots, slot)
        push!(nds, node)
    end
    kernels = _VecKernel[]
    for sig in order
        slots, nds = groups[sig]
        push!(kernels, _VecKernel(slots, _merge_nodes(nds, length(slots)), length(slots)))
    end
    return kernels
end

# ---- Vectorized evaluation (runtime) — fully in place (ess-9cc) ----
#
# `_eval_vec` writes the node's lane values into its preallocated buffer for the
# value type `T` (`_vbuf`, which IS `n.buf` at `T === Float64`) and RETURNS that
# buffer. No node ever mutates a child's buffer: the template is a pure tree, so
# every node's buffer is disjoint from all of its descendants', which lets a parent
# hold several child buffers at once and combine them in place. The whole
# array-kernel evaluation therefore allocates nothing — the only arrays are the
# build-time buffers in the closure (plus, under AD, their one-time Dual twins).
#
# The three DATA kinds return `Vector{Float64}` at every `T`: CONSTVEC its stored
# `n.vals`, LITERAL and PGATHER their `n.buf`. Their lanes are constants and live
# forcing data, whose derivative is genuinely zero, so they promote at the operator
# instead of being widened — cheaper, and (for `^`) the difference between a
# correct gradient and a silent NaN.
function _eval_vec(n::_VecNode, u, p, t, ::Type{T})::_VecVal{T} where {T}
    k = n.kind
    if k === _VK_CONSTVEC
        return n.vals
    elseif k === _VK_GATHER
        b = _vbuf(n, T); s = n.slots
        @inbounds for j in eachindex(s)
            b[j] = u[s[j]]
        end
        return b
    elseif k === _VK_PGATHER
        # Gather over a captured live forcing buffer (ess-14f.3): identical to
        # `_VK_GATHER` but reads the aliased flat `Vector{Float64}` in `payload`
        # (refreshed in place by the J1 callback) instead of the state `u`. The
        # concrete assert + preallocated `buf`/`slots` keep it zero-alloc.
        b = n.buf; f = n.payload::Vector{Float64}; s = n.slots
        @inbounds for j in eachindex(s)
            b[j] = f[s[j]]
        end
        return b
    elseif k === _VK_LITERAL
        b = n.buf; fill!(b, n.literal); return b
    elseif k === _VK_STATE
        b = _vbuf(n, T); fill!(b, @inbounds(u[n.idx])); return b
    elseif k === _VK_PARAM
        b = _vbuf(n, T); fill!(b, getfield(p, n.sym)); return b
    elseif k === _VK_TIME
        b = _vbuf(n, T); fill!(b, t); return b
    elseif k === _VK_INVARIANT
        # The subtree has no free cell index, so ONE scalar evaluation covers every
        # lane. `_eval_node` is the same scalar walker the vec arms mirror, so this is
        # bit-identical to broadcasting the subtree per lane — see `_vk_lane_invariant`.
        b = _vbuf(n, T); fill!(b, _eval_node(n.payload::_Node, u, p, t, T)); return b
    elseif k === _VK_REDUCE
        return _eval_vec_reduce(n, u, p, t, T)
    elseif k === _VK_FN
        return _eval_vec_fn(n, u, p, t, T)
    else
        return _eval_vec_op(n, u, p, t, T)
    end
end

# Semiring axis reduction — folds the contraction children in the SAME order as
# the scalar `_eval_contraction`, seeded in place from the 0̄ identity on the
# node. Writes into `n.buf`; each child buffer is consumed before the next child
# is evaluated, so no child result needs to outlive its use.
function _eval_vec_reduce(n::_VecNode, u, p, t, ::Type{T})::_VecVal{T} where {T}
    op = n.op
    c = n.children
    b = _vbuf(n, T)
    fill!(b, n.literal)
    if op === :+
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t, T)
            @. b += ck
        end
    elseif op === :*
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t, T)
            @. b *= ck
        end
    elseif op === :max
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t, T)
            @. b = max(b, ck)
        end
    else  # :min
        @inbounds for k in 1:length(c)
            ck = _eval_vec(c[k], u, p, t, T)
            @. b = min(b, ck)
        end
    end
    return b
end

# Closed-function map — one kernel node writing its lane values into `n.buf`. The
# `interp.*` ops run as zero-box whole-array kernels: their validated table/axis
# live on the node's typed `_Interp*Spec` payload (built once in `_merge_fn_node`)
# and the per-lane query is a typed `Float64`, so the only Float64 arrays are the
# preallocated buffers (ess-wrh) — the `f!` stays allocation-free even with an
# interp/table-lookup leaf on the RHS. Bit-identical to the scalar `:fn` arm: the
# array kernels call the SAME `_interp_*_core` (registered_functions.jl). All other
# closed functions (`datetime.*`, all-scalar args) keep the boxed `AbstractVector`
# path — a cold case off the PDE array RHS. The `isa` ladder is a manual union
# split: each branch narrows `n.payload::Any` to a concrete type, so the kernels
# it calls are type-stable (no dispatch box).
function _eval_vec_fn(n::_VecNode, u, p, t, ::Type{T})::_VecVal{T} where {T}
    h = n.payload
    if h isa _InterpLinearSpec
        return _eval_vec_interp_linear(h, n, u, p, t, T)
    elseif h isa _InterpBilinearSpec
        return _eval_vec_interp_bilinear(h, n, u, p, t, T)
    elseif h isa _InterpSearchsortedSpec
        return _eval_vec_interp_searchsorted(h, n, u, p, t, T)
    else
        return _eval_vec_fn_boxed(n, u, p, t, T)
    end
end

# Design note (ess-wrh §2 — "whole-array" form). These kernels iterate lanes and
# call the shared `_interp_*_core` once per lane rather than materializing
# intermediate gathered-axis/table arrays and a fused `@.` blend. The choice is
# deliberate: (a) bit-identity with the scalar `:fn` arm is guaranteed because the
# SAME core (same clamp order, same locate, same pinned blend) runs on both paths
# — a separate broadcast form would have to re-derive the fiddly clamp/NaN/on-knot
# corners and risk divergence; (b) `interp.*` tables are §9.2-capped at ≤1024 (and
# are usually tiny), so a materialized locate→gather→broadcast pass would add
# several length-N scratch buffers and extra passes for no measurable gain. The
# costs ess-wrh targets — the per-lane `Float64`→`Any` box, the per-lane axis
# re-validation, and the boxed `AbstractVector` dispatch — are eliminated here
# regardless of locate strategy: the query is a typed `Float64`, the table/axis
# are validated once at build time, and the call is statically dispatched.
function _eval_vec_interp_linear(h::_InterpLinearSpec, n::_VecNode, u, p, t,
                                 ::Type{T})::_VecVal{T} where {T}
    b = _vbuf(n, T)
    xq = _eval_vec(n.children[1], u, p, t, T)   # query lane vector (disjoint from b)
    table = h.table; axis = h.axis
    @inbounds for lane in eachindex(b)
        b[lane] = _interp_linear_core(table, axis, xq[lane])
    end
    return b
end

function _eval_vec_interp_searchsorted(h::_InterpSearchsortedSpec, n::_VecNode, u, p, t,
                                       ::Type{T})::_VecVal{T} where {T}
    b = _vbuf(n, T)
    xq = _eval_vec(n.children[1], u, p, t, T)
    xs = h.xs
    @inbounds for lane in eachindex(b)
        b[lane] = Float64(_interp_searchsorted_core("interp.searchsorted", xq[lane], xs))
    end
    return b
end

function _eval_vec_interp_bilinear(h::_InterpBilinearSpec, n::_VecNode, u, p, t,
                                   ::Type{T})::_VecVal{T} where {T}
    b = _vbuf(n, T)
    xq = _eval_vec(n.children[1], u, p, t, T)
    yq = _eval_vec(n.children[2], u, p, t, T)   # sibling buffer, disjoint from xq and b
    table = h.table; axis_x = h.axis_x; axis_y = h.axis_y
    @inbounds for lane in eachindex(b)
        b[lane] = _interp_bilinear_core(table, axis_x, axis_y, xq[lane], yq[lane])
    end
    return b
end

# Boxed fallback for all-scalar closed functions (e.g. `datetime.*`) inside a
# vectorized arrayop: one reusable `Any[]` (`n.fnargs`) is refilled per lane and
# passed to `evaluate_closed_function`. Off the PDE RHS hot loop, so the residual
# per-lane `Float64`→`Any` box is tolerated. `interp.*` never reaches here — those
# are lowered to typed specs at build time.
function _eval_vec_fn_boxed(n::_VecNode, u, p, t, ::Type{T})::_VecVal{T} where {T}
    fname, spec = n.payload::Tuple{String,Any}
    # Only the all-scalar `datetime.*` path (payload second slot `nothing`)
    # reaches here; `interp.*` specs are handled by `_eval_vec_fn` above.
    spec === nothing ||
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_VEC_OP", string("fn:", fname)))
    c = n.children
    b = _vbuf(n, T)
    args = n.fnargs
    cv = n.cvbufs
    len = length(b)
    @inbounds for a in eachindex(c)
        cv[a] = _eval_vec(c[a], u, p, t, T)
    end
    @inbounds for lane in 1:len
        for a in 1:length(cv)
            args[a] = (cv[a]::AbstractVector)[lane]
        end
        b[lane] = evaluate_closed_function(fname, args)
    end
    return b
end

# The MECHANICAL unary elementwise arms of `_eval_vec_op` (`sin` … `ceil`),
# GENERATED from the op-registry table `_UNARY_ELEMENTWISE_OPS`
# (src/op_registry.jl) so a unary op added to the registry grows this ladder
# automatically. The generated body is one `op === :name` compare chain in
# table (= original hand-ladder arm) order, each arm equivalent to the
# hand-written original:
#     _expect_arity_n(op, c, 1); c1 = _eval_vec(c[1], u, p, t, T)
#     @. b = fn(c1); return b
# — same arity guard, same fused broadcast, same buffer discipline (write the
# caller's `b`, return `b`). Returns `nothing` when `op` is not a mechanical
# unary op, so the caller's ladder falls through to the structurally distinct
# arms (`-`, `atan`, `min`/`max`, …). This is NOT a Dict/table dispatch: the
# splice compiles to the same compare-and-branch machine code as the hand
# ladder, and bit-identity with the scalar path is pinned by the vectorized
# differential tests.
let arms = :(return nothing)
    for row in reverse(_UNARY_ELEMENTWISE_OPS)
        # The arm splices the op SYMBOL (`sin`), not the registry's function
        # VALUE: `@.` deliberately refuses to dotify spliced non-Symbol callees
        # (`Base.Broadcast.dottable(x) = false`), and the symbol reproduces the
        # hand-written arm's module-scope name resolution exactly. The registry
        # pins `sym === Symbol(name)` with `fn` the equally-named Base function;
        # the load-time check after this block asserts that identity per arm.
        # NB: `Core.Expr` is Julia's AST node builder (used to assemble this @eval'd arm).
        arms = Core.Expr(:if, :(op === $(QuoteNode(row.sym))),
                         quote
                             _expect_arity_n(op, c, 1)
                             c1 = _eval_vec(c[1], u, p, t, T)
                             @. b = $(row.sym)(c1)
                             return b
                         end,
                         arms)
    end
    @eval @inline function _eval_vec_unary_elementwise(op::Symbol, c::Vector{_VecNode},
                                                       b::AbstractVector, u, p, t,
                                                       ::Type{T}) where {T}
        $arms
    end
end

# Load-time guard for the symbol-spliced arms above: each op name must still
# resolve, in THIS module's scope, to the registry's recorded scalar function —
# so a future shadowing of e.g. `log` cannot silently desync the generated
# ladder from the `_OP_TABLE` row (and from the scalar `_eval_node_op` twin,
# which resolves the same module-scope names).
for _row in _UNARY_ELEMENTWISE_OPS
    getfield(@__MODULE__, _row.sym) === _row.fn ||
        error("vectorize.jl: unary ladder arm '$(_row.name)' does not resolve " *
              "to the op-registry scalar function in module scope")
end

# Elementwise op over child vectors, written in place into `n.buf`. Each arm
# mirrors the corresponding scalar arm in `_eval_node_op` — fused `@.` broadcasts
# apply the identical scalar op lane-by-lane, so lane j equals the scalar value
# for cell j (bit-identical). Children are read but never mutated; `n.buf` is
# disjoint from every child buffer, so writing it is always safe. Pure
# pass-through arms (1-ary `+`/`*`/`min`/`max`, `Pre`) return the child buffer
# directly — the parent only reads it.
function _eval_vec_op(n::_VecNode, u, p, t, ::Type{T})::_VecVal{T} where {T}
    op = n.op
    c = n.children
    b = _vbuf(n, T)

    if op === :+
        c1 = _eval_vec(c[1], u, p, t, T)
        length(c) == 1 && return c1
        c2 = _eval_vec(c[2], u, p, t, T)
        @. b = c1 + c2
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t, T)
            @. b += ci
        end
        return b
    elseif op === :*
        c1 = _eval_vec(c[1], u, p, t, T)
        length(c) == 1 && return c1
        c2 = _eval_vec(c[2], u, p, t, T)
        @. b = c1 * c2
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t, T)
            @. b *= ci
        end
        return b
    elseif op === :-
        c1 = _eval_vec(c[1], u, p, t, T)
        if length(c) == 1
            @. b = -c1
            return b
        elseif length(c) == 2
            c2 = _eval_vec(c[2], u, p, t, T)
            @. b = c1 - c2
            return b
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "- expects 1 or 2 args"))
    elseif op === :neg
        _expect_arity_n(op, c, 1)
        c1 = _eval_vec(c[1], u, p, t, T)
        @. b = -c1
        return b
    elseif op === :/
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T)
        c2 = _eval_vec(c[2], u, p, t, T)
        @. b = c1 / c2
        return b
    elseif op === :^ || op === :pow
        # THE ONE ARM THAT DEPENDS ON DATA NODES STAYING `Float64`. `^` is the only
        # op whose derivative w.r.t. an OPERAND needs a function with a smaller
        # domain than the op itself: ∂(x^y)/∂y = x^y·log(x). If a literal exponent
        # were lifted into the differentiable type, ForwardDiff would evaluate that
        # branch despite the exponent's partials all being zero — so `c[i]^2` over a
        # lane vector holding any NEGATIVE cell would produce log(negative) = NaN and
        # silently poison the gradient while the primal values still looked perfect.
        # `_VK_LITERAL` and `_VK_CONSTVEC` yield `Vector{Float64}` at every value
        # type, so a literal / const-array exponent lowers to `Dual^Float64` — the
        # power rule. A state- or parameter-dependent exponent lowers to `Dual^Dual`,
        # which is what it should be.
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T)
        c2 = _eval_vec(c[2], u, p, t, T)
        @. b = c1 ^ c2
        return b

    elseif op === :<
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = ifelse(c1 <  c2, 1.0, 0.0); return b
    elseif op === Symbol("<=")
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = ifelse(c1 <= c2, 1.0, 0.0); return b
    elseif op === :>
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = ifelse(c1 >  c2, 1.0, 0.0); return b
    elseif op === Symbol(">=")
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = ifelse(c1 >= c2, 1.0, 0.0); return b
    elseif op === Symbol("==")
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = ifelse(c1 == c2, 1.0, 0.0); return b
    elseif op === Symbol("!=")
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = ifelse(c1 != c2, 1.0, 0.0); return b

    elseif op === :and
        # 1.0 iff every child is non-zero (folds in child order, like the scalar
        # arm; all children are evaluated — no short-circuit, matching prior code).
        fill!(b, 1.0)
        @inbounds for a in eachindex(c)
            ca = _eval_vec(c[a], u, p, t, T)
            @. b = ifelse((b != 0) & (ca != 0), 1.0, 0.0)
        end
        return b
    elseif op === :or
        fill!(b, 0.0)
        @inbounds for a in eachindex(c)
            ca = _eval_vec(c[a], u, p, t, T)
            @. b = ifelse((b != 0) | (ca != 0), 1.0, 0.0)
        end
        return b
    elseif op === :not
        _expect_arity_n(op, c, 1)
        c1 = _eval_vec(c[1], u, p, t, T)
        @. b = ifelse(c1 == 0, 1.0, 0.0); return b
    elseif op === :ifelse
        # EAGER, BY CONSTRUCTION — and deliberately divergent from the scalar walkers.
        # Both branches are evaluated over the WHOLE lane vector before the blend,
        # because the predicate is per-lane: laziness here would mean evaluating each
        # branch under its own mask, which is a different (masked-gather) kernel, not
        # a reordering of this one. The consequence is that a guarded-domain
        # expression inside an `arrayop` is NOT protected by its guard —
        # `ifelse(u[i] >= 0, sqrt(u[i]), 0)` still calls `sqrt` on the negative lanes
        # — whereas the same expression in a SCALAR equation is (both `_eval_node_op`
        # and `_oop_eval_op` short-circuit `ifelse`/`and`/`or`). This is why the CSE
        # guard rule (compile.jl) is scoped to the scalar path: on the array path
        # there is no laziness for a hoist to break. Filters lower to a runtime
        # `ifelse` (resolve.jl), so filtered aggregates inherit this too. Known and
        # accepted; changing it means changing the kernel, not the CSE pass.
        _expect_arity_n(op, c, 3)
        c1 = _eval_vec(c[1], u, p, t, T)
        c2 = _eval_vec(c[2], u, p, t, T)
        c3 = _eval_vec(c[3], u, p, t, T)
        @. b = ifelse(c1 != 0, c2, c3); return b

    # The 19 mechanical unary arms (`sin` … `ceil`) are GENERATED from the
    # registry table — see `_eval_vec_unary_elementwise` above. `nothing` ⇒ not
    # one of them ⇒ fall through to the structurally distinct arms below. The
    # probe sits where the first mechanical arm (`sin`) sat; every arm tests
    # `op === <disjoint symbol>`, so probing the second historical run
    # (`sinh` … `ceil`) before `atan`/`atan2` cannot change which arm fires.
    elseif (unary = _eval_vec_unary_elementwise(op, c, b, u, p, t, T)) !== nothing
        return unary
    elseif op === :atan
        if length(c) == 1
            c1 = _eval_vec(c[1], u, p, t, T)
            @. b = atan(c1); return b
        elseif length(c) == 2
            c1 = _eval_vec(c[1], u, p, t, T)
            c2 = _eval_vec(c[2], u, p, t, T)
            @. b = atan(c1, c2); return b
        end
        throw(TreeWalkError("E_TREEWALK_ARITY", "atan expects 1 or 2 args"))
    elseif op === :atan2
        _expect_arity_n(op, c, 2)
        c1 = _eval_vec(c[1], u, p, t, T); c2 = _eval_vec(c[2], u, p, t, T)
        @. b = atan(c1, c2); return b
    elseif op === :min
        # n-ary min (esm-spec §4.2 — arity ≥ 2), matching the scalar arm's guard.
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "min needs ≥2 args"))
        c1 = _eval_vec(c[1], u, p, t, T)
        c2 = _eval_vec(c[2], u, p, t, T)
        @. b = min(c1, c2)
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t, T)
            @. b = min(b, ci)
        end
        return b
    elseif op === :max
        # n-ary max (esm-spec §4.2 — arity ≥ 2), matching the scalar arm's guard.
        length(c) < 2 && throw(TreeWalkError("E_TREEWALK_ARITY", "max needs ≥2 args"))
        c1 = _eval_vec(c[1], u, p, t, T)
        c2 = _eval_vec(c[2], u, p, t, T)
        @. b = max(c1, c2)
        @inbounds for i in 3:length(c)
            ci = _eval_vec(c[i], u, p, t, T)
            @. b = max(b, ci)
        end
        return b

    elseif op === :pi || op === :π
        fill!(b, Float64(pi)); return b
    elseif op === :e
        fill!(b, Float64(ℯ)); return b
    elseif op === :Pre
        _expect_arity_n(op, c, 1)
        return _eval_vec(c[1], u, p, t, T)
    else
        throw(TreeWalkError("E_TREEWALK_UNSUPPORTED_VEC_OP", String(op)))
    end
end

# Inner closure generator — separated so the closure's body is small
# enough to stay inferable. `rhs_list` and `vec_kernels` are captured by the
# closure; Julia specializes the generated method to the captured types.
# Scalar/indexed-D equations evaluate through `rhs_list` (one slot each); array
# (`arrayop`) equations evaluate through `vec_kernels` as whole-array ops.
# Accepts any AbstractVector so both the pre-allocated and the
# dynamically-grown forms produced by build_evaluator work.
#
# The vectorized scatter writes lane values back into `du` with an explicit
# indexed loop (NOT `du[out_slots] .= …`, whose `dotview` allocates a SubArray):
# combined with the in-place `_eval_vec`, the whole RHS is allocation-free in
# steady state (ess-9cc), so it can be reused across every RK stage without GC
# pressure. Property pinned by the `@allocated f!(du,u,p,t) == 0` test.
#
# ELTYPE-GENERIC, STILL ZERO-ALLOC. `f!` computes in `T = _rhs_value_type(u, p, t)`,
# which is a compile-time constant per specialization — so at `T === Float64` the
# two scratch lookups below (`_cse_buf`, and `_vbuf` inside `_eval_vec`) are field
# loads and this is exactly the Float64 RHS it always was. Hand it `Dual` state
# (a ForwardDiff Jacobian for a stiff solver) or a `Dual`-valued parameter
# NamedTuple (a sensitivity) and the SAME closure evaluates in `Dual`, reusing the
# per-node Dual buffers created on the first such call. `t` is folded into the value
# type alongside `u` and `p` precisely so the parameter axis works: there `u` stays
# `Vector{Float64}` and only the parameter VALUES are `Dual`, so a scratch sized
# from `eltype(u)` alone would compile and then throw `Float64(::Dual)` on its first
# store.
function _make_rhs(rhs_list::AbstractVector{Tuple{Int,_Node}},
                   cse_prelude::AbstractVector{_Node},
                   cse_cache::_CSECache,
                   vec_kernels::AbstractVector{_VecKernel})
    function f!(du, u, p, t)
        T = _rhs_value_type(u, p, t)
        # CSE prelude (ess-r7h): evaluate each distinct shared subexpression
        # exactly once per call into the scratch cache, in slot order. `defs[s]`
        # references only slots < s (topological), so each read is already
        # filled. Every slot is overwritten each call, so there is no staleness;
        # the cache makes `f!` non-reentrant (one instance per integrator, which
        # is how ODE RHS closures are used). Empty prelude ⇒ this loop is a no-op
        # and f! is identical to the pre-CSE evaluator.
        #
        # This loop is UNCONDITIONAL — every slot is evaluated before any equation
        # runs, whether or not the guard above its occurrence would have fired. That
        # is safe only because `_cse_compile_scalar` refuses to hoist a key whose
        # every occurrence sits under a lazy `ifelse`/`and`/`or` arm (see the GUARDS
        # note in compile.jl); a slot that exists always has an occurrence the walk
        # would have evaluated anyway.
        cache = _cse_buf(cse_cache, T)
        @inbounds for s in 1:length(cse_prelude)
            cache[s] = _eval_node(cse_prelude[s], u, p, t, T)
        end
        @inbounds for k in 1:length(rhs_list)
            idx_and_node = rhs_list[k]
            du[idx_and_node[1]] = _eval_node(idx_and_node[2], u, p, t, T)
        end
        @inbounds for j in 1:length(vec_kernels)
            vk = vec_kernels[j]
            res = _eval_vec(vk.template, u, p, t, T)
            out = vk.out_slots
            for m in 1:length(out)
                du[out[m]] = res[m]
            end
        end
        return nothing
    end
    return f!
end
