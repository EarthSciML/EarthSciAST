---
title: "function_table"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `FunctionTable` | not exported | `FunctionTable` | not exported | `FunctionTable` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct FunctionTable
FunctionTable(axes::AbstractVector{FunctionTableAxis}, data; description, interpolation, out_of_bounds, outputs, shape, schema_version)
```

```julia
FunctionTable
```

A sampled function table referenced by `table_lookup` AST op nodes
(esm-spec §9.5, v0.4.0). Tables are syntactic sugar over §9.2's
`interp.linear` / `interp.bilinear` / `index` — a `table_lookup` query
MUST be bit-equivalent to the equivalent inline-`const` lookup. Shape of
`data` is `[len(outputs), len(axes[0].values), len(axes[1].values), ...]`
when `outputs` is non-`nothing`; `[len(axes[0].values), ...]` otherwise.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L2346)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class FunctionTable
FunctionTable(axes: list[FunctionTableAxis], data: Any, description: str | None = None, interpolation: str | None = None, out_of_bounds: str | None = None, outputs: list[str] | None = None, shape: list[int] | None = None, schema_version: str | None = None)
```

A sampled function table referenced by table_lookup AST ops
(esm-spec §9.5, v0.4.0).

Tables are syntactic sugar over §9.2's interp.linear / interp.bilinear /
index — a table_lookup query MUST be bit-equivalent to the equivalent
inline-const lookup. The shape of `data` is
`[len(outputs), len(axes[0].values), len(axes[1].values), ...]` when
`outputs` is non-empty; `[len(axes[0].values), ...]` otherwise.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L1309)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

<p class="api-absent">Rust does not export this type.</p>

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type FunctionTable struct {
	Description   *string             `json:"description,omitempty"`
	Axes          []FunctionTableAxis `json:"axes"`
	Interpolation *string             `json:"interpolation,omitempty"`
	OutOfBounds   *string             `json:"out_of_bounds,omitempty"`
	Outputs       []string            `json:"outputs,omitempty"`
	Data          any                 `json:"data"`
	Shape         []int               `json:"shape,omitempty"`
	SchemaVersion *string             `json:"schema_version,omitempty"`
}
```

FunctionTable is a sampled function table (esm-spec §9.5). The shape of Data is \[len(Outputs), len(Axes\[0\].Values), len(Axes\[1\].Values), ...\] when Outputs is non-empty; \[len(Axes\[0\].Values), ...\] otherwise. Tables are syntactic sugar over interp.linear / interp.bilinear / index — a table\_lookup query MUST be bit-equivalent to the equivalent inline-const lookup.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L1404) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#FunctionTable)

</div>

</div>
