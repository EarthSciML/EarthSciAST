package esm

import (
	"fmt"
	"os"
	"path/filepath"
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

// loadRefBytes resolves and reads a library ref (an http(s) URL or a path
// relative to baseDir), returning the raw bytes and the base directory against
// which the target's OWN nested relative refs should be resolved.
//
// Resolution matches the three existing loaders exactly:
//   - Remote (isRemoteRef): fetched via fetchRemoteRef. A remote target has no
//     resolvable local base for nested refs, so the caller's baseDir is
//     threaded back unchanged (as loadImportBytes and resolveSubsystemMap do).
//   - Local: resolved via canonicalImportRef(ref, baseDir) — joined onto
//     baseDir when relative, then made absolute — and rejected when it does not
//     stat or names a directory. dir is filepath.Dir of the resolved file.
//
// Errors are plain (fmt.Errorf, %w-wrapped where an underlying error exists);
// callers attach their own diagnostic code.
func loadRefBytes(ref, baseDir string) (data []byte, dir string, err error) {
	if isRemoteRef(ref) {
		data, err = fetchRemoteRef(ref)
		if err != nil {
			return nil, "", err
		}
		return data, baseDir, nil
	}
	path := canonicalImportRef(ref, baseDir)
	info, statErr := os.Stat(path)
	if statErr != nil || info.IsDir() {
		return nil, "", fmt.Errorf("ref %q not found or not a readable file: %s", ref, path)
	}
	data, err = os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("failed to read ref %q (%s): %w", ref, path, err)
	}
	return data, filepath.Dir(path), nil
}
