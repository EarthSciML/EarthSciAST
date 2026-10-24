package esm

// Per-term provenance through flatten (esm-libraries-spec §4.7.5,
// CONFORMANCE_SPEC §5.48, issue #539).
//
// The flatten corpus (flatten_conformance_test.go) pins every equation's
// rendered contribution list. These tests check what a rendering cannot:
//
//   - the INVARIANT, by evaluation: each equation's Body() evaluates bit for bit
//     to the LEFT-FOLD sum of its contributions' values at sampled non-default
//     states. Evaluate binds scalars only, so a pointwise-lifted equation (an
//     `faq` over a grid) is out of its reach and is skipped;
//   - the systems-order pair: the same contributions and origins in both
//     argument orders, in `rhs_A + rhs_B` order;
//   - non-vacuity: two structurally identical contributions stay two.

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func termProvenanceDir() string {
	// pkg/esm -> pkg -> earthsci-ast-go -> pkg -> repo root
	return filepath.Join("..", "..", "..", "..", "tests", "conformance", "term_provenance", "fixtures")
}

func flattenFixture(t *testing.T, path string) *FlattenedSystem {
	t.Helper()
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("flatten %s: %v", path, err)
	}
	return flat
}

func equationByLHS(t *testing.T, flat *FlattenedSystem, lhs string) FlattenedEquation {
	t.Helper()
	var found []FlattenedEquation
	for _, eq := range flat.Equations {
		if ToASCII(eq.LHS) == lhs {
			found = append(found, eq)
		}
	}
	if len(found) != 1 {
		t.Fatalf("expected one equation %q, got %d", lhs, len(found))
	}
	return found[0]
}

func originsJSON(c Contribution) string {
	b, _ := json.Marshal(c.Origins)
	return string(b)
}

// provenanceSamples is the number of independent sampled states per equation:
// one state can sum to the same bits in every association by chance; several
// make that vanishingly unlikely.
const provenanceSamples = 8

// provenanceSample is a deterministic, non-default value for name in sample
// salt, spread over many decades so that summing in another association rounds
// differently.
func provenanceSample(name string, salt int) float64 {
	h := fnv.New32a()
	fmt.Fprintf(h, "%d:%s", salt, name)
	v := h.Sum32()
	return (1 + float64(v%100003)/100003) * math.Pow(10, float64(int((v>>17)%13)-6))
}

// checkProvenanceInvariant asserts the invariant for one equation. evaluated is
// false when Evaluate cannot run the equation; discriminating is true when some
// sampled state sums the contributions to different bits right-nested, i.e. the
// check could tell the two orders apart.
func checkProvenanceInvariant(t *testing.T, eq FlattenedEquation) (evaluated, discriminating bool) {
	t.Helper()
	if eq.Lifted {
		return false, false
	}
	names := map[string]bool{}
	for _, c := range eq.Contributions {
		for n := range FreeVariables(c.Expr) {
			names[n] = true
		}
	}
	for salt := 0; salt < provenanceSamples; salt++ {
		bindings := map[string]float64{"t": 0.75}
		for n := range names {
			if n != "t" {
				bindings[n] = provenanceSample(n, salt)
			}
		}
		body, err := Evaluate(eq.Body(), bindings)
		if err != nil {
			return false, false
		}
		parts := make([]float64, len(eq.Contributions))
		for i, c := range eq.Contributions {
			if parts[i], err = Evaluate(c.Expr, bindings); err != nil {
				return false, false
			}
		}
		fold := parts[0]
		for _, p := range parts[1:] {
			fold += p
		}
		if math.Float64bits(body) != math.Float64bits(fold) {
			t.Errorf("%s: body %v != left fold %v of %v", ToASCII(eq.LHS), body, fold, parts)
		}
		right := parts[len(parts)-1]
		for i := len(parts) - 2; i >= 0; i-- {
			right = parts[i] + right
		}
		discriminating = discriminating || math.Float64bits(right) != math.Float64bits(fold)
	}
	return true, discriminating
}

// scalarUnreachable are the fixtures with no equation Evaluate can run: `grad`
// with no discretization, and the lifted `faq` over a grid.
var scalarUnreachable = map[string]bool{
	"placeholder_expansion.esm": true,
	"pointwise_lift.esm":        true,
}

func TestTermProvenanceInvariant(t *testing.T) {
	entries, err := os.ReadDir(termProvenanceDir())
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".esm") {
			fixtures = append(fixtures, e.Name())
		}
	}
	sort.Strings(fixtures)
	if len(fixtures) == 0 {
		t.Fatal("no term_provenance fixtures")
	}
	for _, name := range fixtures {
		t.Run(name, func(t *testing.T) {
			flat := flattenFixture(t, filepath.Join(termProvenanceDir(), name))
			evaluated := 0
			for _, eq := range flat.Equations {
				ok, discriminating := checkProvenanceInvariant(t, eq)
				if !ok {
					continue
				}
				evaluated++
				// With three or more contributions the check must be able to see
				// the order.
				if len(eq.Contributions) >= 3 && !discriminating {
					t.Errorf("%s cannot tell sum orders apart", ToASCII(eq.LHS))
				}
			}
			if evaluated == 0 && !scalarUnreachable[name] {
				t.Errorf("no equation of %s could be evaluated", name)
			}
		})
	}
}

// TestTermProvenanceCorpus runs the invariant over every corpus case, where
// Evaluate reaches, and checks every contribution has a non-empty, deduplicated
// origin list.
func TestTermProvenanceCorpus(t *testing.T) {
	corpus := loadFlattenCorpus(t)
	root := flattenCorpusRoot(t)
	for _, c := range corpus.Cases {
		t.Run(c.ID, func(t *testing.T) {
			flat := flattenFixture(t, filepath.Join(root, "tests", filepath.FromSlash(c.Fixture)))
			for _, eq := range flat.Equations {
				checkProvenanceInvariant(t, eq)
				if len(eq.Contributions) == 0 {
					t.Errorf("%s records no contributions", ToASCII(eq.LHS))
				}
				for _, contribution := range eq.Contributions {
					if len(contribution.Origins) == 0 {
						t.Errorf("%s has an unattributed term", ToASCII(eq.LHS))
					}
					for _, o := range contribution.Origins {
						if (o.Component == "") == (o.Coupling == nil) {
							t.Errorf("%s: malformed origin %+v", ToASCII(eq.LHS), o)
						}
					}
					if len(unionOrigins([]Contribution{contribution})) != len(contribution.Origins) {
						t.Errorf("%s: repeated origin in %s", ToASCII(eq.LHS), originsJSON(contribution))
					}
				}
			}
		})
	}
}

func TestTermProvenanceSystemsOrder(t *testing.T) {
	pairs := func(eq FlattenedEquation) []string {
		out := make([]string, len(eq.Contributions))
		for i, c := range eq.Contributions {
			out[i] = ToASCII(c.Expr) + " " + originsJSON(c)
		}
		return out
	}
	ab := equationByLHS(t, flattenFixture(t, filepath.Join(termProvenanceDir(), "systems_order_ab.esm")), "D(Chem.O3)/Dt")
	ba := equationByLHS(t, flattenFixture(t, filepath.Join(termProvenanceDir(), "systems_order_ba.esm")), "D(Chem.O3)/Dt")
	abPairs, baPairs := pairs(ab), pairs(ba)
	sortedAB := append([]string(nil), abPairs...)
	sortedBA := append([]string(nil), baPairs...)
	sort.Strings(sortedAB)
	sort.Strings(sortedBA)
	if strings.Join(sortedAB, "|") != strings.Join(sortedBA, "|") {
		t.Errorf("the two orders differ in contributions:\n  ab %v\n  ba %v", abPairs, baPairs)
	}
	origins := func(eq FlattenedEquation) string {
		var out []string
		for _, c := range eq.Contributions {
			out = append(out, originsJSON(c))
		}
		return strings.Join(out, ",")
	}
	if got := origins(ab); got != `[{"component":"Chem"}],[{"component":"Sink"}]` {
		t.Errorf("ab origins = %s", got)
	}
	if got := origins(ba); got != `[{"component":"Sink"}],[{"component":"Chem"}]` {
		t.Errorf("ba origins = %s", got)
	}
}

func TestTermProvenanceNonVacuity(t *testing.T) {
	eq := equationByLHS(t, flattenFixture(t, filepath.Join(termProvenanceDir(), "non_vacuity.esm")), "D(Chem.O3)/Dt")
	tail := eq.Contributions[1:]
	if len(tail) != 2 || ToASCII(tail[0].Expr) != "Emis.flux" || ToASCII(tail[1].Expr) != "Emis.flux" {
		t.Fatalf("want two Emis.flux contributions after the first, got %+v", tail)
	}
	if originsJSON(tail[0]) != `[{"component":"OpA"}]` || originsJSON(tail[1]) != `[{"component":"OpB"}]` {
		t.Errorf("origins = %s, %s", originsJSON(tail[0]), originsJSON(tail[1]))
	}
}

func TestTermProvenanceLift(t *testing.T) {
	flat := flattenFixture(t, filepath.Join(termProvenanceDir(), "pointwise_lift.esm"))
	var lifted []FlattenedEquation
	for _, eq := range flat.Equations {
		if eq.Lifted {
			lifted = append(lifted, eq)
		}
	}
	if len(lifted) != 1 {
		t.Fatalf("want one lifted equation, got %d", len(lifted))
	}
	node, ok := asExprNode(lifted[0].RHS)
	if !ok || node.Op != "faq" {
		t.Fatalf("lifted rhs is not an faq: %s", ToASCII(lifted[0].RHS))
	}
	var got []string
	for _, c := range lifted[0].Contributions {
		got = append(got, originsJSON(c))
	}
	want := `[{"component":"Chem"}] [{"component":"Src"}] [{"component":"Adv"}]`
	if strings.Join(got, " ") != want {
		t.Errorf("origins = %v, want %s", got, want)
	}
}
