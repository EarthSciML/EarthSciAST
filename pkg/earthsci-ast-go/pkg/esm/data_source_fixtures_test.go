package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// data_source_fixtures_test.go is the successor to data_loader_fixtures_test.go.
// The construct it covers was renamed AND narrowed by esm 1.0.0: `data_loaders`
// became `data_sources`, and a source stopped being a component. It exposes no
// variables and is not a coupling endpoint, so the "loader's variable footprint"
// this suite used to assert has MOVED -- onto the consuming parameters, each
// carrying `update: {kind: "data", source, from: {file_variable}}` and its own
// units.
//
// The test therefore checks the footprint on the other side of the relationship
// from where it used to look, which is the whole point of the D2 change: the
// model declares what it consumes, and the source only says where bytes are.

// TestDataSourceFixturesCoverage verifies that the DataSource schema can express
// every data loader implemented in EarthSciData.jl (gt-mos coverage acceptance
// test).
//
// For each EarthSciData.jl loader, a hand-authored fixture lives under
// testdata/data_sources/<name>.esm. Each fixture must:
//  1. Schema-validate (gojsonschema + the embedded esm-schema.json).
//  2. Structurally validate, which now includes `data_source_undefined`: every
//     `update.source` in the fixture must name a declared entry.
//  3. Round-trip: parse -> serialize -> parse -> deep equal.
//  4. Express the loader's field footprint as that many data-bound parameters.
func TestDataSourceFixturesCoverage(t *testing.T) {
	// Each entry corresponds to an EarthSciData.jl loader. `minBindings` is the
	// field count the loader supplies -- asserted over the model's data-bound
	// PARAMETERS, since the source no longer lists its own variables.
	cases := []struct {
		name        string
		fixture     string
		sourceID    string
		kind        string
		minBindings int
	}{
		{"GEOSFP", "geosfp.esm", "GEOSFP_I3", "grid", 3},
		{"ERA5_PressureLevels", "era5.esm", "ERA5_PL", "grid", 7},
		{"WRF", "wrf.esm", "WRF_d01", "grid", 5},
		{"NEI2016Monthly", "nei2016monthly.esm", "NEI2016Monthly_ptegu", "grid", 4},
		{"CEDS", "ceds.esm", "CEDS_NOx", "grid", 3},
		{"EDGARv81Monthly", "edgar_v81_monthly.esm", "EDGAR_v81_Monthly_NOx_ENE", "grid", 1},
		{"USGS3DEP_Elevation", "usgs3dep.esm", "USGS3DEP_Elevation", "static", 1},
		{"USGS3DEP_Slopes", "usgs3dep_slopes.esm", "USGS3DEP_Slopes", "static", 2},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join("testdata", "data_sources", tc.fixture)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture %s: %v", path, err)
			}

			// 1. LoadString runs the embedded JSON schema check first.
			esmFile, err := LoadString(string(data))
			if err != nil {
				t.Fatalf("LoadString failed for %s: %v", tc.fixture, err)
			}

			source, ok := esmFile.DataSources[tc.sourceID]
			if !ok {
				t.Fatalf("fixture %s missing expected data_source %q", tc.fixture, tc.sourceID)
			}
			if source.Kind != tc.kind {
				t.Errorf("source %q kind: got %q, want %q", tc.sourceID, source.Kind, tc.kind)
			}
			if source.Source.URLTemplate == "" {
				t.Errorf("source %q missing source.url_template", tc.sourceID)
			}

			// 4. The field footprint, counted over the CONSUMING parameters. Each
			// must name this source, bind a file_variable, and declare its own
			// units -- the three things that moved off the source.
			bindings := 0
			for modelName, model := range esmFile.Models {
				for _, varName := range sortedKeys(model.Variables) {
					v := model.Variables[varName]
					if v.Update == nil {
						continue
					}
					for _, rule := range v.Update.Rules {
						if rule.Kind != UpdateKindData {
							continue
						}
						bindings++
						if rule.Source != tc.sourceID {
							t.Errorf("%s.%s: update.source = %q, want %q",
								modelName, varName, rule.Source, tc.sourceID)
						}
						if rule.From == nil || rule.From.FileVariable == "" {
							t.Errorf("%s.%s: a data update must bind a file_variable",
								modelName, varName)
						}
						if v.Units == nil || *v.Units == "" {
							t.Errorf("%s.%s: units live on the parameter now and are required",
								modelName, varName)
						}
						// A buffer refilled on a discrete cadence must have a known
						// extent before the first refresh.
						if !v.ShapeDeclared() {
							t.Errorf("%s.%s: a data-updated parameter must declare a shape",
								modelName, varName)
						}
					}
				}
			}
			if bindings < tc.minBindings {
				t.Errorf("source %q: got %d data-bound parameters, want >= %d",
					tc.sourceID, bindings, tc.minBindings)
			}

			// 2. Structural validation must pass.
			vres := Validate(esmFile)
			if !vres.Valid {
				t.Errorf("structural validation failed for %s: %+v", tc.fixture, vres.Messages)
			}

			// 3. Round-trip: serialize, re-parse, compare the canonicalized trees
			// as generic interface{} so map ordering and whitespace do not matter.
			serialized, err := Serialize(esmFile)
			if err != nil {
				t.Fatalf("Serialize failed for %s: %v", tc.fixture, err)
			}
			roundTripped, err := LoadString(serialized)
			if err != nil {
				t.Fatalf("LoadString(Serialize()) failed for %s: %v", tc.fixture, err)
			}
			origNorm, err := normalizeESMJSON(esmFile)
			if err != nil {
				t.Fatalf("normalize original failed: %v", err)
			}
			rtNorm, err := normalizeESMJSON(roundTripped)
			if err != nil {
				t.Fatalf("normalize round-tripped failed: %v", err)
			}
			if !reflect.DeepEqual(origNorm, rtNorm) {
				t.Errorf("round-trip produced different structure for %s", tc.fixture)
			}
		})
	}
}

// A source with a `temporal` block is time-varying and a source without one is
// not. That distinction survives the rename unchanged, and it is the whole of
// the cadence source-seed refinement (CONFORMANCE_SPEC §5.7.2): a data-fed
// parameter reading a temporal source stays DISCRETE, one reading a static
// source refines to CONST.
func TestDataSourceTemporalDiscriminates(t *testing.T) {
	cases := map[string]bool{
		"geosfp.esm":   true,  // daily files, 3-hourly records
		"era5.esm":     true,  // hourly reanalysis
		"usgs3dep.esm": false, // elevation does not change
	}
	for fixture, wantTemporal := range cases {
		t.Run(fixture, func(t *testing.T) {
			path := filepath.Join("testdata", "data_sources", fixture)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			esmFile, err := LoadString(string(data))
			if err != nil {
				t.Fatalf("LoadString: %v", err)
			}
			for name, src := range esmFile.DataSources {
				if got := src.HasTemporal(); got != wantTemporal {
					t.Errorf("source %q HasTemporal() = %v, want %v", name, got, wantTemporal)
				}
			}
		})
	}
}

// normalizeESMJSON serializes an ESMFile and reparses it as interface{} so the
// result can be compared with reflect.DeepEqual without being affected by Go
// map ordering or float representation quirks.
func normalizeESMJSON(f *ESMFile) (any, error) {
	b, err := json.Marshal(f)
	if err != nil {
		return nil, err
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	return v, nil
}
