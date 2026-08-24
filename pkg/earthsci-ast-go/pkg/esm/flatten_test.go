package esm

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestFlatten_SingleModelNamespacesVariables(t *testing.T) {
	// The role lists are DERIVED from the equations (esm-spec §6.3.1), so `T` is
	// an ODE state because an equation differentiates it — not because it is
	// declared one. A declaration alone no longer says.
	file := &ESMFile{
		Models: map[string]Model{
			"Atmos": {
				Variables: map[string]ModelVariable{
					"T": {Type: "unknown"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{{
					LHS: ExprNode{Op: "D", Args: []any{"T"}, Wrt: strPtr("t")},
					RHS: ExprNode{Op: "-", Args: []any{"k"}},
				}},
			},
		},
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}

	if !containsVar(flat.StateVariables, "Atmos.T") {
		t.Errorf("expected Atmos.T in state variables, got %v", flat.StateVariables)
	}
	if !containsVar(flat.Parameters, "Atmos.k") {
		t.Errorf("expected Atmos.k in parameters, got %v", flat.Parameters)
	}
	if !contains(flat.Metadata.SourceSystems, "Atmos") {
		t.Errorf("expected Atmos in source systems, got %v", flat.Metadata.SourceSystems)
	}
}

func TestFlatten_ReactionSystemNamespacesSpecies(t *testing.T) {
	file := &ESMFile{
		ReactionSystems: map[string]ReactionSystem{
			"Chem": {
				Species: map[string]Species{
					"O3": {},
				},
				Parameters: map[string]Parameter{
					"k1": {},
				},
				Reactions: []Reaction{},
			},
		},
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}

	if !containsVar(flat.StateVariables, "Chem.O3") {
		t.Errorf("expected Chem.O3 in state variables, got %v", flat.StateVariables)
	}
	if !containsVar(flat.Parameters, "Chem.k1") {
		t.Errorf("expected Chem.k1 in parameters, got %v", flat.Parameters)
	}
}

func TestFlatten_ReactionSystemHonorsSpeciesDefault(t *testing.T) {
	// A species' declared scalar `default` must flow through to the flattened
	// system's initial-value vector. Absent defaults fall back to 0.0.
	file := &ESMFile{
		ReactionSystems: map[string]ReactionSystem{
			"Chem": {
				Species: map[string]Species{
					// json.Number is what the UseNumber-based parser produces.
					"O3":  {Default: json.Number("3.0")},
					"NO2": {Default: 5.0},              // float64, as built directly in code
					"NO":  {},                          // no default -> sensible fallback (0.0)
					"O":   {Default: json.Number("0")}, // explicit zero must survive
				},
				Parameters: map[string]Parameter{"k1": {}},
				Reactions:  []Reaction{},
			},
		},
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}

	cases := map[string]float64{
		"Chem.O3":  3.0,
		"Chem.NO2": 5.0,
		"Chem.NO":  0.0,
		"Chem.O":   0.0,
	}
	for name, want := range cases {
		initial := flat.InitialValues()
		got, ok := initial[name]
		if !ok {
			t.Errorf("expected initial value for %s, got none (map=%v)", name, initial)
			continue
		}
		if got != want {
			t.Errorf("initial value for %s = %v, want %v", name, got, want)
		}
	}
}

func TestFlatten_RecordsCouplingRules(t *testing.T) {
	file := &ESMFile{
		Models: map[string]Model{
			"A": {
				Variables: map[string]ModelVariable{"x": {Type: "unknown"}},
				Equations: []Equation{},
			},
			"B": {
				Variables: map[string]ModelVariable{"y": {Type: "parameter"}},
				Equations: []Equation{},
			},
		},
		Coupling: []CouplingEntry{
			VariableMapCoupling{
				Type:      "variable_map",
				From:      "A.x",
				To:        "B.y",
				Transform: "identity",
			},
		},
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}

	if len(flat.Metadata.CouplingRules) == 0 {
		t.Fatalf("expected coupling rules to be recorded")
	}
	found := false
	for _, rule := range flat.Metadata.CouplingRules {
		if strings.Contains(rule, "variable_map") || strings.Contains(rule, "VariableMap") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected variable_map rule, got %v", flat.Metadata.CouplingRules)
	}
}

// TestFlatten_VariableMapSubstitutionIsTokenExact pins what the old text-splice
// substitution could only approximate: a `variable_map` targeting `B.y` rewrites
// exactly that reference and never the distinct longer name `B.y2`.
//
// It used to be a unit test on a string-rewriting helper (replaceVarToken) whose
// whole job was to re-derive token boundaries out of rendered text. The
// substitution is STRUCTURAL now — it replaces a string LEAF of the AST — so a
// prefix collision is impossible by construction, and this exercises the property
// end to end instead of the machinery that used to be needed for it.
func TestFlatten_VariableMapSubstitutionIsTokenExact(t *testing.T) {
	src := `{
	  "esm":"1.0.0",
	  "metadata":{"name":"token-exact"},
	  "models":{
	    "A":{"variables":{"p":{"type":"unknown","default":0.0},"x":{"type":"parameter","default":1.0}},
	         "equations":[{"lhs":{"op":"D","args":["p"],"wrt":"t"},"rhs":"x"}]},
	    "B":{"variables":{"q":{"type":"unknown","default":0.0},
	                      "y":{"type":"parameter","default":1.0},
	                      "y2":{"type":"parameter","default":1.0}},
	         "equations":[{"lhs":{"op":"D","args":["q"],"wrt":"t"},"rhs":{"op":"+","args":["y","y2"]}}]}
	  },
	  "coupling":[{"type":"variable_map","from":"A.x","to":"B.y","transform":"param_to_var"}]}`

	file, err := LoadString(src)
	if err != nil {
		t.Fatal(err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}
	for _, eq := range flat.Equations {
		rhs := eq.RHSString()
		if !strings.Contains(rhs, "B.y2") {
			continue
		}
		if strings.Contains(rhs, "A.x2") || !strings.Contains(rhs, "A.x") {
			t.Errorf("variable_map rewrote the wrong tokens: %q", rhs)
		}
		return
	}
	t.Fatal("no flattened equation referenced the mapped variables")
}

// TestFlattenEquationRendering_PowIsLeftAssociative pins that a flattened
// equation renders through the SHARED display renderer: (a^b)^c must not come
// out as a^b^c, which reparses right-associatively. Flatten used to carry its own
// pretty-printer, which is why this assertion lived on that printer; the trees
// now render with ToAscii, which the cross-language display corpus pins.
func TestFlattenEquationRendering_PowIsLeftAssociative(t *testing.T) {
	inner := ExprNode{Op: "^", Args: []any{"a", "b"}}
	eq := FlattenedEquation{RHS: ExprNode{Op: "^", Args: []any{inner, "c"}}}
	if got := eq.RHSString(); !strings.HasPrefix(got, "(") {
		t.Errorf("RHSString = %q; a pow base must be parenthesized", got)
	}
	eq2 := FlattenedEquation{RHS: ExprNode{Op: "^", Args: []any{"a", ExprNode{Op: "^", Args: []any{"b", "c"}}}}}
	if got := eq2.RHSString(); strings.HasPrefix(got, "(") {
		t.Errorf("RHSString = %q; a pow exponent needs no parentheses", got)
	}
}

// containsVar reports whether an ordered flattened-variable map holds `needle`.
func containsVar(haystack []FlattenedVariable, needle string) bool {
	for _, v := range haystack {
		if v.Name == needle {
			return true
		}
	}
	return false
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}
