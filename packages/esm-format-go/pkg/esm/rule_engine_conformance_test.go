package esm

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestRuleEngineConformanceFixtures consumes
// tests/conformance/discretization/infra/rule_engine/*.json. Each
// fixture's expect.canonical_json is the byte-exact form that every
// binding's CanonicalJSON(Rewrite(input, rules)) must produce; error
// fixtures assert that the engine aborts with a specific stable code.
// Shared with the Julia and Rust conformance harnesses per RFC §13.1
// Step 1.
func TestRuleEngineConformanceFixtures(t *testing.T) {
	dir := ruleEngineFixturesDir(t)
	manifestBytes, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var manifest struct {
		Fixtures []struct {
			ID   string `json:"id"`
			Path string `json:"path"`
		} `json:"fixtures"`
	}
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	if len(manifest.Fixtures) == 0 {
		t.Fatal("manifest has no fixtures")
	}
	for _, f := range manifest.Fixtures {
		f := f
		t.Run(f.ID, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(dir, f.Path))
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			var fixture struct {
				ID        string          `json:"id"`
				Rules     json.RawMessage `json:"rules"`
				Input     json.RawMessage `json:"input"`
				MaxPasses *int            `json:"max_passes,omitempty"`
				Context   json.RawMessage `json:"context,omitempty"`
				Expect    struct {
					Kind          string `json:"kind"`
					CanonicalJSON string `json:"canonical_json,omitempty"`
					Code          string `json:"code,omitempty"`
				} `json:"expect"`
			}
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatalf("parse fixture: %v", err)
			}

			rules, err := ParseRules(fixture.Rules)
			if err != nil {
				t.Fatalf("parse rules: %v", err)
			}
			input, err := ParseExpr(fixture.Input)
			if err != nil {
				t.Fatalf("parse input: %v", err)
			}
			maxPasses := DefaultMaxPasses
			if fixture.MaxPasses != nil {
				maxPasses = *fixture.MaxPasses
			}
			ctx, err := buildFixtureContext(fixture.Context)
			if err != nil {
				t.Fatalf("build ctx: %v", err)
			}

			switch fixture.Expect.Kind {
			case "output":
				out, err := Rewrite(input, rules, ctx, maxPasses)
				if err != nil {
					t.Fatalf("fixture %s: %v", f.ID, err)
				}
				got, err := CanonicalJSON(out)
				if err != nil {
					t.Fatalf("canonicalize: %v", err)
				}
				if string(got) != fixture.Expect.CanonicalJSON {
					t.Errorf("\n   id: %s\n  got: %s\n want: %s",
						f.ID, got, fixture.Expect.CanonicalJSON)
				}
			case "error":
				_, err := Rewrite(input, rules, ctx, maxPasses)
				if err == nil {
					t.Fatalf("fixture %s: expected error %s, got nil",
						f.ID, fixture.Expect.Code)
				}
				re, ok := err.(*RuleEngineError)
				if !ok {
					t.Fatalf("fixture %s: expected *RuleEngineError, got %T: %v",
						f.ID, err, err)
				}
				if re.Code != fixture.Expect.Code {
					t.Errorf("fixture %s: got code %s, want %s",
						f.ID, re.Code, fixture.Expect.Code)
				}
			default:
				t.Fatalf("fixture %s: unknown expect.kind %q",
					f.ID, fixture.Expect.Kind)
			}
		})
	}
}

func buildFixtureContext(raw json.RawMessage) (RuleContext, error) {
	ctx := NewRuleContext()
	if len(raw) == 0 || string(raw) == "null" {
		return ctx, nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var obj struct {
		Grids      map[string]map[string]interface{} `json:"grids"`
		Variables  map[string]map[string]interface{} `json:"variables"`
		QueryPoint map[string]interface{}            `json:"query_point"`
		GridName   string                            `json:"grid_name"`
		MaskFields map[string][]map[string]interface{} `json:"mask_fields"`
	}
	if err := dec.Decode(&obj); err != nil {
		return ctx, err
	}
	for k, v := range obj.Grids {
		meta := GridMeta{}
		if arr, ok := v["spatial_dims"].([]interface{}); ok {
			meta.SpatialDims = stringSlice(arr)
		}
		if arr, ok := v["periodic_dims"].([]interface{}); ok {
			meta.PeriodicDims = stringSlice(arr)
		}
		if arr, ok := v["nonuniform_dims"].([]interface{}); ok {
			meta.NonuniformDims = stringSlice(arr)
		}
		if db, ok := v["dim_bounds"].(map[string]interface{}); ok {
			meta.DimBounds = map[string][2]int64{}
			for dim, raw := range db {
				arr, ok := raw.([]interface{})
				if !ok || len(arr) != 2 {
					continue
				}
				lo, lok := jsonToInt64(arr[0])
				hi, hok := jsonToInt64(arr[1])
				if !lok || !hok {
					continue
				}
				meta.DimBounds[dim] = [2]int64{lo, hi}
			}
		}
		if ds, ok := v["dim_sizes"].(map[string]interface{}); ok {
			meta.DimSizes = map[string]int64{}
			for dim, raw := range ds {
				n, ok := jsonToInt64(raw)
				if !ok {
					continue
				}
				meta.DimSizes[dim] = n
			}
		}
		ctx.Grids[k] = meta
	}
	for k, v := range obj.Variables {
		meta := VariableMeta{}
		if g, ok := v["grid"].(string); ok {
			meta.Grid = g
		}
		if l, ok := v["location"].(string); ok {
			meta.Location = l
		}
		if arr, ok := v["shape"].([]interface{}); ok {
			meta.Shape = stringSlice(arr)
			meta.HasShape = true
		}
		ctx.Variables[k] = meta
	}
	for k, v := range obj.QueryPoint {
		if i, ok := jsonToInt64(v); ok {
			ctx.QueryPoint[k] = i
		}
	}
	for k, pts := range obj.MaskFields {
		entries := make([]map[string]int64, 0, len(pts))
		for _, pt := range pts {
			entry := map[string]int64{}
			for axis, raw := range pt {
				if i, ok := jsonToInt64(raw); ok {
					entry[axis] = i
				}
			}
			entries = append(entries, entry)
		}
		ctx.MaskFields[k] = entries
	}
	ctx.GridName = obj.GridName
	return ctx, nil
}

func jsonToInt64(v interface{}) (int64, bool) {
	switch x := v.(type) {
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return i, true
		}
	case float64:
		if x == float64(int64(x)) {
			return int64(x), true
		}
	case int:
		return int64(x), true
	case int64:
		return x, true
	}
	return 0, false
}

func stringSlice(arr []interface{}) []string {
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		if s, ok := e.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func ruleEngineFixturesDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	pkgDir := filepath.Dir(thisFile)
	repoRoot := filepath.Join(pkgDir, "..", "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "conformance",
		"discretization", "infra", "rule_engine")
}
