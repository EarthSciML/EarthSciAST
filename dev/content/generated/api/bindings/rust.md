---
title: "Rust API index"
description: "Every stable name Rust exports, and its extension seams."
type: "api"
---


**Package:** `earthsci-ast` 0.6.0

Documentation extracted with rustdoc JSON (rustdoc 1.101.0-nightly (21b707e3f 2026-09-30)), format_version 61.

**Capability profiles:** core, classification, simulation, runtime I/O.

Extension-tier names are on the [Rust extension page](/generated/api/extension/rust).

## Stable names

| Rust | Canonical | Kind | Summary |
|---|---|---|---|
| `add_coupling` | [`add_coupling`](/generated/api/ref/add_coupling) | function | Add a coupling entry to an ESM file |
| `add_equation` | [`add_equation`](/generated/api/ref/add_equation) | function | Add an equation to a model |
| `add_reaction` | [`add_reaction`](/generated/api/ref/add_reaction) | function | Add a reaction to a reaction system |
| `add_species` | [`add_species`](/generated/api/ref/add_species) | function | Add a species to a reaction system |
| `add_variable` | [`add_variable`](/generated/api/ref/add_variable) | function | Add a variable to a model |
| `AffectEquation` | [`affect_equation`](/generated/api/ref/affect_equation) | type | Equation that modifies state/parameters when event fires |
| `algebraic_unknowns` | [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns) | function | Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`). |
| `apply_dae_contract` | [`apply_dae_contract`](/generated/api/ref/apply_dae_contract) | function | Run the RFC §12 DAE binding contract on `esm` **in place** and return the classification summary. |
| `apply_scope_injections` | [`apply_scope_injections`](/generated/api/ref/apply_scope_injections) | function | esm-spec §9.7.10 forms A + B: fold any scope-directed injection — a subsystem-ref edge's `injected` import list (form A) or a coupling entry's injection map (form B) — into the… |
| `area_tolerance_ok` | [`area_tolerance_ok`](/generated/api/ref/area_tolerance_ok) | function | The combined relative + absolute area-agreement gate with a sliver floor (B.5 / CONFORMANCE_SPEC.md §5.8.2): |
| `AssertionResult` | [`assertion_result`](/generated/api/ref/assertion_result) | type | Outcome of one §6.6.5 inline-test assertion evaluated through the simulation pathway. |
| `brownian_parameters` | [`brownian_parameters`](/generated/api/ref/brownian_parameters) | function | Parameters whose `update.kind` is `wiener` — the SDE noise sources. |
| `build_reference_graph` | [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | Resolve the reference edges of one `model` value into a graph, against the |
| `build_reference_graph_with_index_sets` | [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | Deprecated alias of `build_reference_graph`. |
| `build_unit_env` | [`build_unit_env`](/generated/api/ref/build_unit_env) | function | Build a `HashMap<String, Unit>` environment from model variable metadata, together with a list of warnings for any variables whose declared unit string could not be parsed. |
| `Cadence` | [`cadence`](/generated/api/ref/cadence) | type | The cadence lattice (`CONFORMANCE_SPEC.md` §5.7.1): `const ⊏ discrete ⊏ continuous`. |
| `CadenceError` | [`cadence_error`](/generated/api/ref/cadence_error) | error | A cadence-partition contract violation in a fixture or producer output (a wrong `expect_cadence`, a `CONTINUOUS` relational node, a `from_faq` cycle, a float topology key, or a… |
| `callbacks` | [`callbacks`](/generated/api/ref/callbacks) | function | The callbacks declared on `prob` (§2.5.4). |
| `CallbackSet` | [`callback_set`](/generated/api/ref/callback_set) | type | The callbacks declared on a `EsmProblem`. |
| `can_migrate` | [`can_migrate`](/generated/api/ref/can_migrate) | function | Whether `migrate` would succeed for this version pair — i.e. whether `to_version` is among `supported_migration_targets``(from_version)`. |
| `canonical_index_set_json` | [`canonical_index_set_json`](/generated/api/ref/canonical_index_set_json) | function | Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the `distinct` rows, each tuple serialised as a JSON array, in §5.5.1 sorted order, as **compact JSON** (`,` /… |
| `canonical_json` | [`canonical_json`](/generated/api/ref/canonical_json) | function | Emit the canonical on-wire JSON form of an expression (§5.4.6). |
| `canonicalize` | [`canonicalize`](/generated/api/ref/canonicalize) | function | Canonicalize an `Expr` tree per RFC §5.4. |
| `CanonicalizeError` | [`canonicalize_error`](/generated/api/ref/canonicalize_error) | error | Errors raised during canonicalization (per RFC §5.4.6 / §5.4.7). |
| `closed_function_names` | [`closed_function_names`](/generated/api/ref/closed_function_names) | function | The closed function set. |
| `ClosedFunctionError` | [`closed_function_error`](/generated/api/ref/closed_function_error) | error | Error type for closed-function dispatch failures (esm-spec §9.1–§9.2). |
| `Compiler` | [`compiler`](/generated/api/ref/compiler) | type | Which strategy builds a Problem's right-hand side (API_SPEC §5.8, esm-libraries-spec §2.5.10). |
| `CompilerReport` | [`compiler_report`](/generated/api/ref/compiler_report) | type | What built a Problem's right-hand side, per rule (API_SPEC §5.8). |
| `component_exists` | [`component_exists`](/generated/api/ref/component_exists) | function | Check if a component exists in the ESM file |
| `component_graph` | [`component_graph`](/generated/api/ref/component_graph-function) | function | Build a component graph from an ESM file |
| `ComponentGraph` | [`component_graph`](/generated/api/ref/component_graph-type) | type | Component graph representing model structure |
| `ComponentNode` | [`component_node`](/generated/api/ref/component_node) | type | Node in the component graph |
| `compose` | [`compose`](/generated/api/ref/compose) | function | Concatenate two callback sets into a new one. |
| `constant_parameters` | [`constant_parameters`](/generated/api/ref/constant_parameters) | function | Parameters with neither a distribution nor an update — plain constants. |
| `contains` | [`contains`](/generated/api/ref/contains) | function | Check if an expression contains a specific variable |
| `ContinuousEvent` | [`continuous_event`](/generated/api/ref/continuous_event) | type | Continuous event that fires on zero-crossings |
| `Contribution` | [`contribution`](/generated/api/ref/contribution) | type | One summand of a flattened equation's right-hand side, with its authors (esm-libraries-spec §4.7.5, "Per-term provenance"). |
| `convert_units` | [`convert_units`](/generated/api/ref/convert_units) | function | Convert between compatible units |
| `Coordinate` | [`coordinate`](/generated/api/ref/coordinate) | type | One entry of the document-scoped `EsmFile::coordinates` registry (RFC streaming-output-sinks §8.3): marks an existing data array — or an inline literal vector — as a physical… |
| `CouplingEdge` | [`coupling_edge`](/generated/api/ref/coupling_edge) | type | Edge in the component graph |
| `CouplingEntry` | [`coupling_entry`](/generated/api/ref/coupling_entry) | type | Coupling entry with discriminated union based on type field |
| `CouplingImportOptions` | [`coupling_import_options`](/generated/api/ref/coupling_import_options) | type | Options controlling how `coupling_import` refs are resolved at flatten. |
| `CouplingRole` | [`coupling_role`](/generated/api/ref/coupling_role) | type | A coupling-library formal component role (esm-spec §10.9). |
| `DaeInfo` | [`dae_info`](/generated/api/ref/dae_info) | type | Summary of DAE classification stamped onto `metadata.dae_info` by `discretize()` per RFC §12. |
| `DataSource` | [`data_source`](/generated/api/ref/data_source) | type | Generic, runtime-agnostic description of an external data source (esm-spec §8). |
| `DataSourceBinding` | [`data_source_binding`](/generated/api/ref/data_source_binding) | type | Binds a parameter to ONE variable of a `data_sources` entry (esm-spec §8.5). |
| `DataSourceDeterminism` | [`data_source_determinism`](/generated/api/ref/data_source_determinism) | type | Reproducibility contract a loader advertises to bindings (esm-spec §8.9.2). |
| `DataSourceKind` | [`data_source_kind`](/generated/api/ref/data_source_kind) | type | Structural kind of a data loader dataset. |
| `DataSourceLocation` | [`data_source_location`](/generated/api/ref/data_source_location) | type | File discovery configuration. |
| `DataSourceTemporal` | [`data_source_temporal`](/generated/api/ref/data_source_temporal) | type | Temporal coverage and record layout for a data source. |
| `Decomposition` | [`decomposition`](/generated/api/ref/decomposition) | type | The horizontal decomposition a tile cuts (RFC U3 §1): the decomposed index sets and the face sets that stagger off them, `(face set, cell set)`. |
| `DEFAULT_ABSTOL` | [`default_abstol`](/generated/api/ref/default_abstol) | constant | The canonical default absolute tolerance — Julia's. |
| `DEFAULT_RELTOL` | [`default_reltol`](/generated/api/ref/default_reltol) | constant | The canonical default relative tolerance. |
| `DependencyEdge` | [`dependency_edge`](/generated/api/ref/dependency_edge) | type | Edge representing dependencies between variables in an expression graph |
| `derive_odes` | [`derive_odes`](/generated/api/ref/derive_odes) | function | Generate ODE model from a reaction system |
| `derive_output_gridding` | [`derive_output_gridding`](/generated/api/ref/derive_output_gridding) | function | Invert the flat state-element names into one `VarGridding` per output base-variable (RFC §7), the flat index of a name being its position in `slot_names` — the shape… |
| `derive_output_meta` | [`derive_output_meta`](/generated/api/ref/derive_output_meta) | function | Distill a run document into `OutputMeta` — the Rust mirror of Julia's `derive_output_meta`. |
| `derive_output_plan` | [`derive_output_plan`](/generated/api/ref/derive_output_plan) | function | Derive the whole output plan for a run. |
| `desugar_pushdown` | [`desugar_pushdown`](/generated/api/ref/desugar_pushdown) | function | Recognise the projection-pushdown pattern in `esm`'s named model and, when it matches, return a NEW document (`Cow::Owned`) with the four constructs desugared in (a… |
| `Dimension` | [`dimension`](/generated/api/ref/dimension) | type | Base physical dimensions — the eight canonical axes shared across the bindings (`m kg s mol K A cd rad`). |
| `discrete_parameters` | [`discrete_parameters`](/generated/api/ref/discrete_parameters) | function | Parameters carrying any OTHER update — piecewise-constant between refreshes. |
| `DiscreteEvent` | [`discrete_event`](/generated/api/ref/discrete_event) | type | Discrete event that can modify the system |
| `DiscreteEventTrigger` | [`discrete_event_trigger`](/generated/api/ref/discrete_event_trigger) | type | Trigger condition for discrete events |
| `distinct` | [`distinct`](/generated/api/ref/distinct) | function | Set semantics over `rows`: sort by the §5.5.1 total order, then drop |
| `Distribution` | [`distribution`](/generated/api/ref/distribution) | type | A parameter's value drawn from a probability distribution rather than fixed (esm-spec §6.3, schema `Distribution`). |
| `Domain` | [`domain`](/generated/api/ref/domain) | type | Spatial/temporal domain specification |
| `EdgeKind` | [`edge_kind`](/generated/api/ref/edge_kind) | type | The three kinds of reference edge (RFC §6.1 "Propagation"). |
| `EditError` | [`edit_error`](/generated/api/ref/edit_error) | error | Errors that can occur during editing operations |
| `EnsembleProblem` | [`ensemble_problem`](/generated/api/ref/ensemble_problem) | type | A EsmProblem plus a per-trajectory rewrite, and the family it stands for (§2.5.8) — the canonical form for parameter sweeps, Monte Carlo over declared distributions, and… |
| `EnumLoweringError` | [`enum_lowering_error`](/generated/api/ref/enum_lowering_error) | error | Stable diagnostic codes raised by the enum-lowering pass. |
| `ephemeral_injected_file` | [`ephemeral_injected_file`](/generated/api/ref/ephemeral_injected_file) | function | esm-spec §9.7.10 form C: build a throwaway `EsmFile` in which component `model_name` has the test's `imports` (raw §9.7.2 entries) appended to its own… |
| `Equation` | [`equation`](/generated/api/ref/equation) | type | Differential equation |
| `error_code_names` | [`error_code_names`](/generated/api/ref/error_code_names) | function | Every diagnostic code string in `ERROR_CODES`, sorted. |
| `ERROR_CODES` | [`error_codes`](/generated/api/ref/error_codes) | constant | The `codes` registry in ENUMERABLE form: `(constant name, code string)` for every diagnostic code this binding emits, in declaration order (grouped by the pass that emits it, as… |
| `esm_problem` | [`esm_problem`](/generated/api/ref/esm_problem-function) | function | Build a `EsmProblem` (§2.5.2). |
| `EsmFile` | [`esm_file`](/generated/api/ref/esm_file) | type | Top-level ESM file structure |
| `EsmProblem` | [`esm_problem`](/generated/api/ref/esm_problem-type) | type | A simulation problem: a document, an interval, and the bindings that fix the document rather than the run. |
| `evaluate` | [`evaluate`](/generated/api/ref/evaluate) | function | Evaluate a scalar AST expression against a map of float variable bindings. |
| `evaluate_cellwise` | [`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise) | function | Evaluate an array-valued expression (elementwise ops over array-producing `faq`/`makearray` nodes — e.g. a grid-geometry template expanded by a §9.7 import, or a §6.6.5 analytic… |
| `evaluate_closed_function` | [`evaluate_closed_function`](/generated/api/ref/evaluate_closed_function) | function | Dispatch a closed function call. |
| `ExactScale` | [`exact_scale`](/generated/api/ref/exact_scale) | type | The EXACT scale of a unit relative to SI (esm-spec §4.8.1 "Scales are EXACT"). |
| `expand_coupling_imports` | [`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports) | function | Expand every `coupling_import` entry in `file.coupling` into concrete edges, splicing them in the position of the import entry (esm-spec §10.10.3). |
| `Expr` | [`expr`](/generated/api/ref/expr) | type | Mathematical expression: a number literal, variable reference, or operator node. |
| `expression_graph` | [`expression_graph`](/generated/api/ref/expression_graph-function) | function | Build an expression graph from various ESM components |
| `ExpressionGraph` | [`expression_graph`](/generated/api/ref/expression_graph-type) | type | Expression graph representing variable dependencies within expressions |
| `ExpressionGraphOptions` | [`expression_graph_options`](/generated/api/ref/expression_graph_options) | type | Settings for `expression_graph_with_options`. |
| `ExpressionParseError` | [`expression_parse_error`](/generated/api/ref/expression_parse_error) | error | Returned when an expression string cannot be parsed. |
| `field_reduce` | [`field_reduce`](/generated/api/ref/field_reduce) | function | Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares (esm-spec §6.6.5); semantics identical to the Julia / Python references: |
| `flatten` | [`flatten`](/generated/api/ref/flatten) | function | Flatten a coupled `EsmFile` into a single unified `FlattenedSystem`. |
| `flatten_with_options` | [`flatten_with_options`](/generated/api/ref/flatten_with_options) | function | Flatten with explicit `CouplingImportOptions` controlling how `coupling_import` `ref`s resolve (esm-spec §10.10.3). |
| `FlattenedSystem` | [`flattened_system`](/generated/api/ref/flattened_system) | type | Spec-compliant flattened coupled system (§4.7.5). |
| `FlattenError` | [`flatten_error`](/generated/api/ref/flatten_error) | error | Errors raised by `flatten` and `flatten_model` during spec-compliant coupled-system flattening. |
| `FlattenMetadata` | [`flatten_metadata`](/generated/api/ref/flatten_metadata) | type | Provenance metadata for a flattening pipeline run. |
| `FloatKeyError` | [`float_key_error`](/generated/api/ref/float_key_error) | error | Raised when a relational key contains a floating-point (or otherwise non-integer / out-of-domain) component, violating `CONFORMANCE_SPEC.md` §5.5.1 rule 1 ("floats are forbidden… |
| `ForcingSet` | [`forcing_set`](/generated/api/ref/forcing_set-type) | type | The forcing a program evaluation reads (API_SPEC §5.8): one immutable buffer per `RhsProgram::forcing_slots` entry, stamped with a process-unique epoch. |
| `ForcingSlot` | [`forcing_slot`](/generated/api/ref/forcing_slot) | type | One buffer of a `ForcingSet`: the variable it serves, its shape, and its kind. |
| `format_canonical_float` | [`format_canonical_float`](/generated/api/ref/format_canonical_float) | function | Format a finite f64 per RFC §5.4.6. |
| `free_parameters` | [`free_parameters`](/generated/api/ref/free_parameters) | function | Extract all free parameters from an expression |
| `free_variables` | [`free_variables`](/generated/api/ref/free_variables) | function | Extract all free variables from an expression |
| `FunctionalUpdate` | [`functional_update`](/generated/api/ref/functional_update) | type | A registered handler computing a parameter's new value when its update fires (esm-spec §5.5). |
| `GeometryError` | [`geometry_error`](/generated/api/ref/geometry_error) | error | An error from the geometry kernel — a degenerate input ring or a failed clip. |
| `get_component_type` | [`get_component_type`](/generated/api/ref/get_component_type) | function | Get the type of a component |
| `get_supported_migration_targets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | Deprecated alias of `supported_migration_targets`. |
| `Graph` | [`graph`](/generated/api/ref/graph) | type | The graph kinds the esm-libraries-spec §4.8.3 text exporters render. |
| `GridPlan` | [`grid_plan`](/generated/api/ref/grid_plan) | type | One grid: a set of variables sharing a spatial-dim signature, with the coordinates and dimension lengths that describe it (RFC §9). |
| `group_aggregate` | [`group_aggregate`](/generated/api/ref/group_aggregate) | function | Group-by + semiring aggregate (rule 5). |
| `group_gridding_by_grid` | [`group_gridding_by_grid`](/generated/api/ref/group_gridding_by_grid) | function | Partition output variables into GRIDS by their spatial-dim signature (RFC §9): variables over the same set of axes form one grid, so an atmosphere over `[lev, lat, lon]` and an… |
| `init` | [`init`](/generated/api/ref/init) | function | Build a stepping integrator for `prob` (§2.5.6). |
| `InlineTestOptions` | [`inline_test_options`](/generated/api/ref/inline_test_options) | type | Per-document overrides for `run_inline_tests_paths`, returned by its `options_for` callback. |
| `Integrator` | [`integrator`](/generated/api/ref/integrator) | type | A stepping integrator (§2.5.6) — the same lifecycle `solve` performs internally, exposed for callers that need to interleave their own work with the integration: the coupling… |
| `intersect_polygon` | [`intersect_polygon`](/generated/api/ref/intersect_polygon) | function | Clip polygon `a` against polygon `b` on the given `manifold`, returning the overlap ring as `(lon, lat)` degree vertices. |
| `is_coupling_library_doc` | [`is_coupling_library_doc`](/generated/api/ref/is_coupling_library_doc) | function | True when `raw` has the coupling-library-file FORM (top-level `coupling_roles`, esm-spec §10.9). |
| `is_ode_state` | [`is_ode_state`](/generated/api/ref/is_ode_state) | function | Membership test for `ode_states`. |
| `is_template_library_doc` | [`is_template_library_doc`](/generated/api/ref/is_template_library_doc) | function | True when `raw` has the template-library-file FORM (top-level `expression_templates`, esm-spec §9.7.1). |
| `LIBRARY_VERSION` | [`library_version`](/generated/api/ref/library_version) | constant | This crate's OWN version — NOT the `.esm` format version, which is `SCHEMA_VERSION`. |
| `load_document` | [`load_document`](/generated/api/ref/load_document) | function | Load and parse an ESM document that is ALREADY parsed as a `serde_json::Value` — the same document a `.esm` file holds, just already decoded. |
| `load_path` | [`load_path`](/generated/api/ref/load_path) | function | Load an ESM file from a filesystem path. |
| `load_string` | [`load_string`](/generated/api/ref/load_string) | function | Load and parse an ESM file from JSON string |
| `LoaderField` | [`loader_field`](/generated/api/ref/loader_field) | type | One provider-served loaded field the flattened system consumes (esm-spec §8.5; esm-libraries-spec §4.7.5 step 4 `loader_fields`). |
| `LoadOptions` | [`load_options`](/generated/api/ref/load_options) | type | Options controlling how `load_string_with_options` / `load_document_with_options` / `load_path_with_options` parse an ESM file (esm-spec §9.7). |
| `lower_enums` | [`lower_enums`](/generated/api/ref/lower_enums) | function | Lower every `enum`-op node in `file` to a `{op: "const", value: <int>}` node using the document's top-level `enums` block, returning a NEW document. |
| `lower_enums_mut` | [`lower_enums_mut`](/generated/api/ref/lower_enums_mut) | function | `lower_enums`, applied in place. |
| `lower_reactions_to_equations` | [`lower_reactions_to_equations`](/generated/api/ref/lower_reactions_to_equations) | function | Lower a reaction network to an ODE equation list. |
| `materialize_value_invention` | [`materialize_value_invention`](/generated/api/ref/materialize_value_invention) | function | Run the build-time value-invention engine over a raw model document. |
| `Metadata` | [`metadata`](/generated/api/ref/metadata) | type | Metadata section |
| `migrate` | [`migrate`](/generated/api/ref/migrate) | function | Migrate an ESM file from the version it declares to `target_version`. |
| `MigrationError` | [`migration_error`](/generated/api/ref/migration_error) | error | Migration error that occurs when migration fails. |
| `Model` | [`model`](/generated/api/ref/model) | type | ODE-based model component |
| `ModelVariable` | [`model_variable`](/generated/api/ref/model_variable) | type | Variable within a model |
| `observed_definitions` | [`observed_definitions`](/generated/api/ref/observed_definitions) | function | Each observed unknown's defining RHS, keyed by name. |
| `observed_field` | [`observed_field`](/generated/api/ref/observed_field) | function | The build-time field named `name`, from `prob`'s construction. |
| `observed_unknowns` | [`observed_unknowns`](/generated/api/ref/observed_unknowns) | function | Unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable, materializable. |
| `ode_states` | [`ode_states`](/generated/api/ref/ode_states) | function | Unknowns appearing under `D(·, t)` on some equation LHS. |
| `Operator` | [`operator`](/generated/api/ref/operator) | type | Runtime operator reference |
| `OutputError` | [`output_error`](/generated/api/ref/output_error) | error | Failure deriving an `OutputPlan` — the output-side mirror of the loader seam's errors. |
| `OutputMeta` | [`output_meta`](/generated/api/ref/output_meta) | type | The document slice a streaming writer needs so it can name axes and emit CF coordinates (RFC §7–§8) without importing the document model. |
| `OutputPlan` | [`output_plan`](/generated/api/ref/output_plan) | type | The full derived output plan: every grid the run produces. |
| `ParameterSweep` | [`parameter_sweep`](/generated/api/ref/parameter_sweep) | type | A parameter-sweep specification on a `ModelAnalysis` (schema `ParameterSweep`). |
| `ParameterUpdate` | [`parameter_update`](/generated/api/ref/parameter_update) | type | One update rule: WHEN a parameter refreshes, and WHAT from (esm-spec §5.4). |
| `ParamSlot` | [`param_slot`](/generated/api/ref/param_slot) | type | One positional parameter of a program: `p[k]` is `RhsProgram::parameters``[k]`. |
| `parse_equation` | [`parse_equation`](/generated/api/ref/parse_equation) | function | Parse `lhs = rhs` into an `Equation`. |
| `parse_expression` | [`parse_expression`](/generated/api/ref/parse_expression) | function | Parse a single expression string into an AST expression — the inverse of `crate::display::to_ascii`. |
| `parse_unit` | [`parse_unit`](/generated/api/ref/parse_unit) | function | Parse a unit string into a Unit struct |
| `Partition` | [`partition`](/generated/api/ref/partition) | type | The partition of one model: the class summary, the materialization-point set, and the hot-tree / per-event-handler emptiness (§5.7.5 three execution outputs). |
| `plan_dimension_coordinates` | [`plan_dimension_coordinates`](/generated/api/ref/plan_dimension_coordinates) | function | Resolve the `coordinates` registry (§8.3) into the CF **dimension coordinates** for a set of `VarGridding`s — the Rust mirror of Julia's `plan_dimension_coordinates`. |
| `Plot` | [`plot`](/generated/api/ref/plot) | type | A plot specification of a `ModelAnalysis` (schema `Plot`). |
| `PlotAxis` | [`plot_axis`](/generated/api/ref/plot_axis) | type | Axis specification of an analysis `Plot` (schema `PlotAxis`). |
| `PlotSeries` | [`plot_series`](/generated/api/ref/plot_series) | type | A single named series of a multi-series line/scatter `Plot` (schema `PlotSeries`). |
| `PlotValue` | [`plot_value`](/generated/api/ref/plot_value) | type | A scalar value derived from a trajectory, used for heatmap / color channels (schema `PlotValue`). |
| `polygon_area` | [`polygon_area`](/generated/api/ref/polygon_area) | function | Unsigned `polygon_area` of an overlap ring under `manifold` — the imperative |
| `rank` | [`rank`](/generated/api/ref/rank) | function | Dense integer renumbering (rule 3) at Rust's native **0-based** emission: assign IDs by position in the sorted `distinct` sequence. |
| `Ranking` | [`ranking`](/generated/api/ref/ranking) | type | Result of `rank`. |
| `Reaction` | [`reaction`](/generated/api/ref/reaction) | type | Chemical reaction |
| `ReactionSystem` | [`reaction_system`](/generated/api/ref/reaction_system) | type | Reaction network component |
| `ReferenceEdge` | [`reference_edge`](/generated/api/ref/reference_edge) | type | A directed `source → target` edge: *source references / depends on target*. |
| `ReferenceError` | [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | Deprecated alias of `ReferenceResolutionError`. |
| `ReferenceGraph` | [`reference_graph`](/generated/api/ref/reference_graph) | type | The resolved reference DAG for one model — the partition pass's input. |
| `ReferenceResolutionError` | [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | A reference could not be resolved, or the reference graph has a cycle. |
| `ReferenceVertex` | [`reference_vertex`](/generated/api/ref/reference_vertex) | type | A vertex in the reference graph, addressed by a kind-namespaced `key`. |
| `reject_solver_external_pre_v13` | [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13) | function | Reject `solver.external` in a file declaring esm &lt; 1.3.0. |
| `reject_solver_pre_v11` | [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) | function | Reject a top-level `solver` block in a file declaring esm &lt; 1.1.0. |
| `reject_solver_time_span_pre_v13` | [`reject_solver_time_span_pre_v13`](/generated/api/ref/reject_solver_time_span_pre_v13) | function | Reject `solver.time_span` in a file declaring esm &lt; 1.3.0. |
| `reject_template_imports_pre_v08` | [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08) | function | `expression_template_imports`, top-level `expression_templates` (template-library files), and `metaparameters` arrive at `esm: 0.8.0`; files declaring an earlier version that… |
| `remake` | [`remake`](/generated/api/ref/remake) | function | A NEW EsmProblem with `changes` applied and everything else shared (§2.5.5). |
| `remove_coupling` | [`remove_coupling`](/generated/api/ref/remove_coupling) | function | Remove a coupling entry from an ESM file by index |
| `remove_equation` | [`remove_equation`](/generated/api/ref/remove_equation) | function | Remove an equation from a model by index |
| `remove_reaction` | [`remove_reaction`](/generated/api/ref/remove_reaction) | function | Remove a reaction from a reaction system by index |
| `remove_species` | [`remove_species`](/generated/api/ref/remove_species) | function | Remove a species from a reaction system |
| `remove_variable` | [`remove_variable`](/generated/api/ref/remove_variable) | function | Remove a variable from a model |
| `resolve_references` | [`resolve_references`](/generated/api/ref/resolve_references) | function | Resolve reference edges for every model in `document`. |
| `resolve_subsystem_refs` | [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) | function | Resolve every subsystem `{ "ref": ... |
| `resolve_template_machinery` | [`resolve_template_machinery`](/generated/api/ref/resolve_template_machinery) | function | Resolve every esm-spec §9.7 construct of the ROOT document `raw_data` (relative import refs resolve against `base_path`): imports recursively with per-edge instantiation,… |
| `resolve_time_span` | [`resolve_time_span`](/generated/api/ref/resolve_time_span) | function | The run interval, most specific first (esm-spec §2.2.7, by the §2.2.2 order): |
| `resolve_tolerances` | [`resolve_tolerances`](/generated/api/ref/resolve_tolerances) | function | Resolve integration tolerances most-specific first (esm-spec §2.2.2): |
| `ReturnCode` | [`return_code`](/generated/api/ref/return_code) | type | Why a solve stopped — the SciML `ReturnCode` vocabulary (`esm-libraries-spec.md` §2.5.3). |
| `rhs_program` | [`rhs_program`](/generated/api/ref/rhs_program) | function | The right-hand side `prob` compiled, as a program `RhsProgram::select`, `RhsProgram::halo`, `RhsProgram::tile` and `RhsProgram::lanes` accept (API_SPEC §5.8). |
| `run_inline_tests` | [`run_inline_tests`](/generated/api/ref/run_inline_tests) | function | Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of the selected model(s) of `file` through the official simulation pathway… |
| `sampled_parameters` | [`sampled_parameters`](/generated/api/ref/sampled_parameters) | function | Parameters with a `distribution` and no update — drawn once at setup. |
| `SCHEMA_VERSION` | [`schema_version`](/generated/api/ref/schema_version) | constant | ESM schema version supported by this implementation. |
| `SchemaError` | [`schema_error`](/generated/api/ref/schema_error-error) | error | A schema validation error |
| `simplify` | [`simplify`](/generated/api/ref/simplify) | function | Simplify an expression (basic symbolic simplification). |
| `SimulateError` | [`simulate_error`](/generated/api/ref/simulate_error) | error | Errors raised building an `crate::problem::EsmProblem` or running `crate::problem::solve`. |
| `skolem` | [`skolem`](/generated/api/ref/skolem) | function | Canonical-tuple Skolem key (rule 4). |
| `skolem_edge` | [`skolem_edge`](/generated/api/ref/skolem_edge) | function | Canonical key for an **undirected** pair (a symmetric relation): `(min(a,b), max(a,b))`. |
| `Solution` | [`solution`](/generated/api/ref/solution) | type | A simulation result. |
| `solve` | [`solve`](/generated/api/ref/solve) | function | Run `prob` to completion (§2.5.3). |
| `Solver` | [`solver`](/generated/api/ref/solver) | type | Document-scoped, OPTIONAL solver hints (esm-spec §2.2). |
| `solver_external_location` | [`solver_external_location`](/generated/api/ref/solver_external_location) | function | Where the document's `solver.external` points (esm-spec §2.2.6), or `Ok(None)` when the document names no run configuration. |
| `SolverTimeSpan` | [`solver_time_span`](/generated/api/ref/solver_time_span) | type | `solver.time_span` (esm-spec §2.2.7): the `{start, end}` shape of `tests[].time_span` (`TimeSpan`), except that each bound may also be an RFC 3339 UTC timestamp, so it is a… |
| `Species` | [`species`](/generated/api/ref/species) | type | Chemical species in a reaction system. |
| `StateBlock` | [`state_block`](/generated/api/ref/state_block) | type | One state variable's block of `u` (API_SPEC §5.8): `shape` column-major from `flat_offset`, first index fastest. |
| `step` | [`step`](/generated/api/ref/step) | function | Advance `integrator` by one grid point (§2.5.6's `step!`). |
| `stoichiometric_matrix` | [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | Generate stoichiometric matrix from a reaction system |
| `StructuralError` | [`structural_error`](/generated/api/ref/structural_error) | error | A structural validation error |
| `substitute` | [`substitute`](/generated/api/ref/substitute) | function | Substitute variables in an expression, returning a new expression. |
| `substitute_in_model` | [`substitute_in_model`](/generated/api/ref/substitute_in_model) | function | Substitute variables in all expressions within a model (equations plus discrete/continuous events; other model fields are cloned unchanged). |
| `substitute_in_model_with_context` | [`substitute_in_model_with_context`](/generated/api/ref/substitute_in_model_with_context) | function | `substitute_in_model` with scoped reference resolution. |
| `substitute_in_reaction_system` | [`substitute_in_reaction_system`](/generated/api/ref/substitute_in_reaction_system) | function | Substitute variables in all reaction-rate expressions within a reaction system. |
| `substitute_in_reaction_system_with_context` | [`substitute_in_reaction_system_with_context`](/generated/api/ref/substitute_in_reaction_system_with_context) | function | `substitute_in_reaction_system` with scoped reference resolution. |
| `substitute_with_context` | [`substitute_with_context`](/generated/api/ref/substitute_with_context) | function | Substitute variables in an expression with scoped reference resolution (esm-spec §2.3.3). |
| `supported_migration_targets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | The schema versions `from_version` can be migrated to. |
| `SweepDimension` | [`sweep_dimension`](/generated/api/ref/sweep_dimension) | type | One axis of a `ParameterSweep` (schema `SweepDimension`): exactly one of `values` / `range` is present. |
| `SweepRange` | [`sweep_range`](/generated/api/ref/sweep_range) | type | Generated range of values for one `SweepDimension` (schema `SweepRange`). |
| `system_kind` | [`system_kind`](/generated/api/ref/system_kind-function) | function | The DERIVED system kind (esm-spec §6.3.1), which a binding uses when the `system_kind` field is absent and checks against when it is present. |
| `SystemKind` | [`system_kind`](/generated/api/ref/system_kind-type) | type | The derived system kind (esm-spec §6.3.1). |
| `TermOrigin` | [`term_origin`](/generated/api/ref/term_origin) | type | Who authored one `Contribution` to a flattened equation (esm-libraries-spec §4.7.5, "Per-term provenance"). |
| `time_origin` | [`time_origin`](/generated/api/ref/time_origin) | function | The time origin in seconds from the POSIX epoch (esm-spec §2.2.7): `domain.temporal.reference_time`, else `domain.temporal.start`, else the epoch itself, as `W0 + f0` -- whole… |
| `TimePoint` | [`time_point`](/generated/api/ref/time_point) | type | One bound of a `SolverTimeSpan`, kept in its authored form. |
| `TimeSpan` | [`time_span`](/generated/api/ref/time_span) | type | Simulation time interval used by inline model tests. |
| `timestamp_to_seconds` | [`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds) | function | `timestamp` as seconds from `source`'s time origin (esm-spec §2.2.7). |
| `to_ascii` | [`to_ascii`](/generated/api/ref/to_ascii) | function | Render `target` as plain ASCII. |
| `to_dot` | [`to_dot`](/generated/api/ref/to_dot) | function | Render `graph` as Graphviz DOT (esm-libraries-spec §4.8.3). |
| `to_json` | [`to_json`](/generated/api/ref/to_json) | function | Serialize an ESM file to JSON string |
| `to_json_compact` | [`to_json_compact`](/generated/api/ref/to_json_compact) | function | Serialize an ESM file to compact JSON string (no pretty printing) |
| `to_json_graph` | [`to_json_graph`](/generated/api/ref/to_json_graph) | function | Render `graph` as a JSON adjacency-list document (esm-libraries-spec §4.8.3). |
| `to_latex` | [`to_latex`](/generated/api/ref/to_latex) | function | Render `target` as LaTeX. |
| `to_mermaid` | [`to_mermaid`](/generated/api/ref/to_mermaid) | function | Render `graph` as Mermaid (esm-libraries-spec §4.8.3). |
| `to_unicode` | [`to_unicode`](/generated/api/ref/to_unicode) | function | Render `target` as Unicode mathematical notation. |
| `Tolerance` | [`tolerance`](/generated/api/ref/tolerance) | type | Numerical comparison tolerance used by inline model tests. |
| `Unit` | [`unit`](/generated/api/ref/unit) | type | Represents a physical unit with dimensions |
| `UNIT_FINDING_ANALYSIS` | [`unit_finding_analysis`](/generated/api/ref/unit_finding_analysis) | constant | See `UNIT_FINDING_DIMENSIONAL_MISMATCH`. |
| `UNIT_FINDING_DIMENSIONAL_MISMATCH` | [`unit_finding_dimensional_mismatch`](/generated/api/ref/unit_finding_dimensional_mismatch) | constant | The cross-binding `code` values a dimensional finding can carry, as surfaced on `crate::validate::UnitWarning::code`. |
| `UNIT_FINDING_DIMENSIONLESS_LITERAL` | [`unit_finding_dimensionless_literal`](/generated/api/ref/unit_finding_dimensionless_literal) | constant | A check site the CURRENT neutral-literal rule passes or skips fails once a nonzero bare numeric literal is read as dimensionless at scale 1 (esm-spec §4.8.6). |
| `UNIT_FINDING_UNPARSEABLE` | [`unit_finding_unparseable`](/generated/api/ref/unit_finding_unparseable) | constant | See `UNIT_FINDING_DIMENSIONAL_MISMATCH`. |
| `UnitFinding` | [`unit_finding`](/generated/api/ref/unit_finding) | type | A single dimensional finding produced while propagating an expression. |
| `UnitWarning` | [`unit_warning`](/generated/api/ref/unit_warning) | type | A dimensional-analysis finding surfaced by validation. |
| `validate` | [`validate`](/generated/api/ref/validate) | function | Perform structural validation on an ESM file |
| `validate_complete` | [`validate_text`](/generated/api/ref/validate_text) | function | Deprecated alias of `validate_text`. |
| `validate_equation_dimensions` | [`validate_equation_dimensions`](/generated/api/ref/validate_equation_dimensions) | function | Validate that an equation's LHS and RHS have matching dimensions. |
| `validate_text` | [`validate_text`](/generated/api/ref/validate_text) | function | Validate an ESM file completely (schema + structural validation) |
| `ValidationResult` | [`validation_result`](/generated/api/ref/validation_result) | type | Result of structural validation |
| `ValueInventionError` | [`value_invention_error`](/generated/api/ref/value_invention_error) | error | A value-invention build-time materialisation error (the Rust analog of Julia's `TreeWalkError` value-invention codes). |
| `ValueInventionResult` | [`value_invention_result`](/generated/api/ref/value_invention_result) | type | Result of `materialize_value_invention`. |
| `VarGridding` | [`var_gridding`](/generated/api/ref/var_gridding) | type | The gridded layout of one output base-variable, derived from the flat state-element names (RFC §7). |
| `VariableKind` | [`variable_kind`](/generated/api/ref/variable_kind) | type | Type/kind of variable, as the graph renders it. |
| `VariableNode` | [`variable_node`](/generated/api/ref/variable_node) | type | Node representing a variable in an expression graph |
| `VarPlan` | [`var_plan`](/generated/api/ref/var_plan) | type | One output variable: what a writer declares, plus the inversion that fills it. |
| `VertexKind` | [`vertex_kind`](/generated/api/ref/vertex_kind) | type | The three kinds of vertex in the reference graph. |
| `write_path` | [`write_path`](/generated/api/ref/write_path) | function | Write an ESM file to `path` as pretty-printed JSON. |
