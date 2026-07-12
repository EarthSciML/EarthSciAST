# Coupling preflight checks and coupling-rule application (spec §4.7.5 step 3):
# conflicting-derivative detection, variable-map unit checks, then
# operator_compose / couple / variable_map application, plus the human-readable
# coupling descriptions recorded in FlattenMetadata. Split from flatten.jl.

using OrderedCollections: OrderedDict

# ========================================
# Equation-LHS pattern helpers
# ========================================

"""
    lhs_dependent_variable(expr) -> Union{String, Nothing}

Extract the dependent variable name from an equation LHS. For `D(x, t)`, returns
`"x"`. For a bare `VarExpr("x")`, returns `"x"`. Otherwise returns `nothing`.

NOTE: this deliberately CONFLATES the differential (`D(x, t) = …`) and bare
algebraic (`x = …`) equation forms — the operator_compose merge keys equations
by dependent variable regardless of form. Use
[`differential_lhs_variable`](@ref) when only the differential form should
match (e.g. state-ODE detection).
"""
function lhs_dependent_variable(expr::ASTExpr)::Union{String, Nothing}
    if expr isa VarExpr
        return expr.name
    elseif expr isa OpExpr && expr.op == "D" && !isempty(expr.args) && expr.args[1] isa VarExpr
        return (expr.args[1]::VarExpr).name
    end
    return nothing
end

"""
    differential_lhs_variable(expr) -> Union{String, Nothing}

The dependent-variable name of a DIFFERENTIAL equation LHS: returns `"x"` for
`D(x, …)` (any `wrt` — the flatten pipeline's LHS derivatives are time
derivatives by construction, so `wrt` is not inspected) and `nothing` for
anything else, including a bare `VarExpr` — see
[`lhs_dependent_variable`](@ref) for the form-conflating variant.
"""
function differential_lhs_variable(expr::ASTExpr)::Union{String, Nothing}
    expr isa OpExpr || return nothing
    expr.op == "D" || return nothing
    (!isempty(expr.args) && expr.args[1] isa VarExpr) || return nothing
    return (expr.args[1]::VarExpr).name
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
        raw = differential_lhs_variable(eq.lhs)
        raw === nothing && continue
        # A bare name refers to a variable in this model's scope.
        push!(acc, occursin('.', raw) ? raw : "$(prefix).$(raw)")
    end
    for (sub_name, sub) in model.subsystems
        # Only Model subsystems contribute explicit-derivative LHS names.
        sub isa Model || continue
        _collect_explicit_derivative_lhs!(acc, sub, "$(prefix).$(sub_name)")
    end
end

function _collect_reaction_species!(acc::Set{String}, rsys::ReactionSystem, prefix::String)
    for rxn in rsys.reactions
        # Collection-only use of the shared signed-stoichiometry iteration —
        # the sign is irrelevant here, only the species names.
        for (species, _) in each_stoich_term(rxn)
            push!(acc, "$(prefix).$(species)")
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

# The `_var` placeholder: an operator_compose template equation whose LHS
# dependent variable is `_var` (or a namespaced `<prefix>._var` after
# collection) does not name a concrete state — it is expanded once per state
# variable of the other coupled systems.
const PLACEHOLDER_VAR = "_var"

# True iff `name` is the bare `_var` placeholder or any namespaced
# `<prefix>._var` form of it.
is_placeholder(name::AbstractString)::Bool =
    name == PLACEHOLDER_VAR || endswith(name, "." * PLACEHOLDER_VAR)

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
        if dep !== nothing && is_placeholder(dep)
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
        # Apply translation to land on a canonical name. A non-String
        # `translate` value (malformed payload — the connector/translate dicts
        # are deliberately untyped at coercion time) is SILENTLY ignored and
        # the equation keeps its own dependent variable. Pinned behavior for
        # now; Wave 3 should surface the discard (e.g. via
        # `metadata.opaque_coupling_refs`, like `_apply_couple!` does for an
        # unparsed connector equation).
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
        terms = ASTExpr[equations[i].rhs for i in indices]
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

function _substitute_placeholder(expr::ASTExpr,
                                 placeholder::Union{String, Nothing},
                                 target::String)::ASTExpr
    placeholder === nothing && return expr
    if expr isa NumExpr || expr isa IntExpr
        return expr
    elseif expr isa VarExpr
        if is_placeholder(expr.name) || expr.name == placeholder
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
flattened equation list. Connector equations come in two shapes:

  * a plain `{lhs, rhs}` equation (a raw `Equation`, or a dict whose `lhs`/`rhs`
    are already-parsed `ASTExpr`s) — appended verbatim; and

  * a `{from, to, transform, expression}` connector-transform equation
    (esm-spec §10.3), where `transform` selects how `expression` modifies the
    `to` variable's flattened ODE — see [`_apply_connector_transform!`](@ref).

A dict-shaped connector equation that is neither (no `transform`, and no parsed
`ASTExpr` `lhs`/`rhs`) is NOT silently degraded into a bogus placeholder
equation; it is recorded in `opaque_refs` (the `metadata.opaque_coupling_refs`
channel used for the other couplings the flattener cannot lower) so callers can
see the entry was skipped. The spec taxonomy (§4.7.6, 8 error types for
cross-language parity) has no matching typed error, and adding a ninth is
forbidden — the opaque-refs channel is the designated fallback.
"""
function _apply_couple!(equations::Vector{Equation},
                        entry::CouplingCouple,
                        opaque_refs::Vector{String})
    raw = get(entry.connector, "equations", nothing)
    raw isa AbstractVector || return
    for item in raw
        if item isa Equation
            push!(equations, item)
            continue
        end
        item isa AbstractDict || continue
        # A `{from, to, transform, expression}` connector-transform equation
        # (esm-spec §10.3) is discriminated by its `transform` key, which the
        # plain `{lhs, rhs}` form never carries.
        if _has_field(item, :transform)
            _apply_connector_transform!(equations, item, entry, opaque_refs)
            continue
        end
        lhs = get(item, "lhs", nothing)
        rhs = get(item, "rhs", nothing)
        if lhs isa ASTExpr && rhs isa ASTExpr
            push!(equations, Equation(lhs, rhs; _comment="couple"))
        else
            push!(opaque_refs, string(
                "couple:unparsed_connector_equation:",
                join(entry.systems, "<->")))
        end
    end
    return
end

"""
    _apply_connector_transform!(equations, item, entry, opaque_refs)

Apply one `{from, to, transform, expression}` connector-transform equation
(esm-spec §10.3). The `transform` string selects how `expression` (parsed to an
`ASTExpr`) modifies the `to` variable's flattened ODE:

  * `additive`       — add `expression` as a source/sink term to `to`'s
                       tendency: `D(to) ~ <existing rhs> + expression`. The term
                       is folded onto the existing `D(to)` equation exactly as
                       [`_apply_operator_compose!`](@ref) sums equations that
                       share a dependent variable. If `to` has no tendency yet,
                       `expression` becomes it.
  * `multiplicative` — multiply `to`'s existing tendency by `expression`:
                       `D(to) ~ (<existing rhs>) * expression`.
  * `replacement`    — NOT IMPLEMENTED. "Replace the variable value entirely"
                       (§10.3) is ambiguous between replacing the tendency and
                       turning `to` into an algebraic variable; rather than
                       guess, this raises a clear error.

`expression` may already be an `ASTExpr` (in-memory construction) or raw JSON
(the usual load path), in which case it is parsed. A malformed item (missing
`to`/`expression`, or a non-string `transform`) is recorded on `opaque_refs`
rather than misapplied — the same fallback the plain-equation arm uses.
"""
function _apply_connector_transform!(equations::Vector{Equation},
                                     item::AbstractDict,
                                     entry::CouplingCouple,
                                     opaque_refs::Vector{String})
    transform_raw = _get_field(item, :transform, nothing)
    to_raw = _get_field(item, :to, nothing)
    expr_raw = _get_field(item, :expression, nothing)

    if !(transform_raw isa AbstractString) || to_raw === nothing || expr_raw === nothing
        push!(opaque_refs, string(
            "couple:unparsed_connector_equation:",
            join(entry.systems, "<->")))
        return
    end
    transform = String(transform_raw)
    to = String(to_raw)
    expression = expr_raw isa ASTExpr ? expr_raw : parse_expression(expr_raw)

    if transform == "additive"
        _combine_tendency_term!(equations, to, expression, "+")
    elseif transform == "multiplicative"
        _combine_tendency_term!(equations, to, expression, "*")
    elseif transform == "replacement"
        throw(ArgumentError(
            "couple connector transform 'replacement' (esm-spec §10.3) is not " *
            "implemented: its \"replace the variable value entirely\" semantics is " *
            "ambiguous between replacing '$(to)'s tendency and making it algebraic. " *
            "Use 'additive'/'multiplicative', or an explicit {lhs, rhs} connector " *
            "equation."))
    else
        throw(ArgumentError(
            "invalid couple connector transform '$(transform)': must be one of " *
            "additive, multiplicative, replacement (esm-spec §10.3)."))
    end
    return
end

# Fold `expression` into the `to` state's tendency in place: rewrite the RHS of
# the existing `D(to) ~ …` equation to `combine(<existing rhs>, expression)`
# (`combine == "+"` for additive, `"*"` for multiplicative). This mirrors the
# shared-dependent-variable RHS merge in `_apply_operator_compose!`. When no
# `D(to)` equation exists yet:
#   * additive       — `expression` becomes the whole tendency (`D(to) ~ expression`);
#   * multiplicative — there is no existing tendency to scale, which is an error.
function _combine_tendency_term!(equations::Vector{Equation},
                                 to::String, expression::ASTExpr, combine::String)
    idx = findfirst(eq -> differential_lhs_variable(eq.lhs) == to, equations)
    if idx === nothing
        if combine == "*"
            throw(ArgumentError(
                "couple connector 'multiplicative' transform targets '$(to)', which " *
                "has no tendency (`D($(to))`) to multiply (esm-spec §10.3)."))
        end
        push!(equations, Equation(
            OpExpr("D", ASTExpr[VarExpr(to)], wrt="t"), expression;
            _comment="couple:additive"))
        return
    end
    existing = equations[idx]
    new_rhs = OpExpr(combine, ASTExpr[existing.rhs, expression])
    equations[idx] = Equation(existing.lhs, new_rhs; _comment=existing._comment)
    return
end

"""
Apply a `CouplingVariableMap` entry: substitute the `to` parameter/variable
with the `from` variable in every flattened equation. For `param_to_var` and
`conversion_factor`, also promote `to` out of the parameters map.

When `transform` is an `ASTExpr` (esm-spec §10.4 expression transform), the target
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
                              entry::CouplingVariableMap;
                              loader_names::Set{String}=Set{String}(),
                              observeds::Union{OrderedDict{String, ModelVariable},Nothing}=nothing)
    if entry.transform isa ASTExpr
        _apply_expression_transform!(equations, params, observeds, entry)
        return
    end
    _substitute_variable_map!(equations, entry)
    _promote_variable_map_param!(params, entry, loader_names)
    return
end

# Expression transform (esm-spec §10.4): the entry binds the target to a
# DERIVED value. Remove the `to` parameter and introduce in its place an
# observed variable — same name, units, shape, description — whose defining
# expression is the transform, evaluated in the flattened coupled system's
# scope. References to `to` in the equations are left intact: they now
# resolve to the observed, exactly as if the author had declared it. Every
# variable reference inside the transform is (by contract) a fully-scoped
# reference, so no namespacing is applied; the expression MUST reference
# the entry's `from` variable — it is the data-flow edge the entry declares.
function _apply_expression_transform!(equations::Vector{Equation},
                                      params::OrderedDict{String, ModelVariable},
                                      observeds::Union{OrderedDict{String, ModelVariable},Nothing},
                                      entry::CouplingVariableMap)
    from = entry.from
    to = entry.to
    transform = entry.transform::ASTExpr
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

# Substitute the `to` reference with `from` (optionally factor-scaled) in every
# flattened equation.
function _substitute_variable_map!(equations::Vector{Equation},
                                   entry::CouplingVariableMap)
    # Build replacement ASTExpr. `factor` is a scaling coefficient (schema restricts
    # it to the scaling transforms — additive / multiplicative / conversion_factor;
    # a bare param_to_var / identity may not carry one). Apply it uniformly here
    # so all three bindings agree — Julia/Rust previously scaled only for
    # `conversion_factor`, silently dropping it for additive/multiplicative while
    # Python applied it. A factor of 1.0 is a no-op and left unwrapped.
    replacement::ASTExpr = VarExpr(entry.from)
    if entry.factor !== nothing && entry.factor != 1.0
        replacement = OpExpr("*",
            ASTExpr[NumExpr(entry.factor::Float64), VarExpr(entry.from)])
    end

    bindings = Dict{String, ASTExpr}(entry.to => replacement)
    for (i, eq) in enumerate(equations)
        equations[i] = Equation(
            substitute(eq.lhs, bindings),
            substitute(eq.rhs, bindings);
            _comment=eq._comment,
        )
    end
    return
end

# For param_to_var / conversion_factor, remove the target param from the
# parameter list (it is now driven by `from`), carrying its grid shape onto a
# loader-qualified producer when applicable.
function _promote_variable_map_param!(params::OrderedDict{String, ModelVariable},
                                      entry::CouplingVariableMap,
                                      loader_names::Set{String})
    (entry.transform == "param_to_var" || entry.transform == "conversion_factor") ||
        return
    haskey(params, entry.to) || return
    to_var = params[entry.to]
    delete!(params, entry.to)
    # Carry a grid shape from the (deleted) consumer parameter onto the
    # loader-qualified producer name, so the pointwise lift indexes the
    # loaded field per cell. Only when `from` is a data-loader variable
    # (guards against binding a model STATE, which already lives in `states`).
    if to_var.shape !== nothing && !isempty(to_var.shape) && !haskey(params, entry.from)
        from_owner = first(split(entry.from, "."; limit=2))
        if from_owner in loader_names
            params[entry.from] = ModelVariable(ParameterVariable;
                shape=to_var.shape, units=to_var.units,
                description=to_var.description)
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
    transform_str = entry.transform isa ASTExpr ?
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
