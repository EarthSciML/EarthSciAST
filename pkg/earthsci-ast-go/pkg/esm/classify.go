package esm

import "sort"

// classify.go is the esm-spec §6.3.1 classification API: the pure functions of a
// model that recover the finer categories a solver needs from the TWO declared
// variable types.
//
// esm 1.0.0 declares `unknown` and `parameter` and nothing else. Which unknowns
// are ODE states, observed, or algebraic follows from the model's EQUATIONS;
// which parameters are Brownian, discrete, sampled, or constant follows from
// their `distribution` and `update`. Every binding exposes the same functions in
// its own idiom (snake_case in Julia/Python/Rust, camelCase in TypeScript,
// exported CamelCase here), and the cross-language golden is
// tests/conformance/classification/.
//
// These functions are the ONLY sanctioned way to ask these questions. A site
// that used to branch on `variable.type == "state"` calls IsODEState; one that
// branched on `"observed"` calls ObservedUnknowns. Reading a declared type to
// answer a derived question is precisely what 1.0.0 removes.
//
// Both families are PARTITIONS — every unknown lands in exactly one of the three
// unknown sets, every parameter in exactly one of the four parameter sets — and
// classification_test.go asserts it on every fixture.

// --- unknowns ---------------------------------------------------------------

// ODEStates returns the model's unknowns that appear under a time derivative
// `D(·, t)` on some equation LHS, sorted lexicographically.
//
// The derivative LHS may be WRAPPED and still credits its base variable: a bare
// `D(u)`, an indexed `D(u[i])`, and an `aggregate` whose `expr` is a `D(...)`
// (the whole-array spelling of an elementwise derivative) all name `u` an ODE
// state.
func ODEStates(model *Model) []string {
	if model == nil {
		return nil
	}
	states := odeStateSet(model)
	return sortedNamesIn(states, model)
}

// IsODEState reports whether the named variable is an unknown appearing under a
// time derivative on some equation LHS. It is the membership test for ODEStates
// and the replacement for every `variable.Type == "state"` branch.
func IsODEState(model *Model, name string) bool {
	if model == nil {
		return false
	}
	if v, ok := model.Variables[name]; !ok || v.Type != VarTypeUnknown {
		return false
	}
	return odeStateSet(model)[name]
}

// ObservedUnknowns returns the model's unknowns defined by a BARE-VARIABLE LHS
// (`y ~ f(…)`) — eliminable, materializable — sorted lexicographically.
//
// An unknown that is BOTH differentiated somewhere and given a bare-variable
// equation elsewhere is an ODE state; the three sets partition, and ODE-ness
// wins, because the bare equation is then an extra constraint on a state rather
// than that state's definition.
func ObservedUnknowns(model *Model) []string {
	if model == nil {
		return nil
	}
	states := odeStateSet(model)
	observed := map[string]bool{}
	for name := range observedDefinitions(model) {
		if !states[name] {
			observed[name] = true
		}
	}
	return sortedNamesIn(observed, model)
}

// AlgebraicUnknowns returns the model's unknowns constrained only IMPLICITLY —
// those that are neither differentiated nor given a bare-variable definition,
// so the only equations mentioning them have an expression LHS (`H*H*SO4 ~ Ksp`)
// or mention them on a right-hand side. Sorted lexicographically.
func AlgebraicUnknowns(model *Model) []string {
	if model == nil {
		return nil
	}
	states := odeStateSet(model)
	defs := observedDefinitions(model)
	algebraic := map[string]bool{}
	for name, v := range model.Variables {
		if v.Type != VarTypeUnknown {
			continue
		}
		if states[name] {
			continue
		}
		if _, ok := defs[name]; ok {
			continue
		}
		algebraic[name] = true
	}
	return sortedNamesIn(algebraic, model)
}

// ObservedDefinition returns the defining RHS of an observed unknown — the RHS
// of the first equation whose LHS is exactly that bare name — and whether one
// exists. This is where an observed's behaviour moved in 1.0.0: out of
// `variables[v].expression` and into the model's `equations`. Passes that used
// to read the removed field (units propagation, array-shape checking, the
// cadence leaf seed) read it here instead.
func ObservedDefinition(model *Model, name string) (Expression, bool) {
	if model == nil {
		return nil, false
	}
	rhs, ok := observedDefinitions(model)[name]
	return rhs, ok
}

// --- parameters -------------------------------------------------------------

// BrownianParameters returns the parameters whose update is `wiener` — the SDE
// noise sources, resampled every step with √dt increment scaling. Sorted
// lexicographically.
//
// With an update ARRAY a parameter is Brownian iff ANY rule is `wiener`; the
// schema forbids `wiener` inside an array, so in practice an array always means
// discrete. Checking every rule rather than the first keeps the classification
// correct on a document that slipped past a lenient schema check.
func BrownianParameters(model *Model) []string {
	return parametersWhere(model, func(v ModelVariable) bool { return isBrownianVar(v) })
}

// DiscreteParameters returns the parameters carrying any update OTHER than
// `wiener` — piecewise-constant between refreshes. Sorted lexicographically.
func DiscreteParameters(model *Model) []string {
	return parametersWhere(model, func(v ModelVariable) bool {
		return v.HasUpdate() && !isBrownianVar(v)
	})
}

// SampledParameters returns the parameters carrying a distribution and NO
// update — drawn once at setup (uncertainty quantification, ensembles). Sorted
// lexicographically.
func SampledParameters(model *Model) []string {
	return parametersWhere(model, func(v ModelVariable) bool {
		return v.Distribution != nil && !v.HasUpdate()
	})
}

// ConstantParameters returns the parameters carrying neither a distribution nor
// an update — plain constants. Sorted lexicographically.
func ConstantParameters(model *Model) []string {
	return parametersWhere(model, func(v ModelVariable) bool {
		return v.Distribution == nil && !v.HasUpdate()
	})
}

// --- system kind ------------------------------------------------------------

// SystemKind derives what the `system_kind` field declares (esm-spec §6.3.1),
// testing four conditions IN ORDER and taking the first that holds:
//
//  1. any Brownian parameter                   => "sde"
//  2. any equation holds a spatial derivative  => "pde"
//  3. no time-derivative equation at all       => "nonlinear"
//  4. otherwise                                => "ode"
//
// The order is normative and two orderings that look interchangeable are not.
// "pde" is tested BEFORE "nonlinear" so a steady-state PDE (laplacian(phi) ~ f,
// which has no time derivative) does not fall through to "nonlinear"; "sde" is
// tested BEFORE "pde" because there is no SPDESystem constructor to select for
// a model that is both.
//
// Detection is a property of the EQUATIONS, never of the `domain` block: v0.8.0
// removed Domain.spatial, so `domain` carries nothing spatial and the earlier
// "spatial domain plus differential operators" rule named a test no binding
// could perform.
//
// `domain` is still accepted so callers need not change, and is used only for
// the independent-variable name.
func SystemKind(model *Model, domain *Domain) string {
	if model == nil {
		return SystemKindODE
	}
	if len(BrownianParameters(model)) > 0 {
		return SystemKindSDE
	}
	if hasDifferentialOperator(model) {
		return SystemKindPDE
	}
	if !hasTimeDerivative(model) {
		return SystemKindNonlinear
	}
	return SystemKindODE
}

// EffectiveSystemKind is what a consumer should branch on: the DECLARED
// `system_kind` when the model carries one, and the SystemKind derivation
// otherwise (esm-spec §6.3.1, "a binding uses the derivation when the field is
// absent"). The two are checked against each other by the structural validator,
// which reports `system_kind_mismatch` when a present field contradicts the
// derivation — so by the time a document validates, the two agree.
func EffectiveSystemKind(model *Model, domain *Domain) string {
	if model == nil {
		return SystemKindODE
	}
	if model.SystemKind != nil {
		return *model.SystemKind
	}
	return SystemKind(model, domain)
}

// --- shared derivation ------------------------------------------------------

// odeStateSet is the raw membership set behind ODEStates / IsODEState.
func odeStateSet(model *Model) map[string]bool {
	indep := DefaultIndepVar
	states := map[string]bool{}
	for _, eq := range model.Equations {
		for name := range derivativeTargets(eq.LHS, indep) {
			if v, ok := model.Variables[name]; ok && v.Type == VarTypeUnknown {
				states[name] = true
			}
		}
	}
	return states
}

// observedDefinitions maps each unknown given a BARE-VARIABLE-LHS equation to
// that equation's RHS. The first such equation wins, so the map is stable under
// a (malformed) duplicate definition.
func observedDefinitions(model *Model) map[string]Expression {
	defs := make(map[string]Expression)
	for _, eq := range model.Equations {
		name, ok := eq.LHS.(string)
		if !ok {
			continue
		}
		if v, ok := model.Variables[name]; !ok || v.Type != VarTypeUnknown {
			continue
		}
		if _, seen := defs[name]; !seen {
			defs[name] = eq.RHS
		}
	}
	return defs
}

// derivativeTargets collects the base variable names differentiated with respect
// to indep anywhere inside an equation LHS.
//
// A `D` node's argument may be the bare name, an `index(u, i…)` gather, or any
// other wrapper; the base name is the first free symbol reachable through it. An
// `aggregate` whose `expr` is a derivative is the whole-array spelling of the
// same thing and credits the same variable, which is why the walk descends
// `expr` as well as `args`.
func derivativeTargets(expr Expression, indep string) map[string]bool {
	out := map[string]bool{}
	collectDerivativeTargets(expr, indep, out)
	return out
}

func collectDerivativeTargets(expr Expression, indep string, out map[string]bool) {
	node, ok := asExprNode(expr)
	if !ok {
		return
	}
	if node.Op == OpDerivative && derivativeIsTemporal(node, indep) {
		for _, a := range node.Args {
			for _, n := range leafNames(a) {
				out[n] = true
			}
		}
		return
	}
	for _, child := range exprRefChildren(node) {
		collectDerivativeTargets(child.Child, indep, out)
	}
}

// derivativeIsTemporal reports whether a `D` node differentiates with respect to
// the independent variable. `wrt` absent means the temporal derivative (the
// spec's default); an explicit `wrt` naming a spatial dimension is a rewrite
// target, not a time derivative, and must NOT make its operand an ODE state.
func derivativeIsTemporal(node ExprNode, indep string) bool {
	if node.Wrt == nil {
		return true
	}
	return *node.Wrt == indep
}

// leafNames returns the free symbol names reachable inside an expression: the
// bare string itself, or every string leaf of a wrapper node. It stops at the
// first level that yields names so `index(u, i)` credits `u` and `i` alike —
// harmless, since only declared unknowns are kept by the caller.
func leafNames(expr Expression) []string {
	if name, ok := expr.(string); ok {
		return []string{name}
	}
	node, ok := asExprNode(expr)
	if !ok {
		return nil
	}
	var out []string
	for _, child := range exprRefChildren(node) {
		out = append(out, leafNames(child.Child)...)
	}
	return out
}

// hasTimeDerivative reports whether ANY equation LHS carries a time derivative,
// whether or not its operand resolves to a declared unknown. "No time-derivative
// equation at all" is what makes a system `nonlinear`.
func hasTimeDerivative(model *Model) bool {
	for _, eq := range model.Equations {
		if len(derivativeTargets(eq.LHS, DefaultIndepVar)) > 0 {
			return true
		}
	}
	return false
}

// hasDifferentialOperator reports whether any equation uses a SPATIAL
// differential operator — a `D` with an explicit non-temporal `wrt`, or one of
// the named vector-calculus ops.
func hasDifferentialOperator(model *Model) bool {
	for _, eq := range model.Equations {
		if exprHasSpatialOperator(eq.LHS) || exprHasSpatialOperator(eq.RHS) {
			return true
		}
	}
	return false
}

// spatialOperatorOps is exactly the three sugar ops esm-spec 6.3.1 names. The
// open rewrite-target tier is unbounded, so the rule cannot be "any op that
// looks differential" and still agree across five bindings; anything else
// spatial is written as a `D` with a non-`t` `wrt`, handled just below.
var spatialOperatorOps = map[string]struct{}{
	"grad": {}, "div": {}, "laplacian": {},
}

func exprHasSpatialOperator(expr Expression) bool {
	node, ok := asExprNode(expr)
	if !ok {
		return false
	}
	if _, isSpatial := spatialOperatorOps[node.Op]; isSpatial {
		return true
	}
	if node.Op == OpDerivative && node.Wrt != nil && *node.Wrt != DefaultIndepVar {
		return true
	}
	for _, child := range exprRefChildren(node) {
		if exprHasSpatialOperator(child.Child) {
			return true
		}
	}
	return false
}

// isSpatialDomain reports whether the document's domain describes a spatial
// extent. Since v0.8.0 the domain carries no geometry block, so the only signal
// left is an independent variable other than time.
func isSpatialDomain(domain *Domain) bool {
	if domain == nil {
		return false
	}
	return domain.IndependentVariable != nil && *domain.IndependentVariable != DefaultIndepVar
}

// isBrownianVar reports whether any of a variable's update rules is `wiener`.
func isBrownianVar(v ModelVariable) bool {
	for _, rule := range v.UpdateRules() {
		if rule.IsBrownian() {
			return true
		}
	}
	return false
}

func parametersWhere(model *Model, pred func(ModelVariable) bool) []string {
	if model == nil {
		return nil
	}
	var out []string
	for name, v := range model.Variables {
		if v.Type == VarTypeParameter && pred(v) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// sortedNamesIn filters a membership set down to the model's declared variables
// and returns the survivors sorted.
func sortedNamesIn(set map[string]bool, model *Model) []string {
	var out []string
	for name := range set {
		if _, ok := model.Variables[name]; ok {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}
