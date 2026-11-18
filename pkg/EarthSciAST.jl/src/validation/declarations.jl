# Declarations: system kind, reserved names, array defaults, variable_map units.

"""
    _check_system_kind!(errors, model, path)

esm-spec §6.3.1: a binding uses the `system_kind` DERIVATION when the field is
absent, and reports `system_kind_mismatch` when a present field contradicts it.
Recurses into subsystems.
"""
function _check_system_kind!(errors::Vector{StructuralError}, model::Model, path::String)
    declared = declared_system_kind(model)
    derived = system_kind(model)
    if declared !== nothing && declared != derived
        _report!(
            errors, ERROR_CODES.SYSTEM_KIND_MISMATCH,
            "$path/system_kind",
            "Model declares system_kind '$declared' but its equations and " *
                "parameters derive '$derived'",
            Dict{String, Any}("declared" => declared, "derived" => derived)
        )
    end
    for (subsys_name, subsys) in model_subsystems(model)
        _check_system_kind!(errors, subsys, "$path/subsystems/$subsys_name")
    end
    return errors
end

"""
    _reserved_declaration_names(indep::AbstractString) -> Dict{String,String}

Every name a declaration map may NOT spell, mapped to the reason it is reserved
(esm-spec §4.9.1.1).

Two symbols, both GLOBALLY scoped: the document's independent variable and the
§6.4 operator placeholder. §4.9.1.1 is the normative home of this set; the
sibling `reserved_index_symbol` rule for a `faq` binder reads the same
set, so the two cannot drift apart. (That sibling rule is currently implemented
only in the Rust binding; this one is implemented in all five.)

Spatial coordinate names are deliberately absent: they resolve as coordinates
only in a coordinate position (§11.4), and
`tests/valid/units_dimensional_analysis.esm` declares `x` as an ordinary
position variable.
"""
_reserved_declaration_names(indep::AbstractString)::Dict{String, String} = Dict{String, String}(
    String(indep) => "independent_variable",
    _OPERATOR_PLACEHOLDER_VAR => "operator_placeholder"
)

"""
    _check_reserved_declaration_names!(errors, names, container_path, owner, kind; indep)

`reserved_variable_name` for every declared `name` spelled with a globally-scoped
name (esm-spec §4.9.1.1).

The declaration never wins: the independent variable and `_var` are implicitly
declared in every component's expression scope (§4.9.1) and are resolved BY NAME
ahead of the declaration maps, so the implicit symbol shadows the declaration
rather than the other way round, which is why this is a hard error and not a
lint: every reader of the name would get the implicit symbol.

`names` is walked in sorted order: `Model.variables` is ordered but a reaction
system's species and parameters are vectors, and sorted is the ordering every
binding can produce.
"""
function _check_reserved_declaration_names!(
        errors::Vector{StructuralError},
        names, container_path::AbstractString,
        owner::AbstractString, kind::AbstractString;
        indep::AbstractString = "t"
    )
    reserved = _reserved_declaration_names(indep)
    for name in sort!(collect(String.(names)))
        why = get(reserved, name, nothing)
        why === nothing && continue
        role = why == "independent_variable" ? "the document's independent variable" :
            "the operator-model placeholder"
        _report!(
            errors, ERROR_CODES.RESERVED_VARIABLE_NAME,
            "$container_path/$name",
            "$owner declares a $kind named '$name', which is $role",
            Dict{String, Any}("name" => name, "reserved_as" => why)
        )
    end
    return errors
end

"""
    _check_reserved_file_names!(errors, file)

[`_check_reserved_declaration_names!`](@ref) over all three declaration maps of
`file` — every model's `variables` (subsystems included) and every reaction
system's `species` and `parameters` — in sorted order. Shared by `validate` and
by the build, which refuses the same declarations (see `esm_problem`).
"""
function _check_reserved_file_names!(errors::Vector{StructuralError}, file::EsmFile)
    indep = _indep_var(file)
    if file.models !== nothing
        for model_name in sort!(collect(keys(file.models)))
            _check_reserved_model_names!(
                errors, file.models[model_name],
                "/models/$model_name",
                "Model '$model_name'"; indep = indep
            )
        end
    end
    if file.reaction_systems !== nothing
        for rs_name in sort!(collect(keys(file.reaction_systems)))
            rs = file.reaction_systems[rs_name]
            owner = "Reaction system '$rs_name'"
            _check_reserved_declaration_names!(
                errors, (s.name for s in rs.species),
                "/reaction_systems/$rs_name/species",
                owner, "species"; indep = indep
            )
            _check_reserved_declaration_names!(
                errors, (p.name for p in rs.parameters),
                "/reaction_systems/$rs_name/parameters",
                owner, "parameter"; indep = indep
            )
        end
    end
    return errors
end

"""
    _check_reserved_model_names!(errors, model, path; indep)

[`_check_reserved_declaration_names!`](@ref) over a model's `variables`,
recursing into subsystems.
"""
function _check_reserved_model_names!(
        errors::Vector{StructuralError}, model::Model,
        path::String, owner::AbstractString;
        indep::AbstractString = "t"
    )
    _check_reserved_declaration_names!(
        errors, keys(model.variables), "$path/variables",
        owner, "variable"; indep = indep
    )
    for (subsys_name, subsys) in model_subsystems(model)
        _check_reserved_model_names!(
            errors, subsys, "$path/subsystems/$subsys_name",
            "Model '$subsys_name'"; indep = indep
        )
    end
    return errors
end

"""
    _check_array_defaults_have_shape!(errors, model, path, owner)

`array_default_without_shape` for every variable of `model`, and of its
subsystems, whose `default` is inline ARRAY data but which declares no `shape`
(omitted or empty) — esm-spec §6.3. Inline array data is a shaped variable's
value: its nesting is matched against the declared shape, so with no shape there
is nothing for it to fill. Variables are walked in sorted order, as every binding
can produce.
"""
function _check_array_defaults_have_shape!(
        errors::Vector{StructuralError}, model::Model,
        path::String, owner::AbstractString
    )
    for name in sort!(collect(keys(model.variables)))
        var = model.variables[name]
        is_inline_array(var.default) || continue
        (var.shape === nothing || isempty(var.shape)) || continue
        _report!(
            errors, ERROR_CODES.ARRAY_DEFAULT_WITHOUT_SHAPE,
            "$path/variables/$name/default",
            "$owner variable '$name' has inline array data as its default but declares " *
                "no shape; inline array data is a shaped variable's value (esm-spec §6.3)",
            Dict{String, Any}(
                "variable" => name,
                "variable_type" => _variable_type_word(var.type)
            )
        )
    end
    for (subsys_name, subsys) in sort!(collect(model_subsystems(model)); by = first)
        _check_array_defaults_have_shape!(
            errors, subsys, "$path/subsystems/$subsys_name",
            "Model '$subsys_name'"
        )
    end
    return errors
end

"""
    _operator_composed_systems(file::EsmFile) -> Set{String}

Every system named in an `operator_compose` coupling entry. Their equations are
operator contributions to a shared state, so the excess-equation direction of
[`validate_model_balance`](@ref) does not apply to them.
"""
function _operator_composed_systems(file::EsmFile)::Set{String}
    names = Set{String}()
    for entry in file.coupling
        entry isa CouplingOperatorCompose || continue
        union!(names, entry.systems)
    end
    return names
end

"""
    validate_variable_map_units(file::EsmFile) -> Vector{StructuralError}

The flatten-time [`_check_variable_map_units`](@ref) rule as a `validate()`
structural check (esm-spec §4.7.6); both read `_variable_map_unit_conflict`
(coupling_apply.jl). A `variable_map`
coupling entry with `transform == "identity"` whose `from` and `to` variables
carry DECLARED units that are both present, non-empty, and DIFFERENT is a
domain-unit mismatch — the identity map asserts the two variables are the same
quantity, and `K` is not `degC`. Matching or absent units are legal; the
`param_to_var` and `conversion_factor` transforms are exempt (they are never
`== "identity"`), and an expression transform is an `ASTExpr`, not the string.

Reported as `domain_unit_mismatch` at the coupling ENTRY pointer `/coupling/i`
(the corpus pin), not at `/coupling/i/from` — the defect is the pairing, carried
by the whole entry.
"""
function validate_variable_map_units(file::EsmFile)::Vector{StructuralError}
    errors = StructuralError[]
    for (i, entry) in enumerate(file.coupling)
        conflict = _variable_map_unit_conflict(file, entry)
        conflict === nothing && continue
        src_units, tgt_units = conflict
        _report!(
            errors, ERROR_CODES.DOMAIN_UNIT_MISMATCH,
            "/coupling/$(i - 1)",
            "variable_map identity coupling from '$(entry.from)' ($src_units) to " *
                "'$(entry.to)' ($tgt_units) connects variables with different declared units",
            Dict{String, Any}(
                "from" => entry.from, "to" => entry.to,
                "from_units" => src_units, "to_units" => tgt_units
            )
        )
    end
    return errors
end
