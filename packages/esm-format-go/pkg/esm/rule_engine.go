// Rule engine per discretization RFC §5.2.
//
// Pattern-match rewriting over the ESM expression AST with typed
// pattern variables, guards, non-linear matching (via canonical
// equality), and a top-down fixed-point loop with per-pass sealing of
// rewritten subtrees. Mirrors the Julia reference implementation in
// packages/EarthSciSerialization.jl/src/rule_engine.jl and the Rust
// port in packages/earthsci-toolkit-rs/src/rule_engine.rs.
//
// MVP supports only the inline `replacement` form; `use:<scheme>` (RFC
// §7.2.1) is deferred.
package esm

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// RuleEngineError is a stable-coded error raised by the rule engine.
// Code is one of the RFC §5.2 / §11 codes (e.g. E_RULES_NOT_CONVERGED,
// E_UNREWRITTEN_PDE_OP, E_PATTERN_VAR_UNBOUND).
type RuleEngineError struct {
	Code    string
	Message string
}

func (e *RuleEngineError) Error() string {
	return fmt.Sprintf("RuleEngineError(%s): %s", e.Code, e.Message)
}

func newRuleErr(code, msg string) *RuleEngineError {
	return &RuleEngineError{Code: code, Message: msg}
}

// Guard is a single constraint on pattern-variable bindings (§5.2.4).
// Name is one of the closed-set guard names; Params carries the JSON
// fields other than `guard`.
type Guard struct {
	Name   string
	Params map[string]interface{}
}

// Rule is a rewrite rule (§5.2). MVP supports the inline `replacement`
// form only.
//
// Region carries the legacy advisory string when the rule author wrote a
// string-form `region` (per v0.2). RegionScope carries a parsed object-form
// scope (RFC §5.2.7) — mutually exclusive. WhereExpr carries an optional
// per-query-point boolean predicate AST (RFC §5.2.7); structurally
// distinguished from the guard-list Where at parse time by JSON shape.
//
// BoundaryPolicy declares behavior at domain edges (RFC §5.2.8 / §7) —
// either a uniform string form (BoundaryPolicy.Uniform) or a per-axis
// map (BoundaryPolicy.PerAxis). A nil pointer means unset (semantically
// equivalent to "periodic" for backwards compatibility). GhostWidth
// declares per-axis ghost-cell padding the rule's stencil reaches
// (RFC §5.2.8 / §7); a nil pointer means unset (== 0). Bindings declares
// the time-varying / static symbols the replacement may reference
// (RFC §5.2.8). All three fields are preserved across parse/serialize
// roundtrips; the rule engine does not branch on them.
//
// The Go binding evaluates region.index_range, region.boundary,
// region.mask_field, and the where-expression
// predicate per query point (RFC §5.2.7).
type Rule struct {
	Name           string
	Pattern        Expression
	Where          []Guard
	Replacement    Expression
	Region         string
	RegionScope    *RuleRegionScope
	WhereExpr      Expression
	BoundaryPolicy *BoundaryPolicy
	GhostWidth     *GhostWidth
	Bindings       map[string]RuleBinding
}

// BoundaryPolicy is the parsed authorial form of a rule's boundary_policy
// field (RFC §5.2.8 / §7). Exactly one of Uniform / PerAxis is populated:
// Uniform holds a closed-set string when the author wrote the
// string-uniform form; PerAxis holds a {<axis>: BoundaryPolicySpec} map
// when the author wrote the {by_axis: ...} object form.
type BoundaryPolicy struct {
	Uniform string                          // empty when PerAxis is populated
	PerAxis map[string]BoundaryPolicySpec   // nil when Uniform is populated
}

// BoundaryPolicySpec is a single per-axis boundary-policy entry
// (RFC §5.2.8 / §7). Kind selects the closed-set policy; per-kind
// optional fields carry the policy's parameters.
type BoundaryPolicySpec struct {
	// Kind is one of: "periodic", "reflecting", "one_sided_extrapolation",
	// "prescribed", "ghosted" (alias for "prescribed"),
	// "neumann_zero" (alias for "reflecting"), "extrapolate" (alias for
	// "one_sided_extrapolation").
	Kind string
	// Degree is the extrapolation order for one_sided_extrapolation /
	// extrapolate (0..3). HasDegree distinguishes "explicit zero" from
	// "unset".
	Degree    int
	HasDegree bool
	// Description is an optional authorial note. Empty means unset.
	Description string
}

// GhostWidth is the parsed authorial form of a rule's ghost_width field
// (RFC §5.2.8 / §7). Exactly one of Uniform / PerAxis is populated:
// Uniform holds the integer scalar; PerAxis holds a {<axis>: int} map.
// HasUniform distinguishes "uniform 0" from "per-axis form".
type GhostWidth struct {
	Uniform    int
	HasUniform bool
	PerAxis    map[string]int // nil when Uniform is populated
}

// RuleBinding is a single rule binding declaration (RFC §5.2.8).
// Loaders preserve RuleBinding entries across parse/serialize
// roundtrips; the rule engine itself does not consult them during
// pattern matching or expansion.
type RuleBinding struct {
	// Kind is one of "static", "per_step", "per_cell".
	Kind string
	// Default is an optional default-value expression. Nil means unset.
	Default Expression
	// Description is an optional authorial note. Empty means unset.
	Description string
}

// RuleRegionScope is the parsed object-form `region` per RFC §5.2.7.
// Only one of the tagged fields is populated for a given Kind.
type RuleRegionScope struct {
	Kind  string // "boundary" | "mask_field" | "index_range"
	Side  string // boundary
	Field string // mask_field
	Axis  string // index_range
	Lo    int    // index_range
	Hi    int    // index_range
}

// GridMeta is the subset of grid metadata consulted by the closed-set
// guards and by RFC §5.2.7 region.boundary scope evaluation.
type GridMeta struct {
	SpatialDims    []string
	PeriodicDims   []string
	NonuniformDims []string
	// Optional per-dim [lo, hi] index bounds, used by region.boundary
	// scope evaluation (RFC §5.2.7). Absence is equivalent to "scope
	// disabled" (conservative fall-through).
	DimBounds map[string][2]int64
	// DimSizes holds the cell count for each named spatial dimension.
	// Consumed by bind_side_spacing and bind_side_dim_size guards.
	DimSizes map[string]int64
}

// VariableMeta is the subset of variable metadata consulted by the
// closed-set guards.
type VariableMeta struct {
	Grid     string
	Location string
	Shape    []string
	HasShape bool
}

// RuleContext supplies grid and variable metadata to guard evaluation
// (§5.2.4), plus a per-query-point index map for RFC §5.2.7 region /
// where-expression scope evaluation.
type RuleContext struct {
	Grids     map[string]GridMeta
	Variables map[string]VariableMeta
	// QueryPoint binds canonical index names (i, j, k, ...) to integer
	// coordinates at the current rewrite point. Empty for ordinary tree
	// rewriting — scope-bearing rules then fall through.
	QueryPoint map[string]int64
	// GridName is the grid the QueryPoint refers to (used to resolve
	// region.boundary.side against GridMeta.DimBounds).
	GridName string
	// MaskFields holds loader-backed boolean masks consumed by
	// region.mask_field scope evaluation (RFC §5.2.7). Each entry is the
	// list of grid points where the named mask is truthy; a rule fires at
	// a query point iff some entry is a subset of that query point.
	MaskFields map[string][]map[string]int64
}

// NewRuleContext returns an empty RuleContext with initialized maps.
func NewRuleContext() RuleContext {
	return RuleContext{
		Grids:      map[string]GridMeta{},
		Variables:  map[string]VariableMeta{},
		QueryPoint: map[string]int64{},
		MaskFields: map[string][]map[string]int64{},
	}
}

// DefaultMaxPasses is the RFC §5.2.5 default max-passes budget.
const DefaultMaxPasses = 32

// ============================================================================
// Pattern variable detection
// ============================================================================

func isPvarString(s string) bool {
	return len(s) >= 2 && s[0] == '$'
}

// ============================================================================
// Match
// ============================================================================

// MatchPattern attempts to match pattern against expr. On success
// returns the binding map (pvar name → bound Expression) and true. On
// failure returns nil and false.
//
// Non-linear patterns (§5.2.2): a pattern variable that appears in
// multiple positions must bind to canonically-equal values at every
// occurrence.
func MatchPattern(pattern, expr Expression) (map[string]Expression, bool) {
	b, ok, err := matchInner(pattern, expr, map[string]Expression{})
	if err != nil || !ok {
		return nil, false
	}
	return b, true
}

func matchInner(pat, expr Expression, b map[string]Expression) (map[string]Expression, bool, error) {
	// Pattern variable in an Expression position.
	if ps, ok := pat.(string); ok && isPvarString(ps) {
		nb, ok, err := unify(ps, expr, b)
		return nb, ok, err
	}
	switch p := pat.(type) {
	case int64:
		if ei, ok := expr.(int64); ok && ei == p {
			return b, true, nil
		}
		return nil, false, nil
	case int:
		if ei, ok := expr.(int64); ok && ei == int64(p) {
			return b, true, nil
		}
		return nil, false, nil
	case float64:
		if ef, ok := expr.(float64); ok && ef == p {
			return b, true, nil
		}
		return nil, false, nil
	case string:
		if es, ok := expr.(string); ok && es == p {
			return b, true, nil
		}
		return nil, false, nil
	case ExprNode:
		en, ok := asExprNode(expr)
		if !ok {
			return nil, false, nil
		}
		return matchOp(p, en, b)
	case *ExprNode:
		return matchInner(*p, expr, b)
	}
	return nil, false, nil
}

func matchOp(pat, expr ExprNode, b map[string]Expression) (map[string]Expression, bool, error) {
	if pat.Op != expr.Op {
		return nil, false, nil
	}
	if len(pat.Args) != len(expr.Args) {
		return nil, false, nil
	}
	b, ok, err := matchSiblingName(pat.Wrt, expr.Wrt, b)
	if err != nil || !ok {
		return nil, ok, err
	}
	b, ok, err = matchSiblingName(pat.Dim, expr.Dim, b)
	if err != nil || !ok {
		return nil, ok, err
	}
	b, ok, err = matchSiblingName(pat.Fn, expr.Fn, b)
	if err != nil || !ok {
		return nil, ok, err
	}
	for i := range pat.Args {
		b, ok, err = matchInner(pat.Args[i], expr.Args[i], b)
		if err != nil || !ok {
			return nil, ok, err
		}
	}
	return b, true, nil
}

func matchSiblingName(pat, val *string, b map[string]Expression) (map[string]Expression, bool, error) {
	if pat == nil {
		if val == nil {
			return b, true, nil
		}
		return nil, false, nil
	}
	if val == nil {
		return nil, false, nil
	}
	if isPvarString(*pat) {
		return unify(*pat, *val, b)
	}
	if *pat == *val {
		return b, true, nil
	}
	return nil, false, nil
}

func unify(pvar string, candidate Expression, b map[string]Expression) (map[string]Expression, bool, error) {
	if prev, has := b[pvar]; has {
		// Non-linear: existing binding must match candidate after
		// canonicalization.
		prevJSON, err := CanonicalJSON(prev)
		if err != nil {
			return nil, false, nil
		}
		newJSON, err := CanonicalJSON(candidate)
		if err != nil {
			return nil, false, nil
		}
		if bytes.Equal(prevJSON, newJSON) {
			return b, true, nil
		}
		return nil, false, nil
	}
	nb := make(map[string]Expression, len(b)+1)
	for k, v := range b {
		nb[k] = v
	}
	nb[pvar] = candidate
	return nb, true, nil
}

func asExprNode(e Expression) (ExprNode, bool) {
	switch v := e.(type) {
	case ExprNode:
		return v, true
	case *ExprNode:
		return *v, true
	}
	return ExprNode{}, false
}

// ============================================================================
// Apply bindings (build the replacement AST)
// ============================================================================

// ApplyBindings substitutes pattern variables in template with their
// bound values. Returns E_PATTERN_VAR_UNBOUND if template references an
// unbound pvar, or E_PATTERN_VAR_TYPE if a name-class pvar binds to a
// non-name expression.
func ApplyBindings(template Expression, b map[string]Expression) (Expression, error) {
	switch t := template.(type) {
	case string:
		if isPvarString(t) {
			v, has := b[t]
			if !has {
				return nil, newRuleErr("E_PATTERN_VAR_UNBOUND",
					fmt.Sprintf("pattern variable %s is not bound", t))
			}
			return v, nil
		}
		return t, nil
	case ExprNode:
		return applyBindingsNode(t, b)
	case *ExprNode:
		return applyBindingsNode(*t, b)
	default:
		return t, nil
	}
}

func applyBindingsNode(node ExprNode, b map[string]Expression) (Expression, error) {
	newArgs := make([]interface{}, len(node.Args))
	for i, a := range node.Args {
		v, err := ApplyBindings(a, b)
		if err != nil {
			return nil, err
		}
		newArgs[i] = v
	}
	newWrt, err := applyNameField(node.Wrt, b)
	if err != nil {
		return nil, err
	}
	newDim, err := applyNameField(node.Dim, b)
	if err != nil {
		return nil, err
	}
	newFn, err := applyNameField(node.Fn, b)
	if err != nil {
		return nil, err
	}
	out := ExprNode{
		Op:    node.Op,
		Args:  newArgs,
		Wrt:   newWrt,
		Dim:   newDim,
		Fn:    newFn,
		Name:  node.Name,
		Value: node.Value,
	}
	return out, nil
}

func applyNameField(field *string, b map[string]Expression) (*string, error) {
	if field == nil {
		return nil, nil
	}
	if !isPvarString(*field) {
		s := *field
		return &s, nil
	}
	v, has := b[*field]
	if !has {
		return nil, newRuleErr("E_PATTERN_VAR_UNBOUND",
			fmt.Sprintf("pattern variable %s is not bound", *field))
	}
	s, ok := v.(string)
	if !ok {
		return nil, newRuleErr("E_PATTERN_VAR_TYPE",
			fmt.Sprintf("pattern variable %s used in name-class field must bind a bare name", *field))
	}
	return &s, nil
}

// ============================================================================
// Guards (§5.2.4)
// ============================================================================

// CheckGuards evaluates guards left-to-right, threading bindings. A
// guard whose pvar-valued `grid` field is unbound at entry binds it to
// the variable's actual grid (§9.2.1 pattern). Returns extended
// bindings on success, (nil, false) on failure, or an error for unknown
// guards.
func CheckGuards(guards []Guard, bindings map[string]Expression, ctx RuleContext) (map[string]Expression, bool, error) {
	b := bindings
	for i := range guards {
		nb, ok, err := CheckGuard(guards[i], b, ctx)
		if err != nil {
			return nil, false, err
		}
		if !ok {
			return nil, false, nil
		}
		b = nb
	}
	return b, true, nil
}

// CheckGuard evaluates a single guard.
func CheckGuard(g Guard, b map[string]Expression, ctx RuleContext) (map[string]Expression, bool, error) {
	switch g.Name {
	case "var_has_grid":
		nb, ok := guardVarHasGrid(g, b, ctx)
		return nb, ok, nil
	case "dim_is_spatial_dim_of":
		nb, ok := guardDimIs(g, b, ctx, func(m GridMeta) []string { return m.SpatialDims })
		return nb, ok, nil
	case "dim_is_periodic":
		nb, ok := guardDimIs(g, b, ctx, func(m GridMeta) []string { return m.PeriodicDims })
		return nb, ok, nil
	case "dim_is_nonuniform":
		nb, ok := guardDimIs(g, b, ctx, func(m GridMeta) []string { return m.NonuniformDims })
		return nb, ok, nil
	case "var_location_is":
		nb, ok := guardVarLocationIs(g, b, ctx)
		return nb, ok, nil
	case "var_shape_rank":
		nb, ok := guardVarShapeRank(g, b, ctx)
		return nb, ok, nil
	case "bind_side_axis":
		nb, ok := guardBindSideAxis(g, b)
		return nb, ok, nil
	case "bind_side_spacing":
		nb, ok := guardBindSideSpacing(g, b, ctx)
		return nb, ok, nil
	case "bind_side_dim_size":
		nb, ok := guardBindSideDimSize(g, b, ctx)
		return nb, ok, nil
	}
	return nil, false, newRuleErr("E_UNKNOWN_GUARD",
		fmt.Sprintf("unknown guard: %s (§5.2.4 closed set)", g.Name))
}

func paramStr(g Guard, field string) (string, bool) {
	v, has := g.Params[field]
	if !has {
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		return "", false
	}
	return s, true
}

func resolveName(b map[string]Expression, key string) (string, bool) {
	v, has := b[key]
	if !has {
		return "", false
	}
	s, ok := v.(string)
	if !ok {
		return "", false
	}
	return s, true
}

// resolveOrMark resolves a guard field that may be a literal string or
// a pvar reference. It returns (resolvedValue, pvarNameIfUnbound).
func resolveOrMark(g Guard, b map[string]Expression, field string) (string, bool, string) {
	raw, has := paramStr(g, field)
	if !has {
		return "", false, ""
	}
	if isPvarString(raw) {
		bound, ok := resolveName(b, raw)
		if !ok {
			return "", false, raw
		}
		return bound, true, ""
	}
	return raw, true, ""
}

func bindPvarName(b map[string]Expression, pvar, name string) map[string]Expression {
	nb := make(map[string]Expression, len(b)+1)
	for k, v := range b {
		nb[k] = v
	}
	nb[pvar] = name
	return nb
}

func copyBindings(b map[string]Expression) map[string]Expression {
	nb := make(map[string]Expression, len(b)+1)
	for k, v := range b {
		nb[k] = v
	}
	return nb
}

func guardVarHasGrid(g Guard, b map[string]Expression, ctx RuleContext) (map[string]Expression, bool) {
	pvar, ok := paramStr(g, "pvar")
	if !ok {
		return nil, false
	}
	varName, ok := resolveName(b, pvar)
	if !ok {
		return nil, false
	}
	meta, ok := ctx.Variables[varName]
	if !ok || meta.Grid == "" {
		return nil, false
	}
	wanted, resolved, unboundPvar := resolveOrMark(g, b, "grid")
	if unboundPvar != "" {
		return bindPvarName(b, unboundPvar, meta.Grid), true
	}
	if !resolved {
		return nil, false
	}
	if wanted == meta.Grid {
		return b, true
	}
	return nil, false
}

func dimFromPvarOrLiteral(g Guard, b map[string]Expression) (string, bool) {
	raw, has := paramStr(g, "pvar")
	if !has {
		return "", false
	}
	if isPvarString(raw) {
		return resolveName(b, raw)
	}
	return raw, true
}

func guardDimIs(g Guard, b map[string]Expression, ctx RuleContext, dims func(GridMeta) []string) (map[string]Expression, bool) {
	dimName, ok := dimFromPvarOrLiteral(g, b)
	if !ok {
		return nil, false
	}
	grid, resolved, _ := resolveOrMark(g, b, "grid")
	if !resolved {
		return nil, false
	}
	meta, ok := ctx.Grids[grid]
	if !ok {
		return nil, false
	}
	for _, d := range dims(meta) {
		if d == dimName {
			return b, true
		}
	}
	return nil, false
}

func guardVarLocationIs(g Guard, b map[string]Expression, ctx RuleContext) (map[string]Expression, bool) {
	pvar, ok := paramStr(g, "pvar")
	if !ok {
		return nil, false
	}
	varName, ok := resolveName(b, pvar)
	if !ok {
		return nil, false
	}
	target, ok := paramStr(g, "location")
	if !ok {
		return nil, false
	}
	meta, ok := ctx.Variables[varName]
	if !ok {
		return nil, false
	}
	if meta.Location == target {
		return b, true
	}
	return nil, false
}

func guardVarShapeRank(g Guard, b map[string]Expression, ctx RuleContext) (map[string]Expression, bool) {
	pvar, ok := paramStr(g, "pvar")
	if !ok {
		return nil, false
	}
	varName, ok := resolveName(b, pvar)
	if !ok {
		return nil, false
	}
	raw, has := g.Params["rank"]
	if !has {
		return nil, false
	}
	want, ok := toInt(raw)
	if !ok {
		return nil, false
	}
	meta, ok := ctx.Variables[varName]
	if !ok || !meta.HasShape {
		return nil, false
	}
	if len(meta.Shape) == want {
		return b, true
	}
	return nil, false
}

var sideToAxis = map[string]string{
	"xmin": "x", "xmax": "x", "west": "x", "east": "x",
	"ymin": "y", "ymax": "y", "south": "y", "north": "y",
	"zmin": "z", "zmax": "z", "bottom": "z", "top": "z",
}

var sideToAxisIdx = map[string]int{
	"xmin": 0, "xmax": 0, "west": 0, "east": 0,
	"ymin": 1, "ymax": 1, "south": 1, "north": 1,
	"zmin": 2, "zmax": 2, "bottom": 2, "top": 2,
}

func resolveSideOrLiteral(g Guard, b map[string]Expression, field string) (string, bool) {
	raw, ok := paramStr(g, field)
	if !ok {
		return "", false
	}
	if isPvarString(raw) {
		return resolveName(b, raw)
	}
	return raw, true
}

func guardBindSideAxis(g Guard, b map[string]Expression) (map[string]Expression, bool) {
	pvar, ok := paramStr(g, "pvar")
	if !ok {
		return nil, false
	}
	sideName, ok := resolveSideOrLiteral(g, b, "side")
	if !ok {
		return nil, false
	}
	axis, ok := sideToAxis[sideName]
	if !ok {
		return nil, false
	}
	return bindPvarName(b, pvar, axis), true
}

func guardBindSideSpacing(g Guard, b map[string]Expression, ctx RuleContext) (map[string]Expression, bool) {
	pvar, ok := paramStr(g, "pvar")
	if !ok {
		return nil, false
	}
	sideName, ok := resolveSideOrLiteral(g, b, "side")
	if !ok {
		return nil, false
	}
	gridRaw, ok := paramStr(g, "grid")
	if !ok {
		return nil, false
	}
	var gridName string
	if isPvarString(gridRaw) {
		gridName, ok = resolveName(b, gridRaw)
		if !ok {
			return nil, false
		}
	} else {
		gridName = gridRaw
	}
	meta, ok := ctx.Grids[gridName]
	if !ok {
		return nil, false
	}
	axisIdx, ok := sideToAxisIdx[sideName]
	if !ok || axisIdx >= len(meta.SpatialDims) {
		return nil, false
	}
	dimName := meta.SpatialDims[axisIdx]
	n, ok := meta.DimSizes[dimName]
	if !ok {
		return nil, false
	}
	nb := copyBindings(b)
	nb[pvar] = float64(1) / float64(n)
	return nb, true
}

func guardBindSideDimSize(g Guard, b map[string]Expression, ctx RuleContext) (map[string]Expression, bool) {
	pvar, ok := paramStr(g, "pvar")
	if !ok {
		return nil, false
	}
	sideName, ok := resolveSideOrLiteral(g, b, "side")
	if !ok {
		return nil, false
	}
	gridRaw, ok := paramStr(g, "grid")
	if !ok {
		return nil, false
	}
	var gridName string
	if isPvarString(gridRaw) {
		gridName, ok = resolveName(b, gridRaw)
		if !ok {
			return nil, false
		}
	} else {
		gridName = gridRaw
	}
	meta, ok := ctx.Grids[gridName]
	if !ok {
		return nil, false
	}
	axisIdx, ok := sideToAxisIdx[sideName]
	if !ok || axisIdx >= len(meta.SpatialDims) {
		return nil, false
	}
	dimName := meta.SpatialDims[axisIdx]
	n, ok := meta.DimSizes[dimName]
	if !ok {
		return nil, false
	}
	nb := copyBindings(b)
	nb[pvar] = n
	return nb, true
}

func toInt(v interface{}) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int64:
		return int(x), true
	case float64:
		if x == float64(int(x)) {
			return int(x), true
		}
	case json.Number:
		i, err := x.Int64()
		if err == nil {
			return int(i), true
		}
	}
	return 0, false
}

// ============================================================================
// Rewriter (§5.2.5)
// ============================================================================

// Rewrite runs the rule engine on expr per §5.2.5: top-down walker,
// per-pass sealing of rewritten subtrees, fixed-point loop bounded by
// maxPasses. Returns E_RULES_NOT_CONVERGED on non-convergence. If
// maxPasses <= 0, DefaultMaxPasses is used.
func Rewrite(expr Expression, rules []Rule, ctx RuleContext, maxPasses int) (Expression, error) {
	if maxPasses <= 0 {
		maxPasses = DefaultMaxPasses
	}
	current := expr
	for pass := 0; pass < maxPasses; pass++ {
		changed := false
		next, err := rewritePass(current, rules, ctx, &changed)
		if err != nil {
			return nil, err
		}
		if !changed {
			return next, nil
		}
		current = next
	}
	return nil, newRuleErr("E_RULES_NOT_CONVERGED",
		fmt.Sprintf("rule engine did not converge within %d passes", maxPasses))
}

func rewritePass(expr Expression, rules []Rule, ctx RuleContext, changed *bool) (Expression, error) {
	for i := range rules {
		r := &rules[i]
		m, ok := MatchPattern(r.Pattern, expr)
		if !ok {
			continue
		}
		m2, ok, err := CheckGuards(r.Where, m, ctx)
		if err != nil {
			return nil, err
		}
		if !ok {
			continue
		}
		fire, err := checkScope(r, m2, ctx)
		if err != nil {
			return nil, err
		}
		if !fire {
			continue
		}
		newExpr, err := ApplyBindings(r.Replacement, m2)
		if err != nil {
			return nil, err
		}
		*changed = true
		return newExpr, nil // sealed: do not descend
	}
	node, ok := asExprNode(expr)
	if !ok {
		return expr, nil
	}
	newArgs := make([]interface{}, len(node.Args))
	for i, a := range node.Args {
		v, err := rewritePass(a, rules, ctx, changed)
		if err != nil {
			return nil, err
		}
		newArgs[i] = v
	}
	out := ExprNode{
		Op:    node.Op,
		Args:  newArgs,
		Wrt:   node.Wrt,
		Dim:   node.Dim,
		Name:  node.Name,
		Value: node.Value,
	}
	return out, nil
}

// ============================================================================
// Scope evaluation — region object + where expression (RFC §5.2.7)
// ============================================================================

// checkScope evaluates a rule's per-query-point scope. Returns true when
// the rule should fire at the current query point, false otherwise
// (conservative fall-through). A legacy string region and a missing
// where_expr pass unconditionally, preserving v0.2 semantics.
func checkScope(r *Rule, bindings map[string]Expression, ctx RuleContext) (bool, error) {
	if r.RegionScope != nil {
		ok, err := evalRegion(r.RegionScope, ctx)
		if err != nil || !ok {
			return false, err
		}
	}
	if r.WhereExpr != nil && !evalWhereExpr(r.WhereExpr, bindings, ctx) {
		return false, nil
	}
	return true, nil
}

func evalRegion(scope *RuleRegionScope, ctx RuleContext) (bool, error) {
	switch scope.Kind {
	case "index_range":
		v, has := ctx.QueryPoint[scope.Axis]
		if !has {
			return false, nil
		}
		return int64(scope.Lo) <= v && v <= int64(scope.Hi), nil
	case "boundary":
		return evalBoundary(scope.Side, ctx), nil
	case "mask_field":
		return evalMaskField(scope.Field, ctx), nil
	}
	return false, nil
}

func evalMaskField(field string, ctx RuleContext) bool {
	if len(ctx.QueryPoint) == 0 {
		return false
	}
	points, ok := ctx.MaskFields[field]
	if !ok {
		return false
	}
	for _, pt := range points {
		if maskEntryMatches(pt, ctx.QueryPoint) {
			return true
		}
	}
	return false
}

// maskEntryMatches reports whether mask_pt is a subset of query_pt: every
// (axis, value) the mask declares must agree with query_pt. Axes present
// in query_pt but absent from mask_pt are ignored, so a 2D surface mask
// can scope rules on a 3D grid (matches on i,j for any k).
func maskEntryMatches(maskPt, queryPt map[string]int64) bool {
	if len(maskPt) == 0 {
		return false
	}
	for axis, v := range maskPt {
		qv, has := queryPt[axis]
		if !has || qv != v {
			return false
		}
	}
	return true
}

func evalBoundary(side string, ctx RuleContext) bool {
	if ctx.GridName == "" {
		return false
	}
	meta, ok := ctx.Grids[ctx.GridName]
	if !ok {
		return false
	}
	var dim string
	var whichHi bool
	switch side {
	case "xmin", "west":
		dim, whichHi = "x", false
	case "xmax", "east":
		dim, whichHi = "x", true
	case "ymin", "south":
		dim, whichHi = "y", false
	case "ymax", "north":
		dim, whichHi = "y", true
	case "zmin", "bottom":
		dim, whichHi = "z", false
	case "zmax", "top":
		dim, whichHi = "z", true
	default:
		return false
	}
	bounds, ok := meta.DimBounds[dim]
	if !ok {
		return false
	}
	idxPos := -1
	for i, d := range meta.SpatialDims {
		if d == dim {
			idxPos = i
			break
		}
	}
	if idxPos < 0 {
		return false
	}
	canonical := []string{"i", "j", "k", "l", "m"}
	if idxPos >= len(canonical) {
		return false
	}
	v, has := ctx.QueryPoint[canonical[idxPos]]
	if !has {
		return false
	}
	target := bounds[0]
	if whichHi {
		target = bounds[1]
	}
	return v == target
}

func evalWhereExpr(e Expression, b map[string]Expression, ctx RuleContext) bool {
	if len(ctx.QueryPoint) == 0 {
		return false
	}
	v, ok := evalScalar(e, b, ctx)
	if !ok {
		return false
	}
	return v.truthy()
}

// scalarValue is the dynamically-typed value produced by the where-expr
// scalar interpreter. Bool/Int/Float discrimination mirrors the Rust
// reference (rule_engine.rs::ScalarValue).
type scalarValue struct {
	kind  byte // 'b' bool, 'i' int, 'f' float
	bool  bool
	int   int64
	float float64
}

func sBool(b bool) scalarValue    { return scalarValue{kind: 'b', bool: b} }
func sInt(i int64) scalarValue    { return scalarValue{kind: 'i', int: i} }
func sFloat(f float64) scalarValue { return scalarValue{kind: 'f', float: f} }

func (s scalarValue) toFloat() float64 {
	switch s.kind {
	case 'b':
		if s.bool {
			return 1.0
		}
		return 0.0
	case 'i':
		return float64(s.int)
	default:
		return s.float
	}
}

func (s scalarValue) truthy() bool {
	switch s.kind {
	case 'b':
		return s.bool
	case 'i':
		return s.int != 0
	default:
		return s.float != 0
	}
}

func evalScalar(e Expression, b map[string]Expression, ctx RuleContext) (scalarValue, bool) {
	switch v := e.(type) {
	case bool:
		return sBool(v), true
	case int:
		return sInt(int64(v)), true
	case int64:
		return sInt(v), true
	case float64:
		return sFloat(v), true
	case json.Number:
		if i, err := v.Int64(); err == nil {
			return sInt(i), true
		}
		if f, err := v.Float64(); err == nil {
			return sFloat(f), true
		}
		return scalarValue{}, false
	case string:
		if isPvarString(v) {
			bound, has := b[v]
			if !has {
				return scalarValue{}, false
			}
			return evalScalar(bound, b, ctx)
		}
		i, has := ctx.QueryPoint[v]
		if !has {
			return scalarValue{}, false
		}
		return sInt(i), true
	}
	if node, ok := asExprNode(e); ok {
		return evalOp(node, b, ctx)
	}
	return scalarValue{}, false
}

func evalOp(node ExprNode, b map[string]Expression, ctx RuleContext) (scalarValue, bool) {
	args := make([]scalarValue, 0, len(node.Args))
	for _, a := range node.Args {
		sv, ok := evalScalar(a, b, ctx)
		if !ok {
			return scalarValue{}, false
		}
		args = append(args, sv)
	}
	switch node.Op {
	case "==", "!=", "<", "<=", ">", ">=":
		if len(args) != 2 {
			return scalarValue{}, false
		}
		l, r := args[0].toFloat(), args[1].toFloat()
		var out bool
		switch node.Op {
		case "==":
			out = l == r
		case "!=":
			out = l != r
		case "<":
			out = l < r
		case "<=":
			out = l <= r
		case ">":
			out = l > r
		case ">=":
			out = l >= r
		}
		return sBool(out), true
	case "+":
		allInt := true
		for _, a := range args {
			if a.kind != 'i' {
				allInt = false
				break
			}
		}
		if allInt {
			var sum int64
			for _, a := range args {
				sum += a.int
			}
			return sInt(sum), true
		}
		var sum float64
		for _, a := range args {
			sum += a.toFloat()
		}
		return sFloat(sum), true
	case "-":
		if len(args) == 1 {
			switch args[0].kind {
			case 'i':
				return sInt(-args[0].int), true
			case 'f':
				return sFloat(-args[0].float), true
			default:
				return scalarValue{}, false
			}
		}
		if len(args) != 2 {
			return scalarValue{}, false
		}
		if args[0].kind == 'i' && args[1].kind == 'i' {
			return sInt(args[0].int - args[1].int), true
		}
		return sFloat(args[0].toFloat() - args[1].toFloat()), true
	case "*":
		allInt := true
		for _, a := range args {
			if a.kind != 'i' {
				allInt = false
				break
			}
		}
		if allInt {
			var prod int64 = 1
			for _, a := range args {
				prod *= a.int
			}
			return sInt(prod), true
		}
		prod := 1.0
		for _, a := range args {
			prod *= a.toFloat()
		}
		return sFloat(prod), true
	case "and":
		for _, a := range args {
			if !a.truthy() {
				return sBool(false), true
			}
		}
		return sBool(true), true
	case "or":
		for _, a := range args {
			if a.truthy() {
				return sBool(true), true
			}
		}
		return sBool(false), true
	case "not":
		if len(args) != 1 {
			return scalarValue{}, false
		}
		return sBool(!args[0].truthy()), true
	}
	return scalarValue{}, false
}

// ============================================================================
// JSON parsing (rules and expressions)
// ============================================================================

// ParseRules parses the `rules` section of a model into an ordered
// slice. Accepts the object-keyed-by-name form or the array form (RFC
// §5.2.5).
func ParseRules(raw json.RawMessage) ([]Rule, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v interface{}
	if err := dec.Decode(&v); err != nil {
		return nil, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("cannot decode rules JSON: %v", err))
	}
	return parseRulesValue(v)
}

func parseRulesValue(v interface{}) ([]Rule, error) {
	switch x := v.(type) {
	case []interface{}:
		out := make([]Rule, 0, len(x))
		for _, e := range x {
			obj, ok := e.(map[string]interface{})
			if !ok {
				return nil, newRuleErr("E_RULE_PARSE", "array-form rule must be an object")
			}
			nameRaw, has := obj["name"]
			if !has {
				return nil, newRuleErr("E_RULE_PARSE", "array-form rule missing `name`")
			}
			name, ok := nameRaw.(string)
			if !ok {
				return nil, newRuleErr("E_RULE_PARSE", "array-form rule `name` must be a string")
			}
			r, err := parseRuleObject(name, obj)
			if err != nil {
				return nil, err
			}
			out = append(out, r)
		}
		return out, nil
	case map[string]interface{}:
		// Preserve insertion order per JSON: Go maps don't, so sort keys
		// alphabetically for determinism. Neither fixture relies on map-form
		// rule ordering.
		out := make([]Rule, 0, len(x))
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sortStrings(keys)
		for _, k := range keys {
			obj, ok := x[k].(map[string]interface{})
			if !ok {
				return nil, newRuleErr("E_RULE_PARSE",
					fmt.Sprintf("rule %q must be an object", k))
			}
			r, err := parseRuleObject(k, obj)
			if err != nil {
				return nil, err
			}
			out = append(out, r)
		}
		return out, nil
	}
	return nil, newRuleErr("E_RULE_PARSE", "`rules` must be an object or array")
}

func sortStrings(s []string) {
	// Tiny insertion sort — keeps rule_engine.go free of extra imports.
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j-1] > s[j]; j-- {
			s[j-1], s[j] = s[j], s[j-1]
		}
	}
}

func parseRuleObject(name string, obj map[string]interface{}) (Rule, error) {
	patRaw, has := obj["pattern"]
	if !has {
		return Rule{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s` missing `pattern`", name))
	}
	pat, err := parseExprValue(patRaw)
	if err != nil {
		return Rule{}, err
	}
	replRaw, has := obj["replacement"]
	if !has {
		return Rule{}, newRuleErr("E_RULE_REPLACEMENT_MISSING",
			fmt.Sprintf("rule `%s`: MVP supports only the `replacement` form; `use:` rules are deferred", name))
	}
	repl, err := parseExprValue(replRaw)
	if err != nil {
		return Rule{}, err
	}
	var guards []Guard
	var whereExpr Expression
	if wraw, has := obj["where"]; has {
		switch w := wraw.(type) {
		case []interface{}:
			guards = make([]Guard, 0, len(w))
			for _, gv := range w {
				g, err := parseGuardValue(gv)
				if err != nil {
					return Rule{}, err
				}
				guards = append(guards, g)
			}
		case map[string]interface{}:
			if _, has := w["op"]; !has {
				return Rule{}, newRuleErr("E_RULE_PARSE",
					fmt.Sprintf("rule `%s`: `where` object must be an expression node with an `op` field", name))
			}
			ex, err := parseExprValue(w)
			if err != nil {
				return Rule{}, err
			}
			whereExpr = ex
		default:
			return Rule{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `where` must be an array of guards or an expression object", name))
		}
	}
	var region string
	var regionScope *RuleRegionScope
	if rraw, has := obj["region"]; has {
		switch r := rraw.(type) {
		case string:
			region = r
		case map[string]interface{}:
			scope, err := parseRegionScope(name, r)
			if err != nil {
				return Rule{}, err
			}
			regionScope = scope
		default:
			return Rule{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `region` must be a string (legacy) or object (scope)", name))
		}
	}
	var boundaryPolicy *BoundaryPolicy
	if bpRaw, has := obj["boundary_policy"]; has {
		bp, err := parseBoundaryPolicy(name, bpRaw)
		if err != nil {
			return Rule{}, err
		}
		boundaryPolicy = bp
	}
	var ghostWidth *GhostWidth
	if gwRaw, has := obj["ghost_width"]; has {
		gw, err := parseGhostWidth(name, gwRaw)
		if err != nil {
			return Rule{}, err
		}
		ghostWidth = gw
	}
	var bindings map[string]RuleBinding
	if bRaw, has := obj["bindings"]; has {
		bMap, ok := bRaw.(map[string]interface{})
		if !ok {
			return Rule{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `bindings` must be an object", name))
		}
		bindings = make(map[string]RuleBinding, len(bMap))
		for bname, bval := range bMap {
			rb, err := parseRuleBinding(name, bname, bval)
			if err != nil {
				return Rule{}, err
			}
			bindings[bname] = rb
		}
	}
	return Rule{
		Name:           name,
		Pattern:        pat,
		Where:          guards,
		Replacement:    repl,
		Region:         region,
		RegionScope:    regionScope,
		WhereExpr:      whereExpr,
		BoundaryPolicy: boundaryPolicy,
		GhostWidth:     ghostWidth,
		Bindings:       bindings,
	}, nil
}

var boundaryPolicyStringValues = map[string]struct{}{
	"periodic":                {},
	"reflecting":              {},
	"one_sided_extrapolation": {},
	"prescribed":              {},
	"ghosted":                 {},
	"neumann_zero":            {},
	"extrapolate":             {},
}

var boundaryPolicyKindValues = map[string]struct{}{
	"periodic":                {},
	"reflecting":              {},
	"one_sided_extrapolation": {},
	"prescribed":              {},
	"ghosted":                 {},
	"neumann_zero":            {},
	"extrapolate":             {},
}

func parseBoundaryPolicy(name string, raw interface{}) (*BoundaryPolicy, error) {
	switch v := raw.(type) {
	case string:
		if _, ok := boundaryPolicyStringValues[v]; !ok {
			return nil, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: unknown boundary_policy `%s` "+
					"(closed set: periodic, reflecting, one_sided_extrapolation, prescribed, ghosted, neumann_zero, extrapolate)",
					name, v))
		}
		return &BoundaryPolicy{Uniform: v}, nil
	case map[string]interface{}:
		byAxisRaw, has := v["by_axis"]
		if !has {
			return nil, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `boundary_policy` object must have a `by_axis` field", name))
		}
		byAxisMap, ok := byAxisRaw.(map[string]interface{})
		if !ok {
			return nil, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `boundary_policy.by_axis` must be an object", name))
		}
		out := make(map[string]BoundaryPolicySpec, len(byAxisMap))
		for axis, specRaw := range byAxisMap {
			spec, err := parseBoundaryPolicySpec(name, axis, specRaw)
			if err != nil {
				return nil, err
			}
			out[axis] = spec
		}
		return &BoundaryPolicy{PerAxis: out}, nil
	}
	return nil, newRuleErr("E_RULE_PARSE",
		fmt.Sprintf("rule `%s`: `boundary_policy` must be a string or an object with a `by_axis` field", name))
}

func parseBoundaryPolicySpec(ruleName, axis string, raw interface{}) (BoundaryPolicySpec, error) {
	obj, ok := raw.(map[string]interface{})
	if !ok {
		return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s must be an object", ruleName, axis))
	}
	kindV, has := obj["kind"]
	if !has {
		return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s missing required string `kind`", ruleName, axis))
	}
	kind, ok := kindV.(string)
	if !ok {
		return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s.kind must be a string", ruleName, axis))
	}
	if _, ok := boundaryPolicyKindValues[kind]; !ok {
		return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s: unknown kind `%s`", ruleName, axis, kind))
	}
	spec := BoundaryPolicySpec{Kind: kind}
	if dRaw, has := obj["degree"]; has {
		n, ok := jsonAsInt(dRaw)
		if !ok {
			return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s.degree must be an integer", ruleName, axis))
		}
		if n < 0 || n > 3 {
			return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s.degree must be between 0 and 3, got %d", ruleName, axis, n))
		}
		spec.Degree = n
		spec.HasDegree = true
	}
	if descRaw, has := obj["description"]; has {
		s, ok := descRaw.(string)
		if !ok {
			return BoundaryPolicySpec{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: boundary_policy.by_axis.%s.description must be a string", ruleName, axis))
		}
		spec.Description = s
	}
	return spec, nil
}

func parseGhostWidth(name string, raw interface{}) (*GhostWidth, error) {
	if n, ok := jsonAsInt(raw); ok {
		if n < 0 {
			return nil, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `ghost_width` must be non-negative, got %d", name, n))
		}
		return &GhostWidth{Uniform: n, HasUniform: true}, nil
	}
	if obj, ok := raw.(map[string]interface{}); ok {
		byAxisRaw, has := obj["by_axis"]
		if !has {
			return nil, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `ghost_width` object must have a `by_axis` field", name))
		}
		byAxisMap, ok := byAxisRaw.(map[string]interface{})
		if !ok {
			return nil, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: `ghost_width.by_axis` must be an object", name))
		}
		out := make(map[string]int, len(byAxisMap))
		for axis, w := range byAxisMap {
			n, ok := jsonAsInt(w)
			if !ok {
				return nil, newRuleErr("E_RULE_PARSE",
					fmt.Sprintf("rule `%s`: ghost_width.by_axis.%s must be an integer", name, axis))
			}
			if n < 0 {
				return nil, newRuleErr("E_RULE_PARSE",
					fmt.Sprintf("rule `%s`: ghost_width.by_axis.%s must be non-negative, got %d", name, axis, n))
			}
			out[axis] = n
		}
		return &GhostWidth{PerAxis: out}, nil
	}
	return nil, newRuleErr("E_RULE_PARSE",
		fmt.Sprintf("rule `%s`: `ghost_width` must be a non-negative integer or an object with a `by_axis` field", name))
}

// jsonAsInt converts a JSON-decoded numeric value to int. JSON numbers
// reach this code as either float64 (default decoder) or json.Number
// (decoders configured with UseNumber, as the rule-engine fixture loader
// uses); both forms must round-trip exactly to an integer.
func jsonAsInt(v interface{}) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int64:
		return int(x), true
	case float64:
		n := int(x)
		if float64(n) == x {
			return n, true
		}
		return 0, false
	case json.Number:
		n, err := x.Int64()
		if err != nil {
			return 0, false
		}
		return int(n), true
	}
	return 0, false
}

func parseRuleBinding(ruleName, bindingName string, v interface{}) (RuleBinding, error) {
	obj, ok := v.(map[string]interface{})
	if !ok {
		return RuleBinding{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: bindings.%s must be an object", ruleName, bindingName))
	}
	kindV, has := obj["kind"]
	if !has {
		return RuleBinding{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: bindings.%s missing required string `kind`", ruleName, bindingName))
	}
	kind, ok := kindV.(string)
	if !ok {
		return RuleBinding{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: bindings.%s.kind must be a string", ruleName, bindingName))
	}
	switch kind {
	case "static", "per_step", "per_cell":
		// ok
	default:
		return RuleBinding{}, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: bindings.%s: unknown kind `%s` "+
				"(closed set: static, per_step, per_cell)", ruleName, bindingName, kind))
	}
	rb := RuleBinding{Kind: kind}
	if dRaw, has := obj["default"]; has && dRaw != nil {
		d, err := parseExprValue(dRaw)
		if err != nil {
			return RuleBinding{}, err
		}
		rb.Default = d
	}
	if descRaw, has := obj["description"]; has && descRaw != nil {
		desc, ok := descRaw.(string)
		if !ok {
			return RuleBinding{}, newRuleErr("E_RULE_PARSE",
				fmt.Sprintf("rule `%s`: bindings.%s.description must be a string", ruleName, bindingName))
		}
		rb.Description = desc
	}
	return rb, nil
}

func parseRegionScope(ruleName string, obj map[string]interface{}) (*RuleRegionScope, error) {
	kindV, has := obj["kind"]
	if !has {
		return nil, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: region object must carry a `kind` field", ruleName))
	}
	kind, ok := kindV.(string)
	if !ok {
		return nil, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: region.kind must be a string", ruleName))
	}
	scope := &RuleRegionScope{Kind: kind}
	missing := func(f string) error {
		return newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: region.%s requires `%s`", ruleName, kind, f))
	}
	strField := func(f string) (string, error) {
		v, has := obj[f]
		if !has {
			return "", missing(f)
		}
		s, ok := v.(string)
		if !ok {
			return "", missing(f)
		}
		return s, nil
	}
	intField := func(f string) (int, error) {
		v, has := obj[f]
		if !has {
			return 0, missing(f)
		}
		switch x := v.(type) {
		case float64:
			return int(x), nil
		case int:
			return x, nil
		case int64:
			return int(x), nil
		case json.Number:
			n, err := x.Int64()
			if err != nil {
				return 0, missing(f)
			}
			return int(n), nil
		default:
			return 0, missing(f)
		}
	}
	switch kind {
	case "boundary":
		side, err := strField("side")
		if err != nil {
			return nil, err
		}
		scope.Side = side
	case "mask_field":
		fld, err := strField("field")
		if err != nil {
			return nil, err
		}
		scope.Field = fld
	case "index_range":
		axis, err := strField("axis")
		if err != nil {
			return nil, err
		}
		lo, err := intField("lo")
		if err != nil {
			return nil, err
		}
		hi, err := intField("hi")
		if err != nil {
			return nil, err
		}
		scope.Axis = axis
		scope.Lo = lo
		scope.Hi = hi
	default:
		return nil, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("rule `%s`: unknown region.kind `%s` (closed set: boundary, mask_field, index_range)", ruleName, kind))
	}
	return scope, nil
}

func parseGuardValue(v interface{}) (Guard, error) {
	obj, ok := v.(map[string]interface{})
	if !ok {
		return Guard{}, newRuleErr("E_RULE_PARSE", "guard must be an object")
	}
	nameRaw, has := obj["guard"]
	if !has {
		return Guard{}, newRuleErr("E_RULE_PARSE", "guard object missing `guard` field")
	}
	name, ok := nameRaw.(string)
	if !ok {
		return Guard{}, newRuleErr("E_RULE_PARSE", "guard `guard` field must be a string")
	}
	params := make(map[string]interface{}, len(obj))
	for k, val := range obj {
		if k == "guard" {
			continue
		}
		params[k] = normalizeGuardParam(val)
	}
	return Guard{Name: name, Params: params}, nil
}

func normalizeGuardParam(v interface{}) interface{} {
	if n, ok := v.(json.Number); ok {
		s := string(n)
		if strings.ContainsAny(s, ".eE") {
			f, err := n.Float64()
			if err == nil {
				return f
			}
			return s
		}
		i, err := n.Int64()
		if err == nil {
			return i
		}
		return s
	}
	if arr, ok := v.([]interface{}); ok {
		out := make([]interface{}, len(arr))
		for i, e := range arr {
			out[i] = normalizeGuardParam(e)
		}
		return out
	}
	return v
}

// ParseExpr parses a JSON-decoded value into an Expression, preserving
// int-vs-float per RFC §5.4.
func ParseExpr(raw json.RawMessage) (Expression, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v interface{}
	if err := dec.Decode(&v); err != nil {
		return nil, newRuleErr("E_RULE_PARSE",
			fmt.Sprintf("cannot decode expression JSON: %v", err))
	}
	return parseExprValue(v)
}

func parseExprValue(v interface{}) (Expression, error) {
	switch x := v.(type) {
	case json.Number:
		return normalizeJSONNumber(x), nil
	case int64:
		return x, nil
	case int:
		return int64(x), nil
	case float64:
		return x, nil
	case string:
		return x, nil
	case map[string]interface{}:
		opRaw, has := x["op"]
		if !has {
			return nil, newRuleErr("E_RULE_PARSE", "operator node missing `op`")
		}
		op, ok := opRaw.(string)
		if !ok {
			return nil, newRuleErr("E_RULE_PARSE", "operator node `op` must be a string")
		}
		var argsRaw []interface{}
		if a, has := x["args"]; has {
			arr, ok := a.([]interface{})
			if !ok {
				return nil, newRuleErr("E_RULE_PARSE", "operator node `args` must be an array")
			}
			argsRaw = arr
		}
		args := make([]interface{}, len(argsRaw))
		for i, a := range argsRaw {
			e, err := parseExprValue(a)
			if err != nil {
				return nil, err
			}
			args[i] = e
		}
		node := ExprNode{Op: op, Args: args}
		if w, has := x["wrt"]; has {
			if ws, ok := w.(string); ok {
				s := ws
				node.Wrt = &s
			}
		}
		if d, has := x["dim"]; has {
			if ds, ok := d.(string); ok {
				s := ds
				node.Dim = &s
			}
		}
		if f, has := x["fn"]; has {
			if fs, ok := f.(string); ok {
				s := fs
				node.Fn = &s
			}
		}
		return node, nil
	}
	return nil, newRuleErr("E_RULE_PARSE",
		fmt.Sprintf("cannot parse expression of type %T", v))
}

// ============================================================================
// Unrewritten PDE op check (§11 Step 7)
// ============================================================================

var pdeOps = map[string]struct{}{
	"grad": {}, "div": {}, "laplacian": {}, "D": {}, "bc": {},
}

// CheckUnrewrittenPDEOps scans expr for leftover PDE ops (grad, div,
// laplacian, D, bc) and returns E_UNREWRITTEN_PDE_OP if any remain.
// Authors opt out by annotating an equation with `passthrough: true` at
// the pipeline layer; this check is run only on non-passthrough
// equations.
func CheckUnrewrittenPDEOps(expr Expression) error {
	if op, found := findPDEOp(expr); found {
		return newRuleErr("E_UNREWRITTEN_PDE_OP",
			fmt.Sprintf("equation still contains PDE op '%s' after rewrite; "+
				"annotate the equation with 'passthrough: true' to opt out", op))
	}
	return nil
}

func findPDEOp(e Expression) (string, bool) {
	node, ok := asExprNode(e)
	if !ok {
		return "", false
	}
	if _, found := pdeOps[node.Op]; found {
		return node.Op, true
	}
	for _, a := range node.Args {
		if op, found := findPDEOp(a); found {
			return op, true
		}
	}
	return "", false
}
