package esm

// Go mirror of pkg/earthsci-ast-ts/src/coupling-imports.test.ts: detection,
// expansion, flatten equivalence, multiple instantiation, and the esm-spec
// §10.11 diagnostics (all 11 codes).

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// A coupling-library file: roles + role-scoped edges, no models/loaders.
const couplingLibJSON = `{
  "esm": "0.8.0",
  "metadata": {"name": "RothermelFuelCoupling"},
  "coupling_roles": {
    "Fuel": {"description": "fuel-property source"},
    "Spread": {"description": "Rothermel spread model"}
  },
  "coupling": [
    {"type": "variable_map", "from": "Fuel.sigma", "to": "Spread.sigma", "transform": "param_to_var"},
    {"type": "variable_map", "from": "Fuel.w_0", "to": "Spread.w0", "transform": "param_to_var"}
  ]
}`

func couplingLibView(t *testing.T, jsonStr string) map[string]any {
	t.Helper()
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		t.Fatalf("decode library view: %v", err)
	}
	return view
}

// An assembly mounting the two components the library wires.
func couplingAssembly(coupling []CouplingEntry) *ESMFile {
	return &ESMFile{
		ESM:      "0.8.0",
		Metadata: Metadata{Name: "wildfire"},
		Models: map[string]Model{
			"FuelModelLookup": {
				Variables: map[string]ModelVariable{
					"sigma": {Type: "parameter"},
					"w_0":   {Type: "parameter"},
				},
				Equations: []Equation{},
			},
			"RothermelFireSpread": {
				Variables: map[string]ModelVariable{
					"sigma": {Type: "parameter"},
					"w0":    {Type: "parameter"},
				},
				Equations: []Equation{},
			},
		},
		Coupling: coupling,
	}
}

func couplingImportEntry(bind map[string]string) CouplingImport {
	return CouplingImport{Type: "coupling_import", Ref: "lib.esm", Bind: bind}
}

func expectVarMap(t *testing.T, e any, from, to string) {
	t.Helper()
	vm, ok := e.(VariableMapCoupling)
	if !ok {
		t.Fatalf("expected VariableMapCoupling, got %T", e)
	}
	if vm.From != from || vm.To != to {
		t.Errorf("variable_map = (%s -> %s); want (%s -> %s)", vm.From, vm.To, from, to)
	}
	if vm.TransformKind() != "param_to_var" {
		t.Errorf("transform = %q; want param_to_var", vm.TransformKind())
	}
}

func couplingErrCode(t *testing.T, err error) string {
	t.Helper()
	if err == nil {
		return "NO_ERROR"
	}
	var et *ExpressionTemplateError
	if errors.As(err, &et) {
		return et.Code
	}
	return fmt.Sprintf("<%T: %v>", err, err)
}

func TestIsCouplingLibraryDoc(t *testing.T) {
	lib := couplingLibView(t, couplingLibJSON)
	if !isCouplingLibraryDoc(lib) {
		t.Error("library with coupling_roles should be identified as a coupling-library doc")
	}
	if isCouplingLibraryDoc(map[string]any{"esm": "0.8.0", "models": map[string]any{}}) {
		t.Error("an assembly should not be a coupling-library doc")
	}
	if isCouplingLibraryDoc(nil) {
		t.Error("nil should not be a coupling-library doc")
	}
}

func TestExpandCouplingImports_SubstitutesRoles(t *testing.T) {
	lib := couplingLibView(t, couplingLibJSON)
	loadRef := func(ref, basePath string) (map[string]any, error) { return lib, nil }

	file := couplingAssembly([]CouplingEntry{
		couplingImportEntry(map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}),
	})
	expanded, err := expandCouplingImports(file, CouplingImportOptions{LoadRef: loadRef})
	if err != nil {
		t.Fatalf("expandCouplingImports: %v", err)
	}
	if len(expanded) != 2 {
		t.Fatalf("expected 2 expanded edges, got %d", len(expanded))
	}
	expectVarMap(t, expanded[0], "FuelModelLookup.sigma", "RothermelFireSpread.sigma")
	expectVarMap(t, expanded[1], "FuelModelLookup.w_0", "RothermelFireSpread.w0")
}

func TestExpandCouplingImports_NoImportsUntouched(t *testing.T) {
	inline := []CouplingEntry{
		VariableMapCoupling{Type: "variable_map", From: "FuelModelLookup.sigma", To: "RothermelFireSpread.sigma", Transform: "param_to_var"},
	}
	file := couplingAssembly(inline)
	got, err := expandCouplingImports(file, CouplingImportOptions{})
	if err != nil {
		t.Fatalf("expandCouplingImports: %v", err)
	}
	// Same backing slice returned verbatim (no options needed).
	if reflect.ValueOf(got).Pointer() != reflect.ValueOf(file.Coupling).Pointer() {
		t.Errorf("expected file.Coupling returned verbatim")
	}
}

func TestExpandCouplingImports_MultipleInstantiation(t *testing.T) {
	lib := couplingLibView(t, couplingLibJSON)
	loadRef := func(ref, basePath string) (map[string]any, error) { return lib, nil }

	file := couplingAssembly([]CouplingEntry{
		couplingImportEntry(map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}),
		couplingImportEntry(map[string]string{"Fuel": "RothermelFireSpread", "Spread": "FuelModelLookup"}),
	})
	expanded, err := expandCouplingImports(file, CouplingImportOptions{LoadRef: loadRef})
	if err != nil {
		t.Fatalf("expandCouplingImports: %v", err)
	}
	if len(expanded) != 4 {
		t.Fatalf("expected 4 expanded edges, got %d", len(expanded))
	}
	expectVarMap(t, expanded[2], "RothermelFireSpread.sigma", "FuelModelLookup.sigma")
}

func TestFlattenEquivalence_ImportEqualsInline(t *testing.T) {
	lib := couplingLibView(t, couplingLibJSON)
	loadRef := func(ref, basePath string) (map[string]any, error) { return lib, nil }

	imported, err := FlattenWithOptions(
		couplingAssembly([]CouplingEntry{
			couplingImportEntry(map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}),
		}),
		CouplingImportOptions{LoadRef: loadRef},
	)
	if err != nil {
		t.Fatalf("flatten import: %v", err)
	}
	inline, err := Flatten(couplingAssembly([]CouplingEntry{
		VariableMapCoupling{Type: "variable_map", From: "FuelModelLookup.sigma", To: "RothermelFireSpread.sigma", Transform: "param_to_var"},
		VariableMapCoupling{Type: "variable_map", From: "FuelModelLookup.w_0", To: "RothermelFireSpread.w0", Transform: "param_to_var"},
	}))
	if err != nil {
		t.Fatalf("flatten inline: %v", err)
	}
	if !reflect.DeepEqual(imported, inline) {
		t.Errorf("import-expanded flatten != inline flatten\nimport: %#v\ninline: %#v", imported, inline)
	}
}

func TestCouplingImportDiagnostics(t *testing.T) {
	baseLib := couplingLibView(t, couplingLibJSON)
	loadBase := func(ref, basePath string) (map[string]any, error) { return baseLib, nil }

	tests := []struct {
		name    string
		bind    map[string]string
		loadRef func(ref, basePath string) (map[string]any, error)
		want    string
	}{
		{
			name:    "role_unbound",
			bind:    map[string]string{"Fuel": "FuelModelLookup"},
			loadRef: loadBase,
			want:    "coupling_import_role_unbound",
		},
		{
			name:    "unknown_role",
			bind:    map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread", "Ghost": "FuelModelLookup"},
			loadRef: loadBase,
			want:    "coupling_import_unknown_role",
		},
		{
			name:    "bind_not_a_component",
			bind:    map[string]string{"Fuel": "FuelModelLookup", "Spread": "DoesNotExist"},
			loadRef: loadBase,
			want:    "coupling_import_bind_not_a_component",
		},
		{
			name: "not_library",
			bind: map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"},
			loadRef: func(ref, basePath string) (map[string]any, error) {
				return couplingLibView(t, `{"esm": "0.8.0", "metadata": {"name": "x"}, "models": {}}`), nil
			},
			want: "coupling_import_not_library",
		},
		{
			name: "illegal_payload_declares_models",
			bind: map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"},
			loadRef: func(ref, basePath string) (map[string]any, error) {
				v := couplingLibView(t, couplingLibJSON)
				v["models"] = map[string]any{}
				return v, nil
			},
			want: "coupling_library_illegal_payload",
		},
		{
			name: "role_unused",
			bind: map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread", "Extra": "FuelModelLookup"},
			loadRef: func(ref, basePath string) (map[string]any, error) {
				v := couplingLibView(t, couplingLibJSON)
				roles := v["coupling_roles"].(map[string]any)
				roles["Extra"] = map[string]any{}
				return v, nil
			},
			want: "coupling_role_unused",
		},
		{
			name: "edge_unknown_role",
			bind: map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"},
			loadRef: func(ref, basePath string) (map[string]any, error) {
				v := couplingLibView(t, couplingLibJSON)
				v["coupling"] = []any{
					map[string]any{"type": "variable_map", "from": "Ghost.sigma", "to": "Spread.sigma", "transform": "param_to_var"},
				}
				return v, nil
			},
			want: "coupling_edge_unknown_role",
		},
		{
			name: "nested_import",
			bind: map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"},
			loadRef: func(ref, basePath string) (map[string]any, error) {
				v := couplingLibView(t, couplingLibJSON)
				v["coupling"] = []any{
					map[string]any{"type": "coupling_import", "ref": "other.esm", "bind": map[string]any{}},
				}
				return v, nil
			},
			want: "coupling_library_nested_import",
		},
		{
			name: "unresolved_loadref_error",
			bind: map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"},
			loadRef: func(ref, basePath string) (map[string]any, error) {
				return nil, fmt.Errorf("boom")
			},
			want: "coupling_import_unresolved",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			file := couplingAssembly([]CouplingEntry{couplingImportEntry(tc.bind)})
			_, err := expandCouplingImports(file, CouplingImportOptions{LoadRef: tc.loadRef})
			if code := couplingErrCode(t, err); code != tc.want {
				t.Errorf("code = %s; want %s", code, tc.want)
			}
		})
	}
}

// Default filesystem loader: a missing ref surfaces as coupling_import_unresolved.
func TestCouplingImport_DefaultLoaderMissingRef(t *testing.T) {
	dir := t.TempDir()
	file := couplingAssembly([]CouplingEntry{
		couplingImportEntry(map[string]string{"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}),
	})
	_, err := expandCouplingImports(file, CouplingImportOptions{BasePath: dir})
	if code := couplingErrCode(t, err); code != "coupling_import_unresolved" {
		t.Errorf("code = %s; want coupling_import_unresolved", code)
	}
}

// The coupling_import source entry round-trips intact (esm-spec §10.10.3):
// only the flattened system carries the expanded edges.
func TestCouplingImport_RoundTrip(t *testing.T) {
	src := `{
      "esm": "0.8.0",
      "metadata": {"name": "wildfire", "authors": ["x"]},
      "models": {
        "FuelModelLookup": {"variables": {"sigma": {"type": "parameter"}}, "equations": []},
        "RothermelFireSpread": {"variables": {"sigma": {"type": "parameter"}}, "equations": []}
      },
      "coupling": [
        {"type": "coupling_import", "ref": "rothermel.esm",
         "bind": {"Fuel": "FuelModelLookup", "Spread": "RothermelFireSpread"}}
      ]
    }`
	file, err := FromJSON([]byte(src))
	if err != nil {
		t.Fatalf("FromJSON: %v", err)
	}
	if len(file.Coupling) != 1 {
		t.Fatalf("expected 1 coupling entry, got %d", len(file.Coupling))
	}
	imp, ok := file.Coupling[0].(CouplingImport)
	if !ok {
		t.Fatalf("expected CouplingImport, got %T", file.Coupling[0])
	}
	if imp.Ref != "rothermel.esm" || imp.Bind["Fuel"] != "FuelModelLookup" || imp.Bind["Spread"] != "RothermelFireSpread" {
		t.Fatalf("coupling_import fields not preserved: %#v", imp)
	}
	out, err := file.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON: %v", err)
	}
	round, err := FromJSON(out)
	if err != nil {
		t.Fatalf("FromJSON(round): %v", err)
	}
	imp2, ok := round.Coupling[0].(CouplingImport)
	if !ok {
		t.Fatalf("round-trip: expected CouplingImport, got %T", round.Coupling[0])
	}
	if !reflect.DeepEqual(imp, imp2) {
		t.Errorf("coupling_import not preserved across round-trip:\n before: %#v\n after:  %#v", imp, imp2)
	}
}

// A §4.7 subsystem ref targeting a coupling-library file is rejected.
func TestSubsystemRef_IsCouplingLibrary(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "clib.esm"), couplingLibJSON)
	file := &ESMFile{
		ESM:      "0.8.0",
		Metadata: Metadata{Name: "a"},
		Models: map[string]Model{
			"Outer": {
				Variables:  map[string]ModelVariable{},
				Equations:  []Equation{},
				Subsystems: map[string]any{"Inner": map[string]any{"ref": "clib.esm"}},
			},
		},
	}
	err := ResolveSubsystemRefs(file, dir)
	if code := couplingErrCode(t, err); code != "subsystem_ref_is_coupling_library" {
		t.Errorf("code = %s; want subsystem_ref_is_coupling_library", code)
	}
}

// A §9.7.2 template import targeting a coupling-library file is rejected.
func TestTemplateImport_IsCouplingLibrary(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "clib.esm"), couplingLibJSON)
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(`"expression_template_imports": [{"ref": "./clib.esm"}],`, ""))
	_, err := LoadPath(p)
	if code := couplingErrCode(t, err); code != "template_import_is_coupling_library" {
		t.Errorf("code = %s; want template_import_is_coupling_library", code)
	}
}

// A relative `coupling_import` `ref` names a file relative to the importing
// document (esm-spec §10.10 -> §4.7), so Flatten with default options must find
// ./rothermel_fuel.esm beside assembly_import.esm although `go test` runs in this
// package directory, which holds no such file. Before the fix the import resolved
// against the working directory and failed with coupling_import_unresolved.
func TestCouplingImportRefResolvesAgainstImportingDocument(t *testing.T) {
	corpus := filepath.Join("..", "..", "..", "..", "tests", "coupling_libraries")
	imp, err := LoadPath(filepath.Join(corpus, "assembly_import.esm"))
	if err != nil {
		t.Fatalf("load assembly_import.esm: %v", err)
	}
	inl, err := LoadPath(filepath.Join(corpus, "assembly_inline.esm"))
	if err != nil {
		t.Fatalf("load assembly_inline.esm: %v", err)
	}
	imported, err := Flatten(imp)
	if err != nil {
		t.Fatalf("flatten import with default options: %v", err)
	}
	inline, err := Flatten(inl)
	if err != nil {
		t.Fatalf("flatten inline: %v", err)
	}
	if !reflect.DeepEqual(imported, inline) {
		t.Errorf("import-expanded flatten != inline flatten")
	}
}

// The document's own base wins over an explicit option, and the authored `ref`
// round-trips verbatim (esm-spec §10.10.3): the base is recorded beside the
// entry, never written into it.
func TestCouplingImportBaseWinsAndRefRoundTripsVerbatim(t *testing.T) {
	corpus := filepath.Join("..", "..", "..", "..", "tests", "coupling_libraries")
	imp, err := LoadPath(filepath.Join(corpus, "assembly_import.esm"))
	if err != nil {
		t.Fatalf("load assembly_import.esm: %v", err)
	}
	if _, err := FlattenWithOptions(imp, CouplingImportOptions{BasePath: filepath.Join("does", "not", "exist")}); err != nil {
		t.Fatalf("flatten with an unrelated BasePath option: %v", err)
	}
	var ref string
	for _, e := range imp.Coupling {
		if c, ok := e.(CouplingImport); ok {
			ref = c.Ref
		}
	}
	if ref != "./rothermel_fuel.esm" {
		t.Errorf("loaded ref = %q, want the authored ./rothermel_fuel.esm", ref)
	}
	out, err := ToJSON(imp)
	if err != nil {
		t.Fatalf("ToJSON: %v", err)
	}
	if !strings.Contains(out, `"ref": "./rothermel_fuel.esm"`) {
		t.Errorf("emitted document lost the authored ref")
	}
}

// A document loaded by BARE FILENAME from its own directory has "." as its base,
// which is a real location and must anchor the import just as any other does:
// the "." default of loadOptions.basePath is what means "no base", not the value
// itself. Without basePathSet the option below won, so this document resolved
// its import somewhere else than the four other bindings did.
func TestCouplingImportBareFilenameLoadKeepsItsOwnDirectory(t *testing.T) {
	corpus, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "tests", "coupling_libraries"))
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(corpus); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	defer func() {
		if err := os.Chdir(cwd); err != nil {
			t.Fatalf("chdir back: %v", err)
		}
	}()
	f, err := LoadPath("assembly_import.esm")
	if err != nil {
		t.Fatalf("load assembly_import.esm: %v", err)
	}
	if _, err := FlattenWithOptions(f, CouplingImportOptions{BasePath: filepath.Join("does", "not", "exist")}); err != nil {
		t.Errorf("the document's own directory must win over the option: %v", err)
	}
}

// A document the caller gave no base for — built in memory, or parsed from text
// — has no location of its own, so Flatten's BasePath stays in charge. All five
// bindings agree on this, so a caller's base is never silently replaced.
func TestCouplingImportInMemoryDocumentKeepsTheCallersBase(t *testing.T) {
	corpus, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "tests", "coupling_libraries"))
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(corpus, "assembly_import.esm"))
	if err != nil {
		t.Fatalf("read assembly_import.esm: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for name, load := range map[string]func() (*ESMFile, error){
		"LoadString":   func() (*ESMFile, error) { return LoadString(string(raw)) },
		"LoadDocument": func() (*ESMFile, error) { return LoadDocument(doc) },
	} {
		f, err := load()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if _, err := FlattenWithOptions(f, CouplingImportOptions{BasePath: corpus}); err != nil {
			t.Errorf("%s: the caller's BasePath must resolve the import: %v", name, err)
		}
	}
	// An explicit base at load anchors the document with no BasePath at all.
	for name, load := range map[string]func() (*ESMFile, error){
		"LoadString":   func() (*ESMFile, error) { return LoadString(string(raw), WithBasePath(corpus)) },
		"LoadDocument": func() (*ESMFile, error) { return LoadDocument(doc, WithBasePath(corpus)) },
	} {
		f, err := load()
		if err != nil {
			t.Fatalf("%s with a base: %v", name, err)
		}
		if _, err := Flatten(f); err != nil {
			t.Errorf("%s: the explicit load base must resolve the import: %v", name, err)
		}
	}
}

// A structurally complete `bind` that points a role at a component lacking a
// referenced variable is reported by Validate on the SOURCE document, not only
// at flatten, and the finding is re-pointed at the import entry and names the
// import, role and component (esm-spec §10.10.3).
func TestValidateReportsAMisBoundImportOnTheSourceDocument(t *testing.T) {
	corpus, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "tests", "coupling_libraries"))
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	file, err := LoadPath(filepath.Join(corpus, "import_misbind_downstream.esm"))
	if err != nil {
		t.Fatalf("load import_misbind_downstream.esm: %v", err)
	}
	result := Validate(file)
	var found *StructuralError
	for i := range result.StructuralErrors {
		e := &result.StructuralErrors[i]
		if e.Code == ErrorUnresolvedScopedRef && e.Details["coupling_import"] != nil {
			found = e
			break
		}
	}
	if found == nil {
		t.Fatalf("no import-attributed unresolved_scoped_ref in %+v", result.StructuralErrors)
	}
	if found.Path != "/coupling/0" {
		t.Errorf("path = %q, want /coupling/0", found.Path)
	}
	if got := found.Details["bound_component"]; got != "RothermelNoW0" {
		t.Errorf("bound_component = %v, want RothermelNoW0", got)
	}
	if got := found.Details["role"]; got != "Spread" {
		t.Errorf("role = %v, want Spread", got)
	}
	if result.IsValid {
		t.Error("a mis-bound import must make the document invalid")
	}

	// A document with no recorded base does no file I/O, so it reports nothing
	// about the import rather than resolving the ref against the working dir.
	raw, err := os.ReadFile(filepath.Join(corpus, "import_misbind_downstream.esm"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	noBase, err := LoadString(string(raw))
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	for _, e := range Validate(noBase).StructuralErrors {
		if e.Details["coupling_import"] != nil {
			t.Errorf("a document with no base must not expand its imports: %+v", e)
		}
	}
}

// A coupling library's edges name ROLES, not systems (esm-spec §10.9). Go never
// resolved them against a symbol table, so it never rejected a well-formed
// library — but §10.9 REPLACES that resolution rather than dropping it, and Go's
// library short-circuit used to drop it, silently accepting a typo'd role that
// the other four bindings reject. The same typo is rejected by the import-time
// check the moment an assembly binds the library, so the two sites now agree.
func TestValidateCouplingLibraryRoleRefs(t *testing.T) {
	lib := `{
      "esm": "1.1.0",
      "metadata": {"name": "RoleScopedLib"},
      "coupling_roles": {
        "Source": {"description": "provides x"},
        "Sink": {"description": "consumes x"}
      },
      "coupling": [
        {"type": "variable_map", "from": "Source.x", "to": "Sink.x",
         "transform": "param_to_var"},
        {"type": "operator_compose", "systems": ["Source", "Sink"],
         "translate": {"Source.x": "Sink.x"}, "require_match": false}
      ]
    }`

	if r := ValidateText(lib); !r.IsValid || len(r.StructuralErrors) != 0 {
		t.Fatalf("a well-formed coupling library must validate clean, got %+v", r.StructuralErrors)
	}

	for _, tc := range []struct {
		name, doc, path, role string
	}{
		{"variable_map endpoint", strings.Replace(lib, `"to": "Sink.x"`, `"to": "Snik.x"`, 1), "/coupling/0", "Snik"},
		// A site an endpoint-only check cannot see.
		{"operator_compose systems", strings.Replace(lib, `["Source", "Sink"]`, `["Ghost", "Sink"]`, 1), "/coupling/1", "Ghost"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := ValidateText(tc.doc)
			if r.IsValid || len(r.StructuralErrors) != 1 {
				t.Fatalf("an undeclared role must be rejected, got valid=%v errors=%+v", r.IsValid, r.StructuralErrors)
			}
			e := r.StructuralErrors[0]
			if e.Code != CodeCouplingEdgeUnknownRole {
				t.Errorf("code = %q, want %q", e.Code, CodeCouplingEdgeUnknownRole)
			}
			if e.Path != tc.path {
				t.Errorf("path = %q, want %q", e.Path, tc.path)
			}
			if !strings.Contains(e.Message, "'"+tc.role+"'") {
				t.Errorf("message must name %q, got %q", tc.role, e.Message)
			}
		})
	}
}

// The shared corpus pins the standalone verdict too, not just an in-memory
// document: tests/coupling_libraries/rothermel_fuel.esm must validate clean and
// lib_unknown_role_edge.esm must name its undeclared role.
func TestValidateCouplingLibraryCorpusStandalone(t *testing.T) {
	corpus := filepath.Join("..", "..", "..", "..", "tests", "coupling_libraries")
	good, err := os.ReadFile(filepath.Join(corpus, "rothermel_fuel.esm"))
	if err != nil {
		t.Fatalf("read rothermel_fuel.esm: %v", err)
	}
	if r := ValidateText(string(good)); !r.IsValid || len(r.StructuralErrors) != 0 {
		t.Fatalf("a well-formed corpus library must validate clean, got %+v", r.StructuralErrors)
	}

	bad, err := os.ReadFile(filepath.Join(corpus, "lib_unknown_role_edge.esm"))
	if err != nil {
		t.Fatalf("read lib_unknown_role_edge.esm: %v", err)
	}
	r := ValidateText(string(bad))
	if r.IsValid || len(r.StructuralErrors) != 1 {
		t.Fatalf("lib_unknown_role_edge.esm must be rejected standalone, got valid=%v errors=%+v", r.IsValid, r.StructuralErrors)
	}
	if e := r.StructuralErrors[0]; e.Code != CodeCouplingEdgeUnknownRole || !strings.Contains(e.Message, "'Ghost'") {
		t.Errorf("want %s naming 'Ghost', got %s / %s", CodeCouplingEdgeUnknownRole, e.Code, e.Message)
	}
}
