package esm

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestComponentGraphFromFile tests component graph creation from an ESM file
func TestComponentGraphFromFile(t *testing.T) {
	// Create a sample ESM file
	file := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "Test Model",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown", Units: stringPtr("m")},
					"y": {Type: "parameter", Units: stringPtr("s")},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: stringPtr("t")},
						RHS: "y",
					},
				},
			},
		},
		ReactionSystems: map[string]ReactionSystem{
			"TestReactions": {
				Species: map[string]Species{
					"A": {Units: stringPtr("mol/L")},
					"B": {Units: stringPtr("mol/L")},
				},
				Parameters: map[string]Parameter{
					"k": {Units: stringPtr("1/s")},
				},
				Reactions: []Reaction{
					{
						ID: "R1",
						Substrates: []SubstrateProduct{
							{Species: "A", Stoichiometry: 1},
						},
						Products: []SubstrateProduct{
							{Species: "B", Stoichiometry: 1},
						},
						Rate: ExprNode{
							Op:   "*",
							Args: []any{"k", "A"},
						},
					},
				},
			},
		},
		// A `data_sources` entry is NOT a graph node from esm 1.0.0: it exposes no
		// variables, cannot be a coupling endpoint, and so has no edges to draw
		// (esm-spec §8, CONFORMANCE_SPEC §3.4). It is declared here precisely so
		// the test asserts that it contributes NOTHING to the component graph.
		DataSources: map[string]DataSource{
			"TestSource": {
				Kind: "grid",
				Source: DataSourceLocation{
					URLTemplate: "https://example.com/{date:%Y%m%d}.nc",
				},
			},
		},
		Coupling: []CouplingEntry{
			VariableMapCoupling{
				Type:      "variable_map",
				From:      "TestReactions.A",
				To:        "TestModel.y",
				Transform: "identity",
			},
			OperatorComposeCoupling{
				Type:    "operator_compose",
				Systems: [2]string{"TestModel", "TestReactions"},
			},
		},
	}

	graph := ComponentGraphFromFile(file)

	// Two component nodes: the model and the reaction system. The data source is
	// not one.
	if len(graph.Nodes) != 2 {
		t.Errorf("Expected 2 nodes, got %d", len(graph.Nodes))
	}

	// Check that we have the right node types
	nodeTypes := make(map[string]int)
	for _, node := range graph.Nodes {
		nodeTypes[node.Type]++
	}

	if nodeTypes["model"] != 1 {
		t.Errorf("Expected 1 model node, got %d", nodeTypes["model"])
	}
	if nodeTypes["reaction_system"] != 1 {
		t.Errorf("Expected 1 reaction_system node, got %d", nodeTypes["reaction_system"])
	}
	for _, legacy := range []string{"data_loader", "data_source"} {
		if nodeTypes[legacy] != 0 {
			t.Errorf("a data source must contribute no graph node, got %d %s nodes",
				nodeTypes[legacy], legacy)
		}
	}

	// Check edges
	if len(graph.Edges) != 2 {
		t.Errorf("Expected 2 edges, got %d", len(graph.Edges))
	}

	// Check edge types
	edgeTypes := make(map[CouplingKind]int)
	for _, edge := range graph.Edges {
		edgeTypes[edge.Data.Type]++
	}

	if edgeTypes["variable_map"] != 1 {
		t.Errorf("Expected 1 variable_map edge, got %d", edgeTypes["variable_map"])
	}
	if edgeTypes["operator_compose"] != 1 {
		t.Errorf("Expected 1 operator_compose edge, got %d", edgeTypes["operator_compose"])
	}
}

// A variable node is labelled with its DERIVED role (esm-spec §6.3.1), not with
// the declared type — which, with only `unknown` and `parameter` left, would say
// nothing about how the node behaves.
func TestExpressionGraphNodeKindsAreDerivedRoles(t *testing.T) {
	model := Model{
		Variables: map[string]ModelVariable{
			"x":   {Type: VarTypeUnknown},
			"obs": {Type: VarTypeUnknown},
			"alg": {Type: VarTypeUnknown},
			"k":   {Type: VarTypeParameter},
			"w": {Type: VarTypeParameter,
				Distribution: &Distribution{Kind: DistributionNormal, Mean: 0.0, Std: 1.0},
				Update:       ParameterUpdate{Kind: UpdateKindWiener}},
			"s": {Type: VarTypeParameter,
				Distribution: &Distribution{Kind: DistributionUniform, Low: 0.0, High: 1.0}},
			"d": {Type: VarTypeParameter,
				Update: ParameterUpdate{Kind: UpdateKindCondition, When: true, Expression: 1.0}},
		},
		Equations: []Equation{
			{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: stringPtr("t")}, RHS: "k"},
			{LHS: "obs", RHS: ExprNode{Op: "*", Args: []any{2.0, "x"}}},
			{LHS: ExprNode{Op: "*", Args: []any{"alg", "alg"}}, RHS: "k"},
		},
	}
	graph := ExpressionGraphFromModel(model, "S")
	got := map[string]string{}
	for _, n := range graph.Nodes {
		got[n.Name] = n.Kind
	}
	want := map[string]string{
		"x": RoleODEState, "obs": RoleObserved, "alg": RoleAlgebraic,
		"k": RoleConstant, "w": RoleBrownian, "s": RoleSampled, "d": RoleDiscrete,
	}
	for name, kind := range want {
		if got[name] != kind {
			t.Errorf("node %q kind = %q, want %q", name, got[name], kind)
		}
	}
}

// TestExpressionGraphFromModel tests expression graph creation from a model
func TestExpressionGraphFromModel(t *testing.T) {
	model := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "unknown", Units: stringPtr("m")},
			"y": {Type: "parameter", Units: stringPtr("m/s")},
			"z": {Type: "unknown"},
		},
		Equations: []Equation{
			{
				LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: stringPtr("t")},
				RHS: "y",
			},
			{
				LHS: "z",
				RHS: ExprNode{Op: "*", Args: []any{2.0, "x"}},
			},
		},
	}

	graph := ExpressionGraphFromModel(model, "TestSystem")

	// Check nodes
	if len(graph.Nodes) != 3 {
		t.Errorf("Expected 3 nodes, got %d", len(graph.Nodes))
	}

	// Check that all variables are present
	nodeNames := make(map[string]bool)
	for _, node := range graph.Nodes {
		nodeNames[node.Name] = true
	}

	expectedVars := []string{"x", "y", "z"}
	for _, varName := range expectedVars {
		if !nodeNames[varName] {
			t.Errorf("Expected variable %s not found in nodes", varName)
		}
	}

	// Check edges (y -> x from first equation, x -> z from second equation)
	if len(graph.Edges) != 2 {
		t.Errorf("Expected 2 edges, got %d", len(graph.Edges))
	}
}

// TestExpressionGraphEquationIndex guards against the loop-variable capture bug:
// under go 1.21 loopvar semantics, taking &i of the range variable made every
// dependency edge report the last equation index. Each edge must carry its own
// per-equation index (y->x from eq 0, x->z from eq 1).
func TestExpressionGraphEquationIndex(t *testing.T) {
	model := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "unknown"},
			"y": {Type: "parameter"},
			"z": {Type: "unknown"},
		},
		Equations: []Equation{
			{
				LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: stringPtr("t")},
				RHS: "y",
			},
			{
				LHS: "z",
				RHS: ExprNode{Op: "*", Args: []any{2.0, "x"}},
			},
		},
	}

	graph := ExpressionGraphFromModel(model, "TestSystem")

	byTarget := make(map[string]int)
	for _, edge := range graph.Edges {
		if edge.Data.EquationIndex == nil {
			t.Fatalf("edge %s->%s has nil EquationIndex", edge.Data.Source, edge.Data.Target)
		}
		byTarget[edge.Data.Target] = *edge.Data.EquationIndex
	}

	if got := byTarget["x"]; got != 0 {
		t.Errorf("edge into x: expected equation_index 0, got %d", got)
	}
	if got := byTarget["z"]; got != 1 {
		t.Errorf("edge into z: expected equation_index 1, got %d", got)
	}
}

// TestExpressionGraphFromReactionSystem tests expression graph creation from a reaction system
func TestExpressionGraphFromReactionSystem(t *testing.T) {
	system := ReactionSystem{
		Species: map[string]Species{
			"A": {Units: stringPtr("mol/L")},
			"B": {Units: stringPtr("mol/L")},
		},
		Parameters: map[string]Parameter{
			"k": {Units: stringPtr("1/s")},
		},
		Reactions: []Reaction{
			{
				ID: "R1",
				Substrates: []SubstrateProduct{
					{Species: "A", Stoichiometry: 1},
				},
				Products: []SubstrateProduct{
					{Species: "B", Stoichiometry: 1},
				},
				Rate: ExprNode{
					Op:   "*",
					Args: []any{"k", "A"},
				},
			},
		},
	}

	graph := ExpressionGraphFromReactionSystem(system, "TestReactions")

	// Check nodes (A, B, k)
	if len(graph.Nodes) != 3 {
		t.Errorf("Expected 3 nodes, got %d", len(graph.Nodes))
	}

	// Check node types
	nodeKinds := make(map[string]int)
	for _, node := range graph.Nodes {
		nodeKinds[node.Kind]++
	}

	if nodeKinds["species"] != 2 {
		t.Errorf("Expected 2 species nodes, got %d", nodeKinds["species"])
	}
	if nodeKinds["parameter"] != 1 {
		t.Errorf("Expected 1 parameter node, got %d", nodeKinds["parameter"])
	}

	// Check that we have appropriate edges (rate and stoichiometric)
	if len(graph.Edges) == 0 {
		t.Errorf("Expected some edges, got none")
	}

	// Check edge relationships
	relationshipCounts := make(map[string]int)
	for _, edge := range graph.Edges {
		relationshipCounts[edge.Data.Relationship]++
	}

	if relationshipCounts["rate"] == 0 && relationshipCounts["stoichiometric"] == 0 {
		t.Errorf("Expected rate or stoichiometric edges, got: %v", relationshipCounts)
	}
}

// TestGraphExport tests graph export functionality
func TestGraphExport(t *testing.T) {
	// Create a simple component graph
	graph := &ComponentGraph{
		Nodes: []ComponentNode{
			{ID: "A", Type: "model", Name: "ModelA"},
			{ID: "B", Type: "reaction_system", Name: "ReactionB"},
		},
		Edges: []GraphEdge[ComponentNode, CouplingEdge]{
			{
				Source: ComponentNode{ID: "A", Type: "model", Name: "ModelA"},
				Target: ComponentNode{ID: "B", Type: "reaction_system", Name: "ReactionB"},
				Data: CouplingEdge{
					Type:          "operator_compose",
					Bidirectional: true,
				},
			},
		},
	}

	// Test DOT export
	dotExporter := NewDOTExporter()
	dotOutput, err := dotExporter.ExportComponentGraph(graph)
	if err != nil {
		t.Errorf("DOT export failed: %v", err)
	}

	if !strings.Contains(dotOutput, "digraph ComponentGraph") {
		t.Errorf("DOT output doesn't contain expected header")
	}

	// A bidirectional coupling is a directed edge annotated with dir=both; an
	// undirected `--` edge is a Graphviz syntax error inside a digraph.
	if !strings.Contains(dotOutput, "\"A\" -> \"B\"") {
		t.Errorf("DOT output doesn't contain expected directed edge")
	}
	if !strings.Contains(dotOutput, "dir=both") {
		t.Errorf("DOT output doesn't mark the bidirectional edge with dir=both")
	}

	// Test Mermaid export
	mermaidExporter := NewMermaidExporter()
	mermaidOutput, err := mermaidExporter.ExportComponentGraph(graph)
	if err != nil {
		t.Errorf("Mermaid export failed: %v", err)
	}

	if !strings.Contains(mermaidOutput, "graph LR") {
		t.Errorf("Mermaid output doesn't contain expected header")
	}

	// Test JSON export
	jsonExporter := NewJSONExporter()
	jsonOutput, err := jsonExporter.ExportComponentGraph(graph)
	if err != nil {
		t.Errorf("JSON export failed: %v", err)
	}

	// Verify JSON is valid
	var parsed ComponentGraph
	err = json.Unmarshal([]byte(jsonOutput), &parsed)
	if err != nil {
		t.Errorf("JSON export produced invalid JSON: %v", err)
	}

	if len(parsed.Nodes) != 2 {
		t.Errorf("JSON parsed graph has wrong number of nodes: %d", len(parsed.Nodes))
	}
}

// TestExtractVariablesFromExpression tests variable extraction from expressions
func TestExtractVariablesFromExpression(t *testing.T) {
	testCases := []struct {
		name     string
		expr     Expression
		expected []string
	}{
		{
			name:     "string variable",
			expr:     "x",
			expected: []string{"x"},
		},
		{
			name:     "number literal",
			expr:     3.14,
			expected: []string{},
		},
		{
			name: "binary operation",
			expr: ExprNode{
				Op:   "+",
				Args: []any{"x", "y"},
			},
			expected: []string{"x", "y"},
		},
		{
			name: "nested expression",
			expr: ExprNode{
				Op: "*",
				Args: []any{
					"k",
					ExprNode{
						Op:   "+",
						Args: []any{"x", 2.0},
					},
				},
			},
			expected: []string{"k", "x"},
		},
		{
			name: "duplicate variables",
			expr: ExprNode{
				Op:   "+",
				Args: []any{"x", "x"},
			},
			expected: []string{"x"},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := extractVariablesFromExpression(tc.expr)

			if len(result) != len(tc.expected) {
				t.Errorf("Expected %d variables, got %d: %v", len(tc.expected), len(result), result)
				return
			}

			// Convert to map for easier comparison
			resultMap := make(map[string]bool)
			for _, v := range result {
				resultMap[v] = true
			}

			for _, expected := range tc.expected {
				if !resultMap[expected] {
					t.Errorf("Expected variable %s not found in result: %v", expected, result)
				}
			}
		})
	}
}

// TestExtractVariableFromLHS tests LHS variable extraction
func TestExtractVariableFromLHS(t *testing.T) {
	testCases := []struct {
		name     string
		lhs      Expression
		expected string
	}{
		{
			name:     "simple variable",
			lhs:      "x",
			expected: "x",
		},
		{
			name: "derivative",
			lhs: ExprNode{
				Op:   "D",
				Args: []any{"y"},
				Wrt:  stringPtr("t"),
			},
			expected: "y",
		},
		{
			name:     "number (invalid)",
			lhs:      3.14,
			expected: "",
		},
		{
			name: "other operator",
			lhs: ExprNode{
				Op:   "+",
				Args: []any{"x", "y"},
			},
			expected: "",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := extractVariableFromLHS(tc.lhs)
			if result != tc.expected {
				t.Errorf("Expected %q, got %q", tc.expected, result)
			}
		})
	}
}
