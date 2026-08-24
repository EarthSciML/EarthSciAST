package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The editing ops are exercised against the SHARED corpus rather than
// hand-rolled documents wherever a fixture covers the shape: events_all_types
// carries a model with four variables (two unknowns, two parameters whose
// `update` rules hold their own expression sites), four equations, three
// continuous events with affects and affect_neg, one discrete event, a reaction
// system with three species and two reactions, and two coupling entries — every
// site the §4 operation set touches, in one document.
const editFixtureRel = "valid/events_all_types.esm"

func loadEditFixture(t *testing.T) *ESMFile {
	t.Helper()
	file, err := LoadPath(filepath.Join(repoTestsDir(t), filepath.FromSlash(editFixtureRel)))
	if err != nil {
		t.Fatalf("load %s: %v", editFixtureRel, err)
	}
	return file
}

// mustJSON renders a value for structural comparison. Used to assert both that
// an operation produced the expected shape and that it did NOT write through
// its input.
func editJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

func asEntityNotFound(t *testing.T, err error) *EntityNotFoundError {
	t.Helper()
	e, ok := err.(*EntityNotFoundError)
	if !ok {
		t.Fatalf("error type = %T (%v), want *EntityNotFoundError", err, err)
	}
	if e.DiagnosticCode() != CodeEditEntityNotFound {
		t.Fatalf("code = %q, want %q", e.DiagnosticCode(), CodeEditEntityNotFound)
	}
	return e
}

func asVariableInUse(t *testing.T, err error) *VariableInUseError {
	t.Helper()
	e, ok := err.(*VariableInUseError)
	if !ok {
		t.Fatalf("error type = %T (%v), want *VariableInUseError", err, err)
	}
	if e.DiagnosticCode() != CodeEditVariableInUse {
		t.Fatalf("code = %q, want %q", e.DiagnosticCode(), CodeEditVariableInUse)
	}
	return e
}

// =============================================================================
// Variable operations
// =============================================================================

func TestAddVariableIsImmutable(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	before := editJSON(t, model)

	units := "m"
	added := AddVariable(model, "z", ModelVariable{Type: VarTypeUnknown, Units: &units})

	if _, ok := added.Variables["z"]; !ok {
		t.Fatal("AddVariable did not add the variable")
	}
	if _, ok := model.Variables["z"]; ok {
		t.Fatal("AddVariable wrote through to its input's variables map")
	}
	if got := editJSON(t, model); got != before {
		t.Fatalf("AddVariable mutated its input:\n before: %s\n  after: %s", before, got)
	}
	// Everything else rides through by value.
	if len(added.Equations) != len(model.Equations) {
		t.Fatalf("equations changed: %d vs %d", len(added.Equations), len(model.Equations))
	}
}

func TestRemoveVariableRejectsALiveReference(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]

	// `x` is read by equations, by a parameter's `update.when`, by event
	// conditions, and is WRITTEN by two event affects. Every one of those is a
	// live reference.
	_, err := RemoveVariable(model, "x")
	inUse := asVariableInUse(t, err)
	if inUse.VariableName != "x" {
		t.Fatalf("VariableName = %q", inUse.VariableName)
	}
	if len(inUse.References) == 0 {
		t.Fatal("VariableInUseError lists no references")
	}

	got := map[string]bool{}
	for _, r := range inUse.References {
		got[r] = true
	}
	// Read sites: the equations, and a parameter's own update expressions.
	for _, want := range []string{
		"equation 0",
		"equation 1",
		"variable control_param/update/0/when",
		"continuous_event 0 condition",
	} {
		if !got[want] {
			t.Fatalf("reference %q missing from %v", want, inUse.References)
		}
	}
	// Write sites: an event affect TARGET is a name, not an expression, and
	// must still count as a use.
	if !got["continuous_event 1 affect 0"] || !got["discrete_event 0 affect 0"] {
		t.Fatalf("event affect targets missing from %v", inUse.References)
	}
	// The same site reported from two positions collapses to one entry.
	if len(inUse.References) != len(got) {
		t.Fatalf("duplicate references in %v", inUse.References)
	}
}

func TestRemoveVariableRemovesAnUnreferencedOne(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	before := editJSON(t, model)

	// Add a fresh, unreferenced variable, then remove it: the round trip must
	// land exactly back on the original.
	added := AddVariable(model, "unused_scratch", ModelVariable{Type: VarTypeParameter})
	removed, err := RemoveVariable(added, "unused_scratch")
	if err != nil {
		t.Fatalf("RemoveVariable: %v", err)
	}
	if got := editJSON(t, removed); got != before {
		t.Fatalf("add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}
	if got := editJSON(t, model); got != before {
		t.Fatalf("the round trip mutated the original: %s", got)
	}
}

func TestRemoveVariableUnknownName(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	_, err := RemoveVariable(model, "no_such_variable")
	e := asEntityNotFound(t, err)
	if e.EntityType != "Variable" || e.EntityName != "no_such_variable" {
		t.Fatalf("error = %+v", e)
	}
}

func TestRenameVariableRewritesEverySiteRemovalScans(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	before := editJSON(t, model)

	renamed, err := RenameVariable(model, "x", "x_renamed")
	if err != nil {
		t.Fatalf("RenameVariable: %v", err)
	}
	if got := editJSON(t, model); got != before {
		t.Fatalf("RenameVariable mutated its input: %s", got)
	}

	if _, ok := renamed.Variables["x"]; ok {
		t.Fatal("the old declaration survived the rename")
	}
	if _, ok := renamed.Variables["x_renamed"]; !ok {
		t.Fatal("the new declaration was not created")
	}

	// The invariant that matters: after a rename, NOTHING references the old
	// name any more — so removing it is no longer blocked. That is exactly the
	// lockstep between the read-side scan and the write-side rewrite.
	stillReferenced := []string{}
	for _, site := range modelExpressionSites(renamed, "") {
		if referencesVariable(site.Expr, "x") {
			stillReferenced = append(stillReferenced, site.Site)
		}
	}
	if len(stillReferenced) > 0 {
		t.Fatalf("rename left dangling references to the old name at %v", stillReferenced)
	}
	for i, e := range renamed.ContinuousEvents {
		for j, a := range e.Affects {
			if a.LHS == "x" {
				t.Fatalf("continuous_event %d affect %d still targets the old name", i, j)
			}
		}
	}
	for i, e := range renamed.DiscreteEvents {
		for j, a := range e.Affects {
			if a.LHS == "x" {
				t.Fatalf("discrete_event %d affect %d still targets the old name", i, j)
			}
		}
	}

	// And the new name is genuinely present where the old one was.
	if !referencesVariable(renamed.Equations[0].LHS, "x_renamed") {
		t.Fatalf("equation 0 LHS was not rewritten: %v", renamed.Equations[0].LHS)
	}
}

func TestRenameVariableRoundTrips(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	before := editJSON(t, model)

	there, err := RenameVariable(model, "y", "y_tmp")
	if err != nil {
		t.Fatalf("rename out: %v", err)
	}
	back, err := RenameVariable(there, "y_tmp", "y")
	if err != nil {
		t.Fatalf("rename back: %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("rename round trip is not the identity:\n want: %s\n  got: %s", before, got)
	}
}

func TestRenameVariableUnknownName(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	_, err := RenameVariable(model, "nope", "other")
	asEntityNotFound(t, err)
}

// =============================================================================
// Equation operations
// =============================================================================

func TestEquationOps(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	before := editJSON(t, model)
	n := len(model.Equations)

	added := AddEquation(model, Equation{LHS: "scratch", RHS: float64(0)})
	if len(added.Equations) != n+1 {
		t.Fatalf("AddEquation: %d equations, want %d", len(added.Equations), n+1)
	}
	if len(model.Equations) != n {
		t.Fatal("AddEquation wrote through to its input")
	}

	back, err := RemoveEquationAt(added, n)
	if err != nil {
		t.Fatalf("RemoveEquationAt: %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}

	for _, bad := range []int{-1, n} {
		if _, err := RemoveEquationAt(model, bad); err == nil {
			t.Fatalf("RemoveEquationAt(%d) succeeded on a %d-equation model", bad, n)
		} else {
			asEntityNotFound(t, err)
		}
	}
}

func TestRemoveEquationByLHSIsFieldAware(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]

	// equations 0 and 1 are `D(x, t)` and `D(y, t)`: same op, different args.
	// Equations 2 and 3 are `ic(x)` and `ic(y)`: same op again. A match must
	// therefore compare EVERY field, not just the operator.
	target := model.Equations[1].LHS
	removed, err := RemoveEquationByLHS(model, target)
	if err != nil {
		t.Fatalf("RemoveEquationByLHS: %v", err)
	}
	if len(removed.Equations) != len(model.Equations)-1 {
		t.Fatalf("removed %d equations", len(model.Equations)-len(removed.Equations))
	}
	for i, eq := range removed.Equations {
		if exprEqual(eq.LHS, target) {
			t.Fatalf("equation %d still matches the removed LHS", i)
		}
	}

	// A derivative that differs ONLY in `wrt` must not match.
	wrt := "z"
	nearMiss := ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt}
	if _, err := RemoveEquationByLHS(model, nearMiss); err == nil {
		t.Fatal("a derivative differing only in `wrt` matched")
	} else {
		asEntityNotFound(t, err)
	}

	if _, err := RemoveEquationByLHS(model, "not_an_lhs_here"); err == nil {
		t.Fatal("RemoveEquationByLHS matched a non-existent LHS")
	}
}

func TestSubstituteInEquationsIsTheModelWideAlias(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]

	bindings := map[string]Expression{"control_param": float64(2)}
	viaAlias, err := SubstituteInEquations(model, bindings)
	if err != nil {
		t.Fatalf("SubstituteInEquations: %v", err)
	}
	viaModel, err := SubstituteInModel(model, bindings)
	if err != nil {
		t.Fatalf("SubstituteInModel: %v", err)
	}
	if editJSON(t, viaAlias) != editJSON(t, viaModel) {
		t.Fatal("SubstituteInEquations diverged from SubstituteInModel")
	}
}

// =============================================================================
// Reaction operations
// =============================================================================

func TestReactionOps(t *testing.T) {
	file := loadEditFixture(t)
	system := file.ReactionSystems["EventTestChem"]
	before := editJSON(t, system)
	n := len(system.Reactions)

	added := AddReaction(system, Reaction{ID: "R_scratch", Rate: float64(1)})
	if len(added.Reactions) != n+1 {
		t.Fatalf("AddReaction: %d reactions, want %d", len(added.Reactions), n+1)
	}
	if len(system.Reactions) != n {
		t.Fatal("AddReaction wrote through to its input")
	}

	back, err := RemoveReaction(added, "R_scratch")
	if err != nil {
		t.Fatalf("RemoveReaction: %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}

	if _, err := RemoveReaction(system, "no_such_reaction"); err == nil {
		t.Fatal("RemoveReaction accepted an unknown id")
	} else {
		asEntityNotFound(t, err)
	}
}

func TestRemoveReactionRefusesToEmptyTheSystem(t *testing.T) {
	system := ReactionSystem{
		Species:   map[string]Species{"A": {}},
		Reactions: []Reaction{{ID: "only", Rate: float64(1)}},
	}
	_, err := RemoveReaction(system, "only")
	if err == nil {
		t.Fatal("RemoveReaction emptied a reaction system")
	}
	e, ok := err.(*EditError)
	if !ok || e.DiagnosticCode() != CodeEditInvalidOperation {
		t.Fatalf("error = %T %v, want *EditError with %q", err, err, CodeEditInvalidOperation)
	}
}

func TestSpeciesOps(t *testing.T) {
	file := loadEditFixture(t)
	system := file.ReactionSystems["EventTestChem"]
	before := editJSON(t, system)

	added := AddSpecies(system, "D", Species{})
	if _, ok := added.Species["D"]; !ok {
		t.Fatal("AddSpecies did not add the species")
	}
	if _, ok := system.Species["D"]; ok {
		t.Fatal("AddSpecies wrote through to its input")
	}

	back, err := RemoveSpecies(added, "D")
	if err != nil {
		t.Fatalf("RemoveSpecies: %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}

	if _, err := RemoveSpecies(system, "no_such_species"); err == nil {
		t.Fatal("RemoveSpecies accepted an unknown name")
	} else {
		asEntityNotFound(t, err)
	}
}

func TestRemoveSpeciesRejectsALiveReference(t *testing.T) {
	file := loadEditFixture(t)
	system := file.ReactionSystems["EventTestChem"]

	// Every species in the fixture takes part in a reaction.
	for name := range system.Species {
		_, err := RemoveSpecies(system, name)
		if err == nil {
			continue // an isolated species, if the corpus ever grows one
		}
		inUse := asVariableInUse(t, err)
		if inUse.VariableName != name || len(inUse.References) == 0 {
			t.Fatalf("species %q: %+v", name, inUse)
		}
		for _, ref := range inUse.References {
			if !strings.HasPrefix(ref, "reaction ") && !strings.HasPrefix(ref, "constraint_equation ") {
				t.Fatalf("species %q: unexpected reference label %q", name, ref)
			}
		}
	}
}

// =============================================================================
// Event operations
// =============================================================================

func TestEventOps(t *testing.T) {
	file := loadEditFixture(t)
	model := file.Models["EventTestModel"]
	before := editJSON(t, model)

	name := "scratch_continuous"
	withContinuous := AddContinuousEvent(model, ContinuousEvent{Name: &name, Conditions: []Expression{"x"}})
	if len(withContinuous.ContinuousEvents) != len(model.ContinuousEvents)+1 {
		t.Fatal("AddContinuousEvent did not append")
	}
	if len(model.ContinuousEvents) != 3 {
		t.Fatal("AddContinuousEvent wrote through to its input")
	}
	back, err := RemoveEvent(withContinuous, name)
	if err != nil {
		t.Fatalf("RemoveEvent: %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("continuous add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}

	withDiscrete := AddDiscreteEvent(model, DiscreteEvent{
		Name:    "scratch_discrete",
		Trigger: DiscreteEventTrigger{Type: "condition", Expression: "x"},
	})
	if len(withDiscrete.DiscreteEvents) != len(model.DiscreteEvents)+1 {
		t.Fatal("AddDiscreteEvent did not append")
	}
	back, err = RemoveEvent(withDiscrete, "scratch_discrete")
	if err != nil {
		t.Fatalf("RemoveEvent (discrete): %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("discrete add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}

	// The fixture's own named events are removable by name.
	if _, err := RemoveEvent(model, "complex_condition"); err != nil {
		t.Fatalf("RemoveEvent on a fixture event: %v", err)
	}
	if _, err := RemoveEvent(model, "preset_time_events"); err != nil {
		t.Fatalf("RemoveEvent on a fixture discrete event: %v", err)
	}
	if _, err := RemoveEvent(model, "no_such_event"); err == nil {
		t.Fatal("RemoveEvent accepted an unknown name")
	} else {
		asEntityNotFound(t, err)
	}
}

func TestRemoveEventRemovesEveryMatch(t *testing.T) {
	name := "dup"
	model := Model{
		Variables: map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
		ContinuousEvents: []ContinuousEvent{
			{Name: &name, Conditions: []Expression{"x"}},
			{Name: &name, Conditions: []Expression{"x"}},
		},
	}
	out, err := RemoveEvent(model, name)
	if err != nil {
		t.Fatalf("RemoveEvent: %v", err)
	}
	if len(out.ContinuousEvents) != 0 {
		t.Fatalf("remove-ALL semantics violated: %d events left", len(out.ContinuousEvents))
	}
	// Emptied optional collections vanish from the emitted document.
	if strings.Contains(editJSON(t, out), "continuous_events") {
		t.Fatalf("an emptied optional collection was emitted: %s", editJSON(t, out))
	}
}

// =============================================================================
// Coupling operations
// =============================================================================

func TestCouplingOps(t *testing.T) {
	file := loadEditFixture(t)
	before := editJSON(t, file)
	n := len(file.Coupling)

	composed := Compose(*file, "EventTestChem", "EventTestModel")
	if len(composed.Coupling) != n+1 {
		t.Fatalf("Compose: %d entries, want %d", len(composed.Coupling), n+1)
	}
	if len(file.Coupling) != n {
		t.Fatal("Compose wrote through to its input")
	}
	entry, ok := composed.Coupling[n].(OperatorComposeCoupling)
	if !ok || entry.Type != string(CouplingKindOperatorCompose) {
		t.Fatalf("Compose appended %#v", composed.Coupling[n])
	}

	mapped := MapVariable(*file, "EventTestModel.y", "EventTestChem.k", nil)
	vm, ok := mapped.Coupling[n].(VariableMapCoupling)
	if !ok {
		t.Fatalf("MapVariable appended %#v", mapped.Coupling[n])
	}
	if vm.Type != string(CouplingKindVariableMap) || vm.From != "EventTestModel.y" || vm.To != "EventTestChem.k" {
		t.Fatalf("MapVariable entry = %+v", vm)
	}
	if vm.TransformKind() != "param_to_var" {
		t.Fatalf("default transform = %q, want param_to_var", vm.TransformKind())
	}

	// An Expression transform rides through as the widened form.
	exprTransform := ExprNode{Op: "*", Args: []any{"EventTestModel.y", float64(2)}}
	withExpr := MapVariable(*file, "EventTestModel.y", "EventTestChem.k", exprTransform)
	if !withExpr.Coupling[n].(VariableMapCoupling).TransformIsExpression() {
		t.Fatal("an Expression transform was not carried as one")
	}

	back, err := RemoveCoupling(composed, n)
	if err != nil {
		t.Fatalf("RemoveCoupling: %v", err)
	}
	if got := editJSON(t, back); got != before {
		t.Fatalf("add-then-remove is not the identity:\n want: %s\n  got: %s", before, got)
	}

	for _, bad := range []int{-1, n} {
		if _, err := RemoveCoupling(*file, bad); err == nil {
			t.Fatalf("RemoveCoupling(%d) succeeded on a %d-entry file", bad, n)
		} else {
			asEntityNotFound(t, err)
		}
	}
}

// =============================================================================
// File-level operations
// =============================================================================

func TestMerge(t *testing.T) {
	a := loadEditFixture(t)
	b, err := LoadPath(filepath.Join(repoTestsDir(t), "valid", "minimal_chemistry.esm"))
	if err != nil {
		t.Fatalf("load minimal_chemistry: %v", err)
	}
	beforeA := editJSON(t, a)
	beforeB := editJSON(t, b)

	merged := Merge(*a, *b)

	for name := range a.Models {
		if _, ok := merged.Models[name]; !ok {
			t.Fatalf("merged file lost model %q from the left operand", name)
		}
	}
	for name := range b.Models {
		if _, ok := merged.Models[name]; !ok {
			t.Fatalf("merged file lost model %q from the right operand", name)
		}
	}
	if len(merged.Coupling) != len(a.Coupling)+len(b.Coupling) {
		t.Fatalf("coupling entries = %d, want %d", len(merged.Coupling), len(a.Coupling)+len(b.Coupling))
	}
	// The right operand wins the non-collection fields.
	if merged.ESM != b.ESM || merged.Metadata.Name != b.Metadata.Name {
		t.Fatalf("merged marker/metadata = %q/%q, want %q/%q",
			merged.ESM, merged.Metadata.Name, b.ESM, b.Metadata.Name)
	}
	if editJSON(t, a) != beforeA || editJSON(t, b) != beforeB {
		t.Fatal("Merge mutated an operand")
	}

	// Right-wins on a key collision.
	left := ESMFile{ESM: "1.0.0", Metadata: Metadata{Name: "l"},
		Models: map[string]Model{"M": {Variables: map[string]ModelVariable{"a": {Type: VarTypeUnknown}}}}}
	right := ESMFile{ESM: "1.0.0", Metadata: Metadata{Name: "r"},
		Models: map[string]Model{"M": {Variables: map[string]ModelVariable{"b": {Type: VarTypeUnknown}}}}}
	if _, ok := Merge(left, right).Models["M"].Variables["b"]; !ok {
		t.Fatal("the right operand did not win the key collision")
	}
}

func TestExtract(t *testing.T) {
	file := loadEditFixture(t)
	before := editJSON(t, file)

	extracted, err := Extract(*file, "EventTestModel")
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if len(extracted.Models) != 1 {
		t.Fatalf("extracted %d models, want 1", len(extracted.Models))
	}
	if _, ok := extracted.Models["EventTestModel"]; !ok {
		t.Fatal("the named model was not extracted")
	}
	if len(extracted.ReactionSystems) != 0 {
		t.Fatalf("extracted %d reaction systems, want 0", len(extracted.ReactionSystems))
	}
	if extracted.ESM != file.ESM {
		t.Fatalf("extracted esm = %q, want %q", extracted.ESM, file.ESM)
	}
	// Both fixture coupling entries name EventTestModel (one by systems, one by
	// a scoped `from` endpoint), so both come along.
	if len(extracted.Coupling) != 2 {
		t.Fatalf("carried %d coupling entries, want 2: %#v", len(extracted.Coupling), extracted.Coupling)
	}

	rs, err := Extract(*file, "EventTestChem")
	if err != nil {
		t.Fatalf("Extract reaction system: %v", err)
	}
	if len(rs.ReactionSystems) != 1 || len(rs.Models) != 0 {
		t.Fatalf("extracted %d systems / %d models", len(rs.ReactionSystems), len(rs.Models))
	}

	if _, err := Extract(*file, "no_such_component"); err == nil {
		t.Fatal("Extract accepted an unknown component")
	} else {
		e := asEntityNotFound(t, err)
		if e.EntityType != "Component" {
			t.Fatalf("EntityType = %q, want Component", e.EntityType)
		}
	}

	if editJSON(t, file) != before {
		t.Fatal("Extract mutated its input")
	}
}

func TestExtractDoesNotOfferDataSources(t *testing.T) {
	// From esm 1.0.0 a data source is not a COMPONENT: it declares no variables
	// and cannot be a coupling endpoint or a subsystem, so there is no standalone
	// document to extract it into. TypeScript refuses; Julia still offers it.
	file, err := LoadPath(filepath.Join(repoTestsDir(t), "valid", "data_sources_only.esm"))
	if err != nil {
		t.Fatalf("load data_sources_only: %v", err)
	}
	if len(file.DataSources) == 0 {
		t.Fatal("fixture declares no data sources")
	}
	for name := range file.DataSources {
		if _, err := Extract(*file, name); err == nil {
			t.Fatalf("Extract offered data source %q as a component", name)
		} else {
			asEntityNotFound(t, err)
		}
	}
}

// =============================================================================
// Corpus-wide invariants
// =============================================================================

// TestEditOpsRoundTripOverValidCorpus asserts, over EVERY model of EVERY
// schema-valid fixture, the two properties that carry the immutability and
// lockstep contracts:
//
//  1. AddVariable followed by RemoveVariable is the identity;
//  2. renaming a variable away and back is the identity over the WHOLE file,
//     and after the rename out, no expression site in the renamed model still
//     names the old variable — the invariant that keeps RemoveVariable's scan
//     and the rename's rewrite from disagreeing.
//
// The rename is driven through RenameVariableInFile: property 2 is about
// leaving no dangling reference, and some fixtures reach a variable by its
// fully-qualified path ("EarthSystem.global_forcing"), which only the
// scope-aware entry point can resolve. The model-scoped RenameVariable's
// narrower guarantee is pinned separately by
// TestRenameVariableScopeAwareVsModelScoped.
func TestEditOpsRoundTripOverValidCorpus(t *testing.T) {
	validDir := filepath.Join(repoTestsDir(t), "valid")
	var fixtures []string
	err := filepath.Walk(validDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(path, ".esm") {
			fixtures = append(fixtures, path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk tests/valid: %v", err)
	}

	for _, path := range fixtures {
		path := path
		rel, _ := filepath.Rel(validDir, path)
		t.Run(filepath.ToSlash(rel), func(t *testing.T) {
			file, err := LoadPath(path)
			if err != nil {
				// Loading is not what is under test here; a fixture this
				// binding cannot load has nothing to say about editing.
				t.Skipf("not loadable: %v", err)
			}
			fileBefore := editJSON(t, file)

			modelNames := make([]string, 0, len(file.Models))
			for name := range file.Models {
				modelNames = append(modelNames, name)
			}
			sort.Strings(modelNames)

			for _, modelName := range modelNames {
				model := file.Models[modelName]
				modelBefore := editJSON(t, model)

				added := AddVariable(model, "__edit_scratch__", ModelVariable{Type: VarTypeParameter})
				removed, err := RemoveVariable(added, "__edit_scratch__")
				if err != nil {
					t.Fatalf("model %s: RemoveVariable of a fresh variable: %v", modelName, err)
				}
				if got := editJSON(t, removed); got != modelBefore {
					t.Fatalf("model %s: add/remove is not the identity", modelName)
				}

				varNames := make([]string, 0, len(model.Variables))
				for v := range model.Variables {
					varNames = append(varNames, v)
				}
				sort.Strings(varNames)
				for _, v := range varNames {
					tmp := v + "__edit_tmp__"
					there, err := RenameVariableInFile(*file, modelName, v, tmp)
					if err != nil {
						t.Fatalf("model %s: rename %s out: %v", modelName, v, err)
					}
					for _, site := range modelExpressionSites(there.Models[modelName], "") {
						if referencesVariable(site.Expr, v) {
							t.Fatalf("model %s: rename of %s left a reference at %s",
								modelName, v, site.Site)
						}
					}
					back, err := RenameVariableInFile(there, modelName, tmp, v)
					if err != nil {
						t.Fatalf("model %s: rename %s back: %v", modelName, v, err)
					}
					if got := editJSON(t, &back); got != fileBefore {
						t.Fatalf("model %s: rename round trip of %s is not the identity:\n want: %s\n  got: %s",
							modelName, v, fileBefore, got)
					}
				}
				if got := editJSON(t, model); got != modelBefore {
					t.Fatalf("model %s: an edit mutated the loaded model", modelName)
				}
			}
			if got := editJSON(t, file); got != fileBefore {
				t.Fatal("an edit mutated the loaded file")
			}
		})
	}
}

// TestRenameVariableScopeAwareVsModelScoped pins the documented difference
// between the two rename entry points on a fixture that reads a variable
// through its fully-qualified path.
//
// scoped_refs_nested's EarthSystem model reads its own `global_forcing` as
// "EarthSystem.global_forcing". Resolving that needs the document and the
// model's name, so the model-scoped RenameVariable — like TypeScript's, which
// calls substituteInModel without its esmFile context — leaves it alone, while
// RenameVariableInFile rewrites it. RemoveVariable's guard counts the scoped
// read as a use either way, which is the safe direction.
func TestRenameVariableScopeAwareVsModelScoped(t *testing.T) {
	file, err := LoadPath(filepath.Join(repoTestsDir(t), "valid", "scoped_refs_nested.esm"))
	if err != nil {
		t.Fatalf("load scoped_refs_nested: %v", err)
	}
	const modelName, varName = "EarthSystem", "global_forcing"
	model := file.Models[modelName]

	// The scoped read exists, and the removal guard sees it.
	if _, err := RemoveVariable(model, varName); err == nil {
		t.Fatal("RemoveVariable ignored a scoped read of the variable")
	} else {
		asVariableInUse(t, err)
	}

	// Model-scoped: the bare reads are rewritten, the scoped one is not.
	modelScoped, err := RenameVariable(model, varName, "renamed_forcing")
	if err != nil {
		t.Fatalf("RenameVariable: %v", err)
	}
	scopedLeftovers := 0
	for _, site := range modelExpressionSites(modelScoped, "") {
		if referencesVariable(site.Expr, varName) {
			scopedLeftovers++
		}
	}
	if scopedLeftovers == 0 {
		t.Fatal("the model-scoped rename resolved a scoped reference; " +
			"if that is now supported, this test and RenameVariable's doc need updating")
	}

	// Scope-aware: nothing is left behind.
	fileScoped, err := RenameVariableInFile(*file, modelName, varName, "renamed_forcing")
	if err != nil {
		t.Fatalf("RenameVariableInFile: %v", err)
	}
	for _, site := range modelExpressionSites(fileScoped.Models[modelName], "") {
		if referencesVariable(site.Expr, varName) {
			t.Fatalf("RenameVariableInFile left a reference at %s", site.Site)
		}
	}
	if _, ok := fileScoped.Models[modelName].Variables["renamed_forcing"]; !ok {
		t.Fatal("the declaration was not renamed")
	}
	if _, err := RenameVariableInFile(*file, "no_such_model", varName, "x"); err == nil {
		t.Fatal("RenameVariableInFile accepted an unknown model")
	} else {
		asEntityNotFound(t, err)
	}
}

// TestRenameVariableInFileRewritesCouplingEndpoints pins the other thing the
// scope-aware rename does that no model-scoped rewrite can: a coupling
// endpoint is a plain string in the FILE, not an expression inside the model.
func TestRenameVariableInFileRewritesCouplingEndpoints(t *testing.T) {
	file := loadEditFixture(t)
	const modelName, varName = "EventTestModel", "x"

	out, err := RenameVariableInFile(*file, modelName, varName, "x_renamed")
	if err != nil {
		t.Fatalf("RenameVariableInFile: %v", err)
	}

	found := false
	for _, entry := range out.Coupling {
		vm, ok := entry.(VariableMapCoupling)
		if !ok {
			continue
		}
		if vm.From == "EventTestModel.x" {
			t.Fatal("a variable_map endpoint still names the old variable")
		}
		if vm.From == "EventTestModel.x_renamed" {
			found = true
		}
	}
	if !found {
		t.Fatalf("the variable_map endpoint was not rewritten: %#v", out.Coupling)
	}
	for _, entry := range file.Coupling {
		if vm, ok := entry.(VariableMapCoupling); ok && vm.From != "EventTestModel.x" {
			t.Fatal("RenameVariableInFile mutated the input's coupling entries")
		}
	}
}
