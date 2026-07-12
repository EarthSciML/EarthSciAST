package esm

import (
	"fmt"
	"strings"
)

// ========================================
// 1. Graph Data Structures
// ========================================

// GraphEdge represents an edge in a directed graph
type GraphEdge[N any, E any] struct {
	Source N `json:"source"`
	Target N `json:"target"`
	Data   E `json:"data"`
}

// ComponentNode represents a node in the component graph
type ComponentNode struct {
	ID            string         `json:"id"`
	Type          string         `json:"type"` // "model", "reaction_system", "data_loader", "operator"
	Name          string         `json:"name"`
	VariableCount *int           `json:"variable_count,omitempty"`
	EquationCount *int           `json:"equation_count,omitempty"`
	SpeciesCount  *int           `json:"species_count,omitempty"`
	ReactionCount *int           `json:"reaction_count,omitempty"`
	Metadata      map[string]any `json:"metadata,omitempty"`
}

// CouplingKind identifies the kind of coupling a component-graph edge represents.
type CouplingKind string

const (
	CouplingKindOperatorCompose CouplingKind = "operator_compose"
	CouplingKindCouple          CouplingKind = "couple"
	CouplingKindVariableMap     CouplingKind = "variable_map"
)

// CouplingEdge represents an edge in the component graph
type CouplingEdge struct {
	Type          CouplingKind `json:"type"` // coupling type
	Label         *string      `json:"label,omitempty"`
	Description   *string      `json:"description,omitempty"`
	Bidirectional bool         `json:"bidirectional"`
	CouplingEntry any          `json:"coupling_entry"`
}

// VariableNode represents a node in the expression graph
type VariableNode struct {
	Name   string  `json:"name"`
	Kind   string  `json:"kind"` // "state", "parameter", "observed", "brownian", "species"
	Units  *string `json:"units,omitempty"`
	System string  `json:"system"`
}

// DependencyEdge represents an edge in the expression graph
type DependencyEdge struct {
	Source        string     `json:"source"`
	Target        string     `json:"target"`
	Relationship  string     `json:"relationship"` // "additive", "multiplicative", "rate", "stoichiometric"
	EquationIndex *int       `json:"equation_index,omitempty"`
	Expression    Expression `json:"expression,omitempty"`
}

// ComponentGraph is a specialized graph for system components
type ComponentGraph struct {
	Nodes []ComponentNode                          `json:"nodes"`
	Edges []GraphEdge[ComponentNode, CouplingEdge] `json:"edges"`
}

// ExpressionGraph is a specialized graph for variable dependencies
type ExpressionGraph struct {
	Nodes []VariableNode                            `json:"nodes"`
	Edges []GraphEdge[VariableNode, DependencyEdge] `json:"edges"`
}

// ========================================
// 2. Component Graph Construction
// ========================================

// ComponentGraphFromFile creates a component graph from an ESM file
func ComponentGraphFromFile(file *ESMFile) *ComponentGraph {
	graph := &ComponentGraph{
		Nodes: make([]ComponentNode, 0),
		Edges: make([]GraphEdge[ComponentNode, CouplingEdge], 0),
	}

	// Create a map to track nodes by ID for edge creation
	nodeMap := make(map[string]ComponentNode)

	// Add nodes for models
	for id, model := range file.Models {
		node := ComponentNode{
			ID:       id,
			Type:     "model",
			Name:     id,
			Metadata: make(map[string]any),
		}

		// Count variables and equations
		varCount := len(model.Variables)
		eqCount := len(model.Equations)
		node.VariableCount = &varCount
		node.EquationCount = &eqCount

		graph.Nodes = append(graph.Nodes, node)
		nodeMap[id] = node
	}

	// Add nodes for reaction systems
	for id, system := range file.ReactionSystems {
		node := ComponentNode{
			ID:       id,
			Type:     "reaction_system",
			Name:     id,
			Metadata: make(map[string]any),
		}

		// Count species and reactions
		speciesCount := len(system.Species)
		reactionCount := len(system.Reactions)
		node.SpeciesCount = &speciesCount
		node.ReactionCount = &reactionCount

		graph.Nodes = append(graph.Nodes, node)
		nodeMap[id] = node
	}

	// Add nodes for data loaders
	for id, loader := range file.DataLoaders {
		node := ComponentNode{
			ID:   id,
			Type: "data_loader",
			Name: id,
			Metadata: map[string]any{
				"kind":      loader.Kind,
				"variables": len(loader.Variables),
			},
		}

		graph.Nodes = append(graph.Nodes, node)
		nodeMap[id] = node
	}

	// `operators` block removed in v0.3.0 (closed-function-registry RFC).

	// Add edges for coupling entries
	for _, coupling := range file.Coupling {
		edges := createCouplingEdges(coupling, nodeMap)
		graph.Edges = append(graph.Edges, edges...)
	}

	return graph
}

// createCouplingEdges creates edges for a coupling entry
func createCouplingEdges(coupling any, nodeMap map[string]ComponentNode) []GraphEdge[ComponentNode, CouplingEdge] {
	var edges []GraphEdge[ComponentNode, CouplingEdge]

	switch c := coupling.(type) {
	case OperatorComposeCoupling:
		if len(c.Systems) == 2 {
			source, sourceExists := nodeMap[c.Systems[0]]
			target, targetExists := nodeMap[c.Systems[1]]

			if sourceExists && targetExists {
				edge := GraphEdge[ComponentNode, CouplingEdge]{
					Source: source,
					Target: target,
					Data: CouplingEdge{
						Type:          CouplingKindOperatorCompose,
						Description:   c.Description,
						Bidirectional: true,
						CouplingEntry: c,
					},
				}
				edges = append(edges, edge)
			}
		}

	case CouplingCouple:
		if len(c.Systems) == 2 {
			source, sourceExists := nodeMap[c.Systems[0]]
			target, targetExists := nodeMap[c.Systems[1]]

			if sourceExists && targetExists {
				label := fmt.Sprintf("%s ↔ %s", c.Systems[0], c.Systems[1])
				edge := GraphEdge[ComponentNode, CouplingEdge]{
					Source: source,
					Target: target,
					Data: CouplingEdge{
						Type:          CouplingKindCouple,
						Label:         &label,
						Description:   c.Description,
						Bidirectional: true,
						CouplingEntry: c,
					},
				}
				edges = append(edges, edge)
			}
		}

	case VariableMapCoupling:
		// Extract system names from scoped references
		fromSystem := extractSystemFromScoped(c.From)
		toSystem := extractSystemFromScoped(c.To)

		source, sourceExists := nodeMap[fromSystem]
		target, targetExists := nodeMap[toSystem]

		if sourceExists && targetExists {
			// Extract variable name for label
			varName := extractVariableFromScoped(c.From)
			edge := GraphEdge[ComponentNode, CouplingEdge]{
				Source: source,
				Target: target,
				Data: CouplingEdge{
					Type:          CouplingKindVariableMap,
					Label:         &varName,
					Description:   c.Description,
					Bidirectional: false,
					CouplingEntry: c,
				},
			}
			edges = append(edges, edge)
		}
	}

	return edges
}

// ========================================
// 3. Expression Graph Construction
// ========================================

// ExpressionGraphFromFile creates an expression graph from an ESM file
func ExpressionGraphFromFile(file *ESMFile) *ExpressionGraph {
	graph := &ExpressionGraph{
		Nodes: make([]VariableNode, 0),
		Edges: make([]GraphEdge[VariableNode, DependencyEdge], 0),
	}

	// Create a map to track nodes by name for edge creation
	nodeMap := make(map[string]VariableNode)

	// Add nodes and edges for models
	for systemName, model := range file.Models {
		addModelNodesToGraph(graph, nodeMap, systemName, model)
		addModelEdgesToGraph(graph, nodeMap, systemName, model)
	}

	// Add nodes and edges for reaction systems
	for systemName, system := range file.ReactionSystems {
		addReactionSystemNodesToGraph(graph, nodeMap, systemName, system)
		addReactionSystemEdgesToGraph(graph, nodeMap, systemName, system)
	}

	return graph
}

// ExpressionGraphFromModel creates an expression graph for a single model
func ExpressionGraphFromModel(model Model, systemName string) *ExpressionGraph {
	graph := &ExpressionGraph{
		Nodes: make([]VariableNode, 0),
		Edges: make([]GraphEdge[VariableNode, DependencyEdge], 0),
	}

	nodeMap := make(map[string]VariableNode)
	addModelNodesToGraph(graph, nodeMap, systemName, model)
	addModelEdgesToGraph(graph, nodeMap, systemName, model)

	return graph
}

// ExpressionGraphFromReactionSystem creates an expression graph for a single reaction system
func ExpressionGraphFromReactionSystem(system ReactionSystem, systemName string) *ExpressionGraph {
	graph := &ExpressionGraph{
		Nodes: make([]VariableNode, 0),
		Edges: make([]GraphEdge[VariableNode, DependencyEdge], 0),
	}

	nodeMap := make(map[string]VariableNode)
	addReactionSystemNodesToGraph(graph, nodeMap, systemName, system)
	addReactionSystemEdgesToGraph(graph, nodeMap, systemName, system)

	return graph
}

// depNodeKey is the nodeMap key for a variable node. Keying by system+name (not
// bare name) prevents same-named variables in different systems from colliding.
func depNodeKey(systemName, name string) string {
	return systemName + "." + name
}

// addModelNodesToGraph adds nodes from a model to the graph
func addModelNodesToGraph(graph *ExpressionGraph, nodeMap map[string]VariableNode, systemName string, model Model) {
	for varName, variable := range model.Variables {
		node := VariableNode{
			Name:   varName,
			Kind:   variable.Type,
			Units:  variable.Units,
			System: systemName,
		}

		graph.Nodes = append(graph.Nodes, node)
		nodeMap[depNodeKey(systemName, varName)] = node
	}
}

// addReactionSystemNodesToGraph adds nodes from a reaction system to the graph
func addReactionSystemNodesToGraph(graph *ExpressionGraph, nodeMap map[string]VariableNode, systemName string, system ReactionSystem) {
	// Add species as nodes
	for speciesName, species := range system.Species {
		node := VariableNode{
			Name:   speciesName,
			Kind:   "species",
			Units:  species.Units,
			System: systemName,
		}

		graph.Nodes = append(graph.Nodes, node)
		nodeMap[depNodeKey(systemName, speciesName)] = node
	}

	// Add parameters as nodes
	for paramName, param := range system.Parameters {
		node := VariableNode{
			Name:   paramName,
			Kind:   "parameter",
			Units:  param.Units,
			System: systemName,
		}

		graph.Nodes = append(graph.Nodes, node)
		nodeMap[depNodeKey(systemName, paramName)] = node
	}
}

// addModelEdgesToGraph adds edges from a model to the graph
func addModelEdgesToGraph(graph *ExpressionGraph, nodeMap map[string]VariableNode, systemName string, model Model) {
	for i, equation := range model.Equations {
		// Per-iteration copy: taking &i of the range variable (go 1.21 loopvar
		// semantics) would make every edge point at the last index.
		idx := i

		// Extract LHS variable
		lhsVar := extractVariableFromLHS(equation.LHS)
		if lhsVar == "" {
			continue
		}

		// Find all variables in RHS
		rhsVars := extractVariablesFromExpression(equation.RHS)

		// Create edges from each RHS variable to LHS variable
		for _, rhsVar := range rhsVars {
			if rhsVar != lhsVar { // Avoid self-loops for basic dependencies
				sourceNode, sourceExists := nodeMap[depNodeKey(systemName, rhsVar)]
				targetNode, targetExists := nodeMap[depNodeKey(systemName, lhsVar)]

				if sourceExists && targetExists {
					edge := GraphEdge[VariableNode, DependencyEdge]{
						Source: sourceNode,
						Target: targetNode,
						Data: DependencyEdge{
							Source:        rhsVar,
							Target:        lhsVar,
							Relationship:  "additive",
							EquationIndex: &idx,
							Expression:    equation.RHS,
						},
					}
					graph.Edges = append(graph.Edges, edge)
				}
			}
		}
	}
}

// addReactionSystemEdgesToGraph adds edges from a reaction system to the graph
func addReactionSystemEdgesToGraph(graph *ExpressionGraph, nodeMap map[string]VariableNode, systemName string, system ReactionSystem) {
	for i, reaction := range system.Reactions {
		// Per-iteration copy: taking &i of the range variable (go 1.21 loopvar
		// semantics) would make every edge point at the last reaction index.
		idx := i

		// Get all variables in the rate expression
		rateVars := extractVariablesFromExpression(reaction.Rate)

		// Create sets of affected species
		affectedSpecies := make(map[string]bool)

		// Add substrates (consumed)
		for _, substrate := range reaction.Substrates {
			affectedSpecies[substrate.Species] = true
		}

		// Add products (produced)
		for _, product := range reaction.Products {
			affectedSpecies[product.Species] = true
		}

		// Create edges from rate variables to affected species
		for _, rateVar := range rateVars {
			for speciesName := range affectedSpecies {
				sourceNode, sourceExists := nodeMap[depNodeKey(systemName, rateVar)]
				targetNode, targetExists := nodeMap[depNodeKey(systemName, speciesName)]

				if sourceExists && targetExists && rateVar != speciesName {
					edge := GraphEdge[VariableNode, DependencyEdge]{
						Source: sourceNode,
						Target: targetNode,
						Data: DependencyEdge{
							Source:        rateVar,
							Target:        speciesName,
							Relationship:  "rate",
							EquationIndex: &idx,
							Expression:    reaction.Rate,
						},
					}
					graph.Edges = append(graph.Edges, edge)
				}
			}
		}

		// Create stoichiometric edges between species
		for _, substrate := range reaction.Substrates {
			for _, product := range reaction.Products {
				sourceNode, sourceExists := nodeMap[depNodeKey(systemName, substrate.Species)]
				targetNode, targetExists := nodeMap[depNodeKey(systemName, product.Species)]

				if sourceExists && targetExists {
					edge := GraphEdge[VariableNode, DependencyEdge]{
						Source: sourceNode,
						Target: targetNode,
						Data: DependencyEdge{
							Source:        substrate.Species,
							Target:        product.Species,
							Relationship:  "stoichiometric",
							EquationIndex: &idx,
						},
					}
					graph.Edges = append(graph.Edges, edge)
				}
			}
		}
	}
}

// ========================================
// 4. Utility Functions
// ========================================

// extractSystemFromScoped extracts system name from a scoped reference like "System.var"
func extractSystemFromScoped(scopedRef string) string {
	parts := strings.Split(scopedRef, ".")
	if len(parts) > 1 {
		return parts[0]
	}
	return scopedRef // If no dot, assume it's just the system name
}

// extractVariableFromScoped extracts variable name from a scoped reference
func extractVariableFromScoped(scopedRef string) string {
	parts := strings.Split(scopedRef, ".")
	return parts[len(parts)-1] // Last part is the variable name
}

// extractVariableFromLHS extracts the variable name from equation LHS
func extractVariableFromLHS(lhs Expression) string {
	switch v := lhs.(type) {
	case string:
		return v
	case ExprNode:
		if v.Op == "D" && len(v.Args) > 0 {
			// For derivative D(var, t), extract the variable
			if varExpr, ok := v.Args[0].(string); ok {
				return varExpr
			}
		}
	}
	return ""
}

// extractVariablesFromExpression recursively extracts all variable names from an expression
func extractVariablesFromExpression(expr Expression) []string {
	var vars []string

	switch v := expr.(type) {
	case string:
		vars = append(vars, v)
	case ExprNode:
		for _, arg := range v.Args {
			childVars := extractVariablesFromExpression(arg)
			vars = append(vars, childVars...)
		}
	case float64:
		// Numbers don't contribute variables
	}

	// Remove duplicates
	uniqueVars := make([]string, 0)
	seen := make(map[string]bool)
	for _, v := range vars {
		if !seen[v] {
			uniqueVars = append(uniqueVars, v)
			seen[v] = true
		}
	}

	return uniqueVars
}

// ========================================
// 5. Graph Utility Methods
// ========================================

// ComponentAdjacency is one entry returned by ComponentGraph.Adjacency: a
// neighbouring component node and the coupling edge that reaches it.
type ComponentAdjacency struct {
	Neighbor ComponentNode
	Edge     CouplingEdge
}

// Adjacency returns adjacent nodes for a given node in component graph
func (g *ComponentGraph) Adjacency(node ComponentNode) []ComponentAdjacency {
	var result []ComponentAdjacency

	for _, edge := range g.Edges {
		if edge.Source.ID == node.ID {
			result = append(result, ComponentAdjacency{edge.Target, edge.Data})
		}
		if edge.Data.Bidirectional && edge.Target.ID == node.ID {
			result = append(result, ComponentAdjacency{edge.Source, edge.Data})
		}
	}

	return result
}

// Predecessors returns all nodes that have edges pointing to the given node
func (g *ComponentGraph) Predecessors(node ComponentNode) []ComponentNode {
	var result []ComponentNode

	for _, edge := range g.Edges {
		if edge.Target.ID == node.ID {
			result = append(result, edge.Source)
		}
		if edge.Data.Bidirectional && edge.Source.ID == node.ID {
			result = append(result, edge.Target)
		}
	}

	return result
}

// Successors returns all nodes that the given node has edges pointing to
func (g *ComponentGraph) Successors(node ComponentNode) []ComponentNode {
	var result []ComponentNode

	for _, edge := range g.Edges {
		if edge.Source.ID == node.ID {
			result = append(result, edge.Target)
		}
		if edge.Data.Bidirectional && edge.Target.ID == node.ID {
			result = append(result, edge.Source)
		}
	}

	return result
}

// VariableAdjacency is one entry returned by ExpressionGraph.AdjacencyVariable:
// a neighbouring variable node and the dependency edge that reaches it.
type VariableAdjacency struct {
	Neighbor VariableNode
	Edge     DependencyEdge
}

// AdjacencyVariable returns adjacent nodes for a given node in expression graph
func (g *ExpressionGraph) AdjacencyVariable(node VariableNode) []VariableAdjacency {
	var result []VariableAdjacency

	for _, edge := range g.Edges {
		if edge.Source.Name == node.Name && edge.Source.System == node.System {
			result = append(result, VariableAdjacency{edge.Target, edge.Data})
		}
	}

	return result
}

// PredecessorsVariable returns all nodes that have edges pointing to the given variable node
func (g *ExpressionGraph) PredecessorsVariable(node VariableNode) []VariableNode {
	var result []VariableNode

	for _, edge := range g.Edges {
		if edge.Target.Name == node.Name && edge.Target.System == node.System {
			result = append(result, edge.Source)
		}
	}

	return result
}

// SuccessorsVariable returns all nodes that the given variable node has edges pointing to
func (g *ExpressionGraph) SuccessorsVariable(node VariableNode) []VariableNode {
	var result []VariableNode

	for _, edge := range g.Edges {
		if edge.Source.Name == node.Name && edge.Source.System == node.System {
			result = append(result, edge.Target)
		}
	}

	return result
}
