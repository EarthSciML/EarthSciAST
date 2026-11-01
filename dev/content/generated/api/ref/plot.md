---
title: "plot"
description: "Stable type · Document types"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Document types](/generated/api/topics/document-types)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `Plot` | `Plot` |


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
pub struct Plot {
    pub id: String,
    pub plot_type: String,
    pub description: Option<String>,
    pub x: PlotAxis,
    pub y: PlotY,
    pub value: Option<PlotValue>,
    pub series: Option<Vec<PlotSeries>>,
    pub at_time: Option<f64>,
    pub pinned_coords: Option<HashMap<String, f64>>,
    pub contours: Option<Vec<f64>>,
}
```

A plot specification of a [`ModelAnalysis`](/generated/api/extension/rust#x-modelanalysis) (schema `Plot`). Structural
information only — axes, series selection, value reductions; styling is
the viewer's concern.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/types/analysis.rs#L304) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.Plot.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type Plot struct {
	ID          string       `json:"id"`
	Type        string       `json:"type"` // "line" | "scatter" | "heatmap"
	Description *string      `json:"description,omitempty"`
	X           PlotAxis     `json:"x"`
	Y           PlotAxis     `json:"y"`
	Value       *PlotValue   `json:"value,omitempty"`
	Series      []PlotSeries `json:"series,omitempty"`
}

func (p *Plot) UnmarshalJSON(data []byte) error
```

Plot is a plot specification associated with an Analysis.

**Methods**

```go
func (p *Plot) UnmarshalJSON(data []byte) error
```

UnmarshalJSON handles plots.y as either a single PlotAxis or an array of PlotAxis objects (v0.5.0 inline multi-series shorthand). When y is an array the first entry becomes the canonical Y axis and all entries are projected onto Series (using label-or-variable as the series name). An explicit series field, if present, takes precedence over the projection.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/types.go#L661) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#Plot)

</div>

</div>
