package esm

import (
	"encoding/json"
	"fmt"
	"os"
)

// marshalCanonical pre-processes v with canonicalizeForJSON so every float
// is emitted in discretization RFC §5.4.6 form (trailing ".0" for
// integer-valued magnitudes in [−1e21+1, 1e21−1], exponent form outside
// that range) before running encoding/json. Without this pass Go emits
// float64(1.0) as "1", which collides with int64(1) on the wire and
// breaks the round-trip int/float node distinction.
func marshalCanonical(v any, indent bool) ([]byte, error) {
	canonical, err := canonicalizeForJSON(v)
	if err != nil {
		return nil, err
	}
	canonical, err = restoreUnresolvedTopLevelMounts(canonical, v)
	if err != nil {
		return nil, err
	}
	if indent {
		return json.MarshalIndent(canonical, "", "  ")
	}
	return json.Marshal(canonical)
}

// restoreUnresolvedTopLevelMounts writes an UNRESOLVED top-level `models.<k>`
// `{ref}` MOUNT EDGE back out as the edge it was authored as.
//
// `ESMFile.Models` is a `map[string]Model`, so a bare `{ref}` entry decodes to
// an EMPTY Model. LoadString snapshots the edges off the text before that
// decode and the ref resolver consumes them — but LoadString and LoadDocument
// do NOT resolve refs (only LoadPath does), so a document that came in through
// either and goes out again would otherwise emit `{"variables": null}` where
// the mount was: the `ref`, its `bindings` and its `index_set_rename` gone,
// with no error anywhere.
//
// The `subsystems.<k>` form never had this problem, because that map is
// `map[string]any` and keeps the edge verbatim. esm-spec §4.7 "Two mount forms,
// one mechanism" is what says the two must not differ here either.
//
// Only edges the resolver has NOT consumed are still in the map, so this can
// never overwrite a mount that did resolve.
func restoreUnresolvedTopLevelMounts(canonical any, v any) (any, error) {
	file, ok := v.(*ESMFile)
	if !ok || len(file.topLevelModelRefs) == 0 {
		return canonical, nil
	}
	root, ok := canonical.(map[string]any)
	if !ok {
		return canonical, nil
	}
	models, ok := root["models"].(map[string]any)
	if !ok {
		return canonical, nil
	}
	for _, name := range sortedKeys(file.topLevelModelRefs) {
		if _, present := models[name]; !present {
			continue
		}
		edge, err := canonicalizeForJSON(file.topLevelModelRefs[name])
		if err != nil {
			return nil, err
		}
		models[name] = edge
	}
	return canonical, nil
}

// serializeDocument is the shared serialization core for the four exported
// entry points (ToJSON/ToJSONCompact return the string; WritePath/
// WritePathCompact persist it). It validates the file (unlike the raw
// (*ESMFile).ToJSON METHOD, which is a plain marshal) and emits canonical
// JSON, indented when indent is true and compact otherwise.
func serializeDocument(file *ESMFile, indent bool) (string, error) {
	if file == nil {
		return "", fmt.Errorf("cannot serialize nil ESM file")
	}

	// Validate the file before serializing
	if err := file.ValidateStruct(); err != nil {
		return "", fmt.Errorf("validation failed before serialization: %w", err)
	}

	jsonData, err := marshalCanonical(file, indent)
	if err != nil {
		return "", fmt.Errorf("failed to marshal ESM file to JSON: %w", err)
	}

	return string(jsonData), nil
}

// ToJSON validates an ESM file and returns it as an indented canonical JSON
// string. PURE — it never touches disk; WritePath is the writer.
//
// Go was the only binding whose NAMES already distinguished serializing from
// writing (Serialize/SaveToFile) — and the only one whose names matched
// nobody else's. These are those functions under the shared names.
func ToJSON(file *ESMFile) (string, error) {
	out, err := serializeDocument(file, true)
	if err != nil {
		return out, err
	}
	return raiseFaqEsmFloor(out), nil
}

// raiseFaqEsmFloor raises an emitted document's declared `esm` to 1.1.0 when it
// CONTAINS a `faq` node but declares less.
//
// Like the §9.6.4 rule-8 template stamp this is a FLOOR — it only ever raises.
// A document can come to CONTAIN `faq` without ever spelling it: a 1.0.0 parent that mounts a subsystem whose child uses `faq` has the child inlined at load, and emitting that as 1.0.0 writes a document the `faq_version_too_old` gate then refuses to read back.
// The load-time gate cannot catch it — the parent's AUTHORED bytes are legal — so the stamp closes it here.
// See docs/content/rfcs/faq-node-rename.md §5.5.
func raiseFaqEsmFloor(jsonStr string) string {
	_, _, _, hasFaq := scanOpAliases(jsonStr)
	if !hasFaq {
		return jsonStr
	}
	declared, below := declaredEsmBelowV11(jsonStr)
	if !below {
		return jsonStr
	}
	return raiseEsmFloorToV11(jsonStr, declared)
}

// ToJSONCompact validates an ESM file and returns it as a compact canonical
// JSON string (no indentation). A separate function rather than a ToJSON
// option because Go has no default arguments.
func ToJSONCompact(file *ESMFile) (string, error) {
	out, err := serializeDocument(file, false)
	if err != nil {
		return out, err
	}
	return raiseFaqEsmFloor(out), nil
}

// WritePath writes an ESM file to path as indented canonical JSON. It returns
// only an error, never the payload: no function in this API both writes and
// hands back the serialized bytes — call ToJSON when you want the string.
func WritePath(file *ESMFile, path string) error {
	jsonStr, err := ToJSON(file)
	if err != nil {
		return err
	}

	// Write to file
	if err := writeFile(path, []byte(jsonStr)); err != nil {
		return fmt.Errorf("failed to write file %s: %w", path, err)
	}

	return nil
}

// WritePathCompact writes an ESM file to path in the compact canonical form.
func WritePathCompact(file *ESMFile, path string) error {
	jsonStr, err := ToJSONCompact(file)
	if err != nil {
		return err
	}

	// Write to file
	if err := writeFile(path, []byte(jsonStr)); err != nil {
		return fmt.Errorf("failed to write file %s: %w", path, err)
	}

	return nil
}

// writeFile is a simple file writing helper.
func writeFile(path string, data []byte) error {
	return os.WriteFile(path, data, 0644)
}

// SerializeExpression serializes just an expression to JSON
func SerializeExpression(expr Expression) (string, error) {
	jsonData, err := marshalCanonical(expr, true)
	if err != nil {
		return "", fmt.Errorf("failed to serialize expression: %w", err)
	}
	return string(jsonData), nil
}

// SerializeExpressionCompact serializes just an expression to compact JSON
func SerializeExpressionCompact(expr Expression) (string, error) {
	jsonData, err := marshalCanonical(expr, false)
	if err != nil {
		return "", fmt.Errorf("failed to serialize expression: %w", err)
	}
	return string(jsonData), nil
}

// SerializeModel serializes just a model to JSON
func SerializeModel(model *Model) (string, error) {
	if model == nil {
		return "", fmt.Errorf("cannot serialize nil model")
	}

	jsonData, err := marshalCanonical(model, true)
	if err != nil {
		return "", fmt.Errorf("failed to serialize model: %w", err)
	}
	return string(jsonData), nil
}

// SerializeReactionSystem serializes just a reaction system to JSON
func SerializeReactionSystem(system *ReactionSystem) (string, error) {
	if system == nil {
		return "", fmt.Errorf("cannot serialize nil reaction system")
	}

	jsonData, err := marshalCanonical(system, true)
	if err != nil {
		return "", fmt.Errorf("failed to serialize reaction system: %w", err)
	}
	return string(jsonData), nil
}
