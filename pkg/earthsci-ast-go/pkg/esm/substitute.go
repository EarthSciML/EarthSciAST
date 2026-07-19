package esm

import (
	"fmt"
	"reflect"
	"strings"
)

// SubstitutionError is returned when substitution cannot complete. Currently
// the only cause is a cyclic binding — a variable whose expansion reaches
// itself (directly, x → f(x), or transitively, x → y, y → x) — which would
// otherwise recurse forever. It carries the shared "[code] message" diagnostic
// form (DiagnosticError).
type SubstitutionError struct {
	Code    string
	Message string
}

func (e *SubstitutionError) Error() string { return fmt.Sprintf("[%s] %s", e.Code, e.Message) }

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *SubstitutionError) DiagnosticCode() string { return e.Code }

// codeCyclicSubstitution is raised when a binding is cyclic.
const codeCyclicSubstitution = "cyclic_substitution"

// Substitute performs variable substitution in expressions.
// expr: the expression to substitute into
// bindings: map from variable names to replacement expressions
// Returns a SubstitutionError if the bindings are cyclic.
func Substitute(expr Expression, bindings map[string]Expression) (Expression, error) {
	return substituteRecursiveWithScoped(expr, bindings, nil, "")
}

// substituteRecursiveWithScoped is the internal recursive substitution entry
// with scoped-reference support (file != nil enables dotted-name resolution).
// It seeds a fresh cycle-tracking set for each top-level call.
func substituteRecursiveWithScoped(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) (Expression, error) {
	return substituteRec(expr, bindings, file, currentSystem, map[string]bool{})
}

// substituteRec recursively substitutes bindings into expr. visiting is the set
// of binding keys currently being expanded on the active path; re-entering a key
// means the binding is cyclic and yields a SubstitutionError. The set is
// backtracked (a key is removed once its expansion returns), so a variable
// appearing in independent sibling positions is not mistaken for a cycle.
func substituteRec(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string, visiting map[string]bool) (Expression, error) {
	switch e := expr.(type) {
	case string:
		// Variable reference — resolve to a binding key (direct name, else a
		// scoped dotted name), then expand it with cycle tracking.
		key, replacement, ok := lookupBinding(e, bindings, file, currentSystem)
		if !ok {
			return e, nil
		}
		if visiting[key] {
			return nil, &SubstitutionError{
				Code:    codeCyclicSubstitution,
				Message: fmt.Sprintf("cyclic binding: variable '%s' is reachable from its own substitution", key),
			}
		}
		visiting[key] = true
		out, err := substituteRec(replacement, bindings, file, currentSystem, visiting)
		delete(visiting, key)
		return out, err

	case ExprNode:
		return substituteNode(e, bindings, file, currentSystem, visiting)

	case *ExprNode:
		if e == nil {
			return nil, nil
		}
		return substituteNode(*e, bindings, file, currentSystem, visiting)

	case float64, int, int32, int64, float32:
		// Numeric literals - no substitution needed
		return e, nil

	default:
		// Handle interface{} that might contain other types
		if e == nil {
			return nil, nil
		}
		// Try to handle the case where expr is wrapped in a pointer.
		v := reflect.ValueOf(e)
		if v.Kind() == reflect.Pointer && !v.IsNil() {
			return substituteRec(v.Elem().Interface(), bindings, file, currentSystem, visiting)
		}
		// For unknown types, return as-is
		return e, nil
	}
}

// lookupBinding resolves a variable name to the binding key and replacement it
// substitutes to: the direct binding first, then (when file != nil and the name
// is dotted) the scoped-reference resolution. Returns ok=false when no binding
// applies. The returned key is what cycle tracking is keyed on.
func lookupBinding(name string, bindings map[string]Expression, file *ESMFile, currentSystem string) (key string, replacement Expression, ok bool) {
	if r, exists := bindings[name]; exists {
		return name, r, true
	}
	if file != nil && strings.Contains(name, ".") {
		if resolved, found := resolveScopedReference(name, file, currentSystem); found {
			if r, exists := bindings[resolved]; exists {
				return resolved, r, true
			}
		}
	}
	return "", nil, false
}

// substituteNode substitutes into an operator node's children (via the shared
// field-preserving walker, so every field survives) and then resolves the
// variable-name slots a node carries OUTSIDE `args`: the `wrt` of a derivative,
// and the `dim` axis name of ANY node that carries one.
//
// The `dim` slot is resolved STRUCTURALLY — by the field, not the op name
// (esm-spec §4.9.1) — because `dim` is an ordinary axis-naming scalar with no
// privileged op semantics: grad/div/laplacian all carry it, and so may any
// open-tier user op. Keying it on the `grad` op (as this did) silently skipped
// the `dim` of `div`/`laplacian`.
func substituteNode(node ExprNode, bindings map[string]Expression, file *ESMFile, currentSystem string, visiting map[string]bool) (Expression, error) {
	out, err := mapExprChildren(node, func(child Expression) (Expression, error) {
		return substituteRec(child, bindings, file, currentSystem, visiting)
	})
	if err != nil {
		return out, err
	}
	if out.Op == OpDerivative {
		out.Wrt = substituteScalarField(out.Wrt, bindings, file, currentSystem)
	}
	if out.Dim != nil {
		out.Dim = substituteScalarField(out.Dim, bindings, file, currentSystem)
	}
	return out, nil
}

// substituteScalarField resolves a substitution for a *string variable-name
// slot (a `wrt`/`dim` name a D/grad op carries outside `args`). A binding is
// applied only when the replacement is itself a bare name (string); a
// non-string replacement, or no binding, leaves the slot unchanged. It performs
// no recursion (a name has no children), so it cannot introduce a cycle.
func substituteScalarField(field *string, bindings map[string]Expression, file *ESMFile, currentSystem string) *string {
	if field == nil {
		return nil
	}
	if _, replacement, ok := lookupBinding(*field, bindings, file, currentSystem); ok {
		if s, ok := replacement.(string); ok {
			return &s
		}
	}
	return field
}

// SubstituteInEquation substitutes variables in both LHS and RHS of an equation.
func SubstituteInEquation(eq Equation, bindings map[string]Expression) (Equation, error) {
	lhs, err := substituteRecursiveWithScoped(eq.LHS, bindings, nil, "")
	if err != nil {
		return Equation{}, err
	}
	rhs, err := substituteRecursiveWithScoped(eq.RHS, bindings, nil, "")
	if err != nil {
		return Equation{}, err
	}
	return Equation{LHS: lhs, RHS: rhs}, nil
}

// SubstituteInAffectEquation substitutes variables in an affect equation.
// Note: LHS is a variable name (string) so it's not substituted, only RHS.
func SubstituteInAffectEquation(affect AffectEquation, bindings map[string]Expression) (AffectEquation, error) {
	rhs, err := substituteRecursiveWithScoped(affect.RHS, bindings, nil, "")
	if err != nil {
		return AffectEquation{}, err
	}
	return AffectEquation{LHS: affect.LHS, RHS: rhs}, nil
}

// SubstituteInModel performs substitution across an entire model. It is the
// scope-free case of SubstituteInModelWithScoped (file=nil disables dotted-name
// resolution), so it delegates rather than duplicating the traversal.
func SubstituteInModel(model Model, bindings map[string]Expression) (Model, error) {
	return SubstituteInModelWithScoped(model, bindings, nil, "")
}

// SubstituteInReactionSystem performs substitution across an entire reaction
// system. Scope-free delegation to SubstituteInReactionSystemWithScoped.
func SubstituteInReactionSystem(system ReactionSystem, bindings map[string]Expression) (ReactionSystem, error) {
	return SubstituteInReactionSystemWithScoped(system, bindings, nil, "")
}

// SubstituteInFile performs substitution across an entire ESM file.
func SubstituteInFile(file ESMFile, bindings map[string]Expression) (ESMFile, error) {
	newFile := file // Copy the struct

	newModels := make(map[string]Model)
	for name, model := range file.Models {
		out, err := SubstituteInModel(model, bindings)
		if err != nil {
			return ESMFile{}, err
		}
		newModels[name] = out
	}
	newFile.Models = newModels

	newReactionSystems := make(map[string]ReactionSystem)
	for name, system := range file.ReactionSystems {
		out, err := SubstituteInReactionSystem(system, bindings)
		if err != nil {
			return ESMFile{}, err
		}
		newReactionSystems[name] = out
	}
	newFile.ReactionSystems = newReactionSystems

	return newFile, nil
}

// PartialSubstitute performs substitution but preserves the original structure
// when possible. This is useful when you want to substitute some variables but
// keep others as symbolic references.
func PartialSubstitute(expr Expression, bindings map[string]Expression, keepSymbolic []string) (Expression, error) {
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

// SubstituteWithScoped performs variable substitution with scoped reference support.
func SubstituteWithScoped(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) (Expression, error) {
	return substituteRecursiveWithScoped(expr, bindings, file, currentSystem)
}

// SubstituteInModelWithScoped performs substitution across an entire model with
// scoped reference support.
func SubstituteInModelWithScoped(model Model, bindings map[string]Expression, file *ESMFile, modelName string) (Model, error) {
	newModel := model // Copy the struct

	// sub applies substitution and latches the first error, so the traversal
	// below reads like a straight-line rewrite; the latched error is returned
	// once at the end.
	var firstErr error
	sub := func(e Expression) Expression {
		if firstErr != nil {
			return e
		}
		out, err := substituteRecursiveWithScoped(e, bindings, file, modelName)
		if err != nil {
			firstErr = err
			return e
		}
		return out
	}

	// Substitute in equations
	newEquations := make([]Equation, len(model.Equations))
	for i, eq := range model.Equations {
		newEquations[i] = Equation{LHS: sub(eq.LHS), RHS: sub(eq.RHS)}
	}
	newModel.Equations = newEquations

	// Substitute in observed variable expressions
	newVariables := make(map[string]ModelVariable)
	for name, variable := range model.Variables {
		newVar := variable
		if variable.Expression != nil {
			newVar.Expression = sub(variable.Expression)
		}
		newVariables[name] = newVar
	}
	newModel.Variables = newVariables

	// Substitute in discrete events
	newDiscreteEvents := make([]DiscreteEvent, len(model.DiscreteEvents))
	for i, event := range model.DiscreteEvents {
		newEvent := event
		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			newEvent.Trigger.Expression = sub(event.Trigger.Expression)
		}
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{LHS: affect.LHS, RHS: sub(affect.RHS)}
		}
		newEvent.Affects = newAffects
		newDiscreteEvents[i] = newEvent
	}
	newModel.DiscreteEvents = newDiscreteEvents

	// Substitute in continuous events
	newContinuousEvents := make([]ContinuousEvent, len(model.ContinuousEvents))
	for i, event := range model.ContinuousEvents {
		newEvent := event
		newConditions := make([]Expression, len(event.Conditions))
		for j, condition := range event.Conditions {
			newConditions[j] = sub(condition)
		}
		newEvent.Conditions = newConditions
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{LHS: affect.LHS, RHS: sub(affect.RHS)}
		}
		newEvent.Affects = newAffects
		newAffectNeg := make([]AffectEquation, len(event.AffectNeg))
		for j, affect := range event.AffectNeg {
			newAffectNeg[j] = AffectEquation{LHS: affect.LHS, RHS: sub(affect.RHS)}
		}
		newEvent.AffectNeg = newAffectNeg
		newContinuousEvents[i] = newEvent
	}
	newModel.ContinuousEvents = newContinuousEvents

	if firstErr != nil {
		return Model{}, firstErr
	}
	return newModel, nil
}

// SubstituteInReactionSystemWithScoped performs substitution across an entire
// reaction system with scoped reference support.
func SubstituteInReactionSystemWithScoped(system ReactionSystem, bindings map[string]Expression, file *ESMFile, systemName string) (ReactionSystem, error) {
	newSystem := system // Copy the struct

	var firstErr error
	sub := func(e Expression) Expression {
		if firstErr != nil {
			return e
		}
		out, err := substituteRecursiveWithScoped(e, bindings, file, systemName)
		if err != nil {
			firstErr = err
			return e
		}
		return out
	}

	// Substitute in reactions
	newReactions := make([]Reaction, len(system.Reactions))
	for i, reaction := range system.Reactions {
		newReaction := reaction
		newReaction.Rate = sub(reaction.Rate)
		newReactions[i] = newReaction
	}
	newSystem.Reactions = newReactions

	// Substitute in constraint equations
	newConstraintEquations := make([]Equation, len(system.ConstraintEquations))
	for i, eq := range system.ConstraintEquations {
		newConstraintEquations[i] = Equation{LHS: sub(eq.LHS), RHS: sub(eq.RHS)}
	}
	newSystem.ConstraintEquations = newConstraintEquations

	// Substitute in discrete events (same as in model)
	newDiscreteEvents := make([]DiscreteEvent, len(system.DiscreteEvents))
	for i, event := range system.DiscreteEvents {
		newEvent := event
		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			newEvent.Trigger.Expression = sub(event.Trigger.Expression)
		}
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{LHS: affect.LHS, RHS: sub(affect.RHS)}
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
			newConditions[j] = sub(condition)
		}
		newEvent.Conditions = newConditions
		newAffects := make([]AffectEquation, len(event.Affects))
		for j, affect := range event.Affects {
			newAffects[j] = AffectEquation{LHS: affect.LHS, RHS: sub(affect.RHS)}
		}
		newEvent.Affects = newAffects
		newAffectNeg := make([]AffectEquation, len(event.AffectNeg))
		for j, affect := range event.AffectNeg {
			newAffectNeg[j] = AffectEquation{LHS: affect.LHS, RHS: sub(affect.RHS)}
		}
		newEvent.AffectNeg = newAffectNeg
		newContinuousEvents[i] = newEvent
	}
	newSystem.ContinuousEvents = newContinuousEvents

	if firstErr != nil {
		return ReactionSystem{}, firstErr
	}
	return newSystem, nil
}

// SubstituteInFileWithScoped performs substitution across an entire ESM file
// with scoped reference support.
func SubstituteInFileWithScoped(file ESMFile, bindings map[string]Expression) (ESMFile, error) {
	newFile := file // Copy the struct

	newModels := make(map[string]Model)
	for name, model := range file.Models {
		out, err := SubstituteInModelWithScoped(model, bindings, &file, name)
		if err != nil {
			return ESMFile{}, err
		}
		newModels[name] = out
	}
	newFile.Models = newModels

	newReactionSystems := make(map[string]ReactionSystem)
	for name, system := range file.ReactionSystems {
		out, err := SubstituteInReactionSystemWithScoped(system, bindings, &file, name)
		if err != nil {
			return ESMFile{}, err
		}
		newReactionSystems[name] = out
	}
	newFile.ReactionSystems = newReactionSystems

	return newFile, nil
}
