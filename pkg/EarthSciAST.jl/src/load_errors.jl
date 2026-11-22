# The error types of the load pipeline and the one shape they share.

"""
    _LoadDiagnostic <: EarthSciASTError

Supertype of the errors a load raises about the document it is reading:
[`ParseError`](@ref), [`ExpressionTemplateError`](@ref),
[`SubsystemRefError`](@ref), [`EnumLoweringError`](@ref) and
[`SchemaValidationError`](@ref). Each subtype leads with the same five fields, in
this order, and puts anything of its own after them:

| Field | Type | Meaning |
|---|---|---|
| `code` | `String` | the diagnostic code from [`ERROR_CODES`](@ref); `""` only for a `ParseError` with no code (malformed JSON, a coercion failure) |
| `message` | `String` | the text; corpus-pinned messages keep their location prose in it |
| `path` | `String` | RFC 6901 pointer into the document named by `file`, `""` if none |
| `file` | `String` | canonical key of the document the error is about (absolute path or URL), `""` for the root |
| `details` | `Dict{String,Any}` | machine-readable extras, as on a `StructuralError` |

Each subtype keeps its default (all-fields) constructor, so [`_at`](@ref) can
rebuild any of them with a location filled in.
"""
abstract type _LoadDiagnostic <: EarthSciASTError end

"""
    ParseError <: EarthSciASTError

A document that cannot be read: malformed JSON, a value the typed coercion
cannot accept, or a construct refused by name at the wire boundary
(`removed_op`, `faq_version_too_old`, `ic_in_reaction_system`). An ordinary
parse failure has an empty `code`; a refusal that is also a pinned finding
carries its `code` and `path`, which [`load_failure_structural_error`](@ref)
renders. After the common fields (see `_LoadDiagnostic`) comes
`original_error`, the underlying exception, if any.

    ParseError(message, original_error = nothing; code = "", path = "", file = "", details = Dict())
"""
struct ParseError <: _LoadDiagnostic
    code::String
    message::String
    path::String
    file::String
    details::Dict{String, Any}
    original_error::Union{Exception, Nothing}
end

ParseError(
    message::AbstractString, original_error = nothing;
    code::AbstractString = "", path::AbstractString = "", file::AbstractString = "",
    details::AbstractDict = Dict{String, Any}()
) = ParseError(
    String(code), String(message), String(path), String(file),
    Dict{String, Any}(details), original_error
)

"""
    ExpressionTemplateError <: EarthSciASTError

A load-time pass refused the document: expression-template expansion
(esm-spec §9.6), template-library imports (§9.7), coupling-library imports
(§10.9–§10.11), the §4.7 mount checks (`mounts.jl`), the version gates, and the
`solver` and data-source location checks. Its `code` is drawn from
[`ERROR_CODES`](@ref); [`_KNOWN_DIAGNOSTIC_CODES`](@ref) lists the codes it is
raised with. Codes and their messages are conformance-relevant, so a new raise
site uses a registered code, and a new code is added to `ERROR_CODES` and
coordinated across the bindings with its first raise site. Fields: the common
ones of `_LoadDiagnostic`.

    ExpressionTemplateError(code, message; path = "", file = "", details = Dict())
"""
struct ExpressionTemplateError <: _LoadDiagnostic
    code::String
    message::String
    path::String
    file::String
    details::Dict{String, Any}
end

ExpressionTemplateError(
    code::AbstractString, message::AbstractString;
    path::AbstractString = "", file::AbstractString = "",
    details::AbstractDict = Dict{String, Any}()
) = ExpressionTemplateError(
    String(code), String(message), String(path), String(file), Dict{String, Any}(details)
)

"""
    SubsystemRefError <: EarthSciASTError

A §4.7 mount that cannot be resolved: its file is missing, unreadable or does
not hold exactly the component asked for, or the mounts form a cycle. `code`
is required (`unresolved_subsystem_ref`, `ambiguous_subsystem_ref`,
`element_type_uncarried`). After the common fields (see `_LoadDiagnostic`)
come the `ref` as written and, for the `subsystems.<k>` form, the mount site
(`subsystem`, `parent_model`), which `validate` renders as
`/models/<parent_model>/subsystems/<subsystem>`.

    SubsystemRefError(message; code, ref = "", subsystem = "", parent_model = "", path = "", file = "", details = Dict())
"""
struct SubsystemRefError <: _LoadDiagnostic
    code::String
    message::String
    path::String
    file::String
    details::Dict{String, Any}
    ref::String
    subsystem::String
    parent_model::String
end

SubsystemRefError(
    message::AbstractString;
    code::AbstractString,
    ref::AbstractString = "", subsystem::AbstractString = "",
    parent_model::AbstractString = "", path::AbstractString = "",
    file::AbstractString = "", details::AbstractDict = Dict{String, Any}()
) = SubsystemRefError(
    String(code), String(message), String(path), String(file),
    Dict{String, Any}(details), String(ref), String(subsystem), String(parent_model)
)

"""
    EnumLoweringError <: EarthSciASTError

Raised when enum lowering (esm-spec §9.3) fails, the same error type the other
bindings raise here (`EnumLoweringError` in TypeScript, Python and Rust;
`DiagnosticError` in Go; API_SPEC.md §8 item 15). Codes:
`enum_duplicate_value`, `enum_op_malformed`, `unknown_enum`,
`unknown_enum_symbol`. Fields: the common ones of `_LoadDiagnostic`.

    EnumLoweringError(code, message; path = "", file = "", details = Dict())
"""
struct EnumLoweringError <: _LoadDiagnostic
    code::String
    message::String
    path::String
    file::String
    details::Dict{String, Any}
end

EnumLoweringError(
    code::AbstractString, message::AbstractString;
    path::AbstractString = "", file::AbstractString = "",
    details::AbstractDict = Dict{String, Any}()
) = EnumLoweringError(
    String(code), String(message), String(path), String(file), Dict{String, Any}(details)
)

"""
    _at(e; path = "", file = "") -> typeof(e)

`e` with its `path` and `file` filled in where they are still empty. A
location already set is kept, so the innermost site that knows it wins. Any
other exception comes back unchanged.
"""
function _at(e::_LoadDiagnostic; path::AbstractString = "", file::AbstractString = "")
    fill_path = isempty(e.path) && !isempty(path)
    fill_file = isempty(e.file) && !isempty(file)
    (fill_path || fill_file) || return e
    T = typeof(e)
    return T(
        (
            f === :path && fill_path ? String(path) :
                f === :file && fill_file ? String(file) : getfield(e, f)
                for f in fieldnames(T)
        )...
    )
end
_at(e; path::AbstractString = "", file::AbstractString = "") = e

"""
    _in_file(f, file) -> f()

Run `f`. A load diagnostic escaping it that names no file yet is rethrown
naming `file` (`_at`), so an error raised inside a document another one reads
names that document.
"""
function _in_file(f, file::AbstractString)
    try
        return f()
    catch e
        located = _at(e; file = file)
        located === e && rethrow()
        throw(located)
    end
end

# `e` with the `subsystems.<k>` mount site filled in where it is not set yet.
_with_mount_site(e::SubsystemRefError, subsystem::AbstractString, parent_model::AbstractString) =
    SubsystemRefError(
    e.code, e.message, e.path, e.file, e.details, e.ref,
    isempty(e.subsystem) ? String(subsystem) : e.subsystem,
    isempty(e.parent_model) ? String(parent_model) : e.parent_model
)

# The load error of type `T` with `code` and `message`.
_load_error(::Type{ExpressionTemplateError}, code, message; kw...) =
    ExpressionTemplateError(code, message; kw...)
_load_error(::Type{SubsystemRefError}, code, message; kw...) =
    SubsystemRefError(message; code = code, kw...)

"""
    _rebrand(f, code, context; as = ExpressionTemplateError, kw...) -> f()

Run `f`. A resource error (`_is_resource_error`) or a package error
(`EarthSciASTError`) propagates as it is. Anything else (a `MethodError` from a
caller's loader, an I/O error) is rethrown as an `as` error with `code` and the
message `"<context>: <its showerror text>"`; `kw` go to that constructor.
"""
function _rebrand(
        f, code::AbstractString, context::AbstractString;
        as::Type = ExpressionTemplateError, kw...
    )
    try
        return f()
    catch e
        (_is_resource_error(e) || e isa EarthSciASTError) && rethrow()
        throw(_load_error(as, code, string(context, ": ", sprint(showerror, e)); kw...))
    end
end

"""
    _KNOWN_DIAGNOSTIC_CODES

The subset of [`ERROR_CODES`](@ref) that is raised as an
[`ExpressionTemplateError`](@ref), grouped by the spec section that pins it.
Every entry is a reference into the central registry (`src/error_codes.jl`),
never a literal: `ERROR_CODES` owns the values, this tuple records which codes
belong to this exception. Keep it in step with the raise sites.
"""
const _KNOWN_DIAGNOSTIC_CODES = (
    # esm-spec §4.8.5 item 6: declared `units` on an expression node need
    # esm >= 1.2.0 (`_VERSION_GATES`, resolve.jl).
    ERROR_CODES.CONST_UNITS_VERSION_TOO_OLD,
    # esm-spec §6.3.2: `lb` / `ub` on a variable need esm >= 2.1.0
    # (`_VERSION_GATES`, resolve.jl).
    ERROR_CODES.VARIABLE_BOUNDS_VERSION_TOO_OLD,
    # esm-spec §8.2.1 data-source location resolution (data_source_urls.jl).
    ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
    # esm-spec §2.2.6 `solver.external`: the version gate (`_VERSION_GATES`)
    # and the `${` refusal (solver.jl).
    ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
    ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED,
    # esm-spec §2.2.7 `solver.time_span`: the version gate and the interval
    # check (solver.jl).
    ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD,
    ERROR_CODES.SOLVER_TIME_SPAN_INVALID,
    # esm-spec §9.6 expression templates + §9.6.4 post-expansion validators
    # (templates/declarations.jl, templates/rewrite.jl).
    ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
    ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
    ERROR_CODES.OPERATOR_RECURSIVE_BODY,
    ERROR_CODES.OPERATOR_INVALID_DEFINITION,
    ERROR_CODES.OPERATOR_VERSION_TOO_OLD,
    ERROR_CODES.REWRITE_RULE_NONTERMINATING,
    # esm 2.4.0 one operator type (esm-spec §9.6.12).
    ERROR_CODES.OPERATOR_ARITY_MISMATCH,
    ERROR_CODES.OPERATOR_DEFINES_CORE_OP,
    ERROR_CODES.DEFINITION_UNIT_MISMATCH,
    ERROR_CODES.OPERATOR_CONSTRAINT_UNKNOWN_INDEX_SET,
    ERROR_CODES.MAKEARRAY_REGION_INVERTED,
    # Flatten-time shadow-registry guard (flatten.jl): a surviving registry
    # body references a variable a coupling `variable_map` rewrote in the
    # flattened equations (esm-spec §9.6.4 / §10.4).
    ERROR_CODES.OPERATOR_BODY_REFERENCES_COUPLING_REWRITTEN_VARIABLE,
    # Projection-pushdown desugar post-condition (pushdown_rewrite.jl): a rect
    # factor the rewrite must re-point onto the generated per-support cell
    # gathers is named FREE in a template body instead of bound at the call
    # site, so the call-site-only rewrite cannot reach it (esm-spec §9.6.4
    # Option B / CONFORMANCE_SPEC §5.5.7).
    ERROR_CODES.OPERATOR_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE,
    # esm-spec §2.2.4 document-scoped solver hints: the top-level `solver`
    # block in a file declaring esm < 1.1.0 (`_VERSION_GATES`).
    ERROR_CODES.SOLVER_VERSION_TOO_OLD,
    # esm-spec §9.7 template-library imports + metaparameters
    # (templates/imports.jl, templates/metaparameters.jl).
    ERROR_CODES.OPERATOR_IMPORT_VERSION_TOO_OLD,
    ERROR_CODES.OPERATOR_IMPORT_UNRESOLVED,
    ERROR_CODES.OPERATOR_IMPORT_NOT_LIBRARY,
    ERROR_CODES.OPERATOR_IMPORT_IS_COUPLING_LIBRARY,
    ERROR_CODES.OPERATOR_LIBRARY_ILLEGAL_PAYLOAD,
    ERROR_CODES.OPERATOR_IMPORT_CYCLE,
    ERROR_CODES.OPERATOR_IMPORT_NAME_CONFLICT,
    ERROR_CODES.OPERATOR_IMPORT_UNKNOWN_NAME,
    ERROR_CODES.OPERATOR_IMPORT_INDEX_SET_CONFLICT,
    ERROR_CODES.OPERATOR_IMPORT_RENAME_UNKNOWN_NAME,
    ERROR_CODES.OPERATOR_IMPORT_REBIND_UNKNOWN_NAME,
    ERROR_CODES.OPERATOR_IMPORT_RENAME_COLLISION,
    ERROR_CODES.OPERATOR_IMPORT_RENAME_INVALID,
    ERROR_CODES.OPERATOR_INJECT_TARGET_UNKNOWN,
    ERROR_CODES.OPERATOR_INJECT_TARGET_NOT_COMPONENT,
    ERROR_CODES.OPERATOR_INJECT_TARGET_IS_LOADER,
    ERROR_CODES.OPERATOR_BODY_EXPANSION_TOO_DEEP,
    ERROR_CODES.METAPARAMETER_UNBOUND,
    ERROR_CODES.METAPARAMETER_TYPE_ERROR,
    ERROR_CODES.METAPARAMETER_NAME_CONFLICT,
    # esm-spec §10.9–§10.11 coupling-library imports (coupling_imports.jl).
    ERROR_CODES.COUPLING_IMPORT_UNRESOLVED,
    ERROR_CODES.COUPLING_IMPORT_NOT_LIBRARY,
    ERROR_CODES.COUPLING_IMPORT_UNKNOWN_ROLE,
    ERROR_CODES.COUPLING_IMPORT_ROLE_UNBOUND,
    ERROR_CODES.COUPLING_IMPORT_BIND_NOT_A_COMPONENT,
    ERROR_CODES.COUPLING_EDGE_UNKNOWN_ROLE,
    ERROR_CODES.COUPLING_ROLE_UNUSED,
    ERROR_CODES.COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
    ERROR_CODES.COUPLING_LIBRARY_NESTED_IMPORT,
    # esm-spec §4.7 mounts: a leaf that is a library, and the index-set merge
    # (mounts.jl).
    ERROR_CODES.SUBSYSTEM_REF_IS_OPERATOR_LIBRARY,
    ERROR_CODES.SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
    ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
    # esm-spec §4.7 mount-edge index-set renaming: the rename's own unknown-key
    # check (mounts.jl).
    ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME,
    # esm-spec §4.7 mount-edge `url_substitutions` (data_source_urls.jl).
    ERROR_CODES.URL_SUBSTITUTION_UNKNOWN_NAME,
    # esm-spec §4.7 mounted `data_sources` merge (mounts.jl).
    ERROR_CODES.DATA_SOURCE_MERGE_CONFLICT,
    # esm-spec §8.5.1 record shapes re-checked by `flatten` after
    # `coupling_import` expansion (flatten.jl).
    ERROR_CODES.RECORDS_PER_SAMPLE_INVALID,
    ERROR_CODES.RECORD_AXIS_MISPLACED,
    ERROR_CODES.RECORD_AXIS_TIME_INVARIANT_SOURCE,
)
