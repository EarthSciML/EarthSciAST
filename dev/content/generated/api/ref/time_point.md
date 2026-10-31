---
title: "time_point"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | not exported | `TimePoint` | `TimePoint` |


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
pub enum TimePoint {
    Seconds(Number),
    Timestamp(String),
}
```

One bound of a [`SolverTimeSpan`](/generated/api/ref/solver_time_span), kept in its authored form.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/types/model.rs#L245) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/enum.TimePoint.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type TimePoint struct {
	Number    *float64
	Timestamp *string
	// contains filtered or unexported fields
}

func (p TimePoint) MarshalJSON() ([]byte, error)

func (p *TimePoint) UnmarshalJSON(data []byte) error
```

TimePoint is one bound of a SolverTimeSpan: either a number in the document's time units (seconds of the independent variable) or an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss(.f+)?Z`), which means the seconds from the document's time origin to that instant (esm-spec §2.2.7). Exactly one of Number and Timestamp is set. It round-trips verbatim: a timestamp stays the string, a number stays the number written (`1.0` emits as `1.0`, `0` as `0`).

**Methods**

```go
func (p TimePoint) MarshalJSON() ([]byte, error)
```

MarshalJSON writes the bound back as authored: the timestamp string, or the number.

```go
func (p *TimePoint) UnmarshalJSON(data []byte) error
```

UnmarshalJSON reads a bound that is a JSON number or a JSON string. The string's form is the schema's to judge; it is held as written.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-go/pkg/esm/solver_time_span.go#L33) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#TimePoint)

</div>

</div>
