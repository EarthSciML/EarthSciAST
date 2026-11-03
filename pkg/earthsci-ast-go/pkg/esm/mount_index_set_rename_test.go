package esm

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
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

// esm-spec §8.9.4 "When the check is evaluated", under the §4.7 root reorder.
//
// LoadPath inlines the root document's refs BEFORE LoadString's own §9.7
// machinery, so the §9.6.3 fixpoint lowers through mounted content (issue
// #311). That also consumes each mounted leaf's `metaparameters` at its edge,
// so the text LoadString receives is no longer the authored text. The static
// `extent` check must still see the names collected from the AUTHORED tree —
// which LoadPath does by collecting them before it inlines and handing them to
// LoadString through an unexported option.
//
// Measured before that option existed: with the reorder active, six of the
// extent-scope tests failed with exactly the `ok` half's shape refused. So the
// first half is the regression detector for the option; the second half proves
// collecting from the authored tree widened the accepted set to what the mount
// declares and no further.
func TestReorderedLoadChecksExtentAgainstTheAuthoredTree(t *testing.T) {
	ok := mrFixture(t, "fixtures", "mount_hoist_extent", "hoist_extent_ok.esm")
	if _, err := LoadPath(ok); err != nil {
		t.Fatalf("an `extent` naming a metaparameter declared only by a mounted leaf must load "+
			"through the reordered path-based loader: %v", err)
	}

	typo := mrFixture(t, "fixtures", "mount_hoist_extent", "hoist_extent_typo.esm")
	_, err := LoadPath(typo)
	if err == nil {
		t.Fatal("an `extent` misspelling the mounted leaf's metaparameter must still be refused")
	}
	if !strings.Contains(err.Error(), string(CodeTemplateImportUnknownName)) || !strings.Contains(err.Error(), "N_RECS") {
		t.Errorf("error = %v; want %s naming N_RECS", err, CodeTemplateImportUnknownName)
	}
}

// esm-spec §4.7 "Two mount forms, one mechanism": a top-level
// `reaction_systems.<k>` `{ref}` mounts the leaf's reaction system under the key,
// through the same edge pipeline as a top-level `models.<k>` `{ref}`, whether
// the document is read by LoadPath (which inlines on the raw view) or by
// LoadString plus ResolveSubsystemRefs (which inlines on the typed file).
func TestTopLevelReactionSystemRefIsMounted(t *testing.T) {
	path := mrFixture(t, "fixtures", "mount_form_unsupported", "toplevel_reaction_system_ref.esm")
	check := func(how string, f *ESMFile) {
		t.Helper()
		rs, ok := f.ReactionSystems["Chem"]
		if !ok {
			t.Fatalf("%s: no reaction system Chem", how)
		}
		if len(rs.Species) != 2 || len(rs.Reactions) != 1 {
			t.Errorf("%s: Chem has %d species and %d reactions; want 2 and 1", how, len(rs.Species), len(rs.Reactions))
		}
	}
	f, err := LoadPath(path)
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	check("LoadPath", f)

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	g, err := LoadString(string(raw))
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	// Before resolution the edge survives emit as the edge it was authored as.
	out, err := ToJSONCompact(g)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `"ref":"./reaction_system_leaf.esm"`) {
		t.Errorf("an unresolved reaction_systems.<k> {ref} must emit as authored; got %s", out)
	}
	if err := ResolveSubsystemRefs(g, filepath.Dir(path)); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}
	check("LoadString+ResolveSubsystemRefs", g)
}

// tests/conformance/toplevel_reaction_system_ref/: each mount loads to the same
// `models` and `reaction_systems` as its inline twin, and each bad mount is
// refused with the code `load_errors` names.
func TestTopLevelReactionSystemRefConformanceFixtures(t *testing.T) {
	dir := mrFixture(t, "conformance", "toplevel_reaction_system_ref")
	raw, err := os.ReadFile(filepath.Join(dir, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var expected struct {
		ImplementedBy []string                       `json:"implemented_by"`
		Loads         map[string]string              `json:"loads"`
		LoadErrors    map[string]map[string][]string `json:"load_errors"`
	}
	if err := json.Unmarshal(raw, &expected); err != nil {
		t.Fatal(err)
	}
	listed := false
	for _, b := range expected.ImplementedBy {
		listed = listed || b == "go"
	}
	if !listed {
		t.Fatal("expected.json must list go as implementing the form")
	}
	components := func(fixture string) (any, any) {
		t.Helper()
		f, err := LoadPath(filepath.Join(dir, fixture))
		if err != nil {
			t.Fatalf("%s: %v", fixture, err)
		}
		out, err := ToJSON(f)
		if err != nil {
			t.Fatalf("%s: emit: %v", fixture, err)
		}
		var doc map[string]any
		if err := json.Unmarshal([]byte(out), &doc); err != nil {
			t.Fatal(err)
		}
		return doc["models"], doc["reaction_systems"]
	}
	for _, fixture := range sortedKeys(expected.Loads) {
		inline := expected.Loads[fixture]
		gotModels, gotRS := components(fixture)
		wantModels, wantRS := components(inline)
		if !reflect.DeepEqual(gotRS, wantRS) {
			t.Errorf("%s: reaction_systems differ from %s:\n got  %v\n want %v", fixture, inline, gotRS, wantRS)
		}
		if !reflect.DeepEqual(gotModels, wantModels) {
			t.Errorf("%s: models differ from %s:\n got  %v\n want %v", fixture, inline, gotModels, wantModels)
		}
	}
	for _, fixture := range sortedKeys(expected.LoadErrors) {
		code := ""
		for c, bindings := range expected.LoadErrors[fixture] {
			for _, b := range bindings {
				if b == "go" {
					code = c
				}
			}
		}
		_, err := LoadPath(filepath.Join(dir, fixture))
		if err == nil {
			t.Errorf("%s loaded; it must be refused", fixture)
			continue
		}
		if code == "" {
			continue
		}
		var et *ExpressionTemplateError
		if !errors.As(err, &et) || string(et.Code) != code {
			t.Errorf("%s: error %v; want %s", fixture, err, code)
			continue
		}
		if !strings.HasPrefix(et.Path, "/reaction_systems/") {
			t.Errorf("%s: path = %q; want /reaction_systems/<k>", fixture, et.Path)
		}
	}
}

// A top-level `reaction_systems.<k>` `{ref}` runs the whole edge pipeline
// (esm-spec §4.7): the edge's `bindings` close the leaf, its `index_sets` merge
// into the mounting document, and `index_set_rename` applies, as at `models.<k>`.
func TestTopLevelReactionSystemRefRunsTheEdgePipeline(t *testing.T) {
	dir := t.TempDir()
	leaf := `{"esm":"1.0.0","metadata":{"name":"rs_leaf","description":"probe"},
 "metaparameters":{"N":{"type":"integer","default":2}},
 "index_sets":{"x":{"kind":"interval","size":"N"}},
 "reaction_systems":{"Chem":{"species":{"A":{"units":"1","default":1.0}},
  "parameters":{"k":{"units":"1/s","default":0.3}},
  "reactions":[{"id":"R1","substrates":[{"species":"A","stoichiometry":1}],"products":null,"rate":"k"}]}}}`
	if err := os.WriteFile(filepath.Join(dir, "leaf.esm"), []byte(leaf), 0o644); err != nil {
		t.Fatal(err)
	}
	load := func(edge string) map[string]IndexSet {
		t.Helper()
		host := `{"esm":"1.0.0","metadata":{"name":"rs_host","description":"probe"},
 "reaction_systems":{"Chem":{"ref":"./leaf.esm"` + edge + `}}}`
		path := filepath.Join(dir, "host.esm")
		if err := os.WriteFile(path, []byte(host), 0o644); err != nil {
			t.Fatal(err)
		}
		f, err := LoadPath(path)
		if err != nil {
			t.Fatalf("edge %q: %v", edge, err)
		}
		return f.IndexSets
	}
	size := func(sets map[string]IndexSet, name string) int64 {
		t.Helper()
		s, ok := sets[name]
		if !ok || s.Size == nil {
			t.Fatalf("index set %q missing or unsized: %v", name, sets)
		}
		return int64(*s.Size)
	}
	if got := size(load(""), "x"); got != 2 {
		t.Errorf("x = %d; want the leaf's default 2", got)
	}
	if got := size(load(`,"bindings":{"N":5}`), "x"); got != 5 {
		t.Errorf("x = %d; want 5, closed by the edge", got)
	}
	renamed := load(`,"index_set_rename":{"x":"y"}`)
	if _, still := renamed["x"]; still {
		t.Errorf("x survived the rename: %v", renamed)
	}
	if got := size(renamed, "y"); got != 2 {
		t.Errorf("y = %d; want 2", got)
	}
}

// A top-level `reaction_systems.<k>` `{ref}` lands the leaf's reaction system
// with the leaf's AUTHORED species order (API_SPEC.md §5.10,
// esm-libraries-spec §4.7.5 step 4), exactly as the inline copy has it — on both
// reach paths. Species are declared O3, NO, NO2, so sorted-name order would
// differ. The host's own model is declared z, a, and keeps that order too when
// LoadPath re-encodes the document to splice the mount in.
func TestTopLevelReactionSystemRefKeepsAuthoredSpeciesOrder(t *testing.T) {
	dir := t.TempDir()
	rs := `{"species":{"O3":{"units":"1","default":1.0},"NO":{"units":"1","default":1.0},"NO2":{"units":"1","default":1.0}},
  "parameters":{"k":{"units":"1/s","default":0.3}},
  "reactions":[{"id":"R1","substrates":[{"species":"NO","stoichiometry":1},{"species":"O3","stoichiometry":1}],"products":[{"species":"NO2","stoichiometry":1}],"rate":"k"}]}`
	model := `"models":{"M":{"variables":{"z":{"type":"parameter","units":"1","default":1.0},"a":{"type":"parameter","units":"1","default":2.0}},"equations":[]}}`
	leaf := `{"esm":"1.0.0","metadata":{"name":"leaf","description":"probe"},"reaction_systems":{"Chem":` + rs + `}}`
	mounted := `{"esm":"1.0.0","metadata":{"name":"host","description":"probe"},` + model + `,
 "reaction_systems":{"Chem":{"ref":"./leaf.esm"}}}`
	inline := `{"esm":"1.0.0","metadata":{"name":"host","description":"probe"},` + model + `,
 "reaction_systems":{"Chem":` + rs + `}}`
	for name, text := range map[string]string{"leaf.esm": leaf, "mounted.esm": mounted, "inline.esm": inline} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	type observed struct {
		odes   string
		matrix [][]float64
		params []string
		states []string
	}
	observe := func(how string, f *ESMFile) observed {
		t.Helper()
		chem := f.ReactionSystems["Chem"]
		model, err := DeriveODEs(&chem)
		if err != nil {
			t.Fatalf("%s: DeriveODEs: %v", how, err)
		}
		odes, err := json.Marshal(model.Equations)
		if err != nil {
			t.Fatal(err)
		}
		flat, err := Flatten(f)
		if err != nil {
			t.Fatalf("%s: Flatten: %v", how, err)
		}
		var o observed
		o.odes = string(odes)
		o.matrix = StoichiometricMatrix(&chem)
		for _, v := range flat.StateVariables {
			o.states = append(o.states, v.Name)
		}
		for _, v := range flat.Parameters {
			o.params = append(o.params, v.Name)
		}
		return o
	}

	want, err := LoadPath(filepath.Join(dir, "inline.esm"))
	if err != nil {
		t.Fatalf("inline: %v", err)
	}
	wantObs := observe("inline", want)
	if got := []string{"Chem.O3", "Chem.NO", "Chem.NO2"}; !reflect.DeepEqual(wantObs.states, got) {
		t.Fatalf("inline copy flattens its species as %v; want %v", wantObs.states, got)
	}

	viaPath, err := LoadPath(filepath.Join(dir, "mounted.esm"))
	if err != nil {
		t.Fatalf("LoadPath: %v", err)
	}
	viaString, err := LoadString(mounted)
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	if err := ResolveSubsystemRefs(viaString, dir); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}
	for how, f := range map[string]*ESMFile{"LoadPath": viaPath, "LoadString+ResolveSubsystemRefs": viaString} {
		got := observe(how, f)
		if got.odes != wantObs.odes {
			t.Errorf("%s: DeriveODEs equations differ from the inline copy:\n got  %s\n want %s", how, got.odes, wantObs.odes)
		}
		if !reflect.DeepEqual(got.matrix, wantObs.matrix) {
			t.Errorf("%s: StoichiometricMatrix = %v; the inline copy gives %v", how, got.matrix, wantObs.matrix)
		}
		if !reflect.DeepEqual(got.states, wantObs.states) {
			t.Errorf("%s: Flatten state order = %v; the inline copy gives %v", how, got.states, wantObs.states)
		}
		if !reflect.DeepEqual(got.params, wantObs.params) {
			t.Errorf("%s: Flatten parameter order = %v; the inline copy gives %v", how, got.params, wantObs.params)
		}
	}
}

// esm-spec §9.6.6: a top-level `{ref}` mount edge that LoadString decoded but
// nothing resolved is NOT an empty component. Flatten, Validate and DeriveODEs
// report `unresolved_subsystem_ref` at the entry, at both top-level forms;
// once ResolveSubsystemRefs runs, the same file works.
func TestUnresolvedTopLevelRefIsNotAnEmptySystem(t *testing.T) {
	dir := mrFixture(t, "fixtures", "mount_form_unsupported")
	leafModel := t.TempDir()
	if err := os.WriteFile(filepath.Join(leafModel, "leaf.esm"), []byte(`{"esm":"1.0.0","metadata":{"name":"leaf","description":"probe"},
 "models":{"M":{"variables":{"x":{"type":"parameter","units":"1","default":1.0}},"equations":[]}}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		section, name, host, base string
	}{
		{"models", "M", `{"esm":"1.0.0","metadata":{"name":"host","description":"probe"},"models":{"M":{"ref":"./leaf.esm"}}}`, leafModel},
		{"reaction_systems", "Chem", `{"esm":"1.0.0","metadata":{"name":"host","description":"probe"},"reaction_systems":{"Chem":{"ref":"./reaction_system_leaf.esm"}}}`, dir},
	}
	for _, c := range cases {
		pointer := "/" + c.section + "/" + c.name
		f, err := LoadString(c.host)
		if err != nil {
			t.Fatalf("%s: LoadString: %v", c.section, err)
		}

		_, err = Flatten(f)
		var et *ExpressionTemplateError
		if !errors.As(err, &et) || et.Code != CodeUnresolvedSubsystemRef || et.Path != pointer {
			t.Errorf("%s: Flatten of an unresolved mount = %v; want %s at %s", c.section, err, CodeUnresolvedSubsystemRef, pointer)
		}

		found := false
		for _, e := range Validate(f).StructuralErrors {
			found = found || (e.Code == CodeUnresolvedSubsystemRef && e.Path == pointer)
		}
		if !found {
			t.Errorf("%s: Validate does not report %s at %s", c.section, CodeUnresolvedSubsystemRef, pointer)
		}

		if c.section == "reaction_systems" {
			chem := f.ReactionSystems[c.name]
			if _, err := DeriveODEs(&chem); !errors.As(err, &et) || et.Code != CodeUnresolvedSubsystemRef {
				t.Errorf("DeriveODEs of an unresolved mount = %v; want %s", err, CodeUnresolvedSubsystemRef)
			}
		}

		if err := ResolveSubsystemRefs(f, c.base); err != nil {
			t.Fatalf("%s: ResolveSubsystemRefs: %v", c.section, err)
		}
		if _, err := Flatten(f); err != nil {
			t.Errorf("%s: Flatten after resolution: %v", c.section, err)
		}
		if c.section == "reaction_systems" {
			chem := f.ReactionSystems[c.name]
			if _, err := DeriveODEs(&chem); err != nil {
				t.Errorf("DeriveODEs after resolution: %v", err)
			}
		}
	}
}

// esm-spec §4.7 "Two mount forms, one mechanism": the `model` selector applies
// at a top-level `models.<k>` `{ref}` exactly as `reaction_system` does at
// `reaction_systems.<k>`. A leaf declaring models A and B mounts the one the
// selector names; with no selector, or a selector the leaf does not declare,
// the mount is `unresolved_subsystem_ref` at `/models/<k>`, as Julia raises it.
// A leaf with one model and one reaction system mounts its model, and a leaf
// whose only system is a reaction system has no model to mount, which is
// `unresolved_subsystem_ref` at `/models/<k>` too. Each
// case is checked on both reach paths: LoadPath, and LoadString plus
// ResolveSubsystemRefs.
func TestTopLevelModelRefHonoursTheModelSelector(t *testing.T) {
	dir := t.TempDir()
	model := func(v string) string {
		return `{"variables":{"` + v + `":{"type":"parameter","units":"1","default":1.0}},"equations":[]}`
	}
	rs := `{"species":{"S":{"units":"1","default":1.0}},"parameters":{"k":{"units":"1/s","default":0.3}},
  "reactions":[{"id":"R1","substrates":[{"species":"S","stoichiometry":1}],"products":null,"rate":"k"}]}`
	leaves := map[string]string{
		"two_models.esm":   `"models":{"A":` + model("a") + `,"B":` + model("b") + `}`,
		"model_and_rs.esm": `"models":{"A":` + model("a") + `},"reaction_systems":{"Chem":` + rs + `}`,
		"rs_only.esm":      `"reaction_systems":{"Chem":` + rs + `}`,
	}
	for name, body := range leaves {
		doc := `{"esm":"1.0.0","metadata":{"name":"leaf","description":"probe"},` + body + `}`
		if err := os.WriteFile(filepath.Join(dir, name), []byte(doc), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// load reads a host mounting `edge` at models.Atm on both reach paths and
	// returns each path's mounted model variables, or its error.
	load := func(edge string) (map[string][]string, map[string]error) {
		t.Helper()
		host := `{"esm":"1.0.0","metadata":{"name":"host","description":"probe"},"models":{"Atm":` + edge + `}}`
		path := filepath.Join(dir, "host.esm")
		if err := os.WriteFile(path, []byte(host), 0o644); err != nil {
			t.Fatal(err)
		}
		vars := map[string][]string{}
		errs := map[string]error{}
		record := func(how string, f *ESMFile, err error) {
			if err != nil {
				errs[how] = err
				return
			}
			vars[how] = sortedKeys(f.Models["Atm"].Variables)
		}
		f, err := LoadPath(path)
		record("LoadPath", f, err)
		g, err := LoadString(host)
		if err != nil {
			t.Fatalf("LoadString(%s): %v", edge, err)
		}
		err = ResolveSubsystemRefs(g, dir)
		record("LoadString+ResolveSubsystemRefs", g, err)
		return vars, errs
	}
	mounts := []struct{ edge, want string }{
		{`{"ref":"./two_models.esm","model":"B"}`, "b"},
		{`{"ref":"./two_models.esm","model":"A"}`, "a"},
		{`{"ref":"./model_and_rs.esm"}`, "a"},
	}
	for _, m := range mounts {
		vars, errs := load(m.edge)
		for how, err := range errs {
			t.Errorf("%s: %s: %v", m.edge, how, err)
		}
		for how, got := range vars {
			if !reflect.DeepEqual(got, []string{m.want}) {
				t.Errorf("%s: %s: Atm variables = %v; want [%s]", m.edge, how, got, m.want)
			}
		}
	}
	refusals := []struct {
		edge string
		code string
	}{
		{`{"ref":"./two_models.esm"}`, CodeUnresolvedSubsystemRef},
		{`{"ref":"./two_models.esm","model":"C"}`, CodeUnresolvedSubsystemRef},
		{`{"ref":"./rs_only.esm"}`, CodeUnresolvedSubsystemRef},
	}
	for _, r := range refusals {
		vars, errs := load(r.edge)
		for how := range vars {
			t.Errorf("%s: %s loaded; it must be refused", r.edge, how)
		}
		for how, err := range errs {
			var et *ExpressionTemplateError
			if !errors.As(err, &et) || et.Code != r.code {
				t.Errorf("%s: %s: error %v; want %s", r.edge, how, err, r.code)
				continue
			}
			if et.Path != "/models/Atm" {
				t.Errorf("%s: %s: path = %q; want /models/Atm", r.edge, how, et.Path)
			}
		}
	}
}

// topLevelRefEntries hands back the block it read and only the bare `{ref}`
// entries of it: an inline component that happens to carry a `ref` field, and
// a non-object entry, are not mount edges.
func TestTopLevelRefEntriesReturnsTheBlockAndItsEdges(t *testing.T) {
	view, err := decodeJSONView([]byte(`{"models":{
  "Edge":{"ref":"./leaf.esm","model":"B"},
  "Inline":{"ref":"./x.esm","variables":{}},
  "Odd":3}}`))
	if err != nil {
		t.Fatal(err)
	}
	block, edges := topLevelRefEntries(view, topLevelModelMount)
	if len(block) != 3 {
		t.Errorf("block = %v; want all three entries", block)
	}
	if got := sortedKeys(edges); !reflect.DeepEqual(got, []string{"Edge"}) {
		t.Errorf("edges = %v; want [Edge]", got)
	}
	// The edge is the block's own entry, so resolving it in place rewrites the
	// view the caller holds.
	if e, _ := edges["Edge"].(map[string]any); e == nil || e["model"] != "B" {
		t.Errorf("edge = %v; want the authored entry", edges["Edge"])
	}
	if b, e := topLevelRefEntries(view, topLevelReactionSystemMount); b != nil || e != nil {
		t.Errorf("no reaction_systems block: got %v, %v; want nil, nil", b, e)
	}
}
