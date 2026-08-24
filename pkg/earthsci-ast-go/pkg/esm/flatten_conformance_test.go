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

// TestFlattenConformance drives the Go binding against the shared `flatten`
// conformance corpus (tests/conformance/flatten/cases.json, generated from the
// Python oracle by scripts/generate-flatten-corpus.py).
//
// The corpus pins the canonical FlattenedSystem field set of esm-libraries-spec
// §4.7.5 step 4 for 19 shared fixtures, plus two documents flatten must REFUSE.
// ORDER IS PART OF THE CONTRACT — a parameter vector is positional — so every
// list here is compared as a SEQUENCE, never as a set. That is the property most
// likely to differ silently: Go sorted every role list alphabetically until this
// test existed, emitting [OU.Bw, OU.sigma, OU.theta] where the document declares
// [OU.theta, OU.sigma, OU.Bw].
//
// Equations are compared through ToAscii, the same renderer the shared display
// fixtures and the expression-parse corpus use, so an equation mismatch is a
// mismatch of the TREE and not of a private pretty-printer.

type flattenCorpus struct {
	Cases    []flattenCase `json:"cases"`
	Refusals []struct {
		Fixture string `json:"fixture"`
		Error   string `json:"error"`
		Reason  string `json:"reason"`
	} `json:"refusals"`
}

type flattenVarRecord struct {
	Name             string   `json:"name"`
	Role             string   `json:"role"`
	Units            *string  `json:"units"`
	Default          any      `json:"default"`
	Shape            []string `json:"shape"`
	UpdateKinds      []string `json:"update_kinds"`
	DistributionKind *string  `json:"distribution_kind"`
	SourceSystem     *string  `json:"source_system"`
}

type flattenEqRecord struct {
	LHS          string  `json:"lhs"`
	RHS          string  `json:"rhs"`
	SourceSystem *string `json:"source_system"`
}

type flattenEventRecord struct {
	Name       *string  `json:"name"`
	Conditions []string `json:"conditions"`
	Affects    []string `json:"affects"`
}

type flattenDomainRecord struct {
	IndependentVariable *string `json:"independent_variable"`
	ElementType         *string `json:"element_type"`
	ArrayType           *string `json:"array_type"`
}

type flattenMetadataRecord struct {
	SourceSystems   []string `json:"source_systems"`
	CouplingRules   []string `json:"coupling_rules"`
	OperatorApplies []string `json:"operator_applies"`
	Callbacks       []string `json:"callbacks"`
}

type flattenICRecord struct {
	State string `json:"state"`
	Expr  string `json:"expr"`
}

type flattenLoaderRecord struct {
	Name         string `json:"name"`
	Owner        string `json:"owner"`
	Source       string `json:"source"`
	FileVariable string `json:"file_variable"`
	Cadence      string `json:"cadence"`
}

type flattenCase struct {
	ID      string `json:"id"`
	Tier    string `json:"tier"`
	Fixture string `json:"fixture"`

	SystemKind           string                `json:"system_kind"`
	IndependentVariables []string              `json:"independent_variables"`
	StateVariables       []flattenVarRecord    `json:"state_variables"`
	Parameters           []flattenVarRecord    `json:"parameters"`
	ObservedVariables    []flattenVarRecord    `json:"observed_variables"`
	AlgebraicVariables   []string              `json:"algebraic_variables"`
	BrownianParameters   []string              `json:"brownian_parameters"`
	DiscreteParameters   []string              `json:"discrete_parameters"`
	EquationCount        int                   `json:"equation_count"`
	Equations            []flattenEqRecord     `json:"equations"`
	ContinuousEvents     []flattenEventRecord  `json:"continuous_events"`
	DiscreteEvents       []flattenEventRecord  `json:"discrete_events"`
	Domain               *flattenDomainRecord  `json:"domain"`
	Metadata             flattenMetadataRecord `json:"metadata"`
	IndexSets            []string              `json:"index_sets"`
	FunctionTables       []string              `json:"function_tables"`
	TemplateRegistry     []string              `json:"template_registry"`
	FieldICs             []flattenICRecord     `json:"field_ics"`
	LoaderFields         []flattenLoaderRecord `json:"loader_fields"`
	LiftedShapes         map[string][]int      `json:"lifted_shapes"`
}

func flattenCorpusRoot(t *testing.T) string {
	t.Helper()
	// pkg/esm -> pkg -> earthsci-ast-go -> pkg -> repo root
	return filepath.Join("..", "..", "..", "..")
}

func loadFlattenCorpus(t *testing.T) flattenCorpus {
	t.Helper()
	path := filepath.Join(flattenCorpusRoot(t), "tests", "conformance", "flatten", "cases.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shared flatten corpus: %v", err)
	}
	var corpus flattenCorpus
	if err := json.Unmarshal(raw, &corpus); err != nil {
		t.Fatalf("parse the shared flatten corpus: %v", err)
	}
	if len(corpus.Cases) == 0 {
		t.Fatal("the flatten corpus declares no cases")
	}
	return corpus
}

// --- Go-side record building -------------------------------------------------

func goVarRecord(v FlattenedVariable) flattenVarRecord {
	kinds := []string{}
	for _, rule := range v.UpdateRules() {
		kinds = append(kinds, rule.Kind)
	}
	var dist *string
	if v.Distribution != nil {
		k := v.Distribution.Kind
		dist = &k
	}
	var source *string
	if v.SourceSystem != "" {
		s := v.SourceSystem
		source = &s
	}
	return flattenVarRecord{
		Name: v.Name, Role: v.Role, Units: v.Units, Default: v.Default,
		Shape: v.Shape, UpdateKinds: kinds, DistributionKind: dist, SourceSystem: source,
	}
}

func goVarRecords(vs []FlattenedVariable) []flattenVarRecord {
	out := make([]flattenVarRecord, 0, len(vs))
	for _, v := range vs {
		out = append(out, goVarRecord(v))
	}
	return out
}

func goVarNames(vs []FlattenedVariable) []string {
	out := make([]string, 0, len(vs))
	for _, v := range vs {
		out = append(out, v.Name)
	}
	return out
}

func goEventRecord(name *string, conditions []Expression, affects []AffectEquation) flattenEventRecord {
	conds := []string{}
	for _, c := range conditions {
		conds = append(conds, ToAscii(c))
	}
	acts := []string{}
	for _, a := range affects {
		acts = append(acts, fmt.Sprintf("%s = %s", ToAscii(a.LHS), ToAscii(a.RHS)))
	}
	return flattenEventRecord{Name: name, Conditions: conds, Affects: acts}
}

func goFlattenCase(flat *FlattenedSystem) flattenCase {
	eqs := make([]flattenEqRecord, 0, len(flat.Equations))
	for _, eq := range flat.Equations {
		src := eq.SourceSystem
		eqs = append(eqs, flattenEqRecord{LHS: ToAscii(eq.LHS), RHS: ToAscii(eq.RHS), SourceSystem: &src})
	}
	continuous := []flattenEventRecord{}
	for _, ce := range flat.ContinuousEvents {
		continuous = append(continuous, goEventRecord(ce.Name, ce.Conditions, ce.Affects))
	}
	discrete := []flattenEventRecord{}
	for _, de := range flat.DiscreteEvents {
		var name *string
		if de.Name != "" {
			n := de.Name
			name = &n
		}
		discrete = append(discrete, goEventRecord(name, nil, de.Affects))
	}
	var domain *flattenDomainRecord
	if flat.Domain != nil {
		domain = &flattenDomainRecord{
			IndependentVariable: flat.Domain.IndependentVariable,
			ElementType:         flat.Domain.ElementType,
			ArrayType:           flat.Domain.ArrayType,
		}
	}
	indexSets := []string{}
	for _, s := range flat.IndexSets {
		indexSets = append(indexSets, s.Name)
	}
	tables := []string{}
	for _, s := range flat.FunctionTables {
		tables = append(tables, s.Name)
	}
	templates := []string{}
	for _, s := range flat.TemplateRegistry {
		templates = append(templates, s.Name)
	}
	ics := []flattenICRecord{}
	for _, ic := range flat.FieldICs {
		ics = append(ics, flattenICRecord{State: ic.State, Expr: ToAscii(ic.Expr)})
	}
	loaders := []flattenLoaderRecord{}
	for _, lf := range flat.LoaderFields {
		loaders = append(loaders, flattenLoaderRecord{
			Name: lf.Name, Owner: lf.Owner, Source: lf.Source,
			FileVariable: lf.FileVariable, Cadence: lf.Cadence,
		})
	}
	shapes := map[string][]int{}
	for _, s := range flat.LiftedShapes {
		shapes[s.Name] = s.Shape
	}
	return flattenCase{
		SystemKind:           flat.SystemKind(),
		IndependentVariables: flat.IndependentVariables,
		StateVariables:       goVarRecords(flat.StateVariables),
		Parameters:           goVarRecords(flat.Parameters),
		ObservedVariables:    goVarRecords(flat.ObservedVariables),
		AlgebraicVariables:   goVarNames(flat.AlgebraicVariables),
		BrownianParameters:   goVarNames(flat.BrownianParameters),
		DiscreteParameters:   goVarNames(flat.DiscreteParameters),
		EquationCount:        len(flat.Equations),
		Equations:            eqs,
		ContinuousEvents:     continuous,
		DiscreteEvents:       discrete,
		Domain:               domain,
		Metadata: flattenMetadataRecord{
			SourceSystems:   flat.Metadata.SourceSystems,
			CouplingRules:   flat.Metadata.CouplingRules,
			OperatorApplies: flat.Metadata.OperatorApplies,
			Callbacks:       flat.Metadata.Callbacks,
		},
		IndexSets:        indexSets,
		FunctionTables:   tables,
		TemplateRegistry: templates,
		FieldICs:         ics,
		LoaderFields:     loaders,
		LiftedShapes:     shapes,
	}
}

// --- comparison --------------------------------------------------------------

// sameDefault compares two declared `default` values. Numeric values compare
// NUMERICALLY: the corpus is JSON produced by Python, where an integer default
// is an int and a float default a float, while Go's decoder hands every
// non-Expression `default` back as a float64 — an int/float WIRE distinction
// that is not what step 4 pins. Anything else compares by its JSON encoding.
func sameDefault(a, b any) bool {
	an, aok := exprNumber(a)
	bn, bok := exprNumber(b)
	if aok && bok {
		return an == bn
	}
	if aok != bok {
		return false
	}
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	// An expression-valued default is pinned by the corpus as {"expr": <ascii>}.
	if m, ok := b.(map[string]any); ok {
		if want, ok := m["expr"].(string); ok {
			return ToAscii(a) == want
		}
	}
	aj, _ := json.Marshal(a)
	bj, _ := json.Marshal(b)
	return string(aj) == string(bj)
}

func diffVarRecords(t *testing.T, field string, got, want []flattenVarRecord) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%s: %d entries, want %d\n  got:  %v\n  want: %v",
			field, len(got), len(want), varNamesOf(got), varNamesOf(want))
		return
	}
	for i := range want {
		g, w := got[i], want[i]
		if g.Name != w.Name {
			t.Errorf("%s[%d]: name %q, want %q (ORDER is normative: %v vs %v)",
				field, i, g.Name, w.Name, varNamesOf(got), varNamesOf(want))
			continue
		}
		if g.Role != w.Role {
			t.Errorf("%s[%d] %s: role %q, want %q", field, i, w.Name, g.Role, w.Role)
		}
		if !sameStrPtr(g.Units, w.Units) {
			t.Errorf("%s[%d] %s: units %v, want %v", field, i, w.Name, showStr(g.Units), showStr(w.Units))
		}
		if !sameDefault(g.Default, w.Default) {
			t.Errorf("%s[%d] %s: default %#v, want %#v", field, i, w.Name, g.Default, w.Default)
		}
		if !sameStrSlice(g.Shape, w.Shape) {
			t.Errorf("%s[%d] %s: shape %v, want %v", field, i, w.Name, g.Shape, w.Shape)
		}
		if !sameStrSlice(g.UpdateKinds, w.UpdateKinds) {
			t.Errorf("%s[%d] %s: update kinds %v, want %v", field, i, w.Name, g.UpdateKinds, w.UpdateKinds)
		}
		if !sameStrPtr(g.DistributionKind, w.DistributionKind) {
			t.Errorf("%s[%d] %s: distribution kind %v, want %v",
				field, i, w.Name, showStr(g.DistributionKind), showStr(w.DistributionKind))
		}
		if !sameStrPtr(g.SourceSystem, w.SourceSystem) {
			t.Errorf("%s[%d] %s: source system %v, want %v",
				field, i, w.Name, showStr(g.SourceSystem), showStr(w.SourceSystem))
		}
	}
}

func varNamesOf(vs []flattenVarRecord) []string {
	out := make([]string, 0, len(vs))
	for _, v := range vs {
		out = append(out, v.Name)
	}
	return out
}

func showStr(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

func sameStrPtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

func sameStrSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func diffStrSeq(t *testing.T, field string, got, want []string) {
	t.Helper()
	if !sameStrSlice(got, want) {
		t.Errorf("%s: sequence mismatch (ORDER is normative)\n  got:  %v\n  want: %v", field, got, want)
	}
}

func TestFlattenConformance(t *testing.T) {
	corpus := loadFlattenCorpus(t)
	root := flattenCorpusRoot(t)

	for _, want := range corpus.Cases {
		t.Run(want.ID, func(t *testing.T) {
			path := filepath.Join(root, "tests", filepath.FromSlash(want.Fixture))
			file, err := LoadPath(path)
			if err != nil {
				t.Fatalf("load %s: %v", want.Fixture, err)
			}
			flat, err := Flatten(file)
			if err != nil {
				t.Fatalf("flatten %s: %v", want.Fixture, err)
			}
			got := goFlattenCase(flat)

			if got.SystemKind != want.SystemKind {
				t.Errorf("system_kind = %q, want %q", got.SystemKind, want.SystemKind)
			}
			diffStrSeq(t, "independent_variables", got.IndependentVariables, want.IndependentVariables)
			diffVarRecords(t, "state_variables", got.StateVariables, want.StateVariables)
			diffVarRecords(t, "parameters", got.Parameters, want.Parameters)
			diffVarRecords(t, "observed_variables", got.ObservedVariables, want.ObservedVariables)
			diffStrSeq(t, "algebraic_variables", got.AlgebraicVariables, want.AlgebraicVariables)
			diffStrSeq(t, "brownian_parameters", got.BrownianParameters, want.BrownianParameters)
			diffStrSeq(t, "discrete_parameters", got.DiscreteParameters, want.DiscreteParameters)

			if got.EquationCount != want.EquationCount {
				t.Errorf("equation_count = %d, want %d", got.EquationCount, want.EquationCount)
			}
			for i := 0; i < len(want.Equations) && i < len(got.Equations); i++ {
				g, w := got.Equations[i], want.Equations[i]
				if g.LHS != w.LHS || g.RHS != w.RHS || !sameStrPtr(g.SourceSystem, w.SourceSystem) {
					t.Errorf("equations[%d]:\n  got  %s | %s ~ %s\n  want %s | %s ~ %s",
						i, showStr(g.SourceSystem), g.LHS, g.RHS,
						showStr(w.SourceSystem), w.LHS, w.RHS)
				}
			}

			diffEvents(t, "continuous_events", got.ContinuousEvents, want.ContinuousEvents)
			diffEvents(t, "discrete_events", got.DiscreteEvents, want.DiscreteEvents)

			diffDomain(t, got.Domain, want.Domain)
			diffStrSeq(t, "metadata.source_systems", got.Metadata.SourceSystems, want.Metadata.SourceSystems)
			diffStrSeq(t, "metadata.coupling_rules",
				got.Metadata.CouplingRules, want.Metadata.CouplingRules)
			diffStrSeq(t, "metadata.operator_applies", got.Metadata.OperatorApplies, want.Metadata.OperatorApplies)
			diffStrSeq(t, "metadata.callbacks", got.Metadata.Callbacks, want.Metadata.Callbacks)

			diffStrSeq(t, "index_sets", got.IndexSets, want.IndexSets)
			diffStrSeq(t, "function_tables", got.FunctionTables, want.FunctionTables)
			diffStrSeq(t, "template_registry", got.TemplateRegistry, want.TemplateRegistry)

			if len(got.FieldICs) != len(want.FieldICs) {
				t.Errorf("field_ics: %d entries, want %d (%+v vs %+v)",
					len(got.FieldICs), len(want.FieldICs), got.FieldICs, want.FieldICs)
			} else {
				for i := range want.FieldICs {
					if got.FieldICs[i] != want.FieldICs[i] {
						t.Errorf("field_ics[%d] = %+v, want %+v", i, got.FieldICs[i], want.FieldICs[i])
					}
				}
			}
			if len(got.LoaderFields) != len(want.LoaderFields) {
				t.Errorf("loader_fields: %d entries, want %d\n  got:  %+v\n  want: %+v",
					len(got.LoaderFields), len(want.LoaderFields), got.LoaderFields, want.LoaderFields)
			} else {
				for i := range want.LoaderFields {
					if got.LoaderFields[i] != want.LoaderFields[i] {
						t.Errorf("loader_fields[%d] = %+v, want %+v", i, got.LoaderFields[i], want.LoaderFields[i])
					}
				}
			}
			if !reflect.DeepEqual(normalizeShapes(got.LiftedShapes), normalizeShapes(want.LiftedShapes)) {
				t.Errorf("lifted_shapes = %v, want %v", got.LiftedShapes, want.LiftedShapes)
			}
			checkSubsetInvariants(t, flat)
		})
	}

	for _, refusal := range corpus.Refusals {
		t.Run("refuses/"+refusal.Fixture, func(t *testing.T) {
			path := filepath.Join(root, "tests", filepath.FromSlash(refusal.Fixture))
			file, err := LoadPath(path)
			if err != nil {
				// The oracle's ExpressionTemplateError refusals happen at LOAD;
				// Go raises the same named error there.
				if refusal.Error == "ExpressionTemplateError" && isExpressionTemplateError(err) {
					return
				}
				t.Fatalf("load %s: unexpected error %v (corpus expects a %s from flatten)",
					refusal.Fixture, err, refusal.Error)
			}
			if _, err := Flatten(file); err == nil {
				t.Fatalf("%s: flatten accepted a document the corpus says it must refuse (%s)",
					refusal.Fixture, refusal.Reason)
			}
		})
	}
}

// diffDomain compares the flattened domain against the corpus.
//
// `element_type` and `array_type` are compared UNCONDITIONALLY. They were
// exempted while the oracle could not represent them (Python's Domain dataclass
// carried neither field, so load dropped them and the corpus recorded null
// everywhere). That gap is CLOSED: the oracle now parses and serializes both,
// and the corpus records the authored values.
func diffDomain(t *testing.T, got, want *flattenDomainRecord) {
	t.Helper()
	if (got == nil) != (want == nil) {
		t.Errorf("domain = %+v, want %+v", got, want)
		return
	}
	if got == nil {
		return
	}
	if !sameStrPtr(got.IndependentVariable, want.IndependentVariable) {
		t.Errorf("domain.independent_variable = %v, want %v",
			showStr(got.IndependentVariable), showStr(want.IndependentVariable))
	}
	if !sameStrPtr(got.ElementType, want.ElementType) {
		t.Errorf("domain.element_type = %v, want %v",
			showStr(got.ElementType), showStr(want.ElementType))
	}
	if !sameStrPtr(got.ArrayType, want.ArrayType) {
		t.Errorf("domain.array_type = %v, want %v",
			showStr(got.ArrayType), showStr(want.ArrayType))
	}
}

// checkSubsetInvariants asserts, on the Go side, the structural rules the corpus
// generator asserts on the oracle side before a case may enter the corpus. They
// are cheap and they fail LOUDLY at the shape level rather than as a field diff:
//
//   - brownian_parameters ∪ discrete_parameters ⊆ parameters, and the two are
//     disjoint (esm-spec §6.3.1: the four parameter sets PARTITION the
//     parameters, so a wiener-updated entry is a parameter that ALSO appears in
//     brownian_parameters — dropping it makes the parameter vector's LENGTH
//     depend on whether the model happens to be stochastic).
//   - algebraic_variables ⊆ state_variables (a DAE solves for its algebraic
//     unknowns, so they ride in the same `u` vector).
//   - every subset is a SUBSEQUENCE of its parent map, which is the ordering rule
//     in the only form that can be checked without re-reading the document.
func checkSubsetInvariants(t *testing.T, flat *FlattenedSystem) {
	t.Helper()
	brownian := goVarNames(flat.BrownianParameters)
	discrete := goVarNames(flat.DiscreteParameters)
	params := goVarNames(flat.Parameters)
	states := goVarNames(flat.StateVariables)

	for _, label := range []struct {
		name   string
		subset []string
		parent []string
	}{
		{"brownian_parameters", brownian, params},
		{"discrete_parameters", discrete, params},
		{"algebraic_variables", goVarNames(flat.AlgebraicVariables), states},
	} {
		if !isSubsequence(label.subset, label.parent) {
			t.Errorf("%s is not an ordered subset of its parent map:\n  subset: %v\n  parent: %v",
				label.name, label.subset, label.parent)
		}
	}
	seen := map[string]bool{}
	for _, n := range brownian {
		seen[n] = true
	}
	for _, n := range discrete {
		if seen[n] {
			t.Errorf("%s is both a brownian and a discrete parameter", n)
		}
	}
}

func isSubsequence(sub, whole []string) bool {
	i := 0
	for _, w := range whole {
		if i < len(sub) && sub[i] == w {
			i++
		}
	}
	return i == len(sub)
}

func isExpressionTemplateError(err error) bool {
	return strings.Contains(fmt.Sprintf("%T", err), "ExpressionTemplateError")
}

func normalizeShapes(m map[string][]int) map[string][]int {
	if len(m) == 0 {
		return map[string][]int{}
	}
	return m
}

func diffEvents(t *testing.T, field string, got, want []flattenEventRecord) {
	t.Helper()
	if len(got) != len(want) {
		t.Errorf("%s: %d entries, want %d\n  got:  %+v\n  want: %+v", field, len(got), len(want), got, want)
		return
	}
	for i := range want {
		if !sameStrPtr(got[i].Name, want[i].Name) {
			t.Errorf("%s[%d]: name %v, want %v", field, i, showStr(got[i].Name), showStr(want[i].Name))
		}
		diffStrSeq(t, fmt.Sprintf("%s[%d].conditions", field, i), got[i].Conditions, want[i].Conditions)
		diffStrSeq(t, fmt.Sprintf("%s[%d].affects", field, i), got[i].Affects, want[i].Affects)
	}
}

// TestFlattenDomainPassthrough pins that a document's float-precision and
// array-backend selection survives Flatten.
//
// esm-schema.json declares two fields on Domain that select real numerical
// behaviour:
//
//	element_type : enum ["Float32","Float64"], default "Float64" -- float precision
//	array_type   : string, default "Array"    -- array backend, e.g. "CuArray" (GPU)
//
// esm-libraries-spec §4.7.5 step 4 says the flattened `domain` is "the file's
// `domain` section, UNCHANGED", so both must pass through.
//
// HISTORY, because it explains why this is pinned separately from the corpus
// comparison. Both fields used to be recorded as null for EVERY corpus case:
// the Python oracle's Domain dataclass carried neither, so load dropped them
// before flatten ran and the generator's getattr(..., None) recorded null. Go
// was correct and the ORACLE was wrong, so diffDomain carried an exemption and
// this test asserted the gap from both sides. The oracle was fixed on
// 2026-08-24 (Domain now parses AND serializes both fields; the round trip had
// been lossy too), the corpus regenerated, and the exemption deleted --
// diffDomain now compares both fields unconditionally for all 19 cases.
//
// What survives is the corpus-INDEPENDENT half: tests/valid/model_only.esm
// declares Float32, so the pass-through stays pinned even if no corpus fixture
// declares either field.
func TestFlattenDomainPassthrough(t *testing.T) {
	root := flattenCorpusRoot(t)

	file, err := LoadPath(filepath.Join(root, "tests", "valid", "model_only.esm"))
	if err != nil {
		t.Fatalf("load model_only.esm: %v", err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("flatten model_only.esm: %v", err)
	}
	if flat.Domain == nil {
		t.Fatal("flattened domain is nil; step 4 passes the file's domain section through unchanged")
	}
	if flat.Domain.ElementType == nil || *flat.Domain.ElementType != "Float32" {
		t.Errorf("domain.element_type = %v, want Float32 (the authored value must survive flatten)",
			showStr(flat.Domain.ElementType))
	}
}
