---
title: "metadata"
description: "Identity and provenance for the document."
---

`metadata` is required, and `name` is the only required field inside it.

```json
{
  "esm": "1.0.0",
  "metadata": {
    "name": "SimpleDecay",
    "description": "Exponential decay with a known analytical solution",
    "authors": ["Chris Tessum"],
    "license": "AGPL-3.0",
    "created": "2026-02-14T00:00:00Z",
    "modified": "2026-08-25T00:00:00Z",
    "tags": ["test", "analytical"],
    "references": [
      { "doi": "10.5194/gmd-15-1-2022", "notes": "Original formulation" }
    ]
  },
  "models": {
    "Decay": { "variables": {}, "equations": [] }
  }
}
```

## Fields

| Field | Type | Meaning |
|---|---|---|
| `name` | string | **Required.** The document's name. |
| `description` | string | Free text. |
| `authors` | array of string | Author names. |
| `license` | string | SPDX identifier by convention. |
| `created` / `modified` | string | ISO-8601 timestamps. |
| `tags` | array of string | Free-form labels. |
| `references` | array | Citations; each entry may carry `doi`, `url`, `title`, `notes`. |
| `system_class` | string | Coarse classification of the system. |
| `dae_info` | object | Set when the document has been through DAE analysis. |
| `discretized_from` | string | Provenance: the continuous document this was discretized from. |

`name` is the document's name, and is independent of the keys under `models` —
a component's name is the key it is stored under, not a field on the component.

## Component-level `reference`

Models and reaction systems carry their own `reference` object for
component-scoped provenance, which is separate from document `metadata`:

```json
{
  "models": {
    "ExponentialDecay": {
      "reference": {
        "notes": "dN/dt = -lambda*N, analytical solution N(t) = N0*exp(-lambda*t)"
      },
      "variables": { "N": { "type": "unknown" } },
      "equations": []
    }
  }
}
```
