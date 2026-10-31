---
title: "Python API index"
description: "Every stable name Python exports, and its extension seams."
type: "api"
---


**Package:** `earthsci-ast` 0.6.0

Documentation extracted with griffe 2.3.2.

**Capability profiles:** core, classification, simulation, runtime I/O.

Extension-tier names are on the [Python extension page](/generated/api/extension/python).

## Stable names

| Python | Canonical | Kind | Summary |
|---|---|---|---|
| `add_continuous_event` | [`add_continuous_event`](/generated/api/ref/add_continuous_event) | function | Add a continuous event to a model. |
| `add_continuous_event_to_model` | [`add_continuous_event`](/generated/api/ref/add_continuous_event) | function | Deprecated alias for `add_continuous_event`. |
| `add_coupling` | [`add_coupling`](/generated/api/ref/add_coupling) | function | Add a coupling entry to an ESM file. |
| `add_coupling_to_file` | [`add_coupling`](/generated/api/ref/add_coupling) | function | Deprecated alias for `add_coupling`. |
| `add_discrete_event` | [`add_discrete_event`](/generated/api/ref/add_discrete_event) | function | Add a discrete event to a model. |
| `add_discrete_event_to_model` | [`add_discrete_event`](/generated/api/ref/add_discrete_event) | function | Deprecated alias for `add_discrete_event`. |
| `add_equation` | [`add_equation`](/generated/api/ref/add_equation) | function | Add an equation to a model. |
| `add_equation_to_model` | [`add_equation`](/generated/api/ref/add_equation) | function | Deprecated alias for `add_equation`. |
| `add_reaction` | [`add_reaction`](/generated/api/ref/add_reaction) | function | Add a reaction to a reaction system. |
| `add_reaction_to_system` | [`add_reaction`](/generated/api/ref/add_reaction) | function | Deprecated alias for `add_reaction`. |
| `add_species` | [`add_species`](/generated/api/ref/add_species) | function | Add a species to a reaction system. |
| `add_species_to_system` | [`add_species`](/generated/api/ref/add_species) | function | Deprecated alias for `add_species`. |
| `add_variable` | [`add_variable`](/generated/api/ref/add_variable) | function | Add a variable to a model. |
| `add_variable_to_model` | [`add_variable`](/generated/api/ref/add_variable) | function | Deprecated alias for `add_variable`. |
| `AffectEquation` | [`affect_equation`](/generated/api/ref/affect_equation) | type | Equation that affects a variable (assignment-like). |
| `algebraic_unknowns` | [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns) | function | Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`), sorted. |
| `apply_unit_conversion` | [`apply_unit_conversion`](/generated/api/ref/apply_unit_conversion) | function | Apply `conversion` to `values`. |
| `area_tolerance_ok` | [`area_tolerance_ok`](/generated/api/ref/area_tolerance_ok) | function | Combined rel+abs area-agreement gate with a sliver floor (B.5 / §5.8.2). |
| `brownian_parameters` | [`brownian_parameters`](/generated/api/ref/brownian_parameters) | function | Parameters whose `update.kind` is `"wiener"` — the SDE noise sources (esm-spec §6.3.1), sorted. |
| `build_reference_graph` | [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | Resolve the reference edges of one `model` dict into a graph. |
| `CadenceError` | [`cadence_error`](/generated/api/ref/cadence_error) | error | A cadence-partition contract violation in a model or producer output. |
| `callbacks` | [`callbacks`](/generated/api/ref/callbacks) | function | The EsmProblem's callback set (esm-libraries-spec §2.5.4). |
| `CallbackSet` | [`callback_set`](/generated/api/ref/callback_set) | type | An ordered, immutable set of callbacks, declared on a `EsmProblem`. |
| `can_migrate` | [`can_migrate`](/generated/api/ref/can_migrate) | function | True when `migrate` would succeed for this version pair. |
| `canonical_index_set_json` | [`canonical_index_set_json`](/generated/api/ref/canonical_index_set_json) | function | Canonical byte form of an index set (`CONFORMANCE_SPEC.md` §5.5.3): the `distinct` rows, each tuple serialised as a JSON array, in §5.5.1 sorted order, as compact UTF-8 JSON. |
| `CircularReferenceError` | [`circular_reference_error`](/generated/api/ref/circular_reference_error) | error | Exception raised when circular subsystem references are detected. |
| `Compiler` | [`compiler`](/generated/api/ref/compiler) | type | The type a caller's `compiler` keyword takes. |
| `CompilerReport` | [`compiler_report`](/generated/api/ref/compiler_report) | type | Per rule, the tier it landed on and what declined on the way. |
| `component_exists` | [`component_exists`](/generated/api/ref/component_exists) | function | True when `component_id` names a model or reaction system of `file`. |
| `component_graph` | [`component_graph`](/generated/api/ref/component_graph-function) | function | Build the component/coupling graph of `file`. |
| `ComponentNode` | [`component_node`](/generated/api/ref/component_node) | type | A model or reaction system in the component graph. |
| `ConflictingDerivativeError` | [`conflicting_derivative_error`](/generated/api/ref/conflicting_derivative_error) | error | Two systems define non-additive equations for the same dependent variable. |
| `constant_parameters` | [`constant_parameters`](/generated/api/ref/constant_parameters) | function | Parameters with neither a `distribution` nor an `update` — plain constants (esm-spec §6.3.1), sorted. |
| `contains` | [`contains`](/generated/api/ref/contains) | function | Check if an expression contains a specific variable. |
| `ContinuousEvent` | [`continuous_event`](/generated/api/ref/continuous_event) | type | An event that occurs when a condition becomes true during continuous evolution. |
| `Contribution` | [`contribution`](/generated/api/ref/contribution) | type | One summand of a flattened equation's right-hand side, with its authors. |
| `convert_units` | [`convert_units`](/generated/api/ref/convert_units) | function | Convenience function to convert units. |
| `CoupleMultiplicativeNoTendencyError` | [`couple_multiplicative_no_tendency_error`](/generated/api/ref/couple_multiplicative_no_tendency_error) | error | A `multiplicative` connector transform targets something with no tendency. |
| `CouplingEdge` | [`coupling_edge`](/generated/api/ref/coupling_edge) | type | A coupling relationship between two components. |
| `CouplingEntry` | [`coupling_entry`](/generated/api/ref/coupling_entry) | type | One entry of a document's `coupling` list (esm-spec §10): any of the coupling dataclasses, told apart by their `coupling_type` field (`CouplingType`), which is the wire `type`… |
| `CouplingImport` | [`coupling_import`](/generated/api/ref/coupling_import) | type | Coupling entry that imports a coupling-library file (esm-spec §10.10). |
| `CyclicPromotionError` | [`cyclic_promotion_error`](/generated/api/ref/cyclic_promotion_error) | error | Promotion rules form a cycle (A→B→…→A). |
| `DataSource` | [`data_source`](/generated/api/ref/data_source) | type | A named external data source reduced to pure I/O: it locates, reads, decodes, slices and filters bytes on disk (esm-spec §8). |
| `DataSourceBinding` | [`data_source_binding`](/generated/api/ref/data_source_binding) | type | Binds a parameter to ONE variable of a `data_sources` entry (esm-spec §8.5). |
| `DataSourceDeterminism` | [`data_source_determinism`](/generated/api/ref/data_source_determinism) | type | Reproducibility contract a source advertises to bindings (esm-spec §8.9.2). |
| `DataSourceKind` | [`data_source_kind`](/generated/api/ref/data_source_kind) | type | Structural kind of an external data source. |
| `DataSourceLocation` | [`data_source_location`](/generated/api/ref/data_source_location) | type | File discovery configuration for a data source. |
| `DataSourceTemporal` | [`data_source_temporal`](/generated/api/ref/data_source_temporal) | type | Temporal coverage and record layout for a data source. |
| `declared_system_kind` | [`declared_system_kind`](/generated/api/ref/declared_system_kind) | function | The model's explicit `system_kind` field, or None when absent. |
| `default_forcing_set` | [`default_forcing_set`](/generated/api/ref/default_forcing_set) | function | The Problem's forcing as a forcing set. |
| `DependencyEdge` | [`dependency_edge`](/generated/api/ref/dependency_edge) | type | A dependency between two variables. |
| `derive_odes` | [`derive_odes`](/generated/api/ref/derive_odes) | function | Derive ODEs from a reaction system using mass action kinetics. |
| `desugar_pushdown` | [`desugar_pushdown`](/generated/api/ref/desugar_pushdown) | function | Recognise the projection-pushdown pattern in `esm`'s named model and, when it matches, return a NEW document with the four constructs desugared in (a `kind:"derived"` index set,… |
| `DimensionPromotionError` | [`dimension_promotion_error`](/generated/api/ref/dimension_promotion_error) | error | A variable or equation cannot be promoted given the available Interfaces. |
| `discrete_parameters` | [`discrete_parameters`](/generated/api/ref/discrete_parameters) | function | Parameters carrying any update OTHER than `wiener` — piecewise-constant between refreshes (esm-spec §6.3.1), sorted. |
| `DiscreteEvent` | [`discrete_event`](/generated/api/ref/discrete_event) | type | An event that occurs at discrete time points. |
| `DiscreteEventTrigger` | [`discrete_event_trigger`](/generated/api/ref/discrete_event_trigger) | type | Trigger condition for a discrete event. |
| `distinct` | [`distinct`](/generated/api/ref/distinct) | function | Set semantics over `rows`: sort by the §5.5.1 total order, then drop |
| `Distribution` | [`distribution`](/generated/api/ref/distribution) | type | A parameter's value drawn from a probability distribution (esm-spec §5.4 / §6.3). |
| `Domain` | [`domain`](/generated/api/ref/domain) | type | Comprehensive computational domain specification. |
| `DomainExtentMismatchError` | [`domain_extent_mismatch_error`](/generated/api/ref/domain_extent_mismatch_error) | error | Two domains coupled via `identity` have incompatible spatial extents. |
| `DomainUnitMismatchError` | [`domain_unit_mismatch_error`](/generated/api/ref/domain_unit_mismatch_error) | error | An Interface coupling requires a unit conversion that was not declared. |
| `EarthSciAstError` | [`earth_sci_ast_error`](/generated/api/ref/earth_sci_ast_error) | error | Root of the earthsci_ast exception hierarchy. |
| `EdgeKind` | [`edge_kind`](/generated/api/ref/edge_kind) | type | The three kinds of reference edge (RFC §6.1 "Propagation"). |
| `effective_system_kind` | [`effective_system_kind`](/generated/api/ref/effective_system_kind) | function | The kind a caller choosing a solver should act on: the declared `system_kind` field when the document states one, otherwise the §6.3.1 derivation. |
| `emit_document` | [`emit_document`](/generated/api/ref/emit_document) | function | Produce the reference-preserving, self-contained emitted document (esm-spec §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source document (a fixture, or an… |
| `emit_esm_string` | [`emit_esm_string`](/generated/api/ref/emit_esm_string) | function | Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5): 2-space indent, object keys sorted lexicographically EXCEPT the entries of an `expression_templates`… |
| `EnsembleProblem` | [`ensemble_problem`](/generated/api/ref/ensemble_problem) | type | A `EsmProblem` plus a per-trajectory rewrite (esm-libraries-spec §2.5.8). |
| `EnumLoweringError` | [`enum_lowering_error`](/generated/api/ref/enum_lowering_error) | error | Raised when enum lowering (esm-spec §9.3) fails. |
| `Equation` | [`equation`](/generated/api/ref/equation) | type | Mathematical equation with left and right hand sides. |
| `ERROR_CODES` | [`error_codes`](/generated/api/ref/error_codes) | constant | Every diagnostic code this binding can emit, keyed by its SCREAMING_SNAKE name: `ERROR_CODES.UNDEFINED_VARIABLE == "undefined_variable"`. |
| `esm_problem` | [`esm_problem`](/generated/api/ref/esm_problem-function) | function | Build a document into a runnable `EsmProblem` (esm-libraries-spec §2.5.2). |
| `EsmFile` | [`esm_file`](/generated/api/ref/esm_file) | type | Root container for an ESM format file. |
| `EsmProblem` | [`esm_problem`](/generated/api/ref/esm_problem-type) | type | A document, built and ready to run (esm-libraries-spec §2.5.2). |
| `evaluate` | [`evaluate`](/generated/api/ref/evaluate) | function | Evaluate a scalar AST expression against a dict of float variable bindings. |
| `Expand` | [`expand`](/generated/api/ref/expand) | function | Public alias for `expand_document` using the spec's spelling (esm-spec §9.6.4 rule 2). |
| `expand_coupling_imports` | [`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports) | function | Expand every `coupling_import` entry in `esm_file.coupling` into concrete (typed) coupling edges, splicing them in the position of the import entry (esm-spec §10.10.3). |
| `expand_document` | [`expand_document`](/generated/api/ref/expand_document) | function | Fully expand every surviving `apply_expression_template` reference in a document `loaded` by `lower_expression_templates` (Option B), producing the Option-A image: every… |
| `Expr` | [`expr`](/generated/api/ref/expr) | type | An expression (esm-spec §4): a numeric literal (`int` or `float`), a variable or parameter reference (`str`), or an operator node (`ExprNode`) whose `args` are themselves… |
| `expression_graph` | [`expression_graph`](/generated/api/ref/expression_graph-function) | function | Build the variable-dependency graph of `target`. |
| `ExpressionParseError` | [`expression_parse_error`](/generated/api/ref/expression_parse_error) | error | Raised when an expression string cannot be parsed. |
| `ExpressionTemplateError` | [`expression_template_error`](/generated/api/ref/expression_template_error) | error | Raised when expression-template expansion fails. |
| `ExprNode` | [`expr_node`](/generated/api/ref/expr_node) | type | A node in an expression tree. |
| `extract` | [`extract`](/generated/api/ref/extract) | function | Extract a single component into a standalone ESM file. |
| `extract_component_from_file` | [`extract`](/generated/api/ref/extract) | function | Deprecated alias for `extract`. |
| `flatten` | [`flatten`](/generated/api/ref/flatten) | function | Flatten a coupled multi-system EsmFile per spec §4.7.5. |
| `flatten_template_registries` | [`flatten_template_registries`](/generated/api/ref/flatten_template_registries) | function | The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4). |
| `FlattenedEquation` | [`flattened_equation`](/generated/api/ref/flattened_equation) | type | An equation in the flattened system, with namespaced Expr trees. |
| `FlattenedSystem` | [`flattened_system`](/generated/api/ref/flattened_system) | type | The result of flattening an EsmFile per spec §4.7.5. |
| `FlattenedVariable` | [`flattened_variable`](/generated/api/ref/flattened_variable) | type | A single variable in the flattened system. |
| `FlattenError` | [`flatten_error`](/generated/api/ref/flatten_error) | error | Base class for errors raised during flatten(). |
| `FlattenMetadata` | [`flatten_metadata`](/generated/api/ref/flatten_metadata) | type | Provenance metadata for a FlattenedSystem. |
| `FloatKeyError` | [`float_key_error`](/generated/api/ref/float_key_error) | error | Raised when a relational key contains a floating-point component. |
| `forcing_set` | [`forcing_set`](/generated/api/ref/forcing_set-function) | function | An epoch-stamped forcing set for `prog`. |
| `free_parameters` | [`free_parameters`](/generated/api/ref/free_parameters) | function | Extract free parameters from an expression. |
| `free_variables` | [`free_variables`](/generated/api/ref/free_variables) | function | Extract all free variables from an expression. |
| `FunctionalUpdate` | [`functional_update`](/generated/api/ref/functional_update) | type | A registered handler computing a parameter's new value when its update fires (esm-spec §5.4). |
| `FunctionTable` | [`function_table`](/generated/api/ref/function_table) | type | A sampled function table referenced by table_lookup AST ops (esm-spec §9.5, v0.4.0). |
| `FunctionTableAxis` | [`function_table_axis`](/generated/api/ref/function_table_axis) | type | A single named axis inside a FunctionTable (esm-spec §9.5). |
| `GeometryError` | [`geometry_error`](/generated/api/ref/geometry_error) | error | A polygon-clip / area evaluation failed (bad operand, degenerate input). |
| `Graph` | [`graph`](/generated/api/ref/graph) | type | A directed graph with node/edge lists and adjacency lookups (§4.8). |
| `GraphEdge` | [`graph_edge`](/generated/api/ref/graph_edge) | type | One directed edge: node keys plus the edge payload. |
| `group_aggregate` | [`group_aggregate`](/generated/api/ref/group_aggregate) | function | Group-by + semiring aggregate (rule 5). |
| `halo` | [`halo`](/generated/api/ref/halo) | function | The halo report of `op` along `dec`. |
| `init` | [`init`](/generated/api/ref/init) | function | Build a stepping `Integrator` over `prob` (esm-libraries-spec §2.5.6). |
| `Integrator` | [`integrator`](/generated/api/ref/integrator) | type | A stepping integrator over a `EsmProblem` (esm-libraries-spec §2.5.6). |
| `intersect_polygon` | [`intersect_polygon`](/generated/api/ref/intersect_polygon) | function | Clip two lon-lat polygon rings; return the overlap ring (RFC §8.1). |
| `is_coupling_library_doc` | [`is_coupling_library_doc`](/generated/api/ref/is_coupling_library_doc) | function | True when `raw` has the coupling-library-file FORM (top-level `coupling_roles`, esm-spec §10.9). |
| `is_ode_state` | [`is_ode_state`](/generated/api/ref/is_ode_state) | function | Membership test for `ode_states` — the replacement for every `variable.type == "state"` branch. |
| `lanes` | [`lanes`](/generated/api/ref/lanes) | function | `op` over a run-time list of cells or columns. |
| `LIBRARY_VERSION` | [`library_version`](/generated/api/ref/library_version) | constant | This package's OWN version -- the cross-binding spelling of `__version__`. |
| `load_document` | [`load_document`](/generated/api/ref/load_document) | function | Parse an ESM document that is ALREADY a Python `dict` — the same document a `.esm` file holds, just already `json.load`ed. |
| `load_path` | [`load_path`](/generated/api/ref/load_path) | function | Read and parse an ESM document from a filesystem path. |
| `load_string` | [`load_string`](/generated/api/ref/load_string) | function | Parse an ESM document from JSON TEXT. |
| `LoaderField` | [`loader_field`](/generated/api/ref/loader_field) | type | A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5). |
| `lower_enums` | [`lower_enums`](/generated/api/ref/lower_enums) | function | Return `file` with every `enum` op replaced by a `const` integer per the file's `enums` block (esm-spec §9.3). |
| `lower_enums_mut` | [`lower_enums_mut`](/generated/api/ref/lower_enums_mut) | function | In-place twin of `lower_enums`: lower every `enum` op in `file` itself, and return it (API_SPEC.md §8 item 15). |
| `lower_expression_templates` | [`lower_expression_templates`](/generated/api/ref/lower_expression_templates) | function | Run the load-time rewrite fixpoint (esm-spec §9.6.3) over `file`, Option B (reference-preserving, esm-spec §9.6.4). |
| `materialize_value_invention` | [`materialize_value_invention`](/generated/api/ref/materialize_value_invention) | function | Run the build-time value-invention engine over a raw model document. |
| `MAX_TEMPLATE_EXPANSION_DEPTH` | [`max_template_expansion_depth`](/generated/api/ref/max_template_expansion_depth) | constant | Maximum template-body reference-chain depth (counted in TEMPLATES along the longest chain, so a 33-template chain is rejected and a 32-template chain is accepted) before a file… |
| `merge` | [`merge`](/generated/api/ref/merge) | function | Merge two ESM files. |
| `merge_esm_files` | [`merge`](/generated/api/ref/merge) | function | Deprecated alias for `merge`. |
| `Metadata` | [`metadata`](/generated/api/ref/metadata) | type | Metadata about the model or dataset. |
| `migrate` | [`migrate`](/generated/api/ref/migrate) | function | Migrate `file` to `target_version`. |
| `MigrationError` | [`migration_error`](/generated/api/ref/migration_error) | error | Raised when an ESM document cannot be migrated to the requested version. |
| `Model` | [`model`](/generated/api/ref/model) | type | A mathematical model containing variables and equations. |
| `ModelVariable` | [`model_variable`](/generated/api/ref/model_variable) | type | A variable in a mathematical model — either an `unknown` the solver solves for, or a `parameter` supplied to it. |
| `observed_definitions` | [`observed_definitions`](/generated/api/ref/observed_definitions) | function | Map each observed unknown to its DEFINING equation's RHS. |
| `observed_field` | [`observed_field`](/generated/api/ref/observed_field) | function | Evaluate/read the state-free observed `name` at BUILD time through the EsmProblem's own graph — the const-geometry hoist already materialized it; this resolves the name against… |
| `observed_unknowns` | [`observed_unknowns`](/generated/api/ref/observed_unknowns) | function | Unknowns defined by a bare-variable LHS (`y ~ f(…)`) — eliminable, materializable (esm-spec §6.3.1), sorted. |
| `ode_states` | [`ode_states`](/generated/api/ref/ode_states) | function | Unknowns appearing under `D(·, t)` on some equation LHS (esm-spec §6.3.1), sorted. |
| `Operator` | [`operator`](/generated/api/ref/operator) | type | A registered runtime operator (e.g., dry deposition, wet scavenging). |
| `OperatorComposeAmbiguousBareNameError` | [`operator_compose_ambiguous_bare_name_error`](/generated/api/ref/operator_compose_ambiguous_bare_name_error) | error | A bare-name match unified two STATES and the document did not say which survives. |
| `OperatorComposeNoMergeError` | [`operator_compose_no_merge_error`](/generated/api/ref/operator_compose_no_merge_error) | error | An `operator_compose` entry merged NOTHING (esm-libraries-spec §4.7.1 step 5). |
| `OperatorComposeRequireMatchError` | [`operator_compose_require_match_error`](/generated/api/ref/operator_compose_require_match_error) | error | An `operator_compose` entry declared `require_match` and did not match. |
| `Parameter` | [`parameter`](/generated/api/ref/parameter) | type | A parameter for reaction systems. |
| `ParameterUpdate` | [`parameter_update`](/generated/api/ref/parameter_update) | type | One rule declaring WHEN a parameter refreshes and WHAT from (esm-spec §5.4). |
| `parse_equation` | [`parse_equation`](/generated/api/ref/parse_equation) | function | Parse `lhs = rhs` into an `Equation`. |
| `parse_expression` | [`parse_expression`](/generated/api/ref/parse_expression) | function | Parse a single expression string into an AST expression — the inverse of `to_ascii`. |
| `parse_unit_conversion` | [`parse_unit_conversion`](/generated/api/ref/parse_unit_conversion) | function | Parse a loader variable's RAW `unit_conversion` (esm-spec §8.5). |
| `Partition` | [`partition`](/generated/api/ref/partition) | type | The result of the cadence-partition pass over one model. |
| `polygon_area` | [`polygon_area`](/generated/api/ref/polygon_area) | function | Reference (unsigned) area of an overlap ring under `manifold`. |
| `product_matrix` | [`product_matrix`](/generated/api/ref/product_matrix) | function | Compute the product stoichiometric matrix. |
| `rank` | [`rank`](/generated/api/ref/rank) | function | Dense integer renumbering (rule 3): assign IDs by position in the sorted `distinct` sequence. |
| `Ranking` | [`ranking`](/generated/api/ref/ranking) | type | Result of `rank`. |
| `Reaction` | [`reaction`](/generated/api/ref/reaction) | type | A chemical reaction. |
| `ReactionSystem` | [`reaction_system`](/generated/api/ref/reaction_system) | type | A system of chemical reactions. |
| `Reference` | [`reference`](/generated/api/ref/reference) | type | Bibliographic reference. |
| `ReferenceEdge` | [`reference_edge`](/generated/api/ref/reference_edge) | type | A directed `source → target` edge: *source references/depends on target*. |
| `ReferenceGraph` | [`reference_graph`](/generated/api/ref/reference_graph) | type | The resolved reference DAG for one model — the partition pass's input. |
| `ReferenceResolutionError` | [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | A reference could not be resolved, or the reference graph has a cycle. |
| `ReferenceVertex` | [`reference_vertex`](/generated/api/ref/reference_vertex) | type | A vertex in the reference graph, addressed by a kind-namespaced `key`. |
| `reject_expression_templates_pre_v04` | [`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) | function | Reject template constructs in files declaring esm &lt; 0.4.0. |
| `reject_solver_external_pre_v13` | [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13) | function | Reject `solver.external` in a file declaring esm &lt; 1.3.0. |
| `reject_solver_pre_v11` | [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) | function | Reject a top-level `solver` block in a file declaring esm &lt; 1.1.0. |
| `reject_solver_time_span_pre_v13` | [`reject_solver_time_span_pre_v13`](/generated/api/ref/reject_solver_time_span_pre_v13) | function | Reject `solver.time_span` in a file declaring esm &lt; 1.3.0. |
| `reject_template_imports_pre_v08` | [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08) | function | Reject the §9.7 constructs in files declaring esm &lt; 0.8.0. |
| `remake` | [`remake`](/generated/api/ref/remake) | function | A NEW EsmProblem with the named substitutions applied, everything else shared. |
| `remove_coupling` | [`remove_coupling`](/generated/api/ref/remove_coupling) | function | Remove a coupling entry from an ESM file. |
| `remove_coupling_from_file` | [`remove_coupling`](/generated/api/ref/remove_coupling) | function | Deprecated alias for `remove_coupling`. |
| `remove_equation` | [`remove_equation`](/generated/api/ref/remove_equation) | function | Remove an equation from a model by index. |
| `remove_equation_from_model` | [`remove_equation`](/generated/api/ref/remove_equation) | function | Deprecated alias for `remove_equation`. |
| `remove_event` | [`remove_event`](/generated/api/ref/remove_event) | function | Remove an event from a model. |
| `remove_event_from_model` | [`remove_event`](/generated/api/ref/remove_event) | function | Deprecated alias for `remove_event`. |
| `remove_reaction` | [`remove_reaction`](/generated/api/ref/remove_reaction) | function | Remove a reaction from a reaction system. |
| `remove_reaction_from_system` | [`remove_reaction`](/generated/api/ref/remove_reaction) | function | Deprecated alias for `remove_reaction`. |
| `remove_species` | [`remove_species`](/generated/api/ref/remove_species) | function | Remove a species from a reaction system. |
| `remove_species_from_system` | [`remove_species`](/generated/api/ref/remove_species) | function | Deprecated alias for `remove_species`. |
| `remove_variable` | [`remove_variable`](/generated/api/ref/remove_variable) | function | Remove a variable from a model. |
| `remove_variable_from_model` | [`remove_variable`](/generated/api/ref/remove_variable) | function | Deprecated alias for `remove_variable`. |
| `rename_variable` | [`rename_variable`](/generated/api/ref/rename_variable) | function | Rename a variable in a model. |
| `rename_variable_in_model` | [`rename_variable`](/generated/api/ref/rename_variable) | function | Deprecated alias for `rename_variable`. |
| `resolve_references` | [`resolve_references`](/generated/api/ref/resolve_references) | function | Resolve reference edges for every model in `document`. |
| `resolve_subsystem_refs` | [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) | function | Resolve all subsystem references in an ESM file. |
| `resolve_template_machinery` | [`resolve_template_machinery`](/generated/api/ref/resolve_template_machinery) | function | Resolve every esm-spec §9.7 construct of the ROOT document `raw` (relative import refs resolve against `base_path`): imports recursively with per-edge instantiation, `index_sets`… |
| `resolve_time_span` | [`resolve_time_span`](/generated/api/ref/resolve_time_span) | function | The interval a run should cover, most-specific first (esm-spec §2.2.7). |
| `resolve_tolerances` | [`resolve_tolerances`](/generated/api/ref/resolve_tolerances) | function | Resolve integration tolerances most-specific first (esm-spec §2.2.2). |
| `restrict` | [`restrict`](/generated/api/ref/restrict) | function | `op` restricted to one tile. |
| `ReturnCode` | [`return_code`](/generated/api/ref/return_code) | type | The SciML `ReturnCode` vocabulary (API_SPEC §4, esm-libraries-spec §2.5.3), which is how a run reports its outcome in every simulating binding. |
| `rhs_program` | [`rhs_program`](/generated/api/ref/rhs_program) | function | The Problem's right-hand side as a program value. |
| `sampled_parameters` | [`sampled_parameters`](/generated/api/ref/sampled_parameters) | function | Parameters with a `distribution` and no `update` — drawn once at setup (esm-spec §6.3.1), sorted. |
| `SCHEMA_VERSION` | [`schema_version`](/generated/api/ref/schema_version) | constant | The `.esm` FORMAT version this library implements — NOT the version of the library itself, which is `earthsci_ast.LIBRARY_VERSION`. |
| `SchemaValidationError` | [`schema_validation_error`](/generated/api/ref/schema_validation_error) | error | Exception raised when schema validation fails. |
| `select` | [`select`](/generated/api/ref/select) | function | One operator's program, by provenance. |
| `simplify` | [`simplify`](/generated/api/ref/simplify) | function | Simplify an expression by performing constant folding and basic algebraic simplifications. |
| `skolem` | [`skolem`](/generated/api/ref/skolem) | function | Canonical-tuple Skolem key (rule 4). |
| `skolem_edge` | [`skolem_edge`](/generated/api/ref/skolem_edge) | function | Canonical key for an **undirected** pair (a symmetric relation): `(min(a, b), max(a, b))`. |
| `SliceOutOfDomainError` | [`slice_out_of_domain_error`](/generated/api/ref/slice_out_of_domain_error) | error | A `slice` mapping reaches outside the source variable's domain. |
| `Solution` | [`solution`](/generated/api/ref/solution) | type | What `earthsci_ast.problem.solve` returns. |
| `solve` | [`solve`](/generated/api/ref/solve) | function | Run `prob` to completion and return its `Solution`. |
| `Solver` | [`solver`](/generated/api/ref/solver) | type | Document-scoped, OPTIONAL solver hints (esm-spec §2.2). |
| `solver_external_location` | [`solver_external_location`](/generated/api/ref/solver_external_location) | function | Where the document's `solver.external` points (esm-spec §2.2.6). |
| `SolverTimeSpan` | [`solver_time_span`](/generated/api/ref/solver_time_span) | type | `solver.time_span`: the interval a document is meant to be simulated over. |
| `Species` | [`species`](/generated/api/ref/species) | type | A chemical species in a reaction system. |
| `step` | [`step`](/generated/api/ref/step) | function | Advance `integrator` one accepted step — the spec's `step!`. |
| `stoichiometric_matrix` | [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | Compute the net stoichiometric matrix for a reaction system. |
| `substitute` | [`substitute`](/generated/api/ref/substitute) | function | Recursively substitute variables in an expression with their bindings. |
| `substitute_in_model` | [`substitute_in_model`](/generated/api/ref/substitute_in_model) | function | Apply substitutions to all expressions in a model. |
| `substitute_in_reaction_system` | [`substitute_in_reaction_system`](/generated/api/ref/substitute_in_reaction_system) | function | Apply substitutions to all expressions in a reaction system. |
| `substrate_matrix` | [`substrate_matrix`](/generated/api/ref/substrate_matrix) | function | Compute the substrate (reactant) stoichiometric matrix. |
| `SubsystemRefError` | [`subsystem_ref_error`](/generated/api/ref/subsystem_ref_error) | error | Exception raised when a subsystem reference cannot be resolved. |
| `supported_migration_targets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | The schema versions `from_version` can migrate to. |
| `system_kind` | [`system_kind`](/generated/api/ref/system_kind-function) | function | Derive the model's MTK system kind (esm-spec §6.3.1). |
| `TemporalDomain` | [`temporal_domain`](/generated/api/ref/temporal_domain) | type | Temporal domain specification. |
| `TermOrigin` | [`term_origin`](/generated/api/ref/term_origin) | type | Who authored one contribution to a flattened equation (esm-libraries-spec §4.7.5, "Per-term provenance"). |
| `time_origin` | [`time_origin`](/generated/api/ref/time_origin) | function | The time origin in binary64 seconds from the POSIX epoch. |
| `timestamp_to_seconds` | [`timestamp_to_seconds`](/generated/api/ref/timestamp_to_seconds) | function | `timestamp` as seconds from `source`'s time origin (esm-spec §2.2.7). |
| `to_ascii` | [`to_ascii`](/generated/api/ref/to_ascii) | function | Format target as plain ASCII mathematical notation. |
| `to_dot` | [`to_dot`](/generated/api/ref/to_dot) | function | Render `graph` as Graphviz DOT. |
| `to_json` | [`to_json`](/generated/api/ref/to_json) | function | Serialize an ESM file to a JSON string. |
| `to_json_compact` | [`to_json_compact`](/generated/api/ref/to_json_compact) | function | `to_json` with no indentation — the single-line wire form. |
| `to_json_graph` | [`to_json_graph`](/generated/api/ref/to_json_graph) | function | Render `graph` as the JSON adjacency list of esm-libraries-spec §4.8.3. |
| `to_julia_code` | [`to_julia_code`](/generated/api/ref/to_julia_code) | function | Generate a self-contained Julia script from an ESM file. |
| `to_latex` | [`to_latex`](/generated/api/ref/to_latex) | function | Format target as LaTeX mathematical notation. |
| `to_mermaid` | [`to_mermaid`](/generated/api/ref/to_mermaid) | function | Render `graph` as a Mermaid flowchart for Markdown embedding. |
| `to_unicode` | [`to_unicode`](/generated/api/ref/to_unicode) | function | Format target as Unicode mathematical notation with chemical subscripts. |
| `UNIT_FINDING_ANALYSIS` | [`unit_finding_analysis`](/generated/api/ref/unit_finding_analysis) | constant | The checker could not DETERMINE a dimension -- a symbolic exponent, an operator with no dimensional rule, an unknown variable, a missing pint. |
| `UNIT_FINDING_DIMENSIONAL_MISMATCH` | [`unit_finding_dimensional_mismatch`](/generated/api/ref/unit_finding_dimensional_mismatch) | constant | A PROVABLE inconsistency: metres added to kilograms, an equation whose sides cannot agree. |
| `UNIT_FINDING_DIMENSIONLESS_LITERAL` | [`unit_finding_dimensionless_literal`](/generated/api/ref/unit_finding_dimensionless_literal) | constant | A check the CURRENT neutral-literal rule skips or passes fails once a bare numeric literal is read as dimensionless (esm-spec §4.8.6). |
| `UNIT_FINDING_UNPARSEABLE` | [`unit_finding_unparseable`](/generated/api/ref/unit_finding_unparseable) | constant | A declared unit string that denotes no real unit. |
| `UnitConversionError` | [`unit_conversion_error`](/generated/api/ref/unit_conversion_error) | error | Raised when unit_conversion cannot be applied. |
| `UnitFinding` | [`unit_finding`](/generated/api/ref/unit_finding) | type | One coded dimensional-analysis finding. |
| `UnitWarning` | [`unit_warning`](/generated/api/ref/unit_warning) | type | A single dimensional-analysis finding. |
| `unknowns` | [`unknowns`](/generated/api/ref/unknowns) | function | Every variable declared `type: "unknown"`, sorted. |
| `UnmappedDomainError` | [`unmapped_domain_error`](/generated/api/ref/unmapped_domain_error) | error | A coupling references a variable whose domain has no mapping rule. |
| `UnsupportedMappingError` | [`unsupported_mapping_error`](/generated/api/ref/unsupported_mapping_error) | error | A dimension-promotion mapping is not supported by this implementation tier. |
| `validate` | [`validate`](/generated/api/ref/validate) | function | Validate a parsed ESM document against structural and unit requirements. |
| `validate_path` | [`validate_path`](/generated/api/ref/validate_path) | function | Validate the ESM document stored at `path` (API_SPEC.md §8 item 13). |
| `validate_text` | [`validate_text`](/generated/api/ref/validate_text) | function | Validate an ESM document held as JSON **text** (API_SPEC.md §8 item 13). |
| `validate_units` | [`validate_units`](/generated/api/ref/validate_units) | function | Convenience function to validate units of an ESM structure. |
| `ValidationError` | [`validation_error`](/generated/api/ref/validation_error) | type | Represents a single validation error. |
| `ValidationResult` | [`validation_result`](/generated/api/ref/validation_result) | type | Represents the result of validation. |
| `ValueInventionError` | [`value_invention_error`](/generated/api/ref/value_invention_error) | error | A value-invention build-time materialisation error. |
| `ValueInventionResult` | [`value_invention_result`](/generated/api/ref/value_invention_result) | type | Result of `materialize_value_invention`. |
| `VariableNode` | [`variable_node`](/generated/api/ref/variable_node) | type | A variable, parameter or species in the expression graph. |
| `VertexKind` | [`vertex_kind`](/generated/api/ref/vertex_kind) | type | The three kinds of vertex in the reference graph. |
| `write_path` | [`write_path`](/generated/api/ref/write_path) | function | Write an ESM file to `path` as JSON. |
