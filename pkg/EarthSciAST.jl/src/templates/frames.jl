# Template instances and frames: reading a template reference without
# expanding it (esm-spec §9.6.4 rule 2).
#
# A reference denotes its expansion, but no builder, evaluator or analysis
# expands it: each one reads the template's own body in a FRAME that binds the
# body's parameters to the call site's binding expressions. The body is parsed
# and prepared once per template (once per instance when a parameter sits in a
# structural position), and a frame is made once per template instance, so a
# walk that memoizes per (node, frame) analyses each instance once, however
# many uses it has.
#
# A prepared ("closed") body reads nothing from the caller by name:
#
#   * every leaf of a parameter `p` is the sentinel `"\0arg\0p"`, bound by the
#     frame to the call site's binding of `p`;
#   * every other name the body reads from outside itself (a global variable,
#     `t`, a loop index of the caller's) is the sentinel `"\0free\0n"`, an
#     IMPLICIT parameter bound to the name `n` as the caller reads it.
#
# The implicit parameters are also written onto each reference itself, as
# bindings under their sentinel keys (`_tpl_augment`). Every name a body reads
# from its caller is then a binding expression of the reference: a substitution
# in the caller (an index bound to a subscript, an observed inlined by name)
# reaches the body's reads through the bindings, exactly where expansion would
# have put them, and an analysis that only asks which names an expression reads
# (`free_variables`, `foreach_subexpr`) is right without entering the body.
#
# A name bound inside the body (a `faq` index, a `makearray` output index, an
# integral's variable) stays as it is. A parameter that expansion would also
# substitute outside a variable leaf (an `output_idx` entry, a `ranges` index
# set, `wrt`, an op name) is substituted into that instance's own body, once
# per instance: the binding, read through the frames, must be a name or a
# number there.

const _TPL_ARG = "\0arg\0"
const _TPL_FREE = "\0free\0"

_tpl_is_sentinel(s::AbstractString) = startswith(s, _TPL_ARG) || startswith(s, _TPL_FREE)
_tpl_is_sentinel(e::VarExpr) = _tpl_is_sentinel(e.name)
_tpl_is_sentinel(::ASTExpr) = false
_tpl_is_call(e) = e isa OpExpr && e.op == APPLY_EXPRESSION_TEMPLATE_OP

# One prepared body: the expression and its implicit parameters (sorted).
struct _TplClosed
    body::ASTExpr
    free::Vector{String}
end

# Per template: its parameters, the ones in a structural position, and the
# prepared body when there are none.
struct _TplDef
    name::String
    params::Vector{String}
    structural::Vector{String}
    closed::Union{Nothing, _TplClosed}
end

"""
    _TplFrame

One template instance: the template, its instance key (the template and every
binding as read through the frames, structurally), the prepared body the
instance reads, each sentinel's binding expression and the frame those are
read in (`parent`, `nothing` at the top), and per-walk memos keyed by walk.
"""
mutable struct _TplFrame
    name::String
    key::String
    body::ASTExpr
    args::Dict{String, ASTExpr}
    parent::Union{Nothing, _TplFrame}
    memos::Dict{Symbol, Any}
    depth::Int
end

"""
    _TplTable(reg)

The template instances of one build or analysis against the registry `reg`:
the prepared bodies, the frames by instance key, and the binding-key memo.
"""
mutable struct _TplTable
    reg::Any
    defs::Dict{String, _TplDef}
    inst::Dict{Tuple{String, String}, _TplClosed}
    frames::Dict{String, _TplFrame}
    bkeys::IdDict{Any, IdDict{ASTExpr, String}}
    preparing::Set{String}
    root_memos::Dict{Symbol, Any}
end
_TplTable(reg) = _TplTable(
    reg, Dict{String, _TplDef}(), Dict{Tuple{String, String}, _TplClosed}(),
    Dict{String, _TplFrame}(), IdDict{Any, IdDict{ASTExpr, String}}(), Set{String}(),
    Dict{Symbol, Any}()
)

# A per-walk memo for `fr` (the table's own for the top level), made by `mk`
# on first use.
_tpl_memo(tt::_TplTable, ::Nothing, key::Symbol, mk) = get!(mk, tt.root_memos, key)
_tpl_memo(::_TplTable, fr::_TplFrame, key::Symbol, mk) = get!(mk, fr.memos, key)

_tpl_unknown(name) = ExpressionTemplateError(
    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
    "apply_expression_template references template '$(name === nothing ? "?" : name)' " *
        "with no in-scope registry entry"
)

function _tpl_def(tt::_TplTable, name)
    name isa AbstractString || throw(_tpl_unknown(name))
    d = get(tt.defs, name, nothing)
    d === nothing || return d
    (tt.reg !== nothing && haskey(tt.reg, name)) || throw(_tpl_unknown(name))
    String(name) in tt.preparing && throw(
        ExpressionTemplateError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            "expression template '$name' references itself"
        )
    )
    push!(tt.preparing, String(name))
    try
        decl = _TemplateDecl(tt.reg[name])
        raw = decl.body
        typed = expression_from_json(raw)
        structural = String[p for p in decl.params if _raw_count(raw, p) != _leaf_count(typed, p)]
        closed = isempty(structural) ? _tpl_close(tt, String(name), decl, Dict{String, Any}()) : nothing
        d = _TplDef(String(name), decl.params, structural, closed)
        tt.defs[String(name)] = d
        return d
    finally
        delete!(tt.preparing, String(name))
    end
end

# The prepared body of `name` with the structural parameters substituted by
# `S` (parameter => raw value).
function _tpl_close(tt::_TplTable, name::String, decl::_TemplateDecl, S::Dict{String, Any})
    sub = Dict{String, Any}()
    for p in decl.params
        sub[p] = haskey(S, p) ? S[p] : _TPL_ARG * p
    end
    typed = expression_from_json(_substitute(decl.body, sub))
    typed = _tpl_augment(tt, typed)
    typed = _tpl_elem_reads(tt, typed)
    typed = _tpl_body_lift(tt, typed, IdDict{OpExpr, ASTExpr}())
    free = sort!(collect(_tpl_free_leaves(typed)))
    if !isempty(free)
        m = Dict{String, ASTExpr}(n => VarExpr(_TPL_FREE * n) for n in free)
        typed = _tpl_subst_scoped(typed, m, IdDict{OpExpr, ASTExpr}())
    end
    return _TplClosed(typed, free)
end

# A body's element reads of array-valued references, `index(ref, s...)`, as
# element calls (call.jl `_elem_call`): the reference with each output index
# bound to its subscript. The build entry does this for the model's own tree
# (`_tpl_whole_views`); a body gets it once, when it is prepared, so a body
# reading an element of another template's array is a body with a call in it.
function _tpl_elem_reads(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}())
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    r = map_children(c -> _tpl_elem_reads(tt, c, memo), e)
    if r.op == "index" && _tpl_structless(r) && length(r.args) >= 2 &&
            _tpl_is_call(r.args[1]) && !_tpl_is_elem(r.args[1]::OpExpr)
        info = _tpl_call_info(tt, (r.args[1]::OpExpr).name)
        if info !== nothing && length(info.outs) == length(r.args) - 1
            r = _elem_call(tt, r.args[1]::OpExpr, r.args[2:end])
        end
    end
    memo[e] = r
    return r
end

# THE ELEMENTWISE LIFT IN A BODY. An elementwise operator in a body whose
# operands include whole array-valued references (`2.5 * interior(f)`, all of
# one rank over the same ranges) and otherwise scalars is the array whose
# element at `o…` is the operator over each reference's ELEMENT call at `o…`
# (call.jl `_elem_call`) and the scalars:
#
#     2.5 * interior(f)  ==  faq(output_idx = o, ranges = R, expr = 2.5 * interior(f)[o])
#
# as the model's own elementwise lift reads the same arithmetic on the
# expansion. The references stay references (element calls); the template is
# then array-valued and called through its element like any other.
function _tpl_body_lift(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr})
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    r = map_children(c -> _tpl_body_lift(tt, c, memo), e)
    if r.op in _TPL_CALL_OPS && r.op != "const" && _tpl_structless(r) && !_tpl_is_call(r) &&
            isempty(_bound_symbols(r)) && any(a -> _tpl_whole_ref(tt, a) !== nothing, r.args)
        l = _tpl_lift_whole(tt, r)
        l === nothing || (r = l)
    end
    memo[e] = r
    return r
end

# The output indices and ranges of the whole array-valued reference `a` (its
# instance's own, a fixed bound substituted), or `nothing`.
function _tpl_whole_ref(tt::_TplTable, a)
    (_tpl_is_call(a) && !_tpl_is_elem(a::OpExpr)) || return nothing
    info = _tpl_call_info(tt, a.name)
    (info === nothing || isempty(info.outs)) && return nothing
    b = a.bindings === nothing ? Dict{String, ASTExpr}() : a.bindings
    S = Dict{String, Any}()
    for s in info.fixed
        v = get(b, s[(ncodeunits(_TPL_ARG) + 1):end], nothing)
        iv = v isa IntExpr ? Int(v.value) : v isa NumExpr && isinteger(v.value) ? Int(v.value) : nothing
        iv === nothing && return nothing
        S[s[(ncodeunits(_TPL_ARG) + 1):end]] = iv
    end
    body = _tpl_inst_closed(tt, _tpl_def(tt, a.name), S).body
    (body isa OpExpr && body.ranges !== nothing) || return nothing
    return info.outs, body.ranges
end

function _tpl_range_same(x, y)
    x isa IndexSetRef && y isa IndexSetRef && return x.from == y.from && x.of == y.of
    x isa AbstractVector && y isa AbstractVector && return length(x) == length(y) &&
        all(((p, q),) -> (p isa Integer || p isa IntExpr) && (q isa Integer || q isa IntExpr) &&
        Int(p isa IntExpr ? p.value : p) == Int(q isa IntExpr ? q.value : q), zip(x, y))
    return false
end

function _tpl_lift_whole(tt::_TplTable, r::OpExpr)
    shape = nothing
    for a in r.args
        w = _tpl_whole_ref(tt, a)
        if w === nothing
            # Every other operand a scalar: no whole reference, no array.
            _tpl_reads_whole(tt, a) && return nothing
            continue
        end
        outs, rg = w
        rs = Any[rg[o] for o in outs]
        if shape === nothing
            shape = rs
        else
            (length(rs) == length(shape) && all(_tpl_range_same(p, q) for (p, q) in zip(rs, shape))) ||
                return nothing
        end
    end
    shape === nothing && return nothing
    # Output names not read anywhere in `r`.
    used = Set{String}()
    foreach_subexpr(x -> x isa VarExpr && push!(used, x.name), r)
    oi = String[]
    for k in eachindex(shape)
        n = string("i", k)
        while n in used || n in oi
            n *= "′"
        end
        push!(oi, n)
    end
    subs = ASTExpr[VarExpr(n) for n in oi]
    args = ASTExpr[_tpl_whole_ref(tt, a) === nothing ? a : _elem_call(tt, a::OpExpr, subs) for a in r.args]
    ranges = Dict{String, Any}(n => shape[k] for (k, n) in enumerate(oi))
    return OpExpr(
        "faq", ASTExpr[]; output_idx = Any[oi...], ranges = ranges,
        expr_body = reconstruct(r; args = args)
    )
end

# Does `a` hold a whole array-valued reference or an array-valued node?
function _tpl_reads_whole(tt::_TplTable, a)
    a isa OpExpr || return false
    _tpl_whole_ref(tt, a) !== nothing && return true
    _is_faq_op(a.op) && a.output_idx !== nothing && !isempty(a.output_idx) && return true
    a.op == "makearray" && return true
    return any(c -> _tpl_reads_whole(tt, c), a.args)
end

# The prepared body an instance of `def` with structural values `S` reads.
function _tpl_inst_closed(tt::_TplTable, def::_TplDef, S::Dict{String, Any})
    isempty(S) && return def.closed::_TplClosed
    skey = join(sort!([k * "\0" * _stable_json(v) for (k, v) in S]), "\x01")
    return get!(tt.inst, (def.name, skey)) do
        _tpl_close(tt, def.name, _TemplateDecl(tt.reg[def.name]), S)
    end
end

# ---- Structural instances --------------------------------------------------
# A template with a parameter in a structural position (a `join` envelope, a
# range's index set, `wrt`, ...) is a family of templates, one per value of
# those parameters. A reference whose structural bindings are names or numbers
# reads the INSTANCE: a template of its own (`<name>\0inst\0<values>`, the
# declaration with those values substituted, its other parameters kept),
# registered once in the build's registry, and the reference re-pointed at it
# with the structural bindings dropped. Every by-name query (call gate, call
# target, element call, view) then sees an ordinary template. The expansion,
# where a body is still expanded, substitutes the same values the same way.
const _TPL_INST = "\0inst\0"

function _tpl_structural_ref(tt::_TplTable, call::OpExpr)
    def = _tpl_def(tt, call.name)
    isempty(def.structural) && return call
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    S = Dict{String, Any}()
    for p in def.structural
        x = get(b, p, nothing)
        ok = (x isa VarExpr && !_tpl_is_sentinel(x.name) && !occursin(_TPL_SENTINEL, x.name)) ||
            x isa NumExpr || x isa IntExpr
        ok || return call
        S[p] = serialize_expression(x)
    end
    skey = join(sort!([k * "=" * _stable_json(v) for (k, v) in S]), ",")
    iname = string(call.name, _TPL_INST, skey)
    if !haskey(tt.reg, iname)
        raw = tt.reg[call.name]
        decl = _TemplateDecl(raw)
        sub = Dict{String, Any}(p => v for (p, v) in S)
        nd = OrderedDict{String, Any}()
        for (k, v) in pairs(raw)
            nd[string(k)] = v
        end
        nd["params"] = Any[p for p in decl.params if !haskey(S, p)]
        nd["body"] = _substitute(decl.body, sub)
        tt.reg[iname] = nd
    end
    nb = Dict{String, ASTExpr}(k => v for (k, v) in b if !haskey(S, k))
    return reconstruct(call; name = iname, bindings = nb)
end

# `e` with every reference to a structural template re-pointed at its instance
# (`_tpl_structural_ref`), bindings first.
function _tpl_structural_refs(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}())
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    r = map_children(c -> _tpl_structural_refs(tt, c, memo), e)
    _tpl_is_call(r) && (r = _tpl_structural_ref(tt, r::OpExpr))
    memo[e] = r
    return r
end

# The names `e` reads as variable leaves and does not bind itself, sentinels
# excluded. `wrt` is not a read here: it names an axis or `t` in place.
function _tpl_free_leaves(e::ASTExpr)
    out = Set{String}()
    _tpl_free_leaves!(out, e, Set{String}(), IdDict{OpExpr, Nothing}())
    return out
end
function _tpl_free_leaves!(out, e::ASTExpr, bound::Set{String}, seen)
    if e isa VarExpr
        n = e.name
        (n in bound || _tpl_is_sentinel(n)) || push!(out, n)
        return
    end
    e isa OpExpr || return
    b = _bound_symbols(e)
    if isempty(b)
        # A shared node under the same binders reads the same names.
        isempty(bound) && (haskey(seen, e) && return; seen[e] = nothing)
        foreach_child(c -> _tpl_free_leaves!(out, c, bound, seen), e)
    else
        inner = union(bound, b)
        foreach_child(c -> _tpl_free_leaves!(out, c, inner, seen), e)
    end
    return
end

# Capture-avoiding substitution of variable leaves through every expression
# field, template bindings included (the binder rule of `_sub_preserving`).
function _tpl_subst_scoped(e::ASTExpr, m::Dict{String, ASTExpr}, memo::IdDict{OpExpr, ASTExpr})
    e isa VarExpr && return get(m, e.name, e)
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    if _binds_any(e, m)
        inner = _shadowed_bindings(e, m)
        r = isempty(inner) ? e : _tpl_subst_scoped(e, inner, IdDict{OpExpr, ASTExpr}())
    else
        r = map_children(c -> _tpl_subst_scoped(c, m, memo), e)
    end
    memo[e] = r
    return r
end

"""
    _tpl_augment(tt, e) -> ASTExpr

`e` with every template reference in it carrying its implicit parameters as
bindings: `"\\0free\\0n" => n` for each name `n` the referenced body reads from
its caller. A reference that already carries them is kept.
"""
function _tpl_augment(tt::_TplTable, e::ASTExpr, memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}())
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    out = map_children(c -> _tpl_augment(tt, c, memo), e)
    if _tpl_is_call(out)
        def = _tpl_def(tt, out.name)
        free = def.closed === nothing ? _tpl_generic_free(tt, def) : def.closed.free
        if !isempty(free)
            b = out.bindings === nothing ? Dict{String, ASTExpr}() : copy(out.bindings)
            added = false
            for n in free
                k = _TPL_FREE * n
                haskey(b, k) && continue
                b[k] = VarExpr(n)
                added = true
            end
            added && (out = reconstruct(out; bindings = b))
        end
    end
    memo[e] = out
    return out
end

# The implicit parameters of a template with structural parameters, read off
# its body with every parameter left a sentinel (an instance's own structural
# values may add more; its frame binds those in the caller as well).
function _tpl_generic_free(tt::_TplTable, def::_TplDef)
    decl = _TemplateDecl(tt.reg[def.name])
    sub = Dict{String, Any}(p => _TPL_ARG * p for p in decl.params)
    typed = _tpl_augment(tt, expression_from_json(_substitute(decl.body, sub)))
    return sort!(collect(_tpl_free_leaves(typed)))
end

# A sentinel's binding and the frame it is read in.
function _tpl_arg(fr::_TplFrame, name::String)
    b = get(fr.args, name, nothing)
    b === nothing && throw(
        TreeWalkError(
            "E_TREEWALK_UNBOUND_VARIABLE",
            "template '$(fr.name)': no binding for $(repr(name))"
        )
    )
    return b, fr.parent
end

# A leaf read through the frames down to a non-sentinel expression, with the
# frame that expression is read in.
function _tpl_leaf(e::ASTExpr, fr::Union{Nothing, _TplFrame})
    while fr !== nothing && e isa VarExpr && _tpl_is_sentinel(e.name)
        e, fr = _tpl_arg(fr, e.name)
    end
    return e, fr
end

"""
    _tpl_frame(tt, call, parent) -> _TplFrame

The frame of the reference `call` read in `parent`: one per template instance.
Refuses a reference whose bindings do not cover the template's parameters
exactly (`bindings_mismatch`, as load does).
"""
function _tpl_frame(tt::_TplTable, call::OpExpr, parent::Union{Nothing, _TplFrame})
    name = call.name
    def = _tpl_def(tt, name)
    bind = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    for p in def.params
        haskey(bind, p) || throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "apply_expression_template '$name' missing binding for param '$p'"
            )
        )
    end
    for k in keys(bind)
        (k in def.params || startswith(k, _TPL_FREE) || startswith(k, _TPL_OUT)) || throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "apply_expression_template '$name' supplies unknown param '$k'"
            )
        )
    end
    S = Dict{String, Any}()
    for p in def.structural
        x, xf = _tpl_leaf(bind[p], parent)
        (x isa VarExpr || x isa NumExpr || x isa IntExpr) || throw(
            ExpressionTemplateError(
                ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
                "apply_expression_template '$name': parameter '$p' sits in a " *
                    "structural position and needs a name or a number, not an expression"
            )
        )
        S[p] = serialize_expression(x)
    end
    closed = _tpl_inst_closed(tt, def, S)
    args = Dict{String, ASTExpr}()
    for p in def.params
        haskey(S, p) && continue
        args[_TPL_ARG * p] = bind[p]
    end
    for n in closed.free
        k = _TPL_FREE * n
        args[k] = get(bind, k, nothing) === nothing ? VarExpr(n) : bind[k]
    end
    io = IOBuffer()
    print(io, name, '\x01')
    for (k, v) in sort!(collect(S); by = first)
        print(io, k, '=', _stable_json(v), '\x02')
    end
    print(io, '\x01')
    for k in sort!(collect(keys(args)))
        print(io, k, '=', _tpl_bkey(tt, args[k], parent), '\x02')
    end
    key = String(take!(io))
    fr = get(tt.frames, key, nothing)
    fr === nothing || return fr
    fr = _TplFrame(
        String(name), key, closed.body, args, parent, Dict{Symbol, Any}(),
        parent === nothing ? 1 : parent.depth + 1
    )
    tt.frames[key] = fr
    return fr
end

# The structural key of `e` read in `fr`: its own structure, with each
# sentinel replaced by its binding's key in the binding's frame. Two
# expressions with equal keys denote the same expression.
function _tpl_bkey(tt::_TplTable, e::ASTExpr, fr::Union{Nothing, _TplFrame})
    e isa NumExpr && return string("N", repr(e.value))
    e isa IntExpr && return string("I", e.value)
    if e isa VarExpr
        _tpl_is_sentinel(e.name) || return string("V", e.name)
        fr === nothing && return string("V", e.name)
        b, bf = _tpl_arg(fr, e.name)
        return _tpl_bkey(tt, b, bf)
    end
    memo = get!(() -> IdDict{ASTExpr, String}(), tt.bkeys, fr === nothing ? tt : fr)
    k = get(memo, e, nothing)
    k === nothing || return k
    o = e::OpExpr
    io = IOBuffer()
    print(io, "(", o.op)
    for (f, spec) in pairs(OPEXPR_FIELD_TABLE)
        (f === :op || f === :join_gates || f === :template_origin) && continue
        v = getfield(o, f)
        v === nothing && continue
        print(io, ' ', f, ':')
        if spec.kind === :expr
            print(io, _tpl_bkey(tt, v, fr))
        elseif spec.kind === :expr_vec
            print(io, '[')
            for c in v
                print(io, _tpl_bkey(tt, c, fr), ',')
            end
            print(io, ']')
        elseif spec.kind === :expr_map
            print(io, '{')
            for kk in sort!(collect(keys(v)))
                print(io, kk, '=', _tpl_bkey(tt, v[kk], fr), ',')
            end
            print(io, '}')
        elseif f === :ranges
            print(io, '{')
            for kk in sort!(collect(keys(v)))
                rv = v[kk]
                print(io, kk, '=')
                if rv isa AbstractVector
                    print(io, '[')
                    for x in rv
                        print(io, x isa ASTExpr ? _tpl_bkey(tt, x, fr) : repr(x), ',')
                    end
                    print(io, ']')
                else
                    print(io, repr(rv))
                end
                print(io, ',')
            end
            print(io, '}')
        elseif v isa AbstractDict
            print(io, repr(sort!(collect(v); by = x -> string(first(x)))))
        else
            print(io, repr(v))
        end
    end
    print(io, ')')
    k = String(take!(io))
    memo[e] = k
    return k
end

# ---------------------------------------------------------------------------
# Analyses over references
# ---------------------------------------------------------------------------

"""
    _tpl_foreach_node(f, tt, e)

Call `f(node, frame)` on every node of `e` and of every template instance `e`
reaches, each instance body once: a node of the tree is visited with frame
`nothing`, a node of an instance body with that instance's frame. A shared
node is visited once per frame.
"""
function _tpl_foreach_node(f, tt::_TplTable, e::ASTExpr)
    seen = Set{Tuple{UInt, UInt}}()
    _tpl_foreach_node!(f, tt, e, nothing, seen)
    return nothing
end
function _tpl_foreach_node!(f, tt::_TplTable, e::ASTExpr, fr, seen)
    if e isa OpExpr
        k = (objectid(e), fr === nothing ? UInt(0) : objectid(fr))
        k in seen && return
        push!(seen, k)
    end
    f(e, fr)
    e isa OpExpr || return
    foreach_child(c -> _tpl_foreach_node!(f, tt, c, fr, seen), e)
    if _tpl_is_call(e)
        sub = _tpl_frame(tt, e, fr)
        k = (UInt(1), objectid(sub))
        k in seen && return
        push!(seen, k)
        _tpl_foreach_node!(f, tt, sub.body, sub, seen)
    end
    return
end

# `m` (a model or reaction system) with every reference carrying its implicit
# parameters (`_tpl_augment`): the names a referenced body reads are then
# reads of the reference itself. In place, so the caller passes a copy.
function _tpl_augment_component!(m, reg)
    reg === nothing && return m
    tt = _TplTable(reg)
    memo = IdDict{OpExpr, ASTExpr}()
    map_expressions!(e -> _tpl_augment(tt, e, memo), m)
    return m
end

"""
    _tpl_augmented_file(file::EsmFile) -> EsmFile

A copy of `file` whose references carry their implicit parameters (each name
a referenced body reads from its caller, `_tpl_augment`), so an analysis that
asks which names an expression reads sees through every reference without
expanding it. `file` itself is returned when it carries no reference.
"""
function _tpl_augmented_file(file::EsmFile)
    ct = file.component_templates
    ct === nothing && return file
    out = deepcopy(file)
    if out.models !== nothing
        for (cname, m) in out.models
            _tpl_augment_component!(m, get(ct, "models.$cname", nothing))
        end
    end
    if out.reaction_systems !== nothing
        for (cname, rs) in out.reaction_systems
            _tpl_augment_component!(rs, get(ct, "reaction_systems.$cname", nothing))
        end
    end
    return out
end

# `eqs` with every reference carrying its implicit parameters against `reg`
# (`_tpl_augment`); `eqs` itself when `reg` is `nothing`.
function _tpl_augmented_equations(eqs::AbstractVector{Equation}, reg)
    reg === nothing && return eqs
    tt = _TplTable(reg)
    memo = IdDict{OpExpr, ASTExpr}()
    return Equation[
        Equation(_tpl_augment(tt, eq.lhs, memo), _tpl_augment(tt, eq.rhs, memo); _comment = eq._comment)
            for eq in eqs
    ]
end

# ---------------------------------------------------------------------------
# Template calls (the compiled form, tree_walk/call.jl)
# ---------------------------------------------------------------------------
#
# A reference is compiled as a CALL: the template body is compiled once per
# instance and called with argument values (callnode-design.md). Which
# references the build calls rather than expands is decided here, in one
# place, while the call node is being taught to every phase (an intermediate
# state of the branch: the end state calls every reference).
#
# Today: templates whose prepared body (transitively through nested
# references) is made of literals, parameters and implicit parameters,
# elementwise operators, `index` reads of an ARRAY PARAMETER at scalar
# subscripts, and scalar reductions (`faq` with no output index) over constant
# ranges. Such a body reads its caller only through its arguments, so it
# compiles to a function of them:
#
#   * a parameter read as a value is a scalar argument;
#   * a parameter read as the array of an `index` (declared, or an implicit one:
#     a global array the body reads) is an ARRAY argument, passed at run time
#     (call.jl `_CallSite`), so one compiled body serves every array of the
#     same kind and rank;
#   * a parameter that is a bound of a reduction range is FIXED: its literal
#     value is part of the instance (callnode-design.md section 1, "structural
#     position"), and it is substituted into that instance's body.
#
# The bound-expression rule (user decision, 2026-11-18): a plain variable, a
# literal and a plain `index` read are passed as values; a compound binding is
# passed as a value too when the body reads its parameter unconditionally (it
# would be evaluated anyway), and otherwise (read only under an `ifelse` arm or
# a short-circuited operand, inside a reduction, or not at all) it must become
# part of its own instance, which this step does not do yet, so such a site is
# still expanded.

const _TPL_CALL_OPS = union(_ops_with(:stencil_elementwise), Set(["const", "true", "false"]))

# A binding passed as a value whatever the body does with it.
function _tpl_plain_binding(b::ASTExpr)
    (b isa VarExpr || b isa NumExpr || b isa IntExpr) && return true
    b isa OpExpr || return false
    b.op == "index" && !isempty(b.args) && b.args[1] isa VarExpr && return true
    return false
end

_tpl_structless(e::OpExpr) = e.expr_body === nothing && e.values === nothing &&
    e.ranges === nothing && e.output_idx === nothing && e.filter === nothing &&
    e.lower === nothing && e.upper === nothing && e.key === nothing

# What a callable template's body does with its parameters, by sentinel
# (`"\0arg\0p"` / `"\0free\0n"`): read as a value on an unconditional path,
# read as an array, a fixed (range bound) value.
struct _TplCallInfo
    uncond::Set{String}
    arrays::Set{String}
    fixed::Set{String}
    scalars::Set{String}      # every sentinel read as a value (any path)
    outs::Vector{String}      # an array-valued body's output indices (empty: scalar)
end
_TplCallInfo() = _TplCallInfo(Set{String}(), Set{String}(), Set{String}(), Set{String}(), String[])

const _TPL_OUT = "\0out\0"

# Per template name: `nothing` when the build does not call it yet, else its
# `_TplCallInfo`.
function _tpl_call_info(tt::_TplTable, name::AbstractString)
    memo = _tpl_memo(tt, nothing, :call_info, () -> Dict{String, Any}())
    haskey(memo, name) && return memo[name]
    memo[String(name)] = nothing      # a cycle reads as "not callable"
    r = try
        _tpl_call_info_uncached(tt, String(name))
    catch err
        err isa ExpressionTemplateError || rethrow()
        nothing
    end
    memo[String(name)] = r
    return r
end

function _tpl_call_info_uncached(tt::_TplTable, name::String)
    def = _tpl_def(tt, name)
    def.closed === nothing && return nothing
    info = _TplCallInfo()
    body = def.closed.body
    # An ARRAY-VALUED body, `faq` over its output indices only (no reduction):
    # its element at subscripts `s…` is the expression with each output index
    # read as `s`. It is called through `index(ref, s…)` (call.jl `_elem_call`).
    if body isa OpExpr && _is_faq_op(body.op) && body.output_idx !== nothing && !isempty(body.output_idx)
        oi = body.output_idx
        all(x -> x isa AbstractString, oi) || return nothing
        (body.filter === nothing && body.join_gates === nothing && body.join === nothing &&
            body.key === nothing && body.expr_body !== nothing && all(a -> a isa VarExpr, body.args) &&
            body.values === nothing && body.lower === nothing && body.upper === nothing) || return nothing
        outs = String[String(x) for x in oi]
        body.ranges === nothing || all(k -> String(k) in outs, keys(body.ranges)) || return nothing
        append!(info.outs, outs)
        body = body.expr_body
    end
    _tpl_call_walk!(tt, body, false, info) || return nothing
    # A name is read one way only; an implicit parameter is never fixed (its
    # value is the caller's, not a literal at the reference).
    isempty(intersect(info.arrays, info.scalars)) || return nothing
    isempty(intersect(info.arrays, info.fixed)) || return nothing
    any(s -> startswith(s, _TPL_FREE), info.fixed) && return nothing
    return info
end

# The size of the interval index set a range `{"from": S}` names, from the
# build's registry (set at the build entry), or `nothing` (not an interval of
# known size, a ragged range, no registry in reach).
function _tpl_iset_extent(tt::_TplTable, rv::IndexSetRef)
    isempty(rv.of) || return nothing
    sets = get(tt.root_memos, :index_sets, nothing)
    sets === nothing && return nothing
    s = get(sets, rv.from, nothing)
    (s isa IndexSet && s.kind == "interval" && s.size isa Int) || return nothing
    return s.size::Int
end

# A range bound the build can fix: an integer literal, or a parameter (fixed).
function _tpl_range_bound!(x, info::_TplCallInfo)
    (x isa Integer || x isa IntExpr) && return true
    (x isa NumExpr && isinteger(x.value)) && return true
    if x isa VarExpr && _tpl_is_sentinel(x.name)
        push!(info.fixed, x.name)
        return true
    end
    return false
end

# Walk a prepared body: false when a node is outside the class above. `cond`:
# the node is evaluated only on some paths.
function _tpl_call_walk!(tt::_TplTable, e::ASTExpr, cond::Bool, info::_TplCallInfo)
    if e isa VarExpr
        if _tpl_is_sentinel(e.name)
            push!(info.scalars, e.name)
            cond || push!(info.uncond, e.name)
        end
        return true
    end
    e isa OpExpr || return true
    if _tpl_is_call(e)
        inner = _tpl_call_info(tt, e.name)
        inner === nothing && return false
        # An array-valued reference is read in a body through `index`, as an
        # element call (`_tpl_elem_reads`); read whole it is refused.
        isempty(inner.outs) || _tpl_is_elem(e) || return false
        b = e.bindings === nothing ? Dict{String, ASTExpr}() : e.bindings
        for (k, v) in b
            # An output index's subscript: a value the element body reads.
            if startswith(k, _TPL_OUT)
                _tpl_call_walk!(tt, v, cond, info) || return false
                continue
            end
            s = startswith(k, _TPL_FREE) ? k : _TPL_ARG * k
            # A parameter the inner body never reads: its binding is never made.
            (s in inner.scalars || s in inner.arrays || s in inner.fixed) || continue
            # An array argument of a nested call: the body passes on its own
            # array argument (call.jl `_FwdArr`).
            if s in inner.arrays
                (v isa VarExpr && _tpl_is_sentinel(v.name)) || return false
                push!(info.arrays, v.name)
                continue
            end
            if s in inner.fixed
                (v isa IntExpr || (v isa NumExpr && isinteger(v.value))) && continue
                # A range bound passed on: fixed in this body too (substituted
                # into its instance, so the nested call sees the literal).
                (v isa VarExpr && startswith(v.name, _TPL_ARG)) || return false
                push!(info.fixed, v.name)
                continue
            end
            c = cond || !(s in inner.uncond)
            _tpl_call_walk!(tt, v, c, info) || return false
        end
        return true
    end
    if e.op == "index" && _tpl_structless(e) && length(e.args) >= 2
        base = e.args[1]
        if base isa VarExpr && _tpl_is_sentinel(base.name)
            push!(info.arrays, base.name)
        elseif !(base isa OpExpr && base.op == "const" && base.value isa AbstractVector)
            return false
        end
        for j in 2:length(e.args)
            _tpl_call_walk!(tt, e.args[j], cond, info) || return false
        end
        return true
    end
    if _is_faq_op(e.op)
        # A scalar reduction over constant ranges.
        (e.output_idx === nothing || isempty(e.output_idx)) || return false
        (e.join_gates === nothing && e.join === nothing && e.key === nothing &&
            e.values === nothing && e.lower === nothing && e.upper === nothing) || return false
        (e.expr_body === nothing || e.ranges === nothing) && return false
        isempty(e.args) || all(a -> a isa VarExpr, e.args) || return false
        for (_, rv) in e.ranges
            # A whole interval index set: the range [1, size] (`_call_ibody`).
            rv isa IndexSetRef && _tpl_iset_extent(tt, rv) !== nothing && continue
            (rv isa AbstractVector && 2 <= length(rv) <= 3) || return false
            all(x -> _tpl_range_bound!(x, info), rv) || return false
        end
        # A filter is evaluated per term, the term only where it holds.
        e.filter === nothing || _tpl_call_walk!(tt, e.filter, true, info) || return false
        # The body is evaluated once per term; a range may be empty.
        return _tpl_call_walk!(tt, e.expr_body, true, info)
    end
    (e.op in _TPL_CALL_OPS && _tpl_structless(e)) || return false
    isempty(_bound_symbols(e)) || return false
    for (j, a) in enumerate(e.args)
        _tpl_call_walk!(tt, a, cond || _op_arg_conditional(e.op, j), info) || return false
    end
    return true
end

# A binding the build can pass as an array argument: a name (resolved to its
# array when the call compiles) or an inline `const` array.
_tpl_array_binding(v::ASTExpr) =
    (v isa VarExpr && !occursin(_TPL_SENTINEL, v.name) && !_tpl_is_sentinel(v.name)) ||
    (v isa OpExpr && v.op == "const" && v.value isa AbstractVector)

"""
    _tpl_is_called(tt, call::OpExpr) -> Bool

Whether the build compiles the reference `call` (read at the top level, in the
model's own tree or a body being expanded) as a call node rather than
expanding it. See the section comment above.
"""
function _tpl_is_called(tt::_TplTable, call::OpExpr)
    info = _tpl_call_info(tt, call.name)
    # An aggregate or makearray body is read through its view, whose leaves
    # are calls (call.jl `_tpl_agg_view`).
    info === nothing && return _tpl_agg_called(tt, call)
    def = _tpl_def(tt, call.name)
    b = call.bindings === nothing ? Dict{String, ASTExpr}() : call.bindings
    for p in def.params
        v = get(b, p, nothing)
        s = _TPL_ARG * p
        # A parameter the body never reads may go unbound (a part of a view,
        # call.jl `_tpl_part_call`): its binding is never made.
        v === nothing && !(s in info.scalars || s in info.arrays || s in info.fixed) && continue
        v === nothing && return false
        if s in info.arrays
            _tpl_array_binding(v) || return false
            continue
        end
        if s in info.fixed
            (v isa IntExpr || (v isa NumExpr && isinteger(v.value))) || return false
            continue
        end
        # A parameter the body never reads: its binding is never made.
        s in info.scalars || continue
        # A binding that reads a name the body binds (a reduction index the
        # body runs, which the expansion would capture) is compiled into the
        # instance, read where the body binds the name.
        B = _tpl_body_binders(tt, call.name)
        if !isempty(B) && _tpl_reads_any(v, B)
            _tpl_inlinable(v) || return false
            continue
        end
        s in info.uncond && continue
        # A parameter placeholder of a template skeleton being expanded
        # (expand_typed.jl) stands for a binding not known yet.
        (v isa VarExpr && occursin(_TPL_SENTINEL, v.name)) && return false
        # A compound binding the body reads only on some paths is compiled
        # INTO the instance (the user's bound-expression rule; call.jl
        # `_call_inlined`), when it is made of names, literals and
        # elementwise operators.
        _tpl_plain_binding(v) || _tpl_inlinable(v) || return false
    end
    return true
end

# A compound binding the build compiles into its instance (`_call_inlined`):
# elementwise operators over names and literals, and reads of a named array.
function _tpl_inlinable(v::ASTExpr)
    (v isa VarExpr || v isa NumExpr || v isa IntExpr) && return !(v isa VarExpr && occursin(_TPL_SENTINEL, v.name))
    v isa OpExpr || return false
    if v.op == "index" && _tpl_structless(v) && length(v.args) >= 2 && v.args[1] isa VarExpr
        a = v.args[1]::VarExpr
        (_tpl_is_sentinel(a.name) || occursin(_TPL_SENTINEL, a.name)) && return false
        return all(_tpl_inlinable, @view v.args[2:end])
    end
    (v.op in _TPL_CALL_OPS && v.op != "const" && _tpl_structless(v) && !_tpl_is_call(v)) || return false
    isempty(_bound_symbols(v)) || return false
    return all(_tpl_inlinable, v.args)
end

# The names a template's prepared body binds (reduction and output indices):
# a binding's name of the same spelling is captured there, as the expansion
# captures it.
function _tpl_body_binders(tt::_TplTable, name)
    memo = _tpl_memo(tt, nothing, :body_binders, () -> Dict{String, Set{String}}())
    return get!(memo, String(name)) do
        def = _tpl_def(tt, name)
        out = Set{String}()
        def.closed === nothing && return out
        seen = IdDict{OpExpr, Nothing}()
        function walk(e)
            e isa OpExpr || return
            haskey(seen, e) && return
            seen[e] = nothing
            union!(out, _bound_symbols(e))
            foreach_child(walk, e)
        end
        b = def.closed.body
        # An array-valued body's output indices are no binders of its element
        # body (the element call reads them as arguments).
        if b isa OpExpr && _is_faq_op(b.op) && b.output_idx !== nothing && !isempty(b.output_idx) && b.expr_body !== nothing
            b = b.expr_body
        end
        walk(b)
        out
    end
end

# Does `e` read (as a variable leaf) any of the names `B`?
function _tpl_reads_any(e::ASTExpr, B::Set{String})
    e isa VarExpr && return e.name in B
    e isa OpExpr || return false
    r = false
    foreach_child(c -> (r = r || _tpl_reads_any(c, B)), e)
    return r
end

# The sentinels of `call`'s template read as arrays (`nothing` when the build
# does not call it).
function _tpl_array_slots(tt::_TplTable, name)
    info = _tpl_call_info(tt, name)
    return info === nothing ? nothing : info.arrays
end

"""
    _operands(e::OpExpr) -> AbstractVector{ASTExpr}

The operands of `e` as a value-level walker sees them: a template call's
arguments are its bindings (in name order), every other node's are its
`args`. A hand-written walker that recurses into `e.args` to find what an
expression computes from uses this instead, so a call's arguments are not
missed (the call's body is reached through the shared layer, never by
expanding).
"""
_operands(e::OpExpr) = _tpl_is_call(e) ? _call_operands(e) : e.args
function _call_operands(e::OpExpr)
    b = e.bindings
    b === nothing && return ASTExpr[]
    return ASTExpr[b[k] for k in sort!(collect(keys(b)))]
end
