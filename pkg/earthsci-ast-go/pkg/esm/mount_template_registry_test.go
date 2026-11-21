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
	return emitCanonicalString(map[string]any{"expression_templates": reg})
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
	var node any = host.Subsystems[path[0]]
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
		if !strings.Contains(eqs, `"k"`) || strings.Contains(eqs, "apply_expression_template") {
			t.Errorf("%s equations must read its own k, expanded: %s", sub, eqs)
		}
	}
	inner := mtrModelEquations(t, file, "Inner")
	if !strings.Contains(inner, `"g"`) || strings.Contains(inner, "apply_expression_template") {
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
	if _, has := file.Models["Host"].Subsystems["Sub"].(map[string]any)["expression_templates"]; has {
		t.Error("the mounted Sub still carries its block after the merge")
	}
}
