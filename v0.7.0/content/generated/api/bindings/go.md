---
title: "Go API index"
description: "Every stable name Go exports, and its extension seams."
type: "api"
---


**Package:** `github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm` 0.7.0

Documentation extracted with go/doc go1.26.10.

**Capability profiles:** core, classification.

Extension-tier names are on the [Go extension page](/generated/api/extension/go).

## Stable names

| Go | Canonical | Kind | Summary |
|---|---|---|---|
| `AddContinuousEvent` | [`add_continuous_event`](/generated/api/ref/add_continuous_event) | function | AddContinuousEvent returns a copy of `model` with `event` appended. |
| `AddCoupling` | [`add_coupling`](/generated/api/ref/add_coupling) | function | AddCoupling returns a copy of `file` with `entry` appended to its coupling list. |
| `AddDiscreteEvent` | [`add_discrete_event`](/generated/api/ref/add_discrete_event) | function | AddDiscreteEvent returns a copy of `model` with `event` appended. |
| `AddEquation` | [`add_equation`](/generated/api/ref/add_equation) | function | AddEquation returns a copy of `model` with `equation` appended. |
| `AddReaction` | [`add_reaction`](/generated/api/ref/add_reaction) | function | AddReaction returns a copy of `system` with `reaction` appended. |
| `AddSpecies` | [`add_species`](/generated/api/ref/add_species) | function | AddSpecies returns a copy of `system` carrying `species` under `name`. |
| `AddVariable` | [`add_variable`](/generated/api/ref/add_variable) | function | AddVariable returns a copy of `model` carrying `variable` under `name`. |
| `AffectEquation` | [`affect_equation`](/generated/api/ref/affect_equation) | type | AffectEquation represents an equation that affects a variable (for events) |
| `AlgebraicUnknowns` | [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns) | function | AlgebraicUnknowns returns the model's unknowns constrained only IMPLICITLY — those that are neither differentiated nor DEFINED, so the only equations mentioning them have an… |
| `ApplyDAEContract` | [`apply_dae_contract`](/generated/api/ref/apply_dae_contract) | function | ApplyDAEContract applies the Go binding's trivial-DAE strategy to every applicable model in file (mutating each in place) and classifies the result. |
| `BrownianParameters` | [`brownian_parameters`](/generated/api/ref/brownian_parameters) | function | BrownianParameters returns the parameters whose update is `wiener` — the SDE noise sources, resampled every step with √dt increment scaling. |
| `BuildReferenceGraph` | [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | BuildReferenceGraph resolves the reference edges of one raw `model` view into a graph. |
| `BuildUnitEnv` | [`build_unit_env`](/generated/api/ref/build_unit_env) | function | BuildUnitEnv converts a map of name→unit-string into a map of name→Unit. |
| `Cadence` | [`cadence`](/generated/api/ref/cadence) | type | Cadence is a value's evaluation class, forming the total order CadenceConst ⊏ CadenceDiscrete ⊏ CadenceContinuous (CONFORMANCE\_SPEC §5.7.1). |
| `CadenceError` | [`cadence_error`](/generated/api/ref/cadence_error) | error | CadenceError is a cadence-partition contract violation: an observed-definition cycle (§5.7.2), a failed `expect_cadence` assertion (§5.7.6 guard 3), or a relational node on the… |
| `CanMigrate` | [`can_migrate`](/generated/api/ref/can_migrate) | function | CanMigrate reports whether a migration from `sourceVersion` to `targetVersion` is supported. |
| `Canonicalize` | [`canonicalize`](/generated/api/ref/canonicalize) | function | Canonicalize applies RFC §5.4 canonical form to an expression tree. |
| `CanonicalJSON` | [`canonical_json`](/generated/api/ref/canonical_json) | function | CanonicalJSON emits the canonical on-wire JSON form of an expression per §5.4.6: keys sorted, no extraneous whitespace, shortest-round-trip float literals with trailing-`.0`… |
| `ClosedFunctionError` | [`closed_function_error`](/generated/api/ref/closed_function_error) | error | ClosedFunctionError carries the spec-defined diagnostic codes pinned by esm-spec §9.1–§9.2 / §9.3: |
| `ClosedFunctionNames` | [`closed_function_names`](/generated/api/ref/closed_function_names) | function | ClosedFunctionNames returns the v0.3.0 closed function set as a sorted slice. |
| `ComponentGraph` | [`component_graph`](/generated/api/ref/component_graph-type) | type | ComponentGraph is a specialized graph for system components |
| `ComponentNode` | [`component_node`](/generated/api/ref/component_node) | type | ComponentNode represents a node in the component graph |
| `Compose` | [`compose`](/generated/api/ref/compose) | function | Compose returns a copy of `file` with an `operator_compose` coupling entry linking systems `a` and `b`. |
| `ConflictingDerivativeError` | [`conflicting_derivative_error`](/generated/api/ref/conflicting_derivative_error) | error | ConflictingDerivativeError reports that two source systems define non-additive equations for the same dependent variable (esm-libraries-spec §4.7.5 step 4's over-determination… |
| `ConstantParameters` | [`constant_parameters`](/generated/api/ref/constant_parameters) | function | ConstantParameters returns the parameters carrying neither a distribution nor an update — plain constants. |
| `Contains` | [`contains`](/generated/api/ref/contains) | function | Contains checks if a specific variable appears anywhere in an expression. |
| `ContinuousEvent` | [`continuous_event`](/generated/api/ref/continuous_event) | type | ContinuousEvent represents a continuous event. |
| `Contribution` | [`contribution`](/generated/api/ref/contribution) | type | Contribution is one summand of a flattened equation's right-hand side, with its authors. |
| `Coordinate` | [`coordinate`](/generated/api/ref/coordinate) | type | Coordinate is one entry of the document-scoped `coordinates` registry (RFC streaming-output-sinks §8): it marks an existing data array — a model unknown or parameter named by… |
| `CoupleMultiplicativeNoTendencyError` | [`couple_multiplicative_no_tendency_error`](/generated/api/ref/couple_multiplicative_no_tendency_error) | error | CoupleMultiplicativeNoTendencyError reports that a `couple` connector equation applies the `multiplicative` transform to a target with no `D(to)` equation in the flattened system… |
| `CouplingCouple` | [`coupling_couple`](/generated/api/ref/coupling_couple) | type | CouplingCouple represents bi-directional coupling via connector equations |
| `CouplingEdge` | [`coupling_edge`](/generated/api/ref/coupling_edge) | type | CouplingEdge represents an edge in the component graph |
| `CouplingEntry` | [`coupling_entry`](/generated/api/ref/coupling_entry) | type | CouplingEntry represents different types of coupling rules This is a discriminated union based on the "type" field |
| `CouplingImport` | [`coupling_import`](/generated/api/ref/coupling_import) | type | CouplingImport reuses a coupling-library file (esm-spec §10.9, §10.10): it imports the library named by `Ref` and binds each of its declared roles to a component in the assembly… |
| `CouplingImportOptions` | [`coupling_import_options`](/generated/api/ref/coupling_import_options) | type | CouplingImportOptions controls how `coupling_import` refs are resolved at flatten (mirrors the TS CouplingImportOptions). |
| `CouplingRole` | [`coupling_role`](/generated/api/ref/coupling_role) | type | CouplingRole is one entry in a coupling-library file's `coupling_roles` map (esm-spec §10.9): a formal component role (a name, not a type), carrying an optional human-readable… |
| `DAEInfo` | [`dae_info`](/generated/api/ref/dae_info) | type | DAEInfo records the outcome of ApplyDAEContract on an ESMFile. |
| `DataSource` | [`data_source`](/generated/api/ref/data_source) | type | DataSource is a runtime-agnostic description of an external dataset, reduced to a single responsibility: locate, read, decode, slice, and filter bytes on disk (esm-spec 8). |
| `DataSourceBinding` | [`data_source_binding`](/generated/api/ref/data_source_binding) | type | DataSourceBinding binds a PARAMETER to one file variable of a `data_sources` entry, through the `from` value form of a `data` update (esm-spec 8.5). |
| `DataSourceDeterminism` | [`data_source_determinism`](/generated/api/ref/data_source_determinism) | type | DataSourceDeterminism is the reproducibility contract a source advertises to bindings (esm-spec 8.1). |
| `DataSourceLocation` | [`data_source_location`](/generated/api/ref/data_source_location) | type | DataSourceLocation describes file discovery for a data source. |
| `DataSourceTemporal` | [`data_source_temporal`](/generated/api/ref/data_source_temporal) | type | DataSourceTemporal describes the temporal coverage and record layout (esm-spec 8.3). |
| `DeclaredSystemKind` | [`declared_system_kind`](/generated/api/ref/declared_system_kind) | function | DeclaredSystemKind returns the model's EXPLICIT `system_kind` field, or nil when the document declares none. |
| `DependencyEdge` | [`dependency_edge`](/generated/api/ref/dependency_edge) | type | DependencyEdge represents an edge in the expression graph. |
| `DeriveODEs` | [`derive_odes`](/generated/api/ref/derive_odes) | function | DeriveODEs converts a reaction network into a Model whose equations are the species' ODEs under mass-action kinetics (esm-spec §7.4). |
| `Dimension` | [`dimension`](/generated/api/ref/dimension) | type | Dimension is a vector of RATIONAL exponents over the 7 SI base units plus radian. |
| `DimensionPromotionError` | [`dimension_promotion_error`](/generated/api/ref/dimension_promotion_error) | error | DimensionPromotionError reports that a variable or equation cannot be promoted onto the target grid (esm-libraries-spec §4.7.6): here, that the pointwise spatial lift (esm-spec… |
| `DiscreteEvent` | [`discrete_event`](/generated/api/ref/discrete_event) | type | DiscreteEvent represents a discrete event. |
| `DiscreteEventTrigger` | [`discrete_event_trigger`](/generated/api/ref/discrete_event_trigger) | type | DiscreteEventTrigger represents different trigger types for discrete events |
| `DiscreteParameters` | [`discrete_parameters`](/generated/api/ref/discrete_parameters) | function | DiscreteParameters returns the parameters carrying any update OTHER than `wiener` — piecewise-constant between refreshes. |
| `Distribution` | [`distribution`](/generated/api/ref/distribution) | type | Distribution is a parameter's value drawn from a closed set of probability distributions (esm-spec 6.3): `normal` (Mean + Std\|Cov), `lognormal` (Mu + Sigma\|Cov), or `uniform`… |
| `Domain` | [`domain`](/generated/api/ref/domain) | type | Domain represents the spatiotemporal domain. |
| `EdgeKind` | [`edge_kind`](/generated/api/ref/edge_kind) | type | EdgeKind is one of the three kinds of reference edge (RFC §6.1 "Propagation"). |
| `EditError` | [`edit_error`](/generated/api/ref/edit_error) | error | EditError is the base diagnostic for a failed editing operation, and the error type for failures with no more specific type. |
| `EffectiveSystemKind` | [`effective_system_kind`](/generated/api/ref/effective_system_kind) | function | EffectiveSystemKind is what a consumer choosing a solver should branch on: the DECLARED `system_kind` when the model carries one, and the SystemKind derivation otherwise… |
| `EntityNotFoundError` | [`entity_not_found_error`](/generated/api/ref/entity_not_found_error) | error | EntityNotFoundError reports an operation on a non-existent entity. |
| `EnumLoweringError` | [`enum_lowering_error`](/generated/api/ref/enum_lowering_error) | error | EnumLoweringError carries the spec-defined diagnostic codes for the load-time lowering pass: |
| `Equation` | [`equation`](/generated/api/ref/equation) | type | Equation represents a mathematical equation with LHS and RHS |
| `ESMFile` | [`esm_file`](/generated/api/ref/esm_file) | type | ESMFile represents the top-level ESM file structure |
| `Evaluate` | [`evaluate`](/generated/api/ref/evaluate) | function | Evaluate numerically evaluates an expression with variable bindings. |
| `EvaluateClosedFunction` | [`evaluate_closed_function`](/generated/api/ref/evaluate_closed_function) | function | EvaluateClosedFunction dispatches a closed function call. |
| `ExactScale` | [`exact_scale`](/generated/api/ref/exact_scale) | type | ExactScale is the EXACT scale of a unit relative to SI (esm-spec §4.8.1 "Scales are EXACT"): a product of prime powers and a power of pi, each with a rational exponent, so mi is… |
| `Expand` | [`expand`](/generated/api/ref/expand) | function | Expand fully expands every surviving `apply_expression_template` reference in a loaded document by pure substitution to the acyclic fixpoint (esm-spec §9.6.4 rule 2), producing… |
| `ExpressionGraph` | [`expression_graph`](/generated/api/ref/expression_graph-type) | type | ExpressionGraph is a specialized graph for variable dependencies |
| `ExpressionGraphOptions` | [`expression_graph_options`](/generated/api/ref/expression_graph_options) | type | ExpressionGraphOptions tunes ExpressionGraphFromFileWithOptions. |
| `ExpressionParseError` | [`expression_parse_error`](/generated/api/ref/expression_parse_error) | error | ExpressionParseError reports that an expression string could not be parsed. |
| `ExpressionTemplateError` | [`expression_template_error`](/generated/api/ref/expression_template_error) | error | ExpressionTemplateError is the error type raised by the expression-template expansion pass. |
| `ExprNode` | [`expr_node`](/generated/api/ref/expr_node) | type | ExprNode represents an operator node in the expression tree |
| `Extract` | [`extract`](/generated/api/ref/extract) | function | Extract returns a new file containing only the component `componentName`, together with every coupling entry that references it. |
| `Flatten` | [`flatten`](/generated/api/ref/flatten) | function | Flatten takes an ESMFile containing multiple models and/or reaction systems and returns a FlattenedSystem with dot-namespaced variables (esm-libraries-spec §4.7.5). |
| `FlattenedEquation` | [`flattened_equation`](/generated/api/ref/flattened_equation) | type | FlattenedEquation is a single equation of the flattened system, with dot-namespaced Expression TREES on both sides. |
| `FlattenedSystem` | [`flattened_system`](/generated/api/ref/flattened_system) | type | FlattenedSystem is a coupled system flattened into a single system — the canonical intermediate form between an ESMFile and any downstream consumer, and the API boundary all of… |
| `FlattenedVariable` | [`flattened_variable`](/generated/api/ref/flattened_variable) | type | FlattenedVariable is one variable of the flattened system, carrying the FULL declared metadata step 4 requires ("Full metadata, not names"): a consumer must be able to build a… |
| `FlattenMetadata` | [`flatten_metadata`](/generated/api/ref/flatten_metadata) | type | FlattenMetadata records provenance information about the flattening operation. |
| `FlattenWithOptions` | [`flatten_with_options`](/generated/api/ref/flatten_with_options) | function | FlattenWithOptions is Flatten with control over how `coupling_import` refs are resolved (esm-spec §10.10). |
| `FreeVariables` | [`free_variables`](/generated/api/ref/free_variables) | function | FreeVariables returns the set of all variable names that appear in an expression, including those reachable ONLY through a sidecar (non-`args`) field — an aggregate's… |
| `FunctionalUpdate` | [`functional_update`](/generated/api/ref/functional_update) | type | FunctionalUpdate is a registered handler that computes a parameter's new value when its update fires (esm-spec 5.5). |
| `FunctionTable` | [`function_table`](/generated/api/ref/function_table) | type | FunctionTable is a sampled function table (esm-spec §9.5). |
| `FunctionTableAxis` | [`function_table_axis`](/generated/api/ref/function_table_axis) | type | FunctionTableAxis is a single named axis inside a FunctionTable. |
| `Graph` | [`graph`](/generated/api/ref/graph) | type | Graph is the domain of the three graph renderers — ToDOT, ToMermaid and ToJSONGraph — and is satisfied by exactly the two graph types this package builds: \*ComponentGraph… |
| `GraphEdge` | [`graph_edge`](/generated/api/ref/graph_edge) | type | GraphEdge represents an edge in a directed graph |
| `IsODEState` | [`is_ode_state`](/generated/api/ref/is_ode_state) | function | IsODEState reports whether the named variable is an unknown appearing under a time derivative on some equation LHS. |
| `LibraryVersion` | [`library_version`](/generated/api/ref/library_version) | constant | LibraryVersion is this Go module's OWN version — NOT the `.esm` format version, which is SchemaVersion. |
| `LoadDocument` | [`load_document`](/generated/api/ref/load_document) | function | LoadDocument parses an ESM document that is ALREADY decoded into a Go map — the same document a `.esm` file holds, just already unmarshalled. |
| `LoaderField` | [`loader_field`](/generated/api/ref/loader_field) | type | LoaderField is a data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5). |
| `LoadPath` | [`load_path`](/generated/api/ref/load_path) | function | LoadPath reads an ESM document from the specified filesystem path and validates it against the JSON schema. |
| `LoadString` | [`load_string`](/generated/api/ref/load_string) | function | LoadString parses an ESM file from JSON TEXT and validates it against the JSON schema |
| `LowerEnums` | [`lower_enums`](/generated/api/ref/lower_enums) | function | LowerEnums resolves every `enum` op in the file to a `{op: "const", value: <int>}` node per esm-spec §9.3, and returns the lowered document. |
| `LowerEnumsMut` | [`lower_enums_mut`](/generated/api/ref/lower_enums_mut) | function | LowerEnumsMut is LowerEnums applied IN PLACE: it walks every expression tree in the file and resolves each `enum` op to a `{op: "const", value: <int>}` node per esm-spec §9.3,… |
| `LowerExpressionTemplates` | [`lower_expression_templates`](/generated/api/ref/lower_expression_templates) | function | LowerExpressionTemplates runs the outermost-first + priority + bounded-fixpoint rewrite over `view` and strips the `expression_templates` blocks. |
| `MapVariable` | [`map_variable`](/generated/api/ref/map_variable) | function | MapVariable returns a copy of `file` with a `variable_map` coupling entry forwarding `from` into `to`. |
| `MaxTemplateExpansionDepth` | [`max_template_expansion_depth`](/generated/api/ref/max_template_expansion_depth) | constant | MaxTemplateExpansionDepth is the maximum template-body reference-chain depth (counted in TEMPLATES along the longest chain, so a 33-template chain is rejected and a 32-template… |
| `Merge` | [`merge`](/generated/api/ref/merge) | function | Merge returns a new file combining `a` and `b`. |
| `Metadata` | [`metadata`](/generated/api/ref/metadata) | type | Metadata represents file metadata |
| `Migrate` | [`migrate`](/generated/api/ref/migrate) | function | Migrate migrates an ESM file from its declared schema version to `targetVersion`. |
| `MigrationError` | [`migration_error`](/generated/api/ref/migration_error) | error | MigrationError is returned when a migration cannot be performed. |
| `Model` | [`model`](/generated/api/ref/model) | type | Model represents an ODE system |
| `ModelVariable` | [`model_variable`](/generated/api/ref/model_variable) | type | ModelVariable represents a variable in a mathematical model. |
| `ObservedDefinition` | [`observed_definition`](/generated/api/ref/observed_definition) | function | ObservedDefinition returns the defining RHS of an observed unknown — the RHS of the first equation whose LHS names it, bare (`y ~ f(…)`) or indexed (`y[i] ~ f(…)`) — and whether… |
| `ObservedUnknowns` | [`observed_unknowns`](/generated/api/ref/observed_unknowns) | function | ObservedUnknowns returns the model's unknowns an equation DEFINES — its LHS naming them, bare (`y ~ f(…)`) or indexed (`y[i] ~ f(…)`, which defines the whole array `y`) —… |
| `ODEStates` | [`ode_states`](/generated/api/ref/ode_states) | function | ODEStates returns the model's unknowns that appear under a time derivative `D(·, t)` on some equation LHS, sorted lexicographically. |
| `OperatorComposeAmbiguousBareNameError` | [`operator_compose_ambiguous_bare_name_error`](/generated/api/ref/operator_compose_ambiguous_bare_name_error) | error | OperatorComposeAmbiguousBareNameError reports that the bare-name fallback would unify two STATE variables and the document has not said which spelling survives… |
| `OperatorComposeNoMergeError` | [`operator_compose_no_merge_error`](/generated/api/ref/operator_compose_no_merge_error) | error | OperatorComposeNoMergeError reports that an `operator_compose` entry merged NOTHING (esm-libraries-spec §4.7.1 step 5). |
| `OperatorComposeRequireMatchError` | [`operator_compose_require_match_error`](/generated/api/ref/operator_compose_require_match_error) | error | OperatorComposeRequireMatchError reports that an `operator_compose` entry declared `require_match: true` and one of Systems\[1\]'s equations found no equation of Systems\[0\] to… |
| `Parameter` | [`parameter`](/generated/api/ref/parameter) | type | Parameter represents a reaction-system parameter — rate constant, temperature, photolysis rate. |
| `ParameterSweep` | [`parameter_sweep`](/generated/api/ref/parameter_sweep) | type | ParameterSweep is a parameter sweep specification (currently only cartesian). |
| `ParameterUpdate` | [`parameter_update`](/generated/api/ref/parameter_update) | type | ParameterUpdate is ONE rule of a parameter's `update` block (esm-spec 5.4): WHEN the parameter refreshes (Kind, plus the kind's own trigger fields) and WHAT from (exactly one of… |
| `ParseEquation` | [`parse_equation`](/generated/api/ref/parse_equation) | function | ParseEquation parses `lhs = rhs` into an Equation. |
| `ParseExpression` | [`parse_expression`](/generated/api/ref/parse_expression) | function | ParseExpression parses a single expression string into an AST expression — the inverse of ToASCII. |
| `ParseUnit` | [`parse_unit`](/generated/api/ref/parse_unit) | function | ParseUnit parses a unit string into a Unit. |
| `Plot` | [`plot`](/generated/api/ref/plot) | type | Plot is a plot specification associated with an Analysis. |
| `PlotAxis` | [`plot_axis`](/generated/api/ref/plot_axis) | type | PlotAxis is an axis specification for a plot. |
| `PlotSeries` | [`plot_series`](/generated/api/ref/plot_series) | type | PlotSeries is a single named series for multi-series line/scatter plots. |
| `PlotValue` | [`plot_value`](/generated/api/ref/plot_value) | type | PlotValue is a scalar value derived from a trajectory, used for heatmap color channels. |
| `Reaction` | [`reaction`](/generated/api/ref/reaction) | type | Reaction represents a chemical reaction |
| `ReactionSystem` | [`reaction_system`](/generated/api/ref/reaction_system) | type | ReactionSystem represents a chemical reaction network |
| `Reference` | [`reference`](/generated/api/ref/reference) | type | Reference represents a scientific reference |
| `ReferenceEdge` | [`reference_edge`](/generated/api/ref/reference_edge) | type | ReferenceEdge is a directed source → target edge: SOURCE REFERENCES / DEPENDS ON TARGET. |
| `ReferenceGraph` | [`reference_graph`](/generated/api/ref/reference_graph) | type | ReferenceGraph is the resolved reference DAG for one model — the partition pass's input. |
| `ReferenceResolutionError` | [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | ReferenceResolutionError reports that a reference could not be resolved, or that the reference graph has a cycle. |
| `ReferenceVertex` | [`reference_vertex`](/generated/api/ref/reference_vertex) | type | ReferenceVertex is a vertex in the reference graph, addressed by a kind-namespaced Key. |
| `RejectExpressionTemplatesPreV04` | [`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) | function | RejectExpressionTemplatesPreV04 rejects `expression_templates` blocks and `apply_expression_template` ops in files declaring `esm` &lt; 0.4.0. |
| `RejectSolverExternalPreV13` | [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13) | function | RejectSolverExternalPreV13 rejects `solver.external` in files declaring esm &lt; 1.3.0 with `solver_external_version_too_old` at `/solver/external` (esm-spec §2.2.4 requirement 4). |
| `RejectSolverPreV11` | [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) | function | RejectSolverPreV11 rejects a top-level `solver` block in files declaring esm &lt; 1.1.0. |
| `RejectSolverTimeSpanPreV13` | [`reject_solver_time_span_pre_v13`](/generated/api/ref/reject_solver_time_span_pre_v13) | function | RejectSolverTimeSpanPreV13 rejects `solver.time_span` in files declaring esm &lt; 1.3.0 with `solver_time_span_version_too_old` at `/solver/time_span` (esm-spec §2.2.4… |
| `RejectTemplateImportsPreV08` | [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08) | function | RejectTemplateImportsPreV08 rejects the §9.7 constructs in files declaring esm &lt; 0.8.0: `expression_template_imports`, top-level `expression_templates` (template-library… |
| `RemoveCoupling` | [`remove_coupling`](/generated/api/ref/remove_coupling) | function | RemoveCoupling returns a copy of `file` without the coupling entry at `index`. |
| `RemoveEvent` | [`remove_event`](/generated/api/ref/remove_event) | function | RemoveEvent returns a copy of `model` with every event named `name` removed. |
| `RemoveReaction` | [`remove_reaction`](/generated/api/ref/remove_reaction) | function | RemoveReaction returns a copy of `system` without the reaction whose ID is `id`. |
| `RemoveSpecies` | [`remove_species`](/generated/api/ref/remove_species) | function | RemoveSpecies returns a copy of `system` without the species `name`, after checking that no reaction still references it. |
| `RemoveVariable` | [`remove_variable`](/generated/api/ref/remove_variable) | function | RemoveVariable returns a copy of `model` without the variable `name`, after checking that nothing still references it. |
| `RenameVariable` | [`rename_variable`](/generated/api/ref/rename_variable) | function | RenameVariableInFile when the document is available; it resolves scoped references and rewrites coupling endpoints too. |
| `ResolveReferences` | [`resolve_references`](/generated/api/ref/resolve_references) | function | ResolveReferences resolves the reference edges of every model in a raw `document` view, returning a {model name: graph} map. |
| `ResolveSubsystemRefs` | [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) | function | ResolveSubsystemRefs walks all subsystem maps in models and reaction systems, resolving any entries that contain a "ref" field by loading and inlining the referenced ESM file… |
| `ResolveTimeSpan` | [`resolve_time_span`](/generated/api/ref/resolve_time_span) | function | ResolveTimeSpan resolves the run interval by the esm-spec §2.2.7 chain: the call-site interval when callSite is non-nil (it always wins, both bounds), else the document's… |
| `SampledParameters` | [`sampled_parameters`](/generated/api/ref/sampled_parameters) | function | SampledParameters returns the parameters carrying a distribution and NO update — drawn once at setup (uncertainty quantification, ensembles). |
| `SchemaError` | [`schema_error`](/generated/api/ref/schema_error-error) | error | SchemaError represents a JSON Schema violation |
| `SchemaVersion` | [`schema_version`](/generated/api/ref/schema_version) | constant | SchemaVersion is the schema version this library implements, derived from the embedded schema's `$id` so it cannot hand-drift from the canonical esm-schema.json. |
| `Simplify` | [`simplify`](/generated/api/ref/simplify) | function | Simplify performs constant folding and basic algebraic simplification. |
| `Solver` | [`solver`](/generated/api/ref/solver) | type | Solver carries numerics the document knows about ITSELF — stiffness, integration tolerances, and a splitting hint — which each binding maps to its own integrator (esm-spec §2.2). |
| `SolverExternalLocation` | [`solver_external_location`](/generated/api/ref/solver_external_location) | function | SolverExternalLocation resolves the document's `solver.external` to a location by esm-spec §2.2.6, or returns "" when the root document's `solver` block carries none (an authored… |
| `SolverTimeSpan` | [`solver_time_span`](/generated/api/ref/solver_time_span) | type | SolverTimeSpan is the interval the document's author means it to be simulated over (esm-spec §2.2.7). |
| `Species` | [`species`](/generated/api/ref/species) | type | Species represents a chemical species |
| `StoichiometricMatrix` | [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | StoichiometricMatrix returns the NET stoichiometric matrix of a reaction network: rows are species in declaration order (see the file header), columns are reactions in… |
| `StructuralError` | [`structural_error`](/generated/api/ref/structural_error) | error | StructuralError represents equation/unknown balance, reference integrity issues |
| `Substitute` | [`substitute`](/generated/api/ref/substitute) | function | Substitute performs variable substitution in expressions. |
| `SubstituteInEquations` | [`substitute_in_equations`](/generated/api/ref/substitute_in_equations) | function | SubstituteInEquations applies `bindings` across a model. |
| `SubstituteInModel` | [`substitute_in_model`](/generated/api/ref/substitute_in_model) | function | SubstituteInModel performs substitution across an entire model. |
| `SubstituteInModelWithContext` | [`substitute_in_model_with_context`](/generated/api/ref/substitute_in_model_with_context) | function | SubstituteInModelWithContext performs substitution across an entire model with scoped reference support. |
| `SubstituteInReactionSystem` | [`substitute_in_reaction_system`](/generated/api/ref/substitute_in_reaction_system) | function | SubstituteInReactionSystem performs substitution across an entire reaction system. |
| `SubstituteInReactionSystemWithContext` | [`substitute_in_reaction_system_with_context`](/generated/api/ref/substitute_in_reaction_system_with_context) | function | SubstituteInReactionSystemWithContext performs substitution across an entire reaction system with scoped reference support. |
| `SubstituteWithContext` | [`substitute_with_context`](/generated/api/ref/substitute_with_context) | function | SubstituteWithContext performs variable substitution in a SCOPE CONTEXT: the (file, currentSystem) pair against which a dotted binding key like "OtherModel.x" is resolved. |
| `SupportedMigrationTargets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | SupportedMigrationTargets returns the schema versions `sourceVersion` can be migrated to. |
| `SweepDimension` | [`sweep_dimension`](/generated/api/ref/sweep_dimension) | type | SweepDimension is one axis of a parameter sweep; exactly one of Values or Range is set. |
| `SweepRange` | [`sweep_range`](/generated/api/ref/sweep_range) | type | SweepRange is a generated range of parameter values. |
| `SystemKind` | [`system_kind`](/generated/api/ref/system_kind-function) | function | SystemKind derives what the `system_kind` field declares (esm-spec §6.3.1), testing four conditions IN ORDER and taking the first that holds: |
| `TemporalDomain` | [`temporal_domain`](/generated/api/ref/temporal_domain) | type | TemporalDomain represents temporal bounds |
| `TermOrigin` | [`term_origin`](/generated/api/ref/term_origin) | type | TermOrigin names who authored one contribution to a flattened equation. |
| `TimePoint` | [`time_point`](/generated/api/ref/time_point) | type | TimePoint is one bound of a SolverTimeSpan: either a number in the document's time units (seconds of the independent variable) or an RFC 3339 UTC timestamp… |
| `TimeSpan` | [`time_span`](/generated/api/ref/time_span) | type | TimeSpan is a simulation time interval expressed in the component's time units. |
| `ToASCII` | [`to_ascii`](/generated/api/ref/to_ascii) | function | ToASCII converts an expression, equation or container to a plain-text string using the ascii render format (function-call notation, no Unicode symbols in the operator layer). |
| `ToDOT` | [`to_dot`](/generated/api/ref/to_dot) | function | ToDOT renders a graph in DOT (Graphviz) format. |
| `ToJSON` | [`to_json`](/generated/api/ref/to_json) | function | ToJSON validates an ESM file and returns it as an indented canonical JSON string. |
| `ToJSONCompact` | [`to_json_compact`](/generated/api/ref/to_json_compact) | function | ToJSONCompact validates an ESM file and returns it as a compact canonical JSON string (no indentation). |
| `ToJSONGraph` | [`to_json_graph`](/generated/api/ref/to_json_graph) | function | ToJSONGraph renders a graph as a JSON adjacency list. |
| `ToLatex` | [`to_latex`](/generated/api/ref/to_latex) | function | ToLatex converts an expression, equation or container to a LaTeX string with chemical subscripts and operator precedence. |
| `Tolerance` | [`tolerance`](/generated/api/ref/tolerance) | type | Tolerance is a numerical comparison tolerance. |
| `ToMermaid` | [`to_mermaid`](/generated/api/ref/to_mermaid) | function | ToMermaid renders a graph in Mermaid format. |
| `ToUnicode` | [`to_unicode`](/generated/api/ref/to_unicode) | function | ToUnicode converts an expression, equation or container to a Unicode string with chemical subscripts and operator precedence. |
| `Unit` | [`unit`](/generated/api/ref/unit) | type | Unit is a named physical unit with a dimension vector and a scale factor relative to the canonical SI combination represented by Dim. |
| `UnitFindingAnalysis` | [`unit_finding_analysis`](/generated/api/ref/unit_finding_analysis) | constant | Unit-finding codes. |
| `UnitFindingDimensionalMismatch` | [`unit_finding_dimensional_mismatch`](/generated/api/ref/unit_finding_dimensional_mismatch) | constant | Unit-finding codes. |
| `UnitFindingDimensionlessLiteral` | [`unit_finding_dimensionless_literal`](/generated/api/ref/unit_finding_dimensionless_literal) | constant | UnitFindingDimensionlessLiteral — a check site the CURRENT neutral-literal rule passes or skips fails once a nonzero bare numeric literal is read as dimensionless at scale 1… |
| `UnitFindingUnparseable` | [`unit_finding_unparseable`](/generated/api/ref/unit_finding_unparseable) | constant | Unit-finding codes. |
| `UnitWarning` | [`unit_warning`](/generated/api/ref/unit_warning) | type | UnitWarning represents a finding from dimensional analysis. |
| `Validate` | [`validate`](/generated/api/ref/validate) | function | Validate performs semantic validation of an already-parsed ESM document and returns the four-field ValidationResult of esm-libraries-spec §3.4. |
| `ValidateEquationDimensions` | [`validate_equation_dimensions`](/generated/api/ref/validate_equation_dimensions) | function | ValidateEquationDimensions checks that the LHS and RHS of an equation have the same dimension. |
| `ValidateStructural` | [`validate_structural`](/generated/api/ref/validate_structural) | function | ValidateStructural performs comprehensive structural validation of an ESM file and returns the legacy message-oriented DetailedValidationResult. |
| `ValidateText` | [`validate_text`](/generated/api/ref/validate_text) | function | ValidateText validates an ESM document supplied as JSON TEXT: the schema check the document AS WRITTEN must pass, then — only if it passes — the semantic checks Validate runs… |
| `ValidationResult` | [`validation_result`](/generated/api/ref/validation_result) | type | ValidationResult holds the result of validation per ESM Libraries Spec Section 3.4 |
| `VariableInUseError` | [`variable_in_use_error`](/generated/api/ref/variable_in_use_error) | error | VariableInUseError reports an attempt to remove a name that is still referenced. |
| `VariableNode` | [`variable_node`](/generated/api/ref/variable_node) | type | VariableNode represents a node in the expression graph |
| `VertexKind` | [`vertex_kind`](/generated/api/ref/vertex_kind) | type | VertexKind is one of the three kinds of vertex in a reference graph. |
| `WritePath` | [`write_path`](/generated/api/ref/write_path) | function | WritePath writes an ESM file to path as indented canonical JSON. |
