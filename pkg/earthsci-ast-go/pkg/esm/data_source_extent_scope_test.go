package esm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
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
// Scope note for this binding. Go mounts at BOTH §4.7 attachment points (the
// top-level `models.<k>` `{ref}` form landed with #198 item 4), so the
// cross-form equality §4.7 requires is reachable here and is pinned below. What
// Go does NOT implement is §8.9.4 extent DISCOVERY: it carries only the decoded
// `extent` field and never samples a source, so the count is supplied directly
// as the site-4 loader-API binding discovery would have produced.
//
// The fixtures are shared with the other bindings and live under
// tests/fixtures/ rather than tests/valid/, because the corpus sweep scores a
// document by its diagnostics, and several of these are about a VALUE (which
// size an axis folds to) that a pass/fail sweep cannot see.

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

// TestIndexSetSizeCodecRoundTrips pins the `size` codec in BOTH directions.
//
// `size` is one wire key with two inhabitants — a folded integer and a still
// symbolic metaparameter expression — and this binding is the only one that
// decodes the registry into a typed struct, so it is the only one that needed a
// custom codec to carry the symbolic case at all. An untested MarshalJSON is
// how a field silently stops being emitted: the cross-language round-trip gate
// compares a binding against ITSELF, so a symbolic size dropped on emit and
// absent on the re-read would agree with itself and pass.
func TestIndexSetSizeCodecRoundTrips(t *testing.T) {
	for _, tc := range []struct {
		name string
		wire string
	}{
		{"a folded integer size", `{"kind":"interval","size":4}`},
		{"a bare metaparameter name", `{"kind":"interval","size":"N_REC"}`},
		{"a metaparameter expression", `{"kind":"interval","size":{"op":"mul","args":["NX","NY"]}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var is IndexSet
			if err := json.Unmarshal([]byte(tc.wire), &is); err != nil {
				t.Fatalf("decode %s: %v", tc.wire, err)
			}
			if (is.Size == nil) == (is.SizeExpr == nil) {
				t.Fatalf("exactly one of Size/SizeExpr must be set, got Size=%v SizeExpr=%v",
					is.Size, is.SizeExpr)
			}
			out, err := json.Marshal(is)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			var got, want any
			if err := json.Unmarshal(out, &got); err != nil {
				t.Fatalf("re-decode emitted %s: %v", out, err)
			}
			if err := json.Unmarshal([]byte(tc.wire), &want); err != nil {
				t.Fatalf("decode expected: %v", err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("round-trip changed the declaration:\n  in:  %s\n  out: %s", tc.wire, out)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// The two §4.7 mount forms, and the static check's two idempotency cases
// ---------------------------------------------------------------------------

// TestExtentScope_BothMountFormsSizeTheAxisIdentically drives the SAME leaf,
// the same data source and the same discovered count through both §4.7
// attachment points.
//
// §4.7 "Two mount forms, one mechanism" forbids the two differing, and before
// the loader-API backfill reached the `subsystems.<k>` edge they did — silently,
// with a zero-length axis, a clean validate and a zero exit code.
func TestExtentScope_BothMountFormsSizeTheAxisIdentically(t *testing.T) {
	top, err := extentScopeLoad(t, "extent_root_toplevel.esm", map[string]int64{"N_REC": 3})
	if err != nil {
		t.Fatalf("load at the top-level models.<k> mount form: %v", err)
	}
	sub, err := extentScopeLoad(t, "extent_root_subsystem.esm", map[string]int64{"N_REC": 3})
	if err != nil {
		t.Fatalf("load at the subsystems.<k> mount form: %v", err)
	}
	if got := extentScopeSize(t, top); got != 3 {
		t.Errorf("top-level mount sized the axis %d, want 3", got)
	}
	if got := extentScopeSize(t, sub); got != 3 {
		t.Errorf("subsystem mount sized the axis %d, want 3", got)
	}
	if !reflect.DeepEqual(extentScopeRecords(t, top), extentScopeRecords(t, sub)) {
		t.Errorf("the two mount forms produced different `records` declarations:\n  top-level: %+v\n  subsystem: %+v",
			extentScopeRecords(t, top), extentScopeRecords(t, sub))
	}
}

// TestExtentScope_ReExportedMetaparameterIsAccepted pins that the static §8.9.4
// check does not refuse what §9.7.6 accepts.
//
// The name reaches this document by §9.7.6 site-2 RE-EXPORT, not by declaration
// and not through a mount: the document declares no `metaparameters` and mounts
// nothing, but IMPORTS a library that declares `N_REC` and does not bind it at
// the edge. The loader API may bind such a name, which is exactly what a
// discovered `extent` does. The static check runs on the AUTHORED tree, before
// the imports resolve, so it has to walk the import edges too.
func TestExtentScope_ReExportedMetaparameterIsAccepted(t *testing.T) {
	doc, err := extentScopeLoad(t, "extent_reexport_root.esm", map[string]int64{"N_REC": 3})
	if err != nil {
		t.Fatalf("a re-exported metaparameter is a valid site-4 binding target: %v", err)
	}
	if got := extentScopeSize(t, doc); got != 3 {
		t.Errorf("records sized %d, want 3", got)
	}
	standalone, err := extentScopeLoad(t, "extent_reexport_root.esm", nil)
	if err != nil {
		t.Fatalf("it loads standalone at the library's default too: %v", err)
	}
	if got := extentScopeSize(t, standalone); got != 0 {
		t.Errorf("standalone records sized %d, want the library default 0", got)
	}
}

// TestExtentScope_AResolvedDocumentReloads pins the check's idempotency.
//
// A §4.7 mount CONSUMES the leaf's `metaparameters` (§9.7.6 site 3), so once
// `extent_root_toplevel.esm` has been resolved, `N_REC` is declared nowhere and
// the `{ref}` stub the mount walk reads is gone — while the `extent` that named
// it is still there, having already done its job. A binding that re-loads its
// own resolved document (Rust does, at build) must not be told it is invalid.
func TestExtentScope_AResolvedDocumentReloads(t *testing.T) {
	doc, err := extentScopeLoad(t, "extent_resolved_shape.esm", nil)
	if err != nil {
		t.Fatalf("a document in resolved shape re-loads: %v", err)
	}
	if got := extentScopeSize(t, doc); got != 3 {
		t.Errorf("records sized %d, want the already-folded 3", got)
	}
}

// TestExtentScope_IdempotencyFixturesSayWhatTheyAre guards the two fixtures
// above, which are load-bearing by ABSENCE: restoring either missing block would
// leave every binding's suite green while deleting the property under test.
func TestExtentScope_IdempotencyFixturesSayWhatTheyAre(t *testing.T) {
	read := func(name string) map[string]any {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(extentScopeDir(t), name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		var raw map[string]any
		if err := json.Unmarshal(data, &raw); err != nil {
			t.Fatalf("decode %s: %v", name, err)
		}
		return raw
	}
	reexport := read("extent_reexport_root.esm")
	if _, ok := reexport["metaparameters"]; ok {
		t.Error("extent_reexport_root.esm must declare none: the name arrives by re-export")
	}
	resolved := read("extent_resolved_shape.esm")
	if _, ok := resolved["metaparameters"]; ok {
		t.Error("extent_resolved_shape.esm must declare none: a mount consumed the leaf's block")
	}
	models, _ := resolved["models"].(map[string]any)
	ingest, _ := models["Ingest"].(map[string]any)
	if _, ok := ingest["ref"]; ok {
		t.Error("extent_resolved_shape.esm must be already inlined, not a `{ref}` mount")
	}
	isets, _ := resolved["index_sets"].(map[string]any)
	records, _ := isets["records"].(map[string]any)
	if fmt.Sprint(records["size"]) != "3" {
		t.Errorf("extent_resolved_shape.esm `records.size` must be already folded, got %v", records["size"])
	}
}
