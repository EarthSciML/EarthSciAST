package esm

// Drives tests/conformance/function_tables/load_errors/cases.json: the
// esm-spec §9.5.5 table checks and their pinned order, for the cases JSON
// cannot express as a document. Each case is one table (id `T`) and one
// `table_lookup` into it; the table is built IN MEMORY (the strings "NaN",
// "Inf" and "-Inf" anywhere in it are those binary64 values, which JSON cannot
// carry). The table and the lookup, placed in a document, go through the SAME
// load-time checks load and validate() run (checkFunctionsAtLoad: the table's
// ten checks, then the lookup's own), and the lookup through the production
// §9.5.3 lowering; both must raise
// `expected_error_code` (null: the table passes and the lookup lowers). Go's
// FunctionTable holds axis values as []float64 and `data` as `any`, so every
// case is representable and none is skipped.

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

type tableLoadErrorLedger struct {
	TableID string               `json:"table_id"`
	Order   []string             `json:"order"`
	Cases   []tableLoadErrorCase `json:"cases"`
	// MovedToTestsInvalid maps a former case to the tests/invalid fixture that
	// now carries it; its pinned code counts toward the order's coverage.
	MovedToTestsInvalid map[string]string `json:"moved_to_tests_invalid"`
}

type tableLoadErrorCase struct {
	Name              string          `json:"name"`
	Table             tableCaseTable  `json:"table"`
	Lookup            tableCaseLookup `json:"lookup"`
	ExpectedErrorCode *string         `json:"expected_error_code"`
}

type tableCaseTable struct {
	Axes []struct {
		Name   string `json:"name"`
		Values []any  `json:"values"`
	} `json:"axes"`
	Interpolation *string  `json:"interpolation"`
	OutOfBounds   *string  `json:"out_of_bounds"`
	Outputs       []string `json:"outputs"`
	Data          any      `json:"data"`
	Shape         []int    `json:"shape"`
}

type tableCaseLookup struct {
	Op     string         `json:"op"`
	Table  string         `json:"table"`
	Axes   map[string]any `json:"axes"`
	Output any            `json:"output"`
	Args   []any          `json:"args"`
}

// nanFromLedger rewrites every "NaN", "Inf" and "-Inf" string in a decoded
// JSON value to that binary64 value.
func nanFromLedger(v any) any {
	switch x := v.(type) {
	case string:
		switch x {
		case "NaN":
			return math.NaN()
		case "Inf":
			return math.Inf(1)
		case "-Inf":
			return math.Inf(-1)
		}
		return x
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = nanFromLedger(e)
		}
		return out
	}
	return v
}

func (c tableCaseTable) build(t *testing.T) FunctionTable {
	t.Helper()
	ft := FunctionTable{
		Interpolation: c.Interpolation,
		OutOfBounds:   c.OutOfBounds,
		Outputs:       c.Outputs,
		Data:          nanFromLedger(c.Data),
		Shape:         c.Shape,
	}
	for _, a := range c.Axes {
		values := make([]float64, len(a.Values))
		for i, raw := range a.Values {
			f, ok := toFloat64(nanFromLedger(raw))
			if !ok {
				t.Fatalf("axis %q value %v is not a number", a.Name, raw)
			}
			values[i] = f
		}
		ft.Axes = append(ft.Axes, FunctionTableAxis{Name: a.Name, Values: values})
	}
	return ft
}

func tableLoadErrorsLedgerPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	// pkg/esm/<file> -> repo root is 4 levels up.
	return filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..",
		"tests", "conformance", "function_tables", "load_errors", "cases.json")
}

func TestFunctionTableLoadErrorsLedger(t *testing.T) {
	raw, err := os.ReadFile(tableLoadErrorsLedgerPath(t))
	if err != nil {
		t.Fatalf("read ledger: %v", err)
	}
	var ledger tableLoadErrorLedger
	if err := json.Unmarshal(raw, &ledger); err != nil {
		t.Fatalf("parse ledger: %v", err)
	}
	if len(ledger.Cases) == 0 || len(ledger.Order) == 0 {
		t.Fatal("the load_errors ledger has no cases or no order")
	}
	// Every rule of the order must be the expected code of some case (or of a
	// case moved to a tests/invalid fixture, which TestClosedFnAndTableInvalidFixtures
	// loads), and a valid control must be present, so a ledger that lost a case
	// fails here.
	covered := map[string]bool{}
	pins := resolverOnlyPins(t, dsuRepoRoot(t))
	for from, fixture := range ledger.MovedToTestsInvalid {
		code, ok := pins[fixture]
		if !ok || code == "" {
			t.Errorf("case %q moved to %s, which is not pinned resolver_only with a code", from, fixture)
			continue
		}
		covered[code] = true
	}
	sawControl := false
	for _, c := range ledger.Cases {
		if c.ExpectedErrorCode == nil {
			sawControl = true
		} else {
			covered[*c.ExpectedErrorCode] = true
		}
	}
	if !sawControl {
		t.Error("the ledger has no case that lowers (expected_error_code null)")
	}
	for _, rule := range ledger.Order {
		code := strings.Fields(rule)[0]
		if !covered[code] {
			t.Errorf("no case expects %q", code)
		}
	}

	ran := 0
	for _, c := range ledger.Cases {
		c := c
		t.Run(c.Name, func(t *testing.T) {
			tables := map[string]FunctionTable{ledger.TableID: c.Table.build(t)}
			id := c.Lookup.Table
			axes := make(map[string]Expression, len(c.Lookup.Axes))
			for k, v := range c.Lookup.Axes {
				axes[k] = v
			}
			args := c.Lookup.Args
			if args == nil {
				args = []any{}
			}
			node := ExprNode{Op: c.Lookup.Op, Table: &id, TableAxes: axes,
				Output: c.Lookup.Output, Args: args}
			// The lookup sits in a document beside its table, so the load-time
			// gate runs the table's ten checks and then the lookup's own
			// (rulings Q-107, Q-112), through the same walk load uses.
			doc := &ESMFile{FunctionTables: tables, Models: map[string]Model{
				"M": {Equations: []Equation{{LHS: "y", RHS: node}}},
			}}
			loadErr := checkFunctionsAtLoad(doc)
			_, lowerErr := lowerExprTableLookups(node, tables)
			for _, step := range []struct {
				name string
				err  error
			}{{"load-time table check", loadErr}, {"lowering", lowerErr}} {
				err := step.err
				if c.ExpectedErrorCode == nil {
					if err != nil {
						t.Fatalf("%s: expected no error, got %v", step.name, err)
					}
					continue
				}
				var de DiagnosticError
				if !errors.As(err, &de) {
					t.Fatalf("%s: expected code %q, got %T: %v", step.name, *c.ExpectedErrorCode, err, err)
				}
				if de.DiagnosticCode() != *c.ExpectedErrorCode {
					t.Fatalf("%s: code = %q, want %q (%v)", step.name, de.DiagnosticCode(),
						*c.ExpectedErrorCode, err)
				}
			}
		})
		ran++
	}
	if ran != len(ledger.Cases) {
		t.Fatalf("ran %d of %d cases", ran, len(ledger.Cases))
	}
}
