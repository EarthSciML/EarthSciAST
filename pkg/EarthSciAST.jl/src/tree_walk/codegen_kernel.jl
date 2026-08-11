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
# FALLBACK CONTRACT (identical to the affine/lane-tape tiers): anything the
# emitter cannot model — an unknown node kind or descriptor, a foreign CSE
# scratch (except the build's own shared scalar-prelude cache, which since
# ess-cgfsc is emitted as the interpreter's `_cse_read`; see the tier note
# below), a >3-D box, an oversized spine — declines THAT kernel silently
# (`_CodegenDecline`); the kernel keeps its existing runner (lane tape at
# Float64, scalar walk otherwise). Declines are counted per reason in
# `_CASCADE_TALLY` (`:codegen_kernel` / `:codegen_decline_<reason>`), the
# `_tally_cascade!` pattern.
#
# GENERATED CODE NEVER TOUCHES INTERPRETER STATE: CSE/invariant slots become
# SSA-style locals, never writes into the kernel's `_AccScratch` buffers — so
# an emitted kernel and an interpreted one coexist within one RHS call.
#
# Kill switch: ESS_CODEGEN_DISABLE=1 restores the pre-codegen tiers exactly
# (the differential-oracle escape hatch, mirroring ESS_STENCIL_DISABLE).
# Debug: ESS_CODEGEN_DEBUG=1 prints per-build emission/decline/latency lines.
# Budget: ESS_CODEGEN_NODE_BUDGET overrides the emitted-node cap (default
# 400_000 across all kernels of one build) that bounds Julia compile latency.
# ========================================================================

_codegen_disabled() = get(ENV, "ESS_CODEGEN_DISABLE", "") == "1"
_codegen_debug() = get(ENV, "ESS_CODEGEN_DEBUG", "") == "1"
_codegen_node_budget() =
    something(tryparse(Int, get(ENV, "ESS_CODEGEN_NODE_BUDGET", "")), 400_000)

# ---- Dual overflow tier (ess-dualfp) ----------------------------------------
# Kernels the primary emission declines — in practice on the node BUDGET, which
# exists to bound Float64 build latency — keep the Float64 lane tape, but under
# any OTHER value type (ForwardDiff `Dual` in a stiff-solver Jacobian) they used
# to drop all the way to the per-cell interpreter `_run_acc_kernel!`. The dual
# overflow tier re-emits those residual kernels into a SECOND generated function
# with its own (default unbounded) budget. Under non-Float64 `T` it is called
# unconditionally, so its native-compile cost is paid at the first Dual call.
# (Since ess-f64ofl, below, the same function also serves Float64 calls when
# the Float64 overflow routing is armed; ESS_F64_OVERFLOW_CODEGEN=0 restores
# the tape-at-Float64 routing byte-for-byte.)
# Kill switch: ESS_DUAL_CODEGEN_DISABLE=1 restores the pre-dual routing exactly
# (the differential-oracle escape hatch, mirroring ESS_CODEGEN_DISABLE); the
# tier is also off whenever ESS_CODEGEN_DISABLE=1 disables codegen wholesale,
# so the existing oracle stays a pure interpreter/tape build.
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
# budget-declined kernel stops running the Float64 lane tape and runs compiled
# code, like every other kernel. The overflow RGF is eltype-generic and its
# emission is already paid at build (a few ms); what this routing adds is the
# residual kernels' NATIVE compile at the first Float64 call — measured at
# ~0.13-0.15 s per 1000 emitted nodes (roughly linear, the per-function
# ESS_CODEGEN_FN_NODE_CAP chunking is what keeps it linear), the same latency a
# Dual caller already pays at its first call. Steady-state, the compiled
# routing measured ~1.7-1.8x faster per RHS call than the serial tape on a
# tape-class fixture (234 -> 137 us at 3528 cells; 4.5 -> 2.5 ms at 69768
# cells), 0 B/call either way.
#
# THE TAPE IS NOT RETIRED. It remains built, reachable, and load-bearing:
#   * kill switch ESS_F64_OVERFLOW_CODEGEN=0 restores the tape routing exactly
#     (tape at Float64 for every residual kernel) — the differential oracle;
#   * with Polyester threading active, the overflow RGF now runs CHUNKED on
#     its own threaded cell axis (see "Threaded cell axis for the codegen
#     tier" below) — compiled+threaded, which measured faster than the
#     threaded tape it used to defer to. The tape remains the call-time
#     fallback whenever the section may NOT chunk for safety
#     (`:cg_serial_shared_outs`): its per-kernel threading is still safe
#     there, and the guard is per call, so `using Polyester` after the build
#     still engages it.
#   * kernels even the overflow emission declines (`dual_resid`) keep the
#     tape/interpreter at Float64, exactly as before.
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
# every such kernel (`:foreign_scratch`), dropping it to the tape/interpreter.
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

# Per-kernel decline: the kernel keeps the interpreter/lane-tape runner.
# Never an error — the tier is a pure optimization.
struct _CodegenDecline <: Exception
    reason::Symbol
end

# ---- Emission context (one per generated function) --------------------------
mutable struct _CGCtx
    # Runtime objects the generated code needs (const arrays, connectivity /
    # valence tables, interp specs, outs vectors) — passed as ONE tuple
    # argument and hoisted to locals in the prologue. Deduped by identity.
    tabs::Vector{Any}
    tabid::IdDict{Any,Int}
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
end
_CGCtx(budget::Int, shared_cache::Union{Nothing,_CSECache}=nothing) =
    _CGCtx(Any[], IdDict{Any,Int}(), IdDict{Any,Vector{Symbol}}(),
           Any[], Any[], 0, budget, 0, shared_cache, 0)

_cg_name(ctx::_CGCtx, base::String) = Symbol("_cg", base, ctx.nname += 1)

@inline function _cg_budget!(ctx::_CGCtx)
    ctx.nodes += 1
    ctx.nodes > ctx.budget && throw(_CodegenDecline(:budget))
    return nothing
end

# Register a runtime object; returns the prologue-local Symbol that holds it.
function _cg_tab!(ctx::_CGCtx, obj)
    id = get(ctx.tabid, obj, 0)
    id != 0 && return Symbol("_cgtab", id)
    push!(ctx.tabs, obj)
    id = length(ctx.tabs)
    ctx.tabid[obj] = id
    return Symbol("_cgtab", id)
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
        return :(getfield(p, $(QuoteNode(nd.sym))))
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
        e = _cg_emit(ctx, kc, r)
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
        e = _cg_emit(ctx, kc, r)
        s = _cg_name(ctx, "v")
        push!(ctx.prologue, :(local $s = convert(_cgT, $e)))
        push!(syms, s)
    end
    return syms
end

# ---- One kernel → its loop nest (mirrors `_run_acc_kernel!`) ----------------
# CHUNK-PARAMETERIZED (threaded cell axis, see "Threaded cell axis for the
# codegen tier" below): every loop nest iterates the cell ordinals `[a, b)` of
# ITS OWN cell set for chunk `_cgci` of `_cgnc`, where `(a, b)` is the tape's
# exact static partition (`_chunk_ordinals`, access_kernel.jl — shared, not
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
        push!(stmts, :(du[$(kc.oln)] = $(_cg_emit(ctx, kc, K.spine))))
        return stmts
    end

    cs = K.cells
    # This kernel's chunk of the cell-ordinal axis (0-based, half-open).
    ncells = _plan_ncells(cs)
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
    # (`_plan_walk!` decodes the same ordinals per cell; here the decode is
    # hoisted to the row level so the inner loop stays today's instructions).
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
# The cross-KERNEL generalization of `_plan_output_disjoint` (access_kernel.jl):
# that check may short-circuit a contiguous set as disjoint-by-construction
# because it only ever compares a set against itself, while here a contiguous
# range must also collide with the OTHER kernels' slots, so every kind
# enumerates. Same slot arithmetic as the runners, exact Int.
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
        ncells += _plan_ncells(K.cells)
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
        nodes0 = ctx.nodes
        fscratch0 = ctx.fscratch
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
            ctx.nodes = nodes0
            ctx.fscratch = fscratch0
            _tally_cascade!(Symbol(tally, "_decline_", err.reason))
            _codegen_debug() &&
                println(stderr, "[ess-codegen/$tally] kernel $j DECLINED: $(err.reason)")
        end
    end
    any(covered) || return nothing
    tabstmts = Any[:(local $(Symbol("_cgtab", i)) = tabs[$i]) for i in 1:length(ctx.tabs)]
    ln = LineNumberNode(0, Symbol("ess-codegen"))

    # Outer locals a chunk may need as arguments: the table locals and every
    # invariant-slot local defined in the prologue. `_cgT` is deliberately NOT
    # passed — it is the value TYPE (a runtime `DataType`), and passing it across
    # the call boundary loses the constant-propagation that keeps `convert(_cgT,
    # …)` type-stable, boxing every scalar. Each chunk recomputes `_cgT` locally
    # from (u, p, t) instead, so inference constant-propagates it as before.
    outer_passed = Set{Symbol}()
    for i in 1:length(ctx.tabs)
        push!(outer_passed, Symbol("_cgtab", i))
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

    body = Expr(:block,
                tabstmts...,
                :(local _cgT = _rhs_value_type(u, p, t)),
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
    if _codegen_debug()
        ms = (time_ns() - t0) / 1e6
        println(stderr, "[ess-codegen/$tally] emitted $(count(covered))/$(length(covered)) ",
                "kernels in $(length(chunks)) fn(s), $(ctx.nodes) nodes, ",
                "$(length(ctx.tabs)) tab objects, $(ncells) cells ",
                "(outs $(disjoint ? "disjoint" : "SHARED")), ",
                "build $(round(ms; digits=1)) ms")
    end
    return _CGBuilt(f, Tuple(ctx.tabs), covered, ncells, disjoint)
end

# ---- Threaded cell axis for the codegen tier (RFC threaded-eval-tier) -------
# The lane tape's threaded cell axis (access_kernel.jl, "Threaded cell axis" —
# read that first, the safety argument lives there) made the tape the ONLY
# threaded tier: compiled kernels always ran serial, and the f64 overflow
# routing had to DEFER to the tape whenever Polyester threading was active.
# This section threads the generated functions themselves.
#
# GRANULARITY: the WHOLE SECTION is chunked, not each kernel. One batch
# dispatch runs chunk `c` of every emitted kernel back to back —
# `f(du, u, p, t, tabs, c, nchunks)` — instead of the tape's one dispatch per
# kernel with an implicit inter-kernel barrier. The tape needs that barrier
# because it cannot see across kernels (plans are built one kernel at a time);
# the section builder CAN, so it proves the stronger property up front:
# `_cg_covered_outs_disjoint` verifies at build time that every covered
# out-slot is globally unique ACROSS all emitted kernels. When that holds, no
# two cells anywhere in the section touch the same `du` slot, kernels share no
# other mutable state (locals only; `u`/`p`/`t`/tabs are read-only here), and
# the inter-kernel barrier is unnecessary — one dispatch per RHS call, the
# per-kernel wake-up latency the tape's design comment measures as the
# threading killer paid ONCE instead of #kernels times. When it does NOT hold
# (`:cg_serial_shared_outs`), the section never chunks: the primary function
# stays serial, and the overflow routing falls back to the tape loop — whose
# per-kernel threading (Option 2 semantics: chunked kernels with barriers
# between them) still applies wherever `_plan_output_disjoint` holds
# per-kernel.
#
# BIT-IDENTITY: same argument as the tape's, per kernel — chunk boundaries are
# not observable (a cell computes the same instruction sequence on the same
# inputs whichever chunk it lands in; every ⊕-fold is WITHIN a cell — REDUCE/
# CONTRACTION loops are per-cell in the emitted body), the partition is the
# tape's own static `_chunk_ordinals`, and disjoint writes commute. Threaded
# `du` is bitwise `===` serial `du`.
#
# OPT-IN semantics are the tape's, unchanged: no Polyester ⇒ serial,
# ESS_THREADS_DISABLE=1 ⇒ serial, section total below the per-chunk min-cells
# threshold (ESS_THREADS_MIN_CELLS) ⇒ serial. ESS_CG_THREADS_DISABLE=1
# additionally forces THIS tier serial while leaving the tape's threading
# untouched — the codegen-threading differential oracle. Verdicts land in
# `_THREAD_TALLY` (`:cg_threaded` / `:cg_serial_small` /
# `:cg_serial_shared_outs`), documented with the existing keys.
_cg_threads_disabled() = get(ENV, "ESS_CG_THREADS_DISABLE", "") == "1"

# One-time threading verdict for one generated function's cell axes, the
# `_PlanTCache` pattern: `state` is 0 unexamined, 1 chunked, -1 serial (too
# few cells), -2 serial (globally shared out-slots — permanent, decided at
# build). `ncells`/`disjoint` are build facts (`_CGBuilt`); `nchunks` is fixed
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

# Decide once whether this generated function may run chunked. Mirrors
# `_plan_prep_threads!` check for check (size first, then disjointness), with
# the section's cell total standing in for the plan's: the threshold guards
# per-DISPATCH work, and the section is one dispatch.
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

# Run one generated function's cells as `nchunks` STATIC chunks — the same
# `_BATCH_RUNNER` hook (EarthSciASTPolyesterExt) and the same partition the
# tape uses; each chunk re-runs the (pure) tab-hoist + invariant prologue on
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

# Per-call gate for the chunked path (the tape's `_threads_available()` plus
# the codegen-specific kill switch; both re-read per call, so toggling either
# env var between calls flips the route without touching the cached verdict).
@inline _cg_threads_available() = _threads_available() && !_cg_threads_disabled()

# ---- The RHS's kernel section (wired into `_make_rhs`, acc_merge.jl) --------
# One concretely-typed callable holding the generated function (or `Nothing`)
# plus the residual kernels/plans that keep their pre-codegen runners. The
# `F === Nothing` branch folds away per closure specialization, so with the
# tier disabled (or nothing emitted) `f!` is instruction-for-instruction the
# pre-codegen RHS. Emitted kernels write disjoint du slots from residual ones
# (each state slot has exactly one equation/cell), so running the generated
# section first is value-identical to the original in-order kernel loop.
struct _KernelSection{F,TB,G,GTB}
    cgf::F
    cgtabs::TB
    n_emitted::Int                # kernels compiled into the generated function
    kernels::Vector{_AccKernel}   # residual kernels (pre-codegen runners)
    plans::Vector{Union{Nothing,_AccPlan}}
    # Dual overflow tier (ess-dualfp): a second generated function covering the
    # residual kernels the PRIMARY emission declined (in practice on the node
    # budget), called ONLY under non-Float64 `T` — so Duals run compiled code
    # instead of the per-cell interpreter, and the Float64 path (tape /
    # interpreter over `kernels`/`plans` above) is untouched. `dual_resid`
    # indexes `kernels`: the kernels even the overflow emission declined, which
    # keep the eltype-generic interpreter under non-Float64 `T`.
    dualf::G
    dualtabs::GTB
    n_dual_emitted::Int
    dual_resid::Vector{Int}
    # Float64 overflow routing (ess-f64ofl): when true, the overflow function
    # above also serves Float64 calls (in place of the lane tape). Baked at
    # build time from ESS_F64_OVERFLOW_CODEGEN (default on).
    f64cg::Bool
    # Threaded cell axis: one lazily-decided chunk verdict per generated
    # function (primary / overflow), see `_SecTCache` above.
    tcache::_SecTCache
    dual_tcache::_SecTCache
end

@inline function (s::_KernelSection{F,TB,G})(du, u, p, t, ::Type{T}) where {F,TB,G,T}
    if F !== Nothing
        # PRIMARY generated function, chunked at Float64 when the section
        # verdict allows (threaded cell axis above; Float64-only exactly like
        # the tape's — Dual calls stay serial). Any serial verdict (small,
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
    plans = s.plans
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
        # to the tape/interpreter by the emitter's contract — and, since the
        # threaded cell axis, CHUNKED whenever the section verdict allows, so
        # threaded users get compiled+threaded rather than deferring to the
        # tape (measured on reseact.esm at 8 threads, whole mechanism forced
        # onto the overflow tier via budget 0: chemistry 2.44 ms/call chunked
        # RGF vs 3.55 ms threaded tape, 1.46x; transport 11.1 ms vs 1.26 s —
        # its kernels are not tape-eligible, so the old deferral left them on
        # the per-cell interpreter). The tape loop
        # remains the fallback on the `:cg_serial_shared_outs` verdict, where
        # its per-kernel chunking (barriers between kernels) is still safe.
        # Kernels the overflow emission itself declined keep their pre-codegen
        # runners, in the same order as the plain loop below.
        route = 1                     # 1 ⇒ serial (1,1) call, 2 ⇒ chunked, 3 ⇒ tape
        if _cg_threads_available()
            st = _sec_prep_threads!(s.dual_tcache).state
            route = st == 1 ? 2 : st == -2 ? 3 : 1
        end
        if route != 3
            if route == 2
                _run_cg_section_threaded!(s.dualf, s.dualtabs, du, u, p, t,
                                          s.dual_tcache)
            else
                s.dualf(du, u, p, t, s.dualtabs, 1, 1)
            end
            @inbounds for j in s.dual_resid
                P = plans[j]
                if P !== nothing
                    _run_acc_plan!(du, u, p, t, kernels[j], P)
                else
                    _run_acc_kernel!(du, u, p, t, kernels[j], Float64)
                end
            end
            return nothing
        end
    end
    @inbounds for j in 1:length(kernels)
        P = plans[j]
        if T === Float64 && P !== nothing
            _run_acc_plan!(du, u, p, t, kernels[j], P)
        else
            _run_acc_kernel!(du, u, p, t, kernels[j], T)
        end
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
function _make_kernel_section(acc_kernels::AbstractVector{_AccKernel},
                              acc_plans::AbstractVector{Union{Nothing,_AccPlan}};
                              shared_cache::Union{Nothing,_CSECache}=nothing)
    cg = _codegen_disabled() ? nothing :
         _build_codegen_rhs(acc_kernels; shared_cache=shared_cache)
    if cg === nothing
        kernels = collect(_AccKernel, acc_kernels)
        plans = collect(Union{Nothing,_AccPlan}, acc_plans)
        n_emitted = 0
    else
        resid = [j for j in eachindex(cg.covered) if !cg.covered[j]]
        kernels = _AccKernel[acc_kernels[j] for j in resid]
        plans = Union{Nothing,_AccPlan}[acc_plans[j] for j in resid]
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
        return _KernelSection(cgf, cgtabs, n_emitted, kernels, plans,
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
    return _KernelSection(cgf, cgtabs, n_emitted, kernels, plans,
                          dg.f, dg.tabs, count(dg.covered), dual_resid, f64cg,
                          _sec_tcache(cg), _sec_tcache(dg))
end
