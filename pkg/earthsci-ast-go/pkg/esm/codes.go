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

	// CodeTemplateImportNotLibrary: an `import` resolves to a file that is not a
	// template library (it declares components, or declares no
	// `expression_templates` / `coupling_roles` block at all).
	CodeTemplateImportNotLibrary = "template_import_not_library"
	// CodeTemplateImportIsCouplingLibrary: a template `import` resolves to a
	// COUPLING library (§10.9). The two library kinds are imported through
	// different blocks and are not interchangeable.
	CodeTemplateImportIsCouplingLibrary = "template_import_is_coupling_library"
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
	// CodeMakearrayRegionInverted: a `makearray` region's stop precedes its
	// start, so the region denotes no cells (esm-spec §4.3.5).
	CodeMakearrayRegionInverted = "makearray_region_inverted"
	// CodeGeometryManifoldInvalid: a geometry kernel declares a manifold that is
	// not one of the spec's manifold kinds, or one inconsistent with the
	// coordinates it is given.
	CodeGeometryManifoldInvalid = "geometry_manifold_invalid"
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
	ErrorIcInReactionSystem = "ic_in_reaction_system"
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
)

// --- Diagnostic codes: expression EVALUATION (EvaluationError, raised from
// expression.go). `unlowered_operator` is a cross-binding wire code — Julia and
// TypeScript emit exactly this string — so it belongs in the registry rather
// than at the call site. ---
const (
	// CodeUnloweredOperator: evaluation reached an op that the load-time
	// lowering passes should already have rewritten away (an `enum` symbol, an
	// unexpanded template application), so no evaluator rule applies to it.
	CodeUnloweredOperator = "unlowered_operator"
	// CodeUnsupportedOperator: evaluation reached a well-formed op for which
	// this binding's evaluator has no rule.
	CodeUnsupportedOperator = "unsupported_operator"
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

// --- Render format discriminator (display.go; compared ~50× as a bare
// string). ---
const (
	FmtUnicode = "unicode"
	FmtLatex   = "latex"
	FmtAscii   = "ascii"
	// FmtUnicodeSpaced is FmtUnicode with the multiplication operator rendered
	// as " · " (spaced) instead of "·". The spacing is applied where the
	// operator is emitted, so it never touches a "·" occurring inside a
	// variable name or chemical formula.
	FmtUnicodeSpaced = "unicode_spaced"
)

// DiagnosticError is implemented by the package's code-bearing error types
// (EvaluationError, ExpressionTemplateError, RuleEngineError, LowerEnumsError,
// ClosedFunctionError). It lets a caller recover the stable diagnostic code
// from any of them uniformly — errors.As(err, &de) then de.DiagnosticCode() —
// without switching over the concrete types. All five render Error() in the
// shared "[code] message" form.
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
	_ DiagnosticError = (*LowerEnumsError)(nil)
	_ DiagnosticError = (*ClosedFunctionError)(nil)
)
