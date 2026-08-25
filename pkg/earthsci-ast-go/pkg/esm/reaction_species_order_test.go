package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// reaction_species_order_test.go drives the CROSS-LANGUAGE SPECIES-ORDER corpus
// (tests/conformance/reactions/species_order.json).
//
// It pins the one thing five bindings had silently disagreed about: the ORDER
// species appear in, in the results of DeriveODEs and StoichiometricMatrix.
// Canonical is DECLARATION order (API_SPEC.md §5.10) — the order the document
// writes the `species` object's keys in. Go sorted in both operations until
// phase 6b; Rust sorted in StoichiometricMatrix only.
//
// The order is observable, which is what makes it a contract rather than an
// implementation detail: it is the ROW order of the stoichiometric matrix and
// the EQUATION order of the derived model.
//
// Unlike the graph corpus, order here IS the conformance property, so nothing
// below is compared as a multiset.

type speciesOrderCorpus struct {
	Cases []struct {
		Name                      string          `json:"name"`
		Description               string          `json:"description"`
		System                    string          `json:"system"`
		DeclarationOrder          []string        `json:"species_declaration_order"`
		SortedOrder               []string        `json:"species_sorted_order"`
		DeriveODEsEquationSpecies []string        `json:"derive_odes_equation_species"`
		StoichiometricMatrix      [][]float64     `json:"stoichiometric_matrix"`
		Document                  json.RawMessage `json:"document"`
	} `json:"cases"`
}

func loadSpeciesOrderCorpus(t *testing.T) *speciesOrderCorpus {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "conformance", "reactions", "species_order.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var corpus speciesOrderCorpus
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return &corpus
}

// lhsDerivativeTarget returns the species an `D(<species>, t)` LHS names — the
// first argument of the derivative node. Reading the equation list this way is
// deliberate: ODEStates sorts its result by design (esm-spec §6.3.1), so an
// assertion built on it would pass vacuously in every binding.
func lhsDerivativeTarget(t *testing.T, lhs any) string {
	t.Helper()
	node, ok := lhs.(ExprNode)
	if !ok {
		t.Fatalf("equation LHS is %T, want an ExprNode derivative node", lhs)
	}
	if node.Op != "D" {
		t.Fatalf("equation LHS op = %q, want the time-derivative op \"D\"", node.Op)
	}
	if len(node.Args) == 0 {
		t.Fatalf("equation LHS %v carries no args", node)
	}
	name, ok := node.Args[0].(string)
	if !ok {
		t.Fatalf("equation LHS first arg is %T, want a species name", node.Args[0])
	}
	return name
}

func TestReactionSpeciesOrderCorpus(t *testing.T) {
	corpus := loadSpeciesOrderCorpus(t)
	// Anti-vacuity: a corpus that failed to parse into zero cases must not pass.
	if len(corpus.Cases) < 2 {
		t.Fatalf("corpus has %d cases, want at least 2", len(corpus.Cases))
	}

	for _, c := range corpus.Cases {
		t.Run(c.Name, func(t *testing.T) {
			// Anti-vacuity: the case only discriminates while the declared order
			// differs from the sorted order it must not be confused with.
			if reflect.DeepEqual(c.DeclarationOrder, c.SortedOrder) {
				t.Fatalf("case %q declares species in their sorted order, so it cannot detect a sort", c.Name)
			}

			file, err := LoadString(string(c.Document))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			rs, ok := file.ReactionSystems[c.System]
			if !ok {
				t.Fatalf("document has no reaction system %q", c.System)
			}

			if got := StoichiometricMatrix(&rs); !reflect.DeepEqual(got, c.StoichiometricMatrix) {
				t.Errorf("StoichiometricMatrix rows =\n%v\nwant (species in declaration order %v)\n%v",
					got, c.DeclarationOrder, c.StoichiometricMatrix)
			}

			model, err := DeriveODEs(&rs)
			if err != nil {
				t.Fatalf("DeriveODEs: %v", err)
			}
			var species []string
			for _, eq := range model.Equations {
				species = append(species, lhsDerivativeTarget(t, eq.LHS))
			}
			if !reflect.DeepEqual(species, c.DeriveODEsEquationSpecies) {
				t.Errorf("DeriveODEs equation species = %v, want %v", species, c.DeriveODEsEquationSpecies)
			}
		})
	}
}
