# Variable bounds `lb` / `ub` (esm-spec §6.3.2): the version gate and the four
# validity rules. The rewrite flattening applies to a bound
# (esm-libraries-spec §4.7.5, "Bounds follow the renaming") is the bound site
# of the expression-site walk (expression_sites.jl).

# ============================================================================
# Version gate
# ============================================================================

"""
    reject_variable_bounds_pre_v21(raw_data)

Reject `lb` or `ub` on a model variable in a file declaring `esm` < 2.1.0
(esm-spec §6.3.2, "Version gate"), with `variable_bounds_version_too_old` at the
pointer of the first such field. Runs on the raw JSON before schema validation,
so the author sees the version hint rather than an unknown-property error. Only
this file's inline models and subsystems are read: a `{ref}` subsystem is
another file, gated against its own version when it is mounted.
The rule is the `variable_bounds` row of [`_VERSION_GATES`](@ref).
"""
reject_variable_bounds_pre_v21(raw_data) =
    _check_version_gate(_VERSION_GATES.variable_bounds, raw_data)

# The pointer of the first `lb` / `ub` in a raw model or inline subsystem, in
# document order (a variable's `lb` before its `ub`, a model's own variables
# before its subsystems), or `nothing`.
function _first_raw_bound(model, at::String)
    _is_object(model) || return nothing
    vars = _raw_get(model, "variables")
    if vars !== nothing && _is_object(vars)
        for (vname, v) in pairs(vars)
            _is_object(v) || continue
            for field in ("lb", "ub")
                _raw_haskey(v, field) && return _pointer(at, "variables", vname, field)
            end
        end
    end
    subs = _raw_get(model, "subsystems")
    if subs !== nothing && _is_object(subs)
        for (sname, sub) in pairs(subs)
            p = _first_raw_bound(sub, _pointer(at, "subsystems", sname))
            p === nothing || return p
        end
    end
    return nothing
end

# ============================================================================
# Validation
# ============================================================================

"""
    validate_variable_bounds(file::EsmFile; toplevel=nothing, index=nothing) -> Vector{StructuralError}

The validity rules of esm-spec §6.3.2 over every variable of every model and
inline subsystem, at `/models/M[/subsystems/S…]/variables/v`:

1. a reference that does not resolve is `undefined_variable` at `…/lb` (`/ub`);
2. a referenced variable whose declared shape is neither scalar nor the bounded
   variable's is `variable_bound_shape_mismatch`;
3. a reference to the bounded variable itself, or to an observed whose
   definition reaches it through observed definitions, is
   `variable_bound_circular`;
4. two numeric bounds with `lb > ub` are `variable_bounds_inverted` at the
   variable.

A reference resolves as a variable reference in the owning model's expressions
does (§4.9.7 precedence), through the same resolver and observed-definition
graph [`validate_coupling_cycles`](@ref) uses (`_scoped_observed_graph`), so the
two walks cannot disagree about what a name means or where a definition stops.
An unresolved reference is not checked against rules 2 and 3.
"""
function validate_variable_bounds(
        file::EsmFile; toplevel = nothing, index = nothing
    )::Vector{StructuralError}
    errors = StructuralError[]
    file.models === nothing && return errors
    _any_bound(file) || return errors
    index === nothing && (index = _scoped_index(file))
    g = _scoped_observed_graph(file; toplevel = toplevel)
    for name in sort!(collect(keys(file.models)))
        _foreach_component(
            file.models[name], _pointer("", "models", name); scope = name, sorted = true
        ) do m, p, _, s
            _check_variable_bounds!(errors, index, g, m, s, p)
        end
    end
    return errors
end

function _any_bound(file::EsmFile)
    has(m::Model) = any(v -> v.lb !== nothing || v.ub !== nothing, values(m.variables)) ||
        any(p -> has(p.second), model_subsystems(m))
    return any(has, values(file.models))
end

# The bounds of one component's own variables (not its subsystems').
function _check_variable_bounds!(
        errors::Vector{StructuralError}, index::_ScopedIndex, g,
        model::Model, scoped_path::String, pointer::String
    )
    for vname in sort!(collect(keys(model.variables)))
        var = model.variables[vname]
        vpointer = _pointer(pointer, "variables", vname)
        for (field, bound) in (("lb", var.lb), ("ub", var.ub))
            bound isa String || continue
            _check_bound_reference!(
                errors, index, g, var, vname, scoped_path, field, bound, _pointer(vpointer, field)
            )
        end
        if var.lb isa Real && var.ub isa Real && var.lb > var.ub
            _report!(
                errors, ERROR_CODES.VARIABLE_BOUNDS_INVERTED,
                vpointer,
                "'$vname' has lb $(var.lb) greater than ub $(var.ub)",
                Dict{String, Any}("variable" => vname, "lb" => var.lb, "ub" => var.ub)
            )
        end
    end
    return errors
end

function _check_bound_reference!(
        errors::Vector{StructuralError}, index::_ScopedIndex, g, var::ModelVariable,
        vname::String, scoped_path::String, field::String, ref::String, pointer::String
    )
    # Rule 1: the reference resolves as an expression's free variable would.
    target = g.resolve(scoped_path, ref)
    if target === nothing
        _report!(
            errors, ERROR_CODES.UNDEFINED_VARIABLE,
            pointer,
            "Variable \"$ref\" referenced as the $field of '$vname' but not declared",
            Dict{String, Any}("variable" => ref, "bound" => field)
        )
        return
    end
    details = Dict{String, Any}("variable" => vname, "bound" => field, "reference" => ref)

    # Rule 2: declared shapes, compared by index-set name. A reaction-system
    # species declares no shape and reads as scalar.
    own_shape = var.shape === nothing ? String[] : collect(String, var.shape)
    ref_shape = something(_declared_shape_of(index, target), String[])
    if !isempty(ref_shape) && ref_shape != own_shape
        show_shape(s) = isempty(s) ? "(scalar)" : "[" * join(s, ", ") * "]"
        _report!(
            errors, ERROR_CODES.VARIABLE_BOUND_SHAPE_MISMATCH,
            pointer,
            "The $field of '$vname' references '$ref', shaped $(show_shape(ref_shape)); " *
                "a bound must be scalar or the bounded variable's shape $(show_shape(own_shape))",
            details
        )
    end

    # Rule 3: the variable itself, or an observed whose definition reaches it.
    self = "$scoped_path.$vname"
    chain = target == self ? String[self] : _observed_chain_to(g, target, self)
    chain === nothing && return
    short(n) = startswith(n, scoped_path * ".") ? n[(length(scoped_path) + 2):end] : n
    message = length(chain) == 1 ?
        "The $field of '$vname' refers to '$vname' itself" :
        "The $field of '$vname' refers to '$ref', whose definition depends on " *
        "'$vname' ($(join(short.(chain), " -> ")))"
    _report!(
        errors, ERROR_CODES.VARIABLE_BOUND_CIRCULAR,
        pointer,
        message,
        details
    )
    return
end

# The chain of scoped names from the observed `from` to `goal` through observed
# definitions (`[from, …, goal]`), or `nothing` when none reaches it. A name
# with no definition in `g.defs` — a state, a parameter, an algebraic unknown,
# a species — ends its branch: its value is not computed from anything else.
# Breadth-first, so the reported chain is a shortest one; successors are
# visited in sorted order so it is the same chain on every run.
function _observed_chain_to(g, from::String, goal::String)
    haskey(g.defs, from) || return nothing
    parent = Dict{String, String}(from => from)
    queue = String[from]
    while !isempty(queue)
        v = popfirst!(queue)
        haskey(g.defs, v) || continue
        succ = Set{String}()
        for ref in _observed_dependency_names(g.defs[v])
            w = g.resolve(g.scope[v], ref)
            w === nothing || push!(succ, w)
        end
        for w in sort!(collect(succ))
            haskey(parent, w) && continue
            parent[w] = v
            if w == goal
                chain = String[w]
                while chain[1] != from
                    pushfirst!(chain, parent[chain[1]])
                end
                return chain
            end
            push!(queue, w)
        end
    end
    return nothing
end
