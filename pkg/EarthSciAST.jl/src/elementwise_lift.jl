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
#
# Each node is visited once per `(bound, inside)`: `seen` records the visits
# made, by node identity. Expansions share their subtrees (a template that
# references another twice holds one expansion of it), so walking them as a
# tree is exponential in the depth of the template chain. A repeated visit
# would only report again what the first one reported, so every caller sees
# the same reads and anonymous arrays, each first reported in the same order,
# without the repeats.
function _ew_visit(
        expr::ASTExpr, shapes::Dict{String, Vector{String}},
        ctx::Union{Nothing, _ElementwiseContext}, bound::Set{String}, inside::Bool,
        on_read, on_anonymous = nothing,
        seen::IdDict{OpExpr, Set{Tuple{Bool, Set{String}}}} = IdDict{OpExpr, Set{Tuple{Bool, Set{String}}}}()
    )
    if expr isa VarExpr
        (expr.name in bound || isempty(get(shapes, expr.name, String[]))) && return
        on_read(expr.name, inside)
        return
    end
    expr isa OpExpr || return
    visits = get!(() -> Set{Tuple{Bool, Set{String}}}(), seen, expr)
    (inside, bound) in visits && return
    push!(visits, (inside, bound))
    op = expr.op
    if op == "apply_expression_template"
        # Read through the reference, never expanded: a binding is in a value
        # position where its parameter is (elementwise_refs.jl `_ew_roles`).
        r = _ew_roles(ctx, expr.name)
        r === nothing && return
        b = expr.bindings === nothing ? Dict{String, ASTExpr}() : expr.bindings
        for k in sort!(collect(keys(b)))
            rk = get(r.role, k, :none)
            (rk == :value || rk == :mixed) &&
                _ew_visit(b[k], shapes, ctx, bound, true, on_read, on_anonymous, seen)
        end
        for n in r.free_value
            (n in bound || isempty(get(shapes, n, String[]))) && continue
            on_read(n, true)
        end
        return
    end
    inside = inside || expr.template_origin !== nothing
    rec(a, b = bound, i = inside) = _ew_visit(a, shapes, ctx, b, i, on_read, on_anonymous, seen)
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
# reports gathered at the loops its index sets name; a template reference keeps
# its reference, its bindings read at the cell by role (`_ew_ref_at_cell`).
#
# Memoized by node identity and `(bound, inside)`, as `_ew_visit` is: a subtree
# an expansion shares is rewritten once, and the rewrite shares it too, rather
# than re-inflating the shared expansion into a tree exponential in the depth
# of the template chain.
#
# `on_foreign(v, shape, axes, s)` answers a read naming an index set `s` the
# cell's grid is not shaped over ([`_index_wrap_var`](@ref)).
function _ew_at_cell(
        expr::ASTExpr, shapes::Dict{String, Vector{String}}, ctx,
        loops::Vector{String}, align, on_foreign, bound::Set{String} = Set{String}(),
        inside::Bool = false,
        memo::IdDict{OpExpr, Dict{Tuple{Bool, Set{String}}, ASTExpr}} = IdDict{OpExpr, Dict{Tuple{Bool, Set{String}}, ASTExpr}}()
    )::ASTExpr
    if expr isa VarExpr
        (expr.name in bound || isempty(get(shapes, expr.name, String[]))) && return expr
        return _index_wrap_var(expr, loops, align; on_foreign = on_foreign)
    end
    expr isa OpExpr || return expr
    done = get!(() -> Dict{Tuple{Bool, Set{String}}, ASTExpr}(), memo, expr)
    return get!(done, (inside, bound)) do
        _ew_at_cell_op(expr, shapes, ctx, loops, align, on_foreign, bound, inside, memo)
    end
end

function _ew_at_cell_op(
        expr::OpExpr, shapes::Dict{String, Vector{String}}, ctx,
        loops::Vector{String}, align, on_foreign, bound::Set{String}, inside::Bool, memo
    )::ASTExpr
    op = expr.op
    inside = inside || expr.template_origin !== nothing
    rec(a, b = bound, i = inside) = _ew_at_cell(a, shapes, ctx, loops, align, on_foreign, b, i, memo)
    if op == "apply_expression_template"
        # The reference stays a reference: its bindings are read at the cell
        # by role, never its expansion (esm-spec §9.6.11).
        return _ew_ref_at_cell(expr, shapes, ctx, v -> rec(v, bound, true), bound)
    end
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
    loops = _fresh_loops(rhs, length(shape); ctx = ctx)
    foreign(v, vs, axes, s) = throw(
        DimensionPromotionError(
            "array_shape_mismatch: '$(lhs)': $(_array_shape_mismatch_text(v, vs, axes, s)) " *
                "(esm-spec §9.6.11)"
        )
    )
    body = _ew_at_cell(rhs, shapes, ctx, loops, _AxisAlign(shape, shapes), foreign)
    return _cell_faq(body, loops, _cell_ranges(loops, shape))
end

# Every array's index sets as the build sees them (esm-spec §4.3.1): a
# variable's declared non-empty `shape`, or, for a variable declared without
# one, the shape its defining equation evaluates to (§4.3.4, §9.6.11), to a
# fixed point. An explicit `shape: []` declares a scalar and is never given
# one. The Rust binding's `promoted_var_shapes`.
#
# `seed` holds shapes inferred by an earlier
# call on this system (the pointwise lift's); each is kept unless its
# definition reads, directly or through another seeded variable, a name in
# `stale` (a state whose declared shape has changed since).
function _flat_array_shapes(
        states, params, observeds, equations, ctx;
        seed::Union{Nothing, AbstractDict} = nothing, stale = ()
    )
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
    open = filter!(
        ((n, _),) -> !(haskey(shapes, n) || n in declared_scalar), _bare_definitions(equations)
    )
    if seed !== nothing
        kept = Dict{String, ASTExpr}(n => rhs for (n, rhs) in open if haskey(seed, n))
        dropped = Set{String}(stale)
        grew = true
        while grew
            grew = false
            for (n, rhs) in kept
                isempty(intersect(free_variables(rhs), dropped)) && continue
                push!(dropped, n)
                delete!(kept, n)
                grew = true
            end
        end
        for n in keys(kept)
            shapes[n] = seed[n]
        end
    end
    return _infer_shapes!(shapes, open, ctx)
end

# Whether `e` holds a template application: a reference this binding kept, or
# the root of an expansion made at load.
function _holds_application(e, seen::IdDict{OpExpr, Nothing} = IdDict{OpExpr, Nothing}())
    e isa OpExpr || return false
    (e.op == "apply_expression_template" || e.template_origin !== nothing) && return true
    haskey(seen, e) && return false
    seen[e] = nothing
    found = false
    foreach_child(c -> (found = found || _holds_application(c, seen)), e)
    return found
end

"""
    _lift_elementwise_applications_flat!(pool, field_ics, states, params, observeds, registry; seed, stale)

Flatten's last step (esm-spec §9.6.11, "A flattened system keeps its
applications' meaning on the wire"): every equation `x = rhs`, and every field
initial condition `ic(x) = rhs`, that applies a template elementwise becomes
the per-cell `faq` the build would lift it to. Its template references stay
references, each binding read at the cell by its parameter's role
(elementwise_refs.jl; esm-spec §9.6.11): nothing is expanded. A flattened system written out as a document and read back — the
EarthSciIntegrator planner's derived documents, after `expand_flattened_refs` —
then denotes the same system: left as an application whose expansion reads an
array by bare name inside the template's bracket count, it would be refused as
`faq_bare_array_operand` (§4.3.1). An initial condition is lifted over its
state's shape.

No declaration changes (esm-libraries-spec §4.7.5). A lifted equation's
contributions collapse into the one `faq`, their origins united. When an
operand cannot be aligned to its target (`array_shape_mismatch`), every equation
and initial condition is left as it was, for the build to refuse. `seed`/`stale` reuse the
pointwise lift's shapes (`_flat_array_shapes`). Returns the field initial
conditions, lifted. The Rust binding's flatten writes the same equations.
"""
function _lift_elementwise_applications_flat!(
        pool::Vector{_FlatEq}, field_ics::Vector{Pair{String, ASTExpr}},
        states, params, observeds, registry; seed = nothing, stale = ()
    )
    equations = _pool_equations(pool)
    # An expansion is elementwise only because it came from an application.
    (
        any(eq -> _holds_application(eq.rhs), equations) ||
            any(p -> _holds_application(last(p)), field_ics)
    ) || return field_ics
    ctx = _ElementwiseContext(registry === nothing || isempty(registry) ? nothing : registry)
    shapes = _flat_array_shapes(
        states, params, observeds, equations, ctx; seed = seed, stale = stale
    )
    lifted = Dict{Int, OpExpr}()
    lifted_ics = Dict{Int, OpExpr}()
    try
        for eq in equations
            _refuse_anonymous_arrays(eq.rhs, eq.lhs, ctx)
        end
        for (target, rhs) in field_ics
            _refuse_anonymous_arrays(rhs, VarExpr(target), ctx)
        end
        for (n, eq) in enumerate(equations)
            eq.lhs isa VarExpr || continue
            name = (eq.lhs::VarExpr).name
            _has_elementwise_application(eq.rhs, shapes, ctx) || continue
            sh = get(shapes, name, String[])
            isempty(sh) && continue
            lifted[n] = _lift_elementwise_application(eq.rhs, sh, shapes, ctx, name)
        end
        for (n, (target, rhs)) in enumerate(field_ics)
            sh = get(shapes, target, String[])
            (isempty(sh) || !_has_elementwise_application(rhs, shapes, ctx)) && continue
            lifted_ics[n] = _lift_elementwise_application(rhs, sh, shapes, ctx, target)
        end
    catch e
        e isa DimensionPromotionError || rethrow()
        return field_ics
    end
    for (n, rhs) in lifted
        pool[n] = _with_contribs(pool[n], Contribution[Contribution(rhs, _union_origins(pool[n].contribs))])
    end
    isempty(lifted_ics) && return field_ics
    return Pair{String, ASTExpr}[
        haskey(lifted_ics, n) ? (first(p) => lifted_ics[n]) : p for (n, p) in enumerate(field_ics)
    ]
end
