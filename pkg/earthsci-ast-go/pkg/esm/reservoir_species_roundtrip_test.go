package esm

// Round-trip coverage for Species.constant (reservoir species) — gt-ertm.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestReservoirSpeciesConstantRoundTrip(t *testing.T) {
	wd, err := os.Getwd()
	require.NoError(t, err)
	repoRoot := filepath.Join(wd, "..", "..", "..", "..")
	path := filepath.Join(repoRoot, "tests", "valid", "reservoir_species_constant.esm")

	parsed, err := Load(path)
	require.NoError(t, err)
	require.NotNil(t, parsed)

	rs, ok := parsed.ReactionSystems["SuperFastSubset"]
	require.True(t, ok)

	for _, name := range []string{"O2", "CH4", "H2O"} {
		sp, ok := rs.Species[name]
		require.True(t, ok, "species %s missing", name)
		require.NotNil(t, sp.Constant, "species %s should have constant flag", name)
		assert.True(t, *sp.Constant, "species %s should be constant=true", name)
	}
	for _, name := range []string{"O3", "OH", "HO2"} {
		sp, ok := rs.Species[name]
		require.True(t, ok, "species %s missing", name)
		assert.Nil(t, sp.Constant, "species %s should have no constant flag", name)
	}

	first, err := json.Marshal(parsed)
	require.NoError(t, err)
	var reparsed EsmFile
	require.NoError(t, json.Unmarshal(first, &reparsed))
	second, err := json.Marshal(&reparsed)
	require.NoError(t, err)
	assert.JSONEq(t, string(first), string(second))
}
