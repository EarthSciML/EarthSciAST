package esm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// graph_conformance_test.go drives the CROSS-LANGUAGE GRAPH corpus
// (tests/conformance/graph/cases.json), generated from the TypeScript oracle by
// scripts/generate-graph-corpus.mjs.
//
// It pins the SEMANTIC graph model, not any rendering: component nodes with
// their types and the three summary counts, coupling edges with their types and
// labels, variable nodes with their derived kinds / units / owning systems,
// dependency edges with their relationships and equation indices, the
// adjacency / predecessor / successor closure, and the JSON adjacency-list
// export. The DOT and Mermaid BYTE formats are deliberately NOT pinned (§4.8.3
// requires both formats but specifies neither one's syntax) — see the corpus
// README.
//
// NODE AND EDGE ORDER IS NOT A CONFORMANCE PROPERTY: every binding builds its
// lists from its own map iteration, so everything here is compared as a SORTED
// MULTISET.

// ---------------------------------------------------------------------------
// Corpus shapes
// ---------------------------------------------------------------------------

type graphCorpus struct {
	Files []struct {
		Name           string `json:"name"`
		InputFile      string `json:"input_file"`
		Covers         string `json:"covers"`
		ComponentGraph struct {
			Nodes   []corpusComponentNode         `json:"nodes"`
			Edges   []corpusCouplingEdge          `json:"edges"`
			Closure map[string]corpusClosureEntry `json:"closure"`
		} `json:"component_graph"`
		ComponentGraphJSON  corpusJSONExport `json:"component_graph_json"`
		ExpressionGraph     corpusExprGraph  `json:"expression_graph"`
		ExpressionGraphJSON corpusJSONExport `json:"expression_graph_json"`
		MergeCoupled        corpusExprGraph  `json:"expression_graph_merge_coupled"`
	} `json:"files"`
	Targets []struct {
		Name            string          `json:"name"`
		Kind            string          `json:"kind"`
		Covers          string          `json:"covers"`
		Target          json.RawMessage `json:"target"`
		ExpressionGraph corpusExprGraph `json:"expression_graph"`
	} `json:"targets"`
}

type corpusComponentNode struct {
	ID           string `json:"id"`
	Type         string `json:"type"`
	VarCount     int    `json:"var_count"`
	EqCount      int    `json:"eq_count"`
	SpeciesCount int    `json:"species_count"`
}

type corpusCouplingEdge struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Type  string `json:"type"`
	Label string `json:"label"`
}

type corpusVariableNode struct {
	Name   string  `json:"name"`
	Kind   string  `json:"kind"`
	Units  *string `json:"units"`
	System string  `json:"system"`
}

type corpusDependencyEdge struct {
	Source        string `json:"source"`
	Target        string `json:"target"`
	Relationship  string `json:"relationship"`
	EquationIndex int    `json:"equation_index"`
}

type corpusClosureEntry struct {
	Adjacency    []string `json:"adjacency"`
	Predecessors []string `json:"predecessors"`
	Successors   []string `json:"successors"`
}

type corpusExprGraph struct {
	Nodes   []corpusVariableNode          `json:"nodes"`
	Edges   []corpusDependencyEdge        `json:"edges"`
	Closure map[string]corpusClosureEntry `json:"closure"`
}

type corpusJSONEndpoint struct {
	Source string `json:"source"`
	Target string `json:"target"`
}

type corpusJSONExport struct {
	TopLevelKeys []string             `json:"top_level_keys"`
	NodeIDs      []string             `json:"node_ids"`
	Edges        []corpusJSONEndpoint `json:"edges"`
	Adjacency    map[string][]string  `json:"adjacency"`
}

// ---------------------------------------------------------------------------
// Multiset comparison
// ---------------------------------------------------------------------------

// canonicalMultiset renders a slice as a SORTED list of canonical JSON strings,
// so two slices holding the same elements in different orders compare equal.
func canonicalMultiset[T any](t *testing.T, items []T) []string {
	t.Helper()
	out := make([]string, 0, len(items))
	for _, item := range items {
		data, err := json.Marshal(item)
		if err != nil {
			t.Fatalf("marshal for comparison: %v", err)
		}
		out = append(out, string(data))
	}
	sort.Strings(out)
	return out
}

// requireSameMultiset compares two slices as sorted multisets, reporting the
// elements only one side has.
func requireSameMultiset[T any](t *testing.T, what string, got, want []T) {
	t.Helper()
	gotCanon := canonicalMultiset(t, got)
	wantCanon := canonicalMultiset(t, want)
	if reflect.DeepEqual(gotCanon, wantCanon) {
		return
	}

	counts := map[string]int{}
	for _, g := range gotCanon {
		counts[g]++
	}
	for _, w := range wantCanon {
		counts[w]--
	}
	keys := make([]string, 0, len(counts))
	for k, n := range counts {
		if n != 0 {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)

	var msg string
	for _, k := range keys {
		if counts[k] > 0 {
			msg += fmt.Sprintf("\n  EXTRA (x%d): %s", counts[k], k)
		} else {
			msg += fmt.Sprintf("\n  MISSING (x%d): %s", -counts[k], k)
		}
	}
	t.Errorf("%s: %d element(s) got, %d want%s", what, len(gotCanon), len(wantCanon), msg)
}

// normalizeStrings turns a nil slice into an empty one and sorts it, so a
// binding that returns nil for "no neighbours" compares equal to the corpus's
// `[]`.
func normalizeStrings(in []string) []string {
	out := append([]string{}, in...)
	sort.Strings(out)
	return out
}

func requireSameClosure(t *testing.T, what string, got, want map[string]corpusClosureEntry) {
	t.Helper()
	if len(got) != len(want) {
		gotKeys := make([]string, 0, len(got))
		for k := range got {
			gotKeys = append(gotKeys, k)
		}
		wantKeys := make([]string, 0, len(want))
		for k := range want {
			wantKeys = append(wantKeys, k)
		}
		sort.Strings(gotKeys)
		sort.Strings(wantKeys)
		t.Errorf("%s: %d keys, want %d\n  got:  %v\n  want: %v", what, len(got), len(want), gotKeys, wantKeys)
		return
	}
	keys := make([]string, 0, len(want))
	for k := range want {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		g, ok := got[k]
		if !ok {
			t.Errorf("%s: missing closure entry for %q", what, k)
			continue
		}
		w := want[k]
		if !reflect.DeepEqual(normalizeStrings(g.Adjacency), normalizeStrings(w.Adjacency)) {
			t.Errorf("%s[%q].adjacency = %v, want %v", what, k, normalizeStrings(g.Adjacency), normalizeStrings(w.Adjacency))
		}
		if !reflect.DeepEqual(normalizeStrings(g.Predecessors), normalizeStrings(w.Predecessors)) {
			t.Errorf("%s[%q].predecessors = %v, want %v", what, k, normalizeStrings(g.Predecessors), normalizeStrings(w.Predecessors))
		}
		if !reflect.DeepEqual(normalizeStrings(g.Successors), normalizeStrings(w.Successors)) {
			t.Errorf("%s[%q].successors = %v, want %v", what, k, normalizeStrings(g.Successors), normalizeStrings(w.Successors))
		}
	}
}

// ---------------------------------------------------------------------------
// Go graph -> corpus shape
// ---------------------------------------------------------------------------

func shapeComponentNodes(graph *ComponentGraph) []corpusComponentNode {
	out := make([]corpusComponentNode, 0, len(graph.Nodes))
	for _, n := range graph.Nodes {
		out = append(out, corpusComponentNode{
			ID:           n.ID,
			Type:         n.Type,
			VarCount:     n.Metadata.VarCount,
			EqCount:      n.Metadata.EqCount,
			SpeciesCount: n.Metadata.SpeciesCount,
		})
	}
	return out
}

func shapeCouplingEdges(graph *ComponentGraph) []corpusCouplingEdge {
	out := make([]corpusCouplingEdge, 0, len(graph.Edges))
	for _, e := range graph.Edges {
		label := ""
		if e.Data.Label != nil {
			label = *e.Data.Label
		}
		out = append(out, corpusCouplingEdge{
			From:  e.Source.ID,
			To:    e.Target.ID,
			Type:  string(e.Data.Type),
			Label: label,
		})
	}
	return out
}

func shapeComponentClosure(graph *ComponentGraph) map[string]corpusClosureEntry {
	c := graph.closure()
	out := make(map[string]corpusClosureEntry, len(graph.Nodes))
	for _, n := range graph.Nodes {
		out[n.ID] = corpusClosureEntry{
			Adjacency:    c.adjacent(n.ID),
			Predecessors: c.predecessor(n.ID),
			Successors:   c.successor(n.ID),
		}
	}
	return out
}

func shapeExpressionGraph(graph *ExpressionGraph) corpusExprGraph {
	nodes := make([]corpusVariableNode, 0, len(graph.Nodes))
	for _, n := range graph.Nodes {
		nodes = append(nodes, corpusVariableNode{
			Name:   n.Name,
			Kind:   n.Kind,
			Units:  n.Units,
			System: n.System,
		})
	}
	edges := make([]corpusDependencyEdge, 0, len(graph.Edges))
	for _, e := range graph.Edges {
		idx := 0
		if e.Data.EquationIndex != nil {
			idx = *e.Data.EquationIndex
		}
		edges = append(edges, corpusDependencyEdge{
			Source:        e.Data.Source,
			Target:        e.Data.Target,
			Relationship:  e.Data.Relationship,
			EquationIndex: idx,
		})
	}
	c := graph.closure()
	closure := make(map[string]corpusClosureEntry, len(graph.Nodes))
	for _, n := range graph.Nodes {
		closure[n.Name] = corpusClosureEntry{
			Adjacency:    c.adjacent(n.Name),
			Predecessors: c.predecessor(n.Name),
			Successors:   c.successor(n.Name),
		}
	}
	return corpusExprGraph{Nodes: nodes, Edges: edges, Closure: closure}
}

// shapeJSONExport reduces an exported JSON adjacency list to the part the
// corpus pins: the top-level keys, the node ids, each edge's two endpoints, and
// the adjacency map (with each neighbour list sorted — a node's neighbour ORDER
// is no more a conformance property than the node list's own order).
func shapeJSONExport(t *testing.T, jsonStr string) corpusJSONExport {
	t.Helper()
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(jsonStr), &raw); err != nil {
		t.Fatalf("export is not valid JSON: %v", err)
	}

	keys := make([]string, 0, len(raw))
	for k := range raw {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var nodes []struct {
		ID string `json:"id"`
	}
	if data, ok := raw["nodes"]; ok {
		if err := json.Unmarshal(data, &nodes); err != nil {
			t.Fatalf("export `nodes` is not a list of objects carrying an id: %v", err)
		}
	}
	nodeIDs := make([]string, 0, len(nodes))
	for _, n := range nodes {
		nodeIDs = append(nodeIDs, n.ID)
	}

	edges := []corpusJSONEndpoint{}
	if data, ok := raw["edges"]; ok {
		if err := json.Unmarshal(data, &edges); err != nil {
			t.Fatalf("export `edges` endpoints are not node-key strings: %v", err)
		}
	}

	adjacency := map[string][]string{}
	if data, ok := raw["adjacency"]; ok {
		if err := json.Unmarshal(data, &adjacency); err != nil {
			t.Fatalf("export `adjacency` is not a map of node key to neighbour keys: %v", err)
		}
	}
	for k, v := range adjacency {
		adjacency[k] = normalizeStrings(v)
	}

	return corpusJSONExport{
		TopLevelKeys: keys,
		NodeIDs:      nodeIDs,
		Edges:        edges,
		Adjacency:    adjacency,
	}
}

func requireSameJSONExport(t *testing.T, what string, got, want corpusJSONExport) {
	t.Helper()
	if !reflect.DeepEqual(normalizeStrings(got.TopLevelKeys), normalizeStrings(want.TopLevelKeys)) {
		t.Errorf("%s top-level keys = %v, want %v", what, got.TopLevelKeys, want.TopLevelKeys)
	}
	requireSameMultiset(t, what+" node ids", got.NodeIDs, want.NodeIDs)
	requireSameMultiset(t, what+" edges", got.Edges, want.Edges)

	wantAdj := want.Adjacency
	if wantAdj == nil {
		wantAdj = map[string][]string{}
	}
	if len(got.Adjacency) != len(wantAdj) {
		t.Errorf("%s adjacency has %d keys, want %d", what, len(got.Adjacency), len(wantAdj))
	}
	keys := make([]string, 0, len(wantAdj))
	for k := range wantAdj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		g, ok := got.Adjacency[k]
		if !ok {
			t.Errorf("%s adjacency: missing key %q", what, k)
			continue
		}
		if !reflect.DeepEqual(normalizeStrings(g), normalizeStrings(wantAdj[k])) {
			t.Errorf("%s adjacency[%q] = %v, want %v", what, k, normalizeStrings(g), normalizeStrings(wantAdj[k]))
		}
	}
}

// ---------------------------------------------------------------------------
// The drivers
// ---------------------------------------------------------------------------

func loadGraphCorpus(t *testing.T) (*graphCorpus, string) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "conformance", "graph", "cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var corpus graphCorpus
	if err := json.Unmarshal(data, &corpus); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	if len(corpus.Files) == 0 || len(corpus.Targets) == 0 {
		t.Fatalf("corpus at %s has no cases", path)
	}
	return &corpus, repoRoot
}

// TestGraphConformanceFiles drives every whole-document case: the component
// graph, its JSON adjacency-list export, the expression graph, its JSON export,
// and the merge-coupled expression graph.
func TestGraphConformanceFiles(t *testing.T) {
	corpus, repoRoot := loadGraphCorpus(t)

	for _, c := range corpus.Files {
		t.Run(c.Name, func(t *testing.T) {
			file, err := Load(filepath.Join(repoRoot, c.InputFile))
			if err != nil {
				t.Fatalf("load %s: %v", c.InputFile, err)
			}

			cg := ComponentGraphFromFile(file)
			requireSameMultiset(t, "component_graph.nodes", shapeComponentNodes(cg), c.ComponentGraph.Nodes)
			requireSameMultiset(t, "component_graph.edges", shapeCouplingEdges(cg), c.ComponentGraph.Edges)
			requireSameClosure(t, "component_graph.closure", shapeComponentClosure(cg), c.ComponentGraph.Closure)

			cgJSON, err := ExportComponentGraphJSON(cg)
			if err != nil {
				t.Fatalf("export component graph JSON: %v", err)
			}
			requireSameJSONExport(t, "component_graph_json", shapeJSONExport(t, cgJSON), c.ComponentGraphJSON)

			eg := ExpressionGraphFromFile(file)
			got := shapeExpressionGraph(eg)
			requireSameMultiset(t, "expression_graph.nodes", got.Nodes, c.ExpressionGraph.Nodes)
			requireSameMultiset(t, "expression_graph.edges", got.Edges, c.ExpressionGraph.Edges)
			requireSameClosure(t, "expression_graph.closure", got.Closure, c.ExpressionGraph.Closure)

			egJSON, err := ExportExpressionGraphJSON(eg)
			if err != nil {
				t.Fatalf("export expression graph JSON: %v", err)
			}
			requireSameJSONExport(t, "expression_graph_json", shapeJSONExport(t, egJSON), c.ExpressionGraphJSON)

			merged := ExpressionGraphFromFileWithOptions(file, ExpressionGraphOptions{MergeCoupled: true})
			gotMerged := shapeExpressionGraph(merged)
			requireSameMultiset(t, "merge_coupled.nodes", gotMerged.Nodes, c.MergeCoupled.Nodes)
			requireSameMultiset(t, "merge_coupled.edges", gotMerged.Edges, c.MergeCoupled.Edges)
			requireSameClosure(t, "merge_coupled.closure", gotMerged.Closure, c.MergeCoupled.Closure)
		})
	}
}

// TestGraphConformanceTargets drives the five sub-document expressionGraph
// overloads §4.8.2 requires beside the EsmFile one: a Model, a ReactionSystem,
// an Equation, a Reaction and a bare Expr. Their nodes carry BARE names in the
// synthetic "default" system.
func TestGraphConformanceTargets(t *testing.T) {
	corpus, _ := loadGraphCorpus(t)

	for _, c := range corpus.Targets {
		t.Run(c.Name, func(t *testing.T) {
			var graph *ExpressionGraph

			switch c.Kind {
			case "model":
				var model Model
				if err := json.Unmarshal(c.Target, &model); err != nil {
					t.Fatalf("decode model target: %v", err)
				}
				graph = ExpressionGraphFromModel(model, defaultSystem)
			case "reaction_system":
				var system ReactionSystem
				if err := json.Unmarshal(c.Target, &system); err != nil {
					t.Fatalf("decode reaction_system target: %v", err)
				}
				graph = ExpressionGraphFromReactionSystem(system, defaultSystem)
			case "equation":
				var equation Equation
				if err := json.Unmarshal(c.Target, &equation); err != nil {
					t.Fatalf("decode equation target: %v", err)
				}
				graph = ExpressionGraphFromEquation(equation)
			case "reaction":
				var reaction Reaction
				if err := json.Unmarshal(c.Target, &reaction); err != nil {
					t.Fatalf("decode reaction target: %v", err)
				}
				graph = ExpressionGraphFromReaction(reaction)
			case "expression":
				expr, err := UnmarshalExpression(c.Target)
				if err != nil {
					t.Fatalf("decode expression target: %v", err)
				}
				graph = ExpressionGraphFromExpression(expr)
			default:
				t.Fatalf("unknown target kind %q", c.Kind)
			}

			got := shapeExpressionGraph(graph)
			requireSameMultiset(t, "expression_graph.nodes", got.Nodes, c.ExpressionGraph.Nodes)
			requireSameMultiset(t, "expression_graph.edges", got.Edges, c.ExpressionGraph.Edges)
			requireSameClosure(t, "expression_graph.closure", got.Closure, c.ExpressionGraph.Closure)
		})
	}
}
