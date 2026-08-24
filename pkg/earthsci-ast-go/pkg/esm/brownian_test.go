package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// brownian_test.go covers the esm 1.0.0 spelling of a stochastic noise source.
// There is no `brownian` variable TYPE any more: a noise source is a PARAMETER
// carrying a `distribution` and `update: {kind: "wiener"}`, and "which
// parameters are Brownian" is answered by the classification function
// BrownianParameters (esm-spec §6.3.1), never by reading a declared type.
// Correlated noise is likewise one VECTOR-VALUED parameter whose distribution
// carries an explicit `cov`, replacing the 0.x `correlation_group` tag that
// named a correlation without ever giving one.

func loadSDEFixture(t *testing.T, name string) *ESMFile {
	t.Helper()
	fixture := filepath.Join("..", "..", "..", "..", "tests", "fixtures", "sde", name)
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed ESMFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal fixture: %v", err)
	}
	return &parsed
}

// A wiener-updated parameter round-trips through parse → serialize → parse with
// its distribution and its update rule intact.
func TestWienerParameterRoundTrip(t *testing.T) {
	parsed := loadSDEFixture(t, "ornstein_uhlenbeck.esm")
	bw, ok := parsed.Models["OU"].Variables["Bw"]
	if !ok {
		t.Fatalf("Bw variable missing in fixture")
	}
	if bw.Type != VarTypeParameter {
		t.Errorf("Bw.Type = %q, want %q — a noise source is a parameter in 1.0.0", bw.Type, VarTypeParameter)
	}
	rules := bw.UpdateRules()
	if len(rules) != 1 || rules[0].Kind != UpdateKindWiener {
		t.Fatalf("Bw update = %+v, want a single wiener rule", rules)
	}
	if bw.Distribution == nil || bw.Distribution.Kind != DistributionNormal {
		t.Fatalf("Bw.Distribution = %+v, want a normal distribution (a wiener update resamples it)", bw.Distribution)
	}

	out, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var reparsed ESMFile
	if err := json.Unmarshal(out, &reparsed); err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	rbw := reparsed.Models["OU"].Variables["Bw"]
	if !reflect.DeepEqual(bw, rbw) {
		t.Errorf("wiener parameter lost information on round-trip: got %+v want %+v", rbw, bw)
	}
}

// The four parameter sets of esm-spec §6.3.1 partition, and only the
// wiener-updated parameter is Brownian. `sigma` — the noise INTENSITY — is an
// ordinary constant, which is the mistake this pins against: a binding that
// treated "anything with noise-ish units" or "anything with a distribution" as
// Brownian would put it in the wrong set.
func TestBrownianParametersClassification(t *testing.T) {
	parsed := loadSDEFixture(t, "ornstein_uhlenbeck.esm")
	model := parsed.Models["OU"]

	if got, want := BrownianParameters(&model), []string{"Bw"}; !reflect.DeepEqual(got, want) {
		t.Errorf("BrownianParameters = %v, want %v", got, want)
	}
	if got, want := ConstantParameters(&model), []string{"sigma", "theta"}; !reflect.DeepEqual(got, want) {
		t.Errorf("ConstantParameters = %v, want %v", got, want)
	}
	if got := DiscreteParameters(&model); len(got) != 0 {
		t.Errorf("DiscreteParameters = %v, want none", got)
	}
	if got := SampledParameters(&model); len(got) != 0 {
		t.Errorf("SampledParameters = %v, want none — Bw has an update, so it is Brownian, not sampled", got)
	}
	// Any Brownian parameter promotes the model to an SDE.
	if got := SystemKind(&model, parsed.Domain); got != SystemKindSDE {
		t.Errorf("SystemKind = %q, want %q", got, SystemKindSDE)
	}
}

// Correlated noise: ONE vector-valued parameter whose distribution carries the
// covariance matrix. The `cov` must survive the round-trip — it is the only
// place the correlation is stated.
func TestCorrelatedNoiseIsOneVectorParameter(t *testing.T) {
	parsed := loadSDEFixture(t, "correlated_noise.esm")
	model := parsed.Models["TwoBody"]

	if got, want := BrownianParameters(&model), []string{"B"}; !reflect.DeepEqual(got, want) {
		t.Errorf("BrownianParameters = %v, want %v (one vector-valued source, not two scalars)", got, want)
	}
	b := model.Variables["B"]
	if b.Distribution == nil {
		t.Fatal("B carries no distribution")
	}
	wantCov := [][]float64{{1.0, 0.5}, {0.5, 1.0}}
	if !reflect.DeepEqual(b.Distribution.Cov, wantCov) {
		t.Errorf("B.Distribution.Cov = %v, want %v", b.Distribution.Cov, wantCov)
	}
	if got, want := b.Dims(), []string{"wind_noise"}; !reflect.DeepEqual(got, want) {
		t.Errorf("B shape = %v, want %v (the cov order must match it)", got, want)
	}

	out, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var reparsed ESMFile
	if err := json.Unmarshal(out, &reparsed); err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	if !reflect.DeepEqual(b, reparsed.Models["TwoBody"].Variables["B"]) {
		t.Errorf("correlated-noise parameter lost information on round-trip: got %+v want %+v",
			reparsed.Models["TwoBody"].Variables["B"], b)
	}
}

// Flattening surfaces the derived Brownian set under its dot-namespaced names.
// The parameter is ALSO an ordinary parameter of the flattened system, which is
// the substantive change from 0.x: a noise source is no longer a variable kind
// of its own.
func TestFlattenBrownianParameters(t *testing.T) {
	parsed := loadSDEFixture(t, "correlated_noise.esm")
	flat, err := Flatten(parsed)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	names := func(vs []FlattenedVariable) []string {
		out := []string{}
		for _, v := range vs {
			out = append(out, v.Name)
		}
		return out
	}
	if want := []string{"TwoBody.B"}; !reflect.DeepEqual(names(flat.BrownianParameters), want) {
		t.Errorf("BrownianParameters = %v, want %v", names(flat.BrownianParameters), want)
	}
	if !containsVar(flat.Parameters, "TwoBody.B") {
		t.Errorf("Parameters = %v, want it to include TwoBody.B — a noise source IS a parameter",
			names(flat.Parameters))
	}
	// The Brownian bucket carries the FULL variable, not a bare name: a consumer
	// building an SDE problem needs its distribution and shape from here
	// (esm-libraries-spec §4.7.5 step 4, "Full metadata, not names").
	if b := flat.BrownianParameters[0]; b.Distribution == nil || len(b.Shape) == 0 {
		t.Errorf("flattened Brownian parameter lost its metadata: %+v", b)
	}
	if want := []string{"TwoBody.x", "TwoBody.y"}; !reflect.DeepEqual(names(flat.StateVariables), want) {
		t.Errorf("StateVariables = %v, want %v", names(flat.StateVariables), want)
	}
}
