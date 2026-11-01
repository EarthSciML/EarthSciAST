---
title: "Runtime I/O"
description: "Refresh cadence, output planning and gridding: the protocol a host uses to feed data into and write results out of a running simulation."
type: "api"
---


These operations belong to the **runtime I/O** capability profile: Julia, Python, Rust.

| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`derive_output_gridding`](/generated/api/ref/derive_output_gridding) | function | Julia, Rust | Invert the flat `var_map` (state-element name → flat index) into one `VarGridding` per output base-variable (RFC §7). |
| [`derive_output_meta`](/generated/api/ref/derive_output_meta) | function | Julia, Rust | Distill the flattened run document into `OutputMeta`: the model names, the `index_sets` axis lengths, each variable's declared `shape` (real dim names) + retained CF attrs +… |
| [`derive_output_plan`](/generated/api/ref/derive_output_plan) | function | Julia, Rust | Derive the whole output plan for a run (RFC §7–§9) — the Julia mirror of `earthsci_ast::data_output::derive_output_plan`. |
| [`group_gridding_by_grid`](/generated/api/ref/group_gridding_by_grid) | function | Julia, Rust | Partition output variables into GRIDS by their spatial-dim signature (RFC §9): variables that live on the same set of axes form one grid, so an atmosphere over `[lev, lat, lon]`… |
| [`plan_dimension_coordinates`](/generated/api/ref/plan_dimension_coordinates) | function | Julia, Rust | Resolve the `coordinates` registry (§8.3) into the CF **dimension coordinates** for a set of `VarGridding`s: for each distinct spatial dim, if the registry has an entry KEYED BY… |
| [`cadence`](/generated/api/ref/cadence) | type | Rust, Go | The cadence lattice (`CONFORMANCE_SPEC.md` §5.7.1): `const ⊏ discrete ⊏ continuous`. |
| [`grid_plan`](/generated/api/ref/grid_plan) | type | Julia, Rust | One emergent grid (RFC §9): the ordered SPATIAL `dims` (`name => length`; empty for the scalar grid — the record axis is not included, see `time_dim`), the record-axis name, the… |
| [`output_meta`](/generated/api/ref/output_meta) | type | Julia, Rust | The document-derived output metadata carried by an `EsmProblem` so a streaming sink can name axes and emit CF coordinates (RFC §7–§8). |
| [`output_plan`](/generated/api/ref/output_plan) | type | Julia, Rust | The full derived output plan: one `GridPlan` per emergent grid, in first-seen signature order. |
| [`partition`](/generated/api/ref/partition) | type | Python, Rust | The result of the cadence-partition pass over one model. |
| [`var_gridding`](/generated/api/ref/var_gridding) | type | Julia, Rust | The gridded layout of one output base-variable, derived from a flat `var_map` (RFC §7). |
| [`var_plan`](/generated/api/ref/var_plan) | type | Julia, Rust | One output variable as a writer sees it: the on-disk `name`, its ordered on-disk `dims` (record axis first, then spatial axes — a scalar's dims are exactly `[time_dim]`), the CF… |
| [`cadence_error`](/generated/api/ref/cadence_error) | error | Python, Rust, Go | A cadence-partition contract violation in a model or producer output. |
| [`output_error`](/generated/api/ref/output_error) | error | Julia, Rust | Thrown by the streaming-output surface: an unimplemented Sink protocol method, a malformed snapshot, an output request that designates no single variable, or a call to… |

[All topics](/generated/api)
