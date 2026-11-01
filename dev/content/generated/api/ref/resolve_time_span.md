---
title: "resolve_time_span"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `resolve_time_span` | `resolveTimeSpan` | `resolve_time_span` | `resolve_time_span` | `ResolveTimeSpan` |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
resolve_time_span(file::EsmFile; tspan)
```

```julia
resolve_time_span(file::EsmFile; tspan=nothing) -> Union{Tuple{Float64,Float64},Nothing}
```

The interval to simulate `file` over, most specific first (esm-spec §2.2.7):

1. `tspan`, an explicit interval at the call site, returned unchanged — it
   always wins, both bounds.
2. Otherwise the document's `solver.time_span`, as `(start, end)` in seconds.
3. Otherwise `nothing`.

A number bound is already seconds. A timestamp bound is the seconds from the
document's time origin — `domain.temporal.reference_time`, else
`domain.temporal.start`, else the POSIX epoch — to that instant, computed from
the fields as `(W − W₀) + (f − f₀)` with no host date library. Throws
`solver_time_span_invalid` for an interval a load would have refused (a
document built in memory is not checked at load).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/EarthSciAST.jl/src/solver.jl#L391)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

```typescript
function resolveTimeSpan(file: EsmFile, tspan?: readonly [ number, number ] | null): [ number, number ] | null
```

The run interval by the esm-spec §2.2.7 chain: the call-site interval
`tspan` when given (both bounds, always), otherwise the root document's
`solver.time_span` converted to binary64 seconds since the document's time
origin, otherwise `null` (no interval).

A timestamp bound counts seconds from `domain.temporal.reference_time`, else
`domain.temporal.start`, else the POSIX epoch, without leap seconds, by exact
arithmetic on its fields (no host date library). A number bound is its
value. The document keeps what was authored; `toJson` writes the authored
bounds back and never the converted value.

**Throws**

- [`EsmMachineryError`](/generated/api/extension/typescript#x-esmmachineryerror) — `solver_time_span_invalid` when the document's
    interval is not one (only reachable for a document built in memory; load
    refuses it), including a bound whose form is not schema-valid.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-ts/src/solver.ts#L420)

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
resolve_time_span(esm_file: EsmFile, tspan: tuple[float, float] | None = None) -> tuple[float, float] | None
```

The interval a run should cover, most-specific first (esm-spec §2.2.7).

1. `tspan`, an explicit call-site interval: it always wins, both bounds.
2. Otherwise the document's `solver.time_span`, converted to binary64
   seconds: a number bound is its value; a timestamp is seconds from the
   document's time origin (`domain.temporal.reference_time`, else
   `domain.temporal.start`, else the POSIX epoch), computed as
   `(W - W0) + (f - f0)` -- whole seconds in integers, then the
   fractions in binary64.
3. Otherwise `None`: no interval, not a default one.

The document keeps, and `emit` writes, the authored bounds; the converted
value is never written back. Raises `solver_time_span_invalid` for an
interval a load would have refused (a document built in memory is not
checked at load), and for a bound whose form is not the schema's.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L537)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn resolve_time_span(file: &EsmFile, tspan: Option<(f64, f64)>) -> Result<Option<(f64, f64)>, DiagnosticError>
```

The run interval, most specific first (esm-spec §2.2.7, by the §2.2.2
order):

1. `tspan`, an explicit interval at the call site — it always wins, both
   bounds.
2. Otherwise the document's `solver.time_span`, converted to binary64
   seconds on the document's clock (a timestamp counts from
   `domain.temporal.reference_time`, else `domain.temporal.start`, else the
   POSIX epoch).
3. Otherwise `Ok(None)`: no interval, not a default one.

The document is not changed — `emit` writes the authored bounds. A loaded
document has already passed the load-time check; one built in memory that
describes no interval fails here with `solver_time_span_invalid`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/solver.rs#L599) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.resolve_time_span.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

```go
func ResolveTimeSpan(file *ESMFile, callSite *[2]float64) (*[2]float64, error)
```

ResolveTimeSpan resolves the run interval by the esm-spec §2.2.7 chain: the call-site interval when callSite is non-nil (it always wins, both bounds), else the document's `solver.time_span` converted to binary64 seconds, else nil (no interval). A timestamp bound counts seconds from the document's time origin: `domain.temporal.reference_time`, else `domain.temporal.start`, else the POSIX epoch. Only the root's `solver` block is consulted; a mounted leaf's block does not cross the mount.

The error is non-nil only for a document the load-time check would refuse (`solver_time_span_invalid`), which a loaded document never is but one built in code can be.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-go/pkg/esm/solver_time_span.go#L393) · [Go docs](https://pkg.go.dev/github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm#ResolveTimeSpan)

</div>

</div>
