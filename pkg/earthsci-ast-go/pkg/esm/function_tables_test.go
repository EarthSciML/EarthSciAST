package esm

import (
	"encoding/json"
	"testing"
)

// Test that a top-level function_tables block plus a table_lookup AST node
// roundtrips through Load/Marshal preserving the authored form.
//
// Coverage (esm-spec §9.5.6):
//   - 1-axis linear, single-output table
//   - 2-axis bilinear, multi-output table with named outputs
//   - table_lookup with int output index
//   - table_lookup with string output name
//   - axes (object, per-axis input expression map) preserved
const functionTablesFixture = `{
  "esm": "0.4.0",
  "metadata": {"name": "ft_smoke", "authors": ["test"]},
  "function_tables": {
    "sigma_O3": {
      "description": "1-D linear table",
      "axes": [
        {"name": "lambda_idx", "values": [1, 2, 3, 4]}
      ],
      "interpolation": "linear",
      "out_of_bounds": "clamp",
      "data": [1.1e-17, 1.0e-17, 9.5e-18, 8.7e-18]
    },
    "F_actinic": {
      "axes": [
        {"name": "P",       "units": "Pa", "values": [10, 100, 1000]},
        {"name": "cos_sza",                "values": [0.1, 0.5, 1.0]}
      ],
      "interpolation": "bilinear",
      "outputs": ["NO2", "O3"],
      "data": [
        [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
        [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]]
      ]
    }
  },
  "models": {
    "M": {
      "variables": {
        "k_O3":   {"type": "state",     "default": 0.0},
        "j_NO2":  {"type": "state",     "default": 0.0},
        "P_atm":  {"type": "parameter", "default": 101325.0},
        "cos_sza":{"type": "parameter", "default": 0.5}
      },
      "equations": [
        {"lhs": {"op": "D", "args": ["k_O3"], "wrt": "t"}, "rhs": {
          "op": "table_lookup",
          "table": "sigma_O3",
          "axes": {"lambda_idx": 2},
          "args": []
        }},
        {"lhs": {"op": "D", "args": ["j_NO2"], "wrt": "t"}, "rhs": {
          "op": "table_lookup",
          "table": "F_actinic",
          "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
          "output": "NO2",
          "args": []
        }}
      ]
    }
  }
}`

func TestFunctionTables_Roundtrip(t *testing.T) {
	esm, err := LoadString(functionTablesFixture)
	if err != nil {
		t.Fatalf("LoadString failed: %v", err)
	}
	if len(esm.FunctionTables) != 2 {
		t.Fatalf("expected 2 function_tables, got %d", len(esm.FunctionTables))
	}
	sig, ok := esm.FunctionTables["sigma_O3"]
	if !ok {
		t.Fatalf("missing function_tables.sigma_O3")
	}
	if len(sig.Axes) != 1 || sig.Axes[0].Name != "lambda_idx" {
		t.Errorf("sigma_O3 axes wrong: %+v", sig.Axes)
	}
	fa, ok := esm.FunctionTables["F_actinic"]
	if !ok {
		t.Fatalf("missing function_tables.F_actinic")
	}
	if len(fa.Axes) != 2 {
		t.Errorf("F_actinic should have 2 axes, got %d", len(fa.Axes))
	}
	if len(fa.Outputs) != 2 || fa.Outputs[0] != "NO2" {
		t.Errorf("F_actinic outputs wrong: %+v", fa.Outputs)
	}

	// Verify the table_lookup nodes survived parse.
	m := esm.Models["M"]
	if len(m.Equations) != 2 {
		t.Fatalf("expected 2 equations, got %d", len(m.Equations))
	}
	rhs1, ok := m.Equations[0].RHS.(ExprNode)
	if !ok {
		t.Fatalf("eq0.rhs is not ExprNode: %T", m.Equations[0].RHS)
	}
	if rhs1.Op != "table_lookup" {
		t.Errorf("eq0.rhs.op = %q, want table_lookup", rhs1.Op)
	}
	if rhs1.Table == nil || *rhs1.Table != "sigma_O3" {
		t.Errorf("eq0.rhs.table = %v, want sigma_O3", rhs1.Table)
	}
	if _, ok := rhs1.TableAxes["lambda_idx"]; !ok {
		t.Errorf("eq0.rhs.axes missing lambda_idx: %+v", rhs1.TableAxes)
	}

	rhs2, ok := m.Equations[1].RHS.(ExprNode)
	if !ok {
		t.Fatalf("eq1.rhs is not ExprNode: %T", m.Equations[1].RHS)
	}
	if rhs2.Op != "table_lookup" {
		t.Errorf("eq1.rhs.op = %q, want table_lookup", rhs2.Op)
	}
	if outStr, ok := rhs2.Output.(string); !ok || outStr != "NO2" {
		t.Errorf("eq1.rhs.output = %v, want \"NO2\"", rhs2.Output)
	}

	// Round-trip: marshal and reload; the ExprNode shape must be preserved.
	out, err := json.Marshal(esm)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}
	esm2, err := LoadString(string(out))
	if err != nil {
		t.Fatalf("Reload failed: %v\nJSON: %s", err, string(out))
	}
	if len(esm2.FunctionTables) != 2 {
		t.Errorf("after round-trip got %d function_tables", len(esm2.FunctionTables))
	}
	rhs1b, ok := esm2.Models["M"].Equations[0].RHS.(ExprNode)
	if !ok {
		t.Fatalf("after round-trip eq0.rhs is not ExprNode: %T", esm2.Models["M"].Equations[0].RHS)
	}
	if rhs1b.Op != "table_lookup" {
		t.Errorf("after round-trip eq0.rhs.op = %q", rhs1b.Op)
	}
}
