package esm

import (
	"path/filepath"
	"reflect"
	"testing"
)

// faqBareDoc is a one-model document whose single equation is
// `out ~ faq(i ∈ a_rows, expr: <expr>)`, with the local template
// `twice(x) = 2x` and the shaped parameters `v` and `w` over `a_rows`.
func faqBareDoc(expr string) string {
	return `{"esm":"1.2.0","metadata":{"name":"t","authors":["t"]},
 "index_sets":{"a_rows":{"kind":"interval","size":2}},
 "models":{"Probe":{
  "variables":{
   "v":{"type":"parameter","units":"1","shape":["a_rows"],"default":[1.0,2.0]},
   "w":{"type":"parameter","units":"1","shape":["a_rows"],"default":[10.0,20.0]},
   "out":{"type":"unknown","units":"1","shape":["a_rows"]}},
  "expression_templates":{"twice":{"params":["x"],"body":{"op":"*","args":[2.0,"x"]}}},
  "equations":[{"lhs":"out","rhs":{"op":"faq","args":[],"semiring":"sum_product",
   "output_idx":["i"],"ranges":{"i":{"from":"a_rows"}},"expr":` + expr + `}}]}}}`
}

func faqBareFindings(t *testing.T, doc string) []StructuralError {
	t.Helper()
	file, err := LoadString(doc)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	var out []StructuralError
	for _, e := range Validate(file).StructuralErrors {
		if e.Code == CodeFAQBareArrayOperand {
			out = append(out, e)
		}
	}
	return out
}

// A template application is opaque to faq_bare_array_operand (esm-spec §4.3.1):
// the array bound to its argument is not a bare read, although load has
// already expanded the application into `2 * v`.
func TestFAQBareArrayOperandTemplateApplicationOpaque(t *testing.T) {
	apply := `{"op":"apply_expression_template","args":[],"name":"twice","bindings":{"x":"v"}}`
	if got := faqBareFindings(t, faqBareDoc(`{"op":"+","args":[`+apply+`,{"op":"index","args":["w","i"]}]}`)); len(got) != 0 {
		t.Fatalf("template argument reported as a bare read: %+v", got)
	}
	// Opaque is per application, not per equation: a bare read beside it is
	// still reported, and only that one.
	got := faqBareFindings(t, faqBareDoc(`{"op":"+","args":[`+apply+`,"w"]}`))
	if len(got) != 1 || got[0].Details["variable"] != "w" {
		t.Fatalf("want one finding for w, got %+v", got)
	}
}

// The authored-form record reaches a template application inside an inline
// subsystem too.
func TestFAQBareArrayOperandTemplateOpaqueInSubsystem(t *testing.T) {
	inner := faqBareDoc(`{"op":"+","args":[{"op":"apply_expression_template","args":[],"name":"twice","bindings":{"x":"v"}},"w"]}`)
	file, err := LoadString(inner)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if _, ok := file.authoredTemplateRHS["/models/Probe/equations/0"]; !ok {
		t.Fatalf("authored right-hand side not recorded: %v", file.authoredTemplateRHS)
	}
	view := map[string]any{"models": map[string]any{"Host": map[string]any{
		"subsystems": map[string]any{"Probe": map[string]any{"equations": []any{
			map[string]any{"lhs": "out", "rhs": map[string]any{"op": "apply_expression_template", "name": "twice"}},
		}}},
	}}}
	if _, ok := authoredTemplateApplications(view)["/models/Host/subsystems/Probe/equations/0"]; !ok {
		t.Fatal("a subsystem equation's template application was not recorded")
	}
}

// The left-hand-side exemption is for an observed or recurrence definition's
// self-read only; a derivative's own state read bare is reported. And the check
// walks inline subsystems, as do the other per-equation faq checks.
func TestFAQBareArrayOperandDerivativeAndSubsystemFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	// The derivative fixture spells the defect twice: `D(y)` and the
	// array-equation `faq[i](D(z[i]))`.
	for name, want := range map[string][]string{
		"bare_array_operand_derivative.esm": {
			CodeFAQBareArrayOperand + " /models/Probe/equations/0/rhs",
			CodeFAQBareArrayOperand + " /models/Probe/equations/1/rhs",
		},
		"bare_array_operand_subsystem.esm": {
			CodeFAQBareArrayOperand + " /models/Host/subsystems/Probe/equations/2/rhs",
		},
		"ragged_values_not_gathered_subsystem.esm": {
			CodeRaggedValuesNotGathered + " /models/Host/subsystems/RaggedValuesNotGathered/equations/3/rhs",
		},
	} {
		t.Run(name, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(repoRoot, "tests", "invalid", "faq", name))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			var got []string
			for _, e := range Validate(file).StructuralErrors {
				got = append(got, e.Code+" "+e.Path)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("want exactly %v, got %v", want, got)
			}
		})
	}
}
