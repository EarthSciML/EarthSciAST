package esm

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// A discovered `extent` binds where the NAME is declared, not only at the root.
//
// esm-spec §8.9.4 lets a data source measure its own record count and bind a
// metaparameter an index set is sized by. The count arrives as a §9.7.6 site-4
// loader-API binding, so these tests bind it directly: LoadPath(...,
// WithMetaparameters{"N_REC": 3}) is exactly what extent discovery hands the
// loader, and it exercises the same path without needing a file on disk.
//
// Scope note for this binding. Go implements the `subsystems.<k>` mount form
// and does NOT implement the top-level `models.<k>` `{ref}` mount form, nor
// §8.9.4 extent DISCOVERY (it carries only the decoded `extent` field). So the
// subsystem-form fixtures carry the mount tests here, and the shared
// `extent_root_toplevel.esm` appears only where its behaviour does not depend on
// being mounted — the static §8.9.4 check, which is a pure document check and is
// fully reachable.
//
// The fixtures are shared with the other bindings and live under
// tests/fixtures/ rather than tests/valid/, because the corpus sweep would score
// Go and TypeScript a false pass on the top-level mount form they do not
// implement.

func extentScopeDir(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(repoRoot, "tests", "fixtures", "data_source_extent_scope")
}

// extentScopeLoad loads one shared fixture under the given loader-API bindings.
func extentScopeLoad(t *testing.T, name string, meta map[string]int64) (*ESMFile, error) {
	t.Helper()
	opts := []LoadOption{}
	if meta != nil {
		opts = append(opts, WithMetaparameters(meta))
	}
	return LoadPath(filepath.Join(extentScopeDir(t), name), opts...)
}

// extentScopeRecords returns the merged `records` axis declaration, whatever
// shape the registry holds it in — an integer Size, or the unfolded SizeExpr a
// §4.7 mount edge leaves for the mounting registry to close.
func extentScopeRecords(t *testing.T, doc *ESMFile) IndexSet {
	t.Helper()
	is, ok := doc.IndexSets["records"]
	if !ok {
		t.Fatalf("index set 'records' absent from the merged registry; have %v", doc.IndexSets)
	}
	return is
}

func extentScopeSize(t *testing.T, doc *ESMFile) int {
	t.Helper()
	is := extentScopeRecords(t, doc)
	if is.Size == nil {
		t.Fatalf("index set 'records' has no folded size (size expression: %v)", is.SizeExpr)
	}
	return *is.Size
}

// ---------------------------------------------------------------------------
// §9.7.6 site 4 reaches a name only a MOUNTED document declares
// ---------------------------------------------------------------------------

// TestExtentScope_MountedLeafMetaparameterNeedNotBeRestated pins the widened
// site-4 check together with the mount-edge backfill it exists to serve.
//
// The thin root owns the `data_sources` entry and declares NO `metaparameters`;
// the leaf it mounts as a subsystem declares `N_REC` and is sized by it. The
// discovered extent is a loader-API binding, and the site-4 check used to ask
// only whether the ROOT declared the name — so every assembly had to carry a
// second, identical `metaparameters` block that configured nothing. The check
// now accepts a name declared by any document the root mounts, and the mount
// edge forwards the value into the leaf's own close.
func TestExtentScope_MountedLeafMetaparameterNeedNotBeRestated(t *testing.T) {
	doc, err := extentScopeLoad(t, "extent_root_subsystem.esm", map[string]int64{"N_REC": 3})
	if err != nil {
		t.Fatalf("load with the mounted leaf's metaparameter bound: %v", err)
	}
	if got := extentScopeSize(t, doc); got != 3 {
		t.Errorf("merged records size = %d; want 3 — a subsystem-mounted leaf must "+
			"size its axis from the loader-API binding, not from its own placeholder "+
			"default (esm-spec §4.7, §9.7.6 site 4)", got)
	}
}

// TestExtentScope_LoaderBindingNoDocumentDeclaresIsRefused: widening the check
// must not delete it. A name neither the root nor anything it mounts declares is
// still `template_import_unknown_name` — §9.7.6: bindings never invent
// metaparameters, a typo fails loudly.
func TestExtentScope_LoaderBindingNoDocumentDeclaresIsRefused(t *testing.T) {
	_, err := extentScopeLoad(t, "extent_root_subsystem.esm", map[string]int64{"N_RECS": 3})
	if err == nil {
		t.Fatal("expected a loader-API binding no document declares to be refused")
	}
	if !strings.Contains(err.Error(), string(CodeTemplateImportUnknownName)) {
		t.Errorf("error = %v; want %s", err, CodeTemplateImportUnknownName)
	}
	if !strings.Contains(err.Error(), "N_RECS") {
		t.Errorf("error = %v; want it to name the offending binding N_RECS", err)
	}
}

// ---------------------------------------------------------------------------
// An UNUSED template import does not decide whether a leaf resolves
// ---------------------------------------------------------------------------

// TestExtentScope_UnusedTemplateImportDoesNotDecideResolution loads two
// assemblies differing by ONE import of a library the leaf never calls.
//
// Whether a mounted leaf folded strictly used to be a whole-document boolean —
// does it carry ANY §9.7 machinery — so adding that import flipped the leaf from
// "axis merges symbolically and the assembler closes it" to
// `metaparameter_unbound`. Factoring a shared expression into a library is not
// supposed to change whether a document's shape resolves.
//
// The assertion is DIFFERENTIAL rather than absolute on purpose: where the §4.7
// merge sits relative to the mounting document's own §9.7.6 close still differs
// across bindings (RFC mount-edge-index-set-renaming.md open question 2), so the
// portable contract is that the two spellings agree with each other.
func TestExtentScope_UnusedTemplateImportDoesNotDecideResolution(t *testing.T) {
	withImport, errWith := extentScopeLoad(t, "assembler_root_with_import.esm", nil)
	noImport, errNo := extentScopeLoad(t, "assembler_root_no_import.esm", nil)
	if errWith != nil || errNo != nil {
		t.Fatalf("the two spellings must load alike: with_import err = %v; no_import err = %v",
			errWith, errNo)
	}
	a, err := json.Marshal(extentScopeRecords(t, withImport))
	if err != nil {
		t.Fatalf("marshal with_import records: %v", err)
	}
	b, err := json.Marshal(extentScopeRecords(t, noImport))
	if err != nil {
		t.Fatalf("marshal no_import records: %v", err)
	}
	if string(a) != string(b) {
		t.Errorf("records axis differs by an import the leaf never calls:\n with_import = %s\n no_import   = %s",
			a, b)
	}
}

// ---------------------------------------------------------------------------
// §8.9.4 statically: an extent nobody declares is refused at load
// ---------------------------------------------------------------------------

// TestExtentScope_ExtentNamingUndeclaredMetaparameterIsRefused: `extent` names
// `N_RECS`; neither the root nor the leaf declares it.
//
// This used to validate clean and fail only once the source was SAMPLED, at
// build — the same validate/build split §9.7.6's own binding sites had. It is
// decidable from the document alone, so it is decided at load. Reachable in Go
// even though extent discovery is not: nothing here samples a source.
func TestExtentScope_ExtentNamingUndeclaredMetaparameterIsRefused(t *testing.T) {
	_, err := extentScopeLoad(t, "extent_undeclared_root.esm", nil)
	if err == nil {
		t.Fatal("expected an `extent` naming a metaparameter nobody declares to be refused at load")
	}
	if !strings.Contains(err.Error(), string(CodeTemplateImportUnknownName)) {
		t.Errorf("error = %v; want the existing %s code, not a new one", err, CodeTemplateImportUnknownName)
	}
	if !strings.Contains(err.Error(), "N_RECS") {
		t.Errorf("error = %v; want it to name the offending metaparameter N_RECS", err)
	}
}

// TestExtentScope_ExtentReachedThroughEitherMountFormIsAccepted: the static
// check's declared set reads BOTH §4.7 mount forms, including the top-level
// `models.<k>` `{ref}` Go does not mount.
//
// Go's acceptance side must not be narrower than the schema: a document whose
// `extent` names a metaparameter only a top-level-mounted leaf declares is
// legal, and refusing it would make a conforming document unloadable here. This
// is the companion to the test above — without it, an empty mount-declared set
// would pass that test for the wrong reason.
func TestExtentScope_ExtentReachedThroughEitherMountFormIsAccepted(t *testing.T) {
	if _, err := extentScopeLoad(t, "extent_root_toplevel.esm", nil); err != nil {
		t.Fatalf("an `extent` whose name the top-level-mounted leaf declares must load: %v", err)
	}
}

// TestExtentScope_DeclaredExtentStillLoadsWithNoLoaderBindings: the static check
// must not refuse the ordinary case. An `extent` whose metaparameter the mounted
// leaf declares loads standalone, at its default, with no loader-API bindings at
// all (§8.9.4: "declare the metaparameter with a `default` so the document still
// validates and loads standalone").
func TestExtentScope_DeclaredExtentStillLoadsWithNoLoaderBindings(t *testing.T) {
	doc, err := extentScopeLoad(t, "extent_root_subsystem.esm", nil)
	if err != nil {
		t.Fatalf("the ordinary standalone load must not be refused: %v", err)
	}
	if got := extentScopeSize(t, doc); got != 0 {
		t.Errorf("merged records size = %d; want 0 (the leaf's declared placeholder default)", got)
	}
}

// ---------------------------------------------------------------------------
// The backfill is FILTERED to the names the leaf declares
// ---------------------------------------------------------------------------

// TestExtentScope_LoaderBindingTheLeafDoesNotDeclareIsNotForwarded: widening the
// root's check must not loosen the filter on what reaches the leaf.
//
// Here the assembler declares `N_REC` and the leaf it mounts declares nothing.
// Forwarding the whole loader-API map into the leaf's close would raise
// `template_import_unknown_name` against a leaf that never asked for the name —
// and, worse, would let an assembler's unrelated metaparameter silently resize a
// leaf axis the edge never bound (esm-spec §4.7).
// TestExtentScope_UnrelatedAssemblerMetaparameterIsWithheldFromTheLeaf is the
// same invariant one step in, where the FILTER rather than the leaf's silence
// has to enforce it.
//
// The assembler declares `N_OTHER` and the leaf it mounts declares `N_REC`, and
// the load binds both. In the test above the leaf declares NOTHING, so merely
// asking for its `metaparameters` block already withheld the whole map; here the
// block exists and only the per-name filter stands between an assembler's
// unrelated metaparameter and the leaf's close. Dropping that filter is a
// mutation the other test cannot see, and the failure it would let through is
// the quiet one §4.7 warns about: a name the edge never bound resizing a leaf
// axis.
//
// Fixture: assembler_partial_overlap_root.esm (added with this change).
func TestExtentScope_UnrelatedAssemblerMetaparameterIsWithheldFromTheLeaf(t *testing.T) {
	doc, err := extentScopeLoad(t, "assembler_partial_overlap_root.esm",
		map[string]int64{"N_REC": 3, "N_OTHER": 7})
	if err != nil {
		t.Fatalf("only the names the leaf declares may reach it: %v", err)
	}
	if got := extentScopeSize(t, doc); got != 3 {
		t.Errorf("merged records size = %d; want 3 (N_REC reaches the leaf, N_OTHER does not)", got)
	}
}

func TestExtentScope_LoaderBindingTheLeafDoesNotDeclareIsNotForwarded(t *testing.T) {
	doc, err := extentScopeLoad(t, "assembler_root_with_import.esm", map[string]int64{"N_REC": 5})
	if err != nil {
		t.Fatalf("a loader binding the leaf does not declare must not be forwarded into it: %v", err)
	}
	if doc == nil {
		t.Fatal("load returned no document")
	}
}
