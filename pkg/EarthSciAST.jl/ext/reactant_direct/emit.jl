# ========================================================================
# ext/reactant_direct/emit.jl — the walk: scalar spines, access kernels,
# template sub-kernels, CSR reduces, prefix scans, and the whole RHS.
# ========================================================================

# ---- parameters and time -----------------------------------------------------

function _de_param(ctx::_DECtx, nd::_E._Node)::_DEVal
    p = ctx.p
    p isa NamedTuple ||
        _de_refuse("a parameter read on a `p` of type $(typeof(p))",
            "the emitter reads parameters by NAME out of a NamedTuple, the " *
            "shape `build_evaluator` hands back. A vector `p` (`ComponentVector`, " *
            "`Vector`) reaches parameters by flat index and is not wired here.")
    hasproperty(p, nd.sym) ||
        _de_refuse("the parameter `$(nd.sym)`",
            "it is not a field of the parameter NamedTuple passed to this call.")
    x = getfield(p, nd.sym)
    if x isa TracedRNumber{Float64}
        _de_tally!(ctx, :param_input)
        op = _hlo.reshape(x.mlir_data; result_0=_de_ty(1), location=_de_loc())
        return _DEVal(_de_res(op), 1)
    elseif x isa Real
        # A HOST parameter is a compile-time constant, exactly as it is under the
        # traced emitter. Pass `ConcreteRNumber`s to keep parameters as program
        # inputs (an override then needs no recompile).
        return _de_const(ctx, Float64(x))
    end
    _de_refuse("the parameter `$(nd.sym)` of type $(typeof(x))",
        "a parameter is either a host `Real` (baked as a constant) or a traced " *
        "`Float64` scalar (a program input).")
end

function _de_time(t)
    if t isa TracedRNumber{Float64}
        op = _hlo.reshape(t.mlir_data; result_0=_de_ty(1), location=_de_loc())
        return _DEVal(_de_res(op), 1)
    end
    _de_refuse("a time argument of type $(typeof(t))",
        "`t` must be traced so the program can be stepped without recompiling; " *
        "pass a `ConcreteRNumber{Float64}`.")
end

# ---- the scalar spine --------------------------------------------------------

function _de_scalar(ctx::_DECtx, nd::_E._Node, cache::Vector{_DEVal})::_DEVal
    folded = _de_try_fold(ctx, nd)
    folded === nothing || return folded
    k = nd.kind
    if k === _E._NK_LITERAL
        return _de_const(ctx, nd.literal)
    elseif k === _E._NK_STATE
        return _de_read(ctx, ctx.ue, nd.idx)
    elseif k === _E._NK_PARAM
        return _de_param(ctx, nd)
    elseif k === _E._NK_TIME
        return ctx.t
    elseif k === _E._NK_CACHED
        return cache[nd.idx]
    elseif k === _E._NK_CONTRACTION
        terms = _DEVal[_de_scalar(ctx, ch, cache) for ch in nd.children]
        return _de_fold_terms(ctx, nd.op, nd.literal, terms)
    elseif k === _E._NK_CONTRACTION_LOOP
        # Emission-time unroll of the static range, in the interpreter's
        # ascending order. A loop whose BODY is host data never gets here — it
        # folded above — and a long one lands in `stablehlo.reduce` rather than a
        # chain of `range` binary ops (see `_de_fold_terms`).
        spec = nd.payload::_E._ContractLoop
        body = nd.children[1]
        terms = _DEVal[]
        for kk in spec.lo:spec.step:spec.hi
            spec.ref[] = kk
            push!(terms, _de_scalar(ctx, body, cache))
        end
        return _de_fold_terms(ctx, nd.op, nd.literal, terms)
    elseif k === _E._NK_LOOPVAR
        return _de_const(ctx, Float64((nd.payload::Base.RefValue{Int})[]))
    elseif k === _E._NK_CONST_GATHER
        return _de_const(ctx, _de_hostval(ctx, nd))
    elseif k === _E._NK_STATE_GATHER
        sg = nd.payload::_E._StateGather
        off = 0
        for d in eachindex(nd.children)
            sub = _de_index_int(nd.children[d])
            (sg.lo[d] <= sub <= sg.hi[d]) || return _de_const(ctx, 0.0)   # ghost cell
            off += (sub - sg.lo[d]) * sg.strides[d]
        end
        return _de_read(ctx, ctx.ue, sg.slot_flat[off + 1])
    elseif k === _E._NK_PARAM_GATHER
        # Live forcing, read from the `buffers` ARGUMENT (never from the build's
        # captured host array — see `_de_buffer`).
        buf = _de_buffer(ctx, nd.payload::Vector{Float64})
        return _de_slice(ctx, buf, nd.idx, nd.idx)
    elseif k === _E._NK_OP
        if nd.op === :fn
            return _de_fn(ctx, nd, ch -> _de_scalar(ctx, ch, cache))
        end
        if (nd.op === :^ || nd.op === :pow) && length(nd.children) == 2 &&
           nd.children[2].kind === _E._NK_LITERAL
            base = _de_scalar(ctx, nd.children[1], cache)
            return _de_bin(ctx, _hlo.power, base, _de_const(ctx, nd.children[2].literal))
        end
        c = _DEVal[_de_scalar(ctx, ch, cache) for ch in nd.children]
        return _de_op(ctx, nd, c)
    end
    _de_refuse("the scalar-spine node kind $(_de_kindname(k))",
        "no arm of `_de_scalar` lowers it.")
end

# Node-kind names, so a refusal says `_NK_SUBCALL` rather than `7`.
const _DE_KINDS = Dict{UInt8,String}(
    _E._NK_LITERAL => "_NK_LITERAL", _E._NK_STATE => "_NK_STATE",
    _E._NK_PARAM => "_NK_PARAM", _E._NK_TIME => "_NK_TIME",
    _E._NK_CACHED => "_NK_CACHED", _E._NK_OP => "_NK_OP",
    _E._NK_PARAM_GATHER => "_NK_PARAM_GATHER",
    _E._NK_CONST_GATHER => "_NK_CONST_GATHER",
    _E._NK_STATE_GATHER => "_NK_STATE_GATHER",
    _E._NK_LOOPVAR => "_NK_LOOPVAR",
    _E._NK_CONTRACTION => "_NK_CONTRACTION",
    _E._NK_CONTRACTION_LOOP => "_NK_CONTRACTION_LOOP",
    _E._NK_ACCESS => "_NK_ACCESS", _E._NK_SUBCALL => "_NK_SUBCALL",
    _E._NK_REDUCE => "_NK_REDUCE",
)
_de_kindname(k::UInt8) = get(_DE_KINDS, k, "kind $(Int(k))")

const _DE_AKINDS = Dict{UInt8,String}(
    _E._AK_STATE_AFFINE => "_AK_STATE_AFFINE",
    _E._AK_STATE_INDIRECT => "_AK_STATE_INDIRECT",
    _E._AK_STATE_INDIRECT_COL => "_AK_STATE_INDIRECT_COL",
    _E._AK_STATE_TBL_BOX => "_AK_STATE_TBL_BOX",
    _E._AK_STATE_FIXED => "_AK_STATE_FIXED",
    _E._AK_SCALAR => "_AK_SCALAR",
    _E._AK_ARR_FIXED => "_AK_ARR_FIXED",
    _E._AK_FORCING_BOX => "_AK_FORCING_BOX",
    _E._AK_ARR_TBL_BOX => "_AK_ARR_TBL_BOX",
)
_de_akindname(k::UInt8) = get(_DE_AKINDS, k, "access descriptor kind $(Int(k))")

# ---- template sub-kernels ----------------------------------------------------
#
# The emission twin of `_OopSubRT`: the parent plan's FLAT transitive sub list
# with its aligned lane plans, and one CSE tier per sub. The invariant tier is
# emitted once per kernel by the prologue (as the interpreter's runner fills it
# once per call); the per-cell tier is re-emitted at each subcall site, which is
# what the interpreter's re-fill is in SSA form.
struct _DESubRT
    subs::Vector{_E._AccKernel}
    plans::Vector{_E._OopAccPlan}
    invvals::Vector{Vector{_DEVal}}
    cellvals::Vector{Vector{_DEVal}}
end
const _DE_NO_SUB = _DESubRT(_E._AccKernel[], _E._OopAccPlan[],
                            Vector{_DEVal}[], Vector{_DEVal}[])

function _de_build_subrt(plan::_E._OopAccPlan)
    subs = plan.subs
    isempty(subs) && return _DE_NO_SUB
    invvals = Vector{Vector{_DEVal}}(undef, length(subs))
    cellvals = Vector{Vector{_DEVal}}(undef, length(subs))
    for j in eachindex(subs)
        S = subs[j]
        invvals[j] = Vector{_DEVal}(undef, length(S.cse.inv_recipes))
        cellvals[j] = Vector{_DEVal}(undef, length(S.cse.recipes))
    end
    return _DESubRT(subs, plan.sub_plans, invvals, cellvals)
end

# ---- CSR reduces -------------------------------------------------------------
#
# `_oop_reduce_fold` in SSA form. The body has already been emitted ONCE over the
# flat E-lane buffer; each cell's answer is `zerobar ⊕ body[seg[c]] ⊕ … ` in
# ascending (CSR) order. Emitted as `W = max segment width` whole-lane steps:
# step `m` reads each cell's `m`-th entry (a read of the body value at
# `seg[c]+m-1`) and, for the cells whose segment is shorter than `m`, selects the
# ⊕-identity instead — so every cell folds its own entries, in order, and the
# short cells fold identities after them.
#
# `⊕ 0̄` is exact for every semiring the IR uses (`+` with 0.0 on a value that is
# never `-0.0` because the seed is `+0.0`; `*` with 1.0; `max`/`min` with ∓Inf),
# so the padding changes no value. The op count is O(W) — the widest cell's
# valence, a property of the connectivity — and never O(#cells).
function _de_reduce_fold(ctx::_DECtx, bodyE::_DEVal, seg::Vector{Int},
                         zerobar::Float64, op::Symbol)::_DEVal
    N = length(seg) - 1
    N >= 1 || _de_refuse("_NK_REDUCE", "the CSR row-pointer vector is empty.")
    widths = Int[seg[c + 1] - seg[c] for c in 1:N]
    W = maximum(widths)
    W == 0 && return _de_bcast(ctx, _de_const(ctx, zerobar), N)
    E = bodyE.len
    f = _de_semiring_fn(op)
    s = _de_bcast(ctx, _de_const(ctx, zerobar), N)
    zpad = _de_const(ctx, zerobar)
    for m in 1:W
        if bodyE.len == 1
            term = bodyE            # a body that hoisted lane-invariant
        else
            pos = Int[min(max(seg[c] + m - 1, 1), E) for c in 1:N]
            term = _de_take(ctx, bodyE, pos)
        end
        short = Bool[widths[c] < m for c in 1:N]
        if any(short)
            term = _de_select(ctx, _de_boolconst(ctx, short), N, zpad,
                              _de_bcast(ctx, term, N))
        end
        s = _de_bin(ctx, f, s, term)
    end
    _de_tally!(ctx, :csr_reduce)
    return s
end

# ---- access kernels ----------------------------------------------------------

function _de_acck(ctx::_DECtx, nd::_E._Node, K::_E._AccKernel, plan::_E._OopAccPlan,
                  invvals::Vector{_DEVal}, cellvals::Vector{_DEVal},
                  sub::_DESubRT)::_DEVal
    folded = _de_try_fold(ctx, nd)
    folded === nothing || return folded
    k = nd.kind
    if k === _E._NK_ACCESS
        a = K.acc[nd.idx]
        ak = a.kind
        if ak === _E._AK_STATE_AFFINE || ak === _E._AK_STATE_INDIRECT ||
           ak === _E._AK_STATE_INDIRECT_COL
            return _de_gather(ctx, ctx.ue, plan.gathers[nd.idx])
        elseif ak === _E._AK_STATE_TBL_BOX
            g = _de_gather(ctx, ctx.ue, plan.gathers[nd.idx])
            m = plan.ghost[nd.idx]
            isempty(m) && return g
            return _de_select(ctx, _de_boolconst(ctx, m), g.len, _de_const(ctx, 0.0), g)
        elseif ak === _E._AK_STATE_FIXED
            return _de_read(ctx, ctx.ue, a.idx)
        elseif ak === _E._AK_SCALAR
            return _de_const(ctx, a.v)
        elseif ak === _E._AK_ARR_FIXED
            # LIVE forcing, invariant slot: one element of a program input.
            buf = _de_buffer(ctx, a.arr)
            return _de_slice(ctx, buf, a.idx, a.idx)
        elseif ak === _E._AK_FORCING_BOX || ak === _E._AK_ARR_TBL_BOX
            # LIVE forcing lanes: one read of a program input at host-frozen
            # indices — slices plus a concatenate, or one gather.
            buf = _de_buffer(ctx, a.arr)
            return _de_take(ctx, buf, plan.forc[nd.idx])
        else
            # CONST_AFFINE / CONST_BOX / LOOP_IDX / CONST_CELL / CONST_EDGE:
            # frozen lane data, one interned array constant.
            return _de_arrconst(ctx, plan.consts[nd.idx])
        end
    elseif k === _E._NK_LITERAL
        return _de_const(ctx, nd.literal)
    elseif k === _E._NK_PARAM
        return _de_param(ctx, nd)
    elseif k === _E._NK_TIME
        return ctx.t
    elseif k === _E._NK_CACHED
        return nd.payload === K.cse.scratch ? cellvals[nd.idx] : invvals[nd.idx]
    elseif k === _E._NK_SUBCALL
        S = nd.payload::_E._AccKernel
        j = _de_sub_index(sub.subs, S)
        Sp = sub.plans[j]
        iv = sub.invvals[j]
        cv = sub.cellvals[j]
        rs = S.cse.recipes
        for i in eachindex(rs)
            cv[i] = _de_acck(ctx, rs[i], S, Sp, iv, cv, sub)
        end
        _de_tally!(ctx, :subcall)
        return _de_acck(ctx, S.spine, S, Sp, iv, cv, sub)
    elseif k === _E._NK_REDUCE
        isempty(plan.red_plan) &&
            _de_refuse("_NK_REDUCE", "this kernel's plan carries no E-lane " *
                       "reduce plan, so the body cannot be evaluated per entry.")
        Ep = plan.red_plan[1]
        bodyE = _de_acck(ctx, nd.children[1], K, Ep, invvals, cellvals, sub)
        return _de_reduce_fold(ctx, bodyE, plan.red_seg, K.zerobar, :+)
    elseif k === _E._NK_CONTRACTION
        terms = _DEVal[_de_acck(ctx, ch, K, plan, invvals, cellvals, sub)
                       for ch in nd.children]
        return _de_fold_terms(ctx, nd.op, nd.literal, terms)
    elseif k === _E._NK_OP
        if nd.op === :fn
            return _de_fn(ctx, nd, ch -> _de_acck(ctx, ch, K, plan, invvals, cellvals, sub))
        end
        if (nd.op === :^ || nd.op === :pow) && length(nd.children) == 2 &&
           nd.children[2].kind === _E._NK_LITERAL
            base = _de_acck(ctx, nd.children[1], K, plan, invvals, cellvals, sub)
            return _de_bin(ctx, _hlo.power, base, _de_const(ctx, nd.children[2].literal))
        end
        c = _DEVal[_de_acck(ctx, ch, K, plan, invvals, cellvals, sub)
                   for ch in nd.children]
        return _de_op(ctx, nd, c)
    end
    _de_refuse("the access-kernel node kind $(_de_kindname(k))",
        "no arm of `_de_acck` lowers it.")
end

function _de_sub_index(subs::Vector{_E._AccKernel}, S::_E._AccKernel)
    for j in eachindex(subs)
        subs[j] === S && return j
    end
    _de_refuse("_NK_SUBCALL",
        "the call references a sub-kernel absent from the parent plan's " *
        "transitive `K.subs` list — a `_collect_subkernels` invariant break, " *
        "not a coverage gap.")
end

# One vectorized kernel: the sub-kernels' invariant tiers, then this kernel's
# invariant and per-cell tiers, the spine, and the scatter into the target slot
# map. Mirrors `_oop_run_acc_vec` step for step.
function _de_run_kernel!(ctx::_DECtx, out::Vector{_DESlot}, K::_E._AccKernel,
                         plan::_E._OopAccPlan)
    plan.vectorizable ||
        _de_refuse("a per-cell fallback access kernel",
            "its lane plan is not vectorizable, so the interpreter runs it one " *
            "cell at a time. A compiled program cannot: the emitted graph would " *
            "grow with the grid. Find what made `_build_oop_acc_plan` decline " *
            "(an unsupported descriptor kind or an unbounded reduce) and lower " *
            "that instead.")
    sub = _de_build_subrt(plan)
    for j in eachindex(sub.subs)
        S = sub.subs[j]
        Sp = sub.plans[j]
        iv = sub.invvals[j]; cv = sub.cellvals[j]
        ir = S.cse.inv_recipes
        for i in eachindex(ir)
            iv[i] = _de_acck(ctx, ir[i], S, Sp, iv, cv, sub)
        end
    end
    cse = K.cse
    invvals = Vector{_DEVal}(undef, length(cse.inv_recipes))
    cellvals = Vector{_DEVal}(undef, length(cse.recipes))
    for i in eachindex(cse.inv_recipes)
        invvals[i] = _de_acck(ctx, cse.inv_recipes[i], K, plan, invvals, cellvals, sub)
    end
    for i in eachindex(cse.recipes)
        cellvals[i] = _de_acck(ctx, cse.recipes[i], K, plan, invvals, cellvals, sub)
    end
    res = _de_acck(ctx, K.spine, K, plan, invvals, cellvals, sub)
    _de_tally!(ctx, :kernels)
    _de_write!(ctx, out, plan.out_slots, res)
    return nothing
end

# ---- prefix scans ------------------------------------------------------------
#
# Level-major, exactly as the traced extension's `_scan_lanes_oop`: one whole
# LEVEL per step, so the emitted program is O(scan length) and independent of the
# number of lanes at each level.
function _de_scan!(ctx::_DECtx, m::Vector{_DESlot}, S::_E._ScanFold)
    len = S.len
    len >= 1 || return nothing
    nl = div(length(S.slots), len)
    f = _de_semiring_fn(S.oplus)
    z = _de_const(ctx, S.zerobar)
    acc = z
    for kk in 1:len
        slots_k = Int[S.slots[(l - 1) * len + kk] for l in 1:nl]
        term = _de_gather(ctx, m, slots_k)
        if S.inclusive
            acc = _de_bin(ctx, f, acc, term)
            _de_write!(ctx, m, slots_k, acc)
        else
            if kk == 1
                _de_write!(ctx, m, slots_k, _de_bcast(ctx, z, nl))
                acc = _de_bin(ctx, f, z, term)
            else
                _de_write!(ctx, m, slots_k, acc)
                acc = _de_bin(ctx, f, acc, term)
            end
        end
    end
    _de_tally!(ctx, :scans)
    return nothing
end

# ---- the whole RHS -----------------------------------------------------------

function _de_emit!(ctx::_DECtx, rhs)::_DEVal
    n_states = ctx.n_states
    # Materialized observed levels, filled into the extended slot map.
    mat = getfield(rhs, :mat_levels)
    for (li, lvl) in enumerate(mat)
        scalars, kernels, plans, scans = lvl
        empty_cache = _DEVal[]
        for (slot, nd) in scalars
            _de_rule!("the observed fill of $(_de_slotname(ctx, slot)) " *
                      "(materialization level $li)") do
                _de_write!(ctx, ctx.ue, Int[slot], _de_scalar(ctx, nd, empty_cache))
            end
        end
        for j in eachindex(kernels)
            _de_rule!("the observed fill kernel writing " *
                      "$(_de_slotsname(ctx, plans[j].out_slots)) " *
                      "(materialization level $li)") do
                _de_run_kernel!(ctx, ctx.ue, kernels[j], plans[j])
            end
        end
        for S in scans
            _de_rule!("a prefix scan at materialization level $li") do
                _de_scan!(ctx, ctx.ue, S)
            end
        end
    end
    # CSE prelude.
    prelude = getfield(rhs, :cse_prelude)
    cache = Vector{_DEVal}(undef, length(prelude))
    for s in eachindex(prelude)
        _de_rule!("shared subexpression $s of the CSE prelude") do
            cache[s] = _de_scalar(ctx, prelude[s], cache)
        end
    end
    # State equations.
    du = Vector{_DESlot}(nothing, n_states)
    for (slot, nd) in getfield(rhs, :rhs_list)
        _de_rule!("the state equation for $(_de_slotname(ctx, slot))") do
            _de_write!(ctx, du, Int[slot], _de_scalar(ctx, nd, cache))
        end
    end
    kernels = getfield(rhs, :acc_kernels)
    plans = getfield(rhs, :acc_plans)
    for j in eachindex(kernels)
        _de_rule!("the access kernel writing $(_de_slotsname(ctx, plans[j].out_slots))") do
            _de_run_kernel!(ctx, du, kernels[j], plans[j])
        end
    end
    for S in getfield(rhs, :scan_folds)
        _de_rule!("a prefix scan over the state equations") do
            _de_scan!(ctx, du, S)
        end
    end
    return _de_assemble(ctx, du, n_states)
end
