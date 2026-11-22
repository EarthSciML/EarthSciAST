package esm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mount_template_registry_test.go drives
// tests/conformance/expression_templates/mount_registry_merge/ and
// mount_shared_definition/ (esm-spec §9.6.4 rules 1 and 7, §10.7): a mounted
// leaf keeps its references; its definitions join the mounting component's
// registry in the leaf's own names, a body's free names are read in the scope
// of the subsystem that owns the reference, flatten closes every body, and
// the registry merge keeps one entry per distinct definition. The goldens are
// written by Julia and compared byte for byte.

func mtrPath(dir, file string) string {
	return oolConf(dir, file)
}

func mtrBlock(reg *orderedMap) string {
	return emitCanonicalString(map[string]any{"operators": reg})
}

func mtrFlat(t *testing.T, p string) string {
	t.Helper()
	file, err := LoadPath(p)
	if err != nil {
		t.Fatalf("LoadPath(%s): %v", p, err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten(%s): %v", p, err)
	}
	reg := newOrderedMap()
	for _, e := range flat.TemplateRegistry {
		reg.set(e.Name, e.Declaration)
	}
	return mtrBlock(reg)
}

func mtrLoaded(t *testing.T, p string) (*ESMFile, string) {
	t.Helper()
	file, err := LoadPath(p)
	if err != nil {
		t.Fatalf("LoadPath(%s): %v", p, err)
	}
	reg := file.componentTemplates["models.Host"]
	if reg == nil {
		t.Fatalf("%s: no registry for models.Host after load", p)
	}
	return file, mtrBlock(reg)
}

func mtrGolden(t *testing.T, dir, file string) string {
	t.Helper()
	b, err := os.ReadFile(mtrPath(dir, file))
	if err != nil {
		t.Fatalf("read golden %s/%s: %v", dir, file, err)
	}
	return string(b)
}

func mtrCompare(t *testing.T, what, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("%s != golden (byte for byte)\n--- got ---\n%s\n--- want ---\n%s", what, got, want)
	}
}

func TestMountRegistryMergeGoldens(t *testing.T) {
	d := "mount_registry_merge"
	mtrCompare(t, "flattened registry of fixture.esm",
		mtrFlat(t, mtrPath(d, "fixture.esm")), mtrGolden(t, d, "flattened_registry.esm"))
	mtrCompare(t, "flattened registry of inline_form.esm",
		mtrFlat(t, mtrPath(d, "inline_form.esm")), mtrGolden(t, d, "inline_flattened_registry.esm"))
	_, loaded := mtrLoaded(t, mtrPath(d, "fixture.esm"))
	mtrCompare(t, "loaded registry of models.Host", loaded, mtrGolden(t, d, "loaded_registry.esm"))
	p := mtrPath(d, "inline_form.esm")
	src, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	emitted, err := EmitReferencePreserving(string(src), filepath.Dir(p), nil)
	if err != nil {
		t.Fatalf("EmitReferencePreserving(inline_form.esm): %v", err)
	}
	mtrCompare(t, "emitted inline_form.esm", emitted, mtrGolden(t, d, "inline_emitted.esm"))
}

// mtrModelEquations renders the equations of the (sub)system at `path` below
// the loaded document's models.Host (the expanded image a load produces).
func mtrModelEquations(t *testing.T, file *ESMFile, path ...string) string {
	t.Helper()
	host, ok := file.Models["Host"]
	if !ok {
		t.Fatal("no model Host")
	}
	if len(path) == 0 {
		var parts []string
		for _, eq := range host.Equations {
			parts = append(parts, showJSON(eq.LHS)+" = "+showJSON(eq.RHS))
		}
		return strings.Join(parts, "\n")
	}
	node := any(host.Subsystems[path[0]])
	for _, p := range path[1:] {
		node = node.(map[string]any)["subsystems"].(map[string]any)[p]
	}
	m, ok := node.(map[string]any)
	if !ok {
		t.Fatalf("subsystem %v is %T, not a raw model", path, node)
	}
	return showJSON(m["equations"])
}

func TestMountSharedDefinition(t *testing.T) {
	d := "mount_shared_definition"
	p := mtrPath(d, "fixture.esm")
	mtrCompare(t, "flattened registry", mtrFlat(t, p), mtrGolden(t, d, "flattened_registry.esm"))
	file, loaded := mtrLoaded(t, p)
	mtrCompare(t, "loaded registry of models.Host", loaded, mtrGolden(t, d, "loaded_registry.esm"))

	reg := file.componentTemplates["models.Host"]
	keys := append([]string(nil), reg.keys...)
	want := map[string]bool{"Host.rate": true, "Sub1.rate": true, "loss": true, "pull": true}
	if len(keys) != len(want) {
		t.Errorf("Host registry = %v; want one entry per definition %v", keys, want)
	}
	for _, k := range keys {
		if !want[k] {
			t.Errorf("Host registry has unexpected entry %q", k)
		}
	}

	// The load expands every reference; each subsystem's expansion reads its
	// OWN names: Sub1's and Sub2's `k`, Inner's `g`, Host's `g`.
	for _, sub := range []string{"Sub1", "Sub2"} {
		eqs := mtrModelEquations(t, file, sub)
		if !strings.Contains(eqs, `"k"`) || strings.Contains(eqs, "apply_operator") {
			t.Errorf("%s equations must read its own k, expanded: %s", sub, eqs)
		}
	}
	inner := mtrModelEquations(t, file, "Inner")
	if !strings.Contains(inner, `"g"`) || strings.Contains(inner, "apply_operator") {
		t.Errorf("Inner equations must read its own g, expanded: %s", inner)
	}

	// Flattened, the names are scoped to the subsystem owning each reference.
	file, err := LoadPath(p)
	if err != nil {
		t.Fatal(err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatal(err)
	}
	reads := map[string][]string{
		"Host.Sub1.c":  {`"Host.Sub1.k"`},
		"Host.Sub1.d":  {`"Host.Sub1.k"`},
		"Host.Sub2.c":  {`"Host.kh"`},
		"Host.Sub2.d":  {`"Host.kh"`},
		"Host.z":       {`"Host.g"`},
		"Host.Inner.w": {`"Host.Inner.g"`},
	}
	found := map[string]bool{}
	for _, eq := range flat.Equations {
		v := lhsDependentVar(eq.LHS)
		names, ok := reads[v]
		if !ok {
			continue
		}
		found[v] = true
		rhs := showJSON(eq.RHS)
		for _, n := range names {
			if !strings.Contains(rhs, n) {
				t.Errorf("D(%s) must read %s, got %s", v, n, rhs)
			}
		}
	}
	for v := range reads {
		if !found[v] {
			t.Errorf("no flattened equation defines %s", v)
		}
	}
}

// The typed mount path (ResolveSubsystemRefs on a file loaded without its
// mounts) merges the mounted leaf's definitions into the mounting model's
// registry by the same rule, and expands the leaf's references against it, as
// a load does.
func TestMountRegistryMergeTypedPath(t *testing.T) {
	d := "mount_registry_merge"
	p := mtrPath(d, "fixture.esm")
	src, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	file, err := LoadString(string(src))
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	if _, isRef := file.Models["Host"].Subsystems["Sub"].(map[string]any)["ref"]; !isRef {
		t.Fatal("LoadString resolved the mount itself; this test needs it left for ResolveSubsystemRefs")
	}
	if err := ResolveSubsystemRefs(file, filepath.Dir(p)); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}
	reg := file.componentTemplates["models.Host"]
	if reg == nil {
		t.Fatal("no registry for models.Host")
	}
	loaded, _ := mtrLoaded(t, p)
	want := loaded.componentTemplates["models.Host"]
	if reg.len() != want.len() {
		t.Errorf("typed-path registry %v; load gives %v", reg.keys, want.keys)
	}
	for _, k := range want.keys {
		if !reg.has(k) || !jsonEqual(reg.get(k), want.get(k)) {
			t.Errorf("typed-path registry entry %q = %v; load gives %v", k, reg.get(k), want.get(k))
		}
	}
	got := mtrModelEquations(t, file, "Sub")
	if exp := mtrModelEquations(t, loaded, "Sub"); got != exp {
		t.Errorf("typed-path Sub equations\n got %s\nwant %s", got, exp)
	}
	if _, has := file.Models["Host"].Subsystems["Sub"].(map[string]any)["operators"]; has {
		t.Error("the mounted Sub still carries its block after the merge")
	}
}

// mount_host_rule (esm-spec §9.6.3): Host's `match` rule `cube` fires on the
// content of the models Host mounts, at any depth (Sub, Sub's own mount Deep,
// and Bare, which declares no templates), as on an authored subsystem's.
func TestMountHostRule(t *testing.T) {
	d := "mount_host_rule"
	p := mtrPath(d, "fixture.esm")
	file, loaded := mtrLoaded(t, p)
	mtrCompare(t, "loaded registry of models.Host", loaded, mtrGolden(t, d, "loaded_registry.esm"))
	mtrCompare(t, "flattened registry", mtrFlat(t, p), mtrGolden(t, d, "flattened_registry.esm"))
	siCompareSansMetadata(t, file, mtrPath(d, "expanded.esm"))
}

// TestFlattenClosesJoinNames: esm-spec §10.7, a body's `join` clauses name
// component variables it reads nowhere else (an overlap gate's envelope
// factors, an `on` clause's key columns); closing makes them parameters, as
// it does the body's variable leaves.
func TestFlattenClosesJoinNames(t *testing.T) {
	d := "flatten_closes_join_names"
	mtrCompare(t, "flattened registry", mtrFlat(t, mtrPath(d, "fixture.esm")), mtrGolden(t, d, "flattened_registry.esm"))
}

// mtrLoadWithLeaf loads host from a directory that also holds leaf.esm.
func mtrLoadWithLeaf(t *testing.T, host, leaf string) (*ESMFile, error) {
	t.Helper()
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "leaf.esm"), []byte(leaf), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "host.esm"), []byte(host), 0o600); err != nil {
		t.Fatal(err)
	}
	return LoadPath(filepath.Join(d, "host.esm"))
}

// A leaf declaring `scale(q) = 3q`, whose own equation calls it.
const mtrScaleLeaf = `{"esm": "2.4.0", "metadata": {"name": "leaf"}, "models": {"L": {
  "variables": {"a": {"type": "parameter", "default": 1.0}, "b": {"type": "unknown"}},
  "equations": [{"lhs": "b", "rhs": {"op": "scale", "args": ["a"]}}],
  "operators": {"scale": {"params": ["q"], "body": {"op": "*", "args": [3, "q"]}}}}}}`

// esm-spec §4.7, §9.6.3 constraint 4, §9.6.12: a mounted leaf's definitions
// are local to the leaf. A call in the mounting component of an operator only
// the leaf defines stays a placeholder there, whatever its arity, and a call
// the mounting component's own definitions take resolves to them alone; the
// leaf's own call still resolves to the leaf's definition.
func TestMountedLeafDefinitionsAreLeafLocal(t *testing.T) {
	host := `{"esm": "2.4.0", "metadata": {"name": "host"}, "models": {"H": {
  "variables": {"x": {"type": "parameter", "default": 1.0}, "y": {"type": "unknown"}, "z": {"type": "unknown"}},
  "equations": [{"lhs": "y", "rhs": {"op": "scale", "args": ["x"]}},
                {"lhs": "z", "rhs": {"op": "scale", "args": ["x", "x"]}}],
  "subsystems": {"leaf": {"ref": "leaf.esm"}}}}}`
	f, err := mtrLoadWithLeaf(t, host, mtrScaleLeaf)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	eqs := f.Models["H"].Equations
	for i, want := range []int{1, 2} {
		n, ok := asExprNode(eqs[i].RHS)
		if !ok || n.Op != "scale" || len(n.Args) != want {
			t.Errorf("host equation %d rhs = %#v; want the placeholder scale call with %d operand(s)", i, eqs[i].RHS, want)
		}
	}
	leaf, _ := subsystemAsMap(f.Models["H"].Subsystems["leaf"])
	leafEqs, _ := leaf["equations"].([]any)
	if len(leafEqs) != 1 || !strings.Contains(emitCanonicalString(leafEqs[0]), `"*"`) {
		t.Errorf("leaf equation = %v; want its call resolved to the leaf's definition", leafEqs)
	}

	// The host defines its own two-operand `scale`: its call resolves to that
	// definition, never to the leaf's one-operand one.
	host = `{"esm": "2.4.0", "metadata": {"name": "host"}, "models": {"H": {
  "variables": {"x": {"type": "parameter", "default": 1.0}, "z": {"type": "unknown"}},
  "equations": [{"lhs": "z", "rhs": {"op": "scale", "args": ["x", "x"]}}],
  "operators": {"scale": {"params": ["q", "r"], "body": {"op": "+", "args": ["q", "r"]}}},
  "subsystems": {"leaf": {"ref": "leaf.esm"}}}}}`
	f, err = mtrLoadWithLeaf(t, host, mtrScaleLeaf)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got, err := Evaluate(f.Models["H"].Equations[0].RHS, map[string]float64{"x": 1}); err != nil || got != 2 {
		t.Errorf("host rhs = %v, %v; want 2 (x + x at x = 1, the host's definition)", got, err)
	}
	// A host call the host's definitions do not take is an arity mismatch
	// counted against the host's definitions only.
	host = strings.Replace(host, `"args": ["x", "x"]`, `"args": ["x"]`, 1)
	_, err = mtrLoadWithLeaf(t, host, mtrScaleLeaf)
	if got := tiErrCode(t, err); got != codeOperatorArityMismatch {
		t.Errorf("code = %q; want %q (%v)", got, codeOperatorArityMismatch, err)
	}
}

// An authored subsystem's own definitions resolve the calls in that subsystem
// (and below it), together with the mounting component's, but never a call in
// the mounting component itself.
func TestInlineSubsystemDefinitionsResolveOnItsPath(t *testing.T) {
	f, err := LoadString(`{"esm": "2.4.0", "metadata": {"name": "host"}, "models": {"H": {
  "variables": {"x": {"type": "parameter", "default": 1.0}, "y": {"type": "unknown"}},
  "equations": [{"lhs": "y", "rhs": {"op": "twice", "args": ["x"]}}],
  "operators": {"halve": {"params": ["q"], "body": {"op": "/", "args": ["q", 2]}}},
  "subsystems": {"S": {
    "variables": {"a": {"type": "parameter", "default": 1.0}, "b": {"type": "unknown"}, "c": {"type": "unknown"}},
    "equations": [{"lhs": "b", "rhs": {"op": "twice", "args": ["a"]}},
                  {"lhs": "c", "rhs": {"op": "halve", "args": ["a"]}}],
    "operators": {"twice": {"params": ["q"], "body": {"op": "*", "args": [2, "q"]}}}}}}}}`)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if n, ok := asExprNode(f.Models["H"].Equations[0].RHS); !ok || n.Op != "twice" {
		t.Errorf("host rhs = %#v; want the placeholder twice call", f.Models["H"].Equations[0].RHS)
	}
	sub, _ := subsystemAsMap(f.Models["H"].Subsystems["S"])
	eqs, _ := sub["equations"].([]any)
	got := emitCanonicalString(eqs)
	if strings.Contains(got, `"twice"`) || strings.Contains(got, `"halve"`) {
		t.Errorf("subsystem equations = %s; want both calls resolved", got)
	}
}
