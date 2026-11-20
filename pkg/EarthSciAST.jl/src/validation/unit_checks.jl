# The unit checks validate runs: reference-preserving views, rates, declarations, heuristics.

# The model a validation pass's checks read: the model itself, with every
# surviving `apply_expression_template` reference CARRYING the names its body
# reads from the caller as bindings (`_tpl_augment_component!`,
# templates/frames.jl), so a check that asks which names an expression reads
# sees through a reference without entering its body. No reference is
# expanded: the units engine reads a reference through its frame
# (`_tpl_call_unit!`), and the recurrence checks read its body through its
# frame (`_tpl_step`). The augmentation is made on a copy (`_expansion_copy`
# copies only the containers it rewrites); the loaded model is not changed.
# `tt` is the model's template table when the caller has one.
function _units_view(
        file::EsmFile, model_name::AbstractString, model::Model;
        tt = nothing
    )
    file.component_templates === nothing && return model
    reg = get(file.component_templates, "models.$model_name", nothing)
    reg === nothing && return model
    return _tpl_augment_component!(_expansion_copy(model), reg, tt)
end
# The same, read from `views` — a validation pass's `_UnitsInputs.models`,
# which holds each top-level model's view — when the caller built them.
_units_view(file::EsmFile, model_name::AbstractString, model::Model, ::Nothing) =
    _units_view(file, model_name, model)
_units_view(::EsmFile, model_name::AbstractString, ::Model, views::AbstractDict) =
    views[model_name]

"""
    validate_model_unit_consistency(model::Model, path::String; file=nothing, toplevel=nothing, indep="t") -> Vector{StructuralError}

Every unit error of `model` and its model subsystems, at its JSON pointer under
`path`: [`model_unit_findings`](@ref) for each component, the subsystems at
`path/subsystems/<name>`. `file`, the document holding `model`, lets a scoped
reference into a top-level component be typed from its target's declaration
(esm-spec §4.8.4); `toplevel` is that document-wide map already built.
"""
function validate_model_unit_consistency(
        model::Model, path::String; file = nothing, toplevel = nothing,
        indep::AbstractString = "t"
    )::Vector{StructuralError}
    toplevel === nothing && (toplevel = _toplevel_scoped_units(file))
    errors = StructuralError[]
    _foreach_component(model, path; sorted = true) do c, p, _
        for f in model_unit_findings(c; toplevel, indep)
            _report!(
                errors, f.code,
                "$p/$(f.subpath)",
                f.message
            )
        end
    end
    return errors
end

"""
    _unit_check!(units::_UnitsInputs) -> (; errors, warnings)

The units checker of a `validate` pass, run once and kept on `units`: every
component's unit findings (`_component_unit_findings!`), each top-level model
and reaction system and its inline subsystems at any depth, each template
reference read through its frame against the component's registry
(`_tpl_units_env`). `errors` are the structural errors;
`warnings` the esm-spec §4.8.6 `(pointer, message)` pairs.
"""
function _unit_check!(units::_UnitsInputs)
    cached = units.checked[]
    cached === nothing || return cached
    errors = StructuralError[]
    warnings = Tuple{String, String}[]
    errs = UnitFinding[]
    warns = UnitFinding[]
    tt = Ref{Any}(nothing)
    visit = function (c, p, _)
        empty!(errs)
        empty!(warns)
        env = _tpl_units_env(_component_unit_env(c, units.toplevel; indep = units.indep), tt[])
        _component_unit_findings!(errs, warns, c, p, env)
        for f in errs
            _report!(
                errors, f.code,
                "$p/$(f.subpath)",
                f.message
            )
        end
        for f in warns
            push!(warnings, ("$p/$(f.subpath)", f.message))
        end
        return
    end
    for name in sort!(collect(keys(units.models)))
        tt[] = _tpl_component_table(units.file, "models", name, units.tables)
        _foreach_component(visit, units.models[name], _pointer("", "models", name); sorted = true)
    end
    for name in sort!(collect(keys(units.reaction_systems)))
        tt[] = _tpl_component_table(units.file, "reaction_systems", name, units.tables)
        _foreach_component(
            visit, units.reaction_systems[name], _pointer("", "reaction_systems", name);
            sorted = true
        )
    end
    result = (; errors, warnings)
    units.checked[] = result
    return result
end

"""
    validate_reaction_rate_units(rs::ReactionSystem, path::String; file=nothing, toplevel=nothing) -> Vector{StructuralError}

Enforce the mass-action dimensional constraint from spec §7.4: for each reaction,
rate * prod(substrate^stoichiometry) must have dimensions of species/time. The
reference concentration unit is taken from the first substrate (matching TS/Python).

The check is skipped when the reference concentration unit is dimensionless
(mol/mol, ppm, …) because atmospheric-chemistry rate expressions commonly bake
a number-density factor into rate constants.

A scoped rate or substrate (`Sub.k`, `Other.A`) has the units its target
declares, with the precedence [`model_unit_findings`](@ref) uses: the system's
own names, then paths relative to its own subsystems, then the top-level
components of `file` (or the prebuilt `toplevel` map). Covers the system's
subsystems at any depth.
"""
function validate_reaction_rate_units(
        rs::ReactionSystem, path::String;
        file = nothing,
        toplevel = nothing
    )::Vector{StructuralError}
    errors = StructuralError[]
    toplevel === nothing && (toplevel = _toplevel_scoped_units(file))
    _foreach_component(rs, path) do r, p, _
        _check_reaction_rate_units!(errors, r, p, toplevel)
    end
    return errors
end

# The §7.4 mass-action rate-unit rule over one reaction system's own reactions.
function _check_reaction_rate_units!(errors, rs::ReactionSystem, path::String, toplevel)
    scoped = _UnitEnv(Dict{String, String}(), _relative_scoped_units(rs), toplevel)

    # Build name → unit-string map using ONLY explicitly declared units.
    # Mirrors Python's conservative scope: skip when any relevant unit is
    # absent, so we do not surface false positives on partially-annotated
    # fixtures (e.g. tests that omit units to exercise other rules).
    species_units = Dict{String, String}()
    for species in rs.species
        species.units !== nothing && (species_units[species.name] = species.units)
    end
    param_units = Dict{String, String}()
    for param in rs.parameters
        param.units !== nothing && (param_units[param.name] = param.units)
    end

    time_unit = parse_units("s")

    for (i, reaction) in enumerate(rs.reactions)
        # Only check bare-variable rate references whose symbol has declared
        # units. Compound rate expressions are skipped because atmospheric-
        # chemistry rate constants routinely carry implicit units on numeric
        # literals, which defeats literal dimensional analysis.
        isa(reaction.rate, VarExpr) || continue
        rate_name = reaction.rate.name
        rate_units_str = get(
            param_units, rate_name,
            get(species_units, rate_name, get(scoped, rate_name, nothing))
        )
        rate_units_str === nothing && continue
        rate_dim = parse_units(rate_units_str)
        rate_dim === nothing && continue

        substrates_field = raw_substrates(reaction)
        (substrates_field === nothing || isempty(substrates_field)) && continue

        # Require every referenced substrate to have declared units.
        # Fractional stoichiometries on substrates produce non-integer unit
        # exponents, which Unitful does not support for dimensional analysis —
        # skip the dimensional check in that case (fractional substrates are
        # unusual; fractional *products* are the common atmospheric-chemistry
        # case and don't enter this path).
        resolvable = true
        substrate_dim = Unitful.NoUnits
        species_dim = nothing
        total_order = 0.0
        fractional_substrate = false
        for substrate in substrates_field
            sp_units_str = get(
                species_units, substrate.species,
                get(scoped, substrate.species, nothing)
            )
            if sp_units_str === nothing
                resolvable = false
                break
            end
            sp_dim = parse_units(sp_units_str)
            if sp_dim === nothing
                resolvable = false
                break
            end
            species_dim === nothing && (species_dim = sp_dim)
            if !isinteger(substrate.stoichiometry)
                fractional_substrate = true
                break
            end
            substrate_dim = substrate_dim * (sp_dim^Int(substrate.stoichiometry))
            total_order += substrate.stoichiometry
        end
        fractional_substrate && continue
        (!resolvable || species_dim === nothing) && continue

        # Skip when the reference concentration unit is dimensionless
        # (mol/mol, ppm, …) — mass-action convention is ambiguous there.
        dimension(species_dim) == dimension(Unitful.NoUnits) && continue

        expected_dim = species_dim / time_unit
        full_dim = rate_dim * substrate_dim
        if dimension(full_dim) != dimension(expected_dim)
            first_sp = substrates_field[1].species
            first_sp_units = get(species_units, first_sp, get(scoped, first_sp, ""))
            order_str = isinteger(total_order) ? string(Int(total_order)) : string(total_order)
            _report!(
                errors, ERROR_CODES.UNIT_INCONSISTENCY,
                _pointer(path, "reactions", i),
                "Reaction $(reaction.id) rate '$rate_name' units '$rate_units_str' " *
                    "incompatible with order-$order_str reaction for species units " *
                    "'$first_sp_units' (expected rate*substrates to have dimensions of species/time)"
            )
        end
    end
    return errors
end

# `grad` / `div` / `laplacian` have no dimensional rule (esm-spec §4.2, §4.8.3,
# §4.8.4): they are open-tier rewrite-target ops, so the units engine reports
# their dimension as undeterminable and skips the enclosing check. Pinned by
# `tests/invalid/units_gradient_operator_mismatch.esm`, whose one finding is
# the `m + kg` addition.

"""
Well-known physical constants whose declared units can be dimensionally
verified against a canonical form. Conservative on purpose — names chosen
to minimize collision with common non-constant uses (e.g., no `c` for
speed of light, which conflicts with concentration). Mirrors Python's
`units.KNOWN_PHYSICAL_CONSTANTS`.

Each tuple is (name, canonical_units, description).
"""
const _KNOWN_PHYSICAL_CONSTANTS = (
    ("R", "J/(mol*K)", "ideal gas constant"),
    ("k_B", "J/K", "Boltzmann constant"),
    ("N_A", "1/mol", "Avogadro constant"),
)

# Returns true when the expression tree references a variable by exact name
# (VarExpr leaf match). Routed through the shared generated walker
# (`foreach_subexpr`), so the scan covers every child field of a node, not
# just `args`.
function _expr_references_name(expr, name::String)::Bool
    expr isa ASTExpr || return false
    found = false
    foreach_subexpr(expr) do x
        found || (x isa VarExpr && x.name == name && (found = true))
        nothing
    end
    return found
end

"""
    validate_physical_constant_units(model::Model, path::String) -> Vector{StructuralError}

Flag parameters whose name matches a well-known physical constant but whose
declared units are dimensionally incompatible with the canonical form (e.g.,
`R` declared as `kcal/mol` — missing temperature — instead of `J/(mol*K)`).
Reports at the first observed-variable usage site in the same model;
otherwise at the declaration. Mirrors Python's
`units.UnitValidator._check_physical_constants`. Covers the model's
subsystems at any depth.
"""
function validate_physical_constant_units(model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]
    _foreach_component((m, p, _) -> _check_physical_constant_units!(errors, m, p), model, path)
    return errors
end

function _check_physical_constant_units!(errors, model::Model, path::String)
    for (constant_name, canonical, description) in _KNOWN_PHYSICAL_CONSTANTS
        haskey(model.variables, constant_name) || continue
        var = model.variables[constant_name]
        var.type == ParameterVariable || continue
        declared_str = var.units
        (declared_str === nothing || isempty(declared_str)) && continue

        declared_unit = parse_units(String(declared_str))
        canonical_unit = parse_units(canonical)
        (declared_unit === nothing || canonical_unit === nothing) && continue
        dimension(declared_unit) == dimension(canonical_unit) && continue

        usage_name = nothing
        for other_name in observed_unknowns(model)
            defn = observed_definition(model, other_name)
            defn === nothing && continue
            if _expr_references_name(defn, constant_name)
                usage_name = other_name
                break
            end
        end
        target = usage_name === nothing ? constant_name : usage_name

        _report!(
            errors, ERROR_CODES.UNIT_INCONSISTENCY,
            _pointer(path, "variables", target),
            "Physical constant used with incorrect dimensional analysis " *
                "(constant '$constant_name' ($description) declared with units '$declared_str', " *
                "expected dimensions compatible with '$canonical')"
        )
    end
    return errors
end

# Compute the linear conversion factor from `from_units` to `to_units`, or
# `nothing` when the conversion is affine (e.g., degC → K) or the units can't
# be parsed/converted. A conversion is linear iff 0 `from_units` converts to
# 0 `to_units` (within tolerance).
function _linear_conversion_factor(from_units::String, to_units::String)::Union{Float64, Nothing}
    from_unit = parse_units(from_units)
    to_unit = parse_units(to_units)
    (from_unit === nothing || to_unit === nothing) && return nothing
    dimension(from_unit) == dimension(to_unit) || return nothing
    try
        q0 = Unitful.ustrip(Unitful.uconvert(to_unit, 0.0 * from_unit))
        q1 = Unitful.ustrip(Unitful.uconvert(to_unit, 1.0 * from_unit))
        abs(q0) > 1.0e-12 && return nothing  # affine
        # Identical exact scales imply no conversion, so the coefficient is free;
        # otherwise the expected factor is formed EXACTLY and rounded once, so the
        # caller's tolerance only absorbs the literal's spelling (esm-spec §4.8.1).
        from_exact, to_exact = _exact_scale(from_unit), _exact_scale(to_unit)
        from_exact == to_exact && return nothing
        return Float64(from_exact / to_exact)
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
end

"""
    validate_conversion_factor_consistency(model::Model, path::String) -> Vector{StructuralError}

Flag observed variables whose defining expression is `<numeric> * <var>`
(or `<var> * <numeric>`) where the declared units and the source variable's
units are dimensionally compatible but the numeric literal disagrees with the
correct linear conversion factor. Only linear (non-affine) conversions are
checked. Mirrors Python's `units.UnitValidator._check_conversion_factor`.
Covers the model's subsystems at any depth.
"""
function validate_conversion_factor_consistency(model::Model, path::String)::Vector{StructuralError}
    errors = StructuralError[]
    _foreach_component((m, p, _) -> _check_conversion_factors!(errors, m, p), model, path)
    return errors
end

function _check_conversion_factors!(errors, model::Model, path::String)
    for (vname, expr) in observed_definitions(model)
        var = model.variables[vname]
        lhs_units = var.units
        (lhs_units === nothing || isempty(lhs_units)) && continue
        expr isa OpExpr || continue
        expr.op == "*" || continue
        length(expr.args) == 2 || continue

        numeric = nothing
        var_ref = nothing
        for a in expr.args
            if a isa NumExpr
                numeric = Float64(a.value)
            elseif a isa IntExpr
                numeric = Float64(a.value)
            elseif a isa VarExpr
                var_ref = a.name
            end
        end
        (numeric === nothing || var_ref === nothing) && continue

        src_var = get(model.variables, var_ref, nothing)
        src_var === nothing && continue
        src_units = src_var.units
        (src_units === nothing || isempty(src_units)) && continue

        # Skip identical unit strings — no conversion to check.
        src_units == lhs_units && continue

        factor = _linear_conversion_factor(String(src_units), String(lhs_units))
        (factor === nothing || factor == 0) && continue
        abs(numeric - factor) <= 1.0e-9 * max(abs(factor), 1.0) && continue

        _report!(
            errors, ERROR_CODES.UNIT_INCONSISTENCY,
            _pointer(path, "variables", vname),
            "Unit conversion factor is incorrect for specified unit transformation " *
                "(variable '$vname', declared_units='$lhs_units', source_units='$src_units', " *
                "declared_factor=$numeric, expected_factor=$factor)"
        )
    end
    return errors
end
