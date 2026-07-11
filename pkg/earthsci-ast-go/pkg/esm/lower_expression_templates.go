package esm

// Load-time rewrite pass for `expression_templates` (esm-spec §9.6,
// docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md).
//
// Each `expression_templates` entry is a rewrite rule with `params`
// (metavariables) and a `body` (replacement Expression), applied in one of two
// ways:
//
//   - WITHOUT a `match` field — invoked explicitly by an
//     `apply_expression_template` node whose `bindings` supply each param's AST
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
// node the engine first tries to fire a rule AT that node before descending: an
// `apply_expression_template` op is expanded, otherwise the structurally-matching
// `match` rule of highest `priority` (int, default 0; ties by declaration order)
// fires. A fired rule's body replaces the node and the walk does NOT descend into
// that freshly-produced body during the current pass. Passes repeat until a pass
// performs zero rewrites (the fixpoint) or until MaxRewritePasses productive
// passes have run without converging, in which case the file is rejected with
// `rewrite_rule_nonterminating` (the pass bound — not a static check — is the
// authoritative termination guard). After convergence the tree contains no
// `apply_expression_template` ops and no `expression_templates` blocks — Option A
// round-trip. Any rewrite-target op (e.g. a spatial `D`) that survives the
// fixpoint into an evaluation position is caught later by the `unlowered_operator`
// gate (see Evaluate), not here.
//
// Operates on the pre-deserialization `map[string]interface{}` view, so it
// must run after schema validation but before unmarshaling into the
// `ESMFile` struct.

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const applyExpressionTemplateOp = "apply_expression_template"

// Geometry-kernel ops whose `manifold` scalar field is restricted to the
// closed manifold registry (CONFORMANCE_SPEC §5.8.4). The document schema
// admits any string in the `manifold` position so a template `body` can carry
// a parameter name there (esm-spec §9.6.1 scalar-field substitution site); the
// closed set is enforced by validateGeometryManifolds on the EXPANDED form per
// esm-spec §9.6.4.
var geometryManifoldOps = map[string]struct{}{
	"intersect_polygon":         {},
	"polygon_intersection_area": {},
}

var geometryManifoldValues = map[string]struct{}{
	"planar":    {},
	"spherical": {},
	"geodesic":  {},
}

// validateGeometryManifolds is the post-expansion validator (esm-spec §9.6.4):
// every `intersect_polygon` / `polygon_intersection_area` node OUTSIDE an
// `expression_templates` block must carry a `manifold` drawn from the closed
// set {planar, spherical, geodesic}. Template bodies are skipped — a parameter
// name in the `manifold` position of a `body` is a legal scalar-field
// substitution site (esm-spec §9.6.1); by the time this validator runs on a
// loaded document every such site has been substituted, so an out-of-set value
// here is a real defect (e.g. a template invocation binding the manifold
// parameter to a non-member literal). Returns an *ExpressionTemplateError with
// code `geometry_manifold_invalid`.
func validateGeometryManifolds(tree any, path string) error {
	// Pre-substitution template trees may legally carry a param name in the
	// manifold position (esm-spec §9.6.1), so `expression_templates` is skipped.
	return walkJSONTreeSkipping(tree, path, expressionTemplatesSkip, func(p string, t map[string]any) error {
		op, ok := t["op"].(string)
		if !ok {
			return nil
		}
		if _, geomOp := geometryManifoldOps[op]; !geomOp {
			return nil
		}
		m, present := t["manifold"]
		if !present {
			return nil
		}
		ms, isStr := m.(string)
		if _, member := geometryManifoldValues[ms]; !isStr || !member {
			return newETErr(
				"geometry_manifold_invalid",
				fmt.Sprintf("%s: `%s` carries manifold %#v, not a member of the closed set {planar, spherical, geodesic}. The manifold enum is enforced on the expanded form (esm-spec §9.6.4; CONFORMANCE_SPEC §5.8.4) — a template parameter substituted into this scalar field must be bound to one of the closed-set literals.", p, op, m),
			)
		}
		return nil
	})
}

// expressionTemplatesSkip is the skip-set the §9.6.4 expanded-form validators
// pass to walkJSONTreeSkipping so they do NOT descend into pre-substitution
// `expression_templates` bodies (which may legally carry parameter names in
// scalar slots).
var expressionTemplatesSkip = map[string]struct{}{"expression_templates": {}}

// MaxRewritePasses is the maximum number of productive rewrite passes before a
// file is rejected as non-converging (esm-spec §9.6.3, diagnostic
// `rewrite_rule_nonterminating`). Pinned identically across all bindings so the
// accept/reject decision — and the resulting fixpoint — is byte-identical
// everywhere.
const MaxRewritePasses = 64

// ExpressionTemplateError is the error type raised by the expression-template
// expansion pass. The Code field carries one of the stable diagnostic codes:
//
//   - apply_expression_template_unknown_template
//   - apply_expression_template_bindings_mismatch
//   - apply_expression_template_recursive_body
//   - apply_expression_template_invalid_declaration
//   - apply_expression_template_version_too_old
//   - rewrite_rule_nonterminating
//
// or one of the esm-spec §9.7 template-library / metaparameter codes
// (§9.6.6, raised from template_imports.go and subsystem_ref.go):
//
//   - template_import_version_too_old
//   - template_import_unresolved
//   - template_import_not_library
//   - subsystem_ref_is_template_library
//   - template_import_cycle
//   - template_import_name_conflict
//   - template_import_unknown_name
//   - template_import_index_set_conflict
//   - template_body_expansion_too_deep
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
//   - template_import_is_coupling_library
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
}

func (e *ExpressionTemplateError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

func newETErr(code, msg string) *ExpressionTemplateError {
	return &ExpressionTemplateError{Code: code, Message: msg}
}

// assertNoNestedApply rejects `apply_expression_template` nodes inside a
// `match` pattern (esm-spec §9.7.3: match patterns MUST NOT reference
// templates).
func assertNoNestedApply(body any, templateName, path string) error {
	// walkJSONTree descends objects in sorted-key order, so the surfaced error
	// is deterministic across runs (Go map iteration is randomized).
	return walkJSONTree(body, path, func(p string, b map[string]any) error {
		if op, ok := b["op"].(string); ok && op == applyExpressionTemplateOp {
			return newETErr(
				"apply_expression_template_invalid_declaration",
				fmt.Sprintf("expression_templates.%s: `match` contains an 'apply_expression_template' node at %s; match patterns MUST NOT reference templates (esm-spec §9.7.3)", templateName, p),
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
				"apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: entry must be an object with params + body", scope, name),
			)
		}
		// `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
		// template is a named constant fragment (common in library files).
		paramsRaw, ok := declObj["params"].([]any)
		if !ok {
			return newETErr(
				"apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: 'params' must be an array of strings", scope, name),
			)
		}
		seen := make(map[string]struct{})
		for _, p := range paramsRaw {
			ps, ok := p.(string)
			if !ok || ps == "" {
				return newETErr(
					"apply_expression_template_invalid_declaration",
					fmt.Sprintf("%s.expression_templates.%s: param names must be non-empty strings", scope, name),
				)
			}
			if _, exists := seen[ps]; exists {
				return newETErr(
					"apply_expression_template_invalid_declaration",
					fmt.Sprintf("%s.expression_templates.%s: param '%s' declared twice", scope, name, ps),
				)
			}
			seen[ps] = struct{}{}
		}
		if _, ok := declObj["body"]; !ok {
			return newETErr(
				"apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: 'body' is required", scope, name),
			)
		}
		// A body MAY reference other match-less in-scope templates via
		// apply_expression_template nodes (esm-spec §9.7.3); those are checked
		// (acyclic, depth <= MaxTemplateExpansionDepth) and inlined at
		// registration by composeTemplateBodies — the old any-nesting
		// rejection is now cycle-only (`apply_expression_template_recursive_body`).
		// esm-spec §9.6: an optional `match` pattern turns the entry into an
		// auto-applied rewrite rule. The pattern is an Expression whose declared
		// params are wildcards; it MUST NOT contain nested
		// apply_expression_template ops. Nontermination is NOT checked statically
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
// `where` match-scoping block (esm-spec §9.6.1, 0.8.0): `where` is admissible
// only alongside `match`; it must be a non-empty object mapping declared params
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
	if !hasMatch || matchRaw == nil {
		return newETErr("apply_expression_template_invalid_declaration",
			fmt.Sprintf("%s.expression_templates.%s: 'where' is only admissible alongside 'match' — constraints scope an auto-applied rewrite rule, not a named fragment (esm-spec §9.6.1)", scope, name))
	}
	whr, ok := whrRaw.(map[string]any)
	if !ok || len(whr) == 0 {
		return newETErr("apply_expression_template_invalid_declaration",
			fmt.Sprintf("%s.expression_templates.%s: 'where' must be a non-empty object mapping declared params to constraint objects", scope, name))
	}
	for _, p := range sortedKeys(whr) {
		if _, isParam := seen[p]; !isParam {
			return newETErr("apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: 'where' constrains '%s', which is not a declared param (esm-spec §9.6.1)", scope, name, p))
		}
		cobj, ok := whr[p].(map[string]any)
		if !ok {
			return newETErr("apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: where.%s must be a constraint object (v1 admits exactly the 'shape' kind)", scope, name, p))
		}
		ckeys := sortedKeys(cobj)
		if len(ckeys) != 1 || ckeys[0] != "shape" {
			return newETErr("apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: where.%s carries constraint kind(s) %s; the v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)", scope, name, p, strings.Join(ckeys, ", ")))
		}
		shp, ok := cobj["shape"].([]any)
		if !ok || len(shp) == 0 {
			return newETErr("apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: where.%s.shape must be a non-empty array of index-set names", scope, name, p))
		}
		for _, s := range shp {
			if ss, ok := s.(string); !ok || ss == "" {
				return newETErr("apply_expression_template_invalid_declaration",
					fmt.Sprintf("%s.expression_templates.%s: where.%s.shape entries must be non-empty strings", scope, name, p))
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

func substituteParams(body any, bindings map[string]any) any {
	switch b := body.(type) {
	case string:
		if v, ok := bindings[b]; ok {
			return deepCopyJSON(v)
		}
		return body
	case []any:
		out := make([]any, len(b))
		for i, c := range b {
			out[i] = substituteParams(c, bindings)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(b))
		for k, v := range b {
			out[k] = substituteParams(v, bindings)
		}
		return out
	default:
		return body
	}
}

func expandApply(node map[string]any, templates map[string]any, scope string) (any, error) {
	nameRaw, ok := node["name"].(string)
	if !ok || nameRaw == "" {
		return nil, newETErr(
			"apply_expression_template_invalid_declaration",
			fmt.Sprintf("%s: apply_expression_template node missing or empty 'name'", scope),
		)
	}
	declRaw, ok := templates[nameRaw]
	if !ok {
		return nil, newETErr(
			"apply_expression_template_unknown_template",
			fmt.Sprintf("%s: apply_expression_template references undeclared template '%s'", scope, nameRaw),
		)
	}
	decl, ok := declRaw.(map[string]any)
	if !ok {
		return nil, newETErr(
			"apply_expression_template_invalid_declaration",
			fmt.Sprintf("%s: template '%s' declaration is not an object", scope, nameRaw),
		)
	}
	bindingsRaw, ok := node["bindings"].(map[string]any)
	if !ok {
		return nil, newETErr(
			"apply_expression_template_bindings_mismatch",
			fmt.Sprintf("%s: apply_expression_template '%s' missing 'bindings' object", scope, nameRaw),
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
				"apply_expression_template_bindings_mismatch",
				fmt.Sprintf("%s: apply_expression_template '%s' missing binding for param '%s'", scope, nameRaw, p),
			)
		}
	}
	for k := range bindingsRaw {
		if _, ok := declared[k]; !ok {
			return nil, newETErr(
				"apply_expression_template_bindings_mismatch",
				fmt.Sprintf("%s: apply_expression_template '%s' supplies unknown param '%s'", scope, nameRaw, k),
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
func matchPattern(pattern, node any, params map[string]struct{}, bindings map[string]any) bool {
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
			if !matchPattern(pa[i], na[i], params, bindings) {
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
			if !matchPattern(pv, nv, params, bindings) {
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
func whereSatisfied(whereC map[string][]string, bindings map[string]any, shapeEnv map[string][]string) bool {
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
// (`isetNames`). An unknown name is `template_constraint_unknown_index_set`
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
				return nil, newETErr("template_constraint_unknown_index_set",
					fmt.Sprintf("%s.expression_templates.%s: where.%s.shape names index set '%s', which the consuming document's index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)", scope, tname, p, s))
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
	// `expression_templates` is skipped.
	return walkJSONTreeSkipping(tree, path, expressionTemplatesSkip, func(p string, t map[string]any) error {
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
					return newETErr("makearray_region_inverted",
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
	pattern  any
	params   map[string]struct{}
	body     any
	priority int
	declIdx  int
	// whereC is the registered `where` shape-constraint map (param → required
	// shape); nil when the rule carries no `where` block (esm-spec §9.6.1).
	whereC map[string][]string
}

// rewritePass performs one pre-order (outermost-first) rewrite pass over `node`
// (esm-spec §9.6.3). At each object node the engine first tries to fire a rule AT
// the node before descending: (1) an `apply_expression_template` op is expanded,
// OR (2) the first rule in `rules` (pre-sorted highest-priority-first, ties by
// declaration order) whose `match` pattern structurally matches the node fires.
// A fired rule's body replaces the node and the walk does NOT descend into that
// freshly-produced body during this pass. Otherwise it descends into children.
// The returned bool is true iff any rewrite occurred; `last` records the op of
// the most recent rewrite, for the non-convergence diagnostic.
func rewritePass(node any, named map[string]any, rules []matchRule, scope string, last *string, shapeEnv map[string][]string) (any, bool, error) {
	switch n := node.(type) {
	case []any:
		changed := false
		out := make([]any, len(n))
		for i, c := range n {
			nc, ch, err := rewritePass(c, named, rules, scope, last, shapeEnv)
			if err != nil {
				return nil, false, err
			}
			out[i] = nc
			changed = changed || ch
		}
		return out, changed, nil
	case map[string]any:
		op, _ := n["op"].(string)
		// (1) Outermost-first: fire a rule AT this node before descending.
		if op == applyExpressionTemplateOp {
			*last = applyExpressionTemplateOp
			expanded, err := expandApply(n, named, scope)
			if err != nil {
				return nil, false, err
			}
			return expanded, true, nil
		}
		for i := range rules {
			bindings := map[string]any{}
			// Constraint filtering is part of match ELIGIBILITY (esm-spec
			// §9.6.3 constraint 2): a `where`-excluded rule is treated exactly
			// like a non-matching rule, so the scan proceeds to the next
			// candidate in priority / declaration order.
			if matchPattern(rules[i].pattern, n, rules[i].params, bindings) &&
				whereSatisfied(rules[i].whereC, bindings, shapeEnv) {
				*last = op
				return substituteParams(rules[i].body, bindings), true, nil
			}
		}
		// (2) No rule fired here — descend into children.
		changed := false
		out := make(map[string]any, len(n))
		for k, v := range n {
			nv, ch, err := rewritePass(v, named, rules, scope, last, shapeEnv)
			if err != nil {
				return nil, false, err
			}
			out[k] = nv
			changed = changed || ch
		}
		return out, changed, nil
	default:
		return node, false, nil
	}
}

// rewriteToFixpoint drives rewritePass to a fixpoint (esm-spec §9.6.3): repeat
// pre-order passes until a pass performs zero rewrites, or reject the file with
// `rewrite_rule_nonterminating` once MaxRewritePasses productive passes have run
// without converging. This bound — not a static check — is the authoritative
// termination guard.
func rewriteToFixpoint(node any, named map[string]any, rules []matchRule, scope string, shapeEnv map[string][]string) (any, error) {
	last := ""
	current := node
	for pass := 0; pass < MaxRewritePasses; pass++ {
		next, changed, err := rewritePass(current, named, rules, scope, &last, shapeEnv)
		if err != nil {
			return nil, err
		}
		current = next
		if !changed {
			return current, nil // fixpoint reached
		}
	}
	return nil, newETErr(
		"rewrite_rule_nonterminating",
		fmt.Sprintf("%s: expression-template rewriting did not converge within MaxRewritePasses=%d passes (last rewritten op '%s'). A `match` rule likely re-introduces its own pattern (esm-spec §9.6.3).", scope, MaxRewritePasses, last),
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
// and stay unrewritten (a leftover apply_expression_template there is caught
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
// `expression_templates` block under models/reaction_systems, or contains any
// `apply_expression_template` op anywhere. Files with neither need no rewriting.
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
			if tpl, ok := compObj["expression_templates"].(map[string]any); ok && len(tpl) > 0 {
				return true
			}
		}
	}
	return containsApplyOp(view)
}

// errStopWalk is a sentinel returned by a walkJSONTree visitor to halt the walk
// early (the presence probe below only needs the first hit, not every path).
var errStopWalk = errors.New("stop walk")

// containsApplyOp reports whether tree contains any `apply_expression_template`
// op, stopping at the first occurrence.
func containsApplyOp(tree any) bool {
	err := walkJSONTree(tree, "", func(_ string, obj map[string]any) error {
		if op, ok := obj["op"].(string); ok && op == applyExpressionTemplateOp {
			return errStopWalk
		}
		return nil
	})
	return errors.Is(err, errStopWalk)
}

// findApplyPaths appends the JSON-pointer path of every
// `apply_expression_template` op in view to hits (used by the leftover gate and
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
// keyed by path (e.g. "/models/m/expression_templates"). Best-effort: on any
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

// RejectExpressionTemplatesPreV04 rejects `expression_templates` blocks and
// `apply_expression_template` ops in files declaring `esm` < 0.4.0. Mirrors
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
			if _, has := compObj["expression_templates"]; has {
				offences = append(offences, fmt.Sprintf("/%s/%s/expression_templates", kind, cname))
			}
		}
	}
	findApplyPaths(view, "", &offences)
	if len(offences) > 0 {
		return newETErr(
			"apply_expression_template_version_too_old",
			fmt.Sprintf("expression_templates / apply_expression_template require esm >= 0.4.0; file declares %s. Offending paths: %s", esmRaw, strings.Join(offences, ", ")),
		)
	}
	return nil
}

// buildRewriteContext builds the per-component rewrite context from a validated,
// body-composed `expression_templates` map (nil ⇒ an empty context):
//
//   - named — every template keyed by name, consulted by
//     `apply_expression_template` (order-independent);
//   - rules — the auto-applied `match` rules, sorted highest-priority-first,
//     ties by declaration order (esm-spec §9.6.3).
//
// `order` is the recovered declaration order (nil ⇒ sorted-name fallback);
// `isetNames` is the consuming document's merged index_sets registry, against
// which each rule's `where` shape constraints are resolved at registration
// (esm-spec §9.6.1; `template_constraint_unknown_index_set`). scope is the
// diagnostic prefix (e.g. "models.M").
func buildRewriteContext(tplMap map[string]any, order []string, isetNames map[string]struct{}, scope string) (map[string]any, []matchRule, error) {
	named := map[string]any{}
	var rules []matchRule
	if tplMap == nil {
		return named, rules, nil
	}
	for idx, name := range orderedTemplateNames(tplMap, order) {
		decl, _ := tplMap[name].(map[string]any)
		named[name] = decl
		match, ok := decl["match"]
		if !ok || match == nil {
			continue
		}
		pset := map[string]struct{}{}
		if pr, ok := decl["params"].([]any); ok {
			for _, p := range pr {
				if ps, ok := p.(string); ok {
					pset[ps] = struct{}{}
				}
			}
		}
		whereC, err := registeredWhere(decl, isetNames, scope, name)
		if err != nil {
			return nil, nil, err
		}
		rules = append(rules, matchRule{
			pattern:  match,
			params:   pset,
			body:     decl["body"],
			priority: rulePriority(decl),
			declIdx:  idx,
			whereC:   whereC,
		})
	}
	sort.SliceStable(rules, func(i, j int) bool {
		if rules[i].priority != rules[j].priority {
			return rules[i].priority > rules[j].priority
		}
		return rules[i].declIdx < rules[j].declIdx
	})
	return named, rules, nil
}

// LowerExpressionTemplates runs the outermost-first + priority + bounded-fixpoint
// rewrite over `view` and strips the `expression_templates` blocks. Mutates
// `view` in place. Declaration order for `match`-rule tie-breaking is recovered
// via sorted-name fallback (an already-decoded map has no key order); callers
// with the raw JSON string should use the load path (`applyExpressionTemplatesToJSON`),
// which recovers genuine declaration order.
//
// Pre-condition: the input has been schema-validated.
func LowerExpressionTemplates(view map[string]any) error {
	return lowerExpressionTemplatesOrdered(view, nil)
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
	// Fast path: files with neither an `expression_templates` block nor any
	// `apply_expression_template` op need no rewriting (strip is a no-op).
	if !hasTemplateMachinery(view) {
		stripExpressionTemplates(view)
		// No expansion to run, but the §9.6.4 expanded-form validators still
		// apply — the raw tree IS the expanded form (esm-spec §4.3.2 makearray
		// bounds + geometry manifolds).
		if err := validateGeometryManifolds(view, ""); err != nil {
			return err
		}
		return validateMakearrayRegions(view, "")
	}
	// The consuming document's merged index_sets registry (post-§9.7.5): the
	// namespace `where` shape constraints resolve against at registration
	// (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name not
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
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for cname, compRaw := range comps {
			compObj, ok := compRaw.(map[string]any)
			if !ok {
				continue
			}
			cscope := fmt.Sprintf("%s.%s", kind, cname)
			// Static shape environment for `where` constraint evaluation
			// (esm-spec §9.6.1): declared variable shapes only.
			shapeEnv := componentShapeEnv(compObj)
			tplMap, _ := compObj["expression_templates"].(map[string]any)
			if tplMap != nil {
				if err := validateTemplates(tplMap, cscope); err != nil {
					return err
				}
				// Registration-time body composition (esm-spec §9.7.3):
				// inline body references to match-less in-scope templates as
				// a statically-checked acyclic DAG, so every rule body the
				// fixpoint sees is a closed AST.
				if err := composeTemplateBodies(tplMap, cscope); err != nil {
					return err
				}
			}
			var order []string
			if orders != nil {
				order = orders["/"+kind+"/"+cname+"/expression_templates"]
			}
			named, rules, err := buildRewriteContext(tplMap, order, isetNames, cscope)
			if err != nil {
				return err
			}
			delete(compObj, "expression_templates")
			for k, v := range compObj {
				scope := fmt.Sprintf("%s.%s.%s", kind, cname, k)
				rewritten, err := rewriteToFixpoint(v, named, rules, scope, shapeEnv)
				if err != nil {
					return err
				}
				compObj[k] = rewritten
			}
			// Expression transforms of variable_map coupling entries whose
			// receiving component is this one rewrite to fixpoint with the
			// same context, as if they were a field of the component. A
			// template-less receiver leaves the transform unrewritten.
			if len(named) > 0 || len(rules) > 0 {
				for _, site := range couplingSites[[2]string{kind, cname}] {
					scope := fmt.Sprintf("coupling[%d].transform", site.idx)
					rewritten, err := rewriteToFixpoint(site.entry["transform"], named, rules, scope, shapeEnv)
					if err != nil {
						return err
					}
					site.entry["transform"] = rewritten
				}
			}
		}
	}
	leftover := []string{}
	findApplyPaths(view, "", &leftover)
	if len(leftover) > 0 {
		return newETErr(
			"apply_expression_template_unknown_template",
			fmt.Sprintf("apply_expression_template ops remain after expansion at: %s — likely referenced from a component lacking an expression_templates block", strings.Join(leftover, ", ")),
		)
	}
	// Validators run on the expanded form (esm-spec §9.6.4): reject any
	// geometry-kernel node whose (possibly just-substituted) `manifold` is
	// outside the closed set, and any makearray region whose folded bound pair
	// is inverted (stop < start - 1; esm-spec §4.3.2).
	if err := validateGeometryManifolds(view, ""); err != nil {
		return err
	}
	return validateMakearrayRegions(view, "")
}

func stripExpressionTemplates(view map[string]any) {
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			if compObj, ok := compRaw.(map[string]any); ok {
				delete(compObj, "expression_templates")
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
		return "", fmt.Errorf("apply_expression_template pass: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
	if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
		return "", err
	}
	out, err := json.Marshal(view)
	if err != nil {
		return "", fmt.Errorf("apply_expression_template pass: re-marshal: %w", err)
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
	var view map[string]any
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		return "", fmt.Errorf("template resolution pass: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
	// esm-spec §9.7.10 form B: fold any coupling-entry injection into the target
	// components' own `expression_template_imports` BEFORE resolution, so the
	// ordinary import resolver + §9.6.3 fixpoint lower the target under the
	// assembler-chosen discretization. No-op when no coupling entry carries an
	// injection map.
	if err := applyCouplingInjections(view); err != nil {
		return "", err
	}
	if _, err := resolveTemplateMachinery(view, orders, basePath, metaparameters); err != nil {
		return "", err
	}
	if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
		return "", err
	}
	out, err := json.Marshal(view)
	if err != nil {
		return "", fmt.Errorf("template resolution pass: re-marshal: %w", err)
	}
	return string(out), nil
}

// ResolveAndLower is the exported raw §9.7 pipeline — resolveAndLowerJSON
// verbatim: load-time template-import/metaparameter resolution against
// basePath, then the §9.6.3 rewrite fixpoint, returning the post-lowering
// document as JSON (numeric tokens preserved via json.Number). This is the
// entry point external conformance runners drive to reproduce the Julia
// reference's expansion goldens (CONFORMANCE_SPEC.md §5.9) without going
// through the typed Load round-trip, whose serializer normalizes fields.
func ResolveAndLower(jsonStr, basePath string, metaparameters map[string]int64) (string, error) {
	return resolveAndLowerJSON(jsonStr, basePath, metaparameters)
}
