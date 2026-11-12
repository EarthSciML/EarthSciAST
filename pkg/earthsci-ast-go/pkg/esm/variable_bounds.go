package esm

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strconv"
	"strings"
)

// variable_bounds.go implements esm-spec §6.3.2 "Bounds (`lb`, `ub`)": the
// wire type, the esm 2.1.0 version gate, the four structural rules, and the
// helpers flatten uses to carry a bound through the renaming of
// esm-libraries-spec §4.7.5.

// VariableBound is one bound of a model variable (esm-spec §6.3.2): a number
// in the variable's declared `units`, or a reference to another variable,
// written and resolved as a variable reference in the model's expressions.
// Exactly one of Number and Ref is set.
//
// Number holds an int64 or a float64, decoded by the int/float rule every
// numeric literal follows (normalizeJSONNumber): a token with '.', 'e' or 'E'
// is a float64, any other an int64 (a float64 only beyond the int64 range).
// So a bound stays the number written (esm-spec §6.3.2, "Round-trip"): an
// integer keeps every digit, and a float is emitted as a float — `1.0` stays
// `1.0` rather than collapsing to `1` as the document form does elsewhere. A
// reference is emitted as the string written.
type VariableBound struct {
	Number any
	Ref    *string
}

// MarshalJSON writes the bound as a JSON number or a JSON string.
func (b VariableBound) MarshalJSON() ([]byte, error) {
	if b.Ref != nil {
		return json.Marshal(*b.Ref)
	}
	switch n := b.Number.(type) {
	case int64:
		return []byte(strconv.FormatInt(n, 10)), nil
	case float64:
		s, err := formatCanonicalFloatShared(n)
		if err != nil {
			return nil, err
		}
		return []byte(s), nil
	case nil:
		return nil, fmt.Errorf("variable bound holds neither a number nor a reference")
	}
	return nil, fmt.Errorf("variable bound number must be an int64 or a float64, got %T", b.Number)
}

// numberValue is a number bound's value as a float64, for ordering; ok is
// false for a reference or an absent bound.
func (b *VariableBound) numberValue() (v float64, ok bool) {
	if b == nil {
		return 0, false
	}
	switch n := b.Number.(type) {
	case int64:
		return float64(n), true
	case float64:
		return n, true
	}
	return 0, false
}

// UnmarshalJSON reads a bound that is a JSON number or a JSON string. Whether
// the string names a variable is the validator's question, not the decoder's.
func (b *VariableBound) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) > 0 && data[0] == '"' {
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*b = VariableBound{Ref: &s}
		return nil
	}
	var num json.Number
	if err := json.Unmarshal(data, &num); err != nil {
		return fmt.Errorf("a variable bound must be a number or a variable reference: %w", err)
	}
	*b = VariableBound{Number: normalizeJSONNumber(num)}
	return nil
}

// boundExpression is the bound as a one-leaf Expression — a float64 or a
// variable-name string — so flatten pushes a reference through the same
// renaming as the names in the component's equations. Nil for an absent bound.
func boundExpression(b *VariableBound) Expression {
	switch {
	case b == nil:
		return nil
	case b.Ref != nil:
		return *b.Ref
	case b.Number != nil:
		return b.Number
	}
	return nil
}

// boundNames are the two bound fields, in the order they are checked and
// reported.
var boundNames = [2]string{"lb", "ub"}

// bounds returns the variable's lb and ub, in boundNames order.
func (mv ModelVariable) bounds() [2]*VariableBound { return [2]*VariableBound{mv.LB, mv.UB} }

// rejectVariableBoundsPreV21 rejects `lb` / `ub` on a model variable in a file
// declaring esm < 2.1.0 with `variable_bounds_version_too_old`, naming the
// first such field (models, variables and subsystems in sorted name order, lb
// before ub). It reads the raw view before schema validation, so the author
// sees the version hint rather than an unknown-property error.
func rejectVariableBoundsPreV21(view map[string]any) error {
	if view == nil || !esmVersionBelow(view, 2, 1) {
		return nil
	}
	models, _ := view["models"].(map[string]any)
	for _, name := range sortedKeys(models) {
		if path := firstRawBoundField(models[name], "/models/"+name); path != "" {
			esmRaw, _ := view["esm"].(string)
			return newETErr(
				CodeVariableBoundsVersionTooOld,
				fmt.Sprintf("variable bounds `lb` / `ub` require esm >= 2.1.0; file declares %s (offending path: %s)", esmRaw, path),
			)
		}
	}
	return nil
}

// firstRawBoundField returns the pointer of the first `lb` / `ub` on a
// variable of the raw model at path or of any inline subsystem below it, or ""
// when there is none.
func firstRawBoundField(raw any, path string) string {
	model, ok := raw.(map[string]any)
	if !ok {
		return ""
	}
	vars, _ := model["variables"].(map[string]any)
	for _, name := range sortedKeys(vars) {
		decl, ok := vars[name].(map[string]any)
		if !ok {
			continue
		}
		for _, field := range boundNames {
			if _, has := decl[field]; has {
				return fmt.Sprintf("%s/variables/%s/%s", path, name, field)
			}
		}
	}
	subs, _ := model["subsystems"].(map[string]any)
	for _, name := range sortedKeys(subs) {
		if p := firstRawBoundField(subs[name], path+"/subsystems/"+name); p != "" {
			return p
		}
	}
	return ""
}

// raiseVariableBoundsEsmFloor raises a document's declared `esm` to 2.1.0
// when a model variable at any depth carries `lb` or `ub` but the document
// declares less. A document comes to carry bounds without spelling them when a
// 2.1.0 leaf is mounted into an older root: the root's authored bytes pass the
// gate, but the assembled document, emitted at the root's version, would be
// refused by rejectVariableBoundsPreV21 when read back. Like the `faq` floor
// it only ever raises.
//
// The declared version is read first, without decoding the rest: a document
// at 2.1.0 or later — every one written by a current author — needs no scan.
func raiseVariableBoundsEsmFloor(jsonStr string) string {
	declared, below := declaredEsmBelow(jsonStr, 2, 1)
	if !below {
		return jsonStr
	}
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return jsonStr
	}
	models, _ := view["models"].(map[string]any)
	for _, name := range sortedKeys(models) {
		if firstRawBoundField(models[name], "/models/"+name) != "" {
			return raiseEsmFloorTo(jsonStr, declared, "2.1.0")
		}
	}
	return jsonStr
}

// validateVariableBounds applies the four §6.3.2 rules to every variable of
// every model and inline subsystem. A reference is resolved by the
// scopedNameIndex the §4.9.6 / §4.9.7 cycle checks use, which gives a bare
// name the owning component's own variable and a dotted one the §4.9.7
// precedence. A reference that does not resolve is reported once, and the
// shape and circularity rules are not applied to it.
func (s *structuralScan) validateVariableBounds() {
	if s.file == nil {
		return
	}
	ix := s.scopedNameIndex()
	var observedReads map[string]map[string]bool
	var walk func(prefix, basePath string, model *Model)
	walk = func(prefix, basePath string, model *Model) {
		for _, varName := range sortedKeys(model.Variables) {
			v := model.Variables[varName]
			varPath := fmt.Sprintf("%s/variables/%s", basePath, varName)
			self := prefix + "." + varName
			for i, b := range v.bounds() {
				if b == nil || b.Ref == nil {
					continue
				}
				which, ref := boundNames[i], *b.Ref
				fieldPath := varPath + "/" + which
				full := ix.resolve(prefix, ref)
				if !ix.declared[full] {
					s.addErr(StructuralError{
						Path:    fieldPath,
						Code:    ErrorUndefinedVariable,
						Message: fmt.Sprintf("Variable %q referenced as the %s of '%s' but not declared", ref, which, varName),
						Details: map[string]any{"variable": ref, "bound": which},
					})
					continue
				}
				details := map[string]any{"variable": varName, "bound": which, "reference": ref}
				if shape, found := declaredShapeOf(s.file, full); found && len(shape) > 0 && !slices.Equal(shape, v.Dims()) {
					s.addErr(StructuralError{
						Path: fieldPath,
						Code: CodeVariableBoundShapeMismatch,
						Message: fmt.Sprintf("The %s of '%s' references '%s', shaped %s; a bound must be scalar or the bounded variable's shape %s",
							which, varName, ref, boundShapeString(shape), boundShapeString(v.Dims())),
						Details: details,
					})
				}
				if full == self {
					s.addErr(StructuralError{
						Path:    fieldPath,
						Code:    CodeVariableBoundCircular,
						Message: fmt.Sprintf("The %s of '%s' refers to '%s' itself", which, varName, ref),
						Details: details,
					})
					continue
				}
				if observedReads == nil {
					observedReads, _ = documentObservedReads(s.file, ix)
				}
				if chain := observedDependencyChain(observedReads, full, self); chain != nil {
					s.addErr(StructuralError{
						Path: fieldPath,
						Code: CodeVariableBoundCircular,
						Message: fmt.Sprintf("The %s of '%s' refers to '%s', whose definition depends on '%s' (%s)",
							which, varName, ref, varName, strings.Join(chain, " -> ")),
						Details: details,
					})
				}
			}
			lo, okLo := v.LB.numberValue()
			hi, okHi := v.UB.numberValue()
			if okLo && okHi && lo > hi {
				s.addErr(StructuralError{
					Path:    varPath,
					Code:    CodeVariableBoundsInverted,
					Message: fmt.Sprintf("'%s' has lb %v greater than ub %v", varName, v.LB.Number, v.UB.Number),
					Details: map[string]any{"variable": varName, "lb": v.LB.Number, "ub": v.UB.Number},
				})
			}
		}
		for _, subName := range sortedKeys(model.Subsystems) {
			raw := model.Subsystems[subName]
			if _, _, isRef := extractRefWithBindings(raw); isRef {
				continue
			}
			if m, ok := raw.(map[string]any); ok {
				if _, isRS := m["reactions"]; isRS {
					continue
				}
			}
			if sub, ok := decodeSubsystemAs[Model](raw); ok {
				walk(prefix+"."+subName, basePath+"/subsystems/"+subName, &sub)
			}
		}
	}
	for _, name := range sortedKeys(s.file.Models) {
		model := s.file.Models[name]
		walk(name, "/models/"+name, &model)
	}
}

// observedDependencyChain follows observed definitions from the scoped name
// from, depth-first in sorted order, and returns the first path that reaches
// target (`[a b x]` for a bound `a` reading `b` reading `x`), or nil when none
// does. reads is documentObservedReads: only an observed has an entry, so the
// walk stops at an ODE state, a parameter, an algebraic unknown and a species.
func observedDependencyChain(reads map[string]map[string]bool, from, target string) []string {
	visited := map[string]bool{}
	short := func(full string) string {
		if i := strings.LastIndex(full, "."); i >= 0 {
			return full[i+1:]
		}
		return full
	}
	var dfs func(node string, path []string) []string
	dfs = func(node string, path []string) []string {
		path = append(path, node)
		if node == target {
			return path
		}
		if visited[node] {
			return nil
		}
		visited[node] = true
		for _, next := range sortedKeysOfSet(reads[node]) {
			if found := dfs(next, path); found != nil {
				return found
			}
		}
		return nil
	}
	chain := dfs(from, nil)
	if chain == nil {
		return nil
	}
	// The chain is reported in the names its scope uses when every step lies
	// in one component, and in full scoped names otherwise.
	out := make([]string, len(chain))
	copy(out, chain)
	if !spansScopes(chain) {
		for i, n := range chain {
			out[i] = short(n)
		}
	}
	return out
}

// boundShapeString renders a declared shape for a bound diagnostic:
// `[salt]`, or `(scalar)` for none.
func boundShapeString(shape []string) string {
	if len(shape) == 0 {
		return "(scalar)"
	}
	return "[" + strings.Join(shape, ", ") + "]"
}

// namespaceBound is a flattened variable's bound: a number unchanged, and a
// reference namespaced exactly like a name in the component's equations
// (esm-libraries-spec §4.7.5).
func namespaceBound(b *VariableBound, prefix string, leaveAlone, subsystemKeys, locals map[string]bool) Expression {
	e := boundExpression(b)
	if e == nil {
		return nil
	}
	return namespaceExprTree(e, prefix, leaveAlone, subsystemKeys, locals)
}

// rewriteBounds applies rewrite to the bounds of every variable in every
// table of the given components, so a coupling's renaming reaches a
// reference held on a variable exactly as it reaches the equations.
func rewriteBounds(components map[string]*componentSystem, rewrite func(Expression) Expression) {
	for _, comp := range components {
		for _, table := range []*varTable{comp.stateVars, comp.parameters, comp.observed} {
			for _, name := range table.keys {
				v := table.m[name]
				if v.LB == nil && v.UB == nil {
					continue
				}
				if v.LB != nil {
					v.LB = rewrite(v.LB)
				}
				if v.UB != nil {
					v.UB = rewrite(v.UB)
				}
				table.m[name] = v
			}
		}
	}
}
