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
  // ---- F-6 static aggregate / coupling semantics (model-checks.ts,
  //      coupling-checks.ts). Statically decidable from the SINGLE document,
  //      pinned as STRUCTURAL findings by tests/invalid/expected_errors.json.
  //      Values coordinated across all bindings (Julia/Rust/Python/Go/TS). ----
  //
  // `join_key_invalid_type` — a `faq` value-equality `join` whose key
  //   columns come from a categorical index set with a FLOAT or NULL member
  //   (floats aren't portably equality-comparable; null is unmatchable).
  //   RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1.
  JOIN_KEY_INVALID_TYPE: 'join_key_invalid_type',
  // `join_side_ambiguous` — an `on` key for which the DOCUMENT does not
  //   determine a range symbol: its index set is drawn by more than one of the
  //   node's ranges and the clause names no `syms`. CONFORMANCE_SPEC §5.5.8.
  JOIN_SIDE_AMBIGUOUS: 'join_side_ambiguous',
  // `join_syms_unknown_symbol` — a `join.syms` entry that is not a range symbol
  //   of the node. CONFORMANCE_SPEC §5.5.8.
  JOIN_SYMS_UNKNOWN_SYMBOL: 'join_syms_unknown_symbol',
  // `domain_unit_mismatch` — an `identity`-transform `variable_map` coupling
  //   whose `from`/`to` variables carry declared, non-empty, DIFFERENT units
  //   (esm-spec §4.7.6). `param_to_var` / `conversion_factor` are exempt.
  DOMAIN_UNIT_MISMATCH: 'domain_unit_mismatch',
  // `couple_multiplicative_no_tendency` — a `couple` connector equation whose
  //   `transform` is `multiplicative` names a `to` target with no `D(to)`
  //   tendency in the flattened system: a parameter, an observed, an algebraic
  //   unknown, or an undefined name. esm-spec §10.3 and esm-libraries-spec
  //   §4.7.2 both define `multiplicative` against the target's EXISTING ODE RHS,
  //   so there is nothing to multiply and the operation has no meaning. A
  //   library MUST raise rather than silently drop the connector equation —
  //   dropping it is a wrong answer delivered quietly: the document declares a
  //   coupling, the flattened system carries no trace of it, and nothing
  //   downstream can tell "applied" from "ignored". `additive` deliberately has
  //   NO counterpart code, and the asymmetry is intentional: zero is the
  //   additive identity, so an additive term against an absent tendency simply
  //   BECOMES the tendency; no multiplicative identity gives the degenerate
  //   case a corresponding meaning. Raised from flatten.ts as
  //   CoupleMultiplicativeNoTendencyError.
  COUPLE_MULTIPLICATIVE_NO_TENDENCY: 'couple_multiplicative_no_tendency',
  // `operator_compose_no_merge` — ERROR (esm-libraries-spec §4.7.1 step 5). An
  //   `operator_compose` entry merged NONE of the equations `systems[1]`
  //   authored, which makes it indistinguishable from an entry that is not
  //   there: the operator integrates a private decoupled system from its own
  //   defaults, the other system receives no contribution, and the only evidence
  //   is a state count one too high. An operator that genuinely contributes only
  //   states of its own declares that with `require_match: false` and is then
  //   permitted. Raised from flatten.ts as OperatorComposeNoMergeError.
  OPERATOR_COMPOSE_NO_MERGE: 'operator_compose_no_merge',
  // `operator_compose_partial_merge` — WARNING. Some but not all of
  //   `systems[1]`'s equations landed. Unlike a zero merge this is
  //   indistinguishable from an operator that legitimately contributes states of
  //   its own ALONGSIDE the ones it does merge, so the format cannot call it a
  //   defect; an author who knows better says so with `require_match`.
  OPERATOR_COMPOSE_PARTIAL_MERGE: 'operator_compose_partial_merge',
  // `operator_compose_require_match_unmatched` — an `operator_compose` entry
  //   declared `require_match: true` and one of `systems[1]`'s equations found
  //   no equation of `systems[0]` to land on. A PARTIAL match fails too: there
  //   is no "some is enough" reading an author could rely on. Raised from
  //   flatten.ts as OperatorComposeRequireMatchError.
  OPERATOR_COMPOSE_REQUIRE_MATCH_UNMATCHED: 'operator_compose_require_match_unmatched',
  // `operator_compose_ambiguous_bare_name` — the bare-name fallback (§4.7.1
  //   step 3) would unify two STATE variables. Each carries its own INITIAL
  //   CONDITION and the merge keeps only one, so the choice decides what the
  //   flattened system integrates from — and the document, which bound them on a
  //   shared local name alone, has not expressed it. Deciding it silently is how
  //   flipping an entry's `systems` order came to change the answer. A match
  //   where only ONE side is a state is not ambiguous: the state owns the
  //   quantity. Raised from flatten.ts as OperatorComposeAmbiguousBareNameError.
  OPERATOR_COMPOSE_AMBIGUOUS_BARE_NAME: 'operator_compose_ambiguous_bare_name',
  // `relational_node_in_continuous` — a relational / value-invention
  //   `faq` (`distinct: true` under `bool_and_or`) whose `key`/`expr`
  //   reads a declared STATE variable, so the cadence partition would class the
  //   node CONTINUOUS — forbidden on the hot path (CONFORMANCE_SPEC §5.7 guard 2).
  RELATIONAL_NODE_IN_CONTINUOUS: 'relational_node_in_continuous',
  // `undefined_index_set` — a `faq` `ranges` entry `{ from: NAME }`
  //   naming an index set absent from the document `index_sets` registry
  //   (RFC semiring-faq-unified-ir §5.2; no implicit interval is inferred).
  UNDEFINED_INDEX_SET: 'undefined_index_set',
  // `invalid_broadcast_fn` — a `broadcast` node's `fn` is absent, does not name
  //   a SCALAR operator, or is applied to an argument count that operator's
  //   §4.2 arity does not admit (esm-spec §4.3.4 / §9.6.6). The value analogue
  //   of `unknown_closed_function`: `broadcast` is the one op whose OPERATOR is
  //   carried as data, so no `op`-keyed check reaches it and an unchecked `fn`
  //   is discarded silently rather than failing. Loading MUST fail.
  INVALID_BROADCAST_FN: 'invalid_broadcast_fn',
  // `array_shape_mismatch` — an operand of an array-level expression is
  //   declared over an index set the result is not shaped over (esm-spec
  //   §4.3.4 / CONFORMANCE_SPEC §7.1). Operands align by index-set NAME: one
  //   declared over a SUBSET of the result's sets broadcasts along the missing
  //   axes and axis ORDER is immaterial, but one carrying an EXTRA set has no
  //   axis to align to. Both shapes are declared, so this is static — a hard
  //   error, not a warning and not a runtime concern.
  ARRAY_SHAPE_MISMATCH: 'array_shape_mismatch',
  // `observed_cycle` — a dependency cycle among a model's OBSERVED unknowns
  //   (esm-spec §4.9.6): each observed on the cycle is defined by an equation
  //   whose RHS names the next, so no evaluation order satisfies every
  //   definition. Decidable from the equations alone — no shapes, no values, no
  //   solver — so it is a HARD error at the structural layer in every binding,
  //   executing or not, rather than a surprise at build time.
  //   Pinned at `/models/<M>`: a cycle belongs to no single equation, exactly as
  //   `equation_count_mismatch` belongs to no single one. `details.cycle` is the
  //   path in traversal order with the entry node repeated to close it — a PATH,
  //   so it is ordered semantically rather than by the §7.1.0 sort.
  //   The self-edge of a §4.3.1.1 recurrence CANDIDATE is not one of these edges
  //   and is dropped; every other self-reference (a scalar `x ~ x + 1`, a bare
  //   `s ~ s + 1`) has no axis to fold along, is a cycle of length one, and IS
  //   reported here. Distinct from `circular_dependency`, which is a cycle among
  //   MODELS reached through scoped references.
  OBSERVED_CYCLE: 'observed_cycle',
  // `recurrence_not_wellfounded` — a causal self-read (esm-spec §4.3.1.1) that
  //   is not strictly earlier along exactly ONE of its aggregate's output axes:
  //   a read provably at the same cell or later on its axis (`k`, `k+c`), an
  //   index argument that is not affine in its frame symbol with coefficient 1
  //   (a bare constant, `2*k`, another axis's symbol), an offset on more than
  //   one axis, two self-reads disagreeing on the axis, or a BARE read of the
  //   variable in its own RHS (which names the whole array, and the whole array
  //   does not exist while the recurrence sweeps it).
  //   Hard error in EVERY binding, executing or not (CONFORMANCE_SPEC §5.19.5):
  //   this binding evaluates no array numerics, and rejection parity is the one
  //   part of the construct it implements. The pre-1.0 behaviour was a
  //   plausible WRONG NUMBER, which is why none of these is a warning.
  RECURRENCE_NOT_WELLFOUNDED: 'recurrence_not_wellfounded',
  // `recurrence_unsupported_form` — a causal self-read the format cannot
  //   SEQUENCE, as opposed to one it can prove wrong (esm-spec §4.3.1.1). Two
  //   shapes: the self-read is reachable only through a construct whose operand
  //   is consumed WHOLE — a `makearray` region value, or a `reshape` /
  //   `transpose` / `concat` / `broadcast` / `apply_expression_template` operand
  //   — so no cell-by-cell sweep can supply it; or the equation declares no cell
  //   frame to sweep (its RHS is not a `faq` over the variable's axes and
  //   its LHS is not the §4.3 indexed-aggregate form).
  //   The `makearray` case is worth naming separately because §4.3.2's overlap
  //   rule ("later entries overwrite earlier ones") reads like a licence to
  //   define cell `k` from cell `k-1`. It is not: region order fixes which write
  //   WINS, not the order cells are EVALUATED in, and a region's value
  //   expression is evaluated once for the whole region.
  RECURRENCE_UNSUPPORTED_FORM: 'recurrence_unsupported_form',
  EQUATION_COUNT_MISMATCH: 'equation_count_mismatch',
  // `event_affects_parameter` — an event `affects` LHS names a PARAMETER
  //   (esm-spec §5.4). From 1.0.0 events affect UNKNOWNS ONLY: a parameter that
  //   changes during a run declares its own `update` block, so the
  //   `discrete_parameters` list and the event `functional_affect` are gone and
  //   there is nothing left for an event to write a parameter through. Fires
  //   from a model `discrete_events` / `continuous_events` block or from an
  //   `event` coupling entry — it keys off the AFFECTS TARGET, not the trigger.
  //   Replaces `invalid_discrete_param` and `undeclared_discrete_parameter`,
  //   which asked whether a parameter was correctly DECLARED on a list that no
  //   longer exists; touching a parameter from an event is now wrong outright.
  EVENT_AFFECTS_PARAMETER: 'event_affects_parameter',
  EVENT_VAR_UNDECLARED: 'event_var_undeclared',
  FACTOR_WITH_EXPRESSION_TRANSFORM: 'factor_with_expression_transform',
  IC_IN_REACTION_SYSTEM: 'ic_in_reaction_system',
  INVALID_STOICHIOMETRY: 'invalid_stoichiometry',
  INVALID_TEMPORAL_DURATION: 'invalid_temporal_duration',
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
  // `data_source_undefined` — a parameter's `update.source` names no entry in
  //   the document's top-level `data_sources`. From 1.0.0 a data source is not
  //   a coupling endpoint, so `update.source` is the ONLY way to name one — and
  //   being an ordinary string it is schema-valid by construction, which is
  //   what makes this reachable structural validation rather than a schema
  //   error. Replaces `undefined_data_loader_variable`, whose coupling-to-a-
  //   loader-variable shape no longer exists.
  DATA_SOURCE_UNDEFINED: 'data_source_undefined',
  // `data_source_url_unresolved` — a `data_sources[*].source.url_template` (or
  //   a `mirrors` entry) cannot be resolved to a URL at load time (esm-spec
  //   §8.2.1). Raised for an unexpanded `${VAR}` — §8.2 does not expand
  //   environment variables into a source's location at all — and for a
  //   resolved path carrying a `?` or `#`. The message names the offending data
  //   source and template: the failure it replaces was an "io error at
  //   /${VAR}/x.parquet" that named neither, one step away from a source that
  //   silently delivered a consuming parameter's default.
  DATA_SOURCE_URL_UNRESOLVED: 'data_source_url_unresolved',
  // A declaration — a `variables` key, a species, or a reaction parameter —
  //   spelled with a GLOBALLY-SCOPED name: the document's independent variable
  //   (`domain.independent_variable`, default `"t"`) or the §6.4 `_var`
  //   placeholder (esm-spec §4.9.1.1). Both are in scope in every component and
  //   resolve BY NAME ahead of the declaration maps, so the declaration is
  //   unreachable and every reader silently receives the implicit symbol
  //   instead — the simulation clock in place of the declared quantity.
  RESERVED_VARIABLE_NAME: 'reserved_variable_name',
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

  // ---- solver hints: §2.2 document-scoped solver block (solver.ts;
  //      EsmMachineryError code) ----
  SOLVER_VERSION_TOO_OLD: 'solver_version_too_old',

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
  // A SURVIVING registry body that names a variable a COUPLING rule rewrote out
  //   of the flattened equations -- a `variable_map` substitution target, or a
  //   name an `operator_compose` renaming match merged away
  //   (esm-libraries-spec §4.7.1 step 4). The body is a shadow copy of authored
  //   source that expands at the BUILD boundary, so it would expand into a name
  //   the flattened system no longer declares. Refused rather than rewritten,
  //   because rewriting authored source would diverge from the expand-at-load
  //   image (CONFORMANCE_SPEC §5.35). Raised by `flatten.ts`.
  TEMPLATE_BODY_REFERENCES_COUPLING_REWRITTEN_VARIABLE:
    'template_body_references_coupling_rewritten_variable',
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
  TEMPLATE_INJECT_TARGET_NOT_COMPONENT: 'template_inject_target_not_component',
  TEMPLATE_INJECT_TARGET_UNKNOWN: 'template_inject_target_unknown',

  // ---- templates: geometry / makearray structural folds (also emitted from
  //      lower-expression-templates.ts during template lowering) ----
  GEOMETRY_MANIFOLD_INVALID: 'geometry_manifold_invalid',
  MAKEARRAY_REGION_INVERTED: 'makearray_region_inverted',

  // ---- subsystem refs (ref-loading.ts; EsmMachineryError codes raised
  //      while resolving `subsystem` references / library detection) ----
  SUBSYSTEM_INDEX_SET_CONFLICT: 'subsystem_index_set_conflict',
  SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME: 'subsystem_index_set_rename_unknown_name',
  SUBSYSTEM_INDEX_SET_RENAME_UNSUPPORTED_MOUNT_FORM:
    'subsystem_index_set_rename_unsupported_mount_form',
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

  // ---- function tables: §9.5.3 `table_lookup` lowering (lower-table-lookups.ts;
  //      TableLookupLoweringError codes, named by esm-spec §9.5.5) ----
  TABLE_LOOKUP_UNKNOWN_TABLE: 'table_lookup_unknown_table',
  TABLE_LOOKUP_AXIS_NAME_MISMATCH: 'table_lookup_axis_name_mismatch',
  TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE: 'table_lookup_output_out_of_range',
  TABLE_INTERPOLATION_AXES_MISMATCH: 'table_interpolation_axes_mismatch',
  TABLE_DATA_SHAPE_MISMATCH: 'table_data_shape_mismatch',
  TABLE_AXIS_NAN: 'table_axis_nan',
  // `table_out_of_bounds_unsupported` — esm-spec §9.5.3a. `out_of_bounds:
  //   "error"` is "conformant when implemented" (§9.5.1) and this binding does
  //   not implement it. Lowering such a table to the clamping `interp.*` form
  //   anyway would answer in a mode the author did not ask for, with nothing in
  //   the result to say so, so the lookup is REFUSED at the point it would
  //   otherwise lower. Loading and round-tripping are unaffected.
  TABLE_OUT_OF_BOUNDS_UNSUPPORTED: 'table_out_of_bounds_unsupported',

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
