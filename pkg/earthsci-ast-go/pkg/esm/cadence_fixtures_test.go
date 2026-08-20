package esm

import (
	"path/filepath"
	"testing"
)

// TestCadenceValidFixtures asserts every tests/valid/cadence/*.esm fixture
// parses and schema-validates cleanly through the Go loader. They exercise the
// additive `expect_cadence` enum on ExpressionNode (the partition pass's
// author-assertion / diagnostic hook). Cross-binding class / materialization /
// CONST-fold goldens are asserted by scripts/run-cadence-conformance.py
// (CONFORMANCE_SPEC §5.7).
func TestCadenceValidFixtures(t *testing.T) {
	for _, path := range cadenceFixturePaths(t) {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			if _, err := Load(path); err != nil {
				t.Fatalf("expected %s to validate, got error: %v", name, err)
			}
		})
	}
}

func cadenceFixturePaths(t *testing.T) []string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "cadence", "*.esm")
	files, err := filepath.Glob(pattern)
	if err != nil {
		t.Fatalf("glob %s: %v", pattern, err)
	}
	if len(files) == 0 {
		t.Fatalf("no .esm fixtures matched %s", pattern)
	}
	return files
}

// TestCadenceExpectAnnotationsAgree runs the Go partition pass (cadence.go) over
// every `tests/valid/cadence` fixture and asserts that wherever a node carries an
// `expect_cadence` annotation the DERIVED class agrees — CONFORMANCE_SPEC §5.7.6
// guard 3.
//
// This is the behavioural half of the port. The classes are derived from leaf
// seeds that come from the esm-spec §6.3.1 classification functions and NOT from
// a local re-derivation (§5.7.2 requires exactly that, so that five bindings
// cannot disagree about which nodes fold).
func TestCadenceExpectAnnotationsAgree(t *testing.T) {
	for _, path := range cadenceFixturePaths(t) {
		path := path
		t.Run(filepath.Base(path), func(t *testing.T) {
			file, err := Load(path)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			annotated := 0
			for _, name := range sortedKeys(file.Models) {
				model := file.Models[name]
				c := NewCadenceClassifier(file, &model)
				for _, problem := range c.CheckExpectCadence() {
					t.Errorf("%s: %v", name, problem)
				}
				for _, problem := range c.CheckNoContinuousRelational() {
					t.Errorf("%s: %v", name, problem)
				}
				annotated += countExpectCadenceAnnotations(&model)
			}
			if annotated == 0 {
				t.Errorf("no expect_cadence annotation found — the assertion would pass vacuously")
			}
		})
	}
}

func countExpectCadenceAnnotations(model *Model) int {
	n := 0
	var walk func(Expression)
	walk = func(e Expression) {
		node, ok := asExprNode(e)
		if !ok {
			return
		}
		if node.ExpectCadence != nil {
			n++
		}
		for _, child := range exprRefChildren(node) {
			walk(child.Child)
		}
	}
	for _, eq := range model.Equations {
		walk(eq.LHS)
		walk(eq.RHS)
	}
	return n
}

// TestCadenceObservedLeafSeeds is the discriminating case of CONFORMANCE_SPEC
// §5.7.2: an OBSERVED unknown's leaf seed is the class of its DEFINING
// EQUATION's RHS, resolved transitively.
//
// tests/valid/cadence/observed_leaf_seeds.esm rules out BOTH wrong answers at
// once. Seeding every unknown CONTINUOUS is sound but stops the state-free
// `geom` folding at bind, and const-folding exactly those is what the geometry
// and projection-pushdown paths rely on. Seeding an observed CONST — the 0.x
// shortcut, whose own comment admitted it was imprecise and unexercised — is
// unsound the other way, since `u_scaled` reads a state and is genuinely
// CONTINUOUS. `geom_chain` additionally pins that the resolution is TRANSITIVE:
// it reads another observed, so one level of lookup is not enough.
func TestCadenceObservedLeafSeeds(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	file, err := Load(filepath.Join(repoRoot, "tests", "valid", "cadence", "observed_leaf_seeds.esm"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	model := file.Models["ObservedLeafSeeds"]
	c := NewCadenceClassifier(file, &model)

	want := map[string]Cadence{
		"u":          CadenceContinuous, // ODE state
		"dx":         CadenceConst,      // plain constant parameter
		"Kdiff":      CadenceDiscrete,   // schedule update
		"geom":       CadenceConst,      // observed reading only parameters
		"geom_chain": CadenceConst,      // observed reading ANOTHER observed
		"k_scaled":   CadenceDiscrete,   // observed reading a discrete parameter
		"u_scaled":   CadenceContinuous, // observed reading the state
	}
	seeds, err := c.LeafSeeds()
	if err != nil {
		t.Fatalf("leaf seeds: %v", err)
	}
	for name, wantClass := range want {
		got, ok := seeds[name]
		if !ok {
			t.Errorf("%s: no leaf seed derived", name)
			continue
		}
		if got != wantClass {
			t.Errorf("%s: leaf seed = %s, want %s", name, got, wantClass)
		}
	}
	// The independent variable is CONTINUOUS: an explicit continuous-t forcing
	// is not piecewise-constant between events.
	if got, err := c.SeedLeaf("t"); err != nil || got != CadenceContinuous {
		t.Errorf("seed(t) = %s (err=%v), want continuous", got, err)
	}
	// An index-set name is CONST topology, not an undeclared-variable error.
	if got, err := c.SeedLeaf("cells"); err != nil || got != CadenceConst {
		t.Errorf("seed(cells) = %s (err=%v), want const", got, err)
	}
}

// An observed-definition CYCLE is a defect and MUST be reported, not silently
// seeded (CONFORMANCE_SPEC §5.7.2: "a cycle is a defect and MUST be reported
// rather than silently seeded"). The recursion is otherwise unbounded.
func TestCadenceObservedCycleIsReported(t *testing.T) {
	model := &Model{
		Variables: map[string]ModelVariable{
			"a": {Type: VarTypeUnknown},
			"b": {Type: VarTypeUnknown},
		},
		Equations: []Equation{
			{LHS: "a", RHS: ExprNode{Op: "*", Args: []any{"b", 2.0}}},
			{LHS: "b", RHS: ExprNode{Op: "*", Args: []any{"a", 2.0}}},
		},
	}
	c := NewCadenceClassifier(nil, model)
	_, err := c.SeedLeaf("a")
	if err == nil {
		t.Fatal("an observed definition cycle must be reported")
	}
	var ce *CadenceError
	if !asCadenceError(err, &ce) || ce.Code != CodeCadenceObservedCycle {
		t.Errorf("err = %v, want %s", err, CodeCadenceObservedCycle)
	}
}

func asCadenceError(err error, out **CadenceError) bool {
	ce, ok := err.(*CadenceError)
	if ok {
		*out = ce
	}
	return ok
}

// The SOURCE-SEEDED refinement (CONFORMANCE_SPEC §5.7.2 / RFC
// pure-io-data-loaders §4.6) survived the data_loaders → data_sources rename: a
// parameter fed by a `data` update whose source declares a `temporal` block
// stays DISCRETE and folds at bind, while one whose source has no `temporal`
// describes non-time-varying data and refines down to CONST.
//
// The paired fixtures loader_temporal_seed.esm and loader_const_seed.esm are
// IDENTICAL models differing only in that block, so any binding that ignores the
// source and reads only the parameter's own declaration gives them the same
// answer — and gets one of the two wrong.
func TestCadenceDataSourceTemporalRefinement(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	cases := []struct {
		fixture string
		want    Cadence
	}{
		{"loader_temporal_seed.esm", CadenceDiscrete},
		{"loader_const_seed.esm", CadenceConst},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.fixture, func(t *testing.T) {
			file, err := Load(filepath.Join(repoRoot, "tests", "valid", "cadence", tc.fixture))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			checked := 0
			for _, mname := range sortedKeys(file.Models) {
				model := file.Models[mname]
				c := NewCadenceClassifier(file, &model)
				for _, vname := range sortedKeys(model.Variables) {
					v := model.Variables[vname]
					dataFed := false
					for _, rule := range v.UpdateRules() {
						if rule.Kind == UpdateKindData {
							dataFed = true
						}
					}
					if !dataFed {
						continue
					}
					got, err := c.SeedLeaf(vname)
					if err != nil {
						t.Fatalf("%s: %v", vname, err)
					}
					if got != tc.want {
						t.Errorf("%s.%s: seed = %s, want %s", mname, vname, got, tc.want)
					}
					checked++
				}
			}
			if checked == 0 {
				t.Fatal("no data-fed parameter found — the refinement would pass vacuously")
			}
		})
	}
}

// A parameter's cadence comes from the §6.3.1 partitions, not from a local
// re-derivation: every category maps to exactly one seed, and the mapping is
// stated once (cadence.go parameterSeed) rather than at each call site.
func TestCadenceParameterSeedsFollowClassification(t *testing.T) {
	interval := 3600.0
	model := &Model{
		Variables: map[string]ModelVariable{
			"p_const":   {Type: VarTypeParameter, Default: 1.0},
			"p_sampled": {Type: VarTypeParameter, Distribution: &Distribution{Kind: DistributionUniform, Low: 0.0, High: 1.0}},
			"p_wiener": {Type: VarTypeParameter,
				Distribution: &Distribution{Kind: DistributionNormal, Mean: 0.0, Std: 1.0},
				Update:       ParameterUpdate{Kind: UpdateKindWiener}},
			"p_sched": {Type: VarTypeParameter, Shape: dims(),
				Update: ParameterUpdate{Kind: UpdateKindSchedule, Interval: &interval, Expression: 1.0}},
		},
	}
	want := map[string]Cadence{
		"p_const":   CadenceConst,
		"p_sampled": CadenceConst, // drawn ONCE at setup — still const for the run
		"p_wiener":  CadenceContinuous,
		"p_sched":   CadenceDiscrete,
	}
	c := NewCadenceClassifier(nil, model)
	for name, wantClass := range want {
		got, err := c.SeedLeaf(name)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got != wantClass {
			t.Errorf("%s: seed = %s, want %s", name, got, wantClass)
		}
	}
}

// Propagation is `max` over children (§5.7.3), and for a gather the index
// expressions are classed INDEPENDENTLY of the array — which is what lets a
// stencil split across phases.
func TestCadenceGatherSplitsByJoin(t *testing.T) {
	model := &Model{
		Variables: map[string]ModelVariable{
			"u":   {Type: VarTypeUnknown},
			"nbr": {Type: VarTypeParameter, Default: 0.0},
		},
		Equations: []Equation{{
			LHS: ExprNode{Op: OpDerivative, Args: []any{"u"}, Wrt: strPtr("t")},
			RHS: "u",
		}},
	}
	c := NewCadenceClassifier(nil, model)

	// The inner neighbour selection touches only CONST topology.
	inner := ExprNode{Op: "index", Args: []any{"nbr", "i", "k"}}
	if got, err := c.Classify(inner); err != nil || got != CadenceConst {
		t.Errorf("inner gather = %s (err=%v), want const", got, err)
	}
	// The outer value load touches `u`, so it is CONTINUOUS.
	outer := ExprNode{Op: "index", Args: []any{"u", inner}}
	if got, err := c.Classify(outer); err != nil || got != CadenceContinuous {
		t.Errorf("outer gather = %s (err=%v), want continuous", got, err)
	}
}
