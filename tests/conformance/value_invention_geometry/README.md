# Value Invention and Setup Geometry (`value_invention_geometry`)

Build-time value invention and setup-time polygon geometry whose products a
right-hand side reads, under every compiler. Normative text is
`CONFORMANCE_SPEC.md` §5.45.4; the runner contract is `CONFORMANCE_SPEC.md`
§5.45 and the shared [`../README.md`](../README.md) adapter discipline.

This tier is one of the **inline-test** family: each fixture is a document
that carries its own §6.6 `tests` block, and each binding runs it through its
OWN inline-test runner under a NAMED compiler. It is driven by
`scripts/run-inline-tests-conformance.py`.

## Why it exists

esm-spec §4.2 runs value invention (`distinct` over integer keys, dense IDs,
the `argmin` / `argmax` arg-witnesses, all written with `esm:std/relational.esm`
templates) and setup-time geometry (`esm:std/geometry.esm`) once, at build
time, and requires every column they read to be a **constant factor**:
a caller-supplied array, a shaped parameter with inline data, or an unknown
whose defining equation is an array `const` node. The existing fixtures
(`tests/valid/faq/*`, `tests/valid/geometry/*`) read their inputs from shaped
parameters with no data, so nothing built them end to end without a caller,
and the gaps below went unseen:

* Julia read a ragged set's `offsets` / `values` factors only under their bare
  name, so a const-defined factor (registered under its flattened name) was not
  found; with no factor at all it crashed with a `KeyError` instead of refusing.
* Julia and Python dropped an arg-witness assignment from the ODE without
  handing its buffer to the right-hand side, so a state gathering through it
  (`gx[assign[i]]`) failed; Python's flattener also qualified the arg-witness's
  own loop symbol. Rust's native compiler refused the gather, because a const
  array read at a data subscript had no tape form.
* Julia refused a polygon clip (then the `intersect_polygon` operator) whose
  rings are const-defined unknowns, and its front door's shape promotion
  treated two rings of different vertex counts as a broadcast conflict.

## Shape

| Comparison | Shape (see [`../README.md`](../README.md)) |
|---|---|
| each binding's `actual` vs the document's `expected`, by the runner's own §6.6.3 predicate | **reference-comparing**: the authored values are arithmetic (member counts, gathered coordinates, overlap areas, `exp(-t)`) |
| each binding's `actual` vs `golden/<id>.json` | **reference-comparing**: the golden is the Julia `interpreter` |
| Rust / Python `actual` vs the golden | additionally **cross-binding-agreeing** |

## The fixtures

Authored here (every producer input a `const`-defined unknown, except the
parameter-computed rings of `overlap_gated_regrid_ring_params_ode`):

| Fixture | What the right-hand side reads |
|---|---|
| `edge_enumeration_ode` | the size of the derived edge set a `distinct` producer invents over a ragged face-vertex set (5), and a contraction over each cell's ragged edge list |
| `nearest_generator_ode` | an `argmin` template arg-witness buffer, through a gather `gx[assign[i]]`, including the smallest-id tie-break |
| `bin_skolem_count_ode` | the size of a bin-key candidate-pair set (5) |
| `overlap_gated_regrid_ode` | a construction-time conservative regrid whose `faq` nodes carry an `overlap` join gate on the ring envelopes (A_ij by `overlap_area_planar`, the sliver-filtered A_j and F_tgt), four of six pairs pruned (#535; EarthSciDiscretizations `conservative_overlap_gated_*`) |
| `overlap_gated_regrid_ring_params_ode` | the same gated regrid, but each gate side is one `[pos, verts, coord]` ring stack COMPUTED from scalar grid parameters (origin and spacing), the shape of reseact's `NEIRegrid`: the gate's range symbols come from the ring stacks' position axis, and the parameters feeding the rings are baked (CONFORMANCE_SPEC §5.5.8). Rust resolved an overlap gate only over 1-D envelope factors, so it never drove a ring-stack gate, and at reseact's size its native compiler refused the narrow phase |

Referenced from `tests/valid/geometry/`: `polygon_intersection_area_padded_ring`
and `polygon_intersection_area_planar` (both `overlap_area_planar` documents,
named for the leaf they were written with). The `intersect_polygon_planar_ode`
clip document was removed with `intersect_polygon` at esm 2.0.0.

## Ledger

Empty. `native` is required for every fixture in all three bindings
(`API_SPEC.md` §5.8), so no ledger entry can excuse a `native` refusal.

## What did not move here

Documents whose producer inputs must come from a caller (`const_arrays`) are
not fixtures of an inline-test tier, which passes no data. A shaped parameter
with no data is refused by name at construction (`tests/conformance/missing_data`).
