package esm

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestToUnicodeBasic(t *testing.T) {
	tests := []struct {
		name     string
		input    any
		expected string
	}{
		{
			name:     "simple number",
			input:    3.14,
			expected: "3.14",
		},
		{
			name:     "simple variable",
			input:    "x",
			expected: "x",
		},
		{
			name:     "chemical species",
			input:    "O3",
			expected: "O₃",
		},
		{
			name:     "scientific notation small",
			input:    1.8e-12,
			expected: "1.8×10⁻¹²",
		},
		{
			name:     "scientific notation large",
			input:    2.46e19,
			expected: "2.46×10¹⁹",
		},
		{
			name:     "threshold value 0.001 - should use scientific",
			input:    0.001,
			expected: "1.0×10⁻³",
		},
		{
			name:     "threshold value 0.005 - should use scientific",
			input:    0.005,
			expected: "5.0×10⁻³",
		},
		{
			name:     "threshold value 0.009 - should use scientific",
			input:    0.009,
			expected: "9.0×10⁻³",
		},
		{
			name:     "threshold value 0.01 - should NOT use scientific",
			input:    0.01,
			expected: "0.01",
		},
		{
			name: "simple addition",
			input: ExprNode{
				Op:   "+",
				Args: []any{"a", "b"},
			},
			expected: "a + b",
		},
		{
			name: "multiplication",
			input: ExprNode{
				Op:   "*",
				Args: []any{"a", "b"},
			},
			expected: "a·b",
		},
		{
			name: "power of 2",
			input: ExprNode{
				Op:   "^",
				Args: []any{"x", 2},
			},
			expected: "x²",
		},
		{
			name: "derivative",
			input: ExprNode{
				Op:   "D",
				Args: []any{"O3"},
				Wrt:  strPtr("t"),
			},
			expected: "∂O₃/∂t",
		},
		{
			name: "gradient (generic fallback, dim not rendered)",
			input: ExprNode{
				Op:   "grad",
				Args: []any{"x"},
				Dim:  strPtr("y"),
			},
			expected: "grad(x)",
		},
		{
			name: "unary minus",
			input: ExprNode{
				Op:   "-",
				Args: []any{"x"},
			},
			expected: "−x",
		},
		{
			name: "binary subtraction",
			input: ExprNode{
				Op:   "-",
				Args: []any{"a", "b"},
			},
			expected: "a − b",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ToUnicode(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestToLatexBasic(t *testing.T) {
	tests := []struct {
		name     string
		input    any
		expected string
	}{
		{
			name:     "simple variable",
			input:    "x",
			expected: "x",
		},
		{
			name:     "chemical species",
			input:    "O3",
			expected: "\\mathrm{O_3}",
		},
		{
			name: "simple addition",
			input: ExprNode{
				Op:   "+",
				Args: []any{"a", "b"},
			},
			expected: "a + b",
		},
		{
			name: "multiplication",
			input: ExprNode{
				Op:   "*",
				Args: []any{"a", "b"},
			},
			expected: "a \\cdot b",
		},
		{
			name: "division",
			input: ExprNode{
				Op:   "/",
				Args: []any{"a", "b"},
			},
			expected: "\\frac{a}{b}",
		},
		{
			name: "power",
			input: ExprNode{
				Op:   "^",
				Args: []any{"x", 2},
			},
			expected: "x^{2}",
		},
		{
			name: "derivative",
			input: ExprNode{
				Op:   "D",
				Args: []any{"O3"},
				Wrt:  strPtr("t"),
			},
			expected: "\\frac{\\partial \\mathrm{O_3}}{\\partial t}",
		},
		{
			name: "exponential simple",
			input: ExprNode{
				Op:   "exp",
				Args: []any{"x"},
			},
			expected: "\\exp(x)",
		},
		{
			name: "exponential complex",
			input: ExprNode{
				Op: "exp",
				Args: []any{
					ExprNode{
						Op:   "/",
						Args: []any{-1370, "T"},
					},
				},
			},
			expected: "\\exp\\left(\\frac{-1370}{T}\\right)",
		},
		{
			name: "Pre function",
			input: ExprNode{
				Op:   "Pre",
				Args: []any{"x"},
			},
			expected: "\\mathrm{Pre}(x)",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ToLatex(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestOperatorPrecedence(t *testing.T) {
	tests := []struct {
		name    string
		input   any
		unicode string
		latex   string
	}{
		{
			name: "addition with multiplication (no parens needed)",
			input: ExprNode{
				Op: "+",
				Args: []any{
					ExprNode{Op: "*", Args: []any{"a", "b"}},
					"c",
				},
			},
			unicode: "a·b + c",
			latex:   "a \\cdot b + c",
		},
		{
			name: "multiplication with addition (parens needed)",
			input: ExprNode{
				Op: "*",
				Args: []any{
					ExprNode{Op: "+", Args: []any{"a", "b"}},
					"c",
				},
			},
			unicode: "(a + b)·c",
			latex:   "(a + b) \\cdot c",
		},
		{
			name: "exponentiation with addition (parens needed for base)",
			input: ExprNode{
				Op: "^",
				Args: []any{
					ExprNode{Op: "+", Args: []any{"x", "y"}},
					2,
				},
			},
			unicode: "(x + y)²",
			latex:   "(x + y)^{2}",
		},
		{
			name: "complex expression",
			input: ExprNode{
				Op: "+",
				Args: []any{
					ExprNode{Op: "^", Args: []any{"x", 2}},
					ExprNode{Op: "*", Args: []any{2, "x"}},
				},
			},
			unicode: "x² + 2·x",
			latex:   "x^{2} + 2 \\cdot x",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name+" unicode", func(t *testing.T) {
			result := ToUnicode(tt.input)
			assert.Equal(t, tt.unicode, result)
		})

		t.Run(tt.name+" latex", func(t *testing.T) {
			result := ToLatex(tt.input)
			assert.Equal(t, tt.latex, result)
		})
	}
}

func TestFormatChemicalSpecies(t *testing.T) {
	tests := []struct {
		species string
		unicode string
		latex   string
	}{
		{"O3", "O₃", "\\mathrm{O_3}"},
		{"NO2", "NO₂", "\\mathrm{NO_2}"},
		{"H2O", "H₂O", "\\mathrm{H_2O}"},
		{"CO2", "CO₂", "\\mathrm{CO_2}"},
		{"CH4", "CH₄", "\\mathrm{CH_4}"},
		{"SO4", "SO₄", "\\mathrm{SO_4}"},
	}

	for _, tt := range tests {
		t.Run("unicode "+tt.species, func(t *testing.T) {
			result := ToUnicode(tt.species)
			assert.Equal(t, tt.unicode, result)
		})

		t.Run("latex "+tt.species, func(t *testing.T) {
			result := ToLatex(tt.species)
			assert.Equal(t, tt.latex, result)
		})
	}
}

func TestIfElse(t *testing.T) {
	input := ExprNode{
		Op: "ifelse",
		Args: []any{
			ExprNode{Op: ">", Args: []any{"x", 0}},
			"x",
			0,
		},
	}

	unicode := ToUnicode(input)
	latex := ToLatex(input)

	assert.Equal(t, "ifelse(x > 0, x, 0)", unicode)
	assert.Equal(t, "\\begin{cases} x & \\text{if } x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}", latex)
}

func TestComplexChemicalExpression(t *testing.T) {
	input := ExprNode{
		Op:   "*",
		Args: []any{1.8e-12, "O3", "NO", "M"},
	}

	unicode := ToUnicode(input)
	latex := ToLatex(input)

	assert.Equal(t, "1.8×10⁻¹²·O₃·NO·M", unicode)
	assert.Equal(t, "1.8 \\times 10^{-12} \\cdot \\mathrm{O_3} \\cdot \\mathrm{NO} \\cdot M", latex)
}

// TestToUnicodeSpacedMatchesUnicode pins that ToUnicodeSpaced (now rendered via
// FmtUnicodeSpaced, spacing applied at the operator) reproduces the previous
// behavior — a "·"→" · " rewrite of the ToUnicode output — for every render
// path. Because "·" is only ever emitted by the multiplication operator, the
// spaced-at-emission form must equal the old post-hoc ReplaceAll for any
// expression whose leaves contain no "·". A missed format-switch arm (which
// would misroute FmtUnicodeSpaced to the ascii fallback) is caught here.
func TestToUnicodeSpacedMatchesUnicode(t *testing.T) {
	cases := []struct {
		name string
		expr Expression
	}{
		{"scalar mul with sci-notation + chemistry", ExprNode{Op: "*", Args: []any{1.8e-12, "O3", "NO", "M"}}},
		{"nested mul", ExprNode{Op: "*", Args: []any{"a", ExprNode{Op: "*", Args: []any{"b", "c"}}}}},
		{"mul over additive term (parens)", ExprNode{Op: "*", Args: []any{"k", ExprNode{Op: "+", Args: []any{"x", "y"}}}}},
		{"division", ExprNode{Op: "/", Args: []any{ExprNode{Op: "*", Args: []any{"a", "b"}}, "c"}}},
		{"power of product", ExprNode{Op: "^", Args: []any{ExprNode{Op: "*", Args: []any{"a", "b"}}, 2.0}}},
		{"function call", ExprNode{Op: "exp", Args: []any{ExprNode{Op: "*", Args: []any{"-1.0", "x"}}}}},
		{"bare variable (no mul)", "O3"},
		{"bare number (no mul)", 3.14},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			want := strings.ReplaceAll(ToUnicode(tc.expr), "·", " · ")
			got := ToUnicodeSpaced(tc.expr)
			assert.Equal(t, want, got)
		})
	}
}

func TestModelSummary(t *testing.T) {
	// Create a minimal ESM file structure similar to minimal_chemistry.esm
	esm := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:        "MinimalChemAdvection",
			Description: strPtr("O3-NO-NO2 chemistry with advection and external meteorology"),
			Authors:     []string{"Chris Tessum"},
		},
		ReactionSystems: map[string]ReactionSystem{
			"SimpleOzone": {
				Species: map[string]Species{
					"O3":  {Units: strPtr("mol/mol"), Default: 40e-9, Description: strPtr("Ozone")},
					"NO":  {Units: strPtr("mol/mol"), Default: 0.1e-9, Description: strPtr("Nitric oxide")},
					"NO2": {Units: strPtr("mol/mol"), Default: 1.0e-9, Description: strPtr("Nitrogen dioxide")},
				},
				Parameters: map[string]Parameter{
					"T":    {Units: strPtr("K"), Default: 298.15, Description: strPtr("Temperature")},
					"M":    {Units: strPtr("molec/cm^3"), Default: 2.46e19, Description: strPtr("Air number density")},
					"jNO2": {Units: strPtr("1/s"), Default: 0.005, Description: strPtr("NO2 photolysis rate")},
				},
				Reactions: []Reaction{
					{
						ID: "R1",
						Substrates: []SubstrateProduct{
							{Species: "NO", Stoichiometry: 1},
							{Species: "O3", Stoichiometry: 1},
						},
						Products: []SubstrateProduct{
							{Species: "NO2", Stoichiometry: 1},
						},
						Rate: ExprNode{
							Op: "*",
							Args: []any{
								1.8e-12,
								ExprNode{
									Op: "exp",
									Args: []any{
										ExprNode{
											Op:   "/",
											Args: []any{-1370, "T"},
										},
									},
								},
								"M",
							},
						},
					},
					{
						ID: "R2",
						Substrates: []SubstrateProduct{
							{Species: "NO2", Stoichiometry: 1},
						},
						Products: []SubstrateProduct{
							{Species: "NO", Stoichiometry: 1},
							{Species: "O3", Stoichiometry: 1},
						},
						Rate: "jNO2",
					},
				},
			},
		},
		Models: map[string]Model{
			"Advection": {
				Variables: map[string]ModelVariable{
					"u_wind": {Type: "parameter", Units: strPtr("m/s"), Default: 0.0},
					"v_wind": {Type: "parameter", Units: strPtr("m/s"), Default: 0.0},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"_var"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op: "+",
							Args: []any{
								ExprNode{
									Op: "*",
									Args: []any{
										ExprNode{Op: "-", Args: []any{"u_wind"}},
										ExprNode{Op: "grad", Args: []any{"_var"}, Dim: strPtr("x")},
									},
								},
								ExprNode{
									Op: "*",
									Args: []any{
										ExprNode{Op: "-", Args: []any{"v_wind"}},
										ExprNode{Op: "grad", Args: []any{"_var"}, Dim: strPtr("y")},
									},
								},
							},
						},
					},
				},
			},
		},
		DataLoaders: map[string]DataLoader{
			"GEOSFP": {
				Kind: "grid",
				Source: DataLoaderSource{
					URLTemplate: "https://example.com/{date:%Y%m%d}.nc",
				},
				Variables: map[string]DataLoaderVariable{
					"u": {FileVariable: "U", Units: "m/s", Description: strPtr("Eastward wind")},
					"v": {FileVariable: "V", Units: "m/s", Description: strPtr("Northward wind")},
					"T": {FileVariable: "T", Units: "K", Description: strPtr("Temperature")},
				},
			},
		},
		Coupling: []CouplingEntry{
			OperatorComposeCoupling{
				Type:    "operator_compose",
				Systems: [2]string{"SimpleOzone", "Advection"},
			},
			VariableMapCoupling{
				Type:      "variable_map",
				From:      "GEOSFP.T",
				To:        "SimpleOzone.T",
				Transform: "param_to_var",
			},
			VariableMapCoupling{
				Type:      "variable_map",
				From:      "GEOSFP.u",
				To:        "Advection.u_wind",
				Transform: "param_to_var",
			},
			VariableMapCoupling{
				Type:      "variable_map",
				From:      "GEOSFP.v",
				To:        "Advection.v_wind",
				Transform: "param_to_var",
			},
		},
		Domain: &Domain{
			Temporal: &TemporalDomain{
				Start: "2024-05-01T00:00:00Z",
				End:   "2024-05-03T00:00:00Z",
			},
		},
	}

	result := ModelSummary(esm)

	// Debug: print the actual result
	t.Logf("Actual result:\n%s", result)

	// Check key parts of the expected output
	assert.Contains(t, result, "ESM v0.1.0: MinimalChemAdvection")
	assert.Contains(t, result, "O3-NO-NO2 chemistry with advection and external meteorology")
	assert.Contains(t, result, "Authors: Chris Tessum")
	assert.Contains(t, result, "SimpleOzone (3 species, 3 parameters, 2 reactions)")
	assert.Contains(t, result, "R1: NO + O₃ → NO₂    rate: 1.8×10⁻¹² · exp(−1370/T) · M")
	assert.Contains(t, result, "R2: NO₂ → NO + O₃    rate: jNO₂")
	assert.Contains(t, result, "Advection (2 parameters, 1 equation)")
	// grad now renders via the generic fallback (dim is NOT rendered), so both
	// advection terms print as grad(_var). Unary minus is an operator node, so it
	// is parenthesized inside the product ((−a)·b), per RENDERING_CONTRACT.md.
	assert.Contains(t, result, "∂_var/∂t = (−u_wind) · grad(_var) + (−v_wind) · grad(_var)")
	assert.Contains(t, result, "GEOSFP: T, u, v (grid)")
	assert.Contains(t, result, "operator_compose: SimpleOzone + Advection")
	assert.Contains(t, result, "variable_map: GEOSFP.T → SimpleOzone.T")
	assert.Contains(t, result, "2024-05-01 to 2024-05-03")
}
