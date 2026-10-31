---
title: "resolve_references"
description: "Stable function · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `resolve_references` | `resolveReferences` | `resolve_references` | `resolve_references` | `ResolveReferences` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
resolve_references(document::AbstractDict)
```

```julia
resolve_references(document::AbstractDict) -> OrderedDict{String,ReferenceGraph}
```

Resolve reference edges for every model in `document`. Throws a
[`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) on any unresolved reference *or* reference
cycle (each model's graph is checked acyclic eagerly here).

The document's top-level `index_sets` registry is threaded into every model's
[`build_reference_graph`](/generated/api/ref/build_reference_graph) call — that is where esm 1.0.0 puts it.

Node ids are collected from EVERY model first, so a derived index set's
`from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a duplicate
id anywhere in the document is an error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/reference_graph.jl#L725)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function resolveReferences(document: EsmFile | RawObject): Map<string, ReferenceGraph>
```

Resolve reference edges for EVERY model in `document`.

Returns a `modelName -> ReferenceGraph` map. Throws
[`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) on any unresolved reference *or* reference
cycle (each model's graph is checked acyclic eagerly here).

The document-scoped `index_sets` registry is read once from the top level and
threaded into every model, so a caller never assembles it by hand.

Node ids are collected from EVERY model first, so a derived index set's
`from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a
duplicate id anywhere in the document is an error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-ts/src/reference-resolution.ts#L626)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
resolve_references(document: dict) -> dict[str, ReferenceGraph]
```

Resolve reference edges for every model in `document`.

Returns a `{model_name: ReferenceGraph}` map. Raises
[`ReferenceResolutionError`](/generated/api/ref/reference_resolution_error) on any unresolved reference *or* reference
cycle (each model's graph is checked acyclic eagerly here).

Node ids are collected from **every** model first, so a derived index set's
`from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a
duplicate id anywhere in the document is an error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/reference_resolution.py#L586)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn resolve_references(document: &Value) -> Result<IndexMap<String, ReferenceGraph>, ReferenceResolutionError>
```

Resolve reference edges for every model in `document`.

Returns a `{model_name: ReferenceGraph}` map. Errors on any unresolved
reference *or* reference cycle (each model's graph is checked acyclic).

Node ids are collected from EVERY model first, so a derived index set's
`from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a
duplicate id anywhere in the document is an error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/reference_resolution.rs#L848) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_references.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ResolveReferences(document map[string]any) (map[string]*ReferenceGraph, error)
```

ResolveReferences resolves the reference edges of every model in a raw `document` view, returning a {model name: graph} map.

Returns a \*ReferenceResolutionError on any unresolved reference OR reference cycle — each model's graph is checked acyclic eagerly here, unlike BuildReferenceGraph, which leaves cycle detection to TopologicalOrder.

Node ids are collected from EVERY model first, so a derived index set's `from_faq` may name a producer in any model (esm-spec.md §9.7.5) and a duplicate id anywhere in the document is an error.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/reference_graph.go#L821) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ResolveReferences)

</div>

</div>
