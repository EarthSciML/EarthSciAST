package esm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Round-trip FIDELITY: `save(load(F))` compared against **F itself**.
//
// This is deliberately a different shape from the round-trip test that already
// existed (tests_analyses_roundtrip_test.go), which compares pass 2 against
// pass 3 — `save(load(F))` vs `save(load(save(load(F))))`. That comparison is
// IDEMPOTENCE, and it is blind to exactly the defect class this file exists to
// catch: a field the loader never models is dropped identically on both passes,
// so the two outputs agree perfectly while the authored content is gone. Every
// drop fixed alongside this file (`Equation._comment` on 48 fixtures, the whole
// reaction-system `Parameter.update` block, the top-level `coordinates`
// registry, `metadata.x_esd`) was invisible to the idempotence test and stayed
// invisible for as long as it was the only round-trip gate. The cross-binding
// conformance gate compares a binding against itself the same way.
//
// So: load each corpus fixture, save it, and diff the saved document against
// the ORIGINAL FILE. Anything dropped, added, or altered is a failure unless it
// is a load-time transform this binding performs BY DESIGN, in which case the
// fixture is named in transformingFixtures with the transform that excuses it.

// jsonDiff collects the differences between two decoded JSON documents as
// JSON-pointer-style paths. Object keys and array elements compare exactly,
// with one deliberate exception: numbers compare by MATHEMATICAL VALUE, not by
// spelling — the same tolerance, and for the same reason, as `value_diff` in
// pkg/earthsci-ast-rs/tests/round_trip.rs. The canonical-number rule
// (CONFORMANCE_SPEC.md §5.5.3.1 rule 1) is implemented at the settled sites but
// not yet at every typed float field in every binding, and their spellings still
// diverge. Comparing by value keeps this test honest about STRUCTURE and
// CONTENT — which is what a dropped field is — without going red on a spelling
// difference that is being closed separately.
//
// Both documents must be decoded with a json.Decoder in UseNumber mode, so a
// large integer is not first mangled into a float64 by the comparison itself.
func jsonDiff(path string, want, got any, out *[]string) {
	const maxDiffs = 25
	if len(*out) >= maxDiffs {
		return
	}
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			*out = append(*out, fmt.Sprintf("%s: object -> %T", path, got))
			return
		}
		for _, k := range diffSortedKeys(w) {
			if gv, ok := g[k]; ok {
				jsonDiff(path+"/"+k, w[k], gv, out)
			} else {
				*out = append(*out, fmt.Sprintf("%s/%s: DROPPED (was %s)", path, k, briefJSON(w[k])))
			}
		}
		for _, k := range diffSortedKeys(g) {
			if _, ok := w[k]; !ok {
				*out = append(*out, fmt.Sprintf("%s/%s: ADDED (%s)", path, k, briefJSON(g[k])))
			}
		}
	case []any:
		g, ok := got.([]any)
		if !ok {
			*out = append(*out, fmt.Sprintf("%s: array -> %T", path, got))
			return
		}
		if len(w) != len(g) {
			*out = append(*out, fmt.Sprintf("%s: array len %d -> %d", path, len(w), len(g)))
		}
		n := len(w)
		if len(g) < n {
			n = len(g)
		}
		for i := 0; i < n; i++ {
			jsonDiff(fmt.Sprintf("%s/%d", path, i), w[i], g[i], out)
		}
	case json.Number:
		g, ok := got.(json.Number)
		if !ok {
			*out = append(*out, fmt.Sprintf("%s: number -> %T", path, got))
			return
		}
		wf, err1 := w.Float64()
		gf, err2 := g.Float64()
		if err1 != nil || err2 != nil || wf != gf {
			*out = append(*out, fmt.Sprintf("%s: %v -> %v", path, w, g))
		}
	case nil:
		if got != nil {
			*out = append(*out, fmt.Sprintf("%s: null -> %s", path, briefJSON(got)))
		}
	default:
		if want != got {
			*out = append(*out, fmt.Sprintf("%s: %s -> %s", path, briefJSON(want), briefJSON(got)))
		}
	}
}

func diffSortedKeys(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// brief renders a value for a diff message, truncated so one oversized subtree
// cannot bury the rest of the report.
func briefJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	if len(b) > 120 {
		return string(b[:117]) + "..."
	}
	return string(b)
}

// decodeJSONNumbers decodes JSON text with numeric literals preserved as
// json.Number, so jsonDiff can compare them by value without a float64 detour.
func decodeJSONNumbers(t *testing.T, label string, text []byte) any {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(string(text)))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("%s: decode: %v", label, err)
	}
	return v
}

// transformingFixtures are the corpus fixtures this binding deliberately
// TRANSFORMS at load, so `save(load(F))` is legitimately not F. Each entry names
// the transform. This list is an admission of designed behaviour, not of
// unfixed drops — do not add a fixture here to silence a real one.
var transformingFixtures = map[string]string{
	// Eager `apply_expression_template` expansion (esm-spec §9.6, Option A):
	// call sites are expanded at load and the component's own
	// `expression_templates` / `expression_template_imports` blocks are
	// consumed, so the emitted equations are the expanded ones.
	"advection_reaction_loaded_ic_bc.esm":       "eager expression-template expansion",
	"derivative_trailing_boundary_operands.esm": "eager expression-template expansion",
	"expression_templates_arrhenius.esm":        "eager expression-template expansion",
	"template_import_minimal.esm":               "template-library import + eager expansion",

	// Metaparameter close+fold (esm-spec §9.7.1): symbolic extents such as
	// `"size": "N"` are folded to their integer values at load.
	"data_sources_ingest_and_select.esm":    "metaparameter folding (N_REC/N_POP/N_SRC -> integers)",
	"makearray_empty_region_min_extent.esm": "metaparameter folding (N -> integer)",
	"template_import_lib.esm":               "metaparameter folding (N -> integer)",
	"template_import_rename_lib.esm":        "metaparameter folding (M -> integer)",

	// Subsystem `{"ref": ...}` resolution: the mount is replaced in place by
	// the referenced file's spliced-in variables and equations.
	"lib_calendar_subsystem_inclusion.esm": "subsystem ref resolution",
	"lib_solar_subsystem_inclusion.esm":    "subsystem ref resolution",
	"subsystem_index_set_merge.esm":        "subsystem ref resolution + index_sets merge",

	// Enum lowering (esm-spec §9.3): `enum` op nodes are resolved to `const`
	// integers at load time.
	"enums_categorical_lookup.esm": "enum lowering to const",

	// The v0.5.0 inline multi-series shorthand: an array-form `plots[].y` is
	// normalized at load into a canonical single `y` plus a `series` list
	// (Plot.UnmarshalJSON).
	"tests_analyses_comprehensive.esm": "array-form plots[].y normalized to y + series",
}

// emptyEventListExempt reports whether a diff is the one drop this test
// knowingly tolerates: an AUTHORED-EMPTY `discrete_events` / `continuous_events`
// array re-emitted as an absent key.
//
// Both are `omitempty` plain slices on Model / ReactionSystem, so `[]` and
// "absent" are the same Go value and cannot be told apart on the way out. The
// distinction is invisible to the schema too — neither key is required, and an
// empty list and a missing list mean the same thing to every consumer — so
// unlike `Parameter.shape` (which esm-spec §5.4 REQUIRES on a schedule/data/
// remesh parameter, making a dropped `[]` a schema-INVALID re-emission) this
// costs no correctness. Separating them would mean turning both fields into
// pointer-to-slice across Model, ReactionSystem, and every site that reads them,
// for no semantic gain; it is recorded here rather than done.
//
// The exemption is deliberately narrow — these two keys, and only when the
// authored value was an empty array — so that a future drop of a genuinely
// meaningful empty container still fails.
func emptyEventListExempt(diff string, original any) bool {
	path, rest, ok := strings.Cut(diff, ": ")
	if !ok || !strings.HasPrefix(rest, "DROPPED") {
		return false
	}
	key := path[strings.LastIndexByte(path, '/')+1:]
	if key != "discrete_events" && key != "continuous_events" {
		return false
	}
	return strings.HasSuffix(rest, "(was [])")
}

// TestCorpusRoundTripIsLossless is the fidelity gate: for every fixture under
// tests/valid, `save(load(F))` must reproduce F.
func TestCorpusRoundTripIsLossless(t *testing.T) {
	root := validFixtureRoot(t)
	var paths []string
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(p, ".esm") {
			paths = append(paths, p)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", root, err)
	}
	if len(paths) == 0 {
		t.Fatalf("no fixtures found under %s", root)
	}
	sort.Strings(paths)

	for _, path := range paths {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			if why, skip := transformingFixtures[name]; skip {
				t.Skipf("load-time transform by design: %s", why)
			}
			authored, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read: %v", err)
			}
			// LoadPath, not LoadString: relative `ref` and template-library
			// paths resolve against the fixture's own directory.
			file, err := LoadPath(path)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			saved, err := file.ToJSON()
			if err != nil {
				t.Fatalf("save: %v", err)
			}

			want := decodeJSONNumbers(t, "authored", authored)
			got := decodeJSONNumbers(t, "saved", saved)

			var diffs []string
			jsonDiff("", want, got, &diffs)

			var real []string
			for _, d := range diffs {
				if !emptyEventListExempt(d, want) {
					real = append(real, d)
				}
			}
			if len(real) > 0 {
				t.Errorf("save(load(F)) differs from F in %d place(s):\n  %s",
					len(real), strings.Join(real, "\n  "))
			}
		})
	}
}

func validFixtureRoot(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(repoRoot, "tests", "valid")
}

func repoFile(t *testing.T, parts ...string) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(append([]string{repoRoot}, parts...)...)
}

// TestRoundTripPreservesEquationComment pins the dominant drop: `_comment` was
// absent from the Equation struct, so every equation annotation in every
// document edited through this binding was deleted — 48 of the 94 corpus
// fixtures carry at least one.
func TestRoundTripPreservesEquationComment(t *testing.T) {
	path := repoFile(t, "tests", "valid", "aggregate", "min_sum_tropical.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	eq := file.Models["MinSumTropical"].Equations[0]
	if eq.Comment == nil {
		t.Fatalf("_comment did not survive parse")
	}
	if !strings.Contains(*eq.Comment, "tropical") && !strings.Contains(*eq.Comment, "min_") {
		t.Logf("comment text: %q", *eq.Comment)
	}
	saved, err := file.ToJSON()
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if !strings.Contains(string(saved), *eq.Comment) {
		t.Errorf("_comment did not survive emit")
	}

	// It must also ride through a substitution rebuild, which constructs new
	// Equation values rather than mutating the old ones in place.
	sub, err := SubstituteInEquation(eq, map[string]Expression{"nothing": 1.0})
	if err != nil {
		t.Fatalf("substitute: %v", err)
	}
	if sub.Comment == nil || *sub.Comment != *eq.Comment {
		t.Errorf("_comment lost through SubstituteInEquation: %v", sub.Comment)
	}
}

// TestRoundTripPreservesReactionParameterUpdate pins the semantic drop: a
// reaction-system Parameter modelled only units/default/description, so its
// `update` block — the ONLY channel binding a parameter to a data source
// (esm-spec §5.4) — vanished, silently converting a data-driven parameter into
// a constant held at its `default`. Its `shape` vanished with it, which alone
// re-emitted a schema-INVALID document (§5.4 REQUIRES `shape` on a `data`
// parameter).
func TestRoundTripPreservesReactionParameterUpdate(t *testing.T) {
	path := repoFile(t, "tests", "valid", "minimal_chemistry.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	p := file.ReactionSystems["SimpleOzone"].Parameters["T"]
	rules := p.UpdateRules()
	if len(rules) != 1 {
		t.Fatalf("update rules: got %d, want 1", len(rules))
	}
	if rules[0].Kind != UpdateKindData {
		t.Errorf("update kind: got %q, want %q", rules[0].Kind, UpdateKindData)
	}
	if rules[0].Source != "GEOSFP" {
		t.Errorf("update source: got %q, want %q", rules[0].Source, "GEOSFP")
	}
	if rules[0].From == nil || rules[0].From.FileVariable != "T" {
		t.Errorf("update from: %+v", rules[0].From)
	}
	// An authored `"shape": []` must survive as the key, not vanish: the
	// pointer is non-nil and the slice is empty.
	if p.Shape == nil {
		t.Errorf("authored empty shape collapsed to an absent key")
	} else if len(*p.Shape) != 0 {
		t.Errorf("shape: got %v, want []", *p.Shape)
	}

	saved, err := file.ToJSON()
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	reloaded, err := LoadString(string(saved))
	if err != nil {
		t.Fatalf("reload emitted document: %v", err)
	}
	if !reloaded.ReactionSystems["SimpleOzone"].Parameters["T"].HasUpdate() {
		t.Errorf("update did not survive the emit + reload")
	}
}

// TestRoundTripPreservesCoordinates pins the top-level `coordinates` registry
// (RFC streaming-output-sinks §8), for which ESMFile modelled no field at all —
// so the CF metadata naming which arrays are latitude/longitude was deleted
// wholesale by a load → save.
func TestRoundTripPreservesCoordinates(t *testing.T) {
	path := repoFile(t, "tests", "valid", "coordinates_registry.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(file.Coordinates) == 0 {
		t.Fatalf("coordinates registry did not survive parse")
	}
	// grid_lon is the inline-literal form; level is the `source` form.
	lon, ok := file.Coordinates["grid_lon"]
	if !ok {
		t.Fatalf("grid_lon missing; got %v", sortedCoordNames(file.Coordinates))
	}
	if len(lon.Values) != 4 {
		t.Errorf("grid_lon values: got %v, want 4 entries", lon.Values)
	}
	if lon.Axis == nil || *lon.Axis != "X" {
		t.Errorf("grid_lon axis: %v", lon.Axis)
	}
	if lon.StandardName == nil || *lon.StandardName != "longitude" {
		t.Errorf("grid_lon standard_name: %v", lon.StandardName)
	}
	lev, ok := file.Coordinates["level"]
	if !ok || lev.Source == nil || *lev.Source != "lev_pressure" {
		t.Errorf("level source: %+v", lev)
	}
	// An auxiliary coordinate declares no `axis`; the key must stay absent
	// rather than being emitted as an empty string the schema's enum rejects.
	cell, ok := file.Coordinates["cell_lat"]
	if !ok || cell.Axis != nil {
		t.Errorf("cell_lat should carry no axis: %+v", cell)
	}

	saved, err := file.ToJSON()
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if _, err := LoadString(string(saved)); err != nil {
		t.Fatalf("emitted document no longer validates: %v", err)
	}
}

func sortedCoordNames(m map[string]Coordinate) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// TestRoundTripPreservesMetadataXESD pins `metadata.x_esd`, whose schema
// description is normative and explicit: "core tooling MUST NOT assign meaning
// to them and MUST preserve them across parse → emit like any other metadata
// field." The fixture is a pushdown golden document, the only corpus material
// that carries the block.
func TestRoundTripPreservesMetadataXESD(t *testing.T) {
	path := repoFile(t, "tests", "conformance", "pushdown", "golden", "pushdown_l1.rewritten.json")
	authored, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(file.Metadata.XESD) == 0 {
		t.Fatalf("x_esd did not survive parse")
	}
	saved, err := file.ToJSON()
	if err != nil {
		t.Fatalf("save: %v", err)
	}

	// Compare only the x_esd subtree: the rest of a pushdown golden document
	// goes through the rewrite machinery and is not this test's subject.
	want := decodeJSONNumbers(t, "authored", authored).(map[string]any)["metadata"].(map[string]any)["x_esd"]
	got := decodeJSONNumbers(t, "saved", saved).(map[string]any)["metadata"].(map[string]any)["x_esd"]
	var diffs []string
	jsonDiff("/metadata/x_esd", want, got, &diffs)
	if len(diffs) > 0 {
		t.Errorf("x_esd altered across parse -> emit:\n  %s", strings.Join(diffs, "\n  "))
	}
}

// TestRoundTripPreservesFieldsWithNoCorpusFixture covers the schema-sanctioned
// fields that NO fixture anywhere in tests/ exercises: Species.default_units,
// Parameter.default_units, Parameter.distribution, and the three
// discretize()-stamped metadata diagnostics (system_class, dae_info,
// discretized_from). They are modelled because the schema declares them and a
// document carrying them must round-trip; with no corpus coverage, this
// synthetic document is what proves they do.
func TestRoundTripPreservesFieldsWithNoCorpusFixture(t *testing.T) {
	doc := `{
	  "esm": "1.0.0",
	  "metadata": {
	    "name": "no_corpus_coverage",
	    "system_class": "dae",
	    "dae_info": {"algebraic_equation_count": 2, "per_model": {"R": 2}},
	    "discretized_from": {"name": "source_doc"}
	  },
	  "reaction_systems": {
	    "R": {
	      "species": {
	        "A": {"units": "mol/m^3", "default": 1.0, "default_units": "ppb"}
	      },
	      "parameters": {
	        "k": {"units": "1/s", "default": 0.5, "default_units": "1/min"},
	        "j": {"units": "1/s", "distribution": {"kind": "uniform", "low": 0.1, "high": 0.9}}
	      },
	      "reactions": [
	        {"id": "r1", "substrates": [{"species": "A", "stoichiometry": 1.0}],
	         "products": [{"species": "A", "stoichiometry": 2.0}], "rate": {"op": "*", "args": ["k", "A"]}}
	      ]
	    }
	  }
	}`
	file, err := LoadString(doc)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	saved, err := file.ToJSON()
	if err != nil {
		t.Fatalf("save: %v", err)
	}

	want := decodeJSONNumbers(t, "authored", []byte(doc))
	got := decodeJSONNumbers(t, "saved", saved)
	var diffs []string
	jsonDiff("", want, got, &diffs)
	if len(diffs) > 0 {
		t.Errorf("save(load(F)) differs from F in %d place(s):\n  %s",
			len(diffs), strings.Join(diffs, "\n  "))
	}
}

// TestConnectorEquationOmitsAbsentExpression pins the one ADDED key the audit
// found: `expression` is optional on a ConnectorEquation (esm-schema.json
// requires only from/to/transform), but the field carried no `omitempty`, so a
// connector equation authored without one came back with `"expression": null`
// bolted on. A load → save was not merely losing content, it was inventing it.
func TestConnectorEquationOmitsAbsentExpression(t *testing.T) {
	path := repoFile(t, "tests", "valid", "scoped_refs_coupling.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	saved, err := file.ToJSON()
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	root := decodeJSONNumbers(t, "saved", saved).(map[string]any)
	coupling, _ := root["coupling"].([]any)
	found := 0
	for _, entry := range coupling {
		e, _ := entry.(map[string]any)
		conn, ok := e["connector"].(map[string]any)
		if !ok {
			continue
		}
		eqs, _ := conn["equations"].([]any)
		for i, raw := range eqs {
			eq, _ := raw.(map[string]any)
			found++
			if v, present := eq["expression"]; present && v == nil {
				t.Errorf("connector equation %d emitted a spurious \"expression\": null", i)
			}
		}
	}
	if found == 0 {
		t.Fatalf("fixture carries no connector equations; it no longer covers this")
	}
}
