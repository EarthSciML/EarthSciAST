package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestDataSourceFixturesCoverage verifies that the esm 1.0.0 `data_sources`
// registry can express every data loader implemented in EarthSciData.jl (gt-mos
// coverage acceptance test).
//
// The 1.0.0 shape is the substantive change these fixtures now pin. A source is
// a document-scoped INGEST REGISTRY ENTRY: it declares no variables and no
// units. Each field it delivers is a PARAMETER of the consuming model, carrying
// `update: {kind: "data", source, from: {file_variable}}` — so the binding lives
// on the consumer, the units are declared once instead of twice, and there is no
// coupling edge to wire the field in.
//
// For each EarthSciData.jl loader, a hand-authored fixture lives under
// testdata/data_sources/<name>.esm. Each fixture must:
//  1. Schema-validate (gojsonschema + the embedded esm-schema.json).
//  2. Round-trip: parse -> serialize -> parse -> deep equal (as generic JSON).
//  3. Express the loader's field footprint from the EarthSciData.jl source, as
//     data-fed parameters of the consuming model.
func TestDataSourceFixturesCoverage(t *testing.T) {
	// Each entry corresponds to an EarthSciData.jl loader. Add new entries here
	// when new loaders land in EarthSciData.jl; the fixture file pins the schema
	// coverage for that loader.
	cases := []struct {
		name      string
		fixture   string
		sourceID  string
		kind      string
		minFields int
		// temporal records whether the source declares a `temporal` block. It is
		// not decoration: CONFORMANCE_SPEC §5.7.2 refines a data-fed parameter's
		// cadence seed by exactly this — with `temporal` it stays DISCRETE, and
		// without it folds to CONST at bind.
		temporal bool
	}{
		{"GEOSFP", "geosfp.esm", "GEOSFP_I3", "grid", 3, true},
		{"ERA5_PressureLevels", "era5.esm", "ERA5_PL", "grid", 7, true},
		{"WRF", "wrf.esm", "WRF_d01", "grid", 5, true},
		{"NEI2016Monthly", "nei2016monthly.esm", "NEI2016Monthly_ptegu", "grid", 4, true},
		{"CEDS", "ceds.esm", "CEDS_NOx", "grid", 3, true},
		{"EDGARv81Monthly", "edgar_v81_monthly.esm", "EDGAR_v81_Monthly_NOx_ENE", "grid", 1, true},
		{"USGS3DEP_Elevation", "usgs3dep.esm", "USGS3DEP_Elevation", "static", 1, false},
		{"USGS3DEP_Slopes", "usgs3dep_slopes.esm", "USGS3DEP_Slopes", "static", 2, false},
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

			src, ok := esmFile.DataSources[tc.sourceID]
			if !ok {
				t.Fatalf("fixture %s missing expected data_sources entry %q", tc.fixture, tc.sourceID)
			}
			if src.Kind != tc.kind {
				t.Errorf("source %q kind: got %q, want %q", tc.sourceID, src.Kind, tc.kind)
			}
			if src.Source.URLTemplate == "" {
				t.Errorf("source %q missing source.url_template", tc.sourceID)
			}
			if src.IsTimeVarying() != tc.temporal {
				t.Errorf("source %q IsTimeVarying = %v, want %v", tc.sourceID, src.IsTimeVarying(), tc.temporal)
			}

			// A source declares NO variables of its own: the fields arrive as
			// parameters of the consuming model, each naming this source.
			fields := 0
			for _, model := range esmFile.Models {
				for varName, v := range model.Variables {
					for _, rule := range v.UpdateRules() {
						if rule.Kind != UpdateKindData || rule.Source != tc.sourceID {
							continue
						}
						fields++
						if v.Type != VarTypeParameter {
							t.Errorf("%s: data-fed %q is declared %q, want a parameter",
								tc.fixture, varName, v.Type)
						}
						if v.Units == nil || *v.Units == "" {
							t.Errorf("%s: data-fed parameter %q declares no units — the "+
								"consumer owns them in 1.0.0", tc.fixture, varName)
						}
						if v.Shape == nil {
							t.Errorf("%s: data-fed parameter %q declares no shape; a `data` "+
								"update requires one (esm-spec §5.4)", tc.fixture, varName)
						}
						if rule.From == nil || rule.From.FileVariable == "" {
							t.Errorf("%s: parameter %q binds no file_variable", tc.fixture, varName)
						}
					}
				}
			}
			if fields < tc.minFields {
				t.Errorf("source %q: got %d data-fed parameters, want >= %d",
					tc.sourceID, fields, tc.minFields)
			}

			// 2. Structural validation must pass, which now includes
			// `data_source_undefined`: every `update.source` above resolves.
			vres := Validate(esmFile)
			if !vres.Valid {
				t.Errorf("structural validation failed for %s: %+v", tc.fixture, vres.Messages)
			}

			// 3. Round-trip: serialize, re-parse, and compare the canonicalized
			// JSON trees.
			serialized, err := ToJSON(esmFile)
			if err != nil {
				t.Fatalf("Serialize failed for %s: %v", tc.fixture, err)
			}
			roundTripped, err := LoadString(serialized)
			if err != nil {
				t.Fatalf("LoadString(ToJSON()) failed for %s: %v", tc.fixture, err)
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

// A `data` update whose `source` names no declared entry is
// `data_source_undefined` (esm-spec §8.5). This is the ONLY way left to misname
// a source — it is not a coupling endpoint any more — so it carries the whole of
// the diagnostic.
func TestDataSourceUndefinedReference(t *testing.T) {
	file, content := loadInvalidFixture(t, "data_source_undefined_reference.esm")
	result := ValidateFile(file, content)
	if !hasCode(result, ErrorDataSourceUndefined) {
		t.Errorf("want data_source_undefined: %+v", result.StructuralErrors)
	}
	if result.IsValid {
		t.Error("fixture is pinned invalid")
	}
	for _, se := range result.StructuralErrors {
		if se.Code != ErrorDataSourceUndefined {
			continue
		}
		if se.Path != "/models/TestModel/variables/external_temp/update" {
			t.Errorf("path = %q, want the update block that names the source", se.Path)
		}
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
