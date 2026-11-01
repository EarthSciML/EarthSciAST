---
title: "build_reference_graph"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `build_reference_graph` | `buildReferenceGraph` | `build_reference_graph` | `build_reference_graph`, `build_reference_graph_with_index_sets` | `BuildReferenceGraph` |


**Note:** spelling differs from the §2 rule: rust=build_reference_graph_with_index_sets (expected build_reference_graph); multiple spellings exported by: rust


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
build_reference_graph(model::AbstractDict)
build_reference_graph(model::AbstractDict, model_name::AbstractString)
build_reference_graph(model::AbstractDict, model_name::AbstractString, index_sets::Union{Nothing, AbstractDict})
```

```julia
build_reference_graph(model::AbstractDict, model_name="", index_sets=nothing)
    -> ReferenceGraph
```

Resolve the reference edges of one `model` dict into a graph. Throws a
[`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) on a duplicate node id, an undeclared
`ranges[*].from` index set, a `from_faq` naming no node, or an unresolved
`join.on` factor. (Cycles are reported lazily by `topological_order`, or
eagerly by [`resolve_references`](/generated/api/ref/resolve_references).)

`index_sets` is the **document-scoped** index-set registry (RFC §5.2). Since
v0.8.0 that registry is a sibling of `models` at the top level of the document,
not a key on each model, and in esm 1.0.0 it is the only place it may appear
(`esm-schema.json` declares `index_sets` at `/properties/index_sets` and
nowhere else). [`resolve_references`](/generated/api/ref/resolve_references) threads the document's registry in
for every model; a caller holding only a raw model dict may pass it explicitly,
or omit it and get the pre-0.8.0 model-nested `index_sets` key as a fallback.

Until API_SPEC.md §8 item 17 this method read ONLY `model["index_sets"]` and
took no registry argument, so on any v0.8.0+ document every `ranges[*].from`
target was undeclared and the pass raised `undeclared_index_set` where Python,
Rust and Go all built the graph. The optional trailing argument is the shape
Python (`index_sets=`) and Go (`docIndexSets`) already use; Rust spells it as
the separate `build_reference_graph_with_index_sets`.

`from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5). A caller holding one
model gets that model as its own document, which is the right answer for a
one-model document; [`resolve_references`](/generated/api/ref/resolve_references) is the document-scoped entry
point and resolves against every model's nodes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/reference_graph.jl#L609)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function buildReferenceGraph(model: Model | RawObject, modelName?: string, indexSets?: Record<string, unknown>): ReferenceGraph
```

Resolve the reference edges of ONE `model` into a [`ReferenceGraph`](/generated/api/ref/reference_graph).

**Parameters**

- `model` — the raw model object (as parsed, not the typed layer)
- `modelName` — the model's key in the document, used in diagnostics
- `indexSets` — the DOCUMENT-SCOPED `index_sets` registry. `esm-schema.json`
    declares `index_sets` only at document scope, as a sibling of `models`.
    [`resolveReferences`](/generated/api/ref/resolve_references) reads it once from the document root and threads
    it into every model, which is how a caller normally arrives here. It is an
    OPTIONAL TRAILING argument — not a separate function, and not required
    (API_SPEC.md §8 item 17). A model-nested `index_sets` key (a pre-0.8.0
    document) is merged ON TOP, so a model-level entry wins a key collision,
    matching Go and Rust exactly.
  
  Throws [`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) on a duplicate node id, an undeclared
  `ranges[*].from` index set, a `from_faq` naming no node, or an unresolved
  `join.on` factor. Cycles are reported lazily by
  `ReferenceGraph.topologicalOrder`, or eagerly by
  [`resolveReferences`](/generated/api/ref/resolve_references).
  
  `from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5). A caller holding
  one model gets that model as its own document, which is the right answer for
  a one-model document; [`resolveReferences`](/generated/api/ref/resolve_references) is the document-scoped entry
  point and resolves against every model's nodes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/reference-resolution.ts#L303)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
build_reference_graph(model: dict, model_name: str = '', index_sets: dict | None = None) -> ReferenceGraph
```

Resolve the reference edges of one `model` dict into a graph.

`index_sets` is the document-scoped index-set registry (RFC §5.2), which
lives at the top level of the document rather than on each model.
[`resolve_references`](/generated/api/ref/resolve_references) threads the document registry in for every
model. Any model-nested `index_sets` key is **merged** on top
of it — a model-level entry wins a key collision — matching Julia,
TypeScript, Rust and Go.

Raises [`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) on a duplicate node id, an
undeclared `ranges[*].from` index set, a `from_faq` naming no node, or
an unresolved `join.on` factor. (Cycles are reported lazily by
`ReferenceGraph.topological_order`, or eagerly by
[`resolve_references`](/generated/api/ref/resolve_references).)

`from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5). A caller
holding only one model gets that model as its own document, which is the
right answer for a one-model document; [`resolve_references`](/generated/api/ref/resolve_references) is the
document-scoped entry point and resolves against every model's nodes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L337)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

Exported as `build_reference_graph` and `build_reference_graph_with_index_sets`. Both names refer to the same operation.

**`build_reference_graph`**

```rust
pub fn build_reference_graph(model: &Value, model_name: &str, doc_index_sets: Option<&Map<String, Value>>) -> Result<ReferenceGraph, ReferenceResolutionError>
```

Resolve the reference edges of one `model` value into a graph, against the
**document-scoped** `index_sets` registry.

One name, with the registry as an optional TRAILING argument (API_SPEC.md
§8 item 17) — the shape Python (`index_sets=None`) and Go (`docIndexSets`)
already have. Pass `None` for a direct caller holding only a raw model;
[`resolve_references`](/generated/api/ref/resolve_references), which is the DOCUMENT-scoped entry point, derives
the registry from the document itself and threads it in for every model.

The `index_sets` registry is a sibling of `models`, shared by every model
(as in `crate::cadence::model_with_loaders`). An `index_sets` nested
inside the model itself is merged on top, and a model-level entry wins on
a key collision.

Errors on a duplicate node id, an undeclared `ranges[*].from` index set, a
`from_faq` naming no node, or an unresolved `join.on` factor. Cycles are
reported lazily by `ReferenceGraph::topological_order`, or eagerly by
[`resolve_references`](/generated/api/ref/resolve_references).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/reference_resolution.rs#L720) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.build_reference_graph.html)

**`build_reference_graph_with_index_sets`**

```rust
pub fn build_reference_graph_with_index_sets(model: &Value, model_name: &str, doc_index_sets: Option<&Map<String, Value>>) -> Result<ReferenceGraph, ReferenceResolutionError>
```

**Deprecated** since 0.2.0: the registry is now the trailing argument of `build_reference_graph` (API_SPEC.md §8 item 17)

Deprecated alias of [`build_reference_graph`](/generated/api/ref/build_reference_graph).

API_SPEC.md §8 item 17: the explicit index-set registry is an optional
TRAILING argument of `build_reference_graph`, not a separate name. This
alias is deprecated and will be removed at the next major (API_SPEC.md
§10).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/reference_resolution.rs#L694) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.build_reference_graph_with_index_sets.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func BuildReferenceGraph(model map[string]any, modelName string, docIndexSets map[string]any) (*ReferenceGraph, error)
```

BuildReferenceGraph resolves the reference edges of one raw `model` view into a graph.

`docIndexSets` is the DOCUMENT-SCOPED index-set registry (RFC §5.2), which as of v0.8.0 lives at the top level of the document rather than on each model; ResolveReferences threads the document registry in for every model. Any model-nested `index_sets` key is MERGED on top of it — a model-level entry wins a key collision — so a pre-0.8.0 nested shape still resolves. Pass nil for `docIndexSets` to rely on the model-nested key alone.

Returns a \*ReferenceResolutionError on a duplicate node id, an undeclared `ranges[*].from` index set, a `from_faq` naming no node, or an unresolved `join.on` factor. Cycles are reported lazily by ReferenceGraph.TopologicalOrder, or eagerly by ResolveReferences.

`from_faq` resolves at DOCUMENT scope (esm-spec.md §9.7.5). A caller holding one model gets that model as its own document, which is the right answer for a one-model document; ResolveReferences is the document-scoped entry point and resolves against every model's nodes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L727) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#BuildReferenceGraph)

</div>

</div>
