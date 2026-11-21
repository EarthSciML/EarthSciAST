---
title: "Removed operators"
description: "The operators esm 2.0.0 removed, the error a document using one gets, and the standard-library template that replaces each."
---

esm 2.0.0 removed every operator whose evaluation needed code outside the
expression AST. Each one has a pure-AST replacement in the
[standard library](../../standard_library/): an expression template that a
component imports with `expression_template_imports` and calls with
`apply_expression_template`. A template body is ordinary AST, so every binding
evaluates it with the same core operators.

A document that still uses a removed operator, or the removed
`function_tables` block, is rejected at load with the hard error `removed_op`,
which names the operator or field and where it occurs. Loaders do not rewrite
it; the 2.0.0 codemod (see `MIGRATION.md`) rewrites a 1.x document into the
template form.

| Removed | Replacement |
|---|---|
| `fn` with `datetime.year`, `month`, `day`, `hour`, `minute`, `second`, `day_of_year`, `julian_day`, `is_leap_year` | the template of the same name in `esm:std/calendar.esm` |
| `fn` with `interp.searchsorted`, `interp.linear`, `interp.bilinear` | `searchsorted`, `linear`, `bilinear` in `esm:std/interp.esm` |
| `function_tables` and `table_lookup` | `linear` / `bilinear` from `esm:std/interp.esm`, applied to the table's data and axes |
| `skolem` | an integer key: `pair_key` / `edge_key` in `esm:std/relational.esm`, or one integer column per component for a `join.on` key |
| `rank` | the member's loop index over the `distinct` set, or `rank_of` / `rank_of_set` in `esm:std/relational.esm` |
| `argmin`, `argmax` (operator forms) | the `argmin`, `argmax`, `argmin_where`, `argmax_where` templates in `esm:std/relational.esm` |
| `polygon_intersection_area` | `overlap_area_planar` / `overlap_area_spherical` (with `lonlat_to_unit`) in `esm:std/geometry.esm`; see [geometry](../geometry/) |
| `intersect_polygon` | none |
| `aggregate` (the deprecated spelling of `faq`) | `faq`, the same node |

The `manifold` field went with the geometry operators.

## Example: a calendar field

**JSON**
```json
{
  "expression_template_imports": [
    { "ref": "esm:std/calendar.esm", "only": ["hour"] }
  ],
  "equations": [
    {
      "lhs": "hour_utc",
      "rhs": { "op": "apply_expression_template", "args": [], "name": "hour",
               "bindings": { "t": "t_utc" } }
    }
  ]
}
```

## Example: a sampled table

A one-axis table becomes a `linear` call over its data and axis; the axis
length is an explicit integer parameter.

**JSON**
```json
{
  "expression_template_imports": [{ "ref": "esm:std/interp.esm", "only": ["linear"] }],
  "equations": [
    {
      "lhs": "mu",
      "rhs": {
        "op": "apply_expression_template", "args": [], "name": "linear",
        "bindings": {
          "table": { "op": "const", "args": [], "value": [1.60e-5, 1.73e-5, 1.85e-5] },
          "axis":  { "op": "const", "args": [], "value": [250.0, 275.0, 300.0] },
          "x": "temp",
          "n": 3
        }
      }
    }
  ]
}
```

Outside the axis the result is flat (the edge value). A two-axis table uses
`bilinear`; a multi-output table becomes one call per output, each over that
output's slice of the data.

## Writing it in the AST first

If an operation can be written with the arithmetic and elementary operators,
write it that way, so it stays visible to canonicalization,
common-subexpression elimination, dimensional analysis and rewrite rules. A
composition that recurs belongs in a template library, not in a new operator.
