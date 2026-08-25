package esm

import (
	"reflect"
	"strings"
	"testing"
)

// reactionsFixture is a network exercising every case the two functions have to
// answer for: a two-substrate reaction, a reaction reversing it, a reservoir
// species (`constant: true`) that must NOT get an ODE, and a fractional
// product coefficient.
const reactionsFixture = `{
  "esm":"1.0.0",
  "metadata":{"name":"rx"},
  "reaction_systems":{"R":{
    "species":{
      "NO":{"units":"ppb","default":1.0},
      "NO2":{"units":"ppb","default":0.0},
      "O3":{"units":"ppb","default":30.0},
      "M":{"units":"molec cm-3","default":2.5e19,"constant":true}
    },
    "parameters":{"k1":{"default":1.8e-12},"jNO2":{"default":0.01}},
    "reactions":[
      {"id":"r1","substrates":[{"species":"NO","stoichiometry":1},{"species":"O3","stoichiometry":1}],
       "products":[{"species":"NO2","stoichiometry":1}],"rate":"k1"},
      {"id":"r2","substrates":[{"species":"NO2","stoichiometry":1}],
       "products":[{"species":"NO","stoichiometry":1},{"species":"O3","stoichiometry":0.5}],"rate":"jNO2"}
    ]}}}`

func reactionsFixtureSystem(t *testing.T) *ReactionSystem {
	t.Helper()
	file, err := LoadString(reactionsFixture)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	rs := file.ReactionSystems["R"]
	return &rs
}

// TestStoichiometricMatrix pins the shape and the sign convention: rows are
// species in DECLARATION order (API_SPEC.md §5.10), columns are reactions in
// declaration order, and an entry is products − substrates.
//
// The fixture declares NO, NO2, O3, M — deliberately not its own sorted order
// (M, NO, NO2, O3), so this assertion distinguishes the two. It used to expect
// the sorted order.
func TestStoichiometricMatrix(t *testing.T) {
	rs := reactionsFixtureSystem(t)
	got := StoichiometricMatrix(rs)

	want := [][]float64{
		{-1, +1},   // NO  — consumed by r1, produced by r2
		{+1, -1},   // NO2 — produced by r1, consumed by r2
		{-1, +0.5}, // O3  — consumed by r1, produced fractionally by r2
		{0, 0},     // M   — a reservoir takes part in no reaction here
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("stoichiometric matrix =\n%v\nwant\n%v", got, want)
	}

	// Dimensions are (species × reactions), not the transpose — the single
	// easiest thing to get backwards, and unobservable on a square network.
	if len(got) != len(rs.Species) {
		t.Errorf("row count = %d, want one per species (%d)", len(got), len(rs.Species))
	}
	for i, row := range got {
		if len(row) != len(rs.Reactions) {
			t.Errorf("row %d has %d columns, want one per reaction (%d)", i, len(row), len(rs.Reactions))
		}
	}
}

// TestStoichiometricMatrixSumsRepeatedSpecies confirms a species listed twice
// on one side accumulates rather than overwriting. `duplicate_reaction_species`
// is a WARNING, so the matrix must still have an answer.
func TestStoichiometricMatrixSumsRepeatedSpecies(t *testing.T) {
	rs := &ReactionSystem{
		Species: map[string]Species{"A": {}, "B": {}},
		Reactions: []Reaction{{
			ID:         "r",
			Substrates: []SubstrateProduct{{Species: "A", Stoichiometry: 1}, {Species: "A", Stoichiometry: 2}},
			Products:   []SubstrateProduct{{Species: "B", Stoichiometry: 1}},
			Rate:       1.0,
		}},
	}
	got := StoichiometricMatrix(rs)
	if got[0][0] != -3 {
		t.Errorf("A coefficient = %v, want -3 (1 + 2 summed)", got[0][0])
	}
}

// TestDeriveODEs pins the variable classification and the equation set.
func TestDeriveODEs(t *testing.T) {
	rs := reactionsFixtureSystem(t)
	model, err := DeriveODEs(rs)
	if err != nil {
		t.Fatalf("DeriveODEs: %v", err)
	}

	// Species are unknowns; a RESERVOIR species is a parameter holding its
	// declared default, because it is held fixed and gets no ODE (§7.4).
	wantTypes := map[string]string{
		"NO": VarTypeUnknown, "NO2": VarTypeUnknown, "O3": VarTypeUnknown,
		"M": VarTypeParameter, "k1": VarTypeParameter, "jNO2": VarTypeParameter,
	}
	for name, want := range wantTypes {
		v, ok := model.Variables[name]
		if !ok {
			t.Errorf("derived model is missing variable %q", name)
			continue
		}
		if v.Type != want {
			t.Errorf("%s: type = %q, want %q", name, v.Type, want)
		}
	}
	if len(model.Variables) != len(wantTypes) {
		t.Errorf("variables = %v, want exactly %d", sortedKeys(model.Variables), len(wantTypes))
	}

	// One ODE per non-reservoir species with a non-zero net rate; the reservoir
	// gets none.
	var lhs []string
	for _, eq := range model.Equations {
		lhs = append(lhs, ToASCII(eq.LHS))
	}
	wantLHS := []string{"D(NO)/Dt", "D(NO2)/Dt", "D(O3)/Dt"}
	if !reflect.DeepEqual(lhs, wantLHS) {
		t.Errorf("equation LHSs = %v, want %v", lhs, wantLHS)
	}

	// The rate law is the coefficient TIMES the substrate product (§7.4): `rate`
	// is the rate COEFFICIENT, not the whole law.
	no2 := ToASCII(model.Equations[1].RHS)
	if !strings.Contains(no2, "k1") || !strings.Contains(no2, "NO") || !strings.Contains(no2, "O3") {
		t.Errorf("d[NO2]/dt = %q, want the mass-action law k1·[NO]·[O3] less the r2 loss", no2)
	}

	// The derived unknowns must be exactly the ODE states the §6.3.1
	// classification recovers from those equations — the two views of the same
	// fact have to agree.
	if got := ODEStates(model); !reflect.DeepEqual(got, []string{"NO", "NO2", "O3"}) {
		t.Errorf("ODEStates(derived) = %v, want [NO NO2 O3]", got)
	}
}

// TestDeriveODEsAgreesWithFlatten is the reason DeriveODEs delegates to the
// flatten path's lowering helper rather than reimplementing mass action: the
// ODEs a caller gets from a reaction system directly must be the ones the whole
// document flattens to.
func TestDeriveODEsAgreesWithFlatten(t *testing.T) {
	file, err := LoadString(reactionsFixture)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	rs := file.ReactionSystems["R"]
	model, err := DeriveODEs(&rs)
	if err != nil {
		t.Fatalf("DeriveODEs: %v", err)
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten: %v", err)
	}

	direct := make(map[string]string, len(model.Equations))
	for _, eq := range model.Equations {
		direct[ToASCII(eq.LHS)] = ToASCII(eq.RHS)
	}
	seen := 0
	for _, eq := range flat.Equations {
		key := strings.ReplaceAll(ToASCII(eq.LHS), "R.", "")
		want, ok := direct[key]
		if !ok {
			continue
		}
		seen++
		if got := strings.ReplaceAll(ToASCII(eq.RHS), "R.", ""); got != want {
			t.Errorf("%s: flatten gives %q, DeriveODEs gives %q", key, got, want)
		}
	}
	if seen != len(direct) {
		t.Errorf("matched %d of %d derived equations against the flattened system", seen, len(direct))
	}
}
