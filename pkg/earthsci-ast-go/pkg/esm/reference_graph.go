package esm

// reference_graph.go implements build-time NODE ADDRESSING and reference-edge
// resolution for the semiring-FAQ unified IR — the hard prerequisite the §6.1
// cadence-partition pass of the `semiring-faq-unified-ir` RFC calls out:
//
//	"node addressing — referencing a node by id — is a hard prerequisite: the
//	 pass cannot be built until `from_faq` and join references are real edges
//	 in this DAG."
//
// The partition pass classifies every node by cadence (CONST / DISCRETE /
// CONTINUOUS) by walking the INTER-NODE dependency DAG bottom-up
// (class(n) = max over inputs). For that walk to exist, three kinds of name/id
// reference in the document must be resolved into real, queryable graph edges
// (RFC §6.1 "Propagation"):
//
//   - an aggregate node → an index set it references (`ranges[*].from`);
//   - a `kind:"derived"` index set → its `from_faq` node (by stable id);
//   - an aggregate `join.on` factor → the factor it names.
//
// Like the Julia, Python, and Rust bindings, this pass operates on the RAW
// document view (a decoded `map[string]any`), not the typed ExprNode tree. The
// raw view is what gives every node its STRUCTURAL PATH (`equations/0/rhs/expr`)
// — the stable address a node without an explicit `id` is known by — spelled
// with the document's own JSON key names, so an address minted here means the
// same thing in every binding. BuildReferenceGraphFromModel /
// ResolveReferencesInFile are typed conveniences that render an ESMFile to that
// view first.
//
// The output ReferenceGraph is the queryable surface the partition pass
// consumes: Dependencies / Dependents give the DAG adjacency, and
// TopologicalOrder both detects reference cycles (an out-of-scope
// implicit/iterative solve, RFC §6.1 "Acyclicity") and yields a bottom-up
// evaluation order.
//
// Reference bindings: Python `src/earthsci_ast/reference_resolution.py` and
// Rust `src/reference_resolution.rs`, which agree; Julia
// `src/reference_graph.jl` for the error type name and the stable `E_REF_*`
// codes. Documented divergences are marked DIVERGENCE below.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// --- stable diagnostic codes (mirrored across the Julia / Python bindings) ---

const (
	// CodeRefUndeclaredIndexSet: an undeclared name in a `ranges[*].from`.
	CodeRefUndeclaredIndexSet = "E_REF_UNDECLARED_INDEX_SET"
	// CodeRefUnknownFAQNode: a `kind:"derived"` index set's `from_faq` names no
	// node id in the model.
	CodeRefUnknownFAQNode = "E_REF_UNKNOWN_FAQ_NODE"
	// CodeRefDuplicateNodeID: two expression nodes in the same model share an
	// explicit `id`.
	CodeRefDuplicateNodeID = "E_REF_DUPLICATE_NODE_ID"
	// CodeRefUnresolvedJoinFactor: a `join.on` factor reference names nothing in
	// the node's scope.
	CodeRefUnresolvedJoinFactor = "E_REF_UNRESOLVED_JOIN_FACTOR"
	// CodeRefCycle: a directed cycle exists among the reference edges.
	CodeRefCycle = "E_REF_CYCLE"
)

// ReferenceResolutionError reports that a reference could not be resolved, or
// that the reference graph has a cycle.
//
// It carries a stable Code (one of the CodeRef* constants) so callers and the
// cross-binding conformance suite can assert on the failure mode, and a
// human-readable Message. For a cycle, Cycle holds the offending vertex-key
// path. The Rust binding spells this type `ReferenceError`; Julia and Python
// both call it `ReferenceResolutionError`, which is the name used here.
type ReferenceResolutionError struct {
	Code    string
	Message string
	Cycle   []string
}

func (e *ReferenceResolutionError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode exposes the stable code, matching the convention of
// SubstitutionError / EvaluationError elsewhere in this package.
func (e *ReferenceResolutionError) DiagnosticCode() string { return e.Code }

func refErr(code, format string, args ...any) *ReferenceResolutionError {
	return &ReferenceResolutionError{Code: code, Message: fmt.Sprintf(format, args...)}
}

// --- vertex / edge model ---------------------------------------------------

// VertexKind is one of the three kinds of vertex in a reference graph.
type VertexKind string

const (
	// VertexKindNode is an expression node (aggregate, or `id`-bearing).
	VertexKindNode VertexKind = "node"
	// VertexKindIndexSet is a declared `index_sets` entry.
	VertexKindIndexSet VertexKind = "index_set"
	// VertexKindFactor is a factor named by a `join.on` reference.
	VertexKindFactor VertexKind = "factor"
)

// EdgeKind is one of the three kinds of reference edge (RFC §6.1
// "Propagation").
type EdgeKind string

const (
	// EdgeKindRangeFrom: aggregate node → the index set it iterates
	// (`ranges[*].from`).
	EdgeKindRangeFrom EdgeKind = "range_from"
	// EdgeKindFromFAQ: `kind:"derived"` index set → the node that materializes
	// it (`from_faq`).
	EdgeKindFromFAQ EdgeKind = "from_faq"
	// EdgeKindJoinFactor: aggregate node → a factor named by `join.on`.
	EdgeKindJoinFactor EdgeKind = "join_factor"
)

// ReferenceVertex is a vertex in the reference graph, addressed by a
// kind-namespaced Key.
//
// Key is "<kind>:<name>". For a VertexKindNode vertex, Name is the node's
// STABLE ADDRESS: its explicit `id` when it has one, else its structural path
// (e.g. `equations/0/rhs/expr`). NodeID records the explicit id (empty when
// absent), Op the operator, and Path the structural path — all three for
// diagnostics.
type ReferenceVertex struct {
	Key    string
	Kind   VertexKind
	Name   string
	Op     string
	NodeID string
	Path   string
}

// ReferenceEdge is a directed source → target edge: SOURCE REFERENCES /
// DEPENDS ON TARGET.
type ReferenceEdge struct {
	Source string
	Target string
	Kind   EdgeKind
}

// ReferenceGraph is the resolved reference DAG for one model — the partition
// pass's input.
//
// Vertices are keyed by their kind-namespaced Key. Edges point from a vertex to
// a vertex it DEPENDS ON, so a bottom-up (TopologicalOrder) walk visits each
// vertex after its dependencies — exactly the order class(n) = max(class(inputs))
// propagation needs.
type ReferenceGraph struct {
	// Model is the name of the model this graph was built for.
	Model string
	// Edges are the reference edges in discovery order.
	Edges []ReferenceEdge

	vertices    map[string]ReferenceVertex
	vertexOrder []string
	out         map[string][]string
	in          map[string][]string
}

func newReferenceGraph(model string) *ReferenceGraph {
	return &ReferenceGraph{
		Model:    model,
		vertices: map[string]ReferenceVertex{},
		out:      map[string][]string{},
		in:       map[string][]string{},
	}
}

func (g *ReferenceGraph) ensureVertex(v ReferenceVertex) {
	if _, ok := g.vertices[v.Key]; ok {
		return
	}
	g.vertices[v.Key] = v
	g.vertexOrder = append(g.vertexOrder, v.Key)
	if _, ok := g.out[v.Key]; !ok {
		g.out[v.Key] = nil
	}
	if _, ok := g.in[v.Key]; !ok {
		g.in[v.Key] = nil
	}
}

func (g *ReferenceGraph) addEdge(source, target string, kind EdgeKind) {
	g.Edges = append(g.Edges, ReferenceEdge{Source: source, Target: target, Kind: kind})
	g.out[source] = append(g.out[source], target)
	g.in[target] = append(g.in[target], source)
}

// Vertex returns the vertex with the given key.
func (g *ReferenceGraph) Vertex(key string) (ReferenceVertex, bool) {
	v, ok := g.vertices[key]
	return v, ok
}

// VertexKeys returns every vertex key in discovery order.
func (g *ReferenceGraph) VertexKeys() []string {
	out := make([]string, len(g.vertexOrder))
	copy(out, g.vertexOrder)
	return out
}

// Vertices returns every vertex in discovery order.
func (g *ReferenceGraph) Vertices() []ReferenceVertex {
	out := make([]ReferenceVertex, 0, len(g.vertexOrder))
	for _, k := range g.vertexOrder {
		out = append(out, g.vertices[k])
	}
	return out
}

// Len returns the number of vertices.
func (g *ReferenceGraph) Len() int { return len(g.vertices) }

// Dependencies returns the vertices `key` references / depends on (its
// out-neighbours), in discovery order.
func (g *ReferenceGraph) Dependencies(key string) []string {
	out := make([]string, len(g.out[key]))
	copy(out, g.out[key])
	return out
}

// Dependents returns the vertices that reference / depend on `key` (its
// in-neighbours), in discovery order.
func (g *ReferenceGraph) Dependents(key string) []string {
	out := make([]string, len(g.in[key]))
	copy(out, g.in[key])
	return out
}

// EdgesOfKind returns every edge of the given kind, in discovery order.
func (g *ReferenceGraph) EdgesOfKind(kind EdgeKind) []ReferenceEdge {
	out := []ReferenceEdge{}
	for _, e := range g.Edges {
		if e.Kind == kind {
			out = append(out, e)
		}
	}
	return out
}

// DetectCycle returns a reference cycle as a vertex-key path, or nil when the
// graph is acyclic.
//
// Three-colour DFS over the dependency edges, made deterministic by visiting
// starts and neighbours in sorted-key order. The returned path is [v, …, v]
// (the repeated vertex closes the cycle).
func (g *ReferenceGraph) DetectCycle() []string {
	const (
		white = 0
		grey  = 1
		black = 2
	)
	colour := make(map[string]int, len(g.vertices))
	starts := make([]string, 0, len(g.vertices))
	for k := range g.vertices {
		colour[k] = white
		starts = append(starts, k)
	}
	sort.Strings(starts)

	type frame struct {
		node string
		i    int
	}

	for _, start := range starts {
		if colour[start] != white {
			continue
		}
		stack := []frame{{node: start}}
		path := []string{start}
		colour[start] = grey
		for len(stack) > 0 {
			top := &stack[len(stack)-1]
			neighbours := append([]string(nil), g.out[top.node]...)
			sort.Strings(neighbours)
			if top.i < len(neighbours) {
				next := neighbours[top.i]
				top.i++
				switch colour[next] {
				case grey:
					// Back edge → cycle; slice the path from next's first use.
					idx := 0
					for i, p := range path {
						if p == next {
							idx = i
							break
						}
					}
					return append(append([]string(nil), path[idx:]...), next)
				case white:
					colour[next] = grey
					stack = append(stack, frame{node: next})
					path = append(path, next)
				}
			} else {
				colour[top.node] = black
				stack = stack[:len(stack)-1]
				path = path[:len(path)-1]
			}
		}
	}
	return nil
}

// TopologicalOrder returns a bottom-up order (dependencies before dependents).
//
// Returns a *ReferenceResolutionError with code E_REF_CYCLE if the graph is
// cyclic — a cycle among reference edges is an out-of-scope implicit/iterative
// solve (RFC §6.1 "Acyclicity").
//
// Two deliberate passes rather than one Kahn sweep: DetectCycle's DFS reports
// the actual cycle PATH (Kahn's leftover-vertex set cannot name the path), and
// the wave loop below emits ready vertices in sorted-key order per wave, keeping
// the materialization order deterministic. Document node counts are small, so
// the O(V²) scan is irrelevant; after the cycle check the no-progress break is
// unreachable.
func (g *ReferenceGraph) TopologicalOrder() ([]string, error) {
	if cyc := g.DetectCycle(); cyc != nil {
		return nil, &ReferenceResolutionError{
			Code:    CodeRefCycle,
			Message: "reference cycle detected: " + strings.Join(cyc, " -> "),
			Cycle:   cyc,
		}
	}
	keys := make([]string, 0, len(g.vertices))
	for k := range g.vertices {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	emitted := make([]string, 0, len(keys))
	done := make(map[string]bool, len(keys))
	for len(emitted) < len(keys) {
		progressed := false
		for _, k := range keys {
			if done[k] {
				continue
			}
			ready := true
			for _, d := range g.out[k] {
				if !done[d] {
					ready = false
					break
				}
			}
			if ready {
				emitted = append(emitted, k)
				done[k] = true
				progressed = true
			}
		}
		if !progressed {
			break
		}
	}
	return emitted, nil
}

// --- the resolution pass ---------------------------------------------------

func nodeKey(addr string) string     { return string(VertexKindNode) + ":" + addr }
func indexSetKey(name string) string { return string(VertexKindIndexSet) + ":" + name }
func factorKeyOf(name string) string { return string(VertexKindFactor) + ":" + name }

// aggregateOps is the set of ops that participate in node addressing without
// carrying an explicit `id` (Python's AGGREGATE_OPS).
var aggregateOps = map[string]bool{opAggregate: true}

// nonEmptyString reads a non-empty string field out of a raw object.
func nonEmptyString(m map[string]any, key string) (string, bool) {
	s, ok := m[key].(string)
	if !ok || s == "" {
		return "", false
	}
	return s, true
}

func rawObject(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

func rawArray(v any) ([]any, bool) {
	a, ok := v.([]any)
	return a, ok
}

// sortedRawKeys returns a raw object's keys in sorted order.
//
// DIVERGENCE (ordering): Python iterates dicts in DOCUMENT order and Rust uses
// serde_json's `preserve_order`, so both walk a document's keys as authored.
// Go's encoding/json decodes an object into an unordered map, so this walk
// sorts instead. Every part of the queryable surface is either order-insensitive
// (Dependencies / Dependents / EdgesOfKind) or explicitly sorted (DetectCycle /
// TopologicalOrder), so the only observable effects are the order of the Edges
// slice and, in a document carrying MORE THAN ONE unresolved reference, which of
// them is reported first.
func sortedRawKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// factorScope returns the names a `join.on` reference on this node may resolve
// to: the node's string factor-args, its declared range keys, and its symbolic
// output_idx.
func factorScope(node map[string]any) map[string]bool {
	names := map[string]bool{}
	if args, ok := rawArray(node["args"]); ok {
		for _, a := range args {
			if s, ok := a.(string); ok {
				names[s] = true
			}
		}
	}
	if ranges, ok := rawObject(node["ranges"]); ok {
		for k := range ranges {
			names[k] = true
		}
	}
	if outputIdx, ok := rawArray(node["output_idx"]); ok {
		for _, o := range outputIdx {
			if s, ok := o.(string); ok {
				names[s] = true
			}
		}
	}
	return names
}

// nodeAddr records where an explicit node id was first seen.
type nodeAddr struct {
	addr string
	path string
}

// registerAndProcess registers one operator node as an addressable vertex (when
// it is an aggregate or carries an explicit `id`) and adds its within-node
// reference edges (`ranges[*].from`, `join.on`).
func registerAndProcess(
	g *ReferenceGraph,
	node map[string]any,
	path, modelName string,
	indexSets map[string]any,
	idToAddr map[string]nodeAddr,
) error {
	op, _ := node["op"].(string)
	nodeID, hasID := nonEmptyString(node, "id")
	// Only nodes that participate in addressing become vertices: the
	// aggregate / FAQ nodes, and any node carrying an explicit id.
	if !aggregateOps[op] && !hasID {
		return nil
	}
	addr := path
	if hasID {
		addr = nodeID
	}
	key := nodeKey(addr)

	if hasID {
		if first, seen := idToAddr[nodeID]; seen {
			return refErr(CodeRefDuplicateNodeID,
				"duplicate expression-node id '%s' in model '%s' (at %s and %s)",
				nodeID, modelName, path, first.path)
		}
		idToAddr[nodeID] = nodeAddr{addr: addr, path: path}
	}

	g.ensureVertex(ReferenceVertex{
		Key: key, Kind: VertexKindNode, Name: addr,
		Op: op, NodeID: nodeID, Path: path,
	})

	// ranges[*].from -> index set
	if ranges, ok := rawObject(node["ranges"]); ok {
		for _, idxName := range sortedRawKeys(ranges) {
			spec, ok := rawObject(ranges[idxName])
			if !ok {
				continue
			}
			raw, has := spec["from"]
			if !has {
				continue
			}
			target, _ := raw.(string)
			if _, declared := indexSets[target]; target == "" || !declared {
				return refErr(CodeRefUndeclaredIndexSet,
					"range '%s' of node %s references undeclared index set '%s' (model '%s', at %s)",
					idxName, key, target, modelName, path)
			}
			g.addEdge(key, indexSetKey(target), EdgeKindRangeFrom)
		}
	}

	// join[*].on[*] -> factor
	if join, ok := rawArray(node["join"]); ok {
		scope := factorScope(node)
		for _, clause := range join {
			clauseObj, ok := rawObject(clause)
			if !ok {
				continue
			}
			on, ok := rawArray(clauseObj["on"])
			if !ok {
				continue
			}
			for _, pair := range on {
				pairArr, ok := rawArray(pair)
				// DIVERGENCE (malformed pair): Python and Julia SKIP a `on`
				// entry that is not a non-empty array; Rust reports it as an
				// unresolved factor named "". The 2-of-3 majority is followed
				// here — a malformed pair is a SCHEMA problem, and inventing an
				// empty factor name for it makes the diagnostic worse.
				if !ok || len(pairArr) == 0 {
					continue
				}
				ref, isStr := pairArr[0].(string)
				if !isStr || !scope[ref] {
					return refErr(CodeRefUnresolvedJoinFactor,
						"join factor '%s' of node %s names no factor, range, or output index in scope (model '%s', at %s)",
						ref, key, modelName, path)
				}
				g.ensureVertex(ReferenceVertex{
					Key: factorKeyOf(ref), Kind: VertexKindFactor, Name: ref,
				})
				g.addEdge(key, factorKeyOf(ref), EdgeKindJoinFactor)
			}
		}
	}

	return nil
}

// walkReferences descends the raw document tree, registering every operator
// node it meets and resolving that node's within-node references.
func walkReferences(
	g *ReferenceGraph,
	value any,
	path, modelName string,
	indexSets map[string]any,
	idToAddr map[string]nodeAddr,
) error {
	switch v := value.(type) {
	case map[string]any:
		if _, isNode := v["op"]; isNode {
			if err := registerAndProcess(g, v, path, modelName, indexSets, idToAddr); err != nil {
				return err
			}
		}
		for _, k := range sortedRawKeys(v) {
			if err := walkReferences(g, v[k], path+"/"+k, modelName, indexSets, idToAddr); err != nil {
				return err
			}
		}
	case []any:
		for i, el := range v {
			if err := walkReferences(g, el, fmt.Sprintf("%s/%d", path, i), modelName, indexSets, idToAddr); err != nil {
				return err
			}
		}
	}
	return nil
}

// referenceWalkRoots are the model members whose expression trees carry
// addressable nodes.
var referenceWalkRoots = []string{"equations", "initialization_equations"}

// BuildReferenceGraph resolves the reference edges of one raw `model` view into
// a graph.
//
// `docIndexSets` is the DOCUMENT-SCOPED index-set registry (RFC §5.2), which as
// of v0.8.0 lives at the top level of the document rather than on each model;
// ResolveReferences threads the document registry in for every model. Any
// model-nested `index_sets` key is MERGED on top of it — a model-level entry
// wins a key collision — so a pre-0.8.0 nested shape still resolves. Pass nil
// for `docIndexSets` to rely on the model-nested key alone.
//
// Returns a *ReferenceResolutionError on a duplicate node id, an undeclared
// `ranges[*].from` index set, a `from_faq` naming no node, or an unresolved
// `join.on` factor. Cycles are reported lazily by
// ReferenceGraph.TopologicalOrder, or eagerly by ResolveReferences.
func BuildReferenceGraph(model map[string]any, modelName string, docIndexSets map[string]any) (*ReferenceGraph, error) {
	g := newReferenceGraph(modelName)

	// Merge the document-scoped registry (v0.8.0+) with any model-nested one
	// (pre-0.8.0); model-level entries take precedence on a key collision.
	indexSets := map[string]any{}
	for k, v := range docIndexSets {
		indexSets[k] = v
	}
	if modelIndexSets, ok := rawObject(model["index_sets"]); ok {
		for k, v := range modelIndexSets {
			indexSets[k] = v
		}
	}

	// Pass 1 — register declared index sets as vertices.
	for _, name := range sortedRawKeys(indexSets) {
		g.ensureVertex(ReferenceVertex{
			Key: indexSetKey(name), Kind: VertexKindIndexSet, Name: name,
		})
	}

	// Pass 2 — walk every expression node: assign a stable address, register
	// aggregate / id-bearing nodes, and add the within-node reference edges
	// (ranges[*].from, join.on). Builds id -> address for from_faq.
	idToAddr := map[string]nodeAddr{}
	for _, root := range referenceWalkRoots {
		v, has := model[root]
		if !has {
			continue
		}
		if err := walkReferences(g, v, root, modelName, indexSets, idToAddr); err != nil {
			return nil, err
		}
	}

	// Pass 3 — derived index sets resolve their from_faq to a node by id.
	for _, name := range sortedRawKeys(indexSets) {
		entry, ok := rawObject(indexSets[name])
		if !ok {
			continue
		}
		if kind, _ := entry["kind"].(string); kind != "derived" {
			continue
		}
		faq, _ := entry["from_faq"].(string)
		target, resolved := idToAddr[faq]
		if !resolved {
			return nil, refErr(CodeRefUnknownFAQNode,
				"derived index set '%s' references from_faq '%s', which is not the id of any expression node in model '%s'",
				name, faq, modelName)
		}
		g.addEdge(indexSetKey(name), nodeKey(target.addr), EdgeKindFromFAQ)
	}

	return g, nil
}

// ResolveReferences resolves the reference edges of every model in a raw
// `document` view, returning a {model name: graph} map.
//
// Returns a *ReferenceResolutionError on any unresolved reference OR reference
// cycle — each model's graph is checked acyclic eagerly here, unlike
// BuildReferenceGraph, which leaves cycle detection to TopologicalOrder.
func ResolveReferences(document map[string]any) (map[string]*ReferenceGraph, error) {
	out := map[string]*ReferenceGraph{}
	models, ok := rawObject(document["models"])
	if !ok {
		return out, nil
	}
	// The index-set registry is document-scoped (v0.8.0): read it once from the
	// top level and thread it into every model's graph.
	docIndexSets, _ := rawObject(document["index_sets"])

	for _, name := range sortedRawKeys(models) {
		model, ok := rawObject(models[name])
		if !ok {
			continue
		}
		g, err := BuildReferenceGraph(model, name, docIndexSets)
		if err != nil {
			return nil, err
		}
		if cyc := g.DetectCycle(); cyc != nil {
			return nil, &ReferenceResolutionError{
				Code:    CodeRefCycle,
				Message: fmt.Sprintf("reference cycle in model '%s': %s", name, strings.Join(cyc, " -> ")),
				Cycle:   cyc,
			}
		}
		out[name] = g
	}
	return out, nil
}

// --- typed conveniences ----------------------------------------------------

// rawViewOf renders any value to the raw decoded JSON view the reference pass
// walks. The round-trip is what gives the walk the document's own JSON key
// names, so a structural node address minted from a typed Model reads
// identically to one minted from the file on disk.
func rawViewOf(v any) (map[string]any, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var view map[string]any
	if err := json.Unmarshal(data, &view); err != nil {
		return nil, err
	}
	return view, nil
}

// BuildReferenceGraphFromModel is the typed convenience over
// BuildReferenceGraph: it renders `model` and the document's `index_sets`
// registry to their raw views and resolves against those.
func BuildReferenceGraphFromModel(model *Model, modelName string, indexSets map[string]IndexSet) (*ReferenceGraph, error) {
	if model == nil {
		return newReferenceGraph(modelName), nil
	}
	modelView, err := rawViewOf(model)
	if err != nil {
		return nil, refErr(CodeRefUnknownFAQNode, "cannot render model '%s' to a raw view: %v", modelName, err)
	}
	var indexSetView map[string]any
	if indexSets != nil {
		if indexSetView, err = rawViewOf(indexSets); err != nil {
			return nil, refErr(CodeRefUndeclaredIndexSet, "cannot render index_sets to a raw view: %v", err)
		}
	}
	return BuildReferenceGraph(modelView, modelName, indexSetView)
}

// ResolveReferencesInFile is the typed convenience over ResolveReferences: it
// renders `file` to its raw view and resolves every model in it.
func ResolveReferencesInFile(file *ESMFile) (map[string]*ReferenceGraph, error) {
	if file == nil {
		return map[string]*ReferenceGraph{}, nil
	}
	view, err := rawViewOf(file)
	if err != nil {
		return nil, refErr(CodeRefUnknownFAQNode, "cannot render file to a raw view: %v", err)
	}
	return ResolveReferences(view)
}
