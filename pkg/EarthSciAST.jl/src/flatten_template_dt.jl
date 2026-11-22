# Structural time derivatives inside template bodies, resolved without
# expanding (esm-spec §9.6.4 rule 3, "Time derivatives"; esm-libraries-spec
# §4.7.5 step 3a).
#
# Flatten step 3a resolves a right-hand-side `D` by §4.2's table
# (`_deriv` in flatten.jl). A template body may hold such a `D` too, and the
# reference that names the template denotes its expansion (§9.6.4 rule 2), so
# the resolution must equal the resolution of the expansion. It is computed in
# the body, once per template (and per `wrt` literal where `wrt` is a
# parameter), never by substituting a body into a call site:
#
#   * a PARAMETER `p` under a structural `D` resolves to a fresh parameter
#     `p_dt`, which each reference binds to §4.2's resolution of `D(b)` for the
#     `b` it binds to `p`, computed at the reference;
#   * a REFERENCE to `S` under a structural `D` resolves to a reference to `S`'s
#     derivative entry `<S>.ddt` (the resolution of `S`'s whole body by this
#     same rule), bound to the reference's bindings plus the `q_dt` the entry
#     reads;
#   * every other name and literal resolves as at a call site.
#
# The resolved body replaces the template's body in the flattened registry, with
# the `p_dt` parameters appended, and every reference to it (from a call site,
# or from another body, transitively up the reference DAG) gains the `p_dt`
# bindings. Where the table answers nothing the `D` stays standing, and a
# reference whose `p_dt` cannot be resolved keeps pointing at the unresolved
# body (`<name>.unresolved` when other references resolve), so the
# `unlowered_operator` gate (§9.6.3 constraint 6) rejects the build exactly as
# it rejects the expansion.
#
# While the walk runs, a rewritten reference names a MARK (`_DT_MARK…`) instead
# of a registry entry: which entry a resolved body lands in (in place, a
# variant, `.unresolved`) depends on every reference the step reaches, so the
# names are settled once at the end (`_dt_place!`) and the marks renamed.

const _DT_MARK = "\0dt\0"

# One registry entry as step 3a reads it.
struct _DtTemplate
    name::String
    decl::Any
    params::Vector{String}
    body::ASTExpr
    # Parameters that sit in the `wrt` of a body `D` (directly, or forwarded to
    # a nested reference's such parameter): the instance carries whether each is
    # bound to `"t"`, which makes that `D` structural (§9.6.4 rule 3).
    wrt_params::Vector{String}
    # Whether the body holds a `D` that may be structural, or reaches a template
    # whose body does: only such a template's references can change.
    dbearing::Bool
    # Every name the body reads, and its parameters: a `p_dt` avoids them.
    reads::Set{String}
    # p => p_dt, filled on first use.
    dtnames::Dict{String, String}
end

# The resolution of one body (an instance's resolved body, or a derivative
# entry's body).
struct _DtResult
    body::ASTExpr
    # Parameters whose `p_dt` the body reads, in `params` order.
    needs::Vector{String}
    # Parameters read as `index(p, ℓ…)` under a `D`: one cell of a lifted state
    # (flatten.jl `_deriv`), so the reference must bind a lifted state there.
    indexed::Set{String}
    changed::Bool
end

# What a walk inside a body reads of its parameters' derivatives.
struct _DtAcc
    needs::Set{String}
    indexed::Set{String}
end
_DtAcc() = _DtAcc(Set{String}(), Set{String}())
function _dt_merge!(into::_DtAcc, from::_DtAcc)
    union!(into.needs, from.needs)
    union!(into.indexed, from.indexed)
    return into
end

# The body a walk is in: its template and its instance's `wrt` literals
# (parameter => bound to "t").
struct _DtBody
    tpl::_DtTemplate
    key::Dict{String, Bool}
end

mutable struct _DtState
    tendency::Dict{String, ASTExpr}
    definition::Dict{String, ASTExpr}
    time_invariant::Set{String}
    lifted_shapes::AbstractDict
    reg::AbstractDict{String, Any}
    tpl::Dict{String, Union{Nothing, _DtTemplate}}
    tpl_busy::Set{String}
    # (template, instance key) => result; `nothing` while it is being resolved.
    res::Dict{Tuple{String, String}, Union{Nothing, _DtResult}}
    # template => derivative entry; `nothing` when the table cannot answer, or
    # while it is being computed.
    ddt::Dict{String, Union{Nothing, _DtResult}}
    unres::Dict{String, ASTExpr}
    # mark => (:res | :unres | :ddt, template, instance key)
    marks::Dict{String, Tuple{Symbol, String, String}}
end

_DtState(tendency, definition, time_invariant, lifted_shapes, reg) = _DtState(
    tendency, definition, time_invariant, lifted_shapes, reg,
    Dict{String, Union{Nothing, _DtTemplate}}(), Set{String}(),
    Dict{Tuple{String, String}, Union{Nothing, _DtResult}}(),
    Dict{String, Union{Nothing, _DtResult}}(), Dict{String, ASTExpr}(),
    Dict{String, Tuple{Symbol, String, String}}()
)

function _dt_mark(st::_DtState, kind::Symbol, name::String, key::String = "")
    m = string(_DT_MARK, kind, '\0', name, '\0', key)
    st.marks[m] = (kind, name, key)
    return m
end

# The registry entry `name`, read once; `nothing` for a name the registry does
# not hold (the template checks report it) or a reference cycle (refused at
# registration, §9.7.3).
function _dt_template(st::_DtState, name)
    name isa AbstractString || return nothing
    n = String(name)
    haskey(st.tpl, n) && return st.tpl[n]
    (haskey(st.reg, n) && !(n in st.tpl_busy)) || return nothing
    push!(st.tpl_busy, n)
    try
        decl = st.reg[n]
        d = _TemplateDecl(decl)
        d.body === nothing && return (st.tpl[n] = nothing)
        body = expression_from_json(d.body)
        params = d.params
        pset = Set(params)
        wrt = Set{String}()
        dbearing = false
        reads = Set{String}(params)
        foreach_subexpr(body) do x
            if x isa VarExpr
                push!(reads, x.name)
            elseif x isa OpExpr
                if x.op == "D" && (x.wrt === nothing || x.wrt == "t" || x.wrt in pset)
                    dbearing = true
                    x.wrt !== nothing && x.wrt in pset && push!(wrt, x.wrt)
                elseif _tpl_is_call(x)
                    inner = _dt_template(st, x.name)
                    inner === nothing && return
                    dbearing |= inner.dbearing
                    b = x.bindings
                    b === nothing && return
                    for w in inner.wrt_params
                        v = get(b, w, nothing)
                        v isa VarExpr && v.name in pset && push!(wrt, v.name)
                    end
                end
            end
        end
        t = _DtTemplate(
            n, decl, params, body, sort!(collect(wrt)), dbearing, reads,
            Dict{String, String}()
        )
        st.tpl[n] = t
        return t
    finally
        delete!(st.tpl_busy, n)
    end
end

"""
    _dt_param_name(tpl, p) -> String

The derivative parameter of `p` (esm-spec §9.6.4 rule 3, "Time derivatives"):
`_dt` appended to `p`, then `_` until it names no parameter of the template, no
name its body reads, and no derivative parameter already given to another
parameter of it.
"""
function _dt_param_name(tpl::_DtTemplate, p::String)
    return get!(tpl.dtnames, p) do
        taken = union(tpl.reads, values(tpl.dtnames))
        n = p * "_dt"
        while n in taken
            n *= "_"
        end
        n
    end
end

# The instance key of a reference to `tpl` with bindings `b`, read in `ctx`:
# for each `wrt` parameter, whether it is bound to `"t"` (directly, or through a
# parameter of the enclosing body that its instance binds to `"t"`).
function _dt_key(tpl::_DtTemplate, b, ctx::Union{Nothing, _DtBody})
    key = Dict{String, Bool}()
    for w in tpl.wrt_params
        v = b === nothing ? nothing : get(b, w, nothing)
        key[w] = if !(v isa VarExpr)
            false
        elseif ctx !== nothing && v.name in ctx.tpl.params
            get(ctx.key, v.name, false)
        else
            v.name == "t"
        end
    end
    return key
end

_dt_keystr(tpl::_DtTemplate, key::Dict{String, Bool}) =
    join((get(key, w, false) ? "t" : "s" for w in tpl.wrt_params))

# A structural time derivative in `ctx` (esm-spec §4.2, §9.6.4 rule 3): a unary
# `D` whose `wrt` is absent or `"t"`, or, in a body, a parameter its instance
# binds to `"t"`. A parameter named `t` is a parameter first.
function _dt_structural(e::OpExpr, ctx::Union{Nothing, _DtBody})
    (e.op == "D" && length(e.args) == 1) || return false
    w = e.wrt
    if ctx !== nothing && w !== nothing && w in ctx.tpl.params
        return get(ctx.key, w, false)
    end
    return w === nothing || w == "t"
end

"""
    _dt_rewrite(st, e, ctx, acc, active) -> ASTExpr

`e` with every structural `D` resolved by §4.2's table, read in `ctx` (a call
site when `nothing`, else a template body and its instance), and every
reference re-pointed at the entry its instance resolves to, with the `p_dt`
bindings that entry reads (esm-spec §9.6.4 rule 3, "Time derivatives"). A `D`
the table cannot answer is left exactly as authored, its references pointing at
unresolved bodies (`_dt_unresolve`). `acc` collects the parameters of the body
whose derivatives the result reads.
"""
function _dt_rewrite(st::_DtState, e::ASTExpr, ctx, acc::_DtAcc, active::Vector{String})
    e isa OpExpr || return e
    if _dt_structural(e, ctx)
        sub = _DtAcc()
        out = _dt_deriv(st, e.args[1], ctx, sub, active)
        out === nothing && return _dt_unresolve(st, e, ctx)
        _dt_merge!(acc, sub)
        return out
    end
    _tpl_is_call(e) && return _dt_ref(st, e, ctx, acc, active)
    return map_children(x -> _dt_rewrite(st, x, ctx, acc, active), e)
end

# The bindings of a reference, each rewritten in the caller (they are caller
# expressions, esm-spec §9.6.3 constraint 2); the same dict when none changed.
function _dt_map_bindings(f, b)
    b === nothing && return b
    out = b
    for (k, v) in b
        r = f(v)::ASTExpr
        r === v && continue
        out === b && (out = copy(b))
        out[k] = r
    end
    return out
end

# The `p_dt` bindings a reference with bindings `b` gives the entry `res`
# reads, each §4.2's resolution of `D(b[p])` at the reference; `nothing` when
# one has no resolution.
function _dt_bindings(st::_DtState, tpl::_DtTemplate, res::_DtResult, b, ctx, acc, active)
    extra = Dict{String, ASTExpr}()
    for p in res.needs
        bp = b === nothing ? nothing : get(b, p, nothing)
        bp isa ASTExpr || return nothing
        if p in res.indexed
            # `index(p, ℓ…)` under a `D` resolves only for one cell of a lifted
            # state (flatten.jl `_deriv`), so the binding must name one, or
            # forward a parameter of the enclosing body bound the same way.
            bp isa VarExpr || return nothing
            if ctx !== nothing && bp.name in ctx.tpl.params
                push!(acc.indexed, bp.name)
            else
                _is_lifted_tendency(get(st.tendency, bp.name, nothing)) || return nothing
            end
        end
        d = _dt_deriv(st, bp, ctx, acc, active)
        d === nothing && return nothing
        extra[_dt_param_name(tpl, p)] = d
    end
    return extra
end

_dt_with(e::OpExpr, name, b) = (name == e.name && b === e.bindings) ? e :
    reconstruct(e; name = name, bindings = b)

function _dt_merged(b, extra::Dict{String, ASTExpr})
    out = b === nothing ? Dict{String, ASTExpr}() : copy(b)
    merge!(out, extra)
    return out
end

# A reference outside a structural `D`: its bindings rewritten, and its name
# the entry of its instance, with that entry's `p_dt` bindings.
function _dt_ref(st::_DtState, e::OpExpr, ctx, acc::_DtAcc, active::Vector{String})
    nb = _dt_map_bindings(v -> _dt_rewrite(st, v, ctx, acc, active), e.bindings)
    tpl = _dt_template(st, e.name)
    (tpl === nothing || !tpl.dbearing) && return _dt_with(e, e.name, nb)
    key = _dt_key(tpl, e.bindings, ctx)
    res = _dt_resolve(st, tpl, key)
    # `nothing`: the template is being resolved, and its own resolution reached
    # it again (a cycle through names, §4.2): it stays unresolved.
    res === nothing && return _dt_with(e, _dt_mark(st, :unres, tpl.name), nb)
    res.changed || return _dt_with(e, e.name, nb)
    sub = _DtAcc()
    extra = _dt_bindings(st, tpl, res, e.bindings, ctx, sub, active)
    extra === nothing && return _dt_with(e, _dt_mark(st, :unres, tpl.name), nb)
    _dt_merge!(acc, sub)
    return reconstruct(
        e; name = _dt_mark(st, :res, tpl.name, _dt_keystr(tpl, key)),
        bindings = _dt_merged(nb, extra)
    )
end

"""
    _dt_resolve(st, tpl, key) -> Union{_DtResult,Nothing}

The body of `tpl` with its structural `D`s resolved in the instance `key`
(esm-spec §9.6.4 rule 3, "Time derivatives"): once per template and `wrt`
literal, whatever the call site. Its free names resolve as at a call site, with
cycles detected over names from the body itself; `nothing` while it is being
resolved.
"""
function _dt_resolve(st::_DtState, tpl::_DtTemplate, key::Dict{String, Bool})
    k = (tpl.name, _dt_keystr(tpl, key))
    haskey(st.res, k) && return st.res[k]
    st.res[k] = nothing
    acc = _DtAcc()
    body = _dt_rewrite(st, tpl.body, _DtBody(tpl, key), acc, String[])
    needs = String[p for p in tpl.params if p in acc.needs]
    r = _DtResult(body, needs, acc.indexed, body !== tpl.body || !isempty(needs))
    st.res[k] = r
    return r
end

"""
    _dt_ddt(st, tpl) -> Union{_DtResult,Nothing}

The derivative entry of `tpl` (`<name>.ddt`, esm-spec §9.6.4 rule 3): §4.2's
resolution of `D` of its whole body, each parameter `q` resolving to `q_dt`.
`nothing` when the table cannot answer (a `D` in the body among them: a second
derivative is outside it).
"""
function _dt_ddt(st::_DtState, tpl::_DtTemplate)
    haskey(st.ddt, tpl.name) && return st.ddt[tpl.name]
    st.ddt[tpl.name] = nothing
    acc = _DtAcc()
    key = Dict{String, Bool}(w => false for w in tpl.wrt_params)
    d = _dt_deriv(st, tpl.body, _DtBody(tpl, key), acc, String[])
    d === nothing && return nothing
    r = _DtResult(d, String[p for p in tpl.params if p in acc.needs], acc.indexed, true)
    st.ddt[tpl.name] = r
    return r
end

"""
    _dt_deriv(st, e, ctx, acc, active) -> Union{ASTExpr,Nothing}

d/dt of `e` read in `ctx`: flatten.jl's [`_deriv`](@ref) — the same table, the
same folding — with the three leaves of esm-spec §9.6.4 rule 3 ("Time
derivatives"): a parameter of the body is its `p_dt`, a reference is a
reference to its template's derivative entry, and every other name or literal
resolves as at a call site (in the call site's scope: a state's tendency and an
observed's definition are equations of the system, not of the body).
"""
function _dt_deriv(st::_DtState, e::ASTExpr, ctx, acc::_DtAcc, active::Vector{String})
    if e isa VarExpr
        name = (e::VarExpr).name
        if ctx !== nothing && name in ctx.tpl.params
            push!(acc.needs, name)
            return VarExpr(_dt_param_name(ctx.tpl, name))
        end
        name in active && return nothing
        if haskey(st.tendency, name)
            push!(active, name)
            try
                return _dt_rewrite(st, st.tendency[name], nothing, _DtAcc(), active)
            finally
                pop!(active)
            end
        elseif haskey(st.definition, name)
            push!(active, name)
            try
                return _dt_deriv(st, st.definition[name], nothing, acc, active)
            finally
                pop!(active)
            end
        elseif name in st.time_invariant
            return _zero_expr()
        end
        return nothing
    end
    (e isa NumExpr || e isa IntExpr) && return _zero_expr()
    e isa OpExpr || return nothing
    _tpl_is_call(e) && return _dt_ddt_ref(st, e, ctx, acc, active)

    d(a) = _dt_deriv(st, a, ctx, acc, active)
    op = (e::OpExpr).op
    args = (e::OpExpr).args
    if op == "index" && !isempty(args) && args[1] isa VarExpr
        a1 = (args[1]::VarExpr).name
        if ctx !== nothing && a1 in ctx.tpl.params
            # One cell of what the reference binds to `p`: resolvable only for a
            # lifted state, which `_dt_bindings` checks at the reference.
            push!(acc.needs, a1)
            push!(acc.indexed, a1)
            return OpExpr("index", ASTExpr[VarExpr(_dt_param_name(ctx.tpl, a1)), args[2:end]...])
        elseif _is_lifted_tendency(get(st.tendency, a1, nothing))
            whole = d(args[1])
            whole === nothing && return nothing
            return OpExpr("index", ASTExpr[whole, args[2:end]...])
        end
    end
    if op == "+"
        terms = ASTExpr[]
        for a in args
            da = d(a)
            da === nothing && return nothing
            push!(terms, da)
        end
        return _sum_expr(terms)
    elseif op == "-" && length(args) == 1
        da = d(args[1]); da === nothing && return nothing
        return _negate_expr(da)
    elseif op == "-" && length(args) == 2
        da = d(args[1]); da === nothing && return nothing
        db = d(args[2]); db === nothing && return nothing
        return _difference_expr(da, db)
    elseif op == "neg" && length(args) == 1
        da = d(args[1]); da === nothing && return nothing
        return _negate_expr(da)
    elseif op == "*"
        terms = ASTExpr[]
        for (i, a) in enumerate(args)
            da = d(a)
            da === nothing && return nothing
            _is_zero_expr(da) && continue
            factors = ASTExpr[da]
            for (j, b) in enumerate(args)
                i == j || push!(factors, b)
            end
            push!(terms, _product_expr(factors))
        end
        return _sum_expr(terms)
    elseif op == "/" && length(args) == 2
        u, v = args[1], args[2]
        du = d(u); du === nothing && return nothing
        dv = d(v); dv === nothing && return nothing
        _is_zero_expr(dv) && return _quotient_expr(du, v)
        num = _difference_expr(_product_expr(ASTExpr[du, v]), _product_expr(ASTExpr[u, dv]))
        return _quotient_expr(num, _product_expr(ASTExpr[v, v]))
    end
    return nothing
end

# d/dt of a reference to `S`: a reference to `<S>.ddt` with the reference's
# bindings plus each `q_dt` the entry reads (esm-spec §9.6.4 rule 3).
function _dt_ddt_ref(st::_DtState, e::OpExpr, ctx, acc::_DtAcc, active::Vector{String})
    tpl = _dt_template(st, e.name)
    tpl === nothing && return nothing
    r = _dt_ddt(st, tpl)
    r === nothing && return nothing
    nb = _dt_map_bindings(v -> _dt_rewrite(st, v, ctx, acc, active), e.bindings)
    extra = _dt_bindings(st, tpl, r, e.bindings, ctx, acc, active)
    extra === nothing && return nothing
    return reconstruct(e; name = _dt_mark(st, :ddt, tpl.name), bindings = _dt_merged(nb, extra))
end

"""
    _dt_unresolve(st, e, ctx) -> ASTExpr

`e` left as authored, every reference in it to a template whose body holds a
structural `D` (or reaches one) re-pointed at that template's unresolved body:
what a `D` the table cannot answer keeps, and what a site step 3a does not
resolve reads (esm-spec §9.6.4 rule 3: "a reference for which some `p_dt`
cannot be resolved keeps pointing at the unresolved body").
"""
function _dt_unresolve(st::_DtState, e::ASTExpr, ctx = nothing)
    e isa OpExpr || return e
    if _tpl_is_call(e)
        nb = _dt_map_bindings(v -> _dt_unresolve(st, v, ctx), e.bindings)
        tpl = _dt_template(st, e.name)
        (tpl === nothing || !tpl.dbearing) && return _dt_with(e, e.name, nb)
        return _dt_with(e, _dt_mark(st, :unres, tpl.name), nb)
    end
    return map_children(x -> _dt_unresolve(st, x, ctx), e)
end

# The unresolved body of `tpl`: as registered, its references to templates that
# change re-pointed at their own unresolved bodies.
_dt_unres_body(st::_DtState, tpl::_DtTemplate) =
    get!(() -> _dt_unresolve(st, tpl.body), st.unres, tpl.name)

# Every mark `e` names.
function _dt_marks_in!(out::Vector{String}, e::ASTExpr)
    foreach_subexpr(e) do x
        x isa OpExpr && _tpl_is_call(x) && x.name !== nothing &&
            startswith(x.name, _DT_MARK) && push!(out, x.name)
    end
    return out
end

function _dt_fresh(taken::Set{String}, n::String)
    while n in taken
        n *= "_"
    end
    push!(taken, n)
    return n
end

"""
    _dt_place!(st, roots) -> Dict{String,String}

Settle where each resolved body lives (esm-spec §9.6.4 rule 3, "Time
derivatives") and rewrite the flattened registry `st.reg` in place; return the
mark → entry-name map for the sites. Only what `roots` (the marks the sites
name) reach is registered. Per template:

- one resolved body for every instance reached: it replaces the template's body
  under the same name, its `p_dt` parameters appended to `params`;
- several (a `wrt` parameter bound to `"t"` in one instance and not in
  another, where §9.6.4 rule 3's rewriting did not already separate them): each
  is registered as `<name>.variant<k>`, `k` in the order of the bodies' canonical
  bytes, and the template keeps its body for the references that resolve
  nothing;
- the unresolved body, when a reference still needs it and a resolved one took
  the template's name, as `<name>.unresolved`;
- the derivative entry, as `<name>.ddt`.

New names take `_` until they name no other entry. New entries follow their
template, in that order.
"""
function _dt_place!(st::_DtState, roots::Vector{String})
    body_of(m) = begin
        kind, t, k = st.marks[m]
        kind === :res ? st.res[(t, k)].body :
            kind === :ddt ? st.ddt[t].body : _dt_unres_body(st, st.tpl[t])
    end
    reached = Set{String}()
    queue = copy(roots)
    while !isempty(queue)
        m = pop!(queue)
        m in reached && continue
        push!(reached, m)
        _dt_marks_in!(queue, body_of(m))
    end
    isempty(reached) && return Dict{String, String}()

    bytpl = Dict{String, Vector{String}}()
    for m in reached
        push!(get!(bytpl, st.marks[m][2], String[]), m)
    end
    taken = Set{String}(keys(st.reg))
    names = Dict{String, String}()
    # template => [(entry name, mark)] of the entries placed after it
    after = Dict{String, Vector{Tuple{String, String}}}()
    replaced = Dict{String, String}()   # template => the :res mark that replaces it
    for t in sort!(collect(keys(bytpl)))
        ms = bytpl[t]
        res = sort!([m for m in ms if st.marks[m][1] === :res])
        unres = [m for m in ms if st.marks[m][1] === :unres]
        ddt = [m for m in ms if st.marks[m][1] === :ddt]
        derived = get!(after, t, Tuple{String, String}[])
        if !isempty(res)
            canon = Dict(m => _dt_canonical(st, m) for m in res)
            distinct = sort!(unique(collect(values(canon))))
            if length(distinct) == 1
                foreach(m -> names[m] = t, res)
                replaced[t] = res[1]
                for m in unres
                    names[m] = _dt_fresh(taken, "$t.unresolved")
                    push!(derived, (names[m], m))
                end
            else
                vn = Dict{String, String}()
                for (i, c) in enumerate(distinct)
                    vn[c] = _dt_fresh(taken, "$t.variant$i")
                end
                for (i, c) in enumerate(distinct)
                    m = res[findfirst(x -> canon[x] == c, res)]
                    push!(derived, (vn[c], m))
                end
                foreach(m -> names[m] = vn[canon[m]], res)
                foreach(m -> names[m] = t, unres)
            end
        else
            foreach(m -> names[m] = t, unres)
        end
        for m in ddt
            names[m] = _dt_fresh(taken, "$t.ddt")
            push!(derived, (names[m], m))
        end
    end

    entry(t, m) = begin
        kind, _, k = st.marks[m]
        tpl = st.tpl[t]
        r = kind === :res ? st.res[(t, k)] : kind === :ddt ? st.ddt[t] : nothing
        params = r === nothing ? copy(tpl.params) :
            vcat(tpl.params, String[_dt_param_name(tpl, p) for p in r.needs])
        nd = OrderedDict{String, Any}(string(x) => v for (x, v) in pairs(tpl.decl))
        nd["params"] = params
        nd["body"] = serialize_expression(_rename_expr_apply_refs(body_of(m), names))
        nd
    end
    out = OrderedDict{String, Any}()
    for (n, decl) in st.reg
        out[n] = haskey(replaced, n) ? entry(n, replaced[n]) : decl
        for (dn, m) in get(after, n, Tuple{String, String}[])
            out[dn] = entry(n, m)
        end
    end
    empty!(st.reg)
    merge!(st.reg, out)
    return names
end

# A resolved body and its parameters, as canonical bytes (marks unrenamed: two
# instances that resolve alike name the same marks).
function _dt_canonical(st::_DtState, m::String)
    _, t, k = st.marks[m]
    r = st.res[(t, k)]
    tpl = st.tpl[t]
    return _canonical_compact(
        Any[
            String[_dt_param_name(tpl, p) for p in r.needs],
            JSON3.read(JSON3.write(serialize_expression(r.body))),
        ]
    )
end

# Whether step 3a can change `e`: it holds a `D`, or a reference to a template
# whose body holds one (each shared node visited once).
function _dt_touches(st::_DtState, e::ASTExpr)
    found = false
    foreach_subexpr_once(e) do x
        found && return
        x isa OpExpr || return
        if x.op == "D"
            found = true
        elseif _tpl_is_call(x)
            t = _dt_template(st, x.name)
            found = t !== nothing && t.dbearing
        end
    end
    return found
end

"""
    _resolve_template_time_derivatives!(pool, st, own_of, map_other_sites)

Step 3a over an equation pool whose right-hand sides (or whose references'
bodies) hold structural `D`s (esm-spec §9.6.4 rule 3, "Time derivatives";
esm-libraries-spec §4.7.5 step 3a): each equation's right-hand side through
[`_dt_rewrite`](@ref) with `active` seeded by `own_of(eq)`, every other
expression site (`map_other_sites(f)`: events, initialization equations,
variable rules, which step 3a does not resolve) through
[`_dt_unresolve`](@ref), then the marks placed in the registry and renamed.
"""
function _resolve_template_time_derivatives!(
        pool::Vector{_FlatEq}, st::_DtState, own_of, lifted_shapes::AbstractDict,
        map_other_sites
    )
    roots = String[]
    for (i, fe) in enumerate(pool)
        eq = fe.eq
        _dt_touches(st, eq.rhs) || continue
        own = own_of(eq)
        active = own === nothing ? String[] : String[own]
        resolve(e) = _dt_rewrite(st, e, nothing, _DtAcc(), active)
        resolved = _rewrite_flat_eq(resolve, fe, _is_lifted(eq, lifted_shapes))
        resolved === fe && continue
        pool[i] = _FlatEq(Equation(eq.lhs, resolved.eq.rhs), resolved.contribs, fe.owner)
        _dt_marks_in!(roots, pool[i].eq.rhs)
    end
    if map_other_sites !== nothing
        map_other_sites() do e
            _dt_touches(st, e) || return e
            r = _dt_unresolve(st, e)
            r === e || _dt_marks_in!(roots, r)
            r
        end
    end
    isempty(roots) && return pool
    names = _dt_place!(st, unique!(roots))
    rename(e) = _rename_expr_apply_refs(e, names)
    for (i, fe) in enumerate(pool)
        pool[i] = _rewrite_flat_eq(rename, fe, _is_lifted(fe.eq, lifted_shapes))
    end
    map_other_sites === nothing || map_other_sites(rename)
    return pool
end
