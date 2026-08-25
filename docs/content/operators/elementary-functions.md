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

```text
exp(0)
```
```json
{ "op": "exp", "args": [0] }
```
→ `1.0`.

```text
sqrt(9)
```
```json
{ "op": "sqrt", "args": [9] }
```
→ `3.0`.

`log` is the natural logarithm — here a log-pressure vertical coordinate:

```text
log(p0 / p)
```
```json
{ "op": "log", "args": [{ "op": "/", "args": ["p0", "p"] }] }
```

`log10` is base 10 — here pH from hydrogen-ion activity:

```text
-log10(H_plus)
```
```json
{ "op": "-", "args": [{ "op": "log10", "args": ["H_plus"] }] }
```

The classic Arrhenius rate:

```text
A * exp((-Ea) / (R * T))
```
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

The cosine of the solar zenith angle, the canonical use of the circular family:

```text
sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hour)
```
```json
{
  "op": "+",
  "args": [
    { "op": "*", "args": [{ "op": "sin", "args": ["lat"] },
                          { "op": "sin", "args": ["dec"] }] },
    { "op": "*", "args": [{ "op": "cos", "args": ["lat"] },
                          { "op": "cos", "args": ["dec"] },
                          { "op": "cos", "args": ["hour"] }] }
  ]
}
```

```text
tan(slope)
```
```json
{ "op": "tan", "args": ["slope"] }
```

The inverses go the other way — an angle out of a dimensionless ratio:

```text
acos(cos_sza)
```
```json
{ "op": "acos", "args": ["cos_sza"] }
```

```text
asin(z / r)
```
```json
{ "op": "asin", "args": [{ "op": "/", "args": ["z", "r"] }] }
```

```text
atan(dz_dx)
```
```json
{ "op": "atan", "args": ["dz_dx"] }
```

`atan2` is the quadrant-aware form, and takes `y` first:

```text
atan2(y, x)
```
```json
{ "op": "atan2", "args": ["y", "x"] }
```
With `y=1, x=1` → `0.7853981633974483` (π/4).

Note the argument order — `y` then `x`, the usual `atan2(y, x)` convention
rather than coordinate order.

**Dimensions.** `sin`/`cos`/`tan` require an angle and return a dimensionless
value; `asin`/`acos`/`atan`/`atan2` take dimensionless arguments and return an
angle.

## Hyperbolic

`sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh` — all unary, all classed as
transcendental, so all require a dimensionless argument and return a
dimensionless result.

```text
tanh(z)
```
```json
{ "op": "tanh", "args": ["z"] }
```

```text
sinh(z) / cosh(z)
```
```json
{
  "op": "/",
  "args": [{ "op": "sinh", "args": ["z"] }, { "op": "cosh", "args": ["z"] }]
}
```

`asinh` is defined for all reals, which makes it a useful signed log-like
transform for a quantity that changes sign:

```text
asinh(x / x0)
```
```json
{ "op": "asinh", "args": [{ "op": "/", "args": ["x", "x0"] }] }
```

```text
acosh(g)
```
```json
{ "op": "acosh", "args": ["g"] }
```

```text
atanh(r)
```
```json
{ "op": "atanh", "args": ["r"] }
```

Their real-valued domains follow the usual conventions: `acosh` requires `x ≥ 1`
and `atanh` requires `|x| < 1`. Behaviour outside the domain is **binding-defined**
— most propagate their native `NaN`, some raise — and is not fixed by the
specification. The same is true of `asin`/`acos` outside `[-1, 1]`.

## Rounding and sign

| Op | Arity | Result |
|---|---|---|
| `floor` | 1 | largest integer ≤ argument |
| `ceil` | 1 | smallest integer ≥ argument |
| `abs` | 1 | absolute value |
| `sign` | 1 | `-1.0`, `0.0`, or `1.0` |

```text
floor(x)
```
```json
{ "op": "floor", "args": ["x"] }
```
With `x=2.7` → `2.0`.

```text
ceil(x)
```
```json
{ "op": "ceil", "args": ["x"] }
```
With `x=2.7` → `3.0`.

```text
abs(x)
```
```json
{ "op": "abs", "args": ["x"] }
```
With `x=-3` → `3.0`.

```text
sign(x)
```
```json
{ "op": "sign", "args": ["x"] }
```
With `x=-4` → `-1.0`.

These four propagate their argument's dimension (and for `sign`, the result is
conventionally treated as dimensionless).

`floor` is also how a continuous coordinate is quantized into an integer bin key
— see [geometry](../geometry/), where it feeds a `skolem` term. Join keys must
compare by exact equality, so the float must be reduced to an integer first.

## Extrema

| Op | Arity | Result |
|---|---|---|
| `min` | 2 or more | smallest argument |
| `max` | 2 or more | largest argument |

Both are **n-ary with arity ≥ 2**; a binding must reject a one-argument `min` or
`max`.

```text
min(a, b, c)
```
```json
{ "op": "min", "args": ["a", "b", "c"] }
```
With `a=3, b=1, c=2` → `1.0`.

```text
max(a, b)
```
```json
{ "op": "max", "args": ["a", "b"] }
```
With `a=3, b=1` → `3.0`.

`min` of a `max` is the AST-level spelling of clamp / clip / limiter. Write it
this way rather than reaching for a [`fn`](../closed-functions/) that
re-implements it:

```text
min(max(x, lo), hi)
```
```json
{ "op": "min",
  "args": [{ "op": "max", "args": ["x", "lo"] }, "hi"] }
```

**Dimensions.** Operands must share a dimension, which propagates to the result.
