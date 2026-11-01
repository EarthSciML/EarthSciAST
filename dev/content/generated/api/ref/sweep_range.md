---
title: "sweep_range"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `SweepRange` | `SweepRange` |


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
pub struct SweepRange {
    pub start: f64,
    pub stop: f64,
    pub count: i64,
    pub scale: Option<String>,
}
```

Generated range of values for one [`SweepDimension`](/generated/api/ref/sweep_dimension) (schema `SweepRange`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/analysis.rs#L198) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SweepRange.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type SweepRange struct {
	Start float64 `json:"start"`
	Stop  float64 `json:"stop"`
	Count int     `json:"count"`
	Scale *string `json:"scale,omitempty"` // "linear" | "log"
}
```

SweepRange is a generated range of parameter values.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L672) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SweepRange)

</div>

</div>
