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

## Open questions the corpus records rather than settles

Three points where the oracle's answer is pinned but is NOT clearly the right
one. Each is a decision for a human, not a bug to fix quietly.

**1. An INDEXED-LHS unknown: `observed` or `algebraic`?** In
`wildfire_atmosphere_ocean`, `rg_pairs`, `rg_src_bin` and `rg_tgt_bin` are
defined by an indexed LHS (`rg_src_bin[a] ~ …`). esm-spec §6.3.1 defines an
observed unknown as one with a "bare-variable LHS", so TypeScript and Go call
these `algebraic` — and the corpus carries that. Python, Rust and Julia call them
`observed`, because their `observed_definitions` deliberately credits the arrayed
form (an arrayed observed's cadence must resolve through its RHS). So the SPEC
favours the oracle 2-of-5 while the MAJORITY is against it 3-of-5. Narrowing the
classifier in those three would also move `algebraic_unknowns`, which their
codegen and value-invention passes consume as the solved-unknowns set, so this
reaches well past §4.8. Python and Julia mark exactly this fixture's
expression-graph cases as a named expected failure rather than bend either way.

**2. Are an `aggregate`'s BOUND index variables graph nodes?** The corpus carries
nodes named `a`, `o` and `v` for the same document — the bound range indices of
its reductions. TypeScript, Python, Go and Rust all reach them: the collector
their graph uses walks every child and does not subtract an aggregate's own
range indices. Julia's `free_variables` does subtract them, so Julia alone omits
these three nodes. A bound index is not a model variable, so four-of-five
agreeing does not make it obviously right — but the collector is shared with
other passes in each of those four, so this is a decision rather than a local
fix.

**3. A reaction system's `var_count`.** The oracle writes 0; Julia and Python
used to write `len(parameters)`; Go and Rust report no variable count for a
reaction system at all. §4.8.1 asks only for "summary metadata" and settles
nothing. This is the one corpus field pinned purely to keep consumers agreeing.

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
