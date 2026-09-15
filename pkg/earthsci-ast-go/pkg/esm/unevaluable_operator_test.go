package esm

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// unevaluableOperatorCases mirrors tests/conformance/unevaluable_operator/cases.json.
type unevaluableOperatorCases struct {
	Code     string             `json:"code"`
	Bindings map[string]float64 `json:"bindings"`
	Control  struct {
		Expression json.RawMessage `json:"expression"`
		Expected   float64         `json:"expected"`
	} `json:"control"`
	Cases []struct {
		ID         string          `json:"id"`
		Op         string          `json:"op"`
		Expression json.RawMessage `json:"expression"`
	} `json:"cases"`
}

// requireEvaluationCode asserts err is an *EvaluationError carrying code and
// naming op.
func requireEvaluationCode(t *testing.T, label string, err error, code, op string) {
	t.Helper()
	var evErr *EvaluationError
	if !errors.As(err, &evErr) {
		t.Fatalf("%s: want *EvaluationError with code %s, got %T: %v", label, code, err, err)
	}
	if evErr.Code != code {
		t.Errorf("%s: code = %q, want %q (%s)", label, evErr.Code, code, evErr.Message)
	}
	if !strings.Contains(evErr.Message, "'"+op+"'") {
		t.Errorf("%s: message must name the op %q: %s", label, op, evErr.Message)
	}
}

// The shared cross-binding fixture (esm-spec §9.6.6 `unevaluable_operator`).
// Every case puts the op in the UNTAKEN branch of an `ifelse`, so an evaluator
// that raises only when evaluation reaches the node answers 1.0 instead of
// refusing: the refusal has to come from a walk that precedes evaluation.
func TestUnevaluableOperatorConformanceFixture(t *testing.T) {
	raw, err := readFileFromTestDir("../../../../tests/conformance/unevaluable_operator/cases.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fx unevaluableOperatorCases
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("fixture has no cases")
	}
	for _, c := range fx.Cases {
		expr, err := UnmarshalExpression(c.Expression)
		if err != nil {
			t.Fatalf("%s: decode expression: %v", c.ID, err)
		}
		v, err := Evaluate(expr, fx.Bindings)
		if err == nil {
			t.Errorf("%s: `%s` has no evaluation rule and must be refused before evaluation, got value %v", c.ID, c.Op, v)
			continue
		}
		requireEvaluationCode(t, c.ID, err, fx.Code, c.Op)
	}

	control, err := UnmarshalExpression(fx.Control.Expression)
	if err != nil {
		t.Fatalf("control: decode expression: %v", err)
	}
	got, err := Evaluate(control, fx.Bindings)
	if err != nil {
		t.Fatalf("control: an ordinary expression must still evaluate: %v", err)
	}
	if got != fx.Control.Expected {
		t.Errorf("control = %v, want %v", got, fx.Control.Expected)
	}
}

// Every evaluable-core op this scalar evaluator has no rule for reports
// `unevaluable_operator`; an op OUTSIDE the core keeps `unlowered_operator`.
// The two are told apart by which side of esm-spec §4.2 the op falls on, so a
// closed-core op must never receive the rewrite-rule advice.
func TestUnevaluableOperatorClassification(t *testing.T) {
	closed := []string{
		"skolem", "rank", "distinct", "argmin", "argmax", "enum",
		"apply_expression_template", "table_lookup", "ic",
		"faq", "makearray", "index", "broadcast", "reshape", "transpose", "concat",
		"intersect_polygon", "polygon_intersection_area",
	}
	for _, op := range closed {
		_, err := Evaluate(ExprNode{Op: op, Args: []any{"x"}}, map[string]float64{"x": 1})
		requireEvaluationCode(t, op, err, "unevaluable_operator", op)
	}
	for _, op := range []string{"grad", "godunov_hamiltonian"} {
		_, err := Evaluate(ExprNode{Op: op, Args: []any{"x"}}, map[string]float64{"x": 1})
		requireEvaluationCode(t, op, err, "unlowered_operator", op)
	}
}

// The walk reaches operands of a closed-registry `fn` call, and leaves the
// inline `const` table operands such a call legitimately carries alone.
func TestUnevaluableOperatorWalkReachesFnOperands(t *testing.T) {
	name := "interp.linear"
	node := ExprNode{Op: "fn", Name: &name, Args: []any{
		ExprNode{Op: "const", Args: []any{}, Value: []any{1.0, 2.0}},
		ExprNode{Op: "const", Args: []any{}, Value: []any{0.0, 1.0}},
		ExprNode{Op: "ifelse", Args: []any{0.0, ExprNode{Op: "rank", Args: []any{"x"}}, 0.5}},
	}}
	_, err := Evaluate(node, map[string]float64{"x": 1})
	requireEvaluationCode(t, "fn operand", err, "unevaluable_operator", "rank")
}
