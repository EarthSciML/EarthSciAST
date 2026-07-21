"""
    EarthSciAST

EarthSciML Serialization Format Julia library.

This module provides Julia types and functions for working with ESM format files,
which are JSON-based serialization format for EarthSciML model components,
their composition, and runtime configuration.

Deep ModelingToolkit/Catalyst integration is provided by package extensions
(`EarthSciASTMTKExt`, `EarthSciASTCatalystExt`) that load
automatically when the user imports `ModelingToolkit` or `Catalyst`. Without
those packages loaded, `flatten` still produces a pure-Julia `FlattenedSystem`
snapshot, and the MTK-free tree-walk runtime (`build_evaluator`, `simulate`)
runs it end to end.

Two features live in namespaced submodules rather than the flat namespace:
`EarthSciAST.Cadence` (the conformance-only raw-JSON cadence classifier,
spec §5.7 — the §5.7 pass driver itself lives in the conformance adapter,
`scripts/cadence_adapter.jl`) and `EarthSciAST.Relational` (build-time
relational kernels). Their generic names (`classify`, `equijoin`, …) are
deliberately not re-exported — reach them qualified.
"""
module EarthSciAST

using Dates
using JSON3
using JSONSchema
using RuntimeGeneratedFunctions
using Tullio

# The tree-walk codegen tier (tree_walk/codegen_kernel.jl) compiles emitted
# kernel source through this module's RGF cache.
RuntimeGeneratedFunctions.init(@__MODULE__)

# Core data model + validation
include("types.jl")
# Operator-vocabulary registry — single source of truth for the derived op
# sets (tree-walk fold/CSE/stencil/geometry whitelists, the MTK-ext known-op
# set, validate.jl's builtin names, units.jl's dimensional-rule classes, and
# display.jl's infix precedence/separator lookups). Pure data, no AST
# dependency; must precede validate.jl/display.jl/units.jl and tree_walk.jl,
# whose derived consts are computed at include time.
include("op_registry.jl")
include("validate.jl")
# Flattening pipeline (reactions → equations, subsystem flattening, shapes).
# flatten()'s stages live in sibling files: error taxonomy, namespacing +
# per-system collection, coupling application, pointwise lift, orchestrator,
# and the standalone array-shape-inference pass.
include("reactions.jl")
include("flatten_errors.jl")
include("namespacing.jl")
include("coupling_apply.jl")
include("pointwise_lift.jl")
include("flatten.jl")
include("array_shape_inference.jl")
include("shape_promotion.jl")
# Load-time lowering passes (closed registry, templates, imports) and their
# shared raw-JSON traversal helpers
include("json_walk.jl")
include("registered_functions.jl")
include("lower_expression_templates.jl")
include("template_imports.jl")
# Wire I/O
include("parse.jl")
include("serialize.jl")
# Document load pipeline + subsystem-ref linker (RFC-3986 URL machinery,
# top-level {ref} inlining, cycle detection, index-set registry merge)
include("resolve.jl")
# Coupling-library files + `coupling_import` role binding (esm-spec §10.9–§10.11)
include("coupling_imports.jl")
# Expression operations, rendering, and tooling
include("expression.jl")
# Structural interning (hash-consing) of the expression AST — perf plan A1.
include("intern.jl")
include("display.jl")
include("graph.jl")
include("units.jl")
include("edit.jl")
include("codegen.jl")
include("canonicalize.jl")
# Build-time kernels, MTK-export glue, geometry
include("relational.jl")
include("mtk_export.jl")
include("geometry.jl")
include("area_faq.jl")
# Planar spatial-index broad phase (projection-pushdown Phase 3a): a
# dependency-free brute-force reference + the generic seam whose fast STRtree
# method lives in EarthSciASTGeometryOpsExt.
include("broad_phase.jl")
# MTK-free runtime (tree-walk evaluator, refresh, simulate, cadence)
include("tree_walk.jl")
include("data_refresh.jl")
include("simulate.jl")
include("reference_graph.jl")
include("cadence.jl")
include("value_invention.jl")
# Inline-test runners (spec §6.6; called as API by downstream model repos)
include("run_tests.jl")
include("pde_inline_tests.jl")

export
    # Reference resolution — semiring-FAQ node addressing (RFC §6.1).
    # The graph-query methods (dependencies/dependents/detect_cycle/
    # topological_order/edges_of_kind) are intentionally NOT exported: they are
    # generic names (e.g. `dependencies` collides with `Pkg.dependencies`) and
    # are reached as `EarthSciAST.dependencies(graph, key)`.
    ReferenceGraph, ReferenceVertex, ReferenceEdge, ReferenceResolutionError,
    build_reference_graph, resolve_references,
    # Expression types
    ASTExpr, NumExpr, IntExpr, VarExpr, OpExpr,
    # Literal predicates (RFC §5.4.1 int/float distinction)
    is_literal, literal_value,
    # Equation types
    Equation, AffectEquation,
    # Model component types
    ModelVariableType, StateVariable, ParameterVariable, ObservedVariable, BrownianVariable,
    DiscreteVariable,
    ModelVariable, Model, SubsystemRef, Species, Parameter, Reaction, ReactionSystem,
    # Event types
    EventType, ContinuousEvent, DiscreteEvent, DiscreteEventTrigger,
    ConditionTrigger, PeriodicTrigger, PresetTimesTrigger,
    # Data and operator types
    DataLoader, DataLoaderSource, DataLoaderTemporal,
    DataLoaderVariable, DataLoaderDeterminism,
    CouplingEntry,
    # Concrete coupling types
    CouplingOperatorCompose, CouplingCouple, CouplingVariableMap,
    CouplingOperatorApply, CouplingCallback, CouplingEvent, CouplingImport,
    # Coupling-library reuse (esm-spec §10.9–§10.11)
    expand_coupling_imports,
    # Flattened system (§4.7.5 / §4.7.6)
    FlattenMetadata, FlattenedSystem, flatten, lower_reactions_to_equations,
    infer_array_shapes,
    # Flatten error taxonomy (spec §4.7.6.10, 8 types for cross-language parity)
    ConflictingDerivativeError, DimensionPromotionError, UnmappedDomainError,
    UnsupportedMappingError, DomainUnitMismatchError,
    DomainExtentMismatchError, SliceOutOfDomainError, CyclicPromotionError,
    # System types
    Domain, Reference, Metadata, EsmFile,
    FunctionTable, FunctionTableAxis,
    # JSON functionality
    load, save, ParseError, SchemaValidationError, SchemaError, validate_schema,
    parse_expression, ESM_FORMAT_VERSION,
    # Subsystem reference resolution
    resolve_subsystem_refs!, SubsystemRefError,
    # Coupling serialization functions
    serialize_coupling_entry, coerce_coupling_entry,
    # Structural validation
    StructuralError, ValidationResult, validate_structural, validate,
    validate_reaction_rate_units,
    # Expression operations. Expression containment extends `Base.contains`
    # (always in scope for consumers), so `contains` is not re-exported.
    substitute, free_variables, simplify, UnboundVariableError,
    # Qualified reference resolution
    resolve_qualified_reference, QualifiedReferenceError, ReferenceResolution,
    validate_reference_syntax, is_valid_identifier,
    # Reaction system ODE derivation
    derive_odes, stoichiometric_matrix, mass_action_rate,
    # Graph analysis (Section 4.8)
    Graph, ComponentNode, CouplingEdge, VariableNode, DependencyEdge,
    component_graph, expression_graph, adjacency, predecessors, successors,
    to_dot, to_mermaid, to_json,
    # Chemical subscript rendering
    render_chemical_formula, format_node_label,
    # Unit validation
    parse_units, get_expression_dimensions, validate_equation_dimensions,
    validate_model_dimensions, validate_reaction_system_dimensions, validate_file_dimensions,
    infer_variable_units,
    # The error-collecting units engine: these distinguish a PROVABLE dimensional
    # inconsistency from an indeterminate one, which the Bool/`nothing` API above
    # cannot. `validate()` is built on these.
    expression_unit_findings, equation_unit_findings, model_unit_findings,
    UnitFinding, UNIT_DIMENSION_MISMATCH, UNIT_PARSE_ERROR,
    # Editing operations (Section 4). EsmFile merging extends `Base.merge`
    # (always in scope for consumers), so `merge` is not re-exported.
    EditError,
    add_variable, remove_variable, rename_variable,
    add_equation, remove_equation, substitute_in_equations,
    add_reaction, remove_reaction, add_species, remove_species,
    add_continuous_event, add_discrete_event, remove_event,
    add_coupling, remove_coupling, compose, map_variable,
    extract,
    # Code generation
    to_julia_code,
    # Text display formats
    to_ascii, format_expression_ascii,
    to_unicode, to_latex,
    # Canonical AST form (RFC §5.4)
    canonicalize, canonical_json, format_canonical_float, CanonicalizeError,
    # MTK → ESM export (gt-dod2; Phase 1 migration tooling)
    mtk2esm, mtk2esm_gaps, GapReport,
    # Planar spatial-index broad phase (projection-pushdown Phase 3a). The fast
    # STRtree `broad_phase_candidates(query_envs, index)` method + the
    # `build_spatial_index` producer live in EarthSciASTGeometryOpsExt; the core
    # `broad_phase_candidates(query_envs, cell_envs)` brute-force method is the
    # dependency-free fallback + conformance oracle.
    broad_phase_candidates, build_spatial_index,
    # Tree-walk evaluator (gt-e8yw; MTK-free RHS path)
    build_evaluator, evaluate_expr, TreeWalkError, BuildInspection,
    DiscreteMaterializer,
    # Discrete-cadence loader refresh (ess-14f.4, JL-J1; callback ctor in the
    # DiffEqCallbacks/SciMLBase extension). The Provider protocol has concrete
    # impls in the data binding (EarthSciIO); regrid is an in-model coupling
    # expression the RHS evaluates (the obsolete RegridApplier seam was removed).
    build_refresh_callback, RefreshBuffers, RefreshError,
    provider_refresh_times, provider_is_const, provider_sample,
    # Out-of-place RHS explicit-buffers surface (perf-plan B2): the traced-
    # argument binding of the live forcing buffers, plus the refresh-side hook
    # that mirrors a host refresh into the compiled program's argument arrays.
    rhs_with_buffers, forcing_buffers, forcing_buffer_index, sync_forcing!,
    # One-call run entry (load → discretize → build_evaluator → seed → refresh →
    # solve); the solve lives in the SciMLBase extension (JL-J3, Phase 5).
    # `prepare` runs the deterministic-per-document pipeline ONCE into a cached
    # `PreparedModel`; `simulate(prep, tspan; …)` skips prep/build entirely.
    simulate, SimulationResult, SimulateError, seed_expression_ic!, final_state,
    prepare, PreparedModel,
    # Inline-test runner (esm-ol5qa; spec §6.6)
    AssertionStatus, AssertionResult, PASS, FAIL, ERROR, SKIP,
    esm_root, esm_path,
    discover_esm_files, run_esm_tests, write_junit_xml,
    # PDE inline-test runner (spec §6.6.5) over the tree-walk pathway
    PdeAssertionResult, run_pde_tests, evaluate_cellwise, field_reduce,
    # Closed function registry (esm-tzp / esm-4aw; esm-spec §9.2)
    evaluate_closed_function, evaluate_closed_function_ad,
    closed_function_names, ClosedFunctionError,
    lower_enums!,
    # Expression-template expansion (esm-spec §9.6 / docs/rfcs/ast-expression-templates.md)
    lower_expression_templates, reject_expression_templates_pre_v04,
    ExpressionTemplateError,
    # Template-library imports + load-time metaparameters (esm-spec §9.7 /
    # docs/content/rfcs/template-library-imports.md)
    resolve_template_machinery, reject_template_imports_pre_v08

end # module EarthSciAST
