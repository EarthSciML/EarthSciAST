package esm

// codes.go is the single home for this binding's diagnostic-code vocabulary,
// plus the spec enum literals (variable types, op names, system kinds, render
// formats, the default independent variable) that are otherwise typed by hand
// at dozens of sites.
//
// It holds the stable §9.6.6 / §10.11 diagnostic codes the audit flagged as
// repeated across the package (metaparameter_type_error appears 21×,
// template_import_unresolved 10×, template_import_unknown_name 10×,
// template_import_name_conflict 10×, coupling_library_illegal_payload 6×) AND
// the structural-validation codes — including the `Error*` block that used to
// be declared in validate.go, moved here verbatim (same names, same values, so
// no wire-visible change) so that a reader looking for "what codes can this
// binding emit" has exactly one file to open. Every declaration below is
// referenced from its call sites; none is spelled as a bare literal any more.
//
// It is at parity with the peer bindings' single registries — TypeScript's
// ERROR_CODES and Python's ErrorCode — and holds every code raised through
// newETErr (the §9.6 expression-template, §9.7 template-import/metaparameter,
// §10.9-§10.11 coupling-library and §4.7 subsystem-ref vocabularies), which are
// a cross-binding wire contract and must stay spelled identically everywhere.
//
// Still declared next to the logic that raises them, deliberately, because each
// is a self-contained subsystem vocabulary documented against that subsystem's
// rules rather than against the shared vocabulary: cadence.go's CodeCadence*,
// edit.go's CodeEdit*, reference_graph.go's CodeRef*, op_registry.go's
// CodeInvalidBroadcastFn, units.go's UnitFinding*, validate_static_checks.go's
// four F-6 codes and validate_array_shapes.go's CodeArrayShapeMismatch (whose
// file headers enumerate them), and the non-code literal sets
// (lower_expression_templates.go's applyExpressionTemplateOp,
// template_imports.go's templateComponentKinds, the geometryManifold* sets).

// --- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters
// (raised via newETErr from template_imports.go and subsystem_ref.go). ---
const (
	CodeMetaparamTypeError         = "metaparameter_type_error"
	CodeTemplateImportUnresolved   = "template_import_unresolved"
	CodeTemplateImportUnknownName  = "template_import_unknown_name"
	CodeTemplateImportNameConflict = "template_import_name_conflict"
	CodeTemplateImportCycle        = "template_import_cycle"

	// CodeTemplateImportVersionTooOld: a file declaring esm < 0.8.0 carries
	// `expression_template_imports`, top-level `expression_templates`, or
	// `metaparameters` (esm-spec §9.6.5).
	CodeTemplateImportVersionTooOld = "template_import_version_too_old"
	// CodeTemplateImportIndexSetConflict: a merged `index_sets` name collides
	// with a non-deep-equal definition (esm-spec §9.7.5). This binding does not
	// raise it yet; the constant exists because the §9.6.6 table is
	// cross-language uniform.
	CodeTemplateImportIndexSetConflict = "template_import_index_set_conflict"

	// CodeTemplateImportNotLibrary: an `import` resolves to a file that is not a
	// template library (it declares components, or declares no
	// `expression_templates` / `coupling_roles` block at all).
	CodeTemplateImportNotLibrary = "template_import_not_library"
	// CodeTemplateImportIsCouplingLibrary: a template `import` resolves to a
	// COUPLING library (§10.9). The two library kinds are imported through
	// different blocks and are not interchangeable.
	CodeTemplateImportIsCouplingLibrary = "template_import_is_coupling_library"
	// CodeTemplateLibraryIllegalPayload: a document carries top-level
	// `expression_templates` beside `models` / `reaction_systems` /
	// `data_sources` / `coupling` / `domain`, which a template-library file
	// never declares (esm-spec §9.7.1).
	CodeTemplateLibraryIllegalPayload = "template_library_illegal_payload"
	// CodeTemplateImportRenameInvalid: an import's `rename` / `rebind` entry is
	// malformed — not an object, or an entry whose key or value is not a
	// non-empty string.
	CodeTemplateImportRenameInvalid = "template_import_rename_invalid"
	// CodeTemplateImportRenameUnknownName: a `rename` key names nothing the
	// imported library exports.
	CodeTemplateImportRenameUnknownName = "template_import_rename_unknown_name"
	// CodeTemplateImportRenameCollision: a `rename` target collides with a name
	// already in scope (another import's export, or a local declaration).
	CodeTemplateImportRenameCollision = "template_import_rename_collision"
	// CodeTemplateImportRebindUnknownName: a `rebind` key names no metaparameter
	// the imported library declares.
	CodeTemplateImportRebindUnknownName = "template_import_rebind_unknown_name"
	// CodeTemplateInjectTargetUnknown: an injection `target` names a component
	// the document does not declare.
	CodeTemplateInjectTargetUnknown = "template_inject_target_unknown"
	// CodeTemplateInjectTargetNotComponent: an injection `target` resolves to
	// something that is not an injectable component.
	CodeTemplateInjectTargetNotComponent = "template_inject_target_not_component"

	// CodeMetaparamUnbound: a metaparameter reachable in an expanded template
	// body has no binding — neither from the `metaparameters` block nor from an
	// import's `rebind` (esm-spec §9.6.6).
	CodeMetaparamUnbound = "metaparameter_unbound"
	// CodeMetaparamNameConflict: a metaparameter name collides with a name
	// already bound in the scope the template expands into (esm-spec §9.6.6).
	CodeMetaparamNameConflict = "metaparameter_name_conflict"
)

// --- Diagnostic codes: §9.6 expression templates — declaration, application
// and body expansion (raised via newETErr from lower_expression_templates.go,
// out_of_line_templates.go and template_compose.go). ---
const (
	// CodeApplyExpressionTemplateInvalidDeclaration: an
	// `apply_expression_template` node is structurally malformed — a missing or
	// non-string `template`, a `bindings` payload that is not an object, or a
	// binding entry whose key is not a non-empty string.
	CodeApplyExpressionTemplateInvalidDeclaration = "apply_expression_template_invalid_declaration"
	// CodeApplyExpressionTemplateUnknownTemplate: an
	// `apply_expression_template` names a template neither declared locally nor
	// exported by any import in scope.
	CodeApplyExpressionTemplateUnknownTemplate = "apply_expression_template_unknown_template"
	// CodeApplyExpressionTemplateBindingsMismatch: the supplied `bindings` do
	// not match the template's declared parameters — a missing parameter, or a
	// binding naming a parameter the template does not declare.
	CodeApplyExpressionTemplateBindingsMismatch = "apply_expression_template_bindings_mismatch"
	// CodeApplyExpressionTemplateRecursiveBody: a template's body applies the
	// template itself, directly or through a cycle of applications.
	CodeApplyExpressionTemplateRecursiveBody = "apply_expression_template_recursive_body"
	// CodeTemplateBodyExpansionTooDeep: nested template application exceeded the
	// expansion depth budget — the non-cyclic guard against unbounded growth.
	CodeTemplateBodyExpansionTooDeep = "template_body_expansion_too_deep"
	// CodeTemplateConstraintUnknownIndexSet: a template's `constraints` entry
	// names an index set absent from the document `index_sets` registry.
	CodeTemplateConstraintUnknownIndexSet = "template_constraint_unknown_index_set"
	// CodeTemplateBodyReferencesCouplingRewrittenVariable: a SURVIVING
	// registry body names a variable a coupling rule rewrote out of the
	// flattened equations — a `variable_map`'s substituted target, or a
	// spelling an `operator_compose` renaming match deleted (esm-spec §9.6.4,
	// CONFORMANCE_SPEC §5.35). The body is authored source no equation walk
	// reaches, and it expands at the BUILD boundary, so it is REFUSED rather
	// than resolved: rewriting it would silently diverge from the
	// expand-at-load image of the same document.
	CodeTemplateBodyReferencesCouplingRewrittenVariable = "template_body_references_coupling_rewritten_variable"
	// CodeAmbiguousOutputName: an output name that matches no variable exactly
	// and whose last dotted segment is shared by more than one variable
	// (CONFORMANCE_SPEC §5.17.4). This binding has no output derivation; the
	// constant exists because the code vocabulary is uniform across bindings.
	CodeAmbiguousOutputName = "ambiguous_output_name"
	// CodeMakearrayRegionInverted: a `makearray` region's stop precedes its
	// start, so the region denotes no cells (esm-spec §4.3.5).
	CodeMakearrayRegionInverted = "makearray_region_inverted"
	// CodeGeometryManifoldInvalid: a geometry kernel declares a manifold that is
	// not one of the spec's manifold kinds, or one inconsistent with the
	// coordinates it is given.
	CodeGeometryManifoldInvalid = "geometry_manifold_invalid"
	// CodeApplyExpressionTemplateVersionTooOld: a file declaring esm < 0.4.0
	// carries `expression_templates` or `apply_expression_template`.
	CodeApplyExpressionTemplateVersionTooOld = "apply_expression_template_version_too_old"
	// CodeRewriteRuleNonterminating: the rewrite fixpoint did not converge
	// within MAX_REWRITE_PASSES passes (esm-spec §9.6.3).
	CodeRewriteRuleNonterminating = "rewrite_rule_nonterminating"
	// CodeSolverVersionTooOld: a top-level `solver` block in a file declaring
	// esm < 1.1.0 (esm-spec §2.2.4).
	CodeSolverVersionTooOld = "solver_version_too_old"
)

// --- Diagnostic codes: §10.9-§10.11 coupling libraries / coupling_import
// (raised via newETErr from coupling_imports.go). ---
const (
	// CodeCouplingLibraryIllegalPayload: a coupling library file carries a
	// payload §10.11 forbids there (a component, a non-`coupling_roles` block,
	// or a role entry of the wrong shape).
	CodeCouplingLibraryIllegalPayload = "coupling_library_illegal_payload"
	// CodeCouplingLibraryNestedImport: a coupling library itself declares a
	// coupling `import`; §10.11 admits no nesting.
	CodeCouplingLibraryNestedImport = "coupling_library_nested_import"
	// CodeCouplingImportUnresolved: a `coupling_import` names a file that does
	// not exist, is not readable, or was never resolved before use.
	CodeCouplingImportUnresolved = "coupling_import_unresolved"
	// CodeCouplingImportNotLibrary: a `coupling_import` resolves to a file that
	// is not a coupling library.
	CodeCouplingImportNotLibrary = "coupling_import_not_library"
	// CodeCouplingImportUnknownRole: a `coupling_import` binds a role the
	// imported library does not declare.
	CodeCouplingImportUnknownRole = "coupling_import_unknown_role"
	// CodeCouplingImportRoleUnbound: a role the imported library declares is
	// left unbound by the importing document.
	CodeCouplingImportRoleUnbound = "coupling_import_role_unbound"
	// CodeCouplingImportBindNotAComponent: a role binding names something that
	// is not a component of the importing document.
	CodeCouplingImportBindNotAComponent = "coupling_import_bind_not_a_component"
	// CodeCouplingEdgeUnknownRole: a coupling edge inside the library references
	// a role name the library does not declare.
	CodeCouplingEdgeUnknownRole = "coupling_edge_unknown_role"
	// CodeCouplingRoleUnused: a role the library declares is referenced by none
	// of its coupling edges, so binding it could have no effect.
	CodeCouplingRoleUnused = "coupling_role_unused"
)

// --- Diagnostic codes: §4.8.5 declared units on a `const` node (raised via
// newETErr from units.go). ---
const (
	// CodeConstUnitsVersionTooOld: a document declaring esm < 1.2.0 carries
	// `units` on an expression node.
	CodeConstUnitsVersionTooOld = "const_units_version_too_old"
)

// --- Diagnostic codes: §10.3 / esm-libraries-spec §4.7.2 `couple` connector
// semantics (raised from flatten.go's applyCouple). ---
const (
	// CodeCoupleMultiplicativeNoTendency: a `couple` connector equation applies
	// the `multiplicative` transform to a `to` target that has no `D(to)`
	// equation in the flattened system — a parameter, an observed, an algebraic
	// unknown, or an undefined name. Both esm-spec §10.3 and §4.7.2 define
	// `multiplicative` against the target's EXISTING ODE right-hand side, so
	// there is nothing to multiply and the operation has no meaning. Silently
	// dropping the connector equation — what this binding did before — is the
	// one outcome a coupling mis-specification must not have: the document
	// declares a coupling and the flattened system carries no trace of it.
	//
	// `additive` deliberately has NO counterpart code: zero is the additive
	// identity, so an additive term against an absent tendency simply becomes
	// the tendency. There is no multiplicative identity that would do the same.
	CodeCoupleMultiplicativeNoTendency = "couple_multiplicative_no_tendency"

	// CodeOperatorComposeNoMerge is an ERROR (esm-libraries-spec §4.7.1 step 5):
	// an `operator_compose` entry merged NONE of the equations Systems[1]
	// authored, which makes it indistinguishable from an entry that is not
	// there — the operator integrates a private decoupled system from its own
	// defaults, the other system receives no contribution, and the only evidence
	// is a state count one too high. An operator that genuinely contributes only
	// states of its own declares that with `require_match: false` and is then
	// permitted.
	CodeOperatorComposeNoMerge = "operator_compose_no_merge"
	// CodeOperatorComposePartialMerge is WARNING-level: some but not all of
	// Systems[1]'s equations landed. Unlike a zero merge this is
	// indistinguishable from an operator that legitimately contributes states of
	// its own ALONGSIDE the ones it does merge, so the format cannot call it a
	// defect; an author who knows better says so with `require_match`.
	CodeOperatorComposePartialMerge = "operator_compose_partial_merge"

	// CodeOperatorComposeAmbiguousBareName: the bare-name fallback (§4.7.1
	// step 3) would unify two STATE variables. Each carries its own INITIAL
	// CONDITION and the merge keeps only one, so the choice decides what the
	// flattened system integrates from — and the document, which bound them on a
	// shared local name alone, has not expressed it. Deciding it silently is how
	// flipping an entry's `systems` order came to change the answer. A match
	// where only ONE side is a state is not ambiguous: the state owns it.
	CodeOperatorComposeAmbiguousBareName = "operator_compose_ambiguous_bare_name"

	// CodeOperatorComposeRequireMatchUnmatched: an `operator_compose` entry
	// declared `require_match: true` and one of Systems[1]'s equations found no
	// equation of Systems[0] to land on (esm-libraries-spec §4.7.1 step 5). A
	// PARTIAL match fails too: there is no "some is enough" reading an author
	// could rely on — the seven-of-twelve-species case is exactly the defect the
	// flag exists to catch. Refused at FLATTEN, not at validate: the document is
	// schema-valid and structurally valid, and only the merge knows the answer.
	CodeOperatorComposeRequireMatchUnmatched = "operator_compose_require_match_unmatched"
)

// --- Diagnostic codes: §4.7 subsystem refs. Shared with the structural
// validator, which reports the same two conditions for a document whose refs
// were never resolved (tests/invalid/subsystem_ref_not_found.esm,
// subsystem_ref_ambiguous.esm; the names are pinned by
// tests/invalid/expected_errors.json). ---
const (
	// CodeUnresolvedSubsystemRef: a subsystem `ref` names a file that does not
	// exist / is not readable, or that was never resolved before validation.
	CodeUnresolvedSubsystemRef = "unresolved_subsystem_ref"
	// CodeAmbiguousSubsystemRef: a subsystem `ref` resolves to a file holding
	// other than exactly one top-level system; §4.7 requires exactly one.
	CodeAmbiguousSubsystemRef = "ambiguous_subsystem_ref"
	// CodeSubsystemRefIsTemplateLibrary: a subsystem `ref` resolves to a
	// TEMPLATE library (§9.7) rather than to a document declaring a system.
	CodeSubsystemRefIsTemplateLibrary = "subsystem_ref_is_template_library"
	// CodeSubsystemRefIsCouplingLibrary: a subsystem `ref` resolves to a
	// COUPLING library (§10.9) rather than to a document declaring a system.
	CodeSubsystemRefIsCouplingLibrary = "subsystem_ref_is_coupling_library"
	// CodeSubsystemIndexSetConflict: a referenced subsystem declares an index
	// set that conflicts with a same-named set already in the parent document.
	CodeSubsystemIndexSetConflict = "subsystem_index_set_conflict"
	// CodeSubsystemIndexSetRenameUnknownName: a mount edge's
	// `index_set_rename` names an index set the RESOLVED mounted document does
	// not declare (esm-spec §4.7 "Mount-edge index-set renaming") — the
	// mount-edge mirror of `template_import_rename_unknown_name`.
	CodeSubsystemIndexSetRenameUnknownName = "subsystem_index_set_rename_unknown_name"
	// CodeSubsystemIndexSetRenameUnsupportedMountForm: `index_set_rename` on a
	// mount form that does not implement it (esm-spec §4.7 "Mount-edge
	// index-set renaming", "Where it applies"). The field is a legal
	// `SubsystemRef` property at either mount form, but a binding whose
	// top-level `models.<k>` `{ref}` inliner cannot apply it MUST say so rather
	// than merge the leaf under its pre-rename axis names. Go does not inline a
	// top-level `{ref}` at all, so it never raises this; the constant exists
	// because the code table is cross-language uniform.
	CodeSubsystemIndexSetRenameUnsupportedMountForm = "subsystem_index_set_rename_unsupported_mount_form"

	// CodeMountFormUnsupported: a §4.7 `{ref}` mount at a form this binding does
	// not implement — here, a top-level `reaction_systems.<k>` `{ref}` (esm-spec
	// §4.7 "Two mount forms, one mechanism"). Refused at load, pointing at the
	// entry, rather than decoded as an empty reaction system.
	CodeMountFormUnsupported = "mount_form_unsupported"
)

// --- Diagnostic codes: running an arrayed definition (esm-spec §6.3.1). ---
const (
	// CodeIndexedDefinitionUnsupportedForm: a bare-index observed definition
	// `index(V, k…) ~ rhs` outside the runnable form (the RHS is not a `faq`
	// whose `output_idx` names the subscripts in order), refused when a
	// simulating binding builds the model. Go does not simulate, so it never
	// raises this; the constant exists because the code table is
	// cross-language uniform.
	CodeIndexedDefinitionUnsupportedForm = "indexed_definition_unsupported_form"
)

// --- Diagnostic codes: structural validation, per ESM Libraries Spec Section
// 3.4. Moved here verbatim from validate.go, where this block used to be
// declared; the names and values are unchanged and are pinned by
// tests/invalid/expected_errors.json. ---
const (
	ErrorEquationCountMismatch = "equation_count_mismatch"
	ErrorUndefinedVariable     = "undefined_variable"
	ErrorUndefinedSpecies      = "undefined_species"
	// ErrorUndefinedParameter is reserved for a future undeclared-parameter
	// diagnostic; no check emits it yet (kept for cross-binding code parity).
	ErrorUndefinedParameter  = "undefined_parameter"
	ErrorUndefinedSystem     = "undefined_system"
	ErrorUndefinedOperator   = "undefined_operator"
	ErrorUnresolvedScopedRef = "unresolved_scoped_ref"
	// ErrorEventAffectsParameter is raised when an event `affects` LHS names a
	// PARAMETER. From esm 1.0.0 events affect unknowns only: a parameter that
	// changes during a run carries its own `update` block (esm-spec §5.4), so
	// there is no `discrete_parameters` list to be missing from and the write is
	// wrong outright rather than wrong-unless-declared. It replaces both
	// `invalid_discrete_param` and `undeclared_discrete_parameter`.
	ErrorEventAffectsParameter = "event_affects_parameter"
	// ErrorDataSourceUndefined is raised when a parameter's `update.source` names
	// no declared `data_sources` entry (esm-spec §8.5).
	ErrorDataSourceUndefined = "data_source_undefined"
	// ErrorSystemKindMismatch is raised when a model's declared `system_kind`
	// contradicts the esm-spec §6.3.1 derivation.
	ErrorSystemKindMismatch = "system_kind_mismatch"
	ErrorNullReaction       = "null_reaction"
	ErrorEventVarUndeclared = "event_var_undeclared"
	ErrorUnitInconsistency  = "unit_inconsistency"
	ErrorICInReactionSystem = "ic_in_reaction_system"
	// ErrorUnitParseError is a declared unit string that denotes no real unit
	// ("not_a_unit"). It is a defect in the FILE — a hard error, distinct from
	// `unit_inconsistency` (a provable dimensional mismatch between two
	// resolvable units) — and is the code the shared corpus pins for
	// tests/invalid/unparseable_unit.esm.
	ErrorUnitParseError = "unit_parse_error"
	// ErrorCircularDependency is a cycle in the cross-model reference graph:
	// ModelA's equations reference ModelB's variables and vice versa
	// (tests/invalid/circular_coupling.esm).
	ErrorCircularDependency = "circular_dependency"
	// ErrorReservedVariableName is a DECLARATION — a `variables` key, a species,
	// or a reaction parameter — spelled with a globally-scoped name: the
	// document's independent variable (`domain.independent_variable`, default
	// "t") or the §6.4 `_var` placeholder (esm-spec §4.9.1.1). Both are in scope
	// in every component and are resolved BY NAME ahead of the declaration maps
	// — creditIndependentVariable below is exactly that precedence — so the
	// declaration is unreachable and every reader silently receives the implicit
	// symbol instead of the declared quantity. Hard error: the document that
	// reported this (issue #200) validated clean and then read the simulation
	// clock in place of a fuel time-lag constant.
	// (tests/invalid/reserved_variable_name_*.esm).
	ErrorReservedVariableName = "reserved_variable_name"
	// ErrorUnknownOverrideKey is an inline test's `initial_conditions` or
	// `parameter_overrides` key that matches no declared name under the esm-spec
	// §6.6.2 override-key rules (tests/invalid/unknown_override_key_*.esm).
	ErrorUnknownOverrideKey = "unknown_override_key"
	// ErrorAssertionRankMismatch is an assertion whose form does not match the
	// declared rank of the variable it names (esm-spec §6.6.5): pointwise on a
	// shaped variable, or `coords` / `reduce` on a scalar one
	// (tests/invalid/assertion_rank_mismatch_*.esm).
	ErrorAssertionRankMismatch = "assertion_rank_mismatch"
	// ErrorArrayDefaultWithoutShape is inline array data as the `default` of a
	// variable that declares no `shape` (esm-spec §6.3). Inline array data is a
	// SHAPED variable's value, so with no shape there is nothing for the array
	// to fill (tests/invalid/array_default_without_shape.esm).
	ErrorArrayDefaultWithoutShape = "array_default_without_shape"
)

// --- Diagnostic codes: structural validation, peers of the Error* block
// above. ---
const (
	CodeValidationFailed      = "validation_failed"
	CodeUnknownExpressionType = "unknown_expression_type"

	// CodeDuplicateReactionSpecies is a warning-level code: a species appears
	// more than once in a reaction's substrate/product list. Advisory only —
	// it does not invalidate the document.
	CodeDuplicateReactionSpecies = "duplicate_reaction_species"

	// A data source entry still requires `kind` and `source.url_template`. The
	// three per-variable codes that used to sit beside these are gone with
	// `DataLoader.variables`: from esm 1.0.0 a source declares no variables, and
	// what used to be checked on a loader variable (file_variable, units) is
	// checked on the consuming PARAMETER instead -- by the schema, since both are
	// required there.
	CodeMissingDataSourceKind        = "missing_data_source_kind"
	CodeMissingDataSourceURLTemplate = "missing_data_source_url_template"

	// codeDataSourceURLUnresolved is raised at LOAD time when a
	// `data_sources[*].source.url_template` (or a `mirrors` entry) cannot be
	// resolved to a URL (esm-spec §8.2.1): an unexpanded `${VAR}` -- §8.2 does
	// not expand environment variables into a source's location at all -- or a
	// resolved path carrying a `?` or `#`. Unlike the code above it is not a
	// StructuralError: the document is schema-valid and the failure is the
	// resolver's. The message names the offending data source and template.
	codeDataSourceURLUnresolved = "data_source_url_unresolved"
)

// --- Diagnostic codes: §9.5 sampled function tables — the §9.5.3
// `table_lookup` lowering (raised via newTableLookupError from
// lower_table_lookup.go).
//
// A CROSS-BINDING vocabulary: every binding raises these same strings from its
// own §9.5.3 lowering, so they belong in the shared registry rather than beside
// the pass. Only the codes THIS binding actually emits are declared — the
// remaining §9.5.5 codes (`table_axis_non_monotonic`, `table_data_nan`,
// `table_outputs_length_mismatch`, `table_axis_duplicate_name`,
// `table_outputs_duplicate_name`) are load-time table-well-formedness checks
// this binding does not perform, and a constant for a code nothing raises would
// advertise a diagnostic it cannot report. ---
const (
	// CodeTableLookupUnknownTable: a `table_lookup` names no table, or one the
	// document's `function_tables` block does not declare.
	CodeTableLookupUnknownTable = "table_lookup_unknown_table"
	// CodeTableLookupAxisNameMismatch: the key set of `table_lookup.axes` does
	// not match the axis names the referenced table declares — or the node
	// carries positional `args`, which §9.5.2 requires to be empty.
	CodeTableLookupAxisNameMismatch = "table_lookup_axis_name_mismatch"
	// CodeTableLookupOutputOutOfRange: `table_lookup.output` selects no output
	// of the referenced table — an index past `len(outputs)` (or past 0 for a
	// single-output table), a name absent from `outputs`, or a non-integer /
	// non-string selector.
	CodeTableLookupOutputOutOfRange = "table_lookup_output_out_of_range"
	// CodeTableInterpolationAxesMismatch: `interpolation` and the axis count
	// disagree — `linear` and `nearest` require 1 axis, `bilinear` 2.
	CodeTableInterpolationAxesMismatch = "table_interpolation_axes_mismatch"
	// CodeTableDataShapeMismatch: `data`'s nesting does not match the shape
	// `axes` (and `outputs`, when present) imply, so the selected output names
	// no sub-array.
	CodeTableDataShapeMismatch = "table_data_shape_mismatch"
	// CodeTableAxisNaN: an axis's `values` carries a non-finite entry; §9.5.1
	// requires strictly-increasing FINITE floats.
	CodeTableAxisNaN = "table_axis_nan"
	// CodeTableOutOfBoundsUnsupported: the referenced table declares
	// `out_of_bounds: "error"`, which this binding does not implement. Per
	// esm-spec §9.5.3a the lookup is REFUSED at the point it would otherwise
	// lower — answering it under the `"clamp"` mode the binding does have would
	// return a number the author did not ask for with nothing in the result to
	// say so. The document still LOADS and still round-trips; it simply does not
	// evaluate.
	CodeTableOutOfBoundsUnsupported = "table_out_of_bounds_unsupported"
)

// --- Diagnostic codes: §9.2 closed-function registry (raised via
// newClosedFunctionError from registered_functions.go). ---
const (
	// CodeUnknownClosedFunction: an `fn` node names a function outside the
	// closed registry.
	CodeUnknownClosedFunction = "unknown_closed_function"
	// CodeClosedFunctionArity: a closed function received the wrong number or
	// kind of arguments, or an empty table.
	CodeClosedFunctionArity = "closed_function_arity"
	// CodeClosedFunctionOverflow: an integer-valued result overflows Int32.
	CodeClosedFunctionOverflow = "closed_function_overflow"
	// CodeSearchsortedNonMonotonic: a `searchsorted` table is not
	// non-decreasing.
	CodeSearchsortedNonMonotonic = "searchsorted_non_monotonic"
	// CodeSearchsortedNaNInTable: a `searchsorted` table contains a NaN.
	CodeSearchsortedNaNInTable = "searchsorted_nan_in_table"
	// CodeInterpNonMonotonicAxis: an `interp` axis is not strictly increasing.
	CodeInterpNonMonotonicAxis = "interp_non_monotonic_axis"
	// CodeInterpAxisLengthMismatch: an `interp` axis length does not match the
	// table's.
	CodeInterpAxisLengthMismatch = "interp_axis_length_mismatch"
	// CodeInterpNaNInAxis: an `interp` axis contains a NaN.
	CodeInterpNaNInAxis = "interp_nan_in_axis"
	// CodeInterpAxisTooShort: an `interp` axis has fewer than two points.
	CodeInterpAxisTooShort = "interp_axis_too_short"
)

// --- Diagnostic codes: §9.3 enum lowering (raised via newEnumLoweringError
// from lower_enums.go). ---
const (
	// CodeUnknownEnum: an `enum` node names an enum the file does not declare.
	CodeUnknownEnum = "unknown_enum"
	// CodeUnknownEnumSymbol: an `enum` node names a symbol its enum does not
	// declare.
	CodeUnknownEnumSymbol = "unknown_enum_symbol"
	// CodeInvalidEnumArity: an `enum` node does not carry exactly two
	// arguments.
	CodeInvalidEnumArity = "invalid_enum_arity"
	// CodeInvalidEnumArg: an `enum` node argument is not a string.
	CodeInvalidEnumArg = "invalid_enum_arg"
)

// --- Diagnostic codes: expression EVALUATION (EvaluationError, raised from
// expression.go). `unlowered_operator` is a cross-binding wire code — Julia and
// TypeScript emit exactly this string — so it belongs in the registry rather
// than at the call site. ---
const (
	// CodeUnloweredOperator: evaluation reached a rewrite-target op — one
	// OUTSIDE the esm-spec §4.2 evaluable core (a spatial or right-hand-side
	// `D`, `grad`, a user op) — that no rewrite rule eliminated.
	CodeUnloweredOperator = "unlowered_operator"
	// CodeUnevaluableOperator: evaluation reached an op that IS in the esm-spec
	// §4.2 evaluable core but that this evaluator has no rule for (esm-spec
	// §9.6.6): an array/query or value-invention op, or an `enum` that should
	// have been lowered at load. The complement of CodeUnloweredOperator.
	CodeUnevaluableOperator = "unevaluable_operator"
	// CodeDerivedIndexSetUnmaterialized: an expression ranges over a
	// `kind: "derived"` index set whose producer could not be materialized at
	// build (esm-spec §9.6.6). Registered for the cross-binding vocabulary;
	// this binding has no simulator, so nothing here raises it.
	CodeDerivedIndexSetUnmaterialized = "derived_index_set_unmaterialized"
	// CodeUnsupportedConstruct: a continuous or discrete event, or an implicit
	// equation, reached an evaluator that cannot run it (esm-spec §9.6.6). Go does not simulate,
	// so it never raises this; the constant keeps the §9.6.6 vocabulary uniform.
	CodeUnsupportedConstruct = "unsupported_construct"
)

// --- Spec enum literal: ModelVariable.Type (esm-spec §6.3). esm 1.0.0 declares
// exactly TWO. `state`, `observed`, `brownian` and `discrete` are GONE as
// declared types: a site that used to branch on one of them calls the
// classification functions in classify.go instead (esm-spec §6.3.1). ---
const (
	// VarTypeUnknown is a quantity the solver solves for; its behaviour is
	// stated by the model's `equations` and nowhere else.
	VarTypeUnknown = "unknown"
	// VarTypeParameter is a quantity supplied to the solver, valued by
	// `default` or a `distribution` and optionally refreshed by an `update`.
	VarTypeParameter = "parameter"
)

// --- Spec enum literal: AST op names used across more than one file
// (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in
// lower_expression_templates.go and is intentionally not redeclared here. ---
const (
	OpDerivative  = "D"            // derivative op (structural time derivative, or a spatial rewrite target)
	OpIC          = "ic"           // initial-condition wrapper
	OpConst       = "const"        // inline literal payload node
	OpFn          = "fn"           // closed-registry function call
	OpEnum        = "enum"         // enum symbol (lowered to const at load)
	OpMakearray   = "makearray"    // hyper-rectangular array constructor
	OpTableLookup = "table_lookup" // sampled function-table query
)

// --- Spec enum literal: Model.SystemKind and the ode/dae DAE classification
// (esm-spec §6 / dae.go). ---
const (
	SystemKindODE       = "ode"
	SystemKindDAE       = "dae"
	SystemKindNonlinear = "nonlinear"
	SystemKindSDE       = "sde"
	SystemKindPDE       = "pde"
)

// --- Spec default: the independent variable when Domain.IndependentVariable
// is unset (esm-spec §11; dae.go defaults to this). ---
const DefaultIndepVar = "t"

// operatorPlaceholderVar is the esm-spec §6.4 placeholder an operator-style
// model uses for the state it operates on ("D(_var, t) ~ -u*grad(_var)"). When
// the model is coupled via `operator_compose` it is substituted with each
// matching state variable of the target system, so it is a legal reference — in
// equations and in event affects alike — and never an undeclared variable.
const operatorPlaceholderVar = "_var"

// --- Diagnostic SEVERITY levels: the values StructuralError.Level and
// ValidationMessage.Level carry on the wire.
//
// These are the last diagnostic vocabulary validate.go still spelled as bare
// literals after the Error* / Code* blocks moved here, and they are the same
// kind of thing: a value a consumer compares against, so the string is a
// contract and belongs beside the codes it qualifies. The values are unchanged.
//
// Only two are emitted. "info" appears in ValidationMessage.Level's field
// comment as an admissible value but is produced nowhere, so it gets no
// constant — a constant for a level nothing raises would advertise a severity
// this binding cannot report. ---
const (
	// LevelError is a document-INVALIDATING finding. It is also the value of an
	// UNSET Level: a StructuralError built without one is an error, which is why
	// isWarning tests for the warning rather than against the error.
	LevelError = "error"
	// LevelWarning is an ADVISORY finding that does not invalidate the document
	// (e.g. duplicate_reaction_species).
	LevelWarning = "warning"
)

// --- Render format discriminator (display.go; compared ~50× as a bare
// string). ---
const (
	FmtUnicode = "unicode"
	FmtLatex   = "latex"
	FmtASCII   = "ascii"
	// FmtUnicodeSpaced is FmtUnicode with the multiplication operator rendered
	// as " · " (spaced) instead of "·". The spacing is applied where the
	// operator is emitted, so it never touches a "·" occurring inside a
	// variable name or chemical formula.
	FmtUnicodeSpaced = "unicode_spaced"
)

// DiagnosticError is implemented by the package's code-bearing error types
// (EvaluationError, ExpressionTemplateError, RuleEngineError, EnumLoweringError,
// ClosedFunctionError, CoupleMultiplicativeNoTendencyError, tableLookupError,
// OperatorComposeNoMergeError, OperatorComposeAmbiguousBareNameError,
// OperatorComposeRequireMatchError). It lets a caller recover the stable
// diagnostic code from any of them uniformly — errors.As(err, &de) then
// de.DiagnosticCode() — without switching over the concrete types. All ten
// render Error() in the shared "[code] message" form.
type DiagnosticError interface {
	error
	DiagnosticCode() string
}

// Compile-time assertions that every code-bearing error type satisfies
// DiagnosticError (and, by extension, renders Error() in the shared form).
var (
	_ DiagnosticError = (*EvaluationError)(nil)
	_ DiagnosticError = (*ExpressionTemplateError)(nil)
	_ DiagnosticError = (*RuleEngineError)(nil)
	_ DiagnosticError = (*EnumLoweringError)(nil)
	_ DiagnosticError = (*ClosedFunctionError)(nil)
	_ DiagnosticError = (*CoupleMultiplicativeNoTendencyError)(nil)
	_ DiagnosticError = (*tableLookupError)(nil)
	_ DiagnosticError = (*OperatorComposeNoMergeError)(nil)
	_ DiagnosticError = (*OperatorComposeAmbiguousBareNameError)(nil)
	_ DiagnosticError = (*OperatorComposeRequireMatchError)(nil)
)
