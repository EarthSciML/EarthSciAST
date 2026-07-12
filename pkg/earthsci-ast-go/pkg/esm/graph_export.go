package esm

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// ========================================
// 1. DOT (Graphviz) Export
// ========================================

// DOTExporter exports graphs to DOT format
type DOTExporter struct{}

// NewDOTExporter creates a new DOT exporter
func NewDOTExporter() *DOTExporter {
	return &DOTExporter{}
}

// ExportComponentGraph exports a component graph to DOT format
func (e *DOTExporter) ExportComponentGraph(graph *ComponentGraph) (string, error) {
	var builder strings.Builder

	builder.WriteString("digraph ComponentGraph {\n")
	builder.WriteString("  rankdir=LR;\n")
	builder.WriteString("  node [shape=box, style=filled];\n")
	builder.WriteString("\n")

	// Sort nodes for consistent output
	nodes := make([]ComponentNode, len(graph.Nodes))
	copy(nodes, graph.Nodes)
	sortComponentNodes(nodes)

	// Export nodes
	for _, node := range nodes {
		color := getNodeColor(node.Type)
		label := formatComponentNodeLabel(node)

		fmt.Fprintf(&builder, "  \"%s\" [label=\"%s\", fillcolor=\"%s\"];\n",
			dotEscape(node.ID), dotEscape(label), color)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[ComponentNode, CouplingEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sortComponentEdges(edges)

	// Export edges. A bidirectional coupling is a directed edge with
	// dir=both — an undirected `--` edge is a syntax error inside a digraph.
	for _, edge := range edges {
		label := string(edge.Data.Type)
		if edge.Data.Label != nil {
			label = fmt.Sprintf("%s [%s]", edge.Data.Type, *edge.Data.Label)
		}

		attrs := fmt.Sprintf("label=\"%s\"", dotEscape(label))
		if edge.Data.Bidirectional {
			attrs += ", dir=both"
		}

		fmt.Fprintf(&builder, "  \"%s\" -> \"%s\" [%s];\n",
			dotEscape(edge.Source.ID), dotEscape(edge.Target.ID), attrs)
	}

	builder.WriteString("}\n")
	return builder.String(), nil
}

// ExportExpressionGraph exports an expression graph to DOT format
func (e *DOTExporter) ExportExpressionGraph(graph *ExpressionGraph) (string, error) {
	var builder strings.Builder

	builder.WriteString("digraph ExpressionGraph {\n")
	builder.WriteString("  rankdir=LR;\n")
	builder.WriteString("  node [shape=ellipse, style=filled];\n")
	builder.WriteString("\n")

	// Sort nodes for consistent output
	nodes := make([]VariableNode, len(graph.Nodes))
	copy(nodes, graph.Nodes)
	sortVariableNodes(nodes)

	// Export nodes
	for _, node := range nodes {
		color := getVariableNodeColor(node.Kind)
		label := formatVariableNodeLabel(node)
		nodeID := variableNodeID(node, ".")

		fmt.Fprintf(&builder, "  \"%s\" [label=\"%s\", fillcolor=\"%s\"];\n",
			dotEscape(nodeID), dotEscape(label), color)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[VariableNode, DependencyEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sortVariableEdges(edges, ".")

	// Export edges
	for _, edge := range edges {
		sourceID := variableNodeID(edge.Source, ".")
		targetID := variableNodeID(edge.Target, ".")

		fmt.Fprintf(&builder, "  \"%s\" -> \"%s\" [label=\"%s\"];\n",
			dotEscape(sourceID), dotEscape(targetID), dotEscape(edge.Data.Relationship))
	}

	builder.WriteString("}\n")
	return builder.String(), nil
}

// ========================================
// 3. Mermaid Export
// ========================================

// MermaidExporter exports graphs to Mermaid format
type MermaidExporter struct{}

// NewMermaidExporter creates a new Mermaid exporter
func NewMermaidExporter() *MermaidExporter {
	return &MermaidExporter{}
}

// ExportComponentGraph exports a component graph to Mermaid format
func (e *MermaidExporter) ExportComponentGraph(graph *ComponentGraph) (string, error) {
	var builder strings.Builder

	builder.WriteString("graph LR\n")

	// Sort nodes for consistent output
	nodes := make([]ComponentNode, len(graph.Nodes))
	copy(nodes, graph.Nodes)
	sortComponentNodes(nodes)

	// Export nodes with shapes and colors. The node ID is sanitized (as the
	// expression export already does) and the shape's opening and closing
	// tokens both surround the label so the token is well-formed.
	for _, node := range nodes {
		open, closeTok := getMermaidNodeShape(node.Type)
		fmt.Fprintf(&builder, "    %s%s%s%s\n",
			sanitizeMermaidID(node.ID), open, escapeMermaidLabel(node.ID), closeTok)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[ComponentNode, CouplingEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sortComponentEdges(edges)

	// Export edges
	for _, edge := range edges {
		arrow := "-->"
		if edge.Data.Bidirectional {
			arrow = "---"
		}

		label := string(edge.Data.Type)
		if edge.Data.Label != nil {
			label = *edge.Data.Label
		}

		fmt.Fprintf(&builder, "    %s %s|%s| %s\n",
			sanitizeMermaidID(edge.Source.ID), arrow, label, sanitizeMermaidID(edge.Target.ID))
	}

	// Add styling
	builder.WriteString("\n")
	builder.WriteString("    classDef model fill:#e1f5fe\n")
	builder.WriteString("    classDef reaction_system fill:#f3e5f5\n")
	builder.WriteString("    classDef data_loader fill:#e8f5e8\n")

	// Apply classes to nodes
	for _, node := range nodes {
		fmt.Fprintf(&builder, "    class %s %s\n", sanitizeMermaidID(node.ID), node.Type)
	}

	return builder.String(), nil
}

// ExportExpressionGraph exports an expression graph to Mermaid format
func (e *MermaidExporter) ExportExpressionGraph(graph *ExpressionGraph) (string, error) {
	var builder strings.Builder

	builder.WriteString("graph LR\n")

	// Sort nodes for consistent output
	nodes := make([]VariableNode, len(graph.Nodes))
	copy(nodes, graph.Nodes)
	sortVariableNodes(nodes)

	// Export nodes
	for _, node := range nodes {
		nodeID := sanitizeMermaidID(variableNodeID(node, "_"))
		label := "[" + escapeMermaidLabel(node.Name) + "]"

		fmt.Fprintf(&builder, "    %s%s\n", nodeID, label)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[VariableNode, DependencyEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sortVariableEdges(edges, "_")

	// Export edges
	for _, edge := range edges {
		sourceID := sanitizeMermaidID(variableNodeID(edge.Source, "_"))
		targetID := sanitizeMermaidID(variableNodeID(edge.Target, "_"))

		fmt.Fprintf(&builder, "    %s -->|%s| %s\n",
			sourceID, edge.Data.Relationship, targetID)
	}

	// Add styling
	builder.WriteString("\n")
	builder.WriteString("    classDef state fill:#e3f2fd\n")
	builder.WriteString("    classDef parameter fill:#fff8e1\n")
	builder.WriteString("    classDef observed fill:#f1f8e9\n")
	builder.WriteString("    classDef species fill:#fce4ec\n")

	// Apply classes to nodes
	for _, node := range nodes {
		nodeID := sanitizeMermaidID(fmt.Sprintf("%s_%s", node.System, node.Name))
		fmt.Fprintf(&builder, "    class %s %s\n", nodeID, node.Kind)
	}

	return builder.String(), nil
}

// ========================================
// 4. JSON Export
// ========================================

// JSONExporter exports graphs to JSON format
type JSONExporter struct{}

// NewJSONExporter creates a new JSON exporter
func NewJSONExporter() *JSONExporter {
	return &JSONExporter{}
}

// ExportComponentGraph exports a component graph to JSON format
func (e *JSONExporter) ExportComponentGraph(graph *ComponentGraph) (string, error) {
	// Sort nodes and edges for consistent output
	sortedGraph := &ComponentGraph{
		Nodes: make([]ComponentNode, len(graph.Nodes)),
		Edges: make([]GraphEdge[ComponentNode, CouplingEdge], len(graph.Edges)),
	}

	copy(sortedGraph.Nodes, graph.Nodes)
	copy(sortedGraph.Edges, graph.Edges)

	sortComponentNodes(sortedGraph.Nodes)
	sortComponentEdges(sortedGraph.Edges)

	data, err := json.MarshalIndent(sortedGraph, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal component graph: %w", err)
	}

	return string(data), nil
}

// ExportExpressionGraph exports an expression graph to JSON format
func (e *JSONExporter) ExportExpressionGraph(graph *ExpressionGraph) (string, error) {
	// Sort nodes and edges for consistent output
	sortedGraph := &ExpressionGraph{
		Nodes: make([]VariableNode, len(graph.Nodes)),
		Edges: make([]GraphEdge[VariableNode, DependencyEdge], len(graph.Edges)),
	}

	copy(sortedGraph.Nodes, graph.Nodes)
	copy(sortedGraph.Edges, graph.Edges)

	sortVariableNodes(sortedGraph.Nodes)
	sortVariableEdges(sortedGraph.Edges, ".")

	data, err := json.MarshalIndent(sortedGraph, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal expression graph: %w", err)
	}

	return string(data), nil
}

// ========================================
// 5. Utility Functions
// ========================================

// getNodeColor returns appropriate color for different node types in DOT format.
// (The "operator" node type was removed in v0.3.0 and can no longer be produced.)
func getNodeColor(nodeType string) string {
	switch nodeType {
	case "model":
		return "lightblue"
	case "reaction_system":
		return "lightpink"
	case "data_loader":
		return "lightgreen"
	default:
		return "white"
	}
}

// getVariableNodeColor returns appropriate color for different variable types in DOT format
func getVariableNodeColor(kind string) string {
	switch kind {
	case "state":
		return "lightblue"
	case "parameter":
		return "lightyellow"
	case "observed":
		return "lightgreen"
	case "species":
		return "lightpink"
	default:
		return "white"
	}
}

// formatComponentNodeLabel formats the label for a component node
func formatComponentNodeLabel(node ComponentNode) string {
	label := node.Name + "\\n(" + node.Type + ")"

	if node.VariableCount != nil {
		label += fmt.Sprintf("\\n%d vars", *node.VariableCount)
	}
	if node.EquationCount != nil {
		label += fmt.Sprintf(", %d eqs", *node.EquationCount)
	}
	if node.SpeciesCount != nil {
		label += fmt.Sprintf("\\n%d species", *node.SpeciesCount)
	}
	if node.ReactionCount != nil {
		label += fmt.Sprintf(", %d rxns", *node.ReactionCount)
	}

	return label
}

// formatVariableNodeLabel formats the label for a variable node
func formatVariableNodeLabel(node VariableNode) string {
	label := node.Name
	if node.Units != nil {
		label += fmt.Sprintf("\\n[%s]", *node.Units)
	}
	return label
}

// getMermaidNodeShape returns the opening and closing shape tokens for a node
// type in Mermaid. Both tokens must be emitted around the label so the node is
// well-formed (e.g. model -> "[[…]]"). The "operator" node type was removed in
// v0.3.0.
func getMermaidNodeShape(nodeType string) (open, closeTok string) {
	switch nodeType {
	case "model":
		return "[[", "]]"
	case "reaction_system":
		return "([", "])"
	case "data_loader":
		return "{", "}"
	default:
		return "[", "]"
	}
}

// escapeMermaidLabel escapes a label's special characters for Mermaid (the
// caller supplies the surrounding node-shape tokens).
func escapeMermaidLabel(text string) string {
	text = strings.ReplaceAll(text, " ", "_")
	text = strings.ReplaceAll(text, "-", "_")
	text = strings.ReplaceAll(text, ".", "_")
	return text
}

// sanitizeMermaidID sanitizes an ID for use in Mermaid
func sanitizeMermaidID(id string) string {
	// Replace special characters with underscores
	id = strings.ReplaceAll(id, ".", "_")
	id = strings.ReplaceAll(id, "-", "_")
	id = strings.ReplaceAll(id, " ", "_")

	// Ensure it starts with a letter
	if len(id) > 0 && (id[0] >= '0' && id[0] <= '9') {
		id = "n" + id
	}

	return id
}

// dotEscape escapes the double-quote that would otherwise terminate a DOT
// quoted string. Backslash sequences (notably the "\n" line break emitted in
// node labels) are deliberately left intact.
func dotEscape(s string) string {
	return strings.ReplaceAll(s, "\"", "\\\"")
}

// variableNodeID returns the composite "system<sep>name" identifier for a
// variable node; DOT/JSON use "." and Mermaid uses "_".
func variableNodeID(node VariableNode, sep string) string {
	return node.System + sep + node.Name
}

// sortComponentNodes sorts component nodes by ID for deterministic output.
func sortComponentNodes(nodes []ComponentNode) {
	sort.Slice(nodes, func(i, j int) bool {
		return nodes[i].ID < nodes[j].ID
	})
}

// sortComponentEdges sorts component edges by (source ID, target ID).
func sortComponentEdges(edges []GraphEdge[ComponentNode, CouplingEdge]) {
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].Source.ID != edges[j].Source.ID {
			return edges[i].Source.ID < edges[j].Source.ID
		}
		return edges[i].Target.ID < edges[j].Target.ID
	})
}

// sortVariableNodes sorts variable nodes by (system, name).
func sortVariableNodes(nodes []VariableNode) {
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].System != nodes[j].System {
			return nodes[i].System < nodes[j].System
		}
		return nodes[i].Name < nodes[j].Name
	})
}

// sortVariableEdges sorts variable edges by (source ID, target ID) using the
// given separator to build the composite IDs (matching each format's node IDs).
func sortVariableEdges(edges []GraphEdge[VariableNode, DependencyEdge], sep string) {
	sort.Slice(edges, func(i, j int) bool {
		src1 := variableNodeID(edges[i].Source, sep)
		src2 := variableNodeID(edges[j].Source, sep)
		if src1 != src2 {
			return src1 < src2
		}
		return variableNodeID(edges[i].Target, sep) < variableNodeID(edges[j].Target, sep)
	})
}

// ========================================
// 6. Convenience Export Functions
// ========================================

// ExportComponentGraphDOT exports a component graph to DOT format
func ExportComponentGraphDOT(graph *ComponentGraph) (string, error) {
	exporter := NewDOTExporter()
	return exporter.ExportComponentGraph(graph)
}

// ExportComponentGraphMermaid exports a component graph to Mermaid format
func ExportComponentGraphMermaid(graph *ComponentGraph) (string, error) {
	exporter := NewMermaidExporter()
	return exporter.ExportComponentGraph(graph)
}

// ExportComponentGraphJSON exports a component graph to JSON format
func ExportComponentGraphJSON(graph *ComponentGraph) (string, error) {
	exporter := NewJSONExporter()
	return exporter.ExportComponentGraph(graph)
}

// ExportExpressionGraphDOT exports an expression graph to DOT format
func ExportExpressionGraphDOT(graph *ExpressionGraph) (string, error) {
	exporter := NewDOTExporter()
	return exporter.ExportExpressionGraph(graph)
}

// ExportExpressionGraphMermaid exports an expression graph to Mermaid format
func ExportExpressionGraphMermaid(graph *ExpressionGraph) (string, error) {
	exporter := NewMermaidExporter()
	return exporter.ExportExpressionGraph(graph)
}

// ExportExpressionGraphJSON exports an expression graph to JSON format
func ExportExpressionGraphJSON(graph *ExpressionGraph) (string, error) {
	exporter := NewJSONExporter()
	return exporter.ExportExpressionGraph(graph)
}
