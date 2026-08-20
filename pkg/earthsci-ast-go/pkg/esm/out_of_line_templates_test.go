package esm

// Conformance tests for the out-of-line-expression-templates RFC (Option B,
// reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
// §9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten registry
// merge). Mirrors the Julia reference test
// EarthSciAST.jl/test/out_of_line_templates_test.jl. Drives
// tests/conformance/expression_templates/{emit_*, eager_*, opacity_*,
// per_instantiation_validation, flatten_registry_merge}.

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func oolConf(parts ...string) string {
	base := []string{"..", "..", "..", "..", "tests", "conformance", "expression_templates"}
	return filepath.Join(append(base, parts...)...)
}

// oolLoad loads a fixture under Option B (references preserved), returning the
// raw loaded document view.
func oolLoad(t *testing.T, dir string, fixture ...string) map[string]any {
	t.Helper()
	fx := "fixture.esm"
	if len(fixture) > 0 {
		fx = fixture[0]
	}
	fp := oolConf(dir, fx)
	data, err := os.ReadFile(fp)
	if err != nil {
		t.Fatalf("read %s: %v", fp, err)
	}
	view, err := loadOptionB(string(data), filepath.Dir(fp), nil)
	if err != nil {
		t.Fatalf("loadOptionB(%s): %v", dir, err)
	}
	return view
}

// oolLoadErr loads a fixture under Option B, returning the error (for the
// invalid fixtures).
func oolLoadErr(dir string, fixture ...string) error {
	fx := "fixture.esm"
	if len(fixture) > 0 {
		fx = fixture[0]
	}
	fp := oolConf(dir, fx)
	data, err := os.ReadFile(fp)
	if err != nil {
		return err
	}
	_, err = loadOptionB(string(data), filepath.Dir(fp), nil)
	return err
}

// oolEmit emits a fixture's reference-preserving canonical form.
func oolEmit(t *testing.T, dir string, fixture ...string) string {
	t.Helper()
	fx := "fixture.esm"
	if len(fixture) > 0 {
		fx = fixture[0]
	}
	fp := oolConf(dir, fx)
	data, err := os.ReadFile(fp)
	if err != nil {
		t.Fatalf("read %s: %v", fp, err)
	}
	s, err := EmitReferencePreserving(string(data), filepath.Dir(fp), nil)
	if err != nil {
		t.Fatalf("EmitReferencePreserving(%s): %v", dir, err)
	}
	return s
}

// normNum canonicalizes a JSON number to int64 (integral) or float64.
func normNum(v any) any {
	switch n := v.(type) {
	case json.Number:
		s := string(n)
		if !strings.ContainsAny(s, ".eE") {
			if i, err := strconv.ParseInt(s, 10, 64); err == nil {
				return i
			}
		}
		f, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return s
		}
		if f == math.Trunc(f) && !math.IsInf(f, 0) {
			if i := int64(f); float64(i) == f {
				return i
			}
		}
		return f
	case int:
		return int64(n)
	case int64:
		return n
	case float64:
		if n == math.Trunc(n) && !math.IsInf(n, 0) {
			if i := int64(n); float64(i) == n {
				return i
			}
		}
		return n
	}
	return v
}

// normTree normalizes an untyped JSON tree so structurally-equal trees compare
// equal regardless of int/float encoding.
func normTree(v any) any {
	switch x := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, val := range x {
			out[k] = normTree(val)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = normTree(val)
		}
		return out
	default:
		return normNum(v)
	}
}

// isApplyNode reports whether v is an apply_expression_template node.
func isApplyNode(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	op, _ := m["op"].(string)
	return op == applyExpressionTemplateOp
}

// -----------------------------------------------------------------------
// BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): Expand(load(fixture)) is
// structurally equal to the existing expanded*.esm oracle. The goldens are NOT
// regenerated — they are the Option-A image Expand must reproduce.
// -----------------------------------------------------------------------

func TestOOL_BridgeGate_ExpandEqualsExpandedGolden(t *testing.T) {
	coreKeys := []string{"models", "reaction_systems", "coupling", "index_sets"}
	coreJSON := func(d map[string]any) string {
		core := map[string]any{}
		for _, k := range coreKeys {
			if v, ok := d[k]; ok {
				core[k] = normTree(v)
			}
		}
		out, err := json.Marshal(core)
		if err != nil {
			t.Fatalf("marshal core: %v", err)
		}
		return string(out)
	}
	cases := []struct{ dir, fixture, golden string }{
		{"aggregate_int_ratio_golden", "fixture.esm", "expanded.esm"},
		{"arrhenius_smoke", "fixture.esm", "expanded.esm"},
		{"constrained_match_scope", "fixture.esm", "expanded.esm"},
		{"coupling_transform_expression", "fixture.esm", "expanded.esm"},
		{"fixpoint_nested_deriv", "fixture.esm", "expanded.esm"},
		{"godunov_beats_inner_deriv", "fixture.esm", "expanded.esm"},
		{"import_diamond", "fixture.esm", "expanded.esm"},
		{"import_order_determinism", "fixture_import_order.esm", "expanded_import_order.esm"},
		{"import_order_determinism", "fixture_priority_override.esm", "expanded_priority_override.esm"},
		{"import_rebind_keyed_factors", "fixture.esm", "expanded.esm"},
		{"import_rename_diamond", "fixture.esm", "expanded.esm"},
		{"import_rename_two_instances", "fixture.esm", "expanded.esm"},
		{"import_smoke", "fixture.esm", "expanded.esm"},
		{"import_where_rename_two_instances", "fixture.esm", "expanded.esm"},
		{"per_variable_scheme_literal_args", "fixture.esm", "expanded.esm"},
		{"scalar_field_param", "fixture.esm", "expanded.esm"},
		{"two_div_two_meshes", "fixture.esm", "expanded.esm"},
	}
	for _, c := range cases {
		t.Run(c.dir+"/"+c.fixture, func(t *testing.T) {
			loaded := oolLoad(t, c.dir, c.fixture)
			got := coreJSON(Expand(loaded))
			gdata, err := os.ReadFile(oolConf(c.dir, c.golden))
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}
			var want map[string]any
			dec := json.NewDecoder(strings.NewReader(string(gdata)))
			dec.UseNumber()
			if err := dec.Decode(&want); err != nil {
				t.Fatalf("decode golden: %v", err)
			}
			if got != coreJSON(want) {
				t.Errorf("Expand(load) core != %s golden\n got=%s\nwant=%s", c.golden, got, coreJSON(want))
			}
		})
	}
}

// Expand determinism (§9.6.4 rule 2): two expansions produce structurally
// identical results; the loaded view still carries surviving references
// (non-destructive).
func TestOOL_ExpandDeterministicAndNonDestructive(t *testing.T) {
	loaded := oolLoad(t, "import_smoke")
	a, _ := json.Marshal(normTree(Expand(loaded)))
	b, _ := json.Marshal(normTree(Expand(loaded)))
	if string(a) != string(b) {
		t.Errorf("Expand is not deterministic")
	}
	// Non-destructive: the loaded view still carries the surviving makearray.
	mk := loaded["models"].(map[string]any)["Advection"].(map[string]any)["equations"].([]any)[0].(map[string]any)["rhs"].(map[string]any)["args"].([]any)[1].(map[string]any)
	if op, _ := mk["op"].(string); op != "makearray" {
		t.Errorf("loaded view mutated by Expand: op=%v", mk["op"])
	}
}

// -----------------------------------------------------------------------
// emit_materialized_registry (§9.6.4 rule 5, §9.6.7)
// -----------------------------------------------------------------------

func TestOOL_EmitMaterializedRegistry(t *testing.T) {
	s := oolEmit(t, "emit_materialized_registry")
	golden, err := os.ReadFile(oolConf("emit_materialized_registry", "emitted.esm"))
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	if s != string(golden) {
		t.Fatalf("emit != emitted.esm golden (byte-exact)\n--- got ---\n%s\n--- want ---\n%s", s, string(golden))
	}
	var doc map[string]any
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	if err := dec.Decode(&doc); err != nil {
		t.Fatalf("decode emit: %v", err)
	}
	adv := doc["models"].(map[string]any)["Advection"].(map[string]any)
	// The §9.6.4 rule-8 stamp is a FLOOR: the emitted document must declare AT
	// LEAST 0.9.0, the first version whose loader implements Option B. The source
	// fixture declares 1.0.0, so the stamp must leave it alone -- lowering it to
	// 0.9.0 would have the document disclaim the unified variable model it is
	// actually written in.
	if doc["esm"] != "1.0.0" {
		t.Errorf("esm = %v; want 1.0.0 (rule 8 stamps a floor and never downgrades)", doc["esm"])
	}
	if _, has := adv["expression_template_imports"]; has {
		t.Errorf("expression_template_imports should be consumed")
	}
	reg := adv["expression_templates"].(map[string]any)
	if len(reg) != 2 || reg["central_D_lon_interior"] == nil || reg["dlon_deg"] == nil {
		t.Errorf("materialized registry = %v; want {central_D_lon_interior, dlon_deg}", sortedKeys(reg))
	}
	if _, has := reg["central_D_lon_zero_grad_bc"]; has {
		t.Errorf("match rule central_D_lon_zero_grad_bc must NOT be materialized")
	}
	// Idempotency (§9.6.4 rule 5 / RFC gate 2).
	s2, err := EmitReferencePreserving(s, oolConf("emit_materialized_registry"), nil)
	if err != nil {
		t.Fatalf("re-emit: %v", err)
	}
	if s2 != s {
		t.Errorf("emit not idempotent")
	}
}

// -----------------------------------------------------------------------
// emit_rename_dotted_keys (§9.6.4 rule 5, §7.5.6 dotted keys)
// -----------------------------------------------------------------------

func TestOOL_EmitRenameDottedKeys(t *testing.T) {
	s := oolEmit(t, "emit_rename_dotted_keys")
	golden, err := os.ReadFile(oolConf("emit_rename_dotted_keys", "emitted.esm"))
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	if s != string(golden) {
		t.Fatalf("emit != emitted.esm golden (byte-exact)\n--- got ---\n%s\n--- want ---\n%s", s, string(golden))
	}
	var doc map[string]any
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	_ = dec.Decode(&doc)
	reg := doc["models"].(map[string]any)["TwoGrids"].(map[string]any)["expression_templates"].(map[string]any)
	if reg["fine.dx"] == nil || reg["coarse.dx"] == nil || len(reg) != 2 {
		t.Errorf("registry keys = %v; want {fine.dx, coarse.dx}", sortedKeys(reg))
	}
}

// -----------------------------------------------------------------------
// eager_target_bearing (§9.6.4 rule 3): positive + negative.
// -----------------------------------------------------------------------

func TestOOL_EagerTargetBearing(t *testing.T) {
	loaded := oolLoad(t, "eager_target_bearing")
	rhsFor := oolEquationRHS(t, loaded, "m")
	// POSITIVE: deriv_c (D-bearing) reference eagerly expanded, then the D
	// lowered by the `central` rule → an aggregate. No surviving ref.
	deager := normTree(rhsFor["d_eager"]).(map[string]any)
	if deager["op"] != "index" {
		t.Errorf("d_eager op = %v; want index", deager["op"])
	}
	if inner, ok := deager["args"].([]any)[0].(map[string]any); !ok || inner["op"] != "aggregate" {
		t.Errorf("d_eager arg[0] op = %v; want aggregate (D lowered at load)", deager["args"].([]any)[0])
	}
	// NEGATIVE: scale_c (target-free) reference SURVIVES.
	dsurv := normTree(rhsFor["d_survive"]).(map[string]any)
	arg0 := dsurv["args"].([]any)[0]
	if !isApplyNode(arg0) || arg0.(map[string]any)["name"] != "scale_c" {
		t.Errorf("d_survive arg[0] = %v; want surviving scale_c reference", arg0)
	}
	// Emit golden.
	if got, want := oolEmit(t, "eager_target_bearing"), mustRead(t, "eager_target_bearing", "emitted.esm"); got != want {
		t.Errorf("eager emit != golden\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// -----------------------------------------------------------------------
// opacity_negative (§9.6.4 rule 4): the compound pattern MUST NOT fire across a
// surviving-reference boundary.
// -----------------------------------------------------------------------

func TestOOL_OpacityNegative(t *testing.T) {
	loaded := oolLoad(t, "opacity_negative")
	flux := normTree(oolEquationRHS(t, loaded, "m")["flux"]).(map[string]any)
	if flux["op"] != "D" {
		t.Errorf("flux op = %v; want D (compound rule did NOT fire, no marker 999)", flux["op"])
	}
	arg0 := flux["args"].([]any)[0]
	if !isApplyNode(arg0) || arg0.(map[string]any)["name"] != "flux_prod" {
		t.Errorf("flux arg[0] = %v; want surviving flux_prod reference", arg0)
	}
	if got, want := oolEmit(t, "opacity_negative"), mustRead(t, "opacity_negative", "emitted.esm"); got != want {
		t.Errorf("opacity_negative emit != golden\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// -----------------------------------------------------------------------
// opacity_priority_shadowing (§9.6.4 rule 4): the SILENT divergence — the
// high-priority compound rule does NOT fire; a lower-priority generic rule DOES,
// binding the surviving reference whole.
// -----------------------------------------------------------------------

func TestOOL_OpacityPriorityShadowing(t *testing.T) {
	loaded := oolLoad(t, "opacity_priority_shadowing")
	flux := normTree(oolEquationRHS(t, loaded, "m")["flux"]).(map[string]any)
	if flux["op"] != "*" {
		t.Fatalf("flux op = %v; want * (generic rule fired)", flux["op"])
	}
	args := flux["args"].([]any)
	if v, ok := args[0].(int64); !ok || v != 1 {
		t.Errorf("flux arg[0] = %v; want generic marker 1 (NOT compound 999)", args[0])
	}
	if !isApplyNode(args[1]) || args[1].(map[string]any)["name"] != "flux_prod" {
		t.Errorf("flux arg[1] = %v; want surviving flux_prod reference bound whole", args[1])
	}
	if got, want := oolEmit(t, "opacity_priority_shadowing"), mustRead(t, "opacity_priority_shadowing", "emitted.esm"); got != want {
		t.Errorf("opacity_priority_shadowing emit != golden\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// -----------------------------------------------------------------------
// per_instantiation_validation (§9.6.9): manifold param, two call sites, one
// inadmissible → geometry_manifold_invalid naming the call site.
// -----------------------------------------------------------------------

func TestOOL_PerInstantiationValidation(t *testing.T) {
	err := oolLoadErr("per_instantiation_validation")
	if err == nil {
		t.Fatalf("expected geometry_manifold_invalid, got nil")
	}
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected *ExpressionTemplateError, got %T (%v)", err, err)
	}
	if etErr.Code != "geometry_manifold_invalid" {
		t.Errorf("code = %s; want geometry_manifold_invalid", etErr.Code)
	}
	// The call site is the DEFINING EQUATION of area_bad now, so the message
	// locates it by equation index rather than by variable name -- 1.0.0 removed
	// the `variables/<v>/expression` position the template application used to
	// occupy. What matters is that it points at the offending instantiation.
	if !strings.Contains(etErr.Message, "equations/1/rhs") {
		t.Errorf("message must locate the offending call site: %s", etErr.Message)
	}
	if !strings.Contains(etErr.Message, "overlap") {
		t.Errorf("message must name template overlap: %s", etErr.Message)
	}
}

// -----------------------------------------------------------------------
// flatten_registry_merge (§9.6.4 rule 7, §10.7): dedup + owner-path rename.
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryMerge(t *testing.T) {
	loaded := oolLoad(t, "flatten_registry_merge")
	root, merged := flattenTemplateRegistries(loaded)
	got := map[string]bool{}
	for _, k := range merged.keys {
		got[k] = true
	}
	if len(got) != 3 || !got["sten"] || !got["A.s"] || !got["B.s"] {
		t.Errorf("merged registry keys = %v; want {sten, A.s, B.s}", merged.keys)
	}
	stenBody := normTree(merged.get("sten").(map[string]any)["body"])
	wantSten := map[string]any{"op": "*", "args": []any{int64(2), "f"}}
	if !reflect.DeepEqual(stenBody, wantSten) {
		t.Errorf("merged sten body = %v; want {op:*, args:[2, f]}", stenBody)
	}
	// References rewritten in lockstep.
	refName := func(comp, v string) any {
		return oolEquationRHS(t, root, comp)[v].(map[string]any)["name"]
	}
	if refName("A", "za") != "A.s" {
		t.Errorf("A.za name = %v; want A.s", refName("A", "za"))
	}
	if refName("B", "zb") != "B.s" {
		t.Errorf("B.zb name = %v; want B.s", refName("B", "zb"))
	}
	if refName("A", "ya") != "sten" {
		t.Errorf("A.ya name = %v; want sten", refName("A", "ya"))
	}
	if refName("B", "yb") != "sten" {
		t.Errorf("B.yb name = %v; want sten", refName("B", "yb"))
	}
	// Per-component blocks surrendered to the merged registry.
	if _, has := root["models"].(map[string]any)["A"].(map[string]any)["expression_templates"]; has {
		t.Errorf("model A still carries expression_templates after flatten")
	}
	if _, has := root["models"].(map[string]any)["B"].(map[string]any)["expression_templates"]; has {
		t.Errorf("model B still carries expression_templates after flatten")
	}
}

// -----------------------------------------------------------------------
// flatten_registry_merge_transitive (§9.6.4 rule 7, §10.7): TWO models in ONE
// document import the same rule library. `interior_stencil` folds differently
// per model (B rebinds its free `inv_dx`) and collides; the byte-identical
// `outer_stencil` that REFERENCES it must collide too — a single deduped
// `outer_stencil` would carry a reference the merged registry no longer holds,
// and expansion would fail with `apply_expression_template_unknown_template`
// naming a transitively imported stencil no model ever mentioned.
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryMergeTransitive(t *testing.T) {
	applyNames := func(x any) []string {
		out := []string{}
		collectApplyNames(&out, x)
		return out
	}
	loaded := oolLoad(t, "flatten_registry_merge_transitive")
	root, merged := flattenTemplateRegistries(loaded)
	gotKeys := append([]string(nil), merged.keys...)
	sort.Strings(gotKeys)
	wantKeys := []string{"A.interior_stencil", "A.outer_stencil", "B.interior_stencil", "B.outer_stencil"}
	if !reflect.DeepEqual(gotKeys, wantKeys) {
		t.Errorf("merged registry keys = %v; want %v", gotKeys, wantKeys)
	}
	// Each owner's wrapper reaches its OWN leaf, never the other model's.
	for _, m := range []string{"A", "B"} {
		decl, ok := merged.get(m + ".outer_stencil").(map[string]any)
		if !ok {
			t.Fatalf("merged registry is missing %s.outer_stencil", m)
		}
		if got, want := applyNames(decl["body"]), []string{m + ".interior_stencil"}; !reflect.DeepEqual(got, want) {
			t.Errorf("%s.outer_stencil body references %v; want %v", m, got, want)
		}
	}
	// Component reference sites follow in lockstep.
	models := root["models"].(map[string]any)
	for _, m := range []string{"A", "B"} {
		eqs := models[m].(map[string]any)["equations"]
		if got, want := applyNames(eqs), []string{m + ".outer_stencil"}; !reflect.DeepEqual(got, want) {
			t.Errorf("model %s equations reference %v; want %v", m, got, want)
		}
	}
	// Nothing dangles: every surviving reference resolves in the merged registry.
	for _, k := range merged.keys {
		for _, r := range applyNames(merged.get(k)) {
			if !merged.has(r) {
				t.Errorf("dangling registry reference %s (from %s)", r, k)
			}
		}
	}
	for _, m := range []string{"A", "B"} {
		for _, r := range applyNames(models[m].(map[string]any)["equations"]) {
			if !merged.has(r) {
				t.Errorf("dangling component reference %s (from model %s)", r, m)
			}
		}
	}
}

// -----------------------------------------------------------------------
// flatten_registry_merge_transitive/fixture_twins.esm (§9.6.4 rule 7, §10.7):
// the SCOPING PRECONDITION, pinned. Two byte-identical models import the same
// rule library; `interior_stencil`'s body references the free name `inv_dx`,
// which is a model-local parameter and so denotes a DIFFERENT variable in each.
//
// flattenTemplateRegistries is the UNION half only, over the un-namespaced
// component view: identical bodies dedupe under their bare names, and the pair
// it returns is self-consistent with the un-namespaced document. Go reaches this
// surface only from conformance — LowerExpressionTemplates runs Expand-at-build
// (§9.6.4 rule 2) so the load path never leaves a surviving reference, and Go's
// flatten carries no registry, so no scoping step exists here and none is
// required (§10.7, "Applicability across bindings"). The Julia twin of this test
// also pins the scoping∘merge composition, which its reference-preserving
// `flatten` does carry; a binding that grows that path inherits the obligation,
// and this test is what will fail if the merge is fed unscoped bodies from it.
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryMergeIsUnionHalfOnly(t *testing.T) {
	applyNames := func(x any) []string {
		out := []string{}
		collectApplyNames(&out, x)
		return out
	}
	loaded := oolLoad(t, "flatten_registry_merge_transitive", "fixture_twins.esm")
	root, merged := flattenTemplateRegistries(loaded)
	// Step-4 answer on identical (unscoped) bodies: dedup under the bare names.
	gotKeys := append([]string(nil), merged.keys...)
	sort.Strings(gotKeys)
	if want := []string{"interior_stencil", "outer_stencil"}; !reflect.DeepEqual(gotKeys, want) {
		t.Fatalf("merged registry keys = %v; want %v", gotKeys, want)
	}
	outer := merged.get("outer_stencil").(map[string]any)
	if got, want := applyNames(outer["body"]), []string{"interior_stencil"}; !reflect.DeepEqual(got, want) {
		t.Errorf("outer_stencil body references %v; want %v", got, want)
	}
	models := root["models"].(map[string]any)
	for _, m := range []string{"A", "B"} {
		eqs := models[m].(map[string]any)["equations"]
		if got, want := applyNames(eqs), []string{"outer_stencil"}; !reflect.DeepEqual(got, want) {
			t.Errorf("model %s equations reference %v; want %v", m, got, want)
		}
	}
	// Nothing dangles at this layer.
	for _, k := range merged.keys {
		for _, r := range applyNames(merged.get(k)) {
			if !merged.has(r) {
				t.Errorf("dangling registry reference %s (from %s)", r, k)
			}
		}
	}
	// The carried body's free variable is NOT component-scoped by this surface:
	// `inv_dx`, not `A.inv_dx`. Scoping belongs to the caller that namespaces.
	blob, err := json.Marshal(merged.get("interior_stencil").(map[string]any)["body"])
	if err != nil {
		t.Fatalf("marshal interior_stencil body: %v", err)
	}
	body := string(blob)
	if !strings.Contains(body, `"inv_dx"`) {
		t.Errorf("interior_stencil body lost its free inv_dx: %s", body)
	}
	if strings.Contains(body, "A.inv_dx") || strings.Contains(body, "B.inv_dx") {
		t.Errorf("the union-half surface must not component-scope free variables: %s", body)
	}
}

// -----------------------------------------------------------------------
// Idempotency property over every new emit fixture (RFC §12 gate 2).
// -----------------------------------------------------------------------

func TestOOL_EmitIdempotentByteWise(t *testing.T) {
	// RFC §12 gate 2 / §7.5.7: emit∘load is a byte-wise fixed point across ALL
	// (valid, emittable) conformance fixtures — the new emit surface plus the
	// pre-existing bridge fixtures.
	cases := []struct{ dir, fixture string }{
		{"emit_materialized_registry", "fixture.esm"},
		{"emit_rename_dotted_keys", "fixture.esm"},
		{"eager_target_bearing", "fixture.esm"},
		{"opacity_negative", "fixture.esm"},
		{"opacity_priority_shadowing", "fixture.esm"},
		{"flatten_registry_merge", "fixture.esm"},
		{"aggregate_int_ratio_golden", "fixture.esm"},
		{"arrhenius_smoke", "fixture.esm"},
		{"constrained_match_scope", "fixture.esm"},
		{"coupling_transform_expression", "fixture.esm"},
		{"fixpoint_nested_deriv", "fixture.esm"},
		{"godunov_beats_inner_deriv", "fixture.esm"},
		{"import_diamond", "fixture.esm"},
		{"import_order_determinism", "fixture_import_order.esm"},
		{"import_order_determinism", "fixture_priority_override.esm"},
		{"import_rebind_keyed_factors", "fixture.esm"},
		{"import_rename_diamond", "fixture.esm"},
		{"import_rename_two_instances", "fixture.esm"},
		{"import_smoke", "fixture.esm"},
		{"import_where_rename_two_instances", "fixture.esm"},
		{"per_variable_scheme_literal_args", "fixture.esm"},
		{"scalar_field_param", "fixture.esm"},
		{"two_div_two_meshes", "fixture.esm"},
	}
	for _, c := range cases {
		t.Run(c.dir+"/"+c.fixture, func(t *testing.T) {
			s1 := oolEmit(t, c.dir, c.fixture)
			s2, err := EmitReferencePreserving(s1, oolConf(c.dir), nil)
			if err != nil {
				t.Fatalf("re-emit: %v", err)
			}
			if s1 != s2 {
				t.Errorf("emit∘load not a byte-wise fixed point for %s/%s\n--- s1 ---\n%s\n--- s2 ---\n%s", c.dir, c.fixture, s1, s2)
			}
		})
	}
}

func mustRead(t *testing.T, parts ...string) string {
	t.Helper()
	data, err := os.ReadFile(oolConf(parts...))
	if err != nil {
		t.Fatalf("read %v: %v", parts, err)
	}
	return string(data)
}

// oolEquationRHS indexes a component's `equations` by the bare-variable LHS each
// one defines.
//
// Every one of these tests used to read `variables[v].expression`, because that
// is where an observed unknown's definition -- and therefore any surviving or
// expanded template reference -- lived. esm 1.0.0 removed the field, so the
// lowering result is the RHS of the defining equation instead.
func oolEquationRHS(t *testing.T, root map[string]any, component string) map[string]any {
	t.Helper()
	model, ok := root["models"].(map[string]any)[component].(map[string]any)
	if !ok {
		t.Fatalf("no model %q in document", component)
	}
	out := map[string]any{}
	eqs, _ := model["equations"].([]any)
	for _, raw := range eqs {
		eq, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if lhs, ok := eq["lhs"].(string); ok {
			out[lhs] = eq["rhs"]
		}
	}
	return out
}
