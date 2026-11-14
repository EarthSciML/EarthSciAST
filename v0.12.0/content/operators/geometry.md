---
title: "Geometry"
description: "Polygon overlap areas for conservative regridding, written with the standard-library geometry templates."
---

The format has no geometry operator. The overlap area of two cells — the
quantity a conservative regrid is built from — is an expression template in
`esm:std/geometry.esm`, written entirely in core operators and imported like
any other [template](../../templates/). Its results are computed at
**build/setup time** when its inputs are constant, so a conservative regrid is
a build cost rather than a per-step one.

| Template | Parameters | Value |
|---|---|---|
| `overlap_area_planar` | `ring_a`, `cell_a`, `nv_a`, `ring_b`, `cell_b`, `nv_b` | overlap area of cell `cell_a` of the `[cells, nv_a, 2]` ring stack `ring_a` and cell `cell_b` of `ring_b`, with straight edges, in squared coordinate units |
| `overlap_area_spherical` | the same, over `[cells, nv, 3]` stacks of unit vectors | the same with great-circle edges on the unit sphere, in steradians |
| `lonlat_to_unit` | `ring`, `cell`, `vert`, `comp` | component `comp` (1, 2, 3) of the unit vector of vertex `vert` of a `[cells, verts, 2]` lon-lat stack in degrees |

Each polygon operand is one cell of a ring stack: the stack, the cell index
(usually a loop symbol of the enclosing `faq`) and the number of vertex slots,
an integer used as a `faq` `ranges` bound. Cells are convex; a ring may run
either way round and may carry repeated vertices (a closing duplicate, or the
padding of a mixed-valence mesh), which contribute exactly zero. The method and
its tolerances are in the [standard library](../../standard_library/) page.

Disjoint cells give exactly zero, so in a weight matrix built with a `+`
reduction a non-overlapping pair drops out on its own.

## The conservative-regridding weight matrix

The idiomatic use is a whole weight matrix assembled by a `faq` over the
source × target product. `A_ij` is the shared area of each surviving pair:

**JSON**
```json
{
  "expression_template_imports": [{ "ref": "esm:std/geometry.esm" }],
  "equations": [
    {
      "lhs": "A_ij",
      "rhs": {
        "op": "faq", "args": [], "output_idx": ["i", "j"],
        "semiring": "sum_product",
        "ranges": { "i": { "from": "src_cells" }, "j": { "from": "tgt_cells" } },
        "join": [{ "on": [["src_bin", "tgt_bin"]] }],
        "expr": {
          "op": "apply_expression_template", "args": [], "name": "overlap_area_planar",
          "bindings": { "ring_a": "src_poly", "cell_a": "i", "nv_a": 4,
                        "ring_b": "tgt_poly", "cell_b": "j", "nv_b": 4 }
        }
      }
    }
  ]
}
```

The row-sum normalizer drops slivers with a `filter`, which is where the
tolerance lives — in the document, not in the template:

**Text**
```text
sum[j] (A_ij[i, j]) where {i in src_cells, j in tgt_cells} join(src_bin=tgt_bin) if A_ij[i, j] > atol
```
**JSON**
```json
{
  "op": "faq",
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

## Pruning the pair set

Both `faq` nodes above carry `join(src_bin=tgt_bin)`. Without it the `faq`
visits the full source × target product; with it, the cost is proportional to
the number of candidate pairs. The bin keys are themselves computed — quantize
each cell's representative coordinate:

**Text**
```text
sum[i] (floor(src_lon[i] / dx)) where {i in src_cells}
```
**JSON**
```json
{
  "op": "faq",
  "output_idx": ["i"],
  "ranges": { "i": { "from": "src_cells" } },
  "expr": { "op": "floor", "args": [{ "op": "/", "args": [{ "op": "index", "args": ["src_lon", "i"] }, "dx"] }] },
  "args": ["src_lon"]
}
```

The float coordinate enters only the `floor`: join keys compare by exact
equality, so they are integers, and floating-point keys are forbidden. A
two-axis bin is either one integer column per axis, joined with one `on` pair
per column, or a single column built with `pair_key` from
`esm:std/relational.esm` (see [aggregation](../aggregation/)).

An [`overlap` join](../aggregation/) is the alternative broad phase: it gates on
envelope intersection rather than bin equality, which handles cells that
straddle a bin boundary without a halo.

## On the sphere

For a global lon-lat mesh use `overlap_area_spherical`. Build each unit-vector
stack once per cell, `src_xyz[c, v, d] = lonlat_to_unit(src_poly, c, v, d)` as a
`faq` over the cells, the vertex slots and a 3-element component axis, and pass
`src_xyz` and `tgt_xyz` to the template. Doing the trigonometry once per vertex
rather than once per use inside the pair body also keeps the expanded body
small.

Every edge is a great-circle arc — including a lon-lat edge running along a
parallel, which is a small circle. A coarse polar cell therefore carries a real
area error, growing with the square of the cell's longitude width; densify such
edges in the ring data if it matters. Each spherical cell must lie within a
hemisphere.
