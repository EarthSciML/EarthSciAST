package esm

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// ========================================
// 1. Graph Export Interface
// ========================================

// GraphExporter defines the interface for exporting graphs
type GraphExporter interface {
	ExportComponentGraph(graph *ComponentGraph) (string, error)
	ExportExpressionGraph(graph *ExpressionGraph) (string, error)
}

// ========================================
// 2. DOT (Graphviz) Export
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
	sort.Slice(nodes, func(i, j int) bool {
		return nodes[i].ID < nodes[j].ID
	})

	// Export nodes
	for _, node := range nodes {
		color := getNodeColor(node.Type)
		label := formatComponentNodeLabel(node)

		fmt.Fprintf(&builder, "  \"%s\" [label=\"%s\", fillcolor=\"%s\"];\n",
			node.ID, label, color)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[ComponentNode, CouplingEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].Source.ID != edges[j].Source.ID {
			return edges[i].Source.ID < edges[j].Source.ID
		}
		return edges[i].Target.ID < edges[j].Target.ID
	})

	// Export edges
	for _, edge := range edges {
		direction := "->"
		if edge.Data.Bidirectional {
			direction = "--"
		}

		label := edge.Data.Type
		if edge.Data.Label != nil {
			label = fmt.Sprintf("%s [%s]", edge.Data.Type, *edge.Data.Label)
		}

		fmt.Fprintf(&builder, "  \"%s\" %s \"%s\" [label=\"%s\"];\n",
			edge.Source.ID, direction, edge.Target.ID, label)
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
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].System != nodes[j].System {
			return nodes[i].System < nodes[j].System
		}
		return nodes[i].Name < nodes[j].Name
	})

	// Export nodes
	for _, node := range nodes {
		color := getVariableNodeColor(node.Kind)
		label := formatVariableNodeLabel(node)
		nodeID := fmt.Sprintf("%s.%s", node.System, node.Name)

		fmt.Fprintf(&builder, "  \"%s\" [label=\"%s\", fillcolor=\"%s\"];\n",
			nodeID, label, color)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[VariableNode, DependencyEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sort.Slice(edges, func(i, j int) bool {
		sourceID1 := fmt.Sprintf("%s.%s", edges[i].Source.System, edges[i].Source.Name)
		sourceID2 := fmt.Sprintf("%s.%s", edges[j].Source.System, edges[j].Source.Name)
		if sourceID1 != sourceID2 {
			return sourceID1 < sourceID2
		}
		targetID1 := fmt.Sprintf("%s.%s", edges[i].Target.System, edges[i].Target.Name)
		targetID2 := fmt.Sprintf("%s.%s", edges[j].Target.System, edges[j].Target.Name)
		return targetID1 < targetID2
	})

	// Export edges
	for _, edge := range edges {
		sourceID := fmt.Sprintf("%s.%s", edge.Source.System, edge.Source.Name)
		targetID := fmt.Sprintf("%s.%s", edge.Target.System, edge.Target.Name)

		fmt.Fprintf(&builder, "  \"%s\" -> \"%s\" [label=\"%s\"];\n",
			sourceID, targetID, edge.Data.Relationship)
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
	sort.Slice(nodes, func(i, j int) bool {
		return nodes[i].ID < nodes[j].ID
	})

	// Export nodes with shapes and colors
	for _, node := range nodes {
		shape := getMermaidNodeShape(node.Type)
		label := formatMermaidLabel(node.ID)

		fmt.Fprintf(&builder, "    %s%s%s\n", node.ID, shape, label)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[ComponentNode, CouplingEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].Source.ID != edges[j].Source.ID {
			return edges[i].Source.ID < edges[j].Source.ID
		}
		return edges[i].Target.ID < edges[j].Target.ID
	})

	// Export edges
	for _, edge := range edges {
		arrow := "-->"
		if edge.Data.Bidirectional {
			arrow = "---"
		}

		label := edge.Data.Type
		if edge.Data.Label != nil {
			label = *edge.Data.Label
		}

		fmt.Fprintf(&builder, "    %s %s|%s| %s\n",
			edge.Source.ID, arrow, label, edge.Target.ID)
	}

	// Add styling
	builder.WriteString("\n")
	builder.WriteString("    classDef model fill:#e1f5fe\n")
	builder.WriteString("    classDef reaction_system fill:#f3e5f5\n")
	builder.WriteString("    classDef data_loader fill:#e8f5e8\n")
	builder.WriteString("    classDef operator fill:#fff3e0\n")

	// Apply classes to nodes
	for _, node := range nodes {
		fmt.Fprintf(&builder, "    class %s %s\n", node.ID, node.Type)
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
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].System != nodes[j].System {
			return nodes[i].System < nodes[j].System
		}
		return nodes[i].Name < nodes[j].Name
	})

	// Export nodes
	for _, node := range nodes {
		nodeID := sanitizeMermaidID(fmt.Sprintf("%s_%s", node.System, node.Name))
		label := formatMermaidLabel(node.Name)

		fmt.Fprintf(&builder, "    %s%s\n", nodeID, label)
	}

	builder.WriteString("\n")

	// Sort edges for consistent output
	edges := make([]GraphEdge[VariableNode, DependencyEdge], len(graph.Edges))
	copy(edges, graph.Edges)
	sort.Slice(edges, func(i, j int) bool {
		sourceID1 := fmt.Sprintf("%s_%s", edges[i].Source.System, edges[i].Source.Name)
		sourceID2 := fmt.Sprintf("%s_%s", edges[j].Source.System, edges[j].Source.Name)
		if sourceID1 != sourceID2 {
			return sourceID1 < sourceID2
		}
		targetID1 := fmt.Sprintf("%s_%s", edges[i].Target.System, edges[i].Target.Name)
		targetID2 := fmt.Sprintf("%s_%s", edges[j].Target.System, edges[j].Target.Name)
		return targetID1 < targetID2
	})

	// Export edges
	for _, edge := range edges {
		sourceID := sanitizeMermaidID(fmt.Sprintf("%s_%s", edge.Source.System, edge.Source.Name))
		targetID := sanitizeMermaidID(fmt.Sprintf("%s_%s", edge.Target.System, edge.Target.Name))

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

	sort.Slice(sortedGraph.Nodes, func(i, j int) bool {
		return sortedGraph.Nodes[i].ID < sortedGraph.Nodes[j].ID
	})

	sort.Slice(sortedGraph.Edges, func(i, j int) bool {
		if sortedGraph.Edges[i].Source.ID != sortedGraph.Edges[j].Source.ID {
			return sortedGraph.Edges[i].Source.ID < sortedGraph.Edges[j].Source.ID
		}
		return sortedGraph.Edges[i].Target.ID < sortedGraph.Edges[j].Target.ID
	})

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

	sort.Slice(sortedGraph.Nodes, func(i, j int) bool {
		if sortedGraph.Nodes[i].System != sortedGraph.Nodes[j].System {
			return sortedGraph.Nodes[i].System < sortedGraph.Nodes[j].System
		}
		return sortedGraph.Nodes[i].Name < sortedGraph.Nodes[j].Name
	})

	sort.Slice(sortedGraph.Edges, func(i, j int) bool {
		sourceID1 := fmt.Sprintf("%s.%s", sortedGraph.Edges[i].Source.System, sortedGraph.Edges[i].Source.Name)
		sourceID2 := fmt.Sprintf("%s.%s", sortedGraph.Edges[j].Source.System, sortedGraph.Edges[j].Source.Name)
		if sourceID1 != sourceID2 {
			return sourceID1 < sourceID2
		}
		targetID1 := fmt.Sprintf("%s.%s", sortedGraph.Edges[i].Target.System, sortedGraph.Edges[i].Target.Name)
		targetID2 := fmt.Sprintf("%s.%s", sortedGraph.Edges[j].Target.System, sortedGraph.Edges[j].Target.Name)
		return targetID1 < targetID2
	})

	data, err := json.MarshalIndent(sortedGraph, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal expression graph: %w", err)
	}

	return string(data), nil
}

// ========================================
// 5. Utility Functions
// ========================================

// getNodeColor returns appropriate color for different node types in DOT format
func getNodeColor(nodeType string) string {
	switch nodeType {
	case "model":
		return "lightblue"
	case "reaction_system":
		return "lightpink"
	case "data_loader":
		return "lightgreen"
	case "operator":
		return "lightyellow"
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

// getMermaidNodeShape returns appropriate shape for different node types in Mermaid format
func getMermaidNodeShape(nodeType string) string {
	switch nodeType {
	case "model":
		return "["
	case "reaction_system":
		return "("
	case "data_loader":
		return "{"
	case "operator":
		return "[/"
	default:
		return "["
	}
}

// formatMermaidLabel formats a label for Mermaid (escaping special characters)
func formatMermaidLabel(text string) string {
	// Escape special characters for Mermaid
	text = strings.ReplaceAll(text, " ", "_")
	text = strings.ReplaceAll(text, "-", "_")
	text = strings.ReplaceAll(text, ".", "_")
	return "[" + text + "]"
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
