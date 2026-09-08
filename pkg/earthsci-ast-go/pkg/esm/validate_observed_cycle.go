package esm

import (
	"fmt"
	"strings"
)

// validate_observed_cycle.go implements esm-spec §4.9.6 "An observed dependency
// cycle (`observed_cycle`)" (issue #181).
//
// An OBSERVED unknown is *defined* by the RHS of the equation whose LHS names it
// (§6.3.1), so a model's observed definitions induce a dependency graph over the
// observed names: `V → W` whenever `W` occurs free in `V`'s defining RHS and `W`
// is itself an observed of the SAME model. A cycle in that graph — the fixture's
// `gamfac -> hpbl -> wscale -> gamfac` — means no evaluation order satisfies
// every definition, so the document is unrealizable.
//
// It is a STRUCTURAL check, not a build-time one. The graph is a function of the
// equations alone — no shapes, no values, no solver — so it is decided here, at
// the same layer as `undefined_variable` and `equation_count_mismatch`, and it
// is a HARD error on the same grounds as every other provable conflict in §4.9
// (§4.8, "provable mismatch"). Go executes nothing, and CONFORMANCE_SPEC §5.19.5
// gives a non-executing binding the same rejection duty as an executing one, so
// this file is the whole of the construct here.
//
// NAMING THE CYCLE is the requirement, not a nicety. A binding that lets the
// cycle reach its build materializes the observeds in some order and then reads
// one that has no value yet — and the name it reports is whichever the walk
// happened to reach first, which is typically an observed that is declared,
// referenced and defined perfectly well. That is what issue #181 was: the Rust
// build reported `E_TREEWALK_UNBOUND_NAME: 'in_pbl'` against the one observed of
// tests/invalid/observed_cycle_array_elementwise.esm that is on NO cycle. Hence
// `details.cycle` and a message that spells the path.
//
// Relation to the two neighbouring cycle diagnostics:
//
//   - `circular_dependency` (validate.go validateCircularReferences) is a cycle
//     among MODELS reached through scoped references, pinned at `/models`. This
//     one is a cycle among the observeds INSIDE one model, pinned at
//     `/models/<M>`.
//   - `cadence_observed_cycle` (cadence.go) walks the very same graph with the
//     very same self-edge exemption, but it is a *CadenceError raised from the
//     cadence partition — a pass `Validate` never calls. The two are deliberate
//     counterparts: keep their semantics in step, and in particular keep the
//     self-edge gate identical (see below). A change to one wants a look at the
//     other.
//
// THE RECURRENCE SELF-EDGE IS NOT ONE OF THESE EDGES. A §4.3.1.1 recurrence
// CANDIDATE — an array-shaped unknown with at least one `index` self-read in its
// own defining RHS — has its self-edge `V → V` dropped, because a causal
// self-read is an ordering WITHIN one variable rather than a dependency BETWEEN
// two. The exemption is gated on CANDIDACY, never on the well-foundedness
// verdict (CONFORMANCE_SPEC §5.19.5): gating on the verdict would make an
// ill-founded self-read non-exempt, so this check would fire first and the
// `recurrence_not_wellfounded` / `recurrence_unsupported_form` diagnosis would
// never be reached — moving the original masking defect from the legal case to
// the illegal one. Equally it is gated on candidacy rather than on "is this a
// self-edge at all": a scalar `x ~ x + 1`, or a bare `s ~ s + 1` over an array,
// has no axis to fold along, can never be a recurrence, and IS a cycle of length
// one that this check MUST report.

// codeObservedCycle: a dependency cycle among a model's observed unknowns, each
// defined by an equation whose RHS reads the next (esm-spec §4.9.6).
//
// UNEXPORTED, like validate_recurrence.go's two codes and for the same reason:
// api-surface.json (pinned by api_surface_test.go) is the cross-language record
// of the exported surface and is a SHARED file, so an exported constant absent
// from it fails the build. Promoting this is a manifest edit, not a code edit.
const codeObservedCycle = "observed_cycle"

// validateObservedCycles reports ONE cycle in a model's observed dependency
// graph, at the MODEL pointer.
//
// The pointer is `/models/<M>` rather than any equation's, because a cycle is
// carried by no single equation — it is a property of the definition set —
// exactly as `equation_count_mismatch` is pinned at the model. That pair,
// (`observed_cycle`, `/models/<M>`), is what tests/invalid/expected_errors.json
// pins across all five bindings; the PROSE is deliberately not pinned
// (CONFORMANCE_SPEC §5.19.5), only the requirement that it name the observeds on
// the cycle.
//
// It runs for every model, coupled or not: the edges are drawn only between
// unknowns this model both DECLARES and DEFINES, so a coupled model's borrowed
// scope cannot manufacture one.
func (s *structuralScan) validateObservedCycles(modelName string, model *Model, basePath string) {
	graph := observedDependencyGraph(model, s.file)
	cycle := firstObservedCycle(graph)
	if len(cycle) == 0 {
		return
	}
	s.addErr(StructuralError{
		Path: basePath,
		Code: codeObservedCycle,
		Message: fmt.Sprintf("Observed definition cycle in model '%s': %s. Each observed "+
			"on the cycle is defined by an equation whose right-hand side reads the next, so "+
			"no evaluation order satisfies every definition (esm-spec §4.9.6).",
			modelName, strings.Join(cycle, " -> ")),
		// `cycle` is a PATH — ordered semantically, entry node repeated to close
		// it — not one of the §7.1.0 lexicographically-ordered name lists.
		// `dependency_type` distinguishes this payload from
		// `circular_dependency`'s, which carries a cycle among MODELS; the other
		// four bindings emit the same pair.
		Details: map[string]any{"cycle": cycle, "dependency_type": "observed_definitions"},
	})
}

// observedDependencyGraph builds the §4.9.6 graph: one node per observed unknown
// of model, one edge `V → W` per observed `W` occurring free in `V`'s defining
// RHS. Successor lists are SORTED, which together with sorted DFS roots is what
// makes the reported cycle the same on every run — Go's map iteration is
// randomized, so without both this diagnostic would name a different cycle from
// run to run on a document carrying more than one.
func observedDependencyGraph(model *Model, file *ESMFile) map[string][]string {
	defs := observedDefinitions(model)
	if len(defs) == 0 {
		return nil
	}

	// An unknown that is BOTH differentiated and given a defining equation is an
	// ODE STATE, not an observed (classify.go ObservedUnknowns: "ODE-ness wins,
	// because the defining equation is then an extra constraint on a state rather
	// than that state's definition"). A state's value comes from the integrator,
	// so it is never waiting on anything in this graph and must not be a node in
	// it — including it would report a constraint set as a cycle.
	states := odeStateSet(model)
	observed := make(map[string]bool, len(defs))
	for name := range defs {
		if !states[name] {
			observed[name] = true
		}
	}
	if len(observed) == 0 {
		return nil
	}

	// The names whose SELF-edge is dropped: §4.3.1.1 recurrence candidates. See
	// the file header — candidacy, never the well-foundedness verdict. This is
	// the same set cadence.go's `recurrenceSelfEdges` uses, from the same helper.
	selfEdgeExempt := recurrenceCandidateVars(model, file)

	// Binder-introduced symbols (an aggregate's `output_idx` / `ranges` keys, an
	// `index` element position, an integral's integration variable, …) are NOT
	// references to a model variable, so they must be subtracted before
	// intersecting with the observed names: a range key that happens to be spelled
	// like an observed would otherwise manufacture an edge out of thin air. They
	// are collected across the WHOLE equation, both sides, because the
	// indexed-definition form binds on the LHS and uses the symbol on the RHS
	// (`y[i] ~ 2*x[i]` binds `i` at the LHS `index` node) — the same scoping rule
	// validateEquationRefs applies via equationBoundSymbols.
	lhsBound := make(map[string]map[string]bool, len(observed))
	for _, eq := range model.Equations {
		name := definedVariableName(eq.LHS)
		if name == "" || !observed[name] {
			continue
		}
		bound := lhsBound[name]
		if bound == nil {
			bound = map[string]bool{}
			lhsBound[name] = bound
		}
		collectBoundSymbols(eq.LHS, bound)
	}

	graph := make(map[string][]string, len(observed))
	for name := range observed {
		rhs := defs[name]
		bound := expressionBoundSymbols(rhs)
		for sym := range lhsBound[name] {
			bound[sym] = true
		}
		successors := map[string]bool{}
		for ref := range FreeVariables(rhs) {
			if !observed[ref] || bound[ref] {
				continue
			}
			if ref == name && selfEdgeExempt[name] {
				continue
			}
			successors[ref] = true
		}
		graph[name] = sortedKeysOfSet(successors)
	}
	return graph
}

// firstObservedCycle returns the first cycle a deterministic depth-first search
// of graph reaches — the path in traversal order with the entry node repeated to
// close it (`["gamfac", "hpbl", "wscale", "gamfac"]`) — or nil when the graph is
// acyclic.
//
// ONE cycle per model is what §4.9.6 asks for, so the search stops at the first:
// a document with two cycles is already rejected by the first, and enumerating
// the rest would report the same defect several times over. Roots are visited in
// sorted order and each node's successors are already sorted, so the cycle named
// is a function of the document alone.
//
// The DFS shape mirrors validateCircularReferences (validate.go), including
// closing the cycle at the entry node's FIRST occurrence in the current path so
// the reported path is the cycle itself and not the tail leading into it.
func firstObservedCycle(graph map[string][]string) []string {
	if len(graph) == 0 {
		return nil
	}
	visited := map[string]bool{}
	inStack := map[string]bool{}
	var cycle []string

	var dfs func(node string, path []string) bool
	dfs = func(node string, path []string) bool {
		if inStack[node] {
			start := 0
			for i, p := range path {
				if p == node {
					start = i
					break
				}
			}
			cycle = append(append([]string{}, path[start:]...), node)
			return true
		}
		if visited[node] {
			return false
		}
		visited[node] = true
		inStack[node] = true
		path = append(path, node)
		for _, succ := range graph[node] {
			if dfs(succ, path) {
				return true
			}
		}
		inStack[node] = false
		return false
	}

	for _, root := range sortedKeys(graph) {
		if dfs(root, nil) {
			return cycle
		}
	}
	return nil
}
