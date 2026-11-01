---
title: "data_source"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `DataSource` | not exported | `DataSource` | `DataSource` | `DataSource` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct DataSource
DataSource(kind::String, source::DataSourceLocation; temporal, determinism, reader_options, select, record_filter, extent, reference, metadata)
```

```julia
DataSource
```

Generic, runtime-agnostic description of an external dataset (esm-spec §8).
Pure I/O: locate, read, decode, slice, and filter bytes on disk. It performs no
reprojection and no regridding — transferring native fields onto a consuming
model's grid is an ordinary coupling expression (§8.6).

**A data source is a REGISTRY ENTRY, not a component.** It
is not a `SubsystemNode`: it exposes no variables of its own, cannot be a
coupling endpoint or a subsystem, and cannot be the path root of a scoped
reference. A model consumes one by declaring a PARAMETER whose
[`ParameterUpdate`](/generated/api/ref/parameter_update) names the source and binds one of its file variables
([`DataSourceBinding`](/generated/api/ref/data_source_binding)), and that parameter owns the units: the binding
lives on the consumer, not on this struct.

Carries every property esm-schema.json's `DataSource` defines — the schema sets
`additionalProperties: false`, so the list is closed — for the reason
[`Domain`](/generated/api/ref/domain) states: a property this struct does not hold is a property
`load` silently drops. The four decode/slice/filter blocks are kept VERBATIM
(raw JSON) because nothing in this package reads them back; their whole job is
to reach the reader that does.

Fields:
- `kind`: "grid" | "points" | "static" (structural kind; scientific role goes in `metadata.tags`)
- `source`: [`DataSourceLocation`](/generated/api/ref/data_source_location) with url_template + optional mirrors
- `temporal`: optional [`DataSourceTemporal`](/generated/api/ref/data_source_temporal)
- `determinism`: optional [`DataSourceDeterminism`](/generated/api/ref/data_source_determinism)
- `reader_options`: format-specific DECODE options passed to the reader verbatim (§8)
- `select`: source-level axis selection (schema `DataSourceSelect`)
- `record_filter`: which records of a `points` source are DELIVERED (schema `DataSourceRecordFilter`)
- `extent`: binds the source's delivered record count to a metaparameter (schema `DataSourceExtent`)
- `reference`: optional academic/data-source citation
- `metadata`: optional free-form map (conventionally carries a `tags` array)

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/types.jl#L2069)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class DataSource
DataSource(name: str, kind: DataSourceKind, source: DataSourceLocation, temporal: DataSourceTemporal | None = None, determinism: DataSourceDeterminism | None = None, reference: Reference | None = None, metadata: dict[str, Any] = dict(), reader_options: dict[str, Any] | None = None, select: dict[str, Any] | None = None, record_filter: dict[str, Any] | None = None, extent: dict[str, Any] | None = None)
```

A named external data source reduced to pure I/O: it locates, reads,
decodes, slices and filters bytes on disk (esm-spec §8).

It exposes NO variables and is NOT a component — it cannot be a
coupling endpoint, a subsystem, or a scoped-name path root. A model consumes
it by declaring a PARAMETER whose `update` names this source and binds one
of its `file_variable`s ([`DataSourceBinding`](/generated/api/ref/data_source_binding)); the parameter owns
the units. Grid geometry a source reads arrives as ordinary parameters and
is transformed downstream by `faq` FAQs and coupling expressions.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L958)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct DataSource {
    pub kind: DataSourceKind,
    pub source: DataSourceLocation,
    pub temporal: Option<DataSourceTemporal>,
    pub determinism: Option<DataSourceDeterminism>,
    pub reader_options: Option<Value>,
    pub select: Option<Value>,
    pub record_filter: Option<Value>,
    pub extent: Option<Value>,
    pub reference: Option<Reference>,
    pub metadata: Option<DataSourceMetadata>,
}
```

Generic, runtime-agnostic description of an external data source
(esm-spec §8).

A `DataSource` is pure I/O (RFC pure-io-data-loaders §4.1): it locates,
reads, decodes, slices and filters bytes and nothing else. From esm 1.0.0 it
**exposes no variables and is not a component** — not a coupling endpoint,
not a subsystem, not a scoped-name path root. A model consumes it by
declaring a PARAMETER whose `ParameterUpdate::Data` names this entry and
binds one of its file variables ([`DataSourceBinding`](/generated/api/ref/data_source_binding)); the parameter owns
the units. Grid geometry a source reads arrives the same way, as ordinary
parameters, and is transformed downstream by `faq` nodes.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/components.rs#L212) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.DataSource.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type DataSource struct {
	Kind        string                 `json:"kind"` // "grid", "points", or "static" (esm-spec 8.1)
	Source      DataSourceLocation     `json:"source"`
	Temporal    *DataSourceTemporal    `json:"temporal,omitempty"`
	Determinism *DataSourceDeterminism `json:"determinism,omitempty"`
	// ReaderOptions are format-specific DECODE options handed to the format
	// reader verbatim (esm-spec 8.9.1).
	ReaderOptions map[string]any `json:"reader_options,omitempty"`
	// Select is the per-axis default selection every parameter drawing from this
	// source inherits, unless its own `from.select` overrides it (esm-spec
	// 8.9.2). Held raw: this binding round-trips it but does not evaluate it.
	Select any `json:"select,omitempty"`
	// RecordFilter decides which records of a `points` source survive. The mask
	// is computed ONCE for the source and applied to every parameter drawing
	// from it, which is what keeps two columns of one table in alignment
	// (esm-spec 8.9.3).
	RecordFilter *DataSourceRecordFilter `json:"record_filter,omitempty"`
	// Extent binds the delivered record count to a metaparameter, for a source
	// whose size is not knowable until it is read (esm-spec 8.9.4).
	Extent    *DataSourceExtent `json:"extent,omitempty"`
	Reference *Reference        `json:"reference,omitempty"`
	Metadata  map[string]any    `json:"metadata,omitempty"`
}

func (d DataSource) IsTimeVarying() bool
```

DataSource is a runtime-agnostic description of an external dataset, reduced to a single responsibility: locate, read, decode, slice, and filter bytes on disk (esm-spec 8). It performs no reprojection and no regridding.

From esm 1.0.0 a data source is a document-scoped REGISTRY ENTRY, not a component: it exposes no variables of its own, and cannot be a coupling endpoint, a subsystem, or a scoped-name path root. A model consumes one by declaring a PARAMETER whose `update` names the source and binds one of its file variables (`update: {kind: "data", source, from}`) -- the parameter IS the loaded field, and it owns the field's units.

**Methods**

```go
func (d DataSource) IsTimeVarying() bool
```

IsTimeVarying reports whether the source declares a `temporal` block. This is the one document field a cadence leaf seed reads outside the variable's own declaration (CONFORMANCE\_SPEC 5.7.2, source-seeded refinement): a parameter fed by a source WITH `temporal` stays DISCRETE, one fed by a source without it refines down to CONST.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L767) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#DataSource)

</div>

</div>
