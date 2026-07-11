package esm

import (
	"fmt"
	"strings"
)

// ---------------------------------------------------------------------------
// Spec-version gate (esm-spec §9.6.5)
// ---------------------------------------------------------------------------

// RejectTemplateImportsPreV08 rejects the §9.7 constructs in files declaring
// esm < 0.8.0: `expression_template_imports`, top-level `expression_templates`
// (template-library files), and `metaparameters` arrive at esm 0.8.0; files
// declaring an earlier version that carry any of them are rejected with
// `template_import_version_too_old` (esm-spec §9.6.5). Mirrors
// RejectExpressionTemplatesPreV04 for the §9.7 constructs.
func RejectTemplateImportsPreV08(view map[string]any) error {
	if !esmVersionBelow(view, 0, 8) {
		return nil
	}
	esmRaw, _ := view["esm"].(string)
	offences := []string{}
	if _, has := view["expression_templates"]; has {
		offences = append(offences, "/expression_templates")
	}
	if _, has := view["metaparameters"]; has {
		offences = append(offences, "/metaparameters")
	}
	if _, has := view["expression_template_imports"]; has {
		offences = append(offences, "/expression_template_imports")
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			if compObj, ok := comps[cname].(map[string]any); ok {
				if _, has := compObj["expression_template_imports"]; has {
					offences = append(offences,
						fmt.Sprintf("/%s/%s/expression_template_imports", kind, cname))
				}
			}
		}
	}
	if len(offences) > 0 {
		return newETErr(
			"template_import_version_too_old",
			fmt.Sprintf("expression_template_imports / top-level expression_templates / metaparameters require esm >= 0.8.0; file declares %s (offending paths: %s)",
				esmRaw, strings.Join(offences, ", ")),
		)
	}
	return nil
}

// isTemplateLibraryDoc reports whether `view` has the template-library-file
// FORM (top-level `expression_templates`, esm-spec §9.7.1). Purity (no models
// / reaction systems / loaders / coupling / domain) is checked separately at
// import edges.
func isTemplateLibraryDoc(view map[string]any) bool {
	if view == nil {
		return false
	}
	_, has := view["expression_templates"]
	return has
}
