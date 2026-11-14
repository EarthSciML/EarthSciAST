package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The deprecated `neg` / `pow` rewrite at the wire boundary (esm-spec §4.2
// "Deprecated ops", CONFORMANCE_SPEC `deprecated_op`).

func deprecatedOpsRepoPath(parts ...string) string {
	_, thisFile, _, _ := runtime.Caller(0)
	root := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..")
	return filepath.Join(append([]string{root}, parts...)...)
}

// equationRHS returns the RHS of the equation of model whose LHS is lhs.
func equationRHS(t *testing.T, file *ESMFile, model, lhs string) ExprNode {
	t.Helper()
	m, ok := file.Models[model]
	if !ok {
		t.Fatalf("no model %q", model)
	}
	for _, eq := range m.Equations {
		if s, ok := eq.LHS.(string); ok && s == lhs {
			switch v := eq.RHS.(type) {
			case ExprNode:
				return v
			case *ExprNode:
				return *v
			}
			t.Fatalf("rhs of %s is %T, not a node", lhs, eq.RHS)
		}
	}
	t.Fatalf("no equation for %q in %q", lhs, model)
	return ExprNode{}
}

func TestDeprecatedPowRewrittenOnLoad(t *testing.T) {
	path := deprecatedOpsRepoPath("tests", "conformance", "scalar_operator_semantics", "fixtures", "pow_alias.esm")
	file, stderr := loadCapturingStderr(t, path)
	rhs := equationRHS(t, file, "PowAlias", "pow_power")
	if rhs.Op != "^" || len(rhs.Args) != 2 {
		t.Fatalf("pow not rewritten: %+v", rhs)
	}
	if strings.Count(stderr, codeDeprecatedOp) != 1 {
		t.Fatalf("want exactly one %s warning, got %q", codeDeprecatedOp, stderr)
	}
	if !strings.Contains(stderr, "/models/PowAlias/equations/0/rhs (pow)") {
		t.Errorf("warning does not name the node: %q", stderr)
	}
	out, err := ToJSON(file)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, `"pow"`) {
		t.Errorf("emitted document still spells pow")
	}
}

func TestDeprecatedNegRewrittenOnLoad(t *testing.T) {
	path := deprecatedOpsRepoPath("tests", "conformance", "scalar_operator_semantics", "fixtures", "scalar_operator_semantics.esm")
	file, stderr := loadCapturingStderr(t, path)
	rhs := equationRHS(t, file, "Ops", "negated")
	if rhs.Op != "-" || len(rhs.Args) != 1 || rhs.Args[0] != "four" {
		t.Fatalf("neg not rewritten to unary -: %+v", rhs)
	}
	if strings.Count(stderr, codeDeprecatedOp) != 1 || !strings.Contains(stderr, "(neg)") {
		t.Fatalf("want one %s warning naming neg, got %q", codeDeprecatedOp, stderr)
	}
}

func TestDeprecatedBroadcastFnNegRewrittenOnLoad(t *testing.T) {
	path := deprecatedOpsRepoPath("tests", "fixtures", "faq", "27_broadcast_unary.esm")
	_, stderr := loadCapturingStderr(t, path)
	if strings.Count(stderr, codeDeprecatedOp) != 1 || !strings.Contains(stderr, "(broadcast fn neg)") {
		t.Fatalf("want one %s warning naming the broadcast fn, got %q", codeDeprecatedOp, stderr)
	}
}

func TestRewriteDeprecatedOpsText(t *testing.T) {
	cases := []struct {
		name, in, want string
		sites          []string
	}{
		{
			name:  "neg keeps other fields and key order",
			in:    `{"x": {"id": "n1", "op": "neg", "args": ["a"]}}`,
			want:  `{"x": {"id": "n1", "op": "-", "args": ["a"]}}`,
			sites: []string{"/x (neg)"},
		},
		{
			name:  "args before op, nested",
			in:    `{"e": {"args": [{"op":"pow","args":["a",2]}, 1], "op": "neg"}}`,
			want:  `{"e": {"args": [{"op":"^","args":["a",2]}, 1], "op": "neg"}}`,
			sites: []string{"/e/args/0 (pow)"},
		},
		{
			name:  "wrong arity left alone",
			in:    `{"a": {"op": "neg", "args": ["x", "y"]}, "b": {"op": "pow", "args": ["x"]}}`,
			want:  `{"a": {"op": "neg", "args": ["x", "y"]}, "b": {"op": "pow", "args": ["x"]}}`,
			sites: nil,
		},
		{
			name:  "broadcast fn",
			in:    `{"op": "broadcast", "fn": "neg", "args": ["a"]}`,
			want:  `{"op": "broadcast", "fn": "-", "args": ["a"]}`,
			sites: []string{" (broadcast fn neg)"},
		},
		{
			name:  "two-operand broadcast of neg keeps its arity error",
			in:    `{"op": "broadcast", "fn": "neg", "args": ["a", "a"]}`,
			want:  `{"op": "broadcast", "fn": "neg", "args": ["a", "a"]}`,
			sites: nil,
		},
		{
			name:  "pointer segments are escaped",
			in:    `{"a/b~c": {"op": "neg", "args": ["x"]}}`,
			want:  `{"a/b~c": {"op": "-", "args": ["x"]}}`,
			sites: []string{"/a~1b~0c (neg)"},
		},
		{
			name:  "a string value that merely reads neg is not an op",
			in:    `{"name": "neg", "description": "pow"}`,
			want:  `{"name": "neg", "description": "pow"}`,
			sites: nil,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, sites := rewriteDeprecatedOps(c.in)
			if got != c.want {
				t.Errorf("got %s\nwant %s", got, c.want)
			}
			if strings.Join(sites, "|") != strings.Join(c.sites, "|") {
				t.Errorf("sites %v, want %v", sites, c.sites)
			}
			var v any
			if err := json.Unmarshal([]byte(got), &v); err != nil {
				t.Errorf("rewritten text is not JSON: %v", err)
			}
		})
	}
}

// A two-operand broadcast of `neg` is not rewritten to `fn: "-"` (which would
// silently mean subtraction): the load refuses it for its arity, as before.
func TestWrongArityBroadcastNegRefused(t *testing.T) {
	doc := `{"esm": "2.0.0", "metadata": {"name": "B"}, "models": {"M": {
	  "variables": {"a": {"type": "unknown", "units": "1", "default": 0.0}},
	  "equations": [{"lhs": {"op": "D", "args": ["a"], "wrt": "t"},
	                 "rhs": {"op": "broadcast", "fn": "neg", "args": ["a", "a"]}}]}}}`
	file, err := LoadString(doc)
	msg := ""
	if err != nil {
		msg = err.Error()
	} else {
		for _, e := range Validate(file).StructuralErrors {
			msg += e.Code + " " + e.Message + "; "
		}
	}
	if !strings.Contains(msg, "invalid_broadcast_fn") || !strings.Contains(msg, "'neg'") {
		t.Fatalf("a two-operand broadcast of neg must be refused for its arity, got %q", msg)
	}
}

// The reference-preserving emit path applies the same wire boundary as a load,
// so a deprecated spelling never reaches the emitted document.
func TestEmitReferencePreservingRewritesDeprecatedOps(t *testing.T) {
	path := deprecatedOpsRepoPath("tests", "conformance", "scalar_operator_semantics", "fixtures", "pow_alias.esm")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out, err := EmitReferencePreserving(string(src), filepath.Dir(path), nil)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	if strings.Contains(out, `"pow"`) || strings.Contains(out, `"neg"`) {
		t.Fatalf("emitted document still spells a deprecated op:\n%s", out)
	}
}
