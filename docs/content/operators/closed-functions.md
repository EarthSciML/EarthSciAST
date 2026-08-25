---
title: "Closed functions"
description: "The fn op and the closed function registry."
---

## `fn`

Invokes a function from the **closed function registry**. The set of valid names
is fixed by the specification version — there is no per-file declaration of new
functions and no handler lookup.

| Field | Meaning |
|---|---|
| `name` | Dotted path of a registry function, e.g. `"interp.linear"`. |
| `args` | Sub-expressions, evaluated in the current context and passed positionally. |

```json
{ "op": "fn", "name": "datetime.julian_day", "args": ["t_utc"] }
```

The return value takes the place of the `fn` node in the enclosing expression.

A `name` outside the registry is rejected at load with
`unknown_closed_function`; arity and type compatibility are checked against the
registry entry's signature.

## Why closed

The format targets bit-exact-where-possible agreement across five bindings. Any
extension point that lets an author register a per-binding handler defeats that:
each binding ends up with its own implementation and they disagree silently at
the edges. So the registry is **closed by construction**, and every entry is
**pure** — same inputs, same output, no hidden state. Adding a function requires
a specification revision.

## The registry

### `datetime.*` — calendar decomposition

All take a UTC time and return an integer component.

| Name | Result |
|---|---|
| `datetime.year` | calendar year |
| `datetime.month` | 1–12 |
| `datetime.day` | day of month |
| `datetime.hour` | 0–23 |
| `datetime.minute` | 0–59 |
| `datetime.second` | 0–59 |
| `datetime.day_of_year` | 1–366 |
| `datetime.is_leap_year` | `1` or `0` |
| `datetime.julian_day` | Julian day number |

The calendar is proleptic Gregorian and is computed as **branch-free
arithmetic**, not by calling a host date library. That is what lets it be traced
onto a device and differentiated, and what keeps the bindings in agreement.
Resolution is milliseconds: the sub-millisecond remainder of the input is
truncated (toward zero), matching the reference implementation.

```json
{ "op": "fn", "name": "datetime.hour", "args": ["t_utc"] }
```

### `interp.*` — table interpolation

| Name | Arguments | Result |
|---|---|---|
| `interp.linear` | `(table, axis, x)` | 1-D linear interpolation of `table` over `axis` at `x` |
| `interp.bilinear` | `(table, axis_x, axis_y, x, y)` | 2-D bilinear interpolation |
| `interp.searchsorted` | `(x, xs)` | index of `x` within the sorted `xs` |

Outside the axis range, `interp.linear` and `interp.bilinear` **clamp** to the
edge value rather than extrapolating. With `table = [10, 20, 30]` over
`axis = [0, 1, 2]`, `interp.linear` gives `15.0` at `x = 0.5`, `10.0` at
`x = -5`, and `30.0` at `x = 99`.

`interp.searchsorted` returns a **1-based** index and saturates: for
`xs = [0.0, 0.5, 1.0, 1.5]` it gives `3.0` at `x = 0.7`, `1.0` below the range,
and `5.0` (one past the end) above it. That makes it the natural way to turn a
continuous quantity into a categorical one:

```json
{
  "op": "index",
  "args": [
    "deposition_table",
    { "op": "fn",
      "name": "interp.searchsorted",
      "args": ["sza", { "op": "const", "value": [0.0, 0.5, 1.0, 1.5], "args": [] }] }
  ]
}
```

The table and axis arguments are ordinarily `const` nodes or references to
[`function_tables`](../../file-structure/data-and-shape/) entries. Large tables
belong in `function_tables` or a data source, not inline.

## `call`

`call` is the generic invocation node. In practice `fn` is what you write —
`call` exists for the machinery that builds and rewrites expression trees.

## Choosing between `fn` and plain operators

The authoring policy is **AST first, registry second**. If an operation can be
written with the arithmetic and elementary operators, write it that way: it
stays visible to canonicalization, common-subexpression elimination,
dimensional analysis, and rewrite rules. Reach for `fn` when the operation is
genuinely a primitive the AST cannot express — a calendar decomposition, a table
lookup — not to shorten an expression you could have written out.
