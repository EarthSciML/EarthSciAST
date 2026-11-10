package esm

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// removedOpDoc is a minimal model whose one equation carries `node` as an
// operand, so the removed op sits below the right-hand side's root.
func removedOpDoc(esm, node string) string {
	return fmt.Sprintf(`{
	  "esm": %q,
	  "metadata": {"name": "removed"},
	  "models": {"M": {
	    "variables": {"x": {"type": "unknown", "default": 0.0}},
	    "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
	                   "rhs": {"op": "+", "args": [1.0, %s]}}]
	  }}
	}`, esm, node)
}

// requireRemovedOp asserts err is the `removed_op` diagnostic naming name at
// path and, for a 2.0.0 removal, the codemod.
func requireRemovedOp(t *testing.T, err error, name, path string) {
	t.Helper()
	var de DiagnosticError
	if !errors.As(err, &de) || de.DiagnosticCode() != "removed_op" {
		t.Fatalf("err = %v, want the removed_op diagnostic", err)
	}
	var re *removedOpError
	if !errors.As(err, &re) {
		t.Fatalf("err = %T, want *removedOpError", err)
	}
	if re.Name != name || re.Path != path {
		t.Errorf("removed construct = %q at %q, want %q at %q", re.Name, re.Path, name, path)
	}
	for _, want := range []string{name, path} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("message %q does not name %q", err.Error(), want)
		}
	}
	if removedOps[name] != "0.8.0" && !strings.Contains(err.Error(), migrateCommand) {
		t.Errorf("message %q does not point at the codemod", err.Error())
	}
}

// Every op esm 2.0.0 removed is refused BY NAME at load, before schema
// validation and before the rewrite-target tier, under a 1.x or a 2.0.0
// declared version alike.
func TestRemovedOpsAreRefusedAtLoad(t *testing.T) {
	nodes := map[string]string{
		"fn":                        `{"op": "fn", "name": "datetime.year", "args": ["t"]}`,
		"table_lookup":              `{"op": "table_lookup", "table": "T", "axes": {"p": "x"}, "args": []}`,
		"skolem":                    `{"op": "skolem", "args": ["x", "x"], "label": "edge"}`,
		"rank":                      `{"op": "rank", "args": ["x"]}`,
		"intersect_polygon":         `{"op": "intersect_polygon", "manifold": "planar", "args": ["x", "x"]}`,
		"polygon_intersection_area": `{"op": "polygon_intersection_area", "manifold": "spherical", "args": ["x", "x"]}`,
		"argmin":                    `{"op": "argmin", "arg": "g", "expr": "x", "ranges": {"g": [1, 3]}, "args": ["x"]}`,
		"argmax":                    `{"op": "argmax", "arg": "g", "expr": "x", "ranges": {"g": [1, 3]}, "args": ["x"]}`,
		"aggregate":                 `{"op": "aggregate", "output_idx": [], "expr": "x", "ranges": {"g": [1, 3]}, "args": []}`,
	}
	for name, removedVersion := range removedOps {
		if removedVersion != "2.0.0" {
			continue
		}
		node, ok := nodes[name]
		if !ok {
			t.Fatalf("no test node for removed op %q", name)
		}
		for _, esm := range []string{"1.3.0", "2.0.0"} {
			t.Run(name+"@"+esm, func(t *testing.T) {
				_, err := LoadString(removedOpDoc(esm, node))
				requireRemovedOp(t, err, name, "/models/M/equations/0/rhs/args/1")
			})
		}
	}
}

// The `function_tables` block is refused under the same code, at the top level
// and inside a component, and the message names the field.
func TestFunctionTablesBlockIsRefusedAtLoad(t *testing.T) {
	table := `{"T": {"axes": [{"name": "p", "values": [1.0, 2.0]}], "data": [1.0, 2.0]}}`
	topLevel := `{"esm": "1.3.0", "metadata": {"name": "ft"}, "function_tables": ` + table + `,
	  "models": {"M": {"variables": {"x": {"type": "unknown", "default": 0.0}},
	    "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 1.0}]}}}`
	_, err := LoadString(topLevel)
	requireRemovedOp(t, err, "function_tables", "/function_tables")

	inModel := `{"esm": "2.0.0", "metadata": {"name": "ft"},
	  "models": {"M": {"function_tables": ` + table + `,
	    "variables": {"x": {"type": "unknown", "default": 0.0}},
	    "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 1.0}]}}}`
	_, err = LoadString(inModel)
	requireRemovedOp(t, err, "function_tables", "/models/M/function_tables")
}

// A removed op inside an expression-template body and inside a `{ref}`-loaded
// child is refused too: every document goes through the same wire boundary.
func TestRemovedOpInTemplateBodyAndRefChild(t *testing.T) {
	tmpl := `{"esm": "1.3.0", "metadata": {"name": "tmpl"},
	  "models": {"M": {
	    "expression_templates": {"k": {"params": ["a"],
	      "body": {"op": "rank", "args": ["a"]}}},
	    "variables": {"x": {"type": "unknown", "default": 0.0}},
	    "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 1.0}]}}}`
	_, err := LoadString(tmpl)
	requireRemovedOp(t, err, "rank", "/models/M/expression_templates/k/body")

	dir := t.TempDir()
	child := removedOpDoc("1.3.0", `{"op": "skolem", "args": ["x", "x"]}`)
	if err := os.WriteFile(filepath.Join(dir, "child.esm"), []byte(child), 0o644); err != nil {
		t.Fatal(err)
	}
	parent := `{"esm": "2.0.0", "metadata": {"name": "parent"},
	  "models": {"P": {"variables": {"y": {"type": "unknown", "default": 0.0}},
	    "equations": [{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": 1.0}],
	    "subsystems": {"C": {"ref": "./child.esm"}}}}}`
	parentPath := filepath.Join(dir, "parent.esm")
	if err := os.WriteFile(parentPath, []byte(parent), 0o644); err != nil {
		t.Fatal(err)
	}
	// The mount reports the child's refusal inside its own
	// `unresolved_subsystem_ref`, as it does for `arrayop`.
	_, err = LoadPath(parentPath)
	if err == nil || !strings.Contains(err.Error(), "[removed_op] `\"op\": \"skolem\"` at /models/M/equations/0/rhs/args/1") {
		t.Fatalf("err = %v, want the child's removed_op refusal", err)
	}
}

// The names the 2.0.0 break kept are not swept up: `distinct` and `join` stay,
// and an `apply_expression_template` of the esm:std `argmin` template is a
// template reference, not the removed op.
func TestRemovedOpsSpareKeptNames(t *testing.T) {
	for _, node := range []string{
		`{"op": "apply_expression_template", "name": "argmin", "bindings": {}, "args": []}`,
		`{"op": "floor", "args": ["rank"]}`,
	} {
		if err := checkRemovedConstructs(removedOpDoc("2.0.0", node), ""); err != nil {
			t.Errorf("%s: refused: %v", node, err)
		}
		removed, _ := scanOps(removedOpDoc("2.0.0", node))
		if removed != "" {
			t.Errorf("%s: scan reported removed op %q", node, removed)
		}
	}
	for _, kept := range []string{"distinct", "join", "faq"} {
		if _, gone := removedOps[kept]; gone {
			t.Errorf("%q must not be a removed op", kept)
		}
	}
}

// The text form refuses a removed op spelled as a call, and a dotted callee
// (the closed-function spelling), rather than reading either as an open op.
func TestParseExpressionRefusesRemovedCallees(t *testing.T) {
	for _, src := range []string{
		"datetime.year(t)", "interp.linear(tbl, ax, x)", "skolem(a, b)", "rank(S)",
		"argmin(a)", "table_lookup(a)", "polygon_intersection_area(a, b)",
	} {
		if _, err := ParseExpression(src); err == nil || !strings.Contains(err.Error(), "removed_op") {
			t.Errorf("ParseExpression(%q) = %v, want a removed_op refusal", src, err)
		}
	}
	if _, err := ParseExpression("argmin<f = d, n = 3>"); err != nil {
		t.Errorf("the esm:std argmin template application must still parse: %v", err)
	}
}
