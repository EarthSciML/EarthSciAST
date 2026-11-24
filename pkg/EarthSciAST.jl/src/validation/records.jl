# The records validation reports: schema and structural findings, unit warnings, the combined result.

"""
ESM Format Schema Validation

Provides functionality to validate ESM files against the JSON schema.
"""

using JSON3
using JSONSchema

"""
    SchemaError

Represents a validation error with detailed information.
Contains path, message, and keyword from JSON Schema validation.
"""
struct SchemaError
    path::String
    message::String
    keyword::String
end

"""
    StructuralError

Represents a structural validation error with detailed information.
Contains path, message, error type, and machine-readable `details`.

`details` is the machine-readable half of the error. A conformance pin asserts
code, path and `details` under required-subset semantics (CONFORMANCE_SPEC
§7.1.2): every key the pin names must be present with the pinned value, and extra
keys are fine. It defaults to empty; a site that names a variable populates
`details["variable"]`, plus whatever else is locally meaningful.
"""
struct StructuralError
    path::String
    message::String
    error_type::String
    details::Dict{String, Any}

    StructuralError(
        path::AbstractString, message::AbstractString, error_type::AbstractString,
        details::AbstractDict = Dict{String, Any}()
    ) =
        new(String(path), String(message), String(error_type), Dict{String, Any}(details))
end

# The set of codes a finding may carry: the values of `ERROR_CODES`.
const _FINDING_CODES = Set{String}(values(ERROR_CODES))

"""
    _report!(out, code, path, message, details = Dict()) -> out

Push the structural finding `code` at JSON pointer `path` onto `out`: the one
way a check reports a finding. `code` must be a value of
[`ERROR_CODES`](@ref).
"""
function _report!(
        out::Vector{StructuralError}, code::AbstractString, path::AbstractString,
        message::AbstractString, details::AbstractDict = Dict{String, Any}()
    )
    code in _FINDING_CODES || throw(ArgumentError("finding code '$code' is not in ERROR_CODES"))
    push!(out, StructuralError(path, message, code, details))
    return out
end

"""
    UnitWarning

A single dimensional-analysis finding, structured so a caller can filter or
route findings by `code` without parsing the message. Fields and their JSON
spellings match Go's `UnitWarning`
(`pkg/earthsci-ast-go/pkg/esm/validate.go`) and the shape pinned by
`CONFORMANCE_SPEC.md` §3.1:

* `path` — RFC-6901 JSON Pointer to the offending equation / expression, the
  document root being `""` (the same addressing as `StructuralError.path`).
* `code` — the finding kind, set where the finding is raised (never recovered
  from the prose), from the unit-finding vocabulary Go's `UnitFinding*`, Rust's
  `UNIT_FINDING_*` and TypeScript's `UnitWarning['code']` share. This binding
  uses two of its codes: `dimensional_mismatch` (a PROVABLE inconsistency, promoted to a
  `unit_inconsistency` structural error) and the warning
  `units_dimensionless_literal_mismatch`
  ([`UNIT_FINDING_DIMENSIONLESS_LITERAL`](@ref), esm-spec §4.8.6). An
  unresolvable unit string is reported only as a `unit_parse_error`
  structural error, not here.
* `message` — human-readable description (binding-local prose).
* `lhs_units` / `rhs_units` — the inferred units of each side, `""` when the
  raise site does not know them. `validate` reads them from the promoted
  `StructuralError`'s `details` under those keys; `model_unit_findings`
  supplies no unit pair, so they are `""`.

Despite the name (the `unit_warnings` field of the spec's `ValidationResult`),
a `UnitWarning` is not necessarily advisory: the codes that state a defect in
the file are promoted to `unit_inconsistency` structural errors, which
invalidate the document.
"""
struct UnitWarning
    path::String
    code::String
    message::String
    lhs_units::String
    rhs_units::String

    UnitWarning(
        path::AbstractString, code::AbstractString, message::AbstractString,
        lhs_units::AbstractString = "", rhs_units::AbstractString = ""
    ) =
        new(
        String(path), String(code), String(message),
        String(lhs_units), String(rhs_units)
    )
end

"""
    ValidationWarning

An advisory validation finding that is not about units: a stable diagnostic
`code`, the JSON `path` it concerns and a `message`. It never changes
`is_valid`.
"""
struct ValidationWarning
    code::String
    path::String
    message::String
end

"""
    ValidationResult

Combined validation result containing schema errors, structural errors,
unit warnings, non-unit `warnings`, and overall validation status.

The fields `is_valid`, `schema_errors`, `structural_errors` and
`unit_warnings` are pinned by `ESM_COMPLIANCE_VALIDATION_MATRIX.md` VALID-03-A;
`warnings` holds [`ValidationWarning`](@ref)s.

`unit_warnings` mirrors the TS/Python/Go bindings' `ValidationResult` shape:
unit findings appear both here (as [`UnitWarning`](@ref) records) and as
promoted `unit_inconsistency` entries in `structural_errors`. Unit warnings
never affect `is_valid` on their own — the promoted structural errors do.
"""
struct ValidationResult
    is_valid::Bool
    schema_errors::Vector{SchemaError}
    structural_errors::Vector{StructuralError}
    unit_warnings::Vector{UnitWarning}
    warnings::Vector{ValidationWarning}
end

# Constructor for ValidationResult
ValidationResult(
    schema_errors::Vector{SchemaError}, structural_errors::Vector{StructuralError};
    unit_warnings::Vector{UnitWarning} = UnitWarning[],
    warnings::Vector{ValidationWarning} = ValidationWarning[]
) =
    ValidationResult(
    isempty(schema_errors) && isempty(structural_errors), schema_errors, structural_errors,
    unit_warnings, warnings
)

"""
    SchemaValidationError <: EarthSciASTError

A document that fails the ESM schema at load. It is a load diagnostic (see
`_LoadDiagnostic`): the common fields `code` (always
`schema_validation_error`), `message` (the rendered list of violations),
`path`, `file` and `details`, then `errors`, one [`SchemaError`](@ref) per
violation.

    SchemaValidationError(message, errors; path = "", file = "", details = Dict())
"""
struct SchemaValidationError <: _LoadDiagnostic
    code::String
    message::String
    path::String
    file::String
    details::Dict{String, Any}
    errors::Vector{SchemaError}
end

SchemaValidationError(
    message::AbstractString, errors::AbstractVector{SchemaError};
    path::AbstractString = "", file::AbstractString = "",
    details::AbstractDict = Dict{String, Any}()
) = SchemaValidationError(
    ERROR_CODES.SCHEMA_VALIDATION_ERROR, String(message), String(path), String(file),
    Dict{String, Any}(details), Vector{SchemaError}(errors)
)
