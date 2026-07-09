"""
    EarthSciAST

EarthSciML Serialization Format Julia library.

This module provides Julia types and functions for working with ESM format files,
which are JSON-based serialization format for EarthSciML model components,
their composition, and runtime configuration.

Deep ModelingToolkit/Catalyst integration is provided by package extensions
(`EarthSciASTMTKExt`, `EarthSciASTCatalystExt`) that load
automatically when the user imports `ModelingToolkit` or `Catalyst`. Without
those packages loaded, `MockMTKSystem`, `MockPDESystem`, and `MockCatalystSystem`
give plain-Julia snapshots of the flattened system with the same ODE/PDE split.

Two features live in namespaced submodules rather than the flat namespace:
`EarthSciAST.Cadence` (loader-cadence classification and model
partitioning, spec §5.7) and `EarthSciAST.Relational` (build-time
relational kernels). Their generic names (`classify`, `partition_model`,
`equijoin`, …) are deliberately not re-exported — reach them qualified.
"""
module EarthSciAST

using Dates
using JSON3
using JSONSchema
using Tullio

# Core data model + validation
include("types.jl")
include("validate.jl")
# Flattening pipeline (reactions → equations, subsystem flattening, shapes)
include("reactions.jl")
include("flatten.jl")
include("shape_promotion.jl")
include("mock_systems.jl")
# Load-time lowering passes (closed registry, templates, imports)
include("registered_functions.jl")
include("lower_expression_templates.jl")
include("template_imports.jl")
# Wire I/O
include("parse.jl")
include("serialize.jl")
# Coupling-library files + `coupling_import` role binding (esm-spec §10.9–§10.11)
include("coupling_imports.jl")
# Expression operations, rendering, and tooling
include("expression.jl")
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
    Expr, NumExpr, IntExpr, VarExpr, OpExpr,
    # Literal predicates (RFC §5.4.1 int/float distinction)
    is_literal, literal_value,
    # Equation types
    Equation, AffectEquation,
    # Model component types
    ModelVariableType, StateVariable, ParameterVariable, ObservedVariable, BrownianVariable,
    ModelVariable, Model, SubsystemRef, Species, Parameter, Reaction, ReactionSystem,
    # Event types
    EventType, ContinuousEvent, DiscreteEvent, FunctionalAffect, DiscreteEventTrigger,
    ConditionTrigger, PeriodicTrigger, PresetTimesTrigger,
    # Data and operator types
    DataLoader, DataLoaderSource, DataLoaderTemporal,
    DataLoaderVariable, DataLoaderDeterminism,
    Operator, RegisteredFunction, RegisteredFunctionSignature, CouplingEntry,
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
    validate_reaction_rate_units, validate_model_gradient_units,
    # Expression operations. Expression containment extends `Base.contains`
    # (always in scope for consumers), so `contains` is not re-exported.
    substitute, free_variables, simplify, UnboundVariableError,
    # Qualified reference resolution
    resolve_qualified_reference, QualifiedReferenceError, ReferenceResolution,
    validate_reference_syntax, is_valid_identifier,
    # Reaction system ODE derivation
    derive_odes, stoichiometric_matrix, mass_action_rate,
    # Mock systems (no-MTK / no-Catalyst fallbacks)
    MockMTKSystem, MockPDESystem, MockCatalystSystem,
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
    to_julia_code, to_python_code,
    # Text display formats
    to_ascii, format_expression_ascii,
    to_unicode, to_latex,
    # Canonical AST form (RFC §5.4)
    canonicalize, canonical_json, format_canonical_float, CanonicalizeError,
    # MTK → ESM export (gt-dod2; Phase 1 migration tooling)
    mtk2esm, mtk2esm_gaps, GapReport,
    # Tree-walk evaluator (gt-e8yw; MTK-free RHS path)
    build_evaluator, evaluate_expr, TreeWalkError, BuildInspection,
    DiscreteMaterializer,
    # Discrete-cadence loader refresh (ess-14f.4, JL-J1; callback ctor in the
    # DiffEqCallbacks/SciMLBase extension). The Provider protocol has concrete
    # impls in the data binding (EarthSciIO); regrid is an in-model coupling
    # expression the RHS evaluates (the obsolete RegridApplier seam was removed).
    build_refresh_callback, RefreshBuffers, RefreshError,
    provider_refresh_times, provider_is_const, provider_sample,
    # One-call run entry (load → discretize → build_evaluator → seed → refresh →
    # solve); the solve lives in the SciMLBase extension (JL-J3, Phase 5).
    simulate, SimulationResult, SimulateError, seed_expression_ic!, final_state,
    # Inline-test runner (esm-ol5qa; spec §6.6)
    AssertionStatus, AssertionResult, PASS, FAIL, ERROR, SKIP,
    esm_root, esm_path,
    discover_esm_files, run_esm_tests, write_junit_xml,
    # PDE inline-test runner (spec §6.6.5) over the tree-walk pathway
    PdeAssertionResult, run_pde_tests, evaluate_cellwise, field_reduce,
    # Closed function registry (esm-tzp / esm-4aw; esm-spec §9.2)
    evaluate_closed_function, closed_function_names, ClosedFunctionError,
    lower_enums!,
    # Expression-template expansion (esm-spec §9.6 / docs/rfcs/ast-expression-templates.md)
    lower_expression_templates, reject_expression_templates_pre_v04,
    ExpressionTemplateError,
    # Template-library imports + load-time metaparameters (esm-spec §9.7 /
    # docs/content/rfcs/template-library-imports.md)
    resolve_template_machinery, reject_template_imports_pre_v08

end # module EarthSciAST
