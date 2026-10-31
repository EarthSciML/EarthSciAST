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
	collectMountDeclaredInto(out, map[string]bool{}, view, baseDir, false)
	return out
}

// collectImportReachableMetaparameters is collectMountDeclaredMetaparameters
// plus the §9.7.2 `expression_template_imports` edges, at the document and the
// component level, transitively.
//
// A DIFFERENT question from the mount one, and only checkDataSourceExtents asks
// it: a metaparameter an imported library declares and the edge leaves unbound
// is RE-EXPORTED into this document's own scope (§9.7.6 site 2), so the loader
// API may bind it here — which the site-4 check already allows, because by the
// time it runs the re-export has joined the document's declared set. The static
// `extent` check runs on the AUTHORED tree, before any of that, so it has to
// reach the same names by walking. It must NOT widen the site-4 check itself: a
// name an import edge BINDS is consumed rather than re-exported, and site 4 is
// right to refuse it.
func collectImportReachableMetaparameters(view map[string]any, baseDir string) map[string]bool {
	out := map[string]bool{}
	collectMountDeclaredInto(out, map[string]bool{}, view, baseDir, true)
	return out
}

func collectMountDeclaredInto(out, seen map[string]bool, view map[string]any, baseDir string, followImports bool) {
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
		collectMountDeclaredInto(out, seen, child, childBase, followImports)
	}
	// The §9.7.2 import edges one scope carries, when asked for.
	visitImports := func(holder map[string]any) {
		if !followImports {
			return
		}
		entries, ok := holder["expression_template_imports"].([]any)
		if !ok {
			return
		}
		for _, entry := range entries {
			visitRef(entry)
		}
	}
	// A `subsystems` map to any depth: an INLINE entry may itself hold the
	// `{ref}` mount whose leaf declares the name.
	var visitSubsystems func(holder map[string]any)
	visitSubsystems = func(holder map[string]any) {
		subs, ok := holder["subsystems"].(map[string]any)
		if !ok {
			return
		}
		for _, subRaw := range subs {
			sub, ok := subRaw.(map[string]any)
			if !ok {
				continue
			}
			// A `subsystems.<k>` {ref}.
			visitRef(sub)
			visitImports(sub)
			visitSubsystems(sub)
		}
	}
	visitImports(view) // a DOCUMENT-level `expression_template_imports`
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
			visitImports(comp)
			visitSubsystems(comp)
		}
	}
}

// documentHasUnresolvedMount reports whether `view` still carries an unresolved
// §4.7 mount — a top-level `models.<k>` / `reaction_systems.<k>` `{ref}` or a
// `subsystems.<k>` `{ref}`.
func documentHasUnresolvedMount(view map[string]any) bool {
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
			if _, ok := comp["ref"]; ok {
				return true
			}
			if subs, ok := comp["subsystems"].(map[string]any); ok {
				for _, subRaw := range subs {
					sub, ok := subRaw.(map[string]any)
					if !ok {
						continue
					}
					if _, ok := sub["ref"]; ok {
						return true
					}
				}
			}
		}
	}
	return false
}

// indexSetsAreFullyFolded reports whether `view` declares at least one index set
// and every interval `size` in the registry is already a concrete integer — the
// state a document reaches only after its metaparameters have closed and folded.
// Requiring at least one entry keeps the vacuous case (no `index_sets` at all,
// where nothing has been folded) on the checked path.
func indexSetsAreFullyFolded(view map[string]any) bool {
	isets, ok := view["index_sets"].(map[string]any)
	if !ok || len(isets) == 0 {
		return false
	}
	for _, declRaw := range isets {
		decl, ok := declRaw.(map[string]any)
		if !ok {
			continue
		}
		size, present := decl["size"]
		if !present || size == nil {
			continue
		}
		if _, ok := asInt64Strict(size); !ok {
			return false
		}
	}
	return true
}

// documentIsInResolvedShape reports whether `view` is in the shape only a
// RESOLVED document has: no unresolved §4.7 mount left, and at least one index
// set with every interval `size` already a concrete integer.
//
// checkDataSourceExtents is an AUTHORING check and has to stay idempotent. A
// §4.7 mount CONSUMES the leaf's `metaparameters` (§9.7.6 site 3), so once a
// document has been resolved, a name only the leaf declared is declared nowhere
// and the `{ref}` stub the mount walk reads is gone — while the `extent` that
// named it is still there, having already done its job. A binding that re-loads
// its own resolved document (Rust does, at build) must not be told that document
// is invalid. esm-spec §8.9.4 states the exemption normatively, so all five
// bindings answer the same document the same way.
func documentIsInResolvedShape(view map[string]any) bool {
	return !documentHasUnresolvedMount(view) && indexSetsAreFullyFolded(view)
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
	if err := checkDataSourceExtents(view, baseDir, mountDeclared); err != nil {
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
func checkDataSourceExtents(view map[string]any, baseDir string, mountDeclared map[string]bool) error {
	sources, ok := view["data_sources"].(map[string]any)
	if !ok {
		return nil
	}
	if documentIsInResolvedShape(view) {
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
	var reachable map[string]bool
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
		// Widened LAZILY, only for a name about to be refused: a metaparameter
		// an imported library declares and the edge leaves unbound is
		// RE-EXPORTED into this document's scope (§9.7.6 site 2) and is a
		// perfectly good loader-API binding target — but this check runs on the
		// AUTHORED tree, before the imports resolve, so it has to walk for it. A
		// conforming document pays nothing: the walk runs only on the path that
		// would otherwise fail.
		if reachable == nil {
			reachable = collectImportReachableMetaparameters(view, baseDir)
		}
		if reachable[name] {
			continue
		}
		return newETErr(CodeTemplateImportUnknownName,
			fmt.Sprintf("data_sources.%s.extent binds metaparameter '%s', which neither this document nor any document it mounts declares (esm-spec §8.9.4, §9.7.6)", key, name))
	}
	return nil
}
