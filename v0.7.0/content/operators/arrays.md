---
title: "Arrays"
description: "index, makearray, reshape, transpose, concat, broadcast."
---

Array shape comes from a variable's `shape` — an ordered list of
[index-set](../../file-structure/data-and-shape/) names. Array-level expressions
align their operands **by index-set name** and replicate along axes an operand
does not declare; an operand carrying a set the result is not shaped over is
rejected with `array_shape_mismatch`.

## `index`

Element or sub-array access. `args[0]` is the array; `args[1..]` are the index
expressions.

**Text**
```text
C[i, j]
```
**JSON**
```json
{ "op": "index", "args": ["C", "i", "j"] }
```

Indices are expressions, so arithmetic on them is ordinary:

**Text**
```text
C[i - 1]
```
**JSON**
```json
{ "op": "index", "args": ["C", { "op": "-", "args": ["i", 1] }] }
```

which is the `C[i-1]` of a stencil. Indices are **1-based**.

Fewer indices than axes selects a sub-array rather than an element — which is
how one cell's vertex ring is handed to a
[geometry kernel](../geometry/) from an array shaped `[cells, verts, coord]`.

The array operand may itself be an expression, commonly a `const` table:

```json
{
  "op": "index",
  "args": [
    { "op": "const", "value": [1.0, 0.03, 0.0001], "args": [] },
    { "op": "enum", "args": ["land_use_class", "water"] }
  ]
}
```

## `makearray`

Assembles an array from a sequence of sub-region assignments — "default fill,
then override".

| Field | Meaning |
|---|---|
| `regions` | Array of regions. Each region is a list of `[start, stop]` integer pairs, one per output dimension, **both endpoints inclusive**. |
| `values` | Array of expressions, same length as `regions`. Each fills the corresponding region. |
| `args` | Conventionally `[]` — the operands live inside `values`. |

A scalar `values` entry is broadcast across its region; an array-valued entry
must match the region's shape.

**Later regions overwrite earlier ones.** That is what makes the
interior/boundary idiom work — fill the interior with a stencil, then overwrite
the faces with the boundary condition. There is no boundary-condition block
anywhere in the format; this is where a BC lives:

**Text**
```text
makearray([2:9] = k * C[i], [1:1] = 0, [10:10] = 0)
```
**JSON**
```json
{
  "op": "makearray",
  "regions": [[[2, 9]], [[1, 1]], [[10, 10]]],
  "values": [
    { "op": "*", "args": ["k", { "op": "index", "args": ["C", "i"] }] },
    0,
    0
  ],
  "args": []
}
```

Region bounds may be [metaparameter](../../file-structure/data-and-shape/)
expressions, folded to integers at load — which is what lets one document serve
many resolutions.

**Empty and inverted bounds.** `[start, stop]` with `stop == start - 1` is the
canonical **empty** region: it covers nothing, contributes nothing, and its
`values` entry is never consulted. This is legal and load-clean — it is exactly
what a metaparameter-folded interior region produces at the minimum admissible
extent (`[2, N-1]` at `N = 2` folds to `[2, 1]`, leaving the faces to cover the
axis). A pair with `stop < start - 1` is **inverted** and is rejected at load
with `makearray_region_inverted`, because it almost always means an interior
stencil was instantiated below its scheme's minimum extent.

## `reshape`

Reshapes `args[0]` to the target `shape` field. Entries are integers or symbolic
dimension names.

**Text**
```text
reshape(v, [lon, lat])
```
**JSON**
```json
{ "op": "reshape", "args": ["v"], "shape": ["lon", "lat"] }
```

## `transpose`

Axis permutation of `args[0]`. With no `perm`, axes are reversed:

**Text**
```text
transpose(A)
```
**JSON**
```json
{ "op": "transpose", "args": ["A"] }
```

`perm` is a list of **0-based** axis indices giving the new order:

**Text**
```text
transpose(A, [1, 0])
```
**JSON**
```json
{ "op": "transpose", "args": ["A"], "perm": [1, 0] }
```

## `concat`

Concatenates its operand arrays along `axis`, which is **0-based**. All operands
must have identical shape on every other axis.

**Text**
```text
concat(A, B, axis=1)
```
**JSON**
```json
{ "op": "concat", "args": ["A", "B"], "axis": 1 }
```

## `broadcast`

Applies the scalar operator named in `fn` elementwise to its operands. It means
exactly what `{"op": fn, "args": …}` means, applied per element — including at
arity one, where a one-operand `broadcast` applies `fn` **unarily** and must not
be treated as the identity on its operand.

```json
{ "op": "broadcast", "args": ["A", "B"], "fn": "*" }
```

`fn` must name a **scalar** operator — the pointwise ones: arithmetic
(including [`neg`](../arithmetic-comparison-logic/)), the elementary functions,
comparisons, the logical connectives, and `ifelse`. It may not name a
non-pointwise op, and `args` must satisfy that operator's arity. There is no
default: an absent or invalid `fn` is rejected with `invalid_broadcast_fn`.

`broadcast` has no text form of its own — it prints as the operator it applies.

Most of the time you do not need it: ordinary elementwise operators already
broadcast over array operands by index-set alignment. Reach for it when the
operator is chosen by a template parameter, or to make the elementwise intent
explicit.
