# ============================================================================
# Elementwise application of an expression template over array arguments
# (esm-spec §9.6.11), carried out as a per-cell lift at build time
# ============================================================================
#
# A template written for scalar inputs — the `lib/interp.esm` lookups are the
# motivating case — reads a scalar-role parameter inside a reduction body or an
# `index` subscript. Bound to an array, by the author or by a coupling that
# feeds an array into a parameter the component declared scalar, the
# substituted expansion would read a whole array where the body needs one value.
# §9.6.11 gives the application its elementwise meaning: it is evaluated once
# per element of the array argument.
#
# The rule applies to template applications only: an `apply_expression_template`
# reference (this binding keeps them until the evaluator build), or the root of
# an expansion made at load, which carries `template_origin` (a mounted leaf's
# references are expanded at the mount). A shaped read an author wrote by hand
# is never lifted. Inside `promote_downstream_shapes`, on the flattened system,
# an equation `x = rhs` that holds, in elementwise position, an application
# whose expansion reads a shaped variable in a value position becomes
# `x = faq(rhs read at the cell)` over the application's index sets. Each such
# read, and each bare shaped read outside the applications in elementwise
# position, is gathered at the cell aligned by index-set name (esm-spec §4.3.4);
# a table or axis the body reads whole stays whole. The Rust and Python
# bindings, which expand every reference at load, run the same walk on their
# marked expansions.

# Expands the template references the lift meets, against the flattened
# system's merged registry, each once.
# `M` is `_ExpandCache` (defined with the expansion, which is included after
# this file).
struct _ElementwiseContext{M}
    registry::Any
    memo::M
end

_ElementwiseContext(registry) = _ElementwiseContext(registry, _ExpandCache())

# The expansion of the application `e`, its root marked with the template's
# name, or `nothing` when `ctx` has no registry to expand it against.
function _ew_expansion(e::OpExpr, ctx::Union{Nothing, _ElementwiseContext})
    (ctx === nothing || ctx.registry === nothing || isempty(ctx.registry)) && return nothing
    return task_local_storage(_MARK_TEMPLATE_ORIGINS_KEY, true) do
        _expand_expr_refs(e, ctx.registry, nothing, ctx.memo)
    end
end

_is_rank0_faq(e::OpExpr) =
    e.op in _ARRAY_PRODUCER_OPS && e.op != "makearray" &&
    (e.output_idx === nothing || !any(s -> s isa AbstractString, e.output_idx))

function _faq_bound(e::OpExpr, bound::Set{String})
    e.ranges === nothing && return bound
    return union(bound, Set{String}(String(k) for k in keys(e.ranges)))
end

_is_anonymous_array(e::OpExpr) =
    e.op == "reshape" || (e.op == "const" && e.value isa AbstractVector)

# Visit every value position of `expr` (esm-spec §9.6.11). Outside a template
# application those are the operands of elementwise operators, the positions
# the per-cell reading commutes with. Inside one (an expanded reference, a node carrying `template_origin`,
# and everything below it) they are also the body and filter of a reduction
# `faq` and the subscripts of an `index`, where the template reads its
# scalar-role parameters. `on_read(name, inside)` is called for every bare
# shaped read; `on_anonymous(node)` for an anonymous array (a `const` array
# literal, a `reshape` result) in a value position inside an application. An
# `index` base and every operand an op consumes whole are array positions, not
# visited.
function _ew_visit(
        expr::ASTExpr, shapes::Dict{String, Vector{String}},
        ctx::Union{Nothing, _ElementwiseContext}, bound::Set{String}, inside::Bool,
        on_read, on_anonymous = nothing
    )
    if expr isa VarExpr
        (expr.name in bound || isempty(get(shapes, expr.name, String[]))) && return
        on_read(expr.name, inside)
        return
    end
    expr isa OpExpr || return
    op = expr.op
    if op == "apply_expression_template"
        ex = _ew_expansion(expr, ctx)
        ex === nothing ||
            _ew_visit(ex, shapes, ctx, bound, true, on_read, on_anonymous)
        return
    end
    inside = inside || expr.template_origin !== nothing
    rec(a, b = bound, i = inside) = _ew_visit(a, shapes, ctx, b, i, on_read, on_anonymous)
    if op == "index"
        inside && foreach(a -> rec(a, bound, true), expr.args[2:end])
    elseif op == "const" || op == "reshape"
        inside && on_anonymous !== nothing && _is_anonymous_array(expr) && on_anonymous(expr)
    elseif op in _ARRAY_PRODUCER_OPS
        (inside && _is_rank0_faq(expr)) || return
        inner = _faq_bound(expr, bound)
        expr.expr_body === nothing || rec(expr.expr_body, inner, true)
        expr.filter === nothing || rec(expr.filter, inner, true)
    elseif _is_elementwise_node(expr)
        foreach(rec, expr.args)
    end
    return
end

# Every `(name, inside)` read `_ew_visit` reports for `expr`.
function _ew_reads(expr::ASTExpr, shapes, ctx)
    out = Tuple{String, Bool}[]
    _ew_visit(expr, shapes, ctx, Set{String}(), false, (n, i) -> push!(out, (n, i)))
    return out
end

# Whether `expr` applies a template elementwise: an application, in elementwise
# position, whose expansion reads a shaped variable in a value position.
_has_elementwise_application(expr::ASTExpr, shapes, ctx) =
    any(((_, inside),) -> inside, _ew_reads(expr, shapes, ctx))

# `array_shape_mismatch` when a template application in `rhs` reads an
# anonymous array in a value position: it has no index sets, so nothing says
# which element each cell reads (esm-spec §9.6.11).
function _refuse_anonymous_arrays(rhs::ASTExpr, lhs, ctx)
    found = OpExpr[]
    _ew_visit(
        rhs, Dict{String, Vector{String}}(), ctx, Set{String}(), false,
        (_, _) -> nothing, n -> push!(found, n)
    )
    isempty(found) && return
    name = lhs isa VarExpr ? lhs.name : sprint(show, lhs)
    throw(
        DimensionPromotionError(
            "array_shape_mismatch: '$(name)': a template application reads an anonymous " *
                "array (a `$(found[1].op)` node) where its body reads a scalar; an array " *
                "argument of an elementwise application must be declared over index sets, so " *
                "each cell knows which element it reads (esm-spec §9.6.11)"
        )
    )
end

# The operands that shape an application's result: the shaped variables its
# expansion reads in value positions, which broadcast by name (§4.3.4).
function _application_operands(expr::OpExpr, shapes, ctx)::Vector{ASTExpr}
    out = ASTExpr[]
    _ew_visit(
        expr, shapes, ctx, Set{String}(), false,
        (n, inside) -> inside && push!(out, VarExpr(n))
    )
    return out
end

# `expr` read at the current cell of `loops`: every shaped read `_ew_visit`
# reports gathered at the loops its index sets name; a template reference is
# replaced by its expansion, so read.
function _ew_at_cell(
        expr::ASTExpr, shapes::Dict{String, Vector{String}}, ctx,
        loops::Vector{String}, align, bound::Set{String} = Set{String}(), inside::Bool = false
    )::ASTExpr
    if expr isa VarExpr
        (expr.name in bound || isempty(get(shapes, expr.name, String[]))) && return expr
        return _index_wrap_var(expr, loops, align)
    end
    expr isa OpExpr || return expr
    op = expr.op
    if op == "apply_expression_template"
        ex = _ew_expansion(expr, ctx)
        ex === nothing && return expr
        return _ew_at_cell(ex, shapes, ctx, loops, align, bound, true)
    end
    inside = inside || expr.template_origin !== nothing
    rec(a, b = bound, i = inside) = _ew_at_cell(a, shapes, ctx, loops, align, b, i)
    if op == "index"
        inside || return expr
        return reconstruct(
            expr; args = ASTExpr[expr.args[1], (rec(a, bound, true) for a in expr.args[2:end])...]
        )
    elseif op in _ARRAY_PRODUCER_OPS
        (inside && _is_rank0_faq(expr)) || return expr
        inner = _faq_bound(expr, bound)
        return reconstruct(
            expr;
            expr_body = expr.expr_body === nothing ? nothing : rec(expr.expr_body, inner, true),
            filter = expr.filter === nothing ? nothing : rec(expr.filter, inner, true)
        )
    elseif _is_elementwise_node(expr)
        return reconstruct(expr; args = ASTExpr[rec(a) for a in expr.args])
    end
    return expr
end

# `x = rhs` lifted over `shape`: a `faq` over the index sets of `shape` whose
# body is `rhs` read at the cell (esm-spec §9.6.11). Every array read must name
# only index sets of `shape`, each once (§4.3.4).
function _lift_elementwise_application(
        rhs::ASTExpr, shape::Vector{String},
        shapes::Dict{String, Vector{String}}, ctx, lhs::AbstractString
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
        _ew_at_cell(rhs, shapes, ctx, loops, _AxisAlign(shape, shapes))
    catch e
        e isa TreeWalkError && e.code == "E_TREEWALK_ARRAY_SHAPE_MISMATCH" || rethrow()
        throw(DimensionPromotionError("array_shape_mismatch: '$(lhs)': $(e.detail) (esm-spec §9.6.11)"))
    end
    return OpExpr(
        "faq", ASTExpr[];
        output_idx = Any[l for l in loops], ranges = ranges, expr_body = body
    )
end
