---
title: "Geometry"
description: "polygon_intersection_area and intersect_polygon: the kernels behind conservative regridding."
---

Two geometry kernels accompany [`aggregate`](../aggregation/) in the relational
surface. Both take two polygons and clip one against the other; they differ in
what they hand back. Both run at **build/setup time**, not per timestep — their
results are frozen into the compiled system, which is what makes a conservative
regrid a build cost rather than a per-step one.

| Field | Meaning |
|---|---|
| `args` | Exactly two operands: the two polygons to clip. Each is a closed vertex ring — commonly one slice of an array shaped `[cells, verts, coord]`. |
| `manifold` | **Required.** `"planar"`, `"spherical"`, or `"geodesic"`. The op carries no default; the manifold must be declared, never inferred. |
| `id` | Optional node identity, so another node can refer to this one. |

## `polygon_intersection_area`

Returns the **scalar** area shared by the two polygons — the fused composition
of a clip and a shoelace area. It exposes no clip ring, which is what makes it
densely evaluable: a per-pair overlap factor is an ordinary `aggregate` with no
ragged intermediate.

```text
polygon_intersection_area(src_poly[i], tgt_poly[j], manifold=planar)
```
```json
{
  "op": "polygon_intersection_area",
  "args": [
    { "op": "index", "args": ["src_poly", "i"] },
    { "op": "index", "args": ["tgt_poly", "j"] }
  ],
  "manifold": "planar"
}
```

Disjoint polygons give exactly `+0.0`, never `-0.0`. That matters because a
weight matrix is built with a `+` reduction seeded at zero: a non-overlapping
pair contributes the fold identity and drops out on its own.

### The conservative-regridding weight matrix

The idiomatic use is a whole weight matrix assembled by an `aggregate` over the
source × target product. `A_ij` is the shared area of each surviving pair:

```text
sum[i, j] (polygon_intersection_area(src_poly[i], tgt_poly[j], manifold=planar)) where {i in src_cells, j in tgt_cells} join(src_bin=tgt_bin)
```
```json
{
  "op": "aggregate",
  "output_idx": ["i", "j"],
  "semiring": "sum_product",
  "ranges": { "i": { "from": "src_cells" }, "j": { "from": "tgt_cells" } },
  "join": [{ "on": [["src_bin", "tgt_bin"]] }],
  "expr": {
    "op": "polygon_intersection_area",
    "args": [
      { "op": "index", "args": ["src_poly", "i"] },
      { "op": "index", "args": ["tgt_poly", "j"] }
    ],
    "manifold": "planar"
  },
  "args": ["src_poly", "tgt_poly", "src_bin", "tgt_bin"]
}
```

The row-sum normalizer drops slivers with a `filter`, which is where the
tolerance lives — in the document, not in the kernel:

```text
sum[j] (A_ij[i, j]) where {i in src_cells, j in tgt_cells} join(src_bin=tgt_bin) if A_ij[i, j] > atol
```
```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "semiring": "sum_product",
  "ranges": { "i": { "from": "src_cells" }, "j": { "from": "tgt_cells" } },
  "join": [{ "on": [["src_bin", "tgt_bin"]] }],
  "filter": { "op": ">", "args": [{ "op": "index", "args": ["A_ij", "i", "j"] }, "atol"] },
  "expr": { "op": "index", "args": ["A_ij", "i", "j"] },
  "args": ["A_ij", "src_bin", "tgt_bin"]
}
```

`W_ij = A_ij / A_j` is then ordinary arithmetic, and the remapped field is one
more contraction. Nothing about the weights is supplied opaquely: they are
computed from the cell geometry the document already carries.

### Pruning the pair set

Both `aggregate`s above carry `join(src_bin=tgt_bin)`. Without it the aggregate
visits the full source × target product; with it, the cost is proportional to the
number of candidate pairs. The bin keys are themselves computed — quantize each
cell's representative coordinate and mint a key from the two integers:

```text
sum[i] (skolem(floor(src_lon[i] / dx), floor(src_lat[i] / dy))) where {i in src_cells}
```
```json
{
  "op": "aggregate",
  "output_idx": ["i"],
  "ranges": { "i": { "from": "src_cells" } },
  "expr": {
    "op": "skolem",
    "args": [
      { "op": "floor", "args": [{ "op": "/", "args": [{ "op": "index", "args": ["src_lon", "i"] }, "dx"] }] },
      { "op": "floor", "args": [{ "op": "/", "args": [{ "op": "index", "args": ["src_lat", "i"] }, "dy"] }] }
    ]
  },
  "args": ["src_lon", "src_lat"]
}
```

Note that the float coordinate enters only the `floor`. The join key itself is
an integer [`skolem`](../aggregation/) term — join keys must compare by exact
equality, and floating-point keys are forbidden.

An [`overlap` join](../aggregation/) is the alternative broad phase: it gates on
envelope intersection rather than bin equality, which handles cells that straddle
a bin boundary without a halo.

## `intersect_polygon`

Returns the clipped **region** rather than its area — the intersection polygon
itself, a ring of data-dependent length. Reach for it when the downstream
computation needs the geometry (a centroid, a further clip); prefer
`polygon_intersection_area` when all you need is the measure, because the ragged
ring it avoids is what forces a non-dense evaluation path.

```text
intersect_polygon(src_poly[i], tgt_poly[j], manifold=spherical, id=overlap_clip)
```
```json
{
  "op": "intersect_polygon",
  "args": [
    { "op": "index", "args": ["src_poly", "i"] },
    { "op": "index", "args": ["tgt_poly", "j"] }
  ],
  "manifold": "spherical",
  "id": "overlap_clip"
}
```

## Manifolds

| `manifold` | Edges | When |
|---|---|---|
| `planar` | straight lines in the coordinate plane | a small projected patch. Wrong at the poles and across the antimeridian. |
| `spherical` | great circles on the unit sphere | global lon-lat meshes — the correct default for earth grids. |
| `geodesic` | ellipsoidal geodesics | when the ellipsoid matters. |

Two bindings' results may be compared only under the **same** declared manifold,
and the flag is matched exactly: it is a discrete label, not a tolerance-based
quantity.

**The great-circle assumption has a cost at the poles.** Under `spherical` and
`geodesic`, *every* edge is modelled as a geodesic — including a lon-lat edge
running along a parallel, which is a small circle, not a great circle. A coarse
polar cell therefore carries a real area error, growing with the square of the
cell's longitude width. The kernels offer an opt-in densification of parallel
edges into short segments to reduce it; it is **off by default**, so default clip
behaviour is unchanged.

Spherical and geodesic clipping need the geometry extension loaded — `spherely`
in Python, the GeometryOps extension in Julia. Without it, a document requesting
one raises rather than silently computing a planar answer.
