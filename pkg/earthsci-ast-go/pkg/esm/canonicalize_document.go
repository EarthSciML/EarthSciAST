package esm

// The document-level canonical step (esm-spec §4.8.2 "Canonical spelling").

// documentMapKeys are the object properties whose value is a NAME-KEYED map
// (esm-schema.json): a map's keys are names, never fields, so a variable NAMED
// `units` is not a units string. The same list in every binding.
var documentMapKeys = map[string]bool{
	"bind": true, "bindings": true, "coordinates": true, "coords": true,
	"coupling_roles": true, "data_sources": true, "enums": true,
	"expression_template_imports": true, "expression_templates": true,
	"guesses": true, "index_set_rename": true, "index_sets": true,
	"initial_conditions": true, "map": true, "metaparameters": true,
	"models": true, "parameter_overrides": true, "parameters": true,
	"pinned_coords": true, "ranges": true, "reaction_systems": true,
	"rebind": true, "rename": true, "species": true, "subsystems": true,
	"translate": true, "url_substitutions": true, "variables": true,
	"where": true,
}

// documentFreeKeys are the free-form objects (schema
// `additionalProperties: true`), never descended.
var documentFreeKeys = map[string]bool{
	"attrs": true, "config": true, "metadata": true, "reader_options": true, "x_esd": true,
}

// CanonicalizeDocument is the document-level canonical step: every units
// string of a decoded document (the JSON value ToJSON writes and LoadDocument
// reads, as produced by encoding/json into `any`) takes the canonical unit
// spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).
//
// That is every `units` and `default_units` string of a variable, species,
// parameter, coordinate or `const` node, wherever it sits: nested subsystems,
// template bodies, tests, coupling entries. Free-form objects (`metadata`,
// `x_esd`, `attrs`, `config`, `reader_options`) are not touched, and neither
// are the keys of name-keyed maps. The input is not mutated and nothing else
// changes.
func CanonicalizeDocument(doc any) any {
	return canonicalizeDocumentValue(doc, false)
}

func canonicalizeDocumentValue(value any, isMap bool) any {
	switch v := value.(type) {
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = canonicalizeDocumentValue(item, false)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, item := range v {
			s, isString := item.(string)
			switch {
			case isMap:
				out[k] = canonicalizeDocumentValue(item, false)
			case (k == "units" || k == "default_units") && isString:
				out[k] = canonicalUnitSpelling(s)
			case documentFreeKeys[k]:
				out[k] = item
			default:
				out[k] = canonicalizeDocumentValue(item, documentMapKeys[k])
			}
		}
		return out
	default:
		return value
	}
}
