# ========================================================================
# ext/reactant_direct/calls.jl — a template reference emitted as a CALL.
#
# A template instance (`_CallTarget`, src/tree_walk/call.jl) is compiled once
# into a body that reads its caller only through its arguments. Under
# `DirectEmitOptions(calls = :functions)` (the default) the emitter keeps that
# shape in StableHLO: the body is emitted ONCE as a private `func.func` per
# argument shape, and every use is a `func.call`. Under `calls = :inline` the
# body is placed at every use (`_de_inline_call`, emit.jl), the measurement
# baseline. XLA's own pipeline may inline the calls while it compiles; the
# emitted module keeps them.
#
# The arguments are emitted in the caller's frame and passed as rank-1
# tensors (a lane vector in an access kernel, length 1 on the scalar spine).
# The body is walked in a fresh context whose only traced values are the
# function's own block arguments, so nothing from the caller is captured.
# Reactant's `Ops.call` builds the function and caches it per compile by the
# callable (a host-only trace leaf, one per key here) and the argument types.
#
# WHAT A FUNCTION BODY READS. Its scalar arguments (`_NK_ARG`), literals,
# operators, folds, counted loops, literal tables (`_NK_CONST_GATHER`), time,
# further calls (functions too), and its array arguments:
#   * a `:const` array is read as the inlined body reads it, the table living
#     in the function (`_de_body_with_tables`);
#   * a `:state` array (a state or observed array of the extended state) and a
#     `:live` forcing buffer are passed as one more tensor argument each, and
#     the body reads them at traced subscripts (`_de_arg_gather`): a state read
#     outside the array's box is the ghost zero, a forcing read uses the
#     array's boundary policy as the const read does.
# What is still placed inline (`_de_tally!(ctx, :call_inlined)`): a body that
# reads a parameter, a block array (its base is a run-time argument), an array
# a calling body passes on, a windowed tile forcing buffer, or a state array
# some of whose slots a later emission section writes.
# ========================================================================

# The template call whose body a context is emitting as a function: the
# target, the site (for its arrays), the argument values (block arguments) and
# the host intervals of the arguments a subscript reads (`_de_subrange`).
struct _DECallFrame
    target::_E._CallTarget
    site::_E._CallSite
    args::Vector{_DEVal}
    ranges::Vector{Union{Nothing, NTuple{2, Float64}}}
    arrays::Vector{Union{Nothing, _DEVal}}   # per array slot: its tensor (`:state`, `:live`)
end

# What a function emission needs from the calling context, all host data.
struct _DECallFn <: Function
    site::_E._CallSite
    ranges::Vector{Union{Nothing, NTuple{2, Float64}}}
    n_states::Int
    n_total::Int
    precision::DataType
    tree_fold::Bool
    opts::DirectEmitOptions
    rule::String
    uses_time::Bool
    callfns::Dict{Any, Any}
    stats::Dict{Symbol, Int}
end

# Reactant names the emitted function after this printed form, so it is an
# identifier: the template's name with everything else replaced by `_`.
Base.show(io::IO, f::_DECallFn) =
    print(io, "esm_tpl_", replace(f.site.target.name, r"[^A-Za-z0-9_]" => "_"))

function Reactant.make_tracer(
        seen, @nospecialize(prev::_DECallFn), @nospecialize(path), mode; kwargs...
    )
    if mode == Reactant.TracedToTypes
        push!(path, prev)
        return nothing
    end
    return prev
end

# What a target's body (and the bodies it calls) reads, host data per target.
struct _DEBodyInfo
    callable::Bool      # every read has a function lowering (see the header)
    uses_time::Bool
    subscripted::Bool   # an argument can reach a gather subscript
end

const _DE_BODY_KINDS = (
    _E._NK_LITERAL, _E._NK_OP, _E._NK_CONTRACTION, _E._NK_CONTRACTION_LOOP,
    _E._NK_LOOPVAR, _E._NK_ARG, _E._NK_CONST_GATHER, _E._NK_TIME, _E._NK_CALL,
    _E._NK_ARG_GATHER,
)

function _de_body_info(ctx::_DECtx, site::_E._CallSite)::_DEBodyInfo
    key = (:bodyinfo, site)
    hit = get(ctx.callfns, key, nothing)
    hit === nothing || return hit::_DEBodyInfo
    callable = Ref(true)
    uses_time = Ref(false)
    subscripted = Ref(false)
    seen = Base.IdSet{_E._Node}()
    function visit(nd::_E._Node)
        nd in seen && return
        push!(seen, nd)
        k = nd.kind
        k in _DE_BODY_KINDS || (callable[] = false)
        k === _E._NK_TIME && (uses_time[] = true)
        if k === _E._NK_CONST_GATHER || k === _E._NK_ARG_GATHER
            subscripted[] = true
        end
        if k === _E._NK_ARG_GATHER
            ref = nd.payload::_E._ArgGatherRef
            # A block array passes no array (`passed` is 0): its read is the
            # inline path's, which refuses it by name.
            if site.target.baseidx[ref.j] != 0
                callable[] = false
            else
                a = site.arrays[site.target.passed[ref.j]]
                (!(a.data isa _E._FwdArr) && a.kind in (:const, :state, :live)) ||
                    (callable[] = false)
            end
        elseif k === _E._NK_CALL
            inner = nd.payload::_E._CallSite
            # A nested call passing on one of this body's arrays is placed
            # inline with it: the array is this call's, not the callee's.
            any(a -> a.data isa _E._FwdArr, inner.arrays) && (callable[] = false)
            sub = _de_body_info(ctx, inner)
            sub.callable || (callable[] = false)
            sub.uses_time && (uses_time[] = true)
            sub.subscripted && (subscripted[] = true)
        end
        foreach(visit, nd.children)
        return
    end
    visit(site.target.body)
    info = _DEBodyInfo(callable[], uses_time[], subscripted[])
    ctx.callfns[key] = info
    return info
end

# The `_NK_CALL` arm of the walk.
function _de_call(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)::_DEVal
    site = nd.payload::_E._CallSite
    info = ctx.opts.calls === :functions ? _de_body_info(ctx, site) : nothing
    if info === nothing || !info.callable
        info === nothing || _de_tally!(ctx, :call_inlined)
        return _de_walk(ctx, fr, _de_inline_call(ctx, nd))
    end
    arrays = _de_call_arrays(ctx, site)
    if arrays === nothing
        _de_tally!(ctx, :call_inlined)
        return _de_walk(ctx, fr, _de_inline_call(ctx, nd))
    end
    args = _DEVal[_de_walk(ctx, fr, ch) for ch in nd.children]
    # An argument's interval matters only where a subscript can read it; it is
    # then part of the function's key, as the inlined body's subscripts are
    # checked against the caller's argument intervals.
    ranges = Union{Nothing, NTuple{2, Float64}}[
        info.subscripted ? _de_subrange(ctx, ch, x -> _de_cached_term(fr, x)) : nothing
            for ch in nd.children
    ]
    T = ctx.precision
    # Sites that pass state or forcing arrays of one layout share a function
    # (the arrays are its arguments); a const table lives in the function, so
    # it is part of the key by identity.
    key = (site.target, _de_array_key(site), ranges, T, ctx.tree_fold, info.uses_time)
    fn = get!(ctx.callfns, key) do
        _DECallFn(
            site, ranges, ctx.n_states, length(ctx.ue.m), T, ctx.tree_fold, ctx.opts,
            ctx.rule, info.uses_time, ctx.callfns, ctx.stats
        )
    end::_DECallFn
    traced = Any[_de_traced(a, T) for a in args]
    for a in arrays
        a === nothing || push!(traced, _de_traced(a, T))
    end
    info.uses_time && push!(traced, _de_traced(ctx.t, T))
    _de_tally!(ctx, :call)
    return _de_untraced(Reactant.Ops.call(fn, traced...))
end

# The function body: runs inside `Ops.call`'s function, with every traced
# value one of its block arguments. `_de_call_body` is the walk's entry and is
# not rewritten by Reactant's interpreter (device.jl `_de_skip_rewrite!`).
(fn::_DECallFn)(xs::TracedRArray...) = _de_call_body(fn, xs...)

function _de_call_body(fn::_DECallFn, xs::TracedRArray...)
    tg = fn.site.target
    T = fn.precision
    nargs = length(tg.slots)
    kinds = _de_passed_kinds(fn.site)
    narr = count(k -> k === :state || k === :live, kinds)
    length(xs) == nargs + narr + fn.uses_time || _de_refuse_at(
        fn.rule, "a call of the template `$(tg.name)`",
        "it passes $(length(xs)) values for $(nargs) arguments and $(narr) arrays."
    )
    args = _DEVal[_de_untraced(xs[i]) for i in 1:nargs]
    arrays = Union{Nothing, _DEVal}[nothing for _ in kinds]
    k = nargs
    for j in eachindex(kinds)
        (kinds[j] === :state || kinds[j] === :live) || continue
        arrays[j] = _de_untraced(xs[k += 1])
    end
    t = fn.uses_time ? _de_untraced(xs[end]) : _DEVal(_de_zero_time(T), 1)
    frame = _DECallFrame(tg, fn.site, args, fn.ranges, arrays)
    sub = _DECtx(
        fn.n_states, fn.n_total, nothing, t, nothing, (), Vector{Float64}[],
        Dict{Int, String}(), fn.opts; precision = T, tree_fold = fn.tree_fold,
        frame, callfns = fn.callfns
    )
    sub.rule = "the body of the template `$(tg.name)` ($(fn.rule))"
    sub.stats = fn.stats            # the emission's tallies, not a function's own
    body = _de_body_with_tables(fn.callfns, fn.site)
    out = _de_walk(sub, _DEScalarFrame(_DEVal[], _E._NodeMap{_DEVal}()), body)
    return _de_traced(out, T)
end

_de_zero_time(T) = _de_res(
    _hlo.constant(;
        output = _de_ty(1, T), value = _MLIR.IR.DenseElementsAttribute([zero(T)]),
        location = _de_loc()
    )
)

# `_NK_ARG`: argument `idx` of the running call.
function _de_arg(ctx::_DECtx, nd::_E._Node)::_DEVal
    fr = ctx.frame
    (fr isa _DECallFrame && nd.payload === fr.target) || _de_refuse(
        ctx, "an argument read outside its template's body",
        "a body reads only its own arguments."
    )
    return fr.args[nd.idx]
end

# `_NK_ARG_GATHER`: a read of array argument `j` at traced subscripts. A
# `:const` array was substituted before the walk (`_de_body_with_tables`); a
# `:state` or `:live` array is the tensor the call passed.
function _de_arg_gather(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)::_DEVal
    cf = ctx.frame::_DECallFrame
    ref = nd.payload::_E._ArgGatherRef
    a = cf.site.arrays[cf.target.passed[ref.j]]
    src = cf.arrays[ref.j]
    if a.kind === :const || src === nothing
        g = _E._mknode(
            kind = _E._NK_CONST_GATHER, payload = a.data::_E._ConstGatherArray,
            children = nd.children
        )
        return _de_walk(ctx, fr, g)
    elseif a.kind === :state
        sg = a.data::_E._StateGather
        subs = _DEVal[_de_un(ctx, _hlo.round_nearest_even, _de_walk(ctx, fr, ch)) for ch in nd.children]
        L = maximum(x -> x.len, subs)
        lanes = map(x -> _de_traced(_de_cast(_de_bcast(ctx, x, L), ctx.precision, Float64)), subs)
        _de_tally!(ctx, :state_gather_traced)
        return _de_untraced(
            Reactant.call_with_reactant(
                _de_sg_take, _de_traced(src, ctx.precision), Tuple(sg.lo), Tuple(sg.hi),
                Tuple(sg.strides), lanes...
            )
        )
    end
    g = _E._mknode(kind = _E._NK_LIVE_GATHER, payload = a.data::_E._ConstGatherArray, children = nd.children)
    return _de_cgather(ctx, g, ch -> _de_walk(ctx, fr, ch), x -> _de_cached_term(fr, x); src)
end

# A state array read at rounded traced subscripts: the element at
# `1 + Σ (s_d - lo_d) * stride_d` of the array's tensor (its slots in offset
# order), or the ghost zero where a subscript leaves `[lo_d, hi_d]`
# (`_state_gather_slot`).
function _de_sg_take(src::TracedRArray{T, 1}, lo, hi, strides, subs::TracedRArray{Float64, 1}...) where {T}
    O = Reactant.Ops
    n = length(subs[1])
    int(x) = O.fill(Int64(x), [n])
    inside = nothing
    lin = int(1)
    for d in eachindex(subs)
        s = _rx_int(subs[d])
        ok = O.and(
            O.compare(s, int(lo[d]); comparison_direction = "GE"),
            O.compare(s, int(hi[d]); comparison_direction = "LE")
        )
        inside = inside === nothing ? ok : O.and(inside, ok)
        lin = O.add(lin, O.multiply(O.subtract(s, int(lo[d])), int(strides[d])))
    end
    lin = O.clamp(int(1), lin, int(length(src)))
    v = O.gather_getindex(src, O.reshape(lin, n, 1))
    return O.select(inside, v, O.fill(zero(T), [n]))
end

# Which array slots of `site`'s target are passed as tensors.
_de_passed_kinds(site::_E._CallSite) = Symbol[
    site.target.baseidx[j] == 0 && !(site.arrays[site.target.passed[j]].data isa _E._FwdArr) ?
        site.arrays[site.target.passed[j]].kind : :block
        for j in eachindex(site.target.passed)
]

# The tensors a call passes for its `:state` and `:live` array arguments, in
# array-slot order (`nothing` for the others), or `nothing` when one of them
# cannot be passed whole: a windowed tile forcing buffer, or a state array with
# a slot a later emission section writes (the inlined body reads only the
# slots it needs, so it may still be emitted).
function _de_call_arrays(ctx::_DECtx, site::_E._CallSite)
    kinds = _de_passed_kinds(site)
    out = Union{Nothing, _DEVal}[nothing for _ in kinds]
    for j in eachindex(kinds)
        a = site.arrays[site.target.passed[j]]
        if kinds[j] === :state
            sg = a.data::_E._StateGather
            ue = ctx.ue
            srcs = Vector{_DESlot}(undef, sg.len)
            for off in 0:(sg.len - 1)
                s = _E._sg_slot(sg, off)
                if s == 0
                    srcs[off + 1] = nothing
                    continue
                end
                (1 <= s <= length(ue.m)) || return nothing
                e = ue.m[s]
                e === nothing && ue.writer[s] > ctx.section && return nothing
                srcs[off + 1] = e
            end
            out[j] = _de_emit_runs(ctx, srcs)
        elseif kinds[j] === :live
            cg = a.data::_E._ConstGatherArray
            jb = findfirst(x -> x === cg.flat, ctx.hostkeys)
            jb === nothing && return nothing
            val = _de_buffer_read(ctx, cg.flat, collect(1:length(cg.flat)); why = :call_array)
            val.len == length(cg.flat) || return nothing
            out[j] = val
        end
    end
    return out
end

# The interval of argument `idx`, as the caller's subrange walk found it.
function _de_arg_range(ctx::_DECtx, nd::_E._Node)
    fr = ctx.frame
    fr isa _DECallFrame || return nothing
    return fr.ranges[nd.idx]
end

# The target's body with each read of a `:const` array argument replaced by the
# const read of the array this site passes, as the inlined body has it, so the
# host analyses (folding, the comparison count, subscript intervals) see the
# table. Scalar arguments stay arguments and calls stay calls. Once per site.
function _de_body_with_tables(callfns::Dict{Any, Any}, site::_E._CallSite)::_E._Node
    key = (:tables, site)
    hit = get(callfns, key, nothing)
    hit === nothing || return hit::_E._Node
    tg = site.target
    memo = _E._NodeMap{_E._Node}()
    function sub(x::_E._Node)::_E._Node
        got = get(memo, x, nothing)
        got === nothing || return got
        isempty(x.children) && x.kind !== _E._NK_ARG_GATHER && return x
        ch = _E._Node[sub(c) for c in x.children]
        a = x.kind === _E._NK_ARG_GATHER && (x.payload::_E._ArgGatherRef).target === tg ?
            site.arrays[tg.passed[(x.payload::_E._ArgGatherRef).j]] : nothing
        r = if a !== nothing && a.kind === :const
            _E._mknode(kind = _E._NK_CONST_GATHER, payload = a.data::_E._ConstGatherArray, children = ch)
        elseif all(i -> ch[i] === x.children[i], eachindex(ch))
            x
        else
            _E._Node(x.kind, x.op, x.literal, x.idx, x.sym, x.payload, ch)
        end
        memo[x] = r
        return r
    end
    body = sub(tg.body)
    callfns[key] = body
    return body
end

# The layout of each array a site passes, for the function key.
function _de_array_key(site::_E._CallSite)
    return Tuple(
        begin
            a = site.arrays[site.target.passed[j]]
            if a.kind === :state && site.target.baseidx[j] == 0
                sg = a.data::_E._StateGather
                (:state, Tuple(sg.lo), Tuple(sg.hi), Tuple(sg.strides), sg.len)
            elseif a.kind === :live
                cg = a.data::_E._ConstGatherArray
                (:live, Tuple(cg.dims), Tuple(cg.strides), Tuple(cg.boundary))
            else
                (a.kind, objectid(a.data))
            end
        end for j in eachindex(site.target.passed)
    )
end
