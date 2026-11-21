---
title: "Closed functions"
description: "The fn op, the closed function registry, and table_lookup."
---

## `fn`

Invokes a function from the **closed function registry**. The set of valid names
is fixed by the specification version — there is no per-file declaration of new
functions and no handler lookup.

| Field | Meaning |
|---|---|
| `name` | Dotted path of a registry function, e.g. `"interp.linear"`. |
| `args` | Sub-expressions, evaluated in the current context and passed positionally. |

**Text**
```text
datetime.julian_day(t_utc)
```
**JSON**
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

**Text**
```text
datetime.hour(t_utc)
```
**JSON**
```json
{ "op": "fn", "name": "datetime.hour", "args": ["t_utc"] }
```

The calendar is proleptic Gregorian and is computed as **branch-free
arithmetic**, not by calling a host date library. That is what lets it be traced
onto a device and differentiated, and what keeps the bindings in agreement.
Resolution is milliseconds: the sub-millisecond remainder of the input is
truncated toward zero.

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

**Text**
```text
deposition_table[interp.searchsorted(sza, [0, 0.5, 1, 1.5])]
```
**JSON**
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

The table and axis arguments are ordinarily `const` nodes. Large tables belong
in `function_tables` or a data source, not inline.

## `table_lookup`

Evaluates a **sampled function table** declared in the top-level
`function_tables` block. It is sugar: a `table_lookup` lowers at load to the
equivalent `interp.linear` / `interp.bilinear` / `index` form and must be
bit-equivalent to it.

| Field | Meaning |
|---|---|
| `table` | The id of a `function_tables` entry. |
| `axes` | Map from each declared axis name to the scalar input expression supplying that coordinate. Every declared axis must appear; extras are rejected. |
| `output` | Which output of a multi-output table to return — a 0-based integer or a name from the table's `outputs`. Optional for single-output tables. |
| `args` | MUST be empty — the per-axis expressions live in `axes`. |

Its text surface is bracket-and-axis, not a call:

**Text**
```text
visc[T=temp]
```
**JSON**
```json
{ "op": "table_lookup", "table": "visc", "axes": { "T": "temp" }, "args": [] }
```

A two-axis table with an output selector:

**Text**
```text
k_rate[T=temp, p=pres]:1
```
**JSON**
```json
{ "op": "table_lookup", "table": "k_rate", "axes": { "T": "temp", "p": "pres" }, "output": 1, "args": [] }
```

The table it refers to declares its axes, its interpolation kind, its
out-of-bounds policy, and its data:

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "TableLookupExample" },
  "function_tables": {
    "visc": {
      "description": "Dynamic viscosity of air as a function of temperature",
      "axes": [{ "name": "T", "values": [250.0, 275.0, 300.0] }],
      "interpolation": "linear",
      "out_of_bounds": "clamp",
      "data": [1.60e-5, 1.73e-5, 1.85e-5]
    }
  },
  "models": {
    "Air": {
      "variables": {
        "temp": { "type": "parameter", "units": "K", "default": 288.0 },
        "mu": { "type": "unknown", "units": "Pa*s" }
      },
      "equations": [
        { "lhs": "mu",
          "rhs": { "op": "table_lookup", "table": "visc", "axes": { "T": "temp" }, "args": [] } }
      ]
    }
  }
}
```

A reference to an undeclared table is rejected at load with
`table_lookup_unknown_table`; a missing or extra axis with
`table_lookup_axis_name_mismatch`; an out-of-range output with
`table_lookup_output_out_of_range`.

## Choosing between `fn` and plain operators

The authoring policy is **AST first, registry second**. If an operation can be
written with the arithmetic and elementary operators, write it that way: it
stays visible to canonicalization, common-subexpression elimination,
dimensional analysis, and rewrite rules. Reach for `fn` when the operation is
genuinely a primitive the AST cannot express — a calendar decomposition, a table
lookup — not to shorten an expression you could have written out. A `fn` that
only re-implements `min`/`max` clamping in disguise is rejected in review.
