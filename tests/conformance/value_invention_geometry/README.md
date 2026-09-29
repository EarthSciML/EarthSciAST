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

esm-spec §4.2 runs value invention (`skolem`, `distinct`, `rank`, the
`argmin` / `argmax` arg-witnesses) and the `intersect_polygon` clip once, at
build time, and requires every column they read to be a **constant factor**:
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
* Julia refused an `intersect_polygon` whose rings are const-defined unknowns,
  and its front door's shape promotion treated two rings of different vertex
  counts as a broadcast conflict.

## Shape

| Comparison | Shape (see [`../README.md`](../README.md)) |
|---|---|
| each binding's `actual` vs the document's `expected`, by the runner's own §6.6.3 predicate | **reference-comparing**: the authored values are arithmetic (member counts, gathered coordinates, overlap areas, `exp(-t)`) |
| each binding's `actual` vs `golden/<id>.json` | **reference-comparing**: the golden is the Julia `interpreter` |
| Rust / Python `actual` vs the golden | additionally **cross-binding-agreeing** |

## The fixtures

Authored here (every producer input a `const`-defined unknown):

| Fixture | What the right-hand side reads |
|---|---|
| `edge_enumeration_ode` | the size of the derived edge set a `distinct` producer invents over a ragged face-vertex set (5), and a contraction over each cell's ragged edge list |
| `nearest_generator_ode` | an `argmin` arg-witness buffer, through a gather `gx[assign[i]]`, including the smallest-id tie-break |
| `bin_skolem_count_ode` | the size of a bin-skolem candidate-pair set (5) |

Referenced from `tests/valid/geometry/`: `intersect_polygon_planar_ode`
(a clip of two const rings, area 1, `tracer = exp(-t)`),
`polygon_intersection_area_padded_ring` and `polygon_intersection_area_planar`.

## Ledger

One named exclusion: Python's `native` compiler refuses `edge_enumeration_ode`
(a ragged contracted range has no form there). Python native is outside the
native-coverage plan; its interpreter answers.

## What did not move here

Documents whose producer inputs must come from a caller (`const_arrays`) are
not fixtures of an inline-test tier, which passes no data. A shaped parameter
with no data is refused by name at construction (`tests/conformance/missing_data`).
