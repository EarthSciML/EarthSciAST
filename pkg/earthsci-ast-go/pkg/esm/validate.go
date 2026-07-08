package esm

import (
	"fmt"
	"strings"
)

// SchemaError represents a JSON Schema violation
type SchemaError struct {
	Path    string `json:"path"`    // JSON Pointer to the offending location
	Message string `json:"message"` // Human-readable description
	Keyword string `json:"keyword"` // JSON Schema keyword that failed
}

// StructuralError represents equation/unknown balance, reference integrity issues
type StructuralError struct {
	Path    string                 `json:"path"`    // JSON Pointer to the relevant component
	Code    string                 `json:"code"`    // Machine-readable error code
	Message string                 `json:"message"` // Human-readable description
	Details map[string]interface{} `json:"details"` // Additional context
}

// UnitWarning represents dimensional inconsistencies
type UnitWarning struct {
	Path     string `json:"path"`      // JSON Pointer to the equation or expression
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
	ErrorUndefinedParameter    = "undefined_parameter"
	ErrorUndefinedSystem       = "undefined_system"
	ErrorUndefinedOperator     = "undefined_operator"
	ErrorUnresolvedScopedRef   = "unresolved_scoped_ref"
	ErrorInvalidDiscreteParam  = "invalid_discrete_param"
	ErrorNullReaction          = "null_reaction"
	ErrorMissingObservedExpr   = "missing_observed_expr"
	ErrorEventVarUndeclared    = "event_var_undeclared"
	ErrorUnitInconsistency     = "unit_inconsistency"
	ErrorIcInReactionSystem    = "ic_in_reaction_system"
)

// ValidationMessage represents a single validation issue (for backward compatibility)
type ValidationMessage struct {
	Level   string `json:"level"`   // "error", "warning", "info"
	Message string `json:"message"` // Human-readable description
	Path    string `json:"path"`    // JSON path to the problematic element
}

// DetailedValidationResult holds comprehensive validation results (for backward compatibility)
type DetailedValidationResult struct {
	Valid    bool                `json:"valid"`
	Messages []ValidationMessage `json:"messages,omitempty"`
}

// ValidateFile performs comprehensive validation of an ESM file per ESM Libraries Spec Section 3.4
// This includes schema validation, structural validation, and unit validation (future)
func ValidateFile(file *EsmFile, jsonStr string) *ValidationResult {
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
func Validate(file *EsmFile) *DetailedValidationResult {
	return ValidateStructural(file)
}

// StructuralValidationResult holds the structured validation errors for internal use
type StructuralValidationResult struct {
	Valid            bool              `json:"valid"`
	StructuralErrors []StructuralError `json:"structural_errors"`
	UnitWarnings     []UnitWarning     `json:"unit_warnings"`
}

// ValidateStructural performs comprehensive structural validation of an ESM file (renamed for clarity)
// This includes equation balance, reference integrity, and reaction consistency
func ValidateStructural(file *EsmFile) *DetailedValidationResult {
	result := &DetailedValidationResult{
		Valid:    true,
		Messages: []ValidationMessage{},
	}

	// Basic struct validation (already done in types.go)
	if err := file.Validate(); err != nil {
		result.Valid = false
		result.Messages = append(result.Messages, ValidationMessage{
			Level:   "error",
			Message: fmt.Sprintf("Basic validation failed: %v", err),
			Path:    "$",
		})
		return result
	}

	// Validate models
	for modelName, model := range file.Models {
		validateModel(modelName, &model, result, file)
	}

	// Validate reaction systems
	for systemName, system := range file.ReactionSystems {
		validateReactionSystem(systemName, &system, result, file)
	}

	// Validate coupling references
	validateCouplingReferences(file, result)

	// Validate data loader references
	validateDataLoaderReferences(file, result)

	// Validate operator references
	validateOperatorReferences(file, result)

	return result
}

// ValidateStructuralWithCodes performs structural validation and returns structured errors directly
func ValidateStructuralWithCodes(file *EsmFile) *StructuralValidationResult {
	result := &StructuralValidationResult{
		Valid:            true,
		StructuralErrors: []StructuralError{},
		UnitWarnings:     []UnitWarning{},
	}

	// Basic struct validation (already done in types.go)
	if err := file.Validate(); err != nil {
		result.Valid = false
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path:    "$",
			Code:    "validation_failed",
			Message: fmt.Sprintf("Basic validation failed: %v", err),
			Details: map[string]interface{}{},
		})
		return result
	}

	// Validate models
	for modelName, model := range file.Models {
		validateModelWithCodes(modelName, &model, result, file)
		validateModelUnits(modelName, &model, fmt.Sprintf("$.models.%s", modelName), file, result)
	}

	// Validate reaction systems
	for systemName, system := range file.ReactionSystems {
		validateReactionSystemWithCodes(systemName, &system, result, file)
		validateReactionSystemUnits(systemName, &system, fmt.Sprintf("$.reaction_systems.%s", systemName), result)
		validateReactionRateUnits(systemName, &system, fmt.Sprintf("/reaction_systems/%s", systemName), result)
	}

	// Validate coupling references
	validateCouplingReferencesWithCodes(file, result)

	// Validate data loader references
	validateDataLoaderReferencesWithCodes(file, result)

	// Validate operator references
	validateOperatorReferencesWithCodes(file, result)

	return result
}

// validateModelWithCodes checks model-specific validation rules with structured error codes
func validateModelWithCodes(modelName string, model *Model, result *StructuralValidationResult, file *EsmFile) {
	basePath := fmt.Sprintf("$.models.%s", modelName)

	// Check that all variables referenced in equations exist
	allVars := make(map[string]bool)
	for varName := range model.Variables {
		allVars[varName] = true
	}

	for i, eq := range model.Equations {
		eqPath := fmt.Sprintf("%s.equations[%d]", basePath, i)
		validateExpressionVariablesWithStructuredCodes(eq.LHS, allVars, fmt.Sprintf("%s.lhs", eqPath), result, file, modelName)
		validateExpressionVariablesWithStructuredCodes(eq.RHS, allVars, fmt.Sprintf("%s.rhs", eqPath), result, file, modelName)
	}

	// Equation-unknown balance validation (Section 3.2.1)
	validateEquationUnknownBalanceWithCodes(modelName, model, basePath, result)

	// Check observed variables have expressions
	for varName, variable := range model.Variables {
		varPath := fmt.Sprintf("%s.variables.%s", basePath, varName)
		if variable.Type == "observed" && variable.Expression == nil {
			result.Valid = false
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    varPath,
				Code:    ErrorMissingObservedExpr,
				Message: "Observed variable must have an expression",
				Details: map[string]interface{}{
					"variable": varName,
					"model":    modelName,
				},
			})
		}
	}

	// Validate discrete events
	for i, event := range model.DiscreteEvents {
		validateDiscreteEventWithCodes(&event, allVars, fmt.Sprintf("%s.discrete_events[%d]", basePath, i), result, file, modelName)
	}

	// Validate continuous events
	for i, event := range model.ContinuousEvents {
		validateContinuousEventWithCodes(&event, allVars, fmt.Sprintf("%s.continuous_events[%d]", basePath, i), result, file, modelName)
	}
}

// validateModel checks model-specific validation rules
func validateModel(modelName string, model *Model, result *DetailedValidationResult, file *EsmFile) {
	basePath := fmt.Sprintf("$.models.%s", modelName)

	// Check that all variables referenced in equations exist
	allVars := make(map[string]bool)
	for varName := range model.Variables {
		allVars[varName] = true
	}

	for i, eq := range model.Equations {
		eqPath := fmt.Sprintf("%s.equations[%d]", basePath, i)
		validateExpressionVariablesWithScoped(eq.LHS, allVars, fmt.Sprintf("%s.lhs", eqPath), result, file, modelName)
		validateExpressionVariablesWithScoped(eq.RHS, allVars, fmt.Sprintf("%s.rhs", eqPath), result, file, modelName)
	}

	// Equation-unknown balance validation (Section 3.2.1)
	validateEquationUnknownBalance(modelName, model, basePath, result)

	// Check observed variables have expressions
	for varName, variable := range model.Variables {
		varPath := fmt.Sprintf("%s.variables.%s", basePath, varName)
		if variable.Type == "observed" && variable.Expression == nil {
			result.Valid = false
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "error",
				Message: "Observed variable must have an expression",
				Path:    varPath,
			})
		}
	}

	// Validate discrete events
	for i, event := range model.DiscreteEvents {
		validateDiscreteEvent(&event, allVars, fmt.Sprintf("%s.discrete_events[%d]", basePath, i), result, file, modelName)
	}

	// Validate continuous events
	for i, event := range model.ContinuousEvents {
		validateContinuousEvent(&event, allVars, fmt.Sprintf("%s.continuous_events[%d]", basePath, i), result, file, modelName)
	}
}

// validateReactionSystem checks reaction system-specific validation rules
func validateReactionSystem(systemName string, system *ReactionSystem, result *DetailedValidationResult, file *EsmFile) {
	basePath := fmt.Sprintf("$.reaction_systems.%s", systemName)

	// Check reaction stoichiometry balance (optional - could be intentionally unbalanced)
	for i, reaction := range system.Reactions {
		reactionPath := fmt.Sprintf("%s.reactions[%d]", basePath, i)
		validateReaction(&reaction, system, reactionPath, result)
	}

	// Check that all species referenced in reactions exist
	allSpecies := make(map[string]bool)
	for speciesName := range system.Species {
		allSpecies[speciesName] = true
	}

	allParams := make(map[string]bool)
	for paramName := range system.Parameters {
		allParams[paramName] = true
	}

	// Combined variables for expression validation
	allVars := make(map[string]bool)
	for name := range allSpecies {
		allVars[name] = true
	}
	for name := range allParams {
		allVars[name] = true
	}

	for i, reaction := range system.Reactions {
		reactionPath := fmt.Sprintf("%s.reactions[%d]", basePath, i)

		// Check substrates reference valid species
		for j, substrate := range reaction.Substrates {
			if !allSpecies[substrate.Species] {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown species '%s' in reaction substrate", substrate.Species),
					Path:    fmt.Sprintf("%s.substrates[%d].species", reactionPath, j),
				})
			}
		}

		// Check products reference valid species
		for j, product := range reaction.Products {
			if !allSpecies[product.Species] {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown species '%s' in reaction product", product.Species),
					Path:    fmt.Sprintf("%s.products[%d].species", reactionPath, j),
				})
			}
		}

		// Validate rate expression
		validateExpressionVariablesWithScoped(reaction.Rate, allVars, fmt.Sprintf("%s.rate", reactionPath), result, file, systemName)
	}
}

// validateReaction performs reaction-specific validation
func validateReaction(reaction *Reaction, system *ReactionSystem, path string, result *DetailedValidationResult) {
	// Check for duplicate species in substrates/products
	substrateSpecies := make(map[string]int)
	for i, substrate := range reaction.Substrates {
		if count, exists := substrateSpecies[substrate.Species]; exists {
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "warning",
				Message: fmt.Sprintf("Species '%s' appears multiple times in substrates (positions %d and %d)", substrate.Species, count, i),
				Path:    fmt.Sprintf("%s.substrates", path),
			})
		}
		substrateSpecies[substrate.Species] = i
	}

	productSpecies := make(map[string]int)
	for i, product := range reaction.Products {
		if count, exists := productSpecies[product.Species]; exists {
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "warning",
				Message: fmt.Sprintf("Species '%s' appears multiple times in products (positions %d and %d)", product.Species, count, i),
				Path:    fmt.Sprintf("%s.products", path),
			})
		}
		productSpecies[product.Species] = i
	}
}

// validateExpressionVariablesWithScoped checks that all variables in an expression exist
// with support for scoped reference resolution
func validateExpressionVariablesWithScoped(expr Expression, allVars map[string]bool, path string, result *DetailedValidationResult, file *EsmFile, currentSystem string) {
	switch e := expr.(type) {
	case string:
		// Variable reference - check if it exists
		if !allVars[e] {
			// If it's a scoped reference and we have file context, try to resolve it
			if file != nil && strings.Contains(e, ".") {
				if _, resolved := resolveScopedReference(e, file, currentSystem); !resolved {
					result.Valid = false
					result.Messages = append(result.Messages, ValidationMessage{
						Level:   "error",
						Message: fmt.Sprintf("Unresolved scoped reference '%s'", e),
						Path:    path,
					})
				}
			} else {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown variable '%s'", e),
					Path:    path,
				})
			}
		}
	case ExprNode:
		// Recursively validate arguments
		for i, arg := range e.Args {
			validateExpressionVariablesWithScoped(arg, allVars, fmt.Sprintf("%s.args[%d]", path, i), result, file, currentSystem)
		}
	case float64, int:
		// Numeric literals are always valid
	default:
		result.Messages = append(result.Messages, ValidationMessage{
			Level:   "warning",
			Message: fmt.Sprintf("Unknown expression type: %T", e),
			Path:    path,
		})
	}
}

// validateDiscreteEvent validates discrete event structure
func validateDiscreteEvent(event *DiscreteEvent, allVars map[string]bool, path string, result *DetailedValidationResult, file *EsmFile, currentSystem string) {
	// Validate trigger expression if it's a condition type
	if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
		validateExpressionVariablesWithScoped(event.Trigger.Expression, allVars, fmt.Sprintf("%s.trigger.expression", path), result, file, currentSystem)
	}

	// Validate affect equations
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s.affects[%d]", path, i)

		// Check that the target variable exists (could be scoped)
		if !allVars[affect.LHS] {
			if file != nil && strings.Contains(affect.LHS, ".") {
				if _, resolved := resolveScopedReference(affect.LHS, file, currentSystem); !resolved {
					result.Valid = false
					result.Messages = append(result.Messages, ValidationMessage{
						Level:   "error",
						Message: fmt.Sprintf("Unresolved scoped reference '%s' in affect equation", affect.LHS),
						Path:    fmt.Sprintf("%s.lhs", affectPath),
					})
				}
			} else {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown variable '%s' in affect equation", affect.LHS),
					Path:    fmt.Sprintf("%s.lhs", affectPath),
				})
			}
		}

		// Validate the RHS expression
		validateExpressionVariablesWithScoped(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), result, file, currentSystem)
	}
}

// validateContinuousEvent validates continuous event structure
func validateContinuousEvent(event *ContinuousEvent, allVars map[string]bool, path string, result *DetailedValidationResult, file *EsmFile, currentSystem string) {
	// Validate condition expressions
	for i, condition := range event.Conditions {
		validateExpressionVariablesWithScoped(condition, allVars, fmt.Sprintf("%s.conditions[%d]", path, i), result, file, currentSystem)
	}

	// Validate affect equations
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s.affects[%d]", path, i)

		if !allVars[affect.LHS] {
			if file != nil && strings.Contains(affect.LHS, ".") {
				if _, resolved := resolveScopedReference(affect.LHS, file, currentSystem); !resolved {
					result.Valid = false
					result.Messages = append(result.Messages, ValidationMessage{
						Level:   "error",
						Message: fmt.Sprintf("Unresolved scoped reference '%s' in affect equation", affect.LHS),
						Path:    fmt.Sprintf("%s.lhs", affectPath),
					})
				}
			} else {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown variable '%s' in affect equation", affect.LHS),
					Path:    fmt.Sprintf("%s.lhs", affectPath),
				})
			}
		}

		validateExpressionVariablesWithScoped(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), result, file, currentSystem)
	}

	// Validate affect_neg equations if present
	for i, affect := range event.AffectNeg {
		affectPath := fmt.Sprintf("%s.affect_neg[%d]", path, i)

		if !allVars[affect.LHS] {
			if file != nil && strings.Contains(affect.LHS, ".") {
				if _, resolved := resolveScopedReference(affect.LHS, file, currentSystem); !resolved {
					result.Valid = false
					result.Messages = append(result.Messages, ValidationMessage{
						Level:   "error",
						Message: fmt.Sprintf("Unresolved scoped reference '%s' in affect_neg equation", affect.LHS),
						Path:    fmt.Sprintf("%s.lhs", affectPath),
					})
				}
			} else {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown variable '%s' in affect_neg equation", affect.LHS),
					Path:    fmt.Sprintf("%s.lhs", affectPath),
				})
			}
		}

		validateExpressionVariablesWithScoped(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), result, file, currentSystem)
	}
}

// validateCouplingReferences validates that coupling entries reference valid systems
func validateCouplingReferences(file *EsmFile, result *DetailedValidationResult) {
	allSystems := make(map[string]bool)

	// Collect all system names
	for name := range file.Models {
		allSystems[name] = true
	}
	for name := range file.ReactionSystems {
		allSystems[name] = true
	}

	for i, coupling := range file.Coupling {
		basePath := fmt.Sprintf("$.coupling[%d]", i)

		// Now we can use proper type assertions for the typed coupling entries
		switch c := coupling.(type) {
		case OperatorComposeCoupling:
			for j, sysName := range c.Systems {
				if !allSystems[sysName] {
					result.Valid = false
					result.Messages = append(result.Messages, ValidationMessage{
						Level:   "error",
						Message: fmt.Sprintf("Unknown system '%s' in coupling", sysName),
						Path:    fmt.Sprintf("%s.systems[%d]", basePath, j),
					})
				}
			}

		case CouplingCouple:
			for j, sysName := range c.Systems {
				if !allSystems[sysName] {
					result.Valid = false
					result.Messages = append(result.Messages, ValidationMessage{
						Level:   "error",
						Message: fmt.Sprintf("Unknown system '%s' in coupling", sysName),
						Path:    fmt.Sprintf("%s.systems[%d]", basePath, j),
					})
				}
			}

		case VariableMapCoupling:
			// For variable_map coupling, from/to are scoped references (e.g. "System.var")
			// Extract the system name from the scoped reference for validation
			fromSystem := extractSystemFromScoped(c.From)
			if !allSystems[fromSystem] {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown system '%s' in coupling (from '%s')", fromSystem, c.From),
					Path:    fmt.Sprintf("%s.from", basePath),
				})
			}
			toSystem := extractSystemFromScoped(c.To)
			if !allSystems[toSystem] {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: fmt.Sprintf("Unknown system '%s' in coupling (from '%s')", toSystem, c.To),
					Path:    fmt.Sprintf("%s.to", basePath),
				})
			}

		case OperatorApplyCoupling:
			// `operator_apply` was removed in v0.3.0 along with the top-level
			// `operators` block (esm-spec §10 / closed-function-registry RFC).
			// The schema rejects new files; this arm is retained only to
			// surface a clear error if a v0.2.x file leaks through direct
			// JSON unmarshaling.
			result.Valid = false
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "error",
				Message: fmt.Sprintf("'operator_apply' coupling has been removed (v0.3.0); referenced operator '%s'", c.Operator),
				Path:    fmt.Sprintf("%s.operator", basePath),
			})

		case CallbackCoupling:
			// Callback coupling validated by schema; no additional structural checks needed

		case EventCoupling:
			// Event coupling validated by schema; no additional structural checks needed
		}
	}
}

// validateDataLoaderReferences validates data loader configurations
func validateDataLoaderReferences(file *EsmFile, result *DetailedValidationResult) {
	for loaderName, loader := range file.DataLoaders {
		basePath := fmt.Sprintf("$.data_loaders.%s", loaderName)

		// Validate that required fields are present.
		if loader.Kind == "" {
			result.Valid = false
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "error",
				Message: "Data loader kind is required",
				Path:    fmt.Sprintf("%s.kind", basePath),
			})
		}

		if loader.Source.URLTemplate == "" {
			result.Valid = false
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "error",
				Message: "Data loader source.url_template is required",
				Path:    fmt.Sprintf("%s.source.url_template", basePath),
			})
		}

		if len(loader.Variables) == 0 {
			result.Valid = false
			result.Messages = append(result.Messages, ValidationMessage{
				Level:   "error",
				Message: "Data loader must expose at least one variable",
				Path:    fmt.Sprintf("%s.variables", basePath),
			})
		}

		for varName, dv := range loader.Variables {
			if dv.FileVariable == "" {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: "Data loader variable missing file_variable",
					Path:    fmt.Sprintf("%s.variables.%s.file_variable", basePath, varName),
				})
			}
			if dv.Units == "" {
				result.Valid = false
				result.Messages = append(result.Messages, ValidationMessage{
					Level:   "error",
					Message: "Data loader variable missing units",
					Path:    fmt.Sprintf("%s.variables.%s.units", basePath, varName),
				})
			}
		}
	}
}

// validateOperatorReferences was used to walk the now-removed top-level
// `operators` block. v0.3.0 closes the registry (closed-function-registry
// RFC); the function is retained as a no-op to keep call sites stable.
func validateOperatorReferences(_ *EsmFile, _ *DetailedValidationResult) {}

// validateEquationUnknownBalance validates equation-unknown balance for models
// as per ESM libraries specification Section 3.2.1
func validateEquationUnknownBalance(modelName string, model *Model, basePath string, result *DetailedValidationResult) {
	// Count state variables
	stateVars := make(map[string]bool)
	for varName, variable := range model.Variables {
		if variable.Type == "state" {
			stateVars[varName] = true
		}
	}
	nStates := len(stateVars)

	// Count ODE equations (equations whose LHS is a time derivative D(var, t))
	odeEquations := make(map[string]bool) // track which state variables have ODE equations
	nOdes := 0

	for _, eq := range model.Equations {
		if lhsNode, ok := eq.LHS.(ExprNode); ok {
			if lhsNode.Op == "D" && len(lhsNode.Args) > 0 {
				// Check if this is a time derivative
				if lhsNode.Wrt != nil && *lhsNode.Wrt == "t" {
					nOdes++
					// Extract the variable name from the derivative
					if varName, ok := lhsNode.Args[0].(string); ok {
						odeEquations[varName] = true
					}
				}
			}
		}
	}

	// Check equation-unknown balance: n_odes == n_states
	if nOdes != nStates {
		result.Valid = false

		// Report which state variables lack ODE equations
		missingEquations := []string{}
		for varName := range stateVars {
			if !odeEquations[varName] {
				missingEquations = append(missingEquations, varName)
			}
		}

		// Report which ODE equations lack corresponding state variables
		extraEquations := []string{}
		for varName := range odeEquations {
			if !stateVars[varName] {
				extraEquations = append(extraEquations, varName)
			}
		}

		// Generate error message
		message := fmt.Sprintf("Equation-unknown balance failed: found %d state variables but %d ODE equations", nStates, nOdes)

		if len(missingEquations) > 0 {
			message += fmt.Sprintf("; state variables without ODE equations: %v", missingEquations)
		}

		if len(extraEquations) > 0 {
			message += fmt.Sprintf("; ODE equations for non-state variables: %v", extraEquations)
		}

		result.Messages = append(result.Messages, ValidationMessage{
			Level:   "error",
			Message: message,
			Path:    basePath,
		})
	}
}

// validateExpressionVariablesWithStructuredCodes checks that all variables in an expression exist
// with support for scoped reference resolution and structured error codes
func validateExpressionVariablesWithStructuredCodes(expr Expression, allVars map[string]bool, path string, result *StructuralValidationResult, file *EsmFile, currentSystem string) {
	switch e := expr.(type) {
	case string:
		// Variable reference - check if it exists
		if !allVars[e] {
			// If it's a scoped reference and we have file context, try to resolve it
			if file != nil && strings.Contains(e, ".") {
				if _, resolved := resolveScopedReference(e, file, currentSystem); !resolved {
					result.Valid = false
					result.StructuralErrors = append(result.StructuralErrors, StructuralError{
						Path:    path,
						Code:    ErrorUnresolvedScopedRef,
						Message: fmt.Sprintf("Unresolved scoped reference '%s'", e),
						Details: map[string]interface{}{
							"variable":       e,
							"current_system": currentSystem,
						},
					})
				}
			} else {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    path,
					Code:    ErrorUndefinedVariable,
					Message: fmt.Sprintf("Undefined variable '%s'", e),
					Details: map[string]interface{}{
						"variable":       e,
						"current_system": currentSystem,
					},
				})
			}
		}
	case ExprNode:
		// Recursively validate arguments
		for i, arg := range e.Args {
			validateExpressionVariablesWithStructuredCodes(arg, allVars, fmt.Sprintf("%s.args[%d]", path, i), result, file, currentSystem)
		}
	case float64, int:
		// Numeric literals are always valid
	default:
		result.Valid = false
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path:    path,
			Code:    "unknown_expression_type",
			Message: fmt.Sprintf("Unknown expression type: %T", e),
			Details: map[string]interface{}{"type": fmt.Sprintf("%T", e)},
		})
	}
}

// validateEquationUnknownBalanceWithCodes validates equation-unknown balance with structured error codes
func validateEquationUnknownBalanceWithCodes(modelName string, model *Model, basePath string, result *StructuralValidationResult) {
	// Count state variables
	stateVars := make(map[string]bool)
	for varName, variable := range model.Variables {
		if variable.Type == "state" {
			stateVars[varName] = true
		}
	}
	nStates := len(stateVars)

	// Count ODE equations (equations whose LHS is a time derivative D(var, t))
	odeEquations := make(map[string]bool) // track which state variables have ODE equations
	nOdes := 0

	for _, eq := range model.Equations {
		if lhsNode, ok := eq.LHS.(ExprNode); ok {
			if lhsNode.Op == "D" && len(lhsNode.Args) > 0 {
				// Check if this is a time derivative
				if lhsNode.Wrt != nil && *lhsNode.Wrt == "t" {
					nOdes++
					// Extract the variable name from the derivative
					if varName, ok := lhsNode.Args[0].(string); ok {
						odeEquations[varName] = true
					}
				}
			}
		}
	}

	// Check equation-unknown balance: n_odes == n_states
	if nOdes != nStates {
		result.Valid = false

		// Report which state variables lack ODE equations
		missingEquations := []string{}
		for varName := range stateVars {
			if !odeEquations[varName] {
				missingEquations = append(missingEquations, varName)
			}
		}

		// Report which ODE equations lack corresponding state variables
		extraEquations := []string{}
		for varName := range odeEquations {
			if !stateVars[varName] {
				extraEquations = append(extraEquations, varName)
			}
		}

		// Generate error message
		message := fmt.Sprintf("Equation-unknown balance failed: found %d state variables but %d ODE equations", nStates, nOdes)

		if len(missingEquations) > 0 {
			message += fmt.Sprintf("; state variables without ODE equations: %v", missingEquations)
		}

		if len(extraEquations) > 0 {
			message += fmt.Sprintf("; ODE equations for non-state variables: %v", extraEquations)
		}

		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path:    basePath,
			Code:    ErrorEquationCountMismatch,
			Message: message,
			Details: map[string]interface{}{
				"model":             modelName,
				"state_count":       nStates,
				"ode_count":         nOdes,
				"missing_equations": missingEquations,
				"extra_equations":   extraEquations,
			},
		})
	}
}

// validateReactionSystemWithCodes checks reaction system-specific validation rules with structured codes
func validateReactionSystemWithCodes(systemName string, system *ReactionSystem, result *StructuralValidationResult, file *EsmFile) {
	basePath := fmt.Sprintf("$.reaction_systems.%s", systemName)

	// Check that all species referenced in reactions exist
	allSpecies := make(map[string]bool)
	for speciesName := range system.Species {
		allSpecies[speciesName] = true
	}

	allParams := make(map[string]bool)
	for paramName := range system.Parameters {
		allParams[paramName] = true
	}

	// Combined variables for expression validation
	allVars := make(map[string]bool)
	for name := range allSpecies {
		allVars[name] = true
	}
	for name := range allParams {
		allVars[name] = true
	}

	for i, reaction := range system.Reactions {
		reactionPath := fmt.Sprintf("%s.reactions[%d]", basePath, i)

		// Check for null reaction
		if len(reaction.Substrates) == 0 && len(reaction.Products) == 0 {
			result.Valid = false
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    reactionPath,
				Code:    ErrorNullReaction,
				Message: "Reaction has both substrates: null and products: null",
				Details: map[string]interface{}{
					"reaction_index": i,
					"system":         systemName,
				},
			})
		}

		// Check substrates reference valid species
		for j, substrate := range reaction.Substrates {
			if !allSpecies[substrate.Species] {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.substrates[%d].species", reactionPath, j),
					Code:    ErrorUndefinedSpecies,
					Message: fmt.Sprintf("Undefined species '%s' in reaction substrate", substrate.Species),
					Details: map[string]interface{}{
						"species":         substrate.Species,
						"system":          systemName,
						"reaction_index":  i,
						"substrate_index": j,
					},
				})
			}
		}

		// Check products reference valid species
		for j, product := range reaction.Products {
			if !allSpecies[product.Species] {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.products[%d].species", reactionPath, j),
					Code:    ErrorUndefinedSpecies,
					Message: fmt.Sprintf("Undefined species '%s' in reaction product", product.Species),
					Details: map[string]interface{}{
						"species":        product.Species,
						"system":         systemName,
						"reaction_index": i,
						"product_index":  j,
					},
				})
			}
		}

		// Validate rate expression
		validateExpressionVariablesWithStructuredCodes(reaction.Rate, allVars, fmt.Sprintf("%s.rate", reactionPath), result, file, systemName)
	}

	// v0.8.0 §11.4.1: an `ic`-op equation MUST NOT appear inside a reaction
	// system's `constraint_equations`. A reaction system has no `equations`
	// field and hosts no ICs — a species' initial value is its scalar
	// `species.default`, or a scoped-reference `ic` equation in a MODEL. The
	// document is schema-valid (`constraint_equations` is an array of Equation
	// and `ic` is a legal op) but is rejected here structurally.
	for i, eq := range system.ConstraintEquations {
		node, ok := eq.LHS.(ExprNode)
		if !ok || node.Op != "ic" {
			continue
		}
		species := ""
		if len(node.Args) > 0 {
			if s, ok := node.Args[0].(string); ok {
				species = s
			}
		}
		result.Valid = false
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path: fmt.Sprintf("/reaction_systems/%s/constraint_equations/%d", systemName, i),
			Code: ErrorIcInReactionSystem,
			Message: "ic equation not allowed in a reaction system; a reaction system has no equations " +
				"field and hosts no ic equations (ICs are model-hosted: species.default, or a " +
				"scoped-reference ic equation in a model, spec §11.4.1)",
			Details: map[string]interface{}{
				"system":                    systemName,
				"species":                   species,
				"constraint_equation_index": i,
			},
		})
	}
}

// validateCouplingReferencesWithCodes validates coupling references with structured error codes
func validateCouplingReferencesWithCodes(file *EsmFile, result *StructuralValidationResult) {
	allSystems := make(map[string]bool)

	// Collect all system names
	for name := range file.Models {
		allSystems[name] = true
	}
	for name := range file.ReactionSystems {
		allSystems[name] = true
	}

	for i, coupling := range file.Coupling {
		basePath := fmt.Sprintf("$.coupling[%d]", i)

		switch c := coupling.(type) {
		case OperatorComposeCoupling:
			for j, sysName := range c.Systems {
				if !allSystems[sysName] {
					result.Valid = false
					result.StructuralErrors = append(result.StructuralErrors, StructuralError{
						Path:    fmt.Sprintf("%s.systems[%d]", basePath, j),
						Code:    ErrorUndefinedSystem,
						Message: fmt.Sprintf("Undefined system '%s' in coupling", sysName),
						Details: map[string]interface{}{
							"system":         sysName,
							"coupling_type":  "operator_compose",
							"coupling_index": i,
							"system_index":   j,
						},
					})
				}
			}

		case CouplingCouple:
			for j, sysName := range c.Systems {
				if !allSystems[sysName] {
					result.Valid = false
					result.StructuralErrors = append(result.StructuralErrors, StructuralError{
						Path:    fmt.Sprintf("%s.systems[%d]", basePath, j),
						Code:    ErrorUndefinedSystem,
						Message: fmt.Sprintf("Undefined system '%s' in coupling", sysName),
						Details: map[string]interface{}{
							"system":         sysName,
							"coupling_type":  "couple",
							"coupling_index": i,
							"system_index":   j,
						},
					})
				}
			}

		case VariableMapCoupling:
			// from/to are scoped references (e.g. "System.var") — extract system name
			fromSystem := extractSystemFromScoped(c.From)
			if !allSystems[fromSystem] {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.from", basePath),
					Code:    ErrorUndefinedSystem,
					Message: fmt.Sprintf("Undefined system '%s' in coupling (from '%s')", fromSystem, c.From),
					Details: map[string]interface{}{
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
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.to", basePath),
					Code:    ErrorUndefinedSystem,
					Message: fmt.Sprintf("Undefined system '%s' in coupling (from '%s')", toSystem, c.To),
					Details: map[string]interface{}{
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
			result.Valid = false
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    fmt.Sprintf("%s.operator", basePath),
				Code:    ErrorUndefinedOperator,
				Message: fmt.Sprintf("'operator_apply' coupling has been removed (v0.3.0); referenced operator '%s'", c.Operator),
				Details: map[string]interface{}{
					"operator":       c.Operator,
					"coupling_type":  "operator_apply",
					"coupling_index": i,
				},
			})

		case CallbackCoupling:
			// Callback coupling validated by schema; no additional structural checks needed

		case EventCoupling:
			// Event coupling validated by schema; no additional structural checks needed
		}
	}
}

// validateDataLoaderReferencesWithCodes validates data loader configurations with structured codes
func validateDataLoaderReferencesWithCodes(file *EsmFile, result *StructuralValidationResult) {
	for loaderName, loader := range file.DataLoaders {
		basePath := fmt.Sprintf("$.data_loaders.%s", loaderName)

		if loader.Kind == "" {
			result.Valid = false
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    fmt.Sprintf("%s.kind", basePath),
				Code:    "missing_loader_kind",
				Message: "Data loader kind is required",
				Details: map[string]interface{}{
					"loader": loaderName,
				},
			})
		}

		if loader.Source.URLTemplate == "" {
			result.Valid = false
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    fmt.Sprintf("%s.source.url_template", basePath),
				Code:    "missing_loader_source_url_template",
				Message: "Data loader source.url_template is required",
				Details: map[string]interface{}{
					"loader": loaderName,
				},
			})
		}

		if len(loader.Variables) == 0 {
			result.Valid = false
			result.StructuralErrors = append(result.StructuralErrors, StructuralError{
				Path:    fmt.Sprintf("%s.variables", basePath),
				Code:    "missing_loader_variables",
				Message: "Data loader must expose at least one variable",
				Details: map[string]interface{}{
					"loader": loaderName,
				},
			})
		}

		for varName, dv := range loader.Variables {
			if dv.FileVariable == "" {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.variables.%s.file_variable", basePath, varName),
					Code:    "missing_loader_variable_file_variable",
					Message: "Data loader variable missing file_variable",
					Details: map[string]interface{}{
						"loader":   loaderName,
						"variable": varName,
					},
				})
			}
			if dv.Units == "" {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.variables.%s.units", basePath, varName),
					Code:    "missing_loader_variable_units",
					Message: "Data loader variable missing units",
					Details: map[string]interface{}{
						"loader":   loaderName,
						"variable": varName,
					},
				})
			}
		}
	}
}

// validateOperatorReferencesWithCodes was used to walk the now-removed
// top-level `operators` block. v0.3.0 closes the registry; no-op preserved
// to keep call sites stable.
func validateOperatorReferencesWithCodes(_ *EsmFile, _ *StructuralValidationResult) {}

// validateDiscreteEventWithCodes validates discrete event structure with structured codes
func validateDiscreteEventWithCodes(event *DiscreteEvent, allVars map[string]bool, path string, result *StructuralValidationResult, file *EsmFile, currentSystem string) {
	// Validate trigger expression if it's a condition type
	if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
		validateExpressionVariablesWithStructuredCodes(event.Trigger.Expression, allVars, fmt.Sprintf("%s.trigger.expression", path), result, file, currentSystem)
	}

	// Validate affect equations
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s.affects[%d]", path, i)

		// Check that the target variable exists (could be scoped)
		if !allVars[affect.LHS] {
			if file != nil && strings.Contains(affect.LHS, ".") {
				if _, resolved := resolveScopedReference(affect.LHS, file, currentSystem); !resolved {
					result.Valid = false
					result.StructuralErrors = append(result.StructuralErrors, StructuralError{
						Path:    fmt.Sprintf("%s.lhs", affectPath),
						Code:    ErrorUnresolvedScopedRef,
						Message: fmt.Sprintf("Unresolved scoped reference '%s' in affect equation", affect.LHS),
						Details: map[string]interface{}{
							"variable":       affect.LHS,
							"current_system": currentSystem,
							"event_type":     "discrete",
						},
					})
				}
			} else {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.lhs", affectPath),
					Code:    ErrorEventVarUndeclared,
					Message: fmt.Sprintf("Undefined variable '%s' in affect equation", affect.LHS),
					Details: map[string]interface{}{
						"variable":       affect.LHS,
						"current_system": currentSystem,
						"event_type":     "discrete",
					},
				})
			}
		}

		// Validate the RHS expression
		validateExpressionVariablesWithStructuredCodes(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), result, file, currentSystem)
	}
}

// validateContinuousEventWithCodes validates continuous event structure with structured codes
func validateContinuousEventWithCodes(event *ContinuousEvent, allVars map[string]bool, path string, result *StructuralValidationResult, file *EsmFile, currentSystem string) {
	// Validate condition expressions
	for i, condition := range event.Conditions {
		validateExpressionVariablesWithStructuredCodes(condition, allVars, fmt.Sprintf("%s.conditions[%d]", path, i), result, file, currentSystem)
	}

	// Validate affect equations
	for i, affect := range event.Affects {
		affectPath := fmt.Sprintf("%s.affects[%d]", path, i)

		if !allVars[affect.LHS] {
			if file != nil && strings.Contains(affect.LHS, ".") {
				if _, resolved := resolveScopedReference(affect.LHS, file, currentSystem); !resolved {
					result.Valid = false
					result.StructuralErrors = append(result.StructuralErrors, StructuralError{
						Path:    fmt.Sprintf("%s.lhs", affectPath),
						Code:    ErrorUnresolvedScopedRef,
						Message: fmt.Sprintf("Unresolved scoped reference '%s' in affect equation", affect.LHS),
						Details: map[string]interface{}{
							"variable":       affect.LHS,
							"current_system": currentSystem,
							"event_type":     "continuous",
						},
					})
				}
			} else {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.lhs", affectPath),
					Code:    ErrorEventVarUndeclared,
					Message: fmt.Sprintf("Undefined variable '%s' in affect equation", affect.LHS),
					Details: map[string]interface{}{
						"variable":       affect.LHS,
						"current_system": currentSystem,
						"event_type":     "continuous",
					},
				})
			}
		}

		validateExpressionVariablesWithStructuredCodes(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), result, file, currentSystem)
	}

	// Validate affect_neg equations if present
	for i, affect := range event.AffectNeg {
		affectPath := fmt.Sprintf("%s.affect_neg[%d]", path, i)

		if !allVars[affect.LHS] {
			if file != nil && strings.Contains(affect.LHS, ".") {
				if _, resolved := resolveScopedReference(affect.LHS, file, currentSystem); !resolved {
					result.Valid = false
					result.StructuralErrors = append(result.StructuralErrors, StructuralError{
						Path:    fmt.Sprintf("%s.lhs", affectPath),
						Code:    ErrorUnresolvedScopedRef,
						Message: fmt.Sprintf("Unresolved scoped reference '%s' in affect_neg equation", affect.LHS),
						Details: map[string]interface{}{
							"variable":       affect.LHS,
							"current_system": currentSystem,
							"event_type":     "continuous",
						},
					})
				}
			} else {
				result.Valid = false
				result.StructuralErrors = append(result.StructuralErrors, StructuralError{
					Path:    fmt.Sprintf("%s.lhs", affectPath),
					Code:    ErrorEventVarUndeclared,
					Message: fmt.Sprintf("Undefined variable '%s' in affect_neg equation", affect.LHS),
					Details: map[string]interface{}{
						"variable":       affect.LHS,
						"current_system": currentSystem,
						"event_type":     "continuous",
					},
				})
			}
		}

		validateExpressionVariablesWithStructuredCodes(affect.RHS, allVars, fmt.Sprintf("%s.rhs", affectPath), result, file, currentSystem)
	}
}
