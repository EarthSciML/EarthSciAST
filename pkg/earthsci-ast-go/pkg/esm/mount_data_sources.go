package esm

// esm-spec §4.7 "A mounted document's data sources" and "Bindings reach through
// an assembly": the two things a mount edge carries UP (a leaf's located
// `data_sources`) and DOWN (an edge binding the leaf does not declare itself)
// beyond the leaf's single component.

import (
	"encoding/json"
	"fmt"
)

// resolveRawDataSourceURLs is resolveDataSourceURLs on a RAW document view: every
// `url_template` and `mirrors` entry of its `data_sources` resolves by §8.2.1
// against baseDir, the directory of the file that wrote it. An entry already
// located (scheme-led, e.g. hoisted from a deeper mount) is left as is.
func resolveRawDataSourceURLs(doc map[string]any, baseDir string) error {
	for _, s := range urlLocationSites(doc) {
		resolved, err := resolveSourceURL(s.value, baseDir)
		if err != nil {
			return fmt.Errorf("%s: %w", s.site, err)
		}
		s.set(resolved)
	}
	return nil
}

// mountedSources collects the `data_sources` a document's mounts contribute
// to it (esm-spec §4.7 "A mounted document's data sources"), each entry
// already substituted and located at the edge that carried it up.
//
// The mounting document's OWN entry wins over anything it mounts, so a name it
// declares is never collected. Two mounts contributing the same name must
// contribute IDENTICAL entries (structurally equal JSON, every field, numbers
// by value): an identical one merges once (a diamond is legal), an unequal one
// is `data_source_merge_conflict`, naming the source and both edges.
type mountedSources struct {
	own     map[string]bool
	entries map[string]any
	edges   map[string]string
}

// newMountedSources starts a collector for a mounting document whose own
// `data_sources` declare the names in own (a raw `data_sources` object, a typed
// map, or nil).
func newMountedSources(own any) *mountedSources {
	m := &mountedSources{own: map[string]bool{}, entries: map[string]any{}, edges: map[string]string{}}
	switch o := own.(type) {
	case map[string]any:
		for k := range o {
			m.own[k] = true
		}
	case map[string]DataSource:
		for k := range o {
			m.own[k] = true
		}
	}
	return m
}

// add contributes one mount's entry, carried up through edge.
func (m *mountedSources) add(name string, entry any, edge string) error {
	if m == nil || m.own[name] {
		return nil
	}
	prev, seen := m.entries[name]
	if !seen {
		m.entries[name] = entry
		m.edges[name] = edge
		return nil
	}
	if jsonValuesEqual(prev, entry) {
		return nil
	}
	return newETErr(codeDataSourceMergeConflict, fmt.Sprintf(
		"data source '%s' is contributed by two mounts with different entries — %s and %s — after url_substitutions and location resolution (esm-spec §4.7 \"A mounted document's data sources\"). Give them different names, bind them alike, or declare '%s' in the mounting document to override both",
		name, m.edges[name], edge, name))
}

// jsonValuesEqual is structural JSON equality: objects member by member
// regardless of order, arrays element by element, numbers by value (an
// integer token equals the same value written as a float).
func jsonValuesEqual(a, b any) bool {
	if x, ok := jsonNumberValue(a); ok {
		y, ok := jsonNumberValue(b)
		return ok && x == y
	}
	switch x := a.(type) {
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, xv := range x {
			yv, ok := y[k]
			if !ok || !jsonValuesEqual(xv, yv) {
				return false
			}
		}
		return true
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !jsonValuesEqual(x[i], y[i]) {
				return false
			}
		}
		return true
	default:
		return a == b
	}
}

func jsonNumberValue(v any) (float64, bool) {
	switch n := v.(type) {
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}

// mergeMountedDataSources merges what a document's mounts contributed into its
// raw `data_sources`; the document's own entry wins a name clash.
func mergeMountedDataSources(view map[string]any, mounted *mountedSources) {
	if mounted == nil || len(mounted.entries) == 0 {
		return
	}
	own, ok := view["data_sources"].(map[string]any)
	if !ok {
		own = map[string]any{}
		view["data_sources"] = own
	}
	for k, v := range mounted.entries {
		if _, taken := own[k]; !taken {
			own[k] = v
		}
	}
}

// mergeMountedDataSourcesTyped is mergeMountedDataSources onto a typed root
// document (the post-decode resolver path a remote `{ref}` takes).
func mergeMountedDataSourcesTyped(file *ESMFile, mounted *mountedSources) error {
	if mounted == nil || len(mounted.entries) == 0 {
		return nil
	}
	if file.DataSources == nil {
		file.DataSources = map[string]DataSource{}
	}
	for _, k := range sortedKeys(mounted.entries) {
		if _, taken := file.DataSources[k]; taken {
			continue
		}
		b, err := json.Marshal(mounted.entries[k])
		if err != nil {
			return fmt.Errorf("mounted data_sources.%s: %w", k, err)
		}
		var ds DataSource
		if err := json.Unmarshal(b, &ds); err != nil {
			return fmt.Errorf("mounted data_sources.%s: %w", k, err)
		}
		file.DataSources[k] = ds
	}
	return nil
}

// seedEdgeBindings fills, into an edge's `bindings`, the values the leaf sees
// from above for the names the leaf DECLARES (decls is its raw
// `metaparameters` block): the loader-API bindings (§9.7.6 site 4) overlaid by
// the bindings forwarded to this edge through an assembly (esm-spec §4.7
// "Bindings reach through an assembly"), the forwarded value winning. An
// explicit edge binding already in `bindings` wins over both. A name the leaf
// does not declare is never handed to it.
func seedEdgeBindings(bindings map[string]int64, decls any, apiMeta, forwarded map[string]int64) {
	declared, ok := decls.(map[string]any)
	if !ok {
		return
	}
	for _, layer := range []map[string]int64{forwarded, apiMeta} {
		for name, v := range layer {
			if _, isDecl := declared[name]; !isDecl {
				continue
			}
			if _, bound := bindings[name]; bound {
				continue
			}
			bindings[name] = v
		}
	}
}

// forwardBindingsThroughMounts returns the forwarded bindings the leaf's OWN
// mount edges receive (esm-spec §4.7 "Bindings reach through an assembly"),
// and the metaparameters documents the leaf mounts declare (at any depth; nil
// when the walk was not needed). Both mount forms call it, from
// resolveSubsystemMap.
//
// explicit is the edge's own `bindings`; forwarded is what reached this edge
// through an enclosing assembly. The result is
//
//	{forwarded entries whose name the leaf does NOT declare}
//	∪ {explicit entries whose name the leaf does not declare but a document
//	   in its mount tree does}   (these override)
//
// so a forwarded binding stops at the first document on each mount path that
// declares its name: that document consumes it and does not pass it on, and a
// document below it that declares the name again keeps its own edge's binding
// or its default. The loader-API bindings are NOT part of this map: they reach
// every depth (§9.7.6 site 4) and travel beside it unchanged. An explicit name
// declared nowhere in the mount tree is not forwarded and stays
// `template_import_unknown_name` at the edge that wrote it. Read off the
// AUTHORED leaf, before its mounts are inlined.
func forwardBindingsThroughMounts(view map[string]any, baseDir string, explicit, forwarded map[string]int64) (map[string]int64, map[string]bool) {
	decls, _ := view["metaparameters"].(map[string]any)
	out := map[string]int64{}
	for k, v := range forwarded {
		if _, ok := decls[k]; !ok {
			out[k] = v
		}
	}
	var undeclared []string
	for _, k := range sortedKeys(explicit) {
		if _, ok := decls[k]; !ok {
			undeclared = append(undeclared, k)
		}
	}
	if len(undeclared) == 0 {
		return out, nil
	}
	mountDeclared := collectMountDeclaredMetaparameters(view, baseDir)
	for _, k := range undeclared {
		if mountDeclared[k] {
			out[k] = explicit[k]
		}
	}
	return out, mountDeclared
}
