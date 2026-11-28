---
title: "Relational keys and geometry"
description: "Deterministic keys, ranking and grouping for relational index sets, and the polygon geometry used by regridding."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`area_tolerance_ok`](/generated/api/ref/area_tolerance_ok) | function | Python, Rust | Combined rel+abs area-agreement gate with a sliver floor (B.5 / §5.8.2). |
| [`distinct`](/generated/api/ref/distinct) | function | Python, Rust | Set semantics over `rows`: sort by the §5.5.1 total order, then drop |
| [`group_aggregate`](/generated/api/ref/group_aggregate) | function | Python, Rust | Group-by + semiring aggregate (rule 5). |
| [`intersect_polygon`](/generated/api/ref/intersect_polygon) | function | Python, Rust | Clip two lon-lat polygon rings; return the overlap ring (RFC §8.1). |
| [`polygon_area`](/generated/api/ref/polygon_area) | function | Python, Rust | Reference (unsigned) area of an overlap ring under `manifold`. |
| [`rank`](/generated/api/ref/rank) | function | Python, Rust | Dense integer renumbering (rule 3): assign IDs by position in the sorted `distinct` sequence. |
| [`skolem`](/generated/api/ref/skolem) | function | Python, Rust | Canonical-tuple Skolem key (rule 4). |
| [`skolem_edge`](/generated/api/ref/skolem_edge) | function | Python, Rust | Canonical key for an **undirected** pair (a symmetric relation): `(min(a, b), max(a, b))`. |
| [`ranking`](/generated/api/ref/ranking) | type | Python, Rust | Result of `rank`. |
| [`float_key_error`](/generated/api/ref/float_key_error) | error | Python, Rust | Raised when a relational key contains a floating-point component. |
| [`geometry_error`](/generated/api/ref/geometry_error) | error | Python, Rust | A polygon-clip / area evaluation failed (bad operand, degenerate input). |

[All topics](/generated/api)
