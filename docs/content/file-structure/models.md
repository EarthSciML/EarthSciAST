---
title: "models"
description: "Components with variables and equations."
---

`models` is an object keyed by component name. Each model requires exactly two
fields: `variables` and `equations`.

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "SimpleDecay" },
  "models": {
    "ExponentialDecay": {
      "variables": {
        "N": {
          "type": "unknown",
          "units": "mol",
          "default": 100.0,
          "description": "Amount of decaying species"
        },
        "lambda": {
          "type": "parameter",
          "units": "1/s",
          "default": 0.1,
          "description": "Decay constant"
        }
      },
      "equations": [
        {
          "lhs": { "op": "D", "args": ["N"], "wrt": "t" },
          "rhs": { "op": "*", "args": [{ "op": "-", "args": ["lambda"] }, "N"] }
        }
      ]
    }
  }
}
```

`variables` is an **object keyed by name**, not an array — the name is the key,
and there is no `name` field inside a variable.

## Variables

There are exactly **two** declared types, and no third:

| Type | Meaning |
|---|---|
| `unknown` | A quantity the solver solves for. Its behaviour is stated by `equations` and nowhere else — there is no `expression` field on a variable. |
| `parameter` | A quantity supplied to the solver: a `default`, or a `distribution`, optionally refreshed by an `update`. |

| Field | Applies to | Meaning |
|---|---|---|
| `type` | both | **Required.** `"unknown"` or `"parameter"`. |
| `units` | both | Unit string, e.g. `"kg/m^3"`. See [units](../../units-standard/). |
| `default` | both | Constant value. For an unknown this is its initial value. |
| `default_units` | both | Units of `default`, if different from `units`. |
| `description` | both | Free text. |
| `shape` | both | Ordered list of index-set names the variable is arrayed over. Omitted means scalar. |
| `location` | both | Advisory staggering tag (`"cell_center"`, `"x_face"`, …). Metadata only. |
| `distribution` | parameter | Draw the value instead of fixing it. Mutually exclusive with `default`. |
| `update` | parameter | When the parameter refreshes and from what. |

### Everything else is derived

The finer categories a solver needs are **not declared** — they follow from the
equations, and every binding exposes the same functions to recover them.

Unknowns partition into three sets:

| Set | Definition |
|---|---|
| `ode_states` | unknowns appearing under `D(·, t)` on some equation LHS |
| `observed_unknowns` | unknowns *defined* by an equation whose LHS names them — `y ~ f(…)` or `y[i] ~ f(…)` |
| `algebraic_unknowns` | unknowns only *constrained*, never defined — no equation names them on its LHS, e.g. `H*H*SO4 ~ Ksp` |

The split between the last two is **semantic, not syntactic**. An indexed LHS
like `y[i] ~ …` defines the whole array `y`, so it is observed, even though it
is not literally a bare variable. Only a genuine expression LHS — one naming no
single variable — is an implicit constraint.

Parameters partition similarly into constant, sampled, discrete, and Brownian,
according to their `update` and `distribution`.

## Equations

An equation is `{ "lhs": <Expression>, "rhs": <Expression> }`, optionally with a
`_comment`. The **form of the LHS** is what gives the equation its role:

| LHS form | Role |
|---|---|
| `{"op":"D","args":["u"],"wrt":"t"}` | time derivative — makes `u` an ODE state |
| `{"op":"ic","args":["u"]}` | initial condition for `u` |
| `"y"` or `{"op":"index","args":["y", …]}` | defines `y` — an observed unknown |
| any other expression | an implicit constraint (algebraic) |

A structural time derivative is **strictly unary**: `args` holds exactly the
differentiated variable, and the independent variable goes in `wrt`. Writing
`{"op":"D","args":["N","t"]}` is wrong — `t` belongs in `wrt`.

```json
{
  "equations": [
    { "lhs": { "op": "D", "args": ["N"], "wrt": "t" },
      "rhs": { "op": "*", "args": [{ "op": "-", "args": ["lambda"] }, "N"] } },

    { "lhs": { "op": "ic", "args": ["N"] }, "rhs": 100.0 },

    { "lhs": "halflife",
      "rhs": { "op": "/", "args": [{"op":"log","args":[2]}, "lambda"] } }
  ]
}
```

## Other model fields

| Field | Meaning |
|---|---|
| `initialization_equations` | Equations solved once at initialization. |
| `guesses` | Initial guesses for an implicit solve, `name -> value or expression`. |
| `system_kind` | Declared system kind, when it cannot be derived. |
| `discrete_events` / `continuous_events` | Event definitions; see [coupling](../../coupling/). |
| `subsystems` | Nested components, inline or by `$ref`. |
| `tolerance` | Per-component solver tolerances. |
| `tests` | Inline tests carried with the model. |
| `expression_templates` / `expression_template_imports` | Component-scoped rewrite rules; see [templates](../../templates/). |

## Arrayed variables

`shape` names the index sets a variable is arrayed over, in order:

```json
{
  "index_sets": {
    "cells": { "kind": "range", "size": 100 },
    "species": { "kind": "enum", "members": ["O3", "NO", "NO2"] }
  },
  "models": {
    "Chem": {
      "variables": {
        "C": { "type": "unknown", "units": "mol/m^3", "shape": ["cells", "species"] }
      },
      "equations": []
    }
  }
}
```

Array-level expressions align their operands **by index-set name** and replicate
along axes an operand does not declare. An operand carrying an index set the
result is not shaped over is rejected with `array_shape_mismatch`.

Spatiality comes from `shape`, not from a per-component domain: a 0-D model is
simply one whose variables are scalar.
