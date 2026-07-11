package esm

// Go mirror of pkg/earthsci-ast-ts/src/coupling-imports.test.ts: detection,
// expansion, flatten equivalence, multiple instantiation, and the esm-spec
// §10.11 diagnostics (all 11 codes).

import (
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
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
	_, err := Load(p)
	if code := couplingErrCode(t, err); code != "template_import_is_coupling_library" {
		t.Errorf("code = %s; want template_import_is_coupling_library", code)
	}
}
