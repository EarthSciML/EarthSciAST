package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// brownian_test.go covers what the `brownian` VARIABLE TYPE became in esm
// 1.0.0: a parameter carrying a `distribution` and `update: {kind: "wiener"}`.
// The type, its `noise_kind` sidecar, and its `correlation_group` tag are all
// gone, so these tests assert the replacement shape rather than a renamed
// version of the old one.

// A wiener-updated parameter must survive parse -> serialize -> parse with its
// distribution and update intact, and must classify as Brownian.
func TestWienerParameterRoundTrip(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "sde", "ornstein_uhlenbeck.esm")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed ESMFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal fixture: %v", err)
	}
	model := parsed.Models["OU"]
	bw, ok := model.Variables["Bw"]
	if !ok {
		t.Fatalf("Bw variable missing in fixture")
	}

	// The declared type is `parameter` -- there is no `brownian` type to check.
	if bw.Type != VarTypeParameter {
		t.Errorf("Bw.Type = %q, want %q", bw.Type, VarTypeParameter)
	}
	// Brownian-ness is DERIVED from the update, not declared.
	if !bw.Update.IsWiener() {
		t.Errorf("Bw.Update.IsWiener() = false, want true (update = %+v)", bw.Update)
	}
	if bw.Update.IsArray {
		t.Error("a wiener update is admissible only as the object form, not an array")
	}
	if bw.Distribution == nil {
		t.Fatal("a wiener parameter requires a distribution -- it is what gets resampled")
	}
	if bw.Distribution.Kind != DistributionNormal {
		t.Errorf("Bw distribution kind = %q, want %q", bw.Distribution.Kind, DistributionNormal)
	}
	if bw.Distribution.IsMultivariate() {
		t.Error("a scalar mean must classify as univariate")
	}

	if got := BrownianParameters(&model); !reflect.DeepEqual(got, []string{"Bw"}) {
		t.Errorf("BrownianParameters = %v, want [Bw]", got)
	}
	// One wiener parameter is what makes the enclosing model an SDE.
	if got := SystemKind(&model); got != SystemKindSDE {
		t.Errorf("SystemKind = %q, want %q", got, SystemKindSDE)
	}

	out, err := json.Marshal(&parsed)
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

// Correlated noise is ONE vector-valued parameter whose distribution carries a
// `cov`. The 0.x spelling was two brownian variables sharing a
// `correlation_group: "wind"` tag, which named the correlation without stating
// it; the covariance matrix states it.
func TestCorrelatedNoiseIsOneVectorParameter(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "sde", "correlated_noise.esm")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed ESMFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	model := parsed.Models["TwoBody"]

	// ONE parameter, not two: the pair of increments is a vector.
	want := []string{"B"}
	if got := BrownianParameters(&model); !reflect.DeepEqual(got, want) {
		t.Errorf("BrownianParameters = %v, want %v", got, want)
	}

	b := model.Variables["B"]
	if b.Distribution == nil {
		t.Fatal("B must carry a distribution")
	}
	if !b.Distribution.IsMultivariate() {
		t.Error("an array-valued mean must classify as multivariate")
	}
	if len(b.Distribution.Cov) != 2 {
		t.Fatalf("want a 2x2 covariance, got %v", b.Distribution.Cov)
	}
	// The off-diagonal IS the correlation the old tag could only name.
	if b.Distribution.Cov[0][1] == 0 {
		t.Error("the off-diagonal must be non-zero; that is what makes the noise correlated")
	}
	if !b.ShapeDeclared() {
		t.Error("a vector-valued distribution requires the parameter's shape to agree")
	}
}

// Flattening a coupled file must surface a wiener parameter in
// FlattenedSystem.BrownianParameters, dot-namespaced -- and in Parameters too,
// since it IS a parameter now rather than a fourth variable kind.
func TestFlattenBrownianParameters(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "sde", "correlated_noise.esm")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed ESMFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	flat, err := Flatten(&parsed)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	want := []string{"TwoBody.B"}
	if !reflect.DeepEqual(flat.BrownianParameters, want) {
		t.Errorf("BrownianParameters = %v, want %v", flat.BrownianParameters, want)
	}
	if !contains(flat.Parameters, "TwoBody.B") {
		t.Errorf("a brownian parameter must also appear in Parameters, got %v", flat.Parameters)
	}
	if got := flat.Variables["TwoBody.B"]; got != ClassBrownianParameter {
		t.Errorf("Variables[TwoBody.B] = %q, want %q", got, ClassBrownianParameter)
	}
}
