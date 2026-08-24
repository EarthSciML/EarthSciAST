# ========================================================================
# tree_walk/codegen_kernel.jl — the Julia CODEGEN tier for access kernels
# (perf-gap-closure plan, item B1).
#
# The scalar access-kernel runner (`_run_acc_kernel!`, access_kernel.jl) walks
# the spine `_Node` tree once per cell: one dynamic kind/op dispatch per node
# per cell per RHS call. This tier removes that interpretation entirely where
# it can: at `build_evaluator` time each `_AccKernel` is EMITTED as Julia
# source — the kernel's exact per-box loop nest with the spine as a
# straight-line expression using direct indexing (`u[oln + Δ]`, literal
# strides/offsets baked in) — and every emitted kernel is fused into ONE
# function compiled once via RuntimeGeneratedFunctions.jl.
#
# BIT-EXACTNESS IS THE CONTRACT. The emitter mirrors `_eval_acc` /
# `_eval_acc_op` (and through them `_eval_node_op`) operation for operation:
#   * same operand order and the same LEFT-nested fold for n-ary `+`/`*`/
#     `min`/`max` (`((c1 ⊕ c2) ⊕ c3)…`), the same 0̄-seeded fold for
#     `_NK_CONTRACTION`/`_NK_REDUCE` (`((0̄ ⊕ c1) ⊕ c2)…`);
#   * NO `@simd`, NO `@fastmath`, NO `muladd`, NO reassociation of any kind
#     (`@inbounds` only — indices were validated at build);
#   * LAZY guard semantics preserved verbatim: `ifelse` emits a ternary (only
#     the taken branch evaluates), `and`/`or` emit `&&`/`||` chains with the
#     interpreter's exact `== 0`/`!= 0` tests and `1.0`/`0.0` results;
#   * leaves keep their native types (a literal stays `Float64`, so `x ^ 2.0`
#     lands on `Dual^Float64` under AD exactly as the walker's leaf discipline
#     guarantees); CSE slot values convert to `T` exactly where the
#     interpreter's `buf[i] = …` store does;
#   * `fn` nodes call the SAME functions the interpreter calls
#     (`_interp_*_core` with the node's typed `_Interp*Spec` — or, for the
#     per-lane `_Interp*LaneSpec` tables the kernel-class merge mints, the
#     member spec selected by the interpreter's exact `_interp_lane` box
#     addressing — boxed `_eval_closed_fn` for `datetime.*`) — interpolation
#     is not reimplemented.
#
# ELTYPE-GENERIC: the emitted function derives `T = _rhs_value_type(u, p, t)`
# exactly as the interpreter does, so the SAME generated code integrates at
# Float64 and differentiates under ForwardDiff `Dual` (state or parameters).
#
# FALLBACK CONTRACT: anything the emitter cannot model — an unknown node kind
# or descriptor, a foreign CSE scratch (except the build's own shared
# scalar-prelude cache, which since ess-cgfsc is emitted as the interpreter's
# `_cse_read`; see the tier note below), a >3-D box, an oversized spine —
# declines THAT kernel silently (`_CodegenDecline`); the kernel keeps the
# per-cell interpreter (`_run_acc_kernel!`, eltype-generic). Declines are
# counted per reason in `_CASCADE_TALLY` (`:codegen_kernel` /
# `:codegen_decline_<reason>`), the `_tally_cascade!` pattern.
#
# GENERATED CODE NEVER TOUCHES INTERPRETER STATE: CSE/invariant slots become
# SSA-style locals, never writes into the kernel's `_AccScratch` buffers — so
# an emitted kernel and an interpreted one coexist within one RHS call.
#
# Kill switch: ESS_CODEGEN_DISABLE=1 disables BOTH generated functions
# (primary and overflow), so every kernel runs the per-cell interpreter — the
# differential-oracle escape hatch, mirroring ESS_STENCIL_DISABLE. (Since the
# lane-tape retirement this means interpreter-EVERYTHING: slower than it was
# when the tape still served Float64 residuals, but still bit-identical.)
# Debug: ESS_CODEGEN_DEBUG=1 prints per-build emission/decline/latency lines.
# Budget: ESS_CODEGEN_NODE_BUDGET overrides the emitted-node cap (default
# 400_000 across all kernels of one build) that bounds Julia compile latency.
# ========================================================================

_codegen_disabled() = get(ENV, "ESS_CODEGEN_DISABLE", "") == "1"
_codegen_debug() = get(ENV, "ESS_CODEGEN_DEBUG", "") == "1"
# CUMULATIVE emitted-node budget across all kernels in one build call — a
# build-latency backstop, NOT a per-function compile bound (the intra-kernel
# split, ess-iip-split, handles that: every generated function stays under
# `_codegen_fn_node_cap` regardless of a kernel's total size). Since a kernel
# that exceeds this used to DECLINE to the interpreter — which is forbidden
# (runtime speed is critical) — the default is high enough that realistic
# models always emit fully; it only backstops a runaway. The duo LMARS `:inplace`
# state RHS is ~1.5e6 nodes (13 spine-dominated momentum kernels, ~1.1e5–1.6e5
# each); the AST build of that is ~3 GB and cheap. Override with
# ESS_CODEGEN_NODE_BUDGET.
_codegen_node_budget() =
    something(tryparse(Int, get(ENV, "ESS_CODEGEN_NODE_BUDGET", "")), 64_000_000)

# Emitted-node size of a kernel: its spine, both CSE recipe tiers, and
# (recursively) every template sub-kernel it inlines. A sub-kernel shared by
# several parents is counted once per parent.
_cg_node_tree_size(n::_Node) = 1 + sum(_cg_node_tree_size, n.children; init=0)
function _cg_kernel_node_size(K::_AccKernel)
    s = _cg_node_tree_size(K.spine)
    for r in K.cse.recipes;     s += _cg_node_tree_size(r); end
    for r in K.cse.inv_recipes; s += _cg_node_tree_size(r); end
    for sub in K.subs;          s += _cg_kernel_node_size(sub); end
    return s
end

# ---- Dual overflow tier (ess-dualfp) ----------------------------------------
# Kernels the primary emission declines — in practice on the node BUDGET, which
# exists to bound Float64 build latency — used to drop to the per-cell
# interpreter `_run_acc_kernel!` under non-Float64 `T` (ForwardDiff `Dual` in a
# stiff-solver Jacobian). The dual overflow tier re-emits those residual
# kernels into a SECOND generated function with its own (default unbounded)
# budget. Under non-Float64 `T` it is called unconditionally, so its
# native-compile cost is paid at the first Dual call.
# (Since ess-f64ofl, below, the same function also serves Float64 calls when
# the Float64 overflow routing is armed; ESS_F64_OVERFLOW_CODEGEN=0 restores
# the interpreter-at-Float64 routing for the residual kernels.)
# Kill switch: ESS_DUAL_CODEGEN_DISABLE=1 restores the pre-dual routing exactly
# (the differential-oracle escape hatch, mirroring ESS_CODEGEN_DISABLE); the
# tier is also off whenever ESS_CODEGEN_DISABLE=1 disables codegen wholesale,
# so the existing oracle stays a pure interpreter build.
# Budget: ESS_DUAL_CODEGEN_NODE_BUDGET overrides the overflow emission budget
# (default unbounded — per-function size is still capped by
# ESS_CODEGEN_FN_NODE_CAP chunking, which is what bounds LLVM memory).
# Build tally: `:dual_codegen_kernel` / `:dual_codegen_decline_<reason>` in
# `_CASCADE_TALLY` — the observability hook for which tier Dual evaluation uses.
_dual_codegen_disabled() = get(ENV, "ESS_DUAL_CODEGEN_DISABLE", "") == "1"
_dual_codegen_node_budget() =
    something(tryparse(Int, get(ENV, "ESS_DUAL_CODEGEN_NODE_BUDGET", "")), typemax(Int))

# ---- Float64 overflow routing (ess-f64ofl) ----------------------------------
# The SAME overflow generated function, called at Float64 too — so a
# budget-declined kernel runs compiled code, like every other kernel. The
# overflow RGF is eltype-generic and its emission is already paid at build (a
# few ms); what this routing adds is the residual kernels' NATIVE compile at
# the first Float64 call — measured at ~0.13-0.15 s per 1000 emitted nodes
# (roughly linear, the per-function ESS_CODEGEN_FN_NODE_CAP chunking is what
# keeps it linear), the same latency a Dual caller already pays at its first
# call. With Polyester threading active, the overflow RGF runs CHUNKED on its
# own threaded cell axis (see "Threaded cell axis for the codegen tier" below)
# — measured on reseact.esm at 8 threads with the whole mechanism forced onto
# the overflow tier via budget 0: chemistry 2.44 ms/call chunked RGF vs 3.55 ms
# for the (since-retired) threaded Float64 lane tape.
#
# Kill switch ESS_F64_OVERFLOW_CODEGEN=0 routes every residual Float64 kernel
# to the per-cell interpreter instead — the differential oracle for this
# routing. (Historical note: before the lane-tape retirement this switch
# restored the tape-at-Float64 routing; the tape is gone, so the oracle is now
# the interpreter — slower, still bit-identical by the emitter's contract.)
# Kernels even the overflow emission declines (`dual_resid`) keep the
# interpreter at Float64, exactly as before.
# The routing is inert unless the PRIMARY emission declined something and the
# overflow function exists (`ESS_DUAL_CODEGEN_DISABLE=1` therefore also
# disables it, keeping that switch a full pre-overflow oracle). On every model
# within the primary budget — all repo fixtures — nothing changes at all.
# Build tally: `:f64_overflow_armed` when a section is built with the routing
# armed (overflow function present + feature on).
_f64_overflow_codegen_enabled() = get(ENV, "ESS_F64_OVERFLOW_CODEGEN", "1") != "0"

# ---- Shared-prelude (xcse) cache reads (ess-cgfsc) ---------------------------
# The cross-kernel fn-CSE pass (xcse.jl, plan B4) rewrites kernel invariant-tier
# defs into bare `_NK_CACHED` reads of the build's SCALAR prelude cache — a
# `_CSECache` payload that is no kernel's scratch. The emitter used to decline
# every such kernel (`:foreign_scratch`), dropping it to the interpreter.
# This tier emits the read instead, as the very call the interpreter makes
# (`_cse_read(cache, idx, T)` — eltype-generic, so the Float64 AND the Dual
# specialization of the generated code read the same buffer the interpreter
# would: `f64` at Float64, the lazily-allocated `alt::Vector{T}` otherwise).
#
# FILL-ORDERING SOUNDNESS. Acceptance is gated on IDENTITY with the one cache
# the build threads in (`shared_cache` below): `_make_rhs` fills every prelude
# tier (const/time/dynamic) into that exact cache — for the SAME value type `T`
# the kernel section is about to run at — before `kernel_section(du,u,p,t,T)`
# is called, in the same `f!` body (acc_merge.jl). Both generated functions
# (primary and dual/f64 overflow) are only ever invoked from inside that
# section, so every accepted read lands on a slot filled this call. Call sites
# that cannot pin that ordering (the materialized-observed fill sections in
# build.jl, hand-built test sections) pass `shared_cache = nothing` and keep
# today's decline — as does ANY payload that is not that one cache object.
#
# Kill switch: ESS_CG_FOREIGN_SCRATCH_DISABLE=1 restores the unconditional
# `:foreign_scratch` decline exactly (the differential oracle).
# Build tally: `:cg_foreign_scratch_emit` — one bump per kernel that COMPILED
# carrying at least one shared-prelude read (primary or overflow emission; a
# kernel that later declines for another reason is not counted).
_cg_foreign_scratch_disabled() =
    get(ENV, "ESS_CG_FOREIGN_SCRATCH_DISABLE", "") == "1"

# Per-kernel decline: the kernel keeps the per-cell interpreter runner.
# Never an error — the tier is a pure optimization.
struct _CodegenDecline <: EarthSciASTError
    reason::Symbol
end

# ---- Emission context (one per generated function) --------------------------
mutable struct _CGCtx
    # Runtime objects the generated code needs (const arrays, connectivity /
    # valence tables, interp specs, outs vectors), GROUPED BY CONCRETE TYPE into
    # homogeneous containers (ess-iip-tabgroup). The generated code indexes a
    # concrete-element container — `_cggrpG[pos]` — so its element type infers in
    # O(1); the runtime `tabs` argument is a small tuple of those containers, one
    # per distinct type. This replaces a per-object heterogeneous N-tuple whose
    # TYPE alone made inference super-linear: the duo LMARS momentum RHS registers
    # ~2.5e5 tabs, EVERY one a `Vector{Int}`; as `Tuple{Vector{Int},…×2.5e5}` it
    # drove the split helpers' compile to ~850 s, as one `Vector{Vector{Int}}` it
    # is cheap. `tab_types[g]` is group g's element type, `tab_objs[g]` its objects
    # (deduped by identity via `tabid` → (group, position)).
    tab_types::Vector{DataType}
    tab_objs::Vector{Vector{Any}}
    tabid::IdDict{Any,Tuple{Int,Int}}
    # Invariant-slot local names per kernel object (parent or sub), filled by
    # prologue statements in `_run_acc_kernel!`'s nested-first order. Values
    # are recomputed-identical across sharing parents, so one fill suffices.
    invdone::IdDict{Any,Vector{Symbol}}
    invlog::Vector{Any}          # registration order, for decline rollback
    prologue::Vector{Any}        # invariant-fill statements
    nodes::Int                   # emitted-node tally (budget enforcement)
    budget::Int
    nname::Int                   # unique-name counter
    # Shared-prelude cache reads (ess-cgfsc): the ONE `_CSECache` whose
    # `_NK_CACHED` reads may be emitted (`nothing` ⇒ decline as before), and a
    # per-build count of reads emitted (tally bookkeeping in the build loop).
    shared_cache::Union{Nothing,_CSECache}
    fscratch::Int
    # Intra-kernel split (ess-iip-split): top-level `@noinline` helper defs a
    # large kernel's body was partitioned into. Spliced ahead of the chunk
    # sub-functions so both call them by name; each captures nothing (params
    # only), so the RHS stays allocation-free.
    helpers::Vector{Any}
    # Helper dedup (ess-iip-helper-dedup): identical spilled bodies (same code —
    # the momentum spine bears LAZY nodes, so scalar CSE was skipped and its
    # redundant sub-expressions reach codegen un-shared) collapse to ONE compiled
    # `@noinline`, still called per occurrence. Body string → the helper name it
    # was first minted as. Reset per kernel so a declined kernel's rolled-back
    # helpers are never referenced (dedup scope is one kernel — where the
    # redundancy is; distinct kernels are distinct equations).
    helper_dedup::Dict{String,Symbol}
end
_CGCtx(budget::Int, shared_cache::Union{Nothing,_CSECache}=nothing) =
    _CGCtx(DataType[], Vector{Any}[], IdDict{Any,Tuple{Int,Int}}(),
           IdDict{Any,Vector{Symbol}}(),
           Any[], Any[], 0, budget, 0, shared_cache, 0, Any[], Dict{String,Symbol}())

_cg_helper_dedup_disabled() = get(ENV, "ESS_CG_HELPER_DEDUP_DISABLE", "") == "1"

_cg_name(ctx::_CGCtx, base::String) = Symbol("_cg", base, ctx.nname += 1)

# The local that holds group `g`'s homogeneous tab container (`_cggrpG`).
_cg_grp_sym(g::Int) = Symbol("_cggrp", g)

@inline function _cg_budget!(ctx::_CGCtx)
    ctx.nodes += 1
    ctx.nodes > ctx.budget && throw(_CodegenDecline(:budget))
    return nothing
end

# Register a runtime object; returns the indexing expression `_cggrpG[pos]` into
# its by-type container (ess-iip-tabgroup). Deduped by identity; a new object is
# appended to the container for its concrete type (a new group if that type is
# unseen). The returned `_cggrpG[pos]` reads a CONCRETE-element container, so its
# element type infers in O(1) — the whole point of grouping.
function _cg_tab!(ctx::_CGCtx, obj)
    got = get(ctx.tabid, obj, nothing)
    got !== nothing && return :($(_cg_grp_sym(got[1]))[$(got[2])])
    T = typeof(obj)
    g = findfirst(==(T), ctx.tab_types)
    if g === nothing
        push!(ctx.tab_types, T); push!(ctx.tab_objs, Any[])
        g = length(ctx.tab_types)
    end
    push!(ctx.tab_objs[g], obj)
    pos = length(ctx.tab_objs[g])
    ctx.tabid[obj] = (g, pos)
    return :($(_cg_grp_sym(g))[$pos])
end

# ---- Per-kernel-evaluation context ------------------------------------------
# The cell coordinates as EXPRESSIONS (a loop-variable Symbol or an Int
# literal), plus the CSE slot → local-name maps for the kernel currently being
# emitted. `cellsyms` is occurrence-scoped (a template sub-kernel inlined at
# two call sites gets two disjoint sets of locals, mirroring the interpreter's
# per-occurrence scratch refill); `invsyms` is kernel-scoped (filled once per
# call by the prologue, as `_fill_invariant!` does).
struct _CGKernCtx
    K::_AccKernel
    c::Any        # cell ordinal
    n::Any        # neighbour index (0 outside a reduction)
    oln::Any      # output linear slot
    mi1::Any      # loop multi-index, padded with literal 1s
    mi2::Any
    mi3::Any
    cellsyms::Vector{Symbol}
    invsyms::Vector{Symbol}
end

_cg_mi(kc::_CGKernCtx, d::Int) = d == 1 ? kc.mi1 : d == 2 ? kc.mi2 : kc.mi3

# Integer index expression `off + Σ_d (mi_d - 1)·s_d`, folding literal-1 mi
# and zero strides (exact Int arithmetic — folding cannot change the index).
function _cg_boxaddr(kc::_CGKernCtx, s1::Int, s2::Int, s3::Int, off::Int)
    e = nothing
    for (mi, s) in ((kc.mi1, s1), (kc.mi2, s2), (kc.mi3, s3))
        s == 0 && continue
        mi === 1 && continue                      # (1-1)*s == 0
        term = :(($mi - 1) * $s)
        e = e === nothing ? term : :($e + $term)
    end
    return e === nothing ? off : :($off + $e)
end

_cg_offset(base, delta::Int) = delta == 0 ? base : :($base + $delta)

# ---- One access descriptor → one indexing expression (mirrors `_fetch`) -----
function _cg_fetch(ctx::_CGCtx, kc::_CGKernCtx, a::_AccDesc)
    k = a.kind
    if k === _AK_STATE_AFFINE
        return :(u[$(_cg_offset(kc.oln, a.delta))])
    elseif k === _AK_CONST_AFFINE
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_offset(kc.oln, a.delta))])
    elseif k === _AK_CONST_BOX || k === _AK_FORCING_BOX
        # FORCING_BOX's arr is the aliased LIVE buffer — passing the reference
        # through `tabs` keeps every in-place refresh visible.
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_boxaddr(kc, a.s1, a.s2, a.s3, a.off))])
    elseif k === _AK_STATE_FIXED
        return :(u[$(a.idx)])
    elseif k === _AK_LOOP_IDX
        return :(Float64($(_cg_mi(kc, a.dim))))
    elseif k === _AK_SCALAR
        return a.v
    elseif k === _AK_CONST_CELL
        return :($(_cg_tab!(ctx, a.arr))[$(kc.c)])
    elseif k === _AK_CONST_EDGE
        return :($(_cg_tab!(ctx, a.arr))[($(kc.c) - 1) * $(a.width) + $(kc.n)])
    elseif k === _AK_ARR_FIXED
        return :($(_cg_tab!(ctx, a.arr))[$(a.idx)])
    elseif k === _AK_STATE_INDIRECT
        return :(u[$(_cg_tab!(ctx, a.conn))[($(kc.c) - 1) * $(a.width) + $(kc.n)]])
    elseif k === _AK_STATE_INDIRECT_COL
        return :(u[$(_cg_tab!(ctx, a.conn))[($(kc.c) - 1) * $(a.width) + $(a.col)]])
    elseif k === _AK_STATE_TBL_BOX
        s = _cg_name(ctx, "s")
        addr = _cg_boxaddr(kc, a.s1, a.s2, a.s3, a.off)
        # Exactly `_fetch`'s ghost test: slot 0 ⇒ the ghost literal 0.0.
        return :(let $s = $(_cg_tab!(ctx, a.conn))[$addr]
                     $s == 0 ? 0.0 : u[$s]
                 end)
    elseif k === _AK_ARR_TBL_BOX
        addr = _cg_boxaddr(kc, a.s1, a.s2, a.s3, a.off)
        return :($(_cg_tab!(ctx, a.arr))[$(_cg_tab!(ctx, a.conn))[$addr]])
    end
    throw(_CodegenDecline(:unsupported_desc))
end

# ---- Op-symbol tables (the same registry rows the four eval ladders use) ----
const _CG_UNARY_FN = Dict{Symbol,Symbol}(row.sym => row.sym for row in _UNARY_ELEMENTWISE_OPS)
const _CG_BINARY_FN = Dict{Symbol,Symbol}(row.sym => row.fnsym for row in _BINARY_ELEMENTWISE_OPS)
const _CG_CMP_FN = Dict{Symbol,Symbol}(row.sym => row.fnsym for row in _COMPARISON_ELEMENTWISE_OPS)
const _CG_MINMAX_FN = Dict{Symbol,Symbol}(row.sym => row.fnsym for row in _NARY_MINMAX_OPS)

# Left-nested binary fold `((e1 op e2) op e3)…` — the interpreters' exact
# `acc = ev(c1); acc = op(acc, ev(ci))` association.
function _cg_foldl(fnsym::Symbol, exprs::Vector{Any})
    acc = exprs[1]
    for i in 2:length(exprs)
        acc = Expr(:call, fnsym, acc, exprs[i])
    end
    return acc
end

# Short-circuit chain `e1 && (e2 && …)` (head `:&&`/`:||`, NOT a call).
# Right-nested exactly as the parser associates; evaluation is left-to-right
# with the interpreter's short-circuit set either way.
function _cg_chain(head::Symbol, exprs::Vector{Any})
    acc = exprs[end]
    for i in (length(exprs) - 1):-1:1
        acc = Expr(head, exprs[i], acc)
    end
    return acc
end

# ---- Spine node → expression (mirrors `_eval_acc`) --------------------------
function _cg_emit(ctx::_CGCtx, kc::_CGKernCtx, nd::_Node)
    _cg_budget!(ctx)
    k = nd.kind
    if k === _NK_ACCESS
        return _cg_fetch(ctx, kc, kc.K.acc[nd.idx])
    elseif k === _NK_LITERAL
        return nd.literal
    elseif k === _NK_PARAM
        return :(_read_param(p, $(QuoteNode(nd.sym)), $(nd.idx)))
    elseif k === _NK_TIME
        return :t
    elseif k === _NK_CACHED
        pl = nd.payload
        cse = kc.K.cse
        if pl === cse.scratch && nd.idx <= length(kc.cellsyms)
            return kc.cellsyms[nd.idx]
        elseif pl === cse.inv_scratch && nd.idx <= length(kc.invsyms)
            return kc.invsyms[nd.idx]
        elseif pl === ctx.shared_cache && pl isa _CSECache &&
               !_cg_foreign_scratch_disabled()
            # Shared scalar-prelude slot (xcse.jl rewrite; ess-cgfsc). Emit the
            # interpreter's exact read — `_cse_read` selects `f64` at Float64
            # and the `alt::Vector{T}` buffer under any other `T`, both filled
            # by `_make_rhs`'s prelude tiers (at this same `T`) before the
            # kernel section runs; see the fill-ordering note at the tier docs
            # above. The enclosing recipe's `convert(_cgT, …)` store matches
            # `_fill_invariant!`'s `buf[i] = …` conversion exactly.
            ctx.fscratch += 1
            return :(_cse_read($(_cg_tab!(ctx, pl)), $(nd.idx), _cgT))
        end
        throw(_CodegenDecline(:foreign_scratch))
    elseif k === _NK_REDUCE
        # `s = K.zerobar; for m in 1:cnt; s += ev(body @ n=m); end` — the
        # `_eval_acc` REDUCE arm verbatim (the ⊕ is always `+`, seeded from
        # the kernel's 0̄).
        b = kc.K.bound
        cnt = b isa _FixedBound ? b.k :
              b isa _VarBound ? :($(_cg_tab!(ctx, b.valence))[$(kc.c)]) :
              throw(_CodegenDecline(:unsupported_bound))
        s = _cg_name(ctx, "r")
        m = _cg_name(ctx, "m")
        inner = _CGKernCtx(kc.K, kc.c, m, kc.oln, kc.mi1, kc.mi2, kc.mi3,
                           kc.cellsyms, kc.invsyms)
        body = _cg_emit(ctx, inner, nd.children[1])
        return quote
            local $s = $(kc.K.zerobar)
            for $m in 1:$cnt
                $s += $body
            end
            $s
        end
    elseif k === _NK_CONTRACTION
        # Seeded sequential ⊕-fold in child order — `_eval_acc_contraction`
        # arm for arm (`max`/`min` fold through the function, `+`/`*` through
        # the operator; both are the same left-nested application).
        ch = nd.children
        isempty(ch) && return nd.literal
        exprs = Any[nd.literal]
        for c in ch
            push!(exprs, _cg_emit(ctx, kc, c))
        end
        op = nd.op
        fnsym = op === :+ ? :+ : op === :* ? :* :
                op === :max ? :max : op === :min ? :min :
                throw(_CodegenDecline(:unsupported_op))
        return _cg_foldl(fnsym, exprs)
    elseif k === _NK_SUBCALL
        return _cg_emit_subcall(ctx, kc, nd.payload::_AccKernel)
    elseif k === _NK_OP
        return _cg_emit_op(ctx, kc, nd)
    end
    throw(_CodegenDecline(:unknown_kind))
end

# Emit a kernel's per-cell CSE recipes as `local q = convert(T, …)` statements
# appended to `stmts`, registering each local on `kc.cellsyms` so later recipes
# and the spine resolve their `_NK_CACHED` reads (recipes only ever read LOWER
# slots, so each name exists before its first read). The `convert` is exactly
# where the interpreter's scratch store (`buf[i] = _eval_acc(…)`, a `Vector{T}`
# setindex!) converts. Shared by the kernel cell body and the subcall inliner.
function _cg_emit_recipes!(stmts::Vector{Any}, ctx::_CGCtx, kc::_CGKernCtx)
    for r in kc.K.cse.recipes
        e = _cg_bound_body!(ctx, _cg_emit(ctx, kc, r))
        s = _cg_name(ctx, "q")
        push!(stmts, :(local $s = convert(_cgT, $e)))
        push!(kc.cellsyms, s)
    end
    return stmts
end

# Template sub-kernel call (`_NK_SUBCALL`): inline the body at the call site —
# per-cell CSE recipes become occurrence-local `convert(T, …)` locals (the
# interpreter refills the body's scratch at every evaluation; occurrence-local
# names compute the identical values), then the body spine evaluates against
# its OWN descriptor table. The body's invariant tier was emitted once in the
# prologue (`_cg_inv!` — `K.subs` holds every transitive sub, nested-first).
function _cg_emit_subcall(ctx::_CGCtx, kc::_CGKernCtx, S::_AccKernel)
    invsyms = get(ctx.invdone, S, nothing)
    invsyms === nothing && throw(_CodegenDecline(:subcall_order))
    inner = _CGKernCtx(S, kc.c, kc.n, kc.oln, kc.mi1, kc.mi2, kc.mi3,
                       Symbol[], invsyms)
    stmts = _cg_emit_recipes!(Any[], ctx, inner)
    spine = _cg_emit(ctx, inner, S.spine)
    isempty(stmts) && return spine
    return Expr(:block, stmts..., spine)
end

# ---- Op application (mirrors `_eval_acc_op` arm for arm) --------------------
function _cg_emit_op(ctx::_CGCtx, kc::_CGKernCtx, nd::_Node)
    op = nd.op
    ch = nd.children
    ev(x) = _cg_emit(ctx, kc, x)
    if op === :+ || op === :*
        isempty(ch) && throw(_CodegenDecline(:unsupported_op))
        length(ch) == 1 && return ev(ch[1])
        return _cg_foldl(op, Any[ev(c) for c in ch])
    elseif op === :-
        length(ch) == 1 && return :(-$(ev(ch[1])))
        length(ch) == 2 && return :($(ev(ch[1])) - $(ev(ch[2])))
        throw(_CodegenDecline(:unsupported_op))
    elseif op === :neg
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return :(-$(ev(ch[1])))
    elseif op === :and
        # `ev(x) == 0 && return 0.0` per child, else 1.0 — as an `&&` chain:
        # same child order, same short-circuit set, same 1.0/0.0 result.
        isempty(ch) && throw(_CodegenDecline(:unsupported_op))
        cond = _cg_chain(:&&, Any[:($(ev(c)) != 0) for c in ch])
        return :($cond ? 1.0 : 0.0)
    elseif op === :or
        isempty(ch) && throw(_CodegenDecline(:unsupported_op))
        cond = _cg_chain(:||, Any[:($(ev(c)) != 0) for c in ch])
        return :($cond ? 1.0 : 0.0)
    elseif op === :not
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return :($(ev(ch[1])) == 0 ? 1.0 : 0.0)
    elseif op === :ifelse
        length(ch) == 3 || throw(_CodegenDecline(:unsupported_op))
        return :($(ev(ch[1])) != 0 ? $(ev(ch[2])) : $(ev(ch[3])))
    elseif op === :atan
        length(ch) == 1 && return :(atan($(ev(ch[1]))))
        length(ch) == 2 && return :(atan($(ev(ch[1])), $(ev(ch[2]))))
        throw(_CodegenDecline(:unsupported_op))
    elseif op === :pi || op === :π
        return Float64(pi)
    elseif op === :e
        return Float64(ℯ)
    elseif op === :Pre
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return ev(ch[1])
    elseif op === :fn
        return _cg_emit_fn(ctx, kc, nd)
    end
    fnsym = get(_CG_BINARY_FN, op, nothing)
    if fnsym !== nothing
        length(ch) == 2 || throw(_CodegenDecline(:unsupported_op))
        return Expr(:call, fnsym, ev(ch[1]), ev(ch[2]))
    end
    fnsym = get(_CG_CMP_FN, op, nothing)
    if fnsym !== nothing
        length(ch) == 2 || throw(_CodegenDecline(:unsupported_op))
        return :($(Expr(:call, fnsym, ev(ch[1]), ev(ch[2]))) ? 1.0 : 0.0)
    end
    fnsym = get(_CG_UNARY_FN, op, nothing)
    if fnsym !== nothing
        length(ch) == 1 || throw(_CodegenDecline(:unsupported_op))
        return Expr(:call, fnsym, ev(ch[1]))
    end
    fnsym = get(_CG_MINMAX_FN, op, nothing)
    if fnsym !== nothing
        length(ch) >= 2 || throw(_CodegenDecline(:unsupported_op))
        return _cg_foldl(fnsym, Any[ev(c) for c in ch])
    end
    throw(_CodegenDecline(:unsupported_op))
end

# Closed function — the SAME payload dispatch and the SAME core kernels as the
# interpreters' `:fn` arms (compile.jl / access_kernel.jl), so interpolation
# is never reimplemented here. Specs ride the `tabs` tuple (field loads are
# hoisted by the compiler; the spec object is the very one the node carries).
function _cg_emit_fn(ctx::_CGCtx, kc::_CGKernCtx, nd::_Node)
    pl = nd.payload
    ch = nd.children
    if pl isa Tuple{String,_InterpLinearSpec}
        sp = _cg_tab!(ctx, pl[2])
        return :(_interp_linear_core($sp.table, $sp.axis, $(_cg_emit(ctx, kc, ch[1]))))
    elseif pl isa Tuple{String,_InterpBilinearSpec}
        sp = _cg_tab!(ctx, pl[2])
        return :(_interp_bilinear_core($sp.table, $sp.axis_x, $sp.axis_y,
                                       $(_cg_emit(ctx, kc, ch[1])),
                                       $(_cg_emit(ctx, kc, ch[2]))))
    elseif pl isa Tuple{String,_InterpSearchsortedSpec}
        sp = _cg_tab!(ctx, pl[2])
        # `convert(T, …)` exactly as the eval arms: the discrete index must
        # land in the evaluator's value type.
        return :(convert(_cgT, _interp_searchsorted_core("interp.searchsorted",
                     $(_cg_emit(ctx, kc, ch[1])), $sp.xs)))
    elseif pl isa Tuple{String,_InterpLinearLaneSpec}
        # Per-LANE spec table (kernel-class merge, oop_merge.jl): select THIS
        # cell's member spec by the box lane addressing, then call the SAME
        # core on the member's own table/axis — the interpreter's lane-spec
        # arm verbatim, bit-identical per lane by construction. The lane index
        # is `_interp_lane(h, midx)` on the loop multi-index, which is exactly
        # `_cg_boxaddr`'s exact-Int address (the `_AccStateTblBox` addressing;
        # its literal-1/zero-stride folding cannot change the index).
        h = pl[2]
        hs = _cg_tab!(ctx, h)
        sp = _cg_name(ctx, "sp")
        return :(let $sp = $hs.specs[$(_cg_boxaddr(kc, h.s1, h.s2, h.s3, h.off))]
                     _interp_linear_core($sp.table, $sp.axis,
                                         $(_cg_emit(ctx, kc, ch[1])))
                 end)
    elseif pl isa Tuple{String,_InterpBilinearLaneSpec}
        h = pl[2]
        hs = _cg_tab!(ctx, h)
        sp = _cg_name(ctx, "sp")
        return :(let $sp = $hs.specs[$(_cg_boxaddr(kc, h.s1, h.s2, h.s3, h.off))]
                     _interp_bilinear_core($sp.table, $sp.axis_x, $sp.axis_y,
                                           $(_cg_emit(ctx, kc, ch[1])),
                                           $(_cg_emit(ctx, kc, ch[2])))
                 end)
    elseif pl isa Tuple{String,_InterpSearchsortedLaneSpec}
        # `convert(_cgT, …)` exactly as the scalar-spec arm above (and the
        # interpreter's lane-spec arm): the discrete index must land in the
        # evaluator's value type.
        h = pl[2]
        hs = _cg_tab!(ctx, h)
        sp = _cg_name(ctx, "sp")
        return :(let $sp = $hs.specs[$(_cg_boxaddr(kc, h.s1, h.s2, h.s3, h.off))]
                     convert(_cgT, _interp_searchsorted_core("interp.searchsorted",
                                 $(_cg_emit(ctx, kc, ch[1])), $sp.xs))
                 end)
    elseif pl isa Tuple{String,_FnTypedCoreSpec}
        # Registry-declared typed scalar core (ess-dtcore). `_cgT === Float64`
        # folds under the constant propagation the per-chunk `local _cgT =
        # _rhs_value_type(u, p, t)` exists to enable: the Float64 specialization
        # calls the typed core with the row id spliced as a LITERAL — the
        # ladder in `_fn_typed_core_call` then folds to the one core, no arg
        # box — and the `Dual` specialization keeps the boxed registry-on-`T`
        # route below verbatim (AD widening unchanged). The `let` binds the
        # query once so the two arms cannot double-evaluate it.
        spec = pl[2]
        x = _cg_name(ctx, "x")
        return :(let $x = $(_cg_emit(ctx, kc, ch[1]))
                     _cgT === Float64 ?
                         _fn_typed_core_call($(spec.id), $x) :
                         convert(_cgT, _eval_closed_fn($(pl[1]::String), Any[$x], _cgT))
                 end)
    elseif pl isa Tuple{String,Nothing}
        # Boxed all-scalar closed fn WITHOUT a typed-core row (none in the
        # v0.3.0 set): same eager `Any[…]` arg boxing, same `_eval_closed_fn`
        # registry-on-`T` call, same convert.
        args = Any[_cg_emit(ctx, kc, c) for c in ch]
        return :(convert(_cgT, _eval_closed_fn($(pl[1]::String),
                     $(Expr(:ref, :Any, args...)), _cgT)))
    end
    throw(_CodegenDecline(:fn_payload))
end

# ---- Invariant tier → prologue locals (mirrors `_fill_invariant!`) ----------
# Emitted once per kernel OBJECT (a sub-kernel shared by several parents is
# recomputed-identical, so one fill is the same values). The dummy cell
# context (c=1, n=0, oln=1, midx=(1,1,1)) is `_fill_invariant!`'s — invariant
# recipes contain no cell-varying access, so it is never consulted, but a
# hand-built kernel that violates that reproduces the interpreter's reads.
function _cg_inv!(ctx::_CGCtx, K::_AccKernel)
    syms = get(ctx.invdone, K, nothing)
    syms === nothing || return syms
    syms = Symbol[]
    kc = _CGKernCtx(K, 1, 0, 1, 1, 1, 1, Symbol[], syms)
    ctx.invdone[K] = syms
    push!(ctx.invlog, K)
    for r in K.cse.inv_recipes
        e = _cg_bound_body!(ctx, _cg_emit(ctx, kc, r))
        s = _cg_name(ctx, "v")
        push!(ctx.prologue, :(local $s = convert(_cgT, $e)))
        push!(syms, s)
    end
    return syms
end

# ---- One kernel → its loop nest (mirrors `_run_acc_kernel!`) ----------------
# CHUNK-PARAMETERIZED (threaded cell axis, see "Threaded cell axis for the
# codegen tier" below): every loop nest iterates the cell ordinals `[a, b)` of
# ITS OWN cell set for chunk `_cgci` of `_cgnc`, where `(a, b)` is the shared
# static partition (`_chunk_ordinals`, access_kernel.jl — one arithmetic, not
# re-derived). The serial call is the `(1, 1)` instance: `a == 0, b == ncells`
# reproduces today's full loops with the inner-loop body instruction-identical
# (outs/contig/rank-1 boxes differ only in loop-bound arithmetic; rank-2/3
# boxes add two per-ROW range clamps that select the full range at `(1, 1)`).
# Partition and iteration order are pure functions of `(ncells, nchunks)`, and
# a cell computes the same instruction sequence on the same inputs whichever
# chunk it lands in, so any chunking reproduces the serial values BIT FOR BIT
# as long as no two cells share a `du` slot (checked at build — see
# `_cg_covered_outs_disjoint`).
function _cg_emit_kernel!(ctx::_CGCtx, K::_AccKernel)
    # Invariant tiers, nested-first (K.subs holds every transitive sub).
    for S in K.subs
        _cg_inv!(ctx, S)
    end
    invsyms = _cg_inv!(ctx, K)

    # Per-cell body: CSE recipes as locals (converted to T exactly where the
    # interpreter's scratch store converts), then the spine into du[oln].
    function cellbody(kc::_CGKernCtx)
        stmts = _cg_emit_recipes!(Any[], ctx, kc)
        push!(stmts, :(du[$(kc.oln)] = $(_cg_bound_body!(ctx, _cg_emit(ctx, kc, K.spine)))))
        return stmts
    end

    cs = K.cells
    # This kernel's chunk of the cell-ordinal axis (0-based, half-open).
    ncells = _cellset_ncells(cs)
    tv = _cg_name(ctx, "ab")
    av = _cg_name(ctx, "a")
    bv = _cg_name(ctx, "b")
    hdr = Any[:(local $tv = _chunk_ordinals($ncells, _cgci, _cgnc)),
              :(local $av = $tv[1]),
              :(local $bv = $tv[2])]
    if _is_outs(cs)
        outs = _cg_tab!(ctx, cs.outs)
        c = _cg_name(ctx, "c")
        oln = _cg_name(ctx, "o")
        kc = _CGKernCtx(K, c, 0, oln, c, 1, 1, Symbol[], invsyms)
        body = cellbody(kc)
        return quote
            $(hdr...)
            for $c in ($av + 1):$bv
                local $oln = $outs[$c]
                $(body...)
            end
        end
    elseif _is_contig(cs)
        rng = cs.ranges[1]
        c = _cg_name(ctx, "c")
        kc = _CGKernCtx(K, c, 0, c, c, 1, 1, Symbol[], invsyms)
        body = cellbody(kc)
        return quote
            $(hdr...)
            for $c in ($(first(rng)) + $av):($(first(rng)) + $bv - 1)
                $(body...)
            end
        end
    end
    # Strided Cartesian box, rank ≤ 3, in `_run_box_kernel!`'s exact iteration
    # order (k-outer, i-inner). c == oln for a box. The flat cell ordinal `o`
    # of `(i, j, k)` is `(i-i0) + ni·((j-j0) + nj·(k-k0))` — exactly the serial
    # enumeration position — and a chunk `[a, b)` is walked as whole i-ROWS
    # with the FIRST and LAST row's i-range clamped to the chunk boundary
    # (the decode is hoisted to the row level so the inner loop stays today's
    # instructions).
    nd = length(cs.strides)
    nd <= 3 || throw(_CodegenDecline(:box_rank))
    st = cs.strides
    rg = cs.ranges
    iv = _cg_name(ctx, "i")
    jv = nd >= 2 ? _cg_name(ctx, "j") : 1
    kv = nd >= 3 ? _cg_name(ctx, "k") : 1
    oln = _cg_name(ctx, "o")
    olnexpr = :($(cs.base) + $iv * $(st[1]))
    nd >= 2 && (olnexpr = :($olnexpr + $jv * $(st[2])))
    nd >= 3 && (olnexpr = :($olnexpr + $kv * $(st[3])))
    kc = _CGKernCtx(K, oln, 0, oln, iv, jv, kv, Symbol[], invsyms)
    body = cellbody(kc)
    i0 = first(rg[1]); i1 = last(rg[1]); ni = length(rg[1])
    if nd == 1
        return quote
            $(hdr...)
            for $iv in ($i0 + $av):($i0 + $bv - 1)
                local $oln = $olnexpr
                $(body...)
            end
        end
    end
    ohi = _cg_name(ctx, "e")          # last ordinal of the chunk (b - 1)
    ilo = _cg_name(ctx, "il")
    ihi = _cg_name(ctx, "ih")
    jlo = _cg_name(ctx, "jl")
    jhi = _cg_name(ctx, "jh")
    j0 = first(rg[2]); j1 = last(rg[2])
    if nd == 2
        return quote
            $(hdr...)
            if $av < $bv
                local $ohi = $bv - 1
                local $jlo = $j0 + div($av, $ni)
                local $jhi = $j0 + div($ohi, $ni)
                for $jv in $jlo:$jhi
                    local $ilo = $jv == $jlo ? $i0 + rem($av, $ni) : $i0
                    local $ihi = $jv == $jhi ? $i0 + rem($ohi, $ni) : $i1
                    for $iv in $ilo:$ihi
                        local $oln = $olnexpr
                        $(body...)
                    end
                end
            end
        end
    end
    # nd == 3: rows are indexed by the flat (j, k) row ordinal `r = o ÷ ni`;
    # the chunk's first/last row clamp j (per k) and i (on exactly the first
    # and last row, `k == klo && j == jlo` / `k == khi && j == jhi`).
    rlo = _cg_name(ctx, "rl")
    rhi = _cg_name(ctx, "rh")
    klo = _cg_name(ctx, "kl")
    khi = _cg_name(ctx, "kh")
    nj = length(rg[2]); k0 = first(rg[3])
    return quote
        $(hdr...)
        if $av < $bv
            local $ohi = $bv - 1
            local $rlo = div($av, $ni)
            local $rhi = div($ohi, $ni)
            local $klo = $k0 + div($rlo, $nj)
            local $khi = $k0 + div($rhi, $nj)
            for $kv in $klo:$khi
                local $jlo = $kv == $klo ? $j0 + rem($rlo, $nj) : $j0
                local $jhi = $kv == $khi ? $j0 + rem($rhi, $nj) : $j1
                for $jv in $jlo:$jhi
                    local $ilo = ($kv == $klo && $jv == $jlo) ? $i0 + rem($av, $ni) : $i0
                    local $ihi = ($kv == $khi && $jv == $jhi) ? $i0 + rem($ohi, $ni) : $i1
                    for $iv in $ilo:$ihi
                        local $oln = $olnexpr
                        $(body...)
                    end
                end
            end
        end
    end
end

# ---- Build the fused generated RHS section ----------------------------------
struct _CGBuilt{F,TB}
    f::F
    tabs::TB
    covered::Vector{Bool}
    # Threaded cell axis (see "Threaded cell axis for the codegen tier"):
    # total cells across the covered kernels, and the build-time verdict that
    # every covered out-slot is globally unique (section-chunking is only
    # enabled when it holds).
    ncells::Int
    outs_disjoint::Bool
end

# Every output slot of `cs` pushed into `seen`; false on the first duplicate.
# Cross-KERNEL by design: a per-kernel check could short-circuit a contiguous
# set as disjoint-by-construction (it only compares a set against itself),
# while here a contiguous range must also collide with the OTHER kernels'
# slots, so every kind enumerates. Same slot arithmetic as the runners,
# exact Int.
function _cellset_outs_disjoint!(seen::Set{Int}, cs::_CellSet)
    if _is_outs(cs)
        for o in cs.outs
            o in seen && return false
            push!(seen, o)
        end
        return true
    end
    if _is_contig(cs)
        for o in cs.ranges[1]
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

# Build-time SECTION-chunking safety check: are the emitted kernels' output
# slots globally pairwise-distinct ACROSS the whole generated function? Only
# then may one chunk run ALL kernels' cell sub-ranges without a barrier —
# two chunks could otherwise read-modify-write one `du` slot from different
# kernels (indirect-out / scatter merges CAN alias across kernels; the
# `_KernelSection` derivative-section comment says they don't for state
# equations, but this VERIFIES rather than trusts, and materialized-observed
# sections go through the same builder). Returns `(total cells, disjoint)`.
function _cg_covered_outs_disjoint(acc_kernels::AbstractVector{_AccKernel},
                                   covered::Vector{Bool})
    ncells = 0
    for (j, K) in enumerate(acc_kernels)
        covered[j] || continue
        ncells += _cellset_ncells(K.cells)
    end
    seen = Set{Int}()
    sizehint!(seen, ncells)
    for (j, K) in enumerate(acc_kernels)
        covered[j] || continue
        _cellset_outs_disjoint!(seen, K.cells) || return ncells, false
    end
    return ncells, true
end

# Per-generated-FUNCTION emitted-node cap. The node budget above bounds total
# AST size; this bounds the size of any ONE compiled function, because LLVM's
# first-call compile memory is super-linear in single-function size (one ~400k-
# node function OOMs a 40 GB host). Loop nests are packed into `@noinline`
# sub-functions up to this cap so LLVM compiles bounded pieces. Override with
# ESS_CODEGEN_FN_NODE_CAP; 0 disables splitting (one function, legacy layout).
_codegen_fn_node_cap() =
    something(tryparse(Int, get(ENV, "ESS_CODEGEN_FN_NODE_CAP", "")), 20_000)

# Every Symbol referenced anywhere in `ex` (recursively). Used to compute the
# exact set of outer-scope locals a chunk function must receive as arguments.
function _cg_collect_syms!(acc::Set{Symbol}, ex)
    if ex isa Symbol
        push!(acc, ex)
    elseif ex isa Expr
        for a in ex.args
            _cg_collect_syms!(acc, a)
        end
    end
    return acc
end

# LHS symbol of a prologue `local s = …` statement (the invariant-slot name).
function _cg_local_lhs(stmt)
    stmt isa Expr && stmt.head === :local || return nothing
    a = stmt.args[1]
    a isa Expr && a.head === :(=) ? a.args[1] : nothing
end

# ---- Intra-kernel body split (ess-iip-split) --------------------------------
# `_cg_emit` lowers one output cell to a SINGLE Julia expression. For a
# spine-dominated kernel that tree can be ~1e5 nodes; emitted as one function it
# blows the Julia compiler (compile is superlinear in single-function size — the
# duo LMARS momentum kernels OOM a 40 GB `:inplace` build). The kernel-CLASS
# merge already made the cell body grid-INDEPENDENT (one body over a lane axis),
# so the fix is purely to cap the SINGLE-FUNCTION size: partition the emitted
# expression so no generated function exceeds `_codegen_fn_node_cap`, while the
# WHOLE RHS stays compiled and NEVER touches the interpreter.
#
# The transform SPILLS an oversized sub-expression into an `@noinline` helper
# that RETURNS its value; the parent replaces the sub-expression with a CALL to
# that helper, sitting EXACTLY where the sub-expression was. Threading by return
# value (not a scratch buffer) means (a) laziness is preserved automatically — a
# spill inside an `ifelse`/`&&`/`||` arm becomes a call in that same arm, still
# only evaluated when the branch is taken; (b) zero allocation — helpers return
# scalars and capture nothing; (c) eltype-generic — each helper recomputes `_cgT`
# locally from `(u, p, t)`, exactly as the chunk sub-functions do. Bit-identical:
# the arithmetic and its evaluation order are unchanged, only wrapped in calls.
_cg_expr_size(ex) = ex isa Expr ? 1 + sum(_cg_expr_size, ex.args; init=0)::Int : 1

# True for a call to a split helper (`_cgh…(…)`) minted by `_cg_spill!` — an
# irreducible leaf of the partition (re-spilling it cannot shrink it).
_cg_is_spill_call(ex) =
    ex isa Expr && ex.head === :call && ex.args[1] isa Symbol &&
    startswith(String(ex.args[1]::Symbol), "_cgh")

# A head that introduces its own scope / bindings (a `_NK_REDUCE`/subcall body is
# a `quote` block with a `local` accumulator and a `for` loop var). Partitioning
# must treat such a node ATOMICALLY — never hoist a sub-expression out of it,
# since that sub-expression may reference a name bound INSIDE it — so it is
# spilled whole (with its internal bindings excluded from the helper's params)
# or left inline, never cut open.
_cg_binding_head(h::Symbol) =
    h === :block || h === :for || h === :while || h === :let ||
    h === :local || h === :global || h === :function || h === :(->) || h === :do

# Names bound WITHIN `ex` (`local x`, `for x in …`, `x = …`, loop/let targets):
# excluded from a spilled helper's parameter list because the helper carries the
# binding with it, and the call site does not have that name in scope.
function _cg_collect_bound!(acc::Set{Symbol}, ex)
    ex isa Expr || return acc
    if ex.head === :(=) || ex.head === :local || ex.head === :global
        for a in ex.args
            if a isa Symbol
                push!(acc, a)
            elseif a isa Expr && a.head === :(=) && a.args[1] isa Symbol
                push!(acc, a.args[1])
            end
        end
    elseif ex.head === :for || ex.head === :while
        # `for v in range` / a `while`'s loop spec binds its target(s).
        spec = ex.args[1]
        if spec isa Expr && spec.head === :(=) && spec.args[1] isa Symbol
            push!(acc, spec.args[1])
        end
    end
    for a in ex.args
        _cg_collect_bound!(acc, a)
    end
    return acc
end

# An outer-scope local the emitter minted (coords, tabs, cellsyms, invsyms) —
# every such name is `_cg…` EXCEPT the value-type `_cgT` (recomputed inside each
# helper) and the split helpers `_cgh…` themselves (top-level names, called, not
# passed). Anything else a helper body references (u, p, t, global fns, literals)
# needs no argument.
_cg_is_passable(s::Symbol) =
    (n = String(s); startswith(n, "_cg") && s !== :_cgT && !startswith(n, "_cgh"))

# Spill `sub` (already ≤ cap) into a fresh `@noinline` helper returning its
# value; return the call expression that replaces it. Tab reads in `sub` are
# already the by-type container indices `_cggrpG[pos]` (ess-iip-tabgroup), so the
# helper's tab dependency is ONE argument per GROUP (a few concrete-typed
# containers) no matter how many distinct tabs it touches — this is what keeps
# the split's parameter/inference cost from exploding with the tab count.
function _cg_spill!(ctx::_CGCtx, sub)
    syms = Set{Symbol}()
    _cg_collect_syms!(syms, sub)                     # `_cggrpG` containers + coords + child calls
    bound = _cg_collect_bound!(Set{Symbol}(), sub)   # names the helper binds itself
    extra = sort!([s for s in syms if _cg_is_passable(s) && !(s in bound)]; by = string)
    params = Symbol[:u, :p, :t]
    append!(params, extra)
    # Helper dedup: an identical body (same code ⇒ same params, since params are
    # exactly the passable names it references) reuses the first helper minted for
    # it. Only the CALL is re-emitted; the compiled function is shared. Value-exact
    # and laziness-preserving — a call in place of the sub-expression evaluates
    # exactly when the sub-expression would.
    dedup = !_cg_helper_dedup_disabled()
    key = dedup ? string(sub) : ""
    if dedup
        got = get(ctx.helper_dedup, key, nothing)
        if got !== nothing
            _tally_cascade!(:cg_helper_deduped)
            return Expr(:call, got, params...)
        end
    end
    fname = _cg_name(ctx, "h")
    ln = LineNumberNode(0, Symbol("ess-iip-split"))
    stmts = Any[]
    (:_cgT in syms) && push!(stmts, :(local _cgT = _rhs_value_type(u, p, t)))
    push!(stmts, Expr(:macrocall, Symbol("@inbounds"), ln, :(return $sub)))
    fdef = Expr(:function, Expr(:call, fname, params...), Expr(:block, stmts...))
    push!(ctx.helpers, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
    dedup && (ctx.helper_dedup[key] = fname)
    return Expr(:call, fname, params...)
end

# Partition `ex` so every generated function (this expression and every helper
# it spills) is ≤ `cap` nodes. Bottom-up: partition children first (each becomes
# ≤ cap), then, while this node's inlined size exceeds `cap`, spill its largest
# still-inline `Expr` child into a helper CALL (small). A node whose children are
# all spilled is `op(call, call, …)` — small — so the loop always terminates.
# Returns `(bounded_expr, size)`.
function _cg_partition!(ctx::_CGCtx, ex, cap::Int)
    ex isa Expr || return (ex, 1)
    # A scope-introducing node is atomic: do not recurse into it (a hoist could
    # escape a name bound inside). The caller may still spill it WHOLE.
    _cg_binding_head(ex.head) && return (ex, _cg_expr_size(ex))
    total = 1
    argsz = Vector{Int}(undef, length(ex.args))
    for i in eachindex(ex.args)
        (ex.args[i], argsz[i]) = _cg_partition!(ctx, ex.args[i], cap)
        total += argsz[i]
    end
    while total > cap
        bi = 0; bs = 0
        for i in eachindex(ex.args)
            a = ex.args[i]
            # Only a genuine sub-expression is worth spilling; an already-spilled
            # helper call is irreducible (spilling it again just wraps one call in
            # another of the SAME size — the non-termination this guards against).
            if a isa Expr && !_cg_is_spill_call(a) && argsz[i] > bs
                bs = argsz[i]; bi = i
            end
        end
        bi == 0 && break                       # only calls/leaves left — irreducible
        ex.args[bi] = _cg_spill!(ctx, ex.args[bi])
        newsz = _cg_expr_size(ex.args[bi])
        total += newsz - argsz[bi]
        argsz[bi] = newsz
    end
    return (ex, total)
end

# Cap an emitted cell expression to the per-function node target, spilling into
# helpers as needed. A no-op (returns `ex` unchanged, no helper minted) when it
# already fits — so small kernels keep today's single-function fast path byte
# for byte. `ESS_CODEGEN_BODY_SPLIT_DISABLE=1` forces the no-op (the pre-split
# build; used as the differential oracle and to reproduce the OOM).
function _cg_bound_body!(ctx::_CGCtx, ex)
    get(ENV, "ESS_CODEGEN_BODY_SPLIT_DISABLE", "") == "1" && return ex
    cap = _codegen_fn_node_cap()
    cap <= 0 && return ex
    _cg_expr_size(ex) <= cap && return ex
    return _cg_partition!(ctx, ex, cap)[1]
end

# Emit + compile every codegen-able kernel into a RuntimeGeneratedFunction
# `(du, u, p, t, tabs, ci, nchunks) -> nothing` — the per-CHUNK form of the
# section (see `_cg_emit_kernel!`): each kernel's loop nest covers its cell
# ordinals `[a, b)` for chunk `ci` of `nchunks`, and `(1, 1)` is the serial
# call. The shared invariant prologue is computed
# once in the outer function; the kernel loop nests are partitioned into
# `@noinline` sub-functions (each ≤ `_codegen_fn_node_cap()` nodes) so no single
# function is too large for LLVM to compile. Each sub-function receives du/u/p/t
# plus exactly the outer locals (tables, `_cgT`, invariant slots) its loops
# reference, as explicit arguments — it captures nothing, so the RHS stays
# allocation-free. Kernels that decline stay on their existing runners
# (`covered[j] == false`). Returns `nothing` when no kernel could be emitted.
function _build_codegen_rhs(acc_kernels::AbstractVector{_AccKernel};
                            budget::Int=_codegen_node_budget(),
                            tally::Symbol=:codegen,
                            shared_cache::Union{Nothing,_CSECache}=nothing)
    isempty(acc_kernels) && return nothing
    t0 = time_ns()
    ctx = _CGCtx(budget, shared_cache)
    covered = fill(false, length(acc_kernels))
    kloops = Tuple{Any,Int}[]         # (loop-nest expr, its emitted-node cost)
    for (j, K) in enumerate(acc_kernels)
        # Snapshot for rollback: a mid-kernel decline must discard its partial
        # prologue statements AND its invariant registrations (a later kernel
        # sharing that sub-kernel would otherwise reference rolled-back locals).
        nprologue = length(ctx.prologue)
        ninvlog = length(ctx.invlog)
        nhelpers = length(ctx.helpers)
        nodes0 = ctx.nodes
        fscratch0 = ctx.fscratch
        empty!(ctx.helper_dedup)   # dedup scope = this kernel (see the field doc)
        try
            lx = _cg_emit_kernel!(ctx, K)
            push!(kloops, (lx, ctx.nodes - nodes0))
            covered[j] = true
            _tally_cascade!(Symbol(tally, :_kernel))
            # Shared-prelude read observability (ess-cgfsc): this kernel
            # compiled carrying at least one such read.
            ctx.fscratch > fscratch0 && _tally_cascade!(:cg_foreign_scratch_emit)
        catch err
            err isa _CodegenDecline || rethrow()
            resize!(ctx.prologue, nprologue)
            for i in length(ctx.invlog):-1:(ninvlog + 1)
                delete!(ctx.invdone, ctx.invlog[i])
            end
            resize!(ctx.invlog, ninvlog)
            resize!(ctx.helpers, nhelpers)     # discard this kernel's split helpers
            ctx.nodes = nodes0
            ctx.fscratch = fscratch0
            _tally_cascade!(Symbol(tally, "_decline_", err.reason))
            _codegen_debug() &&
                println(stderr, "[ess-codegen/$tally] kernel $j DECLINED: $(err.reason)")
        end
    end
    any(covered) || return nothing
    ln = LineNumberNode(0, Symbol("ess-codegen"))

    # Outer locals a chunk may need as arguments: the table locals and every
    # invariant-slot local defined in the prologue. `_cgT` is deliberately NOT
    # passed — it is the value TYPE (a runtime `DataType`), and passing it across
    # the call boundary loses the constant-propagation that keeps `convert(_cgT,
    # …)` type-stable, boxing every scalar. Each chunk recomputes `_cgT` locally
    # from (u, p, t) instead, so inference constant-propagates it as before.
    ngrp = length(ctx.tab_types)
    outer_passed = Set{Symbol}()
    # The by-type tab containers (`_cggrpG`, one per distinct tab type — a handful,
    # not one per object) are the only tab locals now; every chunk / helper that
    # reads a tab references a container, so it receives that container.
    for g in 1:ngrp
        push!(outer_passed, _cg_grp_sym(g))
    end
    for stmt in ctx.prologue
        s = _cg_local_lhs(stmt)
        s === nothing || push!(outer_passed, s)
    end
    # The chunk index pair rides through like any other outer name: every
    # kernel loop nest references it (its `_chunk_ordinals` header), so the
    # sym-collection below forwards it into each `@noinline` sub-function.
    push!(outer_passed, :_cgci)
    push!(outer_passed, :_cgnc)

    # Partition the loop nests into chunks capped by emitted-node count.
    cap = _codegen_fn_node_cap()
    chunks = Vector{Vector{Any}}()
    cur = Any[]; curcost = 0
    for (lx, cost) in kloops
        if !isempty(cur) && cap > 0 && curcost + cost > cap
            push!(chunks, cur); cur = Any[]; curcost = 0
        end
        push!(cur, lx); curcost += cost
    end
    isempty(cur) || push!(chunks, cur)

    # One `@noinline` sub-function per chunk, taking du/u/p/t + exactly the outer
    # locals its loops reference (sorted for a deterministic signature). It
    # captures nothing, so calling it allocates nothing.
    fndefs = Any[]; callstmts = Any[]
    for (ci, chunk) in enumerate(chunks)
        used = Set{Symbol}()
        for lx in chunk
            _cg_collect_syms!(used, lx)
        end
        passed = sort!(collect(intersect(used, outer_passed)); by = string)
        fname = Symbol("_cgchunk_", ci)
        fbody = Expr(:block,
                     :(local _cgT = _rhs_value_type(u, p, t)),
                     Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, chunk...)),
                     :(return nothing))
        fdef = Expr(:function, Expr(:call, fname, :du, :u, :p, :t, passed...), fbody)
        push!(fndefs, Expr(:macrocall, Symbol("@noinline"), ln, fdef))
        push!(callstmts, Expr(:call, fname, :du, :u, :p, :t, passed...))
    end

    # `tabs` is now a tuple of the by-type containers; hoist each to its `_cggrpG`
    # local (a handful of statements, not one per object).
    grpstmts = Any[:(local $(_cg_grp_sym(g)) = tabs[$g]) for g in 1:ngrp]
    body = Expr(:block,
                grpstmts...,
                :(local _cgT = _rhs_value_type(u, p, t)),
                # Intra-kernel split helpers (ess-iip-split): defined FIRST so the
                # invariant prologue and every chunk sub-function can call them by
                # name. Each is `@noinline`, params-only (captures nothing).
                ctx.helpers...,
                Expr(:macrocall, Symbol("@inbounds"), ln, Expr(:block, ctx.prologue...)),
                fndefs...,
                callstmts...,
                :(return nothing))
    ex = Expr(:function, Expr(:tuple, :du, :u, :p, :t, :tabs, :_cgci, :_cgnc), body)
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__, ex)
    # Threaded cell axis: total covered cells + the global out-slot
    # disjointness verdict, both facts of the BUILD (the runtime chunk verdict
    # is `_sec_prep_threads!`'s).
    ncells, disjoint = _cg_covered_outs_disjoint(acc_kernels, covered)
    # The runtime `tabs` argument: one HOMOGENEOUS container per group, converted
    # to the group's concrete element type (`Vector{Vector{Int}}`, …), packed in a
    # small tuple. `_cggrpG[pos]` then reads a concrete-element container.
    tabpack = ntuple(g -> Vector{ctx.tab_types[g]}(ctx.tab_objs[g]), ngrp)
    ntabs = sum(length, ctx.tab_objs; init=0)
    if _codegen_debug()
        ms = (time_ns() - t0) / 1e6
        println(stderr, "[ess-codegen/$tally] emitted $(count(covered))/$(length(covered)) ",
                "kernels in $(length(chunks)) fn(s) + $(length(ctx.helpers)) split helper(s) ",
                "($(get(_CASCADE_TALLY, :cg_helper_deduped, 0)) deduped), $(ctx.nodes) nodes, ",
                "$ntabs tabs in $ngrp typed group(s), $(ncells) cells ",
                "(outs $(disjoint ? "disjoint" : "SHARED")), ",
                "build $(round(ms; digits=1)) ms")
    end
    return _CGBuilt(f, tabpack, covered, ncells, disjoint)
end

# ---- Threaded cell axis for the codegen tier (RFC threaded-eval-tier) -------
# The shared threading infrastructure (batch-runner hook, verdict tally,
# static partition) lives in access_kernel.jl ("Threading infrastructure" —
# the safety argument lives there). This section threads the generated
# functions themselves; since the Float64 lane tape was retired it is the only
# threaded tier.
#
# GRANULARITY: the WHOLE SECTION is chunked, not each kernel. One batch
# dispatch runs chunk `c` of every emitted kernel back to back —
# `f(du, u, p, t, tabs, c, nchunks)` — with no inter-kernel barrier. That is
# safe because the section builder proves the strong property up front:
# `_cg_covered_outs_disjoint` verifies at build time that every covered
# out-slot is globally unique ACROSS all emitted kernels. When that holds, no
# two cells anywhere in the section touch the same `du` slot, kernels share no
# other mutable state (locals only; `u`/`p`/`t`/tabs are read-only here), and
# the inter-kernel barrier is unnecessary — one dispatch per RHS call, so the
# per-dispatch wake-up latency is paid ONCE instead of #kernels times. When it
# does NOT hold (`:cg_serial_shared_outs`), the section never chunks and every
# generated function runs its serial `(1, 1)` instance.
#
# BIT-IDENTITY, per kernel: chunk boundaries are not observable (a cell
# computes the same instruction sequence on the same inputs whichever chunk it
# lands in; every ⊕-fold is WITHIN a cell — REDUCE/CONTRACTION loops are
# per-cell in the emitted body), the partition is the static
# `_chunk_ordinals`, and disjoint writes commute. Threaded `du` is bitwise
# `===` serial `du`.
#
# OPT-IN semantics: no Polyester ⇒ serial, ESS_THREADS_DISABLE=1 ⇒ serial,
# section total below the per-chunk min-cells threshold
# (ESS_THREADS_MIN_CELLS) ⇒ serial. ESS_CG_THREADS_DISABLE=1 additionally
# forces this tier serial — the codegen-threading differential oracle.
# Verdicts land in `_THREAD_TALLY` (`:cg_threaded` / `:cg_serial_small` /
# `:cg_serial_shared_outs`), documented with the existing keys.
_cg_threads_disabled() = get(ENV, "ESS_CG_THREADS_DISABLE", "") == "1"

# One-time threading verdict for one generated function's cell axes:
# `state` is 0 unexamined, 1 chunked, -1 serial (too few cells), -2 serial
# (globally shared out-slots — permanent, decided at build).
# `ncells`/`disjoint` are build facts (`_CGBuilt`); `nchunks` is fixed
# at the first threaded call, so the partition is identical call to call.
mutable struct _SecTCache
    state::Int
    ncells::Int
    disjoint::Bool
    nchunks::Int
end
_SecTCache(ncells::Int, disjoint::Bool) = _SecTCache(0, ncells, disjoint, 1)
_sec_tcache(cg::_CGBuilt) = _SecTCache(cg.ncells, cg.outs_disjoint)
_sec_tcache(::Nothing) = _SecTCache(0, false)

# Decide once whether this generated function may run chunked: size first
# (the min-cells threshold guards per-DISPATCH work, and the section is one
# dispatch), then the build-time disjointness verdict.
function _sec_prep_threads!(tc::_SecTCache)
    tc.state == 0 || return tc
    minc = _thread_min_cells()
    nchunks = min(Threads.nthreads(), max(1, div(tc.ncells, max(minc, 1))))
    if nchunks < 2
        tc.state = -1                 # too few cells to be worth a dispatch
        _tally_thread!(:cg_serial_small)
        return tc
    end
    if !tc.disjoint
        tc.state = -2                 # shared out-slots: chunks would race
        _tally_thread!(:cg_serial_shared_outs)
        return tc
    end
    tc.nchunks = nchunks
    tc.state = 1
    _tally_thread!(:cg_threaded)
    return tc
end

# Run one generated function's cells as `nchunks` STATIC chunks — the
# `_BATCH_RUNNER` hook (EarthSciASTPolyesterExt) over the `_chunk_ordinals`
# partition; each chunk re-runs the (pure) tab-hoist + invariant prologue on
# its own stack and walks its `[a, b)` slice of every kernel. Only reached
# when `_threads_available()` was true, so the runner is non-null.
function _run_cg_section_threaded!(f, tabs, du, u, p, t, tc::_SecTCache)
    nchunks = tc.nchunks
    run_chunk = function (c::Int)
        f(du, u, p, t, tabs, c, nchunks)
        return nothing
    end
    _BATCH_RUNNER[](run_chunk, nchunks)
    return nothing
end

# Per-call gate for the chunked path (the shared `_threads_available()` plus
# the codegen-specific kill switch; both re-read per call, so toggling either
# env var between calls flips the route without touching the cached verdict).
@inline _cg_threads_available() = _threads_available() && !_cg_threads_disabled()

# ---- The RHS's kernel section (wired into `_make_rhs`, acc_merge.jl) --------
# One concretely-typed callable holding the generated function (or `Nothing`)
# plus the residual kernels that keep the per-cell interpreter. The
# `F === Nothing` branch folds away per closure specialization, so with the
# tier disabled (or nothing emitted) `f!` is instruction-for-instruction the
# pre-codegen RHS. Emitted kernels write disjoint du slots from residual ones
# (each state slot has exactly one equation/cell), so running the generated
# section first is value-identical to the original in-order kernel loop.
struct _KernelSection{F,TB,G,GTB}
    cgf::F
    cgtabs::TB
    n_emitted::Int                # kernels compiled into the generated function
    kernels::Vector{_AccKernel}   # residual kernels (interpreter runner)
    # Dual overflow tier (ess-dualfp): a second generated function covering the
    # residual kernels the PRIMARY emission declined (in practice on the node
    # budget). Under non-Float64 `T` it is called unconditionally, so Duals run
    # compiled code instead of the per-cell interpreter; at Float64 it serves
    # the residual kernels whenever `f64cg` below is armed. `dual_resid`
    # indexes `kernels`: the kernels even the overflow emission declined, which
    # keep the eltype-generic interpreter under every `T`.
    dualf::G
    dualtabs::GTB
    n_dual_emitted::Int
    dual_resid::Vector{Int}
    # Float64 overflow routing (ess-f64ofl): when true, the overflow function
    # above also serves Float64 calls (in place of the per-cell interpreter).
    # Baked at build time from ESS_F64_OVERFLOW_CODEGEN (default on).
    f64cg::Bool
    # Threaded cell axis: one lazily-decided chunk verdict per generated
    # function (primary / overflow), see `_SecTCache` above.
    tcache::_SecTCache
    dual_tcache::_SecTCache
end

@inline function (s::_KernelSection{F,TB,G})(du, u, p, t, ::Type{T}) where {F,TB,G,T}
    if F !== Nothing
        # PRIMARY generated function, chunked at Float64 when the section
        # verdict allows (threaded cell axis above; Float64-only — Dual calls
        # stay serial). Any serial verdict (small,
        # shared outs, no Polyester, either kill switch) runs the (1, 1)
        # instance — the serial entry.
        if T === Float64 && _cg_threads_available() &&
           _sec_prep_threads!(s.tcache).state == 1
            _run_cg_section_threaded!(s.cgf, s.cgtabs, du, u, p, t, s.tcache)
        else
            s.cgf(du, u, p, t, s.cgtabs, 1, 1)
        end
    end
    kernels = s.kernels
    if G !== Nothing && T !== Float64
        # Dual fast path: the overflow function covers every kernel not in
        # `dual_resid`. Emitted kernels write disjoint du slots from residual
        # ones (each state slot has exactly one equation/cell), so the order
        # generated-first is value-identical to the in-order kernel loop.
        s.dualf(du, u, p, t, s.dualtabs, 1, 1)
        @inbounds for j in s.dual_resid
            _run_acc_kernel!(du, u, p, t, kernels[j], T)
        end
        return nothing
    end
    if G !== Nothing && T === Float64 && s.f64cg
        # Float64 overflow routing (ess-f64ofl): budget-declined kernels run
        # the SAME compiled overflow function as the Dual path, bit-identical
        # to the interpreter by the emitter's contract — CHUNKED whenever the
        # section verdict allows, serial `(1, 1)` otherwise. In particular, a
        # shared-outs section (`:cg_serial_shared_outs`) under threading runs
        # the overflow RGF SERIAL: before the lane-tape retirement this case
        # fell back to the tape, whose per-kernel chunking (barriers between
        # kernels) could still thread it. That is an accepted theoretical
        # regression — the verdict has never been produced by any real build
        # (globally shared out-slots require two equations writing one state
        # slot; the threaded-codegen work could not construct it outside a
        # hand-poisoned cache), and serial-compiled is still far faster than
        # the per-cell interpreter. Kernels the overflow emission itself
        # declined keep the interpreter, in the same order as the plain loop
        # below.
        if _cg_threads_available() && _sec_prep_threads!(s.dual_tcache).state == 1
            _run_cg_section_threaded!(s.dualf, s.dualtabs, du, u, p, t,
                                      s.dual_tcache)
        else
            s.dualf(du, u, p, t, s.dualtabs, 1, 1)
        end
        @inbounds for j in s.dual_resid
            _run_acc_kernel!(du, u, p, t, kernels[j], Float64)
        end
        return nothing
    end
    @inbounds for j in 1:length(kernels)
        _run_acc_kernel!(du, u, p, t, kernels[j], T)
    end
    return nothing
end

# Partition the kernels between the codegen tier and the pre-existing runners.
# `ESS_CODEGEN_DISABLE=1` (or an empty emission) yields a section that is
# exactly the pre-codegen kernel loop; `ESS_DUAL_CODEGEN_DISABLE=1` yields the
# pre-dual routing (Duals interpret every residual kernel) with the primary
# tier intact.
# `shared_cache` (ess-cgfsc): the build's scalar prelude `_CSECache`, passed
# ONLY by the `_make_rhs` call site (acc_merge.jl) — the one place where the
# section provably runs after that cache's prelude tiers were filled in the
# same `f!` call. Every other caller keeps the default `nothing`, which keeps
# the `:foreign_scratch` decline for shared-prelude reads.
function _make_kernel_section(acc_kernels::AbstractVector{_AccKernel};
                              shared_cache::Union{Nothing,_CSECache}=nothing)
    cg = _codegen_disabled() ? nothing :
         _build_codegen_rhs(acc_kernels; shared_cache=shared_cache)
    if cg === nothing
        kernels = collect(_AccKernel, acc_kernels)
        n_emitted = 0
    else
        resid = [j for j in eachindex(cg.covered) if !cg.covered[j]]
        kernels = _AccKernel[acc_kernels[j] for j in resid]
        n_emitted = count(cg.covered)
    end
    cgf = cg === nothing ? nothing : cg.f
    cgtabs = cg === nothing ? nothing : cg.tabs
    # Dual overflow tier: retry the residual kernels under the dual budget. Its
    # RGF is only ever CALLED with non-Float64 arguments, so nothing here adds
    # Float64 compile latency — only the (cheap) AST emission runs at build.
    # Gated on ESS_CODEGEN_DISABLE too: that switch must keep yielding a pure
    # pre-codegen build (the codegen tier's differential oracle).
    dg = (_codegen_disabled() || _dual_codegen_disabled() || isempty(kernels)) ?
         nothing :
         _build_codegen_rhs(kernels; budget=_dual_codegen_node_budget(),
                            tally=:dual_codegen, shared_cache=shared_cache)
    if dg === nothing
        return _KernelSection(cgf, cgtabs, n_emitted, kernels,
                              nothing, nothing, 0, collect(Int, 1:length(kernels)),
                              false, _sec_tcache(cg), _sec_tcache(nothing))
    end
    # Float64 overflow routing (ess-f64ofl): armed whenever the overflow
    # function exists and ESS_F64_OVERFLOW_CODEGEN has not turned it off.
    # `ESS_DUAL_CODEGEN_DISABLE=1` / `ESS_CODEGEN_DISABLE=1` reach the branch
    # above instead, so both remain full oracles for their tiers.
    f64cg = _f64_overflow_codegen_enabled()
    f64cg && _tally_cascade!(:f64_overflow_armed)
    dual_resid = Int[j for j in eachindex(dg.covered) if !dg.covered[j]]
    return _KernelSection(cgf, cgtabs, n_emitted, kernels,
                          dg.f, dg.tabs, count(dg.covered), dual_resid, f64cg,
                          _sec_tcache(cg), _sec_tcache(dg))
end
