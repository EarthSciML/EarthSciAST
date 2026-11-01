---
title: "plot_axis"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `PlotAxis` | `PlotAxis` |


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
pub struct PlotAxis {
    pub variable: String,
    pub label: Option<String>,
}
```

Axis specification of an analysis [`Plot`](/generated/api/ref/plot) (schema `PlotAxis`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/analysis.rs#L247) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.PlotAxis.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type PlotAxis struct {
	Variable string  `json:"variable"`
	Label    *string `json:"label,omitempty"`
}
```

PlotAxis is an axis specification for a plot.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L641) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PlotAxis)

</div>

</div>
