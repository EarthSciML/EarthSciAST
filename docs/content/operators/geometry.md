---
title: "Geometry"
description: "intersect_polygon and polygon_intersection_area."
---

Two geometry kernels accompany [`aggregate`](../aggregation/) in the
relational surface. Both run at **build/setup time**, not per timestep: their
results are frozen into the compiled system, which is what makes a conservative
regrid a build cost rather than a per-step one.

## `polygon_intersection_area`

Returns the area of the intersection of two polygons. This is the kernel behind
conservative regridding: the weight relating a source cell to a target cell is
the area they share.

Both operands are polygon *ring* references — a stack of vertex coordinates —
and a `manifold` selects the geometry: planar, or spherical/geodesic.

Disjoint polygons give exactly `+0.0`, never `-0.0`, which matters because a
regrid weight matrix is usually built with a `+` reduction seeded at zero: a
non-overlapping pair contributes the fold identity and drops out.

The idiomatic use is a weight matrix built by an `aggregate` over the source ×
target product, with an `overlap` join restricting the pairs actually visited to
those whose envelopes intersect. Without the join the aggregate visits the full
product; with it, the cost is proportional to the number of candidate pairs.

## `intersect_polygon`

Returns the intersecting *region* rather than its area — the clipped polygon
itself. Use it when the downstream computation needs the geometry (a centroid, a
further clip) rather than just the overlap measure.

## Spherical geometry

The `manifold` argument selects the metric. Planar clipping is exact rational
arithmetic on the coordinates; spherical/geodesic clipping requires the geometry
extension to be loaded (`spherely` in Python, the GeometryOps extension in
Julia). Without it, a document requesting a spherical manifold raises rather
than silently computing a planar answer.

## Tolerances

Area comparisons in the surrounding aggregate are made against an absolute
tolerance, not exact equality — a sliver of intersection below the tolerance is
treated as no intersection. That threshold belongs to the document, not to the
kernel: it is expressed as the `eps` of the `overlap` join or the `atol` of the
filter that consumes the weights.
