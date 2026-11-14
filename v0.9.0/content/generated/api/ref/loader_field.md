---
title: "loader_field"
description: "Stable type · Document I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document I/O](/generated/api/topics/document-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | `LoaderField` | `LoaderField` | `LoaderField` | `LoaderField` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this type.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
interface LoaderField {
    name: string;
    owner: string;
    subkey: string;
    var: string;
    dataSource: DataSource;
    cadence: 'const' | 'discrete';
    unitConversion?: Expression;
    recordsPerSample: 1 | 2;
}
```

A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5).

From 1.0.0 a data source is not a component: a model consumes one by declaring
a parameter whose `update` is `{kind: "data", source, from: {file_variable}}`.
The parameter IS the loaded field and owns the units; this descriptor is what
lets a simulator execute the source at its cadence and bind the resulting
array into the RHS as a read-only input.

**Properties**

- `name` — The namespaced parameter symbol, e.g. `"Plume.wind"`.
- `owner` — The owning component's namespaced prefix, e.g. `"Plume"`.
- `subkey` — The `data_sources` key the parameter's `update` names.
- `var` — The source-file variable the binding names.
- `dataSource` — The resolved `data_sources` entry (carries kind / source / temporal).
- `cadence` — Source-seeded cadence (CONFORMANCE_SPEC §5.7.2): a source WITH a `temporal`
  block is time-varying (`discrete`); one without is read once (`const`).
- `unitConversion` — The binding's declared `unit_conversion` (§8.5), when the document has one.
- `recordsPerSample` — The EFFECTIVE records per query time (esm-spec §8.5.1): the binding's
  `from.records_per_sample`, else the source's `temporal.records_per_sample`,
  else 1. With 2 the field holds the record at or before the query time and
  its successor, stacked along the parameter's first dimension.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/494e1dc4735a68dc35a8f9a91fc5c4803e60a620/pkg/earthsci-ast-ts/src/flatten.ts#L342)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class LoaderField
LoaderField(name: str, owner: str, subkey: str, var: str, data_source: DataSource, cadence: str, unit_conversion: Expr | None = None, records_per_sample: int = 1)
```

A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5).

A data source is not a component: there is no loader subsystem and no
coupling edge. A model consumes a source by declaring a PARAMETER
whose `update` is `{kind: "data", source: <key>, from: {file_variable}}`
— the parameter IS the loaded field, and it owns the units. Flatten records
this descriptor per such parameter so the simulator can execute the source at
its cadence and bind the resulting array into the RHS as a read-only input,
keyed by the parameter's namespaced name. A data-fed parameter carries no
defining equation: its value is injected, not computed.

`cadence` follows the source-seeded refinement (CONFORMANCE_SPEC §5.7.2,
cadence.py): a source WITH a `temporal` block is time-varying →
`"discrete"` (refreshed in a discrete solver callback at its cadence); a
source WITHOUT `temporal` is non-time-varying → `"const"` (read once
before integration).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/494e1dc4735a68dc35a8f9a91fc5c4803e60a620/pkg/earthsci-ast-py/src/earthsci_ast/flatten.py#L327)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct LoaderField {
    pub name: String,
    pub owner: String,
    pub source: String,
    pub file_variable: String,
    pub cadence: String,
    pub records_per_sample: u8,
}
```

One provider-served loaded field the flattened system consumes
(esm-spec §8.5; esm-libraries-spec §4.7.5 step 4 `loader_fields`).

From esm 1.0.0 a data source is not a component: there is no loader
subsystem and no coupling edge. A model consumes a source by declaring a
PARAMETER whose `update` is `{kind: "data", source: &lt;key>, from:
{file_variable}}` — the parameter IS the loaded field and owns the units.
Flatten records this descriptor per such parameter so a consumer can
execute the source at its cadence and bind the resulting array into the RHS
as a read-only input, without re-reading the source document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/494e1dc4735a68dc35a8f9a91fc5c4803e60a620/pkg/earthsci-ast-rs/src/flatten.rs#L866) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.LoaderField.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type LoaderField struct {
	// Name is the namespaced parameter symbol ("Advection.u_wind").
	Name string
	// Owner is the owning component's namespaced prefix ("Advection").
	Owner string
	// Source is the `data_sources` key the parameter's update names.
	Source string
	// FileVariable is the source-file variable the binding names.
	FileVariable string
	// Cadence follows the SOURCE, not the parameter (CONFORMANCE_SPEC §5.7.2):
	// a source WITH a `temporal` block is time-varying → "discrete"; one
	// without is read once → "const".
	Cadence string
	// DataSource is the resolved `data_sources` entry.
	DataSource DataSource
	// UnitConversion is the binding's declared `unit_conversion` (§8.5), or nil.
	UnitConversion Expression
	// RecordsPerSample is the EFFECTIVE number of records the parameter
	// receives per query time, 1 or 2 (esm-spec §8.5.1): the binding's
	// `from.records_per_sample`, else the source's
	// `temporal.records_per_sample`, else 1. With 2 the field holds the record
	// at or before the query time and its successor, stacked along the
	// parameter's first dimension.
	RecordsPerSample int
}
```

LoaderField is a data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5). From 1.0.0 a data source is not a component: a model consumes a source by declaring a parameter whose `update` is `{kind: "data", source: <key>, from: {file_variable}}` — the parameter IS the loaded field. Flatten records this descriptor per such parameter so a simulator can execute the source at its cadence and bind the resulting array into the RHS as a read-only input, keyed by the parameter's namespaced name.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/494e1dc4735a68dc35a8f9a91fc5c4803e60a620/pkg/earthsci-ast-go/pkg/esm/flatten.go#L338) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#LoaderField)

</div>

</div>
