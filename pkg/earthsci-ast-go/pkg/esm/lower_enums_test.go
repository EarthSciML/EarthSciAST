package esm

import "testing"

// TestLowerEnumsRecursesAllFields confirms enum lowering reaches `enum` ops
// nested in fields beyond Args/TableAxes — an aggregate body (`expr`), integral
// bounds (`lower`/`upper`), and join clauses — now that lowerExprNodeEnums
// routes through the shared field-preserving walker (mapExprChildren). Before
// the fix these positions survived to evaluation with a
// "should have been lowered at load" error.
func TestLowerEnumsRecursesAllFields(t *testing.T) {
	enums := map[string]map[string]int{
		"Season": {"winter": 0, "summer": 2},
	}
	enumNode := func(sym string) ExprNode {
		return ExprNode{Op: "enum", Args: []any{"Season", sym}}
	}
	node := ExprNode{
		Op:    "aggregate",
		Args:  []any{enumNode("winter")},
		Expr:  enumNode("summer"),
		Lower: enumNode("winter"),
		Upper: enumNode("summer"),
		Join:  []any{enumNode("winter")},
	}

	lowered, err := lowerExprEnums(node, enums)
	if err != nil {
		t.Fatalf("lowerExprEnums returned error: %v", err)
	}
	out, ok := lowered.(ExprNode)
	if !ok {
		t.Fatalf("expected ExprNode, got %T", lowered)
	}

	assertConst := func(where string, v any, want int64) {
		t.Helper()
		n, ok := v.(ExprNode)
		if !ok {
			t.Fatalf("%s: expected lowered const ExprNode, got %T", where, v)
		}
		if n.Op != "const" {
			t.Errorf("%s: expected op=const (enum not lowered), got %q", where, n.Op)
		}
		if n.Value != want {
			t.Errorf("%s: expected value %d, got %v (%T)", where, want, n.Value, n.Value)
		}
	}

	assertConst("args[0]", out.Args[0], 0)
	assertConst("expr", out.Expr, 2)
	assertConst("lower", out.Lower, 0)
	assertConst("upper", out.Upper, 2)
	assertConst("join[0]", out.Join[0], 0)
}

// TestLowerEnumsUnknownSymbolInNestedField confirms diagnostics still surface
// from the newly-walked positions (errors propagate through mapExprChildren).
func TestLowerEnumsUnknownSymbolInNestedField(t *testing.T) {
	enums := map[string]map[string]int{"Season": {"winter": 0}}
	node := ExprNode{
		Op:    "aggregate",
		Args:  []any{"x"},
		Lower: ExprNode{Op: "enum", Args: []any{"Season", "autumn"}}, // not declared
	}
	_, err := lowerExprEnums(node, enums)
	if err == nil {
		t.Fatal("expected unknown_enum_symbol error from nested lower bound, got nil")
	}
	le, ok := err.(*LowerEnumsError)
	if !ok {
		t.Fatalf("expected *LowerEnumsError, got %T: %v", err, err)
	}
	if le.Code != "unknown_enum_symbol" {
		t.Errorf("expected code unknown_enum_symbol, got %q", le.Code)
	}
}
