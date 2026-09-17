package esm

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// esm-spec §4.7 `${VAR}` expansion in a document ref: the braced form only, an
// unset variable left literal, and expansion BEFORE the remote/absolute
// classification and before a relative ref is anchored. The capability reaches
// every §4.7 ref mechanism through the two chokepoints — expandRefEnv in
// loadRefBytes (the read) and in canonicalImportRef (the cycle key) — so these
// cases drive it through a template-library import (§9.7.2) and a
// `coupling_import` (§10.10), whichever mechanism a case is cheapest to state
// with.

// envRefConsumerJSON is a minimal consuming model whose single template-library
// import carries `ref`. A library merges its index sets into the consumer
// (§9.7.5), so the merged `cells` axis is the proof the ref actually loaded.
func envRefConsumerJSON(ref string) string {
	return `{
      "esm": "1.0.0",
      "metadata": {"name": "env_ref_consumer"},
      "models": {
        "M": {
          "expression_template_imports": [{"ref": "` + ref + `"}],
          "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0}},
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }`
}

// envRefLibJSON is a standalone template library (§9.7.1) sizing `cells` at
// `size`, so a test can tell WHICH library a ref resolved to.
func envRefLibJSON(size int) string {
	return `{
      "esm": "1.0.0",
      "metadata": {"name": "env_ref_lib"},
      "metaparameters": {"NC": {"type": "integer", "default": ` + strconv.Itoa(size) + `}},
      "index_sets": {"cells": {"kind": "interval", "size": "NC"}},
      "expression_templates": {"nc": {"params": [], "body": "NC"}}
    }`
}

// A SET variable is replaced by its value: an absolute directory arriving from
// the environment resolves the import, and the library's axis lands in the
// consumer's registry.
func TestRefEnvExpansion_SetVariableResolvesImport(t *testing.T) {
	libDir := filepath.Join(tiRepoRoot(t), "tests", "valid")
	t.Setenv("ESM_GO_TEST_LIB_ROOT", libDir)
	dir := t.TempDir()
	p := filepath.Join(dir, "consumer.esm")
	writeFileString(t, p, envRefConsumerJSON("${ESM_GO_TEST_LIB_ROOT}/template_import_lib.esm"))
	f, err := LoadPath(p)
	if err != nil {
		t.Fatalf("LoadPath(${VAR} import): %v", err)
	}
	// tests/valid/template_import_lib.esm sizes `cells` at N = 8 by default.
	if f.IndexSets["cells"].Size == nil || *f.IndexSets["cells"].Size != 8 {
		t.Errorf("cells size = %v; want 8 (§9.7.5 merge from the ${VAR}-resolved library)",
			f.IndexSets["cells"].Size)
	}
}

// An UNSET variable is left literal, so the ref fails with the ORDINARY
// unresolved diagnostic and the message quotes the `${VAR}` text the document
// carries — never a path with an empty segment where the value would have gone.
func TestRefEnvExpansion_UnsetVariableStaysLiteral(t *testing.T) {
	// t.Setenv registers the restore and refuses a parallel test; unsetting
	// afterwards is what makes the variable's absence certain here.
	t.Setenv("ESM_GO_TEST_UNSET_ROOT", "unused")
	if err := os.Unsetenv("ESM_GO_TEST_UNSET_ROOT"); err != nil {
		t.Fatalf("unsetenv: %v", err)
	}
	dir := t.TempDir()
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [{"ref": "${ESM_GO_TEST_UNSET_ROOT}/lib.esm"}],`, ""))
	_, err := LoadPath(p)
	if err == nil {
		t.Fatal("LoadPath(unset ${VAR}) succeeded; want template_import_unresolved")
	}
	if code := tiErrCode(t, err); code != "template_import_unresolved" {
		t.Errorf("code = %s; want template_import_unresolved", code)
	}
	if !strings.Contains(err.Error(), "${ESM_GO_TEST_UNSET_ROOT}/lib.esm") {
		t.Errorf("message = %q; want it to quote the literal ${VAR} ref", err.Error())
	}
}

// Only the braced form is expanded: a bare `$VAR` is a literal path segment
// even when the variable IS set, and the ref fails naming it verbatim.
func TestRefEnvExpansion_BareDollarNotExpanded(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "lib.esm"), envRefLibJSON(4))
	t.Setenv("ESM_GO_TEST_BARE_ROOT", dir)
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [{"ref": "$ESM_GO_TEST_BARE_ROOT/lib.esm"}],`, ""))
	_, err := LoadPath(p)
	if err == nil {
		t.Fatal("LoadPath($VAR import) succeeded; the bare form must NOT expand")
	}
	if code := tiErrCode(t, err); code != "template_import_unresolved" {
		t.Errorf("code = %s; want template_import_unresolved", code)
	}
	if !strings.Contains(err.Error(), "$ESM_GO_TEST_BARE_ROOT/lib.esm") {
		t.Errorf("message = %q; want it to quote the literal $VAR ref", err.Error())
	}
}

// Expansion runs BEFORE anchoring: a variable holding a RELATIVE fragment still
// anchors at the referencing document's directory, not at the process working
// directory (where `libs/lib.esm` does not exist).
func TestRefEnvExpansion_ExpandedRelativeRefAnchorsAtDocument(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "libs"), 0o755); err != nil {
		t.Fatalf("mkdir libs: %v", err)
	}
	writeFileString(t, filepath.Join(dir, "libs", "lib.esm"), envRefLibJSON(6))
	t.Setenv("ESM_GO_TEST_LIB_SUBDIR", "libs")
	p := filepath.Join(dir, "consumer.esm")
	writeFileString(t, p, envRefConsumerJSON("${ESM_GO_TEST_LIB_SUBDIR}/lib.esm"))
	f, err := LoadPath(p)
	if err != nil {
		t.Fatalf("LoadPath(relative ${VAR} import): %v", err)
	}
	if f.IndexSets["cells"].Size == nil || *f.IndexSets["cells"].Size != 6 {
		t.Errorf("cells size = %v; want 6 (the library under the document's own libs/)",
			f.IndexSets["cells"].Size)
	}
}

// esm-spec §10.10: a `coupling_import` ref resolves by the §4.7 formats, so it
// expands too — the same chokepoint, reached through the coupling loader.
func TestRefEnvExpansion_CouplingImportRef(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "libs"), 0o755); err != nil {
		t.Fatalf("mkdir libs: %v", err)
	}
	writeFileString(t, filepath.Join(dir, "libs", "lib.esm"), couplingLibJSON)
	t.Setenv("ESM_GO_TEST_COUPLING_ROOT", filepath.Join(dir, "libs"))
	bind := map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}
	file := couplingAssembly([]CouplingEntry{
		CouplingImport{Type: "coupling_import", Ref: "${ESM_GO_TEST_COUPLING_ROOT}/lib.esm", Bind: bind},
	})
	edges, err := expandCouplingImports(file, CouplingImportOptions{BasePath: dir})
	if err != nil {
		t.Fatalf("expandCouplingImports(${VAR} ref): %v", err)
	}
	if len(edges) != 2 {
		t.Errorf("expanded %d edges; want the library's 2", len(edges))
	}
}
