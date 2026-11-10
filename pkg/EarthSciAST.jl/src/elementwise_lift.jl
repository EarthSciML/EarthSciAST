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
struct _ElementwiseContext
    registry::Any
    memo::Dict{Tuple{String, String}, OpExpr}
end

_ElementwiseContext(registry) =
    _ElementwiseContext(registry, Dict{Tuple{String, String}, OpExpr}())

# The expansion of the application `e`, its root marked with the template's
# name, or `nothing` when `ctx` has no registry to expand it against.
function _ew_expansion(e::OpExpr, ctx::Union{Nothing, _ElementwiseContext})
    (ctx === nothing || ctx.registry === nothing || isempty(ctx.registry)) && return nothing
    return task_local_storage(_MARK_TEMPLATE_ORIGINS_KEY, true) do
        _expand_expr_refs(e, ctx.registry, nothing, ctx.memo)
    end
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

_is_anonymous_array(e::OpExpr) =
    e.op == "reshape" || (e.op == "const" && e.value isa AbstractVector)

# Visit every value position of `expr` (esm-spec §9.6.11). Outside a template
# application those are the operands of elementwise operators and the scalar
# arguments of closed functions, the positions the per-cell reading commutes
# with. Inside one (an expanded reference, a node carrying `template_origin`,
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
    elseif op == "fn"
        whole = _whole_array_fn_args(expr.name)
        for (i, a) in enumerate(expr.args)
            i in whole || rec(a)
        end
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
    elseif op == "fn"
        whole = _whole_array_fn_args(expr.name)
        return reconstruct(
            expr; args = ASTExpr[i in whole ? a : rec(a) for (i, a) in enumerate(expr.args)]
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
    loops = _ew_fresh_loops(rhs, length(shape), ctx)
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

# Every name `expr` reads or binds, its template references expanded: the
# names a lift's loop symbols must not shadow.
function _ew_names!(out::Set{String}, e)
    if e isa VarExpr
        push!(out, e.name)
    elseif e isa OpExpr
        foreach(a -> _ew_names!(out, a), e.args)
        e.expr_body === nothing || _ew_names!(out, e.expr_body)
        e.filter === nothing || _ew_names!(out, e.filter)
        e.ranges === nothing || union!(out, (String(k) for k in keys(e.ranges)))
        if e.output_idx !== nothing
            for x in e.output_idx
                x isa AbstractString && push!(out, String(x))
            end
        end
    end
    return out
end

# The lift's loop symbols `_p0, _p1, …`, each prefixed with one more `_` until
# none is a name `rhs` (expanded) reads or binds. The same choice as the Rust
# binding's, so the two write the same lifted equation.
function _ew_fresh_loops(rhs::ASTExpr, n::Integer, ctx)
    full = if ctx === nothing || ctx.registry === nothing || isempty(ctx.registry)
        rhs
    else
        task_local_storage(_MARK_TEMPLATE_ORIGINS_KEY, true) do
            _expand_expr_refs(rhs, ctx.registry, nothing, ctx.memo)
        end
    end
    used = _ew_names!(Set{String}(), full)
    prefix = "_p"
    while true
        loops = String["$(prefix)$(d)" for d in 0:(n - 1)]
        any(in(used), loops) || return loops
        prefix = "_" * prefix
    end
    return
end

# Every array's index sets as the build sees them (esm-spec §4.3.1): a
# variable's declared non-empty `shape`, or, for a variable declared without
# one, the shape its defining equation evaluates to (§4.3.4, §9.6.11), to a
# fixed point. An explicit `shape: []` declares a scalar and is never given
# one. The Rust binding's `promoted_var_shapes`.
function _flat_array_shapes(states, params, observeds, equations, ctx)
    shapes = Dict{String, Vector{String}}()
    declared_scalar = Set{String}()
    for d in (params, observeds, states), (k, v) in d
        v.shape === nothing && continue
        if isempty(v.shape)
            push!(declared_scalar, k)
        else
            haskey(shapes, k) || (shapes[k] = String[string(x) for x in v.shape])
        end
    end
    open = Tuple{String, ASTExpr}[]
    for eq in equations
        eq.lhs isa VarExpr || continue
        n = (eq.lhs::VarExpr).name
        (haskey(shapes, n) || n in declared_scalar) && continue
        push!(open, (n, eq.rhs))
    end
    changed = true
    while changed
        changed = false
        for (n, rhs) in open
            haskey(shapes, n) && continue
            # An operand-shape conflict is the build's to report (as
            # `array_shape_mismatch`); here it only means no shape.
            sh = try
                _infer_expr_shape(rhs, shapes, ctx)
            catch e
                e isa DimensionPromotionError || rethrow()
                String[]
            end
            isempty(sh) && continue
            shapes[n] = sh
            changed = true
        end
    end
    return shapes
end

"""
    _lift_elementwise_applications_flat!(equations, contribs, states, params, observeds, registry)

Flatten's last step (esm-spec §9.6.11, "A flattened system keeps its
applications' meaning on the wire"): every equation `x = rhs` that applies a
template elementwise becomes the per-cell `faq` the build would lift it to, its
template references expanded. A flattened system written out as a document and
read back — the EarthSciIntegrator planner's derived documents, after
`expand_flattened_refs` — then denotes the same system: left as an application
whose expansion reads an array by bare name inside the template's bracket
count, it would be refused as `faq_bare_array_operand` (§4.3.1).

No declaration changes (esm-libraries-spec §4.7.5). A lifted equation's
contributions collapse into the one `faq`, their origins united. When any
right-hand side is refused (`array_shape_mismatch`), every equation is left as
it was, for the build to refuse. The Rust binding's flatten writes the same
equations.
"""
function _lift_elementwise_applications_flat!(
        equations::Vector{Equation}, contribs::Vector{Vector{Contribution}},
        states, params, observeds, registry
    )
    ctx = _ElementwiseContext(registry === nothing || isempty(registry) ? nothing : registry)
    shapes = _flat_array_shapes(states, params, observeds, equations, ctx)
    lifted = Dict{Int, OpExpr}()
    try
        for eq in equations
            _refuse_anonymous_arrays(eq.rhs, eq.lhs, ctx)
        end
        for (n, eq) in enumerate(equations)
            eq.lhs isa VarExpr || continue
            name = (eq.lhs::VarExpr).name
            sh = get(shapes, name, String[])
            (isempty(sh) || !_has_elementwise_application(eq.rhs, shapes, ctx)) && continue
            lifted[n] = _lift_elementwise_application(eq.rhs, sh, shapes, ctx, name)
        end
    catch e
        e isa DimensionPromotionError || rethrow()
        return
    end
    for (n, rhs) in lifted
        contribs[n] = Contribution[Contribution(rhs, _union_origins(contribs[n]))]
        equations[n] = _equation_from(equations[n], contribs[n])
    end
    return
end
