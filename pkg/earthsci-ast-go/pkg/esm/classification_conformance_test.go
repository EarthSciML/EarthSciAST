package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// classification_conformance_test.go wires the Go binding to the cross-language
// oracle for the esm-spec §6.3.1 classification API,
// tests/conformance/classification/.
//
// Five bindings deriving these categories independently is five chances to
// disagree, so the goldens pin ONE answer. Every list is sorted lexicographically
// by UTF-8 code point, which is what makes the comparison order-independent
// across languages, and a golden's model keys are dot-paths from the document
// root, so a subsystem is "Parent.Child".

// classificationGolden mirrors one model entry of a golden file.
type classificationGolden struct {
	ODEStates          []string `json:"ode_states"`
	ObservedUnknowns   []string `json:"observed_unknowns"`
	AlgebraicUnknowns  []string `json:"algebraic_unknowns"`
	BrownianParameters []string `json:"brownian_parameters"`
	DiscreteParameters []string `json:"discrete_parameters"`
	SampledParameters  []string `json:"sampled_parameters"`
	ConstantParameters []string `json:"constant_parameters"`
	SystemKind         string   `json:"system_kind"`
	// DeclaredSystemKind is the model's explicit `system_kind` field, or null
	// when absent — hence the pointer. A golden may omit the key entirely, which
	// means the same thing as null.
	DeclaredSystemKind *string `json:"declared_system_kind"`
}

type classificationManifest struct {
	Fixtures []struct {
		ID      string `json:"id"`
		Fixture string `json:"fixture"`
		Golden  string `json:"golden"`
		Pins    string `json:"pins"`
	} `json:"fixtures"`
	BindingsRequired []string `json:"bindings_required"`
}

func classificationDir(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(repoRoot, "tests", "conformance", "classification")
}

// TestClassificationConformance drives every manifest fixture through the
// §6.3.1 functions and compares the result to the committed golden.
func TestClassificationConformance(t *testing.T) {
	dir := classificationDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var manifest classificationManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	if len(manifest.Fixtures) == 0 {
		t.Fatal("manifest lists no fixtures")
	}
	// Go is a REQUIRED binding for this category; if that ever changes, the
	// wiring below should be revisited rather than silently kept.
	if !containsString(manifest.BindingsRequired, "go") {
		t.Fatalf("manifest no longer requires the go binding: %v", manifest.BindingsRequired)
	}

	for _, fx := range manifest.Fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			file, err := Load(filepath.Join(dir, fx.Fixture))
			if err != nil {
				t.Fatalf("load %s: %v", fx.Fixture, err)
			}
			goldenRaw, err := os.ReadFile(filepath.Join(dir, fx.Golden))
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}
			var golden struct {
				Models map[string]classificationGolden `json:"models"`
			}
			if err := json.Unmarshal(goldenRaw, &golden); err != nil {
				t.Fatalf("parse golden: %v", err)
			}

			got := classifyDocument(t, file)

			// Every model the golden names must be present, and vice versa: a
			// binding that flattens the document first would report one merged
			// entry where the golden has two scoped ones.
			if !reflect.DeepEqual(sortedKeys(got), sortedKeys(golden.Models)) {
				t.Fatalf("model node set = %v, want %v (pins: %s)",
					sortedKeys(got), sortedKeys(golden.Models), fx.Pins)
			}

			for _, path := range sortedKeys(golden.Models) {
				want := golden.Models[path]
				have := got[path]
				checkList(t, path, "ode_states", have.ODEStates, want.ODEStates)
				checkList(t, path, "observed_unknowns", have.ObservedUnknowns, want.ObservedUnknowns)
				checkList(t, path, "algebraic_unknowns", have.AlgebraicUnknowns, want.AlgebraicUnknowns)
				checkList(t, path, "brownian_parameters", have.BrownianParameters, want.BrownianParameters)
				checkList(t, path, "discrete_parameters", have.DiscreteParameters, want.DiscreteParameters)
				checkList(t, path, "sampled_parameters", have.SampledParameters, want.SampledParameters)
				checkList(t, path, "constant_parameters", have.ConstantParameters, want.ConstantParameters)
				if have.SystemKind != want.SystemKind {
					t.Errorf("%s: system_kind = %q, want %q", path, have.SystemKind, want.SystemKind)
				}
				if !reflect.DeepEqual(have.DeclaredSystemKind, want.DeclaredSystemKind) {
					t.Errorf("%s: declared_system_kind = %v, want %v",
						path, derefOrNil(have.DeclaredSystemKind), derefOrNil(want.DeclaredSystemKind))
				}
			}
		})
	}
}

// TestClassificationPartitions asserts the property the manifest states as a
// contract and the goldens can only sample: the three unknown sets partition the
// model's unknowns and the four parameter sets partition its parameters.
//
// A partition is stronger than "the goldens match" — it has to hold for every
// document, not just the five that are pinned — so it is checked over the whole
// valid corpus rather than over the classification fixtures alone.
func TestClassificationPartitions(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	files, err := filepath.Glob(filepath.Join(repoRoot, "tests", "valid", "*.esm"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("no valid fixtures found")
	}
	for _, path := range files {
		file, err := Load(path)
		if err != nil {
			// Loadability is another test's business; a fixture this one cannot
			// read simply contributes no partition evidence.
			continue
		}
		name := filepath.Base(path)
		for modelName, model := range file.Models {
			model := model
			assertPartitions(t, name+"::"+modelName, file, &model)
		}
	}
}

// assertPartitions checks disjointness and completeness of both partitions.
func assertPartitions(t *testing.T, label string, file *ESMFile, model *Model) {
	t.Helper()

	unknownParts := map[string][]string{
		"ode_states":         ODEStatesIn(file, model),
		"observed_unknowns":  ObservedUnknownsIn(file, model),
		"algebraic_unknowns": AlgebraicUnknownsIn(file, model),
	}
	checkPartition(t, label, "unknowns", unknownParts, Unknowns(model))

	var parameters []string
	for name, v := range model.Variables {
		if v.Type == VarTypeParameter {
			parameters = append(parameters, name)
		}
	}
	sort.Strings(parameters)
	paramParts := map[string][]string{
		"brownian_parameters": BrownianParameters(model),
		"discrete_parameters": DiscreteParameters(model),
		"sampled_parameters":  SampledParameters(model),
		"constant_parameters": ConstantParameters(model),
	}
	checkPartition(t, label, "parameters", paramParts, parameters)
}

// checkPartition reports any name in two parts at once (not disjoint) and any
// mismatch between the union and the whole (not covering).
func checkPartition(t *testing.T, label, whole string, parts map[string][]string, all []string) {
	t.Helper()
	seenIn := map[string]string{}
	var union []string
	for _, partName := range sortedKeys(parts) {
		for _, name := range parts[partName] {
			if prev, dup := seenIn[name]; dup {
				t.Errorf("%s: %q is in both %s and %s; the %s sets must be DISJOINT",
					label, name, prev, partName, whole)
				continue
			}
			seenIn[name] = partName
			union = append(union, name)
		}
	}
	sort.Strings(union)
	if len(union) == 0 {
		union = nil
	}
	if len(all) == 0 {
		all = nil
	}
	if !reflect.DeepEqual(union, all) {
		t.Errorf("%s: the %s partition covers %v, but the model declares %v",
			label, whole, union, all)
	}
}

// classifyDocument classifies every model NODE of the document, keyed by its
// dot-path from the root, so a subsystem appears as "Parent.Child".
//
// Classification is per node and not per document: a binding that flattened
// first would return one merged answer where the golden has two scoped ones.
func classifyDocument(t *testing.T, file *ESMFile) map[string]classificationGolden {
	t.Helper()
	out := map[string]classificationGolden{}
	for _, name := range sortedKeys(file.Models) {
		model := file.Models[name]
		classifyNode(t, file, &model, name, out)
	}
	return out
}

func classifyNode(t *testing.T, file *ESMFile, model *Model, path string, out map[string]classificationGolden) {
	t.Helper()
	entry := classificationGolden{
		ODEStates:          ODEStatesIn(file, model),
		ObservedUnknowns:   ObservedUnknownsIn(file, model),
		AlgebraicUnknowns:  AlgebraicUnknownsIn(file, model),
		BrownianParameters: BrownianParameters(model),
		DiscreteParameters: DiscreteParameters(model),
		SampledParameters:  SampledParameters(model),
		ConstantParameters: ConstantParameters(model),
		SystemKind:         SystemKindIn(file, model),
	}
	if declared, ok := DeclaredSystemKind(model); ok {
		entry.DeclaredSystemKind = &declared
	}
	out[path] = entry

	// Subsystems are held untyped (Model.Subsystems is map[string]any), so a
	// nested node is re-decoded into a Model before being classified in its own
	// scope.
	for _, subName := range sortedKeys(model.Subsystems) {
		raw, err := json.Marshal(model.Subsystems[subName])
		if err != nil {
			t.Fatalf("%s: re-marshal subsystem %q: %v", path, subName, err)
		}
		var sub Model
		if err := json.Unmarshal(raw, &sub); err != nil {
			// A `ref` subsystem carries no inline model; it contributes no node.
			continue
		}
		if len(sub.Variables) == 0 && len(sub.Equations) == 0 {
			continue
		}
		classifyNode(t, file, &sub, path+"."+subName, out)
	}
}

func checkList(t *testing.T, path, field string, got, want []string) {
	t.Helper()
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%s: %s = %v, want %v", path, field, got, want)
	}
}

func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}

func derefOrNil(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}
