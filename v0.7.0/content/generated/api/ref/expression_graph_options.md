---
title: "expression_graph_options"
description: "Stable type · Graphs"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Graphs](/generated/api/topics/graphs)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `ExpressionGraphOptions` | `ExpressionGraphOptions` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this type.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct ExpressionGraphOptions {
    pub merge_coupled: bool,
}
```

Settings for [`expression_graph_with_options`](/generated/api/extension/rust#x-expression_graph_with_options).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/graph.rs#L503) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ExpressionGraphOptions.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ExpressionGraphOptions struct {
	// MergeCoupled folds every `variable_map` coupling entry into a
	// cross-system dependency edge (esm-libraries-spec §4.8.2, "coupled
	// file-level graph"), adding either endpoint as a parameter node if the
	// component that owns it did not declare it.
	MergeCoupled bool
}
```

ExpressionGraphOptions tunes ExpressionGraphFromFileWithOptions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/graph.go#L315) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ExpressionGraphOptions)

</div>

</div>
