package esm

import (
	"fmt"
	"strings"
)

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
	// External names a run-configuration document for this document
	// (esm-spec §2.2.6). It is held exactly as authored and emitted verbatim;
	// the resolved location comes from SolverExternalLocation and is never
	// written back. EarthSciAST never opens the referenced document.
	External *string `json:"external,omitempty"`
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
		CodeSolverVersionTooOld,
		fmt.Sprintf("the top-level `solver` block requires esm >= 1.1.0; file declares %s (offending path: /solver)", esmRaw),
	)
}

// RejectSolverExternalPreV13 rejects `solver.external` in files declaring
// esm < 1.3.0 with `solver_external_version_too_old` at `/solver/external`
// (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document whose `solver`
// block carries no `external` stays valid. Below 1.1.0 the whole block is
// already refused by RejectSolverPreV11, which runs first.
func RejectSolverExternalPreV13(view map[string]any) error {
	if view == nil {
		return nil
	}
	solver, ok := view["solver"].(map[string]any)
	if !ok {
		return nil
	}
	if _, has := solver["external"]; !has {
		return nil
	}
	if !esmVersionBelow(view, 1, 3) {
		return nil
	}
	esmRaw, _ := view["esm"].(string)
	return newETErr(
		CodeSolverExternalVersionTooOld,
		fmt.Sprintf("`solver.external` requires esm >= 1.3.0; file declares %s (offending path: /solver/external)", esmRaw),
	)
}

// rejectSolverExternalUnresolved refuses a `solver.external` carrying `${`
// with `solver_external_unresolved` (esm-spec §2.2.6): the reference has no
// substitutions, and a run configuration chosen by the environment is not
// reproducible. A deployment-chosen run configuration is a call-site argument.
func rejectSolverExternalUnresolved(view map[string]any) error {
	solver, ok := view["solver"].(map[string]any)
	if !ok {
		return nil
	}
	ext, ok := solver["external"].(string)
	if !ok {
		return nil
	}
	return checkSolverExternal(ext)
}

func checkSolverExternal(ext string) error {
	if !strings.Contains(ext, "${") {
		return nil
	}
	return newETErr(
		CodeSolverExternalUnresolved,
		fmt.Sprintf("/solver/external %q carries an unexpanded '${...}' variable. "+
			"esm-spec §2.2.6 does not expand environment variables into a run-configuration "+
			"reference: a run configuration chosen by the environment is not reproducible. "+
			"Write a path relative to this document, or pass the run configuration at the call site", ext),
	)
}

// SolverExternalLocation resolves the document's `solver.external` to a
// location by esm-spec §2.2.6, or returns "" when the root document's `solver`
// block carries none (an authored `external` is never empty).
//
// A URL (`scheme://…`) is returned unchanged. An absolute path has its dot
// segments removed and is prefixed `file://`. Anything else is joined onto the
// base, dot segments removed, and prefixed `file://`. The base is `base` when
// it is non-empty — a relative one is taken against the process working
// directory — and otherwise the directory recorded at load: the directory of
// the file LoadPath read, the WithBasePath directory, or the working directory
// of a bare LoadString / LoadDocument.
//
// Resolution is lexical and never touches the filesystem: a location that does
// not exist resolves normally. A mounted leaf's `solver` block does not cross
// the mount, so only the root's `external` is ever consulted.
func SolverExternalLocation(file *ESMFile, base string) (string, error) {
	if file == nil || file.SolverHints == nil || file.SolverHints.External == nil {
		return "", nil
	}
	ext := *file.SolverHints.External
	if err := checkSolverExternal(ext); err != nil {
		return "", err
	}
	if urlTemplateSchemeRE.MatchString(ext) {
		return ext, nil
	}
	if strings.HasPrefix(ext, "/") {
		return "file://" + removeURLDotSegments(ext), nil
	}
	if base == "" {
		base = file.documentBase
	}
	joined := strings.TrimRight(absoluteURLBase(base), "/") + "/" + ext
	return "file://" + removeURLDotSegments(joined), nil
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
	if s.Stiffness == nil && s.Abstol == nil && s.Reltol == nil && s.Splitting == nil && s.External == nil {
		return nil
	}
	return s
}
