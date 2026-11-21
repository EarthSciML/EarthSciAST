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
`(name, split)` in the context's registry under a placeholder name
(`_cw_placeholder`); `_name_cellwise_variants!` names it `<name>.cellwise<k>`
once every lift of the flatten is done.
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
    decl = OrderedDict{String, Any}(string(a) => b for (a, b) in pairs(ctx.registry[name]))
    for f in ("match", "where", "priority")
        delete!(decl, f)
    end
    decl["params"] = Any[params..., (m[x] for x in split)...]
    decl["body"] = serialize_expression(nbody)
    # A placeholder name, a function of the variant alone: a lift of this
    # flatten that met the same variant first (another context over the same
    # registry) registered it already. The final `<name>.cellwise<k>` is
    # assigned once all lifts are done (`_name_cellwise_variants!`).
    canon = _canonical_compact(decl)
    n = 0
    vn = _cw_placeholder(name, split, n)
    while haskey(ctx.registry, vn) && _canonical_compact(ctx.registry[vn]) != canon
        n += 1
        vn = _cw_placeholder(name, split, n)
    end
    haskey(ctx.registry, vn) || (ctx.registry[vn] = decl)
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

# ============================================================================
# Naming the cellwise variants (esm-spec §9.6.11; §9.6.4 rule 3, "Where the
# result lives")
# ============================================================================
#
# The lifts discover cellwise variants one equation at a time, so a variant's
# final name `<name>.cellwise<k>`, with `k` in the order of the canonical bytes
# of the bodies of all of `<name>`'s cellwise variants, is known only once every
# lift of a flatten is done (the pointwise lift, the elementwise lift, and shape
# promotion after flatten). Until then a variant is registered under a
# placeholder that depends only on the variant (its template, its split names,
# and a counter that separates distinct declarations for one split), so the
# placeholder, and hence the result, does not depend on discovery order. The
# placeholder's separators are control characters no document name contains.

const _CW_OPEN = "\x1fcellwise\x1f"
const _CW_SEP = "\x1f"
const _CW_CLOSE = "\x1e"
const _CW_FINAL_RE = r"^(.+)\.cellwise[0-9]+_*$"

_cw_placeholder(name::AbstractString, split::Vector{String}, n::Int) =
    string(name, _CW_OPEN, join(split, _CW_SEP), _CW_SEP, n, _CW_CLOSE)

# Every `apply_expression_template` name a raw JSON value holds.
function _cw_raw_refs!(acc::Set{String}, x)
    if _is_object(x)
        if _raw_get(x, "op") == "apply_expression_template"
            n = _raw_get(x, "name")
            n isa AbstractString && push!(acc, String(n))
        end
        for (_, v) in pairs(x)
            _cw_raw_refs!(acc, v)
        end
    elseif _is_array(x)
        foreach(v -> _cw_raw_refs!(acc, v), x)
    end
    return acc
end

# A raw JSON value with each reference's name renamed through `ren` (old =>
# new); `x` itself when nothing is renamed.
function _cw_raw_rename(x, ren::AbstractDict{String, String})
    if _is_object(x)
        out = OrderedDict{String, Any}()
        changed = false
        isref = _raw_get(x, "op") == "apply_expression_template"
        for (k, v) in pairs(x)
            ks = string(k)
            nv = if isref && ks == "name" && v isa AbstractString && haskey(ren, String(v))
                ren[String(v)]
            else
                _cw_raw_rename(v, ren)
            end
            changed |= nv !== v
            out[ks] = nv
        end
        return changed ? out : x
    elseif _is_array(x)
        nv = Any[_cw_raw_rename(v, ren) for v in x]
        return any(i -> nv[i] !== x[i], eachindex(nv)) ? nv : x
    end
    return x
end

"""
    _name_cellwise_variants!(reg) -> Dict{String,String}

Give every cellwise variant in the flattened registry `reg` its final name and
return the renames (old => new) the expression sites still need. The variants
of template `T` (placeholders, and entries an earlier pass already named
`T.cellwise<k>`) are named `<T'>.cellwise<k>`, `T'` being `T`'s own final name,
with `k = 1, 2, …` in the order of the variants' bodies' canonical bytes
(`_canonical_compact`, each body with its references already renamed; ties by
the whole declaration's bytes) and `_` appended until the name names no other
entry (esm-spec §9.6.11, §9.6.4 rule 3). Two variants with the same declaration
are one entry. The variants of a template are named after every variant their
bodies reference, so the bytes compared hold final names. An entry derived from
a variant (`<variant>.ddt`, `<variant>.variant<j>`, flatten step 3a) follows its
variant's name. Renamed entries move to the end of `reg`, in name order, each
followed by the entries derived from it; every body in `reg` is renamed.
"""
function _name_cellwise_variants!(reg::AbstractDict)
    names = String[string(k) for k in keys(reg)]
    member_base = Dict{String, String}()
    for k in names
        if endswith(k, _CW_CLOSE) && occursin(_CW_OPEN, k)
            r = findlast(_CW_OPEN, k)
            member_base[k] = k[1:prevind(k, first(r))]
        end
    end
    isempty(member_base) && return Dict{String, String}()
    for k in names
        haskey(member_base, k) && continue
        m = match(_CW_FINAL_RE, k)
        m !== nothing && haskey(reg, m[1]) && (member_base[k] = String(m[1]))
    end
    # An entry derived from a variant: `<variant>.<rest>`, the longest variant.
    derived = Dict{String, Tuple{String, String}}()
    for k in names
        haskey(member_base, k) && continue
        i = lastindex(k)
        while (i = findprev('.', k, i)) !== nothing
            pre = k[1:prevind(k, i)]
            if haskey(member_base, pre)
                derived[k] = (pre, k[i:end])
                break
            end
            i = prevind(k, i)
            i < firstindex(k) && break
        end
    end
    assigned = Dict{String, String}()
    final(n) = haskey(member_base, n) ? get(assigned, n, nothing) :
        haskey(derived, n) ? (
            f = final(derived[n][1]);
            f === nothing ? nothing : f * derived[n][2]
        ) : n
    groups = Dict{String, Vector{String}}()
    for (k, b) in member_base
        push!(get!(groups, b, String[]), k)
    end
    taken = Set{String}(k for k in names if !haskey(member_base, k) && !haskey(derived, k))
    refs = Dict{String, Set{String}}(k => _cw_raw_refs!(Set{String}(), _raw_get(reg[k], "body")) for k in keys(member_base))
    pending = sort!(collect(keys(groups)))
    while !isempty(pending)
        progressed = false
        for b in copy(pending)
            nb = final(b)
            nb === nothing && continue
            ms = groups[b]
            all(m -> all(r -> final(r) !== nothing, refs[m]), ms) || continue
            ren = Dict{String, String}()
            for m in ms, r in refs[m]
                f = final(r)
                f == r || (ren[r] = f)
            end
            keyed = Dict{String, Tuple{String, String}}()
            for m in ms
                d = reg[m]
                body = _cw_raw_rename(_raw_get(d, "body"), ren)
                nd = OrderedDict{String, Any}(string(a) => v for (a, v) in pairs(d))
                nd["body"] = body
                keyed[m] = (_canonical_compact(body), _canonical_compact(nd))
            end
            distinct = sort!(unique(collect(values(keyed))))
            fin = Dict{Tuple{String, String}, String}()
            for (k, c) in enumerate(distinct)
                vn = "$nb.cellwise$k"
                while vn in taken
                    vn *= "_"
                end
                push!(taken, vn)
                fin[c] = vn
            end
            for m in ms
                assigned[m] = fin[keyed[m]]
            end
            filter!(!=(b), pending)
            progressed = true
        end
        progressed || error("cellwise variants reference each other in a cycle: $(pending)")
    end
    renames = Dict{String, String}()
    for k in names
        (haskey(member_base, k) || haskey(derived, k)) || continue
        f = final(k)
        f == k || (renames[k] = f)
    end
    # Rebuild: unrenamed entries in place, then each named variant (in name
    # order) followed by the entries derived from it, in their order.
    old = OrderedDict{String, Any}(string(k) => v for (k, v) in pairs(reg))
    ren_decl(d) = begin
        b = _raw_get(d, "body")
        nb = _cw_raw_rename(b, renames)
        nb === b && return d
        nd = OrderedDict{String, Any}(string(a) => v for (a, v) in pairs(d))
        nd["body"] = nb
        nd
    end
    empty!(reg)
    for (k, d) in old
        (haskey(member_base, k) || haskey(derived, k)) && continue
        reg[k] = ren_decl(d)
    end
    after = Dict{String, Vector{String}}()
    for k in names
        haskey(derived, k) || continue
        # the variant the derived entry hangs off, through derived bases
        root = derived[k][1]
        push!(get!(after, final(root), String[]), k)
    end
    firsts = Dict{String, String}()
    for k in names
        haskey(member_base, k) || continue
        get!(firsts, assigned[k], k)
    end
    for f in sort!(collect(keys(firsts)))
        reg[f] = ren_decl(old[firsts[f]])
        for k in get(after, f, String[])
            fk = final(k)
            haskey(reg, fk) || (reg[fk] = ren_decl(old[k]))
        end
    end
    return renames
end
