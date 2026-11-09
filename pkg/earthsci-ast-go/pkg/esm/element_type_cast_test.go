package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// esm-spec §4.2 "Precision conversion" / §11.3.1 (CONFORMANCE_SPEC §5.18.2a):
// `{"op": "cast", "element_type": "Float32"|"Float64", "args": [x]}`. The
// fixtures are shared with the other four bindings. This binding has no
// numeric evaluator, so it asserts the loader contract only: every fixture
// loads with exactly the `casts` expected.json lists, in document order, and
// keeps them through load → emit → load.

var elementTypeCastDir = filepath.Join("..", "..", "..", "..", "tests", "conformance", "element_type_cast")

type elementTypeCastExpected struct {
	Casts map[string][]string `json:"casts"`
}

func readElementTypeCastExpected(t *testing.T) elementTypeCastExpected {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(elementTypeCastDir, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var exp elementTypeCastExpected
	if err := json.Unmarshal(b, &exp); err != nil {
		t.Fatal(err)
	}
	return exp
}

// castElementTypes lists the `element_type` of every `cast` node of an emitted
// document: models in name order, equations in order (lhs then rhs), a node
// before its operands (args, then the node's other fields in key order).
func castElementTypes(doc map[string]any) []string {
	out := []string{}
	var walk func(v any)
	walk = func(v any) {
		switch n := v.(type) {
		case map[string]any:
			if n["op"] == "cast" {
				et, _ := n["element_type"].(string)
				out = append(out, et)
			}
			walk(n["args"])
			keys := make([]string, 0, len(n))
			for k := range n {
				if k != "args" {
					keys = append(keys, k)
				}
			}
			sort.Strings(keys)
			for _, k := range keys {
				walk(n[k])
			}
		case []any:
			for _, a := range n {
				walk(a)
			}
		}
	}
	models, _ := doc["models"].(map[string]any)
	names := make([]string, 0, len(models))
	for name := range models {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		m, _ := models[name].(map[string]any)
		eqs, _ := m["equations"].([]any)
		for _, raw := range eqs {
			eq, _ := raw.(map[string]any)
			walk(eq["lhs"])
			walk(eq["rhs"])
		}
	}
	return out
}

func TestElementTypeCast_LoadsAndRoundTripsEveryCast(t *testing.T) {
	exp := readElementTypeCastExpected(t)
	if len(exp.Casts) == 0 {
		t.Fatal("expected.json lists no casts")
	}
	for fixture, want := range exp.Casts {
		t.Run(fixture, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(elementTypeCastDir, fixture))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			got := castElementTypes(emittedDocument(t, file))
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("casts after load: got %v, want %v", got, want)
			}
			text, err := ToJSON(file)
			if err != nil {
				t.Fatalf("emit: %v", err)
			}
			again, err := LoadString(text)
			if err != nil {
				t.Fatalf("reload: %v", err)
			}
			if twice := castElementTypes(emittedDocument(t, again)); !reflect.DeepEqual(twice, want) {
				t.Fatalf("casts after load → emit → load: got %v, want %v", twice, want)
			}
		})
	}
}

func TestElementTypeCast_TypedNodeCarriesElementType(t *testing.T) {
	file, err := LoadPath(filepath.Join(elementTypeCastDir, "identity_f64.esm"))
	if err != nil {
		t.Fatal(err)
	}
	rhs, ok := asExprNode(file.Models["Same"].Equations[0].RHS)
	if !ok || rhs.Op != "*" {
		t.Fatalf("rhs = %#v", file.Models["Same"].Equations[0].RHS)
	}
	cast, ok := asExprNode(rhs.Args[0])
	if !ok || cast.Op != "cast" || cast.ElementType == nil || *cast.ElementType != "Float64" {
		t.Fatalf("cast node = %#v", rhs.Args[0])
	}
	if !reflect.DeepEqual(cast.Args, []any{"x"}) {
		t.Fatalf("cast args = %#v", cast.Args)
	}
}

// The display form `cast(x, element_type=Float32)` reads back to the same node, and the
// canonical form keeps the two precisions apart.
func TestElementTypeCast_DisplayParseAndCanonical(t *testing.T) {
	f32, f64 := "Float32", "Float64"
	node := ExprNode{Op: "cast", Args: []any{"x"}, ElementType: &f32}
	text := ToASCII(node)
	if text != "cast(x, element_type=Float32)" {
		t.Fatalf("ToASCII = %q", text)
	}
	back, err := ParseExpression(text)
	if err != nil {
		t.Fatalf("parse %q: %v", text, err)
	}
	bn, ok := asExprNode(back)
	if !ok || bn.Op != "cast" || bn.ElementType == nil || *bn.ElementType != f32 ||
		!reflect.DeepEqual(bn.Args, []any{"x"}) {
		t.Fatalf("parse %q = %#v", text, back)
	}
	for _, bad := range []string{"cast(x)", "cast(x, y, element_type=Float32)",
		"cast(x, element_type=Float16)", "cast(x, element_type=Float32, id=z)"} {
		if _, err := ParseExpression(bad); err == nil {
			t.Errorf("parsed malformed %q", bad)
		}
	}
	c32, err := CanonicalJSON(node)
	if err != nil {
		t.Fatalf("canonical: %v", err)
	}
	c64, err := CanonicalJSON(ExprNode{Op: "cast", Args: []any{"x"}, ElementType: &f64})
	if err != nil {
		t.Fatalf("canonical: %v", err)
	}
	if string(c32) != `{"args":["x"],"element_type":"Float32","op":"cast"}` {
		t.Fatalf("canonical Float32 cast = %s", c32)
	}
	if string(c32) == string(c64) {
		t.Fatal("cast(x, Float32) and cast(x, Float64) canonicalize alike")
	}
}

// A cast to Float32 is never evaluated as the identity: this binding has no
// binary32 rounding, so it refuses the node.
func TestElementTypeCast_EvaluatorRefuses(t *testing.T) {
	f32 := "Float32"
	_, err := Evaluate(ExprNode{Op: "cast", Args: []any{"x"}, ElementType: &f32}, map[string]float64{"x": 0.1})
	if err == nil {
		t.Fatal("evaluated a Float32 cast")
	}
	if !strings.Contains(err.Error(), "cast") {
		t.Fatalf("refusal does not name the cast: %v", err)
	}
}
