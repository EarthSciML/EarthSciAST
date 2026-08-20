package esm

// Tests for ResolveAndLowerReferencePreserving — the raw §9.7 pipeline stopped
// at the Option-B image (esm-spec §9.6.4 rules 4 and 5), which is the artifact
// shape the Julia reference, Python, TypeScript and Rust all produce and the
// one an external conformance runner must drive to be comparable with them.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// rpCount counts the nodes under `node` that either carry the object key `key`
// (when non-empty) or are an expression node whose `op` is `op`.
func rpCount(node any, key, op string) int {
	n := 0
	switch v := node.(type) {
	case map[string]any:
		if key != "" {
			if _, ok := v[key]; ok {
				n++
			}
		}
		if op != "" {
			if got, _ := v["op"].(string); got == op {
				n++
			}
		}
		for _, c := range v {
			n += rpCount(c, key, op)
		}
	case []any:
		for _, c := range v {
			n += rpCount(c, key, op)
		}
	}
	return n
}

func rpDecode(t *testing.T, doc string) map[string]any {
	t.Helper()
	var v map[string]any
	if err := json.Unmarshal([]byte(doc), &v); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return v
}

// The two surfaces are ONE pipeline that differs only in its last step:
// ResolveAndLower is ResolveAndLowerReferencePreserving followed by Expand.
// If this ever diverges, the Option-A and Option-B images of the same document
// disagree and the expanded goldens stop meaning what the reference-preserving
// artifact says.
func TestReferencePreserving_ExpandEqualsFused(t *testing.T) {
	// Every group whose fixture loads AND leaves at least one surviving
	// reference, so the two forms genuinely differ before Expand.
	for _, group := range []string{
		"import_smoke",
		"import_diamond",
		"import_rename_two_instances",
		"import_rename_diamond",
		"emit_materialized_registry",
		"emit_rename_dotted_keys",
		"arrhenius_smoke",
		"scalar_field_param",
		"opacity_priority_shadowing",
		"eager_target_bearing",
		"coupling_transform_expression",
	} {
		t.Run(group, func(t *testing.T) {
			path := tiConfDir(t, group, "fixture.esm")
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			base := filepath.Dir(path)

			kept, err := ResolveAndLowerReferencePreserving(string(data), base, nil)
			if err != nil {
				t.Fatalf("ResolveAndLowerReferencePreserving: %v", err)
			}
			fused, err := ResolveAndLower(string(data), base, nil)
			if err != nil {
				t.Fatalf("ResolveAndLower: %v", err)
			}

			keptView := rpDecode(t, kept)

			// Non-vacuity: the reference-preserving form must actually preserve
			// something the fused form destroys.
			refs := rpCount(keptView, "", "apply_expression_template")
			regs := rpCount(keptView, "expression_templates", "")
			if refs == 0 {
				t.Fatalf("no surviving reference — this group cannot distinguish the two forms")
			}
			if regs == 0 {
				t.Errorf("surviving references but no retained registry: an expanded-away registry leaves the references undefinable (§9.6.4 rule 5)")
			}
			fusedView := rpDecode(t, fused)
			if got := rpCount(fusedView, "", "apply_expression_template"); got != 0 {
				t.Errorf("ResolveAndLower left %d unexpanded reference(s); it is the Option-A surface", got)
			}
			if got := rpCount(fusedView, "expression_templates", ""); got != 0 {
				t.Errorf("ResolveAndLower left %d registry/registries; Expand strips them", got)
			}

			if got, want := tiCanonJSON(t, Expand(keptView)), tiCanonJSON(t, fusedView); got != want {
				t.Errorf("Expand(reference-preserving) != ResolveAndLower:\n got=%s\nwant=%s", got, want)
			}
		})
	}
}

// A negative fixture must fail on the reference-preserving path too: stopping
// before Expand skips no validation. Each of these is rejected by a different
// stage — the import resolver, the rewrite fixpoint, and the §9.6.9 call-site
// check respectively.
func TestReferencePreserving_RejectsInvalidFixtures(t *testing.T) {
	for _, tc := range []struct{ group, code string }{
		{"constraint_unknown_index_set", "template_constraint_unknown_index_set"},
		{"import_where_rename_unknown_index_set", "template_constraint_unknown_index_set"},
		{"nonterminating_rewrite", "rewrite_rule_nonterminating"},
		{"per_instantiation_validation", "geometry_manifold_invalid"},
	} {
		t.Run(tc.group, func(t *testing.T) {
			path := tiConfDir(t, tc.group, "fixture.esm")
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			_, err = ResolveAndLowerReferencePreserving(string(data), filepath.Dir(path), nil)
			if err == nil {
				t.Fatalf("expected %s, got no error", tc.code)
			}
			if got := tiErrCode(t, err); got != tc.code {
				t.Errorf("expected %s, got %s", tc.code, got)
			}
		})
	}
}
