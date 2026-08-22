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

	// Apply classes to nodes. The id MUST be built the same way as the node
	// declaration above, or the class line names a node that does not exist.
	for _, node := range nodes {
		nodeID := sanitizeMermaidID(variableNodeID(node, "_"))
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

// jsonAdjacencyEdge is one edge of the JSON adjacency-list export. Its
// endpoints are node KEYS (strings), not embedded node objects: a JSON
// adjacency list is a node table plus references into it, and inlining whole
// nodes on both ends of every edge made the export quadratic in the graph and
// unusable as an adjacency list.
type jsonAdjacencyEdge struct {
	Source string `json:"source"`
	Target string `json:"target"`
	Data   any    `json:"data"`
}

// jsonAdjacencyGraph is the JSON adjacency-list export shape
// (esm-libraries-spec §4.8.3): a node table (each entry carrying an `id`), an
// edge list addressing nodes by that id, and an adjacency map from every node
// id to its UNDIRECTED neighbours.
type jsonAdjacencyGraph struct {
	Nodes     []any               `json:"nodes"`
	Edges     []jsonAdjacencyEdge `json:"edges"`
	Adjacency map[string][]string `json:"adjacency"`
}

// jsonVariableNode is a VariableNode with the node table's `id` key added. A
// component node already carries `id`; a variable node's key is its scoped
// Name, so the id is emitted alongside.
type jsonVariableNode struct {
	ID string `json:"id"`
	VariableNode
}

// ExportComponentGraph exports a component graph as a JSON adjacency list.
func (e *JSONExporter) ExportComponentGraph(graph *ComponentGraph) (string, error) {
	// Sort nodes and edges for consistent output
	nodes := make([]ComponentNode, len(graph.Nodes))
	edges := make([]GraphEdge[ComponentNode, CouplingEdge], len(graph.Edges))
	copy(nodes, graph.Nodes)
	copy(edges, graph.Edges)
	sortComponentNodes(nodes)
	sortComponentEdges(edges)

	closure := graph.closure()
	out := jsonAdjacencyGraph{
		Nodes:     make([]any, 0, len(nodes)),
		Edges:     make([]jsonAdjacencyEdge, 0, len(edges)),
		Adjacency: make(map[string][]string, len(nodes)),
	}
	for _, node := range nodes {
		out.Nodes = append(out.Nodes, node)
		out.Adjacency[node.ID] = closure.adjacent(node.ID)
	}
	for _, edge := range edges {
		out.Edges = append(out.Edges, jsonAdjacencyEdge{
			Source: edge.Source.ID,
			Target: edge.Target.ID,
			Data:   edge.Data,
		})
	}

	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal component graph: %w", err)
	}

	return string(data), nil
}

// ExportExpressionGraph exports an expression graph as a JSON adjacency list.
func (e *JSONExporter) ExportExpressionGraph(graph *ExpressionGraph) (string, error) {
	// Sort nodes and edges for consistent output
	nodes := make([]VariableNode, len(graph.Nodes))
	edges := make([]GraphEdge[VariableNode, DependencyEdge], len(graph.Edges))
	copy(nodes, graph.Nodes)
	copy(edges, graph.Edges)
	sortVariableNodes(nodes)
	sortVariableEdges(edges, ".")

	closure := graph.closure()
	out := jsonAdjacencyGraph{
		Nodes:     make([]any, 0, len(nodes)),
		Edges:     make([]jsonAdjacencyEdge, 0, len(edges)),
		Adjacency: make(map[string][]string, len(nodes)),
	}
	for _, node := range nodes {
		out.Nodes = append(out.Nodes, jsonVariableNode{ID: node.Name, VariableNode: node})
		out.Adjacency[node.Name] = closure.adjacent(node.Name)
	}
	for _, edge := range edges {
		out.Edges = append(out.Edges, jsonAdjacencyEdge{
			Source: edge.Data.Source,
			Target: edge.Data.Target,
			Data:   edge.Data,
		})
	}

	data, err := json.MarshalIndent(out, "", "  ")
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
	// A `data_sources` entry is not a component node from esm 1.0.0, so no
	// "data_loader"/"data_source" case remains here.
	default:
		return "white"
	}
}

// getVariableNodeColor returns appropriate color for a variable node's graph
// kind (esm-libraries-spec §4.8.2; see the NodeKind* constants in graph.go) in
// DOT format. The colours are unchanged; only the vocabulary the switch reads
// moved from the finer §6.3.1 classifier names to the graph's own.
func getVariableNodeColor(kind string) string {
	switch kind {
	case NodeKindState, NodeKindAlgebraic:
		return "lightblue"
	case NodeKindParameter, NodeKindDiscrete:
		return "lightyellow"
	case NodeKindObserved:
		return "lightgreen"
	case NodeKindBrownian:
		return "lightsalmon"
	case NodeKindSpecies:
		return "lightpink"
	default:
		return "white"
	}
}

// formatComponentNodeLabel formats the label for a component node.
//
// The counts a label carries are the ones that MEAN something for the node's
// type: a model shows variables and equations, a reaction system shows species
// and reactions (its ComponentCounts.EqCount IS its reaction count — see
// ComponentCounts). The emitted text is unchanged from when the counts were
// four separate optional pointers.
func formatComponentNodeLabel(node ComponentNode) string {
	label := node.Name + "\\n(" + node.Type + ")"

	switch node.Type {
	case "reaction_system":
		label += fmt.Sprintf("\\n%d species, %d rxns",
			node.Metadata.SpeciesCount, node.Metadata.EqCount)
	default:
		label += fmt.Sprintf("\\n%d vars, %d eqs",
			node.Metadata.VarCount, node.Metadata.EqCount)
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

// variableNodeID returns the identifier for a variable node in an export.
//
// VariableNode.Name is now the node's SCOPED key ("System.name"), so the
// composite this used to build by hand is the name itself; `sep` selects the
// separator each format wants ("." for DOT/JSON, "_" for Mermaid), which for a
// dotted scoped name means rewriting the dots.
func variableNodeID(node VariableNode, sep string) string {
	if sep == "." {
		return node.Name
	}
	return strings.ReplaceAll(node.Name, ".", sep)
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

// sortVariableNodes sorts variable nodes by (system, scoped name).
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
