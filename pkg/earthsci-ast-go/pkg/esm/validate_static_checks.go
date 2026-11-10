package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// validate_static_checks.go holds static-validation checks for defects that
// are decidable from the SINGLE document (no evaluator, no solver, no other
// file). Their pinned (code, path) tuples live in
// tests/invalid/expected_errors.json, and these checks make Go's Validate
// reject each with exactly that pin:
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

	// CodeJoinSideAmbiguous: an `on` key for which the DOCUMENT does not
	// determine a range symbol -- its index set is drawn by more than one of the
	// node's ranges and the clause names no `syms` (CONFORMANCE_SPEC §5.5.8).
	CodeJoinSideAmbiguous = "join_side_ambiguous"

	// CodeJoinSymsUnknownSymbol: a `join.syms` entry that is not a range symbol
	// of the node (CONFORMANCE_SPEC §5.5.8).
	CodeJoinSymsUnknownSymbol = "join_syms_unknown_symbol"
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
	// CodeRaggedValuesNotGathered: a `faq` that is not a value-invention node
	// ranges over a `kind: "ragged"` index set, but its body never reads that
	// set's `values` array. The range binds the POSITION k in 1..offsets[parent],
	// not a member, so the body reads positions where the author meant members
	// (esm-spec §4.3.1 "Ragged ranges").
	CodeRaggedValuesNotGathered = "ragged_values_not_gathered"
	// CodeFAQBareArrayOperand: a `faq`'s `expr` or `filter` reads a variable
	// declared with a non-empty `shape` by BARE name in an elementwise position.
	// The node names its axes by its range symbols, so the read must say which
	// ones: `index(v, i, …)` (esm-spec §4.3.1, issue #441).
	CodeFAQBareArrayOperand = "faq_bare_array_operand"
	// CodeUndefinedIndexSet: an aggregate `ranges` entry `{from: NAME}` names an
	// index set that is not a key of the document `index_sets` registry. No
	// implicit interval is inferred for an undeclared name (RFC §5.2).
	CodeUndefinedIndexSet = "undefined_index_set"
)

// opAggregate is the array-query reduction op these checks key on.
const opAggregate = "faq"

// validateModelStaticAggregateChecks runs the per-model aggregate checks
// (join_key_invalid_type, relational_node_in_continuous, undefined_index_set,
// ragged_values_not_gathered, faq_bare_array_operand) over every equation of a
// model and, recursively, of each of its inline subsystems. Each aggregate node
// reachable in an equation's LHS / RHS tree is inspected; a finding is reported
// at the CONTAINING field (`.../equations/i/lhs` or `.../rhs`), never at the
// leaf position — the same granularity §7.1.2 and the shared corpus pin.
func (s *structuralScan) validateModelStaticAggregateChecks(modelName string, model *Model, basePath string) {
	// "Reads a STATE" is the cadence question, and from esm 1.0.0 it is DERIVED:
	// an ODE state is an unknown under D(·,t) on some equation LHS (esm-spec
	// §6.3.1). An ALGEBRAIC unknown seeds CONTINUOUS too (CONFORMANCE_SPEC
	// §5.7.2), so both count here; an OBSERVED unknown does not, because its
	// class is the class of its defining RHS and may well be CONST.
	stateVars := make(map[string]bool)
	for _, varName := range ODEStates(model) {
		stateVars[varName] = true
	}
	for _, varName := range AlgebraicUnknowns(model) {
		stateVars[varName] = true
	}

	// seen dedupes exact (code|path|discriminator) findings so a single defect
	// referenced from more than one range/aggregate in the same field is reported
	// once.
	seen := make(map[string]bool)
	// A join key may name a DATA COLUMN, whose range symbol comes from its
	// declared 1-D shape -- so the join-side checks need the model's shapes.
	varShapes := make(map[string][]string)
	for varName, v := range model.Variables {
		if v.Shape != nil && len(*v.Shape) == 1 {
			varShapes[varName] = *v.Shape
		}
	}
	checkField := func(fieldPath string, expr Expression) {
		walkOperatorNodes(expr, func(node ExprNode) {
			if node.Op != opAggregate {
				return
			}
			s.checkAggregateJoinKeys(node, fieldPath, modelName, seen)
			s.checkAggregateJoinSides(node, varShapes, fieldPath, modelName, seen)
			s.checkAggregateUndefinedIndexSet(node, fieldPath, modelName, seen)
			s.checkAggregateRaggedValuesGathered(node, fieldPath, modelName, seen)
			s.checkAggregateRelationalInContinuous(node, stateVars, fieldPath, modelName, seen)
		})
	}

	shaped := make(map[string][]string)
	for varName, v := range model.Variables {
		if v.Shape != nil && len(*v.Shape) > 0 {
			shaped[varName] = *v.Shape
		}
	}
	for i, eq := range model.Equations {
		eqPath := fmt.Sprintf("%s/equations/%d", basePath, i)
		checkField(eqPath+"/lhs", eq.LHS)
		checkField(eqPath+"/rhs", eq.RHS)
		// The RHS as authored: a template application there is opaque to the
		// check, and load has already expanded it.
		rhs := eq.RHS
		if authored, ok := s.file.authoredTemplateRHS[eqPath]; ok {
			rhs = authored
		}
		s.checkFAQBareArrayOperands(rhs, shapedExceptSelfDefined(shaped, eq.LHS), eqPath+"/rhs", modelName)
	}

	for _, name := range sortedKeys(model.Subsystems) {
		raw := model.Subsystems[name]
		if _, _, isRef := extractRefWithBindings(raw); isRef {
			continue
		}
		sub, ok := decodeSubsystemAs[Model](raw)
		if !ok {
			continue
		}
		s.validateModelStaticAggregateChecks(modelName+"."+name, &sub, basePath+"/subsystems/"+name)
	}
}

// shapedExceptSelfDefined is shaped less the variables an observed or
// recurrence definition's LHS names. A bare read of the variable such an
// equation defines is a self-reference recurrence_not_wellfounded or
// observed_cycle already reports. A derivative LHS — `D(y)`, or the
// array-equation `faq[i](D(y[i]))` — keeps every name: no other check reports
// `D(y) ~ faq(… y …)`, and the bare `y` there is the same unaligned
// whole-array read as any other.
func shapedExceptSelfDefined(shaped map[string][]string, lhs Expression) map[string][]string {
	derivative := false
	walkOperatorNodes(lhs, func(n ExprNode) {
		if n.Op == "D" {
			derivative = true
		}
	})
	if derivative {
		return shaped
	}
	defined := make(map[string]bool)
	collectStringLeaves(lhs, defined)
	here := make(map[string][]string, len(shaped))
	for name, axes := range shaped {
		if !defined[name] {
			here[name] = axes
		}
	}
	return here
}

// authoredTemplateApplications records, from the authored document view, the
// right-hand side of every model equation (inline subsystems included) that
// holds an `apply_expression_template` node, keyed by its equation pointer.
func authoredTemplateApplications(view map[string]any) map[string]Expression {
	out := make(map[string]Expression)
	var visit func(model map[string]any, path string)
	visit = func(model map[string]any, path string) {
		eqs, _ := model["equations"].([]any)
		for i, raw := range eqs {
			eq, ok := raw.(map[string]any)
			if !ok || !rawHoldsTemplateApplication(eq["rhs"]) {
				continue
			}
			b, err := json.Marshal(eq["rhs"])
			if err != nil {
				continue
			}
			rhs, err := UnmarshalExpression(b)
			if err != nil {
				continue
			}
			out[fmt.Sprintf("%s/equations/%d", path, i)] = rhs
		}
		subs, _ := model["subsystems"].(map[string]any)
		for name, raw := range subs {
			if sub, ok := raw.(map[string]any); ok {
				visit(sub, path+"/subsystems/"+name)
			}
		}
	}
	models, _ := view["models"].(map[string]any)
	for name, raw := range models {
		if model, ok := raw.(map[string]any); ok {
			visit(model, "/models/"+name)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func rawHoldsTemplateApplication(v any) bool {
	switch t := v.(type) {
	case map[string]any:
		if t["op"] == "apply_expression_template" {
			return true
		}
		for _, child := range t {
			if rawHoldsTemplateApplication(child) {
				return true
			}
		}
	case []any:
		for _, child := range t {
			if rawHoldsTemplateApplication(child) {
				return true
			}
		}
	}
	return false
}

// checkFAQBareArrayOperands reports faq_bare_array_operand for every `faq`
// node in expr whose `expr` or `filter` reads a variable declared with a
// non-empty `shape` by BARE name in an elementwise position (esm-spec §4.3.1,
// issue #441).
//
// A `faq` names its axes by its range symbols and evaluates its body and filter
// once per index tuple, so a whole array there does not say which symbol each
// of its axes is. The executing bindings each gave it a meaning and disagreed
// (Rust's reference kept every term of a filter it could not align to the
// output box, so a filter over a node with two output indices was silently
// ignored), so the read must be `index(v, i, …)`.
//
// The descent is collectBareArrayOperands' (elementwise nodes only); a name a
// `faq` binds as a loop symbol, there or further out, shadows the declaration;
// nested `faq` nodes are checked in their own right; a template application is
// opaque, so an array bound to one of its arguments is not a bare read. Order:
// pre-order over nodes, `expr` before `filter`, matching the other bindings.
func (s *structuralScan) checkFAQBareArrayOperands(expr Expression, shaped map[string][]string, fieldPath, modelName string) {
	if len(shaped) == 0 {
		return
	}
	var walk func(e Expression, bound map[string]bool)
	walk = func(e Expression, bound map[string]bool) {
		if list, ok := e.([]any); ok {
			for _, el := range list {
				walk(el, bound)
			}
			return
		}
		node, ok := asExprNode(e)
		if !ok || node.Op == "apply_expression_template" {
			return
		}
		inner := bound
		if node.Op == opAggregate {
			inner = make(map[string]bool)
			for k := range bound {
				inner[k] = true
			}
			for _, sym := range node.OutputIdx {
				inner[fmt.Sprint(sym)] = true
			}
			for sym := range node.Ranges {
				inner[sym] = true
			}
			for _, part := range []struct {
				field string
				expr  Expression
			}{{"expr", node.Expr}, {"filter", node.Filter}} {
				if part.expr == nil {
					continue
				}
				for _, name := range collectBareArrayOperands(part.expr, shaped) {
					if inner[name] {
						continue
					}
					axes := shaped[name]
					s.addErr(StructuralError{
						Path: fieldPath,
						Code: CodeFAQBareArrayOperand,
						Message: fmt.Sprintf("faq `%s` reads %q, declared over [%s], by bare name. A faq names its axes by its range symbols, and its `%s` is evaluated once per index tuple, so a whole array there does not say which symbol each of its axes is. Read it through `index`, e.g. index(%s, <symbol>…) (esm-spec §4.3.1)",
							part.field, name, strings.Join(axes, ", "), part.field, name),
						Details: map[string]any{
							"field":    part.field,
							"variable": name,
							"shape":    axes,
							"model":    modelName,
						},
					})
				}
			}
		}
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walk(child, inner)
			return child, nil
		})
	}
	walk(expr, map[string]bool{})
}

// checkAggregateUndefinedIndexSet reports undefined_index_set for every
// `ranges` entry whose `{from: NAME}` names a set absent from the document
// `index_sets` registry (RFC §5.2 — no implicit interval is inferred).
//
// Run only when the document DECLARES a registry. A document that declares none
// is a §9.7.10 discretization-agnostic PDE leaf: its index sets arrive from a
// discretization library injected into this component's scope by a composing
// document, a subsystem-ref edge or an inline test (§6.6.6), so the effective
// registry exists only in that per-run build and resolving `{from: NAME}`
// against the empty local registry would reject every conforming leaf. The
// check is deferred there, mirroring §9.6.1's standalone exemption for
// template_constraint_unknown_index_set; a name still unresolved once injection
// has run is rejected by the evaluating bindings' resolvers (issue #185).
func (s *structuralScan) checkAggregateUndefinedIndexSet(node ExprNode, fieldPath, modelName string, seen map[string]bool) {
	if s.file == nil || len(s.file.IndexSets) == 0 {
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

// valueInventionBodyOps are the body ops that make a `faq` a value-invention
// node. Over such a node a ragged range binds the MEMBER values[parent, k]
// itself (esm-spec §4.3.1 "Ragged ranges"), so its `values` gather is implicit
// rather than authored.
var valueInventionBodyOps = map[string]bool{
	"distinct": true,
}

// isValueInventionFAQ reports whether node is a value-invention `faq`:
// `distinct: true`, or a `distinct` body.
func isValueInventionFAQ(node ExprNode) bool {
	if node.Distinct != nil && *node.Distinct {
		return true
	}
	body, ok := asExprNode(node.Expr)
	return ok && valueInventionBodyOps[body.Op]
}

// containsTemplateReference reports whether expr holds a surviving
// `apply_expression_template` reference (esm-spec §9.6.4), whose body a static
// walk of this document cannot see.
func containsTemplateReference(expr Expression) bool {
	found := false
	walkOperatorNodes(expr, func(n ExprNode) {
		if n.Op == "apply_expression_template" {
			found = true
		}
	})
	return found
}

// checkAggregateRaggedValuesGathered reports ragged_values_not_gathered for
// every range of a `faq` that iterates a declared `kind: "ragged"` index set
// whose `values` array the body (`expr` / `filter`) never reads (esm-spec
// §4.3.1 "Ragged ranges", issue #259). Such a range binds the POSITION k in
// 1..offsets[parent], never a member, so the body reads positions where the
// author meant members.
//
// Not decided for a value-invention node, which binds the member itself, nor
// for a body that still holds a template reference, which may do the gather out
// of sight. A set the document does not declare is left to the build, as
// checkAggregateUndefinedIndexSet does.
func (s *structuralScan) checkAggregateRaggedValuesGathered(node ExprNode, fieldPath, modelName string, seen map[string]bool) {
	if s.file == nil || len(s.file.IndexSets) == 0 || len(node.Ranges) == 0 || isValueInventionFAQ(node) {
		return
	}
	if containsTemplateReference(node.Expr) || containsTemplateReference(node.Filter) {
		return
	}
	refs := make(map[string]bool)
	collectStringLeaves(node.Expr, refs)
	collectStringLeaves(node.Filter, refs)
	for _, rangeKey := range sortedKeys(node.Ranges) {
		name := rangeFromName(node.Ranges[rangeKey])
		if name == "" {
			continue
		}
		iset, declared := s.file.IndexSets[name]
		if !declared || iset.Kind != "ragged" || iset.Values == nil {
			continue
		}
		values := *iset.Values
		gathered := false
		for ref := range refs {
			if ref == values || strings.HasSuffix(ref, "."+values) {
				gathered = true
				break
			}
		}
		if gathered {
			continue
		}
		dedup := "ragged_values_not_gathered|" + fieldPath + "|" + rangeKey
		if seen[dedup] {
			continue
		}
		seen[dedup] = true
		parents := []string{}
		if m, ok := node.Ranges[rangeKey].(map[string]any); ok {
			if of, ok := m["of"].([]any); ok {
				for _, p := range of {
					if ps, ok := p.(string); ok {
						parents = append(parents, ps)
					}
				}
			}
		}
		parent := strings.Join(parents, ", ")
		if parent == "" {
			parent = "<parent>"
		}
		offsets := "offsets"
		if iset.Offsets != nil {
			offsets = *iset.Offsets
		}
		s.addErr(StructuralError{
			Path: fieldPath,
			Code: CodeRaggedValuesNotGathered,
			Message: fmt.Sprintf("faq range '%s' iterates ragged index set '%s', so it binds the POSITION k in 1..%s[%s], not a member; the body never reads the set's `values` array '%s'. Gather the member explicitly: index(%s, %s, %s)",
				rangeKey, name, offsets, parent, values, values, parent, rangeKey),
			Details: map[string]any{
				"range":     rangeKey,
				"index_set": name,
				"values":    values,
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

// checkAggregateJoinSides reports the two static `join` SIDE findings of
// CONFORMANCE_SPEC §5.5.8, both decidable from this ONE document -- the node's
// `ranges`, the declared variable shapes and the clause itself are all here, so
// no evaluation, no runtime data and no other file are needed. Both are stated
// about the DOCUMENT rather than about where any one implementation happens to
// resolve a join, which is what lets all five bindings pin the same fixtures
// (tests/invalid/expected_errors.json).
//
//   - join_syms_unknown_symbol: a clause's `syms` entry that is not a key of the
//     node's `ranges`. Unchecked, that side resolves to no symbol at all and RFC
//     §5.3's degenerate-positional rule silently DROPS the pair -- an ungated
//     full product, reported as a number rather than as a failure.
//   - join_side_ambiguous: an `on` key for which the document does not determine
//     a range symbol. The symbol comes from an index set -- named outright, or
//     the sole shape axis of the declared 1-D variable that names it -- and if
//     that set is drawn by MORE THAN ONE of the node's ranges with no `syms` on
//     the clause, the key does not say which. TWO candidates resolve by the
//     default side assignment only for a DATA COLUMN: a key naming the index set
//     can already say which side it means by naming the range symbol instead.
func (s *structuralScan) checkAggregateJoinSides(node ExprNode, varShapes map[string][]string, fieldPath, modelName string, seen map[string]bool) {
	if len(node.Join) == 0 || len(node.Ranges) == 0 {
		return
	}
	setToSyms := make(map[string][]string)
	for rangeKey := range node.Ranges {
		if name := rangeFromName(node.Ranges[rangeKey]); name != "" {
			setToSyms[name] = append(setToSyms[name], rangeKey)
		}
	}
	for _, syms := range setToSyms {
		sort.Strings(syms)
	}
	declared := sortedKeys(node.Ranges)

	for _, clause := range node.Join {
		cm, ok := clause.(map[string]any)
		if !ok {
			continue
		}
		if raw, present := cm["syms"]; present {
			list, _ := raw.([]any)
			for _, el := range list {
				name, _ := el.(string)
				if _, isRange := node.Ranges[name]; isRange {
					continue
				}
				dedup := "join_syms_unknown_symbol|" + fieldPath
				if seen[dedup] {
					return
				}
				seen[dedup] = true
				s.addErr(StructuralError{
					Path: fieldPath,
					Code: CodeJoinSymsUnknownSymbol,
					Message: fmt.Sprintf(
						"Aggregate join `syms` names '%s', which is not a range symbol of this aggregate; "+
							"both entries must name one of its `ranges`", name),
					Details: map[string]any{
						"join_syms_entry": name,
						"declared_ranges": declared,
						"model":           modelName,
					},
				})
				return
			}
			// An explicit `syms` answers every pair of this clause.
			continue
		}
		onList, _ := cm["on"].([]any)
		for _, pair := range onList {
			pl, ok := pair.([]any)
			if !ok || len(pl) != 2 {
				continue
			}
			for i, el := range pl {
				key, ok := el.(string)
				if !ok || key == "" {
					continue
				}
				if _, isRange := node.Ranges[key]; isRange {
					continue
				}
				setName := ""
				viaColumn := false
				if _, named := setToSyms[key]; named {
					setName = key
				} else if shape, has := varShapes[key]; has && len(shape) == 1 {
					setName, viaColumn = shape[0], true
				} else {
					continue
				}
				cands := setToSyms[setName]
				// One candidate: two distinct relations. Two: the default side
				// assignment, but only for a data column. Three or more: never.
				if len(cands) < 2 || (len(cands) == 2 && viaColumn) {
					continue
				}
				dedup := "join_side_ambiguous|" + fieldPath
				if seen[dedup] {
					return
				}
				seen[dedup] = true
				msg := fmt.Sprintf(
					"Aggregate join key '%s' names an index set that %d range symbols of this aggregate draw; "+
						"reference the range symbol directly, or name the clause's two sides with `syms`",
					key, len(cands))
				if viaColumn {
					msg = fmt.Sprintf(
						"Aggregate join key column '%s' lives on index set '%s', which %d range symbols of this "+
							"aggregate draw, so the document does not determine which one the key is read at; "+
							"name the clause's two sides with `syms`", key, setName, len(cands))
				}
				side := "left"
				if i == 1 {
					side = "right"
				}
				s.addErr(StructuralError{
					Path:    fieldPath,
					Code:    CodeJoinSideAmbiguous,
					Message: msg,
					Details: map[string]any{
						"join_key":                key,
						"side":                    side,
						"index_set":               setName,
						"candidate_range_symbols": cands,
						"model":                   modelName,
					},
				})
				return
			}
		}
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
