---
title: "Aggregation"
description: "aggregate, arrayop, and value invention with skolem."
---

## `aggregate`

The workhorse. An `aggregate` node is a generalized Einstein-notation
expression: a semiring reduction of a body over named index sets.

| Field | Meaning |
|---|---|
| `output_idx` | Array of index symbols, or the integer `1` for an inserted singleton dimension. These are the *free* indices — the result's shape. |
| `expr` | The scalar body, evaluated at each index point. |
| `reduce` | `"+"` (default), `"*"`, `"max"`, or `"min"`. Applied to indices in `expr` but not in `output_idx`. |
| `ranges` | Optional map from index symbol to `[start, stop]` or `[start, step, stop]`. Unlisted indices are inferred from operand shapes. |
| `args` | The input array operands `expr` references. |

The semantics are exactly:

```
result[output_idx] = reduce over (indices in expr but not in output_idx) of expr
```

### Contraction

Any index appearing in `expr` but not in `output_idx` is **contracted** —
summed over, by default. That single rule gives you matrix multiplication:

```json
{
  "op": "aggregate",
  "output_idx": ["i", "j"],
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

```json
{
  "op": "aggregate",
  "output_idx": [],
  "expr": { "op": "index", "args": ["w", "i"] },
  "args": ["w"]
}
```

which is `Σᵢ w[i]` — a scalar.

Changing `reduce` changes the semiring:

```json
{
  "op": "aggregate",
  "output_idx": ["j"],
  "reduce": "max",
  "expr": { "op": "index", "args": ["A", "i", "j"] },
  "args": ["A"]
}
```

is a column-wise maximum.

### Stencils

With no contracted index, `aggregate` is a **map** — which is how an explicit
stencil is written. A 2-D five-point Laplacian:

```json
{
  "op": "aggregate",
  "output_idx": ["i", "j"],
  "expr": {
    "op": "+",
    "args": [
      { "op": "index", "args": ["u", { "op": "+", "args": ["i", 1] }, "j"] },
      { "op": "index", "args": ["u", { "op": "-", "args": ["i", 1] }, "j"] },
      { "op": "index", "args": ["u", "i", { "op": "+", "args": ["j", 1] }] },
      { "op": "index", "args": ["u", "i", { "op": "-", "args": ["j", 1] }] },
      { "op": "*", "args": [-4, { "op": "index", "args": ["u", "i", "j"] }] }
    ]
  },
  "ranges": { "i": [2, 9], "j": [2, 9] },
  "args": ["u"]
}
```

`ranges` restricts `i` and `j` to the interior, leaving the boundary to a
surrounding [`makearray`](../arrays/).

### The relational surface

Beyond `sum_product`, `aggregate` carries a relational surface — `semiring`,
`from`/`of` ranges, `join`, `distinct`, `key`, and `filter` — which is what lets
grid topology, binning, and conservative regridding be expressed declaratively
rather than being declared in a `grids` block. `filter` gates which tuples
contribute; `join` restricts the enumerated tuples to those satisfying a key
equality or a geometric `overlap` predicate.

A tuple excluded by a gate contributes the **fold identity** — `0` for `+`, `1`
for `*`, `+∞` for `min` — not nothing. This matters: gating a `min` reduction is
not the same as gating a `+` reduction.

## `arrayop`

The array-producing sibling of `aggregate`, carrying the same index machinery.
Where `aggregate` is written as an expression producing a value, `arrayop`
carries an explicit output shape and is what a whole-array equation lowers to.

## `skolem` — value invention

`skolem` invents index values at build time: it maps a tuple of key expressions
to a fresh, dense, deterministic integer identifier. It is how a binning
operation names its bins without an author having to enumerate them.

It runs at **build/setup time**, not per timestep — the invented identifiers are
frozen into the compiled system.

`rank` is its companion, assigning dense ordinals to a set of values. Together
they let a document say "group these cells by their bin key and give me a
contiguous index over the groups that result" without knowing the groups in
advance.
