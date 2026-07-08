package esm

import (
	"reflect"
	"strings"
)

// Substitute performs variable substitution in expressions
// expr: the expression to substitute into
// bindings: map from variable names to replacement expressions
func Substitute(expr Expression, bindings map[string]Expression) Expression {
	return substituteRecursive(expr, bindings)
}

// substituteRecursive is the internal recursive function
func substituteRecursive(expr Expression, bindings map[string]Expression) Expression {
	return substituteRecursiveWithScoped(expr, bindings, nil, "")
}

// substituteRecursiveWithScoped is the internal recursive function with scoped reference support
func substituteRecursiveWithScoped(expr Expression, bindings map[string]Expression, file *EsmFile, currentSystem string) Expression {
	switch e := expr.(type) {
	case string:
		// Variable reference - check for substitution
		if replacement, exists := bindings[e]; exists {
			// Recursively apply substitutions to the replacement
			return substituteRecursiveWithScoped(replacement, bindings, file, currentSystem)
		}

		// If it's a scoped reference and we have file context, try to resolve it
		if file != nil && strings.Contains(e, ".") {
			if resolved, found := resolveScopedReference(e, file, currentSystem); found {
				// Check if the resolved reference has a binding
				if replacement, exists := bindings[resolved]; exists {
					return substituteRecursiveWithScoped(replacement, bindings, file, currentSystem)
				}
			}
		}

		return e

	case ExprNode:
		// Expression node - recursively substitute arguments
		newArgs := make([]interface{}, len(e.Args))
		for i, arg := range e.Args {
			newArgs[i] = substituteRecursiveWithScoped(arg, bindings, file, currentSystem)
		}

		// Create new ExprNode with substituted arguments
		newNode := ExprNode{
			Op:   e.Op,
			Args: newArgs,
			Wrt:  e.Wrt,
			Dim:  e.Dim,
		}

		// Special handling for derivative operators where the 'wrt' variable might be substituted
		if e.Op == "D" && e.Wrt != nil {
			if replacement, exists := bindings[*e.Wrt]; exists {
				if wrtStr, ok := replacement.(string); ok {
					newNode.Wrt = &wrtStr
				}
			} else if file != nil && strings.Contains(*e.Wrt, ".") {
				// Handle scoped reference in wrt
				if resolved, found := resolveScopedReference(*e.Wrt, file, currentSystem); found {
					if replacement, exists := bindings[resolved]; exists {
						if wrtStr, ok := replacement.(string); ok {
							newNode.Wrt = &wrtStr
						}
					}
				}
			}
		}

		// Special handling for gradient operators where the 'dim' variable might be substituted
		if e.Op == "grad" && e.Dim != nil {
			if replacement, exists := bindings[*e.Dim]; exists {
				if dimStr, ok := replacement.(string); ok {
					newNode.Dim = &dimStr
				}
			} else if file != nil && strings.Contains(*e.Dim, ".") {
				// Handle scoped reference in dim
				if resolved, found := resolveScopedReference(*e.Dim, file, currentSystem); found {
					if replacement, exists := bindings[resolved]; exists {
						if dimStr, ok := replacement.(string); ok {
							newNode.Dim = &dimStr
						}
					}
				}
			}
		}

		return newNode

	case *ExprNode:
		// Pointer to expression node
		return substituteRecursiveWithScoped(*e, bindings, file, currentSystem)

	case float64, int, int32, int64, float32:
		// Numeric literals - no substitution needed
		return e

	default:
		// Handle interface{} that might contain other types
		if e == nil {
			return nil
		}

		// Try to handle the case where expr is wrapped in interface{}
		v := reflect.ValueOf(e)
		if v.Kind() == reflect.Pointer && !v.IsNil() {
			// Dereference pointer
			return substituteRecursiveWithScoped(v.Elem().Interface(), bindings, file, currentSystem)
		}

		// For unknown types, return as-is
		return e
	}
}

// SubstituteInEquation substitutes variables in both LHS and RHS of an equation
func SubstituteInEquation(eq Equation, bindings map[string]Expression) Equation {
	return Equation{
		LHS: substituteRecursive(eq.LHS, bindings),
		RHS: substituteRecursive(eq.RHS, bindings),
	}
}

// SubstituteInAffectEquation substitutes variables in an affect equation
// Note: LHS is a variable name (string) so it's not substituted, only RHS
func SubstituteInAffectEquation(affect AffectEquation, bindings map[string]Expression) AffectEquation {
	return AffectEquation{
		LHS: affect.LHS, // Variable name stays the same
		RHS: substituteRecursive(affect.RHS, bindings),
	}
}

// SubstituteInModel performs substitution across an entire model
func SubstituteInModel(model Model, bindings map[string]Expression) Model {
	newModel := model // Copy the struct

	// Substitute in equations
	newEquations := make([]Equation, len(model.Equations))
	for i, eq := range model.Equations {
		newEquations[i] = SubstituteInEquation(eq, bindings)
	}
	newModel.Equations = newEquations

	// Substitute in observed variable expressions
	newVariables := make(map[string]ModelVariable)
	for name, variable := range model.Variables {
		newVar := variable
		if variable.Expression != nil {
			newVar.Expression = substituteRecursive(variable.Expression, bindings)
		}
		newVariables[name] = newVar
	}
	newModel.Variables = newVariables

	// Substitute in discrete events
	newDiscreteEvents := make([]DiscreteEvent, len(model.DiscreteEvents))
	for i, event := range model.DiscreteEvents {
		newEvent := event

		// Substitute in trigger expression if it's a condition type
		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			newEvent.Trigger.Expression = substituteRecursive(event.Trigger.Expression, bindings)
		}

		// Substitute in affects
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = SubstituteInAffectEquation(affect, bindings)
		}
		newEvent.Affects = newAffects

		newDiscreteEvents[i] = newEvent
	}
	newModel.DiscreteEvents = newDiscreteEvents

	// Substitute in continuous events
	newContinuousEvents := make([]ContinuousEvent, len(model.ContinuousEvents))
	for i, event := range model.ContinuousEvents {
		newEvent := event

		// Substitute in conditions
		newConditions := make([]Expression, len(event.Conditions))
		for j, condition := range event.Conditions {
			newConditions[j] = substituteRecursive(condition, bindings)
		}
		newEvent.Conditions = newConditions

		// Substitute in affects
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = SubstituteInAffectEquation(affect, bindings)
		}
		newEvent.Affects = newAffects

		// Substitute in affect_neg if present
		newAffectNeg := make([]AffectEquation, len(event.AffectNeg))
		for j, affect := range event.AffectNeg {
			newAffectNeg[j] = SubstituteInAffectEquation(affect, bindings)
		}
		newEvent.AffectNeg = newAffectNeg

		newContinuousEvents[i] = newEvent
	}
	newModel.ContinuousEvents = newContinuousEvents

	return newModel
}

// SubstituteInReactionSystem performs substitution across an entire reaction system
func SubstituteInReactionSystem(system ReactionSystem, bindings map[string]Expression) ReactionSystem {
	newSystem := system // Copy the struct

	// Substitute in reactions
	newReactions := make([]Reaction, len(system.Reactions))
	for i, reaction := range system.Reactions {
		newReaction := reaction
		newReaction.Rate = substituteRecursive(reaction.Rate, bindings)
		newReactions[i] = newReaction
	}
	newSystem.Reactions = newReactions

	// Substitute in constraint equations
	newConstraintEquations := make([]Equation, len(system.ConstraintEquations))
	for i, eq := range system.ConstraintEquations {
		newConstraintEquations[i] = SubstituteInEquation(eq, bindings)
	}
	newSystem.ConstraintEquations = newConstraintEquations

	// Substitute in discrete events (same as in model)
	newDiscreteEvents := make([]DiscreteEvent, len(system.DiscreteEvents))
	for i, event := range system.DiscreteEvents {
		newEvent := event

		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			newEvent.Trigger.Expression = substituteRecursive(event.Trigger.Expression, bindings)
		}

		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = SubstituteInAffectEquation(affect, bindings)
		}
		newEvent.Affects = newAffects

		newDiscreteEvents[i] = newEvent
	}
	newSystem.DiscreteEvents = newDiscreteEvents

	// Substitute in continuous events (same as in model)
	newContinuousEvents := make([]ContinuousEvent, len(system.ContinuousEvents))
	for i, event := range system.ContinuousEvents {
		newEvent := event

		newConditions := make([]Expression, len(event.Conditions))
		for j, condition := range event.Conditions {
			newConditions[j] = substituteRecursive(condition, bindings)
		}
		newEvent.Conditions = newConditions

		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = SubstituteInAffectEquation(affect, bindings)
		}
		newEvent.Affects = newAffects

		newAffectNeg := make([]AffectEquation, len(event.AffectNeg))
		for j, affect := range event.AffectNeg {
			newAffectNeg[j] = SubstituteInAffectEquation(affect, bindings)
		}
		newEvent.AffectNeg = newAffectNeg

		newContinuousEvents[i] = newEvent
	}
	newSystem.ContinuousEvents = newContinuousEvents

	return newSystem
}

// SubstituteInFile performs substitution across an entire ESM file
func SubstituteInFile(file EsmFile, bindings map[string]Expression) EsmFile {
	newFile := file // Copy the struct

	// Substitute in models
	newModels := make(map[string]Model)
	for name, model := range file.Models {
		newModels[name] = SubstituteInModel(model, bindings)
	}
	newFile.Models = newModels

	// Substitute in reaction systems
	newReactionSystems := make(map[string]ReactionSystem)
	for name, system := range file.ReactionSystems {
		newReactionSystems[name] = SubstituteInReactionSystem(system, bindings)
	}
	newFile.ReactionSystems = newReactionSystems

	return newFile
}

// PartialSubstitute performs substitution but preserves the original structure when possible
// This is useful when you want to substitute some variables but keep others as symbolic references
func PartialSubstitute(expr Expression, bindings map[string]Expression, keepSymbolic []string) Expression {
	// Create a filtered bindings map that excludes variables we want to keep symbolic
	filteredBindings := make(map[string]Expression)
	for k, v := range bindings {
		shouldKeep := false
		for _, keep := range keepSymbolic {
			if k == keep {
				shouldKeep = true
				break
			}
		}
		if !shouldKeep {
			filteredBindings[k] = v
		}
	}

	return substituteRecursive(expr, filteredBindings)
}

// SubstituteWithScoped performs variable substitution with scoped reference support
func SubstituteWithScoped(expr Expression, bindings map[string]Expression, file *EsmFile, currentSystem string) Expression {
	return substituteRecursiveWithScoped(expr, bindings, file, currentSystem)
}

// SubstituteInModelWithScoped performs substitution across an entire model with scoped reference support
func SubstituteInModelWithScoped(model Model, bindings map[string]Expression, file *EsmFile, modelName string) Model {
	newModel := model // Copy the struct

	// Substitute in equations
	newEquations := make([]Equation, len(model.Equations))
	for i, eq := range model.Equations {
		newEquations[i] = Equation{
			LHS: substituteRecursiveWithScoped(eq.LHS, bindings, file, modelName),
			RHS: substituteRecursiveWithScoped(eq.RHS, bindings, file, modelName),
		}
	}
	newModel.Equations = newEquations

	// Substitute in observed variable expressions
	newVariables := make(map[string]ModelVariable)
	for name, variable := range model.Variables {
		newVar := variable
		if variable.Expression != nil {
			newVar.Expression = substituteRecursiveWithScoped(variable.Expression, bindings, file, modelName)
		}
		newVariables[name] = newVar
	}
	newModel.Variables = newVariables

	// Substitute in discrete events
	newDiscreteEvents := make([]DiscreteEvent, len(model.DiscreteEvents))
	for i, event := range model.DiscreteEvents {
		newEvent := event

		// Substitute in trigger expression if it's a condition type
		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			newEvent.Trigger.Expression = substituteRecursiveWithScoped(event.Trigger.Expression, bindings, file, modelName)
		}

		// Substitute in affects
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{
				LHS: affect.LHS, // Variable name stays the same
				RHS: substituteRecursiveWithScoped(affect.RHS, bindings, file, modelName),
			}
		}
		newEvent.Affects = newAffects

		newDiscreteEvents[i] = newEvent
	}
	newModel.DiscreteEvents = newDiscreteEvents

	// Substitute in continuous events
	newContinuousEvents := make([]ContinuousEvent, len(model.ContinuousEvents))
	for i, event := range model.ContinuousEvents {
		newEvent := event

		// Substitute in conditions
		newConditions := make([]Expression, len(event.Conditions))
		for j, condition := range event.Conditions {
			newConditions[j] = substituteRecursiveWithScoped(condition, bindings, file, modelName)
		}
		newEvent.Conditions = newConditions

		// Substitute in affects
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{
				LHS: affect.LHS, // Variable name stays the same
				RHS: substituteRecursiveWithScoped(affect.RHS, bindings, file, modelName),
			}
		}
		newEvent.Affects = newAffects

		// Substitute in affect_neg if present
		newAffectNeg := make([]AffectEquation, len(event.AffectNeg))
		for j, affect := range event.AffectNeg {
			newAffectNeg[j] = AffectEquation{
				LHS: affect.LHS, // Variable name stays the same
				RHS: substituteRecursiveWithScoped(affect.RHS, bindings, file, modelName),
			}
		}
		newEvent.AffectNeg = newAffectNeg

		newContinuousEvents[i] = newEvent
	}
	newModel.ContinuousEvents = newContinuousEvents

	return newModel
}

// SubstituteInReactionSystemWithScoped performs substitution across an entire reaction system with scoped reference support
func SubstituteInReactionSystemWithScoped(system ReactionSystem, bindings map[string]Expression, file *EsmFile, systemName string) ReactionSystem {
	newSystem := system // Copy the struct

	// Substitute in reactions
	newReactions := make([]Reaction, len(system.Reactions))
	for i, reaction := range system.Reactions {
		newReaction := reaction
		newReaction.Rate = substituteRecursiveWithScoped(reaction.Rate, bindings, file, systemName)
		newReactions[i] = newReaction
	}
	newSystem.Reactions = newReactions

	// Substitute in constraint equations
	newConstraintEquations := make([]Equation, len(system.ConstraintEquations))
	for i, eq := range system.ConstraintEquations {
		newConstraintEquations[i] = Equation{
			LHS: substituteRecursiveWithScoped(eq.LHS, bindings, file, systemName),
			RHS: substituteRecursiveWithScoped(eq.RHS, bindings, file, systemName),
		}
	}
	newSystem.ConstraintEquations = newConstraintEquations

	// Substitute in discrete events (same as in model)
	newDiscreteEvents := make([]DiscreteEvent, len(system.DiscreteEvents))
	for i, event := range system.DiscreteEvents {
		newEvent := event

		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			newEvent.Trigger.Expression = substituteRecursiveWithScoped(event.Trigger.Expression, bindings, file, systemName)
		}

		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{
				LHS: affect.LHS, // Variable name stays the same
				RHS: substituteRecursiveWithScoped(affect.RHS, bindings, file, systemName),
			}
		}
		newEvent.Affects = newAffects

		newDiscreteEvents[i] = newEvent
	}
	newSystem.DiscreteEvents = newDiscreteEvents

	// Substitute in continuous events (same as in model)
	newContinuousEvents := make([]ContinuousEvent, len(system.ContinuousEvents))
	for i, event := range system.ContinuousEvents {
		newEvent := event

		newConditions := make([]Expression, len(event.Conditions))
		for j, condition := range event.Conditions {
			newConditions[j] = substituteRecursiveWithScoped(condition, bindings, file, systemName)
		}
		newEvent.Conditions = newConditions

		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{
				LHS: affect.LHS, // Variable name stays the same
				RHS: substituteRecursiveWithScoped(affect.RHS, bindings, file, systemName),
			}
		}
		newEvent.Affects = newAffects

		newAffectNeg := make([]AffectEquation, len(event.AffectNeg))
		for j, affect := range event.AffectNeg {
			newAffectNeg[j] = AffectEquation{
				LHS: affect.LHS, // Variable name stays the same
				RHS: substituteRecursiveWithScoped(affect.RHS, bindings, file, systemName),
			}
		}
		newEvent.AffectNeg = newAffectNeg

		newContinuousEvents[i] = newEvent
	}
	newSystem.ContinuousEvents = newContinuousEvents

	return newSystem
}

// SubstituteInFileWithScoped performs substitution across an entire ESM file with scoped reference support
func SubstituteInFileWithScoped(file EsmFile, bindings map[string]Expression) EsmFile {
	newFile := file // Copy the struct

	// Substitute in models
	newModels := make(map[string]Model)
	for name, model := range file.Models {
		newModels[name] = SubstituteInModelWithScoped(model, bindings, &file, name)
	}
	newFile.Models = newModels

	// Substitute in reaction systems
	newReactionSystems := make(map[string]ReactionSystem)
	for name, system := range file.ReactionSystems {
		newReactionSystems[name] = SubstituteInReactionSystemWithScoped(system, bindings, &file, name)
	}
	newFile.ReactionSystems = newReactionSystems

	return newFile
}
