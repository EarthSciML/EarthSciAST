package esm

// Conformance tests for the out-of-line-expression-templates RFC (Option B,
// reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
// §9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten registry
// merge). Mirrors the Julia reference test
// EarthSciAST.jl/test/out_of_line_templates_test.jl. Drives
// tests/conformance/expression_templates/{emit_*, rewrite_in_template_body,
// rule_writes_reference, template_instance_variants, opacity_*,
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

// oolFlattenRegistries loads a fixture under Option B and runs the flatten
// registry merge over it (flattenTemplateRegistries), with the fixture's text
// as the declaration-order source.
func oolFlattenRegistries(t *testing.T, dir string, fixture ...string) (map[string]any, *orderedMap) {
	t.Helper()
	fx := "fixture.esm"
	if len(fixture) > 0 {
		fx = fixture[0]
	}
	data, err := os.ReadFile(oolConf(dir, fx))
	if err != nil {
		t.Fatalf("read %s/%s: %v", dir, fx, err)
	}
	return flattenTemplateRegistries(oolLoad(t, dir, fx), string(data))
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

// isApplyNode reports whether v is an apply_operator node.
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
		{"faq_int_ratio_golden", "fixture.esm", "expanded.esm"},
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
		{"import_rename_integral_axis", "fixture.esm", "expanded.esm"},
		{"import_rename_two_instances", "fixture.esm", "expanded.esm"},
		{"import_smoke", "fixture.esm", "expanded.esm"},
		{"import_where_rename_two_instances", "fixture.esm", "expanded.esm"},
		{"metaparam_axis_name_collision", "fixture.esm", "expanded.esm"},
		{"per_variable_scheme_literal_args", "fixture.esm", "expanded.esm"},
		{"scalar_field_param", "fixture.esm", "expanded.esm"},
		{"ranges_param", "fixture.esm", "expanded.esm"},
		{"ranges_from_param", "fixture.esm", "expanded.esm"},
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
	// Non-destructive: the loaded view still carries the surviving reference
	// the rule's firing wrote (esm-spec §9.6.3 constraint 7).
	mk := loaded["models"].(map[string]any)["Advection"].(map[string]any)["equations"].([]any)[0].(map[string]any)["rhs"].(map[string]any)["args"].([]any)[1].(map[string]any)
	if !isApplyNode(mk) {
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
	// The version stamp is a FLOOR — esm 2.4.0 or later, the version that names
	// `operators` / `apply_operator` (esm-spec §9.6.12) — so this 1.1.0 fixture
	// is raised to it. The golden (emitted.esm) is the byte-exact pin.
	if doc["esm"] != "2.4.0" {
		t.Errorf("esm = %v; want 2.4.0 (the emitted-definition version floor)", doc["esm"])
	}
	if _, has := adv["operator_imports"]; has {
		t.Errorf("operator_imports should be consumed")
	}
	// The firing wrote a reference to its rule, which materializes match-less
	// (esm-spec §9.6.3 constraint 7, §9.6.4 rule 5).
	reg := adv["operators"].(map[string]any)
	if len(reg) != 3 || reg["central_D_lon_interior"] == nil || reg["dlon_deg"] == nil ||
		reg["central_D_lon_zero_grad_bc"] == nil {
		t.Errorf("materialized registry = %v; want {central_D_lon_interior, central_D_lon_zero_grad_bc, dlon_deg}", sortedKeys(reg))
	}
	rule, _ := reg["central_D_lon_zero_grad_bc"].(map[string]any)
	if _, has := rule["match"]; has {
		t.Errorf("the referenced rule central_D_lon_zero_grad_bc must be materialized without `match`")
	}
	site := adv["equations"].([]any)[0].(map[string]any)["rhs"].(map[string]any)["args"].([]any)[1]
	if !isApplyNode(site) || site.(map[string]any)["name"] != "central_D_lon_zero_grad_bc" {
		t.Errorf("call site = %v; want a reference to central_D_lon_zero_grad_bc", site)
	}
	interior := rule["body"].(map[string]any)["values"].([]any)[0]
	if !isApplyNode(interior) || interior.(map[string]any)["name"] != "central_D_lon_interior" {
		t.Errorf("rule body interior = %v; want a surviving central_D_lon_interior reference", interior)
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
	reg := doc["models"].(map[string]any)["TwoGrids"].(map[string]any)["operators"].(map[string]any)
	if reg["fine.dx"] == nil || reg["coarse.dx"] == nil || reg["fine.central_D_x"] == nil ||
		reg["coarse.central_D_x"] == nil || len(reg) != 4 {
		t.Errorf("registry keys = %v; want {fine.dx, coarse.dx, fine.central_D_x, coarse.central_D_x}", sortedKeys(reg))
	}
}

// oolVarDef returns the DEFINING EXPRESSION of an observed unknown in a RAW
// document view: the RHS of the equation whose LHS is that bare name.
//
// esm 1.0.0 removed the `expression` field on a variable — an unknown's
// behaviour is stated by the model's `equations` and nowhere else — so every
// assertion that used to read `variables[v].expression` reads its equation here
// instead. The template machinery is unaffected: the substitution site simply
// moved with the expression.
func oolVarDef(t *testing.T, root map[string]any, comp, v string) any {
	t.Helper()
	model, ok := root["models"].(map[string]any)[comp].(map[string]any)
	if !ok {
		t.Fatalf("model %q not found", comp)
	}
	eqs, _ := model["equations"].([]any)
	for _, e := range eqs {
		eq, ok := e.(map[string]any)
		if !ok {
			continue
		}
		if lhs, ok := eq["lhs"].(string); ok && lhs == v {
			return eq["rhs"]
		}
	}
	t.Fatalf("no defining equation for %s.%s", comp, v)
	return nil
}

// -----------------------------------------------------------------------
// rewrite_in_template_body (§9.6.4 rule 3, §9.6.7; formerly
// eager_target_bearing): both references survive; the `central` rule rewrites
// `deriv_c`'s body in place to a reference to itself.
// -----------------------------------------------------------------------

func TestOOL_RewriteInTemplateBody(t *testing.T) {
	loaded := oolLoad(t, "rewrite_in_template_body")
	m := loaded["models"].(map[string]any)["m"].(map[string]any)
	reg := m["operators"].(map[string]any)
	deager := normTree(oolVarDef(t, loaded, "m", "d_eager")).(map[string]any)
	if a0 := deager["args"].([]any)[0]; !isApplyNode(a0) || a0.(map[string]any)["name"] != "deriv_c" {
		t.Errorf("d_eager arg[0] = %v; want a surviving deriv_c reference", a0)
	}
	body := normTree(reg["deriv_c"].(map[string]any)["body"]).(map[string]any)
	if !isApplyNode(body) || body["name"] != "central" ||
		!reflect.DeepEqual(body["bindings"], map[string]any{"f": "f"}) {
		t.Errorf("deriv_c body = %v; want a reference to central binding f to f", body)
	}
	if _, has := reg["central"].(map[string]any)["match"]; has {
		t.Errorf("the referenced rule central must be materialized without `match`")
	}
	dsurv := normTree(oolVarDef(t, loaded, "m", "d_survive")).(map[string]any)
	if a0 := dsurv["args"].([]any)[0]; !isApplyNode(a0) || a0.(map[string]any)["name"] != "scale_c" {
		t.Errorf("d_survive arg[0] = %v; want surviving scale_c reference", a0)
	}
	if got, want := oolEmit(t, "rewrite_in_template_body"), mustRead(t, "rewrite_in_template_body", "emitted.esm"); got != want {
		t.Errorf("rewrite_in_template_body emit != golden\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// -----------------------------------------------------------------------
// Rules write references (CONFORMANCE_SPEC §5.60; esm-spec §9.6.3 constraint
// 7, §9.6.4 rule 3): both goldens — the emitted form byte for byte, and
// Expand(load) against the expanded oracle — for every fixture §5.60 lists,
// plus the two rejected fixtures of rewrite_depth_through_bodies.
// -----------------------------------------------------------------------

func TestOOL_RulesWriteReferencesGoldens(t *testing.T) {
	coreJSON := func(d map[string]any) string {
		core := map[string]any{}
		for _, k := range []string{"models", "reaction_systems", "coupling", "index_sets"} {
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
	cases := []struct{ dir, fixture, emitted, expanded string }{
		{"rewrite_in_template_body", "fixture.esm", "emitted.esm", "expanded.esm"},
		{"rule_writes_reference", "fixture.esm", "emitted.esm", "expanded.esm"},
		{"template_instance_variants", "fixture.esm", "emitted.esm", "expanded.esm"},
		{"opacity_rule_replacement", "fixture.esm", "emitted.esm", "expanded.esm"},
		{"rewrite_depth_through_bodies", "chain_depth_64.esm", "emitted_chain_depth_64.esm", "expanded_chain_depth_64.esm"},
		// Coupling transforms keep their references (esm-spec §10.4); the
		// receiving component's block materializes what they name.
		{"coupling_transform_expression", "fixture.esm", "emitted.esm", "expanded.esm"},
		{"coupling_transform_rule_and_import", "fixture.esm", "emitted.esm", "expanded.esm"},
	}
	for _, c := range cases {
		t.Run(c.dir+"/"+c.fixture, func(t *testing.T) {
			if got, want := oolEmit(t, c.dir, c.fixture), mustRead(t, c.dir, c.emitted); got != want {
				t.Errorf("emit != %s (byte-exact)\n--- got ---\n%s\n--- want ---\n%s", c.emitted, got, want)
			}
			// Emit then load is a fixed point: the emitted form reloads and
			// re-emits byte for byte. For the depth-64 chain this holds only
			// because the body-nesting bound equals MaxRewritePasses (esm-spec
			// §9.7.3): its emitted form is a 64-template body-reference chain.
			if got, want := oolEmit(t, c.dir, c.emitted), mustRead(t, c.dir, c.emitted); got != want {
				t.Errorf("re-emit of %s is not a fixed point\n--- got ---\n%s\n--- want ---\n%s", c.emitted, got, want)
			}
			loaded := oolLoad(t, c.dir, c.fixture)
			if rpCount(loaded, "", "apply_operator") == 0 {
				t.Errorf("no surviving reference: the loaded form must keep the references firings wrote")
			}
			expanded := Expand(loaded)
			if n := rpCount(expanded, "", "apply_operator"); n != 0 {
				t.Errorf("Expand left %d reference(s)", n)
			}
			var want map[string]any
			dec := json.NewDecoder(strings.NewReader(mustRead(t, c.dir, c.expanded)))
			dec.UseNumber()
			if err := dec.Decode(&want); err != nil {
				t.Fatalf("decode %s: %v", c.expanded, err)
			}
			if got, w := coreJSON(expanded), coreJSON(want); got != w {
				t.Errorf("Expand(load) core != %s\n got=%s\nwant=%s", c.expanded, got, w)
			}
		})
	}
	// The emitted form of the build-gate fixture (its error is an evaluate-stage
	// error, N/A for this parse/validate-only binding).
	if got, want := oolEmit(t, "unlowered_in_template_body"), mustRead(t, "unlowered_in_template_body", "emitted.esm"); got != want {
		t.Errorf("unlowered_in_template_body emit != golden\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}

	// Variants are numbered by canonical bytes and each call site re-pointed.
	m := oolLoad(t, "template_instance_variants")["models"].(map[string]any)["m"].(map[string]any)
	defRHS := func(m map[string]any, v string) map[string]any {
		for _, e := range m["equations"].([]any) {
			eq := e.(map[string]any)
			if lhs, _ := eq["lhs"].(string); lhs == v {
				return eq["rhs"].(map[string]any)
			}
		}
		t.Fatalf("no defining equation for %s", v)
		return nil
	}
	if got := defRHS(m, "du")["name"]; got != "ddx.variant1" {
		t.Errorf("du references %v; want ddx.variant1", got)
	}
	if got := defRHS(m, "dv")["name"]; got != "ddx.variant2" {
		t.Errorf("dv references %v; want ddx.variant2", got)
	}
	v1 := m["operators"].(map[string]any)["ddx.variant1"].(map[string]any)["body"].(map[string]any)
	if v1["name"] != "central_1d" {
		t.Errorf("ddx.variant1 body references %v; want central_1d", v1["name"])
	}
	// A leaf-bodied rule writes its leaf.
	rw := oolLoad(t, "rule_writes_reference")["models"].(map[string]any)["m"].(map[string]any)
	e := normTree(defRHS(rw, "e"))
	if want := map[string]any{"op": "*", "args": []any{0.25, "b"}}; !reflect.DeepEqual(e, want) {
		t.Errorf("e = %v; want %v", e, want)
	}

	// Nontermination detected through bodies, and the depth bound.
	for _, c := range []struct{ fixture, errf string }{
		{"fixture.esm", "error.json"},
		{"chain_depth_65.esm", "error_chain_depth_65.json"},
	} {
		t.Run("rewrite_depth_through_bodies/"+c.fixture, func(t *testing.T) {
			var want struct{ Code string }
			if err := json.Unmarshal([]byte(mustRead(t, "rewrite_depth_through_bodies", c.errf)), &want); err != nil {
				t.Fatalf("decode %s: %v", c.errf, err)
			}
			fp := oolConf("rewrite_depth_through_bodies", c.fixture)
			data, err := os.ReadFile(fp)
			if err != nil {
				t.Fatalf("read %s: %v", fp, err)
			}
			_, err = loadOptionB(string(data), filepath.Dir(fp), nil)
			if err == nil {
				t.Fatalf("expected %s, got no error", want.Code)
			}
			if got := tiErrCode(t, err); got != want.Code {
				t.Errorf("expected %s, got %s (%v)", want.Code, got, err)
			}
		})
	}
}

// -----------------------------------------------------------------------
// opacity_negative (§9.6.4 rule 4): the compound pattern MUST NOT fire across a
// surviving-reference boundary.
// -----------------------------------------------------------------------

func TestOOL_OpacityNegative(t *testing.T) {
	loaded := oolLoad(t, "opacity_negative")
	flux := normTree(oolVarDef(t, loaded, "m", "flux")).(map[string]any)
	// The authored spatial `D` is read as `partial` at the wire boundary
	// (esm-spec §4.2 "Reading earlier documents").
	if flux["op"] != opPartial {
		t.Errorf("flux op = %v; want partial (compound rule did NOT fire, no marker 999)", flux["op"])
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
	// The generic rule fired and wrote a reference to itself (esm-spec §9.6.3
	// constraint 7), binding the surviving reference WHOLE.
	flux := normTree(oolVarDef(t, loaded, "m", "flux")).(map[string]any)
	if !isApplyNode(flux) || flux["name"] != "generic" {
		t.Fatalf("flux = %v; want a reference to the generic rule", flux)
	}
	f := flux["bindings"].(map[string]any)["f"]
	if !isApplyNode(f) || f.(map[string]any)["name"] != "flux_prod" {
		t.Errorf("flux bindings.f = %v; want surviving flux_prod reference bound whole", f)
	}
	generic := normTree(loaded["models"].(map[string]any)["m"].(map[string]any)["operators"].(map[string]any)["generic"]).(map[string]any)
	if v, ok := generic["body"].(map[string]any)["args"].([]any)[0].(int64); !ok || v != 1 {
		t.Errorf("generic body arg[0] = %v; want generic marker 1 (NOT compound 999)", generic["body"])
	}
	if got, want := oolEmit(t, "opacity_priority_shadowing"), mustRead(t, "opacity_priority_shadowing", "emitted.esm"); got != want {
		t.Errorf("opacity_priority_shadowing emit != golden\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// -----------------------------------------------------------------------
// flatten_registry_merge (§9.6.4 rule 7, §10.7): dedup + owner-path rename.
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryMerge(t *testing.T) {
	root, merged := oolFlattenRegistries(t, "flatten_registry_merge")
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
		return oolVarDef(t, root, comp, v).(map[string]any)["name"]
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
	if _, has := root["models"].(map[string]any)["A"].(map[string]any)["operators"]; has {
		t.Errorf("model A still carries operators after flatten")
	}
	if _, has := root["models"].(map[string]any)["B"].(map[string]any)["operators"]; has {
		t.Errorf("model B still carries operators after flatten")
	}
}

// -----------------------------------------------------------------------
// flatten_registry_merge_transitive (§9.6.4 rule 7, §10.7): TWO models in ONE
// document import the same rule library. `interior_stencil` folds differently
// per model (B rebinds its free `inv_dx`) and collides; the byte-identical
// `outer_stencil` that REFERENCES it must collide too — a single deduped
// `outer_stencil` would carry a reference the merged registry no longer holds,
// and expansion would fail with `operator_unknown_definition`
// naming a transitively imported stencil no model ever mentioned.
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryMergeTransitive(t *testing.T) {
	applyNames := func(x any) []string {
		out := []string{}
		collectApplyNames(&out, x)
		return out
	}
	root, merged := oolFlattenRegistries(t, "flatten_registry_merge_transitive")
	gotKeys := append([]string(nil), merged.keys...)
	sort.Strings(gotKeys)
	wantKeys := []string{"A.d_x_rule", "A.interior_stencil", "A.outer_stencil", "B.d_x_rule", "B.interior_stencil", "B.outer_stencil"}
	if !reflect.DeepEqual(gotKeys, wantKeys) {
		t.Errorf("merged registry keys = %v; want %v", gotKeys, wantKeys)
	}
	// The rule's firing wrote a reference to the rule (esm-spec §9.6.3
	// constraint 7), whose body references the wrapper: it renames with it.
	for _, m := range []string{"A", "B"} {
		decl, ok := merged.get(m + ".d_x_rule").(map[string]any)
		if !ok {
			t.Fatalf("merged registry is missing %s.d_x_rule", m)
		}
		if got, want := applyNames(decl["body"]), []string{m + ".outer_stencil"}; !reflect.DeepEqual(got, want) {
			t.Errorf("%s.d_x_rule body references %v; want %v", m, got, want)
		}
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
		if got, want := applyNames(eqs), []string{m + ".d_x_rule"}; !reflect.DeepEqual(got, want) {
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
// the CLOSING PRECONDITION, pinned. Two byte-identical models import the same
// rule library; `interior_stencil`'s body references the free name `inv_dx`,
// which is a model-local parameter and so denotes a DIFFERENT variable in each.
//
// flattenTemplateRegistries is the UNION half only, over the un-namespaced
// component view: identical bodies dedupe under their bare names, and the pair
// it returns is self-consistent with the un-namespaced document. Flatten's own
// registry closes every body first (TestOOL_FlattenClosesTwinBodies below).
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryMergeIsUnionHalfOnly(t *testing.T) {
	applyNames := func(x any) []string {
		out := []string{}
		collectApplyNames(&out, x)
		return out
	}
	root, merged := oolFlattenRegistries(t, "flatten_registry_merge_transitive", "fixture_twins.esm")
	// Step-4 answer on identical (unscoped) bodies: dedup under the bare names.
	gotKeys := append([]string(nil), merged.keys...)
	sort.Strings(gotKeys)
	if want := []string{"d_x_rule", "interior_stencil", "outer_stencil"}; !reflect.DeepEqual(gotKeys, want) {
		t.Fatalf("merged registry keys = %v; want %v", gotKeys, want)
	}
	outer := merged.get("outer_stencil").(map[string]any)
	if got, want := applyNames(outer["body"]), []string{"interior_stencil"}; !reflect.DeepEqual(got, want) {
		t.Errorf("outer_stencil body references %v; want %v", got, want)
	}
	models := root["models"].(map[string]any)
	for _, m := range []string{"A", "B"} {
		eqs := models[m].(map[string]any)["equations"]
		if got, want := applyNames(eqs), []string{"d_x_rule"}; !reflect.DeepEqual(got, want) {
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
		{"rewrite_in_template_body", "fixture.esm"},
		{"opacity_negative", "fixture.esm"},
		{"opacity_priority_shadowing", "fixture.esm"},
		{"rule_writes_reference", "fixture.esm"},
		{"template_instance_variants", "fixture.esm"},
		{"opacity_rule_replacement", "fixture.esm"},
		{"unlowered_in_template_body", "fixture.esm"},
		{"flatten_registry_merge", "fixture.esm"},
		{"faq_int_ratio_golden", "fixture.esm"},
		{"arrhenius_smoke", "fixture.esm"},
		{"constrained_match_scope", "fixture.esm"},
		{"coupling_transform_expression", "fixture.esm"},
		{"coupling_transform_rule_and_import", "fixture.esm"},
		{"fixpoint_nested_deriv", "fixture.esm"},
		{"godunov_beats_inner_deriv", "fixture.esm"},
		{"import_diamond", "fixture.esm"},
		{"import_order_determinism", "fixture_import_order.esm"},
		{"import_order_determinism", "fixture_priority_override.esm"},
		{"import_rebind_keyed_factors", "fixture.esm"},
		{"import_rename_diamond", "fixture.esm"},
		{"import_rename_integral_axis", "fixture.esm"},
		{"import_rename_two_instances", "fixture.esm"},
		{"import_smoke", "fixture.esm"},
		{"import_where_rename_two_instances", "fixture.esm"},
		{"metaparam_axis_name_collision", "fixture.esm"},
		{"per_variable_scheme_literal_args", "fixture.esm"},
		{"scalar_field_param", "fixture.esm"},
		{"ranges_param", "fixture.esm"},
		{"ranges_from_param", "fixture.esm"},
		{"two_div_two_meshes", "fixture.esm"},
		// esm 2.4.0 one-operator-type fixtures (esm-spec §9.6.12).
		{"operator_call_by_name", "fixture.esm"},
		{"placeholder_call", "fixture.esm"},
		{"partial_wrt_param_instance", "fixture.esm"},
		{"old_names", "fixture.esm"},
	}
	// OPEN design question (reported with the #759 port): a referenced `match`
	// rule is materialized WITHOUT its `match` and `where` but WITH its
	// inferred `defines` (here `div`), so on reload it is a match-less
	// definition of `div` — callable at every `div` call, including the one its
	// `where` excluded. Same shape as QUESTIONS.md Q11.
	knownOpen := map[string]string{
		"constrained_match_scope": "a materialized where-constrained rule becomes an unconstrained callable definition of its match root op on reload (open #759 design question, cf. Q11)",
	}
	for _, c := range cases {
		t.Run(c.dir+"/"+c.fixture, func(t *testing.T) {
			if why, ok := knownOpen[c.dir]; ok {
				t.Skip(why)
			}
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

// The ops of the §4.2 core are evaluable-core, not rewrite targets: a template
// body that uses them is not target-bearing. This is the classification the
// Julia, Python and Rust registries give them.
func TestOpInTCoreOps(t *testing.T) {
	for _, op := range []string{"faq", "index", "pow", "true", "false"} {
		if opInT(op) {
			t.Errorf("opInT(%q) = true, want false (evaluable core)", op)
		}
	}
	for _, op := range []string{"grad", "godunov_hamiltonian", "D", "integral"} {
		if !opInT(op) {
			t.Errorf("opInT(%q) = false, want true (rewrite target)", op)
		}
	}
}

// Flatten closes every carried body before the merge (esm-spec §10.7;
// esm-libraries-spec §4.7.5 steps 2 and 4): the twins' `inv_dx` becomes a
// trailing parameter of `interior_stencil`, which the nested references of
// `outer_stencil` and `d_x_rule` bind to the same name, so the closed bodies
// are identical and kept once, correct for both models.
func TestOOL_FlattenClosesTwinBodies(t *testing.T) {
	file, err := LoadPath(oolConf("flatten_registry_merge_transitive", "fixture_twins.esm"))
	if err != nil {
		t.Fatal(err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatal(err)
	}
	reg := map[string]map[string]any{}
	var names []string
	for _, e := range flat.TemplateRegistry {
		names = append(names, e.Name)
		reg[e.Name] = e.Declaration.(map[string]any)
	}
	sorted := append([]string(nil), names...)
	sort.Strings(sorted)
	if want := []string{"d_x_rule", "interior_stencil", "outer_stencil"}; !reflect.DeepEqual(sorted, want) {
		t.Fatalf("flattened registry = %v; want one closed entry per template %v", names, want)
	}
	for _, n := range sorted {
		params := templateParams(reg[n])
		if len(params) == 0 || params[len(params)-1] != "inv_dx" {
			t.Errorf("%s params = %v; want inv_dx appended", n, params)
		}
	}
	blob, _ := json.Marshal(reg["outer_stencil"]["body"])
	if !strings.Contains(string(blob), `"inv_dx":"inv_dx"`) {
		t.Errorf("outer_stencil's nested reference must bind inv_dx => inv_dx: %s", blob)
	}
}

// -----------------------------------------------------------------------
// flatten_registry_order (§9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5
// step 4): the merged registry's ORDER, written by Julia. Components are
// declared out of alphabetical order (Zulu, Alpha, Mike) with authored entries
// out of alphabetical order, and Zulu materializes two imported entries. The
// merge walks components in document order, each block as emit materializes
// it, so the colliding `s` that Zulu and Mike carry identically is ONE entry
// named after Zulu, the first owner in document order.
// -----------------------------------------------------------------------

func TestOOL_FlattenRegistryOrder(t *testing.T) {
	d := "flatten_registry_order"
	want := mtrGolden(t, d, "flattened_registry.esm")
	mtrCompare(t, "Flatten template registry", mtrFlat(t, mtrPath(d, "fixture.esm")), want)
	root, merged := oolFlattenRegistries(t, d)
	mtrCompare(t, "flattenTemplateRegistries merged registry", mtrBlock(merged), want)
	refName := func(comp, v string) any {
		return oolVarDef(t, root, comp, v).(map[string]any)["name"]
	}
	for comp, w := range map[string]string{"Zulu": "Zulu.s", "Mike": "Zulu.s", "Alpha": "Alpha.s"} {
		if got := refName(comp, "y_s"); got != w {
			t.Errorf("%s.y_s references %v; want %s", comp, got, w)
		}
	}
}
