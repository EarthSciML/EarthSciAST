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

# An ARRAY argument (frames.jl `_TplCallInfo.arrays`): the array a reference
# binds to an array parameter, passed at run time. `data` is the same payload
# the build's own gathers read (`_StateGather` for `:state`,
# `_ConstGatherArray` for `:const` and `:live`), so a read through the argument
# is the gather the expansion would have compiled, bit for bit.
struct _ArrArg
    kind::Symbol
    data::Any
    name::String
end

mutable struct _CallTarget
    name::String                # the template, for messages
    key::String                 # the instance key it was compiled for
    slots::Vector{String}       # the body's scalar argument sentinels, in slot order
    arrslots::Vector{String}    # the body's array argument sentinels, in slot order
    arrkinds::Vector{Symbol}    # each array slot's kind (part of `key`)
    arrdims::Vector{Vector{Int}} # each const or live array slot's dimensions (part of `key`)
    body::_Node
    stack::_ArgStack
    fp::Int                     # stack position below the innermost running call's arguments
    nodes::Int                  # node count of `body` (emitter inline policy)
    curarrs::Vector{_ArrArg}    # the array arguments of the innermost running call
end

# One call site's payload: the target and the arrays this site passes. Sites
# with the same target and the same arrays are one object (`_call_site`), so
# passes that key a call by its payload treat them alike.
struct _CallSite
    target::_CallTarget
    arrays::Vector{_ArrArg}
end

# The array-gather read of a body (`_NK_ARG_GATHER`): array slot `j` of `target`.
struct _ArgGatherRef
    target::_CallTarget
    j::Int
end

# The call targets of one build: the template table and the compiled targets
# by instance key. Held on the build state (`_BuildState.calls`).
struct _CallTable
    tt::_TplTable
    targets::Dict{String, _CallTarget}
    stack::_ArgStack
    sites::Dict{Tuple{_CallTarget, Vector{UInt}}, _CallSite}
    # The count tables built from array arguments, by (array, lo, hi): one
    # object per table for the build (codegen_kernel.jl `_cg_site_count_tables`).
    ctabs::Dict{Tuple{UInt, Int, Int}, Any}
end
_CallTable(reg) = _CallTable(
    _TplTable(reg), Dict{String, _CallTarget}(), _ArgStack(),
    Dict{Tuple{_CallTarget, Vector{UInt}}, _CallSite}(), Dict{Tuple{UInt, Int, Int}, Any}()
)

# The body compile's argument map (`_compile(::VarExpr)` reads `idx`, the
# resolve of `index(<array sentinel>, …)` reads `arr`).
struct _ArgMap
    target::_CallTarget
    idx::Dict{String, Int}
    arr::Dict{String, Int}
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
    return _call_node(tg, kids, _call_arrays(tg, expr))
end

# Any compiler of expressions to `_Node` (`_compile`, the setup geometry
# compiler) compiles a reference the same way: the target from `_call_target`,
# the arguments (`_call_args`, in slot order) compiled in its own context, the
# arrays (`_call_arrays`), and `_call_node`.
function _call_node(tg::_CallTarget, kids::Vector{_Node}, arrs::Vector{_ArrArg} = _ArrArg[])
    length(arrs) == length(tg.arrslots) || throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$(tg.name)': a call site passes $(length(arrs)) of its $(length(tg.arrslots)) array arguments"
        )
    )
    _count!(:call_sites)
    return _mknode(kind = _NK_CALL, op = Symbol(tg.name), payload = _call_site(tg, arrs), children = kids)
end

# The one `_CallSite` of `tg` passing `arrs`.
function _call_site(tg::_CallTarget, arrs::Vector{_ArrArg})
    ct = _call_table()
    ct === nothing && return _CallSite(tg, arrs)
    key = (tg, UInt[objectid(a.data) for a in arrs])
    return get!(() -> _CallSite(tg, arrs), (ct::_CallTable).sites, key)
end

# The array each array slot of `tg` reads at the reference `expr`: its binding
# as the resolve left it (`_resolve_call_bindings` turns an array binding into
# an `__arrarg` marker carrying the `_ArrArg`).
function _call_arrays(tg::_CallTarget, expr::OpExpr)
    isempty(tg.arrslots) && return _ArrArg[]
    b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
    out = Vector{_ArrArg}(undef, length(tg.arrslots))
    for (j, s) in enumerate(tg.arrslots)
        v = _call_arg(b, s)
        (v isa OpExpr && v.op == "__arrarg" && v.value isa _ArrArg) || throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "template '$(tg.name)': the array argument $(repr(s)) reached compile " *
                    "unresolved"
            )
        )
        a = v.value::_ArrArg
        a.kind === tg.arrkinds[j] || throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "template '$(tg.name)': array argument $(repr(s)) is a $(a.kind) array, " *
                    "the target was compiled for a $(tg.arrkinds[j]) array"
            )
        )
        out[j] = a
    end
    return out
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

# The fixed parameters of a reference (`info.fixed`: reduction or output range
# bounds) with their integer literal values, into `S`.
function _call_fixed!(S::Dict{String, Any}, name, info::_TplCallInfo, b::AbstractDict)
    for s in info.fixed
        p = s[(ncodeunits(_TPL_ARG) + 1):end]
        v = _call_arg(b, s)
        iv = v isa IntExpr ? Int(v.value) : v isa NumExpr && isinteger(v.value) ? Int(v.value) :
            throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "template '$name': parameter '$p' bounds a range and needs an integer literal"
            )
        )
        S[p] = iv
    end
    return S
end

# The target of reference `call`: one per INSTANCE, keyed by the template,
# the value of each fixed parameter (a reduction bound, substituted into the
# instance's body), and the kind of each array argument. Arrays themselves are
# run-time data (`_CallSite`), so every array of one kind shares the target.
function _call_target(ct::_CallTable, call::OpExpr)
    name = String(call.name)
    def = _tpl_def(ct.tt, name)
    def.closed === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNSUPPORTED_OP",
            "template '$name' has a parameter in a structural position; the build " *
                "does not compile it as a call yet"
        )
    )
    info = _tpl_call_info(ct.tt, name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = Dict{String, Any}()
    arrkind = Dict{String, Symbol}()
    arrdims = Dict{String, Vector{Int}}()
    io = IOBuffer()
    print(io, name)
    if info !== nothing
        _call_fixed!(S, name, info, b)
        for p in sort!(collect(keys(S)))
            print(io, '\x01', p, '=', S[p])
        end
        for s in sort!(collect(info.arrays))
            v = _call_arg(b, s)
            k = (v isa OpExpr && v.value isa _ArrArg) ? (v.value::_ArrArg).kind : :unresolved
            arrkind[s] = k
            print(io, '\x02', s, '=', k)
            # A const or live array's dimensions are part of the instance:
            # a subscript the body proves inside them reads directly.
            if k === :const || k === :live
                d = ((v.value::_ArrArg).data::_ConstGatherArray).dims
                arrdims[s] = copy(d)
                print(io, '/', join(d, 'x'))
            end
        end
    end
    outs = info === nothing ? String[] : info.outs
    isempty(outs) || print(io, '\x03', "elem")
    key = String(take!(io))
    got = get(ct.targets, key, nothing)
    got === nothing || return got
    inst = _tpl_inst_closed(ct.tt, def, S)
    ibody = inst.body
    if !isempty(outs)
        # The element body: the output indices are arguments (`_elem_call`).
        haskey(b, _TPL_OUT * outs[1]) || throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "array-valued template '$name' is read other than through `index`"
            )
        )
        m = Dict{String, ASTExpr}(o => VarExpr(_TPL_OUT * o) for o in outs)
        ibody = _tpl_subst_scoped((ibody::OpExpr).expr_body, m, IdDict{OpExpr, ASTExpr}())
    end
    arrslots = sort!(collect(keys(arrkind)))
    slots = String[_TPL_ARG * p for p in def.params if !haskey(S, p)]
    append!(slots, String[_TPL_FREE * n for n in inst.free])
    filter!(s -> !haskey(arrkind, s), slots)
    sort!(slots)
    append!(slots, String[_TPL_OUT * o for o in outs])
    tg = _CallTarget(
        name, key, slots, arrslots, Symbol[arrkind[s] for s in arrslots],
        Vector{Int}[get(arrdims, s, Int[]) for s in arrslots],
        _mknode(kind = _NK_LITERAL), ct.stack, 0, 0, _ArrArg[]
    )
    am = _ArgMap(
        tg, Dict{String, Int}(s => i for (i, s) in enumerate(slots)),
        Dict{String, Int}(s => j for (j, s) in enumerate(arrslots))
    )
    st = _build_state()
    saved = st.argmap
    st.argmap = am
    body = try
        # The body binds nothing of the caller's: an empty state map and no
        # parameters. Every name it reads is an argument; an `index` of an
        # array argument resolves to an argument gather (`_arg_gather_resolve`).
        # One memo for both passes: a body is a DAG (a shared sub-term, such
        # as an interpolation's bracket index, is read many times), and an
        # unmemoized pass would walk it as a tree.
        bm = _BuildMemo()
        rb = _resolve_indices(
                ibody, Dict{String, Tuple{Vector{Int}, Vector{Int}}}(), _EMPTY_VARMAP,
                _EMPTY_CONST_ARRAYS, _EMPTY_PGATHER, bm
            )
        _compile(rb, _EMPTY_VARMAP, Set{Symbol}(), bm)
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

# `index(<array argument sentinel>, subs…)` inside a body being compiled: the
# argument gather over the resolved subscripts, or `nothing` when `name` is no
# array argument of the body.
function _arg_gather_resolve(name::String, subs::Vector{ASTExpr}, rc)
    am = _build_state().argmap
    am === nothing && return nothing
    j = get((am::_ArgMap).arr, name, 0)
    j == 0 && return nothing
    return OpExpr(
        "__arg_gather", ASTExpr[_resolve_indices(a, rc) for a in subs];
        value = _Lowered(_NK_ARG_GATHER, _ArgGatherRef((am::_ArgMap).target, j))
    )
end

# The `__arrarg` marker for the array a reference binds to an array parameter
# (`_resolve_call_bindings`): a state array, a live forcing buffer or a const
# array by name, or an inline `const` array.
function _arr_arg_marker(v::ASTExpr, rc)
    (v isa OpExpr && v.op == "__arrarg") && return v
    a = if v isa OpExpr && v.op == "const" && v.value isa AbstractVector
        vals, cname = _intern_inline_const(v, rc.const_arrays)
        _ArrArg(:const, _const_gather_payload(vals, cname), cname)
    elseif v isa VarExpr
        n = v.name
        src = _array_source(n, rc.array_var_info, rc.pgather, rc.const_arrays)
        if src === :state
            lo, hi = rc.array_var_info[n]
            _ArrArg(:state, _state_gather_payload(n, lo, hi, rc.var_map), n)
        elseif src === :forcing
            pg = rc.pgather[n]::_PGatherArray
            nd = length(pg.dims)
            strides = Vector{Int}(undef, nd)
            acc = 1
            for d in 1:nd
                strides[d] = acc
                acc *= pg.dims[d]
            end
            _ArrArg(:live, _ConstGatherArray(pg.flat, strides, collect(Int, pg.dims), fill(:live, nd), n), n)
        elseif src === :const
            _ArrArg(:const, _const_gather_payload(rc.const_arrays[n], n), n)
        else
            throw(
                TreeWalkError(
                    "E_TREEWALK_INDEX_NOT_ARRAY",
                    "'$(n)' is bound to an array parameter of a template but is not an " *
                        "array the build can pass (a state array, a forcing buffer or a const array)"
                )
            )
        end
    else
        throw(
            TreeWalkError(
                "E_TREEWALK_UNSUPPORTED_OP",
                "an array parameter of a template is bound to an expression; the build " *
                    "passes only named or inline const arrays yet"
            )
        )
    end
    return OpExpr("__arrarg", ASTExpr[]; value = a)
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
    site = n.payload::_CallSite
    tg = site.target
    st = tg.stack
    base = st.top
    ch = n.children
    @inbounds for i in eachindex(ch)
        v = ev(ch[i])
        _argstack_push!(st, base + i, v, T)
        st.top = base + i
    end
    old = tg.fp
    oldarrs = tg.curarrs
    tg.fp = base
    tg.curarrs = site.arrays
    r = try
        _eval_node(tg.body, u, p, t, T)
    finally
        tg.fp = old
        tg.curarrs = oldarrs
        st.top = base
    end
    return r
end

# `_NK_ARG_GATHER`: the read of array argument `j` of the running call, at
# the subscripts `n.children`, exactly as the gather of that array would read
# it (`_eval_state_gather_at`, `_eval_const_gather_at`).
function _eval_arg_gather(n::_Node, u, p, t, ::Type{T}) where {T}
    ref = n.payload::_ArgGatherRef
    a = @inbounds ref.target.curarrs[ref.j]
    a.kind === :state && return _eval_state_gather_at(a.data::_StateGather, n.children, u, p, t, T)
    return _eval_const_gather_at(a.data::_ConstGatherArray, n.children, u, p, t, T)
end

@inline _eval_arg(n::_Node, ::Type{T}) where {T} =
    (tg = n.payload::_CallTarget; _argstack_read(tg.stack, tg.fp + n.idx, T))

# ---- Array-valued templates ------------------------------------------------------
# An array-valued template (its body a `faq` over its output indices, frames.jl
# `_TplCallInfo.outs`) is read two ways, both rewritten ONCE at the build entry
# (`_tpl_whole_views`), so no later phase tests for them:
#
#   * its ELEMENT, `index(ref, s...)`, is the ELEMENT CALL: the same reference
#     with each output index `o` bound to its subscript (`"\0out\0o" => s`). It
#     is a scalar call like any other; its target's body is the `faq`'s
#     expression with the output indices read as those arguments
#     (`_call_target`). A subscript is an index expression: pure and cheap, so
#     it is passed as a value whatever the body does with it.
#   * the WHOLE ARRAY, where the reference stands as an array (an equation's
#     right-hand side, a `makearray` region value), is the aggregate over the
#     template's output indices and ranges whose element is the element call:
#
#         ref  ==  faq(output_idx = o, ranges = R, expr = ref[o => o])
#
#     This is the definition of an array value read whole, not an expansion:
#     the body stays in the template, and every phase that handles an array
#     producer handles this one; substituting the output indices (the
#     producer rule every phase already applies) substitutes into the element
#     call's bindings. `R` is the instance's own ranges (a fixed range bound
#     substituted, `_tpl_inst_closed`).

# The rank of the array `e` denotes when it is an array-valued reference (not
# an element call), else 0.
function _tpl_view_rank(tt::_TplTable, e)
    _tpl_is_call(e) || return 0
    info = _tpl_call_info(tt, (e::OpExpr).name)
    (info === nothing || isempty(info.outs)) && return 0
    _tpl_is_elem(e::OpExpr) && return 0
    return length(info.outs)
end

_tpl_is_elem(e::OpExpr) = e.bindings !== nothing && any(k -> startswith(k, _TPL_OUT), keys(e.bindings))

# The element of the array-valued reference `call` at `subs`.
function _elem_call(tt::_TplTable, call::OpExpr, subs::AbstractVector)
    outs = (_tpl_call_info(tt, call.name)::_TplCallInfo).outs
    length(outs) == length(subs) || throw(
        TreeWalkError(
            "E_TREEWALK_ARRAYOP_INDEX_NDIM",
            "template '$(call.name)' is an array of rank $(length(outs)) read with $(length(subs)) subscripts"
        )
    )
    nb = call.bindings === nothing ? Dict{String, ASTExpr}() : copy(call.bindings)
    for (o, s) in zip(outs, subs)
        nb[_TPL_OUT * o] = s
    end
    return reconstruct(call; bindings = nb)
end

# The whole-array view of the array-valued reference `call`. The output index
# names are the body's own unless the reference's bindings read one of them.
function _tpl_whole_view(tt::_TplTable, call::OpExpr)
    info = _tpl_call_info(tt, call.name)::_TplCallInfo
    def = _tpl_def(tt, call.name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = _call_fixed!(Dict{String, Any}(), call.name, info, b)
    body = _tpl_inst_closed(tt, def, S).body::OpExpr
    reads = Set{String}()
    for v in values(b)
        union!(reads, _tpl_free_leaves(v))
    end
    names = Dict{String, String}()
    for o in info.outs
        n = o
        while n in reads
            n *= "′"
        end
        names[o] = n
    end
    ranges = body.ranges === nothing ? nothing :
        Dict{String, Any}(names[String(k)] => v for (k, v) in body.ranges)
    oi = String[names[o] for o in info.outs]
    el = _elem_call(tt, call, ASTExpr[VarExpr(n) for n in oi])
    return reconstruct(body; output_idx = Any[oi...], ranges = ranges, expr_body = el, args = ASTExpr[])
end

# `e` with every element read of an array-valued reference an element call
# and every whole-array use its view. Applied once at the build entry.
function _tpl_whole_views(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}())
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    if e.op == "index" && _tpl_structless(e) && length(e.args) >= 2 &&
            _tpl_view_rank(tt, e.args[1]) == length(e.args) - 1
        a1 = map_children(c -> _tpl_whole_views(tt, c, memo), e.args[1]::OpExpr)
        r = _elem_call(tt, a1, ASTExpr[_tpl_whole_views(tt, a, memo) for a in e.args[2:end]])
    else
        r = map_children(c -> _tpl_whole_views(tt, c, memo), e)
        _tpl_view_rank(tt, r) > 0 && (r = _tpl_whole_view(tt, r::OpExpr))
    end
    memo[e] = r
    return r
end

# ---- Value operands -------------------------------------------------------------------
# The operands of `e` read as VALUES: a call's bindings except the arrays its
# body indexes (an array argument is a whole array, legitimately bare), every
# other node's `args`. A walker asking "which values does this compute from"
# (the bare-array check) uses this; one asking "which names does it read" uses
# `_operands` (frames.jl).
function _value_operands(e::OpExpr)
    _tpl_is_call(e) || return e.args
    ops = _call_operands(e)
    ct = _call_table()
    ct === nothing && return ops
    arrs = _tpl_array_slots((ct::_CallTable).tt, e.name)
    (arrs === nothing || isempty(arrs)) && return ops
    b = e.bindings::AbstractDict
    return ASTExpr[
        b[k] for k in sort!(collect(keys(b)))
            if !((startswith(k, _TPL_FREE) ? k : _TPL_ARG * k) in arrs)
    ]
end

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
            tg = (x.payload::_CallSite).target
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

# A structural measure `f(body, memo::IdDict{OpExpr, Int}) -> Int` of the body
# of the reference `call`'s template (its prepared body, every parameter a
# sentinel), once per template (`key` names the measure), 0 when no table is
# in reach or the template has a parameter in a structural position. A phase
# that asks how an expression is built (how deep its reductions nest) asks it
# of a call through here.
function _call_body_measure(f, call::OpExpr, key::Symbol)
    ct = _call_table()
    ct === nothing && return 0
    tt = (ct::_CallTable).tt
    memo = _tpl_memo(tt, nothing, key, () -> Dict{String, Int}())
    return get!(memo, String(call.name)) do
        def = _tpl_def(tt, call.name)
        body = def.closed === nothing ? nothing : def.closed.body
        body isa OpExpr ? f(body, IdDict{OpExpr, Int}()) : 0
    end
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
