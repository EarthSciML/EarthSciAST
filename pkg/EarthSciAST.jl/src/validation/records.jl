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

"""
    UnitWarning

A single dimensional-analysis finding, in the STRUCTURED form the Python,
TypeScript and Go bindings have always used and Julia did not: this field was
a bare `Vector{String}`, so a caller could read the prose but could not filter
or route findings by `code` without regex-ing the message — exactly the
prose-parsing every binding's units documentation warns against.

Fields and their JSON spellings match Go's `UnitWarning`
(`pkg/earthsci-ast-go/pkg/esm/validate.go`) and the shape pinned by
`CONFORMANCE_SPEC.md` §3.1:

* `path` — RFC-6901 JSON Pointer to the offending equation / expression, the
  document root being `""` (the same addressing as `StructuralError.path`).
* `code` — the finding kind, decided AT THE POINT the finding was raised and
  never recovered from the prose, so rewording a message can never silently
  reclassify it. This is the SECOND, smaller unit vocabulary, the one Go's
  `UnitFinding*`, Rust's `UNIT_FINDING_*` and TypeScript's
  `UnitWarning['code']` union share. This binding puts two of its codes on the
  field: `dimensional_mismatch` (a PROVABLE inconsistency, promoted to a
  `unit_inconsistency` structural error) and the warning
  `units_dimensionless_literal_mismatch`
  ([`UNIT_FINDING_DIMENSIONLESS_LITERAL`](@ref), esm-spec §4.8.6). An
  unresolvable unit string is reported only as a `unit_parse_error`
  structural error, not here.
* `message` — human-readable description (binding-local prose).
* `lhs_units` / `rhs_units` — the inferred units of each side, `""` when the
  raise site does not know them. Julia's units engine (`model_unit_findings`)
  currently reports findings as prose and carries no separate unit pair, so
  these are `""` today; `validate` reads them from the promoted
  `StructuralError`'s `details` under those keys, so a raise site that starts
  supplying them is picked up with no further change here.

Despite the name — kept for wire compatibility, it is the `unit_warnings`
field of the spec's `ValidationResult` — a `UnitWarning` is not necessarily
advisory: the codes that state a defect in the FILE are promoted to hard
`unit_inconsistency` structural errors, and those are what invalidate the
document.
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
    ValidationResult

Combined validation result containing schema errors, structural errors,
unit warnings, and overall validation status.

The four-field shape (`is_valid`, `schema_errors`, `structural_errors`,
`unit_warnings`) is pinned by `ESM_COMPLIANCE_VALIDATION_MATRIX.md` VALID-03-A.

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
end

# Constructor for ValidationResult
ValidationResult(schema_errors::Vector{SchemaError}, structural_errors::Vector{StructuralError}; unit_warnings::Vector{UnitWarning} = UnitWarning[]) =
    ValidationResult(isempty(schema_errors) && isempty(structural_errors), schema_errors, structural_errors, unit_warnings)

"""
    SchemaValidationError

Exception thrown when schema validation fails.
Contains detailed error information including paths and messages.
"""
struct SchemaValidationError <: EarthSciASTError
    message::String
    errors::Vector{SchemaError}
end

# `message` is already the fully rendered multi-line diagnostic
# (`_format_schema_errors`), so the standard "TypeName: message" layout is all
# that is added here.
Base.showerror(io::IO, e::SchemaValidationError) =
    print(io, "SchemaValidationError: ", e.message)
