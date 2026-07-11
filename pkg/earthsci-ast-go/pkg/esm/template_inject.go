package esm

import (
	"fmt"
	"sort"
	"strings"
)

// ===================================================================
// Scope-directed template injection (esm-spec §9.7.10)
//
// The consuming surface — a §4.7 subsystem-ref edge (form A), a §10 coupling
// entry (form B), or a §6.6/§6.7 test/example (form C) — may register imports
// into a TARGET component's own scope without editing the leaf. Forms A/B are
// applied at the raw-view level BEFORE resolveTemplateMachinery: each widens
// the target component's `expression_template_imports` in the §9.7.10 merge
// order (the target's own imports first, then the injected list), so the
// ordinary import resolver + §9.6.3 fixpoint lower the target's rewrite-targets
// with no engine change. Form A is threaded through subsystem-ref resolution
// (subsystem_ref.go); form B runs on the root view inside resolveAndLowerJSON.
// Form C survives parse → emit as authored per-run config (the Test / Example
// typed field) and is consumed only by an ephemeral per-run build — which this
// binding does not perform (no numeric PDE solver). Mirrors the Julia reference
// EarthSciAST.jl/src/template_imports.jl.
// ===================================================================

// appendComponentImports appends raw §9.7.2 import entries to a component's own
// `expression_template_imports` (esm-spec §9.7.10 merge order: the target's own
// imports first, then the injected list). `comp` is a mutable raw view.
func appendComponentImports(comp map[string]any, imports []any) {
	var base []any
	if existing, ok := comp["expression_template_imports"].([]any); ok {
		base = append(base, existing...)
	}
	base = append(base, imports...)
	comp["expression_template_imports"] = base
}

// applySubsystemRefInjection performs esm-spec §9.7.10 form A: append the
// subsystem-ref edge's injected §9.7.2 import entries to the single top-level
// component's own `expression_template_imports`, so the referenced document is
// lowered under the assembler-chosen discretization. `view` is the referenced
// file's mutable raw view; a §4.7 subsystem file holds exactly one top-level
// model or reaction system, which is the implicit target. A data-loader-only
// referenced file has no expression positions, so the injection finds no home
// and the mount fails cleanly downstream. Mirrors the Julia reference
// `_apply_subsystem_ref_injection!`.
func applySubsystemRefInjection(view map[string]any, injected []any) {
	if len(injected) == 0 {
		return
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok || len(comps) == 0 {
			continue
		}
		// Exactly one component (§4.7); sortedKeys makes the pick deterministic.
		for _, cname := range sortedKeys(comps) {
			comp, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			appendComponentImports(comp, injected)
			return
		}
	}
}

// couplingReferencedSystems collects, for one coupling entry, the set of system
// names it references (esm-spec §10.8): `operator_compose`/`couple` → members of
// `systems`; `variable_map` → the owning systems of `from`/`to`; `event` →
// owning systems of any scoped reference in the entry. A `callback` references
// none. Mirrors the Julia reference `_coupling_referenced_systems`.
func couplingReferencedSystems(entry map[string]any) map[string]bool {
	out := map[string]bool{}
	ctype, _ := entry["type"].(string)
	switch ctype {
	case "operator_compose", "couple":
		if sys, ok := entry["systems"].([]any); ok {
			for _, s := range sys {
				ss, ok := s.(string)
				if !ok {
					continue
				}
				out[ss] = true
				out[strings.SplitN(ss, ".", 2)[0]] = true
			}
		}
	case "variable_map":
		for _, k := range []string{"from", "to"} {
			if v, ok := entry[k].(string); ok {
				out[strings.SplitN(v, ".", 2)[0]] = true
			}
		}
	case "event":
		collectScopedOwners(out, entry)
	}
	return out
}

// collectScopedOwners walks `x` and adds the owning-system segment of every
// scoped reference (a string of the form "System.var") to `out`. Used for
// `event` entries whose system references are spread across conditions/affects.
// Mirrors the Julia reference `_collect_scoped_owners!`.
func collectScopedOwners(out map[string]bool, x any) {
	switch v := x.(type) {
	case string:
		if strings.Contains(v, ".") {
			out[strings.SplitN(v, ".", 2)[0]] = true
		}
	case map[string]any:
		for _, c := range v {
			collectScopedOwners(out, c)
		}
	case []any:
		for _, c := range v {
			collectScopedOwners(out, c)
		}
	}
}

// applyCouplingInjections performs esm-spec §9.7.10 form B / §10.8: for each
// `coupling` entry carrying an `expression_template_imports` map
// `{ <target>: [imports...] }`, resolve each target key to a top-level system
// and append its imports to that system's own `expression_template_imports`
// (merge order §9.7.10). The map is consumed here (deleted from the entry) so
// form B does not survive parse → emit.
//
// Diagnostics (esm-spec §9.6.6): a key naming no system the entry references is
// `template_inject_target_unknown`; a key resolving to a data loader is
// `template_inject_target_is_loader`; a key resolving to neither model, reaction
// system, nor loader is `template_inject_target_not_component`. Only top-level
// system targets are resolved by this binding — a nested `Parent.Child` key is
// out of scope and reported as `template_inject_target_not_component`. Mirrors
// the Julia reference `_apply_coupling_injections!`.
func applyCouplingInjections(view map[string]any) error {
	coupling, ok := view["coupling"].([]any)
	if !ok {
		return nil
	}
	models, _ := view["models"].(map[string]any)
	rsystems, _ := view["reaction_systems"].(map[string]any)
	loaders, _ := view["data_loaders"].(map[string]any)
	topComp := func(d map[string]any, k string) (map[string]any, bool) {
		if d == nil {
			return nil, false
		}
		c, has := d[k]
		if !has {
			return nil, false
		}
		cm, ok := c.(map[string]any)
		return cm, ok
	}
	for _, entryRaw := range coupling {
		entry, ok := entryRaw.(map[string]any)
		if !ok {
			continue
		}
		injRaw, has := entry["expression_template_imports"]
		if !has || injRaw == nil {
			continue
		}
		inj, ok := injRaw.(map[string]any)
		if !ok {
			return newETErr("template_inject_target_not_component",
				"coupling entry `expression_template_imports` must be a map from a target system name to a list of imports (esm-spec §9.7.10 / §10.8)")
		}
		referenced := couplingReferencedSystems(entry)
		for _, tname := range sortedKeys(inj) {
			if !referenced[tname] {
				refList := "(none)"
				if len(referenced) > 0 {
					names := make([]string, 0, len(referenced))
					for n := range referenced {
						names = append(names, n)
					}
					sort.Strings(names)
					refList = strings.Join(names, ", ")
				}
				return newETErr("template_inject_target_unknown",
					fmt.Sprintf("coupling entry `expression_template_imports` key '%s' names no system referenced by that entry (esm-spec §9.7.10 / §10.8). The entry references: %s.", tname, refList))
			}
			var comp map[string]any
			if c, ok := topComp(models, tname); ok {
				comp = c
			} else if c, ok := topComp(rsystems, tname); ok {
				comp = c
			} else if _, ok := loaders[tname]; ok {
				return newETErr("template_inject_target_is_loader",
					fmt.Sprintf("coupling entry `expression_template_imports` key '%s' resolves to a data loader, which is pure I/O with no expression positions to rewrite (esm-spec §9.7.10 / §14).", tname))
			} else {
				return newETErr("template_inject_target_not_component",
					fmt.Sprintf("coupling entry `expression_template_imports` key '%s' resolves to neither a top-level model, reaction system, nor data loader (esm-spec §9.7.10). Nested `Parent.Child` targets are out of scope.", tname))
			}
			importsList, ok := inj[tname].([]any)
			if !ok {
				return newETErr("template_import_not_library",
					fmt.Sprintf("coupling entry `expression_template_imports` value for '%s' must be a list of §9.7.2 import entries (esm-spec §9.7.10 / §10.8).", tname))
			}
			appendComponentImports(comp, importsList)
		}
		delete(entry, "expression_template_imports")
	}
	return nil
}
