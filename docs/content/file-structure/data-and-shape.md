---
title: "Data and shape"
description: "index_sets, coordinates, metaparameters, domain, data_sources, function_tables, enums."
---

These sections describe *where numbers come from* and *what shape they have*.
None of them carry equations.

## `index_sets`

A document-scoped registry of named index sets. A variable's `shape` lists index
set names, and index expressions resolve against them.

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "Shapes" },
  "index_sets": {
    "lon":     { "kind": "interval", "size": 4 },
    "lat":     { "kind": "interval", "size": 3 },
    "species": { "kind": "categorical", "members": ["O3", "NO", "NO2"] }
  },
  "models": {
    "Grid": {
      "variables": {
        "C": { "type": "unknown", "units": "mol/m^3", "shape": ["lon", "lat", "species"] },
        "k": { "type": "parameter", "units": "1/s", "default": 0.1 }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["C"], "wrt": "t" },
          "rhs": { "op": "*", "args": [{ "op": "-", "args": ["k"] }, "C"] } }
      ]
    }
  }
}
```

| `kind` | Meaning |
|---|---|
| `interval` | A contiguous range; `size` gives its length. |
| `categorical` | A fixed list; `members` names the elements. |
| `derived` | Built from another set — `of`, `member_factor`, `offsets`. |
| `ragged` | Variable-length groups; `values` carries the per-group extents. |

`size` may be a metaparameter name rather than a literal, which is how one
document serves many resolutions.

## `metaparameters`

Named values bound **at load time**, before anything else resolves. Each entry
declares a `type` and usually a `default`; a caller may override it at load.

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "Parameterized" },
  "metaparameters": {
    "nlev": { "type": "integer", "default": 72, "description": "Vertical levels" }
  },
  "index_sets": { "lev": { "kind": "interval", "size": "nlev" } },
  "models": {
    "Column": {
      "variables": {
        "T": { "type": "unknown", "units": "K", "shape": ["lev"] },
        "r": { "type": "parameter", "units": "K/s", "default": 0.0 }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["T"], "wrt": "t" }, "rhs": "r" }
      ]
    }
  }
}
```

Every binding takes metaparameter bindings at its load entry point, so the same
file can be loaded at 72 levels or at 2 without editing it.

## `domain`

The **single** temporal domain shared by every component in the document. There
is at most one, and it is temporal only — spatiality comes from variable
`shape`, not from a domain reference.

```json
{
  "domain": {
    "temporal": {
      "start": "2024-07-01T00:00:00Z",
      "end": "2024-07-01T12:00:00Z"
    }
  }
}
```

## `data_sources`

Ingest configuration for external data, keyed by name. Each entry requires
`kind` and `source`.

```json
{
  "data_sources": {
    "GEOSFP_MeteoData": {
      "kind": "grid",
      "source": { "url_template": "file:///data/GEOSFP/{date:%Y%m%d_%H%M}.nc" },
      "temporal": { "frequency": "PT3H", "file_period": "PT3H", "records_per_file": 1 },
      "reference": {
        "citation": "Global Modeling and Assimilation Office (GMAO), NASA GSFC",
        "doi": "10.5067/8D5L8QSF2Y6L"
      }
    }
  }
}
```

| Field | Meaning |
|---|---|
| `kind` | `grid`, `static`, `points`, … — what the reader expects. |
| `source` | Where it comes from; `url_template` supports `{date:…}` substitution. |
| `temporal` | Cadence: `frequency`, `file_period`, `records_per_file`. |
| `determinism` | Whether repeated reads must agree. |
| `reader_options` | Passed through to the reader. |
| `select` | Projection pushdown — read only the rows/columns needed. |
| `record_filter` | Row filter applied at read time. |
| `extent` | Declared extent, or the metaparameter the loader discovers it into. |

**A data source is not a component.** It has no variables, is not a coupling
endpoint, and is not a node in the component graph. External data reaches a
model as a *parameter* whose `update` draws from a source:

```json
{
  "parameters": {
    "T": {
      "units": "K",
      "default": 298.15,
      "update": { "kind": "data", "source": "GEOSFP_MeteoData", "from": { "file_variable": "T" } }
    }
  }
}
```

A document whose only component-bearing key is `data_sources` is a
**source-catalog file**: it declares ingest configuration other documents draw
from, and cannot itself be simulated or referenced as a subsystem.

## `coordinates`

An optional registry of coordinate variables, used when writing output. A
coordinate either carries literal `values` or names a `source` variable.

```json
{
  "coordinates": {
    "grid_lon": {
      "values": [-100.0, -99.0, -98.0, -97.0],
      "standard_name": "longitude",
      "units": "degrees_east",
      "axis": "X"
    },
    "level": {
      "source": "lev_pressure",
      "standard_name": "air_pressure",
      "units": "Pa",
      "axis": "Z"
    }
  }
}
```

## `function_tables`

Sampled function tables: ordered named axes plus the sampled values. They are
what [`interp.*`](../../operators/closed-functions/) reads.

## `enums`

File-local symbol-to-positive-integer maps, used by the
[`enum`](../../operators/closed-functions/) op to make categorical lookups
readable.

```json
{
  "enums": {
    "season": { "winter": 1, "spring": 2, "summer": 3, "autumn": 4 },
    "land_use_class": { "urban": 1, "agricultural": 2, "grassland": 7, "water": 9 }
  }
}
```

Values must be positive integers, and they are local to the file — two documents
may number the same symbol differently.
