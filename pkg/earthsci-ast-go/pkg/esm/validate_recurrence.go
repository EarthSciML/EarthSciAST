package esm

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// validate_recurrence.go implements the STATIC half of esm-spec §4.3.1.1
// "Causal self-reference (recurrence) along one axis" — the half every binding
// owes whether or not it evaluates anything (CONFORMANCE_SPEC §5.19.5
// "Rejection parity"). Go evaluates no array numerics, so this file plus the
// dae.go self-edge drop is the whole of the construct here.
//
// A **recurrence definition** is an equation defining an array-shaped unknown
// `V` whose RHS reads `index(V, …)` — the array being defined, at a strictly
// earlier position along exactly ONE of the defining `faq`'s output axes.
// There is no new op and no new schema field: the recurrence, its axis and its
// lag are all read off the document, which is why the recognition is structural
// and why it belongs in the structural validator rather than in a lowering pass.
//
// Two things are decided here:
//
//   - whether each self-read is WELL FOUNDED — affine in its frame symbol with
//     coefficient 1, offset on exactly one axis, and not provably same-cell or
//     later (`recurrence_not_wellfounded`);
//   - whether the construct CARRYING the read can be sequenced cell by cell at
//     all (`recurrence_unsupported_form`).
//
// The proof obligation SPLITS in two, and the split is normative (esm-spec
// §4.3.1.1 "Admitted lag"):
//
//   - the COEFFICIENT of the frame symbol must be provably 1. Without it the read
//     names no position relative to the cell being written, so which axis the
//     recurrence folds along — and in which direction — is undecidable. That is
//     `recurrence_not_wellfounded`.
//   - the SIGN OF THE LAG need not be provable at all. A lag that straddles zero,
//     or that cannot be bounded even in principle (it involves a parameter, or a
//     symbol whose range this checker cannot resolve), is ADMITTED. Soundness does
//     not rest on it: a self-read resolves only against cells the sweep has already
//     PUBLISHED, so an ill-founded read cannot return a number — it faults
//     (`E_TREEWALK_RECUR_UNAVAILABLE`, esm-spec §4.3.1.1 point 5).
//
// The asymmetry is what keeps this validator and an evaluator from disagreeing. A
// validator sees `ranges` before they are resolved against the `index_sets`
// registry and so proves strictly LESS than the evaluator does; a validator that
// treated "unproven" as "illegal" would reject documents its own evaluator
// accepts, which is the one divergence between the two that is never defensible.
// So this check rejects what is PROVABLY wrong and identifies the axis; it does
// not certify what is right.
//
// Mirrors the reference static validator, Rust `structural.rs`
// `check_recurrence_equation` and its helpers, decision for decision: the two
// must agree on which documents are legal, or a document would validate in one
// binding and not in another — which is exactly what §5.19.5 forbids.

const (
	// codeRecurrenceNotWellfounded: a causal self-read that is not strictly
	// earlier along exactly one axis — provably same-cell or later, an index
	// argument not affine in its frame symbol with coefficient 1, an offset on
	// more than one axis, self-reads disagreeing on the axis, or a bare read of
	// the variable in its own RHS (esm-spec §4.3.1.1 *Rejections*).
	codeRecurrenceNotWellfounded = "recurrence_not_wellfounded"
	// codeRecurrenceUnsupportedForm: the self-read is reachable only through a
	// construct that cannot be restricted to one cell (a `makearray` region
	// value, or a `reshape`/`transpose`/`concat`/`broadcast`/
	// `apply_expression_template` operand), or the equation declares no cell
	// frame to sweep (esm-spec §4.3.1.1 *Rejections*).
	//
	// Both codes are UNEXPORTED, unlike the other structural Code* constants in
	// codes.go, because api-surface.json (pinned by api_surface_test.go) is the
	// cross-language record of the exported surface and is a SHARED file: an
	// exported constant absent from it fails the build. Promoting these two is a
	// manifest edit, not a code edit.
	codeRecurrenceUnsupportedForm = "recurrence_unsupported_form"
	// codeRecurrenceGroupAxisMismatch: the members of a recurrence group
	// (esm-spec §4.3.1.2) do not share one cell frame and one recurrence axis.
	codeRecurrenceGroupAxisMismatch = "recurrence_group_axis_mismatch"
)

// opIndex is the gather op a causal self-read is spelled with.
const opIndex = "index"

// symBounds is the resolved inclusive integer interval of an index symbol. Only
// symbols whose bounds the VALIDATOR can resolve get one; a symbol with no entry
// contributes an UNKNOWN constant part to the affine form, which makes a lag's
// sign unprovable — and an unprovable lag is admitted, not rejected.
type symBounds struct{ lo, hi int64 }

// symBinding is one entry of the index-symbol environment stack. A stack rather
// than a map because `faq` nodes nest and an inner binder SHADOWS an
// outer one of the same name; snapshotting in push order lets the innermost win.
type symBinding struct {
	name   string
	bounds symBounds
}

// recurrenceSelfRead is one `index(V, …)` read of the variable being defined,
// found by the structural walk of the RHS.
type recurrenceSelfRead struct {
	// args are the INDEX arguments — the `index` node's args after the array
	// operand — one per axis of the cell frame.
	args []any
	// env is the index-symbol environment in scope where the read was found,
	// which is what makes a symbol-valued lag's bounds computable.
	env map[string]symBounds
	// unsequenceable records that the read was reached ONLY through a construct
	// that consumes its operand whole, so no cell-by-cell sweep can supply it.
	unsequenceable bool
	// target is the variable read: the one being defined, or (esm-spec §4.3.1.2)
	// a peer in its recurrence group.
	target string
}

// recurrenceFinding is one rejection of a recurrence definition: the code, the
// message, and the axis it concerns (empty when the defect names no single axis).
type recurrenceFinding struct {
	code    string
	message string
	axis    string
}

// validateRecurrences reports every equation of model whose causal
// self-reference is not well founded, at the CONTAINING RHS FIELD
// (`/models/M/equations/i/rhs`) — the pointer convention esm-spec §4.3.1.1
// pins and the rest of this package's expression findings share.
//
// It runs for every model, coupled or not: a self-read is decidable from the one
// equation that carries it, so nothing about it waits on flattening.
func (s *structuralScan) validateRecurrences(model *Model, basePath string) {
	arrayShaped := arrayShapedUnknowns(model)
	if len(arrayShaped) == 0 {
		return
	}
	// esm-spec §4.3.1.2: a recurrence group's members count their peers'
	// `index` reads as causal reads, and their frames are compared once every
	// member has one.
	groups := recurrenceGroups(model, s.file)
	type memberFrame struct {
		eq    int
		name  string
		frame string
	}
	var frames []memberFrame
	defer func() {
		for _, g := range groups {
			var members []memberFrame
			for _, f := range frames {
				if g[f.name] {
					members = append(members, f)
				}
			}
			if len(members) == 0 {
				continue
			}
			// The frame signature is "syms|ranges|axis|sameCell"; compare the
			// first two always and the axis where both members fold along one.
			sig := func(f memberFrame) (string, string, []string) {
				p := strings.SplitN(f.frame, "|", 4)
				var sc []string
				if p[3] != "" {
					sc = strings.Split(p[3], ",")
				}
				return p[0] + "|" + p[1], p[2], sc
			}
			first := members[0]
			for _, m := range members {
				if _, ax, _ := sig(m); ax != "-1" {
					first = m
					break
				}
			}
			fBase, fAxis, _ := sig(first)
			mismatch := false
			for _, m := range members {
				mBase, mAxis, _ := sig(m)
				if mBase == fBase && (mAxis == "-1" || fAxis == "-1" || mAxis == fAxis) {
					continue
				}
				mismatch = true
				s.addErr(StructuralError{
					Path: fmt.Sprintf("%s/equations/%d/rhs", basePath, m.eq),
					Code: codeRecurrenceGroupAxisMismatch,
					Message: fmt.Sprintf("'%s' and '%s' read each other as a recurrence group, but "+
						"'%s' does not sweep the same frame: every member shares one cell frame — "+
						"the same `output_idx`, the same ranges — and one recurrence axis "+
						"(esm-spec §4.3.1.2).", m.name, first.name, m.name),
					Details: map[string]any{"variable": m.name, "group": sortedKeysOfSet(g)},
				})
				break
			}
			if mismatch {
				continue
			}
			// Rule 1: the same-cell reads between members must admit an order.
			graph := map[string][]string{}
			for _, m := range members {
				_, _, sc := sig(m)
				graph[m.name] = sortedKeysOfSet(func() map[string]bool {
					out := map[string]bool{}
					for _, x := range sc {
						out[x] = true
					}
					return out
				}())
			}
			if cycle := firstObservedCycle(graph); len(cycle) > 0 {
				at := members[0]
				for _, m := range members {
					found := false
					for _, c := range cycle {
						if c == m.name {
							found = true
						}
					}
					if found {
						at = m
						break
					}
				}
				s.addErr(StructuralError{
					Path: fmt.Sprintf("%s/equations/%d/rhs", basePath, at.eq),
					Code: codeRecurrenceNotWellfounded,
					Message: fmt.Sprintf("the members of a recurrence group read one another at the "+
						"cell being written in a cycle (%s), so no order within the cell satisfies "+
						"them. Reads between members at the same position must be acyclic "+
						"(esm-spec §4.3.1.2 rule 1).", strings.Join(cycle, " -> ")),
					Details: map[string]any{"variable": at.name, "cycle": cycle},
				})
			}
		}
	}()
	for i, eq := range model.Equations {
		var group map[string]bool
		if name, _, _, ok := recurrenceLHSTarget(eq.LHS); ok {
			for _, g := range groups {
				if g[name] {
					group = g
				}
			}
		}
		_, finding, frame := analyzeRecurrenceEquationIn(eq, s.file, arrayShaped, group)
		if finding == nil {
			if group != nil && frame != "" {
				frames = append(frames, memberFrame{i, recurrenceFindingVariable(eq), frame})
			}
			continue
		}
		var axis any // JSON null when the defect names no single axis
		if finding.axis != "" {
			axis = finding.axis
		}
		s.addErr(StructuralError{
			Path:    fmt.Sprintf("%s/equations/%d/rhs", basePath, i),
			Code:    finding.code,
			Message: finding.message,
			Details: map[string]any{
				"variable":        recurrenceFindingVariable(eq),
				"recurrence_axis": axis,
			},
		})
	}
}

// recurrenceFindingVariable is the name a finding's `details.variable` carries:
// the variable the equation defines. Recomputed here rather than threaded out of
// the analysis so the analysis can stay a pure (equation → finding) function.
func recurrenceFindingVariable(eq Equation) string {
	name, _, _, ok := recurrenceLHSTarget(eq.LHS)
	if !ok {
		return ""
	}
	return name
}

// arrayShapedUnknowns is the set of variables a causal self-reference can
// define: those carrying a non-empty declared `shape`. A scalar cannot be swept
// cell by cell, so a scalar self-mention is an ordinary cycle and is left to the
// ordinary cycle diagnostics.
func arrayShapedUnknowns(model *Model) map[string]bool {
	out := make(map[string]bool)
	for name, variable := range model.Variables {
		if len(variable.Dims()) > 0 {
			out[name] = true
		}
	}
	return out
}

// isWellFoundedRecurrence reports whether eq is a recurrence definition whose
// every causal self-read is well founded — the predicate the DAE contract uses
// to drop the self-edge `V -> V` (see dae.go). An equation that mentions its own
// LHS in any OTHER way (a bare read, a scalar cycle, a malformed self-read)
// reports false, so it keeps whatever diagnostic it had before.
func isWellFoundedRecurrence(eq Equation, file *ESMFile, arrayShaped map[string]bool) bool {
	isRecurrence, finding := analyzeRecurrenceEquation(eq, file, arrayShaped)
	return isRecurrence && finding == nil
}

// isRecurrenceCandidate reports whether eq is a recurrence CANDIDATE: it defines
// an array-shaped unknown and reads that array through `index` somewhere in its
// own RHS — well founded or NOT.
//
// This, and not the well-foundedness verdict, is the gate for every exemption a
// PRE-EXISTING check needs in order to admit the construct (CONFORMANCE_SPEC
// §5.19.5 "The exemption is gated on CANDIDACY, not on well-foundedness").
// Gating on the verdict is the intuitive choice and it is wrong: an ill-founded
// self-read is by definition not well founded, so the exemption would not apply
// to it, so the pre-existing cycle check fires and collapses the document to one
// cycle error — and the `recurrence_not_wellfounded` / `recurrence_unsupported_form`
// diagnosis is never reached. That moves the original masking defect from the
// legal case to the illegal one, giving up the named diagnosis this construct
// exists to provide.
//
// Candidacy asks the right question instead: does the recurrence check OWN the
// diagnosis for this equation? If it does, hand the equation over and let it
// decide. If it does not — a scalar `x ~ x + 1`, or a bare `s ~ s + 1` over an
// array, neither of which has an `index` read — leave every existing check
// exactly as it was.
//
// It shares analyzeRecurrenceEquation with the validator deliberately, so the
// candidacy predicate and the well-foundedness check cannot drift apart.
func isRecurrenceCandidate(eq Equation, file *ESMFile, arrayShaped map[string]bool) bool {
	candidate, _ := analyzeRecurrenceEquation(eq, file, arrayShaped)
	return candidate
}

// recurrenceCandidateVars is the set of variables a model defines by a
// recurrence candidate — the names whose self-edge `V -> V` an existing check
// must drop.
func recurrenceCandidateVars(model *Model, file *ESMFile) map[string]bool {
	if model == nil {
		return nil
	}
	arrayShaped := arrayShapedUnknowns(model)
	if len(arrayShaped) == 0 {
		return nil
	}
	var out map[string]bool
	for _, eq := range model.Equations {
		if !isRecurrenceCandidate(eq, file, arrayShaped) {
			continue
		}
		name, _, _, ok := recurrenceLHSTarget(eq.LHS)
		if !ok {
			continue
		}
		if out == nil {
			out = make(map[string]bool)
		}
		out[name] = true
	}
	return out
}

// analyzeRecurrenceEquation decides whether eq is a recurrence definition and,
// if so, whether it is well founded.
//
// Returns (false, nil) for every equation in every document that does not use
// the construct — including one whose RHS mentions its LHS without a single
// `index(V, …)` read, which is an ordinary self-cycle rather than a recurrence.
func analyzeRecurrenceEquation(eq Equation, file *ESMFile, arrayShaped map[string]bool) (bool, *recurrenceFinding) {
	candidate, finding, _ := analyzeRecurrenceEquationIn(eq, file, arrayShaped, nil)
	return candidate, finding
}

// analyzeRecurrenceEquationIn is analyzeRecurrenceEquation for a member of a
// recurrence GROUP (esm-spec §4.3.1.2): the `index` reads of every name in group
// count as causal reads, and a read of a PEER must be provably strictly earlier.
// The third return is the member's frame signature — output indices, each axis's
// range as the validator resolves it, and the recurrence axis — which every
// member of a group must share; empty when the equation is no well-founded
// recurrence.
func analyzeRecurrenceEquationIn(eq Equation, file *ESMFile, arrayShaped map[string]bool, group map[string]bool) (bool, *recurrenceFinding, string) {
	varName, lhsIdx, lhsIdxPresent, ok := recurrenceLHSTarget(eq.LHS)
	if !ok || !arrayShaped[varName] {
		return false, nil, ""
	}

	names := map[string]bool{varName: true}
	for g := range group {
		names[g] = true
	}
	var env []symBinding
	var reads []recurrenceSelfRead
	bare := false
	collectRecurrenceSelfReadsOf(eq.RHS, names, file, &env, false, &reads, &bare)
	if len(reads) == 0 {
		// No `index(V, …)` read: not a recurrence definition. A BARE self-mention
		// alone is left to the ordinary cycle / DAE diagnostics, which is where it
		// was reported before this construct existed.
		return false, nil, ""
	}

	if bare {
		return true, &recurrenceFinding{
			code: codeRecurrenceNotWellfounded,
			message: fmt.Sprintf("'%s' is read bare inside its own defining equation as well as "+
				"through `index`. A bare read names the whole array, which does not exist while "+
				"the recurrence sweeps it (esm-spec §4.3.1.1).", varName),
		}, ""
	}

	for _, read := range reads {
		if !read.unsequenceable {
			continue
		}
		return true, &recurrenceFinding{
			code: codeRecurrenceUnsupportedForm,
			message: fmt.Sprintf("a causal self-read of '%s' is reached only through a construct "+
				"that evaluates its operand whole — a `makearray` region value, or a "+
				"`reshape`/`transpose`/`concat`/`broadcast` operand — so no cell-by-cell sweep can "+
				"supply it. A `makearray`'s region order fixes which write WINS, not the order "+
				"cells are EVALUATED in (esm-spec §4.3.1.1, §4.3.2); write the recurrence as one "+
				"`faq` with the base case as an `ifelse` guard in the body.", varName),
		}, ""
	}

	// The cell frame: the indexed-`faq` LHS's own indices when the LHS names
	// them, else the RHS aggregate's `output_idx`.
	rhsIdx, rhsIdxPresent := aggregateOutputIdx(eq.RHS)
	idxNames, framed := lhsIdx, lhsIdxPresent
	if !framed {
		idxNames, framed = rhsIdx, rhsIdxPresent
	}
	if !framed {
		return true, &recurrenceFinding{
			code: codeRecurrenceUnsupportedForm,
			message: fmt.Sprintf("the definition of '%s' reads '%s' at another position, but the "+
				"equation declares no cell frame to sweep: its RHS is not a `faq` over the "+
				"variable's axes and its LHS is not the indexed-`faq` form "+
				"`faq{expr: index(%s, k…)}` (esm-spec §4.3.1.1).", varName, varName, varName),
		}, ""
	}

	frameSyms, symbolic := frameIndexSymbols(idxNames)
	if !symbolic {
		return true, &recurrenceFinding{
			code: codeRecurrenceUnsupportedForm,
			message: fmt.Sprintf("the recurrence definition of '%s' has no symbolic output index "+
				"to fold along (%v); a literal singleton dimension cannot be a recurrence axis "+
				"(esm-spec §4.3.1.1).", varName, idxNames),
		}, ""
	}

	frameEnv := aggregateRangeBounds(eq.RHS, file)
	axis, sameCell, finding := checkRecurrenceReadsGroup(varName, frameSyms, frameEnv, reads)
	if finding != nil {
		return true, finding, ""
	}
	// The frame signature: each axis's range as the validator resolves it —
	// bounds when provable, the authored spec otherwise, so `{from: steps}` and
	// `[1, 4]` over a 4-element `steps` are one frame.
	var ranges map[string]any
	if node, isNode := asExprNode(eq.RHS); isNode && node.Op == opAggregate {
		ranges = node.Ranges
	}
	parts := make([]string, 0, len(frameSyms))
	for _, sym := range frameSyms {
		spec, present := ranges[sym]
		if b, resolved := validatorSymbolBounds(spec, file); present && resolved {
			parts = append(parts, fmt.Sprintf("%d..%d", b.lo, b.hi))
		} else {
			parts = append(parts, fmt.Sprintf("%v", spec))
		}
	}
	sort.Strings(sameCell)
	return true, nil, fmt.Sprintf("%v|%v|%d|%s", frameSyms, parts, axis, strings.Join(sameCell, ","))
}

// checkRecurrenceReads is the lag analysis: every self-read must be affine in
// its frame symbol with coefficient 1 on every axis, strictly earlier on exactly
// ONE axis, and every read must agree on WHICH axis that is.
func checkRecurrenceReads(varName string, frameSyms []string, frameEnv map[string]symBounds, reads []recurrenceSelfRead) *recurrenceFinding {
	_, finding := checkRecurrenceReadsAxis(varName, frameSyms, frameEnv, reads)
	return finding
}

// checkRecurrenceReadsAxis is checkRecurrenceReads that also returns the
// recurrence axis it settled on (-1 with a finding).
func checkRecurrenceReadsAxis(varName string, frameSyms []string, frameEnv map[string]symBounds, reads []recurrenceSelfRead) (int, *recurrenceFinding) {
	axis, _, finding := checkRecurrenceReadsGroup(varName, frameSyms, frameEnv, reads)
	return axis, finding
}

// checkRecurrenceReadsGroup is the lag analysis for a member of a recurrence
// group: it also returns the peers read at the cell being written (esm-spec
// §4.3.1.2 rule 1), which are admitted here and checked for a cycle by the
// group check. The axis is -1 when every causal read is such a peer read.
func checkRecurrenceReadsGroup(varName string, frameSyms []string, frameEnv map[string]symBounds, reads []recurrenceSelfRead) (int, []string, *recurrenceFinding) {
	var sameCell []string
	axis := -1
	for _, read := range reads {
		if len(read.args) != len(frameSyms) {
			return -1, nil, &recurrenceFinding{
				code: codeRecurrenceNotWellfounded,
				message: fmt.Sprintf("a causal self-read of '%s' supplies %d indices but its frame "+
					"has %d axes; every self-read indexes every axis (esm-spec §4.3.1.1).",
					varName, len(read.args), len(frameSyms)),
			}
		}

		// The read's own environment wins over the frame's: an inner `faq`
		// may rebind a name, and the read sits under that binder.
		env := make(map[string]symBounds, len(frameEnv)+len(read.env))
		for k, v := range frameEnv {
			env[k] = v
		}
		for k, v := range read.env {
			env[k] = v
		}

		lagged := -1
		// Whether every value of the recurrence-axis lag was shown `>= 1`. A
		// self-read need not be; a PEER read must be (esm-spec §4.3.1.2).
		proven := true
		for d, arg := range read.args {
			sym := frameSyms[d]
			affine, ok := structuralAffineInSym(arg, sym, env)
			if !ok {
				return -1, nil, &recurrenceFinding{
					code: codeRecurrenceNotWellfounded,
					message: fmt.Sprintf("index %d of a causal self-read of '%s' is not affine in "+
						"its frame symbol '%s'. A self-read names a position RELATIVE to the cell "+
						"being written (`%s - 1`, `%s - a`, `%s - a - 2`), which is what makes the "+
						"recurrence axis and its direction decidable (esm-spec §4.3.1.1). "+
						"If the offset is read from data (`%s - index(lag, %s)`), it has no direct "+
						"spelling; contract it instead: either order the axis so the predecessor is "+
						"the preceding position and the lag is the constant 1, or range a contracted "+
						"index `a` over the lag's bounds and select the matching term with "+
						"`ifelse(index(lag, %s) == a, <term reading index(%s, %s - a)>, 0)`.",
						d, varName, sym, sym, sym, sym, sym, sym, sym, varName, sym),
				}
			}
			// The MANDATORY half of the proof: coefficient exactly 1. Without it
			// the read names no position relative to the cell being written, so
			// neither the axis nor the direction of the fold is decidable.
			if affine.coef != 1 {
				return -1, nil, &recurrenceFinding{
					code: codeRecurrenceNotWellfounded,
					message: fmt.Sprintf("index %d of a causal self-read of '%s' carries its frame "+
						"symbol '%s' with coefficient %d, not 1, so it does not name a position "+
						"relative to the cell being written (esm-spec §4.3.1.1).",
						d, varName, sym, affine.coef),
				}
			}
			// The OPTIONAL half: an unbounded constant part is a lag of unknown
			// SIGN. This axis IS the recurrence axis — it is demonstrably not the
			// identity — and the cells where the lag would be non-causal cannot be
			// read at all, because the sweep has not published them. Rejecting here
			// would make this validator prove less than the evaluator and refuse a
			// document the evaluator accepts (esm-spec §4.3.1.1 "Admitted lag").
			if !affine.konstOK {
				if lagged >= 0 {
					return -1, nil, &recurrenceFinding{
						code: codeRecurrenceNotWellfounded,
						axis: sym,
						message: fmt.Sprintf("a causal self-read of '%s' is offset on more than "+
							"one axis. A recurrence folds along exactly ONE axis; every other "+
							"index must be the bare frame symbol (esm-spec §4.3.1.1).", varName),
					}
				}
				lagged = d
				proven = false
				continue
			}
			// lag = sym - arg, so the argument's bounds invert.
			lagLo, lagHi := -affine.konst.hi, -affine.konst.lo
			if lagLo == 0 && lagHi == 0 {
				// Provably this axis's own cell: not the recurrence axis, and not a
				// defect — every axis but one reads at the cell being written.
				continue
			}
			if lagHi <= 0 {
				return -1, nil, &recurrenceFinding{
					code: codeRecurrenceNotWellfounded,
					axis: sym,
					message: fmt.Sprintf("index %d of a causal self-read of '%s' names the cell "+
						"being written, or a later one, on axis '%s'. A causal self-reference reads "+
						"strictly EARLIER positions; no sweep order can satisfy a same-cell or "+
						"forward read (esm-spec §4.3.1.1).", d, varName, sym),
				}
			}
			if lagged >= 0 {
				return -1, nil, &recurrenceFinding{
					code: codeRecurrenceNotWellfounded,
					axis: sym,
					message: fmt.Sprintf("a causal self-read of '%s' is offset on more than one "+
						"axis. A recurrence folds along exactly ONE axis; every other index must be "+
						"the bare frame symbol (esm-spec §4.3.1.1).", varName),
				}
			}
			lagged = d
			proven = proven && lagLo >= 1
		}

		if lagged < 0 && readTarget(read, varName) != varName {
			// A read of a PEER at the cell being written: an ordering WITHIN the
			// cell, rejected by the group check only if such reads form a cycle.
			sameCell = append(sameCell, read.target)
			continue
		}
		if lagged < 0 {
			return -1, nil, &recurrenceFinding{
				code: codeRecurrenceNotWellfounded,
				message: fmt.Sprintf("a causal read of '%s' in the definition of '%s' is at the "+
					"same cell on every axis, so it defines '%s' in terms of a value at the cell "+
					"being written rather than of an earlier position (esm-spec §4.3.1.1, "+
					"§4.3.1.2).", readTarget(read, varName), varName, varName),
			}
		}
		if readTarget(read, varName) != varName && !proven {
			return -1, nil, &recurrenceFinding{
				code: codeRecurrenceNotWellfounded,
				axis: frameSyms[lagged],
				message: fmt.Sprintf("the read of '%s' in the definition of '%s' — a peer in its "+
					"recurrence group — is not provably strictly earlier on axis '%s'. A read of a "+
					"PEER must be strictly earlier for every value of its lag (esm-spec §4.3.1.2): "+
					"unlike a self-read, whose same-cell values simply have not been published, a "+
					"same-position read of another variable would make the result depend on which "+
					"member is evaluated first.", read.target, varName, frameSyms[lagged]),
			}
		}
		switch {
		case axis < 0:
			axis = lagged
		case axis == lagged:
			// Same axis as every earlier read: nothing to report.
		default:
			return -1, nil, &recurrenceFinding{
				code: codeRecurrenceNotWellfounded,
				axis: frameSyms[lagged],
				message: fmt.Sprintf("the causal self-reads of '%s' disagree on the recurrence "+
					"axis: one folds along '%s' and another along '%s'. A definition folds along "+
					"exactly one axis (esm-spec §4.3.1.1).", varName, frameSyms[axis], frameSyms[lagged]),
			}
		}
	}
	return axis, sameCell, nil
}

// readTarget is the variable a causal read names: its recorded target, or —
// for a read collected by the single-variable walk — the variable defined.
func readTarget(read recurrenceSelfRead, varName string) string {
	if read.target == "" {
		return varName
	}
	return read.target
}

// recurrenceLHSTarget returns the variable an equation DEFINES, when its LHS
// names one: a bare variable, or the §4.3 indexed-`faq` LHS form
// `faq{expr: index(V, k…)}`. The second return is that form's own index
// frame, and the third whether the LHS supplied one at all.
//
// A DERIVATIVE LHS (`D(u) ~ …`) deliberately yields false: it defines no array
// algebraically, so a stencil read of `u` at `i-1` there is a gather on the
// SOLVER'S STATE — the §4.3.3 ghost-cell regime — and not a self-reference.
// Treating it as one would reject every finite-difference document in the corpus.
func recurrenceLHSTarget(lhs Expression) (string, []any, bool, bool) {
	if name, ok := lhs.(string); ok {
		return name, nil, false, true
	}
	node, ok := asExprNode(lhs)
	if !ok || node.Op != opAggregate {
		return "", nil, false, false
	}
	inner, ok := asExprNode(node.Expr)
	if !ok || inner.Op != opIndex || len(inner.Args) == 0 {
		return "", nil, false, false
	}
	name, ok := inner.Args[0].(string)
	if !ok {
		return "", nil, false, false
	}
	return name, node.OutputIdx, node.OutputIdx != nil, true
}

// aggregateOutputIdx returns an expression's `output_idx` when it is an
// `faq` node that declares one.
func aggregateOutputIdx(expr Expression) ([]any, bool) {
	node, ok := asExprNode(expr)
	if !ok || node.Op != opAggregate || node.OutputIdx == nil {
		return nil, false
	}
	return node.OutputIdx, true
}

// frameIndexSymbols validates a cell frame and returns its axis symbols. An
// EMPTY frame, or one carrying a literal integer in place of a symbol, has no
// axis to fold along: a literal singleton dimension names no position the sweep
// could advance, so there is no recurrence axis to derive.
func frameIndexSymbols(idxNames []any) ([]string, bool) {
	if len(idxNames) == 0 {
		return nil, false
	}
	out := make([]string, len(idxNames))
	for i, raw := range idxNames {
		name, ok := raw.(string)
		if !ok {
			return nil, false
		}
		// A symbol spelled as a decimal integer ("3") is a literal, not a binder,
		// regardless of the JSON type it arrived as.
		if _, err := strconv.ParseInt(name, 10, 64); err == nil {
			return nil, false
		}
		out[i] = name
	}
	return out, true
}

// aggregateRangeBounds resolves the index-symbol bounds a `faq`'s
// `ranges` declares, skipping every entry the validator cannot resolve.
func aggregateRangeBounds(expr Expression, file *ESMFile) map[string]symBounds {
	out := make(map[string]symBounds)
	node, ok := asExprNode(expr)
	if !ok || node.Op != opAggregate {
		return out
	}
	for _, key := range sortedKeys(node.Ranges) {
		if bounds, ok := validatorSymbolBounds(node.Ranges[key], file); ok {
			out[key] = bounds
		}
	}
	return out
}

// validatorSymbolBounds resolves one `ranges` entry to an inclusive integer
// interval, as far as the VALIDATOR can see it — unlike the evaluating bindings'
// runtime, which is handed ranges already resolved against the registry.
//
// Resolvable: a dense literal `[start, stop]` or `[start, step, stop]` tuple
// (the stride is immaterial to the BOUNDS), and a plain `{from: NAME}` reference
// to an `interval` set (`1..size`) or a `categorical` set (`1..len(members)`).
// Both of the latter are 1-origin dense ranges at evaluation and the EVALUATOR
// resolves both before rule building, so omitting `categorical` here would make
// this validator prove less than the evaluator and reject a document the
// evaluator accepts.
//
// Everything else — a derived set, a RAGGED `{from, of}` reference whose extent
// varies per parent tuple, a bound still spelled as a metaparameter expression —
// is unresolvable, which leaves a lag built from that symbol UNPROVABLE rather
// than illegal.
func validatorSymbolBounds(spec any, file *ESMFile) (symBounds, bool) {
	switch s := spec.(type) {
	case []any:
		var stop any
		switch len(s) {
		case 2:
			stop = s[1]
		case 3:
			// `[start, step, stop]` per esm-spec §4.3.1 / esm-schema.json: the stop
			// is the LAST element, not the second.
			stop = s[2]
		default:
			return symBounds{}, false
		}
		lo, okLo := asExactInt64(s[0])
		hi, okHi := asExactInt64(stop)
		if !okLo || !okHi {
			return symBounds{}, false
		}
		return symBounds{lo: lo, hi: hi}, true

	case map[string]any:
		name, ok := s["from"].(string)
		if !ok {
			return symBounds{}, false
		}
		// A RAGGED reference (`of` present) has a per-parent extent, so it bounds
		// nothing statically.
		if _, ragged := s["of"]; ragged {
			return symBounds{}, false
		}
		if file == nil {
			return symBounds{}, false
		}
		set, declared := file.IndexSets[name]
		if !declared {
			return symBounds{}, false
		}
		switch set.Kind {
		case "interval":
			if set.Size == nil {
				return symBounds{}, false
			}
			return symBounds{lo: 1, hi: int64(*set.Size)}, true
		case "categorical":
			if set.Members == nil {
				return symBounds{}, false
			}
			return symBounds{lo: 1, hi: int64(len(set.Members))}, true
		}
		return symBounds{}, false
	}
	return symBounds{}, false
}

// structuralAffine is the affine form of an index expression with respect to a
// frame symbol: the coefficient of that symbol, plus the bounds of the
// symbol-free part — which may be UNKNOWN.
//
// The two halves carry different obligations, and that is the point of splitting
// them (esm-spec §4.3.1.1 "Admitted lag"): the coefficient must be provable,
// because without it the read names no position relative to the cell being
// written; an unprovable constant part is merely a lag of unknown SIGN, which
// the format admits and the runtime's fail-closed read guards.
type structuralAffine struct {
	// coef is the coefficient of the frame symbol. Always known — an expression
	// whose coefficient cannot be derived is not affine at all.
	coef int64
	// konst bounds the symbol-free part; valid only when konstOK.
	konst   symBounds
	konstOK bool
}

// knownAffine builds a fully-proved affine form.
func knownAffine(coef, lo, hi int64) structuralAffine {
	return structuralAffine{coef: coef, konst: symBounds{lo: lo, hi: hi}, konstOK: true}
}

// structuralAffineInSym returns the affine form of e with respect to sym, and
// whether e is affine in sym at all.
//
// It mirrors the evaluating bindings' own `affine_in_sym` exactly — the two must
// agree on which shapes are decidable, or the validator and the evaluator would
// disagree about which documents are legal. Only `+`, `-` and multiplication by
// a symbol-free EXACT constant preserve affinity, so nothing else is admitted; a
// division, a `%`, or a nested `index` leaves the position underivable and is
// reported rather than guessed at.
//
// Note the asymmetry with the constant part: a variable this checker cannot
// bound does NOT make the expression non-affine. It contributes coefficient 0
// with an unknown constant part, so `k - n` for a parameter `n` is still affine
// in `k` with coefficient 1 — the axis is decided, only the lag's sign is not.
func structuralAffineInSym(e any, sym string, env map[string]symBounds) (structuralAffine, bool) {
	switch v := e.(type) {
	case string:
		if v == sym {
			return knownAffine(1, 0, 0), true
		}
		if bounds, known := env[v]; known {
			return knownAffine(0, bounds.lo, bounds.hi), true
		}
		// A parameter, or an index symbol whose range resolves only against the
		// registry. Affine, with an unbounded constant part.
		return structuralAffine{coef: 0, konstOK: false}, true
	case ExprNode:
		return structuralAffineInNode(v, sym, env)
	case *ExprNode:
		if v == nil {
			return structuralAffine{}, false
		}
		return structuralAffineInNode(*v, sym, env)
	}
	if n, ok := asExactInt64(e); ok {
		return knownAffine(0, n, n), true
	}
	if node, ok := asExprNode(e); ok {
		return structuralAffineInNode(node, sym, env)
	}
	return structuralAffine{}, false
}

func structuralAffineInNode(node ExprNode, sym string, env map[string]symBounds) (structuralAffine, bool) {
	if len(node.Args) != 2 {
		return structuralAffine{}, false
	}
	a, okA := structuralAffineInSym(node.Args[0], sym, env)
	if !okA {
		return structuralAffine{}, false
	}
	b, okB := structuralAffineInSym(node.Args[1], sym, env)
	if !okB {
		return structuralAffine{}, false
	}
	// The constant part survives only if BOTH sides bound theirs; one unknown
	// operand makes the whole constant part unknown, while the coefficients still
	// combine exactly.
	both := a.konstOK && b.konstOK

	switch node.Op {
	case "+":
		out := structuralAffine{coef: a.coef + b.coef, konstOK: both}
		if both {
			out.konst = symBounds{lo: a.konst.lo + b.konst.lo, hi: a.konst.hi + b.konst.hi}
		}
		return out, true
	case "-":
		out := structuralAffine{coef: a.coef - b.coef, konstOK: both}
		if both {
			out.konst = symBounds{lo: a.konst.lo - b.konst.hi, hi: a.konst.hi - b.konst.lo}
		}
		return out, true
	case "*":
		// Affinity survives multiplication only when ONE side is a symbol-free
		// EXACT constant (a degenerate interval carrying no `sym`); the other side
		// scales. `k * a` where both carry bounds is affine in neither. The left
		// operand is tried first, as in the reference — with both sides constant
		// either arm gives the same product.
		var k int64
		var other structuralAffine
		switch {
		case a.coef == 0 && a.konstOK && a.konst.lo == a.konst.hi:
			k, other = a.konst.lo, b
		case b.coef == 0 && b.konstOK && b.konst.lo == b.konst.hi:
			k, other = b.konst.lo, a
		default:
			return structuralAffine{}, false
		}
		out := structuralAffine{coef: other.coef * k, konstOK: other.konstOK}
		if other.konstOK {
			p, q := other.konst.lo*k, other.konst.hi*k
			out.konst = symBounds{lo: minInt64(p, q), hi: maxInt64(p, q)}
		}
		return out, true
	}
	return structuralAffine{}, false
}

// asExactInt64 accepts a numeric literal that denotes an EXACT integer: an
// integer-typed leaf, or a float leaf with no fractional part (a `1.0` authored
// where `1` was meant is the same index). A non-finite float, a string, or a
// bool is not an index literal.
func asExactInt64(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int32:
		return int64(n), true
	case int64:
		return n, true
	case float32:
		return exactFloatToInt64(float64(n))
	case float64:
		return exactFloatToInt64(n)
	}
	return 0, false
}

func exactFloatToInt64(f float64) (int64, bool) {
	if math.IsNaN(f) || math.IsInf(f, 0) || f != math.Trunc(f) {
		return 0, false
	}
	return int64(f), true
}

func minInt64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// opBlocksCellRestriction reports whether an op consumes its operands WHOLE. A
// self-read underneath one of these names a cell of an array that has to exist
// in full before the op can run, so no cell-by-cell sweep can supply it — which
// is `recurrence_unsupported_form` rather than `recurrence_not_wellfounded`: the
// READ may be perfectly causal, it is the surrounding construct that cannot be
// sequenced (esm-spec §4.3.1.1 *Rejections*).
//
// `apply_expression_template` is deliberately NOT here. Its operands ride the
// `bindings` field, which this walk does not visit (and must not start visiting
// unilaterally — five bindings mirror this field set and §5.19.5 requires exact
// agreement), so listing it was a rule that barely reached what it named. It is
// also unreachable in practice: a template application surviving into an
// evaluation position is already an `unlowered_operator` error (esm-spec
// §9.6.4). The list therefore names only the ops that legitimately reach
// evaluation and consume an operand whole.
func opBlocksCellRestriction(op string) bool {
	switch op {
	case "reshape", "transpose", "concat", "broadcast":
		return true
	}
	return false
}

// collectRecurrenceSelfReads walks expr and accumulates every `index(varName, …)`
// read into out, together with the index-symbol environment in scope at the read
// and whether the read sits under a construct that cannot be restricted to one
// cell. It also sets bare when varName occurs as a NAKED reference, which names
// the whole array — an object that does not exist while the recurrence sweeps it.
//
// env is a stack: a `faq` pushes its resolvable `ranges` on entry and
// pops them on exit, so a nested binder shadows an outer one of the same name
// and a symbol goes out of scope where the authored binder ends.
//
// The walked field set is deliberately the same as the reference validator's —
// `args`, `expr`, `filter`, `key`, `lower`, `upper`, `values` — and not the
// wider set mapExprChildren covers. `ranges`, `regions`, `bindings`, `axes` and
// `join` hold LOAD-TIME index/metaparameter expressions and join key columns,
// not runtime operands (see exprRefNonRefSlots in expr_walk.go): a name there is
// not a read of the array, so collecting one would manufacture a self-read out
// of a bound.
func collectRecurrenceSelfReads(expr Expression, varName string, file *ESMFile, env *[]symBinding, blocked bool, out *[]recurrenceSelfRead, bare *bool) {
	collectRecurrenceSelfReadsOf(expr, map[string]bool{varName: true}, file, env, blocked, out, bare)
}

// collectRecurrenceSelfReadsOf is collectRecurrenceSelfReads over several names
// at once — a recurrence group's members (esm-spec §4.3.1.2) — recording which
// one each read names.
func collectRecurrenceSelfReadsOf(expr Expression, names map[string]bool, file *ESMFile, env *[]symBinding, blocked bool, out *[]recurrenceSelfRead, bare *bool) {
	node, ok := asExprNode(expr)
	if !ok {
		if name, isName := expr.(string); isName && names[name] {
			*bare = true
		}
		// A bare `[]any` is deliberately NOT descended into: `args` elements are
		// Expressions per esm-schema.json, so a nested array is not a position an
		// operand can occupy, and the reference validator does not look there
		// either. Looking anyway would let Go find a "self-read" Rust cannot.
		return
	}

	pushed := 0
	if node.Op == opAggregate {
		for _, key := range sortedKeys(node.Ranges) {
			if bounds, resolved := validatorSymbolBounds(node.Ranges[key], file); resolved {
				*env = append(*env, symBinding{name: key, bounds: bounds})
				pushed++
			}
		}
	}
	defer func() { *env = (*env)[:len(*env)-pushed] }()

	isSelfIndex := node.Op == opIndex && len(node.Args) > 0
	target := ""
	if isSelfIndex {
		name, isName := node.Args[0].(string)
		isSelfIndex = isName && names[name]
		target = name
	}
	if isSelfIndex {
		snapshot := make(map[string]symBounds, len(*env))
		for _, binding := range *env {
			// Push order, so an inner binder overwrites the outer one it shadows.
			snapshot[binding.name] = binding.bounds
		}
		*out = append(*out, recurrenceSelfRead{
			args:           node.Args[1:],
			env:            snapshot,
			unsequenceable: blocked,
			target:         target,
		})
	}

	blockedChildren := blocked || opBlocksCellRestriction(node.Op)
	// The `index` node's own array operand is the self-reference itself, already
	// recorded; descending into it would additionally report it as a BARE read.
	skip := 0
	if isSelfIndex {
		skip = 1
	}
	for _, arg := range node.Args[skip:] {
		collectRecurrenceSelfReadsOf(arg, names, file, env, blockedChildren, out, bare)
	}
	for _, side := range []any{node.Expr, node.Filter, node.Key, node.Lower, node.Upper} {
		if side == nil {
			continue
		}
		collectRecurrenceSelfReadsOf(side, names, file, env, blockedChildren, out, bare)
	}
	// A `makearray` REGION VALUE is evaluated once for the whole region, so a
	// self-read inside one can never be sequenced — unconditionally blocked, not
	// merely inheriting the parent's state. §4.3.2's "later entries overwrite
	// earlier ones" fixes which write WINS, not the order cells are EVALUATED in.
	for _, value := range node.Values {
		collectRecurrenceSelfReadsOf(value, names, file, env, true, out, bare)
	}
}

// recurrenceGroups returns the recurrence GROUP candidates of model (esm-spec
// §4.3.1.2): each strongly connected component of two or more observeds — in the
// §4.9.6 dependency graph with every recurrence candidate's self-edge already
// dropped — whose members are all array-shaped and whose every internal edge is
// carried by at least one `index` read.
//
// This is the predicate the cycle exemptions (`observed_cycle`, the
// `circular_dependency` graph, the cadence seeder) are gated on, never the
// well-foundedness verdict (CONFORMANCE_SPEC §5.19.5): a group with an
// ill-founded read is still a candidate, so it reaches the named `recurrence_*`
// diagnosis rather than collapsing to a cycle. A component with a scalar member,
// or one held together by a bare read, is no candidate and stays a cycle.
// Components come back sorted by their smallest name.
func recurrenceGroups(model *Model, file *ESMFile) []map[string]bool {
	if model == nil {
		return nil
	}
	defs := observedDefinitions(model)
	if len(defs) < 2 {
		return nil
	}
	states := odeStateSet(model)
	candidates := recurrenceCandidateVars(model, file)
	arrayShaped := arrayShapedUnknowns(model)
	graph := map[string]map[string]bool{}
	for name, rhs := range defs {
		if states[name] {
			continue
		}
		bound := expressionBoundSymbols(rhs)
		succ := map[string]bool{}
		for ref := range FreeVariables(rhs) {
			if bound[ref] || states[ref] {
				continue
			}
			if _, isDef := defs[ref]; !isDef {
				continue
			}
			if ref == name && candidates[name] {
				continue
			}
			succ[ref] = true
		}
		graph[name] = succ
	}
	var out []map[string]bool
	for _, comp := range stronglyConnectedObserved(graph) {
		if len(comp) < 2 {
			continue
		}
		// At least one read inside the component must be OFFSET — not a plain
		// gather whose every index is a bare name. A cycle closed by same-cell
		// gathers alone has no axis to fold along and stays an observed_cycle.
		offset := false
		for u := range comp {
			for v := range comp {
				if readsOffset(defs[u], v) {
					offset = true
				}
			}
		}
		if !offset {
			continue
		}
		ok := true
		for u := range comp {
			if !arrayShaped[u] {
				ok = false
				break
			}
			for v := range graph[u] {
				if v != u && comp[v] && !readsThroughIndex(defs[u], v) {
					ok = false
				}
			}
		}
		if ok {
			out = append(out, comp)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return sortedKeysOfSet(out[i])[0] < sortedKeysOfSet(out[j])[0]
	})
	return out
}

// readsThroughIndex reports whether e gathers name through at least one `index`
// node, at any depth of any expression-bearing field.
func readsThroughIndex(e any, name string) bool {
	switch v := e.(type) {
	case []any:
		for _, x := range v {
			if readsThroughIndex(x, name) {
				return true
			}
		}
		return false
	case map[string]any:
		if v["op"] == opIndex {
			if args, isList := v["args"].([]any); isList && len(args) > 0 && args[0] == name {
				return true
			}
		}
		for _, x := range v {
			if readsThroughIndex(x, name) {
				return true
			}
		}
		return false
	}
	if node, isNode := asExprNode(e); isNode {
		if node.Op == opIndex && len(node.Args) > 0 {
			if head, isName := node.Args[0].(string); isName && head == name {
				return true
			}
		}
		for _, a := range node.Args {
			if readsThroughIndex(a, name) {
				return true
			}
		}
		for _, side := range []any{node.Expr, node.Filter, node.Key, node.Lower, node.Upper} {
			if side != nil && readsThroughIndex(side, name) {
				return true
			}
		}
		for _, value := range node.Values {
			if readsThroughIndex(value, name) {
				return true
			}
		}
	}
	return false
}

// stronglyConnectedObserved returns the strongly connected components of graph
// (Kosaraju, both passes iterative), visiting roots and successors in sorted
// order so the result is a function of the document alone.
func stronglyConnectedObserved(graph map[string]map[string]bool) []map[string]bool {
	visited := map[string]bool{}
	var finish []string
	type frame struct {
		node string
		succ []string
		i    int
	}
	for _, root := range sortedKeysOfSet(keysAsSet(graph)) {
		if visited[root] {
			continue
		}
		visited[root] = true
		stack := []*frame{{root, sortedKeysOfSet(graph[root]), 0}}
		for len(stack) > 0 {
			top := stack[len(stack)-1]
			if top.i >= len(top.succ) {
				finish = append(finish, top.node)
				stack = stack[:len(stack)-1]
				continue
			}
			next := top.succ[top.i]
			top.i++
			if _, inGraph := graph[next]; !inGraph || visited[next] {
				continue
			}
			visited[next] = true
			stack = append(stack, &frame{next, sortedKeysOfSet(graph[next]), 0})
		}
	}
	reverse := map[string][]string{}
	for u, vs := range graph {
		for v := range vs {
			if _, inGraph := graph[v]; inGraph {
				reverse[v] = append(reverse[v], u)
			}
		}
	}
	assigned := map[string]bool{}
	var out []map[string]bool
	for i := len(finish) - 1; i >= 0; i-- {
		root := finish[i]
		if assigned[root] {
			continue
		}
		assigned[root] = true
		comp := map[string]bool{}
		st := []string{root}
		for len(st) > 0 {
			n := st[len(st)-1]
			st = st[:len(st)-1]
			comp[n] = true
			for _, p := range reverse[n] {
				if !assigned[p] {
					assigned[p] = true
					st = append(st, p)
				}
			}
		}
		out = append(out, comp)
	}
	return out
}

// keysAsSet is the key set of m, for sortedKeysOfSet.
func keysAsSet(m map[string]map[string]bool) map[string]bool {
	out := make(map[string]bool, len(m))
	for k := range m {
		out[k] = true
	}
	return out
}

// readsOffset reports whether e gathers name through an `index` with at least one
// argument that is not a bare name — a read that could be offset along an axis.
func readsOffset(e any, name string) bool {
	switch v := e.(type) {
	case []any:
		for _, x := range v {
			if readsOffset(x, name) {
				return true
			}
		}
		return false
	case map[string]any:
		if v["op"] == opIndex {
			if args, isList := v["args"].([]any); isList && len(args) > 0 && args[0] == name {
				for _, a := range args[1:] {
					if _, isName := a.(string); !isName {
						return true
					}
				}
			}
		}
		for _, x := range v {
			if readsOffset(x, name) {
				return true
			}
		}
		return false
	}
	if node, isNode := asExprNode(e); isNode {
		if node.Op == opIndex && len(node.Args) > 0 {
			if head, isName := node.Args[0].(string); isName && head == name {
				for _, a := range node.Args[1:] {
					if _, isStr := a.(string); !isStr {
						return true
					}
				}
			}
		}
		for _, a := range node.Args {
			if readsOffset(a, name) {
				return true
			}
		}
		for _, side := range []any{node.Expr, node.Filter, node.Key, node.Lower, node.Upper} {
			if side != nil && readsOffset(side, name) {
				return true
			}
		}
		for _, value := range node.Values {
			if readsOffset(value, name) {
				return true
			}
		}
	}
	return false
}
