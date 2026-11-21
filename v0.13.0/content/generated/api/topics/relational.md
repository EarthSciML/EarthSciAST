---
title: "Relational index sets"
description: "Deterministic deduplication and grouping for relational index sets."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`distinct`](/generated/api/ref/distinct) | function | Python, Rust | Set semantics over `rows`: sort by the §5.5.1 total order, then drop |
| [`group_aggregate`](/generated/api/ref/group_aggregate) | function | Python, Rust | Group-by + semiring aggregate (rule 5). |
| [`float_key_error`](/generated/api/ref/float_key_error) | error | Python, Rust | Raised when a relational key contains a floating-point component. |

[All topics](/generated/api)
