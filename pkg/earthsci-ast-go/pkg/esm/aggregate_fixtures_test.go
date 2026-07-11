package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestAggregateValidFixtures asserts every tests/valid/aggregate/*.esm fixture
// parses and schema-validates cleanly through the Go loader. These exercise the
// additive aggregate/semiring schema deltas (op:"aggregate", the closed
// `semiring` enum, `ranges` { "from": <index-set> } references, and the
// document-scoped `index_sets` registry). Validation/round-trip only — the Go
// binding does no numeric evaluation. Cross-binding conformance bead
// ess-my4.1.5; RFC semiring-faq-unified-ir §5.1 / §5.2.
func TestAggregateValidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "aggregate", "*.esm")
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

// resolverOnlyInvalidFixtures reads tests/invalid/expected_errors.json and
// returns the set of fixture basenames flagged `resolver_only: true`. Such
// fixtures are SCHEMA-VALID but rejected only by an evaluator/resolver (e.g. an
// `aggregate` `{from}` range naming an index set absent from the registry, RFC
// semiring-faq-unified-ir §5.2). The schema-only Go binding does not run that
// resolver, so it must ACCEPT them — the invalid-fixture loop asserts schema
// acceptance for these rather than rejection. See bead ess-my4.1.6.
func resolverOnlyInvalidFixtures(t *testing.T, repoRoot string) map[string]bool {
	t.Helper()
	path := filepath.Join(repoRoot, "tests", "invalid", "expected_errors.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var entries map[string]struct {
		ResolverOnly bool `json:"resolver_only"`
	}
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	out := make(map[string]bool)
	for name, e := range entries {
		if e.ResolverOnly {
			out[name] = true
		}
	}
	return out
}

// TestAggregateInvalidFixtures asserts every tests/invalid/aggregate/*.esm
// fixture is handled correctly. Pure schema violations (unregistered semiring,
// ragged index set missing offsets/values, discrete variable missing shape,
// join not an array, join `on` pair wrong arity, refresh on a non-discrete
// variable) are REJECTED — Load returns a non-nil error at schema-validation
// time. Fixtures flagged `resolver_only` in expected_errors.json are
// SCHEMA-VALID and rejected only by an evaluating binding's resolver; the
// schema-only Go binding must ACCEPT those (Load returns nil).
func TestAggregateInvalidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	resolverOnly := resolverOnlyInvalidFixtures(t, repoRoot)
	pattern := filepath.Join(repoRoot, "tests", "invalid", "aggregate", "*.esm")
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
			if resolverOnly[name] {
				// Schema-valid; rejected only by a resolver the schema-only Go
				// binding does not run. Load must ACCEPT it.
				if _, err := Load(path); err != nil {
					t.Fatalf("resolver-only fixture %s must pass schema validation, got error: %v", name, err)
				}
				return
			}
			if _, err := Load(path); err == nil {
				t.Fatalf("expected %s to be rejected, but it validated", name)
			}
		})
	}
}

// TestIndexSetsDocumentScopeRoundTrip pins the v0.8.0 relocation of the
// `index_sets` registry from a per-Model field to document scope
// (RFC semiring-faq-unified-ir §5.2). It asserts that (a) the loader parses the
// registry onto the top-level ESMFile.IndexSets field, (b) no model carries an
// index_sets field, and (c) the registry survives a load → save → load → save
// cycle at document scope, idempotently. Covers the four kinds that appear in
// the shared corpus (interval, categorical, derived).
func TestIndexSetsDocumentScopeRoundTrip(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	cases := []struct {
		rel      string
		wantKeys map[string]string // index-set name -> expected kind
	}{
		{
			rel:      filepath.Join("tests", "valid", "aggregate", "aggregate_semiring_indexset.esm"),
			wantKeys: map[string]string{"cells": "interval", "county": "categorical"},
		},
		{
			rel:      filepath.Join("tests", "valid", "geometry", "conservative_regrid_overlap_join.esm"),
			wantKeys: map[string]string{"src_cells": "interval", "candidate_pairs": "derived", "clip_ring": "derived"},
		},
	}

	for _, tc := range cases {
		t.Run(filepath.Base(tc.rel), func(t *testing.T) {
			path := filepath.Join(repoRoot, tc.rel)

			esmFile, err := Load(path)
			if err != nil {
				t.Fatalf("load %s: %v", tc.rel, err)
			}

			// (a) Registry parsed onto the top-level document field.
			if len(esmFile.IndexSets) == 0 {
				t.Fatalf("expected document-scoped IndexSets to be populated, got empty")
			}
			for name, wantKind := range tc.wantKeys {
				set, ok := esmFile.IndexSets[name]
				if !ok {
					t.Fatalf("index set %q missing from document registry", name)
				}
				if set.Kind != wantKind {
					t.Errorf("index set %q kind: got %q, want %q", name, set.Kind, wantKind)
				}
				switch wantKind {
				case "interval":
					if set.Size == nil {
						t.Errorf("interval index set %q missing size", name)
					}
				case "categorical":
					if len(set.Members) == 0 {
						t.Errorf("categorical index set %q missing members", name)
					}
				case "derived":
					if set.FromFAQ == nil || *set.FromFAQ == "" {
						t.Errorf("derived index set %q missing from_faq", name)
					}
				}
			}

			// (b) No model carries an index_sets field (document scope only).
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", tc.rel, err)
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				t.Fatalf("unmarshal fixture %s: %v", tc.rel, err)
			}
			if models, ok := raw["models"].(map[string]any); ok {
				for mn, mv := range models {
					if m, ok := mv.(map[string]any); ok {
						if _, bad := m["index_sets"]; bad {
							t.Errorf("model %q still carries a model-scoped index_sets field", mn)
						}
					}
				}
			}

			// (c) Registry survives serialize → re-parse → serialize, at
			// document scope, idempotently. The re-parse uses FromJSON
			// (json.Unmarshal + struct validation) rather than LoadString so
			// this stays focused on the index_sets scope change: these fixtures
			// carry `aggregate` / `intersect_polygon` op nodes whose required
			// fields (output_idx/expr/ranges/manifold) the Go ExprNode does not
			// yet serialize (a pre-existing gap, see indexing_roundtrip_test.go),
			// so a full schema-validating LoadString of the re-serialized file
			// would fail for reasons unrelated to index_sets.
			out1, err := esmFile.ToJSON()
			if err != nil {
				t.Fatalf("first serialize: %v", err)
			}
			var doc1 map[string]any
			if err := json.Unmarshal(out1, &doc1); err != nil {
				t.Fatalf("unmarshal out1: %v", err)
			}
			iset1, ok := doc1["index_sets"].(map[string]any)
			if !ok || len(iset1) == 0 {
				t.Fatalf("top-level index_sets missing from serialized output")
			}
			if models, ok := doc1["models"].(map[string]any); ok {
				for mn, mv := range models {
					if m, ok := mv.(map[string]any); ok {
						if _, has := m["index_sets"]; has {
							t.Errorf("serialized model %q must not carry index_sets", mn)
						}
					}
				}
			}

			reparsed, err := FromJSON(out1)
			if err != nil {
				t.Fatalf("re-parse serialized output: %v", err)
			}
			if !reflect.DeepEqual(esmFile.IndexSets, reparsed.IndexSets) {
				t.Fatalf("IndexSets not preserved across re-parse:\n first: %+v\nsecond: %+v",
					esmFile.IndexSets, reparsed.IndexSets)
			}
			out2, err := reparsed.ToJSON()
			if err != nil {
				t.Fatalf("second serialize: %v", err)
			}
			var doc2 map[string]any
			if err := json.Unmarshal(out2, &doc2); err != nil {
				t.Fatalf("unmarshal out2: %v", err)
			}
			if !reflect.DeepEqual(doc1["index_sets"], doc2["index_sets"]) {
				t.Fatalf("index_sets round-trip not idempotent:\n first: %v\nsecond: %v",
					doc1["index_sets"], doc2["index_sets"])
			}
		})
	}
}
