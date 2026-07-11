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
	if indent {
		return json.MarshalIndent(canonical, "", "  ")
	}
	return json.Marshal(canonical)
}

// save is the shared serialization core for the four exported entry points
// (Serialize/SerializeCompact return the string; SaveToFile/SaveCompactToFile
// persist it). It validates the file (unlike the raw (*ESMFile).ToJSON) and
// emits canonical JSON, indented when indent is true and compact otherwise.
func save(file *ESMFile, indent bool) (string, error) {
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

// Serialize validates an ESM file and returns it as an indented canonical JSON
// string. (The Save* verbs write to disk; Serialize* return the string.)
func Serialize(file *ESMFile) (string, error) {
	return save(file, true)
}

// SerializeCompact validates an ESM file and returns it as a compact canonical
// JSON string (no indentation).
func SerializeCompact(file *ESMFile) (string, error) {
	return save(file, false)
}

// SaveToFile saves an ESM file directly to a file path
func SaveToFile(file *ESMFile, path string) error {
	jsonStr, err := Serialize(file)
	if err != nil {
		return err
	}

	// Write to file
	if err := writeFile(path, []byte(jsonStr)); err != nil {
		return fmt.Errorf("failed to write file %s: %w", path, err)
	}

	return nil
}

// SaveCompactToFile saves an ESM file to a file path in compact format
func SaveCompactToFile(file *ESMFile, path string) error {
	jsonStr, err := SerializeCompact(file)
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
