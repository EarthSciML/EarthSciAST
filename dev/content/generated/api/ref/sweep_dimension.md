---
title: "sweep_dimension"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `SweepDimension` | `SweepDimension` |


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
pub struct SweepDimension {
    pub parameter: String,
    pub values: Option<Vec<f64>>,
    pub range: Option<SweepRange>,
}
```

One axis of a [`ParameterSweep`](/generated/api/ref/parameter_sweep) (schema `SweepDimension`): exactly one of
`values` / `range` is present.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/analysis.rs#L217) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SweepDimension.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type SweepDimension struct {
	Parameter string      `json:"parameter"`
	Values    []float64   `json:"values,omitempty"`
	Range     *SweepRange `json:"range,omitempty"`
}
```

SweepDimension is one axis of a parameter sweep; exactly one of Values or Range is set.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L681) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SweepDimension)

</div>

</div>
