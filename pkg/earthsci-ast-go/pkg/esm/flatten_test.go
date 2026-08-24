package esm

import (
	"encoding/json"
	"errors"
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

// --- §4.7.1 `operator_compose` translate direction ---------------------------

// twoSystemComposeFile builds A = {D(x) = -kx} and B = {D(y) = -d*y}, two
// systems whose ODE states are spelled DIFFERENTLY. Nothing but a `translate`
// entry can compose them: there is no `_var` placeholder and no shared bare
// name, so a translate map consulted in the wrong direction produces two
// separate equations instead of one summed one.
func twoSystemComposeFile(translate map[string]any) *ESMFile {
	return &ESMFile{
		Models: map[string]Model{
			"A": {
				Variables: map[string]ModelVariable{"x": {Type: "unknown"}, "k": {Type: "parameter"}},
				Equations: []Equation{{
					LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
					RHS: ExprNode{Op: "*", Args: []any{-1.0, "k", "x"}},
				}},
			},
			"B": {
				Variables: map[string]ModelVariable{"y": {Type: "unknown"}, "d": {Type: "parameter"}},
				Equations: []Equation{{
					LHS: ExprNode{Op: "D", Args: []any{"y"}, Wrt: strPtr("t")},
					RHS: ExprNode{Op: "*", Args: []any{-1.0, "d", "y"}},
				}},
			},
		},
		Coupling: []CouplingEntry{OperatorComposeCoupling{
			Type:      "operator_compose",
			Systems:   [2]string{"A", "B"},
			Translate: translate,
		}},
	}
}

// TestFlattenOperatorCompose_TranslateIsAKeyedBValued pins esm-spec §10.2 /
// §4.7.1 step 2: for `"systems": [A, B]` the KEYS name variables of A and the
// VALUES name variables of B. The binding indexed that map by B's dependent
// variable — backwards — so a correctly spelled map matched nothing at all and
// the whole entry was a silent no-op.
func TestFlattenOperatorCompose_TranslateIsAKeyedBValued(t *testing.T) {
	flat, err := Flatten(twoSystemComposeFile(map[string]any{"A.x": "B.y"}))
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}
	if len(flat.Equations) != 1 {
		t.Fatalf("expected the two ODEs to MERGE into one; got %d equations: %v",
			len(flat.Equations), flat.Equations)
	}
	eq := flat.Equations[0]
	if got := ToAscii(eq.LHS); got != "D(A.x)/Dt" {
		t.Errorf("merged LHS = %q, want %q (A's spelling survives)", got, "D(A.x)/Dt")
	}
	// §4.7.1 step 4: on a TRANSLATION match B's dependent variable is rewritten
	// to A's target throughout rhs_B. Leaving `B.y` there would strand it as an
	// unknown nothing defines — its own equation was just consumed by the merge.
	rhs := ToAscii(eq.RHS)
	if strings.Contains(rhs, "B.y") {
		t.Errorf("merged RHS = %q; B's dependent variable must be rewritten to A.x", rhs)
	}
	if !strings.Contains(rhs, "A.k") || !strings.Contains(rhs, "B.d") {
		t.Errorf("merged RHS = %q; both systems' terms must be summed", rhs)
	}
	// B's PARAMETER keeps its own name — only the dependent variable is renamed.
	if !containsVar(flat.Parameters, "B.d") {
		t.Errorf("expected B.d to survive as a parameter, got %v", flat.Parameters)
	}
}

// TestFlattenOperatorCompose_TranslateFactorScalesBsRHS pins the `{var, factor}`
// spelling of §10.2: the factor multiplies B's contribution.
func TestFlattenOperatorCompose_TranslateFactorScalesBsRHS(t *testing.T) {
	flat, err := Flatten(twoSystemComposeFile(map[string]any{
		"A.x": map[string]any{"var": "B.y", "factor": 1e-9},
	}))
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}
	if len(flat.Equations) != 1 {
		t.Fatalf("expected one merged equation, got %d", len(flat.Equations))
	}
	if rhs := ToAscii(flat.Equations[0].RHS); !strings.Contains(rhs, "1.0e-9") {
		t.Errorf("merged RHS = %q; the translate factor must scale B's RHS", rhs)
	}
}

// TestFlattenOperatorCompose_DirectMatchBeatsTranslate pins §4.7.1 step 3's
// precedence AND §10.2's redundancy invariant: `_var` expansion has already
// rewritten B's dependent variable to A's own name, so the expanded equation IS
// a direct match. Consulting `translate` first let an A-keyed map hit spuriously
// on that rewritten name and redirect the match to a target that does not
// exist, turning a working composition into a ConflictingDerivativeError.
// Writing the redundant entry MUST produce the same system as omitting it.
func TestFlattenOperatorCompose_DirectMatchBeatsTranslate(t *testing.T) {
	build := func(translate map[string]any) *ESMFile {
		return &ESMFile{
			Models: map[string]Model{
				"A": {
					Variables: map[string]ModelVariable{"x": {Type: "unknown"}},
					Equations: []Equation{{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: -1.0,
					}},
				},
				"B": {
					Variables: map[string]ModelVariable{"u": {Type: "parameter"}},
					Equations: []Equation{{
						LHS: ExprNode{Op: "D", Args: []any{"_var"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []any{"u", "_var"}},
					}},
				},
			},
			Coupling: []CouplingEntry{OperatorComposeCoupling{
				Type:      "operator_compose",
				Systems:   [2]string{"A", "B"},
				Translate: translate,
			}},
		}
	}

	plain, err := Flatten(build(nil))
	if err != nil {
		t.Fatalf("Flatten without translate: %v", err)
	}
	redundant, err := Flatten(build(map[string]any{"A.x": "B._var"}))
	if err != nil {
		t.Fatalf("Flatten with the redundant translate entry: %v "+
			"(§10.2: writing it MUST be harmless)", err)
	}
	if len(plain.Equations) != 1 || len(redundant.Equations) != 1 {
		t.Fatalf("expected one merged equation either way, got %d and %d",
			len(plain.Equations), len(redundant.Equations))
	}
	if a, b := ToAscii(redundant.Equations[0].RHS), ToAscii(plain.Equations[0].RHS); a != b {
		t.Errorf("the redundant translate entry changed the result:\n  with:    %s\n  without: %s", a, b)
	}
}

// --- §10.3 / §4.7.2 `couple` multiplicative-without-tendency ----------------

// coupleTransformFile targets `to` with one connector equation of the given
// transform. `A.x` has a tendency; `A.c` is a bare PARAMETER with none.
func coupleTransformFile(to, transform string) *ESMFile {
	return &ESMFile{
		Models: map[string]Model{
			"A": {
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"c": {Type: "parameter"},
				},
				Equations: []Equation{{
					LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
					RHS: -1.0,
				}},
			},
			"B": {
				Variables: map[string]ModelVariable{"s": {Type: "unknown"}},
				Equations: []Equation{{
					LHS: ExprNode{Op: "D", Args: []any{"s"}, Wrt: strPtr("t")},
					RHS: 1.0,
				}},
			},
		},
		Coupling: []CouplingEntry{CouplingCouple{
			Type:    "couple",
			Systems: [2]string{"A", "B"},
			Connector: Connector{Equations: []ConnectorEquation{{
				From: "B.s", To: to, Transform: transform,
				Expression: ExprNode{Op: "*", Args: []any{2.0, "B.s"}},
			}}},
		}},
	}
}

// TestFlattenCouple_MultiplicativeWithoutTendencyIsAnError pins esm-spec §10.3
// and §4.7.2: `multiplicative` is defined against the target's EXISTING ODE RHS,
// so a `to` with no `D(to)` has nothing to multiply. The binding used to drop
// the connector equation silently, which is the one outcome a coupling
// mis-specification must not have.
func TestFlattenCouple_MultiplicativeWithoutTendencyIsAnError(t *testing.T) {
	_, err := Flatten(coupleTransformFile("A.c", "multiplicative"))
	if err == nil {
		t.Fatal("expected couple_multiplicative_no_tendency; the connector equation " +
			"was silently dropped instead")
	}
	var de *CoupleMultiplicativeNoTendencyError
	if !errors.As(err, &de) {
		t.Fatalf("error = %v (%T), want *CoupleMultiplicativeNoTendencyError", err, err)
	}
	if de.Target != "A.c" {
		t.Errorf("Target = %q, want %q (the error must NAME the target)", de.Target, "A.c")
	}
	if de.DiagnosticCode() != CodeCoupleMultiplicativeNoTendency {
		t.Errorf("DiagnosticCode = %q, want %q", de.DiagnosticCode(), CodeCoupleMultiplicativeNoTendency)
	}
	if !strings.Contains(err.Error(), CodeCoupleMultiplicativeNoTendency) {
		t.Errorf("Error() = %q; the shared \"[code] message\" form must carry the code", err)
	}
}

// TestFlattenCouple_AdditiveWithoutTendencyIsNotAnError pins the DELIBERATE
// asymmetry of §4.7.2: zero is the additive identity, so an additive term
// against an absent tendency is well defined and there is no counterpart error.
func TestFlattenCouple_AdditiveWithoutTendencyIsNotAnError(t *testing.T) {
	if _, err := Flatten(coupleTransformFile("A.c", "additive")); err != nil {
		t.Fatalf("additive onto a target with no tendency must NOT raise: %v", err)
	}
}

// TestFlattenCouple_MultiplicativeWithTendencyScalesIt is the positive control:
// with a real `D(to)` present the transform applies as before.
func TestFlattenCouple_MultiplicativeWithTendencyScalesIt(t *testing.T) {
	flat, err := Flatten(coupleTransformFile("A.x", "multiplicative"))
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}
	for _, eq := range flat.Equations {
		if ToAscii(eq.LHS) != "D(A.x)/Dt" {
			continue
		}
		if rhs := ToAscii(eq.RHS); !strings.Contains(rhs, "B.s") {
			t.Errorf("D(A.x) RHS = %q; the multiplicative term must be applied", rhs)
		}
		return
	}
	t.Fatal("no D(A.x) equation in the flattened system")
}

// TestFlattenCouple_MultiplicativeOntoAnObservedIsAnError pins the "an observed"
// arm of §10.3's list: a name with SOME defining equation but no TENDENCY still
// has nothing to multiply.
func TestFlattenCouple_MultiplicativeOntoAnObservedIsAnError(t *testing.T) {
	file := coupleTransformFile("A.obs", "multiplicative")
	m := file.Models["A"]
	m.Variables["obs"] = ModelVariable{Type: "unknown"}
	m.Equations = append(m.Equations, Equation{LHS: "obs", RHS: 3.0})
	file.Models["A"] = m

	_, err := Flatten(file)
	var de *CoupleMultiplicativeNoTendencyError
	if !errors.As(err, &de) {
		t.Fatalf("error = %v (%T), want *CoupleMultiplicativeNoTendencyError: an "+
			"observed carries a defining equation but no D(to) to multiply", err, err)
	}
}
