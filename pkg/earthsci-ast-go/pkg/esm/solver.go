package esm

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
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
	// TimeSpan is the interval the document is meant to be simulated over
	// (esm-spec §2.2.7). Each bound is held exactly as authored -- a number
	// or an RFC 3339 UTC timestamp -- and emitted verbatim; its value in
	// seconds comes from ResolveTimeSpan and is never written back.
	TimeSpan *SolverTimeSpan `json:"time_span,omitempty"`
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
		fmt.Sprintf("/solver/external: \"%s\" carries an unexpanded '${...}' variable. "+
			"esm-spec §2.2.6 does not expand environment variables into a run-configuration "+
			"reference: a run configuration chosen by the environment is not reproducible. "+
			"Write a path relative to this document, or pass the run configuration at the call site", ext),
	)
}

// driveLetterRE matches a drive-letter path, `C:/` or `C:\`, which esm-spec
// §2.2.6 reads as absolute on every host.
var driveLetterRE = regexp.MustCompile(`^[A-Za-z]:[/\\]`)

func isAbsoluteLocationPath(p string) bool {
	return strings.HasPrefix(p, "/") || driveLetterRE.MatchString(p)
}

// lexicalAbsolute removes the dot segments of an absolute path (RFC 3986
// §5.2.4). A drive-letter path comes back as `C:/...`, its `\` read as `/`
// and its drive a root that `..` does not climb above.
func lexicalAbsolute(p string) string {
	if driveLetterRE.MatchString(p) {
		return p[:2] + removeURLDotSegments(strings.ReplaceAll(p[2:], "\\", "/"))
	}
	return removeURLDotSegments(p)
}

// absoluteDirectory returns dir as the absolute, dot-segment-free directory D
// of esm-spec §2.2.6. A relative dir is taken against the process working
// directory. Purely lexical: it never touches the filesystem.
func absoluteDirectory(dir string) string {
	d := filepath.ToSlash(dir)
	if d == "" {
		d = "."
	}
	if !isAbsoluteLocationPath(d) {
		cwd, err := os.Getwd()
		if err != nil {
			cwd = "/"
		}
		d = filepath.ToSlash(cwd) + "/" + d
	}
	return lexicalAbsolute(d)
}

// fileLocationURL prefixes an absolute, dot-segment-free path with `file://`,
// percent-encoding each byte of its UTF-8 encoding outside
// `A-Za-z0-9-._~/:` as %XX (esm-spec §2.2.6). A drive path gets the third
// slash: `file:///C:/...`.
func fileLocationURL(p string) string {
	var b strings.Builder
	b.WriteString("file://")
	if !strings.HasPrefix(p, "/") {
		b.WriteByte('/')
	}
	const hex = "0123456789ABCDEF"
	for i := 0; i < len(p); i++ {
		c := p[i]
		if ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') ||
			strings.IndexByte("-._~/:", c) >= 0 {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&0x0F])
	}
	return b.String()
}

// SolverExternalLocation resolves the document's `solver.external` to a
// location by esm-spec §2.2.6, or returns "" when the root document's `solver`
// block carries none (an authored `external` is never empty).
//
// A URL (`scheme://…`) is returned unchanged. An absolute path -- `/…`, or a
// drive-letter `C:/…` / `C:\…` -- has its dot segments removed, is
// percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive).
// Anything else is joined onto the base, dot segments removed,
// percent-encoded, and prefixed `file://`. Percent-encoding writes each byte of
// the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as %XX, `%` included:
// the input is a path, not a URL. The base is `base` when it is non-empty -- a
// relative one is taken against the process working directory -- and
// otherwise the directory recorded at load: the directory of the file LoadPath
// read, the WithBasePath directory, or the working directory of a bare
// LoadString / LoadDocument.
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
	if isAbsoluteLocationPath(ext) {
		return fileLocationURL(lexicalAbsolute(ext)), nil
	}
	var dir string
	switch {
	case base != "":
		dir = absoluteDirectory(base)
	case file.documentBase != "":
		dir = file.documentBase
	default:
		dir = absoluteDirectory(".")
	}
	return fileLocationURL(lexicalAbsolute(dir + "/" + ext)), nil
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
	if s.Stiffness == nil && s.Abstol == nil && s.Reltol == nil && s.Splitting == nil && s.External == nil &&
		s.TimeSpan == nil {
		return nil
	}
	return s
}
