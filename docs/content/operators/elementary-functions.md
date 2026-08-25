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

**Text**
```text
exp(0)
```
**JSON**
```json
{ "op": "exp", "args": [0] }
```
→ `1.0`.

**Text**
```text
sqrt(9)
```
**JSON**
```json
{ "op": "sqrt", "args": [9] }
```
→ `3.0`.

`log` is the natural logarithm — here a log-pressure vertical coordinate:

**Text**
```text
log(p0 / p)
```
**JSON**
```json
{ "op": "log", "args": [{ "op": "/", "args": ["p0", "p"] }] }
```

`log10` is base 10 — here pH from hydrogen-ion activity:

**Text**
```text
-log10(H_plus)
```
**JSON**
```json
{ "op": "-", "args": [{ "op": "log10", "args": ["H_plus"] }] }
```

The classic Arrhenius rate:

**Text**
```text
A * exp((-Ea) / (R * T))
```
**JSON**
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

**Text**
```text
sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hour)
```
**JSON**
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

**Text**
```text
tan(slope)
```
**JSON**
```json
{ "op": "tan", "args": ["slope"] }
```

The inverses go the other way — an angle out of a dimensionless ratio:

**Text**
```text
acos(cos_sza)
```
**JSON**
```json
{ "op": "acos", "args": ["cos_sza"] }
```

**Text**
```text
asin(z / r)
```
**JSON**
```json
{ "op": "asin", "args": [{ "op": "/", "args": ["z", "r"] }] }
```

**Text**
```text
atan(dz_dx)
```
**JSON**
```json
{ "op": "atan", "args": ["dz_dx"] }
```

`atan2` is the quadrant-aware form, and takes `y` first:

**Text**
```text
atan2(y, x)
```
**JSON**
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

**Text**
```text
tanh(z)
```
**JSON**
```json
{ "op": "tanh", "args": ["z"] }
```

**Text**
```text
sinh(z) / cosh(z)
```
**JSON**
```json
{
  "op": "/",
  "args": [{ "op": "sinh", "args": ["z"] }, { "op": "cosh", "args": ["z"] }]
}
```

`asinh` is defined for all reals, which makes it a useful signed log-like
transform for a quantity that changes sign:

**Text**
```text
asinh(x / x0)
```
**JSON**
```json
{ "op": "asinh", "args": [{ "op": "/", "args": ["x", "x0"] }] }
```

**Text**
```text
acosh(g)
```
**JSON**
```json
{ "op": "acosh", "args": ["g"] }
```

**Text**
```text
atanh(r)
```
**JSON**
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

**Text**
```text
floor(x)
```
**JSON**
```json
{ "op": "floor", "args": ["x"] }
```
With `x=2.7` → `2.0`.

**Text**
```text
ceil(x)
```
**JSON**
```json
{ "op": "ceil", "args": ["x"] }
```
With `x=2.7` → `3.0`.

**Text**
```text
abs(x)
```
**JSON**
```json
{ "op": "abs", "args": ["x"] }
```
With `x=-3` → `3.0`.

**Text**
```text
sign(x)
```
**JSON**
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

**Text**
```text
min(a, b, c)
```
**JSON**
```json
{ "op": "min", "args": ["a", "b", "c"] }
```
With `a=3, b=1, c=2` → `1.0`.

**Text**
```text
max(a, b)
```
**JSON**
```json
{ "op": "max", "args": ["a", "b"] }
```
With `a=3, b=1` → `3.0`.

`min` of a `max` is the AST-level spelling of clamp / clip / limiter. Write it
this way rather than reaching for a [`fn`](../closed-functions/) that
re-implements it:

**Text**
```text
min(max(x, lo), hi)
```
**JSON**
```json
{ "op": "min",
  "args": [{ "op": "max", "args": ["x", "lo"] }, "hi"] }
```

**Dimensions.** Operands must share a dimension, which propagates to the result.
