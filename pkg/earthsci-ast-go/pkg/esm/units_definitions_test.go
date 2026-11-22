package esm

// Definition units after edits and at every unit check site (esm-spec §4.8.4,
// §9.6.12 "Units"): the reference-preserving form the load captured types a
// site only while the live site still holds what the load produced, and the
// definition-unit check runs at equations, initialization equations,
// constraint equations and reaction rates, in subsystems at any depth.

import (
	"strings"
	"testing"
)

// udCodes is the set of structural error codes and definition-unit warning
// codes at each pointer.
func udCodes(r *ValidationResult) map[string]string {
	out := map[string]string{}
	for _, e := range r.StructuralErrors {
		out[e.Path] += e.Code + ";"
	}
	for _, w := range r.UnitWarnings {
		if w.Code == codeDefinitionUnitMismatch {
			out[w.Path] += "warning:" + w.Code + ";"
		}
	}
	return out
}

func udLoad(t *testing.T, src string) *ESMFile {
	t.Helper()
	f, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	return f
}

// `good(q)` is q/tau with unit [q]/s; `bad(q)` declares the same unit but its
// body is q*tau, so every call of it is a definition_unit_mismatch.
const udVars = `"x": {"type": "parameter", "units": "m", "default": 1.0},
  "tau": {"type": "parameter", "units": "s", "default": 2.0},
  "y": {"type": "unknown", "units": "m/s"}, "w": {"type": "unknown", "units": "m/s"}`

const udOps = `"operators": {
  "good": {"params": ["q"], "units": {"op": "/", "args": ["q", "tau"]}, "body": {"op": "/", "args": ["q", "tau"]}},
  "bad": {"params": ["q"], "units": {"op": "/", "args": ["q", "tau"]}, "body": {"op": "*", "args": ["q", "tau"]}}}`

func TestDefinitionUnitsFollowEdits(t *testing.T) {
	src := `{"esm": "2.4.0", "metadata": {"name": "x"}, "models": {"m": {
  "variables": {` + udVars + `},
  "equations": [{"lhs": "y", "rhs": "x"}, {"lhs": "w", "rhs": {"op": "good", "args": ["x"]}}], ` + udOps + `}}}`

	// Swapping the equations keeps the real `y = x` (m against m/s) error.
	f := udLoad(t, src)
	m := f.Models["m"]
	m.Equations[0], m.Equations[1] = m.Equations[1], m.Equations[0]
	f.Models["m"] = m
	if got := udCodes(Validate(f)); !strings.Contains(got["/models/m/variables/y"], ErrorUnitInconsistency) {
		t.Errorf("after a swap: %v; want unit_inconsistency at /models/m/variables/y", got)
	}

	// Removing the first equation and adding it back moves it to index 1.
	f = udLoad(t, src)
	m = f.Models["m"]
	first := m.Equations[0]
	m, err := RemoveEquationAt(m, 0)
	if err != nil {
		t.Fatal(err)
	}
	m = AddEquation(m, first)
	f.Models["m"] = m
	if got := udCodes(Validate(f)); !strings.Contains(got["/models/m/variables/y"], ErrorUnitInconsistency) {
		t.Errorf("after remove + add: %v; want unit_inconsistency at /models/m/variables/y", got)
	}

	// Replacing a right-hand side that reached a mismatching definition drops
	// the stale definition_unit_mismatch.
	bad := strings.Replace(src, `"op": "good"`, `"op": "bad"`, 1)
	f = udLoad(t, bad)
	if got := udCodes(Validate(f)); !strings.Contains(got["/models/m/variables/w"], codeDefinitionUnitMismatch) {
		t.Fatalf("as loaded: %v; want definition_unit_mismatch at /models/m/variables/w", got)
	}
	m = f.Models["m"]
	m.Equations[1].RHS = ExprNode{Op: "/", Args: []any{"x", "tau"}}
	f.Models["m"] = m
	if got := udCodes(Validate(f)); strings.Contains(got["/models/m/variables/w"], codeDefinitionUnitMismatch) {
		t.Errorf("after replacing the rhs: %v; want no definition_unit_mismatch", got)
	}
}

func TestDefinitionUnitsAtEverySite(t *testing.T) {
	call := `{"op": "bad", "args": ["x"]}`
	src := `{"esm": "2.4.0", "metadata": {"name": "x"},
 "models": {"m": {
  "variables": {` + udVars + `, "s": {"type": "unknown", "units": "m/s"}},
  "equations": [{"lhs": {"op": "D", "args": ["s"], "wrt": "t"}, "rhs": 0}],
  "initialization_equations": [{"lhs": "s", "rhs": ` + call + `}],
  "subsystems": {"Sub": {
    "variables": {"x": {"type": "parameter", "units": "m", "default": 1.0},
                  "tau": {"type": "parameter", "units": "s", "default": 2.0},
                  "v": {"type": "unknown", "units": "m/s"}},
    "equations": [{"lhs": "v", "rhs": ` + call + `}]}}, ` + udOps + `}},
 "reaction_systems": {"r": {
  "species": {"A": {"units": "mol/m^3", "default": 1.0}},
  "parameters": {"x": {"units": "m", "default": 1.0}, "tau": {"units": "s", "default": 2.0}},
  "reactions": [{"id": "r1", "substrates": [{"species": "A", "stoichiometry": 1}], "products": null, "rate": ` + call + `}],
  "constraint_equations": [{"lhs": "x", "rhs": ` + call + `}], ` + udOps + `}}}`
	got := udCodes(Validate(udLoad(t, src)))
	for _, at := range []string{
		"/models/m/initialization_equations/0",
		"/models/m/subsystems/Sub/variables/v",
		"/reaction_systems/r/reactions/0",
		"/reaction_systems/r/constraint_equations/0",
	} {
		if !strings.Contains(got[at], codeDefinitionUnitMismatch) {
			t.Errorf("no definition_unit_mismatch at %s; findings: %v", at, got)
		}
	}
}

// Subsystem equations are unit-checked like a top-level model's.
func TestSubsystemEquationsAreUnitChecked(t *testing.T) {
	f := udLoad(t, `{"esm": "2.4.0", "metadata": {"name": "x"}, "models": {"m": {
  "variables": {"z": {"type": "unknown", "units": "m"}},
  "equations": [{"lhs": "z", "rhs": "Sub.x"}],
  "subsystems": {"Sub": {
    "variables": {"x": {"type": "parameter", "units": "m", "default": 1.0},
                  "v": {"type": "unknown", "units": "m/s"}},
    "equations": [{"lhs": "v", "rhs": "x"}]}}}}}`)
	if got := udCodes(Validate(f)); !strings.Contains(got["/models/m/subsystems/Sub/variables/v"], ErrorUnitInconsistency) {
		t.Errorf("findings %v; want unit_inconsistency at /models/m/subsystems/Sub/variables/v", got)
	}
}
