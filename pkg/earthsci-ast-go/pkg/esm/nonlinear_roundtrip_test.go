package esm

// Round-trip coverage for Model-level initialization_equations, guesses,
// and system_kind (gt-ebuq). Exercises ISORROPIA-shape nonlinear equilibrium
// and Mogi-shape algebraic surface-deformation fixtures.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func loadNonlinearFixture(t *testing.T, rel string) *EsmFile {
	t.Helper()
	wd, err := os.Getwd()
	require.NoError(t, err)
	repoRoot := filepath.Join(wd, "..", "..", "..", "..")
	path := filepath.Join(repoRoot, "tests", "valid", rel)
	parsed, err := Load(path)
	require.NoError(t, err)
	require.NotNil(t, parsed)
	return parsed
}

func TestNonlinearIsorropiaShapeRoundTrip(t *testing.T) {
	parsed := loadNonlinearFixture(t, "nonlinear_isorropia_shape.esm")

	model, ok := parsed.Models["IsorropiaEq"]
	require.True(t, ok)
	require.NotNil(t, model.SystemKind)
	assert.Equal(t, "nonlinear", *model.SystemKind)
	assert.Len(t, model.InitializationEquations, 2)
	assert.Len(t, model.Guesses, 2)

	data, err := json.Marshal(parsed)
	require.NoError(t, err)
	var reparsed EsmFile
	require.NoError(t, json.Unmarshal(data, &reparsed))

	first, err := json.Marshal(parsed)
	require.NoError(t, err)
	second, err := json.Marshal(&reparsed)
	require.NoError(t, err)
	assert.JSONEq(t, string(first), string(second))
}

func TestNonlinearMogiShapeRoundTrip(t *testing.T) {
	parsed := loadNonlinearFixture(t, "nonlinear_mogi_shape.esm")

	model, ok := parsed.Models["MogiModel"]
	require.True(t, ok)
	require.NotNil(t, model.SystemKind)
	assert.Equal(t, "nonlinear", *model.SystemKind)
	assert.Empty(t, model.InitializationEquations)
	assert.Empty(t, model.Guesses)

	data, err := json.Marshal(parsed)
	require.NoError(t, err)
	var reparsed EsmFile
	require.NoError(t, json.Unmarshal(data, &reparsed))

	first, err := json.Marshal(parsed)
	require.NoError(t, err)
	second, err := json.Marshal(&reparsed)
	require.NoError(t, err)
	assert.JSONEq(t, string(first), string(second))
}
