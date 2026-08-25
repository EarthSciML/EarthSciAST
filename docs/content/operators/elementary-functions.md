---
title: "Elementary functions"
description: "The 23 scalar mathematical functions."
---

All of these are elementwise: applied to an array operand they act per element.

## Exponential and logarithmic

| Op | Arity | Result |
|---|---|---|
| `exp` | 1 | e raised to the argument |
| `log` | 1 | natural logarithm |
| `log10` | 1 | base-10 logarithm |
| `sqrt` | 1 | square root |

```json
{ "op": "exp", "args": [0] }
```
→ `1.0`.

```json
{ "op": "sqrt", "args": [9] }
```
→ `3.0`.

The classic Arrhenius rate:

```json
{
  "op": "*",
  "args": [
    "A",
    { "op": "exp",
      "args": [{ "op": "/", "args": [{ "op": "-", "args": ["Ea"] },
                                     { "op": "*", "args": ["R", "T"] }] }] }
  ]
}
```

**Dimensions.** `exp`, `log`, `log10` require a dimensionless argument and
return a dimensionless result. `sqrt` halves its argument's dimension.

## Trigonometric

| Op | Arity | Result |
|---|---|---|
| `sin`, `cos`, `tan` | 1 | circular functions; argument is an angle |
| `asin`, `acos` | 1 | inverse circular; result is an angle |
| `atan` | 1 or 2 | one argument: arctangent. Two: same as `atan2` |
| `atan2` | 2 | `atan2(y, x)` — the quadrant-aware arctangent, `args[0]` is `y` |

```json
{ "op": "atan2", "args": ["y", "x"] }
```
With `y=1, x=1` → `0.7853981633974483` (π/4).

Note the argument order: `y` first, then `x`, matching the usual `atan2(y, x)`
convention rather than coordinate order.

**Dimensions.** `sin`/`cos`/`tan` require an angle and return a dimensionless
value; `asin`/`acos`/`atan`/`atan2` take dimensionless arguments and return an
angle.

## Hyperbolic

`sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` — all unary, all classed as
transcendental, so all require a dimensionless argument and return a
dimensionless result.

## Rounding and sign

| Op | Arity | Result |
|---|---|---|
| `floor` | 1 | largest integer ≤ argument |
| `ceil` | 1 | smallest integer ≥ argument |
| `abs` | 1 | absolute value |
| `sign` | 1 | `-1.0`, `0.0`, or `1.0` |

```json
{ "op": "floor", "args": ["x"] }
```
With `x=2.7` → `2.0`. With the same `x`, `ceil` → `3.0`.

```json
{ "op": "abs", "args": ["x"] }
```
With `x=-3` → `3.0`.

```json
{ "op": "sign", "args": ["x"] }
```
With `x=-4` → `-1.0`.

These four propagate their argument's dimension (and for `sign`, the result is
conventionally treated as dimensionless).

## Extrema

| Op | Arity | Result |
|---|---|---|
| `min` | 2 or more | smallest argument |
| `max` | 2 or more | largest argument |

Both are **n-ary**.

```json
{ "op": "min", "args": ["a", "b", "c"] }
```
With `a=3, b=1, c=2` → `1.0`.

```json
{ "op": "max", "args": ["a", "b"] }
```
With `a=3, b=1` → `3.0`.

A common clamp is `min` of a `max`:

```json
{ "op": "min",
  "args": [{ "op": "max", "args": ["x", "lo"] }, "hi"] }
```

**Dimensions.** Operands must share a dimension, which propagates to the result.
