---
title: "polygon_area"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `polygon_area` | `polygon_area` | not exported |


<div class="api-tabs">

<div class="api-tab" data-lang="julia" data-label="Julia">
<p class="api-tab-label">Julia</p>

<p class="api-absent">Julia does not export this function.</p>

</div>

<div class="api-tab" data-lang="typescript" data-label="TypeScript">
<p class="api-tab-label">TypeScript</p>

<p class="api-absent">TypeScript does not export this function.</p>

</div>

<div class="api-tab" data-lang="python" data-label="Python">
<p class="api-tab-label">Python</p>

```python
polygon_area(ring: np.ndarray, manifold: str, radius: float = 1.0) -> float
```

Reference (unsigned) area of an overlap ring under `manifold`.

Planar ⇒ shoelace / Gauss–Green; spherical / geodesic ⇒ the spherical-excess
sum (`radius` = sphere radius / characteristic length, default the unit
sphere). Returns `0.0` for a degenerate (&lt; 3 vertex) ring — an empty clip.
This is the imperative **cross-check oracle** for the `sum_product`
`polygon_area` FAQ: the production polygon area routes through that FAQ
([`earthsci_ast.area_faq.polygon_area_via_faq`](/generated/api/extension/python#x-polygon_area_via_faq)) for both manifolds,
and this function encodes the same formula the FAQ body does.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L812)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn polygon_area(ring: &[(f64, f64)], manifold: Manifold) -> Result<f64, GeometryError>
```

Unsigned `polygon_area` of an overlap ring under `manifold` — the imperative
**cross-check oracle** for the `polygon_area` `sum_product` FAQ (RFC §8.1).
Planar ⇒ shoelace / Gauss–Green; spherical / geodesic ⇒ the great-circle-edge
area in **steradians** (unit sphere) via `s2rst`. A degenerate (&lt; 3
vertex) ring — an empty clip — is `0.0`. The conservative-regridding assembly
(a regridding document's build-time aggregates, evaluated by
`crate::prepare`'s observed-graph pass) computes the build-once factor
`A_ij` through the FAQ (`crate::area_faq::polygon_area_faq`); this function
is the same value that FAQ encodes, kept as the independent oracle (mirrors
Python `geometry.polygon_area`).

Target-agnostic in the strong sense: the spherical arm defers to
`spherical_area`, which is the SAME pure-Rust `s2rst` kernel on every
target — there is no wasm-only failure mode left to guard against.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/c04be2a20a642c46f873650609c0f56f6d823cb9/pkg/earthsci-ast-rs/src/geometry.rs#L393) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.polygon_area.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
