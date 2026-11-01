---
title: "plan_dimension_coordinates"
description: "Stable function · Runtime I/O"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Runtime I/O](/generated/api/topics/runtime-io)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `plan_dimension_coordinates` | outside profile | not exported | `plan_dimension_coordinates` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
plan_dimension_coordinates(gridding::AbstractVector{VarGridding}, meta::OutputMeta)
```

```julia
plan_dimension_coordinates(gridding, meta::OutputMeta) -> Vector{DimCoord}
```

Resolve the `coordinates` registry (§8.3) into the CF **dimension coordinates**
for a set of [`VarGridding`](/generated/api/ref/var_gridding)s: for each distinct spatial dim, if the registry
has an entry KEYED BY THAT DIM NAME carrying inline `values`, emit a [`DimCoord`](/generated/api/extension/julia#x-dimcoord)
(validating its length against the dim's grid length) with the entry's
`standard_name`/`units`/`axis` attrs. Registry entries whose key is not a dim name
(auxiliary coordinates) and `source`-backed entries are skipped in v1 (the
dimension-coordinate path handles inline values); they are the documented next
drop-in. Dims with no registry entry emit no coordinate (bare integer axis, as before).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/data_output.jl#L790)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn plan_dimension_coordinates(gridding: &[VarGridding], meta: &OutputMeta) -> Result<Vec<CoordPlan>, OutputError>
```

Resolve the `coordinates` registry (§8.3) into the CF **dimension
coordinates** for a set of [`VarGridding`](/generated/api/ref/var_gridding)s — the Rust mirror of Julia's
`plan_dimension_coordinates`.

For each distinct spatial dim, in first-seen order, a registry entry KEYED
BY THAT DIM NAME carrying inline `values` produces a [`CoordPlan`](/generated/api/extension/rust#x-coordplan) with the
entry's `standard_name` / `units` / `axis`. Entries whose key is not a dim
name (CF *auxiliary* coordinates) and `source`-backed entries are skipped:
they resolve against build artifacts, not the document, and are the
documented next drop-in on the same registry. A dim with no entry emits no
coordinate — a bare integer axis.

**Errors**
`OutputError::CoordLengthMismatch` when an entry's `values` length does
not match the axis it names.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/data_output.rs#L857) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.plan_dimension_coordinates.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the runtime I/O capability profile (Julia, Python, Rust): data-source providers, refresh cadence, output sinks, checkpoints.</p>

</div>

</div>
