---
title: "Calculus"
description: "D, ic, and the rewrite target integral; gradient, divergence and Laplacian written with D."
---

## `D` — derivative

`D` has **two tiers**, and which one a node is in depends entirely on `wrt`.

### Structural time derivative — evaluable

`wrt: "t"` (or `wrt` absent, which means `t`) is the structural time derivative.
It is **strictly unary**: `args` holds exactly the differentiated variable.

**LaTeX**
```latex
\frac{\mathrm{d} N}{\mathrm{d} t}
```
**JSON**
```json
{ "op": "D", "args": ["N"], "wrt": "t" }
```

This is what makes a variable an ODE state, and it belongs on an equation's
**left-hand side**, where system assembly consumes it:

**LaTeX**
```latex
\frac{\mathrm{d} N}{\mathrm{d} t} = \left(-\lambda\right) N
```
**JSON**
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

**LaTeX**
```latex
\frac{\partial C}{\partial x}
```
**JSON**
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

**LaTeX**
```latex
N(t_{0}) = 100
```
**JSON**
```json
{
  "lhs": { "op": "ic", "args": ["N"] },
  "rhs": 100.0
}
```

An initial condition may be an expression, not just a literal — which is how a
spatially varying initial field is written:

**LaTeX**
```latex
C(t_{0}) = \exp(-x^{2})
```
**JSON**
```json
{
  "lhs": { "op": "ic", "args": ["C"] },
  "rhs": { "op": "exp", "args": [{ "op": "-", "args": [{ "op": "^", "args": ["x", 2] }] }] }
}
```

A variable's `default` and an `ic` equation both set an initial value; `ic` is
the one that can carry an expression.

## Gradient, divergence and Laplacian — written with `D`

The format has no gradient, divergence or Laplacian operator. Write each with a
spatial `D`, one per axis:

| Operator | Write |
|---|---|
| gradient component along `x` | `D(f, wrt: x)` |
| Cartesian divergence | `Σᵢ D(Fᵢ, wrt: xᵢ)` |
| Laplacian | `Σᵢ D(D(u, wrt: xᵢ), wrt: xᵢ)` |

Until esm 2.4.0 the format named `grad`, `div` and `laplacian` as sugar for
these sums. It no longer does: they are ordinary operator names like any other
you invent, with no meaning of their own.

A two-dimensional Laplacian, for example:

**JSON**
```json
{ "op": "+", "args": [
  { "op": "D", "args": [{ "op": "D", "args": ["u"], "wrt": "x" }], "wrt": "x" },
  { "op": "D", "args": [{ "op": "D", "args": ["u"], "wrt": "y" }], "wrt": "y" }
] }
```

A scheme that is not a sum of per-axis derivatives — a finite-volume
divergence on an unstructured mesh, or a metric Laplacian discretized as one
stencil — is an operator you invent (any non-core name, `div` or
`laplacian` included), lowered by a
[template rewrite](../templates/). This format ships **no** rewrite rules for
spatial `D` or for any invented operator. The discretization standard library
lives in
[EarthSciDiscretizations](https://github.com/EarthSciML/EarthSciDiscretizations).

An invented operator gets no privileges: its result dimension is undeterminable
until lowered, so a checker reports it as `unknown` and skips the enclosing
check rather than inventing a coordinate-divided dimension. An axis name it
needs can go in `dim`, an ordinary scalar field with no privileged status, and
other scheme parameters in `attrs`.

## `integral`

A spatial partial integral, for partial integro-differential equations.
`args[0]` is the integrand; `var` names the spatial variable integrated over;
`lower` and `upper` are the bounds.

Whole-domain — both bounds constant, giving a spatially uniform value, consumed
through an auxiliary variable plus boundary extraction:

**LaTeX**
```latex
\operatorname{integral}(f; \mathrm{lower} = 0, \mathrm{upper} = 1, \mathrm{var} = x)
```
**JSON**
```json
{ "op": "integral", "args": ["f"], "var": "x", "lower": 0, "upper": 1 }
```

Cumulative — `upper` is the spatial variable itself, giving a field cumulative
up to the current grid point:

**LaTeX**
```latex
\operatorname{integral}(u; \mathrm{lower} = x_{\mathrm{min}}, \mathrm{upper} = x, \mathrm{var} = x)
```
**JSON**
```json
{ "op": "integral", "args": ["u"], "var": "x", "lower": "x_min", "upper": "x" }
```

`integral` carries **no in-repo lowering**: a file using it loads,
pretty-prints, and validates, then fails at evaluation with
`unlowered_operator` unless you supply a rewrite rule. Its bounds carry no
measure, because the format has none.

**Do not reach for `integral` to write a discrete cumulative sum.** A running
total, a cumulative distribution, or a column-integrated burden over a
discretized axis is an ordinary [`faq`](../aggregation/) with a monotone
`filter` — in the evaluable core, and running in every executing binding today.
