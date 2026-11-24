# ========================================================================
# ext/reactant_direct/emit.jl — the walk: scalar spines, access kernels,
# CSR reduces, prefix scans, and the whole RHS.
# ========================================================================

# ---- parameters and time -----------------------------------------------------

_de_param(ctx::_DECtx, nd::_E._Node)::_DEVal = _de_param(ctx, nd.sym)

function _de_param(ctx::_DECtx, sym::Symbol)::_DEVal
    p = ctx.p
    p isa _DEParamVector && return _de_vector_param(ctx, p, sym)
    p isa NamedTuple ||
        _de_refuse(
        ctx,
        "a parameter read on a `p` of type $(typeof(p))",
        "the emitter reads parameters by NAME out of a NamedTuple, the " *
            "shape a build hands back as `p`. A vector `p` (`ComponentVector`, " *
            "`Vector`) reaches parameters by flat index and is not wired here."
    )
    hasproperty(p, sym) ||
        _de_refuse(
        ctx,
        "the parameter `$(sym)`",
        "it is not a field of the parameter NamedTuple passed to this call."
    )
    x = getfield(p, sym)
    if x isa TracedRNumber{Float64}
        _de_tally!(ctx, :param_input)
        op = _hlo.reshape(x.mlir_data; result_0 = _de_ty(1), location = _de_loc())
        return _DEVal(_de_res(op), 1)
    elseif x isa Real
        # A HOST parameter is a compile-time constant. Pass `ConcreteRNumber`s
        # to keep parameters as program inputs (an override then needs no
        # recompile).
        return _de_const(ctx, Float64(x))
    end
    return _de_refuse(
        ctx,
        "the parameter `$(sym)` of type $(typeof(x))",
        "a parameter is either a host `Real` (baked as a constant) or a traced " *
            "`Float64` scalar (a program input)."
    )
end

function _de_time(t)
    if t isa TracedRNumber{Float64}
        op = _hlo.reshape(t.mlir_data; result_0 = _de_ty(1), location = _de_loc())
        return _DEVal(_de_res(op), 1)
    end
    return _de_refuse_at(
        "the right-hand side", "a time argument of type $(typeof(t))",
        "`t` must be traced so the program can be stepped without recompiling; " *
            "pass a `ConcreteRNumber{Float64}`."
    )
end

# ---- the walk ---------------------------------------------------------------
#
# ONE emitting walk over `_Node`s for two surfaces: the scalar spine (a state
# equation or an observed fill entry, one value) and an access kernel (whole
# lanes). A FRAME says which surface is running and supplies what differs: the
# CSE reads, the leaves only that surface has, and the views the count and the
# computed-subscript const read need. Every shared arm — the host fold,
# literals, parameters, time, the seeded contraction fold, the comparison count,
# the computed-subscript const read, the literal-exponent power, the operator
# table — is written once here.
#
# The lane-batched surface (batch.jl) walks a different node type
# (`_OopBatchNode`, whose literals and loop counters vary per lane) and
# recognises neither the count nor the computed-subscript read, so it keeps its
# own walk; it shares the fold, the operator table and the host const-fold's
# operator set.

abstract type _DEFrame end

# ONE VALUE PER NODE. A walked tree is a DAG: a node is referenced from several
# places, and the references nest (a template call's body reads its argument
# more than once, and `_de_inline_call` puts the caller's argument node at each
# read), so a walk that emits every reference emits the unfolded tree,
# exponential in the nesting. A frame's `memo` maps an interior node to the
# value already emitted for it in this frame, and the walk reuses it.
#
# Why that cannot change a value: within one frame the walk is a pure function
# of the node. A kernel frame's descriptors, lane plan and CSE tiers are fixed
# for the kernel's run (a tier slot is read only after it is filled, and is
# filled once), and a scalar frame's prelude likewise. The one exception is a
# loop counter, which an unrolled contraction loop rebinds per iteration: its
# body is walked in a frame with no memo (`_de_unmemoized`). Every emitted value
# lives in the one block the walk emits into, so a reused value dominates its
# later uses.
const _DEMemo = Union{Nothing, _E._NodeMap{_DEVal}}

# The scalar spine: `cache` is the CSE prelude.
struct _DEScalarFrame <: _DEFrame
    cache::Vector{_DEVal}
    memo::_DEMemo
end

# One access kernel `K` under its lane plan, with its CSE tiers.
struct _DEKernelFrame <: _DEFrame
    K::_E._AccKernel
    plan::_E._OopAccPlan
    inv::Vector{_DEVal}
    cell::Vector{_DEVal}
    memo::_DEMemo
end

_de_unmemoized(fr::_DEScalarFrame) = _DEScalarFrame(fr.cache, nothing)
_de_unmemoized(fr::_DEKernelFrame) = _DEKernelFrame(fr.K, fr.plan, fr.inv, fr.cell, nothing)

# A call target is host data: the emitter inlines its body at emission, and it
# holds nothing to trace. Its body's argument nodes refer back to it, a cycle
# the tracer's modes that do not consult `seen` would follow without end, so
# tracing stops at it, as it does at a `Module`.
function Reactant.make_tracer(
        seen, @nospecialize(prev::_E._CallTarget), @nospecialize(path), mode; kwargs...
    )
    if mode == Reactant.TracedToTypes
        push!(path, prev)
        return nothing
    end
    return prev
end

_de_scalar(ctx::_DECtx, nd::_E._Node, cache::Vector{_DEVal})::_DEVal =
    _de_walk(ctx, _DEScalarFrame(cache, _E._NodeMap{_DEVal}()), nd)

# The frame's views for the count recognisers and the computed-subscript read.
_de_keyval(ctx::_DECtx, ::_DEScalarFrame, x::_E._Node) = _de_scalar_keyval(ctx, x)
_de_keyval(ctx::_DECtx, fr::_DEKernelFrame, x::_E._Node) = _de_acck_keyval(ctx, x, fr.K, fr.plan)
_de_same(::_DEScalarFrame, a::_E._Node, b::_E._Node) = _de_same_node(a, b)
_de_same(fr::_DEKernelFrame, a::_E._Node, b::_E._Node) = _de_acck_same(a, b, fr.K, fr.plan)
_de_resolve(::_DEScalarFrame, x::_E._Node) = x
_de_resolve(fr::_DEKernelFrame, x::_E._Node) = _de_acck_term(x, fr.K)
_de_cached_term(::_DEScalarFrame, ::_E._Node) = nothing
_de_cached_term(fr::_DEKernelFrame, x::_E._Node) = _de_acck_cached(x, fr.K)

# A CSE read.
_de_cached(::_DECtx, fr::_DEScalarFrame, nd::_E._Node) = fr.cache[nd.idx]
_de_cached(::_DECtx, fr::_DEKernelFrame, nd::_E._Node) =
    nd.payload === fr.K.cse.scratch ? fr.cell[nd.idx] : fr.inv[nd.idx]

function _de_count(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)
    ctx.precision === Float64 || return nothing
    return _de_count_unrolled(
        nd, x -> _de_keyval(ctx, fr, x), (a, b) -> _de_same(fr, a, b),
        x -> _de_resolve(fr, x)
    )
end

function _de_walk(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)::_DEVal
    memo = fr.memo
    (memo === nothing || isempty(nd.children)) && return _de_walk_node(ctx, fr, nd)
    hit = get(memo, nd, nothing)
    hit === nothing || return hit
    v = _de_walk_node(ctx, fr, nd)
    memo[nd] = v
    return v
end

function _de_walk_node(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)::_DEVal
    folded = _de_try_fold(ctx, nd)
    folded === nothing || return folded
    k = nd.kind
    if k === _E._NK_LITERAL
        return _de_const(ctx, nd.literal)
    elseif k === _E._NK_PARAM
        return _de_param(ctx, nd)
    elseif k === _E._NK_TIME
        return ctx.t
    elseif k === _E._NK_CACHED
        return _de_cached(ctx, fr, nd)
    elseif k === _E._NK_CONTRACTION
        cnt = _de_count(ctx, fr, nd)
        cnt === nothing ||
            return _de_emit_count(ctx, cnt, _de_walk(ctx, fr, cnt.query))
        terms = _DEVal[_de_walk(ctx, fr, ch) for ch in nd.children]
        return _de_fold_terms(ctx, nd.op, nd.literal, terms)
    elseif k === _E._NK_OP
        if nd.op === :+
            cnt = _de_count(ctx, fr, nd)
            cnt === nothing ||
                return _de_emit_count(ctx, cnt, _de_walk(ctx, fr, cnt.query))
        end
        _de_is_cgather(nd) && return _de_cgather(
            ctx, nd, ch -> _de_walk(ctx, fr, ch), x -> _de_cached_term(fr, x)
        )
        exact = _de_exact_compare(ctx, nd)
        exact === nothing || return exact
        if (nd.op === :^ || nd.op === :pow) && length(nd.children) == 2 &&
                nd.children[2].kind === _E._NK_LITERAL
            base = _de_walk(ctx, fr, nd.children[1])
            return _de_bin(ctx, _hlo.power, base, _de_const(ctx, nd.children[2].literal))
        end
        c = _DEVal[_de_walk(ctx, fr, ch) for ch in nd.children]
        return _de_op(ctx, nd, c)
    elseif k === _E._NK_CALL
        # A template call: its body with the call's arguments in place,
        # walked in this frame (`_de_inline_call`).
        return _de_walk(ctx, fr, _de_inline_call(ctx, nd))
    end
    return _de_leaf(ctx, fr, nd)
end

# ---- the scalar spine's own leaves --------------------------------------------

function _de_leaf(ctx::_DECtx, fr::_DEScalarFrame, nd::_E._Node)::_DEVal
    k = nd.kind
    if k === _E._NK_STATE
        return _de_read(ctx, ctx.ue, nd.idx, :state)
    elseif k === _E._NK_CONTRACTION_LOOP
        return _de_contraction_loop(ctx, fr, nd)
    elseif k === _E._NK_LOOPVAR
        return _de_const(ctx, Float64(_de_counter(ctx, nd.payload::Base.RefValue{Int})))
    elseif k === _E._NK_CONST_GATHER
        # `_de_try_fold` has already taken every host-static read.
        return _de_cgather(ctx, nd, ch -> _de_walk(ctx, fr, ch), _ -> nothing)
    elseif k === _E._NK_STATE_GATHER
        sg = nd.payload::_E._StateGather
        slot = _E._state_gather_slot(
            sg, length(nd.children), d -> _de_index_int(ctx, nd.children[d])
        )
        slot == 0 && return _de_const(ctx, 0.0)                     # ghost cell
        return _de_read(ctx, ctx.ue, slot, :stategather)
    elseif k === _E._NK_PARAM_GATHER
        # Live forcing, read from the `buffers` ARGUMENT (never from the build's
        # captured host array — see `_de_buffer`).
        return _de_buffer_read(ctx, nd.payload::Vector{Float64}, nd.idx)
    elseif k === _E._NK_LIVE_GATHER
        # The same live read at an offset the subscripts give: they are loop
        # counters and literals, concrete here (a contraction loop is unrolled
        # at emission), so the offset is resolved on host as the walker does.
        cg = nd.payload::_E._ConstGatherArray
        off = _E._const_gather_offset(
            cg, length(nd.children), d -> _de_index_int(ctx, nd.children[d])
        )
        return _de_buffer_read(ctx, cg.flat, off)
    end
    return _de_refuse(
        ctx, "the scalar-spine node kind $(_de_kindname(k))",
        "no arm of the scalar walk lowers it."
    )
end

_de_kindname(k::UInt8) = _E._node_kind_name(k)

function _de_contraction_loop(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)::_DEVal
    cnt = ctx.precision === Float64 ? _de_count_loop(ctx, nd) : nothing
    cnt === nothing ||
        return _de_emit_count(ctx, cnt, _de_walk(ctx, fr, cnt.query))
    # Emission-time unroll of the static range, in the interpreter's
    # ascending order. A loop whose BODY is host data never gets here — it
    # folded above — and a long one lands in `stablehlo.reduce` rather than a
    # chain of `range` binary ops (see `_de_fold_terms`).
    spec = nd.payload::_E._ContractLoop
    body = nd.children[1]
    terms = _DEVal[]
    bodyfr = _de_unmemoized(fr)              # the counter changes per iteration
    for kk in spec.lo:spec.step:spec.hi
        _de_set_counter!(ctx, spec.ref, kk)
        push!(terms, _de_walk(ctx, bodyfr, body))
    end
    return _de_fold_terms(ctx, nd.op, nd.literal, terms)
end

# ---- template calls ------------------------------------------------------------

# The body of the call `nd` (`_NK_CALL`, call.jl) with the call's arguments in
# place: each argument read (`_NK_ARG`) is the caller's argument node, and each
# read of an array argument (`_NK_ARG_GATHER`) is the gather of the array the
# call passes, a const array, a live
# forcing buffer or a state array. A call in the body passing on an array
# argument of this one passes the array itself. The interpreter evaluates the
# body as a pure function of the arguments, so the inlined body denotes the
# same values; a body is a DAG and stays one.
function _de_inline_call(ctx::Union{_DECtx, Nothing}, nd::_E._Node)::_E._Node
    site = nd.payload::_E._CallSite
    tg = site.target
    memo = _E._NodeMap{_E._Node}()
    function arr(j::Int)
        tg.baseidx[j] == 0 || _de_refuse(
            ctx, "a template call passing a block array",
            "a block array's base is a run-time argument; its read has no direct lowering yet."
        )
        return site.arrays[tg.passed[j]]
    end
    function sub(x::_E._Node)::_E._Node
        got = get(memo, x, nothing)
        got === nothing || return got
        k = x.kind
        r = if k === _E._NK_ARG
            x.payload === tg || _de_refuse(
                ctx, "an argument read of another call in a template call's body",
                "a body reads only its own arguments."
            )
            nd.children[x.idx]
        elseif k === _E._NK_ARG_GATHER
            ref = x.payload::_E._ArgGatherRef
            ref.target === tg || _de_refuse(
                ctx, "an array argument read of another call in a template call's body",
                "a body reads only its own arguments."
            )
            a = arr(ref.j)
            ch = _E._Node[sub(c) for c in x.children]
            if a.kind === :const
                _E._mknode(kind = _E._NK_CONST_GATHER, payload = a.data::_E._ConstGatherArray, children = ch)
            elseif a.kind === :live
                _E._mknode(kind = _E._NK_LIVE_GATHER, payload = a.data::_E._ConstGatherArray, children = ch)
            elseif a.kind === :state
                _E._mknode(kind = _E._NK_STATE_GATHER, payload = a.data::_E._StateGather, children = ch)
            else
                _de_refuse(
                    ctx, "a template call passing a $(a.kind) array",
                    "no arm of the direct walk reads it."
                )
            end
        elseif k === _E._NK_CALL
            s2 = x.payload::_E._CallSite
            arrays = _E._ArrArg[
                (a.data isa _E._FwdArr && (a.data::_E._FwdArr).target === tg) ?
                    arr((a.data::_E._FwdArr).j) : a for a in s2.arrays
            ]
            _E._mknode(
                kind = k, op = x.op, payload = _E._CallSite(s2.target, arrays),
                children = _E._Node[sub(c) for c in x.children]
            )
        elseif isempty(x.children)
            x
        else
            _E._Node(x.kind, x.op, x.literal, x.idx, x.sym, x.payload, _E._Node[sub(c) for c in x.children])
        end
        memo[x] = r
        return r
    end
    return sub(tg.body)
end

# ---- access kernels ----------------------------------------------------------

# ---- an access kernel's own leaves -------------------------------------------

function _de_leaf(ctx::_DECtx, fr::_DEKernelFrame, nd::_E._Node)::_DEVal
    K = fr.K; plan = fr.plan
    k = nd.kind
    if k === _E._NK_ACCESS
        a = K.acc[nd.idx]
        ak = a.kind
        if ak === _E._AK_STATE_AFFINE
            return _de_gather(ctx, ctx.ue, plan.gathers[nd.idx])
        elseif ak === _E._AK_STATE_TBL_BOX
            g = _de_gather(ctx, ctx.ue, plan.gathers[nd.idx])
            m = plan.ghost[nd.idx]
            isempty(m) && return g
            return _de_select(ctx, _de_boolconst(ctx, m), g.len, _de_const(ctx, 0.0), g)
        elseif ak === _E._AK_STATE_FIXED
            return _de_read(ctx, ctx.ue, a.idx, :akfixed)
        elseif ak === _E._AK_ARR_FIXED
            # LIVE forcing, invariant slot: one element of a program input.
            return _de_buffer_read(ctx, a.arr, a.idx; why = :akarrfixed)
        elseif ak === _E._AK_FORCING_BOX || ak === _E._AK_ARR_TBL_BOX
            # LIVE forcing lanes: one read of a program input at host-frozen
            # indices — slices plus a concatenate, or one gather.
            return _de_buffer_read(ctx, a.arr, plan.forc[nd.idx])
        else
            # CONST_BOX / LOOP_IDX: frozen lane data, one interned array constant.
            return _de_arrconst(ctx, plan.consts[nd.idx])
        end
    elseif k === _E._NK_CONTRACTION_LOOP
        # From a template call's body inlined here (`_de_inline_call`).
        return _de_contraction_loop(ctx, fr, nd)
    elseif k === _E._NK_CONST_GATHER
        # A const array a template call passes, read in its inlined body; a
        # host-static read has folded above.
        return _de_cgather(ctx, nd, ch -> _de_walk(ctx, fr, ch), _ -> nothing)
    elseif k === _E._NK_LOOPVAR
        return _de_const(ctx, Float64(_de_counter(ctx, nd.payload::Base.RefValue{Int})))
    end
    return _de_refuse(
        ctx, "the access-kernel node kind $(_de_kindname(k))",
        "no arm of the access-kernel walk lowers it."
    )
end

# One vectorized kernel: this kernel's own CSE tiers (invariant, then per-cell)
# in slot order, the spine over whole lanes, and ONE write into the target slot
# map.
function _de_run_kernel!(
        ctx::_DECtx, out::_DEMap, K::_E._AccKernel,
        plan::_E._OopAccPlan
    )
    plan.vectorizable ||
        _de_refuse(
        ctx,
        "a per-cell fallback access kernel",
        "its lane plan is not vectorizable, so the interpreter runs it one " *
            "cell at a time. A compiled program cannot: the emitted graph would " *
            "grow with the grid. Find what made `_build_oop_acc_plan` decline " *
            "(an unsupported descriptor kind or an unbounded reduce) and lower " *
            "that instead."
    )
    isempty(plan.out_slots) && return nothing
    cse = K.cse
    invvals = Vector{_DEVal}(undef, length(cse.inv_recipes))
    cellvals = Vector{_DEVal}(undef, length(cse.recipes))
    # One frame, and so one memo, for the kernel's whole run.
    fr = _DEKernelFrame(K, plan, invvals, cellvals, _E._NodeMap{_DEVal}())
    for i in eachindex(cse.inv_recipes)
        invvals[i] = _de_walk(ctx, fr, cse.inv_recipes[i])
    end
    for i in eachindex(cse.recipes)
        cellvals[i] = _de_walk(ctx, fr, cse.recipes[i])
    end
    res = _de_walk(ctx, fr, K.spine)
    _de_tally!(ctx, :kernels)
    _de_write!(ctx, out, plan.out_slots, res)
    return nothing
end

# ---- prefix scans ------------------------------------------------------------
#
# Level-major: one whole LEVEL per step, so the emitted program is O(scan length)
# and independent of the number of lanes at each level.
function _de_scan!(ctx::_DECtx, m::_DEMap, S::_E._ScanFold)
    len = S.len
    len >= 1 || return nothing
    nl = div(length(S.slots), len)
    f = _de_semiring_fn(ctx, S.oplus)
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

# The static write plan, computed BEFORE the walk over exactly the plan data the
# walk consumes (see `_DEMap`): which SECTION of this emission first writes each
# slot of the extended state and of `du`. A read of a slot no section writes —
# or one only this same section writes — takes the zero the interpreter's freshly
# allocated extended vector supplies there; a read of a slot a LATER section
# writes is a mis-ordered level plan, and that is what the emitter still refuses.
function _de_plan_writes!(ctx::_DECtx, rhs, du::_DEMap)
    ue = ctx.ue
    mat = rhs.mat_levels
    nlev = length(mat)
    sections = Vector{String}(undef, nlev + 1)
    for (li, lvl) in enumerate(mat)
        sections[li] = "materialization level $li"
        scalars, kernels = _E._mat_scalars(lvl), _E._mat_kernels(lvl)
        plans, scans = _E._mat_plans(lvl), _E._mat_scans(lvl)
        sec = Int32(li)
        for (slot, _) in scalars
            _de_mark!(ue, (slot,), sec)
        end
        for j in eachindex(kernels)
            _de_mark!(ue, plans[j].out_slots, sec)
        end
        for S in scans
            _de_mark!(ue, (S::_E._ScanFold).slots, sec)
        end
    end
    sections[nlev + 1] = "the state-equation section"
    sec = Int32(nlev + 1)
    for (slot, _) in rhs.rhs_list
        _de_mark!(du, (slot,), sec)
    end
    plans = rhs.acc_plans
    for j in eachindex(plans)
        _de_mark!(du, plans[j].out_slots, sec)
    end
    for S in rhs.scan_folds
        _de_mark!(du, (S::_E._ScanFold).slots, sec)
    end
    ctx.sections = sections
    return nothing
end

function _de_emit!(ctx::_DECtx, rhs)::_DEMap
    n_states = ctx.n_states
    # Whole-array einsums are a SECTION of the in-place
    # RHS that this walk has no arm for. Left alone their output slots would
    # just assemble to zero — a silent wrong answer, which is the one thing this
    # emitter does not do. The list is empty on every model whose reductions
    # stay under the tier's floor, which is every model the backend has been run
    # on; say so rather than emit a program that is missing a section.
    let nac = length(rhs.array_contractions) +
            sum(length(_E._mat_contractions(lvl)) for lvl in rhs.mat_levels; init = 0)
        nac == 0 ||
            _de_refuse(
            ctx,
            "$nac whole-array contraction(s)",
            "the array-contraction tier is a " *
                "section of the in-place RHS with no arm in this walk. " *
                "Emitting the rest would leave its output slots zero, so the " *
                "emission stops here."
        )
    end
    du = _DEMap(n_states)
    _de_plan_writes!(ctx, rhs, du)
    # Materialized observed levels, filled into the extended slot map.
    mat = rhs.mat_levels
    mat_batches = rhs.mat_batches
    for (li, lvl) in enumerate(mat)
        ctx.section = Int32(li)
        kernels, plans, scans = _E._mat_kernels(lvl), _E._mat_plans(lvl), _E._mat_scans(lvl)
        empty_cache = _DEVal[]
        _de_at!(ctx, :mat_scalar)
        _de_scalar_surface!(
            ctx, ctx.ue, mat_batches[li], empty_cache,
            "the observed fill at materialization level $li"
        )
        _de_at!(ctx, :mat_kernel)
        for j in eachindex(kernels)
            _de_rule!(
                ctx,
                "the observed fill kernel writing " *
                    "$(_de_slotsname(ctx, plans[j].out_slots)) " *
                    "(materialization level $li)"
            ) do
                _de_run_kernel!(ctx, ctx.ue, kernels[j], plans[j])
            end
        end
        _de_at!(ctx, :mat_scan)
        for S in scans
            _de_rule!(ctx, "a prefix scan at materialization level $li") do
                _de_scan!(ctx, ctx.ue, S)
            end
        end
    end
    # Everything from here on writes `du`, never `ue`: one section.
    ctx.section = Int32(length(mat) + 1)
    # CSE prelude.
    prelude = rhs.cse_prelude
    cache = Vector{_DEVal}(undef, length(prelude))
    _de_at!(ctx, :prelude)
    for s in eachindex(prelude)
        _de_rule!(ctx, "shared subexpression $s of the CSE prelude") do
            cache[s] = _de_scalar(ctx, prelude[s], cache)
        end
    end
    # State equations, through the LANE-BATCHED surface (batch.jl): the
    # leftover singles are the per-entry walk, each group is one whole-lane
    # emission whose varying state leaves are gathers rather than a
    # one-element slice per cell.
    _de_at!(ctx, :rhs_scalar)
    _de_scalar_surface!(
        ctx, du, rhs.rhs_batches, cache,
        "the state equation"
    )
    kernels = rhs.acc_kernels
    plans = rhs.acc_plans
    _de_at!(ctx, :kernel)
    for j in eachindex(kernels)
        _de_rule!(ctx, "the access kernel writing $(_de_slotsname(ctx, plans[j].out_slots))") do
            _de_run_kernel!(ctx, du, kernels[j], plans[j])
        end
    end
    _de_at!(ctx, :scan)
    for S in rhs.scan_folds
        _de_rule!(ctx, "a prefix scan over the state equations") do
            _de_scan!(ctx, du, S)
        end
    end
    _de_at!(ctx, :assemble)
    return du
end
