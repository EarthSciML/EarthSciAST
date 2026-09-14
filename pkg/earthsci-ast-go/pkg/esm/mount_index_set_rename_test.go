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

// esm-spec §4.7 "Two mount forms, one mechanism": the top-level form lands its
// component as a TOP-LEVEL system, which is exactly what the form mounts — so it
// has to compose with itself. A binding that resolves one level deep picks the
// leaf's own UNRESOLVED `{ref}` edge out of its `models` and treats it as the
// component.
func TestTopLevelModelRefResolvesAMountedAssembly(t *testing.T) {
	f, err := LoadPath(filepath.Join("..", "..", "..", "..", "tests", "valid", "mount_chain_outer.esm"))
	if err != nil {
		t.Fatalf("LoadPath(mount_chain_outer.esm): %v", err)
	}
	deep, ok := f.Models["Deep"]
	if !ok {
		t.Fatalf("the assembly did not mount; models = %v", sortedKeys(f.Models))
	}
	if _, hasVar := deep.Variables["Tsoil"]; !hasVar {
		t.Fatalf("the inner mount did not resolve through; variables = %v", sortedKeys(deep.Variables))
	}
	// The axis name the INNER edge chose reaches the OUTER document's registry.
	if _, ok := f.IndexSets["soil_lev"]; !ok {
		t.Errorf("the inner edge's renamed axis should merge up; index_sets = %v", sortedKeys(f.IndexSets))
	}
	if _, ok := f.IndexSets["lev"]; ok {
		t.Errorf("the pre-rename axis must not survive; index_sets = %v", sortedKeys(f.IndexSets))
	}
}

// Which attachment point mounted a file cannot change what that file IS.
func TestSubsystemRefResolvesAMountedAssembly(t *testing.T) {
	f, err := LoadPath(filepath.Join("..", "..", "..", "..", "tests", "valid", "mount_chain_via_subsystem.esm"))
	if err != nil {
		t.Fatalf("LoadPath(mount_chain_via_subsystem.esm): %v", err)
	}
	host, ok := f.Models["Host"]
	if !ok {
		t.Fatalf("models = %v", sortedKeys(f.Models))
	}
	deep, ok := host.Subsystems["Deep"].(map[string]any)
	if !ok {
		t.Fatalf("the subsystem did not resolve to a component; got %T", host.Subsystems["Deep"])
	}
	if _, stillAnEdge := deep["ref"]; stillAnEdge {
		t.Fatalf("a bare mount edge was spliced in as the component: %v", deep)
	}
	vars, _ := deep["variables"].(map[string]any)
	if _, hasVar := vars["Tsoil"]; !hasVar {
		t.Errorf("the inner mount did not resolve through; got %v", deep)
	}
	if _, ok := f.IndexSets["soil_lev"]; !ok {
		t.Errorf("the inner edge's renamed axis should merge up; index_sets = %v", sortedKeys(f.IndexSets))
	}
}

// Composition without cycle detection is unbounded recursion. `visited` is
// path-scoped (pushed on enter, popped on exit), so the same component file may
// be mounted by several keys — only a cycle ALONG THE CURRENT PATH is the error.
func TestTopLevelModelRefCycleAcrossTheChain(t *testing.T) {
	dir := t.TempDir()
	doc := func(name, ref string) string {
		return `{"esm":"1.0.0","metadata":{"name":"` + name + `"},"models":{"M":{"ref":"` + ref + `"}}}`
	}
	for _, f := range []struct{ name, body string }{
		{"a.esm", doc("a", "./b.esm")},
		{"b.esm", doc("b", "./a.esm")},
		{"root.esm", doc("root", "./a.esm")},
	} {
		if err := os.WriteFile(filepath.Join(dir, f.name), []byte(f.body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	_, err := LoadPath(filepath.Join(dir, "root.esm"))
	if err == nil {
		t.Fatal("a mount cycle must be an error, not a silently truncated document")
	}
	if !strings.Contains(err.Error(), "circular") {
		t.Errorf("the diagnostic should name the cycle; got: %v", err)
	}
	// ... and every frame of it names the mount form it is talking about. The
	// chain here is top-level mounts end to end, so the word "subsystem" as a
	// NOUN for one of these edges would be wrong wherever it appeared —
	// including in the ref loader, which is the deepest frame and the last one
	// to learn which form it was called at.
	if strings.Contains(err.Error(), `subsystem "`) {
		t.Errorf("a top-level mount was reported as a subsystem; got: %v", err)
	}
	if !strings.Contains(err.Error(), "top-level model") {
		t.Errorf("the diagnostic should name the mount form; got: %v", err)
	}
}

// The other diagnostic the ref loader raises, at depth 1 so no outer frame can
// supply the noun for it: a top-level mount whose target does not exist.
func TestTopLevelModelRefMissingTargetNamesTheMountForm(t *testing.T) {
	dir := t.TempDir()
	root := `{"esm":"1.0.0","metadata":{"name":"root"},"models":{"M":{"ref":"./nope.esm"}}}`
	rootPath := filepath.Join(dir, "root.esm")
	if err := os.WriteFile(rootPath, []byte(root), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := LoadPath(rootPath)
	if err == nil {
		t.Fatal("an unreadable mount target must be an error")
	}
	if strings.Contains(err.Error(), `subsystem "`) {
		t.Errorf("a top-level mount was reported as a subsystem; got: %v", err)
	}
	if !strings.Contains(err.Error(), "top-level model") {
		t.Errorf("the diagnostic should name the mount form; got: %v", err)
	}
}

// esm-spec §4.7 "Two mount forms, one mechanism", applied to ROUND TRIP. A
// `subsystems.<k>` mount edge survives a load that does not resolve refs,
// because that map is `map[string]any` and keeps it verbatim. `Models` is a
// `map[string]Model`, so a top-level `{ref}` decodes to an EMPTY Model — and
// LoadString/LoadDocument do not resolve refs, only LoadPath does. Without the
// serializer writing the unconsumed edge back out, emitting such a document
// drops the `ref`, its `bindings` and its `index_set_rename` with nothing red.
func TestUnresolvedTopLevelMountSurvivesSerialization(t *testing.T) {
	fixture := filepath.Join("..", "..", "..", "..", "tests", "valid", "mount_rename_two_columns_toplevel.esm")
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	f, err := LoadString(string(data), WithBasePath(filepath.Dir(fixture)))
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	out, err := f.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON: %v", err)
	}
	var round map[string]any
	if err := json.Unmarshal(out, &round); err != nil {
		t.Fatal(err)
	}
	models, _ := round["models"].(map[string]any)
	soil, _ := models["Soil"].(map[string]any)
	if soil["ref"] != "./mount_rename_soil_column.esm" {
		t.Errorf("the mount edge's ref was lost; got %v", soil)
	}
	if _, ok := soil["index_set_rename"]; !ok {
		t.Errorf("the mount edge's index_set_rename was lost; got %v", soil)
	}

	// ... and a mount the resolver DID consume is never written back as an edge.
	rf, err := LoadPath(fixture)
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	rout, err := rf.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON(resolved): %v", err)
	}
	if err := json.Unmarshal(rout, &round); err != nil {
		t.Fatal(err)
	}
	models, _ = round["models"].(map[string]any)
	soil, _ = models["Soil"].(map[string]any)
	if _, stillAnEdge := soil["ref"]; stillAnEdge {
		t.Errorf("a resolved mount must emit its component, not the edge; got %v", soil)
	}
}

// The per-edge rule of esm-spec §4.7 has two ends, and they are easy to
// collapse into one. These two tests pin them apart.
//
// End one: an edge may NOT rename an axis that reached the registry ONLY
// through a mount nested inside the referenced document — that axis is renamed
// at ITS own edge, so naming it here is `subsystem_index_set_rename_unknown_name`.
func TestMountRenameCannotNameAnAxisANestedMountContributed(t *testing.T) {
	for _, tc := range []struct{ file, noun string }{
		{"rename_scope_nested_only_axis.esm", "subsystem ref"},
		{"rename_scope_nested_only_axis_toplevel.esm", "top-level model ref"},
	} {
		_, err := LoadPath(mrFixture(t, "fixtures", "mount_edge_rename_nested_scope", tc.file))
		if err == nil {
			t.Fatalf("%s: loaded, but `lev` is declared only by the leaf's own nested mount", tc.file)
		}
		if !strings.Contains(err.Error(), "subsystem_index_set_rename_unknown_name") {
			t.Errorf("%s: want subsystem_index_set_rename_unknown_name, got: %v", tc.file, err)
		}
		if !strings.Contains(err.Error(), tc.noun) || !strings.Contains(err.Error(), "index set 'lev'") {
			t.Errorf("%s: the diagnostic must name this edge and the axis: %v", tc.file, err)
		}
	}
}

// End two: an edge MUST rename an axis the referenced document declares
// ITSELF, even where a component it mounts declares a deep-equal one of the
// same name — §4.7's deep-equal merge has already made those ONE axis, so the
// rename covers the whole resolved leaf. The observable difference is the
// registry: `{soil_lev}` alone with the nested component's `shape` re-pointed,
// not `{lev, soil_lev}` with the nested component still on `lev`.
func TestMountRenameReachesAnAxisSharedWithANestedMount(t *testing.T) {
	for _, name := range []string{
		"rename_scope_shared_axis.esm",
		"rename_scope_shared_axis_toplevel.esm",
	} {
		f, err := LoadPath(mrFixture(t, "fixtures", "mount_edge_rename_nested_scope", name))
		if err != nil {
			t.Fatalf("LoadPath(%s): %v", name, err)
		}
		if len(f.IndexSets) != 1 {
			t.Errorf("%s: registry = %v; want exactly one entry, the post-rename name", name, f.IndexSets)
		}
		if s, ok := f.IndexSets["soil_lev"]; !ok || s.Size == nil || *s.Size != 4 {
			t.Errorf("%s: soil_lev = %v; want size 4", name, f.IndexSets["soil_lev"])
		}
		b, err := json.Marshal(f)
		if err != nil {
			t.Fatalf("%s: marshal: %v", name, err)
		}
		if strings.Contains(string(b), `"lev"`) {
			t.Errorf("%s: a reference to the pre-rename name survived in the mounted subtree", name)
		}
	}
}

// esm-spec §4.7 "Which environment it folds against": a merge folds against the
// closed metaparameter environment of whatever registry it lands in.
//
// The grandchild sizes an axis "n_lev" and carries no §9.7 machinery, so the
// name survives its own load unfolded; the leaf declares n_lev = 4 and mounts
// it; the assembly declares an unrelated n_lev = 9 and mounts the leaf. The
// axis lands in the LEAF's registry, so the leaf's close speaks and the answer
// is 4. This binding answered 9 before the rule was settled, letting an
// assembler's unrelated same-named metaparameter resize an axis the leaf owns.
func TestMergeFoldsAgainstTheRegistryItLandsIn(t *testing.T) {
	f, err := LoadPath(mrFixture(t, "fixtures", "mount_merge_fold_env", "fold_env_root.esm"))
	if err != nil {
		t.Fatalf("LoadPath(fold_env_root): %v", err)
	}
	got := f.IndexSets["prof"]
	if got.Size == nil || *got.Size != 4 {
		t.Errorf("prof size = %v; want 4 (the LEAF's n_lev, not the assembly's 9)", got.Size)
	}

	// And "the leaf's closed environment" means CLOSED: an explicit edge
	// binding closes the referenced document and wins over its own default
	// (§9.7.6 site 3), so the same axis is 7 when the edge binds 7. An axis the
	// leaf declares ITSELF already folds to 7 through that close, so answering
	// 4 here would make one resolved document disagree with itself.
	bf, err := LoadPath(mrFixture(t, "fixtures", "mount_merge_fold_env", "fold_env_bound_root.esm"))
	if err != nil {
		t.Fatalf("LoadPath(fold_env_bound_root): %v", err)
	}
	bound := bf.IndexSets["prof"]
	if bound.Size == nil || *bound.Size != 7 {
		t.Errorf("prof size = %v; want 7 (the edge binding closes the leaf)", bound.Size)
	}
}

// The RAISED FLOOR, at the seam the §4.7 inline/merge reorder needs it.
//
// esm-spec §4.7 resolves a `{ref}` "before validation or any other
// processing", which puts a mounted leaf's content in the document BEFORE the
// esm-version gates run. A legal 1.0.0 assembly that mounts a `faq`-using leaf
// then CONTAINS `faq` without ever having spelled it, and the gate refuses a
// document nobody authored wrongly. The Julia reference answers this by not
// gating an already-inlined document and raising the floor instead, "exactly as
// `emit` does" (docs/content/rfcs/faq-node-rename.md §5.5).
//
// This binding already has that stamp — `raiseFaqEsmFloor`, applied on emit —
// and the reorder needs it applied one step earlier, to the inlined text before
// LoadString gates it. Pinned here so the mechanism is in place and known-good
// ahead of the reorder rather than debugged alongside it.
func TestRaisedFloorAdmitsAnInlinedFaqDocument(t *testing.T) {
	leaf, err := os.ReadFile(mrFixture(t, "valid", "mount_rename_atm_column.esm"))
	if err != nil {
		t.Fatalf("read the faq-using leaf: %v", err)
	}
	var leafDoc map[string]any
	if err := json.Unmarshal(leaf, &leafDoc); err != nil {
		t.Fatalf("decode the leaf: %v", err)
	}
	// The assembly as the reorder hands it to LoadString: the leaf's component
	// already spliced in, and the assembly's own authored `esm` still 1.0.0.
	inlined := map[string]any{
		"esm": "1.0.0",
		"metadata": map[string]any{
			"name": "inlined_assembly", "description": "a 1.0.0 assembly that CONTAINS faq only because a mount was inlined into it", "license": "MIT",
		},
		"index_sets": leafDoc["index_sets"],
		"models":     leafDoc["models"],
	}
	b, err := json.Marshal(inlined)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}

	// Ungated, it is refused — which is the failure the reorder would otherwise
	// surface on six of this package's tests.
	if _, err := LoadString(string(b)); err == nil {
		t.Fatal("a 1.0.0 document containing faq loaded ungated; the gate is not what this test thinks")
	} else if !strings.Contains(err.Error(), "faq_version_too_old") {
		t.Fatalf("want faq_version_too_old, got: %v", err)
	}

	// With the floor raised, it loads — and the floor only ever raises.
	raised := raiseFaqEsmFloor(string(b))
	f, err := LoadString(raised)
	if err != nil {
		t.Fatalf("the raised floor must admit the inlined document: %v", err)
	}
	if f.ESM != "1.1.0" {
		t.Errorf("esm = %q; want the raised 1.1.0 floor", f.ESM)
	}
}
