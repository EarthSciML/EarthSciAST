package esm

// Drives tests/conformance/function_tables/load_errors/cases.json: the
// esm-spec §9.5.5 table checks and their pinned order. Each case is one table
// (id `T`) and one `table_lookup` into it; the table is built IN MEMORY (the
// string "NaN" anywhere in it is a binary64 NaN, which JSON cannot carry), the
// lookup goes through the production §9.5.3 lowering, and the diagnostic code
// it raises is compared with `expected_error_code` (null: the lookup lowers).
// Go's FunctionTable holds axis values as []float64 and `data` as `any`, so
// every case is representable and none is skipped.

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

// nanFromLedger rewrites every "NaN" string in a decoded JSON value to NaN.
func nanFromLedger(v any) any {
	switch x := v.(type) {
	case string:
		if x == "NaN" {
			return math.NaN()
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
	// Every rule of the order must be the expected code of some case, and a
	// valid control must be present, so a ledger that lost a case fails here.
	covered := map[string]bool{}
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
			_, err := lowerExprTableLookups(node, tables)
			if c.ExpectedErrorCode == nil {
				if err != nil {
					t.Fatalf("expected the lookup to lower, got %v", err)
				}
				return
			}
			var de DiagnosticError
			if !errors.As(err, &de) {
				t.Fatalf("expected code %q, got %T: %v", *c.ExpectedErrorCode, err, err)
			}
			if de.DiagnosticCode() != *c.ExpectedErrorCode {
				t.Fatalf("code = %q, want %q (%v)", de.DiagnosticCode(), *c.ExpectedErrorCode, err)
			}
		})
		ran++
	}
	if ran != len(ledger.Cases) {
		t.Fatalf("ran %d of %d cases", ran, len(ledger.Cases))
	}
}
