# ============================================================================
# Elementwise application of an expression template over array arguments
# (esm-spec §9.6.11), carried out as a per-cell lift at build time
# ============================================================================
#
# A template written for scalar inputs — the `lib/interp.esm` lookups are the
# motivating case — reads a scalar-role parameter (one its body never uses as an
# `index` base) inside a reduction body or an `index` subscript. Bound to an
# array, by the author or by a coupling that feeds an array into a parameter the
# component declared scalar, the substituted expansion would read a whole array
# where the body needs one value. §9.6.11 gives the application its elementwise
# meaning: it is evaluated once per element of the array argument.
#
# This binding keeps template references unexpanded until the evaluator build,
# so the rule is applied to the reference itself, on the flattened system,
# inside `promote_downstream_shapes`: an equation `x = rhs` whose right-hand side
# applies a template with an array bound to a scalar-role parameter (or reads a
# shaped variable by bare name in a reduction body or a subscript — the same
# application already expanded) becomes `x = faq(rhs read at the cell)` over the
# application's index sets. Each scalar-role binding, and every other bare
# shaped read in value position, is gathered at the cell aligned by index-set
# name (esm-spec §4.3.4); array-role bindings (tables, axes) stay whole.

# The array-role parameters of each template in `registry`: those its body uses
# as an `index` base, directly or by passing them to an array-role parameter of
# a template it references.
function _template_array_roles(registry)::Dict{String, Set{String}}
    roles = Dict{String, Set{String}}()
    registry === nothing && return roles
    visiting = Set{String}()
    function roles_of(name::String)::Set{String}
        haskey(roles, name) && return roles[name]
        name in visiting && return Set{String}()
        tpl = get(registry, name, nothing)
        tpl isa AbstractDict || return Set{String}()
        push!(visiting, name)
        params = Set{String}(String(p) for p in get(tpl, "params", Any[]) if p isa AbstractString)
        out = Set{String}()
        walk(x) =
        if x isa AbstractDict
            op = get(x, "op", nothing)
            if op == "index"
                a = get(x, "args", Any[])
                (!isempty(a) && a[1] isa AbstractString && a[1] in params) && push!(out, String(a[1]))
            elseif op == "apply_expression_template"
                inner = get(x, "name", nothing)
                b = get(x, "bindings", nothing)
                if inner isa AbstractString && b isa AbstractDict
                    ir = roles_of(String(inner))
                    for (q, v) in b
                        (v isa AbstractString && v in params && String(q) in ir) && push!(out, String(v))
                    end
                end
            end
            foreach(walk, values(x))
        elseif x isa AbstractVector
            foreach(walk, x)
        end
        walk(get(tpl, "body", nothing))
        delete!(visiting, name)
        roles[name] = out
        return out
    end
    for k in keys(registry)
        roles_of(String(k))
    end
    return roles
end

# The scalar-role bindings of a template application, or `nothing` when the
# template is not in `roles` (its parameters' roles are unknown here).
function _scalar_role_bindings(e::OpExpr, roles)
    (roles === nothing || e.name === nothing || e.bindings === nothing) && return nothing
    arr = get(roles, e.name, nothing)
    arr === nothing && return nothing
    return [(k, v) for (k, v) in e.bindings if !(k in arr)]
end

# The argument positions of a closed function that take a whole array.
_whole_array_fn_args(name) =
    name == "interp.linear" ? (1, 2) :
    name == "interp.bilinear" ? (1, 2, 3) :
    name == "interp.searchsorted" ? (2,) : ()

_is_rank0_faq(e::OpExpr) =
    e.op in _ARRAY_PRODUCER_OPS && e.op != "makearray" &&
    (e.output_idx === nothing || !any(s -> s isa AbstractString, e.output_idx))

function _faq_bound(e::OpExpr, bound::Set{String})
    e.ranges === nothing && return bound
    return union(bound, Set{String}(String(k) for k in keys(e.ranges)))
end

# Whether `expr` holds an elementwise template application over an array: a
# scalar-role binding with an array shape, or a bare shaped read in a scalar slot
# (a reduction body or filter, an `index` subscript), reached through value
# positions only.
function _has_elementwise_application(
        expr::ASTExpr, shapes::Dict{String, Vector{String}}, roles,
        bound::Set{String} = Set{String}(), slot::Bool = false
    )::Bool
    if expr isa VarExpr
        return slot && !(expr.name in bound) && !isempty(get(shapes, expr.name, String[]))
    end
    expr isa OpExpr || return false
    op = expr.op
    rec(a, s = slot, b = bound) = _has_elementwise_application(a, shapes, roles, b, s)
    if op == "index"
        return any(a -> rec(a, true), expr.args[2:end])
    elseif op == "apply_expression_template"
        sb = _scalar_role_bindings(expr, roles)
        sb === nothing && return false
        return any(((_, v),) -> !isempty(_infer_expr_shape(v, shapes, roles)) || rec(v), sb)
    elseif op == "fn"
        whole = _whole_array_fn_args(expr.name)
        return any(i -> !(i in whole) && rec(expr.args[i]), eachindex(expr.args))
    elseif op in _ARRAY_PRODUCER_OPS
        _is_rank0_faq(expr) || return false
        inner = _faq_bound(expr, bound)
        return (expr.expr_body !== nothing && rec(expr.expr_body, true, inner)) ||
            (expr.filter !== nothing && rec(expr.filter, true, inner))
    elseif _is_scalar_op(op)
        return any(a -> rec(a), expr.args)
    end
    return false
end

# `expr` read at the current cell of `loops`: every bare shaped read in value
# position gathered at the loops its index sets name, every scalar-role binding
# of a template application read the same way, array-role bindings left whole.
function _ew_at_cell(
        expr::ASTExpr, shapes::Dict{String, Vector{String}}, roles,
        loops::Vector{String}, align, bound::Set{String} = Set{String}()
    )::ASTExpr
    if expr isa VarExpr
        (expr.name in bound || isempty(get(shapes, expr.name, String[]))) && return expr
        return _index_wrap_var(expr, loops, align)
    end
    expr isa OpExpr || return expr
    op = expr.op
    rec(a, b = bound) = _ew_at_cell(a, shapes, roles, loops, align, b)
    if op == "index"
        return reconstruct(expr; args = ASTExpr[expr.args[1], (rec(a) for a in expr.args[2:end])...])
    elseif op == "apply_expression_template"
        sb = _scalar_role_bindings(expr, roles)
        sb === nothing && return expr
        nb = Dict{String, ASTExpr}(expr.bindings)
        for (k, v) in sb
            nb[k] = rec(v)
        end
        return reconstruct(expr; bindings = nb)
    elseif op == "fn"
        whole = _whole_array_fn_args(expr.name)
        return reconstruct(
            expr; args = ASTExpr[i in whole ? a : rec(a) for (i, a) in enumerate(expr.args)]
        )
    elseif op in _ARRAY_PRODUCER_OPS
        _is_rank0_faq(expr) || return expr
        inner = _faq_bound(expr, bound)
        return reconstruct(
            expr;
            expr_body = expr.expr_body === nothing ? nothing : rec(expr.expr_body, inner),
            filter = expr.filter === nothing ? nothing : rec(expr.filter, inner)
        )
    elseif _is_scalar_op(op)
        return reconstruct(expr; args = ASTExpr[rec(a) for a in expr.args])
    end
    return expr
end

# `x = rhs` lifted over `shape`: a `faq` over the index sets of `shape` whose
# body is `rhs` read at the cell (esm-spec §9.6.11). Every array read must name
# only index sets of `shape`, each once (§4.3.4).
function _lift_elementwise_application(
        rhs::ASTExpr, shape::Vector{String},
        shapes::Dict{String, Vector{String}}, roles, lhs::AbstractString
    )::OpExpr
    allunique(shape) || throw(
        DimensionPromotionError(
            "array_shape_mismatch: '$(lhs)': the elementwise application is over " *
                "$(shape), which names one index set twice (esm-spec §9.6.11)"
        )
    )
    loops = String["_p$(i - 1)" for i in eachindex(shape)]
    ranges = Dict{String, Any}(loops[i] => IndexSetRef(shape[i]) for i in eachindex(shape))
    body = try
        _ew_at_cell(rhs, shapes, roles, loops, _AxisAlign(shape, shapes))
    catch e
        e isa TreeWalkError && e.code == "E_TREEWALK_ARRAY_SHAPE_MISMATCH" || rethrow()
        throw(DimensionPromotionError("array_shape_mismatch: '$(lhs)': $(e.detail) (esm-spec §9.6.11)"))
    end
    return OpExpr(
        "faq", ASTExpr[];
        output_idx = Any[l for l in loops], ranges = ranges, expr_body = body
    )
end
