---
title: "function_table_axis"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `FunctionTableAxis` | not exported | `FunctionTableAxis` | not exported | `FunctionTableAxis` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct FunctionTableAxis
FunctionTableAxis(name::AbstractString, values::AbstractVector; units)
```

```julia
FunctionTableAxis
```

A single named axis inside a [`FunctionTable`](/generated/api/ref/function_table) (esm-spec §9.5).
`values` MUST be strictly-increasing finite floats with at least 2 entries
(mirrors the §9.2 interp.linear / interp.bilinear axis contract). `units`
is advisory only in v0.4.0.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L2327)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FunctionTableAxis
FunctionTableAxis(name: str, values: list[float], units: str | None = None)
```

A single named axis inside a FunctionTable (esm-spec §9.5).

`values` MUST be strictly-increasing finite floats with at least 2
entries (mirrors the §9.2 interp.linear / interp.bilinear axis contract).
`units` is advisory only in v0.4.0 — recorded for documentation, not
used for load-time unit-checking.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1294)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FunctionTableAxis struct {
	Name   string    `json:"name"`
	Units  *string   `json:"units,omitempty"`
	Values []float64 `json:"values"`
}
```

FunctionTableAxis is a single named axis inside a FunctionTable. `Values` MUST be strictly-increasing finite floats with at least 2 entries (mirrors the §9.2 interp.linear / interp.bilinear axis contract).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L1392) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FunctionTableAxis)

</div>

</div>
