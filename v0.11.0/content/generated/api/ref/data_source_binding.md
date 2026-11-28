---
title: "data_source_binding"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DataSourceBinding` | not exported | `DataSourceBinding` | `DataSourceBinding` | `DataSourceBinding` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DataSourceBinding
DataSourceBinding(file_variable::AbstractString; unit_conversion, codes, select, records_per_sample, description, reference)
```

```julia
DataSourceBinding
```

Binds a parameter to one file variable of a `data_sources` entry (esm-spec
§8.5) — the `from` value form of a `data` update. It carries no `units`: the
units are the parameter's own, declared once on the consumer.

`records_per_sample` (1 or 2, `nothing` when not written) is DEPRECATED (esm-spec
§8.5.1, removed at esm 3.0.0): the parameter's record shape says how many
records it receives, and a written value must agree with it. It parses and
round-trips as written; validation and `flatten` refuse a value that disagrees
with the record shape (`records_per_sample_invalid`).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/EarthSciAST.jl/src/types.jl#L898)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DataSourceBinding
DataSourceBinding(file_variable: str, unit_conversion: Expr | None = None, codes: dict[str, Any] | None = None, select: dict[str, Any] | None = None, records_per_sample: int | None = None, description: str | None = None, reference: Reference | None = None)
```

Binds a parameter to ONE variable of a `data_sources` entry (esm-spec
§8.5). It carries no `units`: the units are the parameter's own, declared
once on the parameter.

`select` overrides the source-level default for this parameter only, which
is how a full-grid field and a prefix of it are both read from one
`file_variable` without either being sliced by the consumer.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L325)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DataSourceBinding {
    pub file_variable: String,
    pub unit_conversion: Option<UnitConversion>,
    pub codes: Option<Value>,
    pub select: Option<Value>,
    pub records_per_sample: Option<u8>,
    pub description: Option<String>,
    pub reference: Option<Reference>,
}
```

Binds a parameter to ONE variable of a `data_sources` entry (esm-spec §8.5).
The 0.x `DataLoaderVariable` minus `units`: the units are the parameter's
own, declared once on the parameter instead of twice.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-rs/src/types/model.rs#L984) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DataSourceBinding.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DataSourceBinding struct {
	FileVariable   string `json:"file_variable"`
	UnitConversion any    `json:"unit_conversion,omitempty"`
	Codes          any    `json:"codes,omitempty"`
	Select         any    `json:"select,omitempty"`
	// RecordsPerSample is the DEPRECATED (removed at esm 3.0.0) number of
	// records the parameter receives per query time, 1 or 2, overriding the
	// source's `temporal.records_per_sample` (esm-spec 8.5.1). It must agree
	// with the record shape, which is what says the count. Nil when not
	// written.
	RecordsPerSample *int       `json:"records_per_sample,omitempty"`
	Description      *string    `json:"description,omitempty"`
	Reference        *Reference `json:"reference,omitempty"`
}

func (v *DataSourceBinding) UnmarshalJSON(data []byte) error
```

DataSourceBinding binds a PARAMETER to one file variable of a `data_sources` entry, through the `from` value form of a `data` update (esm-spec 8.5). It carries no `units`: the units are the parameter's own.

UnitConversion is a single Expression position; `Expression` already admits a bare number, so a plain factor is written as one. Its free names are subject to reference integrity (esm-spec 4.9.5).

**Methods**

```go
func (v *DataSourceBinding) UnmarshalJSON(data []byte) error
```

Custom JSON unmarshaling for DataSourceBinding. `unit_conversion` is a single Expression position (a plain factor is just the number spelling of one), so it goes through UnmarshalExpression to keep its int/float wire shape and to become an ExprNode when it is a full AST.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/2a98137b2fc6eb951597ae89e22e993e87bee65a/pkg/earthsci-ast-go/pkg/esm/types.go#L843) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSourceBinding)

</div>

</div>
