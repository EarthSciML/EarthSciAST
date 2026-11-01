---
title: "Document types"
description: "The in-memory types that mirror the sections of an .esm document: models, variables, equations, reaction systems, domains, events, data sources and more."
type: "api"
---


| Operation | Kind | Bindings | Summary |
|---|---|---|---|
| [`affect_equation`](/generated/api/ref/affect_equation) | type | Julia, Python, Rust, Go | Assignment equation for discrete events. |
| [`continuous_event`](/generated/api/ref/continuous_event) | type | Julia, Python, Rust, Go | Event triggered by zero-crossing of condition expressions. |
| [`coordinate`](/generated/api/ref/coordinate) | type | Rust, Go | One entry of the document-scoped `EsmFile::coordinates` registry (RFC streaming-output-sinks §8.3): marks an existing data array — or an inline literal vector — as a physical… |
| [`coupling_couple`](/generated/api/ref/coupling_couple) | type | Julia, Go | Bi-directional coupling via connector equations. |
| [`coupling_entry`](/generated/api/ref/coupling_entry) | type | Julia, Python, Rust, Go | Abstract base type for coupling entries that connect model components. |
| [`coupling_import`](/generated/api/ref/coupling_import) | type | Julia, Python, Go | Reuse of a coupling-library file (esm-spec §10.9, §10.10). |
| [`coupling_import_options`](/generated/api/ref/coupling_import_options) | type | TypeScript, Rust, Go | Options controlling how `coupling_import` refs are resolved at flatten. |
| [`coupling_role`](/generated/api/ref/coupling_role) | type | Rust, Go | A coupling-library formal component role (esm-spec §10.9). |
| [`data_source`](/generated/api/ref/data_source) | type | Julia, Python, Rust, Go | Generic, runtime-agnostic description of an external dataset (esm-spec §8). |
| [`data_source_binding`](/generated/api/ref/data_source_binding) | type | Julia, Python, Rust, Go | Binds a parameter to one file variable of a `data_sources` entry (esm-spec §8.5) — the `from` value form of a `data` update. |
| [`data_source_determinism`](/generated/api/ref/data_source_determinism) | type | Julia, Python, Rust, Go | Reproducibility contract a source advertises to bindings (esm-spec §8.1). |
| [`data_source_kind`](/generated/api/ref/data_source_kind) | type | Python, Rust | Structural kind of an external data source. |
| [`data_source_location`](/generated/api/ref/data_source_location) | type | Julia, Python, Rust, Go | File discovery configuration for a data source (the schema's `DataSource.source` object). |
| [`data_source_temporal`](/generated/api/ref/data_source_temporal) | type | Julia, Python, Rust, Go | Temporal coverage and record layout for a data source (esm-spec §8.3). |
| [`dimension`](/generated/api/ref/dimension) | type | Rust, Go | Base physical dimensions — the eight canonical axes shared across the bindings (`m kg s mol K A cd rad`). |
| [`discrete_event`](/generated/api/ref/discrete_event) | type | Julia, Python, Rust, Go | Event triggered by discrete triggers whose symbolic `affects` are `AffectEquation`s (`lhs` target name, `rhs` new-value expression) — the schema's `AffectEquation` shape, shared… |
| [`discrete_event_trigger`](/generated/api/ref/discrete_event_trigger) | type | Julia, Python, Rust, Go | Abstract base type for discrete event triggers. |
| [`distribution`](/generated/api/ref/distribution) | type | Julia, Python, Rust, Go | A parameter's value drawn from a probability distribution rather than fixed (esm-spec §6.3, schema `Distribution`). |
| [`domain`](/generated/api/ref/domain) | type | Julia, Python, Rust, Go | Spatial and temporal domain specification. |
| [`equation`](/generated/api/ref/equation) | type | Julia, Python, Rust, Go | Mathematical equation with left-hand side and right-hand side expressions. |
| [`esm_file`](/generated/api/ref/esm_file) | type | Julia, Python, Rust, Go | Main ESM file structure containing all components. |
| [`function_table`](/generated/api/ref/function_table) | type | Julia, Python, Go | A sampled function table referenced by `table_lookup` AST op nodes (esm-spec §9.5, v0.4.0). |
| [`function_table_axis`](/generated/api/ref/function_table_axis) | type | Julia, Python, Go | A single named axis inside a `FunctionTable` (esm-spec §9.5). |
| [`functional_update`](/generated/api/ref/functional_update) | type | Julia, Python, Rust, Go | A registered handler that computes a parameter's new value when its update fires (esm-spec §5.5). |
| [`metadata`](/generated/api/ref/metadata) | type | Julia, Python, Rust, Go | Authorship, provenance, and description metadata. |
| [`model`](/generated/api/ref/model) | type | Julia, Python, Rust, Go | ODE-based model component containing variables, equations, and optional subsystems. |
| [`model_variable`](/generated/api/ref/model_variable) | type | Julia, Python, Rust, Go | A model variable: an `unknown` the solver solves for, or a `parameter` supplied to it (esm-spec §6.3). |
| [`operator`](/generated/api/ref/operator) | type | Python, Rust | A registered runtime operator (e.g., dry deposition, wet scavenging). |
| [`parameter`](/generated/api/ref/parameter) | type | Julia, Python, Go | A reaction system's parameter (`reaction_systems.*.parameters.*`) — the reaction-side twin of a `ModelVariable` of `ParameterVariable` type, and it carries the SAME value model… |
| [`parameter_sweep`](/generated/api/ref/parameter_sweep) | type | Rust, Go | A parameter-sweep specification on a `ModelAnalysis` (schema `ParameterSweep`). |
| [`parameter_update`](/generated/api/ref/parameter_update) | type | Julia, Python, Rust, Go | One rule saying WHEN a parameter refreshes and WHAT it refreshes from (esm-spec §5.4). |
| [`plot`](/generated/api/ref/plot) | type | Rust, Go | A plot specification of a `ModelAnalysis` (schema `Plot`). |
| [`plot_axis`](/generated/api/ref/plot_axis) | type | Rust, Go | Axis specification of an analysis `Plot` (schema `PlotAxis`). |
| [`plot_series`](/generated/api/ref/plot_series) | type | Rust, Go | A single named series of a multi-series line/scatter `Plot` (schema `PlotSeries`). |
| [`plot_value`](/generated/api/ref/plot_value) | type | Rust, Go | A scalar value derived from a trajectory, used for heatmap / color channels (schema `PlotValue`). |
| [`reaction`](/generated/api/ref/reaction) | type | Julia, Python, Rust, Go | Chemical reaction with substrates, products, and rate expression. |
| [`reaction_system`](/generated/api/ref/reaction_system) | type | Julia, Python, Rust, Go | Collection of chemical reactions with associated species, supporting hierarchical composition. |
| [`reference`](/generated/api/ref/reference) | type | Julia, Python, Go | Academic citation or data source reference. |
| [`solver`](/generated/api/ref/solver) | type | Julia, Python, Rust, Go | Document-scoped, OPTIONAL solver hints (esm-spec §2.2) — numerics the document knows about *itself*, which each binding maps to its own integrator — plus `external`, a reference… |
| [`species`](/generated/api/ref/species) | type | Julia, Python, Rust, Go | Chemical species definition with name and optional properties. |
| [`sweep_dimension`](/generated/api/ref/sweep_dimension) | type | Rust, Go | One axis of a `ParameterSweep` (schema `SweepDimension`): exactly one of `values` / `range` is present. |
| [`sweep_range`](/generated/api/ref/sweep_range) | type | Rust, Go | Generated range of values for one `SweepDimension` (schema `SweepRange`). |
| [`temporal_domain`](/generated/api/ref/temporal_domain) | type | Python, Go | Temporal domain specification. |
| [`time_span`](/generated/api/ref/time_span) | type | Rust, Go | Simulation time interval used by inline model tests. |
| [`tolerance`](/generated/api/ref/tolerance) | type | Rust, Go | Numerical comparison tolerance used by inline model tests. |

[All topics](/generated/api)
