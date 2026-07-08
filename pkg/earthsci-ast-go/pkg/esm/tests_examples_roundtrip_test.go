package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestInlineTestsExamplesRoundTrip verifies that the Go binding round-trips
// the tests_examples_comprehensive.esm fixture, preserving inline Test /
// Assertion / Example / Plot / ParameterSweep blocks (gt-krpg).
func TestInlineTestsExamplesRoundTrip(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "valid", "tests_examples_comprehensive.esm")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	esmFile, err := LoadString(string(data))
	if err != nil {
		t.Fatalf("initial load: %v", err)
	}
	out1, err := esmFile.ToJSON()
	if err != nil {
		t.Fatalf("first serialize: %v", err)
	}
	esmFile2, err := LoadString(string(out1))
	if err != nil {
		t.Fatalf("re-load: %v", err)
	}
	out2, err := esmFile2.ToJSON()
	if err != nil {
		t.Fatalf("second serialize: %v", err)
	}

	// Idempotence under re-save (spec §2.1a): the JSON form after the second
	// round-trip must match the first.
	var o1, o2 interface{}
	if err := json.Unmarshal(out1, &o1); err != nil {
		t.Fatalf("unmarshal out1: %v", err)
	}
	if err := json.Unmarshal(out2, &o2); err != nil {
		t.Fatalf("unmarshal out2: %v", err)
	}
	if !reflect.DeepEqual(o1, o2) {
		t.Fatalf("round-trip is not idempotent")
	}

	// Verify model-level typed fields.
	m, ok := esmFile.Models["LogisticGrowth"]
	if !ok {
		t.Fatalf("LogisticGrowth model missing")
	}
	if m.Tolerance == nil || m.Tolerance.Rel == nil || *m.Tolerance.Rel != 1e-6 {
		t.Errorf("model tolerance incorrect: %+v", m.Tolerance)
	}
	if got, want := len(m.Tests), 2; got != want {
		t.Errorf("model tests count: got %d, want %d", got, want)
	}
	if got, want := len(m.Examples), 3; got != want {
		t.Errorf("model examples count: got %d, want %d", got, want)
	}

	// Spot-check first test assertion list + tolerance override.
	test0 := m.Tests[0]
	if test0.ID != "closed_form_trajectory" {
		t.Errorf("test0 id: %q", test0.ID)
	}
	if test0.TimeSpan.Start != 0.0 || test0.TimeSpan.End != 30.0 {
		t.Errorf("test0 time_span: %+v", test0.TimeSpan)
	}
	if test0.Tolerance == nil || test0.Tolerance.Rel == nil || *test0.Tolerance.Rel != 1e-5 {
		t.Errorf("test0 tolerance: %+v", test0.Tolerance)
	}
	if got, want := len(test0.Assertions), 5; got != want {
		t.Errorf("test0 assertions count: got %d, want %d", got, want)
	}
	// Last two assertions carry per-assertion tolerance overrides.
	for _, i := range []int{3, 4} {
		if test0.Assertions[i].Tolerance == nil {
			t.Errorf("assertion[%d] missing tolerance override", i)
		}
	}

	// rK_heatmap_sweep: 2-D Cartesian sweep with heatmap plots.
	var sweep *Example
	for i := range m.Examples {
		if m.Examples[i].ID == "rK_heatmap_sweep" {
			sweep = &m.Examples[i]
			break
		}
	}
	if sweep == nil {
		t.Fatalf("rK_heatmap_sweep example missing")
	}
	if sweep.ParameterSweep == nil || len(sweep.ParameterSweep.Dimensions) != 2 {
		t.Errorf("sweep dims: %+v", sweep.ParameterSweep)
	}
	// First dim uses linear range; second uses log range.
	d0 := sweep.ParameterSweep.Dimensions[0]
	if d0.Parameter != "r" || d0.Range == nil || d0.Range.Count != 10 {
		t.Errorf("dim0: %+v", d0)
	}
	if d0.Range.Scale == nil || *d0.Range.Scale != "linear" {
		t.Errorf("dim0 scale: %+v", d0.Range.Scale)
	}
	d1 := sweep.ParameterSweep.Dimensions[1]
	if d1.Range == nil || d1.Range.Scale == nil || *d1.Range.Scale != "log" {
		t.Errorf("dim1 scale: %+v", d1.Range)
	}
	// Heatmap plots expose PlotValue.
	if got, want := len(sweep.Plots), 3; got != want {
		t.Errorf("sweep plots: got %d, want %d", got, want)
	}
	if sweep.Plots[0].Value == nil || sweep.Plots[0].Value.Reduce == nil ||
		*sweep.Plots[0].Value.Reduce != "final" {
		t.Errorf("plot0 value: %+v", sweep.Plots[0].Value)
	}
	if sweep.Plots[2].Value == nil || sweep.Plots[2].Value.AtTime == nil ||
		*sweep.Plots[2].Value.AtTime != 10.0 {
		t.Errorf("plot2 value: %+v", sweep.Plots[2].Value)
	}

	// enumerated_r_sweep: 1-D sweep using Values (not Range).
	var enumSweep *Example
	for i := range m.Examples {
		if m.Examples[i].ID == "enumerated_r_sweep" {
			enumSweep = &m.Examples[i]
			break
		}
	}
	if enumSweep == nil || enumSweep.ParameterSweep == nil {
		t.Fatalf("enumerated_r_sweep missing")
	}
	d := enumSweep.ParameterSweep.Dimensions[0]
	if d.Range != nil {
		t.Errorf("enumerated dim should not carry Range: %+v", d)
	}
	if got, want := len(d.Values), 7; got != want {
		t.Errorf("enumerated values count: got %d, want %d", got, want)
	}

	// ReactionSystem parity: tolerance, tests, examples, and PlotSeries.
	rs, ok := esmFile.ReactionSystems["SimpleDecay"]
	if !ok {
		t.Fatalf("SimpleDecay reaction system missing")
	}
	if rs.Tolerance == nil || rs.Tolerance.Rel == nil || *rs.Tolerance.Rel != 1e-6 {
		t.Errorf("rs tolerance: %+v", rs.Tolerance)
	}
	if got, want := len(rs.Tests), 1; got != want {
		t.Errorf("rs tests: got %d, want %d", got, want)
	}
	if got, want := len(rs.Examples), 2; got != want {
		t.Errorf("rs examples: got %d, want %d", got, want)
	}
	// PlotSeries survives round-trip on the reaction-system example.
	rsExample := rs.Examples[0]
	if len(rsExample.Plots) != 1 || len(rsExample.Plots[0].Series) != 2 {
		t.Fatalf("rs plot series missing: %+v", rsExample.Plots)
	}
	if rsExample.Plots[0].Series[0].Name != "A" ||
		rsExample.Plots[0].Series[1].Name != "B" {
		t.Errorf("rs plot series names: %+v", rsExample.Plots[0].Series)
	}

	// multi_y_trace: inline array-form y (v0.5.0) projects onto Y + Series.
	var multiYEx *Example
	for i := range rs.Examples {
		if rs.Examples[i].ID == "multi_y_trace" {
			multiYEx = &rs.Examples[i]
			break
		}
	}
	if multiYEx == nil {
		t.Fatalf("multi_y_trace example missing")
	}
	if got, want := len(multiYEx.Plots), 1; got != want {
		t.Fatalf("multi_y_trace plots: got %d, want %d", got, want)
	}
	multiPlot := multiYEx.Plots[0]
	if multiPlot.Y.Variable != "A" {
		t.Errorf("multi_y canonical Y: got %q, want \"A\"", multiPlot.Y.Variable)
	}
	if got, want := len(multiPlot.Series), 2; got != want {
		t.Fatalf("multi_y series count: got %d, want %d", got, want)
	}
	if multiPlot.Series[0].Name != "A" || multiPlot.Series[0].Variable != "A" {
		t.Errorf("multi_y series[0]: %+v", multiPlot.Series[0])
	}
	if multiPlot.Series[1].Name != "B" || multiPlot.Series[1].Variable != "B" {
		t.Errorf("multi_y series[1]: %+v", multiPlot.Series[1])
	}
}
