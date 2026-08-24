package esm

// edit.go implements the structural editing operations of esm-libraries-spec §4:
// variable ops, equation ops, reaction ops, event ops, coupling ops, and the
// file-level merge / extract.
//
// # Immutability
//
// Every operation here is NON-MUTATING: it returns a new value and never writes
// through the input. Go gives that only partly for free — a struct is copied by
// assignment, but its maps and slices are shared with the copy — so each
// operation explicitly reallocates the collection it changes. The result is the
// same contract TypeScript's edit.ts states ("All operations are immutable and
// return new objects") with the same shallow-copy shape as its object spread:
// the modified collection is freshly allocated and never aliases the input's,
// while collections the operation did not touch are shared. Callers must not
// mutate a shared collection in place afterwards, exactly as in TypeScript.
//
// # Drop-when-empty
//
// TypeScript represents an emptied collection by OMITTING its key. Go reaches
// the same emitted shape through `omitempty` rather than through a delete: an
// operation that removes the last element leaves an EMPTY, non-nil collection,
// which `encoding/json` then omits for every optional field (`coupling`,
// `continuous_events`, `discrete_events`, `subsystems`, …). Empty is used
// rather than nil deliberately — Model.Variables / Model.Equations /
// ReactionSystem.Species carry no `omitempty`, so a nil there would serialize
// as `null` and produce a schema-INVALID document, whereas an empty collection
// serializes as `{}` / `[]`.
//
// # Errors
//
// The operations that can fail return a typed error: *EntityNotFoundError when
// the target does not exist, *VariableInUseError when a removal would strand a
// live reference, and *EditError for anything else. All three carry a stable
// DiagnosticCode(), matching the EvaluationError / ExpressionTemplateError convention
// elsewhere in this package. Operations that cannot fail (the `Add*` family)
// return a bare value, as they do in TypeScript and Julia.
//
// Reference bindings: TypeScript `src/edit.ts` and Julia `src/edit.jl`, whose
// operation set and semantics agree and are followed here. Where they differ,
// TypeScript is followed and the divergence is marked DIVERGENCE at its site —
// TypeScript's is the 1.0.0-era file (it knows a data source is not a
// component, and that an observed unknown has no per-variable `expression`),
// while Julia's still models species as a vector of named structs and offers
// `extract` on a data source.

import (
	"encoding/json"
	"fmt"
	"strings"
)

// --- diagnostic codes ------------------------------------------------------

const (
	// CodeEditEntityNotFound: an edit names a variable, equation, reaction,
	// species, event, coupling entry, or component that does not exist.
	CodeEditEntityNotFound = "entity_not_found"
	// CodeEditVariableInUse: a removal would strand a live reference to the
	// removed name.
	CodeEditVariableInUse = "variable_in_use"
	// CodeEditInvalidOperation: an edit is refused for a reason other than the
	// two above (e.g. it would empty a collection the schema requires to be
	// non-empty).
	CodeEditInvalidOperation = "invalid_operation"
)

// --- typed errors ----------------------------------------------------------

// EditError is the base diagnostic for a failed editing operation, and the
// error type for failures with no more specific type. It mirrors Julia's
// catch-all `EditError` and Rust's `EditError` enum.
type EditError struct {
	Code    string
	Message string
}

func (e *EditError) Error() string { return fmt.Sprintf("[%s] %s", e.Code, e.Message) }

// DiagnosticCode exposes the stable code.
func (e *EditError) DiagnosticCode() string { return e.Code }

// EntityNotFoundError reports an operation on a non-existent entity. Mirrors
// TypeScript's `EntityNotFoundError`.
type EntityNotFoundError struct {
	EditError
	EntityType string
	EntityName string
}

func newEntityNotFound(entityType, entityName string) *EntityNotFoundError {
	return &EntityNotFoundError{
		EditError: EditError{
			Code:    CodeEditEntityNotFound,
			Message: fmt.Sprintf("%s %q not found", entityType, entityName),
		},
		EntityType: entityType,
		EntityName: entityName,
	}
}

// VariableInUseError reports an attempt to remove a name that is still
// referenced. References lists the sites, in discovery order, using the same
// human-readable labels the TypeScript binding emits. Mirrors TypeScript's
// `VariableInUseError`.
type VariableInUseError struct {
	EditError
	VariableName string
	References   []string
}

func newVariableInUse(name string, references []string) *VariableInUseError {
	return &VariableInUseError{
		EditError: EditError{
			Code: CodeEditVariableInUse,
			Message: fmt.Sprintf("cannot remove variable %q: still referenced in %s",
				name, strings.Join(references, ", ")),
		},
		VariableName: name,
		References:   references,
	}
}

func newEditError(code, format string, args ...any) *EditError {
	return &EditError{Code: code, Message: fmt.Sprintf(format, args...)}
}

// --- copy helpers ----------------------------------------------------------

// copyMap returns a fresh map holding the same entries. A nil input yields an
// empty (non-nil) map, so an operation on an absent collection still produces a
// collection the caller can read back.
func copyMap[V any](m map[string]V) map[string]V {
	out := make(map[string]V, len(m)+1)
	for k, v := range m {
		out[k] = v
	}
	return out
}

// copySlice returns a fresh slice holding the same elements. A nil input yields
// an empty (non-nil) slice.
func copySlice[T any](s []T) []T {
	out := make([]T, len(s))
	copy(out, s)
	return out
}

// --- reference scanning ----------------------------------------------------

// modelExpressionSite is one Expression read-site in a model, paired with the
// human-readable location label used verbatim in VariableInUseError.References.
type modelExpressionSite struct {
	Expr Expression
	Site string
}

// isSubsystemRefStub reports whether a raw subsystem value is an unresolved
// `{"ref": …}` stub rather than an inline component. A stub is an opaque leaf:
// there is nothing local to scan or rewrite inside it.
func isSubsystemRefStub(raw any) bool {
	obj, ok := raw.(map[string]any)
	if !ok {
		return false
	}
	_, hasRef := obj["ref"]
	return hasRef
}

// modelExpressionSites enumerates every EXPRESSION read-site in a model, in a
// single documented order.
//
// This is the shared, read-side definition of "a model's expression sites". It
// MUST stay in lockstep with the write-side set rewritten by RenameVariable, so
// RemoveVariable (which scans these sites) and RenameVariable (which rewrites
// them) can never disagree on where a variable may appear — the invariant
// TypeScript's edit.ts states for the same pair.
//
// Sites, in order: equation `lhs`/`rhs`; every Expression position a variable
// carries (the parameter `update` rules' `when` / `expression` /
// `from.unit_conversion`, via VariableExprSites); continuous-event
// `conditions[]`, `affects[].rhs`, `affect_neg[].rhs`; discrete-event
// condition-`trigger.expression`, `affects[].rhs`; then, recursed with a dotted
// prefix, every INLINE model subsystem (reference stubs are opaque leaves and
// are skipped).
//
// There is deliberately no per-variable defining `expression` to visit: from
// esm 1.0.0 an observed unknown is defined by the bare-variable-LHS equation
// naming it, which is one of the equations already visited above.
//
// Affect `lhs` targets are variable NAMES, not expression sites, and are
// handled by the caller.
func modelExpressionSites(model Model, prefix string) []modelExpressionSite {
	var sites []modelExpressionSite
	visit := func(expr Expression, site string) {
		sites = append(sites, modelExpressionSite{Expr: expr, Site: prefix + site})
	}

	for i, eq := range model.Equations {
		visit(eq.LHS, fmt.Sprintf("equation %d", i))
		visit(eq.RHS, fmt.Sprintf("equation %d", i))
	}
	for _, name := range sortedKeys(model.Variables) {
		v := model.Variables[name]
		for _, site := range VariableExprSites(&v) {
			visit(site.Expr, fmt.Sprintf("variable %s%s", name, site.Path))
		}
	}
	for i, event := range model.ContinuousEvents {
		for _, condition := range event.Conditions {
			visit(condition, fmt.Sprintf("continuous_event %d condition", i))
		}
		for j, affect := range event.Affects {
			visit(affect.RHS, fmt.Sprintf("continuous_event %d affect %d", i, j))
		}
		for j, affect := range event.AffectNeg {
			visit(affect.RHS, fmt.Sprintf("continuous_event %d affect_neg %d", i, j))
		}
	}
	for i, event := range model.DiscreteEvents {
		if event.Trigger.Type == "condition" && event.Trigger.Expression != nil {
			visit(event.Trigger.Expression, fmt.Sprintf("discrete_event %d trigger", i))
		}
		for j, affect := range event.Affects {
			visit(affect.RHS, fmt.Sprintf("discrete_event %d affect %d", i, j))
		}
	}
	for _, name := range sortedKeys(model.Subsystems) {
		raw := model.Subsystems[name]
		if isSubsystemRefStub(raw) {
			continue
		}
		sub, ok := decodeSubsystemAs[Model](raw)
		if !ok {
			continue
		}
		sites = append(sites, modelExpressionSites(sub, prefix+name+".")...)
	}
	return sites
}

// referencesVariable reports whether an expression reads `name`.
//
// Recursion is delegated to FreeVariables, which routes through the shared
// field-preserving walker, so EVERY expression-bearing field is covered —
// aggregate `expr`/`filter`, integral bounds, `makearray` values,
// `table_lookup` axes, and the rest — not just `args`.
//
// A SCOPED reference like "Model.Sub.var" references the variable when one of
// its dot-separated segments matches exactly; substring matching would falsely
// match "x" against "prefix.xy".
func referencesVariable(expr Expression, name string) bool {
	for free := range FreeVariables(expr) {
		if free == name {
			return true
		}
		if strings.Contains(free, ".") {
			for _, seg := range strings.Split(free, ".") {
				if seg == name {
					return true
				}
			}
		}
	}
	return false
}

// exprEqual reports field-aware structural equality of two Expressions.
//
// Comparison is by canonical JSON encoding rather than reflect.DeepEqual: it
// normalizes the several on-heap spellings of the same value (a json.Number and
// the float64 it decodes to; an ExprNode and a *ExprNode) while still
// distinguishing nodes that differ in ANY field — so two `const` nodes with
// different `value`s, or two derivatives differing only in `wrt`, are correctly
// NOT equal.
func exprEqual(a, b Expression) bool {
	an, aIsNode := asExprNode(a)
	bn, bIsNode := asExprNode(b)
	if aIsNode != bIsNode {
		return false
	}
	var av, bv any = a, b
	if aIsNode {
		av, bv = an, bn
	}
	ab, err1 := json.Marshal(av)
	bb, err2 := json.Marshal(bv)
	if err1 != nil || err2 != nil {
		return false
	}
	return string(ab) == string(bb)
}

// =============================================================================
// Variable operations (§4.1)
// =============================================================================

// AddVariable returns a copy of `model` carrying `variable` under `name`. An
// existing variable of that name is replaced.
func AddVariable(model Model, name string, variable ModelVariable) Model {
	out := model
	out.Variables = copyMap(model.Variables)
	out.Variables[name] = variable
	return out
}

// RemoveVariable returns a copy of `model` without the variable `name`, after
// checking that nothing still references it.
//
// Returns *EntityNotFoundError when the variable does not exist, and
// *VariableInUseError when it is still read from any expression site (see
// modelExpressionSites) or written by any event affect. A site reported from
// more than one position — an equation matching in both `lhs` and `rhs` — is
// collapsed to a single reference, preserving discovery order.
func RemoveVariable(model Model, name string) (Model, error) {
	if _, ok := model.Variables[name]; !ok {
		return model, newEntityNotFound("Variable", name)
	}

	var references []string
	seen := map[string]bool{}
	add := func(site string) {
		if !seen[site] {
			seen[site] = true
			references = append(references, site)
		}
	}

	for _, site := range modelExpressionSites(model, "") {
		if referencesVariable(site.Expr, name) {
			add(site.Site)
		}
	}

	// Event affect TARGETS are variable NAMES, not expression read-sites: a
	// variable WRITTEN by an event is still in use, so it is checked here rather
	// than in the Expression-typed enumerator above.
	for i, event := range model.ContinuousEvents {
		for j, affect := range event.Affects {
			if affect.LHS == name {
				add(fmt.Sprintf("continuous_event %d affect %d", i, j))
			}
		}
		for j, affect := range event.AffectNeg {
			if affect.LHS == name {
				add(fmt.Sprintf("continuous_event %d affect_neg %d", i, j))
			}
		}
	}
	for i, event := range model.DiscreteEvents {
		for j, affect := range event.Affects {
			if affect.LHS == name {
				add(fmt.Sprintf("discrete_event %d affect %d", i, j))
			}
		}
	}

	if len(references) > 0 {
		return model, newVariableInUse(name, references)
	}

	out := model
	out.Variables = copyMap(model.Variables)
	delete(out.Variables, name)
	return out, nil
}

// RenameVariable returns a copy of `model` with the variable `oldName` renamed
// to `newName`, everywhere.
//
// The rewrite covers exactly the expression sites RemoveVariable scans — the
// equations, the variables' own Expression positions, the event
// conditions/triggers/affect RHSs, and every inline subsystem — so a rename
// never leaves a dangling reference in a site the removal guard would have
// flagged. Event affect TARGETS (variable names, not expressions) are rewritten
// too, for the same reason they are checked on removal.
//
// Returns *EntityNotFoundError when `oldName` does not exist. Renaming onto an
// existing name REPLACES it, matching TypeScript and Julia.
//
// SCOPE. Given only a Model, this cannot resolve a SCOPED reference — a name
// like "EarthSystem.global_forcing", which some documents use to reach a
// variable of the enclosing model by its fully-qualified path. Resolving one
// needs the document (to know which component the path names) and the model's
// own name, and this signature carries neither. RemoveVariable's guard, by
// contrast, treats a scoped reference whose segments include `name` as a use,
// so it correctly REFUSES to remove such a variable — the safe direction. Use
// renameInRawComponent applies `bindings` to the expression positions of a RAW
// inline-subsystem view, returning a rewritten copy and whether anything
// changed.
//
// It walks exactly the positions modelExpressionSites reads, spelled with the
// document's own JSON keys: equation `lhs`/`rhs`; each variable's `update`
// rules' `when` / `expression` / `from.unit_conversion`; continuous-event
// `conditions[]`, `affects[].rhs` / `.lhs`, `affect_neg[].rhs` / `.lhs`;
// discrete-event condition-`trigger.expression` and `affects[].rhs` / `.lhs`;
// and, recursively, nested inline subsystems. Every other key — including ones
// no Go struct models — is carried through untouched.
//
// A subsystem that is a REACTION SYSTEM rather than a model is left alone here,
// matching modelExpressionSites (and TypeScript's enumerator), which treat an
// inline subsystem as a model.
func renameInRawComponent(raw map[string]any, bindings map[string]Expression) (map[string]any, bool, error) {
	out := copyMap(raw)
	changed := false

	// rewriteAt replaces the value at obj[key], when present, with its
	// substituted form.
	rewriteAt := func(obj map[string]any, key string) error {
		v, has := obj[key]
		if !has {
			return nil
		}
		next, did, err := renameRawExpr(v, bindings)
		if err != nil {
			return err
		}
		if did {
			obj[key] = next
			changed = true
		}
		return nil
	}
	// rewriteName replaces a bare variable-NAME slot (an affect target).
	rewriteName := func(obj map[string]any, key string) {
		name, ok := obj[key].(string)
		if !ok {
			return
		}
		if replacement, bound := bindings[name]; bound {
			if s, isString := replacement.(string); isString {
				obj[key] = s
				changed = true
			}
		}
	}
	// listOfObjects returns a mutable copy of a raw list whose elements are
	// objects, writing it back into `parent` under `key`.
	listOfObjects := func(parent map[string]any, key string) []map[string]any {
		list, ok := parent[key].([]any)
		if !ok {
			return nil
		}
		copied := make([]any, len(list))
		objs := make([]map[string]any, 0, len(list))
		for i, el := range list {
			if obj, ok := el.(map[string]any); ok {
				dup := copyMap(obj)
				copied[i] = dup
				objs = append(objs, dup)
				continue
			}
			copied[i] = el
		}
		parent[key] = copied
		return objs
	}

	for _, root := range []string{"equations", "initialization_equations"} {
		for _, eq := range listOfObjects(out, root) {
			if err := rewriteAt(eq, "lhs"); err != nil {
				return nil, false, err
			}
			if err := rewriteAt(eq, "rhs"); err != nil {
				return nil, false, err
			}
		}
	}

	if variables, ok := out["variables"].(map[string]any); ok {
		copiedVars := copyMap(variables)
		out["variables"] = copiedVars
		for _, varName := range sortedRawKeys(copiedVars) {
			variable, ok := copiedVars[varName].(map[string]any)
			if !ok {
				continue
			}
			variable = copyMap(variable)
			copiedVars[varName] = variable
			rules := []map[string]any{}
			switch u := variable["update"].(type) {
			case map[string]any:
				dup := copyMap(u)
				variable["update"] = dup
				rules = append(rules, dup)
			case []any:
				rules = listOfObjects(variable, "update")
			}
			for _, rule := range rules {
				if err := rewriteAt(rule, "when"); err != nil {
					return nil, false, err
				}
				if err := rewriteAt(rule, "expression"); err != nil {
					return nil, false, err
				}
				if from, ok := rule["from"].(map[string]any); ok {
					dup := copyMap(from)
					rule["from"] = dup
					if err := rewriteAt(dup, "unit_conversion"); err != nil {
						return nil, false, err
					}
				}
			}
		}
	}

	for _, event := range listOfObjects(out, "continuous_events") {
		if conditions, ok := event["conditions"].([]any); ok {
			copied := make([]any, len(conditions))
			for i, condition := range conditions {
				next, did, err := renameRawExpr(condition, bindings)
				if err != nil {
					return nil, false, err
				}
				if did {
					changed = true
				}
				copied[i] = next
			}
			event["conditions"] = copied
		}
		for _, key := range []string{"affects", "affect_neg"} {
			for _, affect := range listOfObjects(event, key) {
				if err := rewriteAt(affect, "rhs"); err != nil {
					return nil, false, err
				}
				rewriteName(affect, "lhs")
			}
		}
	}

	for _, event := range listOfObjects(out, "discrete_events") {
		if trigger, ok := event["trigger"].(map[string]any); ok {
			if kind, _ := trigger["type"].(string); kind == "condition" {
				dup := copyMap(trigger)
				event["trigger"] = dup
				if err := rewriteAt(dup, "expression"); err != nil {
					return nil, false, err
				}
			}
		}
		for _, affect := range listOfObjects(event, "affects") {
			if err := rewriteAt(affect, "rhs"); err != nil {
				return nil, false, err
			}
			rewriteName(affect, "lhs")
		}
	}

	if subsystems, ok := out["subsystems"].(map[string]any); ok {
		var copied map[string]any
		for _, name := range sortedRawKeys(subsystems) {
			sub, ok := subsystems[name].(map[string]any)
			if !ok || isSubsystemRefStub(sub) {
				continue
			}
			rewritten, did, err := renameInRawComponent(sub, bindings)
			if err != nil {
				return nil, false, err
			}
			if !did {
				continue
			}
			if copied == nil {
				copied = copyMap(subsystems)
				out["subsystems"] = copied
			}
			copied[name] = rewritten
			changed = true
		}
	}

	return out, changed, nil
}

// renameRawExpr substitutes into ONE raw expression value, returning the
// rewritten raw value and whether it changed.
//
// The value is normalized to the typed Expression union, substituted with the
// package's own field-preserving substituter, and rendered back to the raw
// decoded form — so the rewrite covers every expression-bearing field (an
// aggregate's `expr`/`filter`, integral bounds, a `table_lookup`'s axes, …)
// rather than only `args`, and the result is comparable to its neighbours.
func renameRawExpr(value any, bindings map[string]Expression) (any, bool, error) {
	before, err := json.Marshal(value)
	if err != nil {
		return value, false, err
	}
	expr, err := UnmarshalExpression(before)
	if err != nil {
		// Not an expression position after all; leave it exactly as authored.
		return value, false, nil
	}
	substituted, err := Substitute(expr, bindings)
	if err != nil {
		return value, false, err
	}
	// "Changed" is decided by comparing the substituted form against the
	// NORMALIZED original, never against the raw bytes. Normalization is not a
	// change: re-encoding an expression can alter how a literal is SPELLED
	// (a stored `24.0` re-encodes as `24`), and treating that as an edit would
	// rewrite — and quietly renormalize — every expression in every subsystem,
	// including the ones the rename never touched.
	normalized, err := json.Marshal(expr)
	if err != nil {
		return value, false, err
	}
	after, err := json.Marshal(substituted)
	if err != nil {
		return value, false, err
	}
	if string(after) == string(normalized) {
		return value, false, nil
	}
	var raw any
	if err := json.Unmarshal(after, &raw); err != nil {
		return value, false, err
	}
	return raw, true, nil
}

// RenameVariableInFile when the document is available; it resolves scoped
// references and rewrites coupling endpoints too. TypeScript's renameVariable
// has exactly this limitation, for exactly this reason: it calls
// substituteInModel without the esmFile context that its own scoped-reference
// resolution requires.
func RenameVariable(model Model, oldName, newName string) (Model, error) {
	if _, ok := model.Variables[oldName]; !ok {
		return model, newEntityNotFound("Variable", oldName)
	}
	if oldName == newName {
		return model, nil
	}

	out, err := renameInModel(model, oldName, newName, "")
	if err != nil {
		return model, err
	}

	// The declaration must be moved from the REWRITTEN model, not the input:
	// a variable's own Expression positions (a parameter's `update.when` /
	// `expression` / `from.unit_conversion`) may reference the renamed name, and
	// renameInModel has already rewritten them. Carrying the input's copy across
	// would silently restore the old name inside its own update rules.
	variable := out.Variables[oldName]
	out.Variables = copyMap(out.Variables)
	delete(out.Variables, oldName)
	out.Variables[newName] = variable
	return out, nil
}

// renameInModel rewrites every read-site and every affect target of a model,
// recursing into inline subsystems. It is the write-side counterpart of
// modelExpressionSites.
//
// `qualifier`, when non-empty, is the enclosing model's name: the rewrite then
// also binds the SELF-QUALIFIED spelling "<qualifier>.<oldName>" to
// "<qualifier>.<newName>", which is how RenameVariableInFile reaches a
// fully-qualified read the model-only entry point cannot see.
//
// The qualified spelling is bound EXPLICITLY rather than left to
// SubstituteInModelWithScoped's dotted-name resolution. That resolution maps a
// scoped path to the LEAF name it designates, so "M.Sub.v" and a model-level
// variable also called "v" would resolve to the same binding key even though
// they are different variables — and the rewrite would replace the qualified
// path with a bare local name, changing both what it denotes and how it reads.
// Binding the exact spelling keeps the rewrite total and textual: a qualified
// read stays qualified, and nothing but the intended variable is touched.
func renameInModel(model Model, oldName, newName, qualifier string) (Model, error) {
	bindings := map[string]Expression{oldName: newName}
	if qualifier != "" {
		bindings[qualifier+"."+oldName] = qualifier + "." + newName
	}
	out, err := SubstituteInModel(model, bindings)
	if err != nil {
		return Model{}, newEditError(CodeEditInvalidOperation,
			"cannot rename %q to %q: %v", oldName, newName, err)
	}

	// Event affect targets are names, which the expression substitution does
	// not reach.
	renameAffects := func(affects []AffectEquation) []AffectEquation {
		if len(affects) == 0 {
			return affects
		}
		renamed := copySlice(affects)
		for i := range renamed {
			if renamed[i].LHS == oldName {
				renamed[i].LHS = newName
			}
		}
		return renamed
	}
	if len(out.ContinuousEvents) > 0 {
		events := copySlice(out.ContinuousEvents)
		for i := range events {
			events[i].Affects = renameAffects(events[i].Affects)
			events[i].AffectNeg = renameAffects(events[i].AffectNeg)
		}
		out.ContinuousEvents = events
	}
	if len(out.DiscreteEvents) > 0 {
		events := copySlice(out.DiscreteEvents)
		for i := range events {
			events[i].Affects = renameAffects(events[i].Affects)
		}
		out.DiscreteEvents = events
	}

	// Inline subsystems. SubstituteInModel does not descend into them, but
	// modelExpressionSites does, so the rename must — otherwise the two would
	// disagree about where a variable can live, which is exactly the lockstep
	// RemoveVariable's guard depends on.
	//
	// The rewrite is SURGICAL: it edits the subsystem's RAW stored view at the
	// expression positions only, rather than decoding it to a Model, rewriting
	// that, and re-rendering. Decoding is LOSSY — a key the Model struct does
	// not model (a fixture's `_comment` on an equation, say) does not survive
	// the round trip — so re-rendering every subsystem would quietly strip
	// authored content that the rename has no business touching. Editing the
	// raw view in place touches only the positions that hold expressions and
	// leaves every sibling key exactly as authored.
	if len(model.Subsystems) > 0 {
		var subs map[string]any
		for _, name := range sortedKeys(model.Subsystems) {
			raw, ok := model.Subsystems[name].(map[string]any)
			if !ok || isSubsystemRefStub(raw) {
				continue
			}
			rewritten, changed, err := renameInRawComponent(raw, bindings)
			if err != nil {
				return Model{}, newEditError(CodeEditInvalidOperation,
					"cannot rewrite subsystem %q: %v", name, err)
			}
			if !changed {
				continue
			}
			if subs == nil {
				subs = copyMap(model.Subsystems)
			}
			subs[name] = rewritten
		}
		if subs != nil {
			out.Subsystems = subs
		}
	}

	return out, nil
}

// RenameVariableInFile renames a variable of the model `modelName` throughout
// `file`, and is the scope-aware counterpart of RenameVariable.
//
// Beyond what RenameVariable does, it:
//
//   - resolves SCOPED references while rewriting, so a self-qualified read of
//     the variable ("EarthSystem.global_forcing" inside model EarthSystem) is
//     rewritten rather than left dangling; and
//   - rewrites the coupling endpoints that name the variable — a
//     `variable_map`'s `from`/`to` and an `event` coupling's affect targets —
//     which are plain strings in the file, not expressions inside the model,
//     and so are out of reach of any model-scoped rewrite.
//
// Returns *EntityNotFoundError when the model or the variable does not exist.
//
// This entry point has no counterpart in the other bindings: TypeScript, Julia,
// Rust and Python all stop at the model-scoped rename. It is additive — the
// model-scoped RenameVariable keeps its cross-binding behaviour unchanged.
func RenameVariableInFile(file ESMFile, modelName, oldName, newName string) (ESMFile, error) {
	model, ok := file.Models[modelName]
	if !ok {
		return file, newEntityNotFound("Model", modelName)
	}
	if _, ok := model.Variables[oldName]; !ok {
		return file, newEntityNotFound("Variable", oldName)
	}
	if oldName == newName {
		return file, nil
	}

	renamed, err := renameInModel(model, oldName, newName, modelName)
	if err != nil {
		return file, err
	}
	variable := renamed.Variables[oldName]
	renamed.Variables = copyMap(renamed.Variables)
	delete(renamed.Variables, oldName)
	renamed.Variables[newName] = variable

	out := file
	out.Models = copyMap(file.Models)
	out.Models[modelName] = renamed

	oldRef := modelName + "." + oldName
	newRef := modelName + "." + newName
	rewriteEndpoint := func(ref string) string {
		if ref == oldRef {
			return newRef
		}
		return ref
	}
	if len(file.Coupling) > 0 {
		coupling := copySlice(file.Coupling)
		for i, entry := range coupling {
			switch e := entry.(type) {
			case VariableMapCoupling:
				e.From = rewriteEndpoint(e.From)
				e.To = rewriteEndpoint(e.To)
				coupling[i] = e
			case EventCoupling:
				if len(e.Affects) > 0 {
					affects := copySlice(e.Affects)
					for j := range affects {
						affects[j].LHS = rewriteEndpoint(affects[j].LHS)
					}
					e.Affects = affects
				}
				if len(e.AffectNeg) > 0 {
					affectNeg := copySlice(e.AffectNeg)
					for j := range affectNeg {
						affectNeg[j].LHS = rewriteEndpoint(affectNeg[j].LHS)
					}
					e.AffectNeg = affectNeg
				}
				coupling[i] = e
			}
		}
		out.Coupling = coupling
	}

	return out, nil
}

// =============================================================================
// Equation operations (§4.2)
// =============================================================================

// AddEquation returns a copy of `model` with `equation` appended.
func AddEquation(model Model, equation Equation) Model {
	out := model
	out.Equations = append(copySlice(model.Equations), equation)
	return out
}

// RemoveEquationAt returns a copy of `model` without the equation at `index`.
// Indices are 0-based (Julia's are 1-based; Go and TypeScript agree on 0).
//
// Returns *EntityNotFoundError when the index is out of range.
func RemoveEquationAt(model Model, index int) (Model, error) {
	if index < 0 || index >= len(model.Equations) {
		return model, newEntityNotFound("Equation", fmt.Sprintf("index %d", index))
	}
	out := model
	equations := make([]Equation, 0, len(model.Equations)-1)
	equations = append(equations, model.Equations[:index]...)
	equations = append(equations, model.Equations[index+1:]...)
	out.Equations = equations
	return out, nil
}

// RemoveEquationByLHS returns a copy of `model` without the FIRST equation
// whose left-hand side structurally equals `lhs`.
//
// Matching uses field-aware structural equality (exprEqual), so e.g. two
// `const` nodes with different `value`s, or two derivatives differing only in
// `wrt`, are not treated as the same equation.
//
// Returns *EntityNotFoundError when no equation matches. TypeScript and Julia
// spell this as an overload of their single remove-equation entry point; Go has
// no overloading, so the index and pattern forms are separate functions.
func RemoveEquationByLHS(model Model, lhs Expression) (Model, error) {
	for i, eq := range model.Equations {
		if exprEqual(eq.LHS, lhs) {
			return RemoveEquationAt(model, i)
		}
	}
	rendered, err := json.Marshal(lhs)
	if err != nil {
		rendered = []byte(fmt.Sprint(lhs))
	}
	return model, newEntityNotFound("Equation", fmt.Sprintf("with LHS %s", rendered))
}

// SubstituteInEquations applies `bindings` across a model.
//
// Despite the historical name — carried from the other bindings — this does NOT
// touch only equations: it is a thin alias for SubstituteInModel and therefore
// also rewrites every Expression position the model's variables carry and every
// event expression position. Prefer calling SubstituteInModel directly; this
// exists so the §4.2 operation set is complete under the name the spec and the
// other bindings use.
func SubstituteInEquations(model Model, bindings map[string]Expression) (Model, error) {
	return SubstituteInModel(model, bindings)
}

// =============================================================================
// Reaction operations (§4.3)
// =============================================================================

// AddReaction returns a copy of `system` with `reaction` appended.
func AddReaction(system ReactionSystem, reaction Reaction) ReactionSystem {
	out := system
	out.Reactions = append(copySlice(system.Reactions), reaction)
	return out
}

// RemoveReaction returns a copy of `system` without the reaction whose ID is
// `id`.
//
// Returns *EntityNotFoundError when no reaction has that ID, and *EditError
// (invalid_operation) when the removal would empty the system: the schema
// requires a reaction system to retain at least one reaction, so the sole
// remaining reaction is still required.
func RemoveReaction(system ReactionSystem, id string) (ReactionSystem, error) {
	found := false
	remaining := make([]Reaction, 0, len(system.Reactions))
	for _, r := range system.Reactions {
		if r.ID == id {
			found = true
			continue
		}
		remaining = append(remaining, r)
	}
	if !found {
		return system, newEntityNotFound("Reaction", id)
	}
	if len(remaining) == 0 {
		return system, newEditError(CodeEditInvalidOperation,
			"cannot remove reaction %q: a reaction system must retain at least one reaction", id)
	}
	out := system
	out.Reactions = remaining
	return out, nil
}

// AddSpecies returns a copy of `system` carrying `species` under `name`. An
// existing species of that name is replaced.
func AddSpecies(system ReactionSystem, name string, species Species) ReactionSystem {
	out := system
	out.Species = copyMap(system.Species)
	out.Species[name] = species
	return out
}

// RemoveSpecies returns a copy of `system` without the species `name`, after
// checking that no reaction still references it.
//
// Returns *EntityNotFoundError when the species does not exist, and
// *VariableInUseError when it appears among any reaction's substrates or
// products, or is read by any reaction's rate expression. Constraint equations
// are scanned too — they are ordinary expression sites over the same names.
func RemoveSpecies(system ReactionSystem, name string) (ReactionSystem, error) {
	if _, ok := system.Species[name]; !ok {
		return system, newEntityNotFound("Species", name)
	}

	var references []string
	seen := map[string]bool{}
	add := func(site string) {
		if !seen[site] {
			seen[site] = true
			references = append(references, site)
		}
	}

	for _, reaction := range system.Reactions {
		for _, substrate := range reaction.Substrates {
			if substrate.Species == name {
				add(fmt.Sprintf("reaction %s substrates", reaction.ID))
			}
		}
		for _, product := range reaction.Products {
			if product.Species == name {
				add(fmt.Sprintf("reaction %s products", reaction.ID))
			}
		}
		if referencesVariable(reaction.Rate, name) {
			add(fmt.Sprintf("reaction %s rate", reaction.ID))
		}
	}
	for i, eq := range system.ConstraintEquations {
		if referencesVariable(eq.LHS, name) || referencesVariable(eq.RHS, name) {
			add(fmt.Sprintf("constraint_equation %d", i))
		}
	}

	if len(references) > 0 {
		return system, newVariableInUse(name, references)
	}

	out := system
	out.Species = copyMap(system.Species)
	delete(out.Species, name)
	return out, nil
}

// =============================================================================
// Event operations (§4.4)
// =============================================================================

// AddContinuousEvent returns a copy of `model` with `event` appended.
func AddContinuousEvent(model Model, event ContinuousEvent) Model {
	out := model
	out.ContinuousEvents = append(copySlice(model.ContinuousEvents), event)
	return out
}

// AddDiscreteEvent returns a copy of `model` with `event` appended.
func AddDiscreteEvent(model Model, event DiscreteEvent) Model {
	out := model
	out.DiscreteEvents = append(copySlice(model.DiscreteEvents), event)
	return out
}

// RemoveEvent returns a copy of `model` with every event named `name` removed.
//
// Remove-ALL semantics: EVERY event whose name matches is removed, not just the
// first. Containers are tried in order — if any continuous event matches, only
// continuous events are filtered; otherwise discrete events are filtered, so a
// name present in both containers is removed only from ContinuousEvents.
//
// Returns *EntityNotFoundError when no event carries that name.
func RemoveEvent(model Model, name string) (Model, error) {
	continuousMatches := false
	for _, e := range model.ContinuousEvents {
		if e.Name != nil && *e.Name == name {
			continuousMatches = true
			break
		}
	}
	if continuousMatches {
		kept := make([]ContinuousEvent, 0, len(model.ContinuousEvents))
		for _, e := range model.ContinuousEvents {
			if e.Name != nil && *e.Name == name {
				continue
			}
			kept = append(kept, e)
		}
		out := model
		out.ContinuousEvents = kept
		return out, nil
	}

	discreteMatches := false
	for _, e := range model.DiscreteEvents {
		if e.Name == name {
			discreteMatches = true
			break
		}
	}
	if discreteMatches {
		kept := make([]DiscreteEvent, 0, len(model.DiscreteEvents))
		for _, e := range model.DiscreteEvents {
			if e.Name == name {
				continue
			}
			kept = append(kept, e)
		}
		out := model
		out.DiscreteEvents = kept
		return out, nil
	}

	return model, newEntityNotFound("Event", name)
}

// =============================================================================
// Coupling operations (§4.5)
// =============================================================================

// AddCoupling returns a copy of `file` with `entry` appended to its coupling
// list.
func AddCoupling(file ESMFile, entry CouplingEntry) ESMFile {
	out := file
	out.Coupling = append(copySlice(file.Coupling), entry)
	return out
}

// RemoveCoupling returns a copy of `file` without the coupling entry at
// `index`. Indices are 0-based.
//
// Returns *EntityNotFoundError when the index is out of range.
func RemoveCoupling(file ESMFile, index int) (ESMFile, error) {
	if index < 0 || index >= len(file.Coupling) {
		return file, newEntityNotFound("Coupling", fmt.Sprintf("index %d", index))
	}
	coupling := make([]CouplingEntry, 0, len(file.Coupling)-1)
	coupling = append(coupling, file.Coupling[:index]...)
	coupling = append(coupling, file.Coupling[index+1:]...)
	out := file
	out.Coupling = coupling
	return out, nil
}

// Compose returns a copy of `file` with an `operator_compose` coupling entry
// linking systems `a` and `b`.
func Compose(file ESMFile, a, b string) ESMFile {
	return AddCoupling(file, OperatorComposeCoupling{
		Type:    string(CouplingKindOperatorCompose),
		Systems: [2]string{a, b},
	})
}

// MapVariable returns a copy of `file` with a `variable_map` coupling entry
// forwarding `from` into `to`.
//
// `transform` is either one of the named transform strings ("param_to_var",
// "identity", "additive", "multiplicative", "conversion_factor") or an
// Expression operator node evaluated in the flattened coupled system's scope
// (esm-spec §8.6 — the regridding form). Pass nil for the default,
// "param_to_var" — the default TypeScript uses.
func MapVariable(file ESMFile, from, to string, transform Expression) ESMFile {
	if transform == nil {
		transform = couplingTransformParamToVar
	}
	return AddCoupling(file, VariableMapCoupling{
		Type:      string(CouplingKindVariableMap),
		From:      from,
		To:        to,
		Transform: transform,
	})
}

// =============================================================================
// File-level operations (§4.6)
// =============================================================================

// Merge returns a new file combining `a` and `b`. On a key collision `b` wins,
// matching every other binding. Coupling entries are concatenated, a's first.
//
// The result keeps b's `esm` marker and metadata, and b's domain when it
// declares one.
func Merge(a, b ESMFile) ESMFile {
	out := b

	out.Models = copyMap(a.Models)
	for k, v := range b.Models {
		out.Models[k] = v
	}
	out.ReactionSystems = copyMap(a.ReactionSystems)
	for k, v := range b.ReactionSystems {
		out.ReactionSystems[k] = v
	}
	out.DataSources = copyMap(a.DataSources)
	for k, v := range b.DataSources {
		out.DataSources[k] = v
	}
	out.IndexSets = copyMap(a.IndexSets)
	for k, v := range b.IndexSets {
		out.IndexSets[k] = v
	}
	out.FunctionTables = copyMap(a.FunctionTables)
	for k, v := range b.FunctionTables {
		out.FunctionTables[k] = v
	}
	out.Coupling = append(copySlice(a.Coupling), b.Coupling...)

	if b.Domain == nil {
		out.Domain = a.Domain
	}
	return out
}

// Extract returns a new file containing only the component `componentName`,
// together with every coupling entry that references it.
//
// Models and reaction systems are searched, in that order. `data_sources` is
// deliberately NOT searched: from esm 1.0.0 a data source is not a COMPONENT —
// it has no variables, is not a coupling endpoint or a subsystem — so there is
// no such thing as extracting one as a standalone document. A model that
// consumes a source carries the binding on its own parameter, and extracting
// that model is what carries the dependency with it.
//
// DIVERGENCE: Julia's `extract` still offers data sources as an extractable
// component; TypeScript's does not, and TypeScript is followed here for the
// reason above.
//
// Returns *EntityNotFoundError when no component of that name exists.
func Extract(file ESMFile, componentName string) (ESMFile, error) {
	extracted := ESMFile{
		ESM:      file.ESM,
		Metadata: file.Metadata,
	}

	switch {
	case hasKey(file.Models, componentName):
		extracted.Models = map[string]Model{componentName: file.Models[componentName]}
	case hasKey(file.ReactionSystems, componentName):
		extracted.ReactionSystems = map[string]ReactionSystem{
			componentName: file.ReactionSystems[componentName],
		}
	default:
		return ESMFile{}, newEntityNotFound("Component", componentName)
	}

	relevant := []CouplingEntry{}
	for _, entry := range file.Coupling {
		if couplingInvolves(entry, componentName) {
			relevant = append(relevant, entry)
		}
	}
	extracted.Coupling = relevant
	return extracted, nil
}

func hasKey[V any](m map[string]V, k string) bool {
	_, ok := m[k]
	return ok
}

// couplingInvolves reports whether a coupling entry names `component` as one of
// its endpoints. Scoped endpoints ("System.var") match on their leading
// segment, which is the component name.
func couplingInvolves(entry CouplingEntry, component string) bool {
	rootOf := func(ref string) string {
		if i := strings.Index(ref, "."); i >= 0 {
			return ref[:i]
		}
		return ref
	}
	switch e := entry.(type) {
	case OperatorComposeCoupling:
		return e.Systems[0] == component || e.Systems[1] == component
	case CouplingCouple:
		return e.Systems[0] == component || e.Systems[1] == component
	case VariableMapCoupling:
		return rootOf(e.From) == component || rootOf(e.To) == component
	case OperatorApplyCoupling:
		return e.Operator == component
	case EventCoupling:
		for _, affect := range append(copySlice(e.Affects), e.AffectNeg...) {
			if rootOf(affect.LHS) == component {
				return true
			}
			if expressionRootsInclude(affect.RHS, component) {
				return true
			}
		}
		for _, condition := range e.Conditions {
			if expressionRootsInclude(condition, component) {
				return true
			}
		}
		if e.Trigger != nil && e.Trigger.Expression != nil {
			return expressionRootsInclude(e.Trigger.Expression, component)
		}
		return false
	case CouplingImport:
		for _, bound := range e.Bind {
			if rootOf(bound) == component {
				return true
			}
		}
		return false
	default:
		return false
	}
}

// expressionRootsInclude reports whether any free name in `expr` is a scoped
// reference rooted at `component`.
func expressionRootsInclude(expr Expression, component string) bool {
	for name := range FreeVariables(expr) {
		if i := strings.Index(name, "."); i >= 0 && name[:i] == component {
			return true
		}
	}
	return false
}

// couplingTransformParamToVar is the default `variable_map` transform, matching
// the default TypeScript's mapVariable applies.
const couplingTransformParamToVar = "param_to_var"
