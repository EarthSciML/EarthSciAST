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

// resolverOnlyPins reads tests/invalid/expected_errors.json and returns, for
// every fixture basename flagged `resolver_only: true`, its pinned
// `resolver_error_code` (the empty string when the pin names none). Such
// fixtures are SCHEMA-VALID by construction and are rejected only by a
// post-schema check — never by JSON-Schema validation.
//
// `resolver_only` says WHERE the defect is caught, not WHETHER Go catches it.
// The two cases split on whether the Go binding implements the check:
//
//   - Checks Go does NOT run — an evaluator/resolver concern such as an
//     `aggregate` `{from}` range naming an index set absent from the registry
//     (RFC semiring-faq-unified-ir §5.2). Go must ACCEPT these (Load returns
//     nil); see TestAggregateInvalidFixtures and bead ess-my4.1.6.
//   - Checks Go DOES run — the §9.6.4 post-expansion validators, e.g. the
//     closed-set `manifold` enum. Go must REJECT these, carrying exactly the
//     pinned code; see TestGeometryInvalidFixtures.
func resolverOnlyPins(t *testing.T, repoRoot string) map[string]string {
	t.Helper()
	path := filepath.Join(repoRoot, "tests", "invalid", "expected_errors.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var entries map[string]struct {
		ResolverOnly bool   `json:"resolver_only"`
		ResolverCode string `json:"resolver_error_code"`
	}
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	out := make(map[string]string)
	for name, e := range entries {
		if e.ResolverOnly {
			out[name] = e.ResolverCode
		}
	}
	return out
}

// TestAggregateInvalidFixtures asserts every tests/invalid/aggregate/*.esm
// fixture is handled correctly, keyed off its pin in expected_errors.json. Three
// contracts, per the promoted-pin split (Phase 3 F-6):
//
//   - Pure schema violations (unregistered semiring, ragged index set missing
//     offsets/values, discrete variable missing shape, join not an array, join
//     `on` pair wrong arity, refresh on a non-discrete variable) carry a
//     `schema_errors` pin and are REJECTED at Load (schema validation fails).
//   - STRUCTURAL fixtures carry a `structural_errors` pin and NO schema error:
//     they are SCHEMA-VALID (Load succeeds) but validate() must reject them with
//     the pinned (code, path). The two F-6 checks in this directory —
//     undefined_index_set and relational_node_in_continuous — were promoted from
//     `resolver_only` to structural pins here.
//   - `resolver_only` fixtures (if any remain) are schema-valid and rejected
//     only by an evaluating binding's resolver; the schema-only Go binding must
//     ACCEPT them (Load returns nil, validate() stays clean).
func TestAggregateInvalidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pins := loadExpectedPins(t, repoRoot)
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
			pin := pins[name]
			switch {
			case pin.ResolverOnly:
				// Schema-valid; rejected only by a resolver the schema-only Go
				// binding does not run. Load must ACCEPT it.
				if _, err := Load(path); err != nil {
					t.Fatalf("resolver-only fixture %s must pass schema validation, got error: %v", name, err)
				}
			case len(pin.SchemaErrors) > 0:
				// Schema violation: rejected at Load (schema validation).
				if _, err := Load(path); err == nil {
					t.Fatalf("expected %s to be rejected at schema validation, but it validated", name)
				}
			default:
				// Schema-valid but structurally invalid: Load succeeds, validate()
				// rejects with the pinned (code, path).
				assertStructuralRejection(t, path, name, pin)
			}
		})
	}
}

// assertStructuralRejection asserts a SCHEMA-VALID fixture loads cleanly yet
// validate() rejects it (IsValid=false) with every pinned structural (code,
// path) present in the emitted structural errors.
func assertStructuralRejection(t *testing.T, path, name string, pin expectedPin) {
	t.Helper()
	file, err := Load(path)
	if err != nil {
		t.Fatalf("structural fixture %s must pass schema validation, got error: %v", name, err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	result := ValidateFile(file, string(raw))
	if result.IsValid {
		t.Fatalf("expected %s to be rejected by validate(), but it was reported valid", name)
	}
	got := make(map[[2]string]bool)
	for _, se := range result.StructuralErrors {
		got[[2]string{se.Code, se.Path}] = true
	}
	for _, want := range pin.StructuralErrors {
		if !got[[2]string{want.Code, want.Path}] {
			t.Fatalf("expected %s to emit structural error (code=%q, path=%q); got %v",
				name, want.Code, want.Path, result.StructuralErrors)
		}
	}
}

// expectedPin is the subset of an expected_errors.json entry the aggregate
// fixture tests read: whether the fixture is resolver-only, and its pinned
// schema / structural findings.
type expectedPin struct {
	ResolverOnly bool `json:"resolver_only"`
	ParseError   bool `json:"parse_error"`
	SchemaErrors []struct {
		Path    string `json:"path"`
		Keyword string `json:"keyword"`
	} `json:"schema_errors"`
	StructuralErrors []struct {
		Path string `json:"path"`
		Code string `json:"code"`
	} `json:"structural_errors"`
}

// loadExpectedPins reads tests/invalid/expected_errors.json into the expectedPin
// view keyed by fixture basename.
func loadExpectedPins(t *testing.T, repoRoot string) map[string]expectedPin {
	t.Helper()
	path := filepath.Join(repoRoot, "tests", "invalid", "expected_errors.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var pins map[string]expectedPin
	if err := json.Unmarshal(data, &pins); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return pins
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
