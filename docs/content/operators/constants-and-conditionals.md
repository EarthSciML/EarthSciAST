---
title: "Constants and conditionals"
description: "ifelse, Pre, const, true, enum, and the niladic constants."
---

## `ifelse`

Arity 3: `ifelse(condition, then, else)`. The condition follows the usual
convention — zero is false, non-zero is true — and the result is `then` when it
holds, `else` otherwise.

```text
ifelse(a >= 0, sqrt(a), 0)
```
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
need masked evaluation. Inside an [`aggregate`](../aggregation/) both branches
are evaluated, so `ifelse` will *not* protect `sqrt` from a negative input. This
is a deliberate, documented divergence between the scalar and array paths —
write the guard into the argument instead:

```text
sqrt(max(a, 0))
```
```json
{ "op": "sqrt", "args": [{ "op": "max", "args": ["a", 0] }] }
```

`ifelse` on an index symbol is also how a stencil's weights are written without
enumerating them — see the second difference on the
[aggregation](../aggregation/) page.

## `Pre`

Arity 1. Used inside event affects: `Pre(x)` is the value `x` had **before** the
event fired, so an affect can reference the pre-event state while assigning the
post-event one. It has no meaning outside an event context. See
[coupling and events](../../coupling/).

```text
Pre(x)
```
```json
{ "op": "Pre", "args": ["x"] }
```

## `true`

The nullary boolean literal. `args` must be empty. Its use is as an
always-true predicate — the body of an index-set-producing
[`aggregate`](../aggregation/), or a join gate that admits everything.

```text
true
```
```json
{ "op": "true", "args": [] }
```

There is no `false` operator; write `0`.

## `const`

`args` MUST be empty; the value lives in a `value` field, which may be any JSON
value — a number, an integer, or a nested array.

```text
[0, 0.5, 1]
```
```json
{ "op": "const", "value": [0.0, 0.5, 1.0], "args": [] }
```

`const` exists for AST positions that need a literal **array** where a bare
number will not do: an `index` lookup table, an `interp.searchsorted` query
vector, a small coefficient set, an in-file polygon ring. A scalar literal does
not need it — just write the number.

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

`enum` has no distinct text form: it prints as a dotted name, which re-parses as
a scoped variable reference.

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

In a whole document:

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

## Niladic constants — do not use

The Julia evaluator's dispatch table carries `pi`, `π`, `e`, `true`, and `false`
as zero-arity operators. Of these, **only `true` is specified**: the other four
appear in no operator table in `esm-spec.md`, in no schema list, and nowhere in
the conformance corpus — so nothing holds the bindings to a shared meaning, and
they do not agree. Python's expression parser reads `pi`, `e`, and `false` as
ordinary variable *references* rather than operators; the Rust operator registry
asserts that `false` is not a registered operator at all, alongside `pow`, `**`,
`power`, and `=`.

Write the numeric literal instead — `3.141592653589793` for π, `0` for false.
For a true predicate use `true`, which is specified and is described above.
