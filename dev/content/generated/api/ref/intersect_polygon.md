---
title: "intersect_polygon"
description: "Stable function · Relational keys and geometry"
type: "api"
api_tabs: true
---


**Tier:** stable · **Kind:** function · **Topic:** [Relational keys and geometry](/generated/api/topics/relational)

| Julia | TypeScript | Python | Rust | Go |
|---|---|---|---|---|
| not exported | not exported | `intersect_polygon` | `intersect_polygon` | not exported |


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
intersect_polygon(poly_a: object, poly_b: object, manifold: str) -> np.ndarray
```

Clip two lon-lat polygon rings; return the overlap ring (RFC §8.1).

`poly_a` / `poly_b` are `[verts, 2]` lon-lat coordinate arrays.
`manifold` is one of [`MANIFOLDS`](/generated/api/extension/python#x-manifolds) and is **required** — the geometry
interpretation is part of the op's contract and is never inferred
(CONFORMANCE_SPEC.md §5.8.4). Returns the overlap as `[n, 2]` *distinct*
lon-lat vertices (data-dependent `n`), or an empty `(0, 2)` array when the
cells do not overlap.

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-py/src/earthsci_ast/geometry.py#L601)

</div>

<div class="api-tab" data-lang="rust" data-label="Rust">
<p class="api-tab-label">Rust</p>

```rust
pub fn intersect_polygon(a: &[(f64, f64)], b: &[(f64, f64)], manifold: Manifold) -> Result<Vec<(f64, f64)>, GeometryError>
```

Clip polygon `a` against polygon `b` on the given `manifold`, returning the
overlap ring as `(lon, lat)` degree vertices. The ring is implicitly closed
and has data-dependent length; a disjoint / edge-touching clip returns an
**empty** `Vec` (§8.1, §5.8.2).

This is the evaluator for the `intersect_polygon` leaf op. `polygon_area`
over the returned ring is a separate `sum_product` FAQ (not computed here).

[Source](https://github.com/EarthSciML/EarthSciAST/blob/3d6e2fd5dd6b36cc3aa91b7f00a270c3ffb3dcf7/pkg/earthsci-ast-rs/src/geometry.rs#L131) · [Rust docs](https://docs.rs/earthsci-ast/latest/earthsci_ast/fn.intersect_polygon.html)

</div>

<div class="api-tab" data-lang="go" data-label="Go">
<p class="api-tab-label">Go</p>

<p class="api-absent">Go does not export this function.</p>

</div>

</div>
