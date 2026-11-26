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
# operators, folds, counted loops, literal tables (`_NK_CONST_GATHER`), const
# array arguments (`_NK_ARG_GATHER` of a `:const` array, read as the inlined
# body reads it, the table living in the function), time, and further calls,
# which are functions too. A body that reads a state or live-forcing array
# argument, or a parameter outside a vector `p`, is placed inline instead:
# those reads resolve their subscripts on the host today, and a function
# argument is not host data. `_de_tally!(ctx, :call_inlined)` counts them.
# ========================================================================

# The template call whose body a context is emitting as a function: the
# target, the site (for its arrays), the argument values (block arguments) and
# the host intervals of the arguments a subscript reads (`_de_subrange`).
struct _DECallFrame
    target::_E._CallTarget
    site::_E._CallSite
    args::Vector{_DEVal}
    ranges::Vector{Union{Nothing, NTuple{2, Float64}}}
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
            a = site.arrays[site.target.passed[ref.j]]
            (site.target.baseidx[ref.j] == 0 && a.kind === :const) || (callable[] = false)
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
    args = _DEVal[_de_walk(ctx, fr, ch) for ch in nd.children]
    # An argument's interval matters only where a subscript can read it; it is
    # then part of the function's key, as the inlined body's subscripts are
    # checked against the caller's argument intervals.
    ranges = Union{Nothing, NTuple{2, Float64}}[
        info.subscripted ? _de_subrange(ctx, ch, x -> _de_cached_term(fr, x)) : nothing
            for ch in nd.children
    ]
    T = ctx.precision
    key = (site, ranges, T, ctx.tree_fold, info.uses_time)
    fn = get!(ctx.callfns, key) do
        _DECallFn(
            site, ranges, ctx.n_states, length(ctx.ue.m), T, ctx.tree_fold, ctx.opts,
            ctx.rule, info.uses_time, ctx.callfns
        )
    end::_DECallFn
    traced = Any[_de_traced(a, T) for a in args]
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
    length(xs) == nargs + fn.uses_time || _de_refuse_at(
        fn.rule, "a call of the template `$(tg.name)`",
        "it passes $(length(xs)) values for $(nargs) arguments."
    )
    args = _DEVal[_de_untraced(xs[i]) for i in 1:nargs]
    t = fn.uses_time ? _de_untraced(xs[end]) : _DEVal(_de_zero_time(T), 1)
    frame = _DECallFrame(tg, fn.site, args, fn.ranges)
    sub = _DECtx(
        fn.n_states, fn.n_total, nothing, t, nothing, (), Vector{Float64}[],
        Dict{Int, String}(), fn.opts; precision = T, tree_fold = fn.tree_fold,
        frame, callfns = fn.callfns
    )
    sub.rule = "the body of the template `$(tg.name)` ($(fn.rule))"
    out = _de_walk(sub, _DEScalarFrame(_DEVal[], _E._NodeMap{_DEVal}()), tg.body)
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

# `_NK_ARG_GATHER` of a `:const` array argument: the read the inlined body
# makes, a const gather at the body's own subscripts (`_de_body_info` admits
# no other array kind into a function).
function _de_arg_gather(ctx::_DECtx, fr::_DEFrame, nd::_E._Node)::_DEVal
    cf = ctx.frame::_DECallFrame
    ref = nd.payload::_E._ArgGatherRef
    a = cf.site.arrays[cf.target.passed[ref.j]]
    g = _E._mknode(
        kind = _E._NK_CONST_GATHER, payload = a.data::_E._ConstGatherArray,
        children = nd.children
    )
    return _de_walk(ctx, fr, g)
end

# The interval of argument `idx`, as the caller's subrange walk found it.
function _de_arg_range(ctx::_DECtx, nd::_E._Node)
    fr = ctx.frame
    fr isa _DECallFrame || return nothing
    return fr.ranges[nd.idx]
end
