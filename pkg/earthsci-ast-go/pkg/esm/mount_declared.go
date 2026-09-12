package esm

import (
	"fmt"
)

// collectMountDeclaredMetaparameters returns the metaparameter names declared by
// every document `view` MOUNTS (esm-spec §4.7), transitively through the mount
// DAG.
//
// A §4.7 mount edge CONSUMES the referenced document's `metaparameters` at the
// edge (§9.7.6 binding site 3), so those names never reach the mounting
// document's own declared set — which is why a loader-API binding for one of
// them used to be refused at a root that had no reason to redeclare it. This
// walk is what lets the site-4 check (and the §8.9.4 `extent` check) ask "does
// ANYONE in this assembly declare that name?" instead of "does the root".
//
// Both §4.7 mount forms are read: the `subsystems.<k>` `{ref}` entries this
// binding implements, and the top-level `models.<k>` / `reaction_systems.<k>`
// `{ref}` form it does not (the schema admits it, and reading it costs nothing
// but keeps the ACCEPTANCE side forward-compatible with a binding that mounts
// it). Reading is all that happens here — nothing is mounted.
//
// Only each referenced file's top-level `metaparameters` keys are read. A ref
// that cannot be read, parsed, or is not an object is IGNORED: this walk exists
// to WIDEN acceptance, and the resolution error belongs to the ref resolver,
// which reports it with the proper mount pointer and diagnostic code. Cycles
// terminate on `seen`, keyed by the canonical ref identity.
func collectMountDeclaredMetaparameters(view map[string]any, baseDir string) map[string]bool {
	out := map[string]bool{}
	collectMountDeclaredInto(out, map[string]bool{}, view, baseDir)
	return out
}

func collectMountDeclaredInto(out, seen map[string]bool, view map[string]any, baseDir string) {
	if view == nil {
		return
	}
	visitRef := func(value any) {
		m, ok := value.(map[string]any)
		if !ok {
			return
		}
		ref, ok := m["ref"].(string)
		if !ok {
			return
		}
		key := canonicalImportRef(ref, baseDir)
		if seen[key] {
			return
		}
		seen[key] = true
		data, childBase, err := loadRefBytes(ref, baseDir)
		if err != nil {
			return
		}
		child, err := decodeJSONView(data)
		if err != nil {
			return
		}
		if decls, ok := child["metaparameters"].(map[string]any); ok {
			for name := range decls {
				out[name] = true
			}
		}
		collectMountDeclaredInto(out, seen, child, childBase)
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			comp, ok := compRaw.(map[string]any)
			if !ok {
				continue
			}
			// A top-level `models.<k>` / `reaction_systems.<k>` {ref}.
			visitRef(comp)
			if subs, ok := comp["subsystems"].(map[string]any); ok {
				for _, sub := range subs {
					// A `subsystems.<k>` {ref}.
					visitRef(sub)
				}
			}
		}
	}
}

// documentDeclaresAnExtent reports whether any `data_sources` entry carries an
// object-valued `extent` (esm-spec §8.9.4).
//
// The cheap guard on the mount walk above. The widened §9.7.6 site-4 check and
// the §8.9.4 `extent` check are its only callers, and neither can matter unless
// the load either carries loader-API bindings or the document declares an
// `extent`. Without the guard the walk would READ every mounted ref on every
// load — including fetching a remote `{ref}` the ref resolver then fetches
// again — so the ordinary path is left byte-for-byte unchanged in behaviour and
// in I/O.
func documentDeclaresAnExtent(view map[string]any) bool {
	sources, ok := view["data_sources"].(map[string]any)
	if !ok {
		return false
	}
	for _, srcRaw := range sources {
		src, ok := srcRaw.(map[string]any)
		if !ok {
			continue
		}
		if _, ok := src["extent"].(map[string]any); ok {
			return true
		}
	}
	return false
}

// rootMountContext is the §4.7 mount context of a ROOT document: the
// mount-declared metaparameter set (guarded, see documentDeclaresAnExtent) and
// the §8.9.4 static `extent` check run against it.
//
// Every root load path goes through here, so the two halves cannot drift apart:
// the check must see the same widened declared set the site-4 check will see,
// or an `extent` would be refused here and accepted there.
func rootMountContext(view map[string]any, baseDir string, metaparameters map[string]int64) (map[string]bool, error) {
	mountDeclared := map[string]bool{}
	if len(metaparameters) > 0 || documentDeclaresAnExtent(view) {
		mountDeclared = collectMountDeclaredMetaparameters(view, baseDir)
	}
	if err := checkDataSourceExtents(view, mountDeclared); err != nil {
		return nil, err
	}
	return mountDeclared, nil
}

// checkDataSourceExtents enforces esm-spec §8.9.4: every
// `data_sources.<k>.extent.metaparameter` MUST name a metaparameter this
// document declares, or one a document it mounts declares.
//
// A discovered extent is a §9.7.6 site-4 loader-API binding, and "binding an
// unknown name is an error" — but that error could only be raised once the
// source had been SAMPLED, which happens at build. So an `extent` naming a
// metaparameter nobody declares validated clean and failed only when the file
// was finally read, with a diagnostic about the loader API rather than about the
// typo. The condition is decidable from the document alone, so it is decided at
// load: `template_import_unknown_name`, the code §9.7.6 already gives an unknown
// name at a binding site — NOT a new code.
//
// This half of §8.9.4 is fully reachable in Go even though extent DISCOVERY is
// not: nothing here samples a source.
func checkDataSourceExtents(view map[string]any, mountDeclared map[string]bool) error {
	sources, ok := view["data_sources"].(map[string]any)
	if !ok {
		return nil
	}
	declared := map[string]bool{}
	if decls, ok := view["metaparameters"].(map[string]any); ok {
		for name := range decls {
			declared[name] = true
		}
	}
	for name := range mountDeclared {
		declared[name] = true
	}
	// Sorted so a document with several bad extents fails deterministically.
	for _, key := range sortedKeys(sources) {
		src, ok := sources[key].(map[string]any)
		if !ok {
			continue
		}
		extent, ok := src["extent"].(map[string]any)
		if !ok {
			continue
		}
		name, ok := extent["metaparameter"].(string)
		if !ok || declared[name] {
			continue
		}
		return newETErr(CodeTemplateImportUnknownName,
			fmt.Sprintf("data_sources.%s.extent binds metaparameter '%s', which neither this document nor any document it mounts declares (esm-spec §8.9.4, §9.7.6)", key, name))
	}
	return nil
}
