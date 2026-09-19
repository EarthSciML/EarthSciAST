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

// TestDerivativeAxisIsTheLiteralT pins the ruling on the esm-spec §4.2 versus
// §5.4 ambiguity: the derivative axis is the LITERAL name `t`, not whatever
// `domain.independent_variable` happens to name.
//
// Before this, Go read the axis two different ways in one binding. `classify.go`
// compared against the literal `t` (every caller passes DefaultIndepVar), while
// `dae.go` and `validate.go` resolved it against `domain.independent_variable`.
// On a document declaring `independent_variable: "s"` the binding therefore
// contradicted itself about one node — the exact shape of EarthSciAST#407, one
// layer down. The assertions below fail on the old reading:
//
//   - `Renamed` writes `D(y, wrt: t)` in a document whose independent variable
//     is `s`. SystemKind called it an `ode`; ApplyDAEContract called the same
//     equation algebraic, could not factor a `D(...)` LHS, and raised
//     E_NONTRIVIAL_DAE.
//   - `Spatial` writes `D(y, wrt: s)`. The old reading made that the temporal
//     derivative and `y` an ODE state; under §4.2 it is a SPATIAL derivative,
//     the model is a `pde`, and the DAE contract does not apply to it at all.
//
// Renaming the independent variable is not hypothetical: in
// tests/valid/independent_variable_renamed.esm it is renamed to `s` precisely
// so that `t` is FREE for its ordinary meteorological meaning, air temperature.
// Resolving `wrt: t` against the independent variable in such a document
// silently retargets the author's derivative onto a different quantity.
func TestDerivativeAxisIsTheLiteralT(t *testing.T) {
	build := func(wrt *string) *ESMFile {
		lhs := ExprNode{Op: "D", Args: []any{"y"}}
		lhs.Wrt = wrt
		return &ESMFile{
			ESM:      "1.0.0",
			Metadata: Metadata{Name: "Renamed"},
			Domain:   &Domain{IndependentVariable: strPtr("s")},
			Models: map[string]Model{
				"M": {
					Variables: map[string]ModelVariable{
						"y": {Type: "unknown", Units: strPtr("1")},
					},
					Equations: []Equation{{LHS: lhs, RHS: int64(0)}},
				},
			},
		}
	}

	// `wrt: t` and no `wrt` are both the structural time derivative, whatever
	// the domain declares — and the DAE contract now agrees with SystemKind.
	for _, spelling := range []*string{strPtr("t"), nil} {
		f := build(spelling)
		m := f.Models["M"]
		assert.Equal(t, "ode", SystemKind(&m))
		assert.Equal(t, []string{"y"}, ODEStates(&m))

		info, err := ApplyDAEContract(build(spelling))
		require.NoError(t, err, "the literal `t` is the structural axis whatever the domain declares")
		assert.Equal(t, "ode", info.SystemClass)
		assert.Equal(t, 0, info.AlgebraicEquationCount)
	}

	// A `wrt` naming the DECLARED independent variable is SPATIAL under §4.2 —
	// the complement that stops the fix being "every `D` is differential".
	f := build(strPtr("s"))
	m := f.Models["M"]
	assert.Equal(t, "pde", SystemKind(&m))
	assert.Empty(t, ODEStates(&m))
	// The DAE contract applies only to `ode` models, so it skips this one
	// rather than reporting a residual algebraic equation — the two layers
	// reaching the same conclusion by construction.
	info, err := ApplyDAEContract(build(strPtr("s")))
	require.NoError(t, err)
	assert.Equal(t, 0, info.AlgebraicEquationCount)
}
