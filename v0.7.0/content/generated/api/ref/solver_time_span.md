---
title: "solver_time_span"
description: "Stable type · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** type · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `SolverTimeSpan` | not exported | `SolverTimeSpan` | `SolverTimeSpan` | `SolverTimeSpan` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
struct SolverTimeSpan
SolverTimeSpan(start::Union{Float64, Int64, String}, stop::Union{Float64, Int64, String})
SolverTimeSpan(start, stop)
```

```julia
SolverTimeSpan(start, stop)
```

The `solver.time_span` interval (esm-spec §2.2.7): the period the document is
meant to be simulated over. Each bound is what the author wrote — a number in
the document's time units (seconds; an `Int64` when written as an integer, else
a `Float64`), or an RFC 3339 UTC timestamp `String` — so `emit` writes it back
unchanged. Its value in seconds comes from
[`resolve_time_span`](/generated/api/ref/resolve_time_span). The wire key `end` is spelled `stop` here, as in
`TimeSpan`, because `end` is a Julia keyword.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/types.jl#L1376)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this type.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
class SolverTimeSpan
SolverTimeSpan(start: float | int | str, end: float | int | str)
```

`solver.time_span`: the interval a document is meant to be simulated over.

Each bound is held EXACTLY as authored (esm-spec §2.2.4 requirement 2): a
number in the document's time units (seconds of the independent variable),
or an RFC 3339 UTC timestamp string (`...Z`), which means seconds from the
document's time origin. [`resolve_time_span`](/generated/api/ref/resolve_time_span)
converts both to binary64 seconds (§2.2.7); the converted value is never
written back into the document.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/esm_types.py#L693)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub struct SolverTimeSpan {
    pub start: TimePoint,
    pub end: TimePoint,
}
```

`solver.time_span` (esm-spec §2.2.7): the `{start, end}` shape of
`tests[].time_span` ([`TimeSpan`](/generated/api/ref/time_span)), except that each bound may also be an
RFC 3339 UTC timestamp, so it is a separate type rather than `f64` bounds.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/types/model.rs#L235) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/struct.SolverTimeSpan.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
type SolverTimeSpan struct {
	Start TimePoint `json:"start"`
	End   TimePoint `json:"end"`
}
```

SolverTimeSpan is the interval the document's author means it to be simulated over (esm-spec §2.2.7). It is a distinct type from TimeSpan (the `tests[].time_span` pair of float bounds) because a bound here may also be an RFC 3339 UTC timestamp. Both bounds are held exactly as authored and emitted verbatim; their value in seconds comes from ResolveTimeSpan and is never written back.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-go/pkg/esm/solver_time_span.go#L22) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#SolverTimeSpan)

</div>

</div>
