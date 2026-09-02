package esm

// Load-time resolution of `data_sources[*].source.url_template`
// (esm-spec §8.2.1).
//
// A `url_template` need not be an absolute URL. §8.2.1 resolves it to one at
// load time against the directory of the file the entry was read from -- the
// same base and the same timing rule §4.7 fixes for a `ref`. That is what lets
// a document name data living outside its own repository without carrying a
// machine-specific absolute path.
//
// Environment variables are deliberately NOT expanded (§4.7 permits `${VAR}`
// in a `ref`; §8.2 does not permit it at all), and a template that needs one is
// REFUSED rather than passed through: a document reading `${...}` from the
// ambient environment does not say what it reads, the expanded value is spliced
// into a URL that is then fetched, and an optional expansion capability would
// make the same document resolve under one binding and not another. See
// docs/content/rfcs/portable-data-source-urls.md.
//
// This binding has no ingest, so nothing here reads bytes. The rule still
// applies to it in full: §8.2.1 is a document normalization, observable through
// parse -> emit, and a binding that skipped it would emit a document whose
// `url_template` means something different from the same document loaded
// elsewhere -- which is the non-portability the section exists to remove.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// urlTemplateSchemeRE matches an already-absolute URL. esm-spec §8.2.1
// requires the `://` (rather than a bare `scheme:`) so that a Windows drive
// letter and a `{date:%Y}` substitution are both read as path text.
var urlTemplateSchemeRE = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.\-]*://`)

// removeURLDotSegments applies RFC 3986 §5.2.4 dot-segment removal, lexically,
// to an absolute path.
//
// Never filepath.EvalSymlinks: a template carrying a `{date:...}` substitution
// names a file that need not exist at load time, and resolving symlinks would
// make the resolved URL depend on the filesystem rather than on the document.
func removeURLDotSegments(path string) string {
	out := make([]string, 0, 8)
	for _, seg := range strings.Split(path, "/") {
		if seg == "" || seg == "." {
			continue
		}
		if seg == ".." {
			if len(out) > 0 {
				out = out[:len(out)-1]
			}
			continue
		}
		out = append(out, seg)
	}
	return "/" + strings.Join(out, "/")
}

// absoluteURLBase returns baseDir as an absolute POSIX directory.
//
// The loader's base may be relative (LoadPath("fixtures/x.esm") gives
// "fixtures"; LoadString defaults to "."), and splicing a relative path after
// `file://` would silently make its first segment the URL HOST -- the exact
// misresolution §8.2.1 exists to stop.
func absoluteURLBase(baseDir string) string {
	b := baseDir
	if b == "" {
		b = "."
	}
	b = filepath.ToSlash(b)
	if strings.HasPrefix(b, "/") {
		return b
	}
	if abs, err := filepath.Abs(b); err == nil {
		return filepath.ToSlash(abs)
	}
	if cwd, err := os.Getwd(); err == nil {
		return filepath.ToSlash(cwd) + "/" + b
	}
	return "/" + b
}

// resolveSourceURL resolves one `url_template` / `mirrors` entry per esm-spec
// §8.2.1. The returned error carries the stable diagnostic code
// codeDataSourceURLUnresolved.
//
// Package-private, like the code constant it raises. The exported Code* names
// in codes.go are exported because a caller reads them off a StructuralError's
// Code field and switches on them; this one only ever appears in the text of a
// load error, so the cross-binding contract it belongs to is the STRING (pinned
// in tests/conformance/data_source_url/manifest.json), not a Go identifier.
// Keeping both unexported is what lets §8.2.1 land without an api-surface.json
// entry and a tier decision that would say nothing a caller could use.
func resolveSourceURL(template, baseDir string) (string, error) {
	if strings.Contains(template, "${") {
		return "", fmt.Errorf("[%s] url template %q carries an unexpanded '${...}' "+
			"variable. esm-spec §8.2.1 does not expand environment variables into a "+
			"data source's location: a document that reads one does not say what it "+
			"reads, and the value is spliced into a URL that is then fetched. Write a "+
			"path relative to this document instead (it resolves against the "+
			"document's own directory), or symlink the data to that path",
			codeDataSourceURLUnresolved, template)
	}
	// Substitution-led: the author's own substitution supplies the location, so
	// there is no literal prefix to classify. §8.2 requires unrecognized
	// substitutions to be passed through, so this is left alone.
	if strings.HasPrefix(template, "{") {
		return template, nil
	}
	if urlTemplateSchemeRE.MatchString(template) {
		return template, nil
	}

	joined := template
	if !strings.HasPrefix(template, "/") {
		joined = strings.TrimRight(absoluteURLBase(baseDir), "/") + "/" + template
	}
	resolved := removeURLDotSegments(joined)
	if strings.ContainsAny(resolved, "?#") {
		return "", fmt.Errorf("[%s] url template %q resolves to %q, whose '?' or '#' "+
			"would be read as a URL query or fragment rather than as part of the path "+
			"(esm-spec §8.2.1). Rename or relocate the file",
			codeDataSourceURLUnresolved, template, resolved)
	}
	return "file://" + resolved, nil
}

// resolveDataSourceURLs rewrites every data source's location on an
// already-unmarshalled document.
//
// It runs on the typed struct rather than on the JSON text because this
// binding's load pipeline is text-based and records the AUTHORED key order off
// that text (extractTemplateOrders): decoding the document to a map and
// re-encoding it to substitute two strings would destroy the order every
// FlattenedSystem depends on. The typed field is the same value the serializer
// emits, so the resolved form still reaches emit.
//
// A resolution failure names the entry AND the template: "io error at
// /${SNAPSHOTS}/x.parquet" names neither, and a source whose location silently
// fails to resolve is indistinguishable from one that read zeros.
func resolveDataSourceURLs(file *ESMFile, baseDir string) error {
	if file == nil {
		return nil
	}
	for name, ds := range file.DataSources {
		if ds.Source.URLTemplate != "" {
			resolved, err := resolveSourceURL(ds.Source.URLTemplate, baseDir)
			if err != nil {
				return fmt.Errorf("data_sources.%s.source.url_template: %w", name, err)
			}
			ds.Source.URLTemplate = resolved
		}
		for i, m := range ds.Source.Mirrors {
			resolved, err := resolveSourceURL(m, baseDir)
			if err != nil {
				return fmt.Errorf("data_sources.%s.source.mirrors[%d]: %w", name, i, err)
			}
			ds.Source.Mirrors[i] = resolved
		}
		// DataSources holds VALUES, so the mutated copy has to be written back.
		file.DataSources[name] = ds
	}
	return nil
}
