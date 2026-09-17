package esm

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestWrtDefaultOmittedRenders pins esm-spec §4.2 on the DISPLAY path: on a `D`
// node an ABSENT `wrt` MEANS `t`, so `D(x)` renders exactly as `D(x, wrt: t)`
// does.
//
// Go was already correct everywhere the defect of EarthSciAST#407 bit — its
// classification, flatten and DAE paths all default a nil Wrt to the
// independent variable — but its renderer required a non-nil Wrt and fell
// through to the bare call form `D(x)`, while Julia, Python and TypeScript all
// printed `∂x/∂t`. Same missing default, different consumer.
func TestWrtDefaultOmittedRenders(t *testing.T) {
	wrt := "t"
	omitted := ExprNode{Op: "D", Args: []any{"x"}}
	explicit := ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt}

	assert.Equal(t, "∂x/∂t", ToUnicode(omitted))
	assert.Equal(t, ToUnicode(explicit), ToUnicode(omitted))
	assert.Equal(t, ToLatex(explicit), ToLatex(omitted))
	assert.Equal(t, ToASCII(explicit), ToASCII(omitted))
}

// TestWrtDefaultOmittedClassifies is the half Go already got right, kept as a
// pin rather than as a fix: a `D` with no `wrt` marks its target an ODE state
// for a SCALAR and for a SHAPED unknown alike, and a `D` whose `wrt` names an
// axis still does not. The shared fixture carries the same five models for
// every binding.
func TestWrtDefaultOmittedClassifies(t *testing.T) {
	f, err := LoadPath("../../../../tests/conformance/classification/fixtures/wrt_default_omitted.esm")
	require.NoError(t, err)

	for _, tc := range []struct {
		model      string
		odeStates  []string
		systemKind string
	}{
		{"ScalarWrtOmitted", []string{"z"}, "ode"},
		{"ScalarWrtExplicit", []string{"z"}, "ode"},
		{"ShapedWrtOmitted", []string{"x"}, "ode"},
		{"ShapedWrtExplicit", []string{"x"}, "ode"},
		{"SpatialControl", nil, "pde"},
	} {
		m, ok := f.Models[tc.model]
		require.True(t, ok, "model %s missing from the fixture", tc.model)
		assert.Equal(t, tc.odeStates, ODEStates(&m), "ode_states of %s", tc.model)
		assert.Equal(t, tc.systemKind, SystemKind(&m), "system_kind of %s", tc.model)
	}
}
