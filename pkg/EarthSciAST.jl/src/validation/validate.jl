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
    _validate_structural(file, _UnitsInputs(file))

# What the units checks of one validation pass share, built once: the
# document-wide scoped-reference units (esm-spec §4.8.4; units.jl's
# `_ScopedUnits`), each top-level model's and reaction system's
# template-expanded view (`_units_view`), the independent variable, and the
# units checker's result once it has run (`_unit_check!`).
struct _UnitsInputs
    file::EsmFile
    toplevel::Dict{String, Union{String, Nothing}}
    models::Dict{String, Model}
    reaction_systems::Dict{String, ReactionSystem}
    indep::String
    checked::Base.RefValue{Any}
end

function _UnitsInputs(file::EsmFile)
    models = Dict{String, Model}()
    if file.models !== nothing
        for (name, model) in file.models
            models[name] = _units_view(file, name, model)
        end
    end
    rss = Dict{String, ReactionSystem}()
    if file.reaction_systems !== nothing
        for (name, rs) in file.reaction_systems
            rss[name] = _reaction_system_units_view(file, name, rs)
        end
    end
    return _UnitsInputs(
        file, _toplevel_scoped_units(file), models, rss, _indep_var(file), Ref{Any}(nothing)
    )
end

function _validate_structural(file::EsmFile, units::_UnitsInputs)::Vector{StructuralError}
    errors = StructuralError[]

    # 1. Validate model equation-unknown balance. A COUPLED model is skipped
    # entirely: its states may be supplied from outside, by a `variable_map` or
    # by the system it is composed onto, so its own equations need not balance
    # its own unknowns.
    if file.models !== nothing
        coupled = _coupled_system_names(file)
        composed = _operator_composed_systems(file)
        for (model_name, model) in file.models
            model_name ∈ coupled && continue
            append!(
                errors, validate_model_balance(
                    model, "/models/$model_name";
                    check_excess = model_name ∉ composed
                )
            )
        end
    end

    # 2. Validate reference integrity
    append!(errors, validate_reference_integrity(file; views = units.models))

    # 2b. An inline test's assertion targets, override keys and assertion ranks
    # (esm-spec §6.6.2, §6.6.3, §6.6.5).
    append!(errors, _validate_inline_tests(file))

    # 3. Validate reaction system consistency
    # The document-wide part of every component's scoped-reference units
    # (esm-spec §4.8.4), built once for the whole pass.
    scoped_toplevel = units.toplevel
    if file.reaction_systems !== nothing
        for (rs_name, rs) in file.reaction_systems
            append!(
                errors, validate_reaction_consistency(
                    rs, "/reaction_systems/$rs_name";
                    indep = _indep_var(file)
                )
            )
            append!(
                errors, validate_reaction_rate_units(
                    rs, "/reaction_systems/$rs_name";
                    toplevel = scoped_toplevel
                )
            )
        end
    end

    # 3b. A data-update binding's `unit_conversion` expression (audit finding
    # (h)). It may be an Expression rather than a numeric factor, and an
    # undefined name in one used to be invisible.
    #
    # Its scope is the DOCUMENT-WIDE declared names: a conversion may scale a
    # loaded field by a MODEL's declared parameter (mirrors TS
    # `documentDeclaredNames`; `tests/invalid/undefined_variable_in_unit_conversion.esm`
    # multiplies the loaded field by the model parameter `k`, whose only defect
    # is the separate undefined name `undefined_xyz`). From esm 1.0.0 the
    # binding lives on the CONSUMING PARAMETER (esm-spec §8.5), so the walk
    # follows the models rather than a loader table.
    if file.models !== nothing
        ucscope = _document_declared_names(file)
        union!(ucscope, keys(file.index_sets))
        for model_name in sort!(collect(keys(file.models)))
            _check_update_unit_conversions!(
                errors, file, file.models[model_name],
                "/models/$model_name", ucscope
            )
        end
    end

    # 3c. `update.source` must resolve to a declared `data_sources` entry
    # (esm-spec §8.5, `data_source_undefined`).
    if file.models !== nothing
        available = file.data_sources === nothing ? String[] :
            sort!(String[String(k) for k in keys(file.data_sources)])
        for model_name in sort!(collect(keys(file.models)))
            _check_update_sources!(
                errors, file.models[model_name],
                "/models/$model_name", available
            )
        end
    end

    # 3c'. Record axes and data-fed record shapes (esm-spec §8.5.1:
    # `record_axis_invalid`, `record_axis_misplaced`,
    # `record_axis_time_invariant_source`, `records_per_sample_invalid`).
    _check_record_axes!(errors, file)
    _check_record_shapes!(errors, file)

    # 3d. A present `system_kind` field must agree with the derivation
    # (esm-spec §6.3.1, `system_kind_mismatch`).
    if file.models !== nothing
        for model_name in sort!(collect(keys(file.models)))
            _check_system_kind!(errors, file.models[model_name], "/models/$model_name")
        end
    end

    # 3e. A DECLARATION spelled with a globally-scoped name — the independent
    # variable or the §6.4 `_var` placeholder — is unreachable (esm-spec
    # §4.9.1.1, `reserved_variable_name`). `_implicit_symbols` credits both by
    # NAME, ahead of the declaration maps, so every reader gets the implicit
    # symbol instead of the declared quantity (issue #200). All three
    # declaration maps are covered: a species and a reaction parameter become
    # symbols of the derived ODE system exactly as a `variables` entry does.
    _check_reserved_file_names!(errors, file)

    # 3f. Inline array data is a SHAPED variable's value (esm-spec §6.3,
    # `array_default_without_shape`): on a variable with no `shape` it has
    # nothing to fill and no scalar reading, so the declaration is malformed.
    if file.models !== nothing
        for model_name in sort!(collect(keys(file.models)))
            _check_array_defaults_have_shape!(
                errors, file.models[model_name],
                "/models/$model_name", "Model '$model_name'"
            )
        end
    end

    # 3g. What an equation's left-hand side may name (esm-spec §6.3.1): never a
    # parameter (`equation_defines_parameter`), and no index symbol a faq does
    # not bind (`unbound_index_symbol`).
    if file.models !== nothing
        meta = file.metaparameters === nothing ? Set{String}() :
            Set{String}(String(k) for k in keys(file.metaparameters))
        for model_name in sort!(collect(keys(file.models)))
            m = file.models[model_name]
            _check_equation_lhs_names!(errors, m, "/models/$model_name", model_name, m, meta)
        end
    end

    # 4. Validate event consistency. Unlike balance and reference integrity, this
    # still RUNS for a coupled model — it is where a genuinely undeclared event
    # target is caught — but with the §6.4 `_var` placeholder credited (finding (b)).
    if file.models !== nothing
        coupled_ev = _coupled_system_names(file)
        for (model_name, model) in file.models
            append!(
                errors, validate_event_consistency(
                    model, "/models/$model_name";
                    is_coupled = model_name ∈ coupled_ev
                )
            )
            append!(errors, validate_physical_constant_units(model, "/models/$model_name"))
            append!(errors, validate_conversion_factor_consistency(model, "/models/$model_name"))
        end
    end

    # The units checker: every unit check site of every component, judged once.
    append!(errors, _unit_check!(units).errors)

    # 5b. Coupling-cycle detection (§3.2). A dependency cycle among top-level
    # systems means no evaluation order exists.
    append!(errors, validate_coupling_cycles(file; toplevel = scoped_toplevel))

    # 5b'. Variable bounds (esm-spec §6.3.2): an unresolved reference, a
    # referenced shape that is neither scalar nor the variable's, a bound that
    # refers back to its variable, and numeric bounds out of order.
    append!(errors, validate_variable_bounds(file; toplevel = scoped_toplevel))

    # 5c. Aggregate/relational semantic checks (F-6). Three defects that are
    # statically decidable from the SINGLE document yet slip past both the schema
    # and the reference-integrity pass, so `validate()` accepted them until now:
    #   • `undefined_index_set`         — an aggregate `ranges` `{from: NAME}`
    #                                     naming a set absent from the document
    #                                     `index_sets` registry (only when the
    #                                     document declares one — §9.7.10 leaves
    #                                     get theirs by injection, issue #185);
    #   • `join_key_invalid_type`       — a value-equality `join` whose key column
    #                                     ranges over a categorical set with a
    #                                     float/null member (not portably equatable);
    #   • `relational_node_in_continuous` — a `distinct` (value-invention) aggregate
    #                                     whose key/body reads a STATE variable, so it
    #                                     classifies CONTINUOUS (§5.7 guard 2).
    # Each attaches at the containing expression FIELD, matching the corpus pins.
    append!(errors, validate_aggregate_semantics(file; views = units.models))

    # 5c'. Array broadcast semantics (esm-spec §4.3.4). Two statically decidable
    # defects the schema cannot express:
    #   • `invalid_broadcast_fn` — a `broadcast` node whose `fn` is missing,
    #     names no operator, names a STRUCTURAL operator, or is handed the wrong
    #     number of operands. `fn` is an opaque string on the wire, so no other
    #     check reads it.
    #   • `array_shape_mismatch` — an element-wise operand declared over an
    #     index set the RESULT does not have, which no name-based broadcast can
    #     align (esm-spec §4.3.4 "Broadcast compatibility").
    append!(errors, validate_broadcast_semantics(file))

    # 5c''. Causal-self-reference well-foundedness (esm-spec §4.3.1.1). A
    # recurrence is recognized STRUCTURALLY — no new op, no new schema field —
    # so nothing but this pass stands between an ill-founded self-read and a
    # plausible wrong number. Both codes are owed by every binding, executing or
    # not (CONFORMANCE_SPEC §5.19.5 rejection parity).
    append!(errors, validate_recurrence_semantics(file))

    # 5c'''. Observed dependency cycles (esm-spec §4.9.6, issue #181). A cycle
    # among a model's observed definitions has no evaluation order, and the
    # equations alone decide it — so it is decided HERE rather than left to the
    # build, which used to report `E_TREEWALK_UNBOUND_NAME` against whichever
    # innocent observed its materialization walk reached first after the cycle
    # stalled. Runs AFTER `validate_recurrence_semantics` for readability only:
    # the two are independent, because the self-edge exemption is gated on
    # recurrence CANDIDACY, never on that pass's verdict (CONFORMANCE_SPEC
    # §5.19.5) — so an ill-founded self-read still gets its `recurrence_*` name
    # rather than being collapsed into a cycle error.
    append!(errors, validate_observed_cycles(file))

    # 5d. `variable_map` identity-coupling declared-unit mismatch (esm-spec §4.7.6).
    # The flatten path already rejects this via `_check_variable_map_units`
    # (`DomainUnitMismatchError`); mirror it as a `domain_unit_mismatch` structural
    # finding at `/coupling/i` so `validate()` catches it without flattening.
    append!(errors, validate_variable_map_units(file))

    # 6. Conflicting derivative detection (§4.7.5 item E). A species cannot
    # have both an explicit D(X, t) = ... equation and a reaction contribution.
    # `_find_conflicting_derivatives` is defined in flatten.jl. The conflict
    # spans TWO top-level blocks (a model equation AND a reaction), so it is
    # reported at the document root, `""` (the offending species name is in the
    # message).
    conflicting = _find_conflicting_derivatives(file)
    for name in conflicting
        push!(
            errors, StructuralError(
                "",
                "Species '$name' has both an explicit derivative equation and a reaction contribution",
                ERROR_CODES.CONFLICTING_DERIVATIVE,
            )
        )
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
    # no extra carrier scrub is needed here. (Historically JSON3 values leaked
    # through these fields and JSONSchema.jl misread them, rejecting e.g.
    # tests/valid/scoped_refs_coupling.esm for a `couple` entry whose
    # `connector.equations` were `JSON3.Object` rather than `Dict`.)
    data = serialize_esm_file(file)

    schema_errors = validate_schema(data)
    units = _UnitsInputs(file)
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
                "/models/$(e.parent_model)/subsystems/$(e.subsystem)",
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
