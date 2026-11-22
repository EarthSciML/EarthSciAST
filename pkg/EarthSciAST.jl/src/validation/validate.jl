# The structural pass and the validation entry points.

"""
    validate_structural(file::EsmFile) -> Vector{StructuralError}

Validate structural consistency of ESM file according to spec Section 3.2.
Checks equation-unknown balance, reference integrity, reaction consistency,
and event consistency.

Error paths use 0-based JSON-Pointer slash style (e.g.
`/models/M/equations/0`), matching the shared cross-language fixtures in
`tests/invalid/expected_errors.json` and the TS/Python bindings.
"""
validate_structural(file::EsmFile)::Vector{StructuralError} =
    _validate_structural(file, _ValidationContext(file))

# What the checks of one validation pass share, built once: the independent
# variable; the systems a coupling entry names (`coupled`) or composes
# (`composed`); the document-wide declared names, coordinate names and
# callback-injected names reference integrity scopes with; every declaration by
# scoped name (`index`) and the document-wide scoped-reference units read off
# it (esm-spec §4.8.4); each top-level model's view (`_units_view`: its
# references kept, each carrying the names its body reads) and each top-level
# reaction system; and the units checker's result once it has run
# (`_unit_check!`).
struct _ValidationContext
    file::EsmFile
    indep::String
    coupled::Set{String}
    composed::Set{String}
    declared::Set{String}
    coordinates::Set{String}
    injected::Set{String}
    index::_ScopedIndex
    toplevel::Dict{String, Union{String, Nothing}}
    models::Dict{String, Model}
    reaction_systems::Dict{String, ReactionSystem}
    # `<kind>.<name>` => the top-level component's template table (absent when
    # it has no surviving reference), one per pass: every check reads the
    # component's references through it, so a body is prepared and an
    # instance's frame built once per pass, not once per check.
    tables::Dict{String, Any}
    checked::Base.RefValue{Any}
end

const _UnitsInputs = _ValidationContext

function _ValidationContext(file::EsmFile)
    tables = Dict{String, Any}()
    models = Dict{String, Model}()
    if file.models !== nothing
        for (name, model) in file.models
            tt = _tpl_component_table(file, "models", name)
            tt === nothing || (tables["models.$name"] = tt)
            models[name] = _units_view(file, name, model; tt)
        end
    end
    rss = file.reaction_systems === nothing ? Dict{String, ReactionSystem}() :
        Dict{String, ReactionSystem}(file.reaction_systems)
    for name in keys(rss)
        tt = _tpl_component_table(file, "reaction_systems", name)
        tt === nothing || (tables["reaction_systems.$name"] = tt)
    end
    index = _scoped_index(file)
    return _ValidationContext(
        file, _indep_var(file), _coupled_system_names(file),
        _operator_composed_systems(file), _document_declared_names(file),
        _coordinate_names(file), _callback_injected_names(file),
        index, _scoped_units(index), models, rss, tables, Ref{Any}(nothing)
    )
end

# The top-level models in name order.
_sorted_models(file::EsmFile) =
    file.models === nothing ? Pair{String, Model}[] :
    [n => file.models[n] for n in sort!(collect(keys(file.models)))]

# ── The structural checks, each `check!(errors, ctx)` ───────────────────────

# Equation-unknown balance. A COUPLED model is skipped: its states may be
# supplied from outside, by a `variable_map` or by the system it is composed
# onto.
function _check_balance!(errors, ctx)
    for (name, model) in _sorted_models(ctx.file)
        name ∈ ctx.coupled && continue
        append!(
            errors, validate_model_balance(
                model, _pointer("", "models", name); check_excess = name ∉ ctx.composed
            )
        )
    end
    return errors
end

_check_references!(errors, ctx) =
    append!(errors, validate_reference_integrity(ctx.file; views = ctx.models, tables = ctx.tables, names = ctx))

# An inline test's assertion targets, override keys and assertion ranks
# (esm-spec §6.6.2, §6.6.3, §6.6.5).
_check_inline_test_names!(errors, ctx) = append!(errors, _validate_inline_tests(ctx.file))

# Reaction-system consistency and the mass-action rate-unit rule (esm-spec §7.4).
function _check_reactions!(errors, ctx)
    rss = ctx.file.reaction_systems
    rss === nothing && return errors
    for name in sort!(collect(keys(rss)))
        rs = rss[name]
        append!(errors, validate_reaction_consistency(rs, _pointer("", "reaction_systems", name); indep = ctx.indep))
        append!(errors, validate_reaction_rate_units(rs, _pointer("", "reaction_systems", name); toplevel = ctx.toplevel))
    end
    return errors
end

# A data-fed parameter's `unit_conversion` expression is scoped by the
# DOCUMENT-WIDE declared names (a conversion may scale a loaded field by a
# model's parameter; `tests/invalid/undefined_variable_in_unit_conversion.esm`),
# and its `update.source` must name a declared `data_sources` entry
# (esm-spec §8.5, `data_source_undefined`).
function _check_update_bindings!(errors, ctx)
    file = ctx.file
    scope = union(ctx.declared, keys(file.index_sets))
    available = file.data_sources === nothing ? String[] :
        sort!(String[String(k) for k in keys(file.data_sources)])
    for (name, model) in _sorted_models(file)
        _check_update_unit_conversions!(errors, file, model, _pointer("", "models", name), scope)
    end
    for (name, model) in _sorted_models(file)
        _check_update_sources!(errors, model, _pointer("", "models", name), available)
    end
    return errors
end

# Record axes and data-fed record shapes (esm-spec §8.5.1).
_check_records!(errors, ctx) =
    (_check_record_axes!(errors, ctx.file); _check_record_shapes!(errors, ctx.file, ctx.index))

# Declarations: a present `system_kind` agrees with the derivation (esm-spec
# §6.3.1); no declaration spells the independent variable or `_var`
# (§4.9.1.1); inline array data sits only on a shaped variable (§6.3).
function _check_declarations!(errors, ctx)
    for (name, model) in _sorted_models(ctx.file)
        _check_system_kind!(errors, model, _pointer("", "models", name))
    end
    _check_reserved_file_names!(errors, ctx.file)
    for (name, model) in _sorted_models(ctx.file)
        _check_array_defaults_have_shape!(errors, model, _pointer("", "models", name), "Model '$name'")
    end
    return errors
end

# What an equation's left-hand side may name (esm-spec §6.3.1): never a
# parameter, and no index symbol a faq does not bind. The metaparameters and
# the independent variable (a time subscript) are legal subscripts.
function _check_equation_lhs!(errors, ctx)
    file = ctx.file
    meta = file.metaparameters === nothing ? Set{String}() :
        Set{String}(String(k) for k in keys(file.metaparameters))
    push!(meta, ctx.indep)
    for (name, m) in _sorted_models(file)
        _foreach_component(m, _pointer("", "models", name); scope = name) do c, p, _, s
            _check_equation_lhs_names!(errors, ctx.index, c, p, s, name, meta)
        end
    end
    return errors
end

# Event consistency. Unlike balance, this runs for a coupled model too, with the
# §6.4 `_var` placeholder credited.
function _check_events!(errors, ctx)
    for (name, model) in _sorted_models(ctx.file)
        append!(
            errors, validate_event_consistency(
                model, _pointer("", "models", name); is_coupled = name ∈ ctx.coupled
            )
        )
    end
    return errors
end

# The units checker (every unit check site of every component, judged once)
# and the two unit heuristics: physical constants and conversion factors.
function _check_units!(errors, ctx)
    append!(errors, _unit_check!(ctx).errors)
    for (name, model) in _sorted_models(ctx.file)
        append!(errors, validate_physical_constant_units(model, _pointer("", "models", name)))
        append!(errors, validate_conversion_factor_consistency(model, _pointer("", "models", name)))
    end
    return errors
end

# Dependency cycles among top-level systems (§3.2) and variable bounds
# (esm-spec §6.3.2).
_check_coupling_cycles!(errors, ctx) =
    append!(errors, validate_coupling_cycles(ctx.file; toplevel = ctx.toplevel))
_check_bounds!(errors, ctx) =
    append!(errors, validate_variable_bounds(ctx.file; toplevel = ctx.toplevel, index = ctx.index))

# The faq checks (index sets, joins, relational nodes, bare array operands) and
# the broadcast checks (the `fn` contract, element-wise axis alignment,
# esm-spec §4.3.4), each at the containing expression field.
_check_faq!(errors, ctx) =
    append!(errors, validate_aggregate_semantics(ctx.file; views = ctx.models, tables = ctx.tables))
_check_broadcast!(errors, ctx) = append!(errors, validate_broadcast_semantics(ctx.file))

# Recurrence well-foundedness (esm-spec §4.3.1.1) and observed dependency
# cycles (§4.9.6). The two are independent: the self-edge exemption of the
# cycle check is gated on recurrence CANDIDACY, never on the recurrence
# verdict (CONFORMANCE_SPEC §5.19.5).
_check_recurrences!(errors, ctx) =
    append!(errors, validate_recurrence_semantics(ctx.file; views = ctx.models, tables = ctx.tables))
_check_observed_dependency_cycles!(errors, ctx) =
    append!(errors, validate_observed_cycles(ctx.file; views = ctx.models, tables = ctx.tables))

# A `variable_map` identity coupling between differently declared units
# (esm-spec §4.7.6), at `/coupling/<i>`.
_check_variable_maps!(errors, ctx) =
    append!(errors, validate_variable_map_units(ctx.file; index = ctx.index))

# A species with both an explicit derivative equation and a reaction
# contribution (§4.7.5 item E). It spans two top-level blocks, so it is
# reported at the document root, `""`.
function _check_conflicting_derivatives!(errors, ctx)
    for name in _find_conflicting_derivatives(ctx.file)
        _report!(
            errors, ERROR_CODES.CONFLICTING_DERIVATIVE, "",
            "Species '$name' has both an explicit derivative equation and a reaction contribution"
        )
    end
    return errors
end

# Every structural check `validate_structural` runs, in order.
const _STRUCTURAL_CHECKS = (
    _check_balance!, _check_references!, _check_inline_test_names!, _check_reactions!,
    _check_update_bindings!, _check_records!, _check_declarations!,
    _check_equation_lhs!, _check_events!, _check_units!, _check_coupling_cycles!,
    _check_bounds!, _check_faq!, _check_broadcast!, _check_recurrences!,
    _check_observed_dependency_cycles!, _check_variable_maps!, _check_conflicting_derivatives!,
)

function _validate_structural(file::EsmFile, ctx::_ValidationContext)::Vector{StructuralError}
    errors = StructuralError[]
    for check! in _STRUCTURAL_CHECKS
        check!(errors, ctx)
    end
    return errors
end

"""
    validate(file::EsmFile) -> ValidationResult

Complete validation combining schema, structural, and unit validation.
Returns ValidationResult with all errors and warnings.
"""
function validate(file::EsmFile)::ValidationResult
    # Schema validation requires the full serialized document: the schema's
    # top-level `anyOf` requires either `models` or `reaction_systems`, so a
    # stub dict with just `esm` and `metadata.name` would always fail.
    #
    # Raw-passthrough fields (`coupling[*].connector`, `callback.config`,
    # `translate`, `domain.temporal`, the template declarations) hold native
    # values — documents are normalized once at the wire boundary — and
    # `validate_schema` itself funnels its input through `_to_native_json`, so
    # no extra carrier scrub is needed here.
    data = serialize_esm_file(file)

    schema_errors = validate_schema(data)
    units = _ValidationContext(file)
    structural_errors = _validate_structural(file, units)
    # As in the TS binding (validate.ts): a provable unit mismatch is surfaced
    # both as a `unit_warnings` record and as a promoted `unit_inconsistency`
    # structural error.
    unit_warnings = UnitWarning[
        UnitWarning(
            e.path, ERROR_CODES.DIMENSIONAL_MISMATCH, e.message,
            string(get(e.details, "lhs_units", "")),
            string(get(e.details, "rhs_units", ""))
        )
            for e in structural_errors if e.error_type == ERROR_CODES.UNIT_INCONSISTENCY
    ]
    _push_dimensionless_literal_warnings!(unit_warnings, units)

    return ValidationResult(schema_errors, structural_errors, unit_warnings = unit_warnings)
end

# Bare numeric literals read as dimensionless (esm-spec §4.8.6): a WARNING at
# this stage, so it is never a structural error and never touches `is_valid`. A
# failure of the pass itself says nothing about the file: it is downgraded to an
# `analysis` unit warning, never an error and never a throw out of `validate`.
# `findings` is the pass, an argument so a test can make it fail.
function _push_dimensionless_literal_warnings!(
        unit_warnings::Vector{UnitWarning}, units,
        findings = _dimensionless_literal_findings
    )
    found = try
        findings(units)
    catch e
        e isa InterruptException && rethrow()
        push!(
            unit_warnings, UnitWarning(
                "", ERROR_CODES.ANALYSIS,
                "Dimensionless-literal check failed: $(sprint(showerror, e))"
            )
        )
        return unit_warnings
    end
    for (path, message) in found
        push!(unit_warnings, UnitWarning(path, UNIT_FINDING_DIMENSIONLESS_LITERAL, message))
    end
    return unit_warnings
end

"""
    validate_path(path::AbstractString) -> ValidationResult

Validate the document at `path`, INCLUDING the failures that happen while
loading it; [`validate`](@ref) itself takes a TYPED document in every binding
(API_SPEC.md §8 item 13). A load failure is a verdict, not an exception, as in
[`validate_text`](@ref), which renders it the same way. `load_path` still
throws, for callers that want the exception.
"""
validate_path(path::AbstractString)::ValidationResult =
    _validate_loaded(() -> load_path(path))

"""
    validate_text(text::AbstractString; base_path=pwd()) -> ValidationResult

Validate an ESM document held as JSON **text**, INCLUDING the failures that
happen while loading it. The text twin of [`validate_path`](@ref); the same
function exists in every binding (Go `ValidateText`, Python `validate_text`,
Rust `validate_text`, TypeScript `validateText`).

A load failure becomes a **verdict** in the returned `ValidationResult` rather
than an exception, as in Python and Go:

- a `SchemaValidationError` carries its structured `SchemaError`s straight
  through into `schema_errors`;
- an ordinary `ParseError` (no `code`) is malformed JSON: one `SchemaError` at
  the document root under the `parse` keyword;
- a load diagnostic carrying a code (an unresolvable `{ref}`, the §11.4.1
  `ic_in_reaction_system` case, a version gate) becomes a `StructuralError`
  through [`load_failure_structural_error`](@ref).

Anything else propagates.

`base_path` anchors relative §9.7.2 template imports and §4.7 `{ref}`s, since
text carries no location of its own. `load_string` does not resolve subsystem
`\$ref` MOUNTS; a document carrying those wants `validate_path`.

# Examples
```julia
result = validate_text(read("model.esm", String); base_path=dirname("model.esm"))
result.is_valid
```
"""
validate_text(text::AbstractString; base_path::AbstractString = pwd())::ValidationResult =
    _validate_loaded(() -> load_string(text; base_path = base_path))

# `validate(load())`, with a load failure rendered as the verdict
# `validate_text` documents.
function _validate_loaded(load)::ValidationResult
    file = try
        load()
    catch e
        if e isa SchemaValidationError
            return ValidationResult(e.errors, StructuralError[])
        elseif e isa ParseError && isempty(e.code)
            return ValidationResult([SchemaError("", e.message, "parse")], StructuralError[])
        end
        err = load_failure_structural_error(e)
        err === nothing && rethrow()
        return ValidationResult(SchemaError[], StructuralError[err])
    end
    return validate(file)
end

"""
    load_failure_structural_error(e) -> Union{StructuralError,Nothing}

Render a load-time rejection as the `StructuralError` the conformance contract
expects, or `nothing` for a failure that carries no code. A load can refuse a
document before the typed `validate()` pass runs, which would otherwise leave
`structural_errors` empty although the document is invalid.

Every load diagnostic (`ParseError`, `ExpressionTemplateError`,
`SubsystemRefError`, `EnumLoweringError`) with a non-empty `code` is rendered with its `code`,
`message`, `path` and `details`. A `SubsystemRefError` from the
`subsystems.<k>` form is reported at its mount site,
`/models/<parent>/subsystems/<sub>`, with `ref`, `subsystem` and `parent_model`
in its details. A `ParseError` without a code (malformed JSON, a coercion
failure) gives `nothing`, and so does a `SchemaValidationError`, whose
findings are schema errors, not structural ones.

[`validate_path`](@ref), [`validate_text`](@ref) and the conformance producer
route load failures through here.
"""
function load_failure_structural_error(e)::Union{StructuralError, Nothing}
    e isa _LoadDiagnostic || return nothing
    e isa SchemaValidationError && return nothing
    isempty(e.code) && return nothing
    if e isa SubsystemRefError
        return StructuralError(
            isempty(e.parent_model) ? e.path :
                _pointer("", "models", e.parent_model, "subsystems", e.subsystem),
            e.message,
            e.code,
            merge(
                Dict{String, Any}(
                    "ref" => e.ref,
                    "subsystem" => e.subsystem,
                    "parent_model" => e.parent_model
                ),
                e.details
            )
        )
    end
    return StructuralError(e.path, e.message, e.code, e.details)
end
