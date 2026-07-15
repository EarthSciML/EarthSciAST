package esm

// Regression tests for the nested-template exponential blow-up (esm-spec
// §9.7.3 registration-time body composition + §9.6.3 fixpoint expansion).
//
// A chain of match-less templates T0..Tn where each T_i body references
// T_{i-1} TWICE denotes a tree with 2^n copies of the T0 leaf. Deep-copy
// substitution materializes all 2^n copies (exponential time and memory);
// structural sharing represents the same expansion as a DAG with O(n) unique
// nodes. The expansion SEMANTICS (and serialized bytes) are unchanged — only
// the in-memory representation is shared.

import (
	"encoding/json"
	"fmt"
	"reflect"
	"runtime"
	"testing"
	"time"
)

// applyNode builds an `apply_expression_template` call-site node.
func applyNode(name string) map[string]any {
	return map[string]any{
		"op":       applyExpressionTemplateOp,
		"args":     []any{},
		"name":     name,
		"bindings": map[string]any{},
	}
}

// buildNestedTemplateDoc builds an in-memory view of an esm 0.4.0 document
// with a chain of match-less zero-param templates T0..T<depth> where each
// T_i (i>0) body references T_{i-1} twice, and one call site apply(T<depth>).
func buildNestedTemplateDoc(depth int) map[string]any {
	leaf := map[string]any{
		"op": "*",
		"args": []any{
			1.8e-12,
			map[string]any{"op": "exp", "args": []any{
				map[string]any{"op": "/", "args": []any{
					map[string]any{"op": "-", "args": []any{1500.0}},
					"T",
				}},
			}},
		},
	}
	templates := map[string]any{
		"T0": map[string]any{"params": []any{}, "body": leaf},
	}
	for i := 1; i <= depth; i++ {
		templates[fmt.Sprintf("T%d", i)] = map[string]any{
			"params": []any{},
			"body": map[string]any{
				"op":   "+",
				"args": []any{applyNode(fmt.Sprintf("T%d", i-1)), applyNode(fmt.Sprintf("T%d", i-1))},
			},
		}
	}
	return map[string]any{
		"esm":      "0.4.0",
		"metadata": map[string]any{"name": "nested_template_blowup", "authors": []any{"esm"}},
		"reaction_systems": map[string]any{
			"chem": map[string]any{
				"species":              map[string]any{"A": map[string]any{"default": 1.0}, "B": map[string]any{"default": 0.5}},
				"parameters":           map[string]any{"T": map[string]any{"default": 298.15}},
				"expression_templates": templates,
				"reactions": []any{
					map[string]any{
						"id":         "R1",
						"substrates": []any{map[string]any{"species": "A", "stoichiometry": 1}},
						"products":   []any{map[string]any{"species": "B", "stoichiometry": 1}},
						"rate":       applyNode(fmt.Sprintf("T%d", depth)),
					},
				},
			},
		},
	}
}

// dagStats counts, pointer-identity-memoized, the number of UNIQUE object/array
// nodes (physical DAG size) and the number of LOGICAL nodes (the size of the
// tree the DAG denotes, i.e. what a full deep walk would visit). Logical size
// is computed arithmetically over the memo so it never expands the DAG.
func dagStats(tree any) (unique int, logical uint64) {
	memo := map[uintptr]uint64{}
	var visit func(v any) uint64
	visit = func(v any) uint64 {
		switch t := v.(type) {
		case map[string]any:
			key := reflect.ValueOf(t).Pointer()
			if n, ok := memo[key]; ok {
				return n
			}
			memo[key] = 0 // acyclic input; placeholder
			var n uint64 = 1
			for _, c := range t {
				n += visit(c)
			}
			memo[key] = n
			unique++
			return n
		case []any:
			var n uint64 = 1
			for _, c := range t {
				n += visit(c)
			}
			unique++ // arrays are counted per occurrence-site parent map; cheap and monotone
			return n
		default:
			return 1
		}
	}
	logical = visit(tree)
	return unique, logical
}

// TestNestedTemplateChain_SharedDAG verifies the expansion of the doubling
// chain is fast and flat: physical (unique-node) size linear in depth, not
// 2^depth, while the logical expansion stays exactly the 2^depth tree the
// document denotes.
func TestNestedTemplateChain_SharedDAG(t *testing.T) {
	const depth = 14
	view := buildNestedTemplateDoc(depth)
	start := time.Now()
	if err := LowerExpressionTemplates(view); err != nil {
		t.Fatalf("LowerExpressionTemplates failed: %v", err)
	}
	elapsed := time.Since(start)

	rate := view["reaction_systems"].(map[string]any)["chem"].(map[string]any)["reactions"].([]any)[0].(map[string]any)["rate"]
	unique, logical := dagStats(rate)

	// Logical semantics: full binary tree of `+` nodes with 2^depth leaf copies.
	// Each leaf copy contributes 4 maps + 4 arg arrays + 3 scalars = 12 logical
	// nodes (map+args counted by dagStats as 1 each, scalars 1 each):
	// leaf logical size = 15; plus node logical = 2 + left + right + "+" scalar? —
	// rather than re-derive the closed form, just require the exponential floor.
	if logical < (1<<depth)*10 {
		t.Errorf("logical expansion size = %d; expected >= %d (2^%d leaf copies) — expansion semantics changed", logical, (1<<depth)*10, depth)
	}
	// Physical representation: shared DAG, linear in depth. Allow generous slack
	// (leaf ~10 unique nodes + ~5 per chain level).
	if unique > 40*(depth+1) {
		t.Errorf("physical DAG size = %d unique nodes for depth %d; expected O(depth) — expansion is materializing exponential copies", unique, depth)
	}
	if elapsed > 30*time.Second {
		t.Errorf("expansion took %v; expected well under 30s at depth %d", elapsed, depth)
	}
	t.Logf("depth=%d unique=%d logical=%d elapsed=%v", depth, unique, logical, elapsed)
}

// TestNestedTemplateChain_MeasureBlowup is a measurement harness (not an
// assertion) logging time / memory / DAG stats at a few depths. Run with -v.
func TestNestedTemplateChain_MeasureBlowup(t *testing.T) {
	for _, depth := range []int{10, 14, 16} {
		view := buildNestedTemplateDoc(depth)
		runtime.GC()
		var before runtime.MemStats
		runtime.ReadMemStats(&before)
		start := time.Now()
		err := LowerExpressionTemplates(view)
		elapsed := time.Since(start)
		var after runtime.MemStats
		runtime.ReadMemStats(&after)
		if err != nil {
			t.Fatalf("depth %d: %v", depth, err)
		}
		rate := view["reaction_systems"].(map[string]any)["chem"].(map[string]any)["reactions"].([]any)[0].(map[string]any)["rate"]
		unique, logical := dagStats(rate)
		t.Logf("depth=%2d elapsed=%12v heapAllocDelta=%8.1fMB totalAllocDelta=%8.1fMB unique=%8d logical=%12d",
			depth, elapsed,
			float64(after.HeapAlloc-before.HeapAlloc)/(1<<20),
			float64(after.TotalAlloc-before.TotalAlloc)/(1<<20),
			unique, logical)
	}
}

// TestNestedTemplateChain_LoadStringEndToEnd drives the doubling chain through
// the full public load pipeline (schema validation, §9.7 resolution, §9.6.3
// fixpoint, re-marshal, typed decode). The typed tree materializes the logical
// expansion (serialization is a tree, by design), so the depth is kept modest;
// the point is that the map-view expansion feeding it no longer blows up.
func TestNestedTemplateChain_LoadStringEndToEnd(t *testing.T) {
	const depth = 10
	raw, err := json.Marshal(buildNestedTemplateDoc(depth))
	if err != nil {
		t.Fatalf("marshal doc: %v", err)
	}
	file, err := LoadString(string(raw))
	if err != nil {
		t.Fatalf("LoadString failed: %v", err)
	}
	rate := file.ReactionSystems["chem"].Reactions[0].Rate
	node, ok := asExprNode(rate)
	if !ok || node.Op != "+" {
		t.Fatalf("expanded rate root = %#v; want op '+'", rate)
	}
}

// TestNestedTemplateChain_SerializedBytesUnchanged pins that structural sharing
// is representation-only: the canonical serialized expansion at a small depth is
// byte-identical to the fully materialized tree (marshal expands the DAG).
func TestNestedTemplateChain_SerializedBytesUnchanged(t *testing.T) {
	const depth = 4
	view := buildNestedTemplateDoc(depth)
	if err := LowerExpressionTemplates(view); err != nil {
		t.Fatalf("LowerExpressionTemplates failed: %v", err)
	}
	got, err := json.Marshal(view["reaction_systems"].(map[string]any)["chem"].(map[string]any)["reactions"].([]any)[0].(map[string]any)["rate"])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Reference expansion computed independently: a full binary tree of `+`
	// over the T0 leaf.
	leafJSON := `{"args":[1.8e-12,{"args":[{"args":[{"args":[1500],"op":"-"},"T"],"op":"/"}],"op":"exp"}],"op":"*"}`
	want := leafJSON
	for i := 0; i < depth; i++ {
		want = fmt.Sprintf(`{"args":[%s,%s],"op":"+"}`, want, want)
	}
	if string(got) != want {
		t.Errorf("serialized expansion differs from the materialized reference at depth %d:\n got: %.200s...\nwant: %.200s...", depth, got, want)
	}
}
