package esm

// Cross-language pin for the EXACT TREE a reaction system lowers to.
//
// Drives the shared, hand-written corpus at
// tests/conformance/reactions/lowering_form.json: every binding's derive_odes
// and flatten must produce the same expressions for a reaction network,
// compared as JSON with integer and non-integer numbers kept apart
// (esm-libraries-spec §4.6.2). Derived documents copy flattened terms
// verbatim, so a binding that lowers a reaction to a different tree writes
// different bytes.
//
// The comparison runs on encoding/json's form of the tree, which is what a
// derived document carries. That form writes an integral float64 as an
// integer token, so it cannot show a stray float by itself; integralFloats
// checks the tree before it is written.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type loweringFormCorpus struct {
	Cases []struct {
		Name       string `json:"name"`
		System     string `json:"system"`
		Lifted     bool   `json:"lifted"`
		DeriveODEs []struct {
			LHS json.RawMessage `json:"lhs"`
			RHS json.RawMessage `json:"rhs"`
		} `json:"derive_odes"`
		Flatten []struct {
			Species      string          `json:"species"`
			Contribution json.RawMessage `json:"contribution"`
		} `json:"flatten"`
		Document json.RawMessage `json:"document"`
	} `json:"cases"`
}

func loadLoweringFormCorpus(t *testing.T) *loweringFormCorpus {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "conformance", "reactions", "lowering_form.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var corpus loweringFormCorpus
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return &corpus
}

// decodeKinded decodes JSON keeping every number as its token, so integers and
// non-integers stay apart.
func decodeKinded(t *testing.T, raw []byte) any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
	return v
}

func writtenKinded(t *testing.T, expr any) any {
	t.Helper()
	raw, err := json.Marshal(expr)
	if err != nil {
		t.Fatalf("marshal %v: %v", expr, err)
	}
	return decodeKinded(t, raw)
}

func isIntegerToken(n json.Number) bool {
	return !strings.ContainsAny(string(n), ".eE")
}

// sameKinded is JSON equality that keeps integers and non-integers apart.
func sameKinded(actual, expected any, path string) error {
	switch e := expected.(type) {
	case json.Number:
		a, ok := actual.(json.Number)
		if !ok {
			return fmt.Errorf("%s: %v is not a number", path, actual)
		}
		if isIntegerToken(a) != isIntegerToken(e) {
			return fmt.Errorf("%s: %s and %s differ in kind (integer vs non-integer)", path, a, e)
		}
		af, _ := a.Float64()
		ef, _ := e.Float64()
		if af != ef {
			return fmt.Errorf("%s: %s != %s", path, a, e)
		}
	case map[string]any:
		a, ok := actual.(map[string]any)
		if !ok || len(a) != len(e) {
			return fmt.Errorf("%s: %v != %v", path, actual, expected)
		}
		for k, ev := range e {
			av, present := a[k]
			if !present {
				return fmt.Errorf("%s: missing key %q", path, k)
			}
			if err := sameKinded(av, ev, path+"."+k); err != nil {
				return err
			}
		}
	case []any:
		a, ok := actual.([]any)
		if !ok || len(a) != len(e) {
			return fmt.Errorf("%s: %v != %v", path, actual, expected)
		}
		for i := range e {
			if err := sameKinded(a[i], e[i], fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	default:
		if actual != expected {
			return fmt.Errorf("%s: %v != %v", path, actual, expected)
		}
	}
	return nil
}

// integralFloats lists every integral float64 literal in expr — CONFORMANCE_SPEC
// §5.5.3.1 rule 3 makes each of them an integer literal.
func integralFloats(expr any) []float64 {
	switch v := expr.(type) {
	case float64:
		if !math.IsInf(v, 0) && !math.IsNaN(v) && v == math.Trunc(v) {
			return []float64{v}
		}
	case ExprNode:
		var out []float64
		for _, a := range v.Args {
			out = append(out, integralFloats(a)...)
		}
		return out
	case *ExprNode:
		return integralFloats(*v)
	}
	return nil
}

func checkLowered(t *testing.T, actual any, expected json.RawMessage, where string) {
	t.Helper()
	if floats := integralFloats(actual); len(floats) > 0 {
		t.Errorf("%s: integral float literal(s) %v in %v", where, floats, actual)
	}
	if err := sameKinded(writtenKinded(t, actual), decodeKinded(t, expected), where); err != nil {
		t.Error(err)
	}
}

// loweredSpecies is the species a flattened left-hand side differentiates:
// D(x, t), or the lift's faq over D(index(x, ...), t).
func loweredSpecies(t *testing.T, lhs any) string {
	t.Helper()
	m, _ := writtenKinded(t, lhs).(map[string]any)
	if m["op"] == "faq" {
		m, _ = m["expr"].(map[string]any)
	}
	if m["op"] != "D" {
		t.Fatalf("left-hand side %v is not a derivative", lhs)
	}
	args, _ := m["args"].([]any)
	if inner, ok := args[0].(map[string]any); ok {
		args, _ = inner["args"].([]any)
	}
	name, _ := args[0].(string)
	return name
}

func TestReactionLoweringFormCorpus(t *testing.T) {
	corpus := loadLoweringFormCorpus(t)
	if len(corpus.Cases) < 3 {
		t.Fatalf("expected at least 3 corpus cases, got %d", len(corpus.Cases))
	}
	for _, tc := range corpus.Cases {
		t.Run(tc.Name, func(t *testing.T) {
			file, err := LoadString(string(tc.Document))
			if err != nil {
				t.Fatalf("load document: %v", err)
			}

			system := file.ReactionSystems[tc.System]
			model, err := DeriveODEs(&system)
			if err != nil {
				t.Fatalf("DeriveODEs: %v", err)
			}
			if len(model.Equations) != len(tc.DeriveODEs) {
				t.Fatalf("DeriveODEs: %d equations, want %d", len(model.Equations), len(tc.DeriveODEs))
			}
			for k, eq := range model.Equations {
				checkLowered(t, eq.LHS, tc.DeriveODEs[k].LHS, fmt.Sprintf("derive_odes[%d].lhs", k))
				checkLowered(t, eq.RHS, tc.DeriveODEs[k].RHS, fmt.Sprintf("derive_odes[%d].rhs", k))
			}

			flat, err := Flatten(file)
			if err != nil {
				t.Fatalf("Flatten: %v", err)
			}
			type pick struct {
				eq           FlattenedEquation
				contribution Contribution
			}
			var selected []pick
			for _, eq := range flat.Equations {
				var mine []Contribution
				for _, c := range eq.Contributions {
					if len(c.Origins) == 1 && c.Origins[0].Component == tc.System && c.Origins[0].Coupling == nil {
						mine = append(mine, c)
					}
				}
				if len(mine) == 0 {
					continue
				}
				if len(mine) != 1 {
					t.Fatalf("%d contributions from %s in one equation", len(mine), tc.System)
				}
				selected = append(selected, pick{eq, mine[0]})
			}
			if len(selected) != len(tc.Flatten) {
				t.Fatalf("Flatten: %d equations from %s, want %d", len(selected), tc.System, len(tc.Flatten))
			}
			for k, p := range selected {
				exp := tc.Flatten[k]
				if got := loweredSpecies(t, p.eq.LHS); got != exp.Species {
					t.Errorf("flatten[%d]: species %q, want %q", k, got, exp.Species)
				}
				checkLowered(t, p.contribution.Expr, exp.Contribution, fmt.Sprintf("flatten[%d].contribution", k))
				if !tc.Lifted {
					if len(p.eq.Contributions) != 1 {
						t.Errorf("flatten[%d]: %d contributions, want 1", k, len(p.eq.Contributions))
					}
					checkLowered(t, p.eq.RHS, exp.Contribution, fmt.Sprintf("flatten[%d].rhs", k))
					wantLHS, _ := json.Marshal(map[string]any{"op": "D", "args": []string{exp.Species}, "wrt": "t"})
					checkLowered(t, p.eq.LHS, wantLHS, fmt.Sprintf("flatten[%d].lhs", k))
				}
			}
		})
	}
}
