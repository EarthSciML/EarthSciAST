package esm

import (
	"strings"
	"testing"
)

// esm-spec §2.2: an empty `solver` block is LEGAL and normalizes to absence at
// load. Pinned in Go specifically because the struct tag does not give this for
// free: `omitempty` on a POINTER tests nil, not emptiness, so a decoded
// `&Solver{}` would re-emit as `"solver": {}` while Python and Julia dropped it
// — five bindings disagreeing about one document.
func TestSolverEmptyBlockNormalizesToAbsence(t *testing.T) {
	base := `{"esm":"1.1.0","metadata":{"name":"T"},%s"models":{"M":{"variables":{"x":{"type":"unknown","units":"m","default":1.0}},"equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":{"op":"neg","args":["x"]}}]}}}`
	f, err := LoadString(strings.Replace(base, "%s", `"solver":{},`, 1))
	if err != nil {
		t.Fatalf("empty block must be LEGAL: %v", err)
	}
	if f.SolverHints != nil {
		t.Errorf("empty block must normalize to absence at load, got %+v", f.SolverHints)
	}
	out, err := ToJSON(f)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, `"solver"`) {
		t.Errorf("empty block must not survive to emit:\n%s", out)
	}
	// A non-empty block is untouched.
	f2, err := LoadString(strings.Replace(base, "%s", `"solver":{"stiffness":"high"},`, 1))
	if err != nil {
		t.Fatal(err)
	}
	if f2.SolverHints == nil || f2.SolverHints.Stiffness == nil || *f2.SolverHints.Stiffness != "high" {
		t.Errorf("non-empty block must be preserved, got %+v", f2.SolverHints)
	}
}
