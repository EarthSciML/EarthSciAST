---
title: "Constants and conditionals"
description: "const, enum, ifelse, Pre, and the niladic constants."
---

## `ifelse`

Arity 3: `ifelse(condition, then, else)`. The condition follows the usual
convention — zero is false, non-zero is true — and the result is `then` when it
holds, `else` otherwise.

```json
{
  "op": "ifelse",
  "args": [
    { "op": ">=", "args": ["a", 0] },
    { "op": "sqrt", "args": ["a"] },
    0
  ]
}
```
With `a=9` → `3.0`. With `a=-1` → `0.0`.

**Laziness is not guaranteed.** The scalar evaluators walk only the taken
branch, so the example above is safe on a scalar. The **array evaluators are
eager by construction**: they broadcast over lanes, and per-lane laziness would
need masked evaluation. Inside an `arrayop`, both branches are evaluated, so
`ifelse` will *not* protect `sqrt` from a negative input. This is a deliberate,
documented divergence between the scalar and array paths — write the guard into
the argument instead:

```json
{ "op": "sqrt", "args": [{ "op": "max", "args": ["a", 0] }] }
```

## `Pre`

Arity 1. Used inside event affects: `Pre(x)` is the value `x` had **before** the
event fired, so an affect can reference the pre-event state while assigning the
post-event one. It has no meaning outside an event context. See
[coupling and events](../../coupling/).

## `const`

`args` MUST be empty; the value lives in a `value` field, which may be any JSON
value — a number, an integer, or a nested array.

```json
{ "op": "const", "value": [0.0, 0.5, 1.0], "args": [] }
```

`const` exists for AST positions that need a literal **array** where a bare
number will not do: an `index` lookup table, an `interp.searchsorted` query
vector, a small coefficient set. A scalar literal does not need it — just write
the number.

Keep these small. A large table belongs in a
[`data_sources`](../../file-structure/data-and-shape/) entry, not inline in the
expression tree.

## `enum`

Resolves a symbol from the document's [`enums`](../../file-structure/data-and-shape/)
registry to its integer, so a categorical lookup reads as a name rather than a
magic number. `args` is a two-element array of **string literals**, not
sub-expressions: `[enum_name, symbol]`.

```json
{ "op": "enum", "args": ["land_use_class", "water"] }
```

It is lowered at load to the integer, exactly as if you had written
`{"op": "const", "value": 9}`. An unknown enum or symbol is rejected at load
with `unknown_enum` / `unknown_enum_symbol`.

The idiomatic use is a categorical index into a tabulated array:

```json
{
  "op": "index",
  "args": [
    "r_c_table",
    { "op": "enum", "args": ["land_use_class", "deciduous_forest"] },
    { "op": "enum", "args": ["season", "summer"] }
  ]
}
```

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "EnumExample" },
  "enums": {
    "land_use_class": { "urban": 1, "grassland": 2, "water": 3 }
  },
  "models": {
    "Surface": {
      "variables": {
        "z0": { "type": "unknown", "units": "m" }
      },
      "equations": [
        { "lhs": "z0",
          "rhs": { "op": "index",
                   "args": [
                     { "op": "const", "value": [1.0, 0.03, 0.0001], "args": [] },
                     { "op": "enum", "args": ["land_use_class", "water"] }
                   ] } }
      ]
    }
  }
}
```

Enum values are file-local: two documents may number the same symbol
differently, and nothing outside the file may depend on the integer.

## Niladic constants — use with care

The operator registry carries `pi`, `π`, `e`, `true`, and `false` as zero-arity
operators. **They are not part of the specification's operator tables, they
appear nowhere in the conformance corpus, and the bindings disagree about them:**

| Op | Julia | Python |
|---|---|---|
| `pi`, `e` | evaluates | rejected as an unlowered rewrite-target |
| `true`, `false` | rejected | evaluates to `1.0` / `0.0` |

Do not use them in a document you intend to be portable. Write the numeric
literal instead — `3.141592653589793`, or `1` and `0` for the booleans.
