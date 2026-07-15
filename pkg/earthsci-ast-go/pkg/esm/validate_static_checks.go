package esm

import (
	"fmt"
	"math"
	"strings"
)

// validate_static_checks.go adds the five F-6 static-validation checks — defects
// that are decidable from the SINGLE document (no evaluator, no solver, no
// other file) yet were previously caught only by an evaluating binding's
// build/resolve/partition pass. Their pinned (code, path) tuples live in
// tests/invalid/expected_errors.json (promoted from `resolver_only`), and these
// checks make Go's validate() reject each with exactly that pin:
//
//   - join_key_invalid_type          — an aggregate value-equality join whose key
//     column draws from a categorical index set with a float or null member.
//   - domain_unit_mismatch           — an identity variable_map coupling whose
//     from/to variables carry declared, non-empty, DIFFERENT units.
//   - relational_node_in_continuous  — a distinct/bool_and_or aggregate whose
//     key/expr reads a STATE variable (value-invention in a continuous context).
//   - undefined_index_set            — an aggregate `ranges` entry `{from: NAME}`
//     naming a set absent from the document `index_sets` registry.
//
// Every finding is emitted at the CONTAINING EXPRESSION FIELD
// (`/models/M/equations/i/lhs` or `/rhs`, or `/coupling/i`) — the same pointer
// convention the reference-integrity findings use.
const (
	// CodeJoinKeyInvalidType: a value-equality join key column draws from a
	// categorical index set whose `members` contain a float (not portably
	// equality-comparable across bindings) or a null (unmatchable as a key).
	// RFC semiring-faq-unified-ir §5.3 / §5.7 rule 1; CONFORMANCE_SPEC §5.5.1.
	CodeJoinKeyInvalidType = "join_key_invalid_type"
	// CodeDomainUnitMismatch: an `identity`-transform `variable_map` coupling
	// whose `from` and `to` variables carry declared, non-empty, and DIFFERENT
	// units (esm-spec §4.7.6). Mirrors the flatten-time DomainUnitMismatch the
	// evaluating bindings raise (Julia _check_variable_map_units, Python
	// _check_variable_map_units, Rust FlattenError::DomainUnitMismatch).
	CodeDomainUnitMismatch = "domain_unit_mismatch"
	// CodeRelationalNodeInContinuous: a relational / value-invention aggregate
	// (`distinct: true` under `bool_and_or`) whose `key`/`expr` reads a declared
	// STATE variable, so the cadence partition classes the node CONTINUOUS and
	// guard 2 (no relational engine on the hot path) forbids it. RFC §6.1,
	// CONFORMANCE_SPEC §5.7.6 guard 2.
	CodeRelationalNodeInContinuous = "relational_node_in_continuous"
	// CodeUndefinedIndexSet: an aggregate `ranges` entry `{from: NAME}` names an
	// index set that is not a key of the document `index_sets` registry. No
	// implicit interval is inferred for an undeclared name (RFC §5.2).
	CodeUndefinedIndexSet = "undefined_index_set"
)

// opAggregate is the array-query reduction op these checks key on.
const opAggregate = "aggregate"

// validateModelStaticAggregateChecks runs the three per-model aggregate checks
// (join_key_invalid_type, relational_node_in_continuous, undefined_index_set)
// over every equation of a model. Each aggregate node reachable in an equation's
// LHS / RHS tree is inspected; a finding is reported at the CONTAINING field
// (`.../equations/i/lhs` or `.../rhs`), never at the leaf position — the same
// granularity §7.1.2 and the shared corpus pin.
func (s *structuralScan) validateModelStaticAggregateChecks(modelName string, model *Model, basePath string) {
	stateVars := make(map[string]bool)
	for varName, variable := range model.Variables {
		if variable.Type == VarTypeState {
			stateVars[varName] = true
		}
	}

	// seen dedupes exact (code|path|discriminator) findings so a single defect
	// referenced from more than one range/aggregate in the same field is reported
	// once.
	seen := make(map[string]bool)
	checkField := func(fieldPath string, expr Expression) {
		walkOperatorNodes(expr, func(node ExprNode) {
			if node.Op != opAggregate {
				return
			}
			s.checkAggregateJoinKeys(node, fieldPath, modelName, seen)
			s.checkAggregateUndefinedIndexSet(node, fieldPath, modelName, seen)
			s.checkAggregateRelationalInContinuous(node, stateVars, fieldPath, modelName, seen)
		})
	}

	for i, eq := range model.Equations {
		eqPath := fmt.Sprintf("%s/equations/%d", basePath, i)
		checkField(eqPath+"/lhs", eq.LHS)
		checkField(eqPath+"/rhs", eq.RHS)
	}
}

// checkAggregateUndefinedIndexSet reports undefined_index_set for every
// `ranges` entry whose `{from: NAME}` names a set absent from the document
// `index_sets` registry (RFC §5.2 — no implicit interval is inferred).
func (s *structuralScan) checkAggregateUndefinedIndexSet(node ExprNode, fieldPath, modelName string, seen map[string]bool) {
	if s.file == nil {
		return
	}
	for _, rangeKey := range sortedKeys(node.Ranges) {
		name := rangeFromName(node.Ranges[rangeKey])
		if name == "" {
			continue
		}
		if _, declared := s.file.IndexSets[name]; declared {
			continue
		}
		dedup := "undefined_index_set|" + fieldPath + "|" + name
		if seen[dedup] {
			continue
		}
		seen[dedup] = true
		s.addErr(StructuralError{
			Path:    fieldPath,
			Code:    CodeUndefinedIndexSet,
			Message: fmt.Sprintf("Aggregate range '%s' references undeclared index set '%s'", rangeKey, name),
			Details: map[string]any{
				"index_set": name,
				"range":     rangeKey,
				"model":     modelName,
			},
		})
	}
}

// checkAggregateJoinKeys reports join_key_invalid_type when a value-equality
// join key column draws from a categorical index set whose members include a
// float or a null. The join key columns are the range names appearing in the
// join clauses' `on` pairs; each is resolved through `ranges[key].from` to the
// index set it iterates.
func (s *structuralScan) checkAggregateJoinKeys(node ExprNode, fieldPath, modelName string, seen map[string]bool) {
	if s.file == nil || len(node.Join) == 0 {
		return
	}
	onKeys := joinOnKeyNames(node.Join)
	for _, rangeKey := range sortedKeysOfSet(onKeys) {
		fromName := rangeFromName(node.Ranges[rangeKey])
		if fromName == "" {
			continue
		}
		iset, ok := s.file.IndexSets[fromName]
		if !ok || iset.Kind != "categorical" {
			continue
		}
		kind, ok := firstInvalidJoinKeyMember(iset.Members)
		if !ok {
			continue
		}
		dedup := "join_key_invalid_type|" + fieldPath + "|" + fromName
		if seen[dedup] {
			continue
		}
		seen[dedup] = true
		s.addErr(StructuralError{
			Path: fieldPath,
			Code: CodeJoinKeyInvalidType,
			Message: fmt.Sprintf(
				"Value-equality join key column '%s' draws from categorical index set '%s' with a %s member; "+
					"floats are not portably equality-comparable and null is unmatchable as a key",
				rangeKey, fromName, kind),
			Details: map[string]any{
				"index_set":    fromName,
				"join_key":     rangeKey,
				"invalid_kind": kind,
				"model":        modelName,
			},
		})
	}
}

// checkAggregateRelationalInContinuous reports relational_node_in_continuous
// when a value-invention aggregate (`distinct: true` under `bool_and_or`) reads
// a declared STATE variable in its `key` or `expr` subtree. Such a node is
// classed CONTINUOUS by the cadence partition (class = max over inputs) and is
// forbidden on the per-step hot path (guard 2). A node over CONST / mesh /
// parameter literals only (e.g. tests/valid/cadence/pure_topology.esm) reads no
// state variable and is allowed.
func (s *structuralScan) checkAggregateRelationalInContinuous(node ExprNode, stateVars map[string]bool, fieldPath, modelName string, seen map[string]bool) {
	if !isRelationalAggregate(node) {
		return
	}
	refs := make(map[string]bool)
	collectStringLeaves(node.Key, refs)
	collectStringLeaves(node.Expr, refs)

	var stateHit string
	for _, name := range sortedKeysOfSet(refs) {
		if stateVars[name] {
			stateHit = name
			break
		}
	}
	if stateHit == "" {
		return
	}
	dedup := "relational_node_in_continuous|" + fieldPath
	if seen[dedup] {
		return
	}
	seen[dedup] = true
	s.addErr(StructuralError{
		Path: fieldPath,
		Code: CodeRelationalNodeInContinuous,
		Message: fmt.Sprintf(
			"Relational aggregate (distinct/bool_and_or) reads state variable '%s' in its key/expr, "+
				"classing the node CONTINUOUS; relational work may not run on the per-step hot path",
			stateHit),
		Details: map[string]any{
			"state_variable": stateHit,
			"model":          modelName,
		},
	})
}

// isRelationalAggregate reports whether an aggregate node is a
// relational / value-invention node: `distinct: true` under the boolean
// semiring `bool_and_or` (the only relational/boolean semiring in the closed
// enum). This is the marker of a node that invents index-set membership rather
// than reducing a numeric field.
func isRelationalAggregate(node ExprNode) bool {
	if node.Op != opAggregate {
		return false
	}
	if node.Distinct == nil || !*node.Distinct {
		return false
	}
	return node.Semiring != nil && *node.Semiring == "bool_and_or"
}

// joinOnKeyNames returns every range-key name appearing in an aggregate's join
// clauses' `on` pairs. A join clause is a non-operator object `{"on": [[a, b],
// …]}`, so after decode it is a map[string]any whose "on" value is a nested
// []any of string pairs (mapExprChildren leaves such clauses in their decoded
// shape).
func joinOnKeyNames(join []any) map[string]bool {
	out := make(map[string]bool)
	for _, clause := range join {
		cm, ok := clause.(map[string]any)
		if !ok {
			continue
		}
		onList, ok := cm["on"].([]any)
		if !ok {
			continue
		}
		for _, pair := range onList {
			pl, ok := pair.([]any)
			if !ok {
				continue
			}
			for _, el := range pl {
				if name, ok := el.(string); ok && name != "" {
					out[name] = true
				}
			}
		}
	}
	return out
}

// rangeFromName extracts the index-set NAME from a decoded `ranges[k]` value of
// the `{from: <name>}` shape, or "" for any other shape (an inline interval
// bound pair, a missing/typed-wrong `from`). Range values keep their decoded
// map[string]any shape (a non-operator object, so mapExprChildren does not
// normalize them into ExprNodes).
func rangeFromName(rangeValue any) string {
	m, ok := rangeValue.(map[string]any)
	if !ok {
		return ""
	}
	name, ok := m["from"].(string)
	if !ok {
		return ""
	}
	return name
}

// firstInvalidJoinKeyMember reports the first categorical member that may not be
// used in a value-equality join key column, with its kind:
//
//   - "null"  — a JSON null (nil): unmatchable as a key; nulls never compare equal.
//   - "float" — a non-integer numeric literal: float equality is not portable
//     across bindings (a platform-dependent repr), so it is forbidden.
//
// Integers and strings are legal keys, so a whole-number numeric member is
// accepted. (The Go loader decodes every JSON number to float64 via the standard
// unmarshaler, discarding the int/float wire distinction, so a member is judged
// a float only when it carries a fractional part — which is exactly the
// non-portable case the rule targets; the pinned fixtures use 1.5 / 2.5.)
func firstInvalidJoinKeyMember(members []any) (string, bool) {
	for _, member := range members {
		switch v := member.(type) {
		case nil:
			return "null", true
		case float64:
			if v != math.Trunc(v) {
				return "float", true
			}
		case float32:
			f := float64(v)
			if f != math.Trunc(f) {
				return "float", true
			}
		}
	}
	return "", false
}

// walkOperatorNodes visits every operator node in an expression tree (in
// pre-order), routing recursion through the field-preserving mapExprChildren
// keystone so it reaches operator nodes nested in ANY expression-bearing field
// (an aggregate's `key`/`expr`/`filter`, a makearray `values`, …), not just
// `args`. Non-operator arrays are descended element-wise; leaves are ignored.
func walkOperatorNodes(expr Expression, visit func(ExprNode)) {
	if node, ok := asExprNode(expr); ok {
		visit(node)
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walkOperatorNodes(child, visit)
			return child, nil
		})
		return
	}
	if arr, ok := expr.([]any); ok {
		for _, el := range arr {
			walkOperatorNodes(el, visit)
		}
	}
}

// collectStringLeaves accumulates every bare STRING leaf reachable from an
// expression subtree into out — the variable-reference surface of the tree.
// Recursion is routed through mapExprChildren so op NAMES (the `op` field) and
// documentary tags (`label`, non-Expression string slots) are never collected,
// and so a name is gathered only where it sits as an actual operand (an `args`
// element or a scalar Expression field). Bound loop indices are collected too;
// callers filter by declared-variable membership, which excludes them.
func collectStringLeaves(expr Expression, out map[string]bool) {
	if str, ok := expr.(string); ok {
		out[str] = true
		return
	}
	if node, ok := asExprNode(expr); ok {
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			collectStringLeaves(child, out)
			return child, nil
		})
		return
	}
	if arr, ok := expr.([]any); ok {
		for _, el := range arr {
			collectStringLeaves(el, out)
		}
	}
}

// checkVariableMapUnits reports domain_unit_mismatch for an `identity`-transform
// `variable_map` coupling whose `from` and `to` variables carry declared,
// non-empty, and DIFFERENT units (esm-spec §4.7.6). Matching or absent units are
// legal; `param_to_var` and `conversion_factor` transforms (and the widened
// Expression transform) are exempt because they are not `"identity"`. Port of
// the flatten-time _check_variable_map_units the evaluating bindings run.
func (s *structuralScan) checkVariableMapUnits(c VariableMapCoupling, basePath string, index int) {
	if s.file == nil || c.TransformKind() != "identity" {
		return
	}
	srcUnits := s.lookupVariableUnits(c.From)
	tgtUnits := s.lookupVariableUnits(c.To)
	if srcUnits == "" || tgtUnits == "" || srcUnits == tgtUnits {
		return
	}
	s.addErr(StructuralError{
		Path: basePath,
		Code: CodeDomainUnitMismatch,
		Message: fmt.Sprintf(
			"identity variable_map couples '%s' (units %q) to '%s' (units %q); an identity mapping requires matching units",
			c.From, srcUnits, c.To, tgtUnits),
		Details: map[string]any{
			"from":           c.From,
			"to":             c.To,
			"from_units":     srcUnits,
			"to_units":       tgtUnits,
			"coupling_type":  "variable_map",
			"coupling_index": index,
		},
	})
}

// lookupVariableUnits resolves a dot-qualified variable's declared units across
// models (recursing into Model subsystems) and reaction systems (species +
// parameters). Returns "" when the variable is missing or carries no declared,
// non-empty units. Mirrors Python's _lookup_variable_units / Julia's
// _lookup_variable_units.
func (s *structuralScan) lookupVariableUnits(qualified string) string {
	if s.file == nil {
		return ""
	}
	parts := strings.Split(qualified, ".")
	if len(parts) < 2 {
		return ""
	}
	root := parts[0]
	tail := parts[1:]
	if model, ok := s.file.Models[root]; ok {
		return lookupModelUnits(&model, tail)
	}
	if rs, ok := s.file.ReactionSystems[root]; ok {
		return lookupReactionSystemUnits(&rs, tail)
	}
	return ""
}

// lookupModelUnits resolves a (possibly subsystem-nested) variable's declared
// units within a model. Only Model subsystems are recursed into.
func lookupModelUnits(model *Model, path []string) string {
	if len(path) == 1 {
		if v, ok := model.Variables[path[0]]; ok && v.Units != nil {
			return *v.Units
		}
		return ""
	}
	sub, ok := model.Subsystems[path[0]]
	if !ok {
		return ""
	}
	if inner, ok := decodeSubsystemAs[Model](sub); ok {
		return lookupModelUnits(&inner, path[1:])
	}
	return ""
}

// lookupReactionSystemUnits resolves a species' or parameter's declared units
// within a reaction system (recursing into subsystems for dotted names).
func lookupReactionSystemUnits(rs *ReactionSystem, path []string) string {
	if len(path) == 1 {
		if sp, ok := rs.Species[path[0]]; ok && sp.Units != nil {
			return *sp.Units
		}
		if p, ok := rs.Parameters[path[0]]; ok && p.Units != nil {
			return *p.Units
		}
		return ""
	}
	sub, ok := rs.Subsystems[path[0]]
	if !ok {
		return ""
	}
	if inner, ok := decodeSubsystemAs[ReactionSystem](sub); ok {
		return lookupReactionSystemUnits(&inner, path[1:])
	}
	return ""
}
