/**
 * Central registry of the diagnostic code STRINGS emitted by this binding, plus
 * a neutral diagnostic base class.
 *
 * Cross-binding contract — values must never change; see Python `ErrorCode`
 * enum (`pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py`). These strings
 * are pinned by the shared conformance fixtures: every value below equals, byte
 * for byte, a literal currently emitted somewhere in `src/`. This module only
 * CENTRALIZES the references — it does not (and must not) change any emitted
 * string. Adding a new diagnostic means adding an entry here AND coordinating
 * the value across every binding.
 *
 * Keys are the SCREAMING_SNAKE_CASE form of the value (mirroring the Python
 * enum) so a reference reads as `ERROR_CODES.UNDEFINED_VARIABLE`.
 */
export const ERROR_CODES = {
  // ---- validation: structural validators + unit analysis (validate.ts,
  //      units.ts; emitted as `code: '...'` on a ValidationError) ----
  ANALYSIS: 'analysis',
  CIRCULAR_DEPENDENCY: 'circular_dependency',
  DIMENSIONAL_MISMATCH: 'dimensional_mismatch',
  EQUATION_COUNT_MISMATCH: 'equation_count_mismatch',
  EVENT_VAR_UNDECLARED: 'event_var_undeclared',
  FACTOR_WITH_EXPRESSION_TRANSFORM: 'factor_with_expression_transform',
  IC_IN_REACTION_SYSTEM: 'ic_in_reaction_system',
  INVALID_DISCRETE_PARAM: 'invalid_discrete_param',
  INVALID_STOICHIOMETRY: 'invalid_stoichiometry',
  INVALID_TEMPORAL_DURATION: 'invalid_temporal_duration',
  MISSING_OBSERVED_EXPR: 'missing_observed_expr',
  NULL_REACTION: 'null_reaction',
  // ---- subsystem-ref resolution (§4.7) ----
  // The canonical, cross-binding names, pinned by
  // `tests/invalid/expected_errors.json` (`subsystem_ref_not_found.esm`,
  // `subsystem_ref_ambiguous.esm`).
  //
  // `unresolved_subsystem_ref` — the reference does not resolve. Raised by the
  //   structural validator (which does no file I/O, so every `{ref}` reaching it
  //   is unresolved) and by the resolver when the file is genuinely missing.
  // `ambiguous_subsystem_ref` — the reference resolves to a file holding MORE
  //   than one top-level system; §4.7 requires exactly one. Only the resolver
  //   can raise this: it is the only layer that reads the referenced file.
  AMBIGUOUS_SUBSYSTEM_REF: 'ambiguous_subsystem_ref',
  UNDEFINED_DATA_LOADER_VARIABLE: 'undefined_data_loader_variable',
  UNDEFINED_PARAMETER: 'undefined_parameter',
  UNDEFINED_SPECIES: 'undefined_species',
  UNDEFINED_SYSTEM: 'undefined_system',
  UNDEFINED_VARIABLE: 'undefined_variable',
  UNIT_ERROR: 'unit_error',
  // A PROVABLE dimensional inconsistency (metres plus kilograms, log of a
  // dimensional quantity, an equation whose sides cannot agree).
  UNIT_INCONSISTENCY: 'unit_inconsistency',
  // A declared unit string that names no real unit ("not_a_unit"). Distinct
  // from UNIT_INCONSISTENCY: nothing was proved inconsistent — the declaration
  // is simply meaningless. Pinned by tests/invalid/unparseable_unit.esm.
  UNIT_PARSE_ERROR: 'unit_parse_error',
  // The internal UnitWarning code that validate() promotes to UNIT_PARSE_ERROR.
  // See UnitWarning.code in units.ts for the severity policy.
  UNPARSEABLE_UNIT: 'unparseable_unit',
  UNRESOLVED_SCOPED_REF: 'unresolved_scoped_ref',
  UNRESOLVED_SUBSYSTEM_REF: 'unresolved_subsystem_ref',

  // ---- validation: load-time exception wrappers (validate.ts#loadErrorCode
  //      and the inline JSON/unexpected guards) ----
  JSON_PARSE_ERROR: 'json_parse_error',
  UNEXPECTED_ERROR: 'unexpected_error',
  SCHEMA_VALIDATION_ERROR: 'schema_validation_error',
  PARSE_ERROR: 'parse_error',
  EXPRESSION_TEMPLATE_ERROR: 'expression_template_error',
  ENUM_LOWERING_ERROR: 'enum_lowering_error',
  NONFINITE_NUMBER: 'nonfinite_number',
  LOAD_ERROR: 'load_error',

  // ---- templates: §9.6 expression-template lowering + §9.7 template-library
  //      imports (lower-expression-templates.ts, template-imports.ts;
  //      EsmMachineryError codes) ----
  APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH: 'apply_expression_template_bindings_mismatch',
  APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION: 'apply_expression_template_invalid_declaration',
  APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY: 'apply_expression_template_recursive_body',
  APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE: 'apply_expression_template_unknown_template',
  APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD: 'apply_expression_template_version_too_old',
  REWRITE_RULE_NONTERMINATING: 'rewrite_rule_nonterminating',
  TEMPLATE_BODY_EXPANSION_TOO_DEEP: 'template_body_expansion_too_deep',
  TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET: 'template_constraint_unknown_index_set',
  METAPARAMETER_NAME_CONFLICT: 'metaparameter_name_conflict',
  METAPARAMETER_TYPE_ERROR: 'metaparameter_type_error',
  METAPARAMETER_UNBOUND: 'metaparameter_unbound',
  TEMPLATE_IMPORT_CYCLE: 'template_import_cycle',
  TEMPLATE_IMPORT_INDEX_SET_CONFLICT: 'template_import_index_set_conflict',
  TEMPLATE_IMPORT_IS_COUPLING_LIBRARY: 'template_import_is_coupling_library',
  TEMPLATE_IMPORT_NAME_CONFLICT: 'template_import_name_conflict',
  TEMPLATE_IMPORT_NOT_LIBRARY: 'template_import_not_library',
  TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME: 'template_import_rebind_unknown_name',
  TEMPLATE_IMPORT_RENAME_COLLISION: 'template_import_rename_collision',
  TEMPLATE_IMPORT_RENAME_INVALID: 'template_import_rename_invalid',
  TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME: 'template_import_rename_unknown_name',
  TEMPLATE_IMPORT_UNKNOWN_NAME: 'template_import_unknown_name',
  TEMPLATE_IMPORT_UNRESOLVED: 'template_import_unresolved',
  TEMPLATE_IMPORT_VERSION_TOO_OLD: 'template_import_version_too_old',
  TEMPLATE_INJECT_TARGET_IS_LOADER: 'template_inject_target_is_loader',
  TEMPLATE_INJECT_TARGET_NOT_COMPONENT: 'template_inject_target_not_component',
  TEMPLATE_INJECT_TARGET_UNKNOWN: 'template_inject_target_unknown',

  // ---- templates: geometry / makearray structural folds (also emitted from
  //      lower-expression-templates.ts during template lowering) ----
  GEOMETRY_MANIFOLD_INVALID: 'geometry_manifold_invalid',
  MAKEARRAY_REGION_INVERTED: 'makearray_region_inverted',

  // ---- subsystem refs (ref-loading.ts; EsmMachineryError codes raised
  //      while resolving `subsystem` references / library detection) ----
  SUBSYSTEM_INDEX_SET_CONFLICT: 'subsystem_index_set_conflict',
  SUBSYSTEM_REF_IS_COUPLING_LIBRARY: 'subsystem_ref_is_coupling_library',
  SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY: 'subsystem_ref_is_template_library',

  // ---- coupling: §9.7 coupling-library imports (coupling-imports.ts;
  //      EsmMachineryError codes) ----
  COUPLING_EDGE_UNKNOWN_ROLE: 'coupling_edge_unknown_role',
  COUPLING_IMPORT_BIND_NOT_A_COMPONENT: 'coupling_import_bind_not_a_component',
  COUPLING_IMPORT_NOT_LIBRARY: 'coupling_import_not_library',
  COUPLING_IMPORT_ROLE_UNBOUND: 'coupling_import_role_unbound',
  COUPLING_IMPORT_UNKNOWN_ROLE: 'coupling_import_unknown_role',
  COUPLING_IMPORT_UNRESOLVED: 'coupling_import_unresolved',
  COUPLING_LIBRARY_ILLEGAL_PAYLOAD: 'coupling_library_illegal_payload',
  COUPLING_LIBRARY_NESTED_IMPORT: 'coupling_library_nested_import',
  COUPLING_ROLE_UNUSED: 'coupling_role_unused',

  // ---- enums: §9.3 load-time enum lowering (lower-enums.ts;
  //      EnumLoweringError codes) ----
  ENUM_OP_MALFORMED: 'enum_op_malformed',
  ENUM_NOT_DECLARED: 'enum_not_declared',
  ENUM_MEMBER_NOT_FOUND: 'enum_member_not_found',

  // ---- closed-functions: §9.2 closed function registry (closed-functions.ts;
  //      ClosedFunctionError codes) ----
  UNKNOWN_CLOSED_FUNCTION: 'unknown_closed_function',
  CLOSED_FUNCTION_ARITY: 'closed_function_arity',
  CLOSED_FUNCTION_OVERFLOW: 'closed_function_overflow',
} as const

/** A diagnostic code string from {@link ERROR_CODES}. */
export type ErrorCode = (typeof ERROR_CODES)[keyof typeof ERROR_CODES]

/**
 * Neutral base for EarthSciAST diagnostics: an `Error` carrying a stable `code`
 * string (from {@link ERROR_CODES}) and optional structured `details`. This is
 * purely additive — a single home for future diagnostics. It intentionally does
 * NOT touch the existing `EsmMachineryError` / `EnumLoweringError` /
 * `ClosedFunctionError` classes, which another file owns.
 */
export class EsmDiagnosticError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly details?: Record<string, unknown>,
  ) {
    super(message)
    this.name = 'EsmDiagnosticError'
  }
}
