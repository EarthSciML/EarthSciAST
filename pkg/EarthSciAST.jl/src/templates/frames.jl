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

The table reads a COPY of `reg` (a shallow one: the declarations are shared,
never mutated). What it registers — a structural instance
(`_tpl_register_instance!`), a view part (`_tpl_skel`) — is the table's own and
never reaches the caller's registry. A validation or analysis table is built on
a document's own registry (`file.component_templates`), and an instance left
there would be read later as one of the document's declarations: flatten closes
every declaration (`_tpl_explicit_free`), which makes the names an instance's
body was substituted with into parameters again, so its instance would be a
structural template that no build can call.
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
    reg isa AbstractDict ? copy(reg) : reg, Dict{String, _TplDef}(), Dict{Tuple{String, String}, _TplClosed}(),
    Dict{String, _TplFrame}(), IdDict{Any, IdDict{ASTExpr, String}}(), Set{String}(),
    Dict{Symbol, Any}()
)

# A per-walk memo for `fr` (the table's own for the top level), made by `mk`
# on first use.
_tpl_memo(tt::_TplTable, ::Nothing, key::Symbol, mk) = get!(mk, tt.root_memos, key)
_tpl_memo(::_TplTable, fr::_TplFrame, key::Symbol, mk) = get!(mk, fr.memos, key)

_tpl_unknown(name) = ExpressionTemplateError(
    ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
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
            ERROR_CODES.OPERATOR_INVALID_DEFINITION,
            "expression template '$name' references itself"
        )
    )
    push!(tt.preparing, String(name))
    try
        decl = _TemplateDecl(tt.reg[name])
        raw = decl.body
        typed = expression_from_json(raw)
        fed = _tpl_feeds_structural(tt, typed)
        structural = String[p for p in decl.params if _raw_count(raw, p) != _leaf_count(typed, p) || p in fed]
        closed = isempty(structural) ? _tpl_close(tt, String(name), decl, Dict{String, Any}()) : nothing
        d = _TplDef(String(name), decl.params, structural, closed)
        tt.defs[String(name)] = d
        return d
    finally
        delete!(tt.preparing, String(name))
    end
end

# The names `body` passes, as a bare name, to a structural parameter of a
# template it references: `T(q = p)` with `q` structural in `T`. Such a `p`,
# when it is a parameter of the body's template, is structural there too —
# its value lands in `T`'s structural position — so the reference is read
# through an instance of the body's template, in which `T(q = <name>)` is
# itself re-pointed at `T`'s instance. (Closing makes a `join` name a body
# reads a parameter, `_tpl_explicit_free`, and an enclosing template that
# passes its own parameter on is the common shape.)
function _tpl_feeds_structural(tt::_TplTable, body::ASTExpr)
    fed = Set{String}()
    visit(x) = begin
        (
            _tpl_is_call(x) && x.name isa AbstractString && x.bindings !== nothing &&
                tt.reg !== nothing && haskey(tt.reg, x.name)
        ) || return nothing
        for q in _tpl_def(tt, x.name).structural
            v = get(x.bindings, q, nothing)
            v isa VarExpr && push!(fed, v.name)
        end
        return nothing
    end
    visit(body)
    foreach_subexpr(visit, body)
    return fed
end

# The prepared body of `name` with the structural parameters substituted by
# `S` (parameter => raw value). A nested reference whose structural bindings
# are then names or numbers reads its instance (`_tpl_structural_refs`).
function _tpl_close(tt::_TplTable, name::String, decl::_TemplateDecl, S::Dict{String, Any})
    sub = Dict{String, Any}()
    for p in decl.params
        sub[p] = haskey(S, p) ? S[p] : _TPL_ARG * p
    end
    typed = expression_from_json(_substitute(decl.body, sub))
    typed = _tpl_structural_refs(tt, typed)
    # `broadcast(fn = F, …)` is `F(…)` (esm-spec §4.3.4), lowered in a body as
    # the build lowers it in the model's own tree (an invalid `fn` is left for
    # the build to refuse).
    typed = _tpl_lower_broadcast(typed, IdDict{OpExpr, ASTExpr}())
    typed = _tpl_augment(tt, typed)
    typed = _tpl_elem_reads(tt, typed)
    typed = _tpl_body_lift(tt, typed, IdDict{OpExpr, ASTExpr}())
    typed = _tpl_lift_root_ref(tt, typed)
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
    r = _tpl_const_table_read(tt, r)
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

# The literal `const` array a reference denotes when its template has no
# parameters and its body is that literal (a lookup table, `duo_tile_map`);
# `nothing` otherwise. One node per template, so every read of the table
# shares it (one interned const array).
function _tpl_const_table(tt::_TplTable, call)
    (call isa OpExpr && _tpl_is_call(call) && !_tpl_is_elem(call)) || return nothing
    memo = _tpl_memo(tt, nothing, :const_table, () -> Dict{String, Any}())
    return get!(memo, call.name) do
        def = try
            _tpl_def(tt, call.name)
        catch err
            err isa ExpressionTemplateError || rethrow()
            return nothing
        end
        (isempty(def.params) && def.closed !== nothing) || return nothing
        b = def.closed.body
        (b isa OpExpr && b.op == "const" && b.value isa AbstractVector && isempty(def.closed.free)) || return nothing
        b
    end
end

# `index(ref, s…)` of a reference that denotes a literal table
# (`_tpl_const_table`) read as `index(<the literal>, s…)`: a constant, which
# every phase reads as it reads an inline `const` array.
function _tpl_const_table_read(tt::_TplTable, r::OpExpr)
    (r.op == "index" && _tpl_structless(r) && length(r.args) >= 2) || return r
    c = _tpl_const_table(tt, r.args[1])
    c === nothing && return r
    return reconstruct(r; args = ASTExpr[c, r.args[2:end]...])
end

# `e` with every `broadcast` whose `fn` is admissible lowered to its operator
# (tree_walk/build_equation_prep.jl `_lower_broadcast_node`).
function _tpl_lower_broadcast(e::ASTExpr, memo::IdDict{OpExpr, ASTExpr})
    e isa OpExpr || return e
    r = get(memo, e, nothing)
    r === nothing || return r
    r = map_children(c -> _tpl_lower_broadcast(c, memo), e)
    if r.op == "broadcast" && _broadcast_fn_problem(r.fn, length(r.args)) === nothing
        r = OpExpr(String(r.fn), copy(r.args))
    end
    memo[e] = r
    return r
end

# THE ELEMENTWISE LIFT IN A BODY. An elementwise operator in a body whose
# operands include whole array-valued references (`2.5 * interior(f)`, all of
# one rank over the same ranges) or array-valued `faq`s over their output
# indices only (`pi * faq(i, R, e)`), and otherwise scalars, is the array whose
# element at `o…` is the operator over each reference's ELEMENT call at `o…`
# (call.jl `_elem_call`), each `faq`'s expression at `o…`, and the scalars:
#
#     2.5 * interior(f)  ==  faq(output_idx = o, ranges = R, expr = 2.5 * interior(f)[o])
#     pi * faq(i, R, e)  ==  faq(output_idx = o, ranges = R, expr = pi * e[i => o])
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
            isempty(_bound_symbols(r)) && any(a -> _tpl_whole_arr(tt, a) !== nothing, r.args)
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

# An array-valued `faq` over its output indices only (no reduction, filter or
# join): its output indices and ranges, else `nothing`.
function _tpl_whole_faq(a)
    (a isa OpExpr && _is_faq_op(a.op) && a.output_idx !== nothing && !isempty(a.output_idx)) || return nothing
    all(x -> x isa AbstractString, a.output_idx) || return nothing
    (
        a.expr_body !== nothing && a.ranges !== nothing && a.filter === nothing && a.join === nothing &&
            a.join_gates === nothing && a.key === nothing && a.values === nothing && a.lower === nothing &&
            a.upper === nothing && all(x -> x isa VarExpr, a.args)
    ) || return nothing
    outs = String[String(x) for x in a.output_idx]
    (length(a.ranges) == length(outs) && all(o -> haskey(a.ranges, o), outs)) || return nothing
    return outs, a.ranges
end

# A whole array operand of an elementwise operator in a body (above).
_tpl_whole_arr(tt::_TplTable, a) = (w = _tpl_whole_ref(tt, a); w === nothing ? _tpl_whole_faq(a) : w)

# The element of the whole array operand `a` at `subs`.
function _tpl_whole_elem(tt::_TplTable, a::OpExpr, subs::Vector{ASTExpr})
    _tpl_whole_ref(tt, a) === nothing || return _elem_call(tt, a, subs)
    outs, _ = _tpl_whole_faq(a)
    m = Dict{String, ASTExpr}(o => subs[k] for (k, o) in enumerate(outs))
    return _tpl_subst_scoped(a.expr_body, m, IdDict{OpExpr, ASTExpr}())
end

function _tpl_range_same(x, y)
    x isa IndexSetRef && y isa IndexSetRef && return x.from == y.from && x.of == y.of
    x isa AbstractVector && y isa AbstractVector && return length(x) == length(y) &&
        all(
        ((p, q),) -> (p isa Integer || p isa IntExpr) && (q isa Integer || q isa IntExpr) &&
            Int(p isa IntExpr ? p.value : p) == Int(q isa IntExpr ? q.value : q), zip(x, y)
    )
    return false
end

function _tpl_lift_whole(tt::_TplTable, r::OpExpr)
    shape = nothing
    for a in r.args
        w = _tpl_whole_arr(tt, a)
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
    args = ASTExpr[_tpl_whole_arr(tt, a) === nothing ? a : _tpl_whole_elem(tt, a::OpExpr, subs) for a in r.args]
    ranges = Dict{String, Any}(n => shape[k] for (k, n) in enumerate(oi))
    return OpExpr(
        "faq", ASTExpr[]; output_idx = Any[oi...], ranges = ranges,
        expr_body = reconstruct(r; args = args)
    )
end

# A body that is itself a whole array-valued reference — the body of a rule
# that forwards to a stencil template, which a firing references (esm-spec
# §9.6.3 constraint 7) — is that reference read at each output index:
#
#     interior(f)  ==  faq(output_idx = o, ranges = R, expr = interior(f)[o])
#
# The reference stays a reference (its element call); the template is then
# array-valued and called through its element like any other.
function _tpl_lift_root_ref(tt::_TplTable, r::ASTExpr)
    r isa OpExpr || return r
    w = _tpl_whole_ref(tt, r)
    w === nothing && return r
    outs, rg = w
    used = Set{String}()
    foreach_subexpr(x -> x isa VarExpr && push!(used, x.name), r)
    oi = String[]
    for k in eachindex(outs)
        n = string("i", k)
        while n in used || n in oi
            n *= "′"
        end
        push!(oi, n)
    end
    subs = ASTExpr[VarExpr(n) for n in oi]
    ranges = Dict{String, Any}(n => rg[outs[k]] for (k, n) in enumerate(oi))
    return OpExpr(
        "faq", ASTExpr[]; output_idx = Any[oi...], ranges = ranges,
        expr_body = _elem_call(tt, r, subs)
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
    iname = _tpl_register_instance!(tt, call.name, S)
    nb = Dict{String, ASTExpr}(k => v for (k, v) in b if !haskey(S, k))
    return reconstruct(call; name = iname, bindings = nb)
end

# The name of the instance of template `name` with the parameters in `S`
# (parameter => raw value) substituted, registered in `tt.reg` on first use:
# the declaration with those values substituted into its body and those
# parameters dropped.
function _tpl_register_instance!(tt::_TplTable, name::AbstractString, S::Dict{String, Any})
    skey = join(sort!([k * "=" * _stable_json(v) for (k, v) in S]), ",")
    iname = string(name, _TPL_INST, skey)
    if !haskey(tt.reg, iname)
        raw = tt.reg[name]
        decl = _TemplateDecl(raw)
        nd = OrderedDict{String, Any}()
        for (k, v) in pairs(raw)
            nd[string(k)] = v
        end
        nd["params"] = Any[p for p in decl.params if !haskey(S, p)]
        body = _substitute(decl.body, S)
        # A nested reference the substitution gave name or number structural
        # bindings (`_tpl_feeds_structural`) reads its own instance, in the
        # declaration too: the view parts are cut from it (`_tpl_skel`).
        tb = expression_from_json(body)
        rb = _tpl_structural_refs(tt, tb)
        nd["body"] = rb === tb ? body : serialize_expression(rb)
        tt.reg[iname] = nd
    end
    return iname
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

# The names `e` reads through a `join` clause and does not bind itself: an
# `on` clause's key columns and an `overlap` clause's envelope factors. They
# are plain strings, not variable leaves, yet name variables exactly as a leaf
# does — the same names component namespacing scopes (`_namespace_join`). A
# column naming a loop symbol of its node or of an enclosing one is a binder,
# not a read.
function _tpl_free_join_names(e::ASTExpr)
    out = Set{String}()
    _tpl_free_join_names!(out, e, Set{String}(), IdDict{OpExpr, Nothing}())
    return out
end
function _tpl_free_join_names!(out, e::ASTExpr, bound::Set{String}, seen)
    e isa OpExpr || return
    b = _bound_symbols(e)
    inner = isempty(b) ? bound : union(bound, b)
    if isempty(inner)
        # A shared node under no binder reads the same names.
        haskey(seen, e) && return
        seen[e] = nothing
    end
    if e.join !== nothing
        add(n) = (s = String(n); (s in inner || _tpl_is_sentinel(s)) || push!(out, s); nothing)
        for clause in e.join
            if clause isa _OverlapJoinSpec
                foreach(add, clause.src_env)
                foreach(add, clause.tgt_env)
            else
                for (l, r) in clause
                    add(l)
                    add(r)
                end
            end
        end
    end
    foreach_child(c -> _tpl_free_join_names!(out, c, inner, seen), e)
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
                ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
                "apply_expression_template '$name' missing binding for param '$p'"
            )
        )
    end
    # A lane (`"\0lane\0k"`, call.jl `_tpl_with_lanes`) is a read the caller
    # makes for the body, derived from the other bindings, which it keeps: the
    # frame reads the instance body itself, so a lane is no argument of it.
    for k in keys(bind)
        (k in def.params || startswith(k, _TPL_FREE) || startswith(k, _TPL_OUT) || startswith(k, _TPL_LANE)) || throw(
            ExpressionTemplateError(
                ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
                "apply_expression_template '$name' supplies unknown param '$k'"
            )
        )
    end
    S = Dict{String, Any}()
    for p in def.structural
        x, xf = _tpl_leaf(bind[p], parent)
        (x isa VarExpr || x isa NumExpr || x isa IntExpr) || throw(
            ExpressionTemplateError(
                ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
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

# The binding of the frame argument `k` (a sentinel) as the reference `call`
# writes it: `"\0arg\0p"` is the binding of parameter `p`, `"\0free\0n"`
# the implicit binding (the name `n` itself when the reference carries none),
# as `_tpl_frame` makes them.
function _tpl_call_binding(call::OpExpr, k::String)
    b = call.bindings
    if startswith(k, _TPL_FREE)
        v = b === nothing ? nothing : get(b, k, nothing)
        return v === nothing ? VarExpr(k[(ncodeunits(_TPL_FREE) + 1):end]) : v
    end
    startswith(k, _TPL_ARG) || throw(ArgumentError("not a frame argument: $(repr(k))"))
    return b[k[(ncodeunits(_TPL_ARG) + 1):end]]
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

"""
    _tpl_step(visit, tt, e, fr) -> Bool

One step of a walk that reads `e` (in the frame `fr`) as its expansion reads
it, without building the expansion: when `e` is a parameter sentinel,
`visit(binding, binding_frame)` (the binding, read in the frame that bound
it); when it is a reference, `visit(body, instance_frame)` (its instance's
prepared body, read in the instance's frame) and then `visit(subscript, fr)`
for each element subscript (an element call's body is the whole array, read
as the expansion's `index(<array>, subscripts…)` reads it). Returns `true`
when it stepped, `false` when `e` is an ordinary node the walker handles
itself — as it is for a reference whose template cannot be read
(`ExpressionTemplateError`, reported by the template checks) or with no table
(`tt === nothing`). Frames are memoized per instance, so a walker that
memoizes per (node, frame) reads each body once per instance.
"""
function _tpl_step(visit, tt, e::ASTExpr, fr::Union{Nothing, _TplFrame})
    if e isa VarExpr
        (fr !== nothing && _tpl_is_sentinel(e.name)) || return false
        b, bf = _tpl_arg(fr, e.name)
        visit(b, bf)
        return true
    end
    (tt !== nothing && _tpl_is_call(e)) || return false
    sub = _tpl_frame_or_nothing(tt, e::OpExpr, fr)
    sub === nothing && return false
    visit(sub.body, sub)
    for s in _tpl_out_bindings(e::OpExpr)
        visit(s, fr)
    end
    return true
end

# `_tpl_frame`, or `nothing` for a reference whose template cannot be read.
function _tpl_frame_or_nothing(tt::_TplTable, call::OpExpr, fr::Union{Nothing, _TplFrame})
    return try
        _tpl_frame(tt, call, fr)
    catch err
        err isa ExpressionTemplateError || rethrow()
        nothing
    end
end

# The subscripts of an element call (`_elem_call`), in output order; empty for
# any other node.
function _tpl_out_bindings(call::OpExpr)
    b = call.bindings
    b === nothing && return ASTExpr[]
    ks = sort!([k for k in keys(b) if startswith(k, _TPL_OUT)])
    return ASTExpr[b[k] for k in ks]
end

"""
    _tpl_reads_binding(tt, call, k) -> Bool

Whether the binding `k` of the reference `call` is read as an expression by the
reference's expansion (`_tpl_body_reads`): an element subscript always; a
declared parameter's when the body reads it as a value somewhere — not only in
a structural position (a range's `from`, `wrt`, an op name, where it is a name
substituted in place), directly or through a nested reference; an implicit
parameter's (`"\0free\0n"`) when the body reads `n` from the caller, not only
inside a scope of its own that captures it. A name-reading analysis visits exactly these bindings of a reference,
treats no binding key as a binder of the caller's names, and reads a declared
parameter's binding with the body's own binders in scope
(`_tpl_scope_binders`), where the expansion substitutes it. `true` for a
reference whose template cannot be read (the template checks report it).
"""
function _tpl_reads_binding(tt::_TplTable, call::OpExpr, k::AbstractString)
    startswith(k, _TPL_OUT) && return true
    try
        return _tpl_binding_sentinel(k) in _tpl_body_reads(tt, call.name)
    catch err
        err isa ExpressionTemplateError || rethrow()
        return true
    end
end

# The body of `name` for the name analyses: every parameter a sentinel, the
# nested references carrying their implicit parameters, and every name read
# from the caller the sentinel `"\0free\0n"` (as `_tpl_close` prepares it,
# without the build's lowerings, which change no name).
function _tpl_names_body(tt::_TplTable, name)
    memo = _tpl_memo(tt, nothing, :names_body, () -> Dict{String, ASTExpr}())
    return get!(memo, String(name)) do
        def = _tpl_def(tt, name)
        decl = _TemplateDecl(tt.reg[def.name])
        sub = Dict{String, Any}(p => _TPL_ARG * p for p in decl.params)
        typed = _tpl_augment(tt, expression_from_json(_substitute(decl.body, sub)))
        free = _tpl_free_leaves(typed)
        isempty(free) && return typed
        m = Dict{String, ASTExpr}(n => VarExpr(_TPL_FREE * n) for n in free)
        _tpl_subst_scoped(typed, m, IdDict{OpExpr, ASTExpr}())
    end
end

# Every name the body of `name` binds anywhere (loop, output and integration
# indices): a binding the expansion substitutes into the body may be captured
# by any of them (read wide, as the build reads a binding's capture).
function _tpl_scope_binders(tt::_TplTable, name)
    memo = _tpl_memo(tt, nothing, :scope_binders, () -> Dict{String, Set{String}}())
    return get!(memo, String(name)) do
        out = Set{String}()
        seen = IdDict{OpExpr, Nothing}()
        function walk(e)
            e isa OpExpr || return
            haskey(seen, e) && return
            seen[e] = nothing
            union!(out, _bound_symbols(e))
            return foreach_child(walk, e)
        end
        walk(_tpl_names_body(tt, name))
        out
    end
end

# The parameter sentinels the expansion of `name` reads as values: each
# declared parameter (`"\0arg\0p"`) the body reads as a variable leaf, directly
# or in a binding a nested reference reads (`_tpl_reads_binding`); each implicit
# parameter (`"\0free\0n"`) likewise, less one read only inside a binding of a
# nested reference whose own body binds `n` (the expansion captures it there).
function _tpl_body_reads(tt::_TplTable, name)
    memo = _tpl_memo(tt, nothing, :body_reads, () -> Dict{String, Set{String}}())
    return get!(memo, String(name)) do
        out = Set{String}()
        function walk(e, captured)
            if e isa VarExpr
                if startswith(e.name, _TPL_FREE)
                    e.name[(ncodeunits(_TPL_FREE) + 1):end] in captured || push!(out, e.name)
                elseif startswith(e.name, _TPL_ARG)
                    push!(out, e.name)
                end
                return
            end
            e isa OpExpr || return
            if _tpl_is_call(e)
                foreach(a -> walk(a, captured), e.args)
                b = e.bindings
                b === nothing && return
                for (k, v) in b
                    _tpl_reads_binding(tt, e, k) || continue
                    inner = (startswith(k, _TPL_FREE) || startswith(k, _TPL_OUT)) ? captured :
                        union(captured, _tpl_scope_binders(tt, e.name))
                    walk(v, inner)
                end
                return
            end
            return foreach_child(c -> walk(c, captured), e)
        end
        walk(_tpl_names_body(tt, name), Set{String}())
        out
    end
end

# The parameter sentinels the expansion of `name` reads ONLY in index space:
# inside a subscript of an `index` (its operands after the array), directly or
# through a nested reference that reads its own parameter only there. Where the
# expansion substitutes such a binding, every name in it is a loop index of
# that `index` (the reference check's subscript-position rule,
# validation/references.jl `_bound_index_symbols`), so the binding binds the
# caller to no name of its scope.
function _tpl_index_reads(tt::_TplTable, name)
    memo = _tpl_memo(tt, nothing, :index_reads, () -> Dict{String, Set{String}}())
    haskey(memo, String(name)) && return memo[String(name)]
    memo[String(name)] = Set{String}()      # (the template graph is acyclic)
    inidx = Set{String}()
    outside = Set{String}()
    function walk(e, idx::Bool)
        if e isa VarExpr
            _tpl_is_sentinel(e.name) && push!(idx ? inidx : outside, e.name)
            return
        end
        e isa OpExpr || return
        if _tpl_is_call(e)
            foreach(a -> walk(a, idx), e.args)
            b = e.bindings
            b === nothing && return
            inner = try
                _tpl_index_reads(tt, e.name)
            catch err
                err isa ExpressionTemplateError || rethrow()
                Set{String}()
            end
            for (k, v) in b
                _tpl_reads_binding(tt, e, k) || continue
                walk(v, idx || _tpl_binding_sentinel(k) in inner)
            end
            return
        end
        for (j, a) in enumerate(e.args)
            walk(a, idx || (e.op == "index" && j >= 2))
        end
        foreach_child(c -> any(x -> x === c, e.args) || walk(c, false), e)
        return
    end
    walk(_tpl_names_body(tt, name), false)
    return memo[String(name)] = setdiff(inidx, outside)
end

"""
    _tpl_ground(tt, e, fr) -> ASTExpr

`e`, read in `fr`, with every parameter sentinel leaf replaced by its binding
(itself grounded in the frame that bound it): the expression as the caller
spells it. For the small expressions an analysis reports from inside a body (a
self-read's subscripts), never for a body itself; a reference inside `e` is
kept as it is.
"""
function _tpl_ground(tt, e::ASTExpr, fr::Union{Nothing, _TplFrame})
    fr === nothing && return e
    if e isa VarExpr
        _tpl_is_sentinel(e.name) || return e
        b, bf = _tpl_arg(fr, e.name)
        return _tpl_ground(tt, b, bf)
    end
    e isa OpExpr || return e
    return map_children(c -> _tpl_ground(tt, c, fr), e)
end

# The template table of the top-level component `<kind>.<name>` of `file`
# (`kind` is "models" or "reaction_systems"), or `nothing` when it has no
# surviving reference. Its subsystems read the same registry.
function _tpl_component_table(file::EsmFile, kind::AbstractString, name::AbstractString)
    ct = file.component_templates
    ct === nothing && return nothing
    reg = get(ct, "$kind.$name", nothing)
    return reg === nothing ? nothing : _TplTable(reg)
end
# The same, read from `tables` — a validation pass's `_ValidationContext.tables`,
# which holds each top-level component's one table — when the caller built them.
_tpl_component_table(file::EsmFile, kind::AbstractString, name::AbstractString, ::Nothing) =
    _tpl_component_table(file, kind, name)
_tpl_component_table(::EsmFile, kind::AbstractString, name::AbstractString, tables::AbstractDict) =
    get(tables, "$kind.$name", nothing)

# `m` (a model or reaction system) with every reference carrying its implicit
# parameters (`_tpl_augment`): the names a referenced body reads are then
# reads of the reference itself. In place, so the caller passes a copy.
# `tt` is the component's template table when the caller has one.
function _tpl_augment_component!(m, reg, tt::Union{Nothing, _TplTable} = nothing)
    reg === nothing && return m
    tt === nothing && (tt = _TplTable(reg))
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

"""
    _tpl_explicit_free(block) -> (block′, added)

`block` (a component's raw template registry) with every match-less body's
free names made EXPLICIT parameters: a name a body reads from its caller (a
variable leaf, or a `join` key column or overlap envelope factor, that it does
not bind and that is not one of its parameters, read directly or through a
nested reference) is appended, sorted, to its `params`,
and every nested reference in a body binds its callee's added parameters to
the same names (`_tpl_bind_explicit`). `added` maps each changed template to
the parameters it gained, for the call sites (`_tpl_bind_explicit`).

Expansion substitutes a body into its call site, where the site's scope then
renames the body's free names; binding each free name to itself at the site
gives the same names in the same scope, so the reference denotes the same
expansion, and a rename at the site (namespacing, a coupling substitution)
reaches the body's reads through the bindings. Used by flatten for
reaction-rate references (the user's decision of 2026-11-20).
"""
function _tpl_explicit_free(block)
    added = Dict{String, Vector{String}}()
    (block === nothing || !_is_object(block)) && return (block, added)
    newdecl = Dict{String, Any}()
    visiting = Set{String}()
    function visit(name::String)
        (haskey(newdecl, name) || name in visiting) && return
        push!(visiting, name)
        decl = _raw_get(block, name)
        td = _TemplateDecl(decl)
        if td.body === nothing || td.match !== nothing
            newdecl[name] = decl
            return
        end
        typed = expression_from_json(td.body)
        callees = Set{String}()
        f(x) = (_tpl_is_call(x) && x.name isa AbstractString && push!(callees, String(x.name)); nothing)
        f(typed)
        foreach_subexpr(f, typed)
        for c in callees
            _raw_haskey(block, c) && visit(c)
        end
        bound = _tpl_bind_explicit(typed, added)
        free = sort!(collect(setdiff(union(_tpl_free_leaves(bound), _tpl_free_join_names(bound)), td.params)))
        if bound === typed && isempty(free)
            newdecl[name] = decl
            return
        end
        nd = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(decl))
        bound === typed || (nd["body"] = serialize_expression(bound))
        if !isempty(free)
            nd["params"] = Any[td.params..., free...]
            added[name] = free
        end
        newdecl[name] = nd
        return
    end
    for (k, _) in pairs(block)
        visit(string(k))
    end
    out = OrderedDict{String, Any}(string(k) => newdecl[string(k)] for (k, _) in pairs(block))
    return (out, added)
end

"""
    _tpl_bind_explicit(e, added) -> ASTExpr

`e` with every reference to a template of `added` (`_tpl_explicit_free`)
binding each added parameter to the same name, `n => n`. A binding the
reference already has is kept.
"""
function _tpl_bind_explicit(
        e::ASTExpr, added::AbstractDict{String, Vector{String}},
        memo::IdDict{OpExpr, ASTExpr} = IdDict{OpExpr, ASTExpr}()
    )
    (isempty(added) || !(e isa OpExpr)) && return e
    r = get(memo, e, nothing)
    r === nothing || return r
    out = map_children(c -> _tpl_bind_explicit(c, added, memo), e)
    if _tpl_is_call(out) && out.name isa AbstractString
        names = get(added, String(out.name), nothing)
        if names !== nothing
            b = out.bindings === nothing ? Dict{String, ASTExpr}() : copy(out.bindings)
            for n in names
                haskey(b, n) || (b[n] = VarExpr(n))
            end
            out = reconstruct(out; bindings = b)
        end
    end
    memo[e] = out
    return out
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

# A binding the caller evaluates and passes as a value whatever the body does
# with it: a name or a literal.
_tpl_value_leaf(b::ASTExpr) = b isa VarExpr || b isa NumExpr || b isa IntExpr

# A binding passed as a value when the body reads it on every path, and made
# in the caller without a compiled instance of its own: a name, a literal or a
# plain read of a named array.
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
        (
            body.filter === nothing && body.join_gates === nothing && body.join === nothing &&
                body.key === nothing && body.expr_body !== nothing && all(a -> a isa VarExpr, body.args) &&
                body.values === nothing && body.lower === nothing && body.upper === nothing
        ) || return nothing
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

# The size of the index set a range `{"from": S}` names, from the build's
# registry (set at the build entry): an interval's size, a derived set's
# extent from value invention; `nothing` otherwise (a ragged range, no
# registry in reach).
function _tpl_iset_extent(tt::_TplTable, rv::IndexSetRef)
    isempty(rv.of) || return nothing
    sets = get(tt.root_memos, :index_sets, nothing)
    sets === nothing && return nothing
    s = get(sets, rv.from, nothing)
    s isa IndexSet || return nothing
    s.kind == "interval" && s.size isa Int && return s.size::Int
    # A derived set the front door's value invention has sized.
    if s.kind == "derived" && s.from_faq !== nothing
        ext = get(tt.root_memos, :vi_extents, nothing)
        e = ext === nothing ? nothing : get(ext, s.from_faq, nothing)
        e === nothing || return Int(e)
    end
    return nothing
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
        (
            e.join_gates === nothing && e.join === nothing && e.key === nothing &&
                e.values === nothing && e.lower === nothing && e.upper === nothing
        ) || return false
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
    (v isa VarExpr && !occursin(_TPL_SENTINEL, v.name)) ||
    (v isa OpExpr && v.op == "const" && v.value isa AbstractVector)

# The form an array-valued `faq` must have for the build to read it as an array
# over its output indices: no reduction (every range is an output index's),
# filter, join, key, `values` table or bounds, and a body. Shared by the lazy
# route below and the buffered one (`_tpl_buffered_array_expr`).
function _tpl_elementwise_faq_form(v::OpExpr)
    _is_faq_op(v.op) || return false
    oi = v.output_idx
    (oi !== nothing && !isempty(oi) && all(x -> x isa AbstractString, oi)) || return false
    (
        v.filter === nothing && v.join_gates === nothing && v.join === nothing &&
            v.key === nothing && v.expr_body !== nothing && v.values === nothing &&
            v.lower === nothing && v.upper === nothing && all(a -> a isa VarExpr, v.args)
    ) || return false
    return v.ranges === nothing || all(k -> String(k) in oi, keys(v.ranges))
end

# An ARRAY EXPRESSION bound to an array parameter: an elementwise `faq` over
# its output indices (no reduction, filter or join), whose element is read
# lazily: where the body reads the parameter at subscripts `s…`, the element
# with each output index read as `s` is evaluated there, at that cell, and
# nowhere else (call.jl, "Array expressions compiled into the instance"). No
# buffer holds it and the body is not inlined. The form alone; with the
# template table `tt`, also an element the build compiles into the instance
# (`_tpl_inlinable`).
function _tpl_array_expr(v::ASTExpr, tt::Union{Nothing, _TplTable} = nothing)
    (v isa OpExpr && _tpl_elementwise_faq_form(v)) || return false
    return tt === nothing || _tpl_inlinable(v.expr_body, tt)
end

# A COMPUTED ARRAY bound to an array parameter that is not an elementwise
# `faq` read lazily (above): a `makearray`, a `faq` with output indices whose
# element is no compiled-in expression, or a whole-array reference, read as its
# view. The build evaluates it once in the caller, into a buffer of its own (an
# internal array observed, call.jl `_hoist_array_arguments`), and passes that
# buffer as the argument, as it passes a named array. Nothing is expanded: the
# reference stays a call and the computed array is its argument. A `makearray`
# or `faq` qualifies only when its extents are build-time integers
# (`_argarr_extents`); a reference's are those of its view, known only once it
# is read as one (call.jl `_hoist_array_arguments` refuses it otherwise).
function _tpl_buffered_array_expr(v::ASTExpr, tt::_TplTable)
    v isa OpExpr || return false
    _tpl_is_call(v) && return !_tpl_is_elem(v) &&
        (_tpl_view_rank(tt, v) > 0 || (_tpl_call_info(tt, v.name) === nothing && _tpl_skel(tt, v.name) !== nothing))
    v.op == "makearray" && return v.values !== nothing && _argarr_extents(tt, v) !== nothing
    _tpl_elementwise_faq_form(v) || return false
    return _argarr_extents(tt, v) !== nothing
end

# A binding of an array parameter that the build passes through a buffer of its
# own (`_tpl_buffered_array_expr`): not one it passes as it stands
# (`_call_passable_array`) or reads lazily (`_tpl_array_expr`).
_tpl_buffered_binding(b::ASTExpr, tt::_TplTable) =
    b isa OpExpr && !_call_passable_array(b) && !_tpl_array_expr(b, tt) &&
    _tpl_buffered_array_expr(b, tt)

# The keys of the bindings of `call` that bind an array parameter (an explicit
# one or an implicit one, `_TPL_FREE`), the lanes and outputs of a laned call
# left out. Empty for a reference read through its view.
function _tpl_array_param_keys(tt::_TplTable, call::OpExpr)
    keys_ = String[]
    call.bindings === nothing && return keys_
    info = _tpl_call_info(tt, call.name)
    info === nothing && return keys_
    for k in keys(call.bindings)
        (startswith(k, _TPL_OUT) || startswith(k, _TPL_LANE)) && continue
        ((startswith(k, _TPL_FREE) ? k : _TPL_ARG * k) in info.arrays) && push!(keys_, k)
    end
    return keys_
end

# The extents of a computed array (`makearray` or array `faq`), each axis
# `[1, n]` (an array index starts at 1), as a list of `n`; `nothing` when one is
# not a build-time integer or an axis does not start at 1.
function _argarr_extents(tt::_TplTable, v::OpExpr)
    if v.op == "makearray"
        regs = v.regions
        (regs === nothing || isempty(regs)) && return nothing
        nd = length(regs[1])
        hi = zeros(Int, nd)
        for r in regs
            length(r) == nd || return nothing
            for d in 1:nd
                b = r[d]
                (length(b) == 2 && b[1] isa Integer && b[2] isa Integer) || return nothing
                b[1] >= 1 || return nothing
                b[2] >= b[1] - 1 || return nothing
                hi[d] = max(hi[d], b[2])
            end
        end
        return hi
    end
    (_is_faq_op(v.op) && v.output_idx !== nothing && v.ranges !== nothing) || return nothing
    n = Int[]
    for o in v.output_idx
        r = get(v.ranges, String(o), nothing)
        r === nothing && (r = get(v.ranges, Symbol(o), nothing))
        if r isa IndexSetRef
            e = _tpl_iset_extent(tt, r)
            e === nothing && return nothing
            push!(n, e)
        elseif r isa AbstractVector && length(r) == 2 && r[1] == 1 && r[2] isa Integer
            push!(n, Int(r[2]))
        else
            return nothing
        end
    end
    return n
end

"""
    _tpl_compiles(tt, call::OpExpr) -> Bool

Whether the build can compile the reference `call` as a call node (or read it
through its view). The build never expands a reference: one this refuses is a
build error (call.jl `_tpl_refuse_uncompiled`). See the section comment above.
"""
function _tpl_compiles(tt::_TplTable, call::OpExpr)
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
            _tpl_array_binding(v) || _tpl_array_expr(v, tt) || _tpl_buffered_array_expr(v, tt) ||
                return false
            continue
        end
        if s in info.fixed
            (v isa IntExpr || (v isa NumExpr && isinteger(v.value))) || return false
            continue
        end
        # A parameter the body never reads: its binding is never made.
        s in info.scalars || continue
        # A binding that reads a name the body binds (a reduction index the
        # body runs, or one a body it references binds, which the expansion
        # would capture) is compiled into the instance, read where that body
        # binds the name. A template call in it stays a call there.
        B = _tpl_capture_names(tt, call.name)
        if !isempty(B) && _tpl_reads_any(v, B)
            _tpl_inlinable(v, tt) || return false
            continue
        end
        s in info.uncond && continue
        # A compound binding the body reads only on some paths is compiled
        # INTO the instance (the user's bound-expression rule; call.jl
        # `_call_inlined`), when it is made of names, literals and
        # elementwise operators.
        # A template call in it stays a call inside the instance, evaluated
        # only where the body reads the parameter (`_tpl_inlinable` with `tt`).
        _tpl_plain_binding(v) || _tpl_inlinable(v, tt) || return false
    end
    # An implicit parameter read as an array is bound to the caller's name of
    # its spelling unless the reference carries it, possibly as an array
    # expression.
    for s in info.arrays
        startswith(s, _TPL_FREE) || continue
        v = get(b, s, nothing)
        v === nothing || _tpl_array_binding(v) || _tpl_array_expr(v, tt) ||
            _tpl_buffered_array_expr(v, tt) || return false
    end
    return true
end

# A compound binding the build compiles into its instance (`_call_inlined`):
# elementwise operators over names and literals, and reads of a named array;
# with the template table `tt`, also template calls the build compiles whose
# bindings are such expressions (the call stays a call inside the instance,
# so it is evaluated only where the body reads the parameter).
function _tpl_inlinable(v::ASTExpr, tt::Union{Nothing, _TplTable} = nothing)
    (v isa VarExpr || v isa NumExpr || v isa IntExpr) && return !(v isa VarExpr && occursin(_TPL_SENTINEL, v.name))
    v isa OpExpr || return false
    _tpl_is_call(v) && return tt !== nothing && _tpl_inlinable_call(v, tt)
    if v.op == "index" && _tpl_structless(v) && length(v.args) >= 2 && v.args[1] isa VarExpr
        a = v.args[1]::VarExpr
        (_tpl_is_sentinel(a.name) || occursin(_TPL_SENTINEL, a.name)) && return false
        return all(a -> _tpl_inlinable(a, tt), @view v.args[2:end])
    end
    # A read of an inline const table.
    if v.op == "index" && _tpl_structless(v) && length(v.args) >= 2 && v.args[1] isa OpExpr &&
            v.args[1].op == "const" && v.args[1].value isa AbstractVector
        return all(a -> _tpl_inlinable(a, tt), @view v.args[2:end])
    end
    (v.op in _TPL_CALL_OPS && v.op != "const" && _tpl_structless(v)) || return false
    isempty(_bound_symbols(v)) || return false
    return all(a -> _tpl_inlinable(a, tt), v.args)
end

# A template call inside a compiled-in binding (above): a scalar call the build
# compiles, each array argument a name or inline const array, each fixed one a
# literal, each value one compiled in as well (call.jl `_inl_mark`).
function _tpl_inlinable_call(v::OpExpr, tt::_TplTable)
    info = _tpl_call_info(tt, v.name)
    info === nothing && return false
    isempty(info.outs) || _tpl_is_elem(v) || return false
    _tpl_compiles(tt, v) || return false
    v.bindings === nothing && return true
    for (k, x) in v.bindings
        s = _tpl_binding_sentinel(k)
        if s in info.arrays
            _tpl_array_binding(x) || return false
        elseif s in info.fixed
            continue
        elseif startswith(k, _TPL_OUT) || startswith(k, _TPL_LANE) || s in info.scalars
            _tpl_inlinable(x, tt) || return false
        end
    end
    return true
end

# The sentinel a reference's binding key binds (`"\0arg\0p"` for a declared
# parameter `p`, the key itself for an implicit, output or lane binding).
_tpl_binding_sentinel(k::AbstractString) =
    startswith(k, _TPL_FREE) || startswith(k, _TPL_OUT) || startswith(k, _TPL_LANE) ? String(k) : _TPL_ARG * k

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
            return foreach_child(walk, e)
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

# The names a binding of a reference to `name` is CAPTURED by: those the
# template's prepared body binds (`_tpl_body_binders`), and through every
# reference in that body, the names the referenced template captures in turn,
# with the output indices of an array-valued one. The expansion substitutes a
# binding into the body, and a body passes it on into the bodies it
# references, so a name any of those binds is the binder's there, not the
# caller's (EarthSciAST Rust `captured_symbols`: the binders of the instance
# body and of every body it reaches). The library's narrow phase
# (`A_ij(i = i)` around `pairs(area = area_ij(i = i))`, whose `faq` binds
# `i`) reads its loop symbols this way.
function _tpl_capture_names(tt::_TplTable, name)
    memo = _tpl_memo(tt, nothing, :capture_names, () -> Dict{String, Set{String}}())
    got = get(memo, String(name), nothing)
    got === nothing || return got
    # The template graph is acyclic (esm-spec §9.7.3); the placeholder only
    # keeps a malformed registry from recursing forever.
    memo[String(name)] = Set{String}()
    out = copy(_tpl_body_binders(tt, name))
    def = _tpl_def(tt, name)
    if def.closed !== nothing
        seen = IdDict{OpExpr, Nothing}()
        function walk(e)
            e isa OpExpr || return
            haskey(seen, e) && return
            seen[e] = nothing
            if _tpl_is_call(e) && e.name isa AbstractString
                union!(out, _tpl_capture_names(tt, e.name))
                info = _tpl_call_info(tt, e.name)
                info === nothing || union!(out, info.outs)
            end
            return foreach_child(walk, e)
        end
        walk(def.closed.body)
    end
    return memo[String(name)] = out
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
