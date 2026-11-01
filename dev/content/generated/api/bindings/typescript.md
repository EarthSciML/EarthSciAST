---
title: "TypeScript API index"
description: "Every stable name TypeScript exports, and its extension seams."
type: "api"
---


**Package:** `@earthsciml/ast` 0.7.0

Documentation extracted with typescript 6.0.3 compiler API.

**Capability profiles:** core, classification.

Extension-tier names are on the [TypeScript extension page](/generated/api/extension/typescript).

## Stable names

| TypeScript | Canonical | Kind | Summary |
|---|---|---|---|
| `addContinuousEvent` | [`add_continuous_event`](/generated/api/ref/add_continuous_event) | function | Add a continuous event to a model |
| `addCoupling` | [`add_coupling`](/generated/api/ref/add_coupling) | function | Add a coupling entry to an ESM file |
| `addDiscreteEvent` | [`add_discrete_event`](/generated/api/ref/add_discrete_event) | function | Add a discrete event to a model |
| `addEquation` | [`add_equation`](/generated/api/ref/add_equation) | function | Add a new equation to a model |
| `addReaction` | [`add_reaction`](/generated/api/ref/add_reaction) | function | Add a new reaction to a reaction system |
| `addSpecies` | [`add_species`](/generated/api/ref/add_species) | function | Add a new species to a reaction system |
| `addVariable` | [`add_variable`](/generated/api/ref/add_variable) | function | Add a new variable to a model |
| `algebraicUnknowns` | [`algebraic_unknowns`](/generated/api/ref/algebraic_unknowns) | function | Unknowns constrained only implicitly — no equation names them on its LHS (`H*H*SO4 ~ Ksp`). |
| `applyScopeInjections` | [`apply_scope_injections`](/generated/api/ref/apply_scope_injections) | function | esm-spec §9.7.10 forms A + B: if `raw` needs a scope-directed injection (a non-empty subsystem-ref edge list `injected`, or a coupling entry carrying an injection map), return a… |
| `brownianParameters` | [`brownian_parameters`](/generated/api/ref/brownian_parameters) | function | Parameters whose `update.kind` is `wiener` — the SDE noise sources. |
| `buildReferenceGraph` | [`build_reference_graph`](/generated/api/ref/build_reference_graph) | function | Resolve the reference edges of ONE `model` into a `ReferenceGraph`. |
| `canMigrate` | [`can_migrate`](/generated/api/ref/can_migrate) | function | Check if migration is possible from the source version to target version. |
| `canonicalize` | [`canonicalize`](/generated/api/ref/canonicalize) | function | Canonicalize an expression tree per RFC §5.4. |
| `CanonicalizeError` | [`canonicalize_error`](/generated/api/ref/canonicalize_error) | error | Canonical-form error carrying a stable RFC §5.4.6 / §5.4.7 `code` string (`E_CANONICAL_NONFINITE`, `E_CANONICAL_DIVBY_ZERO`). |
| `canonicalJson` | [`canonical_json`](/generated/api/ref/canonical_json) | function | Emit canonical on-wire JSON per §5.4.6 (sorted keys, no whitespace). |
| `CircularReferenceError` | [`circular_reference_error`](/generated/api/ref/circular_reference_error) | error | Error thrown when a circular reference is detected during subsystem resolution. |
| `ClosedFunctionError` | [`closed_function_error`](/generated/api/ref/closed_function_error) | error | Error thrown by closed function dispatch and load-time table validation. |
| `closedFunctionNames` | [`closed_function_names`](/generated/api/ref/closed_function_names) | function | Names that bindings MUST recognize (derived from the dispatch table keys). |
| `componentExists` | [`component_exists`](/generated/api/ref/component_exists) | function | Utility to check if a component exists in the ESM file |
| `ComponentGraph` | [`component_graph`](/generated/api/ref/component_graph-type) | type | System graph representation with components and couplings |
| `componentGraph` | [`component_graph`](/generated/api/ref/component_graph-function) | function | Extract the system graph from an ESM file. |
| `ComponentNode` | [`component_node`](/generated/api/ref/component_node) | type | Graph node representing a component in the system |
| `compose` | [`compose`](/generated/api/ref/compose) | function | Compose two systems using a coupling entry |
| `ConflictingDerivativeError` | [`conflicting_derivative_error`](/generated/api/ref/conflicting_derivative_error) | error | Two systems define non-additive equations for the same dependent variable — the §4.7.5 over-determination check. |
| `constantParameters` | [`constant_parameters`](/generated/api/ref/constant_parameters) | function | Parameters with neither a `distribution` nor an `update` — plain constants. |
| `contains` | [`contains`](/generated/api/ref/contains) | function | Check if an expression contains a specific variable |
| `Contribution` | [`contribution`](/generated/api/ref/contribution) | type | One summand of a flattened equation's right-hand side, with its authors. |
| `convertUnits` | [`convert_units`](/generated/api/ref/convert_units) | function | Convert a numeric value from one unit string to another. |
| `CoupleMultiplicativeNoTendencyError` | [`couple_multiplicative_no_tendency_error`](/generated/api/ref/couple_multiplicative_no_tendency_error) | error | A `couple` connector equation with `transform: "multiplicative"` targets something with no tendency to multiply. |
| `CouplingEdge` | [`coupling_edge`](/generated/api/ref/coupling_edge) | type | Graph edge representing a coupling relationship |
| `CouplingImportOptions` | [`coupling_import_options`](/generated/api/ref/coupling_import_options) | type | Options controlling how `coupling_import` refs are resolved at flatten. |
| `declaredSystemKind` | [`declared_system_kind`](/generated/api/ref/declared_system_kind) | function | The model's explicit `system_kind` field, or `null` when absent. |
| `DEFAULT_ABSTOL` | [`default_abstol`](/generated/api/ref/default_abstol) | constant | Binding default absolute tolerance (API_SPEC §5.8) — the bottom of the §2.2.2 chain, used when neither the caller nor `solver.abstol` sets one. |
| `DEFAULT_RELTOL` | [`default_reltol`](/generated/api/ref/default_reltol) | constant | Binding default relative tolerance (API_SPEC §5.8) — the bottom of the §2.2.2 chain, used when neither the caller nor `solver.reltol` sets one. |
| `DependencyEdge` | [`dependency_edge`](/generated/api/ref/dependency_edge) | type | Graph edge representing a dependency between variables. |
| `deriveODEs` | [`derive_odes`](/generated/api/ref/derive_odes) | function | --- |
| `deriveOdes` | [`derive_odes`](/generated/api/ref/derive_odes) | function | Derive ODEs from a reaction system using mass action kinetics |
| `DimensionPromotionError` | [`dimension_promotion_error`](/generated/api/ref/dimension_promotion_error) | error | A variable or equation cannot be promoted onto the target grid — raised by the §10.5 pointwise spatial lift when a species' operator makearrays yield no full-rank… |
| `discreteParameters` | [`discrete_parameters`](/generated/api/ref/discrete_parameters) | function | Parameters carrying any OTHER update — piecewise-constant between refreshes. |
| `DomainUnitMismatchError` | [`domain_unit_mismatch_error`](/generated/api/ref/domain_unit_mismatch_error) | error | An `identity`-transform `variable_map` bridges two variables whose declared, non-empty units differ (esm-libraries-spec §4.7.6). |
| `EdgeKind` | [`edge_kind`](/generated/api/ref/edge_kind) | type | The three kinds of reference edge (RFC §6.1 "Propagation"). |
| `effectiveSystemKind` | [`effective_system_kind`](/generated/api/ref/effective_system_kind) | function | The kind a caller choosing a solver actually asks for: the DECLARED `system_kind` when the document states one, otherwise the DERIVED kind. |
| `emitDocument` | [`emit_document`](/generated/api/ref/emit_document) | function | Produce the reference-preserving, self-contained emitted document (esm-spec §9.6.4 rule 5, RFC out-of-line-expression-templates §7.5) from a source document `rawSource` (a… |
| `emitEsmString` | [`emit_esm_string`](/generated/api/ref/emit_esm_string) | function | Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5): 2-space indent, object keys sorted lexicographically (UTF-8 byte order) EXCEPT the entries of an… |
| `EntityNotFoundError` | [`entity_not_found_error`](/generated/api/ref/entity_not_found_error) | error | Error thrown when attempting an operation on a non-existent entity |
| `EnumLoweringError` | [`enum_lowering_error`](/generated/api/ref/enum_lowering_error) | error | Error thrown by `lowerEnums` (and so by loading) when an `enum` op cannot be lowered. |
| `ephemeralInjectedFile` | [`ephemeral_injected_file`](/generated/api/ref/ephemeral_injected_file) | function | esm-spec §9.7.10 form C: build a throwaway `EsmFile` in which component `mname` has the run's `imports` (raw §9.7.2 entries) appended to its own `expression_template_imports`, so… |
| `ERROR_CODES` | [`error_codes`](/generated/api/ref/error_codes) | constant | Central registry of the diagnostic code STRINGS emitted by this binding, plus a neutral diagnostic base class. |
| `expandCouplingImports` | [`expand_coupling_imports`](/generated/api/ref/expand_coupling_imports) | function | Expand every `coupling_import` entry in `file.coupling` into concrete edges, splicing them in the position of the import entry (esm-spec §10.10.3). |
| `expandDocument` | [`expand_document`](/generated/api/ref/expand_document) | function | Fully expand every surviving `apply_expression_template` reference in a document `loaded` by `lowerExpressionTemplates` (Option B), producing the Option-A image: every reference… |
| `expressionGraph` | [`expression_graph`](/generated/api/ref/expression_graph-function) | function | Extract a variable-level dependency graph from an ESM file, model, reaction system, equation, reaction, or expression. |
| `ExpressionParseError` | [`expression_parse_error`](/generated/api/ref/expression_parse_error) | error | Thrown when an expression string cannot be parsed. |
| `ExpressionTemplateError` | [`expression_template_error`](/generated/api/ref/expression_template_error) | error | `instanceof ExpressionTemplateError` and `instanceof EsmMachineryError` are identical. |
| `extract` | [`extract`](/generated/api/ref/extract) | function | Extract a specific component from an ESM file into a new file |
| `flatten` | [`flatten`](/generated/api/ref/flatten) | function | Flatten a coupled multi-system ESM file into a single unified system (esm-libraries-spec §4.7.5). |
| `FlattenedEquation` | [`flattened_equation`](/generated/api/ref/flattened_equation) | type | A single equation of the flattened system, with dot-namespaced Expression TREES. |
| `FlattenedSystem` | [`flattened_system`](/generated/api/ref/flattened_system) | type | A fully flattened representation of a coupled ESM system — the canonical field set of esm-libraries-spec §4.7.5 step 4. |
| `FlattenedVariable` | [`flattened_variable`](/generated/api/ref/flattened_variable) | type | One variable of the flattened system, carrying the COMPLETE declared metadata step 4 requires ("Full metadata, not names"): a consumer must be able to build a solver problem from… |
| `FlattenError` | [`flatten_error`](/generated/api/ref/flatten_error) | error | Base class for every error `flatten` raises. |
| `FlattenMetadata` | [`flatten_metadata`](/generated/api/ref/flatten_metadata) | type | Metadata describing the origin of the flattened system. |
| `flattenTemplateRegistries` | [`flatten_template_registries`](/generated/api/ref/flatten_template_registries) | function | The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4). |
| `formatCanonicalFloat` | [`format_canonical_float`](/generated/api/ref/format_canonical_float) | function | Format a finite `number` as a byte-CANONICAL float token per RFC §5.4.6. |
| `freeParameters` | [`free_parameters`](/generated/api/ref/free_parameters) | function | Extract free parameters from an expression within a model context |
| `freeVariables` | [`free_variables`](/generated/api/ref/free_variables) | function | Extract all variable references from an expression. |
| `getComponentType` | [`get_component_type`](/generated/api/ref/get_component_type) | function | Get the type of a component by its ID |
| `getSupportedMigrationTargets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | --- |
| `Graph` | [`graph`](/generated/api/ref/graph) | type | Directed graph with node/edge lists plus adjacency, predecessor, and successor lookups (ESM Libraries Specification §4.8). |
| `isCouplingLibraryDoc` | [`is_coupling_library_doc`](/generated/api/ref/is_coupling_library_doc) | function | True when `raw` has the coupling-library-file FORM (top-level `coupling_roles`, esm-spec §10.9). |
| `isOdeState` | [`is_ode_state`](/generated/api/ref/is_ode_state) | function | Membership test for `odeStates`. |
| `isTemplateLibraryDoc` | [`is_template_library_doc`](/generated/api/ref/is_template_library_doc) | function | True when `raw` has the template-library-file FORM (top-level `expression_templates`, esm-spec §9.7.1). |
| `LIBRARY_VERSION` | [`library_version`](/generated/api/ref/library_version) | constant | The package's OWN version — distinct from `SCHEMA_VERSION`, which is the `.esm` FORMAT version this build implements. |
| `loadDocument` | [`load_document`](/generated/api/ref/load_document) | function | Parse an ESM document that is ALREADY a JavaScript object — the same document a `.esm` file holds, just already `JSON.parse`d. |
| `LoaderField` | [`loader_field`](/generated/api/ref/loader_field) | type | A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5). |
| `LoadOptions` | [`load_options`](/generated/api/ref/load_options) | type | Options controlling how the `load*` entry points parse and represent an ESM file. |
| `loadPath` | [`load_path`](/generated/api/ref/load_path) | function | Read and parse an ESM document from a filesystem path. |
| `loadString` | [`load_string`](/generated/api/ref/load_string) | function | Parse an ESM document from JSON TEXT. |
| `lowerEnums` | [`lower_enums`](/generated/api/ref/lower_enums) | function | Resolve every `enum` op in `file` against `file.enums`. |
| `lowerExpressionTemplates` | [`lower_expression_templates`](/generated/api/ref/lower_expression_templates) | function | Load the file under Option B (reference preservation, esm-spec §9.6.4): fire auto-applied `match` rules and eagerly expand target-bearing references to a fixpoint per component… |
| `mapVariable` | [`map_variable`](/generated/api/ref/map_variable) | function | Map a variable from one system to another with optional transformation |
| `MAX_TEMPLATE_EXPANSION_DEPTH` | [`max_template_expansion_depth`](/generated/api/ref/max_template_expansion_depth) | constant | Maximum template-body reference-chain depth (counted in TEMPLATES along the longest chain, so a 33-template chain is rejected while a 32-template chain is accepted) before a file… |
| `merge` | [`merge`](/generated/api/ref/merge) | function | Merge two ESM files |
| `migrate` | [`migrate`](/generated/api/ref/migrate) | function | Migrate an ESM file from its current schema version to the target version. |
| `MigrationError` | [`migration_error`](/generated/api/ref/migration_error) | error | Error thrown when migration fails. |
| `observedDefinitions` | [`observed_definitions`](/generated/api/ref/observed_definitions) | function | The DEFINING EXPRESSION of every observed unknown: the RHS of the equation whose LHS names it, bare (`y ~ f(…)`) or indexed (`y[i] ~ f(…)`). |
| `observedUnknowns` | [`observed_unknowns`](/generated/api/ref/observed_unknowns) | function | Unknowns an equation DEFINES — its LHS naming them, bare (`y ~ f(…)`) or indexed (`y[i] ~ f(…)`, which defines the whole array `y`) — eliminable, materializable (esm-spec §6.3.1). |
| `odeStates` | [`ode_states`](/generated/api/ref/ode_states) | function | Unknowns appearing under `D(·, t)` on some equation LHS — the integrated states. |
| `OperatorComposeAmbiguousBareNameError` | [`operator_compose_ambiguous_bare_name_error`](/generated/api/ref/operator_compose_ambiguous_bare_name_error) | error | The bare-name fallback would unify two STATE variables and the document has not said which spelling survives (esm-libraries-spec §4.7.1 step 3). |
| `OperatorComposeNoMergeError` | [`operator_compose_no_merge_error`](/generated/api/ref/operator_compose_no_merge_error) | error | An `operator_compose` entry merged NOTHING (esm-libraries-spec §4.7.1 step 5). |
| `OperatorComposeRequireMatchError` | [`operator_compose_require_match_error`](/generated/api/ref/operator_compose_require_match_error) | error | An `operator_compose` entry declared `require_match: true` and one of `systems[1]`'s equations found no equation of `systems[0]` to land on (esm-libraries-spec §4.7.1 step 5). |
| `parameters` | [`parameters`](/generated/api/ref/parameters) | function | Names of every variable declared `parameter`, sorted. |
| `parseEquation` | [`parse_equation`](/generated/api/ref/parse_equation) | function | Parse `lhs = rhs` into an `Equation`. |
| `ParseError` | [`parse_error`](/generated/api/ref/parse_error) | error | Parse error - thrown when JSON parsing fails |
| `parseExpression` | [`parse_expression`](/generated/api/ref/parse_expression) | function | Parse a single expression string into an AST expression — the inverse of `toAscii`. |
| `parseUnit` | [`parse_unit`](/generated/api/ref/parse_unit) | function | Parse a unit string into canonical SI dimensions plus scale factor. |
| `productMatrix` | [`product_matrix`](/generated/api/ref/product_matrix) | function | Compute product stoichiometric matrix from a reaction system |
| `ReferenceEdge` | [`reference_edge`](/generated/api/ref/reference_edge) | type | A directed `source → target` edge: *source references / depends on target*. |
| `ReferenceGraph` | [`reference_graph`](/generated/api/ref/reference_graph) | type | The resolved reference DAG for one model — the partition pass's input. |
| `ReferenceResolutionError` | [`reference_resolution_error`](/generated/api/ref/reference_resolution_error) | error | A reference could not be resolved, or the reference graph has a cycle. |
| `ReferenceVertex` | [`reference_vertex`](/generated/api/ref/reference_vertex) | type | A vertex in the reference graph, addressed by a kind-namespaced `key`. |
| `rejectExpressionTemplatesPreV04` | [`reject_expression_templates_pre_v04`](/generated/api/ref/reject_expression_templates_pre_v04) | function | Reject `apply_expression_template` and `expression_templates` in files declaring `esm` &lt; 0.4.0. |
| `rejectSolverExternalPreV13` | [`reject_solver_external_pre_v13`](/generated/api/ref/reject_solver_external_pre_v13) | function | Reject `solver.external` in a file declaring esm &lt; 1.3.0. |
| `rejectSolverPreV11` | [`reject_solver_pre_v11`](/generated/api/ref/reject_solver_pre_v11) | function | Reject a top-level `solver` block in a file declaring esm &lt; 1.1.0. |
| `rejectSolverTimeSpanPreV13` | [`reject_solver_time_span_pre_v13`](/generated/api/ref/reject_solver_time_span_pre_v13) | function | Reject `solver.time_span` in a file declaring esm &lt; 1.3.0. |
| `rejectTemplateImportsPreV08` | [`reject_template_imports_pre_v08`](/generated/api/ref/reject_template_imports_pre_v08) | function | `expression_template_imports`, top-level `expression_templates` (template-library files), and `metaparameters` arrive at `esm: 0.8.0`; files declaring an earlier version that… |
| `removeCoupling` | [`remove_coupling`](/generated/api/ref/remove_coupling) | function | Remove a coupling entry from an ESM file by index |
| `removeEquation` | [`remove_equation`](/generated/api/ref/remove_equation) | function | Remove an equation from a model |
| `removeEvent` | [`remove_event`](/generated/api/ref/remove_event) | function | Remove events from a model by name. |
| `removeReaction` | [`remove_reaction`](/generated/api/ref/remove_reaction) | function | Remove a reaction from a reaction system |
| `removeSpecies` | [`remove_species`](/generated/api/ref/remove_species) | function | Remove a species from a reaction system, with reference checking |
| `removeVariable` | [`remove_variable`](/generated/api/ref/remove_variable) | function | Remove a variable from a model, with reference checking |
| `renameVariable` | [`rename_variable`](/generated/api/ref/rename_variable) | function | Rename a variable throughout a model. |
| `resolveReferences` | [`resolve_references`](/generated/api/ref/resolve_references) | function | Resolve reference edges for EVERY model in `document`. |
| `resolveSubsystemRefs` | [`resolve_subsystem_refs`](/generated/api/ref/resolve_subsystem_refs) | function | Async resolution — the only entry point that can reach a REMOTE (`http(s)://`) ref, since `fetch` cannot be awaited synchronously. |
| `resolveTemplateMachinery` | [`resolve_template_machinery`](/generated/api/ref/resolve_template_machinery) | function | Resolve every esm-spec §9.7 construct of the ROOT document `rawData` (relative import refs resolve against `basePath`): imports recursively with per-edge instantiation,… |
| `resolveTimeSpan` | [`resolve_time_span`](/generated/api/ref/resolve_time_span) | function | The run interval by the esm-spec §2.2.7 chain: the call-site interval `tspan` when given (both bounds, always), otherwise the root document's `solver.time_span` converted to… |
| `resolveTolerances` | [`resolve_tolerances`](/generated/api/ref/resolve_tolerances) | function | Resolve integration tolerances most-specific first (esm-spec §2.2.2): |
| `sampledParameters` | [`sampled_parameters`](/generated/api/ref/sampled_parameters) | function | Parameters with a `distribution` and no `update` — drawn once at setup. |
| `SCHEMA_VERSION` | [`schema_version`](/generated/api/ref/schema_version) | constant | The schema version this library implements, derived from the embedded schema's `$id` (https://earthsciml.org/schemas/esm/&lt;version>/esm.schema.json) so it cannot hand-drift from… |
| `SchemaError` | [`schema_error`](/generated/api/ref/schema_error-type) | type | Schema validation error with JSON Pointer path |
| `SchemaValidationError` | [`schema_validation_error`](/generated/api/ref/schema_validation_error) | error | Schema validation error - thrown when schema validation fails |
| `simplify` | [`simplify`](/generated/api/ref/simplify) | function | Simplify an expression using basic algebraic rules |
| `solverExternalLocation` | [`solver_external_location`](/generated/api/ref/solver_external_location) | function | The location `solver.external` names, resolved by esm-spec §2.2.6, or `null` when the root document's `solver` block carries none. |
| `stoichiometricMatrix` | [`stoichiometric_matrix`](/generated/api/ref/stoichiometric_matrix) | function | Compute stoichiometric matrix from a reaction system |
| `substitute` | [`substitute`](/generated/api/ref/substitute) | function | Recursively substitute variable references in an expression with bound expressions. |
| `substituteInEquations` | [`substitute_in_equations`](/generated/api/ref/substitute_in_equations) | function | (exported from `substitute.js`) directly. |
| `substituteInModel` | [`substitute_in_model`](/generated/api/ref/substitute_in_model) | function | Apply substitution across an ENTIRE model, not just its equations. |
| `substituteInReactionSystem` | [`substitute_in_reaction_system`](/generated/api/ref/substitute_in_reaction_system) | function | Apply substitution across all rate expressions in a reaction system. |
| `substrateMatrix` | [`substrate_matrix`](/generated/api/ref/substrate_matrix) | function | Compute substrate stoichiometric matrix from a reaction system |
| `supportedMigrationTargets` | [`supported_migration_targets`](/generated/api/ref/supported_migration_targets) | function | Get the list of schema versions that a given source version can migrate to. |
| `SystemKind` | [`system_kind`](/generated/api/ref/system_kind-type) | type | The MTK system type a model maps to. |
| `systemKind` | [`system_kind`](/generated/api/ref/system_kind-function) | function | The system kind DERIVED from the equations and the parameter updates. |
| `TermOrigin` | [`term_origin`](/generated/api/ref/term_origin) | type | Who authored one contribution to a flattened equation. |
| `toAscii` | [`to_ascii`](/generated/api/ref/to_ascii) | function | Format an expression as plain ASCII text |
| `toDot` | [`to_dot`](/generated/api/ref/to_dot) | function | Export graph as Graphviz DOT format. |
| `toJson` | [`to_json`](/generated/api/ref/to_json) | function | Serialize an `EsmFile` to wire-form JSON. |
| `toJsonCompact` | [`to_json_compact`](/generated/api/ref/to_json_compact) | function | `toJson` with no indentation — the single-line wire form. |
| `toJsonGraph` | [`to_json_graph`](/generated/api/ref/to_json_graph) | function | Export graph as JSON adjacency list format for web consumption. |
| `toLatex` | [`to_latex`](/generated/api/ref/to_latex) | function | Format an expression as LaTeX mathematical notation |
| `toMermaid` | [`to_mermaid`](/generated/api/ref/to_mermaid) | function | Export graph as Mermaid flowchart format for Markdown embedding. |
| `toUnicode` | [`to_unicode`](/generated/api/ref/to_unicode) | function | Format an expression as Unicode mathematical notation |
| `UnitConversionError` | [`unit_conversion_error`](/generated/api/ref/unit_conversion_error) | error | Error thrown when a unit string cannot be parsed (unknown unit name, malformed number or exponent, unbalanced parentheses, trailing input) or when `convertUnits` is asked to… |
| `UnitWarning` | [`unit_warning`](/generated/api/ref/unit_warning) | type | Dimensional-consistency warning emitted during file-level validation. |
| `unknowns` | [`unknowns`](/generated/api/ref/unknowns) | function | Names of every variable declared `unknown`, sorted. |
| `validate` | [`validate`](/generated/api/ref/validate) | function | Validate a TYPED ESM DOCUMENT and return a structured validation result. |
| `validateSchema` | [`validate_schema`](/generated/api/ref/validate_schema) | function | Validate data against the ESM schema |
| `validateText` | [`validate_text`](/generated/api/ref/validate_text) | function | Validate ESM JSON **text**: parse it, then run `validate` on the result. |
| `validateUnits` | [`validate_units`](/generated/api/ref/validate_units) | function | Validate dimensional consistency of equations in an ESM file. |
| `ValidationError` | [`validation_error`](/generated/api/ref/validation_error) | type | Validation error with structured details |
| `ValidationResult` | [`validation_result`](/generated/api/ref/validation_result) | type | Structured validation result |
| `VariableInUseError` | [`variable_in_use_error`](/generated/api/ref/variable_in_use_error) | error | Error thrown when attempting to remove a variable that is still referenced |
| `VariableKind` | [`variable_kind`](/generated/api/ref/variable_kind) | type | The kind of a variable node. |
| `VariableNode` | [`variable_node`](/generated/api/ref/variable_node) | type | Graph node representing a variable/parameter/species in the system |
| `VertexKind` | [`vertex_kind`](/generated/api/ref/vertex_kind) | type | The three kinds of vertex in the reference graph. |
| `writePath` | [`write_path`](/generated/api/ref/write_path) | function | Write an `EsmFile` to `path` as wire-form JSON. |
