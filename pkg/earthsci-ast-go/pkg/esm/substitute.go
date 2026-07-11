package esm

import (
	"reflect"
	"strings"
)

// maxSubstituteDepth bounds substitution recursion so a cyclic binding
// (e.g. x → f(x)) becomes a bounded no-op instead of a stack-overflow panic:
// once the cap is reached the current expression is returned unchanged, which
// breaks the cycle. The cap is far above any realistic expression nesting, so
// well-formed inputs are never affected. (The exported Substitute* API returns
// only Expression, so the guard halts rather than surfacing an error.)
const maxSubstituteDepth = 10000

// Substitute performs variable substitution in expressions
// expr: the expression to substitute into
// bindings: map from variable names to replacement expressions
func Substitute(expr Expression, bindings map[string]Expression) Expression {
	return substituteRecursiveWithScoped(expr, bindings, nil, "")
}

// substituteRecursiveWithScoped is the internal recursive substitution entry
// with scoped-reference support (file != nil enables dotted-name resolution).
func substituteRecursiveWithScoped(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) Expression {
	return substituteDepth(expr, bindings, file, currentSystem, 0)
}

func substituteDepth(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string, depth int) Expression {
	if depth > maxSubstituteDepth {
		return expr // cyclic binding guard — halt without recursing
	}
	switch e := expr.(type) {
	case string:
		// Variable reference — direct binding, then scoped resolution.
		if replacement, exists := bindings[e]; exists {
			return substituteDepth(replacement, bindings, file, currentSystem, depth+1)
		}
		if file != nil && strings.Contains(e, ".") {
			if resolved, found := resolveScopedReference(e, file, currentSystem); found {
				if replacement, exists := bindings[resolved]; exists {
					return substituteDepth(replacement, bindings, file, currentSystem, depth+1)
				}
			}
		}
		return e

	case ExprNode:
		return substituteNode(e, bindings, file, currentSystem, depth)

	case *ExprNode:
		if e == nil {
			return nil
		}
		return substituteNode(*e, bindings, file, currentSystem, depth)

	case float64, int, int32, int64, float32:
		// Numeric literals - no substitution needed
		return e

	default:
		// Handle interface{} that might contain other types
		if e == nil {
			return nil
		}
		// Try to handle the case where expr is wrapped in a pointer.
		v := reflect.ValueOf(e)
		if v.Kind() == reflect.Pointer && !v.IsNil() {
			return substituteDepth(v.Elem().Interface(), bindings, file, currentSystem, depth+1)
		}
		// For unknown types, return as-is
		return e
	}
}

// substituteNode substitutes into an operator node's children (via the shared
// field-preserving walker, so every field survives) and then, for D/grad,
// substitutes the `wrt`/`dim` variable-name slot they carry outside args.
func substituteNode(node ExprNode, bindings map[string]Expression, file *ESMFile, currentSystem string, depth int) Expression {
	out, _ := mapExprChildren(node, func(child Expression) (Expression, error) {
		return substituteDepth(child, bindings, file, currentSystem, depth+1), nil
	})
	if out.Op == OpDerivative {
		out.Wrt = substituteScalarField(out.Wrt, bindings, file, currentSystem)
	}
	if out.Op == OpGrad {
		out.Dim = substituteScalarField(out.Dim, bindings, file, currentSystem)
	}
	return out
}

// substituteScalarField resolves a substitution for a *string variable-name
// slot (a `wrt`/`dim` name a D/grad op carries outside `args`). A binding is
// applied only when the replacement is itself a bare name (string); a
// non-string replacement, or no binding, leaves the slot unchanged. Mirrors the
// string-arm of substituteDepth, minus recursion (a name has no children).
func substituteScalarField(field *string, bindings map[string]Expression, file *ESMFile, currentSystem string) *string {
	if field == nil {
		return nil
	}
	if replacement, exists := bindings[*field]; exists {
		if s, ok := replacement.(string); ok {
			return &s
		}
		return field
	}
	if file != nil && strings.Contains(*field, ".") {
		if resolved, found := resolveScopedReference(*field, file, currentSystem); found {
			if replacement, exists := bindings[resolved]; exists {
				if s, ok := replacement.(string); ok {
					return &s
				}
			}
		}
	}
	return field
}

// SubstituteInEquation substitutes variables in both LHS and RHS of an equation
func SubstituteInEquation(eq Equation, bindings map[string]Expression) Equation {
	return Equation{
		LHS: substituteRecursiveWithScoped(eq.LHS, bindings, nil, ""),
		RHS: substituteRecursiveWithScoped(eq.RHS, bindings, nil, ""),
	}
}

// SubstituteInAffectEquation substitutes variables in an affect equation
// Note: LHS is a variable name (string) so it's not substituted, only RHS
func SubstituteInAffectEquation(affect AffectEquation, bindings map[string]Expression) AffectEquation {
	return AffectEquation{
		LHS: affect.LHS, // Variable name stays the same
		RHS: substituteRecursiveWithScoped(affect.RHS, bindings, nil, ""),
	}
}

// SubstituteInModel performs substitution across an entire model. It is the
// scope-free case of SubstituteInModelWithScoped (file=nil disables dotted-name
// resolution), so it delegates rather than duplicating the traversal.
func SubstituteInModel(model Model, bindings map[string]Expression) Model {
	return SubstituteInModelWithScoped(model, bindings, nil, "")
}

// SubstituteInReactionSystem performs substitution across an entire reaction
// system. Scope-free delegation to SubstituteInReactionSystemWithScoped.
func SubstituteInReactionSystem(system ReactionSystem, bindings map[string]Expression) ReactionSystem {
	return SubstituteInReactionSystemWithScoped(system, bindings, nil, "")
}

// SubstituteInFile performs substitution across an entire ESM file
func SubstituteInFile(file ESMFile, bindings map[string]Expression) ESMFile {
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

	return substituteRecursiveWithScoped(expr, filteredBindings, nil, "")
}

// SubstituteWithScoped performs variable substitution with scoped reference support
func SubstituteWithScoped(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) Expression {
	return substituteRecursiveWithScoped(expr, bindings, file, currentSystem)
}

// SubstituteInModelWithScoped performs substitution across an entire model with scoped reference support
func SubstituteInModelWithScoped(model Model, bindings map[string]Expression, file *ESMFile, modelName string) Model {
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
func SubstituteInReactionSystemWithScoped(system ReactionSystem, bindings map[string]Expression, file *ESMFile, systemName string) ReactionSystem {
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
func SubstituteInFileWithScoped(file ESMFile, bindings map[string]Expression) ESMFile {
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
