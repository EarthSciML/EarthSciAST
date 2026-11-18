# What an equation's left-hand side may name.

# Lower-case wire spelling of a ModelVariableType for diagnostics. Total over
# the enum: a missing arm here silently MISLABELS a variable in the diagnostic
# it prints.
_variable_type_word(t::ModelVariableType)::String =
    t == ParameterVariable ? "parameter" : "unknown"

# The variable a left-hand side defines or differentiates (a parameter may have
# neither a definition nor dynamics), not through an `ic`; `nothing` otherwise.
function _lhs_defined_name(e)
    s = _lhs_shape(e)
    return s.role === :definition || s.role === :derivative ? s.name : nothing
end

# The model variable `name` refers to from the component at scoped name
# `scope`: a local variable, a scoped reference into a subsystem, or one
# written from the top-level model `root_name` (and from no other).
function _lhs_variable(ix::_ScopedIndex, scope::String, name::String, root_name::String)
    d = _resolve_declaration(
        ix, scope, name; kinds = (:variable,), absolute = startswith(name, root_name * ".")
    )
    return d === nothing ? nothing : d.decl
end

# Free string subscripts of `index` nodes in `e`: not bound by an enclosing faq
# (or by `bound`), and not in `names` (the declared variables, the
# metaparameters and the independent variable).
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
                (n in bound || n in names) || push!(out, n)
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
    _check_equation_lhs_names!(errors, ix, model, path, scope, root_name, metaparameters)

esm-spec §6.3.1, what an equation's left-hand side may name: an equation defines
unknowns, never a parameter (`equation_defines_parameter`, for a bare, indexed
or faq-wrapped left side and for a scoped reference into a subsystem), and an
index symbol on it must be bound by a faq on that side or, for the bare-index
definition, by the right side's faq `output_idx` (`unbound_index_symbol`).
Checks `model`'s own equations; `scope` is its scoped name, `root_name` the
top-level model it sits in, and `ix` the document's declarations.
"""
function _check_equation_lhs_names!(
        errors::Vector{StructuralError}, ix::_ScopedIndex, model::Model,
        path::String, scope::String, root_name::String,
        meta::Set{String}
    )
    names = Set{String}(keys(model.variables))
    union!(names, meta)
    for (k, eq) in enumerate(model.equations)
        lhs = eq.lhs
        (lhs isa OpExpr && (lhs::OpExpr).op == "ic") && continue
        lpath = _pointer(path, "equations", k, "lhs")
        dn = _lhs_defined_name(lhs)
        if dn !== nothing
            v = _lhs_variable(ix, scope, dn, root_name)
            if v !== nothing && v.type == ParameterVariable
                _report!(
                    errors, ERROR_CODES.EQUATION_DEFINES_PARAMETER,
                    lpath,
                    "Equation $(k - 1) defines '$(dn)', which is a parameter; an " *
                        "equation defines unknowns only",
                    Dict{String, Any}("variable" => dn)
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
            _report!(
                errors, ERROR_CODES.UNBOUND_INDEX_SYMBOL,
                lpath,
                "Equation $(k - 1)" * (dn === nothing ? "" : " (defining '$(dn)')") *
                    " subscripts its left-hand side with '$(sym)', which no faq binds",
                Dict{String, Any}("symbol" => sym)
            )
        end
    end
    return errors
end
