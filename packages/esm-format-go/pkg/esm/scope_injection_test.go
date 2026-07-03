package esm

// Tests for esm-spec §9.7.10 — scope-directed template injection
// (docs/content/rfcs/scoped-template-injection.md): the assembler- or
// test-chosen discretization for a discretization-agnostic PDE leaf, via
// `expression_template_imports` on a §4.7 subsystem-ref edge (form A), a §10
// coupling entry (form B), or a §6.6/§6.7 test/example (form C). Drives the
// shared conformance fixtures under tests/conformance/expression_templates/,
// mirroring the Julia reference testset
// EarthSciSerialization.jl/test/scope_injection_test.jl.
//
// Form B is a pure root-level transform, so it is asserted against the full
// expanded golden through the raw §9.7 pipeline (tiExpandRaw), exactly like
// import_smoke. Forms A and C go through the typed EsmFile round-trip, whose
// serializer emits an empty `metadata.authors` the Julia goldens omit (a
// pre-existing cross-binding serializer quirk, unrelated to injection), so
// those two compare every block EXCEPT `metadata` — the same scoping the
// existing TestMatchScoping_ConformanceGoldens uses to dodge golden metadata.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// siNodeOp returns the `op` of an expression node, handling the typed
// ExprNode / *ExprNode (a Load-parsed equation) and the raw map form (an
// inlined-subsystem or raw-pipeline node).
func siNodeOp(x interface{}) string {
	switch e := x.(type) {
	case ExprNode:
		return e.Op
	case *ExprNode:
		return e.Op
	case map[string]interface{}:
		s, _ := e["op"].(string)
		return s
	}
	return ""
}

// siNodeArgs returns the `args` slice of an expression node in either form.
func siNodeArgs(x interface{}) []interface{} {
	switch e := x.(type) {
	case ExprNode:
		return e.Args
	case *ExprNode:
		return e.Args
	case map[string]interface{}:
		a, _ := e["args"].([]interface{})
		return a
	}
	return nil
}

// siDecodeDoc decodes a JSON document string into a generic map.
func siDecodeDoc(t *testing.T, s string) map[string]interface{} {
	t.Helper()
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatalf("decode document: %v", err)
	}
	return m
}

// siEqRHS navigates a model's first equation RHS in a decoded raw document.
func siRawFirstEqRHS(t *testing.T, comp map[string]interface{}) interface{} {
	t.Helper()
	eqs, ok := comp["equations"].([]interface{})
	if !ok || len(eqs) == 0 {
		t.Fatalf("component has no equations")
	}
	eq, _ := eqs[0].(map[string]interface{})
	return eq["rhs"]
}

// siCompareSansMetadata marshals the typed EsmFile, strips `metadata` from both
// it and the golden, and asserts structural equality of every other block.
func siCompareSansMetadata(t *testing.T, f *EsmFile, goldenPath string) {
	t.Helper()
	b, err := json.Marshal(f)
	if err != nil {
		t.Fatalf("marshal EsmFile: %v", err)
	}
	got := siDecodeDoc(t, string(b))
	delete(got, "metadata")

	gd, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden %s: %v", goldenPath, err)
	}
	want := siDecodeDoc(t, string(gd))
	delete(want, "metadata")

	if g, w := tiCanonJSON(t, got), tiCanonJSON(t, want); g != w {
		t.Errorf("expanded form diverges from golden (sans metadata):\n got=%s\nwant=%s", g, w)
	}
}

// ---------------------------------------------------------------------------
// Form A — subsystem-ref injection (§4.7 / §9.7.10)
// ---------------------------------------------------------------------------

func TestScopeInjection_FormA_SubsystemRef(t *testing.T) {
	dir := tiConfDir(t, "inject_subsystem_ref")

	f, err := Load(filepath.Join(dir, "fixture.esm"))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}

	// The mounted, agnostic leaf's D(c, wrt: lon) is lowered by the injected
	// rule at the mount; the subsystem resolves to an inline component (a raw
	// map), not a ref.
	runoff, ok := f.Models["Assembly"].Subsystems["Runoff"].(map[string]interface{})
	if !ok {
		t.Fatalf("Runoff subsystem did not resolve to an inline component: %T",
			f.Models["Assembly"].Subsystems["Runoff"])
	}
	rhsArgs := siNodeArgs(siRawFirstEqRHS(t, runoff))
	if len(rhsArgs) != 2 || siNodeOp(rhsArgs[1]) != "makearray" {
		t.Errorf("mounted leaf lon-derivative not lowered: op=%q", siNodeOp(rhsArgs[1]))
	}

	// Injected library brought its grid into the importing registry.
	if is, ok := f.IndexSets["lon"]; !ok || is.Size == nil || *is.Size != 288 {
		t.Errorf("index_sets.lon.size = %v; want 288", is.Size)
	}
	if is, ok := f.IndexSets["lat"]; !ok || is.Size == nil || *is.Size != 181 {
		t.Errorf("index_sets.lat.size = %v; want 181", is.Size)
	}

	// Round-trip golden: the resolved+lowered assembly; the injection field is
	// gone (form A does not survive parse → emit).
	siCompareSansMetadata(t, f, filepath.Join(dir, "expanded.esm"))

	// The leaf loads standalone with its D intact (agnostic; unlowered).
	leaf, err := Load(filepath.Join(dir, "leaf.esm"))
	if err != nil {
		t.Fatalf("load leaf: %v", err)
	}
	leafArgs := siNodeArgs(leaf.Models["Advection"].Equations[0].RHS)
	if len(leafArgs) != 2 || siNodeOp(leafArgs[1]) != "D" {
		t.Errorf("standalone leaf lon-derivative op = %q; want D", siNodeOp(leafArgs[1]))
	}

	// Negative twin: mounting WITHOUT injection loads cleanly (the D survives —
	// the op namespace is open); the unlowered_operator gate is an evaluation-
	// time concern, not a load error (N/A for this parse/serialize binding).
	ni, err := Load(filepath.Join(dir, "no_inject.esm"))
	if err != nil {
		t.Fatalf("load no_inject: %v", err)
	}
	niRunoff, ok := ni.Models["Assembly"].Subsystems["Runoff"].(map[string]interface{})
	if !ok {
		t.Fatalf("no_inject Runoff did not resolve to a component: %T",
			ni.Models["Assembly"].Subsystems["Runoff"])
	}
	niArgs := siNodeArgs(siRawFirstEqRHS(t, niRunoff))
	if len(niArgs) != 2 || siNodeOp(niArgs[1]) != "D" {
		t.Errorf("no_inject mounted lon-derivative op = %q; want D (unlowered)", siNodeOp(niArgs[1]))
	}
}

// ---------------------------------------------------------------------------
// Form B — coupling-entry injection (§10.8 / §9.7.10)
// ---------------------------------------------------------------------------

func TestScopeInjection_FormB_CouplingEntry(t *testing.T) {
	dir := tiConfDir(t, "inject_coupling_entry")

	got := tiExpandRaw(t, filepath.Join(dir, "fixture.esm"))
	doc := siDecodeDoc(t, got)
	models := doc["models"].(map[string]interface{})

	// Advection is discretized by name; its lon-derivative is lowered.
	advArgs := siNodeArgs(siRawFirstEqRHS(t, models["Advection"].(map[string]interface{})))
	if len(advArgs) != 2 || siNodeOp(advArgs[1]) != "makearray" {
		t.Errorf("Advection lon-derivative not lowered: op=%q", siNodeOp(advArgs[1]))
	}
	// Injected grid reached the importing registry.
	if isets, ok := doc["index_sets"].(map[string]interface{}); ok {
		lon, _ := isets["lon"].(map[string]interface{})
		if lon["size"] != float64(288) {
			t.Errorf("index_sets.lon.size = %v; want 288", lon["size"])
		}
	} else {
		t.Errorf("index_sets missing from expanded document")
	}
	// Emit (the 0-D partner) named no key and stays untouched.
	emitEq := models["Emit"].(map[string]interface{})["equations"].([]interface{})[0].(map[string]interface{})
	if siNodeOp(emitEq["lhs"]) != "D" {
		t.Errorf("Emit lhs op = %q; want D (untouched)", siNodeOp(emitEq["lhs"]))
	}
	// The injection map is consumed — form B does not survive parse → emit.
	coupling := doc["coupling"].([]interface{})
	if entry, ok := coupling[0].(map[string]interface{}); ok {
		if _, has := entry["expression_template_imports"]; has {
			t.Errorf("coupling entry retained expression_template_imports after load")
		}
	}

	// Full expanded golden (raw pipeline preserves metadata verbatim).
	want := tiGolden(t, filepath.Join(dir, "expanded.esm"))
	if got != want {
		t.Errorf("expanded form diverges from golden:\n got=%s\nwant=%s", got, want)
	}

	// Diagnostics (esm-spec §9.6.6).
	if _, err := Load(filepath.Join(dir, "neg_target_unknown.esm")); tiErrCode(t, err) != "template_inject_target_unknown" {
		t.Errorf("neg_target_unknown code = %s; want template_inject_target_unknown", tiErrCode(t, err))
	}
	if _, err := Load(filepath.Join(dir, "neg_target_is_loader.esm")); tiErrCode(t, err) != "template_inject_target_is_loader" {
		t.Errorf("neg_target_is_loader code = %s; want template_inject_target_is_loader", tiErrCode(t, err))
	}
}

// ---------------------------------------------------------------------------
// Form C — test/example injection (§6.6.6 / §9.7.10)
// ---------------------------------------------------------------------------

func TestScopeInjection_FormC_TestBlock(t *testing.T) {
	dir := tiConfDir(t, "inject_test_block")

	f, err := Load(filepath.Join(dir, "fixture.esm"))
	if err != nil {
		t.Fatalf("load fixture: %v", err)
	}
	adv := f.Models["Advection"]

	// The enclosing component round-trips with its D INTACT (form C does not
	// lower it at load) and each test keeps its import field (survives emit).
	advArgs := siNodeArgs(adv.Equations[0].RHS)
	if len(advArgs) != 2 || siNodeOp(advArgs[1]) != "D" {
		t.Errorf("enclosing component lon-derivative op = %q; want D (intact)", siNodeOp(advArgs[1]))
	}
	if len(adv.Tests) != 2 {
		t.Fatalf("got %d tests; want 2", len(adv.Tests))
	}
	for i, tst := range adv.Tests {
		if len(tst.ExpressionTemplateImports) == 0 {
			t.Errorf("test[%d] (%s) lost its expression_template_imports", i, tst.ID)
		}
	}

	// Round-trip golden (component D intact + both tests keep their imports).
	// This binding numerically simulates no PDEs, so form C is a round-trip
	// contract only — no ephemeral lowered build is asserted.
	siCompareSansMetadata(t, f, filepath.Join(dir, "roundtrip.esm"))
}
