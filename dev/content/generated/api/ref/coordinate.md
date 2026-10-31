---
title: "coordinate"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `Coordinate` | `Coordinate` |


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
pub struct Coordinate {
    pub source: Option<String>,
    pub values: Option<Vec<f64>>,
    pub standard_name: Option<String>,
    pub units: Option<String>,
    pub axis: Option<String>,
}
```

One entry of the document-scoped `EsmFile::coordinates` registry
(RFC streaming-output-sinks §8.3): marks an existing data array — or an
inline literal vector — as a physical coordinate and attaches CF metadata.

Exactly one of `source` and `values` is present. The coordinate's shape
comes from its source, so it is NOT attached to any single axis: that one
rule covers rectilinear (1-D monotonic → CF *dimension* coordinate),
unstructured (1-D over a shared dimension) and curvilinear (2-D `lat(y,x)`)
grids, the latter two emitting CF *auxiliary* coordinates.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/model.rs#L265) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Coordinate.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Coordinate struct {
	// Source names an existing data array supplying this coordinate's values.
	// Mutually exclusive with Values; `omitempty` because exactly one of the two
	// is authored and the other key must not appear.
	Source *string `json:"source,omitempty"`
	// Values is the inline literal 1-D coordinate vector (finite floats),
	// mutually exclusive with Source.
	Values []float64 `json:"values,omitempty"`
	// StandardName is the CF standard name emitted as the coordinate variable's
	// `standard_name` attribute.
	StandardName *string `json:"standard_name,omitempty"`
	// Units is the CF/UDUNITS units string. Advisory at load time (no unit
	// checking), matching FunctionTableAxis.Units.
	Units *string `json:"units,omitempty"`
	// Axis is the optional CF axis role ("X"|"Y"|"Z"|"T") of a 1-D monotonic
	// dimension coordinate; auxiliary coordinates have no single axis and omit
	// it, so it must be `omitempty` — the schema's enum admits no empty string.
	Axis *string `json:"axis,omitempty"`
}
```

Coordinate is one entry of the document-scoped `coordinates` registry (RFC streaming-output-sinks §8): it marks an existing data array — a model unknown or parameter named by `source` — or an inline literal `values` vector as a physical coordinate, and attaches CF metadata to it. Exactly one of Source / Values is present; the coordinate's shape comes from whichever it is, so no per-axis attachment is needed.

This binding is schema-only for coordinates: it stores and round-trips the declarations, resolves nothing, and writes no output files.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/types.go#L1222) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Coordinate)

</div>

</div>
