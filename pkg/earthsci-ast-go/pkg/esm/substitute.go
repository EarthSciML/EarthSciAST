package esm

import (
	"reflect"
	"strings"
)

// Substitute performs variable substitution in expressions.
// expr: the expression to substitute into
// bindings: map from variable names to replacement expressions
//
// Substitution is SINGLE-PASS (non-transitive), per the normative contract in
// CONFORMANCE_SPEC.md §2.2.3 rule 1: a binding's replacement is inserted
// verbatim and is NOT itself re-substituted. Given {x -> y, y -> x},
// substituting "x" yields "y". This is what guarantees termination for
// self-referential and mutually-referential binding sets without any cycle
// detection, and it is what makes a binding map usable as a simultaneous
// RENAME map (edit.go's renameRawExpr): {a -> b, b -> c} renames a to b, not
// to c.
//
// The error return is retained for signature stability across the package's
// substitution family; single-pass substitution over a decoded expression has
// no failure mode of its own.
func Substitute(expr Expression, bindings map[string]Expression) (Expression, error) {
	return substituteRecursiveWithScoped(expr, bindings, nil, "")
}

// substituteRecursiveWithScoped is the internal recursive substitution entry
// with scoped-reference support (file != nil enables dotted-name resolution).
func substituteRecursiveWithScoped(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) (Expression, error) {
	return substituteRec(expr, bindings, file, currentSystem)
}

// substituteRec recursively substitutes bindings into expr. The recursion is
// over the AST STRUCTURE only — it descends into an operator node's children,
// never into a replacement it just inserted (see Substitute).
func substituteRec(expr Expression, bindings map[string]Expression, file *ESMFile, currentSystem string) (Expression, error) {
	switch e := expr.(type) {
	case string:
		// Variable reference — resolve to a binding (direct name, else a
		// scoped dotted name) and insert the replacement verbatim.
		_, replacement, ok := lookupBinding(e, bindings, file, currentSystem)
		if !ok {
			return e, nil
		}
		return replacement, nil

	case ExprNode:
		return substituteNode(e, bindings, file, currentSystem)

	case *ExprNode:
		if e == nil {
			return nil, nil
		}
		return substituteNode(*e, bindings, file, currentSystem)

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
			return substituteRec(v.Elem().Interface(), bindings, file, currentSystem)
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
func substituteNode(node ExprNode, bindings map[string]Expression, file *ESMFile, currentSystem string) (Expression, error) {
	out, err := mapExprChildren(node, func(child Expression) (Expression, error) {
		return substituteRec(child, bindings, file, currentSystem)
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
// no recursion (a name has no children).
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

	// Substitute in every Expression position a variable carries. From esm 1.0.0
	// those are the parameter `update` rules (`when`, `expression`,
	// `from.unit_conversion`); an observed unknown's defining expression is an
	// ordinary equation and was already rewritten above.
	newVariables := make(map[string]ModelVariable)
	for name, variable := range model.Variables {
		newVar := variable
		for _, site := range VariableExprSites(&newVar) {
			site.Set(sub(site.Expr))
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
