package esm

// codes.go collects string literals the audit flagged as repeated across the
// package: stable §9.6.6 / §10.11 diagnostic codes (metaparameter_type_error
// appears 21×, template_import_unresolved 10×, template_import_unknown_name
// 10×, template_import_name_conflict 10×, coupling_library_illegal_payload 6×),
// the validation codes still inline in validate.go, and the spec enum literals
// (variable types, op names, system kinds, render formats, the default
// independent variable) that are otherwise typed by hand at dozens of sites.
//
// These are ADDITIVE; the existing code definitions (validate.go's Error*
// constants, lower_expression_templates.go's applyExpressionTemplateOp,
// template_imports.go's templateComponentKinds, the geometryManifold* sets) are
// NOT duplicated here. Naming follows the exported-constant convention already
// used by validate.go's Error* block; Wave 2 references these from the call
// sites.

// --- Diagnostic codes: §9.7 template imports / §9.6.6 metaparameters
// (raised via newETErr from template_imports.go and subsystem_ref.go). ---
const (
	CodeMetaparamTypeError         = "metaparameter_type_error"
	CodeTemplateImportUnresolved   = "template_import_unresolved"
	CodeTemplateImportUnknownName  = "template_import_unknown_name"
	CodeTemplateImportNameConflict = "template_import_name_conflict"
	CodeTemplateImportCycle        = "template_import_cycle"
)

// --- Diagnostic codes: §10.11 coupling libraries / coupling_import. ---
const (
	CodeCouplingLibraryIllegalPayload = "coupling_library_illegal_payload"
)

// --- Diagnostic codes: structural validation (currently inline string
// literals in validate.go — the peers of the Error* constants there). ---
const (
	CodeValidationFailed      = "validation_failed"
	CodeUnknownExpressionType = "unknown_expression_type"

	// CodeDuplicateReactionSpecies is a warning-level code: a species appears
	// more than once in a reaction's substrate/product list. Advisory only —
	// it does not invalidate the document.
	CodeDuplicateReactionSpecies = "duplicate_reaction_species"

	CodeMissingLoaderKind                 = "missing_loader_kind"
	CodeMissingLoaderSourceURLTemplate    = "missing_loader_source_url_template"
	CodeMissingLoaderVariables            = "missing_loader_variables"
	CodeMissingLoaderVariableFileVariable = "missing_loader_variable_file_variable"
	CodeMissingLoaderVariableUnits        = "missing_loader_variable_units"
)

// --- Spec enum literal: ModelVariable.Type (esm-spec §4). ---
const (
	VarTypeState     = "state"
	VarTypeObserved  = "observed"
	VarTypeParameter = "parameter"
	VarTypeBrownian  = "brownian"
)

// --- Spec enum literal: AST op names used across more than one file
// (esm-spec §4.2 / §9). applyExpressionTemplateOp already lives in
// lower_expression_templates.go and is intentionally not redeclared here. ---
const (
	OpDerivative  = "D"            // time/spatial derivative
	OpGrad        = "grad"         // gradient
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
	_ DiagnosticError = (*SubstitutionError)(nil)
)
