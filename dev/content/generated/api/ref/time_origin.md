---
title: "time_origin"
description: "Stable function · Other"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Other](/generated/api/topics/other)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `time_origin` | not exported | `time_origin` | `time_origin` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
time_origin(file::EsmFile)
time_origin(domain::Union{Nothing, AbstractString, Real, Domain, AbstractDict, AbstractVector})
```

```julia
time_origin(file::EsmFile) -> Float64
time_origin(domain) -> Float64
```

The time origin in seconds from the POSIX epoch: the instant
`domain.temporal.reference_time` — else `domain.temporal.start`, else the epoch
itself — names, as `W₀ + f₀`, whole seconds in integers and the fraction in
binary64. This is the origin a `solver.time_span` timestamp is counted from
(esm-spec §2.2.7), exposed so a caller does the same arithmetic for a timestamp
of its own with [`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds).

The origin comes from a loaded or in-memory document, or from its `domain`
alone: a typed `Domain`, the raw JSON `domain` object of a document
that has not been loaded (any `AbstractDict`, String- or Symbol-keyed, a
`JSON3.Object` included), or `nothing` for a document without one. The raw form
is read as the load-time check reads it, so a present key selects its field,
`null` included, and a `temporal` that is not an object has no origin field.

Raises `time_origin_invalid`, naming `/domain/temporal/...`, when the origin
field that applies is present but is not an RFC 3339 date-time naming a
calendar day, and naming `/domain` when a raw `domain` is not an object (a
string, an array, a number or a boolean).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/EarthSciAST.jl/src/solver.jl#L443)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
time_origin(source: EsmFile | Domain | dict[str, Any] | None) -> float
```

The time origin in binary64 seconds from the POSIX epoch.

The instant `domain.temporal.reference_time` -- else
`domain.temporal.start`, else the epoch itself -- names, as `W0 + f0`:
whole seconds in integers and the fraction in binary64. This is the origin a
`solver.time_span` timestamp counts from (esm-spec §2.2.7), exposed so a
caller does the same arithmetic for a timestamp of its own with
[`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds).

`source` is a document ([`EsmFile`](/generated/api/ref/esm_file)) or its
domain alone: a typed [`Domain`](/generated/api/ref/domain), the raw JSON
`domain` dict of a document that has not been loaded, or `None` for a
document without one. The raw form is read as the load-time check reads it:
a present key selects its field, `null` included, and a `temporal` that
is not an object has no origin field.

Raises `time_origin_invalid` naming `/domain/temporal/...` when the
origin field that applies is present but is not an RFC 3339 date-time naming
a calendar day, and naming `/domain` when a raw `domain` is not an object
(a string, a list, a number or a boolean); `TypeError` for a
`source` of any other type.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/solver.py#L626)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn time_origin<S: TimeOriginSource + ?Sized>(source: &S) -> Result<f64, DiagnosticError>
```

The time origin in seconds from the POSIX epoch (esm-spec §2.2.7):
`domain.temporal.reference_time`, else `domain.temporal.start`, else the
epoch itself, as `W0 + f0` -- whole seconds converted, the fraction added in
binary64.

This is the origin a `solver.time_span` timestamp counts from: the `W0`/`f0`
half of what [`resolve_time_span`](/generated/api/ref/resolve_time_span) does, exposed so a caller can convert a
timestamp of its own with [`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds). `source` is a document
or its domain, typed or raw JSON ([`TimeOriginSource`](/generated/api/extension/rust#x-timeoriginsource)):
`time_origin(&file)`, `time_origin(&domain)`, `time_origin(&doc["domain"])`.

A field that is present but is not an RFC 3339 date-time naming a calendar
day fails with `time_origin_invalid`, naming its pointer; so does a raw
`domain` that is not an object, naming `/domain`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/solver.rs#L733) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.time_origin.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
