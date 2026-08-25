---
title: "Aggregation"
description: "aggregate, its relational surface, argmin/argmax, and value invention with skolem and rank."
---

## `aggregate`

The workhorse. An `aggregate` node is a generalized Einstein-notation
expression: a semiring reduction of a body over named index sets.

| Field | Meaning |
|---|---|
| `output_idx` | Index symbols, or the integer `1` for an inserted singleton dimension. These are the *free* indices — the result's shape. |
| `expr` | The scalar body, evaluated at each index point. |
| `ranges` | Map from index symbol to the range it iterates. Either a dense tuple `[start, stop]` / `[start, step, stop]`, or `{"from": "<index set>"}` with an optional `"of"` for a ragged inner set. |
| `args` | The input array operands `expr` references. A derived cache, not a source of truth. |
| `reduce` | Shorthand naming only ⊕: `"+"` (default), `"*"`, `"max"`, `"min"`. |
| `semiring` | The named (⊕, ⊗) pair; supersedes `reduce` when present. |
| `join` | Restricts which index tuples contribute — by key equality or by envelope overlap. |
| `filter` | Boolean predicate gating which tuples contribute. |
| `distinct` / `key` | Set semantics: the node produces an *index set* rather than an array. |
| `id` | Names the node so other nodes can refer to it. |

The semantics are exactly:

```
result[output_idx] = ⊕ over (indices in expr but not in output_idx) of expr
```

### Contraction

Any index appearing in `expr` but not in `output_idx` is **contracted** —
summed over, by default. That single rule gives you matrix multiplication:

**Text**
```text
sum[i, j] (A[i, k] * B[k, j]) where {i in rows, j in cols, k in inner}
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["i", "j"],
  "ranges": { "i": { "from": "rows" }, "j": { "from": "cols" }, "k": { "from": "inner" } },
  "expr": {
    "op": "*",
    "args": [
      { "op": "index", "args": ["A", "i", "k"] },
      { "op": "index", "args": ["B", "k", "j"] }
    ]
  },
  "args": ["A", "B"]
}
```

`k` appears in the body but not the output, so it is reduced away with `+`:
`C[i,j] = Σₖ A[i,k]·B[k,j]`.

A full reduction is the same node with an empty `output_idx`:

**Text**
```text
sum[] (w[i]) where {i in cells}
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": [],
  "ranges": { "i": { "from": "cells" } },
  "expr": { "op": "index", "args": ["w", "i"] },
  "args": ["w"]
}
```

which is `Σᵢ w[i]` — a scalar.

### Semirings

`reduce` names ⊕ alone and leaves ⊗ as `*`. A column-wise maximum:

**Text**
```text
max[j] (A[i, j]) where {i in rows, j in cols}
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "reduce": "max",
  "ranges": { "i": { "from": "rows" }, "j": { "from": "cols" } },
  "expr": { "op": "index", "args": ["A", "i", "j"] },
  "args": ["A"]
}
```

`semiring` names both operators, and supersedes `reduce` where both appear. The
registry is closed:

| Semiring | ⊕ | ⊗ | Use |
|---|---|---|---|
| `sum_product` (default) | `+` | `*` | einsum, contraction, weighted sums |
| `max_product` | `max` | `*` | best-path / most-likely-explanation |
| `max_sum`, `min_sum` | `max` / `min` | `+` | shortest and longest paths |
| `bool_and_or` | `or` | `and` | relational queries; the semiring of `distinct` |

**Text**
```text
max[j] (A[i, j]) where {i in rows, j in cols} [semiring=max_product]
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "semiring": "max_product",
  "ranges": { "i": { "from": "rows" }, "j": { "from": "cols" } },
  "expr": { "op": "index", "args": ["A", "i", "j"] },
  "args": ["A"]
}
```

### Dense ranges and stencils

A dense `ranges` tuple iterates integers directly, which is how an explicit
stencil is written. The 1-D second difference, with the stencil offset as a
contracted index `k`:

**Text**
```text
sum[i] (ifelse(k == 0, -2, 1) * u[i + k]) where {i in 2:9, k in -1:1}
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["i"],
  "ranges": { "i": [2, 9], "k": [-1, 1] },
  "expr": {
    "op": "*",
    "args": [
      { "op": "ifelse", "args": [{ "op": "==", "args": ["k", 0] }, -2, 1] },
      { "op": "index", "args": ["u", { "op": "+", "args": ["i", "k"] }] }
    ]
  },
  "args": ["u"]
}
```

`i` runs over the interior only, leaving the boundary to a surrounding
[`makearray`](../arrays/) — which is where the boundary condition lives.

### Ragged ranges

`{"from": …, "of": […]}` iterates a set whose membership depends on an outer
index — the edges of a cell, the vertices of a face. This is how unstructured
connectivity is expressed without a special block:

**Text**
```text
sum[i] (flux[i, k]) where {i in cells, k in edges_of_cell(i)}
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["i"],
  "ranges": {
    "i": { "from": "cells" },
    "k": { "from": "edges_of_cell", "of": ["i"] }
  },
  "expr": { "op": "index", "args": ["flux", "i", "k"] },
  "args": ["flux"]
}
```

## The relational surface

Beyond contraction, `aggregate` carries `join`, `filter`, `distinct`, and `key`.
This is what lets grid topology, binning, and conservative regridding be
*computed* from ordinary data rather than declared in a dedicated block.

A tuple excluded by a gate contributes the **⊕ identity** — `0` for `+`, `1` for
`*`, `+∞` for `min` — not nothing. Gating a `min` reduction is therefore not the
same as gating a `+` reduction.

### `filter` — a predicate gate

**Text**
```text
sum[j] (A[i, j]) where {i in src, j in tgt} if A[i, j] > atol
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "ranges": { "i": { "from": "src" }, "j": { "from": "tgt" } },
  "filter": { "op": ">", "args": [{ "op": "index", "args": ["A", "i", "j"] }, "atol"] },
  "expr": { "op": "index", "args": ["A", "i", "j"] },
  "args": ["A"]
}
```

A **monotone** filter turns a reduction into a prefix scan. This is the discrete
cumulative sum — reach for it rather than `integral`, which has no evaluator:

**Text**
```text
sum[i] (q[k]) where {i in lev, k in lev} if k <= i
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["i"],
  "ranges": { "i": { "from": "lev" }, "k": { "from": "lev" } },
  "filter": { "op": "<=", "args": ["k", "i"] },
  "expr": { "op": "index", "args": ["q", "k"] },
  "args": ["q"]
}
```

### `join` — an equality gate

`join` restricts the enumerated tuples to those whose named key columns are
equal. It is an inner equi-join: an unmatched row contributes the ⊕ identity, so
it adds nothing under any semiring. Many-to-many is defined, not an error.

**Text**
```text
sum[j] (w[i, j] * q[i]) where {i in src, j in tgt} join(src_bin=tgt_bin)
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "semiring": "sum_product",
  "ranges": { "i": { "from": "src" }, "j": { "from": "tgt" } },
  "join": [{ "on": [["src_bin", "tgt_bin"]] }],
  "expr": {
    "op": "*",
    "args": [
      { "op": "index", "args": ["w", "i", "j"] },
      { "op": "index", "args": ["q", "i"] }
    ]
  },
  "args": ["w", "q", "src_bin", "tgt_bin"]
}
```

Key columns must compare by exact equality — integer IDs or categorical members.
**Floating-point join keys are forbidden.**

### `join` — an overlap gate

The alternative to `on` is `overlap`: a spatial broad phase that admits a
`(src, tgt)` pair only if their envelopes intersect. `src_env` and `tgt_env`
name envelope factor arrays — arity 4 for rectangles `[xmin, ymin, xmax, ymax]`,
arity 2 for points — and `eps` inflates both outward before the test.

```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "ranges": { "i": { "from": "src_cells" }, "j": { "from": "tgt_cells" } },
  "join": [{
    "overlap": {
      "src_env": ["src_W", "src_S", "src_E", "src_N"],
      "tgt_env": ["tgt_W", "tgt_S", "tgt_E", "tgt_N"],
      "eps": 0.0
    }
  }],
  "expr": { "op": "index", "args": ["A", "i", "j"] },
  "args": ["A"]
}
```

The gate is **only** the conservative broad phase — the exact test stays in
`filter` — so the materialized result is identical to the full-product path;
only the number of tuples visited changes. There is no text form for an
`overlap` join.

### `distinct` and `key` — producing an index set

With `distinct`, the node has set semantics and materializes an **index set**
rather than an array: it enumerates the unique `key` values it discovers. This
is meaningful only under `bool_and_or`. Deriving the unique undirected edges of
a mesh from its face→vertex relation:

**Text**
```text
any[] (true) where {f in faces, v in verts_of_face(f), w in verts_of_face(f)} distinct key=skolem(min(v, w), max(v, w)) id=edges [semiring=bool_and_or]
```
**JSON**
```json
{
  "op": "aggregate",
  "output_idx": [],
  "semiring": "bool_and_or",
  "distinct": true,
  "id": "edges",
  "ranges": {
    "f": { "from": "faces" },
    "v": { "from": "verts_of_face", "of": ["f"] },
    "w": { "from": "verts_of_face", "of": ["f"] }
  },
  "key": {
    "op": "skolem",
    "args": [
      { "op": "min", "args": ["v", "w"] },
      { "op": "max", "args": ["v", "w"] }
    ]
  },
  "expr": { "op": "true", "args": [] },
  "args": []
}
```

The `id` is what an [`index_sets`](../../file-structure/data-and-shape/) entry
of kind `derived` names through `from_faq` to shape variables over the result.

## `argmin` and `argmax`

Index-returning reductions: instead of the extremum of the body, they return the
**index at which it is attained**. `arg` names the contracted range symbol whose
value is returned; `expr` is the body; `ranges` is the candidate domain.

**Text**
```text
argmin[g] (cost[g]) where {g in gens}
```
**JSON**
```json
{
  "op": "argmin",
  "args": ["cost"],
  "arg": "g",
  "ranges": { "g": { "from": "gens" } },
  "expr": { "op": "index", "args": ["cost", "g"] }
}
```

**Text**
```text
argmax[g] (cost[g]) where {g in gens}
```
**JSON**
```json
{
  "op": "argmax",
  "args": ["cost"],
  "arg": "g",
  "ranges": { "g": { "from": "gens" } },
  "expr": { "op": "index", "args": ["cost", "g"] }
}
```

The returned value is a 1-based generator id, so it can be used directly as an
index. They accept the same `join` and `filter` gates as `aggregate`, which is
how a nearest-neighbour search is pruned to a candidate set.

## `skolem` — value invention

`skolem` mints a canonical **value** — a tuple, not a hash — identifying a
relation instance. It is how a document names a thing it has not enumerated: an
edge, a bin, a source/target pair.

**Text**
```text
skolem(min(u, v), max(u, v))
```
**JSON**
```json
{
  "op": "skolem",
  "args": [
    { "op": "min", "args": ["u", "v"] },
    { "op": "max", "args": ["u", "v"] }
  ]
}
```

Sorting the endpoints is what makes the key canonical: `(u,v)` and `(v,u)` mint
the same edge. A *directed* relation simply keeps its argument order.

An optional `label` field (`"edge"`, `"bin"`, `"pair"`) is documentary only — it
does not participate in the key, and the text form does not carry it.

`skolem` runs at **build/setup time**, not per timestep: the invented values are
frozen into the compiled system.

## `rank`

`rank` assigns a dense 0-based integer to each element by its position in the
sorted `distinct` sequence of its input. Where `skolem` invents the identity,
`rank` turns identities into contiguous array offsets:

**Text**
```text
area[rank(edge_key)]
```
**JSON**
```json
{
  "op": "index",
  "args": ["area", { "op": "rank", "args": ["edge_key"] }]
}
```

Together the two let a document say "group these cells by their bin key, then
give me a contiguous index over the groups that result" without knowing the
groups in advance. Like `skolem`, `rank` is build-time.
