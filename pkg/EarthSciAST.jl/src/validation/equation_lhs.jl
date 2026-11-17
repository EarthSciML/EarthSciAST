# What an equation's left-hand side may name.

# Lower-case wire spelling of a ModelVariableType for diagnostics. Total over
# the enum: a missing arm here silently MISLABELS a variable in the diagnostic
# it prints.
_variable_type_word(t::ModelVariableType)::String =
    t == ParameterVariable ? "parameter" : "unknown"

# The variable a left-hand side names — through `index` / `faq` wrappers and a
# time derivative `D` (a parameter may have neither a definition nor dynamics),
# not an `ic` — or `nothing`.
function _lhs_defined_name(e)
    while e isa OpExpr
        o = e::OpExpr
        if _is_faq_op(o.op) && o.expr_body !== nothing
            e = o.expr_body
        elseif (o.op == "index" || _is_time_derivative(o)) && !isempty(o.args)
            e = o.args[1]
        else
            return nothing
        end
    end
    return e isa VarExpr ? (e::VarExpr).name : nothing
end

# The declaration `name` refers to from `model`: a local variable, or a scoped
# reference into a subsystem, written from the model or from the root model.
function _lhs_variable(model::Model, name::String, root_name::String, root::Model)
    v = get(model.variables, name, nothing)
    v === nothing || return v
    parts = split(name, '.')
    for (start, cur0) in ((1, model), (2, parts[1] == root_name ? root : nothing))
        cur = cur0
        cur === nothing && continue
        ok = true
        for p in parts[start:(end - 1)]
            sub = get(cur.subsystems, String(p), nothing)
            if sub isa Model
                cur = sub
            else
                ok = false; break
            end
        end
        ok || continue
        v = get(cur.variables, String(parts[end]), nothing)
        v === nothing || return v
    end
    return nothing
end

# Free string subscripts of `index` nodes in `e`: not bound by an enclosing faq
# (or by `bound`), and naming no declared variable or metaparameter.
function _free_lhs_index_symbols!(
        out::Vector{String}, e, bound::Set{String},
        names::Set{String}
    )
    e isa OpExpr || return out
    o = e::OpExpr
    if _is_faq_op(o.op)
        b = copy(bound)
        o.output_idx === nothing || foreach(x -> x isa AbstractString && push!(b, String(x)), o.output_idx)
        o.ranges === nothing || foreach(k -> push!(b, String(k)), keys(o.ranges))
        o.expr_body === nothing || _free_lhs_index_symbols!(out, o.expr_body, b, names)
        foreach(a -> _free_lhs_index_symbols!(out, a, b, names), o.args)
        return out
    end
    if o.op == "index" && !isempty(o.args)
        _free_lhs_index_symbols!(out, o.args[1], bound, names)
        for a in o.args[2:end]
            if a isa VarExpr
                n = (a::VarExpr).name
                (n in bound || n in names || n == "t") || push!(out, n)
            else
                _free_lhs_index_symbols!(out, a, bound, names)
            end
        end
        return out
    end
    foreach(a -> _free_lhs_index_symbols!(out, a, bound, names), o.args)
    return out
end

"""
    _check_equation_lhs_names!(errors, model, path, root_name, root, metaparameters)

esm-spec §6.3.1, what an equation's left-hand side may name: an equation defines
unknowns, never a parameter (`equation_defines_parameter`, for a bare, indexed
or faq-wrapped left side and for a scoped reference into a subsystem), and an
index symbol on it must be bound by a faq on that side or, for the bare-index
definition, by the right side's faq `output_idx` (`unbound_index_symbol`).
Recurses into inline subsystems.
"""
function _check_equation_lhs_names!(
        errors::Vector{StructuralError}, model::Model,
        path::String, root_name::String, root::Model,
        meta::Set{String}
    )
    names = Set{String}(keys(model.variables))
    union!(names, meta)
    for (k, eq) in enumerate(model.equations)
        lhs = eq.lhs
        (lhs isa OpExpr && (lhs::OpExpr).op == "ic") && continue
        lpath = "$path/equations/$(k - 1)/lhs"
        dn = _lhs_defined_name(lhs)
        if dn !== nothing
            v = _lhs_variable(model, dn, root_name, root)
            if v !== nothing && v.type == ParameterVariable
                push!(
                    errors, StructuralError(
                        lpath,
                        "Equation $(k - 1) defines '$(dn)', which is a parameter; an " *
                            "equation defines unknowns only",
                        ERROR_CODES.EQUATION_DEFINES_PARAMETER,
                        Dict{String, Any}("variable" => dn)
                    )
                )
            end
        end
        rhs = eq.rhs
        rb = Set{String}()
        if rhs isa OpExpr && _is_faq_op((rhs::OpExpr).op) && (rhs::OpExpr).output_idx !== nothing
            foreach(x -> x isa AbstractString && push!(rb, String(x)), (rhs::OpExpr).output_idx)
        end
        free = unique!(_free_lhs_index_symbols!(String[], lhs, rb, names))
        for sym in free
            push!(
                errors, StructuralError(
                    lpath,
                    "Equation $(k - 1)" * (dn === nothing ? "" : " (defining '$(dn)')") *
                        " subscripts its left-hand side with '$(sym)', which no faq binds",
                    ERROR_CODES.UNBOUND_INDEX_SYMBOL,
                    Dict{String, Any}("symbol" => sym)
                )
            )
        end
    end
    for (sname, sub) in model.subsystems
        sub isa Model || continue
        _check_equation_lhs_names!(errors, sub, "$path/subsystems/$sname", root_name, root, meta)
    end
    return errors
end
