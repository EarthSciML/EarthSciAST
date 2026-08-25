---
title: "Calculus"
description: "D, ic, and the rewrite-target sugar grad / div / laplacian."
---

## `D` — derivative

`D` has **two tiers**, and which one a node is in depends entirely on `wrt`.

### Structural time derivative — evaluable

`wrt: "t"` (or `wrt` absent, which means `t`) is the structural time derivative.
It is **strictly unary**: `args` holds exactly the differentiated variable.

```json
{ "op": "D", "args": ["N"], "wrt": "t" }
```

This is what makes a variable an ODE state, and it belongs on an equation's
**left-hand side**, where system assembly consumes it:

```json
{
  "lhs": { "op": "D", "args": ["N"], "wrt": "t" },
  "rhs": { "op": "*", "args": [{ "op": "-", "args": ["lambda"] }, "N"] }
}
```

A common mistake is writing the independent variable as a second argument —
`{"op":"D","args":["N","t"]}`. That is wrong: `t` goes in `wrt`, and a `wrt:"t"`
node with more than one argument is rejected by the schema.

### Spatial derivative — rewrite target

Any other `wrt` — or *any* `D` appearing on a right-hand side — has **no
evaluator**. It must be lowered to a stencil by a
[rewrite rule](../../templates/) before the document can run.

```json
{ "op": "D", "args": ["C"], "wrt": "x" }
```

A spatial `D` may carry **trailing operands** after `args[0]`:

```json
{ "op": "D", "args": ["C", "C_west", "C_east"], "wrt": "x" }
```

These are auxiliary data for the discretization rule — canonically the per-face
boundary or halo values of a closure. They carry **no evaluator semantics**:
they do not change the derivative's value, its dimension, or its eligibility for
lowering. A dimensional checker applies the `D` rule to `args[0]` alone and
ignores the rest entirely.

Their count is unbounded and their meaning is **positional and rule-defined** —
the format assigns no role to any position, and a binding must not infer one.
By convention rule libraries list per-face operands in ascending order along the
differentiated axis, but that is readability only, never enforced.

Because pattern and node `args` must match in length, a rule written for a bare
`D(f, wrt:x)` does **not** fire on a `D` carrying trailing operands, and vice
versa. That is intended: the closure is part of the rule's identity, so a rule
that does not consume the boundary data cannot silently discard it.

## `ic` — initial condition

Used as an equation LHS. `args[0]` is the ODE state; the RHS is its initial
field.

```json
{
  "lhs": { "op": "ic", "args": ["N"] },
  "rhs": 100.0
}
```

An initial condition may be an expression, not just a literal — which is how a
spatially varying initial field is written:

```json
{
  "lhs": { "op": "ic", "args": ["C"] },
  "rhs": { "op": "exp", "args": [{ "op": "-", "args": [{ "op": "^", "args": ["x", 2] }] }] }
}
```

A variable's `default` and an `ic` equation both set an initial value; `ic` is
the one that can carry an expression.

## `grad`, `div`, `laplacian` — sugar, not operators

These are **not** built-in operators. They are optional rewrite-target sugar,
and they mean exactly what their `D` expansions mean:

| Sugar | Expansion |
|---|---|
| `grad(f, dim: x)` | `D(f, wrt: x)` |
| `div(F)` | `Σᵢ D(Fᵢ, wrt: xᵢ)` |
| `laplacian(u)` | `Σᵢ D(D(u, wrt: xᵢ), wrt: xᵢ)` |

This format ships **no** rewrite rules for them. The discretization standard
library lives in
[EarthSciDiscretizations](https://github.com/EarthSciML/EarthSciDiscretizations).

As open-tier rewrite targets they get no privileges: their result dimension is
undeterminable until lowered, so a checker reports it as `unknown` and skips the
enclosing check rather than inventing a coordinate-divided dimension. A binding
must not single these names out — they are matched, lowered, and checked by the
same machinery as any operator you invent yourself.

## `integral`

A spatial partial integral, for partial integro-differential equations.
`args[0]` is the integrand; `var` names the spatial variable integrated over;
`lower` and `upper` are the bounds.

Two modes:

- **cumulative** — `"upper": "x"`, the spatial variable itself, giving a field
  cumulative up to the current grid point;
- **whole-domain** — both bounds constant, giving a spatially uniform value,
  consumed through an auxiliary variable plus boundary extraction.

`integral` carries **no in-repo lowering**: a file using it loads but cannot
simulate.
