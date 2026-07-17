package esm

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------------
// Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
// ---------------------------------------------------------------------------

// templateScope is everything one template-library file exports after
// resolution in its OWN scope: its effective template sequence (imports
// depth-first post-order, then own declarations; esm-spec §9.7.4), its
// instantiated `index_sets`, and its still-open metaparameter declarations
// (re-exported to the importer, esm-spec §9.7.6 binding site 2). All three
// maps preserve insertion order — the effective declaration order is
// normative for the §9.6.3 tie-break.
type templateScope struct {
	templates  *orderedMap
	indexSets  *orderedMap
	metaparams *orderedMap
}

func newTemplateScope() *templateScope {
	return &templateScope{
		templates:  newOrderedMap(),
		indexSets:  newOrderedMap(),
		metaparams: newOrderedMap(),
	}
}

func mergeNamed(dst *orderedMap, name string, decl any, code, what, origin string) error {
	if dst.has(name) {
		// Deep-equal redeclaration (a diamond import) dedups at first
		// occurrence; a non-equal collision is a conflict (§9.7.4/§9.7.5).
		if jsonEqual(dst.get(name), decl) {
			return nil
		}
		return newETErr(code,
			fmt.Sprintf("%s: %s '%s' collides with a non-deep-equal existing definition (esm-spec §9.7.4/§9.7.5)", origin, what, name))
	}
	dst.set(name, decl)
	return nil
}

func mergeScope(dst, src *templateScope, origin string) error {
	for _, n := range src.templates.keys {
		if err := mergeNamed(dst.templates, n, src.templates.get(n),
			CodeTemplateImportNameConflict, "template", origin); err != nil {
			return err
		}
	}
	for _, n := range src.indexSets.keys {
		if err := mergeNamed(dst.indexSets, n, src.indexSets.get(n),
			"template_import_index_set_conflict", "index set", origin); err != nil {
			return err
		}
	}
	for _, n := range src.metaparams.keys {
		if err := mergeNamed(dst.metaparams, n, src.metaparams.get(n),
			CodeTemplateImportNameConflict, "metaparameter", origin); err != nil {
			return err
		}
	}
	return nil
}

// resolveImportsInto resolves each `expression_template_imports` entry of a
// document/component (depth-first post-order, esm-spec §9.7.2) and merges the
// resulting exported scope into `scope`. `imports` is the raw entries value (a
// nil / non-list value is a no-op). Relative refs resolve against baseDir; the
// cycle stack is threaded by value. This is the shared "resolve imports →
// mergeScope" head of processLibrary and the root/per-component branches of
// resolveTemplateMachinery.
func resolveImportsInto(scope *templateScope, imports any, baseDir string, stack []string, origin string) error {
	list, ok := imports.([]any)
	if !ok {
		return nil
	}
	for _, entry := range list {
		sub, err := resolveImportEntry(entry, baseDir, stack, origin)
		if err != nil {
			return err
		}
		if err := mergeScope(scope, sub, origin); err != nil {
			return err
		}
	}
	return nil
}

// mergeOwnTemplates validates a raw `expression_templates` block and merges its
// entries — in declaration order, honouring `order` — into scope.templates
// (esm-spec §9.7.4). A nil block is a no-op. Shared "validate + merge own
// templates" step of processLibrary and resolveTemplateMachinery.
func mergeOwnTemplates(scope *templateScope, tpl map[string]any, order []string, origin string) error {
	if tpl == nil {
		return nil
	}
	if err := validateTemplates(tpl, origin); err != nil {
		return err
	}
	for _, n := range orderedKeysOf(tpl, order) {
		if err := mergeNamed(scope.templates, n, tpl[n],
			CodeTemplateImportNameConflict, "template", origin); err != nil {
			return err
		}
	}
	return nil
}

// mergeScopeExports merges an import scope's exported index sets and re-exported
// still-open metaparameters into the document-level registries docIsets /
// docMeta (esm-spec §9.7.5 / §9.7.6). Templates stay in the scope (published per
// component, or as the root library block). Shared by the root-library and the
// per-component import branches of resolveTemplateMachinery.
func mergeScopeExports(docIsets, docMeta *orderedMap, scope *templateScope, origin string) error {
	for _, n := range scope.indexSets.keys {
		if err := mergeNamed(docIsets, n, scope.indexSets.get(n),
			"template_import_index_set_conflict", "index set", origin); err != nil {
			return err
		}
	}
	for _, n := range scope.metaparams.keys {
		if err := mergeNamed(docMeta, n, scope.metaparams.get(n),
			CodeTemplateImportNameConflict, "metaparameter", origin); err != nil {
			return err
		}
	}
	return nil
}

// instantiateScope performs per-edge metaparameter instantiation (esm-spec
// §9.7.6 binding site 1): substitute the bound names throughout the exported
// templates and index sets, then fold the structural sites that are now closed.
// A bound VALUE is a metaparameter expression (usually an integer literal, but
// possibly a symbolic `NX*NY` over the importer's still-open metaparameters);
// foldStructuralSites / foldIndexSetSizes leave any site still carrying a free
// name symbolic for the importer's own metaparameter close.
func instantiateScope(scope *templateScope, values map[string]any, ctx string) error {
	newT := newOrderedMap()
	for _, n := range scope.templates.keys {
		nd := substituteMetaparamsDecl(scope.templates.get(n), values)
		if err := foldStructuralSites(nd, ctx); err != nil {
			return err
		}
		newT.set(n, nd)
	}
	scope.templates = newT
	newIS := newOrderedMap()
	for _, n := range scope.indexSets.keys {
		newIS.set(n, substituteMetaparams(scope.indexSets.get(n), values))
	}
	if err := foldIndexSetSizes(newIS, ctx, false); err != nil {
		return err
	}
	scope.indexSets = newIS
	return nil
}

// canonicalImportRef returns the canonical (absolute) form of a local import
// ref used as the cycle-detection identity (esm-spec §4.7 path-scoped cycles):
// a relative ref is joined onto baseDir and made absolute. A remote (http/https)
// ref is its own canonical form, returned unchanged.
func canonicalImportRef(ref, baseDir string) string {
	if isRemoteRef(ref) {
		return ref
	}
	p := ref
	if !filepath.IsAbs(p) {
		p = filepath.Join(baseDir, p)
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	return abs
}

// loadImportBytes loads a template-library `ref` (URL or path relative to
// baseDir) via the shared loadRefBytes loader, returning the raw bytes and the
// directory anchoring the target's own relative refs. A load failure (bad URL,
// missing/unreadable file) is wrapped in the `template_import_unresolved`
// diagnostic; a relative ref inside a remote library has no resolvable base and
// fails as unresolved when encountered.
func loadImportBytes(ref, baseDir, origin string) ([]byte, string, error) {
	data, dir, err := loadRefBytes(ref, baseDir)
	if err != nil {
		return nil, "", newETErr(CodeTemplateImportUnresolved,
			fmt.Sprintf("%s: could not load template-library ref '%s': %v", origin, ref, err))
	}
	return data, dir, nil
}

// decodeJSONView decodes raw JSON bytes into an untyped map view, preserving
// numeric tokens as json.Number (via UseNumber) so the int/float wire
// distinction the metaparameter arithmetic depends on survives (esm-spec
// §5.4.1). Returns the decode error unwrapped; callers attach a diagnostic code.
func decodeJSONView(data []byte) (map[string]any, error) {
	var view map[string]any
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		return nil, err
	}
	return view, nil
}

// resolveImportEntry resolves ONE `expression_template_imports` entry
// (esm-spec §9.7.2): load the target (path-scoped cycle detection over
// canonical refs, as §4.7), verify library purity, resolve the target
// recursively in its own scope, instantiate at this edge's `bindings`, apply
// `only` visibility filtering, then apply the edge's `prefix`/`rename`/`rebind`
// (esm-spec §9.7.7).
//
// `stack` is the cycle-detection path of canonical refs, passed BY VALUE: the
// recursive descent extends its own copy with append(stack, canonical), so the
// caller's slice needs no pop and sibling edges cannot see each other's frame.
func resolveImportEntry(entry any, baseDir string, stack []string, origin string) (*templateScope, error) {
	entryObj, ok := entry.(map[string]any)
	if !ok {
		return nil, newETErr(CodeTemplateImportUnresolved,
			fmt.Sprintf("%s: expression_template_imports entries must be objects with a `ref` field", origin))
	}
	ref, ok := entryObj["ref"].(string)
	if !ok || ref == "" {
		return nil, newETErr(CodeTemplateImportUnresolved,
			fmt.Sprintf("%s: expression_template_imports entry requires a non-empty string `ref`", origin))
	}
	canonical := canonicalImportRef(ref, baseDir)
	for i, s := range stack {
		if s == canonical {
			cyc := append(append([]string{}, stack[i:]...), canonical)
			return nil, newETErr(CodeTemplateImportCycle,
				fmt.Sprintf("%s: import-graph cycle detected: %s (esm-spec §9.7.2)", origin, strings.Join(cyc, " -> ")))
		}
	}

	data, targetDir, err := loadImportBytes(ref, baseDir, origin)
	if err != nil {
		return nil, err
	}
	view, err := decodeJSONView(data)
	if err != nil {
		return nil, newETErr(CodeTemplateImportUnresolved,
			fmt.Sprintf("%s: template-library ref '%s' is not valid JSON: %v", origin, ref, err))
	}
	if err := RejectExpressionTemplatesPreV04(view); err != nil {
		return nil, err
	}
	if err := RejectTemplateImportsPreV08(view); err != nil {
		return nil, err
	}

	// Library purity (esm-spec §9.7.1): the reference mechanisms are disjoint —
	// a component/subsystem file, and a coupling-library file, are not
	// importable as a template library.
	if isCouplingLibraryDoc(view) {
		return nil, newETErr("template_import_is_coupling_library",
			fmt.Sprintf("%s: import target '%s' is a coupling-library file (has `coupling_roles`), not a template library (esm-spec §10.9)", origin, ref))
	}
	if !isTemplateLibraryDoc(view) {
		return nil, newETErr("template_import_not_library",
			fmt.Sprintf("%s: import target '%s' lacks top-level `expression_templates` — not a template-library file (esm-spec §9.7.1)", origin, ref))
	}
	for _, k := range libraryForbiddenKeys {
		if _, has := view[k]; has {
			return nil, newETErr("template_import_not_library",
				fmt.Sprintf("%s: import target '%s' declares `%s` — not a pure template-library file (esm-spec §9.7.1)", origin, ref, k))
		}
	}
	schemaRes, err := validateJSONSchema(string(data))
	if err != nil {
		return nil, newETErr(CodeTemplateImportUnresolved,
			fmt.Sprintf("%s: import target '%s' failed schema validation: %v", origin, ref, err))
	}
	if !schemaRes.IsValid {
		msg := "schema invalid"
		if len(schemaRes.SchemaErrors) > 0 {
			msg = schemaRes.SchemaErrors[0].Message
		}
		return nil, newETErr(CodeTemplateImportUnresolved,
			fmt.Sprintf("%s: import target '%s' failed schema validation: %s", origin, ref, msg))
	}

	scope, err := processLibrary(view, extractTemplateOrders(string(data)),
		targetDir, append(stack, canonical), origin+" -> "+ref)
	if err != nil {
		return nil, err
	}

	// Edge metaparameter bindings (esm-spec §9.7.6 binding site 1). A binding
	// VALUE may be a metaparameter expression over the importer's metaparameters
	// (e.g. `NX*NY`); at an import edge the importer's names are not yet closed
	// (innermost-first), so the value is carried SYMBOLICALLY into the child and
	// folds when the importing document closes (§9.7.6 binding value flow).
	values := map[string]any{}
	if bindingsRaw, ok := entryObj["bindings"].(map[string]any); ok {
		for _, name := range sortedKeys(bindingsRaw) {
			if !scope.metaparams.has(name) {
				return nil, newETErr(CodeTemplateImportUnknownName,
					fmt.Sprintf("%s: import of '%s' binds metaparameter '%s', which the target neither declares nor re-exports (esm-spec §9.7.6)", origin, ref, name))
			}
			v, err := requireMetaExpr(bindingsRaw[name],
				fmt.Sprintf("%s: import of '%s', binding '%s'", origin, ref, name))
			if err != nil {
				return nil, err
			}
			// Carry the value symbolically into the child (its free names are the
			// importer's still-open metaparameters, folded at the importer's
			// close). Normalize numeric leaves to int64 so the child's structural
			// folds accept them; names stay symbolic.
			values[name] = coerceMetaExprInts(v)
		}
	}
	if len(values) > 0 {
		if err := instantiateScope(scope, values, origin+" -> "+ref); err != nil {
			return nil, err
		}
		for name := range values {
			scope.metaparams.delete(name)
		}
	}

	// `only` visibility filtering (esm-spec §9.7.2) — after the target's own
	// internal wiring resolved in its own scope.
	if onlyRaw, ok := entryObj["only"].([]any); ok {
		keep := map[string]bool{}
		for _, nRaw := range onlyRaw {
			n, ok := nRaw.(string)
			if !ok {
				return nil, newETErr(CodeTemplateImportUnknownName,
					fmt.Sprintf("%s: import of '%s' has an `only` entry %#v that is not a template-name string (esm-spec §9.7.2)", origin, ref, nRaw))
			}
			if !scope.templates.has(n) {
				return nil, newETErr(CodeTemplateImportUnknownName,
					fmt.Sprintf("%s: `only` names template '%s', which '%s' does not declare (esm-spec §9.7.2)", origin, n, ref))
			}
			keep[n] = true
		}
		// esm-spec §9.7.2 / §9.6.4 rule 5 (Option B): `only` filters the
		// importer's EXPLICIT visibility, but the kept templates' bodies may
		// reference other "internal-wiring" templates that resolved in the
		// target's own scope (a BC rule referencing an interior stencil). With
		// bodies no longer inlined (§9.7.3), those referenced templates must be
		// carried along as the transitive reference closure, or the surviving
		// references would dangle. `only` is respected automatically —
		// materialization is by reference closure.
		closure := map[string]bool{}
		var stack []string
		for n := range keep {
			if decl, ok := scope.templates.get(n).(map[string]any); ok {
				collectApplyNames(&stack, decl["body"])
			}
		}
		for len(stack) > 0 {
			r := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if keep[r] || closure[r] || !scope.templates.has(r) {
				continue
			}
			closure[r] = true
			if decl, ok := scope.templates.get(r).(map[string]any); ok {
				collectApplyNames(&stack, decl["body"])
			}
		}
		filtered := newOrderedMap()
		for _, n := range scope.templates.keys {
			if keep[n] || closure[n] {
				filtered.set(n, scope.templates.get(n))
			}
		}
		scope.templates = filtered
	}

	// Import-edge renaming / namespacing + free-name rebinding (esm-spec
	// §9.7.7) — after `bindings` instantiation and `only` filtering, before
	// the §9.7.4/§9.7.5 merge, so dedup/conflict checks see post-rename names.
	return applyEdgeRenames(scope, entryObj, origin, ref)
}

// processLibrary resolves a template-library document in its OWN scope: its
// imports (depth-first post-order), then its own templates / index sets /
// metaparameters appended in declaration order (esm-spec §9.7.4), then §9.7.3
// body composition — so a BC-layer body reference to an imported interior
// stencil closes here, before any `only` filtering by a downstream importer.
func processLibrary(view map[string]any, fileOrders map[string][]string,
	dir string, stack []string, origin string) (*templateScope, error) {
	scope := newTemplateScope()
	if err := resolveImportsInto(scope, view["expression_template_imports"], dir, stack, origin); err != nil {
		return nil, err
	}

	tpl, _ := view["expression_templates"].(map[string]any)
	if err := mergeOwnTemplates(scope, tpl, fileOrders["/expression_templates"], origin); err != nil {
		return nil, err
	}

	if isets, ok := view["index_sets"].(map[string]any); ok {
		for _, n := range orderedKeysOf(isets, fileOrders["/index_sets"]) {
			if err := mergeNamed(scope.indexSets, n, isets[n],
				"template_import_index_set_conflict", "index set", origin); err != nil {
				return nil, err
			}
		}
	}

	mps, err := collectMetaparamDecls(view, origin, fileOrders["/metaparameters"])
	if err != nil {
		return nil, err
	}
	for _, n := range mps.keys {
		if err := mergeNamed(scope.metaparams, n, mps.get(n),
			CodeTemplateImportNameConflict, "metaparameter", origin); err != nil {
			return nil, err
		}
	}

	// §9.7.3 body composition in the library's own scope (decl objects are
	// mutated in place, so scope.templates sees the closed bodies).
	if err := composeTemplateBodies(scope.templates.m, origin); err != nil {
		return nil, err
	}
	return scope, nil
}

// ---------------------------------------------------------------------------
// Root-document resolution (the load-time entry point)
// ---------------------------------------------------------------------------

// hasImportMachinery reports whether view carries any esm-spec §9.7 construct
// that resolveTemplateMachinery must process: a top-level `expression_templates`
// / `metaparameters` / `expression_template_imports` block, or a per-component
// `expression_template_imports`. A document with none takes the legacy fast path.
func hasImportMachinery(view map[string]any) bool {
	if view == nil {
		return false
	}
	if _, has := view["expression_templates"]; has {
		return true
	}
	if _, has := view["metaparameters"]; has {
		return true
	}
	if _, has := view["expression_template_imports"]; has {
		return true
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			if compObj, ok := compRaw.(map[string]any); ok {
				if _, has := compObj["expression_template_imports"]; has {
					return true
				}
			}
		}
	}
	return false
}

// resolveTemplateMachinery resolves every esm-spec §9.7 construct of the ROOT
// document `view`, IN PLACE (relative import refs resolve against `baseDir`):
// imports recursively with per-edge instantiation, `index_sets` merge,
// metaparameter close (`metaparameters` is the loader-API binding site 4;
// already-closed edge bindings win, then API bindings, then defaults) and
// fold, expression-position substitution, and — for a root library file —
// §9.7.3 body composition.
//
// `orders` is the path → key-order map recovered from the raw JSON
// (extractTemplateOrders); the resolver reads the root's declaration orders
// from it and WRITES each component's effective template sequence back into
// it, so the subsequent lowerExpressionTemplatesOrdered pass breaks
// declaration-order ties by the §9.7.4 effective sequence. After resolution
// no `expression_template_imports`, `metaparameters`, or top-level
// `expression_templates` key remains (Option A round-trip). Returns false
// when the document carries no §9.7 machinery (the legacy fast path).
func resolveTemplateMachinery(view map[string]any, orders map[string][]string,
	baseDir string, metaparameters map[string]int64) (bool, error) {
	if !hasImportMachinery(view) {
		if len(metaparameters) > 0 {
			names := make([]string, 0, len(metaparameters))
			for k := range metaparameters {
				names = append(names, k)
			}
			sort.Strings(names)
			return false, newETErr(CodeTemplateImportUnknownName,
				fmt.Sprintf("loader API binds metaparameter(s) %s but the document declares none (esm-spec §9.7.6)", strings.Join(names, ", ")))
		}
		return false, nil
	}
	if orders == nil {
		orders = map[string][]string{}
	}
	stack := []string{}

	docMeta, err := collectMetaparamDecls(view, "document", orders["/metaparameters"])
	if err != nil {
		return false, err
	}
	docIsets := newOrderedMap()
	if isets, ok := view["index_sets"].(map[string]any); ok {
		for _, n := range orderedKeysOf(isets, orders["/index_sets"]) {
			docIsets.set(n, isets[n])
		}
	}

	// --- top-level templates + imports (root template-library file, §9.7.4) ---
	_, isLibrary := view["expression_templates"]
	topTemplates := newOrderedMap()
	if isLibrary {
		topTemplates, err = resolveRootLibraryImports(view, orders, baseDir, stack, docIsets, docMeta)
		if err != nil {
			return false, err
		}
	}

	// --- per-component imports (models / reaction systems, §9.7.2) ---
	if err := resolveComponentImports(view, orders, baseDir, stack, docIsets, docMeta); err != nil {
		return false, err
	}

	// --- close this document's metaparameters (§9.7.6 sites 4-5) ---
	values, err := closeDocumentMetaparams(docMeta, metaparameters)
	if err != nil {
		return false, err
	}

	// --- §9.7.6 name-collision check: no shadowing of visible names ---
	if err := checkMetaparamNameCollisions(view, docMeta, docIsets); err != nil {
		return false, err
	}

	// --- expression-position substitution of the closed values ---
	substituteClosedMetaparams(view, topTemplates, docIsets, values)

	// --- fold structural sites on the closed document ---
	if err := foldClosedDocument(view, topTemplates, docIsets); err != nil {
		return false, err
	}

	// --- root library file: compose bodies (validation), then strip; no §9.7
	//     construct survives parse → emit (esm-spec §9.7.6 round-trip) ---
	if isLibrary {
		if err := composeTemplateBodies(topTemplates.m, "document"); err != nil {
			return false, err
		}
		delete(view, "expression_templates")
	}
	delete(view, "expression_template_imports")
	delete(view, "metaparameters")
	if docIsets.len() > 0 {
		view["index_sets"] = docIsets.m
	}
	return true, nil
}

// resolveRootLibraryImports resolves the ROOT document's own template-library
// imports and top-level `expression_templates` (esm-spec §9.7.4, root-library
// case): imports merge depth-first post-order, then the declared templates, into
// a fresh scope; the scope's index sets and re-exported metaparameters flow into
// the document registries docIsets / docMeta. Returns the effective top-level
// template sequence.
func resolveRootLibraryImports(view map[string]any, orders map[string][]string,
	baseDir string, stack []string, docIsets, docMeta *orderedMap) (*orderedMap, error) {
	topscope := newTemplateScope()
	if err := resolveImportsInto(topscope, view["expression_template_imports"], baseDir, stack, "document"); err != nil {
		return nil, err
	}
	tpl, _ := view["expression_templates"].(map[string]any)
	if err := mergeOwnTemplates(topscope, tpl, orders["/expression_templates"], "document"); err != nil {
		return nil, err
	}
	if err := mergeScopeExports(docIsets, docMeta, topscope, "document"); err != nil {
		return nil, err
	}
	return topscope.templates, nil
}

// resolveComponentImports resolves each model / reaction-system component's own
// `expression_template_imports` (esm-spec §9.7.2) IN PLACE: imports merge
// depth-first post-order, then the component's own templates, into a fresh
// scope; the scope's index sets and metaparameters flow into docIsets / docMeta.
// The effective sequence (imports depth-first post-order, then local
// declarations) becomes the component's `expression_templates` block — its
// published key order IS the §9.6.3 declaration order, written back into
// `orders` — and the consumed `expression_template_imports` key is stripped.
func resolveComponentImports(view map[string]any, orders map[string][]string,
	baseDir string, stack []string, docIsets, docMeta *orderedMap) error {
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range orderedKeysOf(comps, orders["/"+kind]) {
			comp, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			importsRaw, present := comp["expression_template_imports"]
			if !present || importsRaw == nil {
				continue
			}
			corigin := kind + "." + cname
			cscope := newTemplateScope()
			if err := resolveImportsInto(cscope, importsRaw, baseDir, stack, corigin); err != nil {
				return err
			}
			tplPath := "/" + kind + "/" + cname + "/expression_templates"
			tpl, _ := comp["expression_templates"].(map[string]any)
			if err := mergeOwnTemplates(cscope, tpl, orders[tplPath], corigin); err != nil {
				return err
			}
			if err := mergeScopeExports(docIsets, docMeta, cscope, corigin); err != nil {
				return err
			}
			comp["expression_templates"] = cscope.templates.m
			orders[tplPath] = cscope.templates.keys
			delete(comp, "expression_template_imports")
		}
	}
	return nil
}

// closeDocumentMetaparams closes the document's metaparameters to concrete int64
// values (esm-spec §9.7.6 sites 4-5): a loader-API binding wins, else the
// declared `default`. A loader-API name the document does not declare is
// `template_import_unknown_name`; a metaparameter still open after bindings and
// defaults is `metaparameter_unbound`.
func closeDocumentMetaparams(docMeta *orderedMap, metaparameters map[string]int64) (map[string]int64, error) {
	apiNames := make([]string, 0, len(metaparameters))
	for k := range metaparameters {
		apiNames = append(apiNames, k)
	}
	sort.Strings(apiNames)
	for _, k := range apiNames {
		if !docMeta.has(k) {
			return nil, newETErr(CodeTemplateImportUnknownName,
				fmt.Sprintf("loader API binds metaparameter '%s', which the document does not declare (esm-spec §9.7.6)", k))
		}
	}
	values := map[string]int64{}
	var openNames []string
	for _, name := range docMeta.keys {
		if v, ok := metaparameters[name]; ok {
			values[name] = v
			continue
		}
		decl, _ := docMeta.get(name).(map[string]any)
		d, has := decl["default"]
		if !has || d == nil {
			openNames = append(openNames, name)
			continue
		}
		dv, err := metaparamInt(d, fmt.Sprintf("metaparameters.%s default", name))
		if err != nil {
			return nil, err
		}
		values[name] = dv
	}
	if len(openNames) > 0 {
		return nil, newETErr("metaparameter_unbound",
			fmt.Sprintf("metaparameter(s) %s still open after edge bindings, loader-API bindings, and defaults (esm-spec §9.7.6)", strings.Join(openNames, ", ")))
	}
	return values, nil
}

// checkMetaparamNameCollisions enforces esm-spec §9.7.6: a declared
// metaparameter name must not shadow any visible index-set / variable / species
// / parameter name. A collision is `metaparameter_name_conflict`. No-op when the
// document declares no metaparameters.
func checkMetaparamNameCollisions(view map[string]any, docMeta, docIsets *orderedMap) error {
	if docMeta.len() == 0 {
		return nil
	}
	visible := map[string]bool{}
	for _, n := range docIsets.keys {
		visible[n] = true
	}
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
			for _, blk := range []string{"variables", "species", "parameters"} {
				if b, ok := compObj[blk].(map[string]any); ok {
					for vn := range b {
						visible[vn] = true
					}
				}
			}
		}
	}
	for _, name := range docMeta.keys {
		if visible[name] {
			return newETErr("metaparameter_name_conflict",
				fmt.Sprintf("metaparameter '%s' collides with a visible variable/parameter/species/index-set name (esm-spec §9.7.6)", name))
		}
	}
	return nil
}

// substituteClosedMetaparams substitutes the closed metaparameter values into
// every expression position of the document — component fields (template decls
// via substituteMetaparamsDecl, everything else via substituteMetaparams), the
// root library templates, and the document index sets (esm-spec §9.7.6). No-op
// when there are no closed values.
func substituteClosedMetaparams(view map[string]any, topTemplates, docIsets *orderedMap, values map[string]int64) {
	if len(values) == 0 {
		return
	}
	// The document close binds every metaparameter to a concrete integer;
	// substituteMetaparams takes a metaparameter-expression map (the same shape
	// an import edge carries symbolically), so lift the int64 close environment
	// into it.
	substVals := make(map[string]any, len(values))
	for k, v := range values {
		substVals[k] = v
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
			for _, k := range sortedKeys(comp) {
				if k == "expression_templates" {
					if tpl, ok := comp[k].(map[string]any); ok {
						for tn, td := range tpl {
							tpl[tn] = substituteMetaparamsDecl(td, substVals)
						}
						continue
					}
				}
				comp[k] = substituteMetaparams(comp[k], substVals)
			}
		}
	}
	for _, tn := range topTemplates.keys {
		topTemplates.m[tn] = substituteMetaparamsDecl(topTemplates.get(tn), substVals)
	}
	for _, n := range docIsets.keys {
		docIsets.m[n] = substituteMetaparams(docIsets.get(n), substVals)
	}
}

// foldClosedDocument folds the structural integer sites (aggregate ranges,
// makearray region bounds) of the closed document and the interval index-set
// sizes (esm-spec §9.7.6): components, then the root library templates, then the
// document index sets with strict=true (any remaining open size is
// `metaparameter_unbound`).
func foldClosedDocument(view map[string]any, topTemplates, docIsets *orderedMap) error {
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			if comp, ok := comps[cname].(map[string]any); ok {
				if err := foldStructuralSites(comp, kind+"."+cname); err != nil {
					return err
				}
			}
		}
	}
	for _, tn := range topTemplates.keys {
		if err := foldStructuralSites(topTemplates.get(tn), "document.expression_templates."+tn); err != nil {
			return err
		}
	}
	return foldIndexSetSizes(docIsets, "document", true)
}
