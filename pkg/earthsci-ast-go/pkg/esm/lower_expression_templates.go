package esm

// Load-time rewrite pass for `operators` (esm-spec §9.6,
// docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md).
//
// Each `operators` entry is a rewrite rule with `params`
// (metavariables) and a `body` (replacement Expression), applied in one of two
// ways:
//
//   - WITHOUT a `match` field — invoked explicitly by an
//     `apply_operator` node whose `bindings` supply each param's AST
//     (named-template expansion).
//   - WITH a `match` field — an auto-applied rewrite rule: `match` is a pattern
//     Expression whose param occurrences are wildcards, fired wherever it
//     structurally matches a node. A param in an operand/`args` position binds
//     to the matched sub-AST; a param in a scalar field (`dim`, `side`,
//     `attrs.<key>`, …) binds to the matched literal.
//
// Rewriting is OUTERMOST-FIRST, PRIORITY-ORDERED, BOUNDED-FIXPOINT (esm-spec
// §9.6.3), mirroring the Julia reference `_rewrite_pass` / `_rewrite_to_fixpoint`.
// One pass (`rewritePass`) is a single pre-order (outermost-first) walk. At each
// node the structurally-matching `match` rule of highest `priority` (int,
// default 0; ties by declaration order) fires and WRITES A REFERENCE to itself
// (esm-spec §9.6.3 constraint 7) — a leaf-bodied rule writes its leaf; the walk
// does NOT descend into what it wrote during the current pass. At an
// `apply_operator` reference no rule is tried, but the walk descends
// into the values of its `bindings` (§9.6.4 rule 4). Passes repeat until a pass
// performs zero rewrites (the fixpoint); a rewrite at depth > MaxRewritePasses
// rejects the file with `rewrite_rule_nonterminating`. Then the rules apply
// inside the bodies of the templates the references reach, once per template
// instance (§9.6.4 rule 3, template_instances.go). Nothing here substitutes a
// template body: references survive, and each component keeps its
// `operators` registry (Option B). Any rewrite-target op (e.g. a
// spatial `D`) that survives into an evaluation position is caught later by the
// `unlowered_operator` gate (see Evaluate), not here.
//
// Operates on the pre-deserialization `map[string]interface{}` view, so it
// must run after schema validation but before unmarshaling into the
// `ESMFile` struct.

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const applyExpressionTemplateOp = "apply_operator"

// expressionTemplatesSkip is the skip-set the §9.6.4 expanded-form validators
// pass to walkJSONTreeSkipping so they do NOT descend into pre-substitution
// `operators` bodies (which may legally carry parameter names in
// scalar slots).
var expressionTemplatesSkip = map[string]struct{}{"operators": {}}

// MaxRewritePasses is the maximum number of productive rewrite passes before a
// file is rejected as non-converging (esm-spec §9.6.3, diagnostic
// `rewrite_rule_nonterminating`). Pinned identically across all bindings so the
// accept/reject decision — and the resulting fixpoint — is byte-identical
// everywhere.
const MaxRewritePasses = 64

// ExpressionTemplateError is the error type raised by the expression-template
// expansion pass. The Code field carries one of the stable diagnostic codes:
//
//   - operator_unknown_definition
//   - operator_bindings_mismatch
//   - operator_recursive_body
//   - operator_invalid_definition
//   - operator_version_too_old
//   - rewrite_rule_nonterminating
//
// or one of the esm-spec §9.7 template-library / metaparameter codes
// (§9.6.6, raised from template_imports.go and subsystem_ref.go):
//
//   - operator_import_version_too_old
//   - operator_import_unresolved
//   - operator_import_not_library
//   - operator_library_illegal_payload
//   - subsystem_ref_is_operator_library
//   - operator_import_cycle
//   - operator_import_name_conflict
//   - operator_import_unknown_name
//   - operator_import_index_set_conflict
//   - operator_body_expansion_too_deep
//   - metaparameter_unbound
//   - metaparameter_type_error
//   - metaparameter_name_conflict
//
// or one of the esm-spec §10.11 coupling-library / coupling_import codes
// (raised from coupling_imports.go, subsystem_ref.go, template_imports.go):
//
//   - coupling_import_unresolved
//   - coupling_import_not_library
//   - subsystem_ref_is_coupling_library
//   - operator_import_is_coupling_library
//   - coupling_library_illegal_payload
//   - coupling_library_nested_import
//   - coupling_edge_unknown_role
//   - coupling_role_unused
//   - coupling_import_unknown_role
//   - coupling_import_role_unbound
//   - coupling_import_bind_not_a_component
type ExpressionTemplateError struct {
	Code    string
	Message string
	// Path is an RFC 6901 JSON Pointer to the document node that carries the
	// defect, when one can be attributed. It is populated for LOAD-phase
	// rejections that a conformance producer must surface as a structured
	// (code, path) structural finding — e.g. a §4.7 subsystem ref that does not
	// resolve (`/models/<M>/subsystems/<name>`). Most template/metaparameter
	// errors leave it empty; a caller that needs a pointer sets it via
	// withETPath as the error unwinds past the frame that knows the location.
	Path string
}

func (e *ExpressionTemplateError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *ExpressionTemplateError) DiagnosticCode() string { return e.Code }

// DiagnosticPath returns the JSON Pointer the error is attributed to, or "" if
// none was set.
func (e *ExpressionTemplateError) DiagnosticPath() string { return e.Path }

// withETPath attaches a JSON Pointer to the *ExpressionTemplateError anywhere in
// err's wrap chain, but only if one is not already set — so the INNERMOST frame
// that knows the location wins (a nested subsystem edge's own pointer is not
// overwritten by an enclosing frame). Non-ET errors pass through untouched.
func withETPath(err error, path string) error {
	var et *ExpressionTemplateError
	if errors.As(err, &et) && et.Path == "" {
		et.Path = path
	}
	return err
}

func newETErr(code, msg string) *ExpressionTemplateError {
	return &ExpressionTemplateError{Code: code, Message: msg}
}

// assertNoNestedApply rejects `apply_operator` nodes inside a
// `match` pattern (esm-spec §9.7.3: match patterns MUST NOT reference
// templates).
func assertNoNestedApply(body any, templateName, path string) error {
	// walkJSONTree descends objects in sorted-key order, so the surfaced error
	// is deterministic across runs (Go map iteration is randomized).
	return walkJSONTree(body, path, func(p string, b map[string]any) error {
		if op, ok := b["op"].(string); ok && op == applyExpressionTemplateOp {
			return newETErr(
				CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("operators.%s: `match` contains an 'apply_operator' node at %s; match patterns MUST NOT reference templates (esm-spec §9.7.3)", templateName, p),
			)
		}
		return nil
	})
}

func validateTemplates(templates map[string]any, scope string) error {
	for _, name := range sortedKeys(templates) {
		decl := templates[name]
		declObj, ok := decl.(map[string]any)
		if !ok {
			return newETErr(
				CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: entry must be an object with params + body", scope, name),
			)
		}
		// `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
		// template is a named constant fragment (common in library files).
		paramsRaw, ok := declObj["params"].([]any)
		if !ok {
			return newETErr(
				CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: 'params' must be an array of strings", scope, name),
			)
		}
		seen := make(map[string]struct{})
		for _, p := range paramsRaw {
			ps, ok := p.(string)
			if !ok || ps == "" {
				return newETErr(
					CodeApplyExpressionTemplateInvalidDeclaration,
					fmt.Sprintf("%s.operators.%s: param names must be non-empty strings", scope, name),
				)
			}
			if _, exists := seen[ps]; exists {
				return newETErr(
					CodeApplyExpressionTemplateInvalidDeclaration,
					fmt.Sprintf("%s.operators.%s: param '%s' declared twice", scope, name, ps),
				)
			}
			seen[ps] = struct{}{}
		}
		if _, ok := declObj["body"]; !ok {
			return newETErr(
				CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: 'body' is required", scope, name),
			)
		}
		// A body MAY reference other match-less in-scope templates via
		// apply_operator nodes (esm-spec §9.7.3); those are checked
		// (acyclic, depth <= MaxTemplateExpansionDepth) and inlined at
		// registration by composeTemplateBodies — the old any-nesting
		// rejection is now cycle-only (`operator_recursive_body`).
		// esm-spec §9.6: an optional `match` pattern turns the entry into an
		// auto-applied rewrite rule. The pattern is an Expression whose declared
		// params are wildcards; it MUST NOT contain nested
		// apply_operator ops. Nontermination is NOT checked statically
		// — the bounded fixpoint (MaxRewritePasses, esm-spec §9.6.3) is the
		// authoritative guard, so a self-reintroducing rule is rejected only when
		// it actually fails to converge (`rewrite_rule_nonterminating`).
		matchRaw, hasMatch := declObj["match"]
		if hasMatch && matchRaw != nil {
			if err := assertNoNestedApply(matchRaw, name, "/match"); err != nil {
				return err
			}
		}

		if err := validateWhereBlock(declObj, seen, hasMatch, matchRaw, scope, name); err != nil {
			return err
		}
	}
	return nil
}

// validateWhereBlock performs the structural validation of a template's optional
// `where` match-scoping block (esm-spec §9.6.1, 0.8.0; admissible on a
// match-less definition since esm 2.4.0): it must be a non-empty object mapping declared params
// (present in `seen`) to single-key `{shape: [nonEmptyString...]}` constraint
// objects. Only the shape/structure is checked here — the unknown-index-set
// check runs later at rule REGISTRATION in the consuming component, where the
// merged `index_sets` registry is in scope (see registeredWhere). A declaration
// with no `where` block is a no-op.
func validateWhereBlock(declObj map[string]any, seen map[string]struct{}, hasMatch bool, matchRaw any, scope, name string) error {
	whrRaw, hasWhere := declObj["where"]
	if !hasWhere || whrRaw == nil {
		return nil
	}
	// esm 2.4.0 (esm-spec §9.6.3 constraint 2, §9.6.8): a `where` scopes a
	// match-less definition too, at a call of the defined operator it defines.
	whr, ok := whrRaw.(map[string]any)
	if !ok || len(whr) == 0 {
		return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
			fmt.Sprintf("%s.operators.%s: 'where' must be a non-empty object mapping declared params to constraint objects", scope, name))
	}
	for _, p := range sortedKeys(whr) {
		if _, isParam := seen[p]; !isParam {
			return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: 'where' constrains '%s', which is not a declared param (esm-spec §9.6.1)", scope, name, p))
		}
		cobj, ok := whr[p].(map[string]any)
		if !ok {
			return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: where.%s must be a constraint object (v1 admits exactly the 'shape' kind)", scope, name, p))
		}
		ckeys := sortedKeys(cobj)
		if len(ckeys) != 1 || ckeys[0] != "shape" {
			return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: where.%s carries constraint kind(s) %s; the v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)", scope, name, p, strings.Join(ckeys, ", ")))
		}
		shp, ok := cobj["shape"].([]any)
		if !ok || len(shp) == 0 {
			return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s.operators.%s: where.%s.shape must be a non-empty array of index-set names", scope, name, p))
		}
		for _, s := range shp {
			if ss, ok := s.(string); !ok || ss == "" {
				return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
					fmt.Sprintf("%s.operators.%s: where.%s.shape entries must be non-empty strings", scope, name, p))
			}
		}
	}
	return nil
}

func deepCopyJSON(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[k] = deepCopyJSON(val)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = deepCopyJSON(val)
		}
		return out
	default:
		return x
	}
}

// substituteParams instantiates a template body against `bindings` with
// STRUCTURAL SHARING (mirroring the Julia reference fix: expanded templates
// are stored as shared DAGs, not exponential trees). A bound sub-AST is
// spliced in BY REFERENCE — never deep-copied — and a map/array none of whose
// children changed is returned as the SAME object. A body subtree with no
// param occurrences therefore stays shared between every instantiation site,
// so a chain of templates that each reference the previous one twice expands
// to a DAG with O(chain) unique nodes instead of 2^chain materialized copies.
// Representation-only: expansion semantics, diagnostics, and serialized bytes
// are unchanged (json.Marshal expands the DAG). Sound because the rewrite
// pipeline never mutates expanded nodes in place — every subsequent pass is
// itself identity-preserving.
func substituteParams(body any, bindings map[string]any) any {
	out, _ := substituteParamsShared(body, bindings, substMemo{})
	return out
}

// substMemo memoizes one substituteParams call over a shared-DAG body: object
// nodes are keyed by map pointer identity, so a sub-body shared under many
// parents is substituted once and its result re-shared. Sound because the
// bindings are constant for the duration of one call. The memo is call-local —
// different calls carry different bindings.
type substMemo map[uintptr]substMemoEntry

type substMemoEntry struct {
	out     any
	changed bool
}

// substituteParamsShared is substituteParams with a `changed` flag upholding
// the identity-preservation invariant: changed == false ⟹ the returned value
// IS `body` (the same object, not an equal copy).
func substituteParamsShared(body any, bindings map[string]any, memo substMemo) (any, bool) {
	switch b := body.(type) {
	case string:
		if v, ok := bindings[b]; ok {
			// Splice the bound sub-AST by reference (structural sharing).
			return v, true
		}
		return body, false
	case []any:
		var out []any
		for i, c := range b {
			nc, ch := substituteParamsShared(c, bindings, memo)
			if ch && out == nil {
				out = make([]any, len(b))
				copy(out, b[:i])
			}
			if out != nil {
				out[i] = nc
			}
		}
		if out == nil {
			return b, false
		}
		return out, true
	case map[string]any:
		key := reflect.ValueOf(b).Pointer()
		if e, hit := memo[key]; hit {
			return e.out, e.changed
		}
		var out map[string]any
		for k, v := range b {
			nv, ch := substituteParamsShared(v, bindings, memo)
			if ch {
				if out == nil {
					out = make(map[string]any, len(b))
					for k2, v2 := range b {
						out[k2] = v2
					}
				}
				out[k] = nv
			}
		}
		if out == nil {
			memo[key] = substMemoEntry{out: b, changed: false}
			return b, false
		}
		memo[key] = substMemoEntry{out: out, changed: true}
		return out, true
	default:
		return body, false
	}
}

func expandApply(node map[string]any, templates map[string]any, scope string) (any, error) {
	nameRaw, ok := node["name"].(string)
	if !ok || nameRaw == "" {
		return nil, newETErr(
			CodeApplyExpressionTemplateInvalidDeclaration,
			fmt.Sprintf("%s: apply_operator node missing or empty 'name'", scope),
		)
	}
	declRaw, ok := templates[nameRaw]
	if !ok {
		return nil, newETErr(
			CodeApplyExpressionTemplateUnknownTemplate,
			fmt.Sprintf("%s: apply_operator references undeclared template '%s'", scope, nameRaw),
		)
	}
	decl, ok := declRaw.(map[string]any)
	if !ok {
		return nil, newETErr(
			CodeApplyExpressionTemplateInvalidDeclaration,
			fmt.Sprintf("%s: template '%s' declaration is not an object", scope, nameRaw),
		)
	}
	bindingsRaw, ok := node["bindings"].(map[string]any)
	if !ok {
		return nil, newETErr(
			CodeApplyExpressionTemplateBindingsMismatch,
			fmt.Sprintf("%s: apply_operator '%s' missing 'bindings' object", scope, nameRaw),
		)
	}
	paramsArr, _ := decl["params"].([]any)
	declared := make(map[string]struct{}, len(paramsArr))
	params := make([]string, 0, len(paramsArr))
	for _, p := range paramsArr {
		if ps, ok := p.(string); ok {
			declared[ps] = struct{}{}
			params = append(params, ps)
		}
	}
	for _, p := range params {
		if _, ok := bindingsRaw[p]; !ok {
			return nil, newETErr(
				CodeApplyExpressionTemplateBindingsMismatch,
				fmt.Sprintf("%s: apply_operator '%s' missing binding for param '%s'", scope, nameRaw, p),
			)
		}
	}
	for k := range bindingsRaw {
		if _, ok := declared[k]; !ok {
			return nil, newETErr(
				CodeApplyExpressionTemplateBindingsMismatch,
				fmt.Sprintf("%s: apply_operator '%s' supplies unknown param '%s'", scope, nameRaw, k),
			)
		}
	}
	// The template `body` is instantiated by pure structural substitution and is
	// NOT re-scanned here (esm-spec §9.6.3): the substituted body's sub-ASTs
	// (from `bindings`) are spliced in intact and rewritten in SUBSEQUENT passes
	// by the outermost-first fixpoint driver — never pre-rewritten in place.
	resolved := make(map[string]any, len(bindingsRaw))
	for k, v := range bindingsRaw {
		resolved[k] = v
	}
	body := decl["body"]
	return substituteParams(body, resolved), nil
}

// ---------------------------------------------------------------------------
// Structural pattern matching (auto-applied `match` rewrite rules, esm-spec §9.6)
// ---------------------------------------------------------------------------

// asNumber reports whether v is a JSON number (json.Number or a native numeric
// type) and returns its float64 value. A bool is NOT a number.
func asNumber(v any) (float64, bool) {
	switch n := v.(type) {
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case int32:
		return float64(n), true
	}
	return 0, false
}

// jsonEqual is structural equality over the normalized JSON view (map / slice /
// scalar / string / number / bool). Numbers compare by value; bools compare only
// to bools. Used to enforce that a metavariable bound twice in one pattern binds
// to identical sub-trees.
func jsonEqual(a, b any) bool {
	if ab, ok := a.(bool); ok {
		bb, ok := b.(bool)
		return ok && ab == bb
	}
	if _, ok := b.(bool); ok {
		return false
	}
	if af, ok := asNumber(a); ok {
		bf, ok := asNumber(b)
		return ok && af == bf
	}
	if as, ok := a.(string); ok {
		bs, ok := b.(string)
		return ok && as == bs
	}
	if aa, ok := a.([]any); ok {
		ba, ok := b.([]any)
		if !ok || len(aa) != len(ba) {
			return false
		}
		for i := range aa {
			if !jsonEqual(aa[i], ba[i]) {
				return false
			}
		}
		return true
	}
	if am, ok := a.(map[string]any); ok {
		bm, ok := b.(map[string]any)
		if !ok || len(am) != len(bm) {
			return false
		}
		for k, v := range am {
			w, present := bm[k]
			if !present || !jsonEqual(v, w) {
				return false
			}
		}
		return true
	}
	return a == nil && b == nil
}

// matchPattern structurally matches `pattern` (an Expression whose declared
// `params` are wildcards) against `node`, accumulating metavariable bindings.
// A param string in any position binds to the matched value (sub-AST or scalar
// literal); a param bound twice must bind to structurally equal values.
// Non-param strings, numbers, and booleans match literally; arrays match
// elementwise (same length); objects match when every pattern key is present on
// `node` and matches (extra `node` keys are allowed).
//
// `bv` is the body view when `node` sits in a template body being rewritten
// for one instance (esm-spec §9.6.4 rules 3 and 4): there a parameter is a
// leaf — a metavariable captures it whole, and any other pattern node sees it
// only as the literal its instance binds in a structural position (and never
// matches an operand-position parameter).
func matchPattern(pattern, node any, params map[string]struct{}, bindings map[string]any, bv *bodyView) bool {
	if ns, ok := node.(string); ok && bv.isParam(ns) {
		ps, pIsStr := pattern.(string)
		_, pIsMeta := params[ps]
		if !pIsStr || !pIsMeta {
			lit, has := bv.lit[ns]
			if !has {
				return false
			}
			return matchPattern(pattern, lit, params, bindings, nil)
		}
	}
	if pb, ok := pattern.(bool); ok {
		nb, ok := node.(bool)
		return ok && nb == pb
	}
	if ps, ok := pattern.(string); ok {
		if _, isParam := params[ps]; isParam {
			if existing, seen := bindings[ps]; seen {
				return jsonEqual(existing, node)
			}
			bindings[ps] = node
			return true
		}
		ns, ok := node.(string)
		return ok && ns == ps
	}
	if pf, ok := asNumber(pattern); ok {
		if _, isBool := node.(bool); isBool {
			return false
		}
		nf, ok := asNumber(node)
		return ok && nf == pf
	}
	if pa, ok := pattern.([]any); ok {
		na, ok := node.([]any)
		if !ok || len(pa) != len(na) {
			return false
		}
		for i := range pa {
			if !matchPattern(pa[i], na[i], params, bindings, bv) {
				return false
			}
		}
		return true
	}
	if pm, ok := pattern.(map[string]any); ok {
		nm, ok := node.(map[string]any)
		if !ok {
			return false
		}
		for k, pv := range pm {
			nv, present := nm[k]
			if !present {
				return false
			}
			if !matchPattern(pv, nv, params, bindings, bv) {
				return false
			}
		}
		return true
	}
	// nil / null literal in the pattern.
	return pattern == nil && node == nil
}

// ---------------------------------------------------------------------------
// Static match-scoping constraints (`where`, esm-spec §9.6.1;
// docs/rfcs/match-pattern-scoping-constraints.md)
// ---------------------------------------------------------------------------

// componentShapeEnv is the static shape environment of one component: every
// declared variable name mapped to its declared `shape` (ordered index-set
// names). This is the ONLY information a `where` constraint may consult
// (esm-spec §9.6.1) — declared shapes at lowering time, never runtime values —
// so constraint evaluation is fully static and the §9.6.3 determinism contract
// is untouched. Variables with no `shape` (scalars) are absent from the
// environment, as are species / parameters of reaction systems (no `shape`
// field): a shape-constrained rule can only fire on a declared, shaped model
// variable.
func componentShapeEnv(comp map[string]any) map[string][]string {
	env := map[string][]string{}
	vars, ok := comp["variables"].(map[string]any)
	if !ok {
		return env
	}
	for vn, vdRaw := range vars {
		vd, ok := vdRaw.(map[string]any)
		if !ok {
			continue
		}
		shp, ok := vd["shape"].([]any)
		if !ok {
			continue
		}
		names := make([]string, 0, len(shp))
		allStr := true
		for _, s := range shp {
			ss, ok := s.(string)
			if !ok {
				allStr = false
				break
			}
			names = append(names, ss)
		}
		if !allStr {
			continue
		}
		env[vn] = names
	}
	return env
}

// strSliceEqual reports whether two string slices are equal (same length, same
// entries in the same order).
func strSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// whereSatisfied evaluates a registered `where` constraint map (param → required
// shape) against the bindings produced by a successful structural match
// (esm-spec §9.6.1). A constraint on param `p` holds iff `bindings[p]` is a BARE
// variable-reference string naming an entry of `shapeEnv` whose declared shape
// equals the required list exactly (same names, same order). Everything else — a
// compound sub-AST, a numeric literal, a scalar-field-bound literal, a scoped
// (`System.var`) reference, an undeclared name, a scalar variable, or a param
// that never bound — fails the constraint. The judgment is deliberately
// syntactic and conservative: no shape inference over compound expressions, so
// eligibility depends only on declarations and is byte-identical across
// bindings.
//
// Inside a template body (`bv` non-nil) a captured value that is one of the
// body's parameters satisfies a constraint iff its instance binds a bare
// variable of exactly that declared shape (esm-spec §9.6.4 rule 3).
func whereSatisfied(whereC map[string][]string, bindings map[string]any, shapeEnv map[string][]string, bv *bodyView) bool {
	if whereC == nil {
		return true
	}
	for p, req := range whereC {
		b, ok := bindings[p]
		if !ok {
			return false
		}
		bs, ok := b.(string)
		if !ok {
			return false
		}
		if bv.isParam(bs) {
			if bv.entries[bs] != shapeEntry(req) {
				return false
			}
			continue
		}
		shp, ok := shapeEnv[bs]
		if !ok || !strSliceEqual(shp, req) {
			return false
		}
	}
	return true
}

// registeredWhere normalizes a template's `where` block into the registered
// constraint map (param → required shape), checking every referenced index-set
// name against the CONSUMING document's merged `index_sets` registry
// (`isetNames`). An unknown name is `operator_constraint_unknown_index_set`
// (esm-spec §9.6.6) — raised here, at rule registration in the consuming
// component, not when a library file is loaded standalone: constraints name
// index sets as spelled in the consuming document's registry (post-§9.7.5
// merge, composing with import-edge index-set renaming). Structural validity of
// the `where` block is already guaranteed by validateTemplates.
func registeredWhere(decl map[string]any, isetNames map[string]struct{}, scope, tname string) (map[string][]string, error) {
	whrRaw, has := decl["where"]
	if !has || whrRaw == nil {
		return nil, nil
	}
	whr, ok := whrRaw.(map[string]any)
	if !ok {
		return nil, nil
	}
	out := map[string][]string{}
	for _, p := range sortedKeys(whr) {
		cobj, _ := whr[p].(map[string]any)
		shpRaw, _ := cobj["shape"].([]any)
		req := make([]string, 0, len(shpRaw))
		for _, s := range shpRaw {
			ss, _ := s.(string)
			req = append(req, ss)
		}
		for _, s := range req {
			if _, ok := isetNames[s]; !ok {
				return nil, newETErr(CodeTemplateConstraintUnknownIndexSet,
					fmt.Sprintf("%s.operators.%s: where.%s.shape names index set '%s', which the consuming document's index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)", scope, tname, p, s))
			}
		}
		out[p] = req
	}
	return out, nil
}

// asInt64Strict reports whether v is an INTEGER token (json.Number with integer
// grammar, or a native int type — a bool/float/string is not) and returns its
// int64 value. Used by validateMakearrayRegions, which checks only concrete
// integer bound pairs on the folded tree.
func asInt64Strict(v any) (int64, bool) {
	switch n := v.(type) {
	case json.Number:
		if !strings.ContainsAny(string(n), ".eE") {
			if i, err := n.Int64(); err == nil {
				return i, true
			}
		}
	case int:
		return int64(n), true
	case int32:
		return int64(n), true
	case int64:
		return n, true
	}
	return 0, false
}

// validateMakearrayRegions is the post-expansion validator (esm-spec §4.3.2 /
// §9.6.4): every `makearray` region bound pair [start, stop] on the expanded,
// metaparameter-folded tree must satisfy stop >= start - 1. stop == start - 1 is
// the canonical EMPTY bound (the region covers no elements). stop < start - 1 is
// INVERTED and rejected with `makearray_region_inverted`: it is almost always an
// authoring bug (an interior stencil instantiated below its minimum extent, e.g.
// [2, N-1] at N = 1 folding to [2, 0]). Template bodies are skipped —
// pre-substitution bounds may legally carry metaparameter names; only concrete
// integer pairs are checked. Mirrors the Julia reference
// `_validate_makearray_regions`.
func validateMakearrayRegions(tree any, path string) error {
	// Template bodies/matches are pre-substitution trees; bounds may legally
	// carry metaparameter names or fold later (esm-spec §9.7.6), so
	// `operators` is skipped. The expanded form is a shared DAG
	// (structural sharing), so each unique node is validated once.
	return walkJSONTreeUniqueSkipping(tree, path, expressionTemplatesSkip, func(p string, t map[string]any) error {
		if op, _ := t["op"].(string); op != "makearray" {
			return nil
		}
		regions, ok := t["regions"].([]any)
		if !ok {
			return nil
		}
		for ri, regionRaw := range regions {
			region, ok := regionRaw.([]any)
			if !ok {
				continue
			}
			for di, boundsRaw := range region {
				bounds, ok := boundsRaw.([]any)
				if !ok || len(bounds) != 2 {
					continue
				}
				lo, loOk := asInt64Strict(bounds[0])
				hi, hiOk := asInt64Strict(bounds[1])
				if !loOk || !hiOk {
					continue
				}
				if hi < lo-1 {
					return newETErr(CodeMakearrayRegionInverted,
						fmt.Sprintf("%s: makearray regions[%d] dimension %d bound pair [%d, %d] is inverted (stop < start - 1). An empty bound is spelled [start, start-1] and contributes no elements (esm-spec §4.3.2); a further-inverted pair is an authoring error — e.g. an interior stencil region [2, N-1] instantiated at N below the scheme's minimum extent (§9.6.8).", p, ri, di, lo, hi))
				}
			}
		}
		return nil
	})
}

// rulePriority returns the `priority` of a `match` rule (esm-spec §9.6.3): higher
// fires first, ties break by declaration order. Absent ⇒ 0. Any numeric encoding
// is coerced defensively.
func rulePriority(decl map[string]any) int {
	p, ok := decl["priority"]
	if !ok || p == nil {
		return 0
	}
	if _, isBool := p.(bool); isBool {
		return 0
	}
	if n, ok := p.(json.Number); ok {
		if i, err := n.Int64(); err == nil {
			return int(i)
		}
		if f, err := n.Float64(); err == nil {
			return int(math.Round(f))
		}
		return 0
	}
	if f, ok := asNumber(p); ok {
		return int(math.Round(f))
	}
	return 0
}

// matchRule is a pre-processed auto-applied (`match`) rewrite rule.
type matchRule struct {
	// name is the rule's registry name: a firing writes a reference to it
	// (esm-spec §9.6.3 constraint 7).
	name    string
	pattern any
	params  map[string]struct{}
	// paramList is `params` in declared order: the keys of the reference a
	// firing writes.
	paramList []string
	body      any
	priority  int
	declIdx   int
	// whereC is the registered `where` shape-constraint map (param → required
	// shape); nil when the rule carries no `where` block (esm-spec §9.6.1).
	whereC map[string][]string
	// exact: a call rule of a match-less definition (esm 2.4.0, esm-spec
	// §9.6.3 constraint 2, §9.6.12) — `pattern` is `{op: defines, args:
	// params}` and the node may carry no field besides `op` and `args`.
	exact bool
}

// depthRec is one entry of lowering.depth: the reference a firing wrote (held
// so its address cannot be recycled while the map is live) and its depth.
type depthRec struct {
	node map[string]any
	d    int
}

// lowering is one component's rewrite state (esm-spec §9.6.3, §9.6.4 rule 3):
// `named` — every template declaration keyed by name (the registry references
// resolve against; rule 3 adds its variants here); `rules` — the auto-applied
// rules pre-sorted into §9.6.3 selection order; `shapeEnv` — the component's
// static shape environment for `where` constraints; `enums` — the document's
// `enums` block, for the per-instance `enum` lowering of rule 3; `depth` — the
// rewrite depth of each reference a firing wrote (the pass that wrote it; a
// reference the author wrote has depth 0 and no entry), keyed by identity.
// Mirrors the Julia `_Lowering`.
type lowering struct {
	named map[string]any
	rules []matchRule
	// callRules: the match-less definitions by the defined operator they
	// define, each list in selection order (esm 2.4.0 calls by operator name).
	callRules map[string][]matchRule
	// arities: the operand counts the definitions of each defined operator
	// take (esm-spec §9.6.12 "Arity").
	arities map[string]map[int]bool
	// hidden: the registry entries that are no definition in scope where this
	// context resolves calls (definitionOwners.hiddenAt): reached by
	// references, never by a call here, and counted for no arity.
	hidden map[string]bool
	// owners records which subsystem blocks contributed each merged entry
	// (nil when nothing is mounted); at builds the context a call site at a
	// subsystem path resolves with (definitionScope).
	owners   definitionOwners
	at       func(path string) (*lowering, error)
	shapeEnv map[string][]string
	enums    map[string]map[string]int
	scope    string
	depth    map[uintptr]depthRec
}

func (L *lowering) depthOf(n map[string]any) (int, bool) {
	r, ok := L.depth[reflect.ValueOf(n).Pointer()]
	return r.d, ok
}

func (L *lowering) setDepth(n map[string]any, d int) {
	L.depth[reflect.ValueOf(n).Pointer()] = depthRec{node: n, d: d}
}

// bodyView is how the rewrite engine sees a template body it rewrites for one
// template instance (esm-spec §9.6.4 rule 3): `params` — the template's
// parameters, each a leaf; `lit` — the literal the instance binds to each
// parameter in a structural position; `entries` — each parameter's instance
// entry (instanceEntry), which a `where` `shape` constraint reads. Mirrors the
// Julia `_BodyView`.
type bodyView struct {
	params  map[string]struct{}
	lit     map[string]any
	entries map[string]string
}

func (bv *bodyView) isParam(s string) bool {
	if bv == nil {
		return false
	}
	_, ok := bv.params[s]
	return ok
}

// ruleReference is what a firing of `rule` writes in place of the matched node
// (esm-spec §9.6.3 constraint 7): a reference to the rule bound to what the
// match captured, a parameter the match never bound being bound to its own
// name. A rule whose body is a single leaf writes the leaf (for one of its
// parameters, what that parameter bound): there is no body to share. Mirrors
// the Julia `_rule_reference`.
func ruleReference(rule *matchRule, captured map[string]any) any {
	switch body := rule.body.(type) {
	case map[string]any, []any:
		_ = body
	case string:
		if _, isParam := rule.params[body]; isParam {
			if v, ok := captured[body]; ok {
				return v
			}
			return body
		}
		return body
	default:
		return body
	}
	b := make(map[string]any, len(rule.paramList))
	for _, p := range rule.paramList {
		if v, ok := captured[p]; ok {
			b[p] = v
		} else {
			b[p] = p
		}
	}
	return map[string]any{
		"op":       applyExpressionTemplateOp,
		"args":     []any{},
		"name":     rule.name,
		"bindings": b,
	}
}

// rewriteMemo memoizes one rewritePass over a (possibly structurally shared)
// tree: object nodes are keyed by map pointer identity
// (reflect.ValueOf(m).Pointer()), so a subtree shared under many parents is
// rewritten once per pass and its result re-shared. Keys are taken only from
// the pass's INPUT tree, which stays reachable for the whole pass, so a key
// can never be recycled mid-pass. Memoization is sound because rewriting is
// context-free — a node's rewrite result depends only on the subtree itself.
type rewriteMemo map[uintptr]rewriteMemoEntry

type rewriteMemoEntry struct {
	out     any
	changed bool
}

// rewritePass performs one pre-order (outermost-first) rewrite pass over `node`
// (esm-spec §9.6.3). At each object node the first rule in L.rules (highest
// priority first, ties by declaration order) whose `match` pattern matches the
// node AND whose `where` constraints hold fires; constraint filtering is part
// of match eligibility (§9.6.3 constraint 2). A firing writes a reference to
// the rule (ruleReference, constraint 7), recorded in L.depth at depth `pass`,
// and the walk does not descend into it during this pass. At a reference —
// authored or written — no pattern matches (§9.6.4 rule 4), but the walk
// descends into the values of its `bindings`, which are expressions of the
// call site. `bv` is the template-body view when `node` is a template body
// being rewritten for one instance (§9.6.4 rule 3), nil at a component's
// expression positions. `last` records the name of the last rule that fired.
//
// The pass is IDENTITY-PRESERVING (returns the same map/slice when no rewrite
// fired at or below it — the returned bool doubles as "result is a new
// object") and memoized by pointer identity. Mirrors the Julia `_rewrite_pass`.
func rewritePass(node any, L *lowering, pass int, last *string, bv *bodyView, memo rewriteMemo) (any, bool) {
	switch n := node.(type) {
	case []any:
		var out []any
		for i, c := range n {
			nc, ch := rewritePass(c, L, pass, last, bv, memo)
			if ch && out == nil {
				out = make([]any, len(n))
				copy(out, n[:i])
			}
			if out != nil {
				out[i] = nc
			}
		}
		if out == nil {
			return n, false
		}
		return out, true
	case map[string]any:
		key := reflect.ValueOf(n).Pointer()
		if e, hit := memo[key]; hit {
			return e.out, e.changed
		}
		op, _ := n["op"].(string)
		if op == applyExpressionTemplateOp {
			b, ok := n["bindings"].(map[string]any)
			if !ok {
				memo[key] = rewriteMemoEntry{out: n}
				return n, false
			}
			var nb map[string]any
			for _, bk := range sortedKeys(b) {
				nv, ch := rewritePass(b[bk], L, pass, last, bv, memo)
				if ch {
					if nb == nil {
						nb = cloneMapAny(b)
					}
					nb[bk] = nv
				}
			}
			if nb == nil {
				memo[key] = rewriteMemoEntry{out: n}
				return n, false
			}
			nn := cloneMapAny(n)
			nn["bindings"] = nb
			// The rebuilt reference is the same reference: it keeps its depth.
			if d, ok := L.depthOf(n); ok {
				L.setDepth(nn, d)
			}
			memo[key] = rewriteMemoEntry{out: nn, changed: true}
			return nn, true
		}
		if rule, bindings := selectDefinition(L, n, op, bv); rule != nil {
			*last = rule.name
			r := ruleReference(rule, bindings)
			if rm, ok := r.(map[string]any); ok && isApplyMap(rm) {
				L.setDepth(rm, pass)
			}
			memo[key] = rewriteMemoEntry{out: r, changed: true}
			return r, true
		}
		// No rule fired here — descend into children.
		var out map[string]any
		for _, k := range sortedKeys(n) {
			nv, ch := rewritePass(n[k], L, pass, last, bv, memo)
			if ch {
				if out == nil {
					out = cloneMapAny(n)
				}
				out[k] = nv
			}
		}
		if out == nil {
			memo[key] = rewriteMemoEntry{out: n}
			return n, false
		}
		memo[key] = rewriteMemoEntry{out: out, changed: true}
		return out, true
	default:
		return node, false
	}
}

// rewriteToFixpoint drives rewritePass to a fixpoint (esm-spec §9.6.3): repeat
// pre-order passes until a pass performs zero rewrites, returning the rewritten
// node and the number of productive passes. A rewrite made in pass p has depth
// p; one whose depth would exceed MaxRewritePasses (a productive pass
// MaxRewritePasses+1) rejects the file with `rewrite_rule_nonterminating`
// (§9.6.4 rule 3, "Rewrite depth"). This bound — not a static check — is the
// authoritative termination guard. Mirrors the Julia `_rewrite_to_fixpoint`.
func rewriteToFixpoint(node any, L *lowering, scope string, bv *bodyView) (any, int, error) {
	last := ""
	current := node
	for pass := 1; pass <= MaxRewritePasses+1; pass++ {
		// Fresh memo per pass: a node's rewrite result is pass-local.
		next, changed := rewritePass(current, L, pass, &last, bv, rewriteMemo{})
		current = next
		if !changed {
			return current, pass - 1, nil // fixpoint reached
		}
	}
	return nil, 0, newETErr(
		CodeRewriteRuleNonterminating,
		fmt.Sprintf("%s: expression-template rewriting did not converge within MaxRewritePasses=%d passes (last rule fired '%s'). A `match` rule likely re-introduces its own pattern (esm-spec §9.6.3).", scope, MaxRewritePasses, last),
	)
}

// orderedTemplateNames returns the template names in DECLARATION order. `order`
// (recovered from the order-preserving source JSON) is honoured first; any name
// not present in `order` (e.g. when only an unordered map is available) is
// appended in sorted-name order, so the result is always deterministic. Mirrors
// the Julia reference `_ordered_template_names`.
func orderedTemplateNames(tpl map[string]any, order []string) []string {
	seen := make(map[string]bool, len(tpl))
	names := make([]string, 0, len(tpl))
	for _, n := range order {
		if _, ok := tpl[n]; ok && !seen[n] {
			names = append(names, n)
			seen[n] = true
		}
	}
	rest := make([]string, 0, len(tpl))
	for n := range tpl {
		if !seen[n] {
			rest = append(rest, n)
		}
	}
	sort.Strings(rest)
	return append(names, rest...)
}

// couplingTransformSite is one top-level `coupling` variable_map entry whose
// `transform` is an OBJECT (a widened Expression transform, esm-spec
// §8.6/§10.4/§10.5); idx is its position in the coupling array, used for the
// `coupling[<idx>].transform` diagnostic scope.
type couplingTransformSite struct {
	idx   int
	entry map[string]any
}

// collectCouplingTransformSites assigns each top-level `coupling` entry with
// "type" == "variable_map" and an OBJECT "transform" to its RECEIVING
// component — the first dot-segment of "to", looked up under models first,
// then reaction_systems. The expression transform is rewritten with that
// component's rewrite context (named templates + match rules) exactly like a
// field of the component. Entries whose receiver is not declared are omitted
// and stay unrewritten (a leftover apply_operator there is caught
// by the final gate).
func collectCouplingTransformSites(view map[string]any) map[[2]string][]couplingTransformSite {
	sites := map[[2]string][]couplingTransformSite{}
	coupling, ok := view["coupling"].([]any)
	if !ok {
		return sites
	}
	for idx, entryRaw := range coupling {
		entry, ok := entryRaw.(map[string]any)
		if !ok {
			continue
		}
		if t, _ := entry["type"].(string); t != "variable_map" {
			continue
		}
		if _, isObj := entry["transform"].(map[string]any); !isObj {
			continue
		}
		to, _ := entry["to"].(string)
		recv := to
		if i := strings.Index(to, "."); i >= 0 {
			recv = to[:i]
		}
		if recv == "" {
			continue
		}
		for _, kind := range templateComponentKinds {
			comps, ok := view[kind].(map[string]any)
			if !ok {
				continue
			}
			if _, has := comps[recv]; has {
				key := [2]string{kind, recv}
				sites[key] = append(sites[key], couplingTransformSite{idx: idx, entry: entry})
				break
			}
		}
	}
	return sites
}

// hasTemplateMachinery reports whether `view` declares any non-empty
// `operators` block under models/reaction_systems, or contains any
// `apply_operator` op anywhere. Files with neither need no rewriting.
func hasTemplateMachinery(view map[string]any) bool {
	if view == nil {
		return false
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			compObj, ok := compRaw.(map[string]any)
			if !ok {
				continue
			}
			if tpl, ok := compObj["operators"].(map[string]any); ok && len(tpl) > 0 {
				return true
			}
		}
	}
	return containsApplyOp(view)
}

// containsApplyOp reports whether tree contains any `apply_operator`
// op, stopping at the first occurrence. The walk is pointer-identity-memoized
// (each unique object node visited once) so probing a post-expansion shared
// DAG costs O(unique nodes), not O(denoted tree size).
func containsApplyOp(tree any) bool {
	return containsApplyOpDAG(tree, map[uintptr]struct{}{})
}

func containsApplyOpDAG(tree any, seen map[uintptr]struct{}) bool {
	switch t := tree.(type) {
	case map[string]any:
		key := reflect.ValueOf(t).Pointer()
		if _, dup := seen[key]; dup {
			return false
		}
		seen[key] = struct{}{}
		if op, ok := t["op"].(string); ok && op == applyExpressionTemplateOp {
			return true
		}
		for _, v := range t {
			if containsApplyOpDAG(v, seen) {
				return true
			}
		}
	case []any:
		for _, c := range t {
			if containsApplyOpDAG(c, seen) {
				return true
			}
		}
	}
	return false
}

// findApplyPaths appends the JSON-pointer path of every
// `apply_operator` op in view to hits (used by the leftover gate and
// the pre-v0.4 rejection, which report all offending paths).
func findApplyPaths(view any, path string, hits *[]string) {
	_ = walkJSONTree(view, path, func(p string, v map[string]any) error {
		if op, ok := v["op"].(string); ok && op == applyExpressionTemplateOp {
			*hits = append(*hits, p)
		}
		return nil
	})
}

// recordKeyOrders walks the raw-JSON token stream, recording the key order of
// every object keyed by a JSON-pointer-like path (array indices included). Used
// to recover template DECLARATION order, which a decoded map[string]interface{}
// loses (Go map iteration is unordered).
func recordKeyOrders(dec *json.Decoder, path string, orders map[string][]string) error {
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	if delim, ok := tok.(json.Delim); ok {
		switch delim {
		case '{':
			var keys []string
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return err
				}
				key, _ := kt.(string)
				keys = append(keys, key)
				if err := recordKeyOrders(dec, path+"/"+key, orders); err != nil {
					return err
				}
			}
			if _, err := dec.Token(); err != nil { // consume '}'
				return err
			}
			orders[path] = keys
		case '[':
			i := 0
			for dec.More() {
				if err := recordKeyOrders(dec, fmt.Sprintf("%s/%d", path, i), orders); err != nil {
					return err
				}
				i++
			}
			if _, err := dec.Token(); err != nil { // consume ']'
				return err
			}
		}
	}
	return nil
}

// extractTemplateOrders returns, for each object in `jsonStr`, its key order
// keyed by path (e.g. "/models/m/operators"). Best-effort: on any
// decode hiccup it returns an empty map, and callers fall back to sorted-name
// order.
func extractTemplateOrders(jsonStr string) map[string][]string {
	orders := map[string][]string{}
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	if err := recordKeyOrders(dec, "", orders); err != nil {
		return map[string][]string{}
	}
	return orders
}

var semverRe = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)$`)

// esmVersionBelow reports whether view declares an `esm` version strictly below
// major.minor (patch ignored). A nil view, a missing/non-string `esm`, or an
// unparseable version reports false — the construct-gate callers treat an
// unknown version as "not below" and defer to schema validation. Shared by
// RejectExpressionTemplatesPreV04 and RejectTemplateImportsPreV08.
func esmVersionBelow(view map[string]any, major, minor int) bool {
	if view == nil {
		return false
	}
	esmRaw, ok := view["esm"].(string)
	if !ok {
		return false
	}
	m := semverRe.FindStringSubmatch(esmRaw)
	if m == nil {
		return false
	}
	maj, _ := strconv.Atoi(m[1])
	min, _ := strconv.Atoi(m[2])
	if maj != major {
		return maj < major
	}
	return min < minor
}

// RejectExpressionTemplatesPreV04 rejects `operators` blocks and
// `apply_operator` ops in files declaring `esm` < 0.4.0. Mirrors
// the equivalent TS / Python / Julia / Rust checks.
func RejectExpressionTemplatesPreV04(view map[string]any) error {
	if !esmVersionBelow(view, 0, 4) {
		return nil
	}
	esmRaw, _ := view["esm"].(string)
	offences := []string{}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			compObj, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			if _, has := compObj["operators"]; has {
				offences = append(offences, fmt.Sprintf("/%s/%s/operators", kind, cname))
			}
		}
	}
	findApplyPaths(view, "", &offences)
	if len(offences) > 0 {
		return newETErr(
			CodeApplyExpressionTemplateVersionTooOld,
			fmt.Sprintf("operators / apply_operator require esm >= 0.4.0; file declares %s (offending paths: %s)", esmRaw, strings.Join(offences, ", ")),
		)
	}
	return nil
}

// buildRewriteContext builds the per-component rewrite context from a validated,
// body-composed `operators` map (nil ⇒ an empty context):
//
//   - named — every template keyed by name, consulted by
//     `apply_operator` (order-independent);
//   - rules — the auto-applied `match` rules, sorted highest-priority-first,
//     ties by declaration order (esm-spec §9.6.3).
//
// `order` is the recovered declaration order (nil ⇒ sorted-name fallback);
// `isetNames` is the consuming document's merged index_sets registry, against
// which each rule's `where` shape constraints are resolved at registration
// (esm-spec §9.6.1; `operator_constraint_unknown_index_set`). scope is the
// diagnostic prefix (e.g. "models.M").
func buildRewriteContext(tplMap map[string]any, order []string, isetNames map[string]struct{}, scope string, hidden map[string]bool) (*lowering, error) {
	L := &lowering{named: map[string]any{}, callRules: map[string][]matchRule{}, arities: map[string]map[int]bool{},
		hidden: hidden}
	if tplMap == nil {
		return L, nil
	}
	addArity := func(op string, k int) {
		if L.arities[op] == nil {
			L.arities[op] = map[int]bool{}
		}
		L.arities[op][k] = true
	}
	for idx, name := range orderedTemplateNames(tplMap, order) {
		decl0, _ := tplMap[name].(map[string]any)
		// esm 2.4.0 (esm-spec §9.6.12): every definition records the defined
		// operator it defines; a core operator's name is reserved.
		if err := checkDefinesNotCore(name, decl0, scope); err != nil {
			return nil, err
		}
		decl := decl0
		if _, has := decl0["defines"]; !has {
			decl = withDefines(name, decl0).(map[string]any)
			tplMap[name] = decl
		}
		L.named[name] = decl
		pset := map[string]struct{}{}
		plist := templateParams(decl)
		for _, ps := range plist {
			pset[ps] = struct{}{}
		}
		defines := definitionDefines(name, decl)
		match, ok := decl["match"]
		hasMatch := ok && match != nil
		if !hasMatch && hidden[name] {
			// Another subsystem's definition: reached by its subtree's
			// references, never by a call here (component-local scope).
		} else if !hasMatch {
			addArity(defines, len(plist))
		} else if rop, ok := matchRootOp(decl); ok && !isCoreOp(rop) {
			margs, _ := match.(map[string]any)["args"].([]any)
			addArity(rop, len(margs))
		}
		whereC, err := registeredWhere(decl, isetNames, scope, name)
		if err != nil {
			return nil, err
		}
		if !hasMatch && !hidden[name] && !isCoreOp(defines) && defines != applyExpressionTemplateOp {
			args := make([]any, len(plist))
			for i, p := range plist {
				args[i] = p
			}
			L.callRules[defines] = append(L.callRules[defines], matchRule{
				name:      name,
				paramList: plist,
				pattern:   map[string]any{"op": defines, "args": args},
				params:    pset,
				body:      decl["body"],
				priority:  rulePriority(decl),
				declIdx:   idx,
				whereC:    whereC,
				exact:     true,
			})
		}
		if !hasMatch {
			continue
		}
		L.rules = append(L.rules, matchRule{
			name:      name,
			paramList: plist,
			pattern:   match,
			params:    pset,
			body:      decl["body"],
			priority:  rulePriority(decl),
			declIdx:   idx,
			whereC:    whereC,
		})
	}
	// Deterministic selection order (esm-spec §9.6.3): highest `priority`
	// first, then a definition with a `where` before one without (esm 2.4.0),
	// then declaration order. selectDefinition takes the FIRST eligible one.
	sort.SliceStable(L.rules, func(i, j int) bool { return selectionLess(&L.rules[i], &L.rules[j]) })
	for _, v := range L.callRules {
		sort.SliceStable(v, func(i, j int) bool { return selectionLess(&v[i], &v[j]) })
	}
	return L, nil
}

// LowerExpressionTemplates runs the outermost-first + priority + bounded-fixpoint
// rewrite over `view` and strips the `operators` blocks. Mutates
// `view` in place. Declaration order for `match`-rule tie-breaking is recovered
// via sorted-name fallback (an already-decoded map has no key order); callers
// with the raw JSON string should use the load path (`applyExpressionTemplatesToJSON`),
// which recovers genuine declaration order.
//
// Pre-condition: the input has been schema-validated.
//
// esm-spec §9.6.4 (Option B): lowering itself PRESERVES surviving
// `apply_operator` references and per-component registries; this
// entry point then Expands them in place (RFC out-of-line-expression-templates
// §7.7 Expand-at-build), so callers see the Option-A image (references replaced
// by their expansion, registries stripped) exactly as before. The
// reference-preserving form is available via ResolveAndLowerReferencePreserving
// (raw §9.7 pipeline) or EmitReferencePreserving (canonical emitted bytes).
func LowerExpressionTemplates(view map[string]any) error {
	// Old spellings (esm-spec §9.6.12) when the caller skipped the wire boundary.
	if err := readOldSpellingsView(view); err != nil {
		return err
	}
	if err := lowerExpressionTemplatesOrdered(view, nil); err != nil {
		return err
	}
	expandDocument(view)
	return nil
}

// lowerExpressionTemplatesOrdered is LowerExpressionTemplates with an optional
// `orders` map (path → template declaration order) recovered from the raw JSON.
func lowerExpressionTemplatesOrdered(view map[string]any, orders map[string][]string) error {
	if err := RejectExpressionTemplatesPreV04(view); err != nil {
		return err
	}
	if view == nil {
		return nil
	}
	// Fast path: files with neither an `operators` block nor any
	// `apply_operator` op need no rewriting (strip is a no-op).
	if !hasTemplateMachinery(view) {
		stripExpressionTemplates(view)
		// No expansion to run, but the §9.6.4 expanded-form validator still
		// applies — the raw tree IS the expanded form (esm-spec §4.3.2 makearray
		// bounds).
		return validateMakearrayRegions(view, "")
	}
	// The consuming document's merged index_sets registry (post-§9.7.5): the
	// namespace `where` shape constraints resolve against at registration
	// (esm-spec §9.6.1 — `operator_constraint_unknown_index_set` for a name not
	// declared here).
	isetNames := map[string]struct{}{}
	if isets, ok := view["index_sets"].(map[string]any); ok {
		for k := range isets {
			isetNames[k] = struct{}{}
		}
	}
	// Top-level `coupling` variable_map entries with an OBJECT `transform`
	// (widened Expression transforms) rewrite with the rewrite context of
	// their RECEIVING component; assign each site up front, the rewrite runs
	// inside the per-component loop below where that context is in scope.
	couplingSites := collectCouplingTransformSites(view)
	// Per-component registries (cname → named), captured so the §9.6.9
	// validation discharge can run on the reference-preserving form. Models are
	// registered first; a reaction system never overwrites a same-named model
	// (mirrors the Julia reference `registries`).
	registries := map[string]map[string]any{}
	// The document's `enums` block: rule 3 lowers `enum` ops inside template
	// bodies per instance against it (esm-spec §9.3, §9.6.4 rule 3).
	enums := rawEnumsBlock(view)
	type componentLowering struct {
		comp       map[string]any
		L          *lowering
		transforms []map[string]any
	}
	var lowerings []*componentLowering
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			compObj, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			cscope := fmt.Sprintf("%s.%s", kind, cname)
			// esm-spec §9.6.4 rule 1: a model mounted as a subsystem (or an
			// authored subsystem with its own block) keeps its references and
			// brings its template definitions; they join this component's
			// registry here, before its fixpoint (hoistMountedTemplates).
			owners := hoistMountedTemplates(compObj, cname, "/"+kind+"/"+cname, orders)
			// Static shape environment for `where` constraint evaluation
			// (esm-spec §9.6.1): declared variable shapes only.
			shapeEnv := componentShapeEnv(compObj)
			tplMap, _ := compObj["operators"].(map[string]any)
			if tplMap != nil {
				if err := validateTemplates(tplMap, cscope); err != nil {
					return err
				}
				// Registration-time body CHECKING (esm-spec §9.7.3, Option B):
				// validate the body-reference DAG (acyclic, depth-bounded,
				// references resolve to match-less templates). Bodies are NOT
				// inlined — references are preserved (§9.6.4).
				if err := composeTemplateBodies(tplMap, cscope); err != nil {
					return err
				}
			}
			var order []string
			if orders != nil {
				order = orders["/"+kind+"/"+cname+"/operators"]
			}
			L, err := buildRewriteContext(tplMap, order, isetNames, cscope, owners.hiddenAt(""))
			if err != nil {
				return err
			}
			L.shapeEnv, L.enums, L.scope, L.depth = shapeEnv, enums, cscope, map[uintptr]depthRec{}
			if owners != nil {
				L.owners = owners
				byPath := map[string]*lowering{"": L}
				L.at = func(path string) (*lowering, error) {
					if Lp, ok := byPath[path]; ok {
						return Lp, nil
					}
					Lp, err := buildRewriteContext(tplMap, order, isetNames, cscope, owners.hiddenAt(path))
					if err != nil {
						return nil, err
					}
					// One depth record per component: rule 3 reads it to tell
					// the references a firing wrote.
					Lp.shapeEnv, Lp.enums, Lp.scope, Lp.depth = shapeEnv, enums, cscope, L.depth
					byPath[path] = Lp
					return Lp, nil
				}
			}
			named, rules := L.named, L.rules
			// Outermost-first, priority-ordered, bounded-fixpoint rewrite per
			// non-template field (esm-spec §9.6.3): each firing writes a
			// reference to its rule (constraint 7); references are leaves for
			// matching and the walk descends into their bindings (§9.6.4 rule
			// 4). The `operators` block is RETAINED (§9.6.4 rule 1).
			for _, k := range sortedKeys(compObj) {
				if k == "operators" || k == "operator_imports" {
					continue
				}
				scope := fmt.Sprintf("%s.%s.%s", kind, cname, k)
				if k == "subsystems" && L.owners != nil {
					if err := rewriteSubsystemsScoped(compObj[k], "", L, scope); err != nil {
						return err
					}
					continue
				}
				rewritten, _, err := rewriteToFixpoint(compObj[k], L, scope, nil)
				if err != nil {
					return err
				}
				compObj[k] = rewritten
			}
			cl := &componentLowering{comp: compObj, L: L}
			// Expression transforms of variable_map coupling entries whose
			// receiving component is this one rewrite to fixpoint with the
			// same context, as if they were a field of the component (esm-spec
			// §10.4). A template-less receiver leaves the transform unrewritten.
			if len(named) > 0 || len(rules) > 0 || len(L.callRules) > 0 {
				for _, site := range couplingSites[[2]string{kind, cname}] {
					scope := fmt.Sprintf("coupling[%d].transform", site.idx)
					rewritten, _, err := rewriteToFixpoint(site.entry["transform"], L, scope, nil)
					if err != nil {
						return err
					}
					site.entry["transform"] = rewritten
					cl.transforms = append(cl.transforms, site.entry)
				}
			}
			lowerings = append(lowerings, cl)
			if _, dup := registries[cname]; !dup {
				registries[cname] = named
			}
		}
	}
	// esm-spec §9.6.4 rule 3: the rules apply inside the bodies of the
	// templates the references reach, once per template instance, without
	// expanding any reference. Then the call-site checks on surviving
	// references (§9.6.9): unknown name / bindings mismatch, against the
	// registry as rule 3 left it.
	for _, cl := range lowerings {
		if err := applyRule3(cl.comp, cl.L, cl.transforms); err != nil {
			return err
		}
		for _, k := range sortedKeys(cl.comp) {
			if k == "operators" || k == "operator_imports" {
				continue
			}
			if err := checkSurvivingRefs(cl.comp[k], cl.L.named, cl.L.scope+"."+k); err != nil {
				return err
			}
		}
		for _, entry := range cl.transforms {
			if err := checkSurvivingRefs(entry["transform"], cl.L.named, cl.L.scope+" coupling transform"); err != nil {
				return err
			}
		}
		// esm-spec §9.6.12 "Arity": surviving calls in the component, in the
		// transforms it receives, and in the bodies its references reach.
		if err := checkComponentArity(cl.comp, cl.L, cl.transforms); err != nil {
			return err
		}
	}
	// esm-spec §9.6.4 rule 1 (Option B): surviving `apply_operator`
	// references are the NEW NORMAL. Only unknown-name / bindings-mismatch
	// references are errors — already checked per component / per transform by
	// checkSurvivingRefs. No global "no apply ops remain" gate.
	//
	// Validation discharge (esm-spec §9.6.9): region bounds cannot carry
	// template params, so the makearray check runs on the reference-preserving
	// tree AND the retained folded template bodies.
	if err := validateMakearrayRegions(view, ""); err != nil {
		return err
	}
	return validateMakearrayRegionsInRegistries(registries)
}

// rewriteSubsystemsScoped rewrites each subsystem below a component whose
// registry holds subsystem blocks (L.owners) with the context of its own path:
// a call there resolves to, and an arity counts, only the definitions the
// component or a subsystem on the path to it owns (esm-spec §9.6.3
// constraint 4, §9.6.12).
func rewriteSubsystemsScoped(subsRaw any, prefix string, L *lowering, scope string) error {
	subs, ok := subsRaw.(map[string]any)
	if !ok {
		return nil
	}
	for _, k := range sortedKeys(subs) {
		path := k
		if prefix != "" {
			path = prefix + "." + k
		}
		sub, ok := subs[k].(map[string]any)
		if !ok {
			rewritten, _, err := rewriteToFixpoint(subs[k], L, scope+"."+k, nil)
			if err != nil {
				return err
			}
			subs[k] = rewritten
			continue
		}
		Lp, err := L.at(path)
		if err != nil {
			return err
		}
		for _, f := range sortedKeys(sub) {
			fscope := scope + "." + k + "." + f
			if f == "subsystems" {
				if err := rewriteSubsystemsScoped(sub[f], path, L, fscope); err != nil {
					return err
				}
				continue
			}
			rewritten, _, err := rewriteToFixpoint(sub[f], Lp, fscope, nil)
			if err != nil {
				return err
			}
			sub[f] = rewritten
		}
	}
	return nil
}

func stripExpressionTemplates(view map[string]any) {
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			if compObj, ok := compRaw.(map[string]any); ok {
				delete(compObj, "operators")
			}
		}
	}
}

// applyExpressionTemplatesToJSON rewrites a JSON document, performing the
// load-time expression-template rewrite (outermost-first + priority + bounded
// fixpoint). Returns the rewritten JSON; the input is not modified.
//
// Used by the Go binding's load path: schema validation runs against the
// original JSON, then this rewrite produces the post-rewrite JSON used to
// unmarshal into the typed struct. Template declaration order is recovered from
// the raw JSON so `match`-rule tie-breaking is byte-identical to the reference.
func applyExpressionTemplatesToJSON(jsonStr string) (string, error) {
	var view map[string]any
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		return "", fmt.Errorf("apply_operator pass: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
	if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
		return "", err
	}
	// Expand-at-build (§9.6.4 rule 2 / RFC §7.7): the typed load path sees the
	// Option-A image so downstream numeric behavior stays bit-identical.
	expandDocument(view)
	out, err := json.Marshal(view)
	if err != nil {
		return "", fmt.Errorf("apply_operator pass: re-marshal: %w", err)
	}
	return string(out), nil
}

// resolveAndLowerJSON is applyExpressionTemplatesToJSON preceded by the
// esm-spec §9.7 load-time resolution (template_imports.go): template-library
// imports resolve depth-first post-order against `basePath` with per-edge
// metaparameter instantiation, imported index_sets merge, and the document's
// metaparameters close (edge bindings > loader-API `metaparameters` > their
// `default`s) and fold — then the §9.6.3 rewrite fixpoint runs on the
// resolved view. The resolver publishes each component's §9.7.4 effective
// template sequence into the declaration-order map, so `match`-rule
// tie-breaking honours imports-then-locals order. Returns the rewritten JSON;
// the input is not modified.
func resolveAndLowerJSON(jsonStr, basePath string, metaparameters map[string]int64) (string, error) {
	// nil: this entry point is handed raw text with no authored set captured for
	// it, so the §4.7 mount context is computed from that text below.
	out, _, err := resolveAndLowerJSONCapturing(jsonStr, basePath, metaparameters, nil, nil)
	return out, err
}

// resolveAndLowerJSONCapturing is resolveAndLowerJSON that ALSO returns each
// component's `operators` block as it stood after import resolution
// and before Expand-at-build stripped it, keyed "models.<name>" /
// "reaction_systems.<name>" with the resolved declaration order preserved.
//
// The merged template registry is a normative field of the flattened
// representation (esm-libraries-spec §4.7.5 step 4), and Expand-at-build
// deletes exactly the inputs that merge needs. Capturing them here is the only
// point at which they still exist: `expandDocument` runs two lines below.
//
// `authoredOrders` (may be nil) is the document's authored key-order table when
// jsonStr is a re-encoding (a root whose §4.7 mounts were inlined, whose keys
// the encoder sorted): it overlays the order read off jsonStr, so the lowering
// and the registry merge of a mounting component see declaration order.
func resolveAndLowerJSONCapturing(jsonStr, basePath string, metaparameters map[string]int64,
	authoredMountDeclared map[string]bool, authoredOrders map[string][]string) (string, map[string]*orderedMap, error) {
	out, ct, _, err := resolveAndLowerJSONCapturingUnits(jsonStr, basePath, metaparameters, authoredMountDeclared, authoredOrders)
	return out, ct, err
}

// resolveAndLowerJSONCapturingUnits is resolveAndLowerJSONCapturing that also
// returns the reference-preserving form of the model equations whose
// references reach a unit-bearing definition (captureLoweredUnitEquations),
// taken before Expand-at-build.
func resolveAndLowerJSONCapturingUnits(jsonStr, basePath string, metaparameters map[string]int64,
	authoredMountDeclared map[string]bool, authoredOrders map[string][]string) (string, map[string]*orderedMap, map[string]loweredUnitEquation, error) {
	// Old spellings (esm-spec §9.6.12) when the caller skipped the wire
	// boundary; text a load already prepared passes through unchanged.
	jsonStr, err := readOldSpellings(jsonStr)
	if err != nil {
		return "", nil, nil, err
	}
	var view map[string]any
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		return "", nil, nil, fmt.Errorf("template resolution pass: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
	for p, keys := range authoredOrders {
		orders[p] = keys
	}
	// esm-spec §9.7.10 form B: fold any coupling-entry injection into the target
	// components' own `operator_imports` BEFORE resolution, so the
	// ordinary import resolver + §9.6.3 fixpoint lower the target under the
	// assembler-chosen discretization. No-op when no coupling entry carries an
	// injection map.
	if err := applyCouplingInjections(view); err != nil {
		return "", nil, nil, err
	}
	// The §4.7 mount context of a ROOT document. `LoadString` computed it on the
	// AUTHORED text and hands it in, because the walk reads unresolved `{ref}`
	// edges and `view` here may already have had its refs resolved. Recomputed
	// only for the callers that have no authored set to give (the guard inside
	// keeps a load with neither loader-API bindings nor an `extent` off the
	// filesystem entirely).
	mountDeclared := authoredMountDeclared
	if mountDeclared == nil {
		md, err := rootMountContext(view, basePath, metaparameters)
		if err != nil {
			return "", nil, nil, err
		}
		mountDeclared = md
	}
	if _, err := resolveTemplateMachinery(view, orders, basePath, metaparameters,
		resolveOpts{mountDeclared: mountDeclared}); err != nil {
		return "", nil, nil, err
	}
	if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
		return "", nil, nil, err
	}
	componentTemplates := captureComponentTemplates(view, orders, jsonStr)
	loweredUnits := captureLoweredUnitEquations(view)
	// Expand-at-build (§9.6.4 rule 2 / RFC §7.7): the raw §9.7 pipeline emits the
	// Option-A image (references replaced by their expansion, registries
	// stripped) so external conformance runners reproduce the expanded goldens.
	expandDocument(view)
	out, err := json.Marshal(view)
	if err != nil {
		return "", nil, nil, fmt.Errorf("template resolution pass: re-marshal: %w", err)
	}
	return string(out), componentTemplates, loweredUnits, nil
}

// captureComponentTemplates snapshots every component's `operators`
// block, keyed "<section>.<component>", in the DOCUMENT order the components
// are declared in, each block as emit materializes it (esm-spec §9.6.4 rule 5,
// materializeComponentBlock): the entries authored in `source` first, in
// authored order, then the closure of the component's surviving references,
// sorted — the typed load path's registry, as the Julia
// `_materialize_components!` gives it. Components with an empty block are
// omitted, so the common document yields an empty map and flatten's registry
// merge is a no-op.
func captureComponentTemplates(view map[string]any, orders map[string][]string, source string) map[string]*orderedMap {
	out := map[string]*orderedMap{}
	var authored map[string][]string
	if origView, err := decodeJSONView([]byte(source)); err == nil {
		authored = authoredTemplateNames(origView, extractTemplateOrders(source))
	}
	received := receivedTransformRefs(view)
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range orderedKeysOf(comps, orders["/"+kind]) {
			comp, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			if tpl, ok := comp["operators"].(map[string]any); !ok || len(tpl) == 0 {
				continue
			}
			mat, _, _ := materializeComponentBlock(
				comp, authored[kind+"."+cname], received[[2]string{kind, cname}])
			if mat.len() == 0 {
				continue
			}
			block := newOrderedMap()
			for _, n := range mat.keys {
				block.set(n, deepCopyJSON(mat.get(n)))
			}
			out[kind+"."+cname] = block
		}
	}
	return out
}

// ResolveAndLower is the exported raw §9.7 pipeline — resolveAndLowerJSON
// verbatim: load-time template-import/metaparameter resolution against
// basePath, then the §9.6.3 rewrite fixpoint AND Expand-at-build, returning the
// post-lowering Option-A image as JSON (numeric tokens preserved via
// json.Number). This is the entry point that reproduces the committed
// `expanded.esm` goldens (CONFORMANCE_SPEC.md §5.9) without going through the
// typed Load round-trip, whose serializer normalizes fields.
//
// It is NOT the right entry point for a conformance runner that must be
// compared against the other four bindings: they all stop at the Option-B
// image, and expansion multiplies out a reference-dense document. Use
// ResolveAndLowerReferencePreserving, of which this is Expand ∘ that.
func ResolveAndLower(jsonStr, basePath string, metaparameters map[string]int64) (string, error) {
	// Old spellings (esm-spec §9.6.12) when the caller skipped the wire boundary.
	jsonStr, err := readOldSpellings(jsonStr)
	if err != nil {
		return "", err
	}
	return resolveAndLowerJSON(jsonStr, basePath, metaparameters)
}

// ResolveAndLowerReferencePreserving is the raw §9.7 pipeline WITHOUT the
// Expand-at-build step: load-time template-import/metaparameter resolution
// against basePath, §9.7.10 form-B coupling injection, then the §9.6.3 rewrite
// fixpoint — stopping at the Option-B image. Surviving
// `apply_operator` references stay as leaves (§9.6.4 rule 4) and
// each component keeps its `operators` registry (rule 5). Returns
// the post-lowering document as JSON, numeric tokens preserved via json.Number.
//
// This is what a conformance runner should drive to produce an artifact
// COMPARABLE WITH THE OTHER FOUR BINDINGS. The Julia reference, Python
// (`resolve_template_machinery` → `lower_expression_templates`), TypeScript
// (`resolveTemplateMachinery` → `lowerExpressionTemplates`) and Rust all stop
// here; only Go's fused ResolveAndLower went on to Expand, so Go alone emitted
// the Option-A image and could not be compared to the other four structurally.
//
// It is also the only pipeline that TERMINATES on a reference-dense document.
// Expansion is what Option B exists to avoid: it substitutes each reference's
// body at every call site, so a document whose templates reference templates
// multiplies out. EarthSciDiscretizations' `duo_*` cases were OOM-killed past
// 9 GB going through ResolveAndLower, which is why the Go runner had no output
// to compare at all on that family.
//
// ResolveAndLower remains the Option-A surface: it is this function followed
// by Expand, and reproduces the committed `expanded.esm` goldens. Prefer this
// one unless you specifically need the expanded image.
func ResolveAndLowerReferencePreserving(jsonStr, basePath string, metaparameters map[string]int64) (string, error) {
	view, err := loadOptionB(jsonStr, basePath, metaparameters)
	if err != nil {
		return "", err
	}
	out, err := json.Marshal(view)
	if err != nil {
		return "", fmt.Errorf("template resolution pass: re-marshal: %w", err)
	}
	return string(out), nil
}
