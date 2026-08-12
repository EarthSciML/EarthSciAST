package esm

// CROSS-BINDING conformance for §5.5.6 join-name namespacing under flattening.
//
// A relational `join` carries its references as plain STRINGS — an `on` key
// column, and an `overlap` clause's `src_env` / `tgt_env` envelope factors —
// inside untyped clause maps. mapExprChildren walks the clause slice, but a
// clause has no "op" key so asExprNode declines it and every name inside used
// to pass through unchanged, leaving a flattened tree whose join named
// variables the flattened registry no longer holds.
//
// The gate is `varNames`, the same one a bare string leaf gets: a key column
// naming a loop symbol or a document-scoped index set is not a declared
// variable of this system and is left alone.
//
// Go's flattened EQUATIONS render to strings, so the surface this reaches is
// events — which is also why it is exercised through namespaceExpressionTree
// directly rather than through Flatten.

import (
	"reflect"
	"testing"
)

func aggregateWithJoin(join []any) Expression {
	return map[string]any{
		"op":         "aggregate",
		"semiring":   "sum_product",
		"output_idx": []any{},
		"ranges": map[string]any{
			"src": map[string]any{"from": "sourceType"},
			"c":   map[string]any{"from": "pop_cells"},
		},
		"join": join,
		"args": []any{"X", "W"},
		"expr": map[string]any{"op": "index", "args": []any{"W", "c"}},
	}
}

func joinOf(t *testing.T, out Expression) []any {
	t.Helper()
	node, ok := asExprNode(out)
	if !ok {
		t.Fatalf("namespaced result is not an expression node: %#v", out)
	}
	return node.Join
}

// The envelope factors of an `overlap` clause name variables, so they follow
// the registry — and so do the same names carried as expression children in
// `args`. A node must not spell one factor two ways.
func TestNamespaceJoin_OverlapEnvelopeFactorsFollowTheRegistry(t *testing.T) {
	varNames := map[string]bool{"X": true, "Y": true, "W": true, "S": true, "E": true, "N": true}
	expr := aggregateWithJoin([]any{
		map[string]any{"overlap": map[string]any{
			"src_env": []any{"X", "Y"},
			"tgt_env": []any{"W", "S", "E", "N"},
			"eps":     0.0,
		}},
	})

	out := namespaceExpressionTree(expr, "ISRM", varNames)
	node, _ := asExprNode(out)

	overlap := joinOf(t, out)[0].(map[string]any)["overlap"].(map[string]any)
	if got, want := overlap["src_env"], []any{"ISRM.X", "ISRM.Y"}; !reflect.DeepEqual(got, want) {
		t.Errorf("src_env = %#v, want %#v", got, want)
	}
	want := []any{"ISRM.W", "ISRM.S", "ISRM.E", "ISRM.N"}
	if got := overlap["tgt_env"]; !reflect.DeepEqual(got, want) {
		t.Errorf("tgt_env = %#v, want %#v", got, want)
	}
	// `eps` is a scalar, not a name: this pass must not touch it. Pinned against
	// the same walk with an empty declared-variable set, so the assertion is
	// about THIS pass and not about how the node decoder spells a number.
	untouched := joinOf(t, namespaceExpressionTree(expr, "ISRM", map[string]bool{}))
	inert := untouched[0].(map[string]any)["overlap"].(map[string]any)
	if !reflect.DeepEqual(overlap["eps"], inert["eps"]) {
		t.Errorf("eps = %#v, want it untouched (%#v)", overlap["eps"], inert["eps"])
	}
	if got, want := inert["src_env"], []any{"X", "Y"}; !reflect.DeepEqual(got, want) {
		t.Errorf("with no declared locals, src_env must be inert: %#v", got)
	}
	// The same factors as expression children, in the same node.
	if got, want := node.Args, []any{"ISRM.X", "ISRM.W"}; !reflect.DeepEqual(got, want) {
		t.Errorf("args = %#v, want %#v", got, want)
	}
}

// The gate is the declared-variable set, not "every bare string": a key column
// naming a loop symbol (`src`, a `ranges` key) or a document-scoped index set
// (`sourceType`) must survive untouched.
func TestNamespaceJoin_LoopSymbolsAndIndexSetsAreLeftAlone(t *testing.T) {
	varNames := map[string]bool{"src_bin": true, "tgt_bin": true, "W": true, "X": true}
	expr := aggregateWithJoin([]any{
		map[string]any{"on": []any{
			[]any{"src_bin", "tgt_bin"},
			[]any{"src", "sourceType"},
		}},
	})

	on := joinOf(t, namespaceExpressionTree(expr, "M", varNames))[0].(map[string]any)["on"]
	want := []any{
		[]any{"M.src_bin", "M.tgt_bin"},
		[]any{"src", "sourceType"},
	}
	if !reflect.DeepEqual(on, want) {
		t.Errorf("on = %#v, want %#v", on, want)
	}
}

// A join-free node is byte-identical, and an unrecognised clause shape is
// carried through rather than dropped.
func TestNamespaceJoin_UnknownClauseShapeIsPreserved(t *testing.T) {
	varNames := map[string]bool{"W": true, "X": true}
	expr := aggregateWithJoin([]any{"not-a-clause"})
	if got := joinOf(t, namespaceExpressionTree(expr, "M", varNames)); !reflect.DeepEqual(got, []any{"not-a-clause"}) {
		t.Errorf("unrecognised clause = %#v, want it preserved", got)
	}
}
