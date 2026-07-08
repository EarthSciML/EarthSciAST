package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestDataLoaderFixturesCoverage verifies that the new STAC-like DataLoader
// schema can express every data loader currently implemented in EarthSciData.jl
// (gt-mos coverage acceptance test).
//
// For each EarthSciData.jl loader, a hand-authored fixture lives under
// testdata/data_loaders/<name>.esm. Each fixture must:
//  1. Schema-validate (gojsonschema + the embedded esm-schema.json).
//  2. Round-trip: parse -> serialize -> parse -> deep equal (as json.RawMessage).
//  3. Express the loader's parameter footprint from the EarthSciData.jl source.
func TestDataLoaderFixturesCoverage(t *testing.T) {
	// Each entry corresponds to an EarthSciData.jl loader. Add new entries here
	// when new loaders land in EarthSciData.jl; the fixture file pins the schema
	// coverage for that loader.
	cases := []struct {
		name     string
		fixture  string
		loaderID string
		kind     string
		minVars  int
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
			path := filepath.Join("testdata", "data_loaders", tc.fixture)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture %s: %v", path, err)
			}

			// 1. LoadString runs the embedded JSON schema check first.
			esmFile, err := LoadString(string(data))
			if err != nil {
				t.Fatalf("LoadString failed for %s: %v", tc.fixture, err)
			}

			loader, ok := esmFile.DataLoaders[tc.loaderID]
			if !ok {
				t.Fatalf("fixture %s missing expected data_loader %q", tc.fixture, tc.loaderID)
			}
			if loader.Kind != tc.kind {
				t.Errorf("loader %q kind: got %q, want %q", tc.loaderID, loader.Kind, tc.kind)
			}
			if loader.Source.URLTemplate == "" {
				t.Errorf("loader %q missing source.url_template", tc.loaderID)
			}
			if got := len(loader.Variables); got < tc.minVars {
				t.Errorf("loader %q: got %d variables, want >= %d", tc.loaderID, got, tc.minVars)
			}
			for varName, v := range loader.Variables {
				if v.FileVariable == "" {
					t.Errorf("loader %q variable %q missing file_variable", tc.loaderID, varName)
				}
				if v.Units == "" {
					t.Errorf("loader %q variable %q missing units", tc.loaderID, varName)
				}
			}

			// 2. Structural validation must pass (no errors for required fields).
			vres := Validate(esmFile)
			if !vres.Valid {
				t.Errorf("structural validation failed for %s: %+v", tc.fixture, vres.Messages)
			}

			// 3. Round-trip: serialize, re-parse, and compare the canonicalized
			// JSON trees. We compare via json.Unmarshal into generic interface{}
			// so that map key ordering and whitespace don't matter.
			serialized, err := Save(esmFile)
			if err != nil {
				t.Fatalf("Save failed for %s: %v", tc.fixture, err)
			}
			roundTripped, err := LoadString(serialized)
			if err != nil {
				t.Fatalf("LoadString(Save()) failed for %s: %v", tc.fixture, err)
			}
			origNorm, err := normalizeEsmJSON(esmFile)
			if err != nil {
				t.Fatalf("normalize original failed: %v", err)
			}
			rtNorm, err := normalizeEsmJSON(roundTripped)
			if err != nil {
				t.Fatalf("normalize round-tripped failed: %v", err)
			}
			if !reflect.DeepEqual(origNorm, rtNorm) {
				t.Errorf("round-trip produced different structure for %s", tc.fixture)
			}
		})
	}
}

// normalizeEsmJSON serializes an EsmFile and reparses it as interface{} so the
// result can be compared with reflect.DeepEqual without being affected by Go
// map ordering or float representation quirks.
func normalizeEsmJSON(f *EsmFile) (interface{}, error) {
	b, err := json.Marshal(f)
	if err != nil {
		return nil, err
	}
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	return v, nil
}
