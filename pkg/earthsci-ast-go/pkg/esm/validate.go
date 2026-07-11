package esm

import (
	"fmt"
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
	// Path locates the relevant component. It is currently emitted in one of
	// three dialects depending on which check produced it: a JSONPath-like
	// dotted form ("$.models.x.equations[0]"), an RFC 6901 JSON Pointer
	// ("/reaction_systems/x/constraint_equations/0"), or a bare dotted form
	// ("models.x.equations[0]"). Consumers must not assume a single format;
	// unifying the dialects is deferred to preserve cross-language output.
	Path    string         `json:"path"`
	Code    string         `json:"code"`    // Machine-readable error code
	Message string         `json:"message"` // Human-readable description
	Details map[string]any `json:"details"` // Additional context
}

// UnitWarning represents dimensional inconsistencies
type UnitWarning struct {
	Path     string `json:"path"`      // location of the equation or expression (same multi-dialect caveat as StructuralError.Path)
	Message  string `json:"message"`   // Human-readable description
	LhsUnits string `json:"lhs_units"` // Inferred units of the LHS
	RhsUnits string `json:"rhs_units"` // Inferred units of the RHS
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

	// Perform structural validation with structured error codes
	structuralResult := ValidateStructuralWithCodes(file)

	// Use the structured validation results directly
	result.StructuralErrors = structuralResult.StructuralErrors
	result.UnitWarnings = structuralResult.UnitWarnings

	// Update IsValid based on both schema and structural errors
	result.IsValid = len(result.SchemaErrors) == 0 && len(result.StructuralErrors) == 0

	return result
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
			Path:    "$",
		})
		return result
	}

	errs, legacyWarnings := collectStructuralErrors(file)
	for _, se := range errs {
		result.Messages = append(result.Messages, structuralErrorToLegacyMessage(se))
	}
	result.Messages = append(result.Messages, legacyWarnings...)

	// A structural error (any adapted error-level message) invalidates the
	// document; legacy-only warnings do not.
	result.Valid = len(errs) == 0
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
			Path:    "$",
			Code:    CodeValidationFailed,
			Message: fmt.Sprintf("Basic validation failed: %v", err),
			Details: map[string]any{},
		})
		result.Valid = false
		return result
	}

	// Single structural traversal (shared with the legacy surface).
	errs, _ := collectStructuralErrors(file)
	result.StructuralErrors = append(result.StructuralErrors, errs...)

	// Unit/dimensional checks (code-bearing surface only).
	for modelName, model := range file.Models {
		model := model
		validateModelUnits(modelName, &model, fmt.Sprintf("$.models.%s", modelName), file, result)
	}
	for systemName, system := range file.ReactionSystems {
		system := system
		validateReactionSystemUnits(systemName, &system, fmt.Sprintf("$.reaction_systems.%s", systemName), result)
		validateReactionRateUnits(systemName, &system, fmt.Sprintf("/reaction_systems/%s", systemName), result)
	}

	// Task 3.4: Valid is computed once from the accumulated errors so that
	// checks appending StructuralErrors need not maintain the flag themselves.
	result.Valid = len(result.StructuralErrors) == 0
	return result
}

// structuralErrorToLegacyMessage adapts a code-bearing StructuralError to the
// legacy ValidationMessage rendering used by Validate/ValidateStructural. The
// legacy wording is conformance-pinned by the Go test suite, so this table is
// the single point that reproduces it:
//
//   - reference checks emitted "Unknown …" where the code-bearing track emits
//     "Undefined …"; the first such word is rewritten;
//   - every structural error maps to level "error" (including
//     unknown_expression_type, which the pre-unification legacy track logged as
//     a warning — the unified contract treats it as an error in both tracks).
//
// All other wording is identical between the two tracks and passes through.
func structuralErrorToLegacyMessage(se StructuralError) ValidationMessage {
	msg := se.Message
	switch se.Code {
	case ErrorUndefinedVariable, ErrorUndefinedSpecies, ErrorUndefinedSystem, ErrorEventVarUndeclared:
		msg = strings.Replace(msg, "Undefined", "Unknown", 1)
	}
	return ValidationMessage{Level: "error", Message: msg, Path: se.Path}
}

// structuralScan performs the single structural traversal that backs both
// validation surfaces. It accumulates code-bearing StructuralErrors plus the
// legacy-only warnings (duplicate substrate/product) that have no code-bearing
// representation.
type structuralScan struct {
	file           *ESMFile
	indep          string
	errors         []StructuralError
	legacyWarnings []ValidationMessage
}

func (s *structuralScan) addErr(se StructuralError) { s.errors = append(s.errors, se) }

func (s *structuralScan) addLegacyWarning(path, message string) {
	s.legacyWarnings = append(s.legacyWarnings, ValidationMessage{
		Level:   "warning",
		Message: message,
		Path:    path,
	})
}

// collectStructuralErrors runs the unified structural traversal and returns the
// code-bearing errors together with legacy-only warnings.
func collectStructuralErrors(file *ESMFile) ([]StructuralError, []ValidationMessage) {
	s := &structuralScan{file: file, indep: fileIndepVar(file)}

	for modelName, model := range file.Models {
		model := model
		s.validateModel(modelName, &model)
	}
	for systemName, system := range file.ReactionSystems {
		system := system
		s.validateReactionSystem(systemName, &system)
	}
	s.validateCouplingReferences()
	s.validateDataLoaderReferences()

	return s.errors, s.legacyWarnings
}

// validateModel checks model-specific structural rules.
func (s *structuralScan) validateModel(modelName string, model *Model) {
	basePath := fmt.Sprintf("$.models.%s", modelName)

	allVars := make(map[string]bool)
	for varName := range model.Variables {
		allVars[varName] = true
	}

	for i, eq := range model.Equations {
		eqPath := fmt.Sprintf("%s.equations[%d]", basePath, i)
		s.validateExpressionVariables(eq.LHS, allVars, fmt.Sprintf("%s.lhs", eqPath), modelName)
		s.validateExpressionVariables(eq.RHS, allVars, fmt.Sprintf("%s.rhs", eqPath), modelName)
	}

	// Equation-unknown balance validation (Section 3.2.1).
	s.validateEquationUnknownBalance(modelName, model, basePath)

	// Observed variables must carry an expression.
	for varName, variable := range model.Variables {
		if variable.Type == VarTypeObserved && variable.Expression == nil {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s.variables.%s", basePath, varName),
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
		s.validateDiscreteEvent(&event, allVars, fmt.Sprintf("%s.discrete_events[%d]", basePath, i), modelName)
	}
	for i, event := range model.ContinuousEvents {
		event := event
		s.validateContinuousEvent(&event, allVars, fmt.Sprintf("%s.continuous_events[%d]", basePath, i), modelName)
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
			Code:    ErrorUndefinedVariable,
			Message: fmt.Sprintf("Undefined variable '%s'", e),
			Details: map[string]any{
				"variable":       e,
				"current_system": currentSystem,
			},
		})
	case ExprNode:
		for i, arg := range e.Args {
			s.validateExpressionVariables(arg, allVars, fmt.Sprintf("%s.args[%d]", path, i), currentSystem)
		}
	case float64, float32, int, int32, int64:
		// Numeric literals are always valid. This mirrors the numeric types the
		// JSON unmarshaler emits (integers lower to int64) and the set the unit
		// propagator recognizes, so an integer literal is not misreported as an
		// unknown expression type.
	default:
		s.addErr(StructuralError{
			Path:    path,
			Code:    CodeUnknownExpressionType,
			Message: fmt.Sprintf("Unknown expression type: %T", e),
			Details: map[string]any{"type": fmt.Sprintf("%T", e)},
		})
	}
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

// validateDiscreteEvent validates discrete event structure.
func (s *structuralScan) validateDiscreteEvent(event *DiscreteEvent, allVars map[string]bool, path, currentSystem string) {
	if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
		s.validateExpressionVariables(event.Trigger.Expression, allVars, fmt.Sprintf("%s.trigger.expression", path), currentSystem)
	}
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s.affects[%d]", path, i)
		s.validateAffectTarget(affect.LHS, allVars, currentSystem, fmt.Sprintf("%s.lhs", affectPath), "affect", "discrete")
		s.validateExpressionVariables(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), currentSystem)
	}
}

// validateContinuousEvent validates continuous event structure.
func (s *structuralScan) validateContinuousEvent(event *ContinuousEvent, allVars map[string]bool, path, currentSystem string) {
	for i, condition := range event.Conditions {
		s.validateExpressionVariables(condition, allVars, fmt.Sprintf("%s.conditions[%d]", path, i), currentSystem)
	}
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s.affects[%d]", path, i)
		s.validateAffectTarget(affect.LHS, allVars, currentSystem, fmt.Sprintf("%s.lhs", affectPath), "affect", "continuous")
		s.validateExpressionVariables(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), currentSystem)
	}
	for i, affect := range event.AffectNeg {
		affectPath := fmt.Sprintf("%s.affect_neg[%d]", path, i)
		s.validateAffectTarget(affect.LHS, allVars, currentSystem, fmt.Sprintf("%s.lhs", affectPath), "affect_neg", "continuous")
		s.validateExpressionVariables(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), currentSystem)
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

// computeEquationBalance counts state variables and ODE equations for a model
// and reports the balance outcome. An equation is an ODE when its LHS is a
// derivative with respect to the document's independent variable (see
// isDifferentialEquation), which also treats an implicit (nil) wrt as
// differential — matching the DAE contract's classification. When unbalanced it
// returns the state variables lacking ODEs (missing), the ODE targets that are
// not state variables (extra), and the assembled diagnostic message.
func computeEquationBalance(model *Model, indep string) (nStates, nOdes int, missing, extra []string, message string, balanced bool) {
	stateVars := make(map[string]bool)
	for varName, variable := range model.Variables {
		if variable.Type == VarTypeState {
			stateVars[varName] = true
		}
	}
	nStates = len(stateVars)

	odeEquations := make(map[string]bool)
	for _, eq := range model.Equations {
		if !isDifferentialEquation(eq, indep) {
			continue
		}
		nOdes++
		if node, ok := exprAsNode(eq.LHS); ok && len(node.Args) > 0 {
			if varName, ok := node.Args[0].(string); ok {
				odeEquations[varName] = true
			}
		}
	}

	if nOdes == nStates {
		return nStates, nOdes, nil, nil, "", true
	}

	missing = []string{}
	for varName := range stateVars {
		if !odeEquations[varName] {
			missing = append(missing, varName)
		}
	}
	extra = []string{}
	for varName := range odeEquations {
		if !stateVars[varName] {
			extra = append(extra, varName)
		}
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

// validateReactionSystem checks reaction system-specific structural rules.
func (s *structuralScan) validateReactionSystem(systemName string, system *ReactionSystem) {
	basePath := fmt.Sprintf("$.reaction_systems.%s", systemName)

	allSpecies := make(map[string]bool)
	for speciesName := range system.Species {
		allSpecies[speciesName] = true
	}
	// Combined names available to rate expressions (species + parameters).
	allVars := make(map[string]bool)
	for name := range system.Species {
		allVars[name] = true
	}
	for name := range system.Parameters {
		allVars[name] = true
	}

	for i, reaction := range system.Reactions {
		reactionPath := fmt.Sprintf("%s.reactions[%d]", basePath, i)

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
					Path:    fmt.Sprintf("%s.substrates[%d].species", reactionPath, j),
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
					Path:    fmt.Sprintf("%s.products[%d].species", reactionPath, j),
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

		s.validateExpressionVariables(reaction.Rate, allVars, fmt.Sprintf("%s.rate", reactionPath), systemName)
	}

	// v0.8.0 §11.4.1: an `ic`-op equation MUST NOT appear inside a reaction
	// system's `constraint_equations`. A reaction system has no `equations`
	// field and hosts no ICs — a species' initial value is its scalar
	// `species.default`, or a scoped-reference `ic` equation in a MODEL. The
	// document is schema-valid (`constraint_equations` is an array of Equation
	// and `ic` is a legal op) but is rejected here structurally.
	for i, eq := range system.ConstraintEquations {
		node, ok := exprAsNode(eq.LHS)
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

// reportDuplicateSpecies records a legacy-only warning for each species that
// appears more than once in a substrate/product list. side is "substrates" or
// "products".
func (s *structuralScan) reportDuplicateSpecies(entries []SubstrateProduct, side, reactionPath string) {
	seen := make(map[string]int)
	for i, entry := range entries {
		if first, exists := seen[entry.Species]; exists {
			s.addLegacyWarning(
				fmt.Sprintf("%s.%s", reactionPath, side),
				fmt.Sprintf("Species '%s' appears multiple times in %s (positions %d and %d)", entry.Species, side, first, i),
			)
		}
		seen[entry.Species] = i
	}
}

// validateCouplingReferences validates that coupling entries reference declared systems.
func (s *structuralScan) validateCouplingReferences() {
	allSystems := make(map[string]bool)
	for name := range s.file.Models {
		allSystems[name] = true
	}
	for name := range s.file.ReactionSystems {
		allSystems[name] = true
	}

	for i, coupling := range s.file.Coupling {
		basePath := fmt.Sprintf("$.coupling[%d]", i)

		switch c := coupling.(type) {
		case OperatorComposeCoupling:
			s.validateCouplingSystems(c.Systems[:], allSystems, basePath, "operator_compose", i)
		case CouplingCouple:
			s.validateCouplingSystems(c.Systems[:], allSystems, basePath, "couple", i)
		case VariableMapCoupling:
			// from/to are scoped references (e.g. "System.var") — extract system name.
			fromSystem := extractSystemFromScoped(c.From)
			if !allSystems[fromSystem] {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s.from", basePath),
					Code:    ErrorUndefinedSystem,
					Message: fmt.Sprintf("Undefined system '%s' in coupling (from '%s')", fromSystem, c.From),
					Details: map[string]any{
						"system":         fromSystem,
						"scoped_ref":     c.From,
						"coupling_type":  "variable_map",
						"coupling_index": i,
						"direction":      "from",
					},
				})
			}
			toSystem := extractSystemFromScoped(c.To)
			if !allSystems[toSystem] {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s.to", basePath),
					Code:    ErrorUndefinedSystem,
					Message: fmt.Sprintf("Undefined system '%s' in coupling (to '%s')", toSystem, c.To),
					Details: map[string]any{
						"system":         toSystem,
						"scoped_ref":     c.To,
						"coupling_type":  "variable_map",
						"coupling_index": i,
						"direction":      "to",
					},
				})
			}
		case OperatorApplyCoupling:
			// `operator_apply` was removed in v0.3.0 along with the top-level
			// `operators` block. Surface a structural error if a v0.2.x file
			// reaches this validator via direct unmarshaling.
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s.operator", basePath),
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

// validateCouplingSystems reports undefined systems for the list-based coupling
// kinds (operator_compose, couple).
func (s *structuralScan) validateCouplingSystems(systems []string, allSystems map[string]bool, basePath, couplingType string, couplingIndex int) {
	for j, sysName := range systems {
		if allSystems[sysName] {
			continue
		}
		s.addErr(StructuralError{
			Path:    fmt.Sprintf("%s.systems[%d]", basePath, j),
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
		basePath := fmt.Sprintf("$.data_loaders.%s", loaderName)

		if loader.Kind == "" {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s.kind", basePath),
				Code:    CodeMissingLoaderKind,
				Message: "Data loader kind is required",
				Details: map[string]any{"loader": loaderName},
			})
		}
		if loader.Source.URLTemplate == "" {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s.source.url_template", basePath),
				Code:    CodeMissingLoaderSourceURLTemplate,
				Message: "Data loader source.url_template is required",
				Details: map[string]any{"loader": loaderName},
			})
		}
		if len(loader.Variables) == 0 {
			s.addErr(StructuralError{
				Path:    fmt.Sprintf("%s.variables", basePath),
				Code:    CodeMissingLoaderVariables,
				Message: "Data loader must expose at least one variable",
				Details: map[string]any{"loader": loaderName},
			})
		}
		for varName, dv := range loader.Variables {
			if dv.FileVariable == "" {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s.variables.%s.file_variable", basePath, varName),
					Code:    CodeMissingLoaderVariableFileVariable,
					Message: "Data loader variable missing file_variable",
					Details: map[string]any{"loader": loaderName, "variable": varName},
				})
			}
			if dv.Units == "" {
				s.addErr(StructuralError{
					Path:    fmt.Sprintf("%s.variables.%s.units", basePath, varName),
					Code:    CodeMissingLoaderVariableUnits,
					Message: "Data loader variable missing units",
					Details: map[string]any{"loader": loaderName, "variable": varName},
				})
			}
		}
	}
}
