package esm

// Round-trip coverage for fractional stoichiometric coefficients (gt-1e96).
// Exercises the v0.2.x schema relaxation of StoichiometryEntry.stoichiometry
// from integer to positive number, using SuperFast-like isoprene oxidation
// products (0.87 CH2O, 1.86 CH3O2, …) alongside integer substrate coefficients.

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFractionalStoichiometryRoundTrip(t *testing.T) {
	wd, err := os.Getwd()
	require.NoError(t, err)
	repoRoot := filepath.Join(wd, "..", "..", "..", "..")
	path := filepath.Join(repoRoot, "tests", "valid", "fractional_stoichiometry.esm")

	parsed, err := Load(path)
	require.NoError(t, err)
	require.NotNil(t, parsed)

	rs, ok := parsed.ReactionSystems["SuperFastLike"]
	require.True(t, ok, "SuperFastLike reaction system missing")
	require.Len(t, rs.Reactions, 4)

	r1 := rs.Reactions[0]
	var ch2o, ch3o2 *SubstrateProduct
	for i := range r1.Products {
		switch r1.Products[i].Species {
		case "CH2O":
			ch2o = &r1.Products[i]
		case "CH3O2":
			ch3o2 = &r1.Products[i]
		}
	}
	require.NotNil(t, ch2o, "R1 missing CH2O product")
	require.NotNil(t, ch3o2, "R1 missing CH3O2 product")
	assert.InDelta(t, 0.87, ch2o.Stoichiometry, 1e-12)
	assert.InDelta(t, 1.86, ch3o2.Stoichiometry, 1e-12)

	r4 := rs.Reactions[3]
	require.Len(t, r4.Substrates, 1)
	assert.Equal(t, 2.0, r4.Substrates[0].Stoichiometry)
	assert.True(t, math.Trunc(r4.Substrates[0].Stoichiometry) == r4.Substrates[0].Stoichiometry,
		"backward-compat: integer substrate coefficient must round-trip as a whole number")

	// JSON round-trip parity.
	first, err := json.Marshal(parsed)
	require.NoError(t, err)

	var reparsed EsmFile
	require.NoError(t, json.Unmarshal(first, &reparsed))

	second, err := json.Marshal(&reparsed)
	require.NoError(t, err)
	assert.JSONEq(t, string(first), string(second))
}
