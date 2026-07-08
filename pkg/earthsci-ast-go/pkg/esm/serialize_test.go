package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSave(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {
						Type:    "state",
						Units:   strPtr("m"),
						Default: 0.0,
					},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
	}

	jsonStr, err := Save(esmFile)
	assert.NoError(t, err)
	assert.NotEmpty(t, jsonStr)

	// Verify it's valid JSON
	var parsed interface{}
	err = json.Unmarshal([]byte(jsonStr), &parsed)
	assert.NoError(t, err)

	// Verify it contains expected fields
	assert.Contains(t, jsonStr, `"esm": "0.1.0"`)
	assert.Contains(t, jsonStr, `"TestModel"`)
}

func TestSaveCompact(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
	}

	jsonStr, err := SaveCompact(esmFile)
	assert.NoError(t, err)
	assert.NotEmpty(t, jsonStr)

	// Compact format should not contain indentation
	assert.NotContains(t, jsonStr, "\n  ")

	// Verify it's valid JSON
	var parsed interface{}
	err = json.Unmarshal([]byte(jsonStr), &parsed)
	assert.NoError(t, err)
}

func TestSaveNilFile(t *testing.T) {
	_, err := Save(nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "cannot serialize nil ESM file")
}

func TestSaveInvalidFile(t *testing.T) {
	// Create an invalid ESM file (missing required models/reaction_systems)
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		// Missing both Models and ReactionSystems
	}

	_, err := Save(esmFile)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "validation failed before serialization")
}

func TestSaveToFile(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
	}

	// Create temporary file
	tmpDir := os.TempDir()
	tmpFile := filepath.Join(tmpDir, "test_output.esm")
	defer func() { _ = os.Remove(tmpFile) }()

	err := SaveToFile(esmFile, tmpFile)
	assert.NoError(t, err)

	// Verify file was created and contains expected content
	content, err := os.ReadFile(tmpFile)
	assert.NoError(t, err)
	assert.Contains(t, string(content), `"esm": "0.1.0"`)
}

func TestSaveCompactToFile(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
	}

	// Create temporary file
	tmpDir := os.TempDir()
	tmpFile := filepath.Join(tmpDir, "test_output_compact.esm")
	defer func() { _ = os.Remove(tmpFile) }()

	err := SaveCompactToFile(esmFile, tmpFile)
	assert.NoError(t, err)

	// Verify file was created
	content, err := os.ReadFile(tmpFile)
	assert.NoError(t, err)
	assert.Contains(t, string(content), `"esm":"0.1.0"`) // No spaces in compact format
}

func TestSerializeExpression(t *testing.T) {
	expr := ExprNode{
		Op:   "+",
		Args: []interface{}{"a", "b"},
	}

	jsonStr, err := SerializeExpression(expr)
	assert.NoError(t, err)
	assert.NotEmpty(t, jsonStr)

	// Verify it's valid JSON
	var parsed ExprNode
	err = json.Unmarshal([]byte(jsonStr), &parsed)
	assert.NoError(t, err)
	assert.Equal(t, "+", parsed.Op)
}

func TestSerializeExpressionCompact(t *testing.T) {
	expr := ExprNode{
		Op:   "*",
		Args: []interface{}{"x", 2},
	}

	jsonStr, err := SerializeExpressionCompact(expr)
	assert.NoError(t, err)
	assert.NotEmpty(t, jsonStr)

	// Should not contain indentation
	assert.NotContains(t, jsonStr, "\n  ")

	// Verify it's valid JSON
	var parsed ExprNode
	err = json.Unmarshal([]byte(jsonStr), &parsed)
	assert.NoError(t, err)
	assert.Equal(t, "*", parsed.Op)
}

func TestSerializeModel(t *testing.T) {
	model := &Model{
		Variables: map[string]ModelVariable{
			"x": {
				Type:    "state",
				Units:   strPtr("m"),
				Default: 0.0,
			},
		},
		Equations: []Equation{
			{
				LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
				RHS: float64(1.0),
			},
		},
	}

	jsonStr, err := SerializeModel(model)
	assert.NoError(t, err)
	assert.NotEmpty(t, jsonStr)

	// Verify it's valid JSON
	var parsed Model
	err = json.Unmarshal([]byte(jsonStr), &parsed)
	assert.NoError(t, err)
	assert.Len(t, parsed.Variables, 1)
	assert.Len(t, parsed.Equations, 1)
}

func TestSerializeModelNil(t *testing.T) {
	_, err := SerializeModel(nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "cannot serialize nil model")
}

func TestSerializeReactionSystem(t *testing.T) {
	system := &ReactionSystem{
		Species: map[string]Species{
			"A": {Units: strPtr("mol/mol")},
			"B": {Units: strPtr("mol/mol")},
		},
		Parameters: map[string]Parameter{
			"k": {Units: strPtr("1/s")},
		},
		Reactions: []Reaction{
			{
				ID:         "R1",
				Substrates: []SubstrateProduct{{Species: "A", Stoichiometry: 1}},
				Products:   []SubstrateProduct{{Species: "B", Stoichiometry: 1}},
				Rate:       "k",
			},
		},
	}

	jsonStr, err := SerializeReactionSystem(system)
	assert.NoError(t, err)
	assert.NotEmpty(t, jsonStr)

	// Verify it's valid JSON
	var parsed ReactionSystem
	err = json.Unmarshal([]byte(jsonStr), &parsed)
	assert.NoError(t, err)
	assert.Len(t, parsed.Species, 2)
	assert.Len(t, parsed.Reactions, 1)
}

func TestSerializeReactionSystemNil(t *testing.T) {
	_, err := SerializeReactionSystem(nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "cannot serialize nil reaction system")
}

func TestRoundTripSerialization(t *testing.T) {
	// Create a complex ESM file
	originalFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "ComplexModel",
			Authors: []string{"Test Author"},
			License: strPtr("MIT"),
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {
						Type:    "state",
						Units:   strPtr("m"),
						Default: 1.0,
					},
					"y": {
						Type:       "observed",
						Expression: ExprNode{Op: "+", Args: []interface{}{"x", 2}},
					},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []interface{}{-0.1, "x"}},
					},
				},
			},
		},
		ReactionSystems: map[string]ReactionSystem{
			"TestReactions": {
				Species: map[string]Species{
					"A": {Units: strPtr("mol/mol"), Default: 1e-9},
				},
				Parameters: map[string]Parameter{
					"k": {Units: strPtr("1/s"), Default: 1e-3},
				},
				Reactions: []Reaction{
					{
						ID:       "R1",
						Products: []SubstrateProduct{{Species: "A", Stoichiometry: 1}},
						Rate:     "k",
					},
				},
			},
		},
	}

	// Serialize
	jsonStr, err := Save(originalFile)
	require.NoError(t, err)

	// Deserialize
	parsedFile, err := LoadString(jsonStr)
	require.NoError(t, err)

	// Compare key fields
	assert.Equal(t, originalFile.Esm, parsedFile.Esm)
	assert.Equal(t, originalFile.Metadata.Name, parsedFile.Metadata.Name)
	assert.Equal(t, len(originalFile.Models), len(parsedFile.Models))
	assert.Equal(t, len(originalFile.ReactionSystems), len(parsedFile.ReactionSystems))

	// Check model variables
	originalModel := originalFile.Models["TestModel"]
	parsedModel := parsedFile.Models["TestModel"]
	assert.Equal(t, len(originalModel.Variables), len(parsedModel.Variables))
	assert.Equal(t, originalModel.Variables["x"].Type, parsedModel.Variables["x"].Type)
}
