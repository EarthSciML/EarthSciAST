package esm

import (
	"errors"
	"math"
	"strings"
	"testing"
)

// Test the §5.4.6 round-trip fixture table verbatim.
func TestCanonicalFloatFormat(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{1.0, "1.0"},
		{-3.0, "-3.0"},
		{0.0, "0.0"},
		{math.Copysign(0, -1), "-0.0"},
		{2.5, "2.5"},
		// Compiler folds `0.1 + 0.2` at arbitrary precision; force a runtime
		// add to exercise the 17-digit round-trip form.
		{func() float64 { a, b := 0.1, 0.2; return a + b }(), "0.30000000000000004"},
		{1e25, "1e25"},
		{5e-324, "5e-324"},
		// Inside plain range
		{42.0, "42.0"},
		{-1.5e-6, "-0.0000015"}, // 1.5e-6 is >= 1e-6, plain form
		{1e-7, "1e-7"},          // just under, exponent form
		{1e21, "1e21"},          // boundary, exponent form
	}
	for _, c := range cases {
		got := formatCanonicalFloat(c.in)
		if got != c.want {
			t.Errorf("formatCanonicalFloat(%v) = %q; want %q", c.in, got, c.want)
		}
	}
}

func TestCanonicalIntegerEmission(t *testing.T) {
	cases := []struct {
		in   Expression
		want string
	}{
		{int64(1), "1"},
		{int64(-42), "-42"},
		{int64(0), "0"},
	}
	for _, c := range cases {
		got, err := CanonicalJSON(c.in)
		if err != nil {
			t.Fatalf("CanonicalJSON(%v) error: %v", c.in, err)
		}
		if string(got) != c.want {
			t.Errorf("CanonicalJSON(%v) = %q; want %q", c.in, got, c.want)
		}
	}
}

func TestCanonicalNonFinite(t *testing.T) {
	for _, f := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		_, err := Canonicalize(f)
		if !errors.Is(err, ErrCanonicalNonFinite) {
			t.Errorf("Canonicalize(%v) err=%v; want ErrCanonicalNonFinite", f, err)
		}
	}
}

func TestCanonicalOrdering(t *testing.T) {
	// +(b, a, 1.0, 0) -> +(0, 1.0, a, b); zero-elim applies: +(1.0, a, b).
	// But integer 0 has float 1.0 present -> singleton rule must keep types.
	expr := ExprNode{
		Op: "+",
		Args: []any{
			"b", "a", 1.0, int64(0),
		},
	}
	got, err := CanonicalJSON(expr)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"args":[1.0,"a","b"],"op":"+"}`
	if string(got) != want {
		t.Errorf("got %s, want %s", got, want)
	}
}

// §5.4.8 worked example.
func TestWorkedExample(t *testing.T) {
	// +(*(a, 0), b, +(a, 1))
	expr := ExprNode{
		Op: "+",
		Args: []any{
			ExprNode{Op: "*", Args: []any{"a", int64(0)}},
			"b",
			ExprNode{Op: "+", Args: []any{"a", int64(1)}},
		},
	}
	got, err := CanonicalJSON(expr)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"args":[1,"a","b"],"op":"+"}`
	if string(got) != want {
		t.Errorf("worked example: got %s, want %s", got, want)
	}
}

func TestFlatten(t *testing.T) {
	// +(+(a,b), c) -> +(a,b,c)
	expr := ExprNode{
		Op: "+",
		Args: []any{
			ExprNode{Op: "+", Args: []any{"a", "b"}},
			"c",
		},
	}
	got, err := CanonicalJSON(expr)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"args":["a","b","c"],"op":"+"}`
	if string(got) != want {
		t.Errorf("flatten: got %s, want %s", got, want)
	}
}

// §5.4.4 type-preserving identity elimination: *(1.0, x) stays when x is
// a bare variable; dropping the 1.0 would erase float-promotion info.
func TestTypePreservingIdentityElim(t *testing.T) {
	// *(1, x) -> x (both int class / unknown class -> safe to drop).
	expr1 := ExprNode{Op: "*", Args: []any{int64(1), "x"}}
	got1, _ := CanonicalJSON(expr1)
	if string(got1) != `"x"` {
		t.Errorf("*(1, x): got %s, want \"x\"", got1)
	}
	// *(1.0, x): must keep the 1.0 so evaluate still promotes to float.
	expr2 := ExprNode{Op: "*", Args: []any{1.0, "x"}}
	got2, _ := CanonicalJSON(expr2)
	want := `{"args":[1.0,"x"],"op":"*"}`
	if string(got2) != want {
		t.Errorf("*(1.0, x): got %s, want %s", got2, want)
	}
}

// §5.4.4 zero-annihilation preserves numeric type.
func TestZeroAnnihilationTypePreserve(t *testing.T) {
	// *(0, x) -> 0 (integer)
	e1 := ExprNode{Op: "*", Args: []any{int64(0), "x"}}
	got1, _ := CanonicalJSON(e1)
	if string(got1) != `0` {
		t.Errorf("*(0,x): got %s", got1)
	}
	// *(0.0, x) -> 0.0 (float)
	e2 := ExprNode{Op: "*", Args: []any{0.0, "x"}}
	got2, _ := CanonicalJSON(e2)
	if string(got2) != `0.0` {
		t.Errorf("*(0.0,x): got %s", got2)
	}
	// *(-0.0, x) -> -0.0 (signed-zero preserved)
	e3 := ExprNode{Op: "*", Args: []any{math.Copysign(0, -1), "x"}}
	got3, _ := CanonicalJSON(e3)
	if string(got3) != `-0.0` {
		t.Errorf("*(-0.0,x): got %s", got3)
	}
}

// §5.4.6 disambiguation: float-1.0 and integer-1 produce distinct wire forms.
func TestIntFloatDisambiguation(t *testing.T) {
	a := ExprNode{Op: "+", Args: []any{1.0, 2.5}}
	b := ExprNode{Op: "+", Args: []any{int64(1), 2.5}}
	gotA, _ := CanonicalJSON(a)
	gotB, _ := CanonicalJSON(b)
	if string(gotA) == string(gotB) {
		t.Fatalf("int/float distinction lost: both emit %s", gotA)
	}
	if !strings.Contains(string(gotA), "1.0") {
		t.Errorf("float 1.0 not emitted with trailing .0: %s", gotA)
	}
}

// §5.4.7 neg / unary minus canonical form.
func TestNegCanonical(t *testing.T) {
	// neg(neg(x)) -> x
	inner := ExprNode{Op: "neg", Args: []any{"x"}}
	outer := ExprNode{Op: "neg", Args: []any{inner}}
	got, _ := CanonicalJSON(outer)
	if string(got) != `"x"` {
		t.Errorf("neg(neg(x)): got %s", got)
	}
	// neg(5) -> -5 (literal)
	e := ExprNode{Op: "neg", Args: []any{int64(5)}}
	got, _ = CanonicalJSON(e)
	if string(got) != `-5` {
		t.Errorf("neg(5): got %s", got)
	}
	// -(0, x) -> neg(x)
	s := ExprNode{Op: "-", Args: []any{int64(0), "x"}}
	got, _ = CanonicalJSON(s)
	want := `{"args":["x"],"op":"neg"}`
	if string(got) != want {
		t.Errorf("-(0,x): got %s, want %s", got, want)
	}
}

// §5.4.7 division edge case: /(0, 0) errors.
func TestDivZeroByZero(t *testing.T) {
	e := ExprNode{Op: "/", Args: []any{int64(0), int64(0)}}
	_, err := Canonicalize(e)
	if !errors.Is(err, ErrCanonicalDivByZero) {
		t.Errorf("0/0: err=%v want ErrCanonicalDivByZero", err)
	}
}

// Canonicalize stays FIELD-PRESERVING on non-arithmetic op nodes (the copy
// rides every field through mapExprChildren), but CanonicalJSON is FAIL-CLOSED:
// a node carrying a non-emissible field (var/lower/upper/…) has no faithful
// canonical JSON in the pinned 7-field encoding, so CanonicalJSON returns
// E_CANONICAL_UNSUPPORTED_FIELD — matching the Julia reference's
// _emit_node_json.
func TestCanonicalizePreservesStructuralFields(t *testing.T) {
	varName := "s"
	node := ExprNode{
		Op:    "integral",
		Args:  []any{"f"},
		Var:   &varName,
		Lower: int64(0),
		Upper: 1.0,
	}
	c, err := Canonicalize(node)
	if err != nil {
		t.Fatal(err)
	}
	out, ok := c.(ExprNode)
	if !ok {
		t.Fatalf("expected ExprNode, got %T", c)
	}
	// Canonicalize must NOT drop the sidecar fields.
	if out.Var == nil || *out.Var != "s" {
		t.Errorf("Var dropped by Canonicalize: %v", out.Var)
	}
	if out.Lower != int64(0) {
		t.Errorf("Lower not preserved: %v (%T)", out.Lower, out.Lower)
	}
	if out.Upper != 1.0 {
		t.Errorf("Upper not preserved: %v (%T)", out.Upper, out.Upper)
	}

	// Emission is fail-closed: the node carries non-emissible fields.
	if _, err := CanonicalJSON(node); !errors.Is(err, ErrCanonicalUnsupportedField) {
		t.Errorf("CanonicalJSON(non-emissible node): err=%v; want ErrCanonicalUnsupportedField", err)
	}
}

// A node carrying a non-emissible field (table_lookup's `table`) has no
// faithful canonical JSON in the pinned 7-field encoding, so CanonicalJSON is
// FAIL-CLOSED and returns E_CANONICAL_UNSUPPORTED_FIELD (matching Julia) rather
// than emitting lossy bytes.
func TestCanonicalTableLookupUnsupported(t *testing.T) {
	tA := "tableA"
	node := ExprNode{Op: "table_lookup", Args: []any{}, Table: &tA}
	if _, err := CanonicalJSON(node); !errors.Is(err, ErrCanonicalUnsupportedField) {
		t.Errorf("CanonicalJSON(table_lookup): err=%v; want ErrCanonicalUnsupportedField", err)
	}
}

// A non-emissible field set on a CHILD node (nested in `args`) is also rejected:
// the emissibility gate recurses through args, matching the Julia emitter.
func TestCanonicalUnsupportedFieldNestedInArgs(t *testing.T) {
	tA := "tbl"
	child := ExprNode{Op: "table_lookup", Args: []any{}, Table: &tA}
	node := ExprNode{Op: "+", Args: []any{"x", child}}
	if _, err := CanonicalJSON(node); !errors.Is(err, ErrCanonicalUnsupportedField) {
		t.Errorf("CanonicalJSON(nested non-emissible): err=%v; want ErrCanonicalUnsupportedField", err)
	}
}

// The emissible field set {op,args,wrt,dim,fn,name,value} still emits: a node
// using only these fields has faithful, sorted-key canonical JSON.
func TestCanonicalEmissibleFields(t *testing.T) {
	wrt, dim, fn, name := "x", "y", "dirichlet", "datetime.julian_day"
	node := ExprNode{
		Op:   "bc",
		Args: []any{"u"},
		Wrt:  &wrt,
		Dim:  &dim,
		Fn:   &fn,
		Name: &name,
	}
	got, err := CanonicalJSON(node)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"args":["u"],"dim":"y","fn":"dirichlet","name":"datetime.julian_day","op":"bc","wrt":"x"}`
	if string(got) != want {
		t.Errorf("emissible fields:\n got %s\nwant %s", got, want)
	}
}

// `value` (the const-op payload) is emissible and emits via the canonical
// value encoder.
func TestCanonicalConstValueEmissible(t *testing.T) {
	node := ExprNode{Op: "const", Args: []any{}, Value: 2.5}
	got, err := CanonicalJSON(node)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"args":[],"op":"const","value":2.5}`
	if string(got) != want {
		t.Errorf("const value:\n got %s\nwant %s", got, want)
	}
}

// `arg` and `bindings` are TOLERATED: present, ignored, never emitted, and NOT
// an error — matching the Julia _CANONICAL_IGNORED_FIELDS tolerance.
func TestCanonicalToleratedFields(t *testing.T) {
	argName := "i"
	node := ExprNode{
		Op:       "argmin",
		Args:     []any{"cost"},
		Arg:      &argName,
		Bindings: map[string]any{"p": 1.0},
	}
	got, err := CanonicalJSON(node)
	if err != nil {
		t.Fatalf("tolerated fields must not error: %v", err)
	}
	want := `{"args":["cost"],"op":"argmin"}`
	if string(got) != want {
		t.Errorf("tolerated fields:\n got %s\nwant %s", got, want)
	}
}
