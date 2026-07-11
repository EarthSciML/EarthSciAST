package esm

// Bit-equivalent table_lookup → interp.* lowering harness (esm-lhm).
//
// For each conformance fixture under tests/conformance/function_tables/,
// load the file, walk the model equations, lower every table_lookup node
// to the structurally-equivalent inline-`const` interp.linear /
// interp.bilinear invocation prescribed by esm-spec §9.5.3, and assert
// IEEE-754 binary64 agreement with the equivalent hand-written
// inline-`const` lookup at the §9.2 tolerance contract (abs:0, rel:0,
// non-FMA reference path).
//
// Both arms drive EvaluateClosedFunction; the harness catches lowering-
// side mistakes (wrong output slice, swapped axis order, dropped input
// expression) by computing the reference value from the raw
// FunctionTables block independently of the parsed table_lookup node.

import (
	"encoding/json"
	"math"
	"path/filepath"
	"runtime"
	"testing"
)

// toFloat64Any extends the package's toFloat64 with json.Number handling.
// Const-op `value` payloads come off the wire as json.Number under the
// UseNumber decoder path and are not normalized in place.
func toFloat64Any(v any) (float64, bool) {
	if n, ok := v.(json.Number); ok {
		f, err := n.Float64()
		return f, err == nil
	}
	return toFloat64(v)
}

func functionTablesFixturesRoot(t *testing.T) string {
	t.Helper()
	_, this, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// this = .../pkg/earthsci-ast-go/pkg/esm/function_tables_lowering_test.go
	return filepath.Join(filepath.Dir(this), "..", "..", "..", "..",
		"tests", "conformance", "function_tables")
}

func bitEqual(a, b float64) bool {
	return math.Float64bits(a) == math.Float64bits(b)
}

func resolveAxisValue(t *testing.T, expr any, vars map[string]ModelVariable) float64 {
	t.Helper()
	switch v := expr.(type) {
	case string:
		mv, ok := vars[v]
		if !ok {
			t.Fatalf("variable %q not in model", v)
		}
		f, ok := toFloat64Any(mv.Default)
		if !ok {
			t.Fatalf("variable %q default %v not numeric", v, mv.Default)
		}
		return f
	default:
		f, ok := toFloat64Any(expr)
		if !ok {
			t.Fatalf("complex axis input expr not exercised: %#v", expr)
		}
		return f
	}
}

func resolveOutputIndex(t *testing.T, node ExprNode, outputs []string) int {
	t.Helper()
	if node.Output == nil {
		return 0
	}
	switch v := node.Output.(type) {
	case int64:
		return int(v)
	case int:
		return v
	case float64:
		return int(v)
	case string:
		for i, n := range outputs {
			if n == v {
				return i
			}
		}
		t.Fatalf("output %q not in %v", v, outputs)
	}
	t.Fatalf("table_lookup.output must be int or string, got %T", node.Output)
	return 0
}

func sliceTo1D(t *testing.T, data any, idx int, hasOutputs bool) []float64 {
	t.Helper()
	arr, ok := data.([]any)
	if !ok {
		t.Fatalf("data must be array, got %T", data)
	}
	src := arr
	if hasOutputs {
		row, ok := arr[idx].([]any)
		if !ok {
			t.Fatalf("data[%d] must be array, got %T", idx, arr[idx])
		}
		src = row
	}
	out := make([]float64, len(src))
	for i, v := range src {
		f, ok := toFloat64Any(v)
		if !ok {
			t.Fatalf("data leaf %v not numeric", v)
		}
		out[i] = f
	}
	return out
}

func sliceTo2D(t *testing.T, data any, idx int, hasOutputs bool) [][]float64 {
	t.Helper()
	arr, ok := data.([]any)
	if !ok {
		t.Fatalf("data must be array, got %T", data)
	}
	var rows []any
	if hasOutputs {
		r, ok := arr[idx].([]any)
		if !ok {
			t.Fatalf("data[%d] must be 2-D array", idx)
		}
		rows = r
	} else {
		rows = arr
	}
	out := make([][]float64, len(rows))
	for i, row := range rows {
		ra, ok := row.([]any)
		if !ok {
			t.Fatalf("row %d must be array, got %T", i, row)
		}
		out[i] = make([]float64, len(ra))
		for j, v := range ra {
			f, ok := toFloat64Any(v)
			if !ok {
				t.Fatalf("data[%d][%d] not numeric", i, j)
			}
			out[i][j] = f
		}
	}
	return out
}

func axisValuesFloat64(in []float64) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

func tableSliceAsAny1D(in []float64) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

func tableSliceAsAny2D(in [][]float64) []any {
	out := make([]any, len(in))
	for i, row := range in {
		rr := make([]any, len(row))
		for j, v := range row {
			rr[j] = v
		}
		out[i] = rr
	}
	return out
}

func evalInterpFloat(t *testing.T, name string, args []any) float64 {
	t.Helper()
	got, err := EvaluateClosedFunction(name, args)
	if err != nil {
		t.Fatalf("%s evaluator error: %v", name, err)
	}
	f, ok := toFloat64Any(got)
	if !ok {
		t.Fatalf("%s did not return numeric: %T", name, got)
	}
	return f
}

func lowerAndEvaluate(t *testing.T, node ExprNode, file *ESMFile,
	vars map[string]ModelVariable) float64 {
	t.Helper()
	if node.Op != "table_lookup" {
		t.Fatalf("expected table_lookup, got %q", node.Op)
	}
	if len(node.Args) != 0 {
		t.Fatalf("table_lookup.args MUST be empty, got %d", len(node.Args))
	}
	if node.Table == nil {
		t.Fatal("table_lookup.table missing")
	}
	table, ok := file.FunctionTables[*node.Table]
	if !ok {
		t.Fatalf("unknown table %q", *node.Table)
	}
	kind := "linear"
	if table.Interpolation != nil {
		kind = *table.Interpolation
	}
	hasOutputs := len(table.Outputs) > 0
	outIdx := resolveOutputIndex(t, node, table.Outputs)

	if kind == "linear" && len(table.Axes) == 1 {
		axis := table.Axes[0]
		slice := sliceTo1D(t, table.Data, outIdx, hasOutputs)
		x := resolveAxisValue(t, node.TableAxes[axis.Name], vars)
		return evalInterpFloat(t, "interp.linear", []any{
			tableSliceAsAny1D(slice),
			axisValuesFloat64(axis.Values),
			x,
		})
	}
	if kind == "bilinear" && len(table.Axes) == 2 {
		ax := table.Axes[0]
		ay := table.Axes[1]
		slice := sliceTo2D(t, table.Data, outIdx, hasOutputs)
		x := resolveAxisValue(t, node.TableAxes[ax.Name], vars)
		y := resolveAxisValue(t, node.TableAxes[ay.Name], vars)
		return evalInterpFloat(t, "interp.bilinear", []any{
			tableSliceAsAny2D(slice),
			axisValuesFloat64(ax.Values),
			axisValuesFloat64(ay.Values),
			x, y,
		})
	}
	t.Fatalf("unsupported lowering: kind=%s axes=%d", kind, len(table.Axes))
	return 0
}

func referenceInlineConst(
	t *testing.T,
	tableID string,
	output *string,
	outputIdxInt *int,
	axisInputs [][2]string,
	file *ESMFile,
	vars map[string]ModelVariable,
) float64 {
	t.Helper()
	table := file.FunctionTables[tableID]
	hasOutputs := len(table.Outputs) > 0
	idx := 0
	switch {
	case output != nil:
		for i, n := range table.Outputs {
			if n == *output {
				idx = i
				break
			}
		}
	case outputIdxInt != nil:
		idx = *outputIdxInt
	}
	kind := "linear"
	if table.Interpolation != nil {
		kind = *table.Interpolation
	}
	if kind == "linear" {
		axis := table.Axes[0]
		if axisInputs[0][0] != axis.Name {
			t.Fatalf("axis name %q != %q", axisInputs[0][0], axis.Name)
		}
		slice := sliceTo1D(t, table.Data, idx, hasOutputs)
		x, ok := toFloat64Any(vars[axisInputs[0][1]].Default)
		if !ok {
			t.Fatal("variable default not numeric")
		}
		return evalInterpFloat(t, "interp.linear", []any{
			tableSliceAsAny1D(slice),
			axisValuesFloat64(axis.Values),
			x,
		})
	}
	if kind == "bilinear" {
		ax := table.Axes[0]
		ay := table.Axes[1]
		if axisInputs[0][0] != ax.Name || axisInputs[1][0] != ay.Name {
			t.Fatalf("axis names mismatch")
		}
		slice := sliceTo2D(t, table.Data, idx, hasOutputs)
		x, _ := toFloat64Any(vars[axisInputs[0][1]].Default)
		y, _ := toFloat64Any(vars[axisInputs[1][1]].Default)
		return evalInterpFloat(t, "interp.bilinear", []any{
			tableSliceAsAny2D(slice),
			axisValuesFloat64(ax.Values),
			axisValuesFloat64(ay.Values),
			x, y,
		})
	}
	t.Fatalf("unsupported reference kind: %s", kind)
	return 0
}

func firstTableLookup(t *testing.T, file *ESMFile, modelID string, eqIdx int) ExprNode {
	t.Helper()
	model := file.Models[modelID]
	rhs := model.Equations[eqIdx].RHS
	node, ok := rhs.(ExprNode)
	if !ok {
		t.Fatalf("eq %d rhs must be ExprNode, got %T", eqIdx, rhs)
	}
	return node
}

func TestFunctionTablesLinearLoweringIsBitEquivalent(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	file, err := Load(filepath.Join(root, "linear", "fixture.esm"))
	if err != nil {
		t.Fatalf("load linear fixture: %v", err)
	}
	model := file.Models["M"]
	vars := model.Variables
	node := firstTableLookup(t, file, "M", 0)

	lowered := lowerAndEvaluate(t, node, file, vars)
	reference := referenceInlineConst(t, "sigma_O3_298", nil, nil,
		[][2]string{{"lambda_idx", "lambda"}}, file, vars)
	if !bitEqual(lowered, reference) {
		t.Fatalf("linear lowering bits diverged: lowered=%v reference=%v", lowered, reference)
	}

	expected := 8.7e-18 + 0.5*(7.9e-18-8.7e-18)
	if !bitEqual(lowered, expected) {
		t.Fatalf("linear value mismatch: got %v want %v", lowered, expected)
	}
}

func TestFunctionTablesBilinearLoweringIsBitEquivalent(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	file, err := Load(filepath.Join(root, "bilinear", "fixture.esm"))
	if err != nil {
		t.Fatalf("load bilinear fixture: %v", err)
	}
	model := file.Models["M"]
	vars := model.Variables

	node0 := firstTableLookup(t, file, "M", 0)
	lowered0 := lowerAndEvaluate(t, node0, file, vars)
	noName := "NO2"
	reference0 := referenceInlineConst(t, "F_actinic", &noName, nil,
		[][2]string{{"P", "P_atm"}, {"cos_sza", "cos_sza"}}, file, vars)
	if !bitEqual(lowered0, reference0) {
		t.Fatalf("bilinear NO2 lowering bits diverged: lowered=%v reference=%v",
			lowered0, reference0)
	}

	node1 := firstTableLookup(t, file, "M", 1)
	lowered1 := lowerAndEvaluate(t, node1, file, vars)
	idx1 := 1
	reference1 := referenceInlineConst(t, "F_actinic", nil, &idx1,
		[][2]string{{"P", "P_atm"}, {"cos_sza", "cos_sza"}}, file, vars)
	if !bitEqual(lowered1, reference1) {
		t.Fatalf("bilinear O3 lowering bits diverged")
	}

	if lowered0 != 1.6 {
		t.Fatalf("NO2 sanity: got %v want 1.6", lowered0)
	}
	if lowered1 != 2.6 {
		t.Fatalf("O3 sanity: got %v want 2.6", lowered1)
	}
}

func TestFunctionTablesRoundtripLoweringMatchesInlineConstCompanion(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	file, err := Load(filepath.Join(root, "roundtrip", "fixture.esm"))
	if err != nil {
		t.Fatalf("load roundtrip fixture: %v", err)
	}
	model := file.Models["M"]
	vars := model.Variables

	node := firstTableLookup(t, file, "M", 0)
	lowered := lowerAndEvaluate(t, node, file, vars)

	inline, ok := model.Equations[1].RHS.(ExprNode)
	if !ok {
		t.Fatalf("eq 1 rhs must be ExprNode, got %T", model.Equations[1].RHS)
	}
	if inline.Op != "fn" {
		t.Fatalf("inline op must be fn, got %q", inline.Op)
	}
	if inline.Name == nil || *inline.Name != "interp.linear" {
		t.Fatalf("inline name must be interp.linear")
	}
	tableArg, ok := inline.Args[0].(ExprNode)
	if !ok || tableArg.Op != "const" {
		t.Fatalf("arg 0 must be const-op")
	}
	axisArg, ok := inline.Args[1].(ExprNode)
	if !ok || axisArg.Op != "const" {
		t.Fatalf("arg 1 must be const-op")
	}
	x := resolveAxisValue(t, inline.Args[2], vars)
	tableSlice := sliceTo1D(t, tableArg.Value, 0, false)
	axisSlice := sliceTo1D(t, axisArg.Value, 0, false)
	inlineVal := evalInterpFloat(t, "interp.linear", []any{
		tableSliceAsAny1D(tableSlice),
		axisValuesFloat64(axisSlice),
		x,
	})
	if !bitEqual(lowered, inlineVal) {
		t.Fatalf("table_lookup vs inline-const companion bits diverged: %v vs %v",
			lowered, inlineVal)
	}
}
