# ========================================================================
# tree_walk/invariant_share.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4e: CROSS-KERNEL and KERNEL↔PRELUDE sharing of
# lane-invariant subtrees — a post-pass over the COMPILED `_Node` IR
# (EarthSciSerialization-ha2).
# ========================================================================
#
# THE GAP THIS CLOSES
# -------------------
# Two independent mechanisms name a repeated computation, and until this pass they
# had nothing to say to each other:
#
#   * `_cse_compile_scalar` (compile.jl) shares subexpressions across SCALAR
#     equations, keyed on `canonical_json`, into a prelude of `_CSECache` slots.
#   * `_maybe_hoist_invariant` (vectorize.jl) collapses a lane-invariant subtree of
#     ONE array kernel to a single `_VK_INVARIANT` node — one scalar eval per RHS
#     call instead of N, but PER KERNEL, and shared with nothing.
#
# So a lane-invariant Arrhenius factor `A*exp(-Ea/(R*Tref))` appearing in two array
# equations and one scalar equation was evaluated THREE times per RHS call: once per
# kernel, plus once inline in the scalar tree. And worse, the scalar occurrence was a
# SINGLETON as far as `_cse_count!` could see — the count pass walks `ASTExpr`
# entries, and array equations never produce any — so the kernels did not merely fail
# to share with the prelude, they SUPPRESSED it (`n_cse_slots = 0`).
#
# Extending the AST-level count pass to array equations is not the fix: the array
# path compiles per-cell `_Node`s and lowers them to `_VecNode` templates; the
# `ASTExpr` the count pass wants is never built. So the sharing is done where the two
# mechanisms DO have a common representation — the compiled `_Node` IR — as a
# post-pass, after `_cse_compile_scalar` has produced the prelude and after the vec
# kernels are built. A `_VK_INVARIANT`'s payload is already a plain scalar `_Node`,
# and `_eval_vec`'s `_VK_INVARIANT` arm already evaluates it with `_eval_node`, which
# resolves `_NK_CACHED` through `_cse_read`. So routing a payload into a prelude slot
# needs no new runtime machinery at all: the payload is REPLACED by an `_NK_CACHED`
# leaf, and the kernel's per-call cost drops from a subtree walk to one field load
# plus the `fill!` it was already doing.
#
# WHY THE HOIST IS SAFE (the guard question, answered once)
# --------------------------------------------------------
# The scalar CSE pass may only hoist a key with at least one UNCONDITIONAL occurrence,
# because the prelude is filled before any equation runs while `_eval_node_op` is LAZY
# for `ifelse`/`and`/`or` — hoisting an operand out from behind its guard would
# evaluate it when the guard says it must not run.
#
# This pass needs no such rule, and the reason is structural rather than lucky:
# **an invariant payload is evaluated unconditionally already.** `_eval_vec` is EAGER
# by construction — its `ifelse` arm evaluates all three children before blending, its
# `and`/`or` arms fold every child, `_VK_REDUCE` and `_VK_FN` evaluate every child —
# so EVERY `_VecNode` in a template, `_VK_INVARIANT` included, is evaluated on every
# call. Promoting a payload to the prelude therefore introduces no evaluation that was
# not already happening on every call: no new `DomainError`, no new NaN. (The same
# holds for the `:oop` emitter, whose `_oop_eval_vec` is eager for the same reason.)
#
# That is also what makes it safe to rewrite a SCALAR occurrence of a shared key —
# even one sitting under a lazy guard — into a cache read. The slot it reads is filled
# on every call regardless, because the kernels need it; the rewrite removes work, it
# does not add any.
#
# WHAT IS DELIBERATELY NOT DONE
# -----------------------------
#   * Intra-template value numbering (audit finding #4a — `sin(u[i]+w[i]) +
#     cos(u[i]+w[i])` lowering `u[i]+w[i]` twice, each with its own lane buffer) is
#     OUT OF SCOPE. It needs a structural key over `_VecNode` plus a per-call
#     lane-buffer cache, which is a different mechanism from this one.
#   * The ORIGINAL prelude defs are never rewritten. A def could in principle contain
#     a subtree that this pass gave a (higher) slot to, but a def may only read slots
#     BELOW its own, so rewriting it would break the prelude's topological order.
#     Only NEW defs are rewritten, against the slots that already exist below them.

# ---- The key: an EXACT structural value number for a `_Node` -------------------
#
# THIS IS THE ONE THING THAT MUST NOT BE APPROXIMATE. Two nodes get the same value
# number iff they are guaranteed to compute the same value; a key that merged two
# nodes computing DIFFERENT values would not crash, it would silently produce wrong
# numbers. So the key is total over every field that can affect the result:
#
#   kind · op · the literal's EXACT BITS · idx · sym · the payload's identity-or-
#   content · and the value numbers of every child, in order.
#
# NOTE — this is emphatically NOT `_struct_sig!` (vectorize.jl), and reusing that
# function here would be the single most dangerous mistake available. `_struct_sig!`
# is a different tool for a different job: it DELIBERATELY ignores leaf VALUES
# (literals print as a bare `L`, state slots as a bare `S`, gather offsets not at all)
# precisely so that cells differing only in those merge into ONE vectorized template
# with per-lane vectors. Keying sharing on it would merge nodes that compute different
# values.
#
# Field-by-field, why each is exact:
#   * `literal` is keyed by its RAW BITS (`reinterpret(UInt64, …)`), not by `==`.
#     `0.0 == -0.0` is true but `1/0.0` and `1/-0.0` are not, and `NaN == NaN` is
#     false though two NaN literals with the same bits do compute the same thing.
#   * `_NK_PARAM_GATHER` is keyed by the IDENTITY of the captured flat buffer (via an
#     `IdDict`, so — unlike an `objectid` — no hash collision is even representable)
#     plus `idx`. Same buffer object + same linear offset ⇒ same memory location ⇒
#     same value (a forcing buffer cannot change mid-call). This is at least as strict
#     as the `(registry name, offset)` identity `_cse_key`'s `_pgather_key_expr` uses,
#     because distinct registry names necessarily hold distinct buffer objects.
#   * `:fn` is keyed by the function NAME **and the typed spec's CONTENT** — every
#     table/axis element, again by raw bits — not by the spec object's identity and
#     not by the name alone. Content, because `_build_interp_spec` builds a FRESH spec
#     object per compile, so two `interp.linear(tbl, ax, t)` calls over the same table
#     in two different equations hold two different objects and must still share. And
#     the content and not just the name, because two `interp.linear` calls over
#     DIFFERENT tables must never share.
#   * `_NK_CACHED` is EXPANDED through its slot: its value number IS the value number
#     of that slot's def. This is what lets a fully-written-out kernel payload match a
#     scalar prelude def whose own body has already been compressed into cache reads —
#     without it, `O:*(C:1,P:A)` and `O:*(O:exp(…),P:A)` would look like different
#     computations. Because the prelude is topologically ordered, numbering the defs in
#     slot order resolves every expansion before it is needed.
#
# Anything not covered above — an unrecognized payload on a node kind that is not
# supposed to carry one, an unrecognized `fn` spec type — FAILS CLOSED: it yields
# `_VN_NONE`, which poisons every ancestor and declines sharing for that subtree.
# Sharing is a pure optimization; declining costs a re-walk, and guessing costs
# correctness.

# The key comes in two halves, and it is worth naming why. `_VNKey` is the exact
# structural key of ONE node, with each child represented by its VALUE NUMBER rather
# than by its own key bytes; `_node_vn` interns a key to a dense `Int`. That indirection
# is not decoration — it is what keeps the pass linear. A self-contained key (a string,
# say) would have to INLINE each `_NK_CACHED` child's whole definition to make a
# compressed prelude def compare equal to a written-out kernel payload, so keying a
# chain of defs would re-emit the fully expanded expression at every level. Numbering
# children instead makes each node's key O(arity), and `_NK_CACHED` expansion becomes a
# single table lookup.

const _VN_NONE = 0   # "unkeyable" — never a real value number (those start at 1)

# A `Tuple` hashes and compares ELEMENTWISE, and its `Vector{Int}` child slot compares
# by VALUE, so this is a sound `Dict` key with no custom `hash`/`==` to get wrong.
const _VNKey = Tuple{UInt8,Symbol,UInt64,Int,Symbol,Int,Vector{Int}}

mutable struct _ShareCtx
    cache::_CSECache                # the one `_CSECache` every `_NK_CACHED` reads
    vn::Dict{_VNKey,Int}            # structural key → value number (the hash-cons table)
    vn_of::IdDict{_Node,Int}        # node OBJECT → its value number (pure ⇒ identity-memoizable)
    slot_vn::Vector{Int}            # prelude slot → the value number its def computes
    ident_ids::IdDict{Any,Int}      # payloads keyed by IDENTITY (forcing buffers)
    content_ids::Dict{Any,Int}      # payloads keyed by CONTENT (`fn` name + spec)
    next_vn::Int
    next_pay::Int
end
_ShareCtx(cache::_CSECache, n_slots::Int) =
    _ShareCtx(cache, Dict{_VNKey,Int}(), IdDict{_Node,Int}(), zeros(Int, n_slots),
              IdDict{Any,Int}(), Dict{Any,Int}(), 0, 0)

function _pay_ident!(ctx::_ShareCtx, obj)::Int
    id = get(ctx.ident_ids, obj, 0)
    id == 0 || return id
    ctx.next_pay += 1
    ctx.ident_ids[obj] = ctx.next_pay
    return ctx.next_pay
end

function _pay_content!(ctx::_ShareCtx, key)::Int
    id = get(ctx.content_ids, key, 0)
    id == 0 || return id
    ctx.next_pay += 1
    ctx.content_ids[key] = ctx.next_pay
    return ctx.next_pay
end

# The raw bits of a `Float64` vector — a bit-exact, `isequal`-flavoured stand-in that
# distinguishes `0.0` from `-0.0` and makes two identical NaNs compare equal. Tables
# are §9.2-capped at ≤1024 entries and this runs once per distinct spec at BUILD time.
_f64_bits(v::AbstractVector{Float64}) = UInt64[reinterpret(UInt64, x) for x in v]

# The CONTENT key of an `:fn` node's `(fname, spec)` payload, or `nothing` if the
# payload is not one this pass understands (fail closed).
function _fn_content_key(payload)
    payload isa Tuple{String,Any} || return nothing
    fname, spec = payload
    if spec === nothing
        return (fname, :none)                      # boxed all-scalar path (`datetime.*`)
    elseif spec isa _InterpLinearSpec
        return (fname, :linear, _f64_bits(spec.table), _f64_bits(spec.axis))
    elseif spec isa _InterpBilinearSpec
        return (fname, :bilinear, [_f64_bits(r) for r in spec.table],
                _f64_bits(spec.axis_x), _f64_bits(spec.axis_y))
    elseif spec isa _InterpSearchsortedSpec
        return (fname, :searchsorted, _f64_bits(spec.xs))
    end
    return nothing
end

function _node_vn(n::_Node, ctx::_ShareCtx)::Int
    v = get(ctx.vn_of, n, -1)
    v == -1 || return v
    v = _node_vn_uncached(n, ctx)
    ctx.vn_of[n] = v
    return v
end

function _node_vn_uncached(n::_Node, ctx::_ShareCtx)::Int
    k = n.kind
    if k === _NK_CACHED
        # Expand through the slot — see the `_NK_CACHED` bullet above. A ref to some
        # OTHER cache, or to a slot we have not numbered yet, is unkeyable.
        n.payload === ctx.cache || return _VN_NONE
        s = n.idx
        (1 <= s <= length(ctx.slot_vn)) || return _VN_NONE
        return ctx.slot_vn[s]
    end
    pay = 0
    if k === _NK_PARAM_GATHER
        buf = n.payload
        buf isa Vector{Float64} || return _VN_NONE
        pay = _pay_ident!(ctx, buf)
    elseif k === _NK_OP && n.op === :fn
        ck = _fn_content_key(n.payload)
        ck === nothing && return _VN_NONE
        pay = _pay_content!(ctx, ck)
    elseif n.payload !== nothing
        # A payload on a kind that is not supposed to carry one: the IR has drifted
        # away from what this key models, so decline rather than key past it.
        return _VN_NONE
    end
    kids = Vector{Int}(undef, length(n.children))
    for i in eachindex(n.children)
        cv = _node_vn(n.children[i], ctx)
        cv == _VN_NONE && return _VN_NONE
        kids[i] = cv
    end
    key = (k, n.op, reinterpret(UInt64, n.literal), n.idx, n.sym, pay, kids)::_VNKey
    got = get(ctx.vn, key, _VN_NONE)
    got == _VN_NONE || return got
    ctx.next_vn += 1
    ctx.vn[key] = ctx.next_vn
    return ctx.next_vn
end

# Only an INTERIOR computation is worth naming: a cache read costs as much as the leaf
# read it would replace. Same rule the scalar pass applies (`_cse_hoistable` never
# hoists a leaf). `_VK_INVARIANT` payload roots are always `_NK_OP` — `_maybe_hoist_invariant`
# refuses a childless op — so every slot this pass creates is `_NK_OP`-rooted.
@inline _share_replaceable(n::_Node) = n.kind === _NK_OP || n.kind === _NK_CONTRACTION

_count_nodes(n::_Node) = 1 + sum(_count_nodes(c) for c in n.children; init=0)

# ---- Rewriting the compiled `_Node` IR ---------------------------------------
#
# IDENTITY-PRESERVING, in the style of `_sub_preserving`: a subtree with nothing to
# replace is returned as the SAME object, so a model this pass does not touch keeps
# byte-identical compiled trees (and `f!` stays instruction-for-instruction what it
# was). Memoized by object identity, so a `_Node` shared across cells by `_BuildMemo`
# is rewritten once.
function _share_rewrite(n::_Node, ctx::_ShareCtx, slot_of_vn::Dict{Int,Int},
                        memo::IdDict{_Node,_Node}, hits::Base.RefValue{Int})::_Node
    r = get(memo, n, nothing)
    r === nothing || return r
    r = _share_rewrite_uncached(n, ctx, slot_of_vn, memo, hits)
    memo[n] = r
    return r
end

function _share_rewrite_uncached(n::_Node, ctx::_ShareCtx, slot_of_vn::Dict{Int,Int},
                                 memo::IdDict{_Node,_Node}, hits::Base.RefValue{Int})::_Node
    if _share_replaceable(n)
        v = _node_vn(n, ctx)
        if v != _VN_NONE
            s = get(slot_of_vn, v, 0)
            if s != 0
                hits[] += 1
                return _mknode(kind=_NK_CACHED, idx=s, payload=ctx.cache)
            end
        end
    end
    return _share_rewrite_below(n, ctx, slot_of_vn, memo, hits)
end

# Rewrite only BELOW `n` — used for a new prelude def, whose root must not be replaced
# by a reference to itself. Deliberately does NOT write `memo[n]`: the same node object
# may later be rewritten in FULL (as a kernel payload, where the root replacement IS
# the point), and a memo entry from this partial rewrite would poison that.
function _share_rewrite_below(n::_Node, ctx::_ShareCtx, slot_of_vn::Dict{Int,Int},
                              memo::IdDict{_Node,_Node}, hits::Base.RefValue{Int})::_Node
    isempty(n.children) && return n
    changed = false
    kids = Vector{_Node}(undef, length(n.children))
    for i in eachindex(n.children)
        c = _share_rewrite(n.children[i], ctx, slot_of_vn, memo, hits)
        changed |= c !== n.children[i]
        kids[i] = c
    end
    changed || return n
    return _Node(n.kind, n.op, n.literal, n.idx, n.sym, n.payload, kids)
end

# ---- Rewriting a `_VecNode` template -----------------------------------------
#
# `_VecNode` is IMMUTABLE, so swapping an invariant's payload means rebuilding the
# spine down to it. Every rebuilt node REUSES the original's `buf`, `altbuf`, `vals`,
# `slots`, `fnargs` and `cvbufs` rather than calling `_mkvnode`, which would mint fresh
# ones: `f!`'s zero-allocation property rests on those being build-time objects captured
# in the closure, and a second set of them would be pure waste (the discarded node's
# `buf` is the right size, and is not aliased by anything else — the template is a tree).
# Untouched subtrees are returned as the SAME object, so a template with no shared
# invariant is not rebuilt at all.
#
# Memoized by identity so that IF a template is ever a DAG (today both builders —
# `_merge_nodes` and stencil.jl's `_lower_template` — emit a fresh `_mkvnode` per node,
# so it is a tree; this is checked, not assumed) a shared `_VecNode` is rebuilt ONCE and
# the sharing is preserved, rather than duplicated along with its buffers.
function _share_rewrite_vec(n::_VecNode, ctx::_ShareCtx, slot_of_vn::Dict{Int,Int},
                            nmemo::IdDict{_Node,_Node}, vmemo::IdDict{_VecNode,_VecNode},
                            nhits::Base.RefValue{Int}, khits::Base.RefValue{Int})::_VecNode
    r = get(vmemo, n, nothing)
    r === nothing || return r
    r = _share_rewrite_vec_uncached(n, ctx, slot_of_vn, nmemo, vmemo, nhits, khits)
    vmemo[n] = r
    return r
end

function _share_rewrite_vec_uncached(n::_VecNode, ctx::_ShareCtx, slot_of_vn::Dict{Int,Int},
                                     nmemo::IdDict{_Node,_Node}, vmemo::IdDict{_VecNode,_VecNode},
                                     nhits::Base.RefValue{Int},
                                     khits::Base.RefValue{Int})::_VecNode
    if n.kind === _VK_INVARIANT
        p = n.payload::_Node
        np = _share_rewrite(p, ctx, slot_of_vn, nmemo, nhits)
        np === p && return n
        # A payload collapsed all the way to a cache read is the headline win: the
        # kernel now does one field load + the `fill!` it already did, instead of
        # walking the subtree. (A payload whose INTERIOR merely picked up a cache read
        # is a smaller win and is not counted here.)
        np.kind === _NK_CACHED && (khits[] += 1)
        return _VecNode(n.kind, n.op, n.literal, n.idx, n.sym, np, n.vals, n.slots,
                        n.children, n.buf, n.altbuf, n.fnargs, n.cvbufs)
    end
    isempty(n.children) && return n
    changed = false
    kids = Vector{_VecNode}(undef, length(n.children))
    for i in eachindex(n.children)
        c = _share_rewrite_vec(n.children[i], ctx, slot_of_vn, nmemo, vmemo, nhits, khits)
        changed |= c !== n.children[i]
        kids[i] = c
    end
    changed || return n
    return _VecNode(n.kind, n.op, n.literal, n.idx, n.sym, n.payload, n.vals, n.slots,
                    kids, n.buf, n.altbuf, n.fnargs, n.cvbufs)
end

function _foreach_vecnode(f, n::_VecNode)
    f(n)
    for c in n.children
        _foreach_vecnode(f, c)
    end
    return nothing
end

# ---- The pass ----------------------------------------------------------------
#
# Mutates `rhs_list`, `prelude`, `cache` and `vec_kernels` IN PLACE (all four are the
# containers the `f!` / `f` closure will capture) and returns the diagnostic counters.
# A model with no array kernels returns immediately, leaving everything byte-identical.
function _share_lane_invariants!(rhs_list::Vector{Tuple{Int,_Node}},
                                 prelude::Vector{_Node},
                                 cache::_CSECache,
                                 vec_kernels::Vector{_VecKernel})
    none = (; n_invariant_slots = 0, n_invariant_shared = 0, n_invariant_scalar_shared = 0)
    isempty(vec_kernels) && return none

    n_orig = length(prelude)
    ctx = _ShareCtx(cache, n_orig)

    # ---- 1. Number the existing prelude defs, in SLOT order ----
    # Slot order is topological, so every `_NK_CACHED(j)` inside `prelude[s]` has
    # `j < s` and its expansion is already resolved.
    slot_of_vn = Dict{Int,Int}()
    for s in 1:n_orig
        v = _node_vn(prelude[s], ctx)
        ctx.slot_vn[s] = v
        v == _VN_NONE && continue
        get!(slot_of_vn, v, s)
    end

    # ---- 2. Number every `_VK_INVARIANT` payload in every kernel, and count ----
    counts = Dict{Int,Int}()
    reps = Dict{Int,_Node}()          # first-seen payload for each value number
    order = Int[]                     # first-seen order, for determinism
    for vk in vec_kernels
        _foreach_vecnode(vk.template) do vn_node
            vn_node.kind === _VK_INVARIANT || return nothing
            p = vn_node.payload::_Node
            v = _node_vn(p, ctx)
            v == _VN_NONE && return nothing
            c = get(counts, v, 0)
            counts[v] = c + 1
            if c == 0
                reps[v] = p
                push!(order, v)
            end
            return nothing
        end
    end

    # ---- 3. Give a NEW slot to each value number that is shared but not yet named ----
    # "Shared" = it occurs in ≥ 2 invariant payloads. A value number that ALREADY has a
    # prelude slot needs no new one — its payloads simply rewrite onto the existing slot,
    # which is finding (d): the kernel↔prelude direction.
    #
    # A payload UNIQUE to one kernel and matching nothing else is left alone: a slot for
    # it would cost a store + a load to save nothing (the `_VK_INVARIANT` node already
    # evaluates it exactly once per call).
    #
    # New slots are assigned in ASCENDING NODE COUNT. That is what keeps the prelude
    # topologically ordered without any cycle analysis: if payload B is a proper subtree
    # of payload A then B is strictly smaller, so B gets the lower slot, and A's def —
    # rewritten below against the slots that exist AT THAT MOMENT — can only ever
    # reference slots below its own. (Original slots are all lower than every new one, so
    # a new def referencing one of those is fine too.)
    seen_at = Dict{Int,Int}(v => i for (i, v) in enumerate(order))
    fresh = [v for v in order if counts[v] >= 2 && !haskey(slot_of_vn, v)]
    sort!(fresh, by = v -> (_count_nodes(reps[v]), seen_at[v]))
    for v in fresh
        s = length(prelude) + 1
        # A FRESH memo per def: the shared memo used in step 4 must not inherit entries
        # produced while only a PREFIX of the slot map existed.
        def = _share_rewrite_below(reps[v], ctx, slot_of_vn,
                                   IdDict{_Node,_Node}(), Ref(0))
        push!(prelude, def)
        push!(ctx.slot_vn, v)
        slot_of_vn[v] = s
    end
    n_new = length(prelude) - n_orig

    # ---- 4. Rewrite the kernels and the scalar equations against the final slot map ----
    # Two memos, not one, purely so the two counters stay honest: a `_Node` object
    # rewritten under the kernel memo would be returned from the memo — not re-counted —
    # if the scalar pass met it again.
    khits = Ref(0)   # invariant payloads collapsed to a bare cache read
    nhits = Ref(0)   # every `_Node` site rewritten inside a kernel (payload interiors too)
    vmemo = IdDict{_VecNode,_VecNode}()
    kmemo = IdDict{_Node,_Node}()
    for j in eachindex(vec_kernels)
        vk = vec_kernels[j]
        tmpl = _share_rewrite_vec(vk.template, ctx, slot_of_vn, kmemo,
                                  vmemo, nhits, khits)
        tmpl === vk.template && continue
        vec_kernels[j] = _VecKernel(vk.out_slots, tmpl, vk.len)
    end

    # The scalar equations get the same treatment — this is what makes the third
    # occurrence of the Arrhenius factor (the one in the scalar equation, which
    # `_cse_count!` saw as a singleton because the two array occurrences were invisible
    # to it) read the slot instead of re-walking the subtree. Safe under a lazy guard for
    # the reason given at the top of this file: the slot is filled on every call anyway,
    # because a kernel needs it.
    shits = Ref(0)
    smemo = IdDict{_Node,_Node}()
    for k in eachindex(rhs_list)
        slot, node = rhs_list[k]
        r = _share_rewrite(node, ctx, slot_of_vn, smemo, shits)
        r === node && continue
        rhs_list[k] = (slot, r)
    end

    # ---- 5. Size the scratch to the grown prelude ----
    # `cache` is the SAME `_CSECache` object every `_NK_CACHED` node captured (the ones
    # `_compile_cse` made and the ones this pass made), so the in-place resize is visible
    # to all of them. `alt` is still `nothing` at build time and is sized from `f64` on
    # its first use.
    n_new == 0 || resize!(cache.f64, length(prelude))

    return (; n_invariant_slots = n_new,
              n_invariant_shared = khits[],
              n_invariant_scalar_shared = shits[])
end
