---
title: "field_reduce"
description: "Stable function · Simulation"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Simulation](/generated/api/topics/simulation)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| `field_reduce` | outside profile | not exported | `field_reduce` | outside profile |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

```julia
field_reduce(kind::AbstractString, actual::AbstractVector{<:Real}; reference)
```

```julia
field_reduce(kind, actual; reference=nothing) -> Float64
```

Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares
(esm-spec §6.6.5):

- `"L2_error"`  — `‖actual − reference‖₂ / ‖reference‖₂` (relative L2 over the
  domain; requires `reference`).
- `"Linf_error"` — `max |actual − reference|` (absolute supremum norm; requires
  `reference`).
- `"integral"` — the uniform-cell Riemann sum under a UNIT total domain
  measure per axis: `Σ field / N_cells`, i.e. exactly `mean`. This is the
  pinned cross-binding convention (the same measure convention under which
  the relative-L2 reduction is measure-free); non-unit physical domains must
  be scaled by the author until the spec grows a measure concept.
- `"mean" | "max" | "min"` — pure collapsers of `actual`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/EarthSciAST.jl/src/inline_tests.jl#L657)

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">Not available in TypeScript. TypeScript is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

<p class="api-absent">Python does not export this function.</p>

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn field_reduce(kind: &str, actual: &[f64], reference: Option<&[f64]>) -> Result<f64, String>
```

Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion
compares (esm-spec §6.6.5); semantics identical to the Julia / Python
references:

- `"L2_error"`  — `‖actual − reference‖₂ / ‖reference‖₂` (relative L2 over
  the domain; requires `reference`).
- `"Linf_error"` — `max |actual − reference|` (absolute supremum norm;
  requires `reference`).
- `"integral"` — the uniform-cell Riemann sum under a UNIT total domain
  measure per axis: `Σ field / N_cells`, i.e. exactly `mean`. This is the
  pinned cross-binding convention (the same measure convention under which
  the relative-L2 reduction is measure-free); non-unit physical domains
  must be scaled by the author until the spec grows a measure concept.
- `"mean" | "max" | "min"` — pure collapsers of `actual`.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c168e38f6a9f1eb2b4fb89c4517d0ccbf7089861/pkg/earthsci-ast-rs/src/inline_tests.rs#L466) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.field_reduce.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Not available in Go. Go is outside the simulation capability profile (Julia, Python, Rust): build an RHS and integrate it; TypeScript and Go are deliberately non-simulating.</p>

</div>

</div>
