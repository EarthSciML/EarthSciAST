---
title: "Coupling"
description: "How components are composed."
---

`coupling` is a top-level **array** of entries. Each entry has a `type`, and the
type determines its other fields.

| Type | What it does |
|---|---|
| `operator_compose` | Match time derivatives across systems and **add** their right-hand sides |
| `couple` | Bi-directional coupling through explicit connector equations |
| `variable_map` | Replace a parameter in one system with a variable — or an expression — from another |
| `event` | A continuous or discrete event spanning coupled systems |
| `callback` | Register a host callback for simulation events |
| `coupling_import` | Import a coupling library and bind its roles to local components |

## `operator_compose`

The simplest and most common. For each variable that both systems give a time
derivative, the composed system's derivative is the **sum** of theirs.

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "Composed" },
  "models": {
    "Chemistry": {
      "variables": {
        "O3": { "type": "unknown", "units": "mol/mol", "default": 1e-9 },
        "k":  { "type": "parameter", "units": "1/s", "default": 0.1 }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["O3"], "wrt": "t" },
          "rhs": { "op": "*", "args": [{ "op": "-", "args": ["k"] }, "O3"] } }
      ]
    },
    "Emissions": {
      "variables": {
        "O3": { "type": "unknown", "units": "mol/mol", "default": 1e-9 },
        "E":  { "type": "parameter", "units": "mol/mol/s", "default": 1e-12 }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["O3"], "wrt": "t" }, "rhs": "E" }
      ]
    }
  },
  "coupling": [
    { "type": "operator_compose", "systems": ["Chemistry", "Emissions"] }
  ]
}
```

The flattened system has one `O3` whose tendency is `-k·O3 + E`.

### `translate`

When the two systems spell the same quantity differently, `translate` maps
between them.

```json
{
  "type": "operator_compose",
  "systems": ["ChemModel", "PhotolysisModel"],
  "translate": { "ChemModel.ozone": "PhotolysisModel.O3" }
}
```

**Direction matters.** For `"systems": [A, B]`, every **key** names a variable of
`A` and every **value** names a variable of `B`. Writing the map backwards does
not produce an error — it matches nothing, and the composition silently does
less than you intended.

A conversion factor may ride along:

```json
{
  "translate": {
    "ChemModel.ozone": { "var": "PhotolysisModel.O3", "factor": 1e-9 }
  }
}
```

Endpoints may be written bare (`"O3"`) or fully scoped
(`"ChemModel.O3"`); a bare key resolves against `systems[0]` and a bare value
against `systems[1]`, so the two spellings mean the same thing.

**A translation consumes the merged-away name.** Only `A`'s spelling survives:
`B`'s declaration of the translated variable is removed from the flattened
system, and *every* remaining reference to it — anywhere in the document, not
just inside `B` — is retargeted at `A`'s name.

## `couple`

Bi-directional coupling through an explicit connector: a set of equations you
write, each saying which variable is affected and how.

| Transform | Meaning |
|---|---|
| `additive` | Add the expression as a source/sink term. If `to` has no tendency, the expression becomes it. |
| `multiplicative` | Multiply the existing tendency by the expression. |
| `replacement` | Replace the variable's value entirely. |

`multiplicative` is defined against an **existing** tendency. If `to` names
something with no `D(to)` equation — a parameter, an observed, an algebraic
unknown, or an undefined name — there is nothing to multiply, and the library
raises `couple_multiplicative_no_tendency` rather than silently dropping the
equation. `additive` has no such requirement, because zero is the additive
identity.

## `variable_map`

Replaces a parameter in one component with something from another.

```json
{
  "type": "variable_map",
  "from": "Meteorology.temperature",
  "to": "Chemistry.T",
  "transform": "param_to_var"
}
```

| Transform | Meaning | `factor`? |
|---|---|---|
| `param_to_var` | Replace a constant parameter with a time-varying variable | no |
| `identity` | Direct assignment | no |
| `additive` | `target := factor · source` | yes |
| `multiplicative` | `target := factor · source` | yes |
| `conversion_factor` | `target := factor · source`, documenting a unit conversion | yes |
| an Expression | `target := <expression>` | no — fold scaling in |

**Every `variable_map` transform is a replacement.** The three scaling
transforms are equivalent in effect and differ only in documented intent. A
`factor` on `param_to_var` or `identity` — which have nothing to scale — or
alongside an Expression transform, which spells its own arithmetic, is rejected
at load.

Genuine term *composition* — adding a source/sink term, or scaling a tendency in
place — is a `couple` concern, not a `variable_map` one. That is the distinction
worth internalizing: `variable_map` **rebinds a name**; `couple` **combines
terms**.

### Expression transforms

An Expression transform is the general form the named ones desugar to, and it is
how regridding across grids is expressed:

```json
{
  "type": "variable_map",
  "from": "CoarseGrid.emis",
  "to": "FineGrid.E",
  "transform": {
    "op": "aggregate",
    "output_idx": ["j"],
    "expr": {
      "op": "*",
      "args": [
        { "op": "index", "args": ["FineGrid.W", "i", "j"] },
        { "op": "index", "args": ["CoarseGrid.emis", "i"] }
      ]
    },
    "args": ["FineGrid.W", "CoarseGrid.emis"]
  }
}
```

Rules for the expression:

- It must be an **operator node** — a bare reference or a literal is not
  admissible, because bare replacement is what the named transforms already do.
- Every variable reference must be a **fully-scoped** reference resolvable in
  the flattened coupled system.
- It **must reference the entry's `from` variable** — that is the data-flow edge
  the entry declares.
- It may reference anything else in scope, which is what lets the receiving
  component's overlap weights and normalization row-sums appear alongside the
  source field.

Flattening removes the `to` parameter and puts a derived (observed) variable in
its place — same name, units, and shape — whose defining expression is the
transform. Every reference to the target then evaluates it exactly as an
authored observed would.

## Events

An `event` entry is a continuous or discrete event spanning coupled systems.
Inside an affect, [`Pre(x)`](../operators/constants-and-conditionals/) is the
value `x` held **before** the event fired, which is what lets an affect
reference the pre-event state while assigning the post-event one.

```json
{
  "type": "event",
  "event_type": "discrete",
  "name": "daily_reset",
  "trigger": { "kind": "periodic", "period": 86400.0 },
  "affects": [
    { "lhs": "Chemistry.accumulated",
      "rhs": 0.0 }
  ]
}
```

## Coupling libraries

A **coupling-library file** declares `coupling_roles` — formal component roles —
alongside a role-scoped `coupling` array, and declares no models, reaction
systems, data sources, domain, index sets, metaparameters, or expression
templates. The presence of `coupling_roles` is the sole positive identifier of
the kind.

A `coupling_import` entry brings one in and binds its roles to local components:

```json
{
  "type": "coupling_import",
  "ref": "libs/emissions-coupling.esm",
  "bind": { "receiver": "Chemistry", "source": "Emissions" }
}
```

Binding is **total and checked by name**: every role the library declares must
be bound, and a name that is not a role is an error. At flatten time the import
expands into concrete `variable_map` / `couple` / `operator_compose` / `event`
edges, exactly as if you had written them inline.

Because that expansion happens *after* the template-rewrite fixpoint, a library
edge's transform must expand to an **already-lowered** form. A transform
template that would introduce `grad`, `div`, or a spatial `D` is rejected with
`coupling_library_illegal_payload`.
