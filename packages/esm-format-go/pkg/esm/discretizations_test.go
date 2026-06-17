package esm

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func intPtr(n int) *int { return &n }

// assertJSONEqual compares two Go values by re-encoding to JSON and decoding
// into generic interface{} form — so json.RawMessage byte differences due to
// whitespace do not cause spurious mismatches.
func assertJSONEqual(t *testing.T, a, b interface{}, name string) {
	t.Helper()
	aj, err := json.Marshal(a)
	if err != nil {
		t.Fatalf("%s: marshal a: %v", name, err)
	}
	bj, err := json.Marshal(b)
	if err != nil {
		t.Fatalf("%s: marshal b: %v", name, err)
	}
	var ax, bx interface{}
	if err := json.Unmarshal(aj, &ax); err != nil {
		t.Fatalf("%s: decode a: %v", name, err)
	}
	if err := json.Unmarshal(bj, &bx); err != nil {
		t.Fatalf("%s: decode b: %v", name, err)
	}
	if !reflect.DeepEqual(ax, bx) {
		t.Errorf("%s: value mismatch after round-trip\n got: %s\nwant: %s", name, string(bj), string(aj))
	}
}

// Round-trip each §7 discretization fixture and verify the top-level
// Discretizations map and its stencil body survive unchanged.
func TestDiscretizationsRoundTrip(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	fixtures := []struct {
		id              string
		path            string
		schemeName      string
		gridFamily      string
		stencilLen      int
		wantOrder       *int
		wantStencilGen  bool
	}{
		// centered_2nd_uniform.esm was migrated to stencil_gen (ess-bq1); stencil array is gone.
		{"centered_2nd_uniform", "tests/discretizations/centered_2nd_uniform.esm", "centered_2nd_uniform", "cartesian", 0, nil, true},
		{"upwind_1st_advection", "tests/discretizations/upwind_1st_advection.esm", "upwind_1st", "cartesian", 3, nil, false},
		{"periodic_bc", "tests/discretizations/periodic_bc.esm", "periodic_bc_x", "cartesian", 1, nil, false},
		{"mpas_cell_div", "tests/discretizations/mpas_cell_div.esm", "mpas_cell_div", "unstructured", 1, nil, false},
		// centered_arbitrary_order_uniform.esm was migrated to stencil_gen (ess-bq1); stencil array is gone.
		{"centered_arbitrary_order_uniform", "tests/discretizations/centered_arbitrary_order_uniform.esm", "centered_arbitrary_order_uniform", "cartesian", 0, intPtr(4), true},
		// dim_split_2d_strang exercises the kind="dimensional_split" branch
		// (RFC §7.5): its primary scheme (strang_grad_xy) has no stencil body.
		// The test references the *inner* 1D scheme ("centered_2nd_uniform")
		// so the generic stencil assertions still apply; TestDimensionalSplitScheme
		// below checks the dimensional-split fields round-trip.
		{"dim_split_2d_strang", "tests/discretizations/dim_split_2d_strang.esm", "centered_2nd_uniform", "cartesian", 2, nil, false},
		// Cross-metric composite (RFC §7.6): the named entry has no stencil
		// (stencilLen 0 routes into the composite assertion below); the
		// per-axis schemes referenced via Terms are exercised separately.
		{"cross_metric_cartesian_composite", "tests/discretizations/cross_metric_cartesian.esm", "laplacian_full_covariant_toy", "cartesian", 0, nil, false},
		{"cross_metric_cartesian_dxi2", "tests/discretizations/cross_metric_cartesian.esm", "d2_dxi2_uniform", "cartesian", 3, nil, false},
		{"cross_metric_cartesian_deta2", "tests/discretizations/cross_metric_cartesian.esm", "d2_deta2_uniform", "cartesian", 3, nil, false},
	}
	for _, f := range fixtures {
		t.Run(f.id, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(repoRoot, f.path))
			if err != nil {
				t.Fatalf("read: %v", err)
			}
			var parsed EsmFile
			if err := json.Unmarshal(raw, &parsed); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			scheme, ok := parsed.Discretizations[f.schemeName]
			if !ok {
				t.Fatalf("scheme %q not found", f.schemeName)
			}
			if scheme.GridFamily != f.gridFamily {
				t.Errorf("grid_family = %q, want %q", scheme.GridFamily, f.gridFamily)
			}
			if len(scheme.Stencil) != f.stencilLen {
				t.Errorf("stencil len = %d, want %d", len(scheme.Stencil), f.stencilLen)
			}
			if f.wantStencilGen && scheme.StencilGen == nil {
				t.Errorf("scheme %q: expected stencil_gen to be set", f.schemeName)
			}
			if !f.wantStencilGen && scheme.StencilGen != nil {
				t.Errorf("scheme %q: unexpected stencil_gen present", f.schemeName)
			}
			switch {
			case f.wantOrder == nil && scheme.Order != nil:
				t.Errorf("order = %d, want absent", *scheme.Order)
			case f.wantOrder != nil && scheme.Order == nil:
				t.Errorf("order absent, want %d", *f.wantOrder)
			case f.wantOrder != nil && scheme.Order != nil && *scheme.Order != *f.wantOrder:
				t.Errorf("order = %d, want %d", *scheme.Order, *f.wantOrder)
			}

			// For cross-metric composite entries (stencilLen == 0, no Stencil, no
			// StencilGen) we expect a nonempty Terms array and IsCrossMetric()==
			// true (RFC §7.6). Skip for dimensional_split (uses InnerRule) and
			// stencil_gen schemes (no stencil by design — the loader expands it).
			if f.stencilLen == 0 && len(scheme.Stencil) == 0 && scheme.Kind != "dimensional_split" && !f.wantStencilGen {
				if !scheme.IsCrossMetric() {
					t.Errorf("scheme %q: expected composite (Terms nonempty), got Terms=%v", f.schemeName, scheme.Terms)
				}
				if len(scheme.Axes) == 0 {
					t.Errorf("scheme %q: composite must declare axes", f.schemeName)
				}
			}

			out, err := json.Marshal(&parsed)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			var reparsed EsmFile
			if err := json.Unmarshal(out, &reparsed); err != nil {
				t.Fatalf("unmarshal round-trip: %v", err)
			}
			// Compare the full discretizations section as decoded JSON values
			// (raw-byte equality is too strict — whitespace differs).
			assertJSONEqual(t, parsed.Discretizations, reparsed.Discretizations, "discretizations")

			// Second hop must also be a fixed point.
			out2, err := json.Marshal(&reparsed)
			if err != nil {
				t.Fatalf("second marshal: %v", err)
			}
			var reparsed2 EsmFile
			if err := json.Unmarshal(out2, &reparsed2); err != nil {
				t.Fatalf("second unmarshal: %v", err)
			}
			assertJSONEqual(t, reparsed.Discretizations, reparsed2.Discretizations, "discretizations (second hop)")
		})
	}
}

// TestDimensionalSplitScheme exercises the structured fields of a
// kind="dimensional_split" Discretization (axes/inner_rule/splitting/
// order_of_sweeps) on the RFC §7.4 worked example fixture.
func TestDimensionalSplitScheme(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	raw, err := os.ReadFile(filepath.Join(repoRoot, "tests/discretizations/dim_split_2d_strang.esm"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var parsed EsmFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	scheme, ok := parsed.Discretizations["strang_grad_xy"]
	if !ok {
		t.Fatalf("scheme strang_grad_xy not found")
	}
	if scheme.Kind != "dimensional_split" {
		t.Errorf("Kind = %q, want \"dimensional_split\"", scheme.Kind)
	}
	if len(scheme.Stencil) != 0 {
		t.Errorf("dimensional_split scheme must have no stencil, got %d entries", len(scheme.Stencil))
	}
	if got, want := scheme.Axes, []string{"x", "y"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Axes = %v, want %v", got, want)
	}
	if scheme.InnerRule != "centered_2nd_uniform" {
		t.Errorf("InnerRule = %q, want \"centered_2nd_uniform\"", scheme.InnerRule)
	}
	if scheme.Splitting != "strang" {
		t.Errorf("Splitting = %q, want \"strang\"", scheme.Splitting)
	}
	if scheme.OrderOfSweeps != "alternating" {
		t.Errorf("OrderOfSweeps = %q, want \"alternating\"", scheme.OrderOfSweeps)
	}
	// Verify the inner scheme also parses (kind="stencil" explicit form).
	inner, ok := parsed.Discretizations["centered_2nd_uniform"]
	if !ok {
		t.Fatalf("inner scheme centered_2nd_uniform not found")
	}
	if inner.Kind != "stencil" {
		t.Errorf("inner Kind = %q, want \"stencil\"", inner.Kind)
	}

	// Round-trip and confirm the dim-split scheme survives intact.
	out, err := json.Marshal(&parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var reparsed EsmFile
	if err := json.Unmarshal(out, &reparsed); err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	assertJSONEqual(t, parsed.Discretizations, reparsed.Discretizations, "discretizations (dim-split)")
}

// TestFfslDiscretizationStructuralAsserts verifies the structural invariants
// of the CAM5 FFSL fixture: the kind discriminator, absence of a stencil,
// and presence + shape of the FFSL-specific fields (reconstruction, remap,
// cfl_policy, dimensions). See RFC §7.7.
func TestFfslDiscretizationStructuralAsserts(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	raw, err := os.ReadFile(filepath.Join(repoRoot, "tests/discretizations/cam5_ffsl_advection.esm"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var parsed EsmFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	d, ok := parsed.Discretizations["cam5_ffsl_1d"]
	if !ok {
		t.Fatal("cam5_ffsl_1d not found")
	}
	if d.Kind != "flux_form_semi_lagrangian" {
		t.Errorf("kind = %q, want %q", d.Kind, "flux_form_semi_lagrangian")
	}
	if len(d.Stencil) != 0 {
		t.Errorf("FFSL rule must not carry a stencil; got %d entries", len(d.Stencil))
	}
	if d.Remap == nil {
		t.Fatal("remap missing")
	}
	if d.Remap.Semantics != "conservative" {
		t.Errorf("remap.semantics = %q, want %q", d.Remap.Semantics, "conservative")
	}
	if d.CflPolicy != "conservative" {
		t.Errorf("cfl_policy = %q, want %q", d.CflPolicy, "conservative")
	}
	if len(d.Dimensions) != 1 || d.Dimensions[0] != "x" {
		t.Errorf("dimensions = %v, want [x]", d.Dimensions)
	}
	if len(d.Reconstruction) == 0 {
		t.Error("reconstruction missing")
	}
}

// TestGridDispatchScheme exercises the RFC §7.8 grid_dispatch fixture: a
// single Discretization with a cartesian variant in lieu of an
// inline body. Verifies parent-level GridFamily / Stencil are absent,
// GridDispatch carries the variant, and the round-trip preserves variant
// bodies.
func TestGridDispatchScheme(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	raw, err := os.ReadFile(filepath.Join(repoRoot, "tests/discretizations/grid_dispatch_ppm.esm"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var parsed EsmFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	d, ok := parsed.Discretizations["ppm_advection"]
	if !ok {
		t.Fatal("ppm_advection not found")
	}
	if d.GridFamily != "" {
		t.Errorf("parent GridFamily must be empty when grid_dispatch is set; got %q", d.GridFamily)
	}
	if len(d.Stencil) != 0 {
		t.Errorf("parent Stencil must be empty when grid_dispatch is set; got %d entries", len(d.Stencil))
	}
	if len(d.GridDispatch) != 1 {
		t.Fatalf("expected 1 grid_dispatch variant; got %d", len(d.GridDispatch))
	}
	families := []string{d.GridDispatch[0].GridFamily}
	want := []string{"cartesian"}
	if !reflect.DeepEqual(families, want) {
		t.Errorf("variant grid_family order = %v, want %v", families, want)
	}
	if got := len(d.GridDispatch[0].Stencil); got != 4 {
		t.Errorf("cartesian variant stencil len = %d, want 4", got)
	}

	// Round-trip the document and confirm the dispatch block survives.
	out, err := json.Marshal(&parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var reparsed EsmFile
	if err := json.Unmarshal(out, &reparsed); err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	assertJSONEqual(t, parsed.Discretizations, reparsed.Discretizations, "discretizations (grid_dispatch)")
}

// TestMultiOutputStencilScheme exercises the RFC §7.9 multi_output_stencil
// fixture: the provider scheme (ppm_reconstruction) carries an object-valued
// stencil and an outputs list; the consumer (ppm_flux) carries a requires map.
func TestMultiOutputStencilScheme(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	raw, err := os.ReadFile(filepath.Join(repoRoot, "tests/discretizations/multi_output_ppm_reconstruction.esm"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var parsed EsmFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// ── Provider (ppm_reconstruction) ──────────────────────────────────────
	provider, ok := parsed.Discretizations["ppm_reconstruction"]
	if !ok {
		t.Fatal("ppm_reconstruction not found")
	}
	if provider.Kind != "multi_output_stencil" {
		t.Errorf("Kind = %q, want \"multi_output_stencil\"", provider.Kind)
	}
	if !provider.IsMultiOutput() {
		t.Error("IsMultiOutput() should return true for kind=multi_output_stencil")
	}
	if got, want := provider.Outputs, []string{"q_left_edge", "q_right_edge"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Outputs = %v, want %v", got, want)
	}
	if len(provider.MultiOutputStencil) != 2 {
		t.Errorf("MultiOutputStencil key count = %d, want 2", len(provider.MultiOutputStencil))
	}
	for _, key := range []string{"q_left_edge", "q_right_edge"} {
		entries, exists := provider.MultiOutputStencil[key]
		if !exists {
			t.Errorf("MultiOutputStencil missing key %q", key)
		}
		if len(entries) != 2 {
			t.Errorf("MultiOutputStencil[%q] len = %d, want 2", key, len(entries))
		}
	}
	if len(provider.Stencil) != 0 {
		t.Errorf("multi_output_stencil provider must have empty Stencil; got %d entries", len(provider.Stencil))
	}
	if provider.EmitsLocation != "face" {
		t.Errorf("EmitsLocation = %q, want \"face\"", provider.EmitsLocation)
	}
	// primary: null must survive as a json.RawMessage holding "null"
	if string(bytes.TrimSpace(provider.Primary)) != "null" {
		t.Errorf("Primary raw = %q, want \"null\"", string(provider.Primary))
	}

	// ── Consumer (ppm_flux) ────────────────────────────────────────────────
	consumer, ok := parsed.Discretizations["ppm_flux"]
	if !ok {
		t.Fatal("ppm_flux not found")
	}
	if consumer.Kind != "stencil" {
		t.Errorf("consumer Kind = %q, want \"stencil\"", consumer.Kind)
	}
	if consumer.IsMultiOutput() {
		t.Error("IsMultiOutput() should return false for a consumer stencil scheme")
	}
	if len(consumer.Requires) != 2 {
		t.Errorf("consumer Requires len = %d, want 2", len(consumer.Requires))
	}
	if got := consumer.Requires["q_left_edge"]; got != "ppm_reconstruction#q_left_edge" {
		t.Errorf("Requires[q_left_edge] = %q, want %q", got, "ppm_reconstruction#q_left_edge")
	}
	if got := consumer.Requires["q_right_edge"]; got != "ppm_reconstruction#q_right_edge" {
		t.Errorf("Requires[q_right_edge] = %q, want %q", got, "ppm_reconstruction#q_right_edge")
	}

	// ── Round-trip ────────────────────────────────────────────────────────
	out, err := json.Marshal(&parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var reparsed EsmFile
	if err := json.Unmarshal(out, &reparsed); err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	assertJSONEqual(t, parsed.Discretizations, reparsed.Discretizations, "discretizations (multi_output)")

	// Second hop.
	out2, err := json.Marshal(&reparsed)
	if err != nil {
		t.Fatalf("second marshal: %v", err)
	}
	var reparsed2 EsmFile
	if err := json.Unmarshal(out2, &reparsed2); err != nil {
		t.Fatalf("second unmarshal: %v", err)
	}
	assertJSONEqual(t, reparsed.Discretizations, reparsed2.Discretizations, "discretizations (multi_output second hop)")
}
