package esm

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// refload.go unifies the http(s)-vs-local ref-loading branch that
// loadImportBytes (template_imports.go), defaultLoadCouplingRef
// (coupling_imports.go), and resolveSubsystemMap (subsystem_ref.go) each
// re-implement — three parallel copies of the same URL detection + stat/IsDir +
// ReadFile logic that differ only in which diagnostic code they wrap the
// failure in. loadRefBytes returns PLAIN wrapped errors; each caller re-wraps
// the result in its own spec diagnostic (template_import_unresolved /
// coupling_import_unresolved / the subsystem-ref message).

// isRemoteRef reports whether ref is an http(s) URL (as opposed to a local
// filesystem path). This is the URL-detection predicate the three loaders spell
// inline as strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://").
func isRemoteRef(ref string) bool {
	return strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://")
}

// refEnvToken is the esm-spec §4.7 environment-variable token: the BRACED form
// only, its name a C identifier. Capture group 1 is the variable name.
var refEnvToken = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// expandRefEnv expands the `${VAR}` tokens of a §4.7 ref from the process
// environment — the mechanism for naming a sibling library repository checked
// out at a deployment-chosen path. Three rules, which the Julia, Python and
// Rust bindings implement identically:
//
//   - ONLY the braced `${VAR}` form with a C-identifier name is expanded. A
//     bare `$VAR`, a non-identifier name (`${2}`, `${A-B}`) and an unclosed
//     `${` are all left exactly as authored.
//   - A SET variable is replaced by its value (a variable set to the empty
//     string expands to the empty string). An UNSET variable is left LITERAL,
//     so the ref goes on to fail with the ordinary unresolved diagnostic —
//     `template_import_unresolved`, `coupling_import_unresolved` or the
//     subsystem-ref error — naming the `${VAR}` text the document actually
//     carries, rather than misresolving against an empty string.
//   - Expansion runs BEFORE the remote-vs-local classification and before a
//     relative ref is anchored, because it feeds them: an expanded ref that now
//     reads `http(s)://…` is fetched, an expanded absolute path is used as-is,
//     and an expanded relative path anchors at the referencing document's
//     directory.
//
// This is an OPTIONAL loader capability on the same footing as URL refs, and it
// reaches every §4.7 ref mechanism — subsystem and top-level `{ref}` mounts,
// `expression_template_imports` (§9.7.2) and `coupling_import` (§10.10) — via
// the two chokepoints below. A `data_sources` entry's `url_template` is NOT a
// §4.7 ref and deliberately does not get this: §8.2.1 refuses a `${` there
// outright (data_source_urls.go).
func expandRefEnv(ref string) string {
	return refEnvToken.ReplaceAllStringFunc(ref, func(token string) string {
		if value, set := os.LookupEnv(refEnvToken.FindStringSubmatch(token)[1]); set {
			return value
		}
		return token
	})
}

// loadRefBytes resolves and reads a library ref (an http(s) URL or a path
// relative to baseDir), returning the raw bytes and the base directory against
// which the target's OWN nested relative refs should be resolved.
//
// Resolution matches the three existing loaders exactly:
//   - Remote (isRemoteRef): fetched via fetchRemoteRef. A remote target has no
//     resolvable local base for nested refs, so the caller's baseDir is
//     threaded back unchanged (as loadImportBytes and resolveSubsystemMap do).
//   - Local: resolved via canonicalRefPath(ref, baseDir) — joined onto
//     baseDir when relative, then made absolute — and rejected when it does not
//     stat or names a directory. dir is filepath.Dir of the resolved file.
//
// Errors are plain (fmt.Errorf, %w-wrapped where an underlying error exists);
// callers attach their own diagnostic code.
func loadRefBytes(ref, baseDir string) (data []byte, dir string, err error) {
	// esm-spec §4.7: `${VAR}` expansion feeds the resolution below, so it runs
	// before the remote-vs-local branch and before the relative-ref anchoring
	// inside canonicalRefPath. The expanded text is what the messages below
	// name; an unset variable is still literal there, so the diagnostic quotes
	// the `${VAR}` the document carries.
	ref = expandRefEnv(ref)
	if isRemoteRef(ref) {
		data, err = fetchRemoteRef(ref)
		if err != nil {
			return nil, "", err
		}
		prepared, perr := prepareDocumentOps(string(data))
		if perr != nil {
			return nil, "", fmt.Errorf("remote ref %q: %w", ref, perr)
		}
		return []byte(prepared), baseDir, nil
	}
	path := canonicalRefPath(ref, baseDir)
	info, statErr := os.Stat(path)
	if statErr != nil || info.IsDir() {
		return nil, "", fmt.Errorf("ref %q not found or not a readable file: %s", ref, path)
	}
	data, err = os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("failed to read ref %q (%s): %w", ref, path, err)
	}
	// A referenced document is a document: same wire boundary as the root
	// (docs/content/rfcs/faq-node-rename.md §5.2). Without this the `aggregate`
	// alias and `arrayop` both survive a `{ref}` all the way into Emit.
	prepared, perr := prepareDocumentOps(string(data))
	if perr != nil {
		return nil, "", fmt.Errorf("ref %q (%s): %w", ref, path, perr)
	}
	return []byte(prepared), filepath.Dir(path), nil
}
