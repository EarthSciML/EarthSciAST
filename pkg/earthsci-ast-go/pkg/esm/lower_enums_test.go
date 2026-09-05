package esm

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

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
	le, ok := err.(*EnumLoweringError)
	if !ok {
		t.Fatalf("expected *EnumLoweringError, got %T: %v", err, err)
	}
	if le.Code != "unknown_enum_symbol" {
		t.Errorf("expected code unknown_enum_symbol, got %q", le.Code)
	}
}

// enumFixtureSrc is a document whose `enum` ops sit in every container
// LowerEnums writes through: a model equation, a discrete-event trigger and
// affect, and a reaction rate.
const enumFixtureSrc = `{
  "esm":"1.0.0",
  "metadata":{"name":"purity"},
  "enums":{"phase":{"solid":1,"liquid":2}},
  "models":{"M":{
    "variables":{"x":{"type":"unknown","default":0.0},"s":{"type":"parameter","default":0.0}},
    "equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":{"op":"enum","args":["phase","solid"]}}],
    "discrete_events":[{
      "trigger":{"type":"condition","expression":{"op":"==","args":["s",{"op":"enum","args":["phase","solid"]}]}},
      "affects":[{"lhs":"s","rhs":{"op":"enum","args":["phase","liquid"]}}]
    }]}}}`

// rawDoc parses text without running the load pipeline's own enum lowering, so
// the `enum` ops are still present to be lowered by the function under test.
func rawDoc(t *testing.T, src string) *ESMFile {
	t.Helper()
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	// LoadString lowers enums itself, so re-plant one to have something to lower.
	m := file.Models["M"]
	m.Equations[0].RHS = ExprNode{Op: OpEnum, Args: []any{"phase", "solid"}}
	file.Models["M"] = m
	return file
}

// TestLowerEnumsIsPure pins API_SPEC.md §8 item 15: the canonical name is the
// PURE form. The argument must be observably unchanged, which is exactly what
// the in-place version could not promise.
func TestLowerEnumsIsPure(t *testing.T) {
	file := rawDoc(t, enumFixtureSrc)

	lowered, err := LowerEnums(file)
	if err != nil {
		t.Fatalf("LowerEnums: %v", err)
	}

	if node, ok := file.Models["M"].Equations[0].RHS.(ExprNode); !ok || node.Op != OpEnum {
		t.Errorf("LowerEnums modified its argument: equation RHS is now %#v", file.Models["M"].Equations[0].RHS)
	}
	node, ok := lowered.Models["M"].Equations[0].RHS.(ExprNode)
	if !ok || node.Op != OpConst {
		t.Fatalf("returned document was not lowered: %#v", lowered.Models["M"].Equations[0].RHS)
	}
	if node.Value != int64(1) {
		t.Errorf("phase.solid lowered to %v, want 1", node.Value)
	}
}

// TestLowerEnumsMutMutates pins the twin: LowerEnumsMut writes through the
// caller's document.
func TestLowerEnumsMutMutates(t *testing.T) {
	file := rawDoc(t, enumFixtureSrc)

	if err := LowerEnumsMut(file); err != nil {
		t.Fatalf("LowerEnumsMut: %v", err)
	}
	node, ok := file.Models["M"].Equations[0].RHS.(ExprNode)
	if !ok || node.Op != OpConst {
		t.Fatalf("LowerEnumsMut did not lower in place: %#v", file.Models["M"].Equations[0].RHS)
	}
}

// TestLowerEnumsRaisesEnumLoweringError confirms the failure channel is the
// code-bearing *EnumLoweringError the other bindings raise, with the spec's
// `unknown_enum_symbol` code — and that a failed PURE call yields no document,
// so a partially-lowered value can never be mistaken for a lowered one.
func TestLowerEnumsRaisesEnumLoweringError(t *testing.T) {
	file := rawDoc(t, enumFixtureSrc)
	m := file.Models["M"]
	m.Equations[0].RHS = ExprNode{Op: OpEnum, Args: []any{"phase", "plasma"}}
	file.Models["M"] = m

	lowered, err := LowerEnums(file)
	if err == nil {
		t.Fatal("expected an error for an undeclared enum symbol")
	}
	if lowered != nil {
		t.Errorf("a failed LowerEnums must return no document, got %#v", lowered)
	}
	var ele *EnumLoweringError
	if !errors.As(err, &ele) {
		t.Fatalf("expected *EnumLoweringError, got %T", err)
	}
	if ele.DiagnosticCode() != "unknown_enum_symbol" {
		t.Errorf("code = %q, want unknown_enum_symbol", ele.DiagnosticCode())
	}
}

// TestZeroAndNegativeEnumMembers pins that an `enums` member may be ANY
// integer — negative, zero or positive (esm-spec §9.3; CONFORMANCE_SPEC,
// "An `enums` Member Is a Code, Not a Position").
//
// The schema used to carry `minimum: 1` on
// `EnumDeclaration.additionalProperties`, so a zero-valued identifier could not
// be named at all. MOVES has load-bearing ones: `operatingmode.opModeID = 0` is
// Braking — an emitting mode with its own rate, not an absence — and
// `opmodepolprocassoc.polProcessID = -1` marks the drive-cycle modes associated
// with no pollutant/process.
//
// Both halves are pinned: the document LOADS, and each member resolves to
// EXACTLY its declared integer through Evaluate. A binding that accepted the
// document but clamped or dropped the sign would still be wrong, which is why
// the arithmetic case is here and not just the two bare constants.
func TestZeroAndNegativeEnumMembers(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	text, err := os.ReadFile(filepath.Join(repoRoot, "tests", "valid", "enums_zero_and_negative.esm"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	file, err := LoadString(string(text))
	if err != nil {
		t.Fatalf("a zero/negative enum member must load: %v", err)
	}

	if got := file.Enums["operating_mode"]["Braking"]; got != 0 {
		t.Errorf("operating_mode.Braking = %d, want 0", got)
	}
	if got := file.Enums["pol_process"]["Unassociated"]; got != -1 {
		t.Errorf("pol_process.Unassociated = %d, want -1", got)
	}
	if vr := Validate(file); !vr.IsValid {
		t.Errorf("document must validate, got %+v", vr.StructuralErrors)
	}

	rhs, ok := file.Models["EnumsZeroAndNegative"].Equations[0].RHS.(ExprNode)
	if !ok {
		t.Fatalf("RHS is %T, want ExprNode", file.Models["EnumsZeroAndNegative"].Equations[0].RHS)
	}
	if rhs.Op != "makearray" {
		t.Fatalf("RHS op = %q, want makearray", rhs.Op)
	}
	// values[0] is the zero-valued member, values[1] the negative one, and
	// values[2] reads both through arithmetic: 0 + 10*1 + (-1) = 9.
	want := []float64{0, -1, 9}
	if len(rhs.Values) != len(want) {
		t.Fatalf("makearray has %d values, want %d", len(rhs.Values), len(want))
	}
	for i, w := range want {
		got, err := Evaluate(rhs.Values[i], map[string]float64{})
		if err != nil {
			t.Fatalf("Evaluate(values[%d]): %v", i, err)
		}
		if got != w {
			t.Errorf("Evaluate(values[%d]) = %v, want %v", i, got, w)
		}
	}
}
