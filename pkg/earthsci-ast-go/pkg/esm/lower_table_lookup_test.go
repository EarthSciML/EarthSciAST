package esm

// Tests for the esm-spec §9.5.3 `table_lookup` lowering — the PRODUCTION pass in
// lower_table_lookup.go, not the independent numeric oracle in
// function_tables_lowering_test.go (which stays deliberately separate: it
// recomputes the reference value straight from the raw `function_tables` block,
// so a mistake made in both places cannot hide).
//
// The properties pinned here are the ones issue #188 found missing: that the
// lowering exists on a path a CALLER can reach, that a `table_lookup` observed
// and its hand-lowered twin evaluate to the same number, that loading still
// leaves the authored form in place (§9.5.4), and that a table declaring
// `out_of_bounds: "error"` is refused rather than answered under "clamp"
// (§9.5.3a).

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A 1-axis linear table plus the `table_lookup` that reads it.
const tableLookupFixture = `{
  "esm": "1.0.0",
  "metadata": {"name": "tl", "authors": ["test"]},
  "function_tables": {
    "t_prof": {
      "axes": [{"name": "p", "values": [1.0, 2.0, 3.0, 4.0]}],
      "interpolation": "linear",
      "data": [10.0, 20.0, 30.0, 40.0]
    }
  },
  "models": {
    "M": {
      "variables": {
        "y": {"type": "unknown", "default": 0.0},
        "p": {"type": "parameter", "default": 2.5}
      },
      "equations": [
        {"lhs": "y",
         "rhs": {"op": "table_lookup", "table": "t_prof", "axes": {"p": "p"}, "args": []}}
      ]
    }
  }
}`

// A multi-output 2-axis bilinear table read once by output NAME and once by
// output INDEX — the tests/conformance/function_tables/bilinear shape, inline.
const tableLookupBilinearFixture = `{
  "esm": "1.0.0",
  "metadata": {"name": "tl2", "authors": ["test"]},
  "function_tables": {
    "F_actinic": {
      "axes": [
        {"name": "P", "values": [10.0, 100.0, 1000.0]},
        {"name": "cos_sza", "values": [0.1, 0.5, 1.0]}
      ],
      "interpolation": "bilinear",
      "outputs": ["NO2", "O3", "HCHO"],
      "data": [
        [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
        [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]],
        [[3.0, 3.5, 4.0], [3.1, 3.6, 4.1], [3.2, 3.7, 4.2]]
      ]
    }
  },
  "models": {
    "M": {
      "variables": {
        "j_NO2": {"type": "unknown", "default": 0.0},
        "j_O3": {"type": "unknown", "default": 0.0},
        "P_atm": {"type": "parameter", "default": 100.0},
        "cos_sza": {"type": "parameter", "default": 0.5}
      },
      "equations": [
        {"lhs": "j_NO2",
         "rhs": {"op": "table_lookup", "table": "F_actinic",
                 "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
                 "output": "NO2", "args": []}},
        {"lhs": "j_O3",
         "rhs": {"op": "table_lookup", "table": "F_actinic",
                 "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
                 "output": 1, "args": []}}
      ]
    }
  }
}`

// jsonView renders any value through JSON and back so two expression trees are
// compared by their WIRE form — the thing §9.5.3 specifies — rather than by the
// Go types a particular construction path happened to produce.
func jsonView(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return out
}

// jsonLiteral parses a JSON source string into the same generic form jsonView
// produces.
func jsonLiteral(t *testing.T, src string) any {
	t.Helper()
	var out any
	if err := json.Unmarshal([]byte(src), &out); err != nil {
		t.Fatalf("parse expected JSON: %v", err)
	}
	return out
}

// loweredRHS loads src, lowers it, and returns the RHS of equation eqIdx of
// model M.
func loweredRHS(t *testing.T, src string, eqIdx int) Expression {
	t.Helper()
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	lowered, err := lowerTableLookups(file)
	if err != nil {
		t.Fatalf("lower: %v", err)
	}
	return lowered.Models["M"].Equations[eqIdx].RHS
}

// refuseCode lowers src and returns the diagnostic code of the refusal.
func refuseCode(t *testing.T, src string) string {
	t.Helper()
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("fixture must LOAD (esm-spec §9.5.3a / §9.5.5 raise at lowering, "+
			"not at load): %v", err)
	}
	if _, err := lowerTableLookups(file); err != nil {
		var de DiagnosticError
		if !errors.As(err, &de) {
			t.Fatalf("refusal must carry a §9.5.5 diagnostic code, got %T: %v", err, err)
		}
		return de.DiagnosticCode()
	}
	t.Fatal("expected the lowering to refuse this document")
	return ""
}

func TestTableLookupLowersOneAxisLinearToTheSpecForm(t *testing.T) {
	got := jsonView(t, loweredRHS(t, tableLookupFixture, 0))
	want := jsonLiteral(t, `{
      "op": "fn",
      "name": "interp.linear",
      "args": [
        {"op": "const", "args": [], "value": [10.0, 20.0, 30.0, 40.0]},
        {"op": "const", "args": [], "value": [1.0, 2.0, 3.0, 4.0]},
        "p"
      ]
    }`)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("lowered form diverges from esm-spec §9.5.3:\n got %#v\nwant %#v", got, want)
	}
}

// The axis `const`s go in the table's DECLARED axis order (the order of `data`'s
// inner dimensions), the inputs follow in that same order, and `output` picks
// the row of `data`'s leading dimension — whether spelled as a name or an index.
func TestTableLookupLowersMultiOutputBilinearToTheSpecForm(t *testing.T) {
	byName := jsonView(t, loweredRHS(t, tableLookupBilinearFixture, 0))
	want := jsonLiteral(t, `{
      "op": "fn",
      "name": "interp.bilinear",
      "args": [
        {"op": "const", "args": [],
         "value": [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]]},
        {"op": "const", "args": [], "value": [10.0, 100.0, 1000.0]},
        {"op": "const", "args": [], "value": [0.1, 0.5, 1.0]},
        "P_atm",
        "cos_sza"
      ]
    }`)
	if !reflect.DeepEqual(byName, want) {
		t.Fatalf("output \"NO2\" (the first row) lowered wrong:\n got %#v\nwant %#v", byName, want)
	}

	byIndex := jsonView(t, loweredRHS(t, tableLookupBilinearFixture, 1))
	gotSlice := byIndex.(map[string]any)["args"].([]any)[0].(map[string]any)["value"]
	wantSlice := jsonLiteral(t, `[[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]]`)
	if !reflect.DeepEqual(gotSlice, wantSlice) {
		t.Fatalf("output 1 must select the SECOND row: got %#v", gotSlice)
	}
}

// `nearest` is an `index` of the table slice at the searchsorted position, not
// an `interp` blend.
func TestTableLookupLowersNearestToIndexOfSearchsorted(t *testing.T) {
	src := strings.Replace(tableLookupFixture,
		`"interpolation": "linear"`, `"interpolation": "nearest"`, 1)
	got := jsonView(t, loweredRHS(t, src, 0))
	want := jsonLiteral(t, `{
      "op": "index",
      "args": [
        {"op": "const", "args": [], "value": [10.0, 20.0, 30.0, 40.0]},
        {"op": "fn", "name": "interp.searchsorted", "args": [
          "p",
          {"op": "const", "args": [], "value": [1.0, 2.0, 3.0, 4.0]}
        ]}
      ]
    }`)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("nearest lowered form diverges from esm-spec §9.5.3:\n got %#v\nwant %#v",
			got, want)
	}
}

// A `table_lookup` nested inside another node's AXIS INPUT is lowered too —
// the bottom-up guarantee. The keystone walker reaches the `axes` sidecar, so
// this cannot regress into "only `args` was walked".
func TestTableLookupLowersNestedLookupsInAxisInputs(t *testing.T) {
	src := strings.Replace(tableLookupFixture,
		`"axes": {"p": "p"}, "args": []}}`,
		`"axes": {"p": {"op": "table_lookup", "table": "t_prof", `+
			`"axes": {"p": "p"}, "args": []}}, "args": []}}`, 1)
	got := jsonView(t, loweredRHS(t, src, 0))
	inner := got.(map[string]any)["args"].([]any)[2]
	innerOp, _ := inner.(map[string]any)
	if innerOp == nil || innerOp["name"] != "interp.linear" {
		t.Fatalf("the nested lookup in the axis input was not lowered: %#v", inner)
	}
}

func TestTableLookupLoweringIsIdempotent(t *testing.T) {
	file, err := LoadString(tableLookupFixture)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	once, err := lowerTableLookups(file)
	if err != nil {
		t.Fatalf("lower: %v", err)
	}
	twice, err := lowerTableLookups(once)
	if err != nil {
		t.Fatalf("lower again: %v", err)
	}
	if !reflect.DeepEqual(jsonView(t, once.Models["M"].Equations[0].RHS),
		jsonView(t, twice.Models["M"].Equations[0].RHS)) {
		t.Fatal("a second lowering pass changed an already-lowered document")
	}
}

// A document declaring no `function_tables` is returned untouched — the pass
// does not even walk it.
func TestTableLookupLoweringLeavesATablelessDocumentAlone(t *testing.T) {
	src := `{
      "esm": "1.0.0",
      "metadata": {"name": "plain", "authors": ["test"]},
      "models": {"M": {
        "variables": {"x": {"type": "unknown", "default": 1.0}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                       "rhs": {"op": "neg", "args": ["x"]}}]
      }}
    }`
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	before := jsonView(t, file.Models["M"].Equations[0].RHS)
	lowered, err := lowerTableLookups(file)
	if err != nil {
		t.Fatalf("lower: %v", err)
	}
	if !reflect.DeepEqual(before, jsonView(t, lowered.Models["M"].Equations[0].RHS)) {
		t.Fatal("a document with no function_tables was rewritten")
	}
}

func TestTableLookupLoweringDiagnostics(t *testing.T) {
	cases := []struct {
		name string
		src  string
		code string
	}{
		{
			name: "unknown table",
			src:  strings.Replace(tableLookupFixture, `"table": "t_prof"`, `"table": "nope"`, 1),
			code: CodeTableLookupUnknownTable,
		},
		{
			name: "misnamed axis",
			src:  strings.Replace(tableLookupFixture, `"axes": {"p": "p"}`, `"axes": {"q": "p"}`, 1),
			code: CodeTableLookupAxisNameMismatch,
		},
		{
			name: "output index past the declared outputs",
			src:  strings.Replace(tableLookupBilinearFixture, `"output": 1,`, `"output": 7,`, 1),
			code: CodeTableLookupOutputOutOfRange,
		},
		{
			name: "output name the table does not declare",
			src:  strings.Replace(tableLookupBilinearFixture, `"output": "NO2"`, `"output": "SO2"`, 1),
			code: CodeTableLookupOutputOutOfRange,
		},
		{
			name: "output selector on a single-output table",
			src: strings.Replace(tableLookupFixture, `"axes": {"p": "p"}, "args": []`,
				`"axes": {"p": "p"}, "output": 2, "args": []`, 1),
			code: CodeTableLookupOutputOutOfRange,
		},
		{
			name: "interpolation kind and axis count disagree",
			src: strings.Replace(tableLookupFixture,
				`"interpolation": "linear"`, `"interpolation": "bilinear"`, 1),
			code: CodeTableInterpolationAxesMismatch,
		},
		{
			// esm-spec §9.5.3a: refused, not answered under "clamp".
			name: "out_of_bounds error",
			src: strings.Replace(tableLookupFixture, `"interpolation": "linear",`,
				`"interpolation": "linear", "out_of_bounds": "error",`, 1),
			code: CodeTableOutOfBoundsUnsupported,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := refuseCode(t, tc.src); got != tc.code {
				t.Fatalf("refusal code = %q, want %q", got, tc.code)
			}
		})
	}
}

// --- The shared conformance fixtures (esm-spec §9.5.6) ----------------------

// TestFunctionTablesInlineTestFixtureEvaluatesThroughTheLoweringPath drives
// tests/conformance/function_tables/inline_test/fixture.esm — the fixture whose
// whole point is that the lowering must live on the EVALUATION path, not in a
// test harness (esm-spec §9.5.6 item 4).
//
// This binding is a rewrite-only port with no simulator, so there is no inline-
// test RUNNER to drive; the equivalent here is to evaluate each asserted
// observed's defining equation through (*ESMFile).Evaluate — the document-scoped
// evaluator the lowering is wired into — using the test's own declared
// `parameter_overrides`, and to require the fixture's own declared expectations.
// `y` is a table_lookup, `z` the same lookup hand-written in lowered form, and
// `w` an out-of-range input exercising the default clamp.
func TestFunctionTablesInlineTestFixtureEvaluatesThroughTheLoweringPath(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	file, err := LoadPath(filepath.Join(root, "inline_test", "fixture.esm"))
	if err != nil {
		t.Fatalf("load inline_test fixture: %v", err)
	}
	model, ok := file.Models["TableLookupObserved"]
	if !ok {
		t.Fatal("fixture must declare model TableLookupObserved")
	}
	if len(model.Tests) != 1 {
		t.Fatalf("fixture must declare exactly one inline test, got %d", len(model.Tests))
	}
	inline := model.Tests[0]

	bindings := make(map[string]float64, len(inline.ParameterOverrides))
	for name, raw := range inline.ParameterOverrides {
		f, ok := toFloat64Any(raw)
		if !ok {
			t.Fatalf("parameter override %q is not numeric: %#v", name, raw)
		}
		bindings[name] = f
	}

	// The defining equation of each observed, by LHS name.
	defining := make(map[string]Expression, len(model.Equations))
	for _, eq := range model.Equations {
		if name, ok := eq.LHS.(string); ok {
			defining[name] = eq.RHS
		}
	}

	values := make(map[string]float64, len(inline.Assertions))
	for _, a := range inline.Assertions {
		rhs, ok := defining[a.Variable]
		if !ok {
			t.Fatalf("no defining equation for asserted variable %q", a.Variable)
		}
		got, err := file.Evaluate(rhs, bindings)
		if err != nil {
			t.Fatalf("evaluating %q: %v", a.Variable, err)
		}
		if !bitEqual(got, a.Expected) {
			t.Errorf("%s = %v, fixture asserts %v", a.Variable, got, a.Expected)
		}
		values[a.Variable] = got
	}

	// §9.5's central promise: the sugar and the hand-written lowering are the
	// SAME computation, bit for bit — not merely close.
	if !bitEqual(values["y"], values["z"]) {
		t.Fatalf("table_lookup and its hand-lowered twin diverged: y=%v z=%v",
			values["y"], values["z"])
	}

	// …and the lowered TREE is the hand-written one, so the agreement above is
	// structural rather than a numeric coincidence.
	lowered, err := lowerTableLookups(file)
	if err != nil {
		t.Fatalf("lower: %v", err)
	}
	loweredDefs := make(map[string]Expression)
	for _, eq := range lowered.Models["TableLookupObserved"].Equations {
		if name, ok := eq.LHS.(string); ok {
			loweredDefs[name] = eq.RHS
		}
	}
	if !reflect.DeepEqual(jsonView(t, loweredDefs["y"]), jsonView(t, defining["z"])) {
		t.Fatalf("lowered `y` is not structurally the authored `z`:\n got %#v\nwant %#v",
			jsonView(t, loweredDefs["y"]), jsonView(t, defining["z"]))
	}
	// `w` reads the same table, so it lowers to the same table/axis consts and
	// differs only in the axis INPUT expression.
	wArgs := jsonView(t, loweredDefs["w"]).(map[string]any)["args"].([]any)
	yArgs := jsonView(t, loweredDefs["y"]).(map[string]any)["args"].([]any)
	if !reflect.DeepEqual(wArgs[0], yArgs[0]) || !reflect.DeepEqual(wArgs[1], yArgs[1]) {
		t.Fatal("`w` must lower to the same table and axis consts as `y`")
	}
	if reflect.DeepEqual(wArgs[2], yArgs[2]) {
		t.Fatal("`w` must keep its own axis input expression")
	}
}

// TestFunctionTablesOutOfBoundsErrorFixtureLoadsButIsRefused drives
// tests/conformance/function_tables/out_of_bounds_error/fixture.esm (esm-spec
// §9.5.6 item 5): the document LOADS and round-trips, and the lowering path —
// both the whole-document pass and the document-scoped evaluator — refuses it
// with `table_out_of_bounds_unsupported` rather than answering under "clamp".
func TestFunctionTablesOutOfBoundsErrorFixtureLoadsButIsRefused(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	path := filepath.Join(root, "out_of_bounds_error", "fixture.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("the fixture must LOAD cleanly (§9.5.3a): %v", err)
	}
	if _, err := file.ToJSON(); err != nil {
		t.Fatalf("the fixture must still serialize (§9.5.4): %v", err)
	}

	assertRefused := func(what string, err error) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s: expected a refusal, got none", what)
		}
		var de DiagnosticError
		if !errors.As(err, &de) {
			t.Fatalf("%s: refusal must carry a diagnostic code, got %T: %v", what, err, err)
		}
		if de.DiagnosticCode() != CodeTableOutOfBoundsUnsupported {
			t.Fatalf("%s: code = %q, want %q", what, de.DiagnosticCode(),
				CodeTableOutOfBoundsUnsupported)
		}
	}

	_, err = lowerTableLookups(file)
	assertRefused("lowerTableLookups", err)

	rhs := file.Models["M"].Equations[0].RHS
	_, err = file.Evaluate(rhs, map[string]float64{"p": 2.5})
	assertRefused("(*ESMFile).Evaluate", err)
}

// TestFunctionTablesLoadDoesNotLowerAndRoundTrips pins the reason the lowering
// runs at BUILD and not at load: esm-spec §9.5.4 requires the AUTHORED form to
// survive parse → emit, and this binding serializes the typed document it
// loaded. A load-time rewrite would emit `interp.linear` where the author wrote
// a `table_lookup`.
func TestFunctionTablesLoadDoesNotLowerAndRoundTrips(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	file, err := LoadPath(filepath.Join(root, "inline_test", "fixture.esm"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}

	node, ok := file.Models["TableLookupObserved"].Equations[1].RHS.(ExprNode)
	if !ok || node.Op != OpTableLookup {
		t.Fatalf("loading must leave the authored `table_lookup` in place, got %#v",
			file.Models["TableLookupObserved"].Equations[1].RHS)
	}

	out, err := file.ToJSON()
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	var reloaded map[string]any
	if err := json.Unmarshal(out, &reloaded); err != nil {
		t.Fatalf("re-decode: %v", err)
	}
	if _, ok := reloaded["function_tables"]; !ok {
		t.Fatal("the emitted document dropped its `function_tables` block (§9.5.4)")
	}
	if !strings.Contains(string(out), `"table_lookup"`) {
		t.Fatal("the emitted document no longer spells `table_lookup` (§9.5.4)")
	}

	// And the round trip is stable: reloading the emitted text still yields the
	// authored op, not the lowered one.
	back, err := LoadString(string(out))
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	again, ok := back.Models["TableLookupObserved"].Equations[1].RHS.(ExprNode)
	if !ok || again.Op != OpTableLookup {
		t.Fatalf("round-tripped document lost its `table_lookup`: %#v",
			back.Models["TableLookupObserved"].Equations[1].RHS)
	}
}

// A FlattenedSystem carries the merged function-table registry precisely so a
// surviving `table_lookup` stays resolvable after the build — flattening does
// NOT lower, because the flattened form is a cross-language wire contract.
func TestFlattenedSystemEvaluatesASurvivingTableLookup(t *testing.T) {
	root := functionTablesFixturesRoot(t)
	file, err := LoadPath(filepath.Join(root, "inline_test", "fixture.esm"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	var rhs Expression
	for _, eq := range flat.Equations {
		if name, ok := eq.LHS.(string); ok && name == "TableLookupObserved.y" {
			rhs = eq.RHS
		}
	}
	if rhs == nil {
		t.Fatal("flattened system has no equation defining TableLookupObserved.y")
	}
	node, ok := rhs.(ExprNode)
	if !ok || node.Op != OpTableLookup {
		t.Fatalf("flattening must NOT lower the authored node, got %#v", rhs)
	}
	got, err := flat.Evaluate(rhs, map[string]float64{"TableLookupObserved.p": 2.5})
	if err != nil {
		t.Fatalf("evaluate through the flattened registry: %v", err)
	}
	if !bitEqual(got, 25.0) {
		t.Fatalf("TableLookupObserved.y = %v, want 25", got)
	}
}
