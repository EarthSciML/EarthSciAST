package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestStructuralOpsDisplayFixtures drives the shared cross-language rendering
// contract fixtures at tests/display/structural_ops.json through the Go
// pretty-printer. Every structural / array-query op MUST render byte-identically
// across all bindings (TypeScript is the reference). Go implements the unicode
// and latex formats (there is no ToAscii), so this asserts those two against the
// fixture's canonical strings. See tests/display/RENDERING_CONTRACT.md.
func TestStructuralOpsDisplayFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	require.NoError(t, err)
	path := filepath.Join(repoRoot, "tests", "display", "structural_ops.json")

	data, err := os.ReadFile(path)
	require.NoError(t, err, "read structural_ops.json")

	var groups []struct {
		Name  string `json:"name"`
		Tests []struct {
			Name    string          `json:"name"`
			Input   json.RawMessage `json:"input"`
			Unicode string          `json:"unicode"`
			Latex   string          `json:"latex"`
			Ascii   string          `json:"ascii"`
		} `json:"tests"`
	}
	require.NoError(t, json.Unmarshal(data, &groups), "parse structural_ops.json")
	require.NotEmpty(t, groups, "fixture file must contain at least one group")

	count := 0
	for _, g := range groups {
		for _, tc := range g.Tests {
			tc := tc
			count++
			t.Run(tc.Name, func(t *testing.T) {
				expr, err := UnmarshalExpression(tc.Input)
				require.NoError(t, err, "unmarshal input")

				assert.Equal(t, tc.Unicode, ToUnicode(expr), "unicode mismatch")
				assert.Equal(t, tc.Latex, ToLatex(expr), "latex mismatch")
			})
		}
	}
	require.Positive(t, count, "fixture file yielded no test cases")
}
