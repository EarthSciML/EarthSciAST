# ============================================================================
# The elementwise lift reads template references without expanding them
# (esm-spec §9.6.11 "Realization", esm-libraries-spec "operands read per cell")
# ============================================================================
#
# A reference denotes its expansion, which substitutes each binding at every
# position of its parameter. The lifts read an application at the cell by
# reading each binding by its parameter's ROLE in the body, decided once per
# template from the body alone: a parameter the body reads only in value
# positions (`:value`) has its binding read at the cell; one it reads only
# whole (an `index` base, a reduction's operand, a `D` operand: `:array`) keeps
# its binding whole; one it reads both ways (`:mixed`) bound to an array takes
# the template's cellwise variant `<name>.cellwise<k>`, whose fresh parameter
# `p_cell` stands at `p`'s value positions. A shaped free name the body reads
# in a value position (a component variable, after flatten's scoping) is read
# at the cell the same way, through a cellwise parameter of its own. The value
# positions inside a body are exactly those `_ew_visit` visits inside an
# application.

struct _EwRoles
    params::Vector{String}
    role::Dict{String, Symbol}      # :value, :array, :mixed, :none
    free_value::Vector{String}      # free names read in a value position (sorted)
end

# The typed body of `name` in the context's registry, with its parameters.
function _ew_template(ctx, name::AbstractString)
    (ctx === nothing || ctx.registry === nothing) && return nothing
    return get!(ctx.bodies, String(name)) do
        decl = get(ctx.registry, String(name), nothing)
        decl === nothing && return nothing
        td = _TemplateDecl(decl)
        td.body === nothing && return nothing
        (String[td.params...], expression_from_json(td.body))
    end
end

"""
    _ew_roles(ctx, name) -> Union{Nothing, _EwRoles}

Each parameter's role in template `name`'s body, and the free names the body
reads in a value position, through the references it makes (memoized per
template).
"""
function _ew_roles(ctx, name::AbstractString)
    t = _ew_template(ctx, name)
    t === nothing && return nothing
    r = get(ctx.roles, String(name), nothing)
    r === nothing || return r
    params, body = t
    P = Set{String}(params)
    vals = Dict{String, Int}()
    arrs = Dict{String, Int}()
    free = Set{String}()
    _ew_classify!(body, true, Set{String}(), P, vals, arrs, free, ctx)
    role = Dict{String, Symbol}()
    for p in params
        v = get(vals, p, 0) > 0
        a = get(arrs, p, 0) > 0
        role[p] = v && a ? :mixed : v ? :value : a ? :array : :none
    end
    r = _EwRoles(params, role, sort!(collect(free)))
    ctx.roles[String(name)] = r
    return r
end

function _ew_classify!(e, val::Bool, bound::Set{String}, P, vals, arrs, free, ctx)
    if e isa VarExpr
        n = e.name
        n in bound && return
        if n in P
            d = val ? vals : arrs
            d[n] = get(d, n, 0) + 1
        elseif val
            push!(free, n)
        end
        return
    end
    e isa OpExpr || return
    rec(x, v = val, b = bound) = _ew_classify!(x, v, b, P, vals, arrs, free, ctx)
    op = e.op
    if op == "apply_expression_template"
        r = _ew_roles(ctx, e.name)
        b = e.bindings === nothing ? Dict{String, ASTExpr}() : e.bindings
        if r === nothing
            foreach(v -> rec(v, false), values(b))
            return
        end
        for (k, v) in b
            rk = get(r.role, k, :none)
            (rk == :value || rk == :mixed) && rec(v, val)
            (rk == :array || rk == :mixed) && rec(v, false)
        end
        if val
            for n in r.free_value
                (n in bound || n in P) || push!(free, n)
            end
        end
    elseif op == "index"
        rec(e.args[1], false)
        foreach(a -> rec(a), e.args[2:end])
    elseif op == "const" || op == "reshape"
        foreach_child(c -> rec(c, false), e)
    elseif op in _ARRAY_PRODUCER_OPS
        if _is_rank0_faq(e)
            inner = _faq_bound(e, bound)
            e.expr_body === nothing || rec(e.expr_body, val, inner)
            e.filter === nothing || rec(e.filter, val, inner)
            foreach(a -> rec(a, false, inner), e.args)
        else
            foreach_child(c -> rec(c, false), e)
        end
    elseif _is_elementwise_node(e)
        foreach(a -> rec(a), e.args)
    else
        foreach_child(c -> rec(c, false), e)
    end
    return
end

"""
    _ew_template_names(ctx, name) -> Set{String}

Every name template `name`'s expansion reads or binds that is not one of its
parameters: the names its body reads or binds, through the references it
makes, less its parameters (memoized per template). With the names a
reference's bindings read, it is the set of names the reference's expansion
reads, computed without expanding (esm-spec §9.6.11, loop symbols).
"""
function _ew_template_names(ctx, name::AbstractString)
    t = _ew_template(ctx, name)
    t === nothing && return Set{String}()
    return get!(ctx.names, String(name)) do
        params, body = t
        setdiff!(_used_names!(Set{String}(), body, ctx), params)
    end
end

"""
    _ew_cellwise!(ctx, name, split) -> (variant name, Dict(x => x_cell))

The cellwise variant of template `name` for the names `split` (mixed
parameters bound to arrays, and shaped free names the body reads in a value
position): `name`'s parameters plus a fresh `x_cell` per split name, which
replaces `x` in each of its value positions, through the references the body
makes (each re-pointed to its own cellwise variant). Registered once per
`(name, split)` in the context's registry as `<name>.cellwise<k>`.
"""
function _ew_cellwise!(ctx, name::String, split::Vector{String})
    key = (name, split)
    hit = get(ctx.cellwise, key, nothing)
    hit === nothing || return hit
    params, body = _ew_template(ctx, name)
    taken = union(Set{String}(params), _ew_template_names(ctx, name))
    m = Dict{String, String}()
    for x in split
        c = x * "_cell"
        while c in taken
            c *= "_"
        end
        push!(taken, c)
        m[x] = c
    end
    nbody = _ew_cell_subst(body, true, Set{String}(), m, ctx)
    k = count(kk -> kk[1] == name, keys(ctx.cellwise)) + 1
    vn = "$name.cellwise$k"
    while haskey(ctx.registry, vn)
        vn *= "_"
    end
    decl = OrderedDict{String, Any}(string(a) => b for (a, b) in pairs(ctx.registry[name]))
    for f in ("match", "where", "priority")
        delete!(decl, f)
    end
    decl["params"] = Any[params..., (m[x] for x in split)...]
    decl["body"] = serialize_expression(nbody)
    ctx.registry[vn] = decl
    res = (vn, m)
    ctx.cellwise[key] = res
    return res
end

# `e` with each name of `m` replaced by its cellwise parameter in its value
# positions (`val`), through nested references by their roles.
function _ew_cell_subst(e, val::Bool, bound::Set{String}, m::Dict{String, String}, ctx)
    if e isa VarExpr
        (val && !(e.name in bound) && haskey(m, e.name)) && return VarExpr(m[e.name])
        return e
    end
    e isa OpExpr || return e
    val || return e
    rec(x, v = val, b = bound) = _ew_cell_subst(x, v, b, m, ctx)
    op = e.op
    if op == "apply_expression_template"
        r = _ew_roles(ctx, e.name)
        r === nothing && return e
        b = e.bindings === nothing ? Dict{String, ASTExpr}() : e.bindings
        nb = Dict{String, ASTExpr}()
        split = String[]
        cellb = Dict{String, ASTExpr}()
        for (k, v) in b
            rk = get(r.role, k, :none)
            if rk == :value
                nb[k] = rec(v)
            elseif rk == :mixed
                nb[k] = v
                c = rec(v)
                c === v || (push!(split, k); cellb[k] = c)
            else
                nb[k] = v
            end
        end
        for n in r.free_value
            (n in bound || !haskey(m, n)) && continue
            push!(split, n)
            cellb[n] = VarExpr(m[n])
        end
        if isempty(split)
            all(nb[k] === v for (k, v) in b) && return e
            return reconstruct(e; bindings = nb)
        end
        sort!(split)
        vn, im = _ew_cellwise!(ctx, String(e.name), split)
        for x in split
            nb[im[x]] = cellb[x]
        end
        return reconstruct(e; name = vn, bindings = nb)
    elseif op == "index"
        na = ASTExpr[e.args[1], (rec(a) for a in e.args[2:end])...]
        return all(a === b for (a, b) in zip(na, e.args)) ? e : reconstruct(e; args = na)
    elseif op in _ARRAY_PRODUCER_OPS
        _is_rank0_faq(e) || return e
        inner = _faq_bound(e, bound)
        nbody = e.expr_body === nothing ? nothing : rec(e.expr_body, true, inner)
        nfilt = e.filter === nothing ? nothing : rec(e.filter, true, inner)
        (nbody === e.expr_body && nfilt === e.filter) && return e
        return reconstruct(e; expr_body = nbody, filter = nfilt)
    elseif _is_elementwise_node(e)
        na = ASTExpr[rec(a) for a in e.args]
        return all(a === b for (a, b) in zip(na, e.args)) ? e : reconstruct(e; args = na)
    end
    return e
end

# Whether `v`, read at a call site in a value position, reads a shaped name in
# a value position (so reading it at the cell changes it).
function _ew_reads_shaped(v::ASTExpr, shapes, ctx, bound::Set{String})
    found = false
    _ew_visit(v, shapes, ctx, bound, true, (_, _) -> (found = true))
    return found
end

# The reference `expr` read at the cell (`_ew_at_cell`): each binding by its
# parameter's role, a mixed parameter bound to an array and a shaped free name
# through the cellwise variant.
function _ew_ref_at_cell(expr::OpExpr, shapes, ctx, rec, bound::Set{String})
    r = _ew_roles(ctx, expr.name)
    r === nothing && return expr
    b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
    nb = Dict{String, ASTExpr}()
    split = String[]
    cellb = Dict{String, ASTExpr}()
    for (k, v) in b
        rk = get(r.role, k, :none)
        if rk == :value
            nb[k] = rec(v)
        elseif rk == :mixed && _ew_reads_shaped(v, shapes, ctx, bound)
            nb[k] = v
            push!(split, k)
            cellb[k] = rec(v)
        else
            nb[k] = v
        end
    end
    for n in r.free_value
        (n in bound || isempty(get(shapes, n, String[]))) && continue
        push!(split, n)
        cellb[n] = rec(VarExpr(n))
    end
    isempty(split) && return reconstruct(expr; bindings = nb)
    sort!(split)
    vn, m = _ew_cellwise!(ctx, String(expr.name), split)
    for x in split
        nb[m[x]] = cellb[x]
    end
    return reconstruct(expr; name = vn, bindings = nb)
end
