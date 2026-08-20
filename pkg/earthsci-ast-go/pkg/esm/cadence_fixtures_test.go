package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// cadence_fixtures_test.go covers the dependency-partition (cadence) fixtures at
// the depth this binding actually reaches.
//
// SCOPE, stated plainly: the Go binding implements NO cadence partition pass.
// It has no leaf-seeding, no max-propagation, no frontier cut and no
// materialization-point derivation, and it never has. The cross-binding class /
// materialization-point / CONST-fold golden is asserted by
// scripts/run-cadence-conformance.py against the bindings that do implement one
// (CONFORMANCE_SPEC §5.7). What Go owes these fixtures is that they LOAD and
// SCHEMA-VALIDATE, which is what is tested here.
//
// CONFORMANCE_SPEC §5.7.2 changed materially in esm 1.0.0 — a leaf now seeds
// from the §6.3.1 classification rather than from a declared variable kind, and
// an OBSERVED leaf seeds from the join of its defining equation's RHS. A binding
// with a cadence pass has real work to do there. Go's obligation is narrower,
// and the one piece of §5.7.2 it can meaningfully offer a cadence pass is
// exposed rather than re-derived: ObservedDefinition (classification.go) is the
// "follow the definition out of variables[v].expression and into equations"
// step, ready for whoever builds the pass.

// TestCadenceValidFixtures asserts every tests/valid/cadence/*.esm fixture
// parses and schema-validates cleanly through the Go loader.
//
// These carry `expect_cadence` annotations on their meaningful nodes — the
// partition pass's author-assertion / diagnostic hook — which exercises the
// additive `expect_cadence` enum on ExpressionNode through the loader.
func TestCadenceValidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "cadence", "*.esm")
	files, err := filepath.Glob(pattern)
	if err != nil {
		t.Fatalf("glob %s: %v", pattern, err)
	}
	if len(files) == 0 {
		t.Fatalf("no .esm fixtures matched %s", pattern)
	}
	for _, path := range files {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			if _, err := Load(path); err != nil {
				t.Fatalf("expected %s to validate, got error: %v", name, err)
			}
		})
	}
}

// TestCadenceManifestFixturesPresent asserts that every fixture the cadence
// conformance manifest names is one this binding can load.
//
// The manifest is the cross-language index; a fixture added there and not here
// would otherwise be silently untested by Go until the shared runner happened to
// exercise it.
func TestCadenceManifestFixturesPresent(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	manifestPath := filepath.Join(repoRoot, "tests", "conformance", "cadence", "manifest.json")
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read cadence manifest: %v", err)
	}
	var manifest struct {
		Fixtures []struct {
			ID      string `json:"id"`
			Fixture string `json:"fixture"`
		} `json:"fixtures"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse cadence manifest: %v", err)
	}
	if len(manifest.Fixtures) == 0 {
		t.Fatal("cadence manifest lists no fixtures")
	}
	for _, fx := range manifest.Fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			path := fx.Fixture
			if !filepath.IsAbs(path) {
				path = filepath.Join(repoRoot, "tests", "conformance", "cadence", path)
			}
			if _, err := os.Stat(path); err != nil {
				// The manifest may name a fixture by a repo-relative path instead.
				path = filepath.Join(repoRoot, fx.Fixture)
			}
			if _, err := Load(path); err != nil {
				t.Fatalf("manifest fixture %s did not load: %v", fx.ID, err)
			}
		})
	}
}

// The observed-leaf fixture is the one §5.7.2 case that turns on the 1.0.0
// relocation, so its four discriminating unknowns are checked here through the
// §6.3.1 functions Go DOES implement — the seed inputs a cadence pass would
// consume.
//
// `geom` reads parameters only (a state-free observed, which must still fold at
// bind); `u_scaled` reads a state (CONTINUOUS); `k_scaled` reads a discrete
// parameter (DISCRETE); `geom_chain` reads another observed (transitive). What
// Go can pin without a partition pass is that each is classified as an OBSERVED
// unknown and that its defining equation is discoverable — which is exactly the
// input §5.7.2 says the seed is computed from, and the step that silently broke
// when definitions left `variables[v].expression`.
func TestObservedLeafSeedsClassification(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	file, err := Load(filepath.Join(repoRoot, "tests", "valid", "cadence", "observed_leaf_seeds.esm"))
	if err != nil {
		t.Fatalf("load observed_leaf_seeds.esm: %v", err)
	}
	model, ok := file.Models["ObservedLeafSeeds"]
	if !ok {
		t.Fatalf("model ObservedLeafSeeds missing; have %v", sortedKeys(file.Models))
	}

	observed := map[string]bool{}
	for _, name := range ObservedUnknownsIn(file, &model) {
		observed[name] = true
	}
	for _, name := range []string{"geom", "u_scaled", "k_scaled", "geom_chain"} {
		if !observed[name] {
			t.Errorf("%s must classify as an observed unknown; observed = %v",
				name, ObservedUnknownsIn(file, &model))
		}
		if _, found := ObservedDefinitionIn(file, &model, name); !found {
			t.Errorf("%s has no discoverable defining equation, so a cadence pass "+
				"could not seed it from its RHS (CONFORMANCE_SPEC 5.7.2)", name)
		}
	}

	// `Kdiff` is the discrete parameter `k_scaled` reads. Its being DISCRETE is
	// what makes k_scaled's seed differ from geom's, so the discrimination the
	// fixture exists for depends on this classification.
	if got := DiscreteParameters(&model); len(got) != 1 || got[0] != "Kdiff" {
		t.Errorf("DiscreteParameters = %v, want [Kdiff]", got)
	}
	// `u` is the state `u_scaled` reads.
	if !IsODEStateIn(file, &model, "u") {
		t.Errorf("u must be an ODE state; ode_states = %v", ODEStatesIn(file, &model))
	}
}

// A data-fed parameter's cadence turns on whether its SOURCE declares
// `temporal`, not on the parameter's own declaration (CONFORMANCE_SPEC §5.7.2,
// source-seeded refinement). The `loader_temporal_seed` / `loader_const_seed`
// pair are identical models differing only in that block, and DataSource
// exposes the distinction through HasTemporal for whatever consumes it.
func TestDataSourceTemporalSeedPair(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	cases := map[string]bool{
		"loader_temporal_seed.esm": true,  // -> stays DISCRETE
		"loader_const_seed.esm":    false, // -> refines to CONST
	}
	for fixture, wantTemporal := range cases {
		fixture, wantTemporal := fixture, wantTemporal
		t.Run(fixture, func(t *testing.T) {
			file, err := Load(filepath.Join(repoRoot, "tests", "valid", "cadence", fixture))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if len(file.DataSources) == 0 {
				t.Fatalf("%s declares no data_sources", fixture)
			}
			for name, src := range file.DataSources {
				if got := src.HasTemporal(); got != wantTemporal {
					t.Errorf("source %q HasTemporal() = %v, want %v", name, got, wantTemporal)
				}
			}
			// The consuming parameter is DISCRETE in both fixtures; only the
			// source-seeded REFINEMENT differs, and that refinement is the cadence
			// pass's business, not the classification's.
			for _, modelName := range sortedKeys(file.Models) {
				model := file.Models[modelName]
				for _, p := range DiscreteParameters(&model) {
					v := model.Variables[p]
					if len(v.Update.DataSourceKeys()) == 0 {
						continue
					}
					for _, key := range v.Update.DataSourceKeys() {
						if _, ok := file.DataSources[key]; !ok {
							t.Errorf("%s.%s names undeclared source %q", modelName, p, key)
						}
					}
				}
			}
		})
	}
}
