package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

func repoTestsDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..", "tests")
}

// readRawDocument reads a fixture as the RAW decoded JSON view the reference
// pass walks — the same view Python and Rust resolve against.
func readRawDocument(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return doc
}

func edgeStrings(edges []ReferenceEdge) []string {
	out := make([]string, 0, len(edges))
	for _, e := range edges {
		out = append(out, e.Source+" -> "+e.Target)
	}
	sort.Strings(out)
	return out
}

// TestReferenceGraphNodeAddressingFixture drives the shared fixture that exists
// precisely to pin the two inter-node reference edges of RFC §6.1: a derived
// index set → its `from_faq` node, and a node → the index set it references.
func TestReferenceGraphNodeAddressingFixture(t *testing.T) {
	doc := readRawDocument(t, filepath.Join(repoTestsDir(t), "valid", "aggregate", "node_addressing_from_faq.esm"))

	graphs, err := ResolveReferences(doc)
	if err != nil {
		t.Fatalf("ResolveReferences: %v", err)
	}
	g, ok := graphs["NodeAddressingDemo"]
	if !ok {
		t.Fatalf("no graph for NodeAddressingDemo; got %v", graphs)
	}

	// Both declared index sets are vertices.
	for _, key := range []string{"index_set:faces", "index_set:edges"} {
		v, ok := g.Vertex(key)
		if !ok {
			t.Fatalf("missing vertex %s", key)
		}
		if v.Kind != VertexKindIndexSet {
			t.Fatalf("%s kind = %q, want %q", key, v.Kind, VertexKindIndexSet)
		}
	}

	// The id-bearing aggregate is addressed by its EXPLICIT id, not its path.
	producer, ok := g.Vertex("node:edge_enum")
	if !ok {
		t.Fatalf("id-bearing aggregate not addressed by its id; vertices = %v", g.VertexKeys())
	}
	if producer.NodeID != "edge_enum" || producer.Op != "aggregate" {
		t.Fatalf("producer vertex = %+v", producer)
	}
	if producer.Path != "equations/0/rhs" {
		t.Fatalf("producer structural path = %q, want %q", producer.Path, "equations/0/rhs")
	}

	// The anonymous aggregate is addressed by its STRUCTURAL PATH.
	consumer, ok := g.Vertex("node:equations/1/rhs")
	if !ok {
		t.Fatalf("anonymous aggregate not addressed by its path; vertices = %v", g.VertexKeys())
	}
	if consumer.NodeID != "" {
		t.Fatalf("anonymous aggregate carries node id %q", consumer.NodeID)
	}

	// from_faq: index_set:edges → node:edge_enum.
	fromFAQ := g.EdgesOfKind(EdgeKindFromFAQ)
	if len(fromFAQ) != 1 {
		t.Fatalf("from_faq edges = %v, want exactly one", edgeStrings(fromFAQ))
	}
	if fromFAQ[0].Source != "index_set:edges" || fromFAQ[0].Target != "node:edge_enum" {
		t.Fatalf("from_faq edge = %s -> %s", fromFAQ[0].Source, fromFAQ[0].Target)
	}

	// range_from: each aggregate → the index set its `ranges` names.
	got := edgeStrings(g.EdgesOfKind(EdgeKindRangeFrom))
	want := []string{
		"node:edge_enum -> index_set:faces",
		"node:equations/1/rhs -> index_set:edges",
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("range_from edges = %v, want %v", got, want)
	}

	// The DAG is acyclic and orders dependencies before dependents.
	if cyc := g.DetectCycle(); cyc != nil {
		t.Fatalf("unexpected cycle: %v", cyc)
	}
	order, err := g.TopologicalOrder()
	if err != nil {
		t.Fatalf("TopologicalOrder: %v", err)
	}
	pos := map[string]int{}
	for i, k := range order {
		pos[k] = i
	}
	if len(order) != g.Len() {
		t.Fatalf("topological order covers %d of %d vertices", len(order), g.Len())
	}
	for _, e := range g.Edges {
		if pos[e.Target] >= pos[e.Source] {
			t.Fatalf("dependency %s not emitted before dependent %s (order %v)", e.Target, e.Source, order)
		}
	}

	// Adjacency reads both ways.
	if deps := g.Dependencies("index_set:edges"); len(deps) != 1 || deps[0] != "node:edge_enum" {
		t.Fatalf("Dependencies(index_set:edges) = %v", deps)
	}
	if dependents := g.Dependents("node:edge_enum"); len(dependents) != 1 || dependents[0] != "index_set:edges" {
		t.Fatalf("Dependents(node:edge_enum) = %v", dependents)
	}
}

// TestReferenceGraphRejectsUndeclaredIndexSet drives the shared INVALID fixture
// that is schema-valid but resolver-invalid. tests/invalid/expected_errors.json
// records this exact failure mode for the reference pass:
// "Python build_reference_graph -> ReferenceResolutionError
// E_REF_UNDECLARED_INDEX_SET".
func TestReferenceGraphRejectsUndeclaredIndexSet(t *testing.T) {
	doc := readRawDocument(t, filepath.Join(repoTestsDir(t), "invalid", "aggregate", "undeclared_from_name.esm"))

	_, err := ResolveReferences(doc)
	if err == nil {
		t.Fatal("ResolveReferences accepted an undeclared `ranges[*].from` name")
	}
	var refErr *ReferenceResolutionError
	if !asReferenceError(err, &refErr) {
		t.Fatalf("error type = %T, want *ReferenceResolutionError", err)
	}
	if refErr.Code != CodeRefUndeclaredIndexSet {
		t.Fatalf("code = %q, want %q", refErr.Code, CodeRefUndeclaredIndexSet)
	}
	if !strings.Contains(refErr.Message, "ghost_cells") {
		t.Fatalf("message does not name the undeclared set: %s", refErr.Message)
	}
}

// referenceCorpusRejections records the schema-valid fixtures that the
// reference pass nevertheless refuses, and why.
//
// These are NOT Go bugs and NOT fixture bugs this task may fix: each is a
// pre-existing gap in the shared corpus, and the Python binding
// (`build_reference_graph`) rejects every one of them with the SAME code and
// the same message. They are pinned here so the sweep below can assert the
// exact partition — accepted vs rejected — rather than the weaker "never
// errors", which the corpus does not satisfy.
//
// See tests/CORPUS_DEFECTS.md.
//
//   - skolem_distinct_rank.esm: a derived index set's `from_faq` names a
//     producer id that appears only in a `_comment`, never as a node `id`
//     anywhere in the document, so nothing is addressable by it (defect #1).
//   - conservative_regrid_assembly.esm and wildfire_atmosphere_ocean.esm: an
//     aggregate `join.on` names a factor (`src_bin` / `rg_src_bin`) that is not
//     among the node's string args, range keys, or symbolic output_idx
//     (defect #3). wildfire's instance was masked until `from_faq` moved to
//     document scope (esm-spec §9.7.5): it used to fail earlier, with
//     E_REF_UNKNOWN_FAQ_NODE, because its producer lives in another model.
var referenceCorpusRejections = map[string]string{
	"aggregate/skolem_distinct_rank.esm":        CodeRefUnknownFAQNode,
	"geometry/conservative_regrid_assembly.esm": CodeRefUnresolvedJoinFactor,
	"wildfire_atmosphere_ocean.esm":             CodeRefUnresolvedJoinFactor,
}

// TestReferenceGraphOverValidCorpus resolves EVERY schema-valid fixture in the
// shared corpus and asserts the accepted/rejected partition recorded in
// referenceCorpusRejections. Every accepted graph must also be acyclic.
//
// This is the corpus-wide conformance check: the same sweep run against the
// Python binding produces an identical partition, and for the accepted
// fixtures an identical vertex set and edge set.
func TestReferenceGraphOverValidCorpus(t *testing.T) {
	validDir := filepath.Join(repoTestsDir(t), "valid")
	var fixtures []string
	err := filepath.Walk(validDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(path, ".esm") {
			fixtures = append(fixtures, path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk tests/valid: %v", err)
	}
	if len(fixtures) == 0 {
		t.Fatal("tests/valid holds no .esm fixtures")
	}

	seenRejections := map[string]bool{}
	for _, path := range fixtures {
		path := path
		rel, _ := filepath.Rel(validDir, path)
		rel = filepath.ToSlash(rel)
		t.Run(rel, func(t *testing.T) {
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read: %v", err)
			}
			var doc map[string]any
			if err := json.Unmarshal(raw, &doc); err != nil {
				// A handful of fixtures are deliberately not standalone JSON
				// documents; the reference pass has nothing to say about them.
				t.Skipf("not a JSON object: %v", err)
			}

			wantCode, wantRejected := referenceCorpusRejections[rel]
			graphs, err := ResolveReferences(doc)
			if wantRejected {
				seenRejections[rel] = true
				if err == nil {
					t.Fatalf("fixture is pinned as rejected (%s) but resolved clean; "+
						"if the corpus was fixed, drop it from referenceCorpusRejections", wantCode)
				}
				var refErr *ReferenceResolutionError
				if !asReferenceError(err, &refErr) {
					t.Fatalf("error type = %T, want *ReferenceResolutionError", err)
				}
				if refErr.Code != wantCode {
					t.Fatalf("code = %q, want %q", refErr.Code, wantCode)
				}
				return
			}
			if err != nil {
				t.Fatalf("ResolveReferences rejected a schema-valid fixture: %v", err)
			}
			for name, g := range graphs {
				order, err := g.TopologicalOrder()
				if err != nil {
					t.Fatalf("model %q: TopologicalOrder: %v", name, err)
				}
				if len(order) != g.Len() {
					t.Fatalf("model %q: topological order covers %d of %d vertices",
						name, len(order), g.Len())
				}
			}
		})
	}

	for rel := range referenceCorpusRejections {
		if !seenRejections[rel] {
			t.Errorf("pinned rejection %q was never exercised; the fixture may have moved or been removed", rel)
		}
	}
}

// TestReferenceGraphJoinFactors pins the third edge kind: an aggregate `join.on`
// reference resolving to a factor in the node's scope — its string args, its
// declared range keys, or its symbolic output_idx — and the refusal when it
// resolves to none of them.
func TestReferenceGraphJoinFactors(t *testing.T) {
	model := map[string]any{
		"equations": []any{
			map[string]any{
				"lhs": "y",
				"rhs": map[string]any{
					"op":         "aggregate",
					"id":         "joined",
					"args":       []any{"src"},
					"output_idx": []any{"cell"},
					"ranges":     map[string]any{"i": map[string]any{"from": "cells"}},
					"join": []any{
						map[string]any{"on": []any{[]any{"src", "tgt"}}},
						map[string]any{"on": []any{[]any{"i", "j"}}},
						map[string]any{"on": []any{[]any{"cell", "k"}}},
					},
				},
			},
		},
	}
	indexSets := map[string]any{"cells": map[string]any{"kind": "interval", "size": 4}}

	g, err := BuildReferenceGraph(model, "M", indexSets)
	if err != nil {
		t.Fatalf("BuildReferenceGraph: %v", err)
	}
	got := edgeStrings(g.EdgesOfKind(EdgeKindJoinFactor))
	want := []string{
		"node:joined -> factor:cell", // symbolic output_idx
		"node:joined -> factor:i",    // declared range key
		"node:joined -> factor:src",  // string factor-arg
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("join_factor edges = %v, want %v", got, want)
	}
	for _, key := range []string{"factor:src", "factor:i", "factor:cell"} {
		v, ok := g.Vertex(key)
		if !ok || v.Kind != VertexKindFactor {
			t.Fatalf("missing factor vertex %s", key)
		}
	}

	// A factor naming nothing in scope is refused.
	bad := map[string]any{
		"equations": []any{
			map[string]any{
				"lhs": "y",
				"rhs": map[string]any{
					"op":         "aggregate",
					"args":       []any{},
					"output_idx": []any{},
					"join":       []any{map[string]any{"on": []any{[]any{"nowhere", "x"}}}},
				},
			},
		},
	}
	_, err = BuildReferenceGraph(bad, "M", nil)
	var refErr *ReferenceResolutionError
	if err == nil || !asReferenceError(err, &refErr) || refErr.Code != CodeRefUnresolvedJoinFactor {
		t.Fatalf("want E_REF_UNRESOLVED_JOIN_FACTOR, got %v", err)
	}
}

// TestReferenceGraphDuplicateNodeID pins the addressing invariant: an explicit
// `id` must be unique within a model, or nothing can be addressed by it.
func TestReferenceGraphDuplicateNodeID(t *testing.T) {
	agg := func() map[string]any {
		return map[string]any{"op": "aggregate", "id": "dup", "args": []any{}, "output_idx": []any{}}
	}
	model := map[string]any{
		"equations": []any{
			map[string]any{"lhs": "a", "rhs": agg()},
			map[string]any{"lhs": "b", "rhs": agg()},
		},
	}
	_, err := BuildReferenceGraph(model, "M", nil)
	var refErr *ReferenceResolutionError
	if err == nil || !asReferenceError(err, &refErr) || refErr.Code != CodeRefDuplicateNodeID {
		t.Fatalf("want E_REF_DUPLICATE_NODE_ID, got %v", err)
	}
	if !strings.Contains(refErr.Message, "dup") {
		t.Fatalf("message does not name the duplicated id: %s", refErr.Message)
	}
}

// TestReferenceGraphUnknownFAQNode pins the from_faq resolution failure: a
// derived index set whose producer node id does not exist.
func TestReferenceGraphUnknownFAQNode(t *testing.T) {
	model := map[string]any{
		"equations": []any{map[string]any{"lhs": "a", "rhs": float64(1)}},
	}
	indexSets := map[string]any{
		"edges": map[string]any{"kind": "derived", "from_faq": "missing_producer"},
	}
	_, err := BuildReferenceGraph(model, "M", indexSets)
	var refErr *ReferenceResolutionError
	if err == nil || !asReferenceError(err, &refErr) || refErr.Code != CodeRefUnknownFAQNode {
		t.Fatalf("want E_REF_UNKNOWN_FAQ_NODE, got %v", err)
	}
}

// TestReferenceGraphCycle pins RFC §6.1 "Acyclicity": a derived index set whose
// producer iterates that same set is an out-of-scope implicit solve.
// BuildReferenceGraph reports it lazily (TopologicalOrder), ResolveReferences
// eagerly.
func TestReferenceGraphCycle(t *testing.T) {
	model := map[string]any{
		"equations": []any{
			map[string]any{
				"lhs": "a",
				"rhs": map[string]any{
					"op":         "aggregate",
					"id":         "self",
					"args":       []any{},
					"output_idx": []any{},
					"ranges":     map[string]any{"e": map[string]any{"from": "edges"}},
				},
			},
		},
	}
	indexSets := map[string]any{
		"edges": map[string]any{"kind": "derived", "from_faq": "self"},
	}

	g, err := BuildReferenceGraph(model, "M", indexSets)
	if err != nil {
		t.Fatalf("BuildReferenceGraph must not report the cycle eagerly: %v", err)
	}
	cyc := g.DetectCycle()
	if cyc == nil {
		t.Fatal("DetectCycle found no cycle in a self-referential derived index set")
	}
	if cyc[0] != cyc[len(cyc)-1] {
		t.Fatalf("cycle path %v does not close on itself", cyc)
	}
	if _, err := g.TopologicalOrder(); err == nil {
		t.Fatal("TopologicalOrder succeeded on a cyclic graph")
	} else {
		var refErr *ReferenceResolutionError
		if !asReferenceError(err, &refErr) || refErr.Code != CodeRefCycle {
			t.Fatalf("want E_REF_CYCLE, got %v", err)
		}
		if len(refErr.Cycle) == 0 {
			t.Fatal("E_REF_CYCLE carries no cycle path")
		}
	}

	doc := map[string]any{"index_sets": indexSets, "models": map[string]any{"M": model}}
	if _, err := ResolveReferences(doc); err == nil {
		t.Fatal("ResolveReferences must reject a cyclic model eagerly")
	}
}

// TestReferenceGraphTypedConveniences checks that the typed entry points agree
// with the raw ones — the structural addresses they mint must be identical,
// which is the whole point of routing both through the raw JSON view.
func TestReferenceGraphTypedConveniences(t *testing.T) {
	path := filepath.Join(repoTestsDir(t), "valid", "aggregate", "node_addressing_from_faq.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	typed, err := ResolveReferencesInFile(file)
	if err != nil {
		t.Fatalf("ResolveReferencesInFile: %v", err)
	}
	raw, err := ResolveReferences(readRawDocument(t, path))
	if err != nil {
		t.Fatalf("ResolveReferences: %v", err)
	}
	if len(typed) != len(raw) {
		t.Fatalf("typed produced %d graphs, raw produced %d", len(typed), len(raw))
	}
	for name, rawGraph := range raw {
		typedGraph, ok := typed[name]
		if !ok {
			t.Fatalf("typed pass produced no graph for %q", name)
		}
		gotKeys := append([]string(nil), typedGraph.VertexKeys()...)
		wantKeys := append([]string(nil), rawGraph.VertexKeys()...)
		sort.Strings(gotKeys)
		sort.Strings(wantKeys)
		if strings.Join(gotKeys, "|") != strings.Join(wantKeys, "|") {
			t.Fatalf("model %q vertices: typed %v, raw %v", name, gotKeys, wantKeys)
		}
		if strings.Join(edgeStrings(typedGraph.Edges), "|") != strings.Join(edgeStrings(rawGraph.Edges), "|") {
			t.Fatalf("model %q edges: typed %v, raw %v", name,
				edgeStrings(typedGraph.Edges), edgeStrings(rawGraph.Edges))
		}
	}

	// The single-model typed entry point agrees too.
	model := file.Models["NodeAddressingDemo"]
	single, err := BuildReferenceGraphFromModel(&model, "NodeAddressingDemo", file.IndexSets)
	if err != nil {
		t.Fatalf("BuildReferenceGraphFromModel: %v", err)
	}
	if strings.Join(edgeStrings(single.Edges), "|") !=
		strings.Join(edgeStrings(raw["NodeAddressingDemo"].Edges), "|") {
		t.Fatalf("BuildReferenceGraphFromModel edges = %v", edgeStrings(single.Edges))
	}
}

// TestResolveReferencesOnDocumentWithoutModels: a document using none of these
// features yields an empty-but-valid result rather than an error.
func TestResolveReferencesOnDocumentWithoutModels(t *testing.T) {
	graphs, err := ResolveReferences(map[string]any{"esm": "1.0.0"})
	if err != nil {
		t.Fatalf("ResolveReferences: %v", err)
	}
	if len(graphs) != 0 {
		t.Fatalf("got %d graphs, want 0", len(graphs))
	}
	if graphs, err := ResolveReferencesInFile(nil); err != nil || len(graphs) != 0 {
		t.Fatalf("ResolveReferencesInFile(nil) = %v, %v", graphs, err)
	}
}

func asReferenceError(err error, out **ReferenceResolutionError) bool {
	re, ok := err.(*ReferenceResolutionError)
	if ok {
		*out = re
	}
	return ok
}

// --- from_faq resolves at DOCUMENT scope (esm-spec.md §9.7.5) ---------------
//
// `index_sets` is a document-scoped registry, so a `kind:"derived"` entry is
// visible to every model and its producing node may live in ANY of them. Every
// binding used to resolve `from_faq` against one model's expression nodes,
// which made the cross-model shape unresolvable even though the node plainly
// existed. The consequence: node ids are unique per DOCUMENT, not per model.

// TestFromFAQResolvesProducerInAnotherModel is the ruling in its minimal form.
func TestFromFAQResolvesProducerInAnotherModel(t *testing.T) {
	doc := map[string]any{
		"index_sets": map[string]any{
			"faces": map[string]any{"kind": "interval", "size": float64(8)},
			"edges": map[string]any{"kind": "derived", "from_faq": "edge_faq"},
		},
		"models": map[string]any{
			"Consumer": map[string]any{"equations": []any{map[string]any{
				"lhs": "c",
				"rhs": map[string]any{
					"op": "aggregate", "args": []any{}, "output_idx": []any{},
					"ranges": map[string]any{"e": map[string]any{"from": "edges"}},
				},
			}}},
			"Producer": map[string]any{"equations": []any{map[string]any{
				"lhs": "p",
				"rhs": map[string]any{
					"op": "aggregate", "args": []any{}, "id": "edge_faq",
					"output_idx": []any{"edge"},
					"ranges":     map[string]any{"f": map[string]any{"from": "faces"}},
				},
			}}},
		},
	}
	graphs, err := ResolveReferences(doc)
	if err != nil {
		t.Fatalf("ResolveReferences: %v", err)
	}
	// BOTH graphs carry the edge: the registry entry is document-scoped, so
	// every model sees the same derived set and the same producer.
	for _, name := range []string{"Consumer", "Producer"} {
		faq := graphs[name].EdgesOfKind(EdgeKindFromFAQ)
		if len(faq) != 1 {
			t.Fatalf("%s: from_faq edges = %d, want 1", name, len(faq))
		}
		if faq[0].Source != indexSetKey("edges") || faq[0].Target != nodeKey("edge_faq") {
			t.Fatalf("%s: edge = %s -> %s", name, faq[0].Source, faq[0].Target)
		}
	}
	// The consumer's graph gained a real vertex for the foreign producer, so
	// the partition pass can walk index_set -> node across the model boundary.
	v, ok := graphs["Consumer"].Vertex(nodeKey("edge_faq"))
	if !ok {
		t.Fatal("consumer graph has no vertex for the foreign producer")
	}
	if v.NodeID != "edge_faq" || v.Path != "models/Producer/equations/0/rhs" {
		t.Fatalf("foreign vertex = %+v", v)
	}
}

// TestFromFAQUnknownAcrossDocumentStillErrors: widening the scope to the
// document does not weaken the error — a name no node carries still fails.
func TestFromFAQUnknownAcrossDocumentStillErrors(t *testing.T) {
	agg := func(id string) map[string]any {
		return map[string]any{"op": "aggregate", "id": id, "args": []any{}, "output_idx": []any{}}
	}
	doc := map[string]any{
		"index_sets": map[string]any{
			"edges": map[string]any{"kind": "derived", "from_faq": "nowhere"},
		},
		"models": map[string]any{
			"A": map[string]any{"equations": []any{map[string]any{"lhs": "a", "rhs": agg("here")}}},
			"B": map[string]any{"equations": []any{map[string]any{"lhs": "b", "rhs": agg("there")}}},
		},
	}
	_, err := ResolveReferences(doc)
	var refErr *ReferenceResolutionError
	if err == nil || !asReferenceError(err, &refErr) || refErr.Code != CodeRefUnknownFAQNode {
		t.Fatalf("want E_REF_UNKNOWN_FAQ_NODE, got %v", err)
	}
}

// TestDuplicateNodeIDAcrossModels: legal before the §9.7.5 ruling, a load-time
// error now — one document-wide id namespace cannot hold two.
func TestDuplicateNodeIDAcrossModels(t *testing.T) {
	agg := func() map[string]any {
		return map[string]any{"op": "aggregate", "id": "dup", "args": []any{}, "output_idx": []any{}}
	}
	doc := map[string]any{
		"models": map[string]any{
			"A": map[string]any{"equations": []any{map[string]any{"lhs": "a", "rhs": agg()}}},
			"B": map[string]any{"equations": []any{map[string]any{"lhs": "b", "rhs": agg()}}},
		},
	}
	_, err := ResolveReferences(doc)
	var refErr *ReferenceResolutionError
	if err == nil || !asReferenceError(err, &refErr) || refErr.Code != CodeRefDuplicateNodeID {
		t.Fatalf("want E_REF_DUPLICATE_NODE_ID, got %v", err)
	}
	// Model-qualified on both sides, so the cross-model clash is visible.
	if !strings.Contains(refErr.Message, "models/A/") || !strings.Contains(refErr.Message, "models/B/") {
		t.Fatalf("message does not name both models: %s", refErr.Message)
	}
}

// TestCrossModelFromFAQCorpusFixture drives the shared cross-binding fixture.
func TestCrossModelFromFAQCorpusFixture(t *testing.T) {
	doc := readRawDocument(t, filepath.Join(
		repoTestsDir(t), "valid", "aggregate", "cross_model_from_faq.esm"))
	graphs, err := ResolveReferences(doc)
	if err != nil {
		t.Fatalf("ResolveReferences: %v", err)
	}
	if len(graphs) != 2 {
		t.Fatalf("graphs = %d, want 2", len(graphs))
	}
	faq := graphs["FluxConsumer"].EdgesOfKind(EdgeKindFromFAQ)
	if len(faq) != 1 || faq[0].Source != indexSetKey("edges") || faq[0].Target != nodeKey("edge_enum") {
		t.Fatalf("FluxConsumer from_faq edges = %+v", faq)
	}
}

// TestWildfireFixtureNoLongerUnknownFAQNode: CORPUS_DEFECTS #2 is fixed; what
// remains on that fixture is #3. `rg_candidate_pairs.from_faq` names
// `rg_candidate_set`, which lives in OceanDynamics while the registry entry is
// document-scoped — that resolves now. The producing node's
// `join.on == [["rg_src_bin","rg_tgt_bin"]]` names model variables rather than
// node-local binders, which is defect #3's shape, previously masked.
func TestWildfireFixtureNoLongerUnknownFAQNode(t *testing.T) {
	doc := readRawDocument(t, filepath.Join(
		repoTestsDir(t), "valid", "wildfire_atmosphere_ocean.esm"))
	_, err := ResolveReferences(doc)
	var refErr *ReferenceResolutionError
	if err == nil || !asReferenceError(err, &refErr) {
		t.Fatalf("want a *ReferenceResolutionError, got %v", err)
	}
	if refErr.Code != CodeRefUnresolvedJoinFactor {
		t.Fatalf("code = %q, want the defect-#3 join error", refErr.Code)
	}
	if !strings.Contains(refErr.Message, "rg_src_bin") {
		t.Fatalf("message does not name the unresolved factor: %s", refErr.Message)
	}
}
