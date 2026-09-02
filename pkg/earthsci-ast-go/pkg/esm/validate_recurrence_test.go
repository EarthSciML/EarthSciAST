package esm

import (
	"path/filepath"
	"sort"
	"testing"
)

// validate_recurrence_test.go pins esm-spec §4.3.1.1 in Go: the SHAPES of causal
// self-reference this binding admits, the ones it rejects, and the exact
// (code, path) pair each rejection carries. CONFORMANCE_SPEC §5.19.5 makes both
// halves a duty — admitting a legal recurrence is the same category of
// obligation as rejecting an illegal one — so the accepted cases are asserted to
// ZERO errors rather than merely "not crashing", and the rejected ones to one
// specific code at one specific pointer rather than to a count.

// --- fixtures ---------------------------------------------------------------

// recurrenceTestFile wraps a single-model document over an `interval` index set
// named "steps" of the given size, holding one array-shaped unknown `s` defined
// by the one equation `s ~ rhs`. The unknown/equation count balances, so nothing
// but the recurrence rule has anything to say about the document.
func recurrenceTestFile(size int, rhs Expression) *ESMFile {
	return recurrenceTestFileWithSets(
		map[string]IndexSet{"steps": {Kind: "interval", Size: &size}},
		map[string]ModelVariable{
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
		},
		[]Equation{{LHS: "s", RHS: rhs}},
	)
}

// intPtr materializes the *int an IndexSet's `size` holds.
func intPtr(n int) *int { return &n }

func recurrenceTestFileWithSets(sets map[string]IndexSet, vars map[string]ModelVariable, eqs []Equation) *ESMFile {
	return &ESMFile{
		ESM:       "1.0.0",
		Metadata:  Metadata{Name: "Recurrence"},
		IndexSets: sets,
		Models: map[string]Model{
			"M": {Variables: vars, Equations: eqs},
		},
	}
}

// stepsAggregate is the canonical recurrence spelling of esm-spec §4.3.1.1: an
// `aggregate` over one output axis `k` drawn from "steps", whose body is `expr`.
func stepsAggregate(expr Expression) ExprNode {
	return ExprNode{
		Op:        opAggregate,
		Args:      []any{},
		OutputIdx: []any{"k"},
		Ranges:    map[string]any{"k": map[string]any{"from": "steps"}},
		Expr:      expr,
	}
}

// selfRead is `index("s", args...)` — a read of the array being defined.
func selfRead(args ...any) ExprNode {
	return ExprNode{Op: opIndex, Args: append([]any{"s"}, args...)}
}

// guarded wraps a self-read in the base-case guard every recurrence body needs
// (esm-spec §4.3.1.1 point 5: the base case is a guard IN the body, never a fall
// off the end of the axis), so the malformed-index cases under test differ from
// the legal spelling in exactly the index argument.
func guarded(body Expression) ExprNode {
	return ExprNode{Op: "ifelse", Args: []any{
		ExprNode{Op: "<=", Args: []any{"k", int64(1)}},
		1.0,
		body,
	}}
}

// recurrenceFindings runs ONLY the recurrence check over a document's single
// model, so an assertion names the code this rule emitted and cannot be
// satisfied by some other validator's finding.
func recurrenceFindings(t *testing.T, file *ESMFile) []StructuralError {
	t.Helper()
	model := file.Models["M"]
	s := &structuralScan{file: file}
	s.validateRecurrences(&model, "/models/M")
	return s.errors
}

// wantOneRecurrenceError asserts exactly one finding, with the given code, at
// the given pointer.
func wantOneRecurrenceError(t *testing.T, got []StructuralError, wantCode, wantPath string) {
	t.Helper()
	if len(got) != 1 {
		t.Fatalf("got %d findings, want exactly 1 (%s at %s): %+v", len(got), wantCode, wantPath, got)
	}
	if got[0].Code != wantCode {
		t.Errorf("Code = %q, want %q (message: %s)", got[0].Code, wantCode, got[0].Message)
	}
	if got[0].Path != wantPath {
		t.Errorf("Path = %q, want %q", got[0].Path, wantPath)
	}
}

// --- the accepted shapes ----------------------------------------------------

// TestRecurrenceValidFixtureValidatesClean is the regression test for the
// trivial-DAE blocker: before the self-edge drop, an equation whose RHS mentioned
// its own LHS was reported as a non-trivial DAE, which rejected this LEGAL
// document. It asserts ZERO structural errors, not "no recurrence error" —
// CONFORMANCE_SPEC §5.19.5's rejection parity cuts both ways.
func TestRecurrenceValidFixtureValidatesClean(t *testing.T) {
	path := filepath.Join(repoTestsDir(t), "valid", "recurrence_causal_self_reference.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	res := ValidateStructuralWithCodes(file)
	for _, e := range res.StructuralErrors {
		t.Errorf("a VALID recurrence fixture was rejected: [%s] %s at %s", e.Code, e.Message, e.Path)
	}
	if !res.Valid {
		t.Errorf("Valid = false, want true")
	}
}

// TestRecurrenceConformanceFixturesValidateClean sweeps the §5.19 execution
// fixtures. Go executes none of them — but §5.19.5 says the non-executing
// bindings carry the same duty not to REJECT them, so each must validate with
// zero errors.
//
// The roster is READ FROM THE DIRECTORY rather than listed here: a hardcoded
// list silently stops covering the corpus the moment a fixture is added, which
// is the audit's F5 finding. recurrenceFixtureFloor makes an EMPTIED or
// unreachable directory fail loudly instead of vacuously passing.
const recurrenceFixtureFloor = 8 // 8 at time of writing (01..08)

func TestRecurrenceConformanceFixturesValidateClean(t *testing.T) {
	dir := filepath.Join(repoTestsDir(t), "fixtures", "recurrence")
	paths, err := filepath.Glob(filepath.Join(dir, "*.esm"))
	if err != nil {
		t.Fatalf("glob %s: %v", dir, err)
	}
	if len(paths) < recurrenceFixtureFloor {
		t.Fatalf("swept only %d recurrence fixtures, want >= %d: the sweep is not reaching %s",
			len(paths), recurrenceFixtureFloor, dir)
	}
	sort.Strings(paths)
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			file, err := LoadPath(path)
			if err != nil {
				t.Fatalf("load %s: %v", path, err)
			}
			res := ValidateStructuralWithCodes(file)
			for _, e := range res.StructuralErrors {
				t.Errorf("rejected: [%s] %s at %s", e.Code, e.Message, e.Path)
			}
			if !res.Valid {
				t.Errorf("Valid = false, want true")
			}
		})
	}
}

// TestRecurrenceAdmittedShapes pins the shapes that MUST pass, each for a stated
// reason — the accepted side of the rule is as much a contract as the rejected
// side, and three of these rows are cases an over-eager check would break.
func TestRecurrenceAdmittedShapes(t *testing.T) {
	cases := []struct {
		name string
		file *ESMFile
	}{
		{
			// The canonical spelling: s[k] = 2 * s[k-1].
			name: "unit lag on the one output axis",
			file: recurrenceTestFile(4, stepsAggregate(guarded(
				ExprNode{Op: "*", Args: []any{selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}}), 2.0}},
			))),
		},
		{
			// A lag > 1 and two self-reads on the SAME axis both stay legal.
			name: "two self-reads at different literal lags on one axis",
			file: recurrenceTestFile(9, stepsAggregate(guarded(
				ExprNode{Op: "+", Args: []any{
					selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}}),
					selfRead(ExprNode{Op: "-", Args: []any{"k", int64(2)}}),
				}},
			))),
		},
		{
			// The STRADDLING row of esm-spec §4.3.1.1: `a` runs from 0, so lag = a
			// is not provably >= 1 and the check cannot prove causality. It is
			// admitted anyway — the runtime is fail-closed, and requiring the proof
			// would force a bounded-lag fold's terms to be written out one per lag.
			name: "symbol-valued lag straddling zero is admitted, not rejected",
			file: recurrenceTestFile(6, ExprNode{
				Op:        opAggregate,
				Args:      []any{},
				OutputIdx: []any{"k"},
				Ranges: map[string]any{
					"k": map[string]any{"from": "steps"},
					"a": []any{int64(0), int64(3)},
				},
				Reduce: strPtr("+"),
				Filter: ExprNode{Op: "<=", Args: []any{"a", ExprNode{Op: "-", Args: []any{"k", int64(1)}}}},
				Expr: ExprNode{Op: "ifelse", Args: []any{
					ExprNode{Op: "==", Args: []any{"a", int64(0)}},
					1.0,
					selfRead(ExprNode{Op: "-", Args: []any{"k", "a"}}),
				}},
			}),
		},
		{
			// A DERIVATIVE LHS is never a recurrence: `D(s) ~ … index(s, i-1) …` is
			// a finite-difference stencil, a gather on the SOLVER'S state under the
			// §4.3.3 ghost-cell regime, not a self-reference. Treating it as one
			// would reject every discretized document in the corpus.
			name: "a stencil read under a derivative LHS is not a self-reference",
			file: recurrenceTestFileWithSets(
				map[string]IndexSet{"steps": {Kind: "interval", Size: intPtr(4)}},
				map[string]ModelVariable{
					"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
				},
				[]Equation{{
					LHS: ExprNode{Op: OpDerivative, Args: []any{"s"}, Wrt: strPtr("t")},
					RHS: ExprNode{Op: opAggregate, Args: []any{}, OutputIdx: []any{"k"},
						Ranges: map[string]any{"k": map[string]any{"from": "steps"}},
						// Same cell AND a forward read: both would be rejected on an
						// algebraic LHS, and neither is a defect here.
						Expr: ExprNode{Op: "-", Args: []any{
							selfRead(ExprNode{Op: "+", Args: []any{"k", int64(1)}}),
							selfRead("k"),
						}},
					},
				}},
			),
		},
		{
			// A SCALAR self-mention is an ordinary cycle, diagnosed by the ordinary
			// cycle/DAE machinery; this rule says nothing about it, so it must not
			// steal the diagnostic with a recurrence code.
			name: "a scalar self-mention is not this rule's business",
			file: recurrenceTestFileWithSets(
				map[string]IndexSet{"steps": {Kind: "interval", Size: intPtr(4)}},
				map[string]ModelVariable{
					"y": {Type: VarTypeUnknown, Units: strPtr("1")},
					"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
				},
				[]Equation{
					{LHS: "y", RHS: ExprNode{Op: "+", Args: []any{"y", 1.0}}},
					{LHS: "s", RHS: stepsAggregate(1.0)},
				},
			),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := recurrenceFindings(t, tc.file); len(got) != 0 {
				for _, e := range got {
					t.Errorf("admitted shape was rejected: [%s] %s at %s", e.Code, e.Message, e.Path)
				}
			}
		})
	}
}

// TestRecurrenceIgnoresApplyExpressionTemplate pins a deliberate EXCLUSION from
// the cell-restriction blocking list. `apply_expression_template`'s operands ride
// the `bindings` field, which this walk does not visit — and must not start
// visiting unilaterally, since five bindings mirror the field set and §5.19.5
// requires exact agreement — so blocking the op was a rule that barely reached
// what it named. It is unreachable anyway: a template application surviving into
// an evaluation position is already `unlowered_operator` (esm-spec §9.6.4). The
// list therefore names only ops that legitimately reach evaluation and consume an
// operand whole, and a self-read in an `args` slot here is judged on its own lag.
func TestRecurrenceIgnoresApplyExpressionTemplate(t *testing.T) {
	file := recurrenceTestFile(4, stepsAggregate(guarded(ExprNode{
		Op:   applyExpressionTemplateOp,
		Args: []any{selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}})},
	})))
	for _, e := range recurrenceFindings(t, file) {
		t.Errorf("apply_expression_template should not block cell restriction: [%s] %s at %s",
			e.Code, e.Message, e.Path)
	}
}

// --- the rejected shapes ----------------------------------------------------

// TestRecurrenceRejectedShapes pins one code and one pointer per malformed
// shape. The pointer is always the CONTAINING RHS FIELD, which is the granularity
// esm-spec §4.3.1.1 *Rejections* names.
func TestRecurrenceRejectedShapes(t *testing.T) {
	const rhsPath = "/models/M/equations/0/rhs"
	cases := []struct {
		name     string
		rhs      Expression
		wantCode string
	}{
		{
			// `hi(lag) <= 0`: provably a LATER cell, which no sweep order satisfies.
			name:     "forward read index(s, k+1)",
			rhs:      stepsAggregate(guarded(selfRead(ExprNode{Op: "+", Args: []any{"k", int64(1)}}))),
			wantCode: codeRecurrenceNotWellfounded,
		},
		{
			// `lag == [0, 0]` on every axis: the definition is of `s` in terms of the
			// very cell being written.
			name:     "same-cell read index(s, k)",
			rhs:      stepsAggregate(guarded(selfRead("k"))),
			wantCode: codeRecurrenceNotWellfounded,
		},
		{
			// A bare `s` names the WHOLE array, which does not exist while the sweep
			// is building it — regardless of the legal `index` read beside it.
			name: "bare read of s alongside a legal index read",
			rhs: stepsAggregate(guarded(ExprNode{Op: "+", Args: []any{
				selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}}),
				"s",
			}})),
			wantCode: codeRecurrenceNotWellfounded,
		},
		{
			// Coefficient 2, not 1: the read names no position RELATIVE to the cell
			// being written, so neither the axis nor the direction is decidable.
			name:     "non-affine index index(s, 2*k)",
			rhs:      stepsAggregate(guarded(selfRead(ExprNode{Op: "*", Args: []any{int64(2), "k"}}))),
			wantCode: codeRecurrenceNotWellfounded,
		},
		{
			// A bare constant carries the frame symbol with coefficient 0.
			name:     "constant index index(s, 1)",
			rhs:      stepsAggregate(guarded(selfRead(int64(1)))),
			wantCode: codeRecurrenceNotWellfounded,
		},
		{
			// The REACHABILITY rule: a `makearray` region value is evaluated once for
			// the whole region, so the read cannot be sequenced at all. §4.3.2's
			// "later entries overwrite earlier ones" fixes which write WINS, not the
			// order cells are EVALUATED in — hence `unsupported_form`, not
			// `not_wellfounded`: the read itself is perfectly causal.
			name: "self-read inside a makearray region value",
			rhs: stepsAggregate(ExprNode{
				Op:      OpMakearray,
				Args:    []any{},
				Regions: [][][]any{{{int64(1), int64(4)}}},
				Values:  []any{selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}})},
			}),
			wantCode: codeRecurrenceUnsupportedForm,
		},
		{
			// Same rule through a shape op: `reshape` needs its operand whole.
			name: "self-read through a reshape operand",
			rhs: stepsAggregate(guarded(ExprNode{
				Op:    "reshape",
				Args:  []any{selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}})},
				Shape: []any{int64(4)},
			})),
			wantCode: codeRecurrenceUnsupportedForm,
		},
		{
			// No `aggregate` on either side, so there is no cell frame to sweep and
			// no axis to read the lag against.
			name:     "self-read with no cell frame at all",
			rhs:      ExprNode{Op: "*", Args: []any{selfRead(int64(1)), 2.0}},
			wantCode: codeRecurrenceUnsupportedForm,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			wantOneRecurrenceError(t, recurrenceFindings(t, recurrenceTestFile(4, tc.rhs)),
				tc.wantCode, rhsPath)
		})
	}
}

// TestRecurrenceAdmitsUnprovableLag pins the OPTIONAL half of the split proof
// obligation (esm-spec §4.3.1.1 "Admitted lag", fifth table row). A lag this
// checker cannot bound — because it is built from a parameter, or from a symbol
// whose range resolves only against the `index_sets` registry — is admitted, on
// the same footing as a straddling one. The coefficient is still proved: the
// axis is decided, only the lag's SIGN is not.
//
// This is the case a validator must NOT reject. A validator sees `ranges` before
// they are resolved and so proves strictly less than the evaluator; refusing an
// unproven lag would reject documents the evaluator accepts, which is the one
// validator/evaluator divergence that is never defensible.
// tests/fixtures/recurrence/08_recurrence_parameter_valued_lag.esm is the
// cross-binding pin; these rows isolate the decision.
func TestRecurrenceAdmitsUnprovableLag(t *testing.T) {
	// `n` is a PARAMETER, so nothing static bounds `k - n`.
	parameterLag := recurrenceTestFileWithSets(
		map[string]IndexSet{"steps": {Kind: "interval", Size: intPtr(5)}},
		map[string]ModelVariable{
			"n": {Type: VarTypeParameter, Units: strPtr("1"), Default: int64(2)},
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
		},
		[]Equation{{LHS: "s", RHS: stepsAggregate(guarded(
			ExprNode{Op: "*", Args: []any{
				selfRead(ExprNode{Op: "-", Args: []any{"k", "n"}}),
				3.0,
			}},
		))}},
	)

	// A CATEGORICAL contraction. This one the validator now PROVES — a categorical
	// set bounds its symbol 1..len(members), exactly as the evaluator resolves it,
	// so `lag = c` lands in [1, 2] — but the point is the same: it must not be
	// refused for being unfamiliar.
	categoricalLag := recurrenceTestFileWithSets(
		map[string]IndexSet{
			"steps": {Kind: "interval", Size: intPtr(4)},
			"tags":  {Kind: "categorical", Members: []any{"a", "b"}},
		},
		map[string]ModelVariable{
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
		},
		[]Equation{{LHS: "s", RHS: ExprNode{
			Op:        opAggregate,
			Args:      []any{},
			OutputIdx: []any{"k"},
			Ranges: map[string]any{
				"k": map[string]any{"from": "steps"},
				"c": map[string]any{"from": "tags"},
			},
			Reduce: strPtr("+"),
			Expr:   selfRead(ExprNode{Op: "-", Args: []any{"k", "c"}}),
		}}},
	)

	for name, file := range map[string]*ESMFile{
		"parameter-valued lag":   parameterLag,
		"categorical-valued lag": categoricalLag,
	} {
		t.Run(name, func(t *testing.T) {
			for _, e := range recurrenceFindings(t, file) {
				t.Errorf("an unprovable lag was rejected: [%s] %s at %s", e.Code, e.Message, e.Path)
			}
		})
	}
}

// TestRecurrenceRejectsUnprovableLagOnTwoAxes guards the boundary of the rule
// above. Admitting an unprovable lag identifies the axis as the recurrence axis;
// it does not stop counting axes. Two unbounded offsets are still an offset on
// more than one axis, and a recurrence folds along exactly ONE — so this is the
// one place an unprovable lag still produces a rejection.
func TestRecurrenceRejectsUnprovableLagOnTwoAxes(t *testing.T) {
	file := recurrenceTestFileWithSets(
		map[string]IndexSet{
			"rows": {Kind: "interval", Size: intPtr(3)},
			"cols": {Kind: "interval", Size: intPtr(4)},
		},
		map[string]ModelVariable{
			"n": {Type: VarTypeParameter, Units: strPtr("1"), Default: int64(1)},
			"m": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("rows", "cols")},
		},
		[]Equation{{LHS: "m", RHS: ExprNode{
			Op:        opAggregate,
			Args:      []any{},
			OutputIdx: []any{"i", "j"},
			Ranges: map[string]any{
				"i": map[string]any{"from": "rows"},
				"j": map[string]any{"from": "cols"},
			},
			Expr: ExprNode{Op: opIndex, Args: []any{"m",
				ExprNode{Op: "-", Args: []any{"i", "n"}},
				ExprNode{Op: "-", Args: []any{"j", "n"}},
			}},
		}}},
	)
	wantOneRecurrenceError(t, recurrenceFindings(t, file),
		codeRecurrenceNotWellfounded, "/models/M/equations/0/rhs")
}

// TestRecurrenceRejectsOffsetOnTwoAxes covers the two-axis rules, which need a
// two-axis frame: an offset on more than one axis, and two self-reads that
// disagree about which axis the definition folds along. Both are
// `recurrence_not_wellfounded` — a recurrence folds along exactly ONE axis.
func TestRecurrenceRejectsOffsetOnTwoAxes(t *testing.T) {
	twoAxisFile := func(expr Expression) *ESMFile {
		return recurrenceTestFileWithSets(
			map[string]IndexSet{
				"rows": {Kind: "interval", Size: intPtr(3)},
				"cols": {Kind: "interval", Size: intPtr(4)},
			},
			map[string]ModelVariable{
				"m": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("rows", "cols")},
			},
			[]Equation{{LHS: "m", RHS: ExprNode{
				Op:        opAggregate,
				Args:      []any{},
				OutputIdx: []any{"i", "j"},
				Ranges: map[string]any{
					"i": map[string]any{"from": "rows"},
					"j": map[string]any{"from": "cols"},
				},
				Expr: expr,
			}}},
		)
	}
	read := func(args ...any) ExprNode {
		return ExprNode{Op: opIndex, Args: append([]any{"m"}, args...)}
	}
	minus1 := func(sym string) ExprNode {
		return ExprNode{Op: "-", Args: []any{sym, int64(1)}}
	}

	cases := []struct {
		name string
		expr Expression
	}{
		{
			name: "one read offset on both axes",
			expr: read(minus1("i"), minus1("j")),
		},
		{
			name: "two reads folding along different axes",
			expr: ExprNode{Op: "+", Args: []any{
				read("i", minus1("j")),
				read(minus1("i"), "j"),
			}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			wantOneRecurrenceError(t, recurrenceFindings(t, twoAxisFile(tc.expr)),
				codeRecurrenceNotWellfounded, "/models/M/equations/0/rhs")
		})
	}
}

// TestRecurrenceRejectionIsWiredIntoValidate proves the check is reached by the
// PUBLIC validation entry point and not merely callable in isolation, and that a
// finding carries the axis it concerns in `details.recurrence_axis`.
func TestRecurrenceRejectionIsWiredIntoValidate(t *testing.T) {
	file := recurrenceTestFile(4, stepsAggregate(guarded(
		selfRead(ExprNode{Op: "+", Args: []any{"k", int64(1)}}),
	)))
	res := ValidateStructuralWithCodes(file)
	if res.Valid {
		t.Errorf("Valid = true, want false for a forward self-read")
	}
	var found *StructuralError
	for i, e := range res.StructuralErrors {
		if e.Code == codeRecurrenceNotWellfounded {
			found = &res.StructuralErrors[i]
		}
	}
	if found == nil {
		t.Fatalf("validate() emitted no %s: %+v", codeRecurrenceNotWellfounded, res.StructuralErrors)
	}
	if found.Path != "/models/M/equations/0/rhs" {
		t.Errorf("Path = %q, want /models/M/equations/0/rhs", found.Path)
	}
	if got := found.Details["variable"]; got != "s" {
		t.Errorf("details.variable = %v, want \"s\"", got)
	}
	if got := found.Details["recurrence_axis"]; got != "k" {
		t.Errorf("details.recurrence_axis = %v, want \"k\"", got)
	}
}

// --- the DAE self-edge drop -------------------------------------------------

// odeStateDrivenBy returns `D(x, t) ~ index(<array>, 1)`, an ODE equation that
// makes the enclosing model an ODE-kind system (§6.3.1) so ApplyDAEContract
// actually runs over it. Without a differential equation the model derives as
// `nonlinear` and the DAE contract skips it entirely — which is why the blocker
// this guards was invisible in the array-only fixtures.
func odeStateDrivenBy(array string) Equation {
	return Equation{
		LHS: ExprNode{Op: OpDerivative, Args: []any{"x"}, Wrt: strPtr("t")},
		RHS: ExprNode{Op: opIndex, Args: []any{array, int64(1)}},
	}
}

// TestDAEContractAdmitsWellFoundedRecurrence is the direct regression test for
// the blocker: the self-edge `V -> V` of a well-founded causal self-read is
// dropped, so a recurrence alongside an ODE state is an ODE and not a
// non-trivial DAE. It also asserts the equation SURVIVES — the recurrence is
// admitted, never substituted away, because its RHS names `s` on purpose.
func TestDAEContractAdmitsWellFoundedRecurrence(t *testing.T) {
	file := recurrenceTestFileWithSets(
		map[string]IndexSet{"steps": {Kind: "interval", Size: intPtr(4)}},
		map[string]ModelVariable{
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
			"x": {Type: VarTypeUnknown, Units: strPtr("1"), Default: 0.0},
		},
		[]Equation{
			{LHS: "s", RHS: stepsAggregate(guarded(
				ExprNode{Op: "*", Args: []any{selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}}), 2.0}},
			))},
			odeStateDrivenBy("s"),
		},
	)

	info, err := ApplyDAEContract(file)
	if err != nil {
		t.Fatalf("a well-founded recurrence was rejected by the DAE contract: %v", err)
	}
	if info.SystemClass != SystemKindODE {
		t.Errorf("SystemClass = %q, want %q", info.SystemClass, SystemKindODE)
	}
	if info.AlgebraicEquationCount != 0 {
		t.Errorf("AlgebraicEquationCount = %d, want 0", info.AlgebraicEquationCount)
	}
	if info.TrivialFactoredCount != 0 {
		t.Errorf("TrivialFactoredCount = %d, want 0: a recurrence must not be substituted away",
			info.TrivialFactoredCount)
	}
	eqs := file.Models["M"].Equations
	if len(eqs) != 2 {
		t.Fatalf("got %d equations after factoring, want 2 (the recurrence must survive)", len(eqs))
	}
	if !Contains(eqs[0].RHS, "s") {
		t.Errorf("the recurrence's self-read was lost: %v", eqs[0].RHS)
	}
}

// TestDAEContractStillRejectsSelfMentionThatIsNoRecurrence guards the other half
// of the fix: the drop is gated on WELL-FOUNDEDNESS, so an array-shaped
// self-mention that is not a causal self-read keeps its E_NONTRIVIAL_DAE. A bare
// `s ~ s + 1` reads the whole array, which is a cycle and not an ordering.
func TestDAEContractStillRejectsSelfMentionThatIsNoRecurrence(t *testing.T) {
	file := recurrenceTestFileWithSets(
		map[string]IndexSet{"steps": {Kind: "interval", Size: intPtr(4)}},
		map[string]ModelVariable{
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
			"x": {Type: VarTypeUnknown, Units: strPtr("1"), Default: 0.0},
		},
		[]Equation{
			{LHS: "s", RHS: ExprNode{Op: "+", Args: []any{"s", 1.0}}},
			odeStateDrivenBy("s"),
		},
	)

	info, err := ApplyDAEContract(file)
	if err == nil {
		t.Fatalf("expected E_NONTRIVIAL_DAE for a bare array self-mention, got nil")
	}
	re, ok := err.(*RuleEngineError)
	if !ok {
		t.Fatalf("expected *RuleEngineError, got %T: %v", err, err)
	}
	if re.Code != codeNontrivialDAE {
		t.Errorf("Code = %q, want %q", re.Code, codeNontrivialDAE)
	}
	if info.SystemClass != SystemKindDAE {
		t.Errorf("SystemClass = %q, want %q", info.SystemClass, SystemKindDAE)
	}
	if info.AlgebraicEquationCount != 1 {
		t.Errorf("AlgebraicEquationCount = %d, want 1", info.AlgebraicEquationCount)
	}
}

// TestDAEContractStillRejectsMalformedRecurrence is the same guard for a
// self-read that IS an `index` read but is not well founded — a forward read.
// The equation stays a residual, so a document the recurrence validator rejects
// is not quietly promoted to an ODE by the self-edge drop.
func TestDAEContractStillRejectsMalformedRecurrence(t *testing.T) {
	file := recurrenceTestFileWithSets(
		map[string]IndexSet{"steps": {Kind: "interval", Size: intPtr(4)}},
		map[string]ModelVariable{
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
			"x": {Type: VarTypeUnknown, Units: strPtr("1"), Default: 0.0},
		},
		[]Equation{
			{LHS: "s", RHS: stepsAggregate(guarded(
				selfRead(ExprNode{Op: "+", Args: []any{"k", int64(1)}}),
			))},
			odeStateDrivenBy("s"),
		},
	)

	_, err := ApplyDAEContract(file)
	if err == nil {
		t.Fatalf("expected E_NONTRIVIAL_DAE for a forward self-read, got nil")
	}
	re, ok := err.(*RuleEngineError)
	if !ok || re.Code != codeNontrivialDAE {
		t.Fatalf("expected RuleEngineError(%s), got %v", codeNontrivialDAE, err)
	}
}

// --- the cadence self-edge drop ---------------------------------------------

// TestCadenceAdmitsRecurrenceSelfEdge is the second half of the §5.19.5
// "cuts both ways" duty, for Go's OTHER cycle detector.
//
// CadenceClassifier.seedLeaf resolves an observed unknown to the class of its
// defining RHS, transitively, with a cycle guard — and a recurrence's RHS reads
// the very name being resolved, so before the self-edge drop every LEGAL
// recurrence document reported `cadence_observed_cycle`. That is the same defect
// as the trivial-DAE blocker, on a different path: the classifier is public API,
// so a consumer calling LeafSeeds / CheckExpectCadence reached it even though
// validate() does not.
func TestCadenceAdmitsRecurrenceSelfEdge(t *testing.T) {
	for _, rel := range []string{
		filepath.Join("valid", "recurrence_causal_self_reference.esm"),
		filepath.Join("fixtures", "recurrence", "01_recurrence_doubling.esm"),
		filepath.Join("fixtures", "recurrence", "08_recurrence_parameter_valued_lag.esm"),
	} {
		t.Run(filepath.Base(rel), func(t *testing.T) {
			file, err := LoadPath(filepath.Join(repoTestsDir(t), rel))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			for _, name := range sortedKeys(file.Models) {
				model := file.Models[name]
				c := NewCadenceClassifier(file, &model)
				seeds, err := c.LeafSeeds()
				if err != nil {
					t.Fatalf("a LEGAL recurrence was reported as a cadence cycle: %v", err)
				}
				if len(seeds) == 0 {
					t.Errorf("LeafSeeds returned no seeds, so nothing was classified")
				}
			}
		})
	}
}

// TestCadenceStillReportsNonRecurrenceCycles guards the gate from the other
// side. The drop is on CANDIDACY — an array-shaped unknown reading itself
// through `index` — so three neighbouring shapes must still be cycles:
// a two-variable cycle, a bare array self-mention, and a scalar self-mention.
// A gate that dropped any of these would be suppressing real cycle detection,
// which §5.19.5 says is not implementing the section.
func TestCadenceStillReportsNonRecurrenceCycles(t *testing.T) {
	steps := 4
	cases := map[string][]Equation{
		// r -> z -> r. The walk meets `r` while resolving `z`, so the direct-self
		// -edge test does not apply even though `r` IS a recurrence candidate.
		"cycle through two distinct variables": {
			{LHS: "r", RHS: ExprNode{Op: "+", Args: []any{
				stepsAggregate(selfReadOf("r", ExprNode{Op: "-", Args: []any{"k", int64(1)}})),
				"z",
			}}},
			{LHS: "z", RHS: "r"},
		},
		// No `index` read anywhere, so not a candidate.
		"bare array self-mention": {
			{LHS: "r", RHS: ExprNode{Op: "+", Args: []any{"r", 1.0}}},
		},
	}
	for name, eqs := range cases {
		t.Run(name, func(t *testing.T) {
			file := recurrenceTestFileWithSets(
				map[string]IndexSet{"steps": {Kind: "interval", Size: &steps}},
				map[string]ModelVariable{
					"r": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
					"z": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
				},
				eqs,
			)
			model := file.Models["M"]
			c := NewCadenceClassifier(file, &model)
			_, err := c.LeafSeeds()
			if err == nil {
				t.Fatalf("expected %s, got nil: the self-edge drop must not suppress real "+
					"cycle detection", CodeCadenceObservedCycle)
			}
			var ce *CadenceError
			if !errorAsCadence(err, &ce) || ce.Code != CodeCadenceObservedCycle {
				t.Errorf("got %v, want a CadenceError(%s)", err, CodeCadenceObservedCycle)
			}
		})
	}

	// A SCALAR self-mention: no shape, so no axis to fold along and never a
	// candidate however it is spelled.
	t.Run("scalar self-mention", func(t *testing.T) {
		file := recurrenceTestFileWithSets(
			map[string]IndexSet{"steps": {Kind: "interval", Size: &steps}},
			map[string]ModelVariable{
				"y": {Type: VarTypeUnknown, Units: strPtr("1")},
			},
			[]Equation{{LHS: "y", RHS: ExprNode{Op: "+", Args: []any{"y", 1.0}}}},
		)
		model := file.Models["M"]
		c := NewCadenceClassifier(file, &model)
		if _, err := c.LeafSeeds(); err == nil {
			t.Fatalf("expected %s for a scalar self-mention, got nil", CodeCadenceObservedCycle)
		}
	})
}

// selfReadOf is selfRead for an array other than the default `s`.
func selfReadOf(array string, args ...any) ExprNode {
	return ExprNode{Op: opIndex, Args: append([]any{array}, args...)}
}

// errorAsCadence is errors.As specialized to *CadenceError, kept local so this
// file needs no import for one call.
func errorAsCadence(err error, target **CadenceError) bool {
	if ce, ok := err.(*CadenceError); ok {
		*target = ce
		return true
	}
	return false
}

// TestCadenceExemptionIsGatedOnCandidacyNotVerdict is the test that tells the
// two gates apart, and the only one that would catch the flip.
//
// An ILL-FOUNDED candidate — a forward self-read — must still receive the
// self-edge exemption, because candidacy is the gate. Had the exemption been
// gated on the well-foundedness VERDICT it would not apply here (an ill-founded
// read is by definition not well founded), the cycle guard would fire, and the
// document would be diagnosed as a cadence cycle instead of as
// `recurrence_not_wellfounded`. Both halves are asserted together, since the
// point is that the recurrence check OWNS the diagnosis for this equation:
// cadence stays quiet and validate names the real defect.
//
// Every gate-flip regression fails HERE rather than in the shared corpus, which
// on Go's layering would not notice: ApplyDAEContract and CadenceClassifier are
// both off the validate path, so a cycle error from either cannot pre-empt the
// corpus's (code, path) pair.
func TestCadenceExemptionIsGatedOnCandidacyNotVerdict(t *testing.T) {
	steps := 4
	file := recurrenceTestFileWithSets(
		map[string]IndexSet{"steps": {Kind: "interval", Size: &steps}},
		map[string]ModelVariable{
			"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
		},
		[]Equation{{LHS: "s", RHS: stepsAggregate(guarded(
			selfRead(ExprNode{Op: "+", Args: []any{"k", int64(1)}}),
		))}},
	)

	model := file.Models["M"]
	if _, err := NewCadenceClassifier(file, &model).LeafSeeds(); err != nil {
		t.Errorf("an ill-founded CANDIDATE was denied the self-edge exemption: %v\n"+
			"the exemption is gated on candidacy, not on the well-foundedness verdict "+
			"(CONFORMANCE_SPEC §5.19.5)", err)
	}

	res := ValidateStructuralWithCodes(file)
	found := false
	for _, e := range res.StructuralErrors {
		if e.Code == codeRecurrenceNotWellfounded && e.Path == "/models/M/equations/0/rhs" {
			found = true
		}
		if e.Code == CodeCadenceObservedCycle {
			t.Errorf("the recurrence diagnosis was pre-empted by %s", CodeCadenceObservedCycle)
		}
	}
	if !found {
		t.Errorf("no %s at /models/M/equations/0/rhs: %+v",
			codeRecurrenceNotWellfounded, res.StructuralErrors)
	}
}
