package esm

// Coupling-library files and `coupling_import` role binding (esm-spec
// §10.9–§10.11).
//
// A *coupling-library file* is a document whose payload is a top-level
// `coupling_roles` map plus a role-scoped `coupling` array. An assembly reuses
// it with a `{ "type": "coupling_import", "ref", "bind" }` coupling entry: at
// flatten the import expands into concrete variable_map / couple /
// operator_compose / event edges by substituting the bound actual component for
// every role-named top-level segment (the §10.10.2 occurrence surface).
//
// Expansion runs *inside* flatten (esm-spec §10.10.3), after subsystem mounting
// (which happens at load) and before the coupling-rule step, so every `bind`
// target resolves against fully-mounted components. The `coupling_import`
// source entry is preserved for round-trip; only the flattened system carries
// the expanded edges. This mirrors the TypeScript reference
// (pkg/earthsci-ast-ts/src/coupling-imports.ts).

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// couplingLibraryForbiddenKeys are the payload keys a coupling-library file
// MUST NOT declare (esm-spec §10.9).
var couplingLibraryForbiddenKeys = []string{
	"models",
	"reaction_systems",
	"data_loaders",
	"domain",
	"index_sets",
	"metaparameters",
	"expression_templates",
}

// roleBearingTypes are the coupling-entry types a library edge MAY carry
// (esm-spec §10.9).
var roleBearingTypes = map[string]bool{
	"variable_map":     true,
	"couple":           true,
	"operator_compose": true,
	"event":            true,
}

// CouplingImportOptions controls how `coupling_import` refs are resolved at
// flatten (mirrors the TS CouplingImportOptions).
type CouplingImportOptions struct {
	// BasePath is the directory import `ref`s resolve against. Defaults to ".".
	BasePath string
	// LoadRef resolves a `ref` string to a parsed coupling-library document
	// (raw JSON view). Defaults to a filesystem reader. Tests may supply an
	// in-memory resolver.
	LoadRef func(ref, basePath string) (map[string]any, error)
}

// isCouplingLibraryDoc reports whether `raw` has the coupling-library-file FORM
// (top-level `coupling_roles`, esm-spec §10.9). Presence of that key is the
// sole positive identifier of the file kind; purity is checked separately at
// the import edge.
func isCouplingLibraryDoc(raw map[string]any) bool {
	if raw == nil {
		return false
	}
	_, has := raw["coupling_roles"]
	return has
}

// ---------------------------------------------------------------------------
// Reference rewriting — the §10.10.2 occurrence surface
// ---------------------------------------------------------------------------

type refFn func(ref string) string

func headSegment(ref string) string {
	if i := strings.Index(ref, "."); i >= 0 {
		return ref[:i]
	}
	return ref
}

// rewriteScopedRef replaces the top-level segment of a scoped reference with
// its bound actual. `"Fuel.w_0"` under `{ Fuel: "FuelModelLookup" }` ->
// `"FuelModelLookup.w_0"`; a dotted bind value (`{ Fuel: "Parent.Child" }`) ->
// `"Parent.Child.w_0"`. A segment not in `bind` is returned unchanged (e.g.
// bare `"t"`, literals).
func rewriteScopedRef(ref string, bind map[string]string) string {
	head := ref
	tail := ""
	if i := strings.Index(ref, "."); i >= 0 {
		head = ref[:i]
		tail = ref[i:]
	}
	if actual, ok := bind[head]; ok {
		return actual + tail
	}
	return ref
}

// rewriteExprRaw rewrites/visits every scoped reference inside a raw Expression
// tree. Numbers and other non-string/non-object leaves pass through unchanged;
// `apply_expression_template` bindings VALUES are free-variable targets
// (esm-spec §10.10.2) — Expressions in their own right.
func rewriteExprRaw(expr any, fn refFn) any {
	switch e := expr.(type) {
	case string:
		return fn(e)
	case map[string]any:
		if args, ok := e["args"].([]any); ok {
			for i := range args {
				args[i] = rewriteExprRaw(args[i], fn)
			}
			e["args"] = args
		}
		if op, _ := e["op"].(string); op == applyExpressionTemplateOp {
			if b, ok := e["bindings"].(map[string]any); ok {
				for k := range b {
					b[k] = rewriteExprRaw(b[k], fn)
				}
			}
		}
		return e
	default:
		return expr
	}
}

// mapStringArrayRaw applies fn to every string element of a raw array in place.
func mapStringArrayRaw(v any, fn refFn) any {
	arr, ok := v.([]any)
	if !ok {
		return v
	}
	for i, el := range arr {
		if s, ok := el.(string); ok {
			arr[i] = fn(s)
		}
	}
	return arr
}

// rewriteEntryInPlace applies structFn to every structural system/scoped
// reference of a coupling edge and exprFn to every scoped reference inside its
// Expression fields (esm-spec §10.10.2). Mutates `entry` in place (callers pass
// a clone).
func rewriteEntryInPlace(entry map[string]any, structFn, exprFn refFn) {
	t, _ := entry["type"].(string)
	switch t {
	case "variable_map":
		if s, ok := entry["from"].(string); ok {
			entry["from"] = structFn(s)
		}
		if s, ok := entry["to"].(string); ok {
			entry["to"] = structFn(s)
		}
		// A legacy string transform ("param_to_var", ...) is left alone; only an
		// Expression (operator-node object) transform carries scoped references.
		if tr, ok := entry["transform"].(map[string]any); ok {
			entry["transform"] = rewriteExprRaw(tr, exprFn)
		}

	case "couple":
		if sys, ok := entry["systems"]; ok {
			entry["systems"] = mapStringArrayRaw(sys, structFn)
		}
		if conn, ok := entry["connector"].(map[string]any); ok {
			if eqs, ok := conn["equations"].([]any); ok {
				for _, e := range eqs {
					eq, ok := e.(map[string]any)
					if !ok {
						continue
					}
					if s, ok := eq["from"].(string); ok {
						eq["from"] = structFn(s)
					}
					if s, ok := eq["to"].(string); ok {
						eq["to"] = structFn(s)
					}
					if ex, ok := eq["expression"]; ok && ex != nil {
						eq["expression"] = rewriteExprRaw(ex, exprFn)
					}
				}
			}
		}

	case "operator_compose":
		if sys, ok := entry["systems"]; ok {
			entry["systems"] = mapStringArrayRaw(sys, structFn)
		}
		if tr, ok := entry["translate"].(map[string]any); ok {
			next := make(map[string]any, len(tr))
			for k, v := range tr {
				nk := structFn(k)
				switch vv := v.(type) {
				case string:
					next[nk] = structFn(vv)
				case map[string]any:
					m, _ := deepCopyJSON(vv).(map[string]any)
					if s, ok := m["var"].(string); ok {
						m["var"] = structFn(s)
					}
					next[nk] = m
				default:
					next[nk] = v
				}
			}
			entry["translate"] = next
		}

	case "event":
		if conds, ok := entry["conditions"].([]any); ok {
			for i, c := range conds {
				conds[i] = rewriteExprRaw(c, exprFn)
			}
		}
		rewriteAffect := func(a any) any {
			am, ok := a.(map[string]any)
			if !ok {
				return a
			}
			if s, ok := am["lhs"].(string); ok {
				am["lhs"] = structFn(s)
			}
			if r, ok := am["rhs"]; ok && r != nil {
				am["rhs"] = rewriteExprRaw(r, exprFn)
			}
			return am
		}
		if aff, ok := entry["affects"].([]any); ok {
			for i := range aff {
				aff[i] = rewriteAffect(aff[i])
			}
		}
		if aff, ok := entry["affect_neg"].([]any); ok {
			for i := range aff {
				aff[i] = rewriteAffect(aff[i])
			}
		}
		if trig, ok := entry["trigger"].(map[string]any); ok {
			if tt, _ := trig["type"].(string); tt == "condition" {
				if ex, ok := trig["expression"]; ok && ex != nil {
					trig["expression"] = rewriteExprRaw(ex, exprFn)
				}
			}
		}
		if fa, ok := entry["functional_affect"].(map[string]any); ok {
			for _, key := range []string{"read_vars", "read_params", "modified_params"} {
				if lst, ok := fa[key]; ok {
					fa[key] = mapStringArrayRaw(lst, structFn)
				}
			}
		}
		if dp, ok := entry["discrete_parameters"]; ok {
			entry["discrete_parameters"] = mapStringArrayRaw(dp, structFn)
		}
	}
}

// collectRoleSegments collects the top-level role segments a library edge
// references. Structural ref fields (systems[], from/to, translate keys, event
// var lists) always name a role; Expression strings name a role only when they
// are scoped references (contain a dot) — bare Expression operands like `"t"`
// are incidental.
func collectRoleSegments(edge map[string]any) map[string]bool {
	seen := map[string]bool{}
	clone, _ := deepCopyJSON(edge).(map[string]any)
	structFn := func(ref string) string {
		seen[headSegment(ref)] = true
		return ref
	}
	exprFn := func(ref string) string {
		if strings.Contains(ref, ".") {
			seen[headSegment(ref)] = true
		}
		return ref
	}
	rewriteEntryInPlace(clone, structFn, exprFn)
	return seen
}

// ---------------------------------------------------------------------------
// Ref loading (mirrors the §9.7 template resolver)
// ---------------------------------------------------------------------------

func defaultLoadCouplingRef(ref, basePath string) (map[string]any, error) {
	// loadRefBytes unifies the http(s)-vs-local branch (isRemoteRef + stat/read);
	// a coupling library never has nested refs, so its base dir is discarded. The
	// plain error is re-wrapped in this loader's own diagnostic code.
	data, _, err := loadRefBytes(ref, basePath)
	if err != nil {
		return nil, newETErr("coupling_import_unresolved",
			fmt.Sprintf("coupling_import ref '%s' failed to load: %v", ref, err))
	}
	return parseCouplingRefView(ref, data)
}

func parseCouplingRefView(where string, data []byte) (map[string]any, error) {
	view, err := decodeJSONView(data)
	if err != nil {
		return nil, newETErr("coupling_import_unresolved",
			fmt.Sprintf("coupling-library ref '%s' is not valid JSON: %v", where, err))
	}
	return view, nil
}

// ---------------------------------------------------------------------------
// Library validation + expansion
// ---------------------------------------------------------------------------

// expandCouplingImportEntry validates a resolved coupling-library document and
// expands one `coupling_import` entry into its concrete edges, bound to `bind`.
// Raises the esm-spec §10.11 diagnostics.
func expandCouplingImportEntry(lib map[string]any, ref string, bind map[string]string, file *EsmFile) ([]CouplingEntry, error) {
	if !isCouplingLibraryDoc(lib) {
		return nil, newETErr("coupling_import_not_library",
			fmt.Sprintf("coupling_import ref '%s' lacks top-level `coupling_roles` — not a coupling-library file (esm-spec §10.9)", ref))
	}

	// Purity (esm-spec §10.9).
	for _, k := range couplingLibraryForbiddenKeys {
		if _, has := lib[k]; has {
			return nil, newETErr("coupling_library_illegal_payload",
				fmt.Sprintf("coupling-library '%s' declares `%s` — a coupling library is nothing but roles + wiring (esm-spec §10.9)", ref, k))
		}
	}

	rolesMap, _ := lib["coupling_roles"].(map[string]any)
	roleNames := sortedKeys(rolesMap)
	if len(roleNames) == 0 {
		return nil, newETErr("coupling_library_illegal_payload",
			fmt.Sprintf("coupling-library '%s' declares no roles (esm-spec §10.9: `coupling_roles` is required, non-empty)", ref))
	}
	edges, _ := lib["coupling"].([]any)
	if len(edges) == 0 {
		return nil, newETErr("coupling_library_illegal_payload",
			fmt.Sprintf("coupling-library '%s' has an empty `coupling` array (esm-spec §10.9: required, non-empty)", ref))
	}

	roleSet := make(map[string]bool, len(roleNames))
	for _, r := range roleNames {
		roleSet[r] = true
	}

	// Edge-type + role-scope checks over the declared roles.
	usedRoles := map[string]bool{}
	for _, e := range edges {
		edge, ok := e.(map[string]any)
		if !ok {
			continue
		}
		et, _ := edge["type"].(string)
		if et == "coupling_import" {
			return nil, newETErr("coupling_library_nested_import",
				fmt.Sprintf("coupling-library '%s' contains a nested coupling_import (v1 forbids layering, esm-spec §10.9)", ref))
		}
		if _, hasImports := edge["expression_template_imports"]; et == "callback" || hasImports {
			return nil, newETErr("coupling_library_illegal_payload",
				fmt.Sprintf("coupling-library '%s' edge of type '%s' is not role-substitutable (no callback entries or edge-level expression_template_imports, esm-spec §10.9)", ref, et))
		}
		if !roleBearingTypes[et] {
			return nil, newETErr("coupling_library_illegal_payload",
				fmt.Sprintf("coupling-library '%s' contains an unsupported edge type '%s' (esm-spec §10.9)", ref, et))
		}
		segs := collectRoleSegments(edge)
		for _, seg := range sortedKeys(segs) {
			if !roleSet[seg] {
				return nil, newETErr("coupling_edge_unknown_role",
					fmt.Sprintf("coupling-library '%s': edge references '%s', which is not a declared role (esm-spec §10.9)", ref, seg))
			}
			usedRoles[seg] = true
		}
	}
	for _, role := range roleNames {
		if !usedRoles[role] {
			return nil, newETErr("coupling_role_unused",
				fmt.Sprintf("coupling-library '%s': role '%s' is declared but referenced by no edge (esm-spec §10.9)", ref, role))
		}
	}

	// Binding — total and checked (esm-spec §10.10.1).
	for _, key := range sortedKeys(bind) {
		if !roleSet[key] {
			return nil, newETErr("coupling_import_unknown_role",
				fmt.Sprintf("coupling_import ref '%s': bind key '%s' is not a declared role (esm-spec §10.10.1)", ref, key))
		}
	}
	for _, role := range roleNames {
		actual, ok := bind[role]
		if !ok {
			return nil, newETErr("coupling_import_role_unbound",
				fmt.Sprintf("coupling_import ref '%s': role '%s' has no bind entry (binding is total, esm-spec §10.10.1)", ref, role))
		}
		if !resolvesToComponent(file, actual) {
			return nil, newETErr("coupling_import_bind_not_a_component",
				fmt.Sprintf("coupling_import ref '%s': bind '%s' -> '%s' does not resolve to a component (esm-spec §10.10.1)", ref, role, actual))
		}
	}

	// Expand: substitute bound actuals for role names, one simultaneous rewrite.
	rw := func(r string) string { return rewriteScopedRef(r, bind) }
	expanded := make([]CouplingEntry, 0, len(edges))
	for _, e := range edges {
		edge, ok := e.(map[string]any)
		if !ok {
			continue
		}
		clone, _ := deepCopyJSON(edge).(map[string]any)
		rewriteEntryInPlace(clone, rw, rw)
		ce, err := rawEdgeToCouplingEntry(clone)
		if err != nil {
			return nil, err
		}
		expanded = append(expanded, ce)
	}
	return expanded, nil
}

// rawEdgeToCouplingEntry re-materializes a rewritten raw edge map into a typed
// CouplingEntry via the shared coupling-entry unmarshaler.
func rawEdgeToCouplingEntry(edge map[string]any) (CouplingEntry, error) {
	data, err := json.Marshal(edge)
	if err != nil {
		return nil, newETErr("coupling_import_unresolved",
			fmt.Sprintf("failed to re-encode expanded coupling edge: %v", err))
	}
	ce, err := UnmarshalCouplingEntry(data)
	if err != nil {
		return nil, newETErr("coupling_import_unresolved",
			fmt.Sprintf("failed to decode expanded coupling edge: %v", err))
	}
	return ce, nil
}

// resolvesToComponent resolves a `bind` value as a component path (esm-spec
// §10.10.1) — a system or loader node, walking models/reaction_systems/
// data_loaders then nested `subsystems`, never terminating on a variable.
func resolvesToComponent(file *EsmFile, value string) bool {
	if file == nil {
		return false
	}
	segs := strings.Split(value, ".")
	top := segs[0]

	var subs map[string]any
	found := false
	if m, ok := file.Models[top]; ok {
		found = true
		subs = m.Subsystems
	} else if rs, ok := file.ReactionSystems[top]; ok {
		found = true
		subs = rs.Subsystems
	} else if _, ok := file.DataLoaders[top]; ok {
		found = true
		subs = nil // data loaders are leaves (no subsystems)
	}
	if !found {
		return false
	}
	for i := 1; i < len(segs); i++ {
		if subs == nil {
			return false
		}
		node, ok := subs[segs[i]]
		if !ok {
			return false
		}
		nodeMap, ok := node.(map[string]any)
		if !ok {
			return false
		}
		subs, _ = nodeMap["subsystems"].(map[string]any)
	}
	return true
}

// expandCouplingImports expands every `coupling_import` entry in `file.Coupling`
// into concrete edges, splicing them in the position of the import entry
// (esm-spec §10.10.3). Returns the effective coupling slice, or nil if the file
// has no `coupling` block. Non-import entries pass through untouched; a file
// with no `coupling_import` entries needs no options and returns `file.Coupling`
// verbatim.
func expandCouplingImports(file *EsmFile, opts CouplingImportOptions) ([]any, error) {
	if file == nil {
		return nil, nil
	}
	coupling := file.Coupling
	if coupling == nil {
		return nil, nil
	}

	hasImport := false
	for _, e := range coupling {
		if ce, ok := e.(CouplingEntry); ok && ce.GetType() == "coupling_import" {
			hasImport = true
			break
		}
	}
	if !hasImport {
		return coupling, nil
	}

	loadRef := opts.LoadRef
	if loadRef == nil {
		loadRef = defaultLoadCouplingRef
	}
	basePath := opts.BasePath
	if basePath == "" {
		basePath = "."
	}

	out := make([]any, 0, len(coupling))
	for _, e := range coupling {
		var imp CouplingImport
		switch v := e.(type) {
		case CouplingImport:
			imp = v
		case *CouplingImport:
			imp = *v
		default:
			out = append(out, e)
			continue
		}
		if imp.Type != "coupling_import" {
			out = append(out, e)
			continue
		}

		lib, err := loadRef(imp.Ref, basePath)
		if err != nil {
			var etErr *ExpressionTemplateError
			if errors.As(err, &etErr) {
				return nil, err
			}
			return nil, newETErr("coupling_import_unresolved",
				fmt.Sprintf("coupling_import ref '%s' failed to load: %v", imp.Ref, err))
		}

		// imp.Bind is only read downstream (validated + used as the rewrite
		// table), so pass it directly instead of a defensive copy.
		expanded, err := expandCouplingImportEntry(lib, imp.Ref, imp.Bind, file)
		if err != nil {
			return nil, err
		}
		for _, ce := range expanded {
			out = append(out, ce)
		}
	}
	return out, nil
}
