package esm

// Mount-edge `url_substitutions` (esm-spec §4.7 "Binding a data source's
// location at the mount").
//
// A `{ref}` mount edge may bind the bare `{name}` placeholders of the
// referenced document's `data_sources` locations, so one shared catalogue can
// be pointed at a different data directory by each document that mounts it.
//
// This binding does not hoist a mounted document's `data_sources` into the
// mounting document at either mount form (extractSingleSystemRaw keeps only the
// single system), so the substituted locations go nowhere after the edge. The
// edge is still applied in full at both forms: its verdicts -- an unknown key
// is `url_substitution_unknown_name`, a non-text value is
// `data_source_url_unresolved` -- are part of the cross-binding contract, and
// a document this binding accepts must be one every other binding accepts.

import (
	"fmt"
	"sort"
	"strings"
)

// urlPlaceholder is one bare `{name}` occurrence in a location: the byte span
// of the whole brace pair and the name it encloses.
type urlPlaceholder struct {
	start, end int
	name       string
}

// urlPlaceholders returns the bare `{name}` placeholders of a template, in
// order of appearance. Only a brace pair enclosing a C identifier is one; a
// formatted substitution such as `{date:%Y%m%d}` is not, so an edge can never
// rewrite the runtime's own date expansion.
func urlPlaceholders(template string) []urlPlaceholder {
	var out []urlPlaceholder
	for i := 0; i < len(template); i++ {
		if template[i] != '{' {
			continue
		}
		start := i + 1
		j := start
		for j < len(template) && isIdentByte(template[j]) {
			j++
		}
		if j < len(template) && template[j] == '}' && j > start &&
			!isDigitByte(template[start]) {
			out = append(out, urlPlaceholder{start: i, end: j + 1, name: template[start:j]})
			i = j
		}
	}
	return out
}

// urlLocationSite is one `url_template` or `mirrors` string of a raw document's
// `data_sources`, with a setter that writes a rewritten value back in place.
type urlLocationSite struct {
	site  string
	value string
	set   func(string)
}

// urlLocationSites lists every location string of a raw document's
// `data_sources`, in sorted entry order so a diagnostic is deterministic.
func urlLocationSites(doc map[string]any) []urlLocationSite {
	sources, ok := doc["data_sources"].(map[string]any)
	if !ok {
		return nil
	}
	var out []urlLocationSite
	for _, name := range sortedKeys(sources) {
		entry, ok := sources[name].(map[string]any)
		if !ok {
			continue
		}
		src, ok := entry["source"].(map[string]any)
		if !ok {
			continue
		}
		if s, ok := src["url_template"].(string); ok {
			out = append(out, urlLocationSite{
				site:  fmt.Sprintf("data_sources.%s.source.url_template", name),
				value: s,
				set:   func(v string) { src["url_template"] = v },
			})
		}
		if ms, ok := src["mirrors"].([]any); ok {
			for i, m := range ms {
				s, ok := m.(string)
				if !ok {
					continue
				}
				i := i
				out = append(out, urlLocationSite{
					site:  fmt.Sprintf("data_sources.%s.source.mirrors[%d]", name, i),
					value: s,
					set:   func(v string) { ms[i] = v },
				})
			}
		}
	}
	return out
}

// applyMountURLSubstitutions applies a mount edge's `url_substitutions` to the
// referenced document's raw view (esm-spec §4.7 "Binding a data source's
// location at the mount").
//
// doc is the referenced document as resolved at this edge, before its own
// §8.2.1 resolution; binderDir is the directory of the MOUNTING document, the
// one that wrote the edge. The rules:
//
//   - A key names a bare `{key}` placeholder of some location in doc; one that
//     names none is `url_substitution_unknown_name`, so a misspelt key fails at
//     the edge rather than leaving the placeholder for a read to trip over.
//   - A value is text: a string carrying no `{` or `}`, so a substitution never
//     introduces another one (`data_source_url_unresolved` otherwise).
//   - Who wrote the location decides what it anchors on (§8.2.1). A placeholder
//     that LEADS a template supplies the whole location, so the bound value is
//     the mounting document's location: a URL or absolute path is used as-is,
//     a relative one joins onto binderDir. A placeholder anywhere else is a
//     segment of a location the referenced document wrote, so the value is
//     spliced in as text and the result resolves against the referenced
//     document's directory, as an unsubstituted template would.
//
// A placeholder the edge does not bind is left as written. A result that is
// already a `file:///` URL is renormalized here, since §8.2.1 leaves a
// scheme-led template alone and a spliced `..` must not survive.
func applyMountURLSubstitutions(doc map[string]any, raw any, binderDir, where string) error {
	if raw == nil {
		return nil
	}
	obj, ok := raw.(map[string]any)
	if !ok {
		return newETErr(codeDataSourceURLUnresolved,
			fmt.Sprintf("%s: `url_substitutions` must be an object mapping a placeholder name to a string (esm-spec §4.7)", where))
	}
	if len(obj) == 0 {
		return nil
	}
	keys := sortedKeys(obj)
	values := make(map[string]string, len(obj))
	for _, k := range keys {
		s, ok := obj[k].(string)
		if !ok {
			return newETErr(codeDataSourceURLUnresolved,
				fmt.Sprintf("%s: `url_substitutions.%s` must be a string, got %#v (esm-spec §4.7)", where, k, obj[k]))
		}
		if strings.ContainsAny(s, "{}") {
			return newETErr(codeDataSourceURLUnresolved,
				fmt.Sprintf("%s: `url_substitutions.%s` = %q carries a brace; a bound value is text and may not introduce another substitution (esm-spec §4.7)", where, k, s))
		}
		values[k] = s
	}

	sites := urlLocationSites(doc)
	present := map[string]bool{}
	for _, s := range sites {
		for _, p := range urlPlaceholders(s.value) {
			present[p.name] = true
		}
	}
	for _, k := range keys {
		if present[k] {
			continue
		}
		avail := make([]string, 0, len(present))
		for n := range present {
			avail = append(avail, n)
		}
		sort.Strings(avail)
		return newETErr(codeURLSubstitutionUnknownName,
			fmt.Sprintf("%s: `url_substitutions` binds '%s', which no `url_template` or `mirrors` entry of the referenced document's data_sources spells as a placeholder `{%s}` (available: [%s]); a mount edge never invents a placeholder (esm-spec §4.7)",
				where, k, k, strings.Join(avail, ", ")))
	}

	// The value a LEADING placeholder contributes: the mounting document's
	// location, per §8.2.1's own forms.
	base := strings.TrimRight(absoluteURLBase(binderDir), "/")
	lead := func(v string) string {
		if urlTemplateSchemeRE.MatchString(v) || strings.HasPrefix(v, "/") {
			return v
		}
		return base + "/" + v
	}

	for _, s := range sites {
		t := s.value
		var b strings.Builder
		last, changed := 0, false
		for _, p := range urlPlaceholders(t) {
			val, bound := values[p.name]
			if !bound {
				continue
			}
			b.WriteString(t[last:p.start])
			if p.start == 0 {
				b.WriteString(lead(val))
			} else {
				b.WriteString(val)
			}
			last, changed = p.end, true
		}
		if !changed {
			continue
		}
		b.WriteString(t[last:])
		out := b.String()
		if path, ok := strings.CutPrefix(out, "file://"); ok && strings.HasPrefix(path, "/") {
			p := removeURLDotSegments(path)
			if strings.ContainsAny(p, "?#") {
				return newETErr(codeDataSourceURLUnresolved,
					fmt.Sprintf("%s: %s: the substituted location %q carries a '?' or '#' (esm-spec §8.2.1)", where, s.site, out))
			}
			out = "file://" + p
		}
		s.set(out)
	}
	return nil
}
