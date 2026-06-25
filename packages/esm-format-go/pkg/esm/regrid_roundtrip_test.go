package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestRegridPointMissingValueRoundtrip verifies that the per-variable
// regrid / missing_value config slot (RFC pure-io-data-loaders §5.2, §6;
// ess-v9a.6) parses into the typed Model.Regrid map and survives a
// load -> ToJSON round-trip losslessly.
func TestRegridPointMissingValueRoundtrip(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "tests", "valid", "regrid_point_missing_value.esm"))
	if err != nil {
		t.Fatal(err)
	}

	f, err := LoadString(string(raw))
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	spec, ok := f.Models["OpenAQCoupler"].Regrid["PM2_5"]
	if !ok {
		t.Fatal("regrid['PM2_5'] missing after parse")
	}
	if spec.Method == nil || *spec.Method != "cell_average" {
		t.Fatalf("method: want cell_average, got %v", spec.Method)
	}
	if spec.MissingValue == nil || *spec.MissingValue != -999.0 {
		t.Fatalf("missing_value: want -999.0, got %v", spec.MissingValue)
	}

	out, err := f.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON: %v", err)
	}
	var in, rt map[string]interface{}
	if err := json.Unmarshal(raw, &in); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(out), &rt); err != nil {
		t.Fatal(err)
	}
	inRegrid := in["models"].(map[string]interface{})["OpenAQCoupler"].(map[string]interface{})["regrid"]
	rtRegrid := rt["models"].(map[string]interface{})["OpenAQCoupler"].(map[string]interface{})["regrid"]
	if !reflect.DeepEqual(inRegrid, rtRegrid) {
		t.Fatalf("regrid not preserved on round-trip:\n in=%v\nout=%v", inRegrid, rtRegrid)
	}
}
