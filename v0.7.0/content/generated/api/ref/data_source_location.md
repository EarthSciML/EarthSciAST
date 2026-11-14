---
title: "data_source_location"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DataSourceLocation` | not exported | `DataSourceLocation` | `DataSourceLocation` | `DataSourceLocation` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DataSourceLocation
DataSourceLocation(url_template::String; mirrors)
```

```julia
DataSourceLocation
```

File discovery configuration for a data source (the schema's
`DataSource.source` object). Describes how to locate data files at runtime via
a URL template with `{date:<strftime>}`, `{var}`, `{sector}`, `{species}`, and
custom substitutions. Optional `mirrors` list gives ordered fallback templates.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1999)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DataSourceLocation
DataSourceLocation(url_template: str, mirrors: list[str] = list())
```

File discovery configuration for a data source.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L933)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DataSourceLocation {
    pub url_template: String,
    pub mirrors: Option<Vec<String>>,
}
```

File discovery configuration. Describes how to locate data files at
runtime via URL templates with date/variable substitutions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/components.rs#L289) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DataSourceLocation.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DataSourceLocation struct {
	URLTemplate string   `json:"url_template"`
	Mirrors     []string `json:"mirrors,omitempty"`
}
```

DataSourceLocation describes file discovery for a data source. URL templates use Jinja-style substitutions for dates, variable names, and similar (esm-spec 8.2).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/types.go#L810) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSourceLocation)

</div>

</div>
