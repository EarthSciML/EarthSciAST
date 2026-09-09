package esm

import (
	"encoding/json"
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
