# The broadcast checks: the fn contract and element-wise axis alignment.

"""
    validate_broadcast_semantics(file::EsmFile) -> Vector{StructuralError}

Array broadcast semantics (esm-spec §4.3.4), document-wide. Two families:

**The `broadcast.fn` contract.** `fn` is parsed as an opaque string, so a
`broadcast` naming a nonexistent operator (`"not_a_real_op"`), naming a
STRUCTURAL operator (`faq`, `index`, `makearray`, `D`, …), carrying no
`fn` at all, or handing its operator the wrong number of operands is reported
here rather than at evaluation. The contract itself is
[`_broadcast_fn_problem`](@ref) (op_registry.jl) — the same predicate the
tree-walk build lowering and the MTK exporter enforce, and the rule is simply
"`broadcast(fn: F, args)` is legal exactly when `{op: F, args}` is legal".
All four defects report under the one cross-binding code
`invalid_broadcast_fn` (esm-spec §9.6.6); `details["reason"]` is
`missing` / `unknown` / `non_scalar` / `arity`.

**Name-based operand alignment** (esm-spec §4.3.4 "Broadcast compatibility").
An element-wise operand aligns with the result by index-set NAME: an operand
whose declared index sets are a SUBSET of the result's broadcasts along the
missing axes (and a name-PERMUTED operand transposes). An operand declared over
an index set the result does NOT have has no alignment at all — reported as
`array_shape_mismatch`. The result shape is the declared shape of the equation's
whole-array LHS (`D(v)` or a bare `v`) or of the array observed being defined,
and is used only when its axis names do not repeat. The walk descends ONLY
through element-wise (scalar) operators; an explicit `index` gather, a
`faq`/`makearray`/`reshape`/`transpose`/`concat`/`broadcast`, a
relational or geometry kernel, and an unlowered rewrite target each consume
their operands WHOLE under their own contract and are not element-wise
positions.
"""
function validate_broadcast_semantics(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]
    if file.models !== nothing
        for model_name in sort!(collect(keys(file.models)))
            _check_model_broadcasts!(errors, file.models[model_name], _pointer("", "models", model_name))
        end
    end
    if file.reaction_systems !== nothing
        for rs_name in sort!(collect(keys(file.reaction_systems)))
            _check_reaction_system_broadcasts!(
                errors, file.reaction_systems[rs_name], _pointer("", "reaction_systems", rs_name)
            )
        end
    end
    no_shapes = Dict{String, Vector{String}}()
    for (i, entry) in enumerate(file.coupling)
        _check_site_broadcasts!(errors, entry, _pointer("", "coupling", i), no_shapes)
    end
    return errors
end

_declared_array_shapes(shapes) = Dict{String, Vector{String}}(
    name => String[String(x) for x in s] for (name, s) in shapes
        if s !== nothing && !isempty(s)
)

# Per-model driver for `validate_broadcast_semantics`: the `fn` contract at
# every expression site of the model, plus the element-wise axis check on the
# right-hand side of every equation whose left-hand side writes a declared
# whole array. Recurses into Model subsystems.
_check_model_broadcasts!(errors::Vector{StructuralError}, model::Model, path::String) =
    (_foreach_component((m, p, _) -> _check_model_broadcasts_here!(errors, m, p), model, path); errors)

function _check_model_broadcasts_here!(
        errors::Vector{StructuralError}, model::Model,
        path::String
    )
    var_shapes = _declared_array_shapes((n, v.shape) for (n, v) in model.variables)
    _check_site_broadcasts!(errors, model, path, var_shapes)
    return errors
end

_check_reaction_system_broadcasts!(errors::Vector{StructuralError}, rs::ReactionSystem, path::String) =
    (_foreach_component((r, p, _) -> _check_reaction_system_broadcasts_here!(errors, r, p), rs, path); errors)

function _check_reaction_system_broadcasts_here!(
        errors::Vector{StructuralError}, rs::ReactionSystem, path::String
    )
    var_shapes = _declared_array_shapes((p.name, p.shape) for p in rs.parameters)
    _check_site_broadcasts!(errors, rs, path, var_shapes)
    return errors
end

# The broadcast checks over the expression sites of one component (not its
# subsystems) or one coupling entry. An observed unknown's defining expression
# is an equation, so it is covered (its bare-variable LHS gives
# `_wholearray_result_axes` the target axes).
function _check_site_broadcasts!(
        errors::Vector{StructuralError}, x, path::String,
        var_shapes::Dict{String, Vector{String}}
    )
    lhs = Ref{Union{ASTExpr, Nothing}}(nothing)
    visit = function (e, anchor, kind)
        _walk_broadcast_fns!(errors, e, anchor)
        if haskey(_RHS_OF_LHS, kind)
            lhs[] = e
        elseif kind in _EQUATION_RHS_KINDS
            tgt = _wholearray_result_axes(lhs[]::ASTExpr, var_shapes)
            tgt === nothing ||
                _check_broadcast_axes!(errors, e, tgt[1], tgt[2], var_shapes, anchor)
        end
        return nothing
    end
    if x isa CouplingEntry
        foreach_expression(visit, x, path)
    else
        foreach_expression(visit, x, path; subsystems = false)
    end
    return errors
end

# Descend `expr`; at every `broadcast` node apply the §4.3.4 `fn` contract, then
# recurse into the full expression-bearing child set (so a NESTED broadcast is
# checked too). `anchor` is the field pointer and stays constant through the
# descent — a finding attaches at the field, not the leaf.
function _walk_broadcast_fns!(
        errors::Vector{StructuralError}, expr::ASTExpr,
        anchor::String
    )
    isa(expr, OpExpr) || return errors
    if expr.op == "broadcast"
        prob = _broadcast_fn_problem(expr.fn, length(expr.args))
        if prob !== nothing
            # ONE cross-binding diagnostic code (esm-spec §9.6.6) for all four
            # defects; `details["reason"]` carries which one.
            _report!(
                errors, ERROR_CODES.INVALID_BROADCAST_FN,
                anchor,
                prob.message,
                Dict{String, Any}(
                    "fn" => expr.fn === nothing ? "" : String(expr.fn),
                    "reason" => String(prob.kind),
                    "operands" => length(expr.args)
                )
            )
        end
    end
    for c in child_exprs(expr)
        _walk_broadcast_fns!(errors, c, anchor)
    end
    return errors
end

# `(target name, declared index-set names)` for an equation whose LHS is a
# WHOLE-ARRAY write, or `nothing` otherwise (a scalar equation, or a per-cell
# `D(index(v,…))` / `faq(…)` LHS, which carries its own indexing). Mirrors
# `_lift_wholearray_deriv_equations`' `is_wholearray_D` plus the bare
# array-observed definition `v = <array rhs>`.
function _wholearray_result_axes(
        lhs::ASTExpr,
        var_shapes::Dict{String, Vector{String}}
    )
    name = lhs isa VarExpr ? (lhs::VarExpr).name :
        (
            lhs isa OpExpr && (lhs::OpExpr).op == "D" &&
            length((lhs::OpExpr).args) == 1 &&
            (lhs::OpExpr).args[1] isa VarExpr
        ) ?
        ((lhs::OpExpr).args[1]::VarExpr).name : nothing
    name === nothing && return nothing
    axes = get(var_shapes, name, nothing)
    axes === nothing && return nothing
    return (name, axes)
end

# Walk `expr` in ELEMENT-WISE position — descending ONLY through elementwise
# nodes ([`_is_elementwise_node`](@ref): a scalar operator, or a `broadcast`
# whose `fn` is one, esm-spec §4.3.4) — and report every array-variable leaf
# declared over an index set absent from the result `axes`. Anything that is not
# a scalar operator ends the walk: an `index` gather and the array producers
# carry their own indexing, and an unlowered rewrite target (a spatial `D`/a
# user op) consumes WHOLE arrays under its own contract — none of them is a broadcast, so
# an operand of a different rank there is not a defect. This mirrors exactly
# where `_wrap_bare_array_refs` (shape_promotion.jl) applies its `_AxisAlign`.
# Skipped entirely when `axes` repeats a name, and per-leaf when the operand's
# own shape does, matching `_usable_align` / `_index_wrap_var`: without a unique
# name→axis map the rewrite stays POSITIONAL, so there is nothing name-based to
# reject.
function _check_broadcast_axes!(
        errors::Vector{StructuralError}, expr::ASTExpr,
        target::String, axes::Vector{String},
        var_shapes::Dict{String, Vector{String}},
        anchor::String
    )
    allunique(axes) || return errors
    axset = Set{String}(axes)
    reported = Set{Tuple{String, String}}()   # one finding per (operand, axis)
    function walk(e::ASTExpr)
        if e isa VarExpr
            vs = get(var_shapes, (e::VarExpr).name, nothing)
            (vs === nothing || !allunique(vs)) && return nothing
            for ax in vs
                (ax in axset || ((e::VarExpr).name, ax) in reported) && continue
                push!(reported, ((e::VarExpr).name, ax))
                _report!(
                    errors, ERROR_CODES.ARRAY_SHAPE_MISMATCH,
                    anchor,
                    "Operand '$((e::VarExpr).name)' of the array-level expression " *
                        "for '$target' is declared over index set '$ax', which " *
                        "'$target' is not shaped over (esm-spec §4.3.4)",
                    Dict{String, Any}(
                        "variable" => (e::VarExpr).name,
                        "target" => target,
                        "index_set" => ax,
                        "operand_shape" => vs,
                        "result_shape" => axes
                    )
                )
            end
        elseif e isa OpExpr
            _is_elementwise_node(e::OpExpr) || return nothing
            for a in (e::OpExpr).args
                walk(a)
            end
        end
        return nothing
    end
    walk(expr)
    return errors
end
