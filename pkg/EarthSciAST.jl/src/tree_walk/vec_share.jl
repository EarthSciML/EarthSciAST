# ========================================================================
# tree_walk/vec_share.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4f: LANE-VARYING vector CSE — sharing a whole
# N-lane vector within and across array kernels
# (EarthSciSerialization-cp5).
# ========================================================================
#
# THE GAP THIS CLOSES — AND HOW IT DIFFERS FROM THE ONE NEXT DOOR
# ---------------------------------------------------------------
# invariant_share.jl (section 4e) shares LANE-INVARIANT subtrees: a subexpression
# with no free cell index has ONE value for the whole kernel, so it collapses to a
# scalar in the `_CSECache` and is broadcast. Everything it shares is a SCALAR.
#
# Nothing shared a VECTOR. Two consumers of the same per-cell quantity each lowered
# their own copy of it, with its own N-lane buffer, evaluated on every RHS call:
#
#     D(u[i]) = sin(u[i] + w[i]) + cos(u[i] + w[i])   # one kernel, twice
#     D(A[i]) = -k*A[i]*B[i] ;  D(B[i]) = -k*A[i]*B[i]   # two kernels, once each
#
# The second shape is the one that matters in practice — a shared reaction flux or
# advective flux appearing in several species' balances is the dominant per-step cost
# of a real chemistry-transport RHS, and it is recomputed once per balance.
#
# This pass gives those a VEC PRELUDE: a list of `_VecNode` defs evaluated once per
# RHS call, before any kernel, each writing its own lane buffer; every occurrence
# becomes a `_VK_VCACHED` node that simply reads that buffer. It is the scalar CSE
# prelude's exact analogue one level up — scalars there, N-lane vectors here.
#
# WHY CROSS-KERNEL SHARING NEEDS NO NOTION OF "THE SAME CELLS"
# ------------------------------------------------------------
# The obvious worry is that kernel A's lane 3 and kernel B's lane 3 are different
# cells, so a vector computed in one is meaningless in the other — which would make
# cross-kernel sharing require a lane-axis identity that `_VecKernel` does not track.
#
# The worry is unfounded, and seeing why is what makes this pass simple. Sharing does
# not need the two kernels to mean the same cells; it needs them to compute the same
# VECTOR. And the lane data is right there in the node: a `_VK_GATHER`'s value is
# determined ENTIRELY by its `slots`, a `_VK_CONSTVEC`'s by its `vals`. So a value
# number that keys those vectors BY VALUE already proves what is needed — two nodes
# with the same key gather from the same places in the same order and therefore hold
# the identical vector, whatever cells the surrounding kernels happen to be about. The
# slots vector IS the lane identity. Kernels over different cells simply key
# differently and do not share.
#
# `len` is in the key for the same reason, and it is not redundant: a `_VK_TIME` in a
# 100-lane kernel and one in a 50-lane kernel are structurally identical but produce
# different-length vectors, and sharing them would feed a length-100 buffer to a
# length-50 broadcast.
#
# WHY A DAG IS STILL SAFE FOR THE IN-PLACE WALKER
# -----------------------------------------------
# This pass hash-conses the templates, so a `_VecNode` can now have SEVERAL parents. That
# is a real change of shape, and `_eval_vec`'s zero-allocation scheme rests on a buffer
# invariant that was stated for a TREE: "no node ever mutates a child's buffer — the
# template is a pure tree, so every node's buffer is disjoint from all of its
# descendants'." Two things keep it true here.
#
#   1. Disjointness survives. Each canonical node still owns exactly ONE `buf` (the one it
#      was built with — `_vec_rebuild` REUSES it and `_vec_canon!` memoizes on the source
#      node, so no node's buffer is ever aliased to another's), and a node cannot be its
#      own descendant. So parent-vs-descendant buffers are still disjoint; what changed is
#      only that a node may now be reached by more than one path.
#   2. Re-walking a shared node is harmless. A node with in-degree ≥ 2 that is NOT lifted
#      (a `_VK_LITERAL`, a `_VK_INVARIANT`) is simply evaluated once per parent edge,
#      rewriting its own buffer with the SAME values — evaluation is pure within a call
#      (`u`, `p`, `t` and the forcing buffers are all fixed), so a parent holding that
#      buffer across a sibling's evaluation still sees the value it read. Correct, merely
#      not free — which is exactly what the hoist below is for.
#
# So the DAG is a correctness-neutral memory win, and the LIFT is the time win. They are
# separable, and that is why the hoist policy (`_vk_hoistable`) can be tuned freely without
# ever putting correctness at risk.
#
# WHY THE HOIST IS SAFE (no guard rule needed)
# --------------------------------------------
# The scalar CSE pass may only hoist a key with an unconditional occurrence, because
# `_eval_node_op` is LAZY for `ifelse`/`and`/`or` and the prelude runs before any
# equation. This pass needs no such rule: `_eval_vec` is EAGER by construction — its
# `ifelse` arm evaluates all three branches over the whole lane vector before blending,
# `and`/`or` fold every child, `_VK_REDUCE`/`_VK_FN` evaluate every child. Every node in
# a template is therefore already evaluated on every call, so lifting one into the
# prelude introduces no evaluation that was not happening anyway: no new `DomainError`,
# no new NaN. (Same argument as invariant_share.jl's, and same for the `:oop` emitter,
# whose `_oop_eval_vec` is eager for the same reason.)

# ---- The key: an EXACT structural value number for a `_VecNode` ---------------
#
# Same discipline as invariant_share.jl's `_node_vn`, and the same warning applies with
# double force: this is NOT `_struct_sig!`. That function DELIBERATELY ignores leaf
# values — literals print as a bare `L`, state slots as a bare `S`, gather offsets not at
# all — precisely so cells differing only in those merge into one template with per-lane
# vectors. Keying sharing on it would merge nodes holding DIFFERENT vectors. Here every
# field that can move the value is in the key, and anything not modelled FAILS CLOSED to
# `_VVN_NONE`, which poisons its ancestors and declines sharing for that subtree. Sharing
# is an optimization; declining costs a re-walk, guessing costs correctness.
#
#   kind · op · literal BITS · idx · sym · len · payload id · vals · slots · child VNs
#
# The scalar `literal` is keyed by its RAW BITS (`reinterpret`); the lane VECTORS (`vals`,
# `slots`, and an `fn` spec's tables) are keyed by CONTENT via `isequal` — the same
# predicate, without the O(N) copy. See the note above `_vk_fn_content_key`.
#
# The payload id is per kind:
#   * `_VK_PGATHER` — the IDENTITY of the captured live forcing buffer (an `IdDict`, so
#     unlike an `objectid` no collision is even representable). Same buffer object + same
#     `slots` ⇒ same memory ⇒ same vector (a forcing buffer cannot change mid-call).
#   * `_VK_FN` — the function's NAME and the typed spec's CONTENT (every table/axis
#     element), never the spec object's identity: `_build_interp_spec` mints
#     a fresh spec per compile, so two `interp.linear` calls over the same table hold
#     different objects and must still share — while two over DIFFERENT tables must not.
#   * `_VK_INVARIANT` — the SCALAR value number of its `_Node` payload, borrowed from
#     invariant_share.jl's `_ShareCtx`. That is what lets `A*u[i]` and `A*w[i]` recognise
#     a common `A`, and (once invariant_share.jl has rewritten shared payloads to
#     `_NK_CACHED`) makes the match a single slot compare.
#   * any other kind carrying a non-`nothing` payload — the IR has drifted away from what
#     this key models, so decline rather than key past it.

const _VVN_NONE = 0   # "unkeyable" — never a real value number (those start at 1)

# A `Tuple` hashes and compares ELEMENTWISE and its `Vector{Int}` child slot compares by
# VALUE, so this is a sound `Dict` key with no custom `hash`/`==` to get wrong. The
# variable-length parts (`vals`, `slots`) are INTERNED to `Int` ids rather than
# inlined, which keeps each node's key O(arity) instead of O(subtree).
const _VecVNKey =
    Tuple{UInt8,Symbol,UInt64,Int,Symbol,Int,Int,Int,Int,Vector{Int}}

mutable struct _VecShareCtx
    sctx::_ShareCtx                  # scalar value numbers, for `_VK_INVARIANT` payloads
    vn::Dict{_VecVNKey,Int}          # structural key → value number (the hash-cons table)
    vn_of::IdDict{_VecNode,Int}      # CANONICAL node → its value number
    canon::Dict{Int,_VecNode}        # value number → the one canonical node for it
    ident_ids::IdDict{Any,Int}       # payloads keyed by IDENTITY (forcing buffers)
    content_ids::Dict{Any,Int}       # payloads/vectors keyed by CONTENT
    next_vn::Int
    next_id::Int
end
_VecShareCtx(sctx::_ShareCtx) =
    _VecShareCtx(sctx, Dict{_VecVNKey,Int}(), IdDict{_VecNode,Int}(), Dict{Int,_VecNode}(),
                 IdDict{Any,Int}(), Dict{Any,Int}(), 0, 0)

function _vshare_ident!(ctx::_VecShareCtx, obj)::Int
    id = get(ctx.ident_ids, obj, 0)
    id == 0 || return id
    ctx.next_id += 1
    ctx.ident_ids[obj] = ctx.next_id
    return ctx.next_id
end

# CONTENT ids share one `Dict{Any,Int}`, so every caller TAGS its key with a leading
# symbol. Without that, `Vector{UInt64}([1])` and `Vector{Int}([1])` are `isequal` — a
# `vals` vector and a `slots` vector could collide and swap ids.
function _vshare_content!(ctx::_VecShareCtx, key)::Int
    id = get(ctx.content_ids, key, 0)
    id == 0 || return id
    ctx.next_id += 1
    ctx.content_ids[key] = ctx.next_id
    return ctx.next_id
end

# THE FLOAT VECTORS GO INTO THE KEY BY REFERENCE, NOT AS A COPY — and the semantics are
# unchanged by that, which is the only reason it is allowed.
#
# The obvious way to key a `Vector{Float64}` bit-exactly is to reinterpret it into a fresh
# `Vector{UInt64}` (what invariant_share.jl's `_f64_bits` does for the ≤1024-entry interp
# tables, where the copy is free). Doing that HERE would be a real build-time tax: a
# `_VK_CONSTVEC`'s `vals` is a LANE vector, one `Float64` per cell, so the copy is O(N) time
# AND O(N) allocation per const-array leaf — megabytes on a large grid, for a key that is
# thrown away at the end of the pass.
#
# It is also unnecessary. A `Dict` hashes an `AbstractArray` by CONTENT and looks it up with
# `isequal`, and `isequal` on `Float64` is exactly the predicate wanted: it separates `0.0`
# from `-0.0` (which `==` does not, though `1/0.0` and `1/-0.0` differ) and it makes two NaNs
# compare equal (which `==` does not, though two NaN lanes do compute the same thing). That
# is the same discipline the raw-bits key encodes — and the same one `_fn_spec_content_equal`
# already relies on — so the vectors go in as-is. Hashing still walks them, but it allocates
# nothing.
#
# The CONTENT key of a `_VK_FN` payload, or `nothing` if it is not a shape this pass models
# (fail closed). NOTE the payload layout differs from the scalar `:fn` node's: `_merge_fn_node`
# puts the BARE typed spec on a `_VK_FN` for the `interp.*` kernels, and the `(fname, nothing)`
# tuple only on the boxed all-scalar (`datetime.*`) path.
function _vk_fn_content_key(payload)
    if payload isa _InterpLinearSpec
        return (:vkfn, :linear, payload.table, payload.axis)
    elseif payload isa _InterpBilinearSpec
        return (:vkfn, :bilinear, payload.table, payload.axis_x, payload.axis_y)
    elseif payload isa _InterpSearchsortedSpec
        return (:vkfn, :searchsorted, payload.xs)
    elseif payload isa Tuple{String,Any}
        fname, spec = payload
        # The boxed path carries `(fname, nothing)`. A typed spec wrapped in a tuple on a
        # `_VK_FN` is not a layout `_merge_fn_node` produces; decline rather than guess.
        spec === nothing && return (:vkfn, :boxed, fname)
        return nothing
    end
    return nothing
end

# Rebuild an immutable `_VecNode` with new children, REUSING every build-time buffer
# (`buf`, `altbuf`, `vals`, `slots`, `fnargs`, `cvbufs`). `_mkvnode` would mint fresh
# ones, and `f!`'s zero-allocation property rests on these being the build-time objects
# captured in the closure.
_vec_rebuild(n::_VecNode, kids::Vector{_VecNode}) =
    _VecNode(n.kind, n.op, n.literal, n.idx, n.sym, n.payload, n.vals, n.slots,
             kids, n.buf, n.altbuf, n.fnargs, n.cvbufs)

function _vec_vn!(n::_VecNode, ctx::_VecShareCtx)::Int
    k = n.kind
    # A ref node is this pass's OWN output, never one of its inputs. It is also the only
    # bufless kind besides `_VK_CONSTVEC`, so `_vk_len` cannot size it — key it and two refs
    # to different-length defs would collide. Fail closed, which also makes the pass safely
    # idempotent if it is ever run twice.
    k === _VK_VCACHED && return _VVN_NONE
    kids = n.children
    cvn = Vector{Int}(undef, length(kids))
    for i in eachindex(kids)
        v = get(ctx.vn_of, kids[i], _VVN_NONE)
        v == _VVN_NONE && return _VVN_NONE      # an unkeyable child poisons its ancestors
        cvn[i] = v
    end

    pay = 0
    if k === _VK_PGATHER
        buf = n.payload
        buf isa Vector{Float64} || return _VVN_NONE
        pay = _vshare_ident!(ctx, buf)
    elseif k === _VK_FN
        ck = _vk_fn_content_key(n.payload)
        ck === nothing && return _VVN_NONE
        pay = _vshare_content!(ctx, ck)
    elseif k === _VK_INVARIANT
        sp = n.payload
        sp isa _Node || return _VVN_NONE
        sv = _node_vn(sp, ctx.sctx)
        sv == _VN_NONE && return _VVN_NONE
        pay = _vshare_content!(ctx, (:inv, sv))
    elseif n.payload !== nothing
        return _VVN_NONE
    end

    # Both lane vectors go in BY REFERENCE — hashed and compared by content, never copied.
    # See the note above `_vk_fn_content_key`: a copy here would be O(N) allocation per leaf.
    vid = isempty(n.vals) ? 0 : _vshare_content!(ctx, (:vals, n.vals))
    sid = isempty(n.slots) ? 0 : _vshare_content!(ctx, (:slots, n.slots))
    key = (k, n.op, reinterpret(UInt64, n.literal), n.idx, n.sym, _vk_len(n),
           pay, vid, sid, cvn)::_VecVNKey

    got = get(ctx.vn, key, _VVN_NONE)
    got == _VVN_NONE || return got
    ctx.next_vn += 1
    ctx.vn[key] = ctx.next_vn
    return ctx.next_vn
end

# ---- 1. Hash-cons the templates into a DAG -----------------------------------
#
# Bottom-up: canonicalize the children, then key the node against the children's VALUE
# NUMBERS. Two nodes with the same value number become the SAME OBJECT — which by itself
# already halves the buffers a duplicated subtree used to own. It does NOT by itself save
# any time (`_eval_vec` re-walks a shared object once per parent edge, recomputing the
# same values into the same buffer — correct, since evaluation is pure within a call, but
# not free); the time is saved by the hoist below.
#
# An UNKEYABLE node keeps its own identity and shares with nothing, but its keyable
# descendants are still canonicalized underneath it.
function _vec_canon!(n::_VecNode, ctx::_VecShareCtx,
                     memo::IdDict{_VecNode,_VecNode})::_VecNode
    hit = get(memo, n, nothing)
    hit === nothing || return hit

    changed = false
    kids = Vector{_VecNode}(undef, length(n.children))
    for i in eachindex(n.children)
        c = _vec_canon!(n.children[i], ctx, memo)
        changed |= c !== n.children[i]
        kids[i] = c
    end
    node = changed ? _vec_rebuild(n, kids) : n

    v = _vec_vn!(node, ctx)
    if v != _VVN_NONE
        prev = get(ctx.canon, v, nothing)
        if prev === nothing
            ctx.canon[v] = node
        else
            node = prev                        # a duplicate: collapse onto the canonical
        end
    end
    ctx.vn_of[node] = v
    memo[n] = node
    return node
end

# ---- 2. In-degree over the DAG -----------------------------------------------
#
# Counted by OBJECT identity and per parent EDGE — so `x*x` gives `x` an in-degree of 2
# from its single parent, which is right: `_eval_vec_op` evaluates `c[1]` and `c[2]`
# separately and would walk it twice. Each kernel ROOT contributes an edge too, so a
# template that is itself a shared subtree of another kernel is hoisted like any node.
function _vec_indegree(roots::Vector{_VecNode})::IdDict{_VecNode,Int}
    indeg = IdDict{_VecNode,Int}()
    visited = Base.IdSet{_VecNode}()
    for r in roots
        indeg[r] = get(indeg, r, 0) + 1
    end
    stack = copy(roots)
    while !isempty(stack)
        n = pop!(stack)
        n in visited && continue               # its child edges are already counted ONCE
        push!(visited, n)
        for c in n.children
            indeg[c] = get(indeg, c, 0) + 1
            push!(stack, c)
        end
    end
    return indeg
end

# ---- 3/4. Lift the shared nodes into the vec prelude and rewrite --------------
#
# Post-order over the DAG, so a def's own children are emitted before it and the prelude
# comes out TOPOLOGICALLY ORDERED for free — `f!` can then just run it front to back.
#
# In-degree ≥ 2 is the exact hoist rule, and building the DAG FIRST is what makes it
# exact. Counting duplicate subtrees in the original TREES instead would over-count:
# `sin(x+y) + cos(x+y)` has two copies of `x+y`, but also two copies of the gather `x`
# inside them — and once `x+y` is hoisted there is only ONE `x` left, so a
# count-on-the-tree rule would mint a pointless slot for it. On the DAG, `x` has
# in-degree 1 (its single parent is the one canonical `x+y`) and correctly stays inline.
function _vec_lift!(n::_VecNode, ctx::_VecShareCtx, indeg::IdDict{_VecNode,Int},
                    prelude::Vector{_VecNode}, done::IdDict{_VecNode,_VecNode},
                    sites::Base.RefValue{Int})::_VecNode
    hit = get(done, n, nothing)
    hit === nothing || return hit

    changed = false
    kids = Vector{_VecNode}(undef, length(n.children))
    for i in eachindex(n.children)
        c = _vec_lift!(n.children[i], ctx, indeg, prelude, done, sites)
        changed |= c !== n.children[i]
        kids[i] = c
    end
    # `body` may be a REBUILT object (its children changed), so it is not a key in
    # `indeg` — every lookup here must use the CANONICAL `n`, which is what `indeg` and
    # `done` are keyed by. Counting `sites` at the moment of the hoist rather than from
    # the finished `prelude` is exactly why: `get(indeg, body, 0)` would quietly be 0.
    body = changed ? _vec_rebuild(n, kids) : n

    out = body
    deg = get(indeg, n, 0)
    if deg >= 2 && _vk_hoistable(n)
        push!(prelude, body)
        sites[] += deg
        # ONE ref object serves every occurrence — it is read-only and O(1), so sharing it
        # costs nothing. `payload` is the def itself, so `_eval_vec` needs no slot lookup;
        # `idx` is carried for the `:oop` emitter, which indexes a per-call result vector.
        out = _mkvnode(kind=_VK_VCACHED, idx=length(prelude), payload=body)
    end
    done[n] = out
    return out
end

# ---- The pass ----------------------------------------------------------------
#
# Mutates `vec_kernels` IN PLACE and RETURNS the vec prelude (which the `f!` / `f` closure
# captures alongside it) plus the diagnostic counters. Runs AFTER `_share_lane_invariants!`
# — that pass rewrites `_VK_INVARIANT` payloads into `_NK_CACHED` reads, and this one keys
# those payloads, so running it second means an invariant shared across kernels is already
# a single slot compare here. A model with no array kernels is untouched.
function _share_lane_vectors!(vec_kernels::Vector{_VecKernel},
                              scalar_prelude::Vector{_Node},
                              scalar_cache::_CSECache)
    none = (; n_vec_slots = 0, n_vec_shared = 0, n_vec_prelude_nodes = 0)
    isempty(vec_kernels) && return (_VecNode[], none)

    # Scalar value numbers, for the `_VK_INVARIANT` payloads. Slot order is topological,
    # so every `_NK_CACHED(j)` inside `scalar_prelude[s]` has `j < s` and its expansion is
    # resolved before it is needed.
    sctx = _ShareCtx(scalar_cache, length(scalar_prelude))
    for s in eachindex(scalar_prelude)
        sctx.slot_vn[s] = _node_vn(scalar_prelude[s], sctx)
    end
    ctx = _VecShareCtx(sctx)

    memo = IdDict{_VecNode,_VecNode}()
    roots = _VecNode[_vec_canon!(vk.template, ctx, memo) for vk in vec_kernels]
    indeg = _vec_indegree(roots)

    prelude = _VecNode[]
    done = IdDict{_VecNode,_VecNode}()
    # Occurrence SITES collapsed onto a def — the honest "how much did this save" number.
    # Each def has in-degree ≥ 2 by construction, so this is ≥ 2 × the slot count.
    sites = Ref(0)
    for j in eachindex(vec_kernels)
        vk = vec_kernels[j]
        tmpl = _vec_lift!(roots[j], ctx, indeg, prelude, done, sites)
        tmpl === vk.template && continue
        vec_kernels[j] = _VecKernel(vk.out_slots, tmpl, vk.len)
    end

    return (prelude, (; n_vec_slots = length(prelude),
                        n_vec_shared = sites[],
                        n_vec_prelude_nodes =
                            sum(_count_vecnodes(d) for d in prelude; init = 0)))
end
