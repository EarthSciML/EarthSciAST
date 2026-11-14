---
title: "data_source_temporal"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DataSourceTemporal` | not exported | `DataSourceTemporal` | `DataSourceTemporal` | `DataSourceTemporal` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DataSourceTemporal
DataSourceTemporal(; start, stop, file_period, frequency, records_per_file, time_variable, records_per_sample)
```

```julia
DataSourceTemporal
```

Temporal coverage and record layout for a data source (esm-spec §8.3). Its
PRESENCE is what makes the source time-varying, and so what keeps a parameter
drawing from it seeded DISCRETE rather than refined to CONST
(CONFORMANCE_SPEC §5.7.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L2015)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DataSourceTemporal
DataSourceTemporal(start: str | None = None, end: str | None = None, file_period: str | None = None, frequency: str | None = None, records_per_file: int | str | None = None, time_variable: str | None = None)
```

Temporal coverage and record layout for a data source.

Its PRESENCE is what makes a source's outputs time-varying, and that is what
seeds a consuming parameter DISCRETE rather than CONST (CONFORMANCE_SPEC
§5.7.2). Absence means non-time-varying: read once, folded at bind.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L941)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DataSourceTemporal {
    pub start: Option<String>,
    pub end: Option<String>,
    pub file_period: Option<String>,
    pub frequency: Option<String>,
    pub records_per_file: Option<RecordsPerFile>,
    pub time_variable: Option<String>,
}
```

Temporal coverage and record layout for a data source.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/components.rs#L303) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DataSourceTemporal.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DataSourceTemporal struct {
	Start            *string `json:"start,omitempty"`
	End              *string `json:"end,omitempty"`
	FilePeriod       *string `json:"file_period,omitempty"`
	Frequency        *string `json:"frequency,omitempty"`
	RecordsPerFile   any     `json:"records_per_file,omitempty"`
	TimeVariable     *string `json:"time_variable,omitempty"`
	RecordsPerSample *int    `json:"records_per_sample,omitempty"`
}
```

DataSourceTemporal describes the temporal coverage and record layout (esm-spec 8.3). RecordsPerFile may be an int or the string "auto".

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L817) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSourceTemporal)

</div>

</div>
