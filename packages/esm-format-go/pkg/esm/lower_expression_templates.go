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
// `EsmFile` struct.

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const applyExpressionTemplateOp = "apply_expression_template"

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
func assertNoNestedApply(body interface{}, templateName, path string) error {
	switch b := body.(type) {
	case []interface{}:
		for i, child := range b {
			if err := assertNoNestedApply(child, templateName, fmt.Sprintf("%s/%d", path, i)); err != nil {
				return err
			}
		}
	case map[string]interface{}:
		if op, ok := b["op"].(string); ok && op == applyExpressionTemplateOp {
			return newETErr(
				"apply_expression_template_invalid_declaration",
				fmt.Sprintf("expression_templates.%s: `match` contains an 'apply_expression_template' node at %s; match patterns MUST NOT reference templates (esm-spec §9.7.3)", templateName, path),
			)
		}
		// Iterate in deterministic order for cross-language reproducibility
		// of error messages (Go map iteration is randomized).
		keys := sortedKeys(b)
		for _, k := range keys {
			if err := assertNoNestedApply(b[k], templateName, path+"/"+k); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateTemplates(templates map[string]interface{}, scope string) error {
	for _, name := range sortedKeys(templates) {
		decl := templates[name]
		declObj, ok := decl.(map[string]interface{})
		if !ok {
			return newETErr(
				"apply_expression_template_invalid_declaration",
				fmt.Sprintf("%s.expression_templates.%s: entry must be an object with params + body", scope, name),
			)
		}
		// `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
		// template is a named constant fragment (common in library files).
		paramsRaw, ok := declObj["params"].([]interface{})
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
		if match, ok := declObj["match"]; ok && match != nil {
			if err := assertNoNestedApply(match, name, "/match"); err != nil {
				return err
			}
		}
	}
	return nil
}

func deepCopyJSON(v interface{}) interface{} {
	switch x := v.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(x))
		for k, val := range x {
			out[k] = deepCopyJSON(val)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(x))
		for i, val := range x {
			out[i] = deepCopyJSON(val)
		}
		return out
	default:
		return x
	}
}

func substituteParams(body interface{}, bindings map[string]interface{}) interface{} {
	switch b := body.(type) {
	case string:
		if v, ok := bindings[b]; ok {
			return deepCopyJSON(v)
		}
		return body
	case []interface{}:
		out := make([]interface{}, len(b))
		for i, c := range b {
			out[i] = substituteParams(c, bindings)
		}
		return out
	case map[string]interface{}:
		out := make(map[string]interface{}, len(b))
		for k, v := range b {
			out[k] = substituteParams(v, bindings)
		}
		return out
	default:
		return body
	}
}

func expandApply(node map[string]interface{}, templates map[string]interface{}, scope string) (interface{}, error) {
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
	decl, ok := declRaw.(map[string]interface{})
	if !ok {
		return nil, newETErr(
			"apply_expression_template_invalid_declaration",
			fmt.Sprintf("%s: template '%s' declaration is not an object", scope, nameRaw),
		)
	}
	bindingsRaw, ok := node["bindings"].(map[string]interface{})
	if !ok {
		return nil, newETErr(
			"apply_expression_template_bindings_mismatch",
			fmt.Sprintf("%s: apply_expression_template '%s' missing 'bindings' object", scope, nameRaw),
		)
	}
	paramsArr, _ := decl["params"].([]interface{})
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
	resolved := make(map[string]interface{}, len(bindingsRaw))
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
func asNumber(v interface{}) (float64, bool) {
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
func jsonEqual(a, b interface{}) bool {
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
	if aa, ok := a.([]interface{}); ok {
		ba, ok := b.([]interface{})
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
	if am, ok := a.(map[string]interface{}); ok {
		bm, ok := b.(map[string]interface{})
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
func matchPattern(pattern, node interface{}, params map[string]struct{}, bindings map[string]interface{}) bool {
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
	if pa, ok := pattern.([]interface{}); ok {
		na, ok := node.([]interface{})
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
	if pm, ok := pattern.(map[string]interface{}); ok {
		nm, ok := node.(map[string]interface{})
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

// rulePriority returns the `priority` of a `match` rule (esm-spec §9.6.3): higher
// fires first, ties break by declaration order. Absent ⇒ 0. Any numeric encoding
// is coerced defensively.
func rulePriority(decl map[string]interface{}) int {
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
	name     string
	pattern  interface{}
	params   map[string]struct{}
	body     interface{}
	priority int
	declIdx  int
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
func rewritePass(node interface{}, named map[string]interface{}, rules []matchRule, scope string, last *string) (interface{}, bool, error) {
	switch n := node.(type) {
	case []interface{}:
		changed := false
		out := make([]interface{}, len(n))
		for i, c := range n {
			nc, ch, err := rewritePass(c, named, rules, scope, last)
			if err != nil {
				return nil, false, err
			}
			out[i] = nc
			changed = changed || ch
		}
		return out, changed, nil
	case map[string]interface{}:
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
			bindings := map[string]interface{}{}
			if matchPattern(rules[i].pattern, n, rules[i].params, bindings) {
				*last = op
				return substituteParams(rules[i].body, bindings), true, nil
			}
		}
		// (2) No rule fired here — descend into children.
		changed := false
		out := make(map[string]interface{}, len(n))
		for k, v := range n {
			nv, ch, err := rewritePass(v, named, rules, scope, last)
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
func rewriteToFixpoint(node interface{}, named map[string]interface{}, rules []matchRule, scope string) (interface{}, error) {
	last := ""
	current := node
	for pass := 0; pass < MaxRewritePasses; pass++ {
		next, changed, err := rewritePass(current, named, rules, scope, &last)
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
func orderedTemplateNames(tpl map[string]interface{}, order []string) []string {
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

// hasTemplateMachinery reports whether `view` declares any non-empty
// `expression_templates` block under models/reaction_systems, or contains any
// `apply_expression_template` op anywhere. Files with neither need no rewriting.
func hasTemplateMachinery(view map[string]interface{}) bool {
	if view == nil {
		return false
	}
	for _, kind := range []string{"models", "reaction_systems"} {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			compObj, ok := compRaw.(map[string]interface{})
			if !ok {
				continue
			}
			if tpl, ok := compObj["expression_templates"].(map[string]interface{}); ok && len(tpl) > 0 {
				return true
			}
		}
	}
	hits := []string{}
	findApplyPaths(view, "", &hits)
	return len(hits) > 0
}

func findApplyPaths(view interface{}, path string, hits *[]string) {
	switch v := view.(type) {
	case []interface{}:
		for i, c := range v {
			findApplyPaths(c, fmt.Sprintf("%s/%d", path, i), hits)
		}
	case map[string]interface{}:
		if op, ok := v["op"].(string); ok && op == applyExpressionTemplateOp {
			*hits = append(*hits, path)
		}
		for _, k := range sortedKeys(v) {
			findApplyPaths(v[k], path+"/"+k, hits)
		}
	}
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

// RejectExpressionTemplatesPreV04 rejects `expression_templates` blocks and
// `apply_expression_template` ops in files declaring `esm` < 0.4.0. Mirrors
// the equivalent TS / Python / Julia / Rust checks.
func RejectExpressionTemplatesPreV04(view map[string]interface{}) error {
	if view == nil {
		return nil
	}
	esmRaw, ok := view["esm"].(string)
	if !ok {
		return nil
	}
	m := semverRe.FindStringSubmatch(esmRaw)
	if m == nil {
		return nil
	}
	major, _ := strconv.Atoi(m[1])
	minor, _ := strconv.Atoi(m[2])
	if major != 0 || minor >= 4 {
		return nil
	}
	offences := []string{}
	for _, kind := range []string{"models", "reaction_systems"} {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			compObj, ok := comps[cname].(map[string]interface{})
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

// LowerExpressionTemplates runs the outermost-first + priority + bounded-fixpoint
// rewrite over `view` and strips the `expression_templates` blocks. Mutates
// `view` in place. Declaration order for `match`-rule tie-breaking is recovered
// via sorted-name fallback (an already-decoded map has no key order); callers
// with the raw JSON string should use the load path (`applyExpressionTemplatesToJSON`),
// which recovers genuine declaration order.
//
// Pre-condition: the input has been schema-validated.
func LowerExpressionTemplates(view map[string]interface{}) error {
	return lowerExpressionTemplatesOrdered(view, nil)
}

// lowerExpressionTemplatesOrdered is LowerExpressionTemplates with an optional
// `orders` map (path → template declaration order) recovered from the raw JSON.
func lowerExpressionTemplatesOrdered(view map[string]interface{}, orders map[string][]string) error {
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
		return nil
	}
	for _, kind := range []string{"models", "reaction_systems"} {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for cname, compRaw := range comps {
			compObj, ok := compRaw.(map[string]interface{})
			if !ok {
				continue
			}
			tplMap, _ := compObj["expression_templates"].(map[string]interface{})
			if tplMap != nil {
				if err := validateTemplates(tplMap, fmt.Sprintf("%s.%s", kind, cname)); err != nil {
					return err
				}
				// Registration-time body composition (esm-spec §9.7.3):
				// inline body references to match-less in-scope templates as
				// a statically-checked acyclic DAG, so every rule body the
				// fixpoint sees is a closed AST.
				if err := composeTemplateBodies(tplMap, fmt.Sprintf("%s.%s", kind, cname)); err != nil {
					return err
				}
			}
			// `named`  — every template keyed by name, consulted by
			//            `apply_expression_template` (order-independent).
			// `rules`  — the auto-applied `match` rules, sorted by highest
			//            priority first, ties by declaration order (esm-spec §9.6.3).
			named := map[string]interface{}{}
			var rules []matchRule
			if tplMap != nil {
				var order []string
				if orders != nil {
					order = orders["/"+kind+"/"+cname+"/expression_templates"]
				}
				for idx, name := range orderedTemplateNames(tplMap, order) {
					decl, _ := tplMap[name].(map[string]interface{})
					named[name] = decl
					if match, ok := decl["match"]; ok && match != nil {
						pset := map[string]struct{}{}
						if pr, ok := decl["params"].([]interface{}); ok {
							for _, p := range pr {
								if ps, ok := p.(string); ok {
									pset[ps] = struct{}{}
								}
							}
						}
						rules = append(rules, matchRule{
							name:     name,
							pattern:  match,
							params:   pset,
							body:     decl["body"],
							priority: rulePriority(decl),
							declIdx:  idx,
						})
					}
				}
				sort.SliceStable(rules, func(i, j int) bool {
					if rules[i].priority != rules[j].priority {
						return rules[i].priority > rules[j].priority
					}
					return rules[i].declIdx < rules[j].declIdx
				})
			}
			delete(compObj, "expression_templates")
			for k, v := range compObj {
				scope := fmt.Sprintf("%s.%s.%s", kind, cname, k)
				rewritten, err := rewriteToFixpoint(v, named, rules, scope)
				if err != nil {
					return err
				}
				compObj[k] = rewritten
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
	return nil
}

func stripExpressionTemplates(view map[string]interface{}) {
	for _, kind := range []string{"models", "reaction_systems"} {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			if compObj, ok := compRaw.(map[string]interface{}); ok {
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
	var view map[string]interface{}
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
	var view map[string]interface{}
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		return "", fmt.Errorf("template resolution pass: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
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
