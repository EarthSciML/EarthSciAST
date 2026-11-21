---
title: "timestamp_to_seconds"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `timestamp_to_seconds` | not exported | `timestamp_to_seconds` | `timestamp_to_seconds` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
timestamp_to_seconds(file::EsmFile, timestamp)
timestamp_to_seconds(domain::Union{Nothing, AbstractString, Real, Domain, AbstractDict, AbstractVector}, timestamp)
```

```julia
timestamp_to_seconds(file::EsmFile, timestamp) -> Float64
timestamp_to_seconds(domain, timestamp) -> Float64
```

`timestamp`, an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z` — the
`solver.time_span` bound form), as seconds from the time origin of `file` or of
`domain` (typed, raw JSON or `nothing`, as for [`time_origin`](/generated/api/ref/time_origin)):
`(W − W₀) + (f − f₀)`, the whole-second difference in integers and then the
fractions in binary64, exactly as [`resolve_time_span`](/generated/api/ref/resolve_time_span) converts a
`time_span` timestamp (esm-spec §2.2.7).

Each cause has its own code, checked in this order, so the first that applies
is the one raised:

1. `timestamp_malformed` — `timestamp` is not a string, or not of that form;
2. `timestamp_no_calendar_day` — it is of that form but its day is not in its
   month (`2019-02-30`, `02-29` outside a leap year);
3. `time_origin_invalid` — the origin field that applies cannot be read, or a
   raw `domain` is not an object.

The timestamp is checked before the origin, so a bad timestamp is reported as
such even when the origin is also unreadable.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/solver.jl#L475)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
timestamp_to_seconds(source: EsmFile | Domain | dict[str, Any] | None, timestamp: str) -> float
```

`timestamp` as seconds from `source`'s time origin (esm-spec §2.2.7).

`timestamp` is an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z`,
the `solver.time_span` bound form). The result is `(W - W0) + (f - f0)`:
the whole-second difference in integers, then the fractions added in
binary64 -- exactly what [`resolve_time_span`](/generated/api/ref/resolve_time_span) does to a `time_span`
timestamp. `source` and the origin are as for [`time_origin`](/generated/api/ref/time_origin).

Each cause has its own code, checked in this order, so the first that
applies is the one raised:

1. `timestamp_malformed` -- `timestamp` is not a string, or not of that
   form;
2. `timestamp_no_calendar_day` -- it is of that form but its day is not
   in its month (`2019-02-30`, `02-29` outside a leap year);
3. `time_origin_invalid` -- the origin field that applies cannot be read,
   or a raw `domain` is not an object.

A `source` of a type [`time_origin`](/generated/api/ref/time_origin) does not take is a
`TypeError`, raised before the timestamp is looked at.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L653)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn timestamp_to_seconds<S: TimeOriginSource + ?Sized>(source: &S, timestamp: &str) -> Result<f64, DiagnosticError>
```

`timestamp` as seconds from `source`'s time origin (esm-spec §2.2.7).

`timestamp` is an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z`, the
`solver.time_span` bound form). The result is `(W - W0) + (f - f0)`: the
whole-second difference in integers, then the fractions added in binary64,
exactly as [`resolve_time_span`](/generated/api/ref/resolve_time_span) converts a `time_span` timestamp. `source`
and the origin are as for [`time_origin`](/generated/api/ref/time_origin).

Each cause has its own code, checked in this order, so the first that
applies is the one returned:

1. `timestamp_malformed` -- `timestamp` is not of that form;
2. `timestamp_no_calendar_day` -- it is, but its day is not in its month
   (`2019-02-30`, `02-29` outside a leap year);
3. `time_origin_invalid` -- the origin field that applies cannot be read,
   or a raw `domain` is not an object.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/solver.rs#L754) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.timestamp_to_seconds.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
