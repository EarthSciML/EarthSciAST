# The error type of the load pipeline (`ExpressionTemplateError`) and the
# subset of `ERROR_CODES` it is raised with.

"""
    ExpressionTemplateError <: EarthSciASTError

Exception raised when a load-time lowering pass fails: expression-template
expansion (esm-spec §9.6), template-library imports (§9.7), coupling-library
imports (§10.9–§10.11), the §4.7 mount checks (subsystem references and
their index sets), and other load-time gates. Carries a stable diagnostic
`code` drawn from [`ERROR_CODES`](@ref) — [`_KNOWN_DIAGNOSTIC_CODES`](@ref) names the subset of
that registry this exception is raised with. Codes (and their message texts)
are conformance-relevant, so a new raise site MUST use a code registered there
— and a genuinely new code MUST be added to `ERROR_CODES` (and coordinated
across every binding) alongside its first raise site.
"""
struct ExpressionTemplateError <: EarthSciASTError
    code::String
    message::String
end

Base.showerror(io::IO, e::ExpressionTemplateError) =
    print(io, "[$(e.code)] $(e.message)")

"""
    _KNOWN_DIAGNOSTIC_CODES

The subset of [`ERROR_CODES`](@ref) that is raised as an
[`ExpressionTemplateError`](@ref) anywhere in the package, grouped by the
spec section that pins it. Every entry is a REFERENCE into the central
registry (`src/error_codes.jl`), never a literal — this tuple records which
codes belong to this exception, and `ERROR_CODES` alone owns their values.
Diagnostic codes are conformance-relevant (cross-binding fixtures assert
them), so keep this tuple in sync with the raise sites: add the code to
`ERROR_CODES` and list it here when introducing it.
"""
const _KNOWN_DIAGNOSTIC_CODES = (
    # esm-spec §4.8.5 item 6: declared `units` on an expression node need
    # esm >= 1.2.0 (units.jl `reject_const_units_pre_v12`).
    ERROR_CODES.CONST_UNITS_VERSION_TOO_OLD,
    # esm-spec §6.3.2: `lb` / `ub` on a variable need esm >= 2.1.0
    # (variable_bounds.jl `reject_variable_bounds_pre_v21`).
    ERROR_CODES.VARIABLE_BOUNDS_VERSION_TOO_OLD,
    # esm-spec §8.2.1 data-source location resolution (data_source_urls.jl).
    ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED,
    # esm-spec §2.2.6 `solver.external` load checks (solver.jl).
    ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
    ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED,
    # esm-spec §2.2.7 `solver.time_span` load checks (solver.jl).
    ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD,
    ERROR_CODES.SOLVER_TIME_SPAN_INVALID,
    # esm-spec §9.6 expression templates + §9.6.4 post-expansion validators
    # (templates/declarations.jl, templates/rewrite.jl).
    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY,
    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
    ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD,
    ERROR_CODES.REWRITE_RULE_NONTERMINATING,
    ERROR_CODES.TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET,
    ERROR_CODES.MAKEARRAY_REGION_INVERTED,
    # Flatten-time shadow-registry guard (flatten.jl): a surviving registry
    # body references a variable a coupling `variable_map` rewrote in the
    # flattened equations (esm-spec §9.6.4 / §10.4).
    ERROR_CODES.TEMPLATE_BODY_REFERENCES_COUPLING_REWRITTEN_VARIABLE,
    # Projection-pushdown desugar post-condition (pushdown_rewrite.jl): a rect
    # factor the rewrite must re-point onto the generated per-support cell
    # gathers is named FREE in a template body instead of bound at the call
    # site, so the call-site-only rewrite cannot reach it (esm-spec §9.6.4
    # Option B / CONFORMANCE_SPEC §5.5.7).
    ERROR_CODES.TEMPLATE_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE,
    # esm-spec §2.2.4 document-scoped solver hints (solver.jl): the top-level
    # `solver` block in a file declaring esm < 1.1.0.
    ERROR_CODES.SOLVER_VERSION_TOO_OLD,
    # esm-spec §9.7 template-library imports + metaparameters
    # (templates/imports.jl, templates/metaparameters.jl).
    ERROR_CODES.TEMPLATE_IMPORT_VERSION_TOO_OLD,
    ERROR_CODES.TEMPLATE_IMPORT_UNRESOLVED,
    ERROR_CODES.TEMPLATE_IMPORT_NOT_LIBRARY,
    ERROR_CODES.TEMPLATE_IMPORT_IS_COUPLING_LIBRARY,
    ERROR_CODES.TEMPLATE_LIBRARY_ILLEGAL_PAYLOAD,
    ERROR_CODES.TEMPLATE_IMPORT_CYCLE,
    ERROR_CODES.TEMPLATE_IMPORT_NAME_CONFLICT,
    ERROR_CODES.TEMPLATE_IMPORT_UNKNOWN_NAME,
    ERROR_CODES.TEMPLATE_IMPORT_INDEX_SET_CONFLICT,
    ERROR_CODES.TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME,
    ERROR_CODES.TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME,
    ERROR_CODES.TEMPLATE_IMPORT_RENAME_COLLISION,
    ERROR_CODES.TEMPLATE_IMPORT_RENAME_INVALID,
    ERROR_CODES.TEMPLATE_INJECT_TARGET_UNKNOWN,
    ERROR_CODES.TEMPLATE_INJECT_TARGET_NOT_COMPONENT,
    ERROR_CODES.TEMPLATE_INJECT_TARGET_IS_LOADER,
    ERROR_CODES.TEMPLATE_BODY_EXPANSION_TOO_DEEP,
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
    # esm-spec §4.7 mount checks: what a subsystem reference may target, and
    # index-set conflicts across a mount (mount resolution).
    ERROR_CODES.SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY,
    ERROR_CODES.SUBSYSTEM_REF_IS_COUPLING_LIBRARY,
    ERROR_CODES.SUBSYSTEM_INDEX_SET_CONFLICT,
    # esm-spec §4.7 mount-edge index-set renaming: the rename's own unknown-key
    # check (mounts.jl).
    ERROR_CODES.SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME,
    # esm-spec §4.7 mount-edge `url_substitutions` (data_source_urls.jl).
    ERROR_CODES.URL_SUBSTITUTION_UNKNOWN_NAME,
    # esm-spec §4.7 mounted `data_sources` merge (resolve.jl).
    ERROR_CODES.DATA_SOURCE_MERGE_CONFLICT,
    # esm-spec §8.5.1 record shapes re-checked by `flatten` after
    # `coupling_import` expansion (flatten.jl).
    ERROR_CODES.RECORDS_PER_SAMPLE_INVALID,
    ERROR_CODES.RECORD_AXIS_MISPLACED,
    ERROR_CODES.RECORD_AXIS_TIME_INVARIANT_SOURCE,
)
