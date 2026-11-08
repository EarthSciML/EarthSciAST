package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// expandGeometryRefs replaces every `apply_expression_template` reference to a
// lib/geometry.esm helper (esm-spec §9.7.3, which a binding may keep unexpanded,
// §9.6.4) by the helper's body with its bindings substituted, recursively.
func expandGeometryRefs(node any, bodies map[string]any) any {
	switch v := node.(type) {
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = expandGeometryRefs(e, bodies)
		}
		return out
	case map[string]any:
		if v["op"] == "apply_expression_template" {
			bindings := map[string]any{}
			if b, ok := v["bindings"].(map[string]any); ok {
				for k, e := range b {
					bindings[k] = expandGeometryRefs(e, bodies)
				}
			}
			return expandGeometryRefs(substituteTemplateParams(bodies[v["name"].(string)], bindings), bodies)
		}
		out := make(map[string]any, len(v))
		for k, e := range v {
			out[k] = expandGeometryRefs(e, bodies)
		}
		return out
	}
	return node
}

// TestGeometryTemplateFixturesExpand loads the documents of the
// geometry_templates conformance tier, which apply the overlap-area templates
// of lib/geometry.esm. The Go evaluator has no `faq` rule, so it cannot
// evaluate an expanded template; the test checks the expansion instead: the
// import resolves, and the `expr` of every `faq` whose body applied a template
// is that template's body with every parameter occurrence (including the
// vertex-slot counts inside the body's `faq` `ranges` bounds) replaced by the
// call's bindings (esm-spec §9.6.3 constraint 5), both sides compared with the
// library's helper references expanded.
func TestGeometryTemplateFixturesExpand(t *testing.T) {
	repo := filepath.Join(closedFunctionsFixturesDir(t), "..", "..")
	libRaw, err := os.ReadFile(filepath.Join(repo, "lib", "geometry.esm"))
	if err != nil {
		t.Fatal(err)
	}
	var library struct {
		Templates map[string]struct {
			Body any `json:"body"`
		} `json:"expression_templates"`
	}
	if err := json.Unmarshal(libRaw, &library); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		fixture, model string
		// variable -> (template, bindings) its faq body applied
		calls map[string]struct {
			name     string
			bindings map[string]any
		}
	}{
		{
			fixture: "planar_overlap.esm",
			model:   "GeometryPlanarOverlapTemplate",
			calls: map[string]struct {
				name     string
				bindings map[string]any
			}{
				"A_template": {"overlap_area_planar", map[string]any{"ring_a": "src_poly", "cell_a": "i", "nv_a": 6, "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 6}},
				"A_gated":    {"overlap_area_planar", map[string]any{"ring_a": "src_poly", "cell_a": "i", "nv_a": 6, "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 6}},
			},
		},
		{
			fixture: "spherical_fan.esm",
			model:   "GeometrySphericalFanTemplate",
			calls: map[string]struct {
				name     string
				bindings map[string]any
			}{
				"A_template": {"overlap_area_spherical", map[string]any{"ring_a": "src_xyz", "cell_a": "i", "nv_a": 4, "ring_b": "tgt_xyz", "cell_b": "j", "nv_b": 4}},
				"src_xyz":    {"lonlat_to_unit", map[string]any{"ring": "src_poly", "cell": "c", "vert": "v", "comp": "d"}},
				"tgt_xyz":    {"lonlat_to_unit", map[string]any{"ring": "tgt_poly", "cell": "c", "vert": "v", "comp": "d"}},
			},
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.fixture, func(t *testing.T) {
			path := filepath.Join(repo, "tests", "conformance", "geometry_templates", "fixtures", tc.fixture)
			file, err := LoadPath(path)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			seen := 0
			for _, eq := range file.Models[tc.model].Equations {
				lhs, ok := eq.LHS.(string)
				if !ok {
					continue
				}
				call, ok := tc.calls[lhs]
				if !ok {
					continue
				}
				seen++
				s, err := SerializeExpressionCompact(eq.RHS)
				if err != nil {
					t.Fatal(err)
				}
				var faq map[string]any
				if err := json.Unmarshal([]byte(s), &faq); err != nil {
					t.Fatal(err)
				}
				bodies := map[string]any{}
				for n, tpl := range library.Templates {
					bodies[n] = tpl.Body
				}
				want := expandGeometryRefs(jsonRoundTrip(t, substituteTemplateParams(library.Templates[call.name].Body, call.bindings)), bodies)
				if !reflect.DeepEqual(expandGeometryRefs(faq["expr"], bodies), want) {
					t.Errorf("%s: the faq body is not the substituted %s template", lhs, call.name)
				}
			}
			if seen != len(tc.calls) {
				t.Errorf("found %d of the %d template-applying equations", seen, len(tc.calls))
			}
		})
	}
}
