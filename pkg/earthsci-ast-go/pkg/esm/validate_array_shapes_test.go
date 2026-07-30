package esm

import "testing"

// arrayShapeModel builds a one-equation model over declared index sets:
// `D(dp, t) ~ rhs`, with `dp` shaped over dpShape and the named operands shaped
// as given.
func arrayShapeModel(dpShape []string, operands map[string][]string, rhs Expression) *Model {
	vars := map[string]ModelVariable{
		"dp": {Type: VarTypeState, Shape: dpShape},
	}
	for name, shape := range operands {
		vars[name] = ModelVariable{Type: VarTypeObserved, Shape: shape}
	}
	return &Model{
		Variables: vars,
		Equations: []Equation{{
			LHS: ExprNode{Op: OpDerivative, Args: []any{"dp"}, Wrt: strPtr("t")},
			RHS: rhs,
		}},
	}
}

func arrayShapeFindings(t *testing.T, model *Model) []StructuralError {
	t.Helper()
	s := &structuralScan{}
	s.validateArrayBroadcastShapes(model, "/models/M")
	return s.errors
}

// TestArrayBroadcastShapeAlignment covers the esm-spec §4.3.4 rule and, just as
// importantly, its deliberate LIMITS: alignment is by index-set NAME, a subset
// operand broadcasts, axis order is immaterial, and the walk stops at every op
// that reshapes or re-indexes its operands.
func TestArrayBroadcastShapeAlignment(t *testing.T) {
	lonLatLev := []string{"lon", "lat", "lev"}
	cases := []struct {
		name     string
		dpShape  []string
		operands map[string][]string
		rhs      Expression
		wantAxis string // the unalignable index set, or "" to expect acceptance
	}{
		{
			name:     "subset operand broadcasts along the missing axes",
			dpShape:  lonLatLev,
			operands: map[string][]string{"w1": {"lat"}},
			rhs:      "w1",
		},
		{
			name:     "axis order is immaterial - the operand transposes",
			dpShape:  lonLatLev,
			operands: map[string][]string{"wT": {"lat", "lon"}},
			rhs:      "wT",
		},
		{
			name:     "mixed-rank product of two subset operands",
			dpShape:  lonLatLev,
			operands: map[string][]string{"w2": {"lon", "lat"}, "z1": {"lev"}},
			rhs:      ExprNode{Op: "*", Args: []any{"w2", "z1"}},
		},
		{
			name:     "the broadcast spelling aligns exactly as the bare one does",
			dpShape:  lonLatLev,
			operands: map[string][]string{"w2": {"lon", "lat"}, "z1": {"lev"}},
			rhs:      ExprNode{Op: opBroadcast, Fn: strPtr("*"), Args: []any{"w2", "z1"}},
		},
		{
			name:     "an operand carrying an index set the result lacks",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      "z1",
			wantAxis: "lev",
		},
		{
			name:     "nested under elementwise ops, the operand is still seen",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: "+", Args: []any{1.0, ExprNode{Op: "exp", Args: []any{"z1"}}}},
			wantAxis: "lev",
		},
		{
			name:     "and through a broadcast node, which MEANS the bare spelling",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: opBroadcast, Fn: strPtr("-"), Args: []any{"z1"}},
			wantAxis: "lev",
		},
		// --- the scope boundaries: ops that consume their operands WHOLE ---
		{
			name:     "aggregate names its own axes",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs: ExprNode{Op: opAggregate, Args: []any{},
				Ranges: map[string]any{"k": map[string]any{"from": "lev"}},
				Expr:   ExprNode{Op: "*", Args: []any{100.0, "z1"}}},
		},
		{
			name:     "index gathers",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: "index", Args: []any{"z1", "k"}},
		},
		{
			name:     "reshape restructures",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: "reshape", Args: []any{"z1"}, Shape: []any{1.0, 2.0}},
		},
		{
			name:     "transpose restructures",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: "transpose", Args: []any{"z1"}},
		},
		{
			name:     "concat restructures",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: "concat", Args: []any{"z1", "z1"}},
		},
		{
			name:     "a geometry kernel returns a result of an unrelated shape",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: "intersect_polygon", Args: []any{"z1", "z1"}},
		},
		{
			name:     "a broadcast whose fn is not a scalar operator is not descended",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      ExprNode{Op: opBroadcast, Fn: strPtr("aggregate"), Args: []any{"z1"}},
		},
		// --- anonymous shapes keep the positional regime (§4.3.4 case 2) ---
		{
			name:     "an operand with no declared shape names no axes",
			dpShape:  []string{"lon", "lat"},
			operands: map[string][]string{"z1": nil},
			rhs:      "z1",
		},
		{
			name:     "a result with no declared shape has no frame to align to",
			dpShape:  nil,
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      "z1",
		},
		{
			name:     "a repeated result axis gives no unambiguous position",
			dpShape:  []string{"lon", "lon"},
			operands: map[string][]string{"z1": {"lev"}},
			rhs:      "z1",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			errs := arrayShapeFindings(t, arrayShapeModel(tc.dpShape, tc.operands, tc.rhs))
			if tc.wantAxis == "" {
				if len(errs) != 0 {
					t.Fatalf("expected acceptance, got %d finding(s): %+v", len(errs), errs)
				}
				return
			}
			if len(errs) != 1 {
				t.Fatalf("expected exactly 1 finding, got %d: %+v", len(errs), errs)
			}
			got := errs[0]
			if got.Code != CodeArrayShapeMismatch {
				t.Errorf("code = %q, want %q", got.Code, CodeArrayShapeMismatch)
			}
			if got.Path != "/models/M/equations/0/rhs" {
				t.Errorf("path = %q, want the containing expression field", got.Path)
			}
			if got.Details["missing_index_set"] != tc.wantAxis {
				t.Errorf("missing_index_set = %v, want %q", got.Details["missing_index_set"], tc.wantAxis)
			}
		})
	}
}

// TestArrayBroadcastShapeCheckedPositions pins WHICH expression fields the rule
// governs: a whole-array LHS (`D(var)` or a bare `var`) and an array-shaped
// observed's defining expression. An INDEXED LHS is a per-cell equation whose
// RHS axes are the author's to spell, so it is left alone.
func TestArrayBroadcastShapeCheckedPositions(t *testing.T) {
	vars := map[string]ModelVariable{
		"dp": {Type: VarTypeState, Shape: []string{"lon", "lat"}},
		"z1": {Type: VarTypeObserved, Shape: []string{"lev"}},
	}

	t.Run("bare variable LHS", func(t *testing.T) {
		model := &Model{Variables: vars, Equations: []Equation{{LHS: "dp", RHS: "z1"}}}
		if errs := arrayShapeFindings(t, model); len(errs) != 1 {
			t.Fatalf("expected 1 finding on a bare-variable LHS, got %d", len(errs))
		}
	})

	t.Run("indexed LHS is left alone", func(t *testing.T) {
		model := &Model{Variables: vars, Equations: []Equation{{
			LHS: ExprNode{Op: OpDerivative,
				Args: []any{ExprNode{Op: "index", Args: []any{"dp", "i", "j"}}}, Wrt: strPtr("t")},
			RHS: "z1",
		}}}
		if errs := arrayShapeFindings(t, model); len(errs) != 0 {
			t.Fatalf("an indexed LHS must not be checked, got %+v", errs)
		}
	})

	t.Run("array-shaped observed expression", func(t *testing.T) {
		observed := map[string]ModelVariable{
			"p3": {Type: VarTypeObserved, Shape: []string{"lon", "lat"}, Expression: "z1"},
			"z1": vars["z1"],
		}
		errs := arrayShapeFindings(t, &Model{Variables: observed})
		if len(errs) != 1 {
			t.Fatalf("expected 1 finding on an observed expression, got %d: %+v", len(errs), errs)
		}
		if errs[0].Path != "/models/M/variables/p3/expression" {
			t.Errorf("path = %q, want the observed's expression field", errs[0].Path)
		}
	})
}
