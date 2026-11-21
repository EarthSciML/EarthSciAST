---
title: "Other"
description: "Stable operations not yet placed in a topic."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`default_forcing_set`](/generated/api/ref/default_forcing_set) | function | Julia, Python | The Problem's forcing when `rhs_program` ran — provider data, a caller's array, or the declared default broadcast over the slot's shape, and an array parameter's value — copied… |
| [`forcing_set`](/generated/api/ref/forcing_set-function) | function | Julia, Python | A forcing set for `x` (API_SPEC §5.8): `bufs` holds one buffer per `forcing_slots``(x)` entry, in slot order, each of `prod(shape)` elements read in linear (column-major) order. |
| [`halo`](/generated/api/ref/halo) | function | Julia, Python | The halo report (API_SPEC §5.8): for every state the operator reads and every cut or face index set on its shape, `(variable, set) => (lo, hi)`, how far the owned output reaches… |
| [`lanes`](/generated/api/ref/lanes) | function | Julia, Python | The operator over a run-time list of cells (`kind = :cells`, `sets` every index set of the written variables' shape) or columns (`kind = :columns`, `sets` the horizontal sets)… |
| [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13) | function | Julia, TypeScript, Python, Rust, Go | Reject `solver.external` in a file declaring `esm` &lt; 1.3.0. |
| [`reject_solver_time_span_pre_v13`](/generated/api/ref/reject_solver_time_span_pre_v13) | function | Julia, TypeScript, Python, Rust, Go | Reject `solver.time_span` in a file declaring `esm` &lt; 1.3.0. |
| [`resolve_time_span`](/generated/api/ref/resolve_time_span) | function | Julia, TypeScript, Python, Rust, Go | The interval to simulate `file` over, most specific first (esm-spec §2.2.7): |
| [`restrict`](/generated/api/ref/restrict) | function | Julia, Python | The operator restricted to one tile (API_SPEC §5.8, "Tile semantics"): `owned` and `storage` give one inclusive range per cut axis (`"lon" => 17:32`), in global coordinates,… |
| [`rhs_program`](/generated/api/ref/rhs_program) | function | Julia, Python, Rust | The Problem's right-hand side as a program value (API_SPEC §5.8): the whole model over the whole domain, with `u` every state of the Problem (in the Problem's flat layout) and… |
| [`select`](/generated/api/ref/select) | function | Julia, Python | The program of one operator (API_SPEC §5.8, "Selection"): every flattened equation keeps the contributions whose #539 origins intersect `terms` (a vector of `TermOrigin`, matched… |
| [`solver_external_location`](/generated/api/ref/solver_external_location) | function | Julia, TypeScript, Python, Rust, Go | Where the document's `solver.external` points (esm-spec §2.2.6), or `nothing` when its `solver` block carries no `external`. |
| [`time_origin`](/generated/api/ref/time_origin) | function | Julia, Python, Rust | The time origin in seconds from the POSIX epoch: the instant `domain.temporal.reference_time` — else `domain.temporal.start`, else the epoch itself — names, as `W₀ + f₀`, whole… |
| [`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds) | function | Julia, Python, Rust | `timestamp`, an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z` — the `solver.time_span` bound form), as seconds from the time origin of `file` or of `domain` (typed, raw JSON… |
| [`contribution`](/generated/api/ref/contribution) | type | Julia, TypeScript, Python, Rust, Go | One summand of a flattened equation's right-hand side, with its authors. |
| [`decomposition`](/generated/api/ref/decomposition) | type | Julia, Rust | A horizontal decomposition (API_SPEC §5.8): the index sets a tiling cuts, each with its period (`nothing` when the axis is not periodic; otherwise the axis's global extent), and… |
| [`forcing_set`](/generated/api/ref/forcing_set-type) | type | Julia, Rust | The forcing inputs of an evaluation (API_SPEC §5.8): one column-major buffer per `forcing_slots` entry, in slot order, and an epoch no other set in the process carries. |
| [`forcing_slot`](/generated/api/ref/forcing_slot) | type | Julia, Rust | One buffer of a `ForcingSet` (`forcing_slots`): the flattened `name`, its resolved `shape` (empty for a 0-d input) and its `kind`: `:forcing` (an externally fed parameter: its… |
| [`param_slot`](/generated/api/ref/param_slot) | type | Julia, Rust | One entry of a program's parameter vector (`parameters`): the flattened parameter `name` and its declared `default` (`nothing` when it declares none). |
| [`solver_time_span`](/generated/api/ref/solver_time_span) | type | Julia, Python, Rust, Go | The `solver.time_span` interval (esm-spec §2.2.7): the period the document is meant to be simulated over. |
| [`state_block`](/generated/api/ref/state_block) | type | Julia, Rust | One block of a program's `u` (`state_layout`): the flattened state `name`, the 1-based `offset` of its first element, and its `shape` (empty for a 0-d state). |
| [`term_origin`](/generated/api/ref/term_origin) | type | Julia, TypeScript, Python, Rust, Go | Who authored one `Contribution`. |
| [`time_point`](/generated/api/ref/time_point) | type | Rust, Go | One bound of a `SolverTimeSpan`, kept in its authored form. |
| [`unit_finding_dimensionless_literal`](/generated/api/ref/unit_finding_dimensionless_literal) | constant | Julia, Python, Rust, Go | The `UnitWarning.code` of a check site that the current neutral-literal rule passes or skips but that fails once a bare numeric literal is read as dimensionless at scale 1… |

[All topics](/generated/api)
