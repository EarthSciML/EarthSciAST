---
title: "plot_value"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `PlotValue` | `PlotValue` |


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
pub struct PlotValue {
    pub variable: String,
    pub at_time: Option<f64>,
    pub reduce: Option<String>,
}
```

A scalar value derived from a trajectory, used for heatmap / color
channels (schema `PlotValue`). Exactly one of `at_time` / `reduce` should
be given.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/analysis.rs#L274) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.PlotValue.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type PlotValue struct {
	Variable string   `json:"variable"`
	AtTime   *float64 `json:"at_time,omitempty"`
	Reduce   *string  `json:"reduce,omitempty"`
}
```

PlotValue is a scalar value derived from a trajectory, used for heatmap color channels.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L648) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#PlotValue)

</div>

</div>
