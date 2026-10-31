---
title: "reaction_systems"
description: "Species and reactions, lowerable to ODEs."
---

`reaction_systems` is an object keyed by component name. Each system requires
`species`, `parameters`, and `reactions`.

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "MinimalChem" },
  "reaction_systems": {
    "SimpleOzone": {
      "reference": { "notes": "Minimal O3-NOx photochemical cycle" },
      "species": {
        "O3":  { "units": "mol/mol", "default": 1e-9, "description": "Ozone" },
        "NO":  { "units": "mol/mol", "default": 1e-9, "description": "Nitric oxide" },
        "NO2": { "units": "mol/mol", "default": 1e-9, "description": "Nitrogen dioxide" }
      },
      "parameters": {
        "k1":   { "units": "1/s", "default": 1.8e-14, "description": "NO + O3 rate constant" },
        "jNO2": { "units": "1/s", "default": 0.005,   "description": "NO2 photolysis rate" }
      },
      "reactions": [
        {
          "id": "R1",
          "name": "NO_O3",
          "substrates": [
            { "species": "NO", "stoichiometry": 1 },
            { "species": "O3", "stoichiometry": 1 }
          ],
          "products": [
            { "species": "NO2", "stoichiometry": 1 }
          ],
          "rate": { "op": "*", "args": ["k1", "NO", "O3"] }
        },
        {
          "id": "R2",
          "name": "NO2_photolysis",
          "substrates": [{ "species": "NO2", "stoichiometry": 1 }],
          "products": [{ "species": "NO", "stoichiometry": 1 }],
          "rate": { "op": "*", "args": ["jNO2", "NO2"] }
        }
      ]
    }
  }
}
```

## Species

`species` is an object keyed by name. Every field is optional.

| Field | Meaning |
|---|---|
| `units` | Unit string. |
| `default` | Initial concentration. |
| `default_units` | Units of `default`, if different. |
| `description` | Free text. |
| `constant` | When true, the species is held fixed — a reservoir. |

## Parameters

Same shape as a model's parameter variables, minus the `type` field (everything
in `parameters` is a parameter): `units`, `default`, `default_units`,
`description`, `shape`, `distribution`, `update`.

## Reactions

`reactions` is an **array**, and each entry requires `id`, `substrates`,
`products`, and `rate`.

| Field | Meaning |
|---|---|
| `id` | **Required.** Unique within the system. |
| `name` | Optional human-readable label. |
| `substrates` | Array of `{species, stoichiometry}`. |
| `products` | Array of `{species, stoichiometry}`. |
| `rate` | **Required.** An [expression](../../operators/) giving the reaction rate. |
| `reference` | Provenance for this reaction. |

Stoichiometry may be fractional. A reaction whose `substrates` and `products`
are both empty is legal but contributes nothing.

## Lowering to ODEs

A reaction system is a compact way of writing an ODE system. Bindings expose the
lowering directly — the derived model has one equation per species, assembled
from the stoichiometric matrix and the rate expressions:

```julia
using EarthSciAST
rsys  = load_path("chemistry.esm").reaction_systems["SimpleOzone"]
model = derive_odes(rsys)                # -> Model
S     = stoichiometric_matrix(rsys)      # species × reactions
```

`constraint_equations` on the system add algebraic constraints alongside the
derived ODEs. `discrete_events`, `continuous_events`, `subsystems`, `tolerance`,
`tests`, and the template fields all behave exactly as they do on a
[model](../models/).
