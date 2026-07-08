package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestArrayedVarsFixtures verifies that the shape and location fields
// introduced by the discretization RFC §10.2 parse, round-trip, and expose
// the expected values for each fixture class (scalar, 1D, 2D, vertex).
func TestArrayedVarsFixtures(t *testing.T) {
	fixtureDir := filepath.Join("..", "..", "..", "..", "tests", "fixtures", "arrayed_vars")

	type check func(*testing.T, *EsmFile)

	cases := []struct {
		file  string
		model string
		check check
	}{
		{
			file:  "scalar_no_shape.esm",
			model: "Scalar0D",
			check: func(t *testing.T, esm *EsmFile) {
				v := esm.Models["Scalar0D"].Variables["x"]
				assert.Nil(t, v.Shape, "unset shape should stay nil (scalar)")
				assert.Equal(t, "", v.Location, "unset location should stay empty")
			},
		},
		{
			file:  "scalar_explicit.esm",
			model: "ScalarExplicit",
			check: func(t *testing.T, esm *EsmFile) {
				v := esm.Models["ScalarExplicit"].Variables["mass"]
				// An empty-list shape is semantically equivalent to omission
				// (both mean scalar). Bindings may normalize one to the
				// other on round-trip; we only require zero dimensions.
				assert.Len(t, v.Shape, 0, "explicit empty shape must parse as zero dimensions")
				assert.Equal(t, "", v.Location)
			},
		},
		{
			file:  "one_d.esm",
			model: "Diffusion1D",
			check: func(t *testing.T, esm *EsmFile) {
				v := esm.Models["Diffusion1D"].Variables["c"]
				assert.Equal(t, []string{"x"}, v.Shape)
				assert.Equal(t, "cell_center", v.Location)
				d := esm.Models["Diffusion1D"].Variables["D"]
				assert.Nil(t, d.Shape)
				assert.Equal(t, "", d.Location)
			},
		},
		{
			file:  "two_d_faces.esm",
			model: "StaggeredFlow2D",
			check: func(t *testing.T, esm *EsmFile) {
				p := esm.Models["StaggeredFlow2D"].Variables["p"]
				assert.Equal(t, []string{"x", "y"}, p.Shape)
				assert.Equal(t, "cell_center", p.Location)
				u := esm.Models["StaggeredFlow2D"].Variables["u"]
				assert.Equal(t, []string{"x", "y"}, u.Shape)
				assert.Equal(t, "x_face", u.Location)
			},
		},
		{
			file:  "vertex_located.esm",
			model: "VertexScalar2D",
			check: func(t *testing.T, esm *EsmFile) {
				phi := esm.Models["VertexScalar2D"].Variables["phi"]
				assert.Equal(t, []string{"x", "y"}, phi.Shape)
				assert.Equal(t, "vertex", phi.Location)
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			path := filepath.Join(fixtureDir, tc.file)
			raw, err := os.ReadFile(path)
			require.NoError(t, err)

			var loaded EsmFile
			require.NoError(t, json.Unmarshal(raw, &loaded))
			tc.check(t, &loaded)

			// Round-trip: loaded -> JSON -> reloaded must match on the
			// arrayed-variable fields.
			reserialized, err := json.Marshal(&loaded)
			require.NoError(t, err)

			var reloaded EsmFile
			require.NoError(t, json.Unmarshal(reserialized, &reloaded))
			tc.check(t, &reloaded)

			// And the model variable map must match one-for-one. Treat nil
			// and empty-slice shape as equivalent (both mean scalar).
			orig := loaded.Models[tc.model].Variables
			rt := reloaded.Models[tc.model].Variables
			require.Equal(t, len(orig), len(rt))
			for name, ov := range orig {
				rv, ok := rt[name]
				require.True(t, ok, "variable %s missing after round-trip", name)
				if len(ov.Shape) == 0 {
					assert.Len(t, rv.Shape, 0, "scalar shape mismatch on %s", name)
				} else {
					assert.Equal(t, ov.Shape, rv.Shape, "shape mismatch on %s", name)
				}
				assert.Equal(t, ov.Location, rv.Location, "location mismatch on %s", name)
			}
		})
	}
}
