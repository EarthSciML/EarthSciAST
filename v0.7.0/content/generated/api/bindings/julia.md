---
title: "Julia API index"
description: "Every stable name Julia exports, and its extension seams."
type: "api"
---


**Package:** `EarthSciAST.jl` 0.7.0

Documentation extracted with Base.Docs (Julia 1.13.3).

**Capability profiles:** core, classification, simulation, runtime I/O.

Extension-tier names are on the [Julia extension page](/generated/api/extension/julia).

## Stable names

| Julia | Canonical | Kind | Summary |
|---|---|---|---|
| `add_continuous_event` | [`add_continuous_event`](/generated/api/ref/add_continuous_event) | function | Add a continuous event to a model. |
| `add_coupling` | [`add_coupling`](/generated/api/ref/add_coupling) | function | Add a coupling entry to an ESM file. |
| `add_discrete_event` | [`add_discrete_event`](/generated/api/ref/add_discrete_event) | function | Add a discrete event to a model. |
| `add_equation` | [`add_equation`](/generated/api/ref/add_equation) | function | Add a new equation to a model. |
| `add_reaction` | [`add_reaction`](/generated/api/ref/add_reaction) | function | Add a new reaction to a reaction system. |
| `add_species` | [`add_species`](/generated/api/ref/add_species) | function | Add a new species to a reaction system. |
| `add_variable` | [`add_variable`](/generated/api/ref/add_variable) | function | Add a new variable to a model. |
| `AffectEquation` | [`affect_equation`](/generated/api/ref/affect_equation) | type | Assignment equation for discrete events. |
| `algebraic_unknowns` | [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns) | function | The unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) — those an equation never names as a derivative target or a bare-variable LHS (esm-spec §6.3.1). |
| `apply_unit_conversion` | [`apply_unit_conversion`](/generated/api/ref/apply_unit_conversion) | function | Non-mutating `apply_unit_conversion!`: returns a converted copy, or `values` itself when there is nothing to apply. |
| `apply_unit_conversion!` | [`apply_unit_conversion`](/generated/api/ref/apply_unit_conversion) | function | Apply `conversion` to `values` IN PLACE, producing the variable's declared units (esm-spec §8.5). |
| `AssertionResult` | [`assertion_result`](/generated/api/ref/assertion_result) | type | Outcome of one `(file, container, test, assertion_idx)` evaluation — the ONE result type both inline-test runners produce (`run_esm_tests` over the MTK engine and… |
| `brownian_parameters` | [`brownian_parameters`](/generated/api/ref/brownian_parameters) | function | Parameters whose `update.kind` is `"wiener"` — the SDE noise sources (esm-spec §6.3.1). |
| `build_reference_graph` | [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | Resolve the reference edges of one `model` dict into a graph. |
| `callbacks` | [`callbacks`](/generated/api/ref/callbacks) | function | The problem's own callback set — the composition of its data-refresh, output-sink and checkpoint callbacks, or `nothing` when it has none. |
| `can_migrate` | [`can_migrate`](/generated/api/ref/can_migrate) | function | Whether `migrate` would succeed for this version pair — i.e. whether `to_version` is among `supported_migration_targets``(from_version)`. |
| `canonical_json` | [`canonical_json`](/generated/api/ref/canonical_json) | function | Emit the canonical on-wire JSON form of an expression per RFC §5.4.6: keys sorted, no extraneous whitespace, shortest round-trip floats with trailing-`.0` disambiguation for… |
| `canonicalize` | [`canonicalize`](/generated/api/ref/canonicalize) | function | Canonicalize an expression tree per discretization RFC §5.4. |
| `CanonicalizeError` | [`canonicalize_error`](/generated/api/ref/canonicalize_error) | error | Error raised by `canonicalize` / `canonical_json`. |
| `closed_function_names` | [`closed_function_names`](/generated/api/ref/closed_function_names) | function | Return the v0.3.0 closed function set. |
| `ClosedFunctionError` | [`closed_function_error`](/generated/api/ref/closed_function_error) | error | Raised by the closed function registry when the spec contract is violated. |
| `CompilerReport` | [`compiler_report`](/generated/api/ref/compiler_report) | type | What a build did, per rule. |
| `component_graph` | [`component_graph`](/generated/api/ref/component_graph-function) | function | Generate component-level graph showing systems and their couplings. |
| `ComponentNode` | [`component_node`](/generated/api/ref/component_node) | type | Component-level node representing a model, reaction system, data source, or operator. |
| `compose` | [`compose`](/generated/api/ref/compose) | function | Convenience function to create an operator_compose coupling entry linking two systems. |
| `ConflictingDerivativeError` | [`conflicting_derivative_error`](/generated/api/ref/conflicting_derivative_error) | error | Raised when a species appears both as the left-hand side of an explicit differential equation (`D(X, t) = ...`) and as a substrate or product of any reaction in the same… |
| `constant_parameters` | [`constant_parameters`](/generated/api/ref/constant_parameters) | function | Parameters with neither a `distribution` nor an `update` — plain constants. |
| `ContinuousEvent` | [`continuous_event`](/generated/api/ref/continuous_event) | type | Event triggered by zero-crossing of condition expressions. |
| `Contribution` | [`contribution`](/generated/api/ref/contribution) | type | One summand of a flattened equation's right-hand side, with its authors. |
| `CouplingCouple` | [`coupling_couple`](/generated/api/ref/coupling_couple) | type | Bi-directional coupling via connector equations. |
| `CouplingEdge` | [`coupling_edge`](/generated/api/ref/coupling_edge) | type | Edge representing coupling between components. |
| `CouplingEntry` | [`coupling_entry`](/generated/api/ref/coupling_entry) | type | Abstract base type for coupling entries that connect model components. |
| `CouplingImport` | [`coupling_import`](/generated/api/ref/coupling_import) | type | Reuse of a coupling-library file (esm-spec §10.9, §10.10). |
| `CyclicPromotionError` | [`cyclic_promotion_error`](/generated/api/ref/cyclic_promotion_error) | error | Defined for cross-language error-name parity. |
| `DataSource` | [`data_source`](/generated/api/ref/data_source) | type | Generic, runtime-agnostic description of an external dataset (esm-spec §8). |
| `DataSourceBinding` | [`data_source_binding`](/generated/api/ref/data_source_binding) | type | Binds a parameter to one file variable of a `data_sources` entry (esm-spec §8.5) — the `from` value form of a `data` update. |
| `DataSourceDeterminism` | [`data_source_determinism`](/generated/api/ref/data_source_determinism) | type | Reproducibility contract a source advertises to bindings (esm-spec §8.1). |
| `DataSourceLocation` | [`data_source_location`](/generated/api/ref/data_source_location) | type | File discovery configuration for a data source (the schema's `DataSource.source` object). |
| `DataSourceTemporal` | [`data_source_temporal`](/generated/api/ref/data_source_temporal) | type | Temporal coverage and record layout for a data source (esm-spec §8.3). |
| `declared_system_kind` | [`declared_system_kind`](/generated/api/ref/declared_system_kind) | function | The `system_kind` the model DECLARES, verbatim, or `nothing` when the field is absent. |
| `Decomposition` | [`decomposition`](/generated/api/ref/decomposition) | type | A horizontal decomposition (API_SPEC §5.8): the index sets a tiling cuts, each with its period (`nothing` when the axis is not periodic; otherwise the axis's global extent), and… |
| `default_forcing_set` | [`default_forcing_set`](/generated/api/ref/default_forcing_set) | function | The Problem's forcing when `rhs_program` ran — provider data, a caller's array, or the declared default broadcast over the slot's shape, and an array parameter's value — copied… |
| `DependencyEdge` | [`dependency_edge`](/generated/api/ref/dependency_edge) | type | Edge representing dependency between variables. |
| `derive_odes` | [`derive_odes`](/generated/api/ref/derive_odes) | function | Generate an ODE model from a reaction system using standard mass action kinetics. |
| `derive_output_gridding` | [`derive_output_gridding`](/generated/api/ref/derive_output_gridding) | function | Invert the flat `var_map` (state-element name → flat index) into one `VarGridding` per output base-variable (RFC §7). |
| `derive_output_meta` | [`derive_output_meta`](/generated/api/ref/derive_output_meta) | function | Distill the flattened run document into `OutputMeta`: the model names, the `index_sets` axis lengths, each variable's declared `shape` (real dim names) + retained CF attrs +… |
| `derive_output_plan` | [`derive_output_plan`](/generated/api/ref/derive_output_plan) | function | Derive the whole output plan for a run (RFC §7–§9) — the Julia mirror of `earthsci_ast::data_output::derive_output_plan`. |
| `DimensionPromotionError` | [`dimension_promotion_error`](/generated/api/ref/dimension_promotion_error) | error | Raised during flatten when a variable or equation cannot be promoted from its source domain to the target domain given the available `Interface` rules (§4.7.6). |
| `discrete_parameters` | [`discrete_parameters`](/generated/api/ref/discrete_parameters) | function | Parameters carrying any update OTHER than `wiener` — piecewise-constant between refreshes (esm-spec §6.3.1). |
| `DiscreteEvent` | [`discrete_event`](/generated/api/ref/discrete_event) | type | Event triggered by discrete triggers whose symbolic `affects` are `AffectEquation`s (`lhs` target name, `rhs` new-value expression) — the schema's `AffectEquation` shape, shared… |
| `DiscreteEventTrigger` | [`discrete_event_trigger`](/generated/api/ref/discrete_event_trigger) | type | Abstract base type for discrete event triggers. |
| `Distribution` | [`distribution`](/generated/api/ref/distribution) | type | A parameter's value drawn from a probability distribution rather than fixed (esm-spec §6.3, schema `Distribution`). |
| `Domain` | [`domain`](/generated/api/ref/domain) | type | Spatial and temporal domain specification. |
| `DomainExtentMismatchError` | [`domain_extent_mismatch_error`](/generated/api/ref/domain_extent_mismatch_error) | error | Defined for cross-language error-name parity with the Rust `FlattenError` taxonomy and the Python `flatten()` exception set. |
| `DomainUnitMismatchError` | [`domain_unit_mismatch_error`](/generated/api/ref/domain_unit_mismatch_error) | error | Raised when coupling across an `Interface` requires a unit conversion that was not declared by the user (§4.7.6). |
| `EarthSciASTError` | [`earth_sci_ast_error`](/generated/api/ref/earth_sci_ast_error) | error | Abstract supertype of every exception raised by `EarthSciAST`. |
| `EditError` | [`edit_error`](/generated/api/ref/edit_error) | error | Exception thrown when an editing operation cannot be applied — e.g. removing a variable, equation, reaction, event, or coupling entry that does not exist, or extracting a missing… |
| `effective_system_kind` | [`effective_system_kind`](/generated/api/ref/effective_system_kind) | function | `declared_system_kind` when the model declares one, otherwise the derived `system_kind`. |
| `EnumLoweringError` | [`enum_lowering_error`](/generated/api/ref/enum_lowering_error) | error | Raised when enum lowering (esm-spec §9.3) fails, carrying the stable diagnostic `code` as a structured field rather than interpolated into the message — the same shape as… |
| `Equation` | [`equation`](/generated/api/ref/equation) | type | Mathematical equation with left-hand side and right-hand side expressions. |
| `error_code_names` | [`error_code_names`](/generated/api/ref/error_code_names) | function | Every diagnostic code string in `ERROR_CODES`, sorted. |
| `ERROR_CODES` | [`error_codes`](/generated/api/ref/error_codes) | constant | The registry itself: a `NamedTuple` mapping each SCREAMING_SNAKE_CASE name to the stable diagnostic code string it stands for. |
| `esm_problem` | [`esm_problem`](/generated/api/ref/esm_problem-function) | function | Build the ESM simulation problem for `input` over `tspan = (t0, t1)` — the one noun of esm-libraries-spec §2.5. |
| `EsmFile` | [`esm_file`](/generated/api/ref/esm_file) | type | Main ESM file structure containing all components. |
| `EsmProblem` | [`esm_problem`](/generated/api/ref/esm_problem-type) | type | The ESM simulation problem: the right-hand side `f!` the chosen `compiler` built — the compiled tree walk under `:native` / `:interpreter`, the compiled StableHLO program under… |
| `evaluate_cellwise` | [`evaluate_cellwise`](/generated/api/ref/evaluate_cellwise) | function | Evaluate an array-valued expression (elementwise ops over array-producing `faq`/`makearray` nodes — e.g. a grid-geometry template expanded by a §9.7 import, or a §6.6.5 analytic… |
| `evaluate_closed_function` | [`evaluate_closed_function`](/generated/api/ref/evaluate_closed_function) | function | Dispatch a closed function call. |
| `expand_coupling_imports` | [`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports) | function | Expand every `CouplingImport` entry in `file.coupling` into concrete edges, splicing them in the position of the import entry (esm-spec §10.10.3). |
| `expression_graph` | [`expression_graph`](/generated/api/ref/expression_graph-function) | function | The variable-level dependency graph (esm-libraries-spec §4.8.2): one `VariableNode` per variable, and a `DependencyEdge` from each variable an equation or reaction reads to the… |
| `ExpressionParseError` | [`expression_parse_error`](/generated/api/ref/expression_parse_error) | error | Thrown when an expression string cannot be parsed by `parse_expression` or `parse_equation`. |
| `ExpressionTemplateError` | [`expression_template_error`](/generated/api/ref/expression_template_error) | error | Exception raised when a load-time lowering pass fails: expression-template expansion (esm-spec §9.6), template-library imports (§9.7), coupling-library imports (§10.9–§10.11),… |
| `extract` | [`extract`](/generated/api/ref/extract) | function | Extract a single component into a standalone ESM file. |
| `field_reduce` | [`field_reduce`](/generated/api/ref/field_reduce) | function | Collapse a spatial field to the scalar a §6.6.5 `reduce` assertion compares (esm-spec §6.6.5): |
| `flatten` | [`flatten`](/generated/api/ref/flatten) | function | Flatten the coupled systems in `file` into a single symbolic representation per spec §4.7.5 (+ §4.7.6 for hybrid dimension-promoted cases). |
| `FlattenedSystem` | [`flattened_system`](/generated/api/ref/flattened_system) | type | A coupled ESM file flattened into a single symbolic representation. |
| `FlattenMetadata` | [`flatten_metadata`](/generated/api/ref/flatten_metadata) | type | Provenance metadata for a flattened system. |
| `forcing_set` | [`forcing_set`](/generated/api/ref/forcing_set-function) | function | A forcing set for `x` (API_SPEC §5.8): `bufs` holds one buffer per `forcing_slots``(x)` entry, in slot order, each of `prod(shape)` elements read in linear (column-major) order. |
| `ForcingSet` | [`forcing_set`](/generated/api/ref/forcing_set-type) | type | The forcing inputs of an evaluation (API_SPEC §5.8): one column-major buffer per `forcing_slots` entry, in slot order, and an epoch no other set in the process carries. |
| `ForcingSlot` | [`forcing_slot`](/generated/api/ref/forcing_slot) | type | One buffer of a `ForcingSet` (`forcing_slots`): the flattened `name`, its resolved `shape` (empty for a 0-d input) and its `kind`: `:forcing` (an externally fed parameter: its… |
| `format_canonical_float` | [`format_canonical_float`](/generated/api/ref/format_canonical_float) | function | Format a finite `Float64` per RFC §5.4.6. |
| `free_variables` | [`free_variables`](/generated/api/ref/free_variables) | function | Extract all free (unbound) variable names from an expression. |
| `FunctionalUpdate` | [`functional_update`](/generated/api/ref/functional_update) | type | A registered handler that computes a parameter's new value when its update fires (esm-spec §5.5). |
| `FunctionTable` | [`function_table`](/generated/api/ref/function_table) | type | A sampled function table referenced by `table_lookup` AST op nodes (esm-spec §9.5, v0.4.0). |
| `FunctionTableAxis` | [`function_table_axis`](/generated/api/ref/function_table_axis) | type | A single named axis inside a `FunctionTable` (esm-spec §9.5). |
| `Graph` | [`graph`](/generated/api/ref/graph) | type | Generic graph structure with nodes and edges. |
| `GridPlan` | [`grid_plan`](/generated/api/ref/grid_plan) | type | One emergent grid (RFC §9): the ordered SPATIAL `dims` (`name => length`; empty for the scalar grid — the record axis is not included, see `time_dim`), the record-axis name, the… |
| `group_gridding_by_grid` | [`group_gridding_by_grid`](/generated/api/ref/group_gridding_by_grid) | function | Partition output variables into GRIDS by their spatial-dim signature (RFC §9): variables that live on the same set of axes form one grid, so an atmosphere over `[lev, lat, lon]`… |
| `halo` | [`halo`](/generated/api/ref/halo) | function | The halo report (API_SPEC §5.8): for every state the operator reads and every cut or face index set on its shape, `(variable, set) => (lo, hi)`, how far the owned output reaches… |
| `InlineTestOptions` | [`inline_test_options`](/generated/api/ref/inline_test_options) | type | Per-document overrides for `run_inline_tests`, returned by its `options_for` callback. |
| `is_ode_state` | [`is_ode_state`](/generated/api/ref/is_ode_state) | function | Membership test for `ode_states`. |
| `lanes` | [`lanes`](/generated/api/ref/lanes) | function | The operator over a run-time list of cells (`kind = :cells`, `sets` every index set of the written variables' shape) or columns (`kind = :columns`, `sets` the horizontal sets)… |
| `LIBRARY_VERSION` | [`library_version`](/generated/api/ref/library_version) | constant | This package's OWN version, read from its `Project.toml` — NOT the `.esm` format version, which is `SCHEMA_VERSION`. |
| `load_document` | [`load_document`](/generated/api/ref/load_document) | function | Parse an ESM document held in memory as a native Julia dict — the same document a `.esm` file holds, just already parsed. |
| `load_path` | [`load_path`](/generated/api/ref/load_path) | function | Read and parse an ESM document from a filesystem path. |
| `load_string` | [`load_string`](/generated/api/ref/load_string) | function | Parse an ESM document from JSON TEXT — held as a `String`, or streamed from an `IO` the method reads to a string first (the `::IO` method is a sanctioned Julia decoration on the… |
| `lower_enums` | [`lower_enums`](/generated/api/ref/lower_enums) | function | The PURE form: return a DEEP COPY of `file` with every `enum` op replaced by the `const` integer the file's `enums` block assigns it, leaving `file` untouched. |
| `lower_enums!` | [`lower_enums`](/generated/api/ref/lower_enums) | function | Walk every expression tree in `file` and replace each `enum` op with a `const` integer per the file's `enums` block. |
| `lower_expression_templates` | [`lower_expression_templates`](/generated/api/ref/lower_expression_templates) | function | Run the §9.6.3 rewrite fixpoint over `raw_data` against each component-local `expression_templates` block (esm-spec §9.6.4, Option B): auto `match` rules fire, EAGER… |
| `lower_reactions_to_equations` | [`lower_reactions_to_equations`](/generated/api/ref/lower_reactions_to_equations) | function | Produce the ODE equations induced by a set of reactions using standard mass-action kinetics: `d[X]/dt = Σ (stoich_ij * rate_j)`. |
| `map_variable` | [`map_variable`](/generated/api/ref/map_variable) | function | Convenience function to create a variable_map coupling entry that forwards a variable reference `from` into `to`. |
| `Metadata` | [`metadata`](/generated/api/ref/metadata) | type | Authorship, provenance, and description metadata. |
| `migrate` | [`migrate`](/generated/api/ref/migrate) | function | Migrate `file` from the version it declares to `target_version`. |
| `MigrationError` | [`migration_error`](/generated/api/ref/migration_error) | error | Thrown when `migrate` is asked for a version pair it does not support — including every pair that crosses the 1.0.0 clean break. |
| `Model` | [`model`](/generated/api/ref/model) | type | ODE-based model component containing variables, equations, and optional subsystems. |
| `ModelVariable` | [`model_variable`](/generated/api/ref/model_variable) | type | A model variable: an `unknown` the solver solves for, or a `parameter` supplied to it (esm-spec §6.3). |
| `observed_definition` | [`observed_definition`](/generated/api/ref/observed_definition) | function | The defining right-hand side of the observed unknown `name`, or `nothing` when it is not an observed unknown of `model`. |
| `observed_definitions` | [`observed_definitions`](/generated/api/ref/observed_definitions) | function | Each observed unknown mapped to its DEFINING EQUATION's right-hand side. |
| `observed_field` | [`observed_field`](/generated/api/ref/observed_field) | function | The observed `name` of the problem, as a flat vector in row-major cell order (last index fastest; one element for a scalar observed). |
| `observed_unknowns` | [`observed_unknowns`](/generated/api/ref/observed_unknowns) | function | The unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable and materializable (esm-spec §6.3.1). |
| `ode_states` | [`ode_states`](/generated/api/ref/ode_states) | function | The unknowns appearing under `D(·, t)` on some equation LHS — the quantities the solver integrates (esm-spec §6.3.1). |
| `OperatorComposeAmbiguousBareNameError` | [`operator_compose_ambiguous_bare_name_error`](/generated/api/ref/operator_compose_ambiguous_bare_name_error) | error | Raised when the bare-name fallback would unify two STATE variables and the document has not said which spelling survives (esm-libraries-spec §4.7.1 step 3). |
| `OperatorComposeNoMergeError` | [`operator_compose_no_merge_error`](/generated/api/ref/operator_compose_no_merge_error) | error | Raised when an `operator_compose` entry merges NOTHING (esm-libraries-spec §4.7.1 step 5). |
| `OperatorComposeRequireMatchError` | [`operator_compose_require_match_error`](/generated/api/ref/operator_compose_require_match_error) | error | Raised when an `operator_compose` entry declares `require_match: true` and one of `systems[2]`'s equations found no equation of `systems[1]` to land on (esm-libraries-spec §4.7.1… |
| `OutputError` | [`output_error`](/generated/api/ref/output_error) | error | Thrown by the streaming-output surface: an unimplemented Sink protocol method, a malformed snapshot, an output request that designates no single variable, or a call to… |
| `OutputMeta` | [`output_meta`](/generated/api/ref/output_meta) | type | The document-derived output metadata carried by an `EsmProblem` so a streaming sink can name axes and emit CF coordinates (RFC §7–§8). |
| `OutputPlan` | [`output_plan`](/generated/api/ref/output_plan) | type | The full derived output plan: one `GridPlan` per emergent grid, in first-seen signature order. |
| `Parameter` | [`parameter`](/generated/api/ref/parameter) | type | A reaction system's parameter (`reaction_systems.*.parameters.*`) — the reaction-side twin of a `ModelVariable` of `ParameterVariable` type, and it carries the SAME value model… |
| `parameter_names` | [`parameters`](/generated/api/ref/parameters) | function | Deprecated alias of `parameters` (API_SPEC.md §8 item 6). |
| `parameters` | [`parameters`](/generated/api/ref/parameters) | function | Every `parameter` declared by `model`, sorted lexicographically. |
| `ParameterUpdate` | [`parameter_update`](/generated/api/ref/parameter_update) | type | One rule saying WHEN a parameter refreshes and WHAT it refreshes from (esm-spec §5.4). |
| `ParamSlot` | [`param_slot`](/generated/api/ref/param_slot) | type | One entry of a program's parameter vector (`parameters`): the flattened parameter `name` and its declared `default` (`nothing` when it declares none). |
| `parse_equation` | [`parse_equation`](/generated/api/ref/parse_equation) | function | Parse `lhs = rhs` into an `Equation`. |
| `parse_expression` | [`parse_expression`](/generated/api/ref/parse_expression) | function | Parse a single expression string in the INFIX TEXT form into an AST expression — the inverse of `to_ascii`. |
| `parse_unit_conversion` | [`parse_unit_conversion`](/generated/api/ref/parse_unit_conversion) | function | Parse a loader variable's RAW `unit_conversion` (`number \| Expression`). |
| `ParseError` | [`parse_error`](/generated/api/ref/parse_error) | error | Exception thrown when JSON parsing fails. |
| `plan_dimension_coordinates` | [`plan_dimension_coordinates`](/generated/api/ref/plan_dimension_coordinates) | function | Resolve the `coordinates` registry (§8.3) into the CF **dimension coordinates** for a set of `VarGridding`s: for each distinct spatial dim, if the registry has an entry KEYED BY… |
| `Reaction` | [`reaction`](/generated/api/ref/reaction) | type | Chemical reaction with substrates, products, and rate expression. |
| `ReactionSystem` | [`reaction_system`](/generated/api/ref/reaction_system) | type | Collection of chemical reactions with associated species, supporting hierarchical composition. |
| `Reference` | [`reference`](/generated/api/ref/reference) | type | Academic citation or data source reference. |
| `ReferenceEdge` | [`reference_edge`](/generated/api/ref/reference_edge) | type | A directed `source → target` edge: *source references / depends on target*. |
| `ReferenceGraph` | [`reference_graph`](/generated/api/ref/reference_graph) | type | The resolved reference DAG for one model — the partition pass's input. |
| `ReferenceResolutionError` | [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | A reference could not be resolved, or the reference graph has a cycle. |
| `ReferenceVertex` | [`reference_vertex`](/generated/api/ref/reference_vertex) | type | A vertex in the reference graph, addressed by a kind-namespaced `key` (`"$kind:$name"`). |
| `reject_expression_templates_pre_v04` | [`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) | function | Reject `expression_templates` blocks and `apply_expression_template` ops in files declaring `esm` &lt; 0.4.0. |
| `reject_solver_external_pre_v13` | [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13) | function | Reject `solver.external` in a file declaring `esm` &lt; 1.3.0. |
| `reject_solver_pre_v11` | [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) | function | Reject a top-level `solver` block in a file declaring `esm` &lt; 1.1.0. |
| `reject_solver_time_span_pre_v13` | [`reject_solver_time_span_pre_v13`](/generated/api/ref/reject_solver_time_span_pre_v13) | function | Reject `solver.time_span` in a file declaring `esm` &lt; 1.3.0. |
| `reject_template_imports_pre_v08` | [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08) | function | `expression_template_imports`, top-level `expression_templates` (template-library files), and `metaparameters` arrive at `esm: 0.8.0`; files declaring an earlier version that… |
| `remove_coupling` | [`remove_coupling`](/generated/api/ref/remove_coupling) | function | Remove a coupling entry by index (1-based). |
| `remove_equation` | [`remove_equation`](/generated/api/ref/remove_equation) | function | Remove an equation from a model. |
| `remove_event` | [`remove_event`](/generated/api/ref/remove_event) | function | Remove events whose `description` field equals `description` from a model. |
| `remove_reaction` | [`remove_reaction`](/generated/api/ref/remove_reaction) | function | Remove a reaction by its ID. |
| `remove_species` | [`remove_species`](/generated/api/ref/remove_species) | function | Remove a species from a reaction system. |
| `remove_variable` | [`remove_variable`](/generated/api/ref/remove_variable) | function | Remove a variable from a model. |
| `rename_variable` | [`rename_variable`](/generated/api/ref/rename_variable) | function | Rename a variable throughout the model. |
| `resolve_references` | [`resolve_references`](/generated/api/ref/resolve_references) | function | Resolve reference edges for every model in `document`. |
| `resolve_subsystem_refs!` | [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) | function | Resolve all subsystem references in-place. |
| `resolve_template_machinery` | [`resolve_template_machinery`](/generated/api/ref/resolve_template_machinery) | function | Resolve every esm-spec §9.7 construct of the ROOT document `raw_data` (relative import refs resolve against `base_path`): imports recursively with per-edge instantiation,… |
| `resolve_time_span` | [`resolve_time_span`](/generated/api/ref/resolve_time_span) | function | The interval to simulate `file` over, most specific first (esm-spec §2.2.7): |
| `resolve_tolerances` | [`resolve_tolerances`](/generated/api/ref/resolve_tolerances) | function | Resolve integration tolerances most-specific first (esm-spec §2.2.2): |
| `restrict` | [`restrict`](/generated/api/ref/restrict) | function | The operator restricted to one tile (API_SPEC §5.8, "Tile semantics"): `owned` and `storage` give one inclusive range per cut axis (`"lon" => 17:32`), in global coordinates,… |
| `rhs_program` | [`rhs_program`](/generated/api/ref/rhs_program) | function | The Problem's right-hand side as a program value (API_SPEC §5.8): the whole model over the whole domain, with `u` every state of the Problem (in the Problem's flat layout) and… |
| `run_inline_tests` | [`run_inline_tests`](/generated/api/ref/run_inline_tests) | function | Run every inline test (esm-spec §6.6, including the §6.6.5 PDE assertions) of the selected component(s) of `inputs` through the official tree-walk simulation pathway, and return… |
| `sampled_parameters` | [`sampled_parameters`](/generated/api/ref/sampled_parameters) | function | Parameters with a `distribution` and no `update` — drawn ONCE at setup (uncertainty quantification, ensembles). |
| `SCHEMA_VERSION` | [`schema_version`](/generated/api/ref/schema_version) | constant | The `.esm` FORMAT version (semver string) this implementation targets — the value written into the `esm` field of freshly constructed files. |
| `SchemaError` | [`schema_error`](/generated/api/ref/schema_error-type) | type | Represents a validation error with detailed information. |
| `SchemaValidationError` | [`schema_validation_error`](/generated/api/ref/schema_validation_error) | error | Exception thrown when schema validation fails. |
| `select` | [`select`](/generated/api/ref/select) | function | The program of one operator (API_SPEC §5.8, "Selection"): every flattened equation keeps the contributions whose #539 origins intersect `terms` (a vector of `TermOrigin`, matched… |
| `simplify` | [`simplify`](/generated/api/ref/simplify) | function | Perform constant folding and algebraic simplification on an expression. |
| `SimulateError` | [`simulate_error`](/generated/api/ref/simulate_error) | error | Exception thrown when a simulation Problem cannot be built or run (API_SPEC §5.8): `esm_problem` given a missing file or an unsupported input, an override in `p` / `u0` that… |
| `SliceOutOfDomainError` | [`slice_out_of_domain_error`](/generated/api/ref/slice_out_of_domain_error) | error | Defined for cross-language error-name parity; only raised if `slice` is ever implemented at a higher tier in the Julia flatten pipeline. |
| `Solver` | [`solver`](/generated/api/ref/solver) | type | Document-scoped, OPTIONAL solver hints (esm-spec §2.2) — numerics the document knows about *itself*, which each binding maps to its own integrator — plus `external`, a reference… |
| `solver_external_location` | [`solver_external_location`](/generated/api/ref/solver_external_location) | function | Where the document's `solver.external` points (esm-spec §2.2.6), or `nothing` when its `solver` block carries no `external`. |
| `SolverTimeSpan` | [`solver_time_span`](/generated/api/ref/solver_time_span) | type | The `solver.time_span` interval (esm-spec §2.2.7): the period the document is meant to be simulated over. |
| `Species` | [`species`](/generated/api/ref/species) | type | Chemical species definition with name and optional properties. |
| `StateBlock` | [`state_block`](/generated/api/ref/state_block) | type | One block of a program's `u` (`state_layout`): the flattened state `name`, the 1-based `offset` of its first element, and its `shape` (empty for a 0-d state). |
| `stoichiometric_matrix` | [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | Compute the net stoichiometric matrix (species × reactions). |
| `substitute` | [`substitute`](/generated/api/ref/substitute) | function | Replace every variable named in `bindings` with its replacement expression, throughout `expr` (including faq bodies, filter predicates, integral bounds and every other… |
| `substitute_in_equations` | [`substitute_in_equations`](/generated/api/ref/substitute_in_equations) | function | Apply substitutions across all equations in a model. |
| `SubsystemRefError` | [`subsystem_ref_error`](/generated/api/ref/subsystem_ref_error) | error | Exception thrown when subsystem reference resolution fails. |
| `supported_migration_targets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | The schema versions `source_version` can be migrated to. |
| `system_kind` | [`system_kind`](/generated/api/ref/system_kind-function) | function | Derive what the `system_kind` field declares (esm-spec §6.3.1). |
| `TermOrigin` | [`term_origin`](/generated/api/ref/term_origin) | type | Who authored one `Contribution`. |
| `time_origin` | [`time_origin`](/generated/api/ref/time_origin) | function | The time origin in seconds from the POSIX epoch: the instant `domain.temporal.reference_time` — else `domain.temporal.start`, else the epoch itself — names, as `W₀ + f₀`, whole… |
| `timestamp_to_seconds` | [`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds) | function | `timestamp`, an RFC 3339 UTC timestamp (`YYYY-MM-DDThh:mm:ss[.f]Z` — the `solver.time_span` bound form), as seconds from the time origin of `file` or of `domain` (typed, raw JSON… |
| `to_ascii` | [`to_ascii`](/generated/api/ref/to_ascii) | function | Format target as plain ASCII mathematical notation. |
| `to_dot` | [`to_dot`](/generated/api/ref/to_dot) | function | Export graph to DOT format for Graphviz rendering. |
| `to_json` | [`to_json`](/generated/api/ref/to_json) | function | Serialize an `EsmFile` to wire-form JSON. |
| `to_json_compact` | [`to_json_compact`](/generated/api/ref/to_json_compact) | function | The single-line wire form. |
| `to_json_graph` | [`to_json_graph`](/generated/api/ref/to_json_graph) | function | Export graph to the JSON adjacency list of esm-libraries-spec §4.8.3. |
| `to_julia_code` | [`to_julia_code`](/generated/api/ref/to_julia_code) | function | Generate a Julia script from an ESM file. |
| `to_latex` | [`to_latex`](/generated/api/ref/to_latex) | function | Format `target` as LaTeX mathematical notation (`\frac{\partial N}{\partial t} = -\lambda \cdot N`). |
| `to_mermaid` | [`to_mermaid`](/generated/api/ref/to_mermaid) | function | Export graph to Mermaid format for markdown embedding. |
| `to_unicode` | [`to_unicode`](/generated/api/ref/to_unicode) | function | Format `target` as Unicode mathematical notation (`∂N/∂t = −λ·N`). |
| `UNIT_FINDING_DIMENSIONLESS_LITERAL` | [`unit_finding_dimensionless_literal`](/generated/api/ref/unit_finding_dimensionless_literal) | constant | The `UnitWarning.code` of a check site that the current neutral-literal rule passes or skips but that fails once a bare numeric literal is read as dimensionless at scale 1… |
| `UnitConversionError` | [`unit_conversion_error`](/generated/api/ref/unit_conversion_error) | error | A `unit_conversion` that cannot be parsed or applied. |
| `UnitFinding` | [`unit_finding`](/generated/api/ref/unit_finding) | type | A units finding: `subpath` RELATIVE to the owning model's JSON pointer (e.g. `"equations/0"`, `"variables/invalid_sum"`), a human-readable `message`, and the esm-spec §4.8.4… |
| `UnitWarning` | [`unit_warning`](/generated/api/ref/unit_warning) | type | A single dimensional-analysis finding, in the STRUCTURED form the Python, TypeScript and Go bindings have always used and Julia did not: this field was a bare `Vector{String}`,… |
| `unknown_names` | [`unknowns`](/generated/api/ref/unknowns) | function | Deprecated alias of `unknowns` (API_SPEC.md §8 item 6). |
| `unknowns` | [`unknowns`](/generated/api/ref/unknowns) | function | Every `unknown` declared by `model`, sorted lexicographically. |
| `UnmappedDomainError` | [`unmapped_domain_error`](/generated/api/ref/unmapped_domain_error) | error | Raised when two systems on different domains are coupled without an `Interface` that defines their dimension mapping (§4.7.6). |
| `UnsupportedMappingError` | [`unsupported_mapping_error`](/generated/api/ref/unsupported_mapping_error) | error | Raised when an `Interface` requests a `dimension_mapping` type or regridding strategy that is not supported by the current library tier (§4.7.6). |
| `validate` | [`validate`](/generated/api/ref/validate) | function | Complete validation combining schema, structural, and unit validation. |
| `validate_equation_dimensions` | [`validate_equation_dimensions`](/generated/api/ref/validate_equation_dimensions) | function | Validate that an equation is dimensionally consistent. |
| `validate_path` | [`validate_path`](/generated/api/ref/validate_path) | function | Validate the document at `path`, INCLUDING the failures that happen while loading it. |
| `validate_schema` | [`validate_schema`](/generated/api/ref/validate_schema) | function | Validate `data` (a native JSON tree of `Dict`/`Vector`/scalars) against the ESM schema. |
| `validate_structural` | [`validate_structural`](/generated/api/ref/validate_structural) | function | Validate structural consistency of ESM file according to spec Section 3.2. |
| `validate_text` | [`validate_text`](/generated/api/ref/validate_text) | function | Validate an ESM document held as JSON **text**, INCLUDING the failures that happen while loading it. |
| `ValidationResult` | [`validation_result`](/generated/api/ref/validation_result) | type | Combined validation result containing schema errors, structural errors, unit warnings, and overall validation status. |
| `VarGridding` | [`var_gridding`](/generated/api/ref/var_gridding) | type | The gridded layout of one output base-variable, derived from a flat `var_map` (RFC §7). |
| `VariableNode` | [`variable_node`](/generated/api/ref/variable_node) | type | Variable-level node for expression graphs. |
| `VarPlan` | [`var_plan`](/generated/api/ref/var_plan) | type | One output variable as a writer sees it: the on-disk `name`, its ordered on-disk `dims` (record axis first, then spatial axes — a scalar's dims are exactly `[time_dim]`), the CF… |
| `write_path` | [`write_path`](/generated/api/ref/write_path) | function | Write an `EsmFile` to `path` as wire-form JSON. |
