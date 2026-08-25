---
title: "File structure"
description: "What goes in an .esm document, section by section."
---

An `.esm` file is a single JSON object. Two keys are always required:

| Key | Type | Meaning |
|---|---|---|
| `esm` | string | Format version, semver. Currently `"1.0.0"`. |
| `metadata` | object | Identity and provenance. Requires `name`. |

On top of those, a document must carry **at least one** of `models`,
`reaction_systems`, `data_sources`, `expression_templates`, or `coupling_roles`
— a file that declares none of them is rejected by the schema. So the smallest
valid document is a single empty component:

```json
{
  "esm": "1.0.0",
  "metadata": { "name": "Minimal" },
  "models": {
    "Empty": { "variables": {}, "equations": [] }
  }
}
```

That parses, validates, and round-trips. It has no unknowns, so there is nothing
to simulate, but it is a legal file.

## The sections

| Section | Purpose |
|---|---|
| [`metadata`](metadata/) | Name, description, authors, license, provenance |
| [`models`](models/) | Components with variables and equations |
| [`reaction_systems`](reaction-systems/) | Species and reactions, lowerable to ODEs |
| [`coupling`](../coupling/) | Rules composing components |
| [`coupling_roles`](../coupling/) | Formal component roles in a coupling-library file |
| [`expression_templates`](../templates/) | `match` rewrite rules |
| [`expression_template_imports`](../templates/) | Ordered imports of template libraries |
| [`data_sources`](data-and-shape/) | Ingest configuration for external data |
| [`index_sets`](data-and-shape/) | Named index sets that array dimensions range over |
| [`coordinates`](data-and-shape/) | Coordinate variables, for output |
| [`metaparameters`](data-and-shape/) | Values bound at load |
| [`function_tables`](data-and-shape/) | Sampled function tables with named axes |
| [`enums`](data-and-shape/) | Symbol-to-integer maps for categorical lookups |
| [`domain`](data-and-shape/) | The document's single temporal domain |

Which of the five required-alternative keys a document carries determines its
**kind**:

- a **component file** carries `models` and/or `reaction_systems`;
- a **source-catalog file** carries only `data_sources` — it declares ingest
  configuration other documents draw from, but is not itself a component and
  cannot be referenced as a subsystem;
- a **template-library file** carries top-level `expression_templates`;
- a **coupling-library file** is the one that declares `coupling_roles`, and its
  presence is the sole positive identifier of that kind.

## What is *not* here

Earlier drafts had `operators`, `registered_functions`, `grids`,
`staggering_rules`, and `discretizations` blocks. All five are **removed**.

- Grid geometry is ordinary data — coordinates, extents, spacing, connectivity
  and metric arrays are loaded through `data_sources` or declared as variables,
  and topology is constructed with [`aggregate`](../operators/aggregation/).
- Discretization is a [template rewrite](../templates/), not a declaration.
- The function registry is closed and lives in the spec, not in your file. See
  [closed functions](../operators/closed-functions/).
