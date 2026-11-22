package esm

import (
	"fmt"
	"strings"
)

// ---------------------------------------------------------------------------
// Spec-version gate (esm-spec §9.6.5)
// ---------------------------------------------------------------------------

// RejectTemplateImportsPreV08 rejects the §9.7 constructs in files declaring
// esm < 0.8.0: `operator_imports`, top-level `operators`
// (template-library files), and `metaparameters` arrive at esm 0.8.0; files
// declaring an earlier version that carry any of them are rejected with
// `operator_import_version_too_old` (esm-spec §9.6.5). Mirrors
// RejectExpressionTemplatesPreV04 for the §9.7 constructs.
func RejectTemplateImportsPreV08(view map[string]any) error {
	if !esmVersionBelow(view, 0, 8) {
		return nil
	}
	esmRaw, _ := view["esm"].(string)
	offences := []string{}
	if _, has := view["operators"]; has {
		offences = append(offences, "/operators")
	}
	if _, has := view["metaparameters"]; has {
		offences = append(offences, "/metaparameters")
	}
	if _, has := view["operator_imports"]; has {
		offences = append(offences, "/operator_imports")
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			if compObj, ok := comps[cname].(map[string]any); ok {
				if _, has := compObj["operator_imports"]; has {
					offences = append(offences,
						fmt.Sprintf("/%s/%s/operator_imports", kind, cname))
				}
			}
		}
	}
	if len(offences) > 0 {
		return newETErr(
			CodeTemplateImportVersionTooOld,
			fmt.Sprintf("operator_imports / top-level operators / metaparameters require esm >= 0.8.0; file declares %s (offending paths: %s)",
				esmRaw, strings.Join(offences, ", ")),
		)
	}
	return nil
}

// isTemplateLibraryDoc reports whether `view` has the template-library-file
// FORM (top-level `operators`, esm-spec §9.7.1). Purity (no models
// / reaction systems / loaders / coupling / domain) is checked separately at
// import edges.
func isTemplateLibraryDoc(view map[string]any) bool {
	if view == nil {
		return false
	}
	_, has := view["operators"]
	return has
}

// rejectImpureTemplateLibrary rejects a document carrying top-level
// `operators` beside a component payload. Such a document is a
// template-library file (esm-spec §9.7.1), which MUST NOT declare `models`,
// `reaction_systems`, `data_sources`, `coupling`, or `domain`. Rewrite rules are
// component-local (§9.6.3 constraint 4), so beside a component the block is
// visible to nothing: the document is rejected with
// `operator_library_illegal_payload` rather than loaded with the templates
// silently inert. An import target is held to the same rule at the edge, as
// `operator_import_not_library`.
func rejectImpureTemplateLibrary(view map[string]any) error {
	if !isTemplateLibraryDoc(view) {
		return nil
	}
	present := []string{}
	for _, k := range libraryForbiddenKeys {
		if _, has := view[k]; has {
			present = append(present, "`"+k+"`")
		}
	}
	if len(present) == 0 {
		return nil
	}
	return newETErr(CodeTemplateLibraryIllegalPayload,
		"top-level `operators` makes this document a template-library file, which MUST NOT declare "+strings.Join(present, ", ")+
			" (esm-spec §9.7.1); templates declared there are visible to no component. Declare them in the component's own `operators` block (§9.6.1), or move them to a template-library file and import it with `operator_imports` (§9.7.2)")
}
