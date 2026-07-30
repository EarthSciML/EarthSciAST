package esm

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func bcast(fn *string, nargs int) ExprNode {
	args := make([]any, nargs)
	for i := range args {
		args[i] = float64(i)
	}
	return ExprNode{Op: "broadcast", Fn: fn, Args: args}
}

// TestScalarOperatorsAllHaveArity pins the invariant scalarOpArity relies on:
// scalarOperators only ever CLASSIFIES operators arithOpTable already knows, so
// the §4.3.4 broadcast rule derives its arity from the package's one arity table
// rather than a second, hand-maintained list. A scalar operator with no
// arithOpTable entry would make every `broadcast` naming it fail as "not a
// scalar operator", which is the wrong diagnostic for the right defect.
func TestScalarOperatorsAllHaveArity(t *testing.T) {
	for op := range scalarOperators {
		if _, ok := arithOpTable[op]; !ok {
			t.Errorf("scalar operator %q has no arithOpTable entry: the arity source and the "+
				"scalar-operator set have drifted", op)
		}
		if _, ok := scalarOpArity(op); !ok {
			t.Errorf("scalarOpArity(%q) reported no arity", op)
		}
	}
}

// TestNonPointwiseOpsAreNotScalarOperators is the load-bearing half of the set:
// esm-spec §4.3.4 lists exactly which ops a `broadcast` fn may NOT name. Each
// exclusion has a reason — the array ops RESHAPE, `broadcast` itself would
// recurse forever, the form ops are consumed by lowering, and the relational /
// geometry kernels return results of an unrelated shape.
func TestNonPointwiseOpsAreNotScalarOperators(t *testing.T) {
	for _, op := range []string{
		// Array / tensor.
		"aggregate", "makearray", "index", "broadcast", "reshape", "transpose", "concat",
		// Closed-registry invocation.
		"fn",
		// Form / lowering.
		"D", "ic", "Pre", "const", "true", "false", "enum", "table_lookup",
		"apply_expression_template",
		// Relational / value-invention and geometry.
		"skolem", "rank", "distinct", "argmin", "argmax",
		"intersect_polygon", "polygon_intersection_area",
		// The format has no operator aliases.
		"**", "pow", "power", "=",
		// Not an operator at all.
		"not_a_real_op",
	} {
		if isScalarOperator(op) {
			t.Errorf("%q must NOT be a scalar operator (esm-spec §4.3.4)", op)
		}
	}
}

// TestCheckBroadcastFn walks the §4.3.4 contract: `broadcast(fn: F, args)` is
// legal exactly when `{op: F, args}` is legal.
func TestCheckBroadcastFn(t *testing.T) {
	cases := []struct {
		name    string
		node    ExprNode
		wantErr string // substring, or "" for accept
	}{
		// A one-operand n-ary or unary fn is LEGAL: `+(x)` IS `x`. This is the
		// spelling tests/property_corpus/expressions/expr_039.json uses.
		{"unary plus folds to identity", bcast(strPtr("+"), 1), ""},
		{"unary times folds to identity", bcast(strPtr("*"), 1), ""},
		{"unary minus is negation", bcast(strPtr("-"), 1), ""},
		{"neg is unary", bcast(strPtr("neg"), 1), ""},
		{"log is unary", bcast(strPtr("log"), 1), ""},
		{"ln is unary", bcast(strPtr("ln"), 1), ""},
		{"binary times", bcast(strPtr("*"), 2), ""},
		{"n-ary times", bcast(strPtr("*"), 3), ""},
		{"binary min", bcast(strPtr("min"), 2), ""},
		{"atan2 is binary", bcast(strPtr("atan2"), 2), ""},
		{"ifelse is ternary", bcast(strPtr("ifelse"), 3), ""},
		{"comparison is binary", bcast(strPtr("<="), 2), ""},

		// A missing `fn` has no default (issue #101): it must not become `+`.
		{"missing fn", bcast(nil, 2), "missing its 'fn'"},

		// A name that is not a scalar operator — a typo or a non-pointwise op.
		{"typo", bcast(strPtr("not_a_real_op"), 1), "does not name a scalar operator"},
		{"aggregate", bcast(strPtr("aggregate"), 1), "does not name a scalar operator"},
		{"index", bcast(strPtr("index"), 2), "does not name a scalar operator"},
		{"makearray", bcast(strPtr("makearray"), 1), "does not name a scalar operator"},
		{"self-referential", bcast(strPtr("broadcast"), 1), "does not name a scalar operator"},
		{"reshape", bcast(strPtr("reshape"), 1), "does not name a scalar operator"},
		{"transpose", bcast(strPtr("transpose"), 1), "does not name a scalar operator"},
		{"concat", bcast(strPtr("concat"), 2), "does not name a scalar operator"},
		{"geometry kernel", bcast(strPtr("intersect_polygon"), 2), "does not name a scalar operator"},
		{"closed-fn invocation", bcast(strPtr("fn"), 1), "does not name a scalar operator"},
		{"derivative", bcast(strPtr("D"), 1), "does not name a scalar operator"},
		{"alias is not an operator", bcast(strPtr("**"), 2), "does not name a scalar operator"},

		// An arity the named operator does not admit — the same defect the bare
		// node would have, reported against the `fn` name.
		{"unary min is spec-rejected", bcast(strPtr("min"), 1), "takes at least 2 argument(s), got 1"},
		{"unary max is spec-rejected", bcast(strPtr("max"), 1), "takes at least 2 argument(s), got 1"},
		{"binary sin", bcast(strPtr("sin"), 2), "takes 1 argument(s), got 2"},
		{"ternary atan2", bcast(strPtr("atan2"), 3), "takes 2 argument(s), got 3"},
		{"unary ifelse", bcast(strPtr("ifelse"), 1), "takes 3 argument(s), got 1"},
		{"unary and", bcast(strPtr("and"), 1), "takes at least 2 argument(s), got 1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := checkBroadcastFn(tc.node)
			if tc.wantErr == "" {
				if got != nil {
					t.Fatalf("expected acceptance, got %q", got.message)
				}
				return
			}
			if got == nil {
				t.Fatalf("expected rejection containing %q, got acceptance", tc.wantErr)
			}
			if !strings.Contains(got.message, tc.wantErr) {
				t.Fatalf("message %q does not contain %q", got.message, tc.wantErr)
			}
		})
	}
}

// TestIsElementwiseNode pins the node-level lift: alignment sees THROUGH a
// `broadcast` to its args iff the node's `fn` names a scalar operator, and never
// through an op that reshapes or re-indexes its operands.
func TestIsElementwiseNode(t *testing.T) {
	for _, tc := range []struct {
		node ExprNode
		want bool
	}{
		{ExprNode{Op: "*", Args: []any{"a", "b"}}, true},
		{ExprNode{Op: "ifelse", Args: []any{"a", "b", "c"}}, true},
		{ExprNode{Op: "neg", Args: []any{"a"}}, true},
		{bcast(strPtr("*"), 2), true},
		{bcast(strPtr("atan2"), 2), true},
		// An absent `fn` keeps the historical `+` classification; such a node is
		// a hard invalid_broadcast_fn error and never reaches alignment.
		{bcast(nil, 2), true},
		{bcast(strPtr("aggregate"), 1), false},
		{bcast(strPtr("not_a_real_op"), 1), false},
		{ExprNode{Op: "aggregate"}, false},
		{ExprNode{Op: "index", Args: []any{"a", "i"}}, false},
		{ExprNode{Op: "reshape", Args: []any{"a"}}, false},
		{ExprNode{Op: "transpose", Args: []any{"a"}}, false},
		{ExprNode{Op: "concat", Args: []any{"a", "b"}}, false},
		{ExprNode{Op: "makearray"}, false},
		{ExprNode{Op: "intersect_polygon", Args: []any{"a", "b"}}, false},
		{ExprNode{Op: "fn", Args: []any{"a"}}, false},
		{ExprNode{Op: "D", Args: []any{"a"}}, false},
	} {
		name := tc.node.Op
		if tc.node.Fn != nil {
			name += "/" + *tc.node.Fn
		}
		if got := isElementwiseNode(tc.node); got != tc.want {
			t.Errorf("isElementwiseNode(%s) = %v, want %v", name, got, tc.want)
		}
	}
}

// TestCorpusBroadcastNodesAreAccepted sweeps EVERY `broadcast` node in the
// shared corpus — including the bare-expression fixtures under
// tests/property_corpus/**, which no document-level test loads — through
// checkBroadcastFn. Exactly one fixture may be rejected: the one pinned invalid.
//
// This is the regression that keeps the rule honest in both directions. Deriving
// the arity from arithOpTable rather than hard-coding "at least 2" is what makes
// the one-operand `broadcast(fn:"+", args:[1])` of expr_039/expr_040 legal, and
// this sweep is what would notice if that ever stopped being true.
func TestCorpusBroadcastNodesAreAccepted(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	// The only corpus fixture whose `broadcast` node is deliberately malformed.
	const pinnedInvalid = "broadcast_fn_unregistered.esm"

	swept, rejected := 0, 0
	walkErr := filepath.WalkDir(filepath.Join(repoRoot, "tests"), func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err //nolint:wrapcheck // walk callback
		}
		if ext := filepath.Ext(path); ext != ".esm" && ext != ".json" {
			return nil
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		var doc any
		if json.Unmarshal(raw, &doc) != nil {
			return nil
		}
		forEachBroadcastNode(doc, func(node ExprNode) {
			swept++
			finding := checkBroadcastFn(node)
			if finding == nil {
				return
			}
			rejected++
			if filepath.Base(path) != pinnedInvalid {
				t.Errorf("%s: corpus `broadcast` node newly rejected: %s",
					mustRel(repoRoot, path), finding.message)
			}
		})
		return nil
	})
	if walkErr != nil {
		t.Fatalf("walk tests/: %v", walkErr)
	}
	// A floor, so a sweep that silently stops reaching the corpus fails loudly.
	if swept < 15 {
		t.Fatalf("swept only %d broadcast nodes, want >= 15: the sweep is not reaching the corpus", swept)
	}
	if rejected != 1 {
		t.Errorf("rejected %d corpus broadcast nodes, want exactly 1 (%s)", rejected, pinnedInvalid)
	}
}

func mustRel(base, path string) string {
	rel, err := filepath.Rel(base, path)
	if err != nil {
		return path
	}
	return rel
}

// forEachBroadcastNode visits every `{"op": "broadcast", …}` object in a decoded
// JSON document, normalized to an ExprNode.
func forEachBroadcastNode(doc any, visit func(ExprNode)) {
	switch v := doc.(type) {
	case map[string]any:
		if op, _ := v["op"].(string); op == opBroadcast {
			if node, ok := asExprNode(v); ok {
				visit(node)
			}
		}
		for _, child := range v {
			forEachBroadcastNode(child, visit)
		}
	case []any:
		for _, child := range v {
			forEachBroadcastNode(child, visit)
		}
	}
}
