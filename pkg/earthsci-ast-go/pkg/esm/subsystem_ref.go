package esm

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// ResolveSubsystemRefs walks all subsystem maps in models and reaction systems,
// resolving any entries that contain a "ref" field by loading and inlining the
// referenced ESM file content.
//
// Resolution rules:
//   - If ref starts with http:// or https://, fetch the file over HTTP.
//   - Otherwise, the ref is resolved as a local file path relative to basePath.
//   - Referenced files are parsed recursively, so nested refs are resolved.
//   - Circular references are detected and reported as errors.
//
// The function modifies file in-place, replacing reference objects with the
// resolved model or reaction system content.
func ResolveSubsystemRefs(file *ESMFile, basePath string) error {
	return resolveSubsystemRefsWithMeta(file, basePath, nil)
}

// resolveSubsystemRefsWithMeta is ResolveSubsystemRefs threaded with the
// MOUNTING document's already-closed metaparameter environment (esm-spec §9.7.6
// binding site 3). A §4.7 subsystem ref is resolved as a complete document and
// folded to concrete integers at the mount, so each edge binding VALUE (a
// metaparameter expression, e.g. `NTGT = NX*NY`) folds IMMEDIATELY against this
// environment — unlike an import edge, whose values are carried symbolically.
// Load computes the root document's environment (declared defaults overlaid
// with the loader-API bindings) and passes it here BEFORE the root's
// metaparameters are consumed by the template-machinery resolver. Direct
// callers (which have no mounting metaparameters) pass nil.
func resolveSubsystemRefsWithMeta(file *ESMFile, basePath string, parentMeta map[string]int64) error {
	visited := make(map[string]bool)
	// The importing document's index_sets registry (esm-spec §4.7): a mounted
	// subsystem file's top-level index_sets merge into it, so a mounted mesh's
	// axes join the importer and a size disagreement fails loudly. Initialize an
	// empty registry so a mount can bring axes into a host that declares none.
	if file.IndexSets == nil {
		file.IndexSets = map[string]IndexSet{}
	}
	return resolveSubsystemRefsInternal(file, basePath, visited, file.IndexSets, parentMeta)
}

// resolveSubsystemRefsInternal is the recursive implementation that tracks
// visited paths for circular reference detection and threads the importing
// document's index_sets registry (esm-spec §4.7 index-set merge) and its closed
// metaparameter environment (esm-spec §9.7.6 binding site 3).
func resolveSubsystemRefsInternal(file *ESMFile, basePath string, visited map[string]bool, registry map[string]IndexSet, parentMeta map[string]int64) error {
	// Top-level `models.<k>` mount edges FIRST: the component each one splices in
	// may itself carry `subsystems`, and the walk below is what resolves those.
	if err := inlineTopLevelModelRefs(file, basePath, visited, registry, parentMeta); err != nil {
		return err
	}

	// Resolve subsystems in models. model.Subsystems is a map (reference type)
	// that resolveSubsystemMap mutates in place, so no write-back of the Model
	// struct into file.Models is needed.
	for modelName, model := range file.Models {
		prefix := fmt.Sprintf("/models/%s/subsystems", modelName)
		if err := resolveSubsystemMap(model.Subsystems, basePath, visited, registry, parentMeta, prefix, subsystemMount); err != nil {
			return fmt.Errorf("model %q subsystems: %w", modelName, err)
		}
	}

	// Resolve subsystems in reaction systems (rs.Subsystems is likewise mutated
	// in place).
	for rsName, rs := range file.ReactionSystems {
		prefix := fmt.Sprintf("/reaction_systems/%s/subsystems", rsName)
		if err := resolveSubsystemMap(rs.Subsystems, basePath, visited, registry, parentMeta, prefix, subsystemMount); err != nil {
			return fmt.Errorf("reaction_system %q subsystems: %w", rsName, err)
		}
	}

	return nil
}

// extractTopLevelModelRefEdges snapshots every top-level `models.<k>` MOUNT
// EDGE out of a document's JSON text, keyed by mount name.
//
// An entry is a mount edge when it carries a `ref` STRING and no inline
// `variables` — the same test Rust and Python apply to the `oneOf [Model,
// SubsystemRef]` union the schema gives `models.<k>`. A component that merely
// happens to carry a `ref`-named field is not a mount.
//
// Returns nil for the common document with no such mount, so the resolver's
// fast path is a nil-map length check.
func extractTopLevelModelRefEdges(jsonStr string) map[string]map[string]any {
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return nil
	}
	models, ok := view["models"].(map[string]any)
	if !ok {
		return nil
	}
	var out map[string]map[string]any
	for name, raw := range models {
		entry, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if _, isString := entry["ref"].(string); !isString {
			continue
		}
		if _, inline := entry["variables"]; inline {
			continue
		}
		if out == nil {
			out = map[string]map[string]any{}
		}
		out[name] = entry
	}
	return out
}

// inlineTopLevelModelRefs inlines every top-level `models.<k>` MOUNT EDGE — a
// bare `{ref}` entry — by resolving the referenced leaf IN ITS OWN SCOPE and
// splicing in its single model under the mount key.
//
// esm-spec §4.7 "Two mount forms, one mechanism": a top-level `models.<k>`
// `{ref}` and a `subsystems.<k>` `{ref}` "differ only in where the mounted
// component lands", and a binding MUST NOT make them differ otherwise. So there
// is no second edge pipeline here. Each edge goes to resolveSubsystemMap — the
// one implementation in this binding — through a one-entry holder map, which
// runs the normative order: the leaf resolves in its own scope (library gates,
// this edge's `bindings` and §9.7.10 injection, its metaparameter close and
// fold, the §9.6.3 fixpoint), then this edge's `index_set_rename` applies to the
// resolved leaf, then the renamed `index_sets` merge into `registry`
// deep-equal-or-`subsystem_index_set_conflict`, then the leaf's own nested
// mounts resolve in the leaf's directory so the merge composes transitively.
//
// What the top-level form adds is what §4.7 says it adds: the component lands as
// a TOP-LEVEL system of the assembling document under the mount key — which is
// what lets a coupled document name its components by file and have
// `<key>.<var>` coupling endpoints resolve with no rewriting — and its inline
// `tests` are dropped, because a test asserts something about the leaf under the
// leaf's OWN standalone conditions and this document may couple it (§6.6).
//
// The edges arrive as the raw JSON LoadString captured before the typed decode:
// `ESMFile.Models` is a `map[string]Model`, so a bare `{ref}` entry decodes to an
// EMPTY Model and the mount would otherwise be lost outright. Resolving them
// HERE rather than on that raw text is what keeps this form on the same side of
// the root document's §9.7.6 close as the `subsystems.<k>` form: both merge into
// `file.IndexSets`, whose sizes the root close has already folded to integers.
// That is "MUST NOT make them differ" applied to merge ORDER, not just to the
// pipeline — merging a leaf's folded axis against an unfolded importer
// declaration is the fold-before-merge collision issue #198 reported.
func inlineTopLevelModelRefs(file *ESMFile, basePath string, visited map[string]bool,
	registry map[string]IndexSet, parentMeta map[string]int64) error {
	if len(file.topLevelModelRefs) == 0 {
		return nil
	}
	if file.Models == nil {
		file.Models = map[string]Model{}
	}
	for _, name := range sortedKeys(file.topLevelModelRefs) {
		edge := file.topLevelModelRefs[name]
		ref, _ := edge["ref"].(string)
		holder := map[string]any{name: edge}
		if err := resolveSubsystemMap(holder, basePath, visited, registry, parentMeta,
			"/models", topLevelModelMount); err != nil {
			return err
		}
		resolvedRaw, ok := holder[name].(map[string]any)
		if !ok {
			return newETErr(CodeUnresolvedSubsystemRef, fmt.Sprintf(
				"top-level model %q: ref %q did not resolve to a component (esm-spec §4.7)",
				name, ref))
		}
		// A top-level `models.<k>` mount must land a MODEL. A reaction system is
		// a component, and a `subsystems.<k>` edge may mount one, but splicing one
		// under `models` would make that block hold two different component kinds
		// under one key space. `variables` is the positive test: the schema makes
		// it required of a Model and absent from a ReactionSystem.
		if _, isModel := resolvedRaw["variables"]; !isModel {
			return newETErr(CodeAmbiguousSubsystemRef, fmt.Sprintf(
				"top-level model %q: ref %q resolves to a component that is not a model; "+
					"a models.<k> mount requires exactly one top-level model (esm-spec §4.7)",
				name, ref))
		}
		// esm-spec §6.6: inline tests do NOT cross a mount edge. Dropped on the
		// RAW map, before the typed decode below, so a leaf's tests are not
		// merely discarded but never interpreted — this document is not the one
		// that gets to say whether they are well-formed.
		delete(resolvedRaw, "tests")
		b, err := json.Marshal(resolvedRaw)
		if err != nil {
			return fmt.Errorf("top-level model %q: re-encoding resolved ref %q: %w", name, ref, err)
		}
		var model Model
		if err := json.Unmarshal(b, &model); err != nil {
			return fmt.Errorf("top-level model %q: decoding resolved ref %q: %w", name, ref, err)
		}
		// The decode above leaves json.Number tokens in every Expression slot,
		// exactly as the document-level decode does; LoadString's own
		// normalizeNumericLiterals has already run by the time refs resolve, so
		// this component needs its own pass (RFC §5.4.6 int/float round-trip).
		normalizeModelLiterals(&model)
		file.Models[name] = model
		// The edge is CONSUMED. What remains in topLevelModelRefs is the set of
		// mounts nobody has resolved yet, which is what the serializer writes
		// back out (restoreUnresolvedTopLevelMounts) and what makes a second
		// ResolveSubsystemRefs call a no-op instead of a redundant re-resolve.
		delete(file.topLevelModelRefs, name)
	}
	return nil
}

// inlineNestedTopLevelModelRefs inlines every top-level `models.<k>` MOUNT EDGE
// that a MOUNTED document carries of its own, in that document's own directory
// (esm-spec §4.7 "Two mount forms, one mechanism": the top-level form composes
// with itself, because the component it lands is a top-level system and a
// top-level system is what the form mounts).
//
// The edges go through resolveSubsystemMap — the one edge-pipeline
// implementation in this binding — under the top-level mount form, so each
// nested leaf gets the same normative order, the same diagnostics, and the same
// `visited` path-scoped cycle set the root's edges get. That recursion re-enters
// this function for ITS leaf, so a chain of any depth composes.
//
// esm-spec §6.6: a mounted component's inline `tests` do not cross a mount edge,
// at any depth — dropped here on the raw map for the same reason the root's
// inliner drops them, so the leaf's assertions are never interpreted by a
// document that may go on to couple it.
func inlineNestedTopLevelModelRefs(view map[string]any, basePath string, visited map[string]bool,
	registry map[string]IndexSet, parentMeta map[string]int64, pathPrefix string) error {
	models, ok := view["models"].(map[string]any)
	if !ok || len(models) == 0 {
		return nil
	}
	edges := map[string]any{}
	for _, name := range sortedKeys(models) {
		entry, ok := models[name].(map[string]any)
		if !ok {
			continue
		}
		if _, isString := entry["ref"].(string); !isString {
			continue
		}
		if _, inline := entry["variables"]; inline {
			continue
		}
		edges[name] = entry
	}
	if len(edges) == 0 {
		return nil
	}
	if err := resolveSubsystemMap(edges, basePath, visited, registry, parentMeta,
		pathPrefix, topLevelModelMount); err != nil {
		return err
	}
	for name, resolved := range edges {
		if m, ok := resolved.(map[string]any); ok {
			delete(m, "tests")
		}
		models[name] = resolved
	}
	return nil
}

// indexSetDeepEqual is the §4.7 / §9.7.5 idempotent-redeclaration test: two
// IndexSet declarations are deep-equal iff they marshal to identical canonical
// JSON (Go sorts object keys, and integer tokens — json.Number / int / float —
// all render identically), so a redeclaration with the same kind/size/members/…
// dedups while any field disagreement is a conflict.
func indexSetDeepEqual(a, b IndexSet) bool {
	ab, err1 := json.Marshal(a)
	bb, err2 := json.Marshal(b)
	return err1 == nil && err2 == nil && bytes.Equal(ab, bb)
}

// showIndexSet renders an index-set declaration on one line —
// `kind=interval, size=59` — so the §4.7 collision diagnostic names both
// definitions rather than only the axis they disagree about. Mirrors the Julia
// `_index_set_show` and the Python `_index_set_show`.
func showIndexSet(s IndexSet) string {
	parts := []string{fmt.Sprintf("kind=%s", s.Kind)}
	if s.Size != nil {
		parts = append(parts, fmt.Sprintf("size=%d", *s.Size))
	}
	if len(s.Members) > 0 {
		parts = append(parts, fmt.Sprintf("members=%v", s.Members))
	}
	if len(s.Of) > 0 {
		parts = append(parts, fmt.Sprintf("of=%v", s.Of))
	}
	if s.FromFAQ != nil {
		parts = append(parts, fmt.Sprintf("from_faq=%s", *s.FromFAQ))
	}
	return strings.Join(parts, ", ")
}

// mergeSubsystemIndexSets merges a referenced subsystem file's (already
// metaparameter-folded) top-level `index_sets` into the importing document's
// registry (esm-spec §4.7, mirroring the §9.7.5 template-import merge).
// Deep-equal redeclaration is idempotent; a non-equal collision is the
// load-time error `subsystem_index_set_conflict` (§9.6.6) — the mounted-mesh
// failure mode this makes loud. Mirrors the Julia reference
// `_merge_subsystem_index_sets!`.
func mergeSubsystemIndexSets(registry map[string]IndexSet, view map[string]any, ref string) error {
	isetsRaw, ok := view["index_sets"].(map[string]any)
	if !ok {
		return nil
	}
	for _, n := range sortedKeys(isetsRaw) {
		b, err := json.Marshal(isetsRaw[n])
		if err != nil {
			return fmt.Errorf("subsystem index set %q from ref %q: %w", n, ref, err)
		}
		var decl IndexSet
		if err := json.Unmarshal(b, &decl); err != nil {
			return fmt.Errorf("subsystem index set %q from ref %q: %w", n, ref, err)
		}
		if existing, has := registry[n]; has {
			if !indexSetDeepEqual(existing, decl) {
				return newETErr(CodeSubsystemIndexSetConflict,
					fmt.Sprintf("index set '%s' from subsystem ref '%s' (%s) collides with a non-deep-equal declaration already in the importing document's registry (%s) — contributed by the document's own `index_sets` or by an earlier mount (subsystem index_sets merge into the importing registry; deep-equal redeclaration is idempotent, a size/kind disagreement is a load-time error — esm-spec §4.7). If the two are genuinely different axes that happen to share a name, rename one at its mount edge with `index_set_rename` (esm-spec §4.7 \"Mount-edge index-set renaming\"), e.g. {\"ref\": \"%s\", \"index_set_rename\": {\"%s\": \"%s_2\"}}", n, ref, showIndexSet(decl), showIndexSet(existing), ref, n, n))
			}
			continue
		}
		registry[n] = decl
	}
	return nil
}

// mountForm names which of esm-spec §4.7's two attachment points a `{ref}` mount
// edge sits at: a `subsystems.<k>` entry, or a top-level `models.<k>` entry.
//
// "Two mount forms, one mechanism" — the forms differ ONLY in where the mounted
// component lands, and a binding MUST NOT make them differ otherwise. So this
// steers diagnostic wording and nothing else: both forms run resolveSubsystemMap,
// which is the one implementation of the §4.7 edge pipeline in this binding.
type mountForm struct {
	// section is the document block the edge lives in, used to label the
	// §9.7.6 binding scope (`subsystems.Soil` / `models.Soil`).
	section string
	// noun names the edge in prose diagnostics ("subsystem \"Soil\"").
	noun string
}

var (
	subsystemMount     = mountForm{section: "subsystems", noun: "subsystem"}
	topLevelModelMount = mountForm{section: "models", noun: "top-level model"}
)

// resolveSubsystemMap resolves references in a single subsystems map.
// Each value in the map is either already-resolved content (left as-is) or a
// reference object with a "ref" key (resolved by loading the referenced file).
//
// The referenced document is resolved on its RAW JSON view: the esm-spec §9.7
// machinery runs first (version gates, template-library rejection —
// `subsystem_ref_is_template_library` — import resolution, and metaparameter
// close, with the edge's optional `bindings` supplying §9.7.6 binding site 3),
// then the §9.6.3 rewrite fixpoint, then nested subsystem refs recursively.
// Working on the raw view keeps full Expression fidelity (aggregate /
// makearray fields the typed ExprNode does not model survive intact).
func resolveSubsystemMap(subsystems map[string]any, basePath string, visited map[string]bool, registry map[string]IndexSet, parentMeta map[string]int64, pathPrefix string, form mountForm) (err error) {
	if len(subsystems) == 0 {
		return nil
	}

	// Attribute a JSON Pointer to whichever subsystem entry failed. pathPrefix is
	// the entry's `subsystems` container (`/models/<M>/subsystems`); currentKey is
	// the entry name being resolved. A load-phase rejection of a §4.7 ref
	// (unresolved / ambiguous) is then a structured (code, path) finding a
	// conformance producer can surface — withETPath is first-set-wins, so a nested
	// edge that already carries its own deeper pointer is left untouched.
	var currentKey string
	defer func() {
		if err != nil && currentKey != "" {
			err = withETPath(err, fmt.Sprintf("%s/%s", pathPrefix, currentKey))
		}
	}()

	// Iterate in sorted key order so a document with multiple bad refs fails
	// with a deterministic diagnostic (the rest of the package does this).
	for _, key := range sortedKeys(subsystems) {
		currentKey = key
		value := subsystems[key]
		ref, bindingsRaw, isRef := extractRefWithBindings(value)
		if !isRef {
			continue
		}

		// esm-spec §9.7.10 form A: the edge's optional `expression_template_imports`
		// inject a discretization into the REFERENCED component's own scope. Kept
		// as raw §9.7.2 entries and threaded into the referenced document's load,
		// where the §9.6.3 fixpoint lowers its rewrite-targets before the mounted
		// form is inlined (so the field does not survive parse → emit).
		var injected []any
		if m, ok := value.(map[string]any); ok {
			if inj, ok := m["expression_template_imports"].([]any); ok {
				injected = inj
			}
		}

		// The edge's metaparameter bindings (esm-spec §9.7.6 binding site 3). A
		// binding VALUE is a metaparameter expression — an integer literal, a
		// name in the MOUNTING document's metaparameter scope, or a `{op:
		// +|-|*|/, args}` tree over the same (e.g. `NTGT = NX*NY`). A subsystem
		// ref resolves as a complete document folded to concrete integers at the
		// mount, so — unlike an import edge — its values cannot be carried
		// symbolically; each folds IMMEDIATELY against the mounting document's
		// already-closed environment (parentMeta). requireMetaExpr validates the
		// structure at the edge (bad op / empty args / float → metaparameter_type_error
		// even with a symbolic arg); evalMetaExpr folds it (a free name absent
		// from parentMeta → template_import_unknown_name).
		bindings := map[string]int64{}
		for _, bk := range sortedKeys(bindingsRaw) {
			ctx := fmt.Sprintf("%s.%s: binding '%s'", form.section, key, bk)
			expr, err := requireMetaExpr(bindingsRaw[bk], ctx)
			if err != nil {
				return err
			}
			bv, err := evalMetaExpr(expr, parentMeta, ctx)
			if err != nil {
				return err
			}
			bindings[bk] = bv
		}

		data, refKey, refBasePath, err := loadSubsystemRefBytes(ref, basePath, key, visited, form)
		if err != nil {
			return err
		}

		// Decode the referenced file's raw view (UseNumber preserves the
		// int/float distinction through the §9.7 resolver).
		view, err := decodeJSONView(data)
		if err != nil {
			return fmt.Errorf("%s %q: failed to parse referenced file %q: %w", form.noun, key, refKey, err)
		}

		// Spec-version gates (esm-spec §9.6.5).
		if err := RejectExpressionTemplatesPreV04(view); err != nil {
			return err
		}
		if err := RejectTemplateImportsPreV08(view); err != nil {
			return err
		}

		// A §4.7 subsystem ref MUST NOT target a template-library file — the
		// two reference mechanisms are disjoint (esm-spec §9.7.1).
		if isTemplateLibraryDoc(view) {
			return newETErr(CodeSubsystemRefIsTemplateLibrary,
				fmt.Sprintf("%s %q: ref %q targets a template-library file (%s); libraries are imported via expression_template_imports (esm-spec §9.7.1)", form.noun, key, ref, refKey))
		}

		// Nor a coupling-library file — those are imported via a coupling_import
		// coupling entry, not a subsystem ref (esm-spec §10.9).
		if isCouplingLibraryDoc(view) {
			return newETErr(CodeSubsystemRefIsCouplingLibrary,
				fmt.Sprintf("%s %q: ref %q targets a coupling-library file (%s); libraries are imported via a coupling_import coupling entry (esm-spec §10.9)", form.noun, key, ref, refKey))
		}

		// esm-spec §9.7.10 form A: fold the edge's injected imports into the
		// referenced file's single top-level component BEFORE resolution, so its
		// rewrite-targets lower under the assembler-chosen discretization.
		applySubsystemRefInjection(view, injected)

		// Capture the referenced (mounted) document's own closed metaparameter
		// environment BEFORE resolveTemplateMachinery consumes its
		// `metaparameters` block: its declared integer defaults overlaid with
		// this edge's folded `bindings`. This is the environment a NESTED
		// subsystem edge inside the mounted document folds its own binding
		// expressions against (the mounted document closes before its own refs
		// resolve, esm-spec §9.7.6 "Ordering within load").
		childMeta := metaEnvFromDecls(view["metaparameters"], bindings)

		// Resolve the referenced document's §9.7 machinery with this edge's
		// bindings, then run the §9.6.3 rewrite fixpoint so the inlined
		// component carries only normal Expression ASTs (Option A).
		orders := extractTemplateOrders(string(data))
		if _, err := resolveTemplateMachinery(view, orders, refBasePath, bindings); err != nil {
			return err
		}
		if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
			return err
		}
		// Expand-at-build (§9.6.4 rule 2 / RFC §7.7): a mounted subsystem is
		// inlined into the importing document as a fully-expanded (Option-A
		// image) component, so its surviving references and per-component
		// registries are resolved away here.
		expandDocument(view)

		// esm-spec §4.7 "Mount-edge index-set renaming", pipeline step 2. The
		// referenced document has now resolved in its OWN scope — its imports,
		// this edge's `bindings` and injection, its metaparameter close and
		// fold, the §9.6.3 fixpoint — so its `index_sets` are the
		// post-resolution vocabulary the edge's `index_set_rename` speaks.
		// Before its own nested mounts resolve: each nested edge renames what IT
		// contributes, at its own edge. Absent or empty => identity, so an edge
		// that does not use the field resolves exactly as before.
		if m, ok := value.(map[string]any); ok {
			if err := applyMountIndexSetRename(view, m["index_set_rename"],
				fmt.Sprintf("%s ref %q", form.noun, ref)); err != nil {
				return err
			}
		}

		// esm-spec §4.7: the mounted file's document-scoped index_sets (already
		// metaparameter-folded) merge into the importing document's registry, so
		// the importer's variables may be shaped over the mesh file's axes and a
		// size/kind disagreement fails loudly (subsystem_index_set_conflict).
		if err := mergeSubsystemIndexSets(registry, view, ref); err != nil {
			return err
		}

		// Recursively resolve subsystem refs nested in the loaded file's
		// components, relative to its own directory; nested mounts merge their
		// axes into the same importing-document registry (transitive, §4.7).
		for _, kind := range templateComponentKinds {
			comps, ok := view[kind].(map[string]any)
			if !ok {
				continue
			}
			for _, compRaw := range comps {
				compObj, ok := compRaw.(map[string]any)
				if !ok {
					continue
				}
				if subs, ok := compObj["subsystems"].(map[string]any); ok {
					// The nested edges live inside the mounted component, which is
					// inlined at this entry's pointer — best-effort deeper prefix (not
					// a corpus-pinned location).
					nestedPrefix := fmt.Sprintf("%s/%s/subsystems", pathPrefix, key)
					if err := resolveSubsystemMap(subs, refBasePath, visited, registry, childMeta, nestedPrefix, subsystemMount); err != nil {
						return fmt.Errorf("%s %q: resolving nested refs in %q: %w", form.noun, key, refKey, err)
					}
				}
			}
		}

		// The mounted document may itself be an ASSEMBLY — a document whose own
		// `models.<k>` entries are `{ref}` mount edges. esm-spec §4.7's top-level
		// form lands its component as a top-level system precisely so that an
		// assembly can be named by file and mounted onward, so the form has to
		// compose with itself. Inline those edges HERE, before the single system
		// is extracted below, or `extractSingleSystemRaw` picks the leaf's
		// UNRESOLVED `{ref}` edge and splices it in as though it were the
		// component: the document loads clean and carries a bare mount edge
		// where a model belongs.
		//
		// Not gated on `form`: it is the MOUNTED DOCUMENT's shape that decides,
		// not which attachment point mounted it, and "two mount forms, one
		// mechanism" forbids answering an assembly differently at the two. The
		// recursion runs through resolveSubsystemMap, so `visited` gives it the
		// same path-scoped cycle detection every other edge gets. Matches the
		// Rust reference, which composes at both forms.
		if err := inlineNestedTopLevelModelRefs(view, refBasePath, visited, registry, childMeta,
			fmt.Sprintf("%s/%s/models", pathPrefix, key)); err != nil {
			return fmt.Errorf("%s %q: resolving nested refs in %q: %w", form.noun, key, refKey, err)
		}

		// Remove from visited after successful resolution (allow the same file
		// to be referenced from different subsystem trees, just not circularly)
		delete(visited, refKey)

		// Extract the single top-level model or reaction system
		resolved, err := extractSingleSystemRaw(view, refKey)
		if err != nil {
			return fmt.Errorf("%s %q: %w", form.noun, key, err)
		}

		subsystems[key] = resolved
	}

	return nil
}

// loadSubsystemRefBytes resolves a subsystem ref (an http(s) URL or a path
// relative to basePath) to its raw bytes, layering the subsystem-ref concerns
// the generic loadRefBytes does not model onto its http(s)-vs-local branch: a
// stable visited-map key for circular-reference detection and a source identity
// for diagnostics.
//
// refKey is that canonical identity — the URL for a remote ref, the absolute
// path for a local one (via canonicalImportRef) — and doubles as the value
// echoed in "referenced file" error messages. refBasePath is the directory the
// referenced document's OWN nested refs resolve against (basePath for a remote
// ref; the referenced file's directory for a local one), threaded back from
// loadRefBytes. A ref already on the resolution stack is the circular-reference
// error; a read/fetch failure is wrapped so it still reads "failed to read
// referenced file …".
func loadSubsystemRefBytes(ref, basePath, key string, visited map[string]bool, form mountForm) (data []byte, refKey, refBasePath string, err error) {
	refKey = canonicalImportRef(ref, basePath)
	if visited[refKey] {
		return nil, refKey, "", fmt.Errorf("%s %q: circular reference detected for %q", form.noun, key, ref)
	}
	visited[refKey] = true

	data, refBasePath, err = loadRefBytes(ref, basePath)
	if err != nil {
		// A ref that names no readable file is the §4.7 `ref_not_found`
		// diagnostic (tests/invalid/subsystem_ref_not_found.esm), not an
		// anonymous I/O failure — the code is what the shared corpus pins and
		// what the other bindings emit.
		return nil, refKey, "", newETErr(CodeUnresolvedSubsystemRef,
			fmt.Sprintf("%s %q: reference %q could not be resolved — %v", form.noun, key, ref, err))
	}
	return data, refKey, refBasePath, nil
}

// fetchRemoteRef downloads a subsystem reference from an HTTP(S) URL and
// returns the raw response body.
func fetchRemoteRef(url string) ([]byte, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch remote ref %q: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("failed to fetch remote ref %q: HTTP %d %s", url, resp.StatusCode, resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read remote ref %q: %w", url, err)
	}
	return body, nil
}

// metaEnvFromDecls builds a closed metaparameter environment (name → int) from
// a raw `metaparameters` declaration block: each declared metaparameter with an
// integer `default` contributes that default, then the overlay (a mount edge's
// already-folded `bindings`) wins. This mirrors the root environment Load
// computes for the top document (declared defaults overlaid with loader-API
// bindings, esm-spec §9.7.6 sites 4-5) and is the environment a nested §4.7
// subsystem edge folds its own binding expressions against. Non-integer or
// absent defaults are simply omitted (an open name is not in scope until bound).
func metaEnvFromDecls(declsRaw any, overlay map[string]int64) map[string]int64 {
	env := map[string]int64{}
	if decls, ok := declsRaw.(map[string]any); ok {
		for name, dRaw := range decls {
			decl, ok := dRaw.(map[string]any)
			if !ok {
				continue
			}
			d, has := decl["default"]
			if !has || d == nil {
				continue
			}
			if iv, err := metaparamInt(d, "metaparameter default"); err == nil {
				env[name] = iv
			}
		}
	}
	for k, v := range overlay {
		env[k] = v
	}
	return env
}

// extractRefWithBindings checks if a value is a reference object (a map with
// a "ref" key) and returns the ref string plus its optional metaparameter
// `bindings` object (esm-spec §9.7.6 binding site 3).
func extractRefWithBindings(value any) (string, map[string]any, bool) {
	m, ok := value.(map[string]any)
	if !ok {
		return "", nil, false
	}

	ref, ok := m["ref"]
	if !ok {
		return "", nil, false
	}

	refStr, ok := ref.(string)
	if !ok {
		return "", nil, false
	}

	bindings, _ := m["bindings"].(map[string]any)
	return refStr, bindings, true
}

// extractSingleSystemRaw extracts the single top-level model or reaction system
// from a referenced ESM document's RAW view. If the file contains exactly one
// such component it is returned as-is (a generic map, preserving every
// Expression field verbatim). If there are multiple systems or none, an error is
// returned.
//
// A `data_sources` entry is NOT a component from esm 1.0.0 and cannot be
// mounted as a subsystem (esm-spec §8, and the `subsystems` schema note), so a
// referenced file whose only payload is a source catalogue has NO mountable
// system — which is the correct rejection, not an oversight.
func extractSingleSystemRaw(view map[string]any, path string) (any, error) {
	models, _ := view["models"].(map[string]any)
	rss, _ := view["reaction_systems"].(map[string]any)
	total := len(models) + len(rss)

	if total == 0 {
		return nil, newETErr(CodeAmbiguousSubsystemRef,
			fmt.Sprintf("referenced file %q contains no models or reaction systems; exactly one is required (esm-spec §4.7)", path))
	}

	if total > 1 {
		// §4.7: a subsystem ref must name a file with EXACTLY ONE top-level
		// system — with several, the mount is ambiguous. `ref_ambiguous_system`
		// is the code the shared corpus pins
		// (tests/invalid/subsystem_ref_ambiguous.esm).
		return nil, newETErr(CodeAmbiguousSubsystemRef,
			fmt.Sprintf("referenced file %q contains %d systems (expected exactly 1); "+
				"models=%d, reaction_systems=%d", path, total, len(models), len(rss)))
	}

	// Extract the single system. Precedence: models -> reaction_systems.
	for _, m := range models {
		return m, nil
	}
	for _, rs := range rss {
		return rs, nil
	}

	// Unreachable, but satisfies the compiler
	return nil, fmt.Errorf("unexpected state extracting system from %q", path)
}
