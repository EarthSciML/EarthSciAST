package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set
// renaming") — the fix for EarthSciML/EarthSciAST#198 item 4.
//
// `index_sets` is a DOCUMENT-scoped registry, so a document that mounts a
// 59-layer atmospheric column and a 4-layer soil column — both of which spell
// their axis `lev`, because both come from the same one-dimensional column
// family at different lengths — hits the §4.7 deep-equal-or-error merge and
// fails with
// `subsystem_index_set_conflict`. That scoping is load-bearing, so the fix is
// not to re-scope it but to let the ASSEMBLER say "this mount's `lev` is not
// that mount's `lev`" at the edge.

func mrFixture(t *testing.T, parts ...string) string {
	t.Helper()
	return filepath.Join(append([]string{tiRepoRoot(t), "tests"}, parts...)...)
}

func TestMountRenameTwoColumnsCoexist(t *testing.T) {
	f, err := LoadPath(mrFixture(t, "valid", "mount_rename_two_columns.esm"))
	if err != nil {
		t.Fatalf("LoadPath(mount_rename_two_columns): %v", err)
	}
	if f.IndexSets["lev"].Size == nil || *f.IndexSets["lev"].Size != 59 {
		t.Errorf("lev size = %v; want 59 (the un-renamed atmospheric mount)", f.IndexSets["lev"].Size)
	}
	if f.IndexSets["soil_lev"].Size == nil || *f.IndexSets["soil_lev"].Size != 4 {
		t.Errorf("soil_lev size = %v; want 4 (the renamed soil mount)", f.IndexSets["soil_lev"].Size)
	}
}

// Transitivity (esm-spec §4.7): the rename rewrites the mounted component's own
// references, not just the registry key — a `shape` list that still said `lev`
// would resolve against the 59-layer axis and allocate 59 soil layers.
func TestMountRenameRewritesMountedComponent(t *testing.T) {
	f, err := LoadPath(mrFixture(t, "valid", "mount_rename_two_columns.esm"))
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	soil, ok := f.Models["Host"].Subsystems["Soil"]
	if !ok {
		t.Fatalf("Host.Soil not mounted; subsystems = %v", f.Models["Host"].Subsystems)
	}
	b, err := json.Marshal(soil)
	if err != nil {
		t.Fatalf("marshal Soil: %v", err)
	}
	text := string(b)
	if !strings.Contains(text, "soil_lev") {
		t.Errorf("renamed axis absent from the mounted component: %s", text)
	}
	if strings.Contains(text, `"lev"`) {
		t.Errorf("bare `lev` survives inside the renamed soil mount: %s", text)
	}
	atm, err := json.Marshal(f.Models["Host"].Subsystems["Atm"])
	if err != nil {
		t.Fatalf("marshal Atm: %v", err)
	}
	if !strings.Contains(string(atm), `"lev"`) {
		t.Errorf("the un-renamed atmospheric mount should be untouched: %s", atm)
	}
}

// A rename key that names nothing the RESOLVED mounted document declares is a
// typo, and renames never invent names (the §9.7.7 rule at a mount edge).
func TestMountRenameUnknownIndexSet(t *testing.T) {
	_, err := LoadPath(mrFixture(t, "invalid", "template_imports", "mount_rename_unknown_index_set.esm"))
	if err == nil {
		t.Fatal("a misspelled rename key must not load")
	}
	if !strings.Contains(err.Error(), CodeSubsystemIndexSetRenameUnknownName) ||
		!strings.Contains(err.Error(), "celsl") {
		t.Errorf("diagnostic should name the code and the offending key; got: %v", err)
	}
}

// esm-spec §4.7 "Where it applies": `index_set_rename` is normative at BOTH
// mount forms, "with the same meaning and the same pipeline", because "a binding
// MUST NOT make the two forms differ". This binding used not to inline a
// top-level `models.<k>` `{ref}` at all — `ESMFile.Models` is a
// `map[string]Model`, so the mount decoded to an EMPTY model and the edge, its
// rename included, was silently discarded. It now runs the same edge pipeline the
// `subsystems.<k>` form runs, so the pair of fixtures below is the same assembly
// written at the two attachment points and must come out the same.
func TestMountRenameAppliesAtTopLevelModelRef(t *testing.T) {
	f, err := LoadPath(mrFixture(t, "valid", "mount_rename_two_columns_toplevel.esm"))
	if err != nil {
		t.Fatalf("LoadPath(mount_rename_two_columns_toplevel): %v", err)
	}
	if f.IndexSets["lev"].Size == nil || *f.IndexSets["lev"].Size != 59 {
		t.Errorf("lev size = %v; want 59 (the un-renamed atmospheric mount)", f.IndexSets["lev"].Size)
	}
	if f.IndexSets["soil_lev"].Size == nil || *f.IndexSets["soil_lev"].Size != 4 {
		t.Errorf("soil_lev size = %v; want 4 (the renamed soil mount)", f.IndexSets["soil_lev"].Size)
	}
	// The component LANDS, which is the other half of the mount form: an empty
	// `Soil` would satisfy the registry assertions above and still have thrown
	// the mounted model away.
	soil, ok := f.Models["Soil"]
	if !ok || len(soil.Variables) == 0 {
		t.Fatalf("Soil did not mount as a top-level model; models = %v", sortedKeys(f.Models))
	}
	b, err := json.Marshal(soil)
	if err != nil {
		t.Fatalf("marshal Soil: %v", err)
	}
	if !strings.Contains(string(b), "soil_lev") {
		t.Errorf("renamed axis absent from the mounted component: %s", b)
	}
	if strings.Contains(string(b), `"lev"`) {
		t.Errorf("bare `lev` survives inside the renamed soil mount: %s", b)
	}
	atm, err := json.Marshal(f.Models["Atm"])
	if err != nil {
		t.Fatalf("marshal Atm: %v", err)
	}
	if !strings.Contains(string(atm), `"lev"`) {
		t.Errorf("the un-renamed atmospheric mount should be untouched: %s", atm)
	}
}

// The key check reaches the top-level form too: a binding that applied the field
// at one attachment point and ignored it at the other would accept this.
func TestMountRenameUnknownIndexSetAtTopLevelModelRef(t *testing.T) {
	_, err := LoadPath(mrFixture(t, "invalid", "template_imports",
		"mount_rename_unknown_index_set_toplevel.esm"))
	if err == nil {
		t.Fatal("a misspelled rename key must not load at a top-level model ref either")
	}
	if !strings.Contains(err.Error(), CodeSubsystemIndexSetRenameUnknownName) ||
		!strings.Contains(err.Error(), "celsl") {
		t.Errorf("diagnostic should name the code and the offending key; got: %v", err)
	}
	// The diagnostic says which mount form it is talking about.
	if !strings.Contains(err.Error(), "top-level model ref") {
		t.Errorf("diagnostic should name the mount form; got: %v", err)
	}
}

// esm-spec §4.7 "Resolution timing": a component mounted at the TOP LEVEL by
// `{ref}` is spliced in with its `tests` dropped, because an inline test asserts
// something about the leaf under the leaf's OWN standalone conditions and the
// mounting document may couple it. (A `subsystems.<k>` mount needs no such
// handling — a test targets a top-level component, so a subsystem's tests are
// never run by the mounting document either.)
func TestTopLevelModelRefDropsMountedTests(t *testing.T) {
	dir := t.TempDir()
	leaf := `{"esm":"1.0.0","metadata":{"name":"leaf"},
	  "models":{"Leaf":{
	    "variables":{"u":{"type":"unknown","units":"1","default":1.0}},
	    "equations":[{"lhs":{"op":"D","args":["u"],"wrt":"t"},
	                  "rhs":{"op":"*","args":[-1.0,"u"]}}],
	    "tests":[{"name":"decays","duration":1.0,
	              "assertions":[{"variable":"u","at":1.0,"expected":0.3679,"tolerance":{"abs":0.01}}]}]}}}`
	if err := os.WriteFile(filepath.Join(dir, "leaf.esm"), []byte(leaf), 0o600); err != nil {
		t.Fatal(err)
	}
	host := `{"esm":"1.0.0","metadata":{"name":"host"},
	  "models":{"Mounted":{"ref":"./leaf.esm"}}}`
	hostPath := filepath.Join(dir, "host.esm")
	if err := os.WriteFile(hostPath, []byte(host), 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := LoadPath(hostPath)
	if err != nil {
		t.Fatalf("LoadPath(host): %v", err)
	}
	m, ok := f.Models["Mounted"]
	if !ok || len(m.Variables) == 0 {
		t.Fatalf("the leaf did not mount; models = %v", sortedKeys(f.Models))
	}
	if len(m.Tests) != 0 {
		t.Errorf("a mounted component's inline tests must not cross the mount edge; got %d", len(m.Tests))
	}
}
