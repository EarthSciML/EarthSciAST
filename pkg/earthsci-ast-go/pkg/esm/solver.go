package esm

import "fmt"

// ---------------------------------------------------------------------------
// Document-scoped solver hints (esm-spec §2.2)
// ---------------------------------------------------------------------------

// Solver carries numerics the document knows about ITSELF — stiffness,
// integration tolerances, and a splitting hint — which each binding maps to its
// own integrator (esm-spec §2.2).
//
// Every field is ADVISORY: a binding may ignore any or all of them and still
// conform. Advisory governs the MECHANISM, never the OUTCOME — a binding that
// ignores every field and still converges conforms; the CONFORMANCE_SPEC §5.9
// requirement to integrate successfully and agree within the error band is
// untouched by this block and is not excused by it.
//
// Abstol/Reltol are INTEGRATION tolerances and are a different quantity from
// Tolerance, which is what an assertion is COMPARED at (esm-spec §6.6.4). They
// resolve on independent chains and neither substitutes for the other.
//
// Every field is a pointer with `omitempty` because each is independently
// optional and absence is NOT a default value: a document that omits
// `stiffness` has not declared its stiffness, and a binding must not read the
// zero value as an assertion about the system.
type Solver struct {
	// Stiffness is the author's declaration of the system's stiffness:
	// "low", "moderate" or "high". A binding MAY select an implicit /
	// BDF-family integrator on "high".
	Stiffness *string `json:"stiffness,omitempty"`
	// Abstol is the absolute INTEGRATION tolerance the document asks for.
	Abstol *float64 `json:"abstol,omitempty"`
	// Reltol is the relative INTEGRATION tolerance the document asks for.
	Reltol *float64 `json:"reltol,omitempty"`
	// Splitting is an advisory operator-splitting convention: "none", "lie"
	// or "strang". It carries no prescribed substep structure.
	Splitting *string `json:"splitting,omitempty"`
}

// ---------------------------------------------------------------------------
// Spec-version gate (esm-spec §2.2.4)
// ---------------------------------------------------------------------------

// RejectSolverPreV11 rejects a top-level `solver` block in files declaring
// esm < 1.1.0. The block arrives at esm 1.1.0; a document declaring an earlier
// version that carries one is rejected with `solver_version_too_old`
// (esm-spec §2.2.4, §2.2.5). Mirrors RejectTemplateImportsPreV08.
func RejectSolverPreV11(view map[string]any) error {
	if view == nil {
		return nil
	}
	if _, has := view["solver"]; !has {
		return nil
	}
	if !esmVersionBelow(view, 1, 1) {
		return nil
	}
	esmRaw, _ := view["esm"].(string)
	return newETErr(
		"solver_version_too_old",
		fmt.Sprintf("the top-level `solver` block requires esm >= 1.1.0; file declares %s (offending path: /solver)", esmRaw),
	)
}

// normalizeSolver maps a `solver` block with nothing set to absence
// (esm-spec §2.2).
//
// `"solver": {}` is legal — every other optional top-level container admits an
// empty object, and making this one the exception would be a rule with no
// payoff — but it means exactly what omitting the block means, so it is
// normalized away AT LOAD. The typed document then never holds a block with
// nothing set, and `parse -> emit` cannot disagree across bindings about
// whether `{}` survives.
func normalizeSolver(s *Solver) *Solver {
	if s == nil {
		return nil
	}
	if s.Stiffness == nil && s.Abstol == nil && s.Reltol == nil && s.Splitting == nil {
		return nil
	}
	return s
}
