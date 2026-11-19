# tree_walk/call.jl — a template reference compiled as a CALL (esm-spec §9.6.4
# rule 2; design: callnode-design.md).
#
# A reference is never expanded: its template body is compiled ONCE per
# instance into a `_CallTarget`, and each use is an `_NK_CALL` node whose
# children are the argument values, evaluated in the caller. Inside the body a
# parameter (declared, or implicit: a name the body reads from its caller,
# `_tpl_augment`) is an `_NK_ARG` leaf. The body reads its caller only through
# its arguments, so one compiled body serves every use with the same instance.
#
# Which references are calls is decided in one place, `_tpl_is_called`
# (templates/frames.jl).
#
# ARGUMENT FRAMES (the walkers). The arguments of a running call live on one
# argument stack per build (`_ArgStack`); a target's `fp` is the stack position
# of its innermost running call. A call evaluates all its arguments first
# (pushing each as it is computed, so an argument that itself calls something
# pushes above it), then moves its target's `fp`, runs the body, and restores
# both. The template graph is acyclic (esm-spec §9.7.3), so a body never calls
# its own target, and an `_NK_ARG` always reads its own call's frame. The
# walkers are single-threaded (threads run only emitted code, where arguments
# are function arguments), so one stack per build is race-free.
#
# VALUE TYPES. An argument keeps its own type: a literal argument is a
# `Float64` even under a ForwardDiff walk, exactly as the literal is where the
# expansion would have put it (the `^` arm relies on a literal exponent staying
# a `Float64`). The stack therefore holds a `Float64` buffer and, under AD, a
# buffer of the value type with a flag per position saying which one holds it.

mutable struct _ArgStack
    f64::Vector{Float64}
    alt::Any                    # Vector{T} for the AD value type, made on first use
    isalt::Vector{Bool}         # position holds a value of the AD type
    top::Int
end
_ArgStack() = _ArgStack(Float64[], nothing, Bool[], 0)

mutable struct _CallTarget
    name::String                # the template, for messages
    key::String                 # the instance key it was compiled for
    slots::Vector{String}       # the body's argument sentinels, in slot order
    body::_Node
    stack::_ArgStack
    fp::Int                     # stack position below the innermost running call's arguments
    nodes::Int                  # node count of `body` (emitter inline policy)
end

# The call targets of one build: the template table and the compiled targets
# by instance key. Held on the build state (`_BuildState.calls`).
struct _CallTable
    tt::_TplTable
    targets::Dict{String, _CallTarget}
    stack::_ArgStack
end
_CallTable(reg) = _CallTable(_TplTable(reg), Dict{String, _CallTarget}(), _ArgStack())

# The body compile's argument map (`_compile(::VarExpr)` reads it first).
struct _ArgMap
    target::_CallTarget
    idx::Dict{String, Int}
end

_call_table() = _build_state().calls

_no_call_table(name) = TreeWalkError(
    "E_TREEWALK_UNRESOLVED_TEMPLATE_REF",
    "template reference '$(name)' reached compile with no template registry in the build"
)

# ---- Compile -------------------------------------------------------------------

"""
    _compile_call(expr, var_map, param_syms, memo) -> _Node

The `_NK_CALL` of the reference `expr`: its target (compiled on first use) and
its arguments, compiled in the caller's context.
"""
function _compile_call(expr::OpExpr, var_map, param_syms, memo::_MaybeMemo)
    ct = _call_table()
    ct === nothing && throw(_no_call_table(expr.name))
    tg = _call_target(ct, expr)
    kids = _Node[_compile(a, var_map, param_syms, memo) for a in _call_args(tg, expr)]
    return _call_node(tg, kids)
end

# Any compiler of expressions to `_Node` (`_compile`, the setup geometry
# compiler) compiles a reference the same way: the target from `_call_target`,
# the arguments (`_call_args`, in slot order) compiled in its own context, and
# `_call_node`.
function _call_node(tg::_CallTarget, kids::Vector{_Node})
    _count!(:call_sites)
    return _mknode(kind = _NK_CALL, op = Symbol(tg.name), payload = tg, children = kids)
end

# The binding expression of each argument slot of `tg` at the reference `expr`.
function _call_args(tg::_CallTarget, expr::OpExpr)
    b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
    out = Vector{ASTExpr}(undef, length(tg.slots))
    for (i, s) in enumerate(tg.slots)
        out[i] = _call_arg(b, s)
    end
    return out
end

# The binding of argument sentinel `s` in the bindings `b` of a reference.
function _call_arg(b::AbstractDict, s::String)
    if startswith(s, _TPL_ARG)
        p = s[(ncodeunits(_TPL_ARG) + 1):end]
        v = get(b, p, nothing)
        v === nothing && throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "apply_expression_template missing binding for param '$p'"
            )
        )
        return v
    end
    # An implicit parameter the reference does not carry reads the caller's
    # name of the same spelling (`_tpl_frame`).
    v = get(b, s, nothing)
    return v === nothing ? VarExpr(s[(ncodeunits(_TPL_FREE) + 1):end]) : v
end

# The target of the reference `expr` in the open build.
function _call_target(expr::OpExpr)
    ct = _call_table()
    ct === nothing && throw(_no_call_table(expr.name))
    return _call_target(ct, expr)
end

# The target of reference `call`: one per template (scalar function templates
# have no structural parameter, so the template alone is the instance).
function _call_target(ct::_CallTable, call::OpExpr)
    name = String(call.name)
    key = name
    got = get(ct.targets, key, nothing)
    got === nothing || return got
    def = _tpl_def(ct.tt, name)
    closed = def.closed
    closed === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$name' has a parameter in a structural position; the build " *
                "does not compile it as a call yet"
        )
    )
    slots = String[_TPL_ARG * p for p in def.params]
    append!(slots, String[_TPL_FREE * n for n in closed.free])
    sort!(slots)
    tg = _CallTarget(name, key, slots, _mknode(kind = _NK_LITERAL), ct.stack, 0, 0)
    am = _ArgMap(tg, Dict{String, Int}(s => i for (i, s) in enumerate(slots)))
    st = _build_state()
    saved = st.argmap
    st.argmap = am
    body = try
        # The body binds nothing of the caller's: an empty state map and no
        # parameters. Every name it reads is an argument.
        _compile(closed.body, _EMPTY_VARMAP, Set{Symbol}(), _BuildMemo())
    finally
        st.argmap = saved
    end
    tg.body = body
    tg.nodes = _call_body_size(body)
    ct.targets[key] = tg
    _count!(:call_targets)
    return tg
end

const _EMPTY_VARMAP = Dict{String, Int}()

function _call_body_size(n::_Node)
    seen = _NodeIdMap{Nothing}()
    c = Ref(0)
    function walk(x)
        haskey(seen, x) && return
        seen[x] = nothing
        c[] += 1
        foreach(walk, x.children)
    end
    walk(n)
    return c[]
end

# The `_NK_ARG` leaf for `name` when a call body is being compiled and `name`
# is one of its argument sentinels; `nothing` otherwise.
@inline function _arg_leaf(name::String)
    am = _build_state().argmap
    am === nothing && return nothing
    i = get((am::_ArgMap).idx, name, 0)
    i == 0 && return nothing
    return _mknode(kind = _NK_ARG, idx = i, payload = (am::_ArgMap).target)
end

# ---- Walk ------------------------------------------------------------------------

@inline function _argstack_alt(st::_ArgStack, ::Type{T}) where {T}
    a = st.alt
    a isa Vector{T} && return a
    na = Vector{T}(undef, length(st.f64))
    st.alt = na
    return na
end

# Room for position `i` on the stack.
@noinline function _argstack_grow!(st::_ArgStack, i::Int)
    n = max(i, 2 * length(st.f64), 16)
    resize!(st.f64, n)
    resize!(st.isalt, n)
    st.alt === nothing || resize!(st.alt, n)
    return nothing
end

@inline function _argstack_push!(st::_ArgStack, i::Int, v::Float64, ::Type{T}) where {T}
    i > length(st.f64) && _argstack_grow!(st, i)
    @inbounds st.f64[i] = v
    @inbounds st.isalt[i] = false
    return nothing
end
@inline function _argstack_push!(st::_ArgStack, i::Int, v, ::Type{T}) where {T}
    i > length(st.f64) && _argstack_grow!(st, i)
    a = _argstack_alt(st, T)
    @inbounds a[i] = v
    @inbounds st.isalt[i] = true
    return nothing
end

@inline function _argstack_read(st::_ArgStack, i::Int, ::Type{Float64})
    return @inbounds st.f64[i]
end
@inline function _argstack_read(st::_ArgStack, i::Int, ::Type{T}) where {T}
    @inbounds st.isalt[i] || return @inbounds st.f64[i]
    return @inbounds (st.alt::Vector{T})[i]
end

# The call itself, given an evaluator `ev(child)` for the caller's context (the
# scalar walker or the access-kernel walker).
@inline function _run_call(ev::F, n::_Node, u, p, t, ::Type{T}) where {F, T}
    tg = n.payload::_CallTarget
    st = tg.stack
    base = st.top
    ch = n.children
    @inbounds for i in eachindex(ch)
        v = ev(ch[i])
        _argstack_push!(st, base + i, v, T)
        st.top = base + i
    end
    old = tg.fp
    tg.fp = base
    r = try
        _eval_node(tg.body, u, p, t, T)
    finally
        tg.fp = old
        st.top = base
    end
    return r
end

@inline _eval_arg(n::_Node, ::Type{T}) where {T} =
    (tg = n.payload::_CallTarget; _argstack_read(tg.stack, tg.fp + n.idx, T))

# ---- Generic IR helpers -------------------------------------------------------------
# A pass over the compiled form sees a call as an operator over its argument
# children; the body is reached once per target through `_ir_targets`.

_ir_is_call(n::_Node) = n.kind === _NK_CALL

# The targets reachable from `roots` (bodies included, each once), nested first.
function _ir_targets(roots)
    out = _CallTarget[]
    seen = IdDict{_CallTarget, Nothing}()
    nseen = _NodeIdMap{Nothing}()
    function walk(x::_Node)
        haskey(nseen, x) && return
        nseen[x] = nothing
        foreach(walk, x.children)
        if x.kind === _NK_CALL
            tg = x.payload::_CallTarget
            if !haskey(seen, tg)
                seen[tg] = nothing
                walk(tg.body)
                push!(out, tg)
            end
        end
    end
    for r in roots
        walk(r)
    end
    return out
end

# ---- Build-time evaluators ------------------------------------------------------------
# A build-time evaluator that meets a reference reads its body in the
# reference's frame (`_tpl_frame`): each argument is evaluated in the caller's
# environment and bound to its sentinel, then the body is evaluated with those
# bindings. Nothing is copied or substituted. `ev(e, env)` is the evaluator;
# an argument whose evaluation fails is left unbound, so the body fails only if
# it reads it, as the expansion would.
function _eval_through_call(ev::F, expr::OpExpr, env::Dict{String, V}) where {F, V}
    ct = _call_table()
    ct === nothing && throw(_no_call_table(expr.name))
    def = _tpl_def(ct.tt, expr.name)
    if def.closed === nothing
        # A parameter in a structural position: the instance's own prepared
        # body (one frame per instance, so per distinct structural value).
        fr = _tpl_frame(ct.tt, expr, nothing)
        body, slots, args = fr.body, collect(keys(fr.args)), s -> fr.args[s]
    else
        # The template's prepared body, with the reference's bindings as its
        # arguments. No frame: a build-time evaluator may run per cell, and a
        # frame per distinct argument value would be kept for the whole build.
        closed = def.closed::_TplClosed
        b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
        slots = String[_TPL_ARG * p for p in def.params]
        append!(slots, String[_TPL_FREE * n for n in closed.free])
        body = closed.body
        args = s -> _call_arg(b, s)
    end
    inner = Dict{String, V}()
    for s in slots
        try
            inner[s] = ev(args(s), env)
        catch err
            err isa TreeWalkError || rethrow()
        end
    end
    return ev(body, inner)
end

# ---- Operator predicates through a call ------------------------------------------------
# Whether any operator in the body of the reference `call` (transitively through
# nested references, each template once) satisfies `pred(op::String)`. A phase
# that asks "which operators does this expression use" asks it through here at
# a reference, never by expanding. With no template table in reach the answer
# is `true` (the conservative one for every caller: "some operator is outside
# what I handle").
function _call_body_any_op(pred, call::OpExpr)
    ct = _call_table()
    ct === nothing && return true
    memo = _tpl_memo(ct.tt, nothing, :body_ops, () -> Dict{String, Set{String}}())
    return any(pred, _call_body_ops!(memo, ct.tt, String(call.name)))
end

function _call_body_ops!(memo::Dict{String, Set{String}}, tt::_TplTable, name::String)
    got = get(memo, name, nothing)
    got === nothing || return got
    ops = Set{String}()
    memo[name] = ops
    def = _tpl_def(tt, name)
    body = def.closed === nothing ? nothing : def.closed.body
    body === nothing && (push!(ops, APPLY_EXPRESSION_TEMPLATE_OP); return ops)
    foreach_subexpr(body) do e
        e isa OpExpr || return
        if _tpl_is_call(e)
            union!(ops, _call_body_ops!(memo, tt, String(e.name)))
        else
            push!(ops, e.op)
        end
    end
    return ops
end

# `call` with a binding for each implicit parameter of its template
# (`"\0free\0n" => n`, as `_tpl_augment` writes them) that it does not carry
# yet; `call` itself when it carries them all or no template table is in reach.
function _call_with_implicit(call::OpExpr)
    ct = _call_table()
    ct === nothing && return call
    def = _tpl_def(ct.tt, call.name)
    free = def.closed === nothing ? _tpl_generic_free(ct.tt, def) : def.closed.free
    isempty(free) && return call
    b = call.bindings
    missing_any = b === nothing || any(n -> !haskey(b, _TPL_FREE * n), free)
    missing_any || return call
    nb = b === nothing ? Dict{String, ASTExpr}() : copy(b)
    for n in free
        k = _TPL_FREE * n
        haskey(nb, k) || (nb[k] = VarExpr(n))
    end
    return reconstruct(call; bindings = nb)
end
