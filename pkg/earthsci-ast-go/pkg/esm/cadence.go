package esm

import (
	"fmt"
	"sort"
	"strings"
)

// cadence.go implements the CONFORMANCE_SPEC §5.7 cadence-partition pass: every
// node's class is a pure function of the data-dependency DAG,
// `class(node) = max` over its inputs, bottoming out at leaf seeds.
//
// The leaf seeds are DERIVED, never declared. §5.7.2 states the seed table in
// terms of the esm-spec §6.3.1 classification functions precisely so that five
// bindings cannot disagree about which nodes fold, so this file calls
// classify.go rather than re-deriving "is this constant / discrete / …" from the
// variable declarations. Two consequences the fixtures pin:
//
//   - An OBSERVED unknown seeds from the class of its DEFINING EQUATION's RHS,
//     resolved transitively with a cycle guard. This is the one place the pass
//     must follow the 1.0.0 relocation of an observed's definition out of
//     `variables[v].expression` and into `equations`. Seeding every unknown
//     CONTINUOUS is sound but stops a state-free observed folding at bind, which
//     the geometry and projection-pushdown paths rely on; seeding an observed
//     CONST (the 0.x shortcut) is unsound the other way, since an observed
//     reading a state is CONTINUOUS.
//   - A parameter fed by a `data` update is refined by ITS SOURCE: a source with
//     a `temporal` block keeps it DISCRETE, one without refines it to CONST.
//     That distinction survived the data_loaders → data_sources rename.

// Cadence is a value's evaluation class, forming the total order
// CadenceConst ⊏ CadenceDiscrete ⊏ CadenceContinuous (CONFORMANCE_SPEC §5.7.1).
type Cadence int

const (
	// CadenceConst never changes: evaluated once and folded into the artifact.
	CadenceConst Cadence = iota
	// CadenceDiscrete changes only at discrete events, and is piecewise-constant
	// between them: evaluated at setup and on each refresh, memoized between.
	CadenceDiscrete
	// CadenceContinuous changes every step: evaluated on every RHS call.
	CadenceContinuous
)

// String renders the class in the spelling `expect_cadence` and the conformance
// goldens use.
func (c Cadence) String() string {
	switch c {
	case CadenceConst:
		return "const"
	case CadenceDiscrete:
		return "discrete"
	case CadenceContinuous:
		return "continuous"
	default:
		return fmt.Sprintf("Cadence(%d)", int(c))
	}
}

// ParseCadence maps an `expect_cadence` annotation to its class.
func ParseCadence(s string) (Cadence, bool) {
	switch s {
	case "const":
		return CadenceConst, true
	case "discrete":
		return CadenceDiscrete, true
	case "continuous":
		return CadenceContinuous, true
	}
	return CadenceConst, false
}

// joinCadence is the lattice join (max) — the §5.7.3 propagation rule.
func joinCadence(a, b Cadence) Cadence {
	if b > a {
		return b
	}
	return a
}

// CadenceError is a cadence-partition contract violation: an observed-definition
// cycle (§5.7.2), a failed `expect_cadence` assertion (§5.7.6 guard 3), or a
// relational node on the hot path (guard 2).
type CadenceError struct {
	Code    string
	Message string
}

func (e *CadenceError) Error() string { return fmt.Sprintf("[%s] %s", e.Code, e.Message) }

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *CadenceError) DiagnosticCode() string { return e.Code }

// Cadence-partition diagnostic codes.
const (
	CodeCadenceObservedCycle        = "cadence_observed_cycle"
	CodeCadenceExpectMismatch       = "cadence_expect_mismatch"
	CodeCadenceContinuousRelational = "cadence_continuous_relational"
)

// CadenceClassifier derives cadence classes for one model. Build it with
// NewCadenceClassifier; it memoises observed-leaf resolution, so reuse one
// instance across a model's equations rather than rebuilding it per node.
type CadenceClassifier struct {
	model *Model
	// sources is the document's data_sources registry, needed for the §5.7.2
	// source-seeded refinement. Nil when the document declares none.
	sources map[string]DataSource
	// indep is the document's independent variable, which always seeds
	// CONTINUOUS.
	indep string

	// leafSeeds caches the derived seed of every variable name.
	leafSeeds map[string]Cadence
	// observedDefs maps an observed unknown to its defining equation's RHS.
	observedDefs map[string]Expression
	// odeStates / brownian / discrete are the §6.3.1 partitions, resolved once.
	odeStates map[string]bool
	brownian  map[string]bool
	discrete  map[string]bool
}

// NewCadenceClassifier builds the classifier for one model of a document. Pass
// the whole file so the `data` update's source refinement (§5.7.2) can resolve;
// a nil file is accepted and simply loses that refinement.
func NewCadenceClassifier(file *ESMFile, model *Model) *CadenceClassifier {
	c := &CadenceClassifier{
		model:        model,
		indep:        DefaultIndepVar,
		leafSeeds:    map[string]Cadence{},
		observedDefs: map[string]Expression{},
		odeStates:    map[string]bool{},
		brownian:     map[string]bool{},
		discrete:     map[string]bool{},
	}
	if file != nil {
		c.sources = file.DataSources
		c.indep = fileIndepVar(file)
	}
	if model == nil {
		return c
	}
	// Seed straight from the §6.3.1 classification functions — NOT from a local
	// re-derivation. §5.7.2 makes this mandatory.
	c.observedDefs = observedDefinitions(model)
	for _, n := range ODEStates(model) {
		c.odeStates[n] = true
	}
	for _, n := range BrownianParameters(model) {
		c.brownian[n] = true
	}
	for _, n := range DiscreteParameters(model) {
		c.discrete[n] = true
	}
	return c
}

// Classify derives an expression's cadence class: for a leaf, its seed; for an
// operator node, the join over its children (§5.7.3). For a gather
// `index(A, e…)` the index expressions are classed independently of the array,
// which is simply what "join over children" already does — no special case is
// needed, and the stencil split falls out of it.
func (c *CadenceClassifier) Classify(expr Expression) (Cadence, error) {
	return c.classify(expr, nil)
}

func (c *CadenceClassifier) classify(expr Expression, resolving []string) (Cadence, error) {
	node, ok := asExprNode(expr)
	if !ok {
		return c.seedLeaf(expr, resolving)
	}
	class := CadenceConst
	for _, child := range exprRefChildren(node) {
		cc, err := c.classify(child.Child, resolving)
		if err != nil {
			return CadenceConst, err
		}
		class = joinCadence(class, cc)
	}
	return class, nil
}

// SeedLeaf derives a leaf's cadence from its ROLE, per the §5.7.2 seed table.
func (c *CadenceClassifier) SeedLeaf(leaf Expression) (Cadence, error) {
	return c.seedLeaf(leaf, nil)
}

func (c *CadenceClassifier) seedLeaf(leaf Expression, resolving []string) (Cadence, error) {
	name, ok := leaf.(string)
	if !ok {
		// Numeric literal, boolean, json.Number, or a non-operator raw value:
		// CONST.
		return CadenceConst, nil
	}
	if name == c.indep {
		// The independent variable. An explicit continuous-t forcing is not
		// piecewise-constant between events, so it must recompute every step.
		return CadenceContinuous, nil
	}
	if c.model == nil {
		return CadenceConst, nil
	}
	v, declared := c.model.Variables[name]
	if !declared {
		// Index-set name, bound index symbol, relation tag: CONST topology.
		return CadenceConst, nil
	}
	if cached, ok := c.leafSeeds[name]; ok {
		return cached, nil
	}

	switch v.Type {
	case VarTypeUnknown:
		// An OBSERVED unknown resolves to the class of its DEFINING EQUATION's
		// RHS, transitively and with a cycle guard. An ODE state or an algebraic
		// unknown is CONTINUOUS.
		if rhs, isObserved := c.observedDefs[name]; isObserved && !c.odeStates[name] {
			for _, r := range resolving {
				if r == name {
					return CadenceConst, &CadenceError{
						Code: CodeCadenceObservedCycle,
						Message: fmt.Sprintf("observed definition cycle through %q: %s",
							name, strings.Join(append(append([]string{}, resolving...), name), " -> ")),
					}
				}
			}
			class, err := c.classify(rhs, append(append([]string{}, resolving...), name))
			if err != nil {
				return CadenceConst, err
			}
			// Only memoise a fully-resolved seed (one derived with no enclosing
			// resolution in flight), so a partial chain can never poison the
			// cache.
			if len(resolving) == 0 {
				c.leafSeeds[name] = class
			}
			return class, nil
		}
		c.leafSeeds[name] = CadenceContinuous
		return CadenceContinuous, nil

	case VarTypeParameter:
		class := c.parameterSeed(name, v)
		c.leafSeeds[name] = class
		return class, nil
	}
	return CadenceConst, nil
}

// parameterSeed applies the §5.7.2 parameter rows plus the source-seeded
// refinement. It reads the §6.3.1 partitions rather than re-inspecting `update`,
// so "which parameters are discrete" has exactly one definition in this binding.
func (c *CadenceClassifier) parameterSeed(name string, v ModelVariable) Cadence {
	if c.brownian[name] {
		// A driving Wiener process is resampled every step.
		return CadenceContinuous
	}
	if !c.discrete[name] {
		// Constant or sampled-once: CONST either way.
		return CadenceConst
	}
	// Source-seeded refinement (CONFORMANCE_SPEC §5.7.2 / RFC
	// pure-io-data-loaders §4.6): a parameter fed by a `data` update whose source
	// declares NO `temporal` block describes non-time-varying data and refines
	// down to CONST (still folding at bind). With `temporal` — or any other
	// update kind, or a source that resolves to no entry — it stays DISCRETE.
	if c.dataUpdateWithoutTemporal(v) {
		return CadenceConst
	}
	return CadenceDiscrete
}

func (c *CadenceClassifier) dataUpdateWithoutTemporal(v ModelVariable) bool {
	rules := v.UpdateRules()
	if len(rules) != 1 || rules[0].Kind != UpdateKindData {
		return false
	}
	src, ok := c.sources[rules[0].Source]
	if !ok {
		return false
	}
	return !src.IsTimeVarying()
}

// CheckExpectCadence walks every equation of the model and asserts that wherever
// a node carries an `expect_cadence` annotation the derived class agrees
// (CONFORMANCE_SPEC §5.7.6 guard 3). The annotation is a checked assertion, not
// a control input: it changes no semantics, and a disagreement is a defect.
func (c *CadenceClassifier) CheckExpectCadence() []error {
	if c.model == nil {
		return nil
	}
	var problems []error
	for i, eq := range c.model.Equations {
		for _, side := range []struct {
			path string
			expr Expression
		}{
			{fmt.Sprintf("/equations/%d/lhs", i), eq.LHS},
			{fmt.Sprintf("/equations/%d/rhs", i), eq.RHS},
		} {
			problems = append(problems, c.checkExpectCadence(side.expr, side.path)...)
		}
	}
	return problems
}

func (c *CadenceClassifier) checkExpectCadence(expr Expression, path string) []error {
	node, ok := asExprNode(expr)
	if !ok {
		return nil
	}
	var problems []error
	if node.ExpectCadence != nil {
		want, known := ParseCadence(*node.ExpectCadence)
		got, err := c.Classify(node)
		switch {
		case err != nil:
			problems = append(problems, err)
		case !known:
			problems = append(problems, &CadenceError{
				Code:    CodeCadenceExpectMismatch,
				Message: fmt.Sprintf("%s: unknown expect_cadence %q", path, *node.ExpectCadence),
			})
		case got != want:
			problems = append(problems, &CadenceError{
				Code: CodeCadenceExpectMismatch,
				Message: fmt.Sprintf("%s: op=%q declares expect_cadence %q but derives %q",
					path, node.Op, want, got),
			})
		}
	}
	for _, child := range exprRefChildren(node) {
		problems = append(problems, c.checkExpectCadence(child.Child, path+child.Path)...)
	}
	return problems
}

// relationalOps are the value-invention / relational-engine ops that guard 2
// (§5.7.6) forbids on the hot path.
var relationalOps = map[string]struct{}{
	"distinct": {}, "join": {}, "skolem": {}, "rank": {}, "argmin": {}, "argmax": {},
}

// CheckNoContinuousRelational is §5.7.6 guard 2: a
// distinct/join/skolem/rank/argmin/argmax node (or a `distinct` aggregate) that
// classifies CONTINUOUS is rejected — state-dependent topology may not run per
// step in v1.
func (c *CadenceClassifier) CheckNoContinuousRelational() []error {
	if c.model == nil {
		return nil
	}
	var problems []error
	for i, eq := range c.model.Equations {
		problems = append(problems, c.checkRelational(eq.LHS, fmt.Sprintf("/equations/%d/lhs", i))...)
		problems = append(problems, c.checkRelational(eq.RHS, fmt.Sprintf("/equations/%d/rhs", i))...)
	}
	return problems
}

func (c *CadenceClassifier) checkRelational(expr Expression, path string) []error {
	node, ok := asExprNode(expr)
	if !ok {
		return nil
	}
	var problems []error
	_, named := relationalOps[node.Op]
	isRelational := named || (node.Op == "aggregate" && node.Distinct != nil && *node.Distinct)
	if isRelational {
		if class, err := c.Classify(node); err == nil && class == CadenceContinuous {
			problems = append(problems, &CadenceError{
				Code: CodeCadenceContinuousRelational,
				Message: fmt.Sprintf("%s: relational/value-invention node op=%q classifies CONTINUOUS; "+
					"it may not run on the hot path (CONFORMANCE_SPEC §5.7.6 guard 2)", path, node.Op),
			})
		}
	}
	for _, child := range exprRefChildren(node) {
		problems = append(problems, c.checkRelational(child.Child, path+child.Path)...)
	}
	return problems
}

// LeafSeeds returns the derived seed of every declared variable of the model,
// keyed by name — the observable form of the §5.7.2 table, useful for
// diagnostics and for a conformance adapter.
func (c *CadenceClassifier) LeafSeeds() (map[string]Cadence, error) {
	if c.model == nil {
		return nil, nil
	}
	names := make([]string, 0, len(c.model.Variables))
	for name := range c.model.Variables {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make(map[string]Cadence, len(names))
	for _, name := range names {
		class, err := c.SeedLeaf(name)
		if err != nil {
			return nil, err
		}
		out[name] = class
	}
	return out, nil
}
