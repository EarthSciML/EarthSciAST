---
title: "data_source_determinism"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DataSourceDeterminism` | not exported | `DataSourceDeterminism` | `DataSourceDeterminism` | `DataSourceDeterminism` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DataSourceDeterminism
DataSourceDeterminism(; endian, float_format, integer_width)
```

```julia
DataSourceDeterminism
```

Reproducibility contract a source advertises to bindings (esm-spec §8.1).
A binding that cannot honor the declared endian / float_format / integer_width
MUST reject the file at load.

Fields (all optional):
- `endian`: "little" | "big"
- `float_format`: "ieee754_single" | "ieee754_double"
- `integer_width`: 32 | 64

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L2048)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DataSourceDeterminism
DataSourceDeterminism(endian: str | None = None, float_format: str | None = None, integer_width: int | None = None)
```

Reproducibility contract a source advertises to bindings (esm-spec §8.9.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L924)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DataSourceDeterminism {
    pub endian: Option<String>,
    pub float_format: Option<String>,
    pub integer_width: Option<u32>,
}
```

Reproducibility contract a loader advertises to bindings
(esm-spec §8.9.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/components.rs#L277) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DataSourceDeterminism.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DataSourceDeterminism struct {
	Endian       *string `json:"endian,omitempty"`        // "little" | "big"
	FloatFormat  *string `json:"float_format,omitempty"`  // "ieee754_single" | "ieee754_double"
	IntegerWidth *int    `json:"integer_width,omitempty"` // 32 | 64
}
```

DataSourceDeterminism is the reproducibility contract a source advertises to bindings (esm-spec 8.1). A binding that cannot honor the declared contract MUST reject the file at load.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L801) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSourceDeterminism)

</div>

</div>
