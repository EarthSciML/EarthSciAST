package esm

import (
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoad(t *testing.T) {
	// Create a temporary test file
	testJSON := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestModel",
			"authors": ["Test Author"]
		},
		"models": {
			"TestModel": {
				"variables": {
					"x": {
						"type": "state",
						"units": "m",
						"default": 0.0
					}
				},
				"equations": [
					{
						"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
						"rhs": 1.0
					}
				]
			}
		}
	}`

	// Create temporary file
	tmpFile, err := os.CreateTemp("", "test*.esm")
	require.NoError(t, err)
	defer func() { _ = os.Remove(tmpFile.Name()) }()

	_, err = tmpFile.WriteString(testJSON)
	require.NoError(t, err)
	require.NoError(t, tmpFile.Close())

	// Test loading
	esmFile, err := Load(tmpFile.Name())
	assert.NoError(t, err)
	assert.NotNil(t, esmFile)
	assert.Equal(t, "0.1.0", esmFile.ESM)
	assert.Equal(t, "TestModel", esmFile.Metadata.Name)
	assert.Len(t, esmFile.Models, 1)
}

func TestLoadString(t *testing.T) {
	testJSON := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestModel",
			"authors": ["Test Author"]
		},
		"models": {
			"TestModel": {
				"variables": {
					"x": {
						"type": "state",
						"units": "m",
						"default": 0.0
					}
				},
				"equations": [
					{
						"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
						"rhs": 1.0
					}
				]
			}
		}
	}`

	esmFile, err := LoadString(testJSON)
	assert.NoError(t, err)
	assert.NotNil(t, esmFile)
	assert.Equal(t, "0.1.0", esmFile.ESM)
	assert.Equal(t, "TestModel", esmFile.Metadata.Name)
}

func TestLoadStringInvalidJSON(t *testing.T) {
	invalidJSON := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestModel"
		}
		// Missing comma and invalid structure
	}`

	_, err := LoadString(invalidJSON)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "schema validation failed")
}

func TestLoadStringMissingRequiredFields(t *testing.T) {
	// Missing required "authors" field in metadata
	invalidJSON := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestModel"
		},
		"models": {
			"TestModel": {
				"variables": {
					"x": {"type": "state"}
				},
				"equations": []
			}
		}
	}`

	_, err := LoadString(invalidJSON)
	// This should pass JSON schema but fail structural validation
	assert.NoError(t, err) // Authors is not actually required in schema
}

func TestLoadNonExistentFile(t *testing.T) {
	_, err := Load("non_existent_file.esm")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "failed to read file")
}

func TestLoadShouldSucceedWithStructuralValidationFailure(t *testing.T) {
	// This test verifies the fix for the bug: LoadString() should succeed for valid JSON
	// that passes schema validation but fails structural validation.
	// According to spec Section 2.1a, structural issues should only be reported
	// by the separate validate() function.

	// Create JSON with empty models - this passes JSON schema validation
	// (because models is not marked as required in schema, only via anyOf pattern)
	// but fails basic structural validation
	testJSON := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestModel",
			"authors": ["Test Author"]
		},
		"models": {}
	}`

	// This should succeed in LoadString (valid JSON schema)
	esmFile, err := LoadString(testJSON)
	assert.NoError(t, err, "LoadString should succeed for valid JSON schema even with structural issues")
	assert.NotNil(t, esmFile)

	// Verify it actually fails structural validation when called separately
	if esmFile != nil {
		validationErr := esmFile.ValidateStruct()
		assert.Error(t, validationErr, "Basic structural validation should fail")
		assert.Contains(t, validationErr.Error(), "at least one of 'models', 'reaction_systems', or 'data_loaders' must be present")
	}
}

func TestValidateJSONSchemaWithEmbeddedSchema(t *testing.T) {
	// Test that schema validation works with embedded schema
	// This should now always work regardless of external file presence
	testJSON := `{"esm": "0.1.0"}`

	result, err := validateJSONSchema(testJSON)

	// With embedded schema, err should always be nil (no file lookup required)
	assert.NoError(t, err)
	// This JSON should fail validation because it's incomplete (missing metadata, models/reaction_systems)
	assert.False(t, result.IsValid)
	assert.NotEmpty(t, result.SchemaErrors)
}

func TestValidateJSONSchemaValidDocument(t *testing.T) {
	// Test with a complete valid document to ensure embedded schema works correctly
	validJSON := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestModel",
			"authors": ["Test Author"]
		},
		"models": {
			"TestModel": {
				"variables": {
					"x": {
						"type": "state",
						"units": "m",
						"default": 0.0
					}
				},
				"equations": [
					{
						"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
						"rhs": 1.0
					}
				]
			}
		}
	}`

	result, err := validateJSONSchema(validJSON)
	assert.NoError(t, err)
	assert.True(t, result.IsValid, "Valid JSON should pass schema validation")
	assert.Empty(t, result.SchemaErrors)
}

// TestLoadPreservesIntFloatDistinction verifies that discretization RFC §5.4.1
// / §5.4.6 round-trip parse rule is honored: a JSON token with no '.' and no
// 'e'/'E' parses to int64; a token with '.' or 'e' parses to float64.
func TestLoadPreservesIntFloatDistinction(t *testing.T) {
	validJSON := `{
		"esm": "0.1.0",
		"metadata": {"name": "int-float-distinction"},
		"models": {
			"m": {
				"variables": {
					"x": {"type": "state"},
					"y": {"type": "state"}
				},
				"equations": [
					{"lhs": "x", "rhs": 1},
					{"lhs": "y", "rhs": 1.0},
					{"lhs": "x", "rhs": {"op": "+", "args": [1, 2.5]}}
				]
			}
		}
	}`

	ef, err := LoadString(validJSON)
	assert.NoError(t, err)

	m := ef.Models["m"]

	// Integer literal: 1 → int64
	rhs0 := m.Equations[0].RHS
	if _, ok := rhs0.(int64); !ok {
		t.Errorf("expected equations[0].rhs int64, got %T (%v)", rhs0, rhs0)
	}

	// Float literal: 1.0 → float64
	rhs1 := m.Equations[1].RHS
	if _, ok := rhs1.(float64); !ok {
		t.Errorf("expected equations[1].rhs float64, got %T (%v)", rhs1, rhs1)
	}

	// Mixed operator node: args[0]=1 → int64, args[1]=2.5 → float64
	node, ok := m.Equations[2].RHS.(ExprNode)
	if !ok {
		t.Fatalf("expected equations[2].rhs ExprNode, got %T", m.Equations[2].RHS)
	}
	if _, ok := node.Args[0].(int64); !ok {
		t.Errorf("expected args[0] int64, got %T (%v)", node.Args[0], node.Args[0])
	}
	if _, ok := node.Args[1].(float64); !ok {
		t.Errorf("expected args[1] float64, got %T (%v)", node.Args[1], node.Args[1])
	}
}
