package esm

import (
	"strings"
	"testing"
)

// opNode builds an operator ExprNode from an op name and args.
func opNode(op string, args ...any) ExprNode {
	return ExprNode{Op: op, Args: args}
}

// dEq builds a differential equation D(name, wrt=indep) ~ rhs.
func dEq(name, indep string, rhs Expression) Equation {
	w := indep
	return Equation{
		LHS: ExprNode{Op: "D", Args: []any{name}, Wrt: &w},
		RHS: rhs,
	}
}

// algEq builds an algebraic equation `lhs ~ rhs` (LHS is a plain variable).
func algEq(lhs string, rhs Expression) Equation {
	return Equation{LHS: lhs, RHS: rhs}
}

func singleModelFile(m Model) *ESMFile {
	return &ESMFile{
		ESM:      "0.2.0",
		Metadata: Metadata{Name: "t"},
		Models:   map[string]Model{"M": m},
	}
}

// TestApplyDAEContract_PureODE_NoChange guards against false positives:
// a model with only differential equations must be classified "ode" and
// must not trigger E_NONTRIVIAL_DAE.
func TestApplyDAEContract_PureODE_NoChange(t *testing.T) {
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state", Default: 1.0},
			"k": {Type: "parameter", Default: 0.5},
		},
		Equations: []Equation{
			dEq("x", "t", opNode("*", opNode("-", "k"), "x")),
		},
	}
	file := singleModelFile(m)
	info, err := ApplyDAEContract(file)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if info.SystemClass != "ode" {
		t.Errorf("SystemClass = %q, want \"ode\"", info.SystemClass)
	}
	if info.AlgebraicEquationCount != 0 {
		t.Errorf("AlgebraicEquationCount = %d, want 0", info.AlgebraicEquationCount)
	}
	if info.TrivialFactoredCount != 0 {
		t.Errorf("TrivialFactoredCount = %d, want 0", info.TrivialFactoredCount)
	}
	if got := len(file.Models["M"].Equations); got != 1 {
		t.Errorf("model equations = %d, want 1 (no factoring expected)", got)
	}
}

// TestApplyDAEContract_TrivialObserved_Factored exercises the typical
// `y ~ expr; D(x) ~ y` shape described in RFC §12 — the trivial algebraic
// equation must be factored out and the result must be a pure ODE whose
// RHS has `y` replaced by its defining expression.
func TestApplyDAEContract_TrivialObserved_Factored(t *testing.T) {
	// y ~ x^2; D(x)/dt ~ -k*y  ==>  D(x)/dt ~ -k*x^2
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state", Default: 1.0},
			"y": {Type: "observed"},
			"k": {Type: "parameter", Default: 0.5},
		},
		Equations: []Equation{
			algEq("y", opNode("^", "x", int64(2))),
			dEq("x", "t", opNode("*", opNode("-", "k"), "y")),
		},
	}
	file := singleModelFile(m)
	info, err := ApplyDAEContract(file)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if info.SystemClass != "ode" {
		t.Errorf("SystemClass = %q, want \"ode\"", info.SystemClass)
	}
	if info.TrivialFactoredCount != 1 {
		t.Errorf("TrivialFactoredCount = %d, want 1", info.TrivialFactoredCount)
	}
	if info.AlgebraicEquationCount != 0 {
		t.Errorf("AlgebraicEquationCount = %d, want 0", info.AlgebraicEquationCount)
	}
	eqs := file.Models["M"].Equations
	if len(eqs) != 1 {
		t.Fatalf("want 1 remaining equation, got %d", len(eqs))
	}
	// The remaining equation must still be the D(x) ODE.
	lhs, ok := eqs[0].LHS.(ExprNode)
	if !ok || lhs.Op != "D" {
		t.Fatalf("want remaining LHS to be D(x), got %v", eqs[0].LHS)
	}
	// RHS must no longer reference y — it should now contain x^2.
	if Contains(eqs[0].RHS, "y") {
		t.Errorf("RHS still references y after factoring: %v", eqs[0].RHS)
	}
	if !Contains(eqs[0].RHS, "x") {
		t.Errorf("RHS lost reference to x after factoring: %v", eqs[0].RHS)
	}
}

// TestApplyDAEContract_TrivialChain_FixedPoint exercises a transitive
// chain z -> y -> D(x), verifying that the factoring loop runs to fixed
// point in one ApplyDAEContract call.
func TestApplyDAEContract_TrivialChain_FixedPoint(t *testing.T) {
	// z ~ y + 1; y ~ x; D(x)/dt ~ z  ==>  D(x)/dt ~ x + 1
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state"},
			"y": {Type: "observed"},
			"z": {Type: "observed"},
		},
		Equations: []Equation{
			algEq("z", opNode("+", "y", int64(1))),
			algEq("y", "x"),
			dEq("x", "t", "z"),
		},
	}
	file := singleModelFile(m)
	info, err := ApplyDAEContract(file)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if info.TrivialFactoredCount != 2 {
		t.Errorf("TrivialFactoredCount = %d, want 2", info.TrivialFactoredCount)
	}
	eqs := file.Models["M"].Equations
	if len(eqs) != 1 {
		t.Fatalf("want 1 remaining equation, got %d", len(eqs))
	}
	if Contains(eqs[0].RHS, "y") || Contains(eqs[0].RHS, "z") {
		t.Errorf("chain not fully factored: RHS still references y or z: %v", eqs[0].RHS)
	}
}

// TestApplyDAEContract_NontrivialConstraint emits E_NONTRIVIAL_DAE on a
// true algebraic constraint (`x^2 + y^2 ~ 1`): neither side's LHS is a
// plain variable, so no factoring candidate exists.
func TestApplyDAEContract_NontrivialConstraint(t *testing.T) {
	// D(x)/dt ~ y; x^2 + y^2 ~ 1
	constraint := Equation{
		LHS: opNode("+", opNode("^", "x", int64(2)), opNode("^", "y", int64(2))),
		RHS: int64(1),
	}
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state"},
			"y": {Type: "state"},
		},
		Equations: []Equation{
			dEq("x", "t", "y"),
			constraint,
		},
	}
	file := singleModelFile(m)
	info, err := ApplyDAEContract(file)
	if err == nil {
		t.Fatalf("expected E_NONTRIVIAL_DAE, got nil error")
	}
	re, ok := err.(*RuleEngineError)
	if !ok {
		t.Fatalf("expected *RuleEngineError, got %T: %v", err, err)
	}
	if re.Code != "E_NONTRIVIAL_DAE" {
		t.Errorf("Code = %q, want E_NONTRIVIAL_DAE", re.Code)
	}
	if info.SystemClass != "dae" {
		t.Errorf("SystemClass = %q, want \"dae\"", info.SystemClass)
	}
	if info.AlgebraicEquationCount != 1 {
		t.Errorf("AlgebraicEquationCount = %d, want 1", info.AlgebraicEquationCount)
	}
	// Error message must name the offending equation path and the Julia
	// escape hatch, per the RFC §12 contract.
	wantSubstrings := []string{
		"models.M.equations",
		"Julia",
		"RFC §12",
	}
	for _, s := range wantSubstrings {
		if !strings.Contains(re.Message, s) {
			t.Errorf("error message missing %q: %s", s, re.Message)
		}
	}
}

// TestApplyDAEContract_CyclicObserved demonstrates that cyclic observed
// equations (each LHS appears in the other's RHS) are partially
// factored and the residual cycle trips E_NONTRIVIAL_DAE.
func TestApplyDAEContract_CyclicObserved(t *testing.T) {
	// y ~ z; z ~ y; D(x)/dt ~ y
	// First pass factors y ~ z (y not in RHS). Then z becomes z ~ z,
	// which is not factorable — residual.
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state"},
			"y": {Type: "observed"},
			"z": {Type: "observed"},
		},
		Equations: []Equation{
			algEq("y", "z"),
			algEq("z", "y"),
			dEq("x", "t", "y"),
		},
	}
	file := singleModelFile(m)
	_, err := ApplyDAEContract(file)
	if err == nil {
		t.Fatalf("expected E_NONTRIVIAL_DAE on cyclic observed, got nil")
	}
	re, ok := err.(*RuleEngineError)
	if !ok || re.Code != "E_NONTRIVIAL_DAE" {
		t.Errorf("expected RuleEngineError(E_NONTRIVIAL_DAE), got %v", err)
	}
}

// TestApplyDAEContract_SkipsNonlinearSystem asserts that models
// declaring system_kind != "ode" are bypassed by the DAE contract.
// A purely nonlinear model (ISORROPIA / Mogi shape) is not a DAE and
// must not be classified as one.
func TestApplyDAEContract_SkipsNonlinearSystem(t *testing.T) {
	kind := "nonlinear"
	constraint := Equation{
		LHS: opNode("+", opNode("^", "H", int64(2)), "SO4"),
		RHS: "Ksp",
	}
	m := Model{
		SystemKind: &kind,
		Variables: map[string]ModelVariable{
			"H":   {Type: "state"},
			"SO4": {Type: "state"},
			"Ksp": {Type: "parameter"},
		},
		Equations: []Equation{constraint},
	}
	file := singleModelFile(m)
	info, err := ApplyDAEContract(file)
	if err != nil {
		t.Fatalf("expected nonlinear model to be skipped, got error: %v", err)
	}
	if info.SystemClass != "ode" {
		t.Errorf("SystemClass = %q, want \"ode\" (nonlinear model skipped)",
			info.SystemClass)
	}
	if info.AlgebraicEquationCount != 0 {
		t.Errorf("AlgebraicEquationCount = %d, want 0", info.AlgebraicEquationCount)
	}
}

// TestApplyDAEContract_ObservedExpressionSubstituted guards an
// easy-to-miss corner: when a trivial equation is factored out, any
// ModelVariable.Expression field that references the factored symbol
// must also be updated so the model remains internally consistent.
func TestApplyDAEContract_ObservedExpressionSubstituted(t *testing.T) {
	// y ~ x; w = y*2 (observed computed expression); D(x)/dt = 1
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state"},
			"y": {Type: "observed"},
			"w": {Type: "observed", Expression: opNode("*", "y", int64(2))},
		},
		Equations: []Equation{
			algEq("y", "x"),
			dEq("x", "t", int64(1)),
		},
	}
	file := singleModelFile(m)
	if _, err := ApplyDAEContract(file); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	w := file.Models["M"].Variables["w"]
	if Contains(w.Expression, "y") {
		t.Errorf("observed var w still references factored y: %v", w.Expression)
	}
	if !Contains(w.Expression, "x") {
		t.Errorf("observed var w lost reference to x: %v", w.Expression)
	}
}

// TestApplyDAEContract_DomainIndepVar verifies that a model whose
// domain declares a non-default independent variable ("time") has its
// D(x, wrt="time") equation classified as differential.
func TestApplyDAEContract_DomainIndepVar(t *testing.T) {
	iv := "time"
	m := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state"},
		},
		Equations: []Equation{
			dEq("x", "time", int64(1)),
		},
	}
	file := &ESMFile{
		ESM:      "0.2.0",
		Metadata: Metadata{Name: "t"},
		Models:   map[string]Model{"M": m},
		Domain:   &Domain{IndependentVariable: &iv},
	}
	info, err := ApplyDAEContract(file)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if info.SystemClass != "ode" {
		t.Errorf("SystemClass = %q, want \"ode\"", info.SystemClass)
	}
}
