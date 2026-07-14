package esm

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// SchemaError represents a JSON Schema violation
type SchemaError struct {
	Path    string `json:"path"`    // RFC 6901 JSON Pointer to the offending location (as reported by the schema validator)
	Message string `json:"message"` // Human-readable description
	Keyword string `json:"keyword"` // JSON Schema keyword that failed
}

// StructuralError represents equation/unknown balance, reference integrity issues
type StructuralError struct {
	// Path is an RFC 6901 JSON Pointer to the offending component
	// ("/models/x/equations/0", "/reaction_systems/x/reactions/0/substrates/1/species"),
	// matching SchemaError.Path and the shared invalid-fixture goldens. The
	// document root is the empty string "".
	Path    string         `json:"path"`
	Code    string         `json:"code"`    // Machine-readable error code
	Message string         `json:"message"` // Human-readable description
	Details map[string]any `json:"details"` // Additional context
	// Level is "warning" for advisory findings that do NOT invalidate the
	// document (e.g. a species listed twice in a reaction), or "" / "error"
	// for hard errors. It is omitempty so hard errors keep their original wire
	// shape; only warnings carry an explicit level.
	Level string `json:"level,omitempty"`
}

// isWarning reports whether se is an advisory warning (Level "warning") rather
// than a document-invalidating error (Level "" or "error").
func (se StructuralError) isWarning() bool { return se.Level == "warning" }

// countStructuralErrorLevel returns how many entries are hard errors (not
// warnings) — the count that determines validity.
func countStructuralErrorLevel(errs []StructuralError) int {
	n := 0
	for _, se := range errs {
		if !se.isWarning() {
			n++
		}
	}
	return n
}

// UnitWarning represents a finding from dimensional analysis.
//
// Despite the name (kept for wire compatibility — it is the `unit_warnings`
// field of the spec's ValidationResult), a UnitWarning is not necessarily
// advisory: Code says whether it is a defect in the FILE or a limit of the
// ANALYSIS. Findings coded UnitFindingDimensionalMismatch or
// UnitFindingUnparseable are promoted to hard `unit_inconsistency` structural
// errors and invalidate the document; UnitFindingAnalysis findings do not. See
// the UnitFinding* constants in units.go for the policy.
type UnitWarning struct {
	Path     string `json:"path"`      // RFC 6901 JSON Pointer to the equation/expression (see StructuralError.Path)
	Code     string `json:"code"`      // UnitFindingDimensionalMismatch | UnitFindingUnparseable | UnitFindingAnalysis
	Message  string `json:"message"`   // Human-readable description
	LhsUnits string `json:"lhs_units"` // Inferred units of the LHS
	RhsUnits string `json:"rhs_units"` // Inferred units of the RHS
}

// isPromotable reports whether a unit finding invalidates the document — i.e.
// whether it states a defect in the FILE (a provable dimensional mismatch, or a
// unit string that denotes no real unit) rather than a limit of the checker.
func (w UnitWarning) isPromotable() bool {
	return w.Code == UnitFindingDimensionalMismatch || w.Code == UnitFindingUnparseable
}

// ValidationResult holds the result of validation per ESM Libraries Spec Section 3.4
type ValidationResult struct {
	SchemaErrors     []SchemaError     `json:"schema_errors"`
	StructuralErrors []StructuralError `json:"structural_errors"`
	UnitWarnings     []UnitWarning     `json:"unit_warnings"`
	IsValid          bool              `json:"is_valid"`
}

// Structural error codes per ESM Libraries Spec Section 3.4
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
	// ErrorInvalidDiscreteParam is reserved for a future discrete-parameter
	// diagnostic; no check emits it yet (kept for cross-binding code parity).
	ErrorInvalidDiscreteParam = "invalid_discrete_param"
	ErrorNullReaction         = "null_reaction"
	ErrorMissingObservedExpr  = "missing_observed_expr"
	ErrorEventVarUndeclared   = "event_var_undeclared"
	ErrorUnitInconsistency    = "unit_inconsistency"
	ErrorIcInReactionSystem   = "ic_in_reaction_system"
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

// ValidationMessage represents a single validation issue in the legacy
// DetailedValidationResult surface returned by Validate/ValidateStructural.
type ValidationMessage struct {
	Level   string `json:"level"`   // "error", "warning", "info"
	Message string `json:"message"` // Human-readable description
	Path    string `json:"path"`    // JSON path to the problematic element
}

// DetailedValidationResult holds the legacy (message-oriented) validation
// results returned by Validate/ValidateStructural. New callers should prefer
// ValidateFile, which returns the code-bearing ValidationResult.
type DetailedValidationResult struct {
	Valid    bool                `json:"valid"`
	Messages []ValidationMessage `json:"messages,omitempty"`
}

// ValidateFile performs comprehensive validation of an ESM file per ESM Libraries Spec Section 3.4
// This includes schema validation, structural validation, and unit validation (future)
func ValidateFile(file *ESMFile, jsonStr string) *ValidationResult {
	// First validate JSON schema
	schemaResult, err := validateJSONSchema(jsonStr)
	if err != nil {
		// If schema validation fails, return with error
		return &ValidationResult{
			IsValid:          false,
			SchemaErrors:     []SchemaError{{Path: "$", Message: fmt.Sprintf("Schema validation failed: %v", err), Keyword: "error"}},
			StructuralErrors: []StructuralError{},
			UnitWarnings:     []UnitWarning{},
		}
	}

	// Start with schema validation results
	result := &ValidationResult{
		SchemaErrors:     schemaResult.SchemaErrors,
		StructuralErrors: []StructuralError{},
		UnitWarnings:     []UnitWarning{},
		IsValid:          schemaResult.IsValid,
	}

	// If schema validation failed, don't proceed with structural validation
	if !schemaResult.IsValid {
		return result
	}

	// A LIBRARY document (expression-template library per esm-spec §9.7, or a
	// coupling-role library per §10.9) declares no components, and its §9.7
	// constructs are stripped during parse by design — so the loaded ESMFile is
	// empty and every component-oriented structural check has nothing to say. The
	// schema (root `anyOf`) has already confirmed it is a well-formed library.
	// Without this, Go rejected every template library outright, because
	// ValidateStruct's assembly-document invariant fired on the emptied struct.
	if isLibraryDocumentJSON(jsonStr) && len(file.Models) == 0 &&
		len(file.ReactionSystems) == 0 && len(file.DataLoaders) == 0 {
		return result
	}

	// Perform structural validation with structured error codes
	structuralResult := ValidateStructuralWithCodes(file)

	// Use the structured validation results directly
	result.StructuralErrors = structuralResult.StructuralErrors
	result.UnitWarnings = structuralResult.UnitWarnings

	// Update IsValid based on both schema and structural errors. Warning-level
	// findings (StructuralError.Level == "warning", e.g. duplicate_reaction_species)
	// are ADVISORY and do not invalidate the document — counting them made
	// ValidateFile report IsValid=false on a file that ValidateStructural and
	// ValidateStructuralWithCodes both call valid (audit G14).
	result.IsValid = len(result.SchemaErrors) == 0 &&
		countStructuralErrorLevel(result.StructuralErrors) == 0

	return result
}

// isLibraryDocumentJSON reports whether the RAW document is a library file —
// one whose payload is an `expression_templates` or `coupling_roles` block
// rather than components. Both are admitted by the schema's root `anyOf`, and
// both are legal with no models / reaction systems / data loaders at all.
//
// It is answered from the raw JSON because parse deliberately strips the §9.7
// constructs, so by the time the typed ESMFile exists the evidence is gone.
func isLibraryDocumentJSON(jsonStr string) bool {
	var view map[string]json.RawMessage
	if err := json.Unmarshal([]byte(jsonStr), &view); err != nil {
		return false
	}
	for _, key := range []string{"expression_templates", "coupling_roles"} {
		if raw, has := view[key]; has && rawIsPresent(raw) {
			return true
		}
	}
	return false
}

// Validate is the backward compatibility function that returns DetailedValidationResult
// For the new spec-compliant validation, use ValidateFile
func Validate(file *ESMFile) *DetailedValidationResult {
	return ValidateStructural(file)
}

// StructuralValidationResult holds the code-bearing structural validation
// output. It is the return type of the exported ValidateStructuralWithCodes and
// the internal source that ValidateFile forwards to callers.
type StructuralValidationResult struct {
	Valid            bool              `json:"valid"`
	StructuralErrors []StructuralError `json:"structural_errors"`
	UnitWarnings     []UnitWarning     `json:"unit_warnings"`
}

// ValidateStructural performs comprehensive structural validation of an ESM file
// and returns the legacy message-oriented DetailedValidationResult. It runs the
// same single structural traversal as ValidateStructuralWithCodes and adapts
// each emitted StructuralError to the legacy ValidationMessage wording (see
// structuralErrorToLegacyMessage). Unit/dimensional checks are NOT part of this
// legacy surface — use ValidateStructuralWithCodes/ValidateFile for those.
func ValidateStructural(file *ESMFile) *DetailedValidationResult {
	result := &DetailedValidationResult{
		Valid:    true,
		Messages: []ValidationMessage{},
	}

	// Basic struct validation (already done in types.go)
	if err := file.ValidateStruct(); err != nil {
		result.Valid = false
		result.Messages = append(result.Messages, ValidationMessage{
			Level:   "error",
			Message: fmt.Sprintf("Basic validation failed: %v", err),
			Path:    "",
		})
		return result
	}

	errs := collectStructuralErrors(file)
	for _, se := range errs {
		result.Messages = append(result.Messages, structuralErrorToLegacyMessage(se))
	}

	// A hard structural error (error-level message) invalidates the document;
	// warning-level findings do not.
	result.Valid = countStructuralErrorLevel(errs) == 0
	return result
}

// ValidateStructuralWithCodes performs structural validation and returns structured errors directly
func ValidateStructuralWithCodes(file *ESMFile) *StructuralValidationResult {
	result := &StructuralValidationResult{
		StructuralErrors: []StructuralError{},
		UnitWarnings:     []UnitWarning{},
	}

	// Basic struct validation (already done in types.go)
	if err := file.ValidateStruct(); err != nil {
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path:    "",
			Code:    CodeValidationFailed,
			Message: fmt.Sprintf("Basic validation failed: %v", err),
			Details: map[string]any{},
		})
		result.Valid = false
		return result
	}

	// Single structural traversal (shared with the legacy surface). Includes
	// warning-level entries (e.g. duplicate reaction species) so the coded
	// surface has parity with the legacy one; warnings do not affect Valid.
	result.StructuralErrors = append(result.StructuralErrors, collectStructuralErrors(file)...)

	// Unit/dimensional checks (code-bearing surface only). Models and systems are
	// visited in sorted order so the emitted findings — and the structural errors
	// promoted from them below — are deterministic across runs.
	for _, modelName := range sortedKeys(file.Models) {
		model := file.Models[modelName]
		validateModelUnits(modelName, &model, fmt.Sprintf("/models/%s", modelName), file, result)
	}
	for _, systemName := range sortedKeys(file.ReactionSystems) {
		system := file.ReactionSystems[systemName]
		validateReactionSystemUnits(systemName, &system, fmt.Sprintf("/reaction_systems/%s", systemName), result)
		validateReactionRateUnits(systemName, &system, fmt.Sprintf("/reaction_systems/%s", systemName), result)
	}
	result.StructuralErrors = append(result.StructuralErrors, promoteUnitFindings(result.UnitWarnings)...)

	// Valid is computed once from the accumulated errors so that checks
	// appending StructuralErrors need not maintain the flag themselves;
	// warning-level entries are excluded.
	result.Valid = countStructuralErrorLevel(result.StructuralErrors) == 0
	return result
}

// promoteUnitFindings turns the DEFECT-BEARING unit findings into hard
// structural errors, leaving the analysis-limited ones as warnings.
//
// This is the cross-binding policy, and it is what the shared corpus requires:
// tests/invalid/expected_errors.json pins every units_*.esm fixture as
// `is_valid: false` with a STRUCTURAL error, so a binding that files a provable
// dimensional mismatch as an advisory warning accepts files the corpus declares
// invalid. The emitted code is `unit_inconsistency` and the path is the JSON
// Pointer the finding already carries (`/models/<M>/equations/<i>`,
// `/models/<M>/variables/<v>`) — both exactly as pinned, and identical to what
// TypeScript emits.
//
// What is NOT promoted is just as deliberate: a UnitFindingAnalysis finding
// (symbolic exponent, an op with no dimensional rule, a malformed arity) reports
// what the checker could not DETERMINE, not a defect in the file, and must never
// invalidate a document.
func promoteUnitFindings(findings []UnitWarning) []StructuralError {
	var errs []StructuralError
	for _, w := range findings {
		if !w.isPromotable() {
			continue
		}
		// The two defect kinds carry DIFFERENT codes: a unit string that denotes
		// no real unit is `unit_parse_error`; a provable mismatch between two
		// units that DO resolve is `unit_inconsistency`. Both are hard errors.
		code := ErrorUnitInconsistency
		if w.Code == UnitFindingUnparseable {
			code = ErrorUnitParseError
		}
		errs = append(errs, StructuralError{
			Path:    w.Path,
			Code:    code,
			Message: w.Message,
			Details: map[string]any{
				"finding":   w.Code,
				"lhs_units": w.LhsUnits,
				"rhs_units": w.RhsUnits,
			},
		})
	}
	return errs
}

// structuralErrorToLegacyMessage adapts a code-bearing StructuralError to the
// legacy ValidationMessage rendering used by Validate/ValidateStructural. The
// legacy wording is conformance-pinned by the Go test suite, so this table is
// the single point that reproduces it:
//
//   - reference checks emitted "Unknown …" where the code-bearing track emits
//     "Undefined …"; the first such word is rewritten;
//   - unknown_expression_type (which the pre-unification legacy track logged as
//     a warning) is emitted at level "error" in both tracks;
//   - a warning-level StructuralError (Level "warning", e.g. duplicate reaction
//     species) is rendered as a "warning" message; every other error maps to
//     level "error".
//
// All other wording is identical between the two tracks and passes through.
func structuralErrorToLegacyMessage(se StructuralError) ValidationMessage {
	msg := se.Message
	switch se.Code {
	case ErrorUndefinedVariable, ErrorUndefinedSpecies, ErrorUndefinedSystem, ErrorEventVarUndeclared:
		msg = strings.Replace(msg, "Undefined", "Unknown", 1)
	}
	level := "error"
	if se.isWarning() {
		level = "warning"
	}
	return ValidationMessage{Level: level, Message: msg, Path: se.Path}
}

// structuralScan performs the single structural traversal that backs both
// validation surfaces. It accumulates code-bearing StructuralErrors, some of
// which are warning-level (Level "warning", e.g. duplicate substrate/product)
// and advisory only.
type structuralScan struct {
	file  *ESMFile
	indep string
	// coupled holds every system named by a coupling entry. A coupled system's
	// equations legitimately reference names it does not declare — the state of
	// the system it is composed with, or the variable a `variable_map` wires in —
	// so equation balance and reference integrity are relaxed for it (mirrors
	// TS validate/orchestrator.ts `coupledSystems`).
	coupled map[string]bool
	// coords holds the implicitly-declared spatial coordinate names (see
	// coordinateNames).
	coords map[string]bool
	// undefCode overrides the code emitted for an undeclared BARE name during a
	// scoped sub-walk. Reaction rate expressions use it to report
	// `undefined_parameter` (the code the shared corpus pins for an undeclared
	// name in a `rate`) instead of the generic `undefined_variable`. Empty means
	// `undefined_variable`.
	undefCode string
	errors    []StructuralError
}

// undefinedNameCode is the code for an undeclared bare name in the current
// context: `undefined_parameter` inside a reaction rate, `undefined_variable`
// everywhere else.
func (s *structuralScan) undefinedNameCode() string {
	if s.undefCode != "" {
		return s.undefCode
	}
	return ErrorUndefinedVariable
}

// withUndefinedCode runs fn with the undeclared-name code overridden, restoring
// it afterwards.
func (s *structuralScan) withUndefinedCode(code string, fn func()) {
	prev := s.undefCode
	s.undefCode = code
	defer func() { s.undefCode = prev }()
	fn()
}

func (s *structuralScan) addErr(se StructuralError) { s.errors = append(s.errors, se) }

// addWarning records an advisory, non-invalidating finding as a warning-level
// StructuralError so both validation surfaces surface it uniformly.
func (s *structuralScan) addWarning(code, path, message string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	s.errors = append(s.errors, StructuralError{
		Path:    path,
		Code:    code,
		Message: message,
		Details: details,
		Level:   "warning",
	})
}

// collectStructuralErrors runs the unified structural traversal and returns the
// code-bearing errors (including any warning-level entries).
func collectStructuralErrors(file *ESMFile) []StructuralError {
	s := &structuralScan{
		file:    file,
		indep:   fileIndepVar(file),
		coupled: coupledSystemNames(file),
		coords:  coordinateNames(file),
	}

	for modelName, model := range file.Models {
		model := model
		s.validateModel(modelName, &model)
	}
	for systemName, system := range file.ReactionSystems {
		system := system
		s.validateReactionSystem(systemName, &system)
	}
	s.validateCouplingReferences()
	s.validateSubsystemRefs()
	s.validateCircularReferences()
	s.validateDataLoaderReferences()

	return s.errors
}

// coupledSystemNames returns every system a coupling entry names — as a
// `systems` member (including the root of a dotted subsystem path) or as the
// system half of a `from`/`to` scoped reference.
//
// A COUPLED system does not own all the names its equations mention. An
// operator-style model spells its operand as the §6.4 placeholder `_var` (or as
// a bare stand-in name), and a `variable_map` supplies a value the target model
// never declares; its `equations` may likewise drive a state that lives in the
// system it is composed with, so its own equation/unknown count need not
// balance. Equation balance and reference integrity are therefore skipped for
// these systems — exactly as TS validate/orchestrator.ts does. Event
// consistency still runs (with `_var` credited, see validateModel), which is
// where a genuinely undeclared event target is still caught.
func coupledSystemNames(file *ESMFile) map[string]bool {
	coupled := map[string]bool{}
	add := func(name string) {
		if name == "" {
			return
		}
		coupled[name] = true
		// A dotted endpoint ("Atmosphere.Chemistry.O3") couples the ROOT system
		// too — that is the model whose checks must relax.
		if root, _, found := strings.Cut(name, "."); found {
			coupled[root] = true
		}
	}
	for _, coupling := range file.Coupling {
		switch c := coupling.(type) {
		case OperatorComposeCoupling:
			for _, name := range c.Systems {
				add(name)
			}
		case CouplingCouple:
			for _, name := range c.Systems {
				add(name)
			}
		case VariableMapCoupling:
			add(c.From)
			add(c.To)
		}
	}
	return coupled
}

// conventionalCoordinateNames are the spatial coordinate names every document
// may reference without declaring them.
//
// v0.8.0 removed `Domain.spatial`, so a coordinate has NO declaration site in
// the schema: it is named directly in an expression (`ic(u) ~ 0.5*(1 +
// tanh((x - 0.3)/0.15))`, tests/valid/initial_conditions/
// expression_ignition_front_1d.esm) and as the `dim` of a `grad`/`div`/
// `laplacian` node. It is a coordinate of the domain, not an entry of any
// `variables` block — reporting it as an undefined variable rejects a valid
// file.
var conventionalCoordinateNames = []string{"x", "y", "z", "lon", "lat", "lev"}

// coordinateNames returns the implicitly-declared coordinate namespace: the
// conventional axis names plus every axis the document itself names — the `dim`
// of a spatial operator and the `wrt` of a SPATIAL derivative (a `wrt` naming
// the independent variable is time, credited separately).
func coordinateNames(file *ESMFile) map[string]bool {
	coords := map[string]bool{}
	for _, name := range conventionalCoordinateNames {
		coords[name] = true
	}
	if file == nil {
		return coords
	}
	indep := fileIndepVar(file)
	var walk func(Expression)
	walk = func(e Expression) {
		node, ok := asExprNode(e)
		if !ok {
			return
		}
		if node.Dim != nil && *node.Dim != "" {
			coords[*node.Dim] = true
		}
		if node.Wrt != nil && *node.Wrt != "" && *node.Wrt != indep {
			coords[*node.Wrt] = true
		}
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walk(child)
			return child, nil
		})
	}
	for _, model := range file.Models {
		for _, eq := range model.Equations {
			walk(eq.LHS)
			walk(eq.RHS)
		}
		for _, v := range model.Variables {
			walk(v.Expression)
		}
	}
	return coords
}

// validateModel checks model-specific structural rules.
func (s *structuralScan) validateModel(modelName string, model *Model) {
	basePath := fmt.Sprintf("/models/%s", modelName)

	allVars := make(map[string]bool)
	for varName := range model.Variables {
		allVars[varName] = true
	}
	// The document-scoped `index_sets` registry is a legitimate non-variable
	// identifier namespace (RFC semiring-faq-unified-ir §5.2): an `aggregate`
	// may name an index set as a positional operand (value-invention form
	// `aggregate(args:["faces"], …)`) or reduce over it (`rank(edges)`). Credit
	// those names so the full-child descent below does not mis-flag them as
	// undefined, mirroring TS `validateReferenceIntegrity`'s `declaredIndexSets`.
	s.creditIndexSetNames(allVars)
	s.creditIndependentVariable(allVars)
	s.creditCoordinateNames(allVars)

	// A COUPLED model does not own every name it mentions, and its own equations
	// need not balance its own unknowns (see coupledSystemNames). Reference
	// integrity and equation balance are therefore skipped for it; event
	// consistency below still runs, with the §6.4 `_var` placeholder credited.
	isCoupled := s.coupled[modelName]

	if !isCoupled {
		for i, eq := range model.Equations {
			eqPath := fmt.Sprintf("%s/equations/%d", basePath, i)
			// Binder-introduced symbols are collected across the WHOLE equation —
			// both sides — and are in scope on both, mirroring TS
			// `validateReferenceIntegrity`. The array-form IR routinely binds an
			// index on one side and uses it on the other: the LHS
			// `aggregate(output_idx:["i"], expr: D(index(u,i)))` binds `i` for an RHS
			// that spells `index(u, i)` inside a makearray value. Scoping the binders
			// per-NODE (the previous behaviour) could not see across that boundary and
			// reported the loop index as an undefined variable.
			scope := allVars
			if bound := equationBoundSymbols(eq); len(bound) > 0 {
				scope = unionScope(allVars, bound)
			}
			s.validateExpressionVariables(eq.LHS, scope, fmt.Sprintf("%s/lhs", eqPath), modelName)
			s.validateExpressionVariables(eq.RHS, scope, fmt.Sprintf("%s/rhs", eqPath), modelName)
		}

		// Equation-unknown balance validation (Section 3.2.1).
		s.validateEquationUnknownBalance(modelName, model, basePath)
	}

	// The §6.4 operator placeholder. In an operator-composed / coupled model
	// `_var` stands for each matching state variable of the system this one is
	// composed with, and it is substituted at composition — so an event affect
	// that assigns to it is legal (esm-spec §6.4), exactly as an EQUATION that
	// differentiates it is. Reporting `_var` as an undeclared event variable
	// while the very same document's equations were exempt from the reference
	// check was internally inconsistent, and it rejected the valid
	// tests/valid/full_coupled.esm.
	eventVars := allVars
	if isCoupled {
		eventVars = unionScope(allVars, map[string]bool{operatorPlaceholderVar: true})
	}

	// Observed variables must carry an expression.
	for varName, variable := range model.Variables {
		if variable.Type == VarTypeObserved && variable.Expression == nil {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/variables/%s", basePath, varName),
				Code:    ErrorMissingObservedExpr,
				Message: "Observed variable must have an expression",
				Details: map[string]any{
					"variable": varName,
					"model":    modelName,
				},
			})
		}
	}

	for i, event := range model.DiscreteEvents {
		event := event
		eventPath := fmt.Sprintf("%s/discrete_events/%d", basePath, i)
		s.validateDiscreteEvent(&event, eventVars, eventPath, modelName)
		s.validateDiscreteParameters(event.DiscreteParameters, model, eventPath, modelName)
	}
	// `discrete_parameters` is a DISCRETE-event field only (a continuous event
	// carries no such list — see types.go).
	for i, event := range model.ContinuousEvents {
		event := event
		s.validateContinuousEvent(&event, eventVars, fmt.Sprintf("%s/continuous_events/%d", basePath, i), modelName)
	}
}

// validateExpressionVariables checks that every variable referenced in an
// expression tree is declared (or resolves as a scoped reference).
func (s *structuralScan) validateExpressionVariables(expr Expression, allVars map[string]bool, path, currentSystem string) {
	switch e := expr.(type) {
	case string:
		if allVars[e] {
			return
		}
		if s.file != nil && strings.Contains(e, ".") {
			if _, resolved := resolveScopedReference(e, s.file, currentSystem); !resolved {
				s.addErr(StructuralError{
					Path:    path,
					Code:    ErrorUnresolvedScopedRef,
					Message: fmt.Sprintf("Unresolved scoped reference '%s'", e),
					Details: map[string]any{
						"variable":       e,
						"current_system": currentSystem,
					},
				})
			}
			return
		}
		s.addErr(StructuralError{
			Path:    path,
			Code:    s.undefinedNameCode(),
			Message: fmt.Sprintf("Undefined variable '%s'", e),
			Details: map[string]any{
				"variable":       e,
				"current_system": currentSystem,
			},
		})
	case ExprNode:
		s.validateExprNodeChildren(e, allVars, path, currentSystem)
	case *ExprNode:
		if e != nil {
			s.validateExprNodeChildren(*e, allVars, path, currentSystem)
		}
	case map[string]any:
		// A raw (un-normalized) operator node reached through a non-`args`
		// sidecar child (expr/filter/key/lower/upper/values/axes/bindings):
		// UnmarshalExpression normalizes only `args`, so those fields keep their
		// decoded-JSON shape and an operator node inside them arrives as a map.
		// Normalize it and descend; a non-operator object carries no references.
		if node, ok := rawExprNode(e); ok {
			s.validateExprNodeChildren(node, allVars, path, currentSystem)
		}
	case []any:
		// A raw nested array reached through a sidecar child; check each element.
		for i, el := range e {
			s.validateExpressionVariables(el, allVars, fmt.Sprintf("%s/%d", path, i), currentSystem)
		}
	case float64, float32, int, int32, int64, json.Number:
		// Numeric literals are always valid. float64/int64 are the shapes the
		// JSON unmarshaler emits for normalized `args`; json.Number appears in
		// raw sidecar children, which retain their decoded-JSON shape.
	case bool, nil:
		// Boolean / null literal leaves, reachable only through raw sidecar
		// children (e.g. a filter-predicate literal) — never a reference.
	default:
		s.addErr(StructuralError{
			Path:    path,
			Code:    CodeUnknownExpressionType,
			Message: fmt.Sprintf("Unknown expression type: %T", e),
			Details: map[string]any{"type": fmt.Sprintf("%T", e)},
		})
	}
}

// creditIndexSetNames marks every document-scoped `index_sets` registry name as
// in-scope in allVars. Index-set names are a legitimate non-variable identifier
// namespace an `aggregate` may reference (RFC semiring-faq-unified-ir §5.2); the
// full-child descent in validateExprNodeChildren would otherwise flag them as
// undefined. No-op when no file/registry is attached.
func (s *structuralScan) creditIndexSetNames(allVars map[string]bool) {
	if s.file == nil {
		return
	}
	for name := range s.file.IndexSets {
		allVars[name] = true
	}
}

// creditIndependentVariable marks the document's independent variable — `t` by
// default, or whatever `domain.independent_variable` names — as in-scope.
//
// It is not an entry of any `variables` block, but it is a perfectly legal
// reference: a time-dependent forcing or event trigger spells `sin(t)` /
// `t > 300`, and every `D(v, t)` names it in `wrt`. Without crediting it the
// reference check reported the independent variable itself as an undefined
// variable (tests/valid/events_all_types.esm, cadence/pure_pointwise.esm, …).
func (s *structuralScan) creditIndependentVariable(allVars map[string]bool) {
	allVars[s.indep] = true
}

// creditCoordinateNames marks the document's spatial coordinate names as
// in-scope. Like the independent variable, a coordinate belongs to the DOMAIN,
// not to any `variables` block — v0.8.0 removed `Domain.spatial`, so it has no
// declaration site at all — yet an expression may name it directly (the `x` of
// an expression initial condition, the `dim` of a `grad`). See coordinateNames.
func (s *structuralScan) creditCoordinateNames(allVars map[string]bool) {
	for name := range s.coords {
		allVars[name] = true
	}
}

// equationBoundSymbols returns every binder-introduced symbol an equation
// scopes, collected across BOTH sides (aggregate `output_idx` / `ranges` keys,
// argmin/argmax witnesses, `index` element positions, integral integration
// variables, apply_expression_template parameter names). Mirrors TS
// `collectIndexSymbols` applied to lhs ∪ rhs.
func equationBoundSymbols(eq Equation) map[string]bool {
	bound := map[string]bool{}
	collectBoundSymbols(eq.LHS, bound)
	collectBoundSymbols(eq.RHS, bound)
	return bound
}

// collectBoundSymbols accumulates the binder symbols of every operator node in
// an expression tree, descending through every expression-bearing field.
func collectBoundSymbols(expr Expression, bound map[string]bool) {
	node, ok := asExprNode(expr)
	if !ok {
		return
	}
	for _, sym := range boundIndexSymbols(node) {
		bound[sym] = true
	}
	_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
		collectBoundSymbols(child, bound)
		return child, nil
	})
}

// unionScope returns a new scope holding every name of base plus every name of
// extra. base is never mutated.
func unionScope(base map[string]bool, extra map[string]bool) map[string]bool {
	out := make(map[string]bool, len(base)+len(extra))
	for k, v := range base {
		out[k] = v
	}
	for k := range extra {
		out[k] = true
	}
	return out
}

// validateExprNodeChildren descends every canonical child-Expression field of an
// operator node — args, lower, upper, expr, filter, values, axes, key, bindings,
// in that order — mirroring Rust `ExpressionNode::for_each_child` (src/types.rs)
// and TS `forEachChild` (expression.ts). Descending only `args` (the historical
// behaviour) silently accepted an undefined variable hidden in an aggregate body
// (`expr`), an aggregate `filter`/`key`, integral `lower`/`upper` bounds, a
// `makearray` `values` list, `table_lookup` `axes`, or an
// `apply_expression_template` `bindings` map. Index symbols the node BINDS (see
// boundIndexSymbols) are added to the in-scope set for the descent so a bound
// loop index is not mis-reported as undefined.
//
// Non-child structural slots — `ranges`/`output_idx`/`arg`/`var` (binder
// sources, credited via boundIndexSymbols instead), `join`, `regions`, `attrs`,
// `output` — are intentionally NOT descended, matching for_each_child; join `on`
// operands in particular bind their own symbols and must not surface as
// references.
func (s *structuralScan) validateExprNodeChildren(node ExprNode, allVars map[string]bool, path, currentSystem string) {
	scope := allVars
	if bound := boundIndexSymbols(node); len(bound) > 0 {
		scope = make(map[string]bool, len(allVars)+len(bound))
		for k, v := range allVars {
			scope[k] = v
		}
		for _, sym := range bound {
			scope[sym] = true
		}
	}

	for i, arg := range node.Args {
		s.validateExpressionVariables(arg, scope, fmt.Sprintf("%s/args/%d", path, i), currentSystem)
	}
	if node.Lower != nil {
		s.validateExpressionVariables(node.Lower, scope, path+"/lower", currentSystem)
	}
	if node.Upper != nil {
		s.validateExpressionVariables(node.Upper, scope, path+"/upper", currentSystem)
	}
	if node.Expr != nil {
		s.validateExpressionVariables(node.Expr, scope, path+"/expr", currentSystem)
	}
	if node.Filter != nil {
		s.validateExpressionVariables(node.Filter, scope, path+"/filter", currentSystem)
	}
	for i, v := range node.Values {
		s.validateExpressionVariables(v, scope, fmt.Sprintf("%s/values/%d", path, i), currentSystem)
	}
	for _, k := range sortedKeys(node.TableAxes) {
		s.validateExpressionVariables(node.TableAxes[k], scope, fmt.Sprintf("%s/axes/%s", path, k), currentSystem)
	}
	if node.Key != nil {
		s.validateExpressionVariables(node.Key, scope, path+"/key", currentSystem)
	}
	for _, k := range sortedKeys(node.Bindings) {
		s.validateExpressionVariables(node.Bindings[k], scope, fmt.Sprintf("%s/bindings/%s", path, k), currentSystem)
	}
}

// boundIndexSymbols returns the index / iteration symbols an operator node BINDS
// for its own child expressions — names that are loop positions or invented keys
// rather than declared variables. validateExprNodeChildren adds them to the
// in-scope set for the descent so a bound loop index (the `i` in `index(u, i)`,
// the `e` an aggregate contracts over, an integral's integration variable) is
// not mis-reported as an undefined variable.
//
// Mirrors Rust `bound_index_symbols` (src/structural.rs) and TS
// `collectIndexSymbols` (validate/expr-utils.ts). Binder sources:
//
//   - OutputIdx     — aggregate surviving (free) index names
//   - Ranges keys   — aggregate / argmin / argmax contraction loop variables
//   - Var           — the integral integration variable
//   - Arg           — the argmin / argmax witness index
//   - Args[1:]      — `index(array, i, j, …)` element positions (bare names)
//   - Bindings keys — apply_expression_template formal parameter names
//
// A `skolem` node binds nothing: its `args` are pure key components (references
// to symbols bound by the enclosing aggregate), and its documentary relation
// tag lives in the dedicated `label` field, so its args are checked normally.
func boundIndexSymbols(node ExprNode) []string {
	var syms []string
	for _, idx := range node.OutputIdx {
		if name, ok := idx.(string); ok {
			syms = append(syms, name)
		}
	}
	for k := range node.Ranges {
		syms = append(syms, k)
	}
	if node.Var != nil {
		syms = append(syms, *node.Var)
	}
	if node.Arg != nil {
		syms = append(syms, *node.Arg)
	}
	switch node.Op {
	case "index":
		// index(array, pos1, pos2, …): the positions after the array head that
		// are bare names are bound index symbols.
		for i := 1; i < len(node.Args); i++ {
			if name, ok := node.Args[i].(string); ok {
				syms = append(syms, name)
			}
		}
	}
	for k := range node.Bindings {
		syms = append(syms, k)
	}
	return syms
}

// rawExprNode normalizes a raw decoded-JSON object (map[string]any) that
// represents an operator node into an ExprNode. Sidecar child fields
// (expr/filter/key/lower/upper/values/axes/bindings) are NOT normalized by
// UnmarshalExpression — only `args` is — so an operator node nested inside one
// of them is reached as a decoded map rather than an ExprNode. Routing it back
// through UnmarshalExpression (the same re-marshal path decode.go uses for
// nested args) yields an ExprNode whose own `args` are normalized; its sidecar
// children remain raw and are re-normalized on further descent. Returns
// (ExprNode{}, false) for a map that is not an operator node (no "op") or that
// fails to normalize.
func rawExprNode(m map[string]any) (ExprNode, bool) {
	if _, hasOp := m["op"]; !hasOp {
		return ExprNode{}, false
	}
	b, err := json.Marshal(m)
	if err != nil {
		return ExprNode{}, false
	}
	expr, err := UnmarshalExpression(b)
	if err != nil {
		return ExprNode{}, false
	}
	return asExprNode(expr)
}

// validateAffectTarget checks that an event affect's LHS target variable is
// declared (or resolves as a scoped reference). kind is "affect" or
// "affect_neg" (selects the message suffix) and eventType is "discrete" or
// "continuous" (recorded in Details).
func (s *structuralScan) validateAffectTarget(lhs string, allVars map[string]bool, currentSystem, lhsPath, kind, eventType string) {
	if allVars[lhs] {
		return
	}
	suffix := "in affect equation"
	if kind == "affect_neg" {
		suffix = "in affect_neg equation"
	}
	if s.file != nil && strings.Contains(lhs, ".") {
		if _, resolved := resolveScopedReference(lhs, s.file, currentSystem); !resolved {
			s.addErr(StructuralError{
				Path:    lhsPath,
				Code:    ErrorUnresolvedScopedRef,
				Message: fmt.Sprintf("Unresolved scoped reference '%s' %s", lhs, suffix),
				Details: map[string]any{
					"variable":       lhs,
					"current_system": currentSystem,
					"event_type":     eventType,
				},
			})
		}
		return
	}
	s.addErr(StructuralError{
		Path:    lhsPath,
		Code:    ErrorEventVarUndeclared,
		Message: fmt.Sprintf("Undefined variable '%s' %s", lhs, suffix),
		Details: map[string]any{
			"variable":       lhs,
			"current_system": currentSystem,
			"event_type":     eventType,
		},
	})
}

// validateDiscreteParameters checks that every name in an event's
// `discrete_parameters` list is a DECLARED PARAMETER of the model.
//
// The list names the parameters the event is allowed to write — so a name that
// is not declared at all ("undefined_param") or that is declared as something
// other than a parameter (a STATE variable: `discrete_parameters: ["x"]` where x
// is integrated) is a defect, and the code the shared corpus pins for both is
// `invalid_discrete_param` (tests/invalid/invalid_discrete_param.esm,
// invalid_discrete_param_not_parameter.esm).
func (s *structuralScan) validateDiscreteParameters(names []string, model *Model, path, modelName string) {
	for i, name := range names {
		v, declared := model.Variables[name]
		switch {
		case !declared:
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/discrete_parameters", path),
				Code:    ErrorInvalidDiscreteParam,
				Message: fmt.Sprintf("Discrete parameter '%s' is not declared", name),
				Details: map[string]any{
					"parameter":   name,
					"model":       modelName,
					"index":       i,
					"expected_in": "variables",
				},
			})
		case v.Type != VarTypeParameter:
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/discrete_parameters", path),
				Code:    ErrorInvalidDiscreteParam,
				Message: fmt.Sprintf("Discrete parameter '%s' is declared as a %q, not a parameter", name, v.Type),
				Details: map[string]any{
					"parameter":     name,
					"model":         modelName,
					"index":         i,
					"declared_type": v.Type,
					"expected_type": VarTypeParameter,
				},
			})
		}
	}
}

// validateDiscreteEvent validates discrete event structure.
func (s *structuralScan) validateDiscreteEvent(event *DiscreteEvent, allVars map[string]bool, path, currentSystem string) {
	if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
		s.validateExpressionVariables(event.Trigger.Expression, allVars, fmt.Sprintf("%s/trigger/expression", path), currentSystem)
	}
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s/affects/%d", path, i)
		s.validateAffectTarget(affect.LHS, allVars, currentSystem, fmt.Sprintf("%s/lhs", affectPath), "affect", "discrete")
		s.validateExpressionVariables(affect.RHS, allVars, fmt.Sprintf("%s/rhs", affectPath), currentSystem)
	}
}

// validateContinuousEvent validates continuous event structure.
func (s *structuralScan) validateContinuousEvent(event *ContinuousEvent, allVars map[string]bool, path, currentSystem string) {
	for i, condition := range event.Conditions {
		s.validateExpressionVariables(condition, allVars, fmt.Sprintf("%s/conditions/%d", path, i), currentSystem)
	}
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s/affects/%d", path, i)
		s.validateAffectTarget(affect.LHS, allVars, currentSystem, fmt.Sprintf("%s/lhs", affectPath), "affect", "continuous")
		s.validateExpressionVariables(affect.RHS, allVars, fmt.Sprintf("%s/rhs", affectPath), currentSystem)
	}
	for i, affect := range event.AffectNeg {
		affectPath := fmt.Sprintf("%s/affect_neg/%d", path, i)
		s.validateAffectTarget(affect.LHS, allVars, currentSystem, fmt.Sprintf("%s/lhs", affectPath), "affect_neg", "continuous")
		s.validateExpressionVariables(affect.RHS, allVars, fmt.Sprintf("%s/rhs", affectPath), currentSystem)
	}
}

// validateEquationUnknownBalance emits an equation_count_mismatch error when the
// number of ODE equations does not equal the number of state variables
// (ESM libraries spec Section 3.2.1).
func (s *structuralScan) validateEquationUnknownBalance(modelName string, model *Model, basePath string) {
	nStates, nOdes, missing, extra, message, balanced := computeEquationBalance(model, s.indep)
	if balanced {
		return
	}
	s.addErr(StructuralError{
		Path:    basePath,
		Code:    ErrorEquationCountMismatch,
		Message: message,
		Details: map[string]any{
			"model":             modelName,
			"state_count":       nStates,
			"ode_count":         nOdes,
			"missing_equations": missing,
			"extra_equations":   extra,
		},
	})
}

// computeEquationBalance counts state variables and defining equations for a
// model and reports the balance outcome. It is BIDIRECTIONAL: it reports both
// state variables that no equation defines (missing) and equations that define
// something which is not a state variable (extra).
//
// What counts as "an equation that defines state variable v" (mirrors TS
// validateEquationBalance / countDerivatives / lhsAssignmentTarget):
//
//   - a time derivative `D(v, t)` ANYWHERE in the LHS — including the
//     ARRAY FORM, where the derivative is carried inside an aggregate's
//     contracted body (`aggregate(output_idx:[i], expr: D(index(v, i)))`)
//     rather than in `args`. Only looking for a top-level `D` LHS is what made
//     Go reject two dozen perfectly good aggregate/geometry fixtures with
//     "0 ODE equations";
//   - failing that, an ALGEBRAIC/relational equation whose LHS assigns to a
//     state variable (`v ~ f(...)`, `index(v, i) ~ aggregate(...)`), which
//     credits that variable — element-defined and observed-style state still
//     balances the unknown count.
//
// An `ic` equation defines an initial value, not the dynamics, so it never
// credits a variable (its LHS op is neither D nor an assignment target).
//
// An ALGEBRAIC model (`system_kind: "nonlinear"`) is balanced the same way, but
// on the general statement of the rule — UNKNOWNS versus EQUATIONS — because it
// has no derivatives at all: its unknowns are determined by algebraic equations
// whose LHS is an arbitrary EXPRESSION, not an assignment target (ISORROPIA's
// solubility product is spelled `H*H*SO4 ~ Ksp`). Counting derivatives there
// yields "0 ODE equations for 2 state variables" and rejects a perfectly
// balanced 2×2 system, which is why the check used to be skipped outright for
// every non-ODE kind. See nonlinearEquationBalance.
//
// Two carve-outs still skip the check entirely:
//
//   - a model whose SystemKind is sde / pde / dae — the balance rule for those
//     is not the plain unknown count (a `pde` carries spatial operators, an
//     `sde` a Brownian term, a `dae` explicit constraints);
//   - a model with SUBSYSTEMS holds its dynamics in those subsystems, so its own
//     `equations` list may legitimately be empty while it declares state
//     variables (tests/valid/scoped_refs_coupling.esm). Only a subsystem-free
//     model owes an equation for each of its state variables.
func computeEquationBalance(model *Model, indep string) (nStates, nOdes int, missing, extra []string, message string, balanced bool) {
	if len(model.Subsystems) > 0 {
		return 0, 0, nil, nil, "", true
	}
	if isAlgebraicSystem(model) {
		return nonlinearEquationBalance(model)
	}
	if !isDAETargetSystem(model) {
		return 0, 0, nil, nil, "", true
	}

	stateVars := make(map[string]bool)
	for varName, variable := range model.Variables {
		if variable.Type == VarTypeState {
			stateVars[varName] = true
		}
	}
	nStates = len(stateVars)

	definedVars := make(map[string]bool)
	extraSet := make(map[string]bool)
	for _, eq := range model.Equations {
		derivatives := countDerivatives(eq.LHS, indep)
		if len(derivatives) > 0 {
			for varName, count := range derivatives {
				nOdes += count
				// A SCOPED target (`D(Chemistry.O3, t)`) drives a variable owned by
				// ANOTHER system; it is not this model's unknown and says nothing
				// about this model's balance. The reference check already validates
				// that the scoped name resolves.
				if strings.Contains(varName, ".") {
					continue
				}
				if stateVars[varName] {
					definedVars[varName] = true
				} else {
					extraSet[varName] = true
				}
			}
			continue
		}
		// A non-differential equation credits the state variable its LHS assigns
		// to: an algebraic/relational definition (`v ~ f(...)`,
		// `index(v,i) ~ aggregate(...)`), or an `ic` prescription — a state variable
		// with an initial condition and no dynamics is a PRESCRIBED field, held at
		// its initial value and typically exported to other models through a
		// coupling (tests/valid/wildfire_atmosphere_ocean.esm's wind_u/wind_v).
		target := extractVariableFromLHS(eq.LHS)
		if target == "" {
			if node, ok := asExprNode(eq.LHS); ok && node.Op == OpIC && len(node.Args) > 0 {
				target = extractVariableFromLHS(node.Args[0])
			}
		}
		if target != "" && stateVars[target] {
			definedVars[target] = true
		}
	}

	missing = []string{}
	for varName := range stateVars {
		if !definedVars[varName] {
			missing = append(missing, varName)
		}
	}
	extra = []string{}
	for varName := range extraSet {
		extra = append(extra, varName)
	}
	sort.Strings(missing)
	sort.Strings(extra)

	if len(missing) == 0 && len(extra) == 0 {
		return nStates, nOdes, nil, nil, "", true
	}

	message = fmt.Sprintf("Equation-unknown balance failed: found %d state variables but %d ODE equations", nStates, nOdes)
	if len(missing) > 0 {
		message += fmt.Sprintf("; state variables without ODE equations: %v", missing)
	}
	if len(extra) > 0 {
		message += fmt.Sprintf("; ODE equations for non-state variables: %v", extra)
	}
	return nStates, nOdes, missing, extra, message, false
}

// isAlgebraicSystem reports whether a model is purely algebraic
// (`system_kind: "nonlinear"`): its unknowns are determined by algebraic
// equations and it carries no derivatives.
func isAlgebraicSystem(model *Model) bool {
	return model.SystemKind != nil && *model.SystemKind == SystemKindNonlinear
}

// nonlinearEquationBalance balances an ALGEBRAIC model: the number of UNKNOWNS
// (state variables) against the number of EQUATIONS.
//
// A nonlinear system has no derivatives, and its equations need not have an
// assignment target: ISORROPIA's charge balance is `H ~ 2*SO4` (a bare target)
// but its solubility product is `H*H*SO4 ~ Ksp` — an expression on the left,
// crediting no single variable. The balance is therefore a COUNT, not a
// per-variable credit: 2 equations determine 2 unknowns
// (tests/valid/nonlinear_isorropia_shape.esm), and it is square-ness, not
// assignment shape, that the solver requires.
//
// `ic`-op equations prescribe an initial guess, not a determining equation, so
// they do not count (initialization_equations live in their own field and are
// never in `equations`).
func nonlinearEquationBalance(model *Model) (nStates, nEqs int, missing, extra []string, message string, balanced bool) {
	for _, variable := range model.Variables {
		if variable.Type == VarTypeState {
			nStates++
		}
	}
	for _, eq := range model.Equations {
		if node, ok := asExprNode(eq.LHS); ok && node.Op == OpIC {
			continue
		}
		nEqs++
	}
	if nStates == nEqs {
		return nStates, nEqs, nil, nil, "", true
	}
	message = fmt.Sprintf(
		"Equation-unknown balance failed: found %d state variables but %d algebraic equations",
		nStates, nEqs)
	return nStates, nEqs, []string{}, []string{}, message, false
}

// countDerivatives returns, per variable, how many time derivatives of it an
// expression carries. It walks EVERY expression-bearing field (the shared
// field-preserving walk), so it finds the `D` an array-form equation hides in an
// aggregate's `expr`, not just a `D` at the root of `args`. Mirrors TS
// countDerivatives (validate/expr-utils.ts).
//
// Only derivatives with respect to the document's independent variable count; a
// SPATIAL `D` (wrt a coordinate) is a rewrite target, not an ODE. A `D` with no
// explicit `wrt` is treated as differential in the independent variable, the
// same convention isDifferentialEquation uses.
func countDerivatives(expr Expression, indep string) map[string]int {
	derivatives := map[string]int{}

	var walk func(Expression)
	walk = func(e Expression) {
		node, ok := asExprNode(e)
		if !ok {
			return
		}
		if node.Op == OpDerivative && len(node.Args) > 0 &&
			(node.Wrt == nil || *node.Wrt == indep) {
			if target := extractVariableFromLHS(node.Args[0]); target != "" {
				derivatives[target]++
			}
		}
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walk(child)
			return child, nil
		})
	}
	walk(expr)

	return derivatives
}

// validateReactionSystem checks reaction system-specific structural rules.
func (s *structuralScan) validateReactionSystem(systemName string, system *ReactionSystem) {
	basePath := fmt.Sprintf("/reaction_systems/%s", systemName)

	allSpecies := make(map[string]bool)
	for speciesName := range system.Species {
		allSpecies[speciesName] = true
	}
	// Combined names available to rate expressions (species + parameters, plus
	// the document-scoped `index_sets` names — see validateModel).
	allVars := make(map[string]bool)
	for name := range system.Species {
		allVars[name] = true
	}
	for name := range system.Parameters {
		allVars[name] = true
	}
	s.creditIndexSetNames(allVars)
	s.creditIndependentVariable(allVars)
	s.creditCoordinateNames(allVars)

	for i, reaction := range system.Reactions {
		reactionPath := fmt.Sprintf("%s/reactions/%d", basePath, i)

		// A reaction with neither substrates nor products carries no mass
		// transfer and is rejected.
		if len(reaction.Substrates) == 0 && len(reaction.Products) == 0 {
			s.addErr(StructuralError{
				Path:    reactionPath,
				Code:    ErrorNullReaction,
				Message: "Reaction has no substrates and no products",
				Details: map[string]any{
					"reaction_index": i,
					"system":         systemName,
				},
			})
		}

		// Legacy-only warnings: duplicate substrate/product species. These have
		// no code-bearing representation and are surfaced only on the legacy
		// (message-oriented) validation surface.
		s.reportDuplicateSpecies(reaction.Substrates, "substrates", reactionPath)
		s.reportDuplicateSpecies(reaction.Products, "products", reactionPath)

		for j, substrate := range reaction.Substrates {
			if !allSpecies[substrate.Species] {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s/substrates/%d/species", reactionPath, j),
					Code:    ErrorUndefinedSpecies,
					Message: fmt.Sprintf("Undefined species '%s' in reaction substrate", substrate.Species),
					Details: map[string]any{
						"species":         substrate.Species,
						"system":          systemName,
						"reaction_index":  i,
						"substrate_index": j,
					},
				})
			}
		}
		for j, product := range reaction.Products {
			if !allSpecies[product.Species] {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s/products/%d/species", reactionPath, j),
					Code:    ErrorUndefinedSpecies,
					Message: fmt.Sprintf("Undefined species '%s' in reaction product", product.Species),
					Details: map[string]any{
						"species":        product.Species,
						"system":         systemName,
						"reaction_index": i,
						"product_index":  j,
					},
				})
			}
		}

		// A RATE EXPRESSION may name anything a species/parameter of this system,
		// a document-scoped index set, the independent variable, a spatial
		// coordinate — or a SCOPED REFERENCE into another system
		// (`Meteorology.Temperature.surface_temp`, an Arrhenius rate reading a
		// coupled model's temperature). validateExpressionVariables resolves the
		// dotted forms through resolveScopedReference, which walks the subsystem
		// chain to ARBITRARY DEPTH; an undeclared BARE name in a rate is reported
		// as `undefined_parameter`, the code the shared corpus pins for it
		// (tests/invalid/undefined_parameter*.esm).
		s.withUndefinedCode(ErrorUndefinedParameter, func() {
			s.validateExpressionVariables(reaction.Rate, allVars, fmt.Sprintf("%s/rate", reactionPath), systemName)
		})
	}

	// v0.8.0 §11.4.1: an `ic`-op equation MUST NOT appear inside a reaction
	// system's `constraint_equations`. A reaction system has no `equations`
	// field and hosts no ICs — a species' initial value is its scalar
	// `species.default`, or a scoped-reference `ic` equation in a MODEL. The
	// document is schema-valid (`constraint_equations` is an array of Equation
	// and `ic` is a legal op) but is rejected here structurally.
	for i, eq := range system.ConstraintEquations {
		node, ok := asExprNode(eq.LHS)
		if !ok || node.Op != OpIC {
			continue
		}
		species := ""
		if len(node.Args) > 0 {
			if sp, ok := node.Args[0].(string); ok {
				species = sp
			}
		}
		s.addErr(StructuralError{
			Path: fmt.Sprintf("/reaction_systems/%s/constraint_equations/%d", systemName, i),
			Code: ErrorIcInReactionSystem,
			Message: "ic equation not allowed in a reaction system; a reaction system has no equations " +
				"field and hosts no ic equations (ICs are model-hosted: species.default, or a " +
				"scoped-reference ic equation in a model, spec §11.4.1)",
			Details: map[string]any{
				"system":                    systemName,
				"species":                   species,
				"constraint_equation_index": i,
			},
		})
	}
}

// reportDuplicateSpecies records a warning-level StructuralError for each
// species that appears more than once in a substrate/product list. side is
// "substrates" or "products". The finding is advisory — it does not invalidate
// the document — and is surfaced on both validation surfaces.
func (s *structuralScan) reportDuplicateSpecies(entries []SubstrateProduct, side, reactionPath string) {
	seen := make(map[string]int)
	for i, entry := range entries {
		if first, exists := seen[entry.Species]; exists {
			s.addWarning(
				CodeDuplicateReactionSpecies,
				fmt.Sprintf("%s/%s", reactionPath, side),
				fmt.Sprintf("Species '%s' appears multiple times in %s (positions %d and %d)", entry.Species, side, first, i),
				map[string]any{"species": entry.Species, "side": side, "positions": []int{first, i}},
			)
		}
		seen[entry.Species] = i
	}
}

// validateCouplingReferences validates that coupling entries reference declared systems.
func (s *structuralScan) validateCouplingReferences() {
	allSystems := couplableSystemNames(s.file)

	for i, coupling := range s.file.Coupling {
		basePath := fmt.Sprintf("/coupling/%d", i)

		switch c := coupling.(type) {
		case OperatorComposeCoupling:
			s.validateCouplingSystems(c.Systems[:], allSystems, basePath, "operator_compose", i)
		case CouplingCouple:
			s.validateCouplingSystems(c.Systems[:], allSystems, basePath, "couple", i)
		case VariableMapCoupling:
			// from/to are scoped references ("System.var", or a deeper
			// "Model.Subsystem.var") — see validateCouplingEndpoint.
			s.validateCouplingEndpoint(c.From, allSystems, fmt.Sprintf("%s/from", basePath), "from", i)
			s.validateCouplingEndpoint(c.To, allSystems, fmt.Sprintf("%s/to", basePath), "to", i)
		case OperatorApplyCoupling:
			// `operator_apply` was removed in v0.3.0 along with the top-level
			// `operators` block. Surface a structural error if a v0.2.x file
			// reaches this validator via direct unmarshaling.
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/operator", basePath),
				Code:    ErrorUndefinedOperator,
				Message: fmt.Sprintf("'operator_apply' coupling has been removed (v0.3.0); referenced operator '%s'", c.Operator),
				Details: map[string]any{
					"operator":       c.Operator,
					"coupling_type":  "operator_apply",
					"coupling_index": i,
				},
			})
		case CallbackCoupling:
			// Validated by schema; no additional structural checks needed.
		case EventCoupling:
			// Validated by schema; no additional structural checks needed.
		}
	}
}

// validateCouplingEndpoint checks one end of a `variable_map` coupling.
//
// A coupling endpoint is a SCOPED REFERENCE of ARBITRARY DEPTH (esm-spec §4.6):
// "Transport.u" names a variable of a top-level system, and
// "Meteorology.Temperature.surface_temp" names one inside a nested subsystem.
// Splitting on '.' and reading segment [0] as the system and [1] as the variable
// cannot see past the first level: it validated only that "Meteorology" exists
// and never checked that the rest of the path resolves at all.
//
// The whole path is therefore resolved with resolveScopedReference, which walks
// the subsystem chain to any depth (and knows that a data loader is a scopable
// namespace too). What is reported depends on WHERE it failed:
//
//   - the root system does not exist    → `undefined_system` (the coupling names
//     a system the document does not have) AND `unresolved_scoped_ref` (the
//     reference does not resolve). The shared corpus pins the same shape under
//     both codes — undefined_system.esm and unresolved_scoped_ref.esm are the
//     same defect — so both are emitted.
//   - the system exists, the tail does not → `unresolved_scoped_ref`
//     (tests/invalid/unresolved_scoped_ref_missing_variable.esm).
func (s *structuralScan) validateCouplingEndpoint(ref string, allSystems map[string]bool, path, direction string, couplingIndex int) {
	if ref == "" {
		return
	}
	root, _, dotted := strings.Cut(ref, ".")
	if !dotted {
		// A bare endpoint names a system directly.
		if !allSystems[ref] {
			s.addUndefinedSystem(ref, ref, path, direction, couplingIndex)
		}
		return
	}
	if s.file == nil {
		return
	}
	if _, resolved := resolveScopedReference(ref, s.file, ""); resolved {
		return
	}
	// It did not resolve. Does the ROOT of the path name a system at all?
	rootExists := allSystems[root] || subsystemPathExists(ref, s.file)
	if !rootExists {
		s.addUndefinedSystem(root, ref, path, direction, couplingIndex)
	}
	s.addErr(StructuralError{
		Path:    path,
		Code:    ErrorUnresolvedScopedRef,
		Message: fmt.Sprintf("Unresolved scoped reference '%s' in coupling (%s)", ref, direction),
		Details: map[string]any{
			"variable":       ref,
			"scoped_ref":     ref,
			"system":         root,
			"coupling_type":  "variable_map",
			"coupling_index": couplingIndex,
			"direction":      direction,
		},
	})
}

// addUndefinedSystem records a coupling entry that names a system the document
// does not declare.
func (s *structuralScan) addUndefinedSystem(system, ref, path, direction string, couplingIndex int) {
	s.addErr(StructuralError{
		Path:    path,
		Code:    ErrorUndefinedSystem,
		Message: fmt.Sprintf("Undefined system '%s' in coupling (%s '%s')", system, direction, ref),
		Details: map[string]any{
			"system":         system,
			"scoped_ref":     ref,
			"reference":      ref,
			"coupling_type":  "variable_map",
			"coupling_index": couplingIndex,
			"direction":      direction,
			"expected_in":    "models, reaction_systems, data_loaders",
		},
	})
}

// validateSubsystemRefs reports every subsystem entry that is still an
// UNRESOLVED `{"ref": …}` object at validation time.
//
// Load() resolves refs (and fails loudly with `unresolved_subsystem_ref` /
// `ambiguous_subsystem_ref` when it cannot), so a ref that survives to
// validation means the document was never resolved against a base path — the
// reference is, as far as the validator can see, unresolved. Mirrors TS
// validate/coupling-checks.ts `validateSubsystemRefs`.
func (s *structuralScan) validateSubsystemRefs() {
	if s.file == nil {
		return
	}
	for _, modelName := range sortedKeys(s.file.Models) {
		s.flagRefSubsystems(s.file.Models[modelName].Subsystems,
			fmt.Sprintf("/models/%s/subsystems", modelName), modelName)
	}
	for _, systemName := range sortedKeys(s.file.ReactionSystems) {
		s.flagRefSubsystems(s.file.ReactionSystems[systemName].Subsystems,
			fmt.Sprintf("/reaction_systems/%s/subsystems", systemName), systemName)
	}
}

func (s *structuralScan) flagRefSubsystems(subsystems map[string]any, pathPrefix, parent string) {
	for _, name := range sortedKeys(subsystems) {
		ref, _, isRef := extractRefWithBindings(subsystems[name])
		if !isRef {
			continue
		}
		s.addErr(StructuralError{
			Path: fmt.Sprintf("%s/%s", pathPrefix, name),
			Code: CodeUnresolvedSubsystemRef,
			Message: fmt.Sprintf("Subsystem reference '%s' could not be resolved — "+
				"resolve subsystem refs (Load, or ResolveSubsystemRefs) before validating", ref),
			Details: map[string]any{
				"ref":       ref,
				"subsystem": name,
				"parent":    parent,
			},
		})
	}
}

// validateCircularReferences reports a cycle in the cross-model reference graph.
//
// A model DEPENDS on another when one of its equations reads a scoped reference
// into it (`ModelA.x ~ … ModelB.y …`). Two models that read each other cannot be
// ordered — neither can be evaluated first — so the composition is unrealizable
// (tests/invalid/circular_coupling.esm). Mirrors TS
// validate/coupling-checks.ts `validateCircularReferences`.
func (s *structuralScan) validateCircularReferences() {
	if s.file == nil || len(s.file.Models) == 0 {
		return
	}
	deps := map[string]map[string]bool{}
	for _, modelName := range sortedKeys(s.file.Models) {
		model := s.file.Models[modelName]
		d := map[string]bool{}
		for _, eq := range model.Equations {
			for name := range FreeVariables(eq.LHS) {
				addModelDep(d, name, modelName, s.file)
			}
			for name := range FreeVariables(eq.RHS) {
				addModelDep(d, name, modelName, s.file)
			}
		}
		deps[modelName] = d
	}

	visited := map[string]bool{}
	inStack := map[string]bool{}
	reported := map[string]bool{}

	var dfs func(node string, path []string)
	dfs = func(node string, path []string) {
		if inStack[node] {
			// Close the cycle at its first occurrence in the current path.
			start := 0
			for i, p := range path {
				if p == node {
					start = i
					break
				}
			}
			cycle := append(append([]string{}, path[start:]...), node)
			key := strings.Join(cycle, "→")
			if reported[key] {
				return
			}
			reported[key] = true
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("/models/%s", cycle[0]),
				Code:    ErrorCircularDependency,
				Message: fmt.Sprintf("Circular coupling detected: %s", strings.Join(cycle, " → ")),
				Details: map[string]any{"cycle": cycle},
			})
			return
		}
		if visited[node] {
			return
		}
		visited[node] = true
		inStack[node] = true
		path = append(path, node)
		for _, dep := range sortedKeysOfSet(deps[node]) {
			dfs(dep, path)
		}
		inStack[node] = false
	}
	for _, modelName := range sortedKeys(s.file.Models) {
		dfs(modelName, nil)
	}
}

// addModelDep records a dependency on the model a scoped reference names, if it
// names one other than the referring model itself.
func addModelDep(deps map[string]bool, ref, self string, file *ESMFile) {
	root, _, dotted := strings.Cut(ref, ".")
	if !dotted || root == self {
		return
	}
	if _, isModel := file.Models[root]; isModel {
		deps[root] = true
	}
}

// sortedKeysOfSet returns the members of a string set in deterministic order.
func sortedKeysOfSet(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// couplableSystemNames returns every name a coupling entry may legally reference
// as a "system": a model, a reaction system, OR A DATA LOADER.
//
// A data loader is a first-class coupling endpoint — `variable_map` exists
// precisely to wire a loader's variables into a model
// (`from: "GEOSFP_MeteoData.u"`, `to: "Transport.u"`). Omitting loaders from
// this namespace made Go reject every document that does so, with a spurious
// `undefined_system` on the loader and an `unresolved_scoped_ref` on each of its
// variables (audit G7; tests/valid/data_loaders_comprehensive.esm,
// full_coupled.esm, model_only.esm, reaction_system_only.esm). TS has always
// included them (validate/coupling-checks.ts `availableSystems`).
func couplableSystemNames(file *ESMFile) map[string]bool {
	names := make(map[string]bool, len(file.Models)+len(file.ReactionSystems)+len(file.DataLoaders))
	for name := range file.Models {
		names[name] = true
	}
	for name := range file.ReactionSystems {
		names[name] = true
	}
	for name := range file.DataLoaders {
		names[name] = true
	}
	return names
}

// validateCouplingSystems reports undefined systems for the list-based coupling
// kinds (operator_compose, couple).
//
// A `systems` entry may name a SUBSYSTEM by its dotted path
// ("AtmosphericChemistry.Aerosols"), which is a legal coupling endpoint, so a
// dotted name that resolves through the subsystem hierarchy is accepted too.
func (s *structuralScan) validateCouplingSystems(systems []string, allSystems map[string]bool, basePath, couplingType string, couplingIndex int) {
	for j, sysName := range systems {
		if allSystems[sysName] {
			continue
		}
		if s.file != nil && strings.Contains(sysName, ".") && subsystemPathExists(sysName, s.file) {
			continue
		}
		s.addErr(StructuralError{
			Path:    fmt.Sprintf("%s/systems/%d", basePath, j),
			Code:    ErrorUndefinedSystem,
			Message: fmt.Sprintf("Undefined system '%s' in coupling", sysName),
			Details: map[string]any{
				"system":         sysName,
				"coupling_type":  couplingType,
				"coupling_index": couplingIndex,
				"system_index":   j,
			},
		})
	}
}

// validateDataLoaderReferences validates data loader configurations.
func (s *structuralScan) validateDataLoaderReferences() {
	for loaderName, loader := range s.file.DataLoaders {
		basePath := fmt.Sprintf("/data_loaders/%s", loaderName)

		if loader.Kind == "" {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/kind", basePath),
				Code:    CodeMissingLoaderKind,
				Message: "Data loader kind is required",
				Details: map[string]any{"loader": loaderName},
			})
		}
		if loader.Source.URLTemplate == "" {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/source/url_template", basePath),
				Code:    CodeMissingLoaderSourceURLTemplate,
				Message: "Data loader source.url_template is required",
				Details: map[string]any{"loader": loaderName},
			})
		}
		if len(loader.Variables) == 0 {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s/variables", basePath),
				Code:    CodeMissingLoaderVariables,
				Message: "Data loader must expose at least one variable",
				Details: map[string]any{"loader": loaderName},
			})
		}
		for varName, dv := range loader.Variables {
			if dv.FileVariable == "" {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s/variables/%s/file_variable", basePath, varName),
					Code:    CodeMissingLoaderVariableFileVariable,
					Message: "Data loader variable missing file_variable",
					Details: map[string]any{"loader": loaderName, "variable": varName},
				})
			}
			if dv.Units == "" {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s/variables/%s/units", basePath, varName),
					Code:    CodeMissingLoaderVariableUnits,
					Message: "Data loader variable missing units",
					Details: map[string]any{"loader": loaderName, "variable": varName},
				})
			}
		}
	}
}
