# Coupling preflight checks and coupling-rule application (spec §4.7.5 step 3):
# conflicting-derivative detection, variable-map unit checks, then
# operator_compose / couple / variable_map application, plus the human-readable
# coupling descriptions recorded in FlattenMetadata. Split from flatten.jl.

using OrderedCollections: OrderedDict

"""
    lhs_dependent_variable(expr) -> Union{String, Nothing}

Extract the dependent variable name from an equation LHS. For `D(x, t)`, returns
`"x"`. For a bare `VarExpr("x")`, returns `"x"`. Otherwise returns `nothing`.
"""
function lhs_dependent_variable(expr::Expr)::Union{String, Nothing}
    if expr isa VarExpr
        return expr.name
    elseif expr isa OpExpr && expr.op == "D" && !isempty(expr.args) && expr.args[1] isa VarExpr
        return (expr.args[1]::VarExpr).name
    end
    return nothing
end

# ========================================
# Conflicting-derivative detection (item E)
# ========================================

"""
    _find_conflicting_derivatives(file) -> Vector{String}

Return the sorted list of fully-qualified species names that appear both as
the LHS dependent variable of an explicit `D(X, t) = ...` equation in any
`models[*]` (including subsystems) AND as a substrate or product of a
reaction in any `reaction_systems[*]` (after namespacing).

Used by `flatten` to throw `ConflictingDerivativeError` before any lowering,
and by `validate_structural` to catch the same class of error at load time.
"""
function _find_conflicting_derivatives(file::EsmFile)::Vector{String}
    explicit_lhs = Set{String}()
    if file.models !== nothing
        for (name, model) in file.models
            _collect_explicit_derivative_lhs!(explicit_lhs, model, name)
        end
    end

    reaction_species = Set{String}()
    if file.reaction_systems !== nothing
        for (name, rsys) in file.reaction_systems
            _collect_reaction_species!(reaction_species, rsys, name)
        end
    end

    conflicting = sort!(collect(intersect(explicit_lhs, reaction_species)))

    # operator_compose is ADDITIVE-merge coupling: a model's explicit `D(X)` for a
    # reaction species X is an operator CONTRIBUTION that flatten SUMS with the
    # reaction ODE (per-species / non-generic transport), not an over-determining
    # redefinition. The generic `_var` operator already relies on this (it just
    # defers naming X); naming X explicitly is the same additive merge. So a
    # species whose reaction system participates in an operator_compose coupling is
    # not a conflict.
    if !isempty(conflicting) && !isempty(file.coupling)
        op_systems = Set{String}()
        for entry in file.coupling
            entry isa CouplingOperatorCompose || continue
            for s in entry.systems
                push!(op_systems, String(s))
            end
        end
        isempty(op_systems) ||
            filter!(c -> !(String(split(c, '.')[1]) in op_systems), conflicting)
    end
    return conflicting
end

function _collect_explicit_derivative_lhs!(acc::Set{String}, model::Model, prefix::String)
    for eq in model.equations
        if eq.lhs isa OpExpr && eq.lhs.op == "D" && !isempty(eq.lhs.args) &&
           eq.lhs.args[1] isa VarExpr
            raw = (eq.lhs.args[1]::VarExpr).name
            # A bare name refers to a variable in this model's scope.
            push!(acc, occursin('.', raw) ? raw : "$(prefix).$(raw)")
        end
    end
    for (sub_name, sub) in model.subsystems
        # Only Model subsystems contribute explicit-derivative LHS names.
        sub isa Model || continue
        _collect_explicit_derivative_lhs!(acc, sub, "$(prefix).$(sub_name)")
    end
end

function _collect_reaction_species!(acc::Set{String}, rsys::ReactionSystem, prefix::String)
    for rxn in rsys.reactions
        substrates = getfield(rxn, :substrates)
        if substrates !== nothing
            for entry in substrates
                push!(acc, "$(prefix).$(entry.species)")
            end
        end
        products = getfield(rxn, :products)
        if products !== nothing
            for entry in products
                push!(acc, "$(prefix).$(entry.species)")
            end
        end
    end
    for (sub_name, sub) in rsys.subsystems
        _collect_reaction_species!(acc, sub, "$(prefix).$(sub_name)")
    end
end

# ========================================
# Hybrid-flattening preflight checks (§4.7.6)
# ========================================

"""
Walk every `variable_map` coupling entry with `transform == "identity"` and
raise `DomainUnitMismatchError` when the source and target variables carry
non-empty, declared-different units. `param_to_var` and `conversion_factor`
transforms are exempt: `conversion_factor` declares the conversion explicitly;
`param_to_var` replaces a parameter with a variable and does not imply unit
equivalence at the mapping site (units are still validated elsewhere).
"""
function _check_variable_map_units(file::EsmFile)
    isempty(file.coupling) && return
    for entry in file.coupling
        entry isa CouplingVariableMap || continue
        entry.transform == "identity" || continue
        src_units = _lookup_variable_units(file, entry.from)
        tgt_units = _lookup_variable_units(file, entry.to)
        (src_units === nothing || tgt_units === nothing) && continue
        if src_units != tgt_units
            throw(DomainUnitMismatchError(entry.from, src_units, tgt_units))
        end
    end
    return
end

"""
Look up a dot-qualified variable's declared units across models, subsystems,
and reaction systems (species + parameters). Returns `nothing` when the
variable is missing or carries no declared units.
"""
function _lookup_variable_units(file::EsmFile, qualified::String)::Union{String, Nothing}
    parts = split(qualified, ".")
    length(parts) >= 2 || return nothing
    root = String(parts[1])
    tail = String(join(parts[2:end], "."))

    if file.models !== nothing && haskey(file.models, root)
        return _lookup_model_units(file.models[root], tail)
    end
    if file.reaction_systems !== nothing && haskey(file.reaction_systems, root)
        return _lookup_rsys_units(file.reaction_systems[root], tail)
    end
    return nothing
end

function _lookup_model_units(model::Model, name::String)::Union{String, Nothing}
    if haskey(model.variables, name)
        return model.variables[name].units
    end
    # Recurse into subsystems for nested names like "Inner.T".
    dot = findfirst('.', name)
    if dot !== nothing
        head = String(SubString(name, 1, dot - 1))
        rest = String(SubString(name, dot + 1))
        if haskey(model.subsystems, head)
            return _lookup_model_units(model.subsystems[head], rest)
        end
    end
    return nothing
end

function _lookup_rsys_units(rsys::ReactionSystem, name::String)::Union{String, Nothing}
    for sp in rsys.species
        sp.name == name && return sp.units
    end
    for p in rsys.parameters
        p.name == name && return p.units
    end
    dot = findfirst('.', name)
    if dot !== nothing
        head = String(SubString(name, 1, dot - 1))
        rest = String(SubString(name, dot + 1))
        if haskey(rsys.subsystems, head)
            return _lookup_rsys_units(rsys.subsystems[head], rest)
        end
    end
    return nothing
end

# ========================================
# Coupling rule application (§4.7.5 step 3)
# ========================================

"""
Apply a `CouplingOperatorCompose` entry: for each equation LHS dependent
variable (with `translate` and `_var` placeholder expansion), find matching
equations across the listed systems and sum their RHS terms. In the flattened
representation, "matching" means "has the same namespaced dependent variable".
"""
function _apply_operator_compose!(equations::Vector{Equation},
                                  entry::CouplingOperatorCompose)
    translate = entry.translate === nothing ? Dict{String, Any}() : entry.translate

    # Build placeholder targets: if any equation's LHS uses VarExpr("_var"),
    # that equation is a template to be expanded for every state variable
    # in the other systems referenced by this compose entry.
    placeholder_indices = Int[]
    normal_indices = Int[]
    for (i, eq) in enumerate(equations)
        dep = lhs_dependent_variable(eq.lhs)
        if dep !== nothing && (dep == "_var" || endswith(dep, "._var"))
            push!(placeholder_indices, i)
        else
            push!(normal_indices, i)
        end
    end

    # Expand placeholder equations into concrete ones, one per state variable
    # that belongs to any of the other systems in `entry.systems`.
    if !isempty(placeholder_indices)
        target_vars = _collect_target_state_vars(equations, normal_indices, entry.systems)
        new_equations = Equation[]
        delete_indices = Set{Int}()
        for i in placeholder_indices
            tmpl = equations[i]
            push!(delete_indices, i)
            placeholder_lhs_dep = lhs_dependent_variable(tmpl.lhs)
            for var in target_vars
                new_lhs = _substitute_placeholder(tmpl.lhs, placeholder_lhs_dep, var)
                new_rhs = _substitute_placeholder(tmpl.rhs, placeholder_lhs_dep, var)
                push!(new_equations, Equation(new_lhs, new_rhs; _comment=tmpl._comment))
            end
        end
        # Remove originals and append the expansions.
        kept = Equation[]
        for (i, eq) in enumerate(equations)
            if !(i in delete_indices)
                push!(kept, eq)
            end
        end
        append!(kept, new_equations)
        empty!(equations)
        append!(equations, kept)
    end

    # Now merge equations with identical dependent variables.
    by_dep = OrderedDict{String, Vector{Int}}()
    for (i, eq) in enumerate(equations)
        dep = lhs_dependent_variable(eq.lhs)
        dep === nothing && continue
        # Apply translation to land on a canonical name.
        canonical = get(translate, dep, dep)
        canonical = canonical isa String ? canonical : dep
        push!(get!(by_dep, canonical, Int[]), i)
    end

    merged = Equation[]
    merged_indices = Set{Int}()
    for (dep, indices) in by_dep
        if length(indices) < 2
            continue
        end
        # Sum all RHS terms into a single equation; keep the first equation's LHS.
        first_idx = indices[1]
        lhs = equations[first_idx].lhs
        terms = Expr[equations[i].rhs for i in indices]
        new_rhs = length(terms) == 1 ? terms[1] : OpExpr("+", terms)
        push!(merged, Equation(lhs, new_rhs))
        for i in indices
            push!(merged_indices, i)
        end
    end

    if isempty(merged)
        return
    end

    kept = Equation[]
    for (i, eq) in enumerate(equations)
        if !(i in merged_indices)
            push!(kept, eq)
        end
    end
    append!(kept, merged)
    empty!(equations)
    append!(equations, kept)
    return
end

function _collect_target_state_vars(equations::Vector{Equation},
                                    normal_indices::Vector{Int},
                                    system_names::Vector{String})::Vector{String}
    vars = String[]
    seen = Set{String}()
    for i in normal_indices
        dep = lhs_dependent_variable(equations[i].lhs)
        dep === nothing && continue
        parts = split(dep, ".")
        length(parts) >= 2 || continue
        root = String(parts[1])
        if root in system_names && !(dep in seen)
            push!(vars, dep)
            push!(seen, dep)
        end
    end
    return vars
end

function _substitute_placeholder(expr::Expr,
                                 placeholder::Union{String, Nothing},
                                 target::String)::Expr
    placeholder === nothing && return expr
    if expr isa NumExpr || expr isa IntExpr
        return expr
    elseif expr isa VarExpr
        if expr.name == "_var" || expr.name == placeholder ||
           endswith(expr.name, "._var")
            return VarExpr(target)
        end
        return expr
    elseif expr isa OpExpr
        # Recurse into EVERY expression-bearing field via the shared field-preserving
        # rewrite and rebuild via `reconstruct`, which preserves all other fields
        # (table/table_axes, int_var, join, id, manifold, key, …) that a hand-listed
        # keyword subset used to drop. `placeholder`/`target` are namespaced
        # dependent-variable names, never node-local binders, so recursing into
        # every field cannot capture a bound index or `int_var`.
        return map_children(x -> _substitute_placeholder(x, placeholder, target), expr)
    end
    return expr
end

"""
Apply a `CouplingCouple` entry: attach the connector equations to the
flattened equation list. The connector.equations field may contain full
equation structures; we accept both raw Equation objects and dict-shaped
connector entries whose `lhs`/`rhs` are already-parsed `Expr`s.

A dict-shaped connector equation that cannot be coerced (no parsed `Expr`
lhs/rhs) is NOT silently degraded into a bogus placeholder equation; it is
recorded in `opaque_refs` (the `metadata.opaque_coupling_refs` channel used
for the other couplings the flattener cannot lower) so callers can see the
entry was skipped. The spec taxonomy (§4.7.6, 8 error types for
cross-language parity) has no matching typed error, and adding a ninth is
forbidden — the opaque-refs channel is the designated fallback.
"""
function _apply_couple!(equations::Vector{Equation},
                        entry::CouplingCouple,
                        opaque_refs::Vector{String})
    connector = entry.connector
    if haskey(connector, "equations")
        raw = connector["equations"]
        if raw isa AbstractVector
            for item in raw
                if item isa Equation
                    push!(equations, item)
                elseif item isa AbstractDict
                    lhs = get(item, "lhs", nothing)
                    rhs = get(item, "rhs", nothing)
                    if lhs isa Expr &&
                       rhs isa Expr
                        push!(equations, Equation(lhs, rhs; _comment="couple"))
                    else
                        push!(opaque_refs, string(
                            "couple:unparsed_connector_equation:",
                            join(entry.systems, "<->")))
                    end
                end
            end
        end
    end
    return
end

"""
Apply a `CouplingVariableMap` entry: substitute the `to` parameter/variable
with the `from` variable in every flattened equation. For `param_to_var` and
`conversion_factor`, also promote `to` out of the parameters map.

When `transform` is an `Expr` (esm-spec §10.4 expression transform), the target
parameter instead becomes an observed defined by the transform expression —
see the expression arm below.

`loader_names` is the set of top-level `data_loaders` keys. When a
`param_to_var` binds a **loaded** field (`from`'s owning system is a data
loader) onto a GRID-SHAPED consumer parameter (`to` carries a non-scalar
`shape`), the shape is transferred to the loader-qualified `from` name so the
downstream pointwise lift (§10.5) still recognizes it as an array-shaped operand
to index per grid cell. Without this, deleting the shaped `to` param would strip
the field's grid shape and the lift would leave a bare (scalar) reference to the
loader variable — e.g. `-Meteorology.u_wind * grad(...)` would not be lifted to
`-index(Meteorology.u_wind, i, j) * …`. (esm-spec §11.5 "BCs from data" +
§10.4 `param_to_var`.)
"""
function _apply_variable_map!(equations::Vector{Equation},
                              params::OrderedDict{String, ModelVariable},
                              entry::CouplingVariableMap,
                              loader_names::Set{String}=Set{String}(),
                              observeds::Union{OrderedDict{String, ModelVariable},Nothing}=nothing)
    from = entry.from
    to = entry.to
    transform = entry.transform

    # Expression transform (esm-spec §10.4): the entry binds the target to a
    # DERIVED value. Remove the `to` parameter and introduce in its place an
    # observed variable — same name, units, shape, description — whose defining
    # expression is the transform, evaluated in the flattened coupled system's
    # scope. References to `to` in the equations are left intact: they now
    # resolve to the observed, exactly as if the author had declared it. Every
    # variable reference inside the transform is (by contract) a fully-scoped
    # reference, so no namespacing is applied; the expression MUST reference
    # the entry's `from` variable — it is the data-flow edge the entry declares.
    if transform isa Expr
        # `contains` (expression.jl) walks EVERY expression-bearing field —
        # aggregate bodies, filter predicates, bounds, table-lookup axes — so
        # the reference check is not blind to nested aggregate transforms.
        if !contains(transform, from)
            throw(ArgumentError(
                "variable_map($(from) -> $(to)): expression transform does not " *
                "reference the entry's 'from' variable '$(from)' (esm-spec §10.4)"))
        end
        to_var = get(params, to, nothing)
        if to_var !== nothing
            delete!(params, to)
        end
        if observeds !== nothing
            observeds[to] = ModelVariable(ObservedVariable;
                units=to_var === nothing ? nothing : to_var.units,
                description=to_var === nothing ? nothing : to_var.description,
                expression=transform,
                shape=to_var === nothing ? nothing : to_var.shape)
        end
        # Synthesize the observed's defining equation (`to ~ transform`) so the
        # flattened system stays well-determined — mirroring _collect_model!'s
        # observed-equation synthesis for authored observeds.
        push!(equations, Equation(VarExpr(to), transform))
        return
    end

    # Build replacement Expr. `factor` is a scaling coefficient (schema restricts
    # it to the scaling transforms — additive / multiplicative / conversion_factor;
    # a bare param_to_var / identity may not carry one). Apply it uniformly here
    # so all three bindings agree — Julia/Rust previously scaled only for
    # `conversion_factor`, silently dropping it for additive/multiplicative while
    # Python applied it. A factor of 1.0 is a no-op and left unwrapped.
    replacement::Expr = VarExpr(from)
    if entry.factor !== nothing && entry.factor != 1.0
        replacement = OpExpr("*",
            Expr[NumExpr(entry.factor::Float64), VarExpr(from)])
    end

    bindings = Dict{String, Expr}(to => replacement)
    for (i, eq) in enumerate(equations)
        equations[i] = Equation(
            substitute(eq.lhs, bindings),
            substitute(eq.rhs, bindings);
            _comment=eq._comment,
        )
    end

    # For param_to_var / conversion_factor, remove target param from parameter list.
    if (transform == "param_to_var" || transform == "conversion_factor") &&
       haskey(params, to)
        to_var = params[to]
        delete!(params, to)
        # Carry a grid shape from the (deleted) consumer parameter onto the
        # loader-qualified producer name, so the pointwise lift indexes the
        # loaded field per cell. Only when `from` is a data-loader variable
        # (guards against binding a model STATE, which already lives in `states`).
        if to_var.shape !== nothing && !isempty(to_var.shape) && !haskey(params, from)
            from_owner = first(split(from, "."; limit=2))
            if from_owner in loader_names
                params[from] = ModelVariable(ParameterVariable;
                    shape=to_var.shape, units=to_var.units,
                    description=to_var.description)
            end
        end
    end
    return
end

# ========================================
# Coupling entry descriptions (unchanged from prior implementation)
# ========================================

"""
    describe_coupling_entry(entry::CouplingEntry) -> String

Produce a human-readable description of a coupling entry for the flattened
system's metadata. One method per concrete coupling type; the
`CouplingEntry` fallback covers any future/unknown subtype.
"""
describe_coupling_entry(entry::CouplingEntry)::String =
    "unknown_coupling($(typeof(entry)))"

# Append the optional free-text description shared by every coupling type.
_with_coupling_description(desc::String, description) =
    description === nothing ? desc : desc * " -- $(description)"

describe_coupling_entry(entry::CouplingOperatorCompose)::String =
    _with_coupling_description(
        "operator_compose($(join(entry.systems, " + ")))", entry.description)

describe_coupling_entry(entry::CouplingCouple)::String =
    _with_coupling_description(
        "couple($(join(entry.systems, " <-> ")))", entry.description)

function describe_coupling_entry(entry::CouplingVariableMap)::String
    transform_str = entry.transform isa Expr ?
        "expression" : entry.transform
    desc = "variable_map($(entry.from) -> $(entry.to), transform=$(transform_str))"
    if entry.factor !== nothing
        desc *= " [factor=$(entry.factor)]"
    end
    return _with_coupling_description(desc, entry.description)
end

describe_coupling_entry(entry::CouplingOperatorApply)::String =
    _with_coupling_description("operator_apply($(entry.operator))", entry.description)

describe_coupling_entry(entry::CouplingCallback)::String =
    _with_coupling_description("callback($(entry.callback_id))", entry.description)

describe_coupling_entry(entry::CouplingEvent)::String =
    _with_coupling_description("event($(entry.event_type))", entry.description)
