package esm

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestFlatten_SingleModelNamespacesVariables(t *testing.T) {
	file := &ESMFile{
		Models: map[string]Model{
			"Atmos": {
				Variables: map[string]ModelVariable{
					"T": {Type: "state"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{},
			},
		},
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}

	if !contains(flat.StateVariables, "Atmos.T") {
		t.Errorf("expected Atmos.T in state variables, got %v", flat.StateVariables)
	}
	if !contains(flat.Parameters, "Atmos.k") {
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

	if !contains(flat.StateVariables, "Chem.O3") {
		t.Errorf("expected Chem.O3 in state variables, got %v", flat.StateVariables)
	}
	if !contains(flat.Parameters, "Chem.k1") {
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
		got, ok := flat.InitialValues[name]
		if !ok {
			t.Errorf("expected initial value for %s, got none (map=%v)", name, flat.InitialValues)
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
				Variables: map[string]ModelVariable{"x": {Type: "state"}},
				Equations: []Equation{},
			},
			"B": {
				Variables: map[string]ModelVariable{"y": {Type: "parameter"}},
				Equations: []Equation{},
			},
		},
		Coupling: []any{
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

func TestReplaceVarToken_RespectsTokenBoundaries(t *testing.T) {
	// "A.x" must not corrupt the distinct tokens "A.x2" and "BA.x" the way a
	// naive strings.ReplaceAll would (esm audit bug).
	if got, want := replaceVarToken("A.x + A.x2 + BA.x", "A.x", "Z"), "Z + A.x2 + BA.x"; got != want {
		t.Errorf("replaceVarToken = %q; want %q", got, want)
	}
	// A whole-token match inside a function wrapper is still replaced.
	if got, want := replaceVarToken("D(A.x, t)", "A.x", "Z"), "D(Z, t)"; got != want {
		t.Errorf("replaceVarToken = %q; want %q", got, want)
	}
	// A deeper path names a different variable and must be left intact.
	if got, want := replaceVarToken("A.x.y", "A.x", "Z"), "A.x.y"; got != want {
		t.Errorf("replaceVarToken = %q; want %q", got, want)
	}
}

func TestNamespaceExpression_PowIsLeftAssociative(t *testing.T) {
	// (a^b)^c must not render as a^b^c, which reparses as a^(b^c).
	inner := ExprNode{Op: "^", Args: []any{"a", "b"}}
	node := ExprNode{Op: "^", Args: []any{inner, "c"}}
	if got, want := namespaceExpression(node, "S", map[string]bool{}), "(a^b)^c"; got != want {
		t.Errorf("namespaceExpression = %q; want %q", got, want)
	}
	// A pow exponent needs no parens: a^(b^c) renders as a^b^c.
	node2 := ExprNode{Op: "^", Args: []any{"a", ExprNode{Op: "^", Args: []any{"b", "c"}}}}
	if got, want := namespaceExpression(node2, "S", map[string]bool{}), "a^b^c"; got != want {
		t.Errorf("namespaceExpression = %q; want %q", got, want)
	}
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}
