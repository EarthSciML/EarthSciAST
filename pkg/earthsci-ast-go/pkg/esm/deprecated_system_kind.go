package esm

// The `deprecated_system_kind` warning (esm 2.4.0).
//
// esm 2.4.0 dropped the "pde" system kind: the §6.3.1 derivation has no
// spatial-derivative rule. A model that still DECLARES `"system_kind": "pde"`
// is not refused. The value is kept as written (emit and round trip are
// unchanged), DeclaredSystemKind treats it as absent so the model is its
// derived kind and `system_kind_mismatch` is never reported for it, and the
// load writes one warning naming every such model by JSON pointer.

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// deprecatedSystemKindSites returns the JSON pointer of the `system_kind` field
// of every model (subsystems included) that declares the dropped value "pde",
// sorted.
func deprecatedSystemKindSites(file *ESMFile) []string {
	if file == nil {
		return nil
	}
	var out []string
	for name, model := range file.Models {
		basePath := "/models/" + escapeJSONPointerSegment(name)
		if model.SystemKind != nil && *model.SystemKind == SystemKindPDE {
			out = append(out, basePath+"/system_kind")
		}
		out = rawSubsystemSystemKindSites(model.Subsystems, basePath, out)
	}
	sort.Strings(out)
	return out
}

// rawSubsystemSystemKindSites walks a model's decoded `subsystems` map.
func rawSubsystemSystemKindSites(subs map[string]any, basePath string, out []string) []string {
	for name, raw := range subs {
		sub, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		path := basePath + "/subsystems/" + escapeJSONPointerSegment(name)
		if kind, _ := sub["system_kind"].(string); kind == SystemKindPDE {
			out = append(out, path+"/system_kind")
		}
		nested, _ := sub["subsystems"].(map[string]any)
		out = rawSubsystemSystemKindSites(nested, path, out)
	}
	return out
}

// warnDeprecatedSystemKind emits the one `deprecated_system_kind` load warning
// when file declares "pde" on any model. Written to stderr, like every other
// Go load warning (warnDeprecatedOps, warnDeprecatedRecordsPerSample).
func warnDeprecatedSystemKind(file *ESMFile) {
	sites := deprecatedSystemKindSites(file)
	if len(sites) == 0 {
		return
	}
	fmt.Fprintf(os.Stderr,
		"warning: %s: the system_kind value \"pde\" is deprecated (esm 2.4.0) and ignored; "+
			"the model is treated as its derived kind. Declared at: %s.\n",
		codeDeprecatedSystemKind, strings.Join(sites, ", "))
}
