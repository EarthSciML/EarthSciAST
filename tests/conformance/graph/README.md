# Graph conformance corpus

`cases.json` is **generated**. Regenerate it with:

```bash
cd pkg/earthsci-ast-ts && npm run build && cd ../..
node scripts/generate-graph-corpus.mjs
```

Never hand-edit it. The generator's header comment is the normative account of
what is pinned and why; this file is the short version for someone porting a
binding.

## What it pins

For nine whole documents from `tests/valid/` and seven sub-document
`expression_graph` targets:

| Section | Pinned |
|---|---|
| `component_graph.nodes` | `id`, `type`, `var_count`, `eq_count`, `species_count` |
| `component_graph.edges` | `from`, `to`, `type`, `label` |
| `component_graph.closure` | `adjacency` / `predecessors` / `successors` per node |
| `component_graph_json` | the JSON adjacency-list export's top-level keys, node ids, edge endpoints and adjacency map |
| `expression_graph.nodes` | `name`, `kind`, `units`, `system` |
| `expression_graph.edges` | `source`, `target`, `relationship`, `equation_index` |
| `expression_graph.closure` | the same three lookups |
| `expression_graph_merge_coupled` | the whole-file graph with `variable_map` folded into cross-system edges |
| `targets[].expression_graph` | the Model / ReactionSystem / Equation / Reaction / Expr overloads |

**Node and edge ORDER is not a conformance property.** Bindings iterate their
own maps. Compare as multisets.

## What it does NOT pin, and why

**The DOT and Mermaid bytes.** `esm-libraries-spec` §4.8.3 requires both
exports but specifies neither one's syntax, and the five bindings do not split
in a way any tie-break rule resolves:

| | component DOT header | Mermaid header |
|---|---|---|
| TypeScript | `digraph {` | `flowchart TD` |
| Python | `digraph ComponentGraph {` | `graph TD` |
| Go | `digraph ComponentGraph {` | `graph LR` |
| Rust | `digraph ComponentGraph {` | `graph LR` / `graph TD` |
| Julia | `digraph ComponentGraph {` | `graph TD` |

Four of five vote *against* the oracle on the DOT header, those four then
disagree with each other on Mermaid, and all five differ on every node and edge
line's shapes, colours and label text. Picking one would be choosing a house
style, not resolving a conformance question, so the corpus does not pretend to
have an answer. `component_graph_json` / `expression_graph_json` pin the third
export because §4.8.3 names it *by structure* ("JSON adjacency list"), which is
checkable without choosing a style.

**`ComponentNode.description` / `.reference`.** TypeScript derives `description`
from `reference.notes`; Python and Julia leave both null; Rust carries an
unrelated `name`. §4.8.1 asks for "summary metadata" and names neither field.

**`DependencyEdge.expression`.** §4.8.2 marks it optional, "for detail views",
and the bindings differ on whether a stoichiometric edge carries the rate
expression that produced it.

## Oracle

TypeScript (`pkg/earthsci-ast-ts`), on the grounds set out at the top of
`scripts/generate-graph-corpus.mjs`: the spec decides the substantive splits and
TypeScript is on its side of each; where the spec is silent, TypeScript and
Python — the two bindings carrying the 1.0.0 model — agree.

## Drivers

| Binding | Test |
|---|---|
| TypeScript | `pkg/earthsci-ast-ts/src/graph-conformance.test.ts` |
| Python | `pkg/earthsci-ast-py/tests/test_graph_conformance.py` |
| Go | `pkg/earthsci-ast-go/pkg/esm/graph_conformance_test.go` |
| Rust | `pkg/earthsci-ast-rs/tests/graph_conformance.rs` |
| Julia | `pkg/EarthSciAST.jl/test/graph_conformance_test.jl` |
