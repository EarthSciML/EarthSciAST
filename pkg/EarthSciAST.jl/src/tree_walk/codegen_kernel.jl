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
#     (`_interp_*_core` with the node's typed `_Interp*Spec`, boxed
#     `_eval_closed_fn` for `datetime.*`) — interpolation is not reimplemented.
#
# ELTYPE-GENERIC: the emitted function derives `T = _rhs_value_type(u, p, t)`
# exactly as the interpreter does, so the SAME generated code integrates at
# Float64 and differentiates under ForwardDiff `Dual` (state or parameters).
#
# FALLBACK CONTRACT (identical to the affine/lane-tape tiers): anything the
# emitter cannot model — an unknown node kind or descriptor, a foreign CSE
# scratch, a >3-D box, an oversized spine — declines THAT kernel silently
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
end
_CGCtx(budget::Int) = _CGCtx(Any[], IdDict{Any,Int}(), IdDict{Any,Vector{Symbol}}(),
                             Any[], Any[], 0, budget, 0)

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
    elseif pl isa Tuple{String,Nothing}
        # Boxed all-scalar closed fn (`datetime.*`): same eager `Any[…]` arg
        # boxing, same `_eval_closed_fn` registry-on-`T` call, same convert.
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
    if _is_outs(cs)
        outs = _cg_tab!(ctx, cs.outs)
        c = _cg_name(ctx, "c")
        oln = _cg_name(ctx, "o")
        kc = _CGKernCtx(K, c, 0, oln, c, 1, 1, Symbol[], invsyms)
        body = cellbody(kc)
        return quote
            for $c in 1:$(length(cs.outs))
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
            for $c in $(first(rng)):$(last(rng))
                $(body...)
            end
        end
    end
    # Strided Cartesian box, rank ≤ 3, in `_run_box_kernel!`'s exact iteration
    # order (k-outer, i-inner). c == oln for a box.
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
    inner = quote
        for $iv in $(first(rg[1])):$(last(rg[1]))
            local $oln = $olnexpr
            $(body...)
        end
    end
    nd >= 2 && (inner = quote
        for $jv in $(first(rg[2])):$(last(rg[2]))
            $inner
        end
    end)
    nd >= 3 && (inner = quote
        for $kv in $(first(rg[3])):$(last(rg[3]))
            $inner
        end
    end)
    return inner
end

# ---- Build the fused generated RHS section ----------------------------------
struct _CGBuilt{F,TB}
    f::F
    tabs::TB
    covered::Vector{Bool}
end

# Emit + compile every codegen-able kernel into ONE RuntimeGeneratedFunction
# `(du, u, p, t, tabs) -> nothing`. Kernels that decline stay on their
# existing runners (`covered[j] == false`). Returns `nothing` when no kernel
# could be emitted.
function _build_codegen_rhs(acc_kernels::AbstractVector{_AccKernel})
    isempty(acc_kernels) && return nothing
    t0 = time_ns()
    ctx = _CGCtx(_codegen_node_budget())
    covered = fill(false, length(acc_kernels))
    loops = Any[]
    for (j, K) in enumerate(acc_kernels)
        # Snapshot for rollback: a mid-kernel decline must discard its partial
        # prologue statements AND its invariant registrations (a later kernel
        # sharing that sub-kernel would otherwise reference rolled-back locals).
        nprologue = length(ctx.prologue)
        ninvlog = length(ctx.invlog)
        nodes0 = ctx.nodes
        try
            push!(loops, _cg_emit_kernel!(ctx, K))
            covered[j] = true
            _tally_cascade!(:codegen_kernel)
        catch err
            err isa _CodegenDecline || rethrow()
            resize!(ctx.prologue, nprologue)
            for i in length(ctx.invlog):-1:(ninvlog + 1)
                delete!(ctx.invdone, ctx.invlog[i])
            end
            resize!(ctx.invlog, ninvlog)
            ctx.nodes = nodes0
            _tally_cascade!(Symbol("codegen_decline_", err.reason))
            _codegen_debug() &&
                println(stderr, "[ess-codegen] kernel $j DECLINED: $(err.reason)")
        end
    end
    any(covered) || return nothing
    tabstmts = Any[:(local $(Symbol("_cgtab", i)) = tabs[$i]) for i in 1:length(ctx.tabs)]
    ln = LineNumberNode(0, Symbol("ess-codegen"))
    body = Expr(:block,
                tabstmts...,
                :(local _cgT = _rhs_value_type(u, p, t)),
                Expr(:macrocall, Symbol("@inbounds"), ln,
                     Expr(:block, ctx.prologue..., loops...)),
                :(return nothing))
    ex = Expr(:function, Expr(:tuple, :du, :u, :p, :t, :tabs), body)
    f = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__, ex)
    if _codegen_debug()
        ms = (time_ns() - t0) / 1e6
        println(stderr, "[ess-codegen] emitted $(count(covered))/$(length(covered)) ",
                "kernels, $(ctx.nodes) nodes, $(length(ctx.tabs)) tab objects, ",
                "build $(round(ms; digits=1)) ms")
    end
    return _CGBuilt(f, Tuple(ctx.tabs), covered)
end

# ---- The RHS's kernel section (wired into `_make_rhs`, acc_merge.jl) --------
# One concretely-typed callable holding the generated function (or `Nothing`)
# plus the residual kernels/plans that keep their pre-codegen runners. The
# `F === Nothing` branch folds away per closure specialization, so with the
# tier disabled (or nothing emitted) `f!` is instruction-for-instruction the
# pre-codegen RHS. Emitted kernels write disjoint du slots from residual ones
# (each state slot has exactly one equation/cell), so running the generated
# section first is value-identical to the original in-order kernel loop.
struct _KernelSection{F,TB}
    cgf::F
    cgtabs::TB
    n_emitted::Int                # kernels compiled into the generated function
    kernels::Vector{_AccKernel}   # residual kernels (pre-codegen runners)
    plans::Vector{Union{Nothing,_AccPlan}}
end

@inline function (s::_KernelSection{F})(du, u, p, t, ::Type{T}) where {F,T}
    F !== Nothing && s.cgf(du, u, p, t, s.cgtabs)
    kernels = s.kernels
    plans = s.plans
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
# exactly the pre-codegen kernel loop.
function _make_kernel_section(acc_kernels::AbstractVector{_AccKernel},
                              acc_plans::AbstractVector{Union{Nothing,_AccPlan}})
    cg = _codegen_disabled() ? nothing : _build_codegen_rhs(acc_kernels)
    if cg === nothing
        return _KernelSection(nothing, nothing, 0,
                              collect(_AccKernel, acc_kernels),
                              collect(Union{Nothing,_AccPlan}, acc_plans))
    end
    resid = [j for j in eachindex(cg.covered) if !cg.covered[j]]
    return _KernelSection(cg.f, cg.tabs, count(cg.covered),
                          _AccKernel[acc_kernels[j] for j in resid],
                          Union{Nothing,_AccPlan}[acc_plans[j] for j in resid])
end
