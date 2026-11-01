---
title: "parameter_sweep"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `ParameterSweep` | `ParameterSweep` |


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
pub struct ParameterSweep {
    pub sweep_type: String,
    pub dimensions: Vec<SweepDimension>,
}
```

A parameter-sweep specification on a [`ModelAnalysis`](/generated/api/extension/rust#x-modelanalysis) (schema
`ParameterSweep`). Only Cartesian-product sweeps exist: the run count is
the product of the dimensions' lengths.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/analysis.rs#L235) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.ParameterSweep.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type ParameterSweep struct {
	Type       string           `json:"type"` // "cartesian"
	Dimensions []SweepDimension `json:"dimensions"`
}
```

ParameterSweep is a parameter sweep specification (currently only cartesian).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L688) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ParameterSweep)

</div>

</div>
