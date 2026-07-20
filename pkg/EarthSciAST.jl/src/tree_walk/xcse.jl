# ========================================================================
# tree_walk/xcse.jl — part of the tree-walk evaluator.
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 4e: CROSS-KERNEL and KERNEL↔PRELUDE sharing of
# lane-invariant fn/interp subtrees via shared scalar prelude slots
# (perf-gap-closure plan item B4).
# ========================================================================
#
# THE GAP THIS CLOSES
# -------------------
# Two independent mechanisms name a repeated LANE-INVARIANT computation, and
# they have nothing to say to each other:
#
#   * `_cse_compile_scalar` (compile.jl) shares subexpressions across SCALAR
#     equations and observed defs, keyed on `canonical_json`, into a prelude of
#     `_CSECache` slots refilled at the top of every `f!` call.
#   * `_build_acc_cse` (access_kernel.jl) hoists every loop-invariant OP subtree
#     of ONE array kernel into that kernel's `inv_recipes` tier — one scalar
#     eval per RHS call instead of one per cell, but PER KERNEL, shared with
#     nothing.
#
# So a FastJX-style photolysis rate `interp.linear(tbl, ax, cos_zenith(t))`
# feeding the balances of K species — K array kernels — is evaluated K times per
# RHS call (once per kernel's `_fill_invariant!`), and a K+1'th time if a scalar
# equation or observed carries the same expression (which `_cse_count!` sees as
# a singleton, because array equations never produce the `ASTExpr` entries it
# counts). This pass makes each such subtree ONE shared scalar prelude slot:
#
#   1. every existing scalar prelude def is EXACTLY value-numbered (slot order,
#      so `_NK_CACHED` refs expand through already-numbered slots);
#   2. every kernel's `inv_recipes` defs (top-level kernels + their transitive
#      template-body `subs`) are value-numbered in the same table, with
#      `_NK_ACCESS` leaves NORMALIZED to their scalar-node equivalents
#      (`_AK_STATE_FIXED` ≡ `_NK_STATE`, `_AK_ARR_FIXED` ≡ `_NK_PARAM_GATHER`,
#      `_AK_SCALAR` ≡ `_NK_LITERAL`) so a kernel-side `u[5]` matches a
#      prelude-side `u[5]`;
#   3. a value number seen by ≥ 2 kernel defs whose body is at least as
#      expensive as an fn/interp call (the `_xcse_expensive` gate — a `:fn`
#      node or a transcendental; never bare arithmetic) gets ONE new prelude
#      slot, built by TRANSLATING the first-seen kernel def into scalar `_Node`
#      form (its inv-slot refs become shared-slot refs, hoisted as
#      dependencies); a value number that already matches an existing prelude
#      slot needs no new slot at all;
#   4. every kernel def whose value number has a shared slot is REPLACED by a
#      bare `_NK_CACHED` read of that slot — `_fill_invariant!` then copies one
#      field load into the kernel's inv scratch instead of re-walking the
#      subtree, and the kernel's spine / cell recipes / lane-tape plan are
#      byte-identical to before (they keep reading the kernel-local inv slot);
#   5. scalar `rhs_list` occurrences of a NEWLY slotted value are rewritten to
#      cache reads too (the kernel↔scalar direction the scalar count pass
#      cannot see).
#
# ORDERING. `_make_rhs` fills the scalar prelude (const tier + dynamic tier)
# BEFORE any equation or kernel runs, and new defs are appended AFTER the defs
# they reference (a dependency is a lower inv slot of the same kernel, so it is
# processed — and slotted — first), so every read lands on a filled slot. The
# `_classify_const_slots` cadence split runs AFTER this pass, so a hoisted
# parameter-only def still joins the const tier.
#
# WHY THE HOIST IS SAFE (the guard question, answered once). The scalar CSE
# pass may only hoist a key with an unconditional occurrence, because the
# prelude is unconditional while `_eval_node_op` is lazy for `ifelse`/`and`/
# `or`. This pass needs no such rule, structurally: every candidate def is an
# `inv_recipes` entry, and `_fill_invariant!` evaluates EVERY inv slot on EVERY
# call, unconditionally, before the cell loop. Promoting such a def to the
# prelude introduces no evaluation that was not already happening — no new
# throw, no new NaN. That also makes the scalar-side rewrite of a GUARDED
# occurrence safe: the slot is filled every call anyway, because a kernel needs
# it; the rewrite removes work, it never adds any. (Kernels whose spine carries
# a lazy guard have no CSE tiers at all — `_acc_from_cell_entries` skips
# `_build_acc_cse` there — so nothing under a kernel-side guard ever becomes a
# candidate.)
#
# BIT-EXACTNESS. A shared slot's value is produced by the SAME arithmetic the
# per-kernel defs performed — the value number is exact over every field that
# can affect the result (literal BITS, state slot, param symbol, forcing-buffer
# IDENTITY + offset, fn name + spec CONTENT by raw bits, op + child value
# numbers in order) — evaluated once instead of K times. That is bitwise
# identical for pure deterministic operations, which every candidate is: the
# closed-function registry (esm-spec §9.2 — `interp.*`, `datetime.*`) is a
# CLOSED set of pure, deterministic, total functions of their arguments (no
# clock, no RNG, no I/O; registered_functions.jl), and every other spine op is
# IEEE float arithmetic. If an impure closed function is ever admitted to the
# registry, its name must be excluded from `_xfn_content_key` (fail-closed:
# return `nothing` there and the node — and every ancestor — declines sharing).
#
# SCOPE / FORM. The pass runs for `form = :inplace` ONLY. The `:oop` emitter
# fills its OWN per-call prelude vector (`_make_rhs_oop`), never the
# `_CSECache` this pass's kernel-side reads would consult, so rewritten kernels
# would read unfilled slots there. (`:oop` kernels are left byte-identical;
# sharing for the oop/traced tier is future work.)
#
# KILL SWITCH: ESS_XCSE_DISABLE=1 skips the pass entirely; the build is then
# byte-identical to the pre-B4 engine. Fixture-level differential oracles
# (test/tree_walk_xcse_test.jl) compare ON vs OFF bit for bit.

_xcse_disabled() = get(ENV, "ESS_XCSE_DISABLE", "") == "1"

# ---- The cost gate (plan B4 criterion (c)) ------------------------------------
# A NEW shared slot is only minted for a def at least as expensive as an
# fn/interp call: a closed-function call itself, or a transcendental /
# power-class op. Bare arithmetic (`+`, `*`, `-`, `/`, comparisons, min/max) is
# never worth a store + K loads on its own. Two deliberate asymmetries:
#   * DEPENDENCIES of a hoisted def are hoisted regardless of their own cost
#     (the def's translated body must read them from somewhere, and they are
#     shared by construction — a shared parent implies shared children);
#   * a kernel def matching an EXISTING scalar prelude slot is rewritten onto
#     it regardless of cost — the slot is already paid for.
const _XCSE_EXPENSIVE_OPS = Set{Symbol}([
    :fn,
    :exp, :expm1, :log, :log2, :log10, :log1p,
    :sin, :cos, :tan, :asin, :acos, :atan, :atan2,
    :sinh, :cosh, :tanh, :asinh, :acosh, :atanh,
    :sqrt, :cbrt, :^, :pow,
])

# ---- Exact value numbering ----------------------------------------------------
#
# THIS IS THE ONE THING THAT MUST NOT BE APPROXIMATE. Two nodes get the same
# value number iff they are guaranteed to compute the same value; a key that
# merged two nodes computing DIFFERENT values would not crash, it would
# silently produce wrong numbers. Anything the key does not model FAILS CLOSED
# (`_XVN_NONE`), poisoning every ancestor — sharing is a pure optimization, so
# declining costs a re-walk while guessing costs correctness.
#
# NOTE — this is emphatically NOT `_struct_sig!` (acc_merge.jl). That signature
# DELIBERATELY ignores leaf values so cells differing only in them merge into
# one vectorized template; keying sharing on it would merge nodes that compute
# different values. Nor is it `_acc_vn_key` (access_kernel.jl), which keys `fn`
# payloads by object identity — sound within one kernel, useless across kernels
# where each compile mints a fresh spec object for the same table.

const _XVN_NONE = 0    # "unkeyable" — never a real value number (those start at 1)

# One node's key: (normalized kind, op, literal bits, idx, sym, payload id,
# child value numbers). A `Tuple` hashes and compares elementwise and the
# `Vector{Int}` slot compares by value, so this is a sound Dict key with no
# custom hash/== to get wrong. Child nodes are represented by their VALUE
# NUMBERS, not their own key bytes — that indirection keeps the pass linear
# (an `_NK_CACHED` expansion is one table lookup, not a re-emission of the
# fully written-out def).
const _XVNKey = Tuple{UInt8,Symbol,UInt64,Int,Symbol,Int,Vector{Int}}

# The global (per-build) interning state shared by every numbering context.
mutable struct _XShareCtx
    cache::_CSECache                # the scalar prelude scratch every shared read lands on
    vn::Dict{_XVNKey,Int}           # structural key → value number (the hash-cons table)
    ident_ids::IdDict{Any,Int}      # payloads keyed by IDENTITY (forcing buffers)
    content_ids::Dict{Any,Int}      # payloads keyed by CONTENT (`fn` name + spec bits)
    expensive::Vector{Bool}         # per-vn: body contains an `_XCSE_EXPENSIVE_OPS` op
    next_pay::Int
end
_XShareCtx(cache::_CSECache) =
    _XShareCtx(cache, Dict{_XVNKey,Int}(), IdDict{Any,Int}(), Dict{Any,Int}(),
               Bool[], 0)

function _xpay_ident!(ctx::_XShareCtx, obj)::Int
    id = get(ctx.ident_ids, obj, 0)
    id == 0 || return id
    ctx.next_pay += 1
    ctx.ident_ids[obj] = ctx.next_pay
    return ctx.next_pay
end

function _xpay_content!(ctx::_XShareCtx, key)::Int
    id = get(ctx.content_ids, key, 0)
    id == 0 || return id
    ctx.next_pay += 1
    ctx.content_ids[key] = ctx.next_pay
    return ctx.next_pay
end

# The raw bits of a Float64 vector — a bit-exact, `isequal`-flavoured stand-in
# that distinguishes `0.0` from `-0.0` and makes two identical NaNs compare
# equal. Tables are §9.2-capped at ≤1024 entries and this runs once per distinct
# spec at BUILD time.
_xf64_bits(v::AbstractVector{Float64}) = UInt64[reinterpret(UInt64, x) for x in v]

# The CONTENT key of an `:fn` node's `(fname, spec)` payload, or `nothing` if
# the payload is not one this pass understands (fail closed). Content — every
# table/axis element by raw bits — and not the spec object's identity, because
# `_build_interp_spec` mints a fresh spec per compile, so two `interp.linear`
# calls over the SAME table in two kernels hold two different objects and must
# still share; and not the name alone, because two calls over DIFFERENT tables
# must never share. Every function admitted here is pure and deterministic
# (see the BIT-EXACTNESS header note).
function _xfn_content_key(payload)
    payload isa Tuple{String,Any} || return nothing
    fname, spec = payload
    if spec === nothing
        return (fname, :none)                      # boxed all-scalar path (`datetime.*`)
    elseif spec isa _InterpLinearSpec
        return (fname, :linear, _xf64_bits(spec.table), _xf64_bits(spec.axis))
    elseif spec isa _InterpBilinearSpec
        return (fname, :bilinear, [_xf64_bits(r) for r in spec.table],
                _xf64_bits(spec.axis_x), _xf64_bits(spec.axis_y))
    elseif spec isa _InterpSearchsortedSpec
        return (fname, :searchsorted, _xf64_bits(spec.xs))
    end
    return nothing
end

# One numbering context: the container whose defs are being numbered. For a
# KERNEL it carries the kernel's descriptor table (so `_NK_ACCESS` leaves can be
# normalized) and its inv-slot→vn table (filled front to back as the recipes
# are numbered, so a ref to a lower slot expands through it). For the SCALAR
# side `acc === nothing` and only `slot_vn` (the shared prelude slot→vn table)
# is consulted. `inv_scratch` is the identity the kernel's own `_NK_CACHED`
# refs are matched against (`_XS_NO_SCRATCH` on the scalar side, which matches
# nothing).
const _XS_NO_SCRATCH = _AccScratch(0)
struct _XNodeCtx
    acc::Union{Nothing,Vector{_AccDesc}}
    inv_scratch::_AccScratch
    inv_vn::Vector{Int}             # this kernel's inv slot → vn (grows front to back)
    slot_vn::Vector{Int}            # scalar prelude slot → vn (one shared vector)
    memo::IdDict{_Node,Int}         # node object → vn (identity-memoized per context)
end
_xkernel_ctx(K::_AccKernel, slot_vn::Vector{Int}) =
    _XNodeCtx(K.acc, K.cse.inv_scratch, Int[], slot_vn, IdDict{_Node,Int}())
_xscalar_ctx(slot_vn::Vector{Int}) =
    _XNodeCtx(nothing, _XS_NO_SCRATCH, Int[], slot_vn, IdDict{_Node,Int}())

function _xnode_vn(n::_Node, nctx::_XNodeCtx, ctx::_XShareCtx)::Int
    v = get(nctx.memo, n, -1)
    v == -1 || return v
    v = _xnode_vn_uncached(n, nctx, ctx)
    nctx.memo[n] = v
    return v
end

# Intern a normalized key, computing the cost-gate bit for a fresh vn from the
# node's own op plus its children's (an expanded `_NK_CACHED` child contributes
# its def's bit, so the gate sees through the slot indirection).
function _xintern!(ctx::_XShareCtx, key::_XVNKey, node_expensive::Bool)::Int
    got = get(ctx.vn, key, _XVN_NONE)
    got == _XVN_NONE || return got
    kids = key[7]
    exp = node_expensive
    if !exp
        for cv in kids
            if ctx.expensive[cv]
                exp = true
                break
            end
        end
    end
    push!(ctx.expensive, exp)
    v = length(ctx.expensive)
    ctx.vn[key] = v
    return v
end

function _xnode_vn_uncached(n::_Node, nctx::_XNodeCtx, ctx::_XShareCtx)::Int
    k = n.kind
    if k === _NK_CACHED
        # Expand through the slot: the ref's value number IS the value number of
        # the def it reads. A ref to a slot not numbered yet (not below us —
        # the prelude/inv tiers are topologically ordered, so this would mean
        # that invariant broke) or to a scratch this context does not own is
        # unkeyable.
        pl = n.payload
        if pl === ctx.cache
            (1 <= n.idx <= length(nctx.slot_vn)) || return _XVN_NONE
            return nctx.slot_vn[n.idx]
        elseif pl === nctx.inv_scratch
            (1 <= n.idx <= length(nctx.inv_vn)) || return _XVN_NONE
            return nctx.inv_vn[n.idx]
        end
        return _XVN_NONE
    elseif k === _NK_ACCESS
        # Normalize the three CELL-INVARIANT descriptor kinds to their scalar-
        # node equivalents so kernel-side and prelude-side leaves share keys.
        # (`_build_acc_cse` only admits these three into the inv tier —
        # `_acc_desc_invariant` — so anything else here is defensive.)
        nctx.acc === nothing && return _XVN_NONE
        (1 <= n.idx <= length(nctx.acc)) || return _XVN_NONE
        a = nctx.acc[n.idx]
        ak = a.kind
        if ak === _AK_STATE_FIXED
            return _xintern!(ctx, (_NK_STATE, Symbol(""), UInt64(0), a.idx,
                                   Symbol(""), 0, Int[]), false)
        elseif ak === _AK_ARR_FIXED
            pay = _xpay_ident!(ctx, a.arr)
            return _xintern!(ctx, (_NK_PARAM_GATHER, Symbol(""), UInt64(0), a.idx,
                                   Symbol(""), pay, Int[]), false)
        elseif ak === _AK_SCALAR
            return _xintern!(ctx, (_NK_LITERAL, Symbol(""), reinterpret(UInt64, a.v),
                                   0, Symbol(""), 0, Int[]), false)
        end
        return _XVN_NONE
    end
    pay = 0
    if k === _NK_PARAM_GATHER
        buf = n.payload
        buf isa Vector{Float64} || return _XVN_NONE
        pay = _xpay_ident!(ctx, buf)
    elseif k === _NK_OP && n.op === :fn
        ck = _xfn_content_key(n.payload)
        ck === nothing && return _XVN_NONE
        pay = _xpay_content!(ctx, ck)
    elseif k === _NK_LITERAL || k === _NK_STATE || k === _NK_PARAM || k === _NK_TIME ||
           k === _NK_OP || k === _NK_CONTRACTION
        # A payload on a kind that is not supposed to carry one means the IR
        # has drifted from what this key models: decline rather than key past it.
        n.payload === nothing || return _XVN_NONE
    else
        return _XVN_NONE    # _NK_REDUCE / _NK_SUBCALL / geometry / future kinds
    end
    kids = Vector{Int}(undef, length(n.children))
    for i in eachindex(n.children)
        cv = _xnode_vn(n.children[i], nctx, ctx)
        cv == _XVN_NONE && return _XVN_NONE
        kids[i] = cv
    end
    node_exp = (k === _NK_OP || k === _NK_CONTRACTION) && n.op in _XCSE_EXPENSIVE_OPS
    lit = k === _NK_LITERAL ? reinterpret(UInt64, n.literal) :
          k === _NK_CONTRACTION ? reinterpret(UInt64, n.literal) : UInt64(0)
    return _xintern!(ctx, (k, n.op, lit, n.idx, n.sym, pay, kids), node_exp)
end

# ---- Translation: a kernel inv def → a scalar prelude `_Node` -----------------
#
# Kernel-only leaves become their scalar equivalents (the SAME memory read, so
# the value is bit-identical): `_AK_STATE_FIXED` → `_NK_STATE`, `_AK_ARR_FIXED`
# → a live `_NK_PARAM_GATHER` over the aliased buffer, `_AK_SCALAR` →
# `_NK_LITERAL`. A ref to a lower inv slot becomes a ref to that def's SHARED
# slot (`slot_of_vn` — the dependency was slotted first; see the sweep).
# Returns `nothing` when anything is not translatable — the caller then simply
# declines to hoist this def (fail closed, never a build error).
function _xcse_translate(n::_Node, nctx::_XNodeCtx, ctx::_XShareCtx,
                         slot_of_vn::Dict{Int,Int})::Union{Nothing,_Node}
    k = n.kind
    if k === _NK_ACCESS
        nctx.acc === nothing && return nothing
        (1 <= n.idx <= length(nctx.acc)) || return nothing
        a = nctx.acc[n.idx]
        if a.kind === _AK_STATE_FIXED
            return _mknode(kind=_NK_STATE, idx=a.idx)
        elseif a.kind === _AK_ARR_FIXED
            return _mknode(kind=_NK_PARAM_GATHER, idx=a.idx, payload=a.arr)
        elseif a.kind === _AK_SCALAR
            return _mknode(kind=_NK_LITERAL, literal=a.v)
        end
        return nothing
    elseif k === _NK_CACHED
        pl = n.payload
        pl === ctx.cache && return n                      # already a shared-slot read
        if pl === nctx.inv_scratch
            (1 <= n.idx <= length(nctx.inv_vn)) || return nothing
            dv = nctx.inv_vn[n.idx]
            dv == _XVN_NONE && return nothing
            s = get(slot_of_vn, dv, 0)
            s == 0 && return nothing                      # dependency not slotted: decline
            return _mknode(kind=_NK_CACHED, idx=s, payload=ctx.cache)
        end
        return nothing
    elseif k === _NK_LITERAL || k === _NK_STATE || k === _NK_PARAM || k === _NK_TIME
        return n
    elseif k === _NK_PARAM_GATHER
        return n.payload isa Vector{Float64} ? n : nothing
    elseif k === _NK_OP || k === _NK_CONTRACTION
        kids = Vector{_Node}(undef, length(n.children))
        for i in eachindex(n.children)
            tc = _xcse_translate(n.children[i], nctx, ctx, slot_of_vn)
            tc === nothing && return nothing
            kids[i] = tc
        end
        return _Node(n.kind, n.op, n.literal, n.idx, n.sym, n.payload, kids)
    end
    return nothing
end

# Mark `v` (and, transitively, every inv-slot dependency of its representative
# def that has no existing prelude slot) as wanting a shared slot. Dependencies
# bypass the cost gate: a shared parent implies shared children (the value
# number is structural over child numbers), so they are always ≥2-shared, and
# the parent's translated body must read them from a slot.
function _xwant!(v::Int, wanted::Set{Int},
                 reps::Dict{Int,Tuple{_Node,_XNodeCtx}},
                 slot_of_vn::Dict{Int,Int}, ctx::_XShareCtx)
    v in wanted && return nothing
    haskey(reps, v) || return nothing     # no kernel rep (an existing-slot-only vn)
    push!(wanted, v)
    rep, rctx = reps[v]
    _xwant_deps!(rep, rctx, wanted, reps, slot_of_vn, ctx)
    return nothing
end

function _xwant_deps!(n::_Node, nctx::_XNodeCtx, wanted::Set{Int},
                      reps::Dict{Int,Tuple{_Node,_XNodeCtx}},
                      slot_of_vn::Dict{Int,Int}, ctx::_XShareCtx)
    if n.kind === _NK_CACHED && n.payload === nctx.inv_scratch
        (1 <= n.idx <= length(nctx.inv_vn)) || return nothing
        dv = nctx.inv_vn[n.idx]
        dv == _XVN_NONE && return nothing
        haskey(slot_of_vn, dv) && return nothing          # already named in the prelude
        _xwant!(dv, wanted, reps, slot_of_vn, ctx)
        return nothing
    end
    for c in n.children
        _xwant_deps!(c, nctx, wanted, reps, slot_of_vn, ctx)
    end
    return nothing
end

# ---- Scalar-side rewrite ------------------------------------------------------
#
# IDENTITY-PRESERVING, in the style of `_sub_preserving`: a subtree with nothing
# to replace is returned as the SAME object, so a model this pass does not touch
# keeps byte-identical compiled trees. Only NEWLY minted slots are rewrite
# targets: a scalar occurrence structurally equal to an ORIGINAL prelude def
# already reads that slot (same structure ⇒ same canonical key, and
# `_compile_cse` rewrote it), so rewriting against originals could only touch
# occurrences the scalar pass deliberately declined.
@inline _xshare_replaceable(n::_Node) =
    n.kind === _NK_OP || n.kind === _NK_CONTRACTION

function _xshare_rewrite(n::_Node, nctx::_XNodeCtx, ctx::_XShareCtx,
                         new_slot_of_vn::Dict{Int,Int},
                         memo::IdDict{_Node,_Node}, hits::Base.RefValue{Int})::_Node
    r = get(memo, n, nothing)
    r === nothing || return r
    r = _xshare_rewrite_uncached(n, nctx, ctx, new_slot_of_vn, memo, hits)
    memo[n] = r
    return r
end

function _xshare_rewrite_uncached(n::_Node, nctx::_XNodeCtx, ctx::_XShareCtx,
                                  new_slot_of_vn::Dict{Int,Int},
                                  memo::IdDict{_Node,_Node},
                                  hits::Base.RefValue{Int})::_Node
    if _xshare_replaceable(n)
        v = _xnode_vn(n, nctx, ctx)
        if v != _XVN_NONE
            s = get(new_slot_of_vn, v, 0)
            if s != 0
                hits[] += 1
                return _mknode(kind=_NK_CACHED, idx=s, payload=ctx.cache)
            end
        end
    end
    isempty(n.children) && return n
    changed = false
    kids = Vector{_Node}(undef, length(n.children))
    for i in eachindex(n.children)
        c = _xshare_rewrite(n.children[i], nctx, ctx, new_slot_of_vn, memo, hits)
        changed |= c !== n.children[i]
        kids[i] = c
    end
    changed || return n
    return _Node(n.kind, n.op, n.literal, n.idx, n.sym, n.payload, kids)
end

# ---- The pass -----------------------------------------------------------------
#
# Mutates `rhs_list`, `prelude`, `cache` and each kernel's `inv_recipes` vector
# IN PLACE (all containers the `f!` closure will capture; `_AccKernel` /
# `_AccCSE` are immutable but their `Vector` fields are not) and returns the
# diagnostic counters. A model with no array kernels — or none with an
# invariant tier — returns immediately, leaving everything byte-identical.
const _XCSE_NONE_DIAG = (; n_xcse_slots = 0, n_xcse_kernel_shared = 0,
                           n_xcse_scalar_shared = 0)

function _share_kernel_invariants!(rhs_list::Vector{Tuple{Int,_Node}},
                                   prelude::Vector{_Node},
                                   cache::_CSECache,
                                   acc_kernels::AbstractVector{_AccKernel})
    isempty(acc_kernels) && return _XCSE_NONE_DIAG

    # Deterministic kernel enumeration: top-level kernels in build order, each
    # followed by its transitive template-body subs, deduplicated by identity
    # (a sub shared by several parents is one def source, not several).
    kernels = _AccKernel[]
    seenk = IdDict{_AccKernel,Nothing}()
    function addk(K::_AccKernel)
        haskey(seenk, K) && return nothing
        seenk[K] = nothing
        push!(kernels, K)
        for S in K.subs
            addk(S)
        end
        return nothing
    end
    for K in acc_kernels
        addk(K)
    end
    any(K -> _has_inv(K.cse), kernels) || return _XCSE_NONE_DIAG

    ctx = _XShareCtx(cache)

    # ---- 1. Number the existing prelude defs, in slot order ----
    # Slot order is topological (`_compile_cse` assigns child slots first), so
    # every `_NK_CACHED` ref inside `prelude[s]` reads a slot < s whose vn is
    # already recorded. First slot with a given vn wins `slot_of_vn` (aliased
    # observed slots can legitimately repeat a vn).
    slot_vn = Int[]
    sctx = _xscalar_ctx(slot_vn)
    slot_of_vn = Dict{Int,Int}()
    for s in eachindex(prelude)
        v = _xnode_vn(prelude[s], sctx, ctx)
        push!(slot_vn, v)
        v == _XVN_NONE && continue
        get!(slot_of_vn, v, s)
    end

    # ---- 2. Number every kernel's inv defs, tally sharing ----
    kctxs = _XNodeCtx[]
    counts = Dict{Int,Int}()
    reps = Dict{Int,Tuple{_Node,_XNodeCtx}}()
    for K in kernels
        kctx = _xkernel_ctx(K, slot_vn)
        push!(kctxs, kctx)
        for r in K.cse.inv_recipes
            v = _xnode_vn(r, kctx, ctx)
            push!(kctx.inv_vn, v)
            v == _XVN_NONE && continue
            counts[v] = get(counts, v, 0) + 1
            haskey(reps, v) || (reps[v] = (r, kctx))
        end
    end
    isempty(counts) && return _XCSE_NONE_DIAG

    # ---- 3. Decide which value numbers deserve a NEW shared slot ----
    # ≥2 kernel defs + the cost gate; dependencies ride along via `_xwant!`.
    # (A vn that already has a prelude slot needs no new one — its kernel defs
    # simply rewrite onto the existing slot in step 4.)
    wanted = Set{Int}()
    for (v, c) in counts
        if c >= 2 && !haskey(slot_of_vn, v) && ctx.expensive[v]
            _xwant!(v, wanted, reps, slot_of_vn, ctx)
        end
    end

    # ---- 4. Sweep: mint slots (first-seen order = rep order, so dependencies
    # — lower slots of the rep's own kernel — are minted before their parents)
    # and rewrite every matching kernel def to a bare shared-slot read. ----
    n_orig = length(prelude)
    kernel_hits = 0
    for (ki, K) in enumerate(kernels)
        kctx = kctxs[ki]
        recs = K.cse.inv_recipes
        for s in eachindex(recs)
            v = kctx.inv_vn[s]
            v == _XVN_NONE && continue
            slot = get(slot_of_vn, v, 0)
            if slot == 0 && v in wanted
                rep, rctx = reps[v]
                def = _xcse_translate(rep, rctx, ctx, slot_of_vn)
                if def === nothing
                    delete!(wanted, v)   # untranslatable: decline for good
                    continue
                end
                push!(prelude, def)
                slot = length(prelude)
                slot_of_vn[v] = slot
                push!(slot_vn, v)
            end
            if slot != 0
                recs[s] = _mknode(kind=_NK_CACHED, idx=slot, payload=cache)
                kernel_hits += 1
            end
        end
    end
    n_new = length(prelude) - n_orig
    if n_new == 0 && kernel_hits == 0
        return _XCSE_NONE_DIAG
    end

    # ---- 5. Rewrite scalar equations against the NEW slots ----
    # The kernel↔scalar direction: a scalar occurrence the batched count pass
    # saw as a singleton (its siblings live in kernels) now reads the shared
    # slot. Safe even under a lazy guard — the slot is filled every call anyway
    # because a kernel needs it (see the header).
    scalar_hits = Ref(0)
    if n_new > 0
        new_slot_of_vn = Dict{Int,Int}(v => s for (v, s) in slot_of_vn if s > n_orig)
        memo = IdDict{_Node,_Node}()
        for k in eachindex(rhs_list)
            slot, node = rhs_list[k]
            r = _xshare_rewrite(node, sctx, ctx, new_slot_of_vn, memo, scalar_hits)
            r === node || (rhs_list[k] = (slot, r))
        end
    end

    # ---- 6. Size the scratch to the grown prelude ----
    # `cache` is the SAME `_CSECache` object every `_NK_CACHED` node captured
    # (scalar-side and kernel-side alike), so the in-place resize is visible to
    # all of them; `alt` is sized from `f64` on first non-Float64 use.
    n_new == 0 || resize!(cache.f64, length(prelude))

    return (; n_xcse_slots = n_new,
              n_xcse_kernel_shared = kernel_hits,
              n_xcse_scalar_shared = scalar_hits[])
end
