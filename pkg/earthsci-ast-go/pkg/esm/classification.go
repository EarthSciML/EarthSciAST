package esm

import "sort"

// classification.go implements the esm-spec §6.3.1 classification API: the pure
// functions that recover, from the two declared variable types, the finer
// categories a solver needs.
//
// This file is the ONLY sanctioned way to ask these questions. Before 1.0.0 the
// format declared `state`, `observed`, `brownian` and `discrete`, and code
// branched on `variable.type == "state"`. Those types are gone, and reading a
// declared type to answer a derived question is exactly what 1.0.0 removes — so
// every such site calls in here instead.
//
// Two sets of PARTITIONS, pinned cross-language by
// tests/conformance/classification/:
//
//	unknowns   = ODEStates ⊎ ObservedUnknowns ⊎ AlgebraicUnknowns
//	parameters = BrownianParameters ⊎ DiscreteParameters ⊎
//	             SampledParameters ⊎ ConstantParameters
//
// Naming follows Go's idiom, as the spec's `naming` clause directs: the
// snake_case `ode_states` of Julia/Python/Rust is spelled `ODEStates` here.
//
// Every returned list is sorted lexicographically by byte order. That is what
// makes the cross-language goldens order-independent, and since
// CONFORMANCE_SPEC §7.1.0 it is also the order a list-valued diagnostic detail
// reports — Go decodes `variables` into a plain map and cannot produce
// declaration order at all.
//
// ── The independent variable ────────────────────────────────────────────────
//
// "Under D(·, t)" needs to know what `t` is, and the document — not the model —
// declares it (`domain.independent_variable`). The bare functions therefore
// assume the "t" default, and each carries an `…In(file, model)` companion that
// threads the document's actual choice. The four parameter partitions need no
// such companion: a parameter's cadence is decided entirely by its own
// `distribution` and `update`.

// The derived classes, as reported by FlattenedSystem.Variables and by any
// caller that wants to name a class rather than test membership.
const (
	ClassODEState          = "ode_state"
	ClassObserved          = "observed"
	ClassAlgebraic         = "algebraic"
	ClassBrownianParameter = "brownian_parameter"
	ClassDiscreteParameter = "discrete_parameter"
	ClassSampledParameter  = "sampled_parameter"
	ClassConstantParameter = "constant_parameter"
)

// ---------------------------------------------------------------------------
// Unknowns
// ---------------------------------------------------------------------------

// ODEStates returns the model's unknowns that appear under a time derivative
// `D(·, t)` on some equation LHS, sorted.
//
// The independent variable is assumed to be "t"; use ODEStatesIn for a document
// that declares another.
func ODEStates(model *Model) []string { return ODEStatesIn(nil, model) }

// ODEStatesIn is ODEStates against the document's declared independent variable.
func ODEStatesIn(file *ESMFile, model *Model) []string {
	return sortedSet(classifyUnknowns(file, model).ode)
}

// IsODEState reports whether name is one of the model's ODE states — the
// membership test §6.3.1 requires alongside the set.
//
// This is what a site that used to ask `variable.type == "state"` calls.
func IsODEState(model *Model, name string) bool { return IsODEStateIn(nil, model, name) }

// IsODEStateIn is IsODEState against the document's declared independent
// variable.
func IsODEStateIn(file *ESMFile, model *Model, name string) bool {
	return classifyUnknowns(file, model).ode[name]
}

// ObservedUnknowns returns the model's unknowns defined by a BARE-VARIABLE LHS
// (`y ~ f(…)`), sorted — the eliminable, materializable quantities.
//
// This is what a site that used to ask `variable.type == "observed"` calls, and
// where an observed's defining expression now lives: 1.0.0 removed the variable
// `expression` field, so the definition is the equation whose LHS is this name.
func ObservedUnknowns(model *Model) []string { return ObservedUnknownsIn(nil, model) }

// ObservedUnknownsIn is ObservedUnknowns against the document's declared
// independent variable.
func ObservedUnknownsIn(file *ESMFile, model *Model) []string {
	return sortedSet(classifyUnknowns(file, model).observed)
}

// AlgebraicUnknowns returns the model's unknowns constrained only IMPLICITLY —
// by an equation whose LHS is an arbitrary expression (`H*H*SO4 ~ Ksp`) rather
// than an assignment target — sorted.
//
// It is the residue of the partition: an unknown that is neither an ODE state
// nor observed. That includes an unknown NO equation mentions, which is an
// unbalanced system and is separately reported as equation_count_mismatch
// (esm-spec §4.9.4); classification stays total rather than silently dropping it
// and breaking the partition.
func AlgebraicUnknowns(model *Model) []string { return AlgebraicUnknownsIn(nil, model) }

// AlgebraicUnknownsIn is AlgebraicUnknowns against the document's declared
// independent variable.
func AlgebraicUnknownsIn(file *ESMFile, model *Model) []string {
	return sortedSet(classifyUnknowns(file, model).algebraic)
}

// Unknowns returns every unknown the model declares, sorted — the union the
// three partitions cover.
func Unknowns(model *Model) []string {
	out := map[string]bool{}
	if model != nil {
		for name, v := range model.Variables {
			if v.Type == VarTypeUnknown {
				out[name] = true
			}
		}
	}
	return sortedSet(out)
}

// ObservedDefinition returns the RHS of the equation defining an observed
// unknown, and whether one was found.
//
// This is the 1.0.0 relocation made available to callers: what used to be
// `variables[v].expression` is now the RHS of the bare-variable-LHS equation
// whose target is v. Any consumer that used to read the removed field asks here
// instead — including a cadence pass seeding an observed leaf from its defining
// equation (CONFORMANCE_SPEC §5.7.2), should this binding ever grow one.
func ObservedDefinition(model *Model, name string) (Expression, bool) {
	return ObservedDefinitionIn(nil, model, name)
}

// ObservedDefinitionIn is ObservedDefinition against the document's declared
// independent variable.
func ObservedDefinitionIn(file *ESMFile, model *Model, name string) (Expression, bool) {
	if model == nil {
		return nil, false
	}
	indep := indepVarOf(file)
	for _, eq := range model.Equations {
		if len(countDerivatives(eq.LHS, indep)) > 0 {
			continue
		}
		if assignmentTargetOf(eq.LHS) == name {
			return eq.RHS, true
		}
	}
	return nil, false
}

// unknownPartition is the computed three-way split of a model's unknowns.
type unknownPartition struct {
	ode       map[string]bool
	observed  map[string]bool
	algebraic map[string]bool
}

// classifyUnknowns performs the §6.3.1 unknown split in one pass.
//
// Precedence is ODE state ▸ observed ▸ algebraic, and it has to be a
// precedence rather than three independent tests, because the three sets must
// PARTITION: a variable both differentiated in one equation and assigned in
// another would otherwise land in two buckets. Differentiation wins — the
// solver integrates it either way, and the assignment is then a constraint on
// an integrated state rather than a definition of a derived one.
func classifyUnknowns(file *ESMFile, model *Model) unknownPartition {
	p := unknownPartition{
		ode:       map[string]bool{},
		observed:  map[string]bool{},
		algebraic: map[string]bool{},
	}
	if model == nil {
		return p
	}
	indep := indepVarOf(file)

	unknowns := map[string]bool{}
	for name, v := range model.Variables {
		if v.Type == VarTypeUnknown {
			unknowns[name] = true
		}
	}

	assigned := map[string]bool{}
	for _, eq := range model.Equations {
		// A derivative may be WRAPPED: `D(u)`, `D(u[i])` (i.e. `D(index(u,i))`),
		// and an `aggregate` whose `expr` is a `D(...)` all credit the base
		// variable. countDerivatives walks every expression-bearing field, so the
		// array-form equation that hides its D inside an aggregate's contracted
		// body is found too — looking only at a top-level `D` LHS is what used to
		// make Go report "0 ODE equations" for two dozen good fixtures.
		if derivs := countDerivatives(eq.LHS, indep); len(derivs) > 0 {
			for name := range derivs {
				if unknowns[name] {
					p.ode[name] = true
				}
			}
			continue
		}
		// Not a derivative: an assignment target makes the unknown OBSERVED, an
		// arbitrary expression LHS leaves it (and anything it mentions) algebraic.
		if target := assignmentTargetOf(eq.LHS); target != "" && unknowns[target] {
			assigned[target] = true
		}
	}

	for name := range unknowns {
		switch {
		case p.ode[name]:
			// already placed
		case assigned[name]:
			p.observed[name] = true
		default:
			p.algebraic[name] = true
		}
	}
	return p
}

// assignmentTargetOf returns the single variable an equation LHS assigns to — a
// bare name, an `index(v, …)` element, or the target inside an `aggregate`'s
// contracted body — and "" for an arbitrary expression LHS such as
// `H*H*SO4`, which assigns to nothing and therefore constrains implicitly.
//
// An `ic` LHS prescribes an initial value rather than the dynamics and is
// deliberately excluded: extractVariableFromLHS does not treat `ic` as an
// assignment target, so an `ic`-only unknown stays algebraic here and shows up
// in the balance check, which is where a missing defining equation belongs.
func assignmentTargetOf(lhs Expression) string { return extractVariableFromLHS(lhs) }

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

// BrownianParameters returns the model's parameters whose update kind is
// `wiener` — the SDE noise sources — sorted.
//
// This is what a site that used to ask `variable.type == "brownian"` calls. The
// 0.x `noise_kind` / `correlation_group` sidecars are gone: `wiener` is the only
// process, and correlated noise is one vector-valued parameter whose
// distribution carries a `cov`.
func BrownianParameters(model *Model) []string {
	return sortedSet(classifyParameters(model).brownian)
}

// DiscreteParameters returns the model's parameters carrying any OTHER update —
// piecewise-constant between refreshes — sorted.
//
// This is what a site that used to ask `variable.type == "discrete"` calls, and
// it is the sole seed of the DISCRETE cadence class (CONFORMANCE_SPEC §5.7.2).
func DiscreteParameters(model *Model) []string {
	return sortedSet(classifyParameters(model).discrete)
}

// SampledParameters returns the model's parameters with a `distribution` and NO
// `update` — drawn once at setup, the uncertainty-quantification / ensemble
// case — sorted.
func SampledParameters(model *Model) []string {
	return sortedSet(classifyParameters(model).sampled)
}

// ConstantParameters returns the model's parameters with neither a
// `distribution` nor an `update` — plain constants — sorted.
func ConstantParameters(model *Model) []string {
	return sortedSet(classifyParameters(model).constant)
}

// parameterPartition is the computed four-way split of a model's parameters.
type parameterPartition struct {
	brownian map[string]bool
	discrete map[string]bool
	sampled  map[string]bool
	constant map[string]bool
}

// classifyParameters performs the §6.3.1 parameter split in one pass.
//
// The two easy mistakes the conformance fixture `parameter_cadences` exists to
// catch are both avoided by testing UPDATE FIRST and DISTRIBUTION SECOND: a
// parameter with a distribution is not thereby Brownian (only a `wiener` update
// makes it so), and a parameter with an update is not thereby Brownian either
// (any non-wiener update makes it discrete, whether or not it also carries a
// distribution).
func classifyParameters(model *Model) parameterPartition {
	p := parameterPartition{
		brownian: map[string]bool{},
		discrete: map[string]bool{},
		sampled:  map[string]bool{},
		constant: map[string]bool{},
	}
	if model == nil {
		return p
	}
	for name, v := range model.Variables {
		if v.Type != VarTypeParameter {
			continue
		}
		switch {
		case v.Update.IsWiener():
			p.brownian[name] = true
		case v.Update != nil && len(v.Update.Rules) > 0:
			p.discrete[name] = true
		case v.Distribution != nil:
			p.sampled[name] = true
		default:
			p.constant[name] = true
		}
	}
	return p
}

// ClassOf returns the derived class of a declared variable — one of the seven
// Class* constants — and whether the model declares it at all. It is the
// single-name form of the two partitions, for a caller that wants to label a
// variable rather than enumerate a category.
func ClassOf(file *ESMFile, model *Model, name string) (string, bool) {
	if model == nil {
		return "", false
	}
	v, ok := model.Variables[name]
	if !ok {
		return "", false
	}
	if v.Type == VarTypeParameter {
		p := classifyParameters(model)
		switch {
		case p.brownian[name]:
			return ClassBrownianParameter, true
		case p.discrete[name]:
			return ClassDiscreteParameter, true
		case p.sampled[name]:
			return ClassSampledParameter, true
		default:
			return ClassConstantParameter, true
		}
	}
	u := classifyUnknowns(file, model)
	switch {
	case u.ode[name]:
		return ClassODEState, true
	case u.observed[name]:
		return ClassObserved, true
	default:
		return ClassAlgebraic, true
	}
}

// ---------------------------------------------------------------------------
// System kind
// ---------------------------------------------------------------------------

// SystemKind derives what the `system_kind` field declares (esm-spec §6.3.1),
// testing four conditions IN THIS ORDER and taking the first that holds:
//
//  1. any parameter in BrownianParameters       ⇒ "sde"
//  2. any equation contains a spatial derivative ⇒ "pde"
//  3. no time-derivative equation at all         ⇒ "nonlinear"
//  4. otherwise                                  ⇒ "ode"
//
// A binding uses the derivation when the field is ABSENT, and a present field
// that contradicts it is `system_kind_mismatch`.
//
// Both orderings are load-bearing and neither is interchangeable:
//
//   - "pde" BEFORE "nonlinear", because a steady-state PDE (`laplacian(u) ~ f`)
//     has no time-derivative equation and would otherwise fall through to
//     "nonlinear". It is a PDE, and PDESystem is what it maps to.
//   - "sde" BEFORE "pde", because a model carrying both a wiener parameter and a
//     spatial derivative has no SPDESystem constructor to select; it is
//     assembled as an SDE.
//
// The rule is stated over the EQUATIONS, not over a domain block: v0.8.0 removed
// `Domain.spatial`, so there is no spatial domain left to test and the
// differential operators are the whole signal.
func SystemKind(model *Model) string { return SystemKindIn(nil, model) }

// SystemKindIn is SystemKind against the document's declared independent
// variable.
func SystemKindIn(file *ESMFile, model *Model) string {
	if model == nil {
		return SystemKindODE
	}
	if len(BrownianParameters(model)) > 0 {
		return SystemKindSDE
	}
	indep := indepVarOf(file)
	if hasSpatialDerivative(model, indep) {
		return SystemKindPDE
	}
	for _, eq := range model.Equations {
		if len(countDerivatives(eq.LHS, indep)) > 0 {
			return SystemKindODE
		}
	}
	return SystemKindNonlinear
}

// DeclaredSystemKind returns the model's explicit `system_kind` field and
// whether it was present — the `declared_system_kind` of the classification
// goldens, and the left-hand side of a system_kind_mismatch comparison.
func DeclaredSystemKind(model *Model) (string, bool) {
	if model == nil || model.SystemKind == nil {
		return "", false
	}
	return *model.SystemKind, true
}

// spatialSugarOps are the sugar spellings of a spatial derivative (esm-spec
// §4.2). They are OPEN-tier rewrite targets, so neither they nor the explicit
// `D`-with-a-spatial-`wrt` form is canonical and both must be recognized.
var spatialSugarOps = map[string]bool{
	"grad": true, "div": true, "laplacian": true,
}

// hasSpatialDerivative reports whether any equation of the model contains a
// spatial derivative: a `D` node whose `wrt` is PRESENT and is not the
// independent variable, or one of the grad / div / laplacian sugar ops.
//
// It is detected anywhere in an equation's LHS or RHS, and the walk descends
// every Expression child rather than `args` alone (§4.9.5) — a `laplacian`
// buried in an aggregate's `expr` or an integral bound is still a spatial
// derivative.
//
// A `D` with NO `wrt` is a time derivative by the package-wide convention
// (isDifferentialEquation, countDerivatives), so it is deliberately not spatial
// here.
func hasSpatialDerivative(model *Model, indep string) bool {
	found := false
	var walk func(Expression)
	walk = func(e Expression) {
		if found {
			return
		}
		node, ok := asExprNode(e)
		if !ok {
			return
		}
		if spatialSugarOps[node.Op] {
			found = true
			return
		}
		if node.Op == OpDerivative && node.Wrt != nil && *node.Wrt != indep {
			found = true
			return
		}
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walk(child)
			return child, nil
		})
	}
	for _, eq := range model.Equations {
		walk(eq.LHS)
		walk(eq.RHS)
		if found {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

// indepVarOf returns the document's independent variable, defaulting to "t"
// when there is no document or it declares none. It is fileIndepVar widened to
// accept a nil file, so the bare (model-only) classification functions and their
// `…In` companions share one code path.
func indepVarOf(file *ESMFile) string {
	if file == nil {
		return DefaultIndepVar
	}
	return fileIndepVar(file)
}

// sortedSet renders a membership set as a lexicographically sorted slice. A nil
// or empty set renders as an EMPTY slice rather than nil, so it marshals to `[]`
// and not `null` — the classification goldens spell an empty category `[]`.
func sortedSet(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}
