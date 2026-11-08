package esm

import (
	"embed"
	"fmt"
	"io/fs"
	"path/filepath"
	"regexp"
	"strings"
)

// stdlib.go resolves esm-spec §4.7 standard-library refs, `esm:std/<file>.esm`,
// against the copy of the repository's lib/ embedded in this package
// (pkg/esm/stdlib/, written by scripts/sync-lib.sh). The form is REQUIRED of
// every binding, at every §4.7 ref site; it reaches all of them through the
// two chokepoints canonicalImportRef and loadRefBytes.
//
// A bundled file has the identity `esm:std/<file>.esm` (the cycle-detection
// key) and the virtual base directory `esm:std`, so a relative ref inside it
// (a library file importing `calendar.esm`) names a sibling in the bundle.

//go:embed stdlib/*.esm
var embeddedStdlib embed.FS

// stdlibFS holds the bundled library files at their bare names. A package
// variable so in-package tests can substitute a bundle.
var stdlibFS fs.FS = mustSubFS(embeddedStdlib, "stdlib")

func mustSubFS(f fs.FS, dir string) fs.FS {
	sub, err := fs.Sub(f, dir)
	if err != nil {
		panic(err)
	}
	return sub
}

const (
	stdRefScheme = "esm:"
	stdRefPrefix = "esm:std/"
	// stdlibBaseDir is the virtual base directory of a bundled file.
	stdlibBaseDir = "esm:std"
)

var stdlibFileName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*\.esm$`)

// classifyStdRef decides whether a ref authored in a document whose base
// directory is baseDir is a standard-library ref. A ref that begins with `esm:`
// is one and is not `${VAR}`-expanded; any other ref is expanded first, and is
// one if the expansion begins with `esm:`, or if it is a relative path inside a
// bundled file (baseDir is the virtual `esm:std`). For a standard-library ref
// it returns the ref's identity — `esm:std/<file>.esm` for a valid name, else
// the spelling as written — and whether the name is a valid one; the bundle may
// still lack the file.
func classifyStdRef(ref, baseDir string) (identity string, valid, isStd bool) {
	r := ref
	if !strings.HasPrefix(r, stdRefScheme) {
		r = expandRefEnv(r)
	}
	switch {
	case strings.HasPrefix(r, stdRefScheme):
	case baseDir == stdlibBaseDir && !isRemoteRef(r) && !filepath.IsAbs(r):
		r = stdRefPrefix + r
	default:
		return "", false, false
	}
	if !strings.HasPrefix(r, stdRefPrefix) {
		return r, false, true
	}
	var segs []string
	for _, s := range strings.Split(strings.TrimPrefix(r, stdRefPrefix), "/") {
		if s != "." {
			segs = append(segs, s)
		}
	}
	if len(segs) != 1 || !stdlibFileName.MatchString(segs[0]) {
		return r, false, true
	}
	return stdRefPrefix + segs[0], true, true
}

// loadStdRef reads the bundled file a standard-library ref names. The error is
// plain; callers wrap it in their own unresolved diagnostic.
func loadStdRef(ref, identity string, valid bool) ([]byte, error) {
	if !valid {
		return nil, fmt.Errorf("standard-library ref %q is not of the form esm:std/<file>.esm", ref)
	}
	data, err := fs.ReadFile(stdlibFS, strings.TrimPrefix(identity, stdRefPrefix))
	if err != nil {
		return nil, fmt.Errorf("standard-library ref %q names no file of the bundled standard library", ref)
	}
	return data, nil
}
