"""
    EarthSciAST

EarthSciML Abstract Syntax Tree Format Julia library.

This module provides Julia types and functions for working with ESM format files,
which are JSON-based serialization format for EarthSciML model components,
their composition, and runtime configuration.

Deep ModelingToolkit/Catalyst integration is provided by package extensions
(`EarthSciASTMTKExt`, `EarthSciASTCatalystExt`) that load
automatically when the user imports `ModelingToolkit` or `Catalyst`. Without
those packages loaded, `flatten` still produces a pure-Julia `FlattenedSystem`
snapshot, and the MTK-free tree-walk runtime (`esm_problem`)
runs it end to end.

The build-time relational kernels live in the submodule
`EarthSciAST.Relational`; their generic names (`distinct`, `equijoin`, …) are
deliberately not re-exported — reach them qualified.
"""
module EarthSciAST

using Dates
using JSON3
using JSONSchema
using LinearAlgebra   # BLAS `mul!` accelerator for linear mat-vec observeds (inline_tests.jl)
# The threaded RHS tier needs a thread dispatch that does NOT allocate a task
# per call (tree_walk/threading.jl): Polyester's persistent, spin-then-sleep
# worker pool, driven through ThreadingUtilities and PolyesterWeave directly.
# A hard dependency: native threads its compiled sections whenever Julia runs
# with more than one thread.
using Polyester: Polyester
using PolyesterWeave: PolyesterWeave
using ThreadingUtilities: ThreadingUtilities
using RuntimeGeneratedFunctions
using SHA: SHA
using Serialization: Serialization
using Tullio

# The tree-walk codegen tier (tree_walk/codegen_kernel.jl) compiles emitted
# kernel source through this module's RGF cache.
RuntimeGeneratedFunctions.init(@__MODULE__)

# Root of the exception hierarchy. Included FIRST and depends on nothing, so
# every `struct … <: EarthSciASTError` below resolves its supertype.
include("errors.jl")
# Central diagnostic-code registry. Pure data, no dependencies; must precede
# every raise site that names a code.
include("error_codes.jl")
# JSON pointers as diagnostics address a document (`_pointer`).
include("json_pointer.jl")
# The load pipeline's error type and the codes it is raised with; needs only
# errors.jl and error_codes.jl.
include("load_errors.jl")
# Compiler selection (API_SPEC §5.8, esm-libraries-spec §2.5.10): the closed
# vocabulary, the per-tier plan each value expands to, the per-build report and
# the strict-`native` refusal. Pure data plus task-local accessors; the types
# it raises (`SimulateError`, `TreeWalkError`) are resolved at call time, so it
# sits here, ahead of every tier that reads a plan.
include("compiler.jl")
# Core data model + validation
include("types.jl")
# The field tables of `OpExpr` and the document records, and what is generated
# from them at load (`reconstruct`); parse.jl and serialize.jl generate the wire
# directions from the same tables.
include("record_tables.jl")
# The record shape of a data-fed parameter (esm-spec §8.5.1).
include("record_shapes.jl")
# Resolving a qualified `System.sub.var` reference against a typed document.
include("qualified_reference.jl")
# Stoichiometry views of a `Reaction` and the dict-form `Reaction` constructor.
include("stoichiometry.jl")
# The expression sites of a typed document: `map_expressions!` / `foreach_expression`.
include("expression_sites.jl")
# The one cycle search over a string-keyed directed graph (`_find_cycle`).
include("digraph.jl")
# Derived variable classification (esm-spec §6.3.1). Must follow types.jl (it
# is stated over `Model`) and precede every consumer, which is nearly all of
# them: there are only two declared variable types, so ODE
# state / observed / algebraic / brownian / discrete / sampled / constant are
# all questions only this module may answer.
include("classification.jl")
# Operator-vocabulary registry — single source of truth for the derived op
# sets (tree-walk fold/CSE/stencil/geometry whitelists, the MTK-ext known-op
# set, the validator's builtin names, and units.jl's dimensional-rule classes).
# Pure data, no AST dependency; must precede src/validation/, units.jl and
# tree_walk.jl, whose derived consts are computed at include time.
include("op_registry.jl")
include("validation/records.jl")
include("validation/schema.jl")
include("validation/scoped_index.jl")
include("validation/validate.jl")
include("validation/balance.jl")
include("validation/data_updates.jl")
include("validation/declarations.jl")
include("validation/faq.jl")
include("validation/broadcast.jl")
include("validation/unit_checks.jl")
include("validation/cycles.jl")
include("validation/recurrence_groups.jl")
include("validation/references.jl")
include("validation/reactions.jl")
include("validation/events.jl")
include("validation/equation_lhs.jl")
include("validate_inline_tests.jl")
include("recurrence.jl")
# Load-time lowering passes (enums, templates, imports) and their shared
# raw-JSON traversal helpers
include("json_walk.jl")
include("enum_lowering.jl")
# Reference spelling and location: `${VAR}`, the bundled standard library, URLs.
include("ref_location.jl")
include("templates/declarations.jl")
include("templates/rewrite.jl")
include("templates/instances.jl")
include("templates/metaparameters.jl")
include("templates/imports.jl")
include("templates/expand_typed.jl")
include("templates/emit.jl")
include("templates/flat_registry.jl")
# Flattening pipeline (reactions → equations, subsystem flattening, shapes).
# flatten()'s stages live in sibling files (listed in flatten.jl's header).
# They load after the template files, whose types their signatures name.
include("reactions.jl")
include("flatten_errors.jl")
include("term_provenance.jl")
include("expr_axes.jl")
include("namespacing.jl")
include("coupling_apply.jl")
include("cell_read.jl")
include("elementwise_refs.jl")
include("pointwise_lift.jl")
include("flatten.jl")
include("flatten_template_dt.jl")
include("array_shape_inference.jl")
include("shape_promotion.jl")
include("elementwise_lift.jl")
# esm-spec §4.7 mount helpers (mount-declared metaparameters, data-source
# `extent` check, mount-edge index-set rename).
include("mounts.jl")
# Document-scoped solver hints (esm-spec §2.2): the version gate and the §2.2.2
# tolerance resolution order. After the template files, whose raw-JSON helpers
# it shares.
include("solver.jl")
# Wire I/O
include("parse.jl")
include("serialize.jl")
# Version-marker migration (esm-libraries-spec §8.3). Needs only `EsmFile` and
# `SCHEMA_VERSION` from types.jl; placed beside the wire I/O it belongs
# with. The TS twin is pkg/earthsci-ast-ts/src/migration.ts.
include("migration.jl")
# Document load pipeline + subsystem-ref linker (RFC-3986 URL machinery,
# top-level {ref} inlining, cycle detection, index-set registry merge)
# esm-spec §8.2.1: load-time resolution of a data source's
# `source.url_template` against the referencing document's own directory.
# Ahead of resolve.jl, which calls it.
include("data_source_urls.jl")
include("resolve.jl")
# Coupling-library files + `coupling_import` role binding (esm-spec §10.9–§10.11)
include("coupling_imports.jl")
# Expression operations, rendering, and tooling
include("expression.jl")
# Structural interning (hash-consing) of the expression AST.
include("intern.jl")
include("templates/frames.jl")
include("graph.jl")
include("units.jl")
include("variable_bounds.jl")  # esm-spec §6.3.2 lb / ub: gate, validity, flatten rewrite
include("edit.jl")
include("codegen.jl")
include("canonicalize.jl")
# Markdown and Typst document source formats (CONFORMANCE §5.58); after
# canonicalize.jl, whose `canonicalize_document` the printers apply first.
include("document_format.jl")
# `show` of expressions, equations and components: their Typst math.
include("show.jl")
# Build-time kernels, MTK-export glue
include("relational.jl")
include("mtk_export.jl")
# Planar spatial-index broad phase behind the `faq` overlap join
include("broad_phase.jl")
# MTK-free runtime (tree-walk evaluator, refresh, the run Problem, cadence)
include("name_table.jl")
include("tree_walk.jl")
include("evaluate_cellwise.jl")
include("unit_conversion.jl")
include("data_refresh.jl")
include("providers.jl")
include("output_sinks.jl")
include("output_plan.jl")
include("checkpoint.jl")
# `compiler=:xla` (API_SPEC §5.8): after the tree walk, because it names the
# emitter's `DirectEmitError`, and before simulate.jl, which dispatches on it.
include("compiler_xla.jl")
include("prepared_run.jl")
include("simulate.jl")
include("observed_field.jl")
include("rhs_program.jl")
include("range/selection.jl")
include("range/intervals.jl")
include("range/need_analysis.jl")
include("range/tile.jl")
include("range/lanes.jl")
include("strip_expose.jl")
include("operator_ir.jl")
include("reference_graph.jl")
include("cadence.jl")
include("value_invention.jl")
# The automatic projection-pushdown desugar: recognises the +-aggregate over a
# sparse binned factor and generates the derived set, its producer, the member
# factor and the gated select.
include("pushdown_rewrite.jl")
# Inline-test runners (spec §6.6; called as API by downstream model repos)
include("run_tests.jl")
include("inline_tests.jl")
include("internal.jl")

export
    # The exported surface by group; API_SPEC.md §5 and §8 record the
    # cross-binding names and the decisions behind them, and api-surface.json
    # pins them.
    # Errors: the root of the hierarchy and the registry of code strings.
    EarthSciASTError, ERROR_CODES, error_code_names,
    error_code, error_message, error_path, error_file,
    deprecated_records_per_sample_sites,
    # Reference resolution (RFC §6.1). The graph queries (`dependencies`,
    # `dependents`, `detect_cycle`, `topological_order`, `edges_of_kind`) are
    # not exported: `dependencies` collides with `Pkg.dependencies`.
    ReferenceGraph, ReferenceVertex, ReferenceEdge, ReferenceResolutionError,
    build_reference_graph, resolve_references,
    # Expressions
    ASTExpr, NumExpr, IntExpr, VarExpr, OpExpr,
    # Data-loader unit conversion (esm-spec §8.5)
    UnitConversionError, parse_unit_conversion,
    apply_unit_conversion, apply_unit_conversion!,
    is_literal, literal_value,
    # Document types
    Equation, AffectEquation,
    ModelVariableType, UnknownVariable, ParameterVariable,
    ModelVariable, Model, SubsystemRef, Species, Parameter, Reaction, ReactionSystem,
    Distribution, ParameterUpdate, FunctionalUpdate, DataSourceBinding,
    PARAMETER_UPDATE_KINDS, SHAPE_REQUIRING_UPDATE_KINDS,
    # Derived classification (esm-spec §6.3.1). `unknown_names` /
    # `parameter_names` stay beside `unknowns` / `parameters` because the bare
    # names collide with ModelingToolkit's exports.
    unknowns, parameters, unknown_names, parameter_names,
    ode_states, is_ode_state, observed_unknowns, algebraic_unknowns,
    solver_unknowns,
    observed_definitions, observed_definition,
    brownian_parameters, discrete_parameters, sampled_parameters,
    constant_parameters,
    system_kind, declared_system_kind, effective_system_kind,
    has_spatial_derivative, has_time_derivative,
    assert_classification_partitions,
    # Events, data sources and coupling
    EventType, ContinuousEvent, DiscreteEvent, DiscreteEventTrigger,
    ConditionTrigger, PeriodicTrigger, PresetTimesTrigger,
    DataSource, DataSourceLocation, DataSourceTemporal, DataSourceDeterminism,
    CouplingEntry,
    CouplingOperatorCompose, CouplingCouple, CouplingVariableMap,
    CouplingOperatorApply, CouplingCallback, CouplingEvent, CouplingImport,
    expand_coupling_imports,
    # Flattening (esm-libraries-spec §4.7.5, §4.7.6)
    FlattenMetadata, FlattenedSystem, flatten, lower_reactions_to_equations,
    infer_array_shapes,
    TermOrigin, Contribution, equation_contributions,
    # Range-restricted and public right-hand sides, strip and expose (API_SPEC §5.8)
    rhs_program, select, halo, restrict, lanes, tile_layout, lane_layout,
    rhs_workspace, rhs!, lane_inputs, gather_lane_inputs!, Decomposition,
    ForcingSet, ForcingSlot, ParamSlot, StateBlock, forcing_slots, forcing_set,
    default_forcing_set, replace_forcing, forcing_epoch, parameter_vector, n_states,
    state_layout, forcing_from_sample,
    StrippedConstructs, stripped, is_stripped, compile_kernels, Kernel, KernelSet,
    KernelBlock, KernelWorkspace, kernel!, kernel_layout, kernel_workspace, z_layout,
    operator_ir, OperatorIR, RhsSelection, Whole, Tile, Lanes, KernelOutputs,
    ir_layout, emit_fragment, gather_lanes, scatter_lanes, forcing_reach, tile_classes,
    # Flatten errors, named as in the other bindings
    FlattenError, CoupleMultiplicativeNoTendencyError,
    ConflictingDerivativeError, DimensionPromotionError, UnmappedDomainError,
    UnsupportedMappingError, DomainUnitMismatchError,
    DomainExtentMismatchError, SliceOutOfDomainError, CyclicPromotionError,
    OperatorComposeNoMergeError, OperatorComposeRequireMatchError,
    OperatorComposeAmbiguousBareNameError,
    Domain, Reference, Metadata, EsmFile,
    # Load and emit. `to_json` is listed with the graph exports below.
    load_path, load_string, load_document,
    to_json_compact, write_path,
    ParseError, SchemaValidationError, SchemaError, validate_schema,
    expression_from_json, SCHEMA_VERSION, LIBRARY_VERSION,
    # Version-marker migration (esm-libraries-spec §8.3)
    migrate, can_migrate, supported_migration_targets, MigrationError,
    resolve_subsystem_refs!, SubsystemRefError,
    serialize_coupling_entry, coerce_coupling_entry,
    # Validation
    StructuralError, ValidationResult, ValidationWarning, UnitWarning, validate_structural, validate,
    validate_path, validate_text,
    validate_reaction_rate_units,
    # Expression operations. `contains` extends `Base.contains` and is not
    # re-exported.
    substitute, free_variables, simplify, UnboundVariableError,
    resolve_qualified_reference, QualifiedReferenceError, ReferenceResolution,
    validate_reference_syntax, is_valid_identifier,
    derive_odes, stoichiometric_matrix, mass_action_rate,
    # Graphs (esm-libraries-spec §4.8). `to_json` is the document serializer;
    # its `Graph` methods are a deprecated alias of `to_json_graph`, kept one
    # minor version.
    Graph, ComponentNode, CouplingEdge, VariableNode, DependencyEdge,
    component_graph, expression_graph, adjacency, predecessors, successors,
    to_dot, to_mermaid, to_json_graph,
    to_json,
    # Units
    parse_units, parse_units_reason, get_expression_dimensions, validate_equation_dimensions,
    validate_model_dimensions, validate_reaction_system_dimensions, validate_file_dimensions,
    infer_variable_units,
    expression_unit_findings, equation_unit_findings, model_unit_findings,
    UnitFinding, UNIT_DIMENSION_MISMATCH, UNIT_PARSE_ERROR,
    UNIT_FINDING_DIMENSIONLESS_LITERAL,
    # Editing. `merge` extends `Base.merge` and is not re-exported.
    EditError,
    add_variable, remove_variable, rename_variable,
    add_equation, remove_equation, substitute_in_equations,
    add_reaction, remove_reaction, add_species, remove_species,
    add_continuous_event, add_discrete_event, remove_event,
    add_coupling, remove_coupling, compose, map_variable,
    extract,
    to_julia_code,
    # Canonical form (RFC §5.4) and the Markdown and Typst source formats
    canonicalize, canonical_json, format_canonical_float, CanonicalizeError,
    canonicalize_document,
    print_markdown, print_typst, print_document, print_math,
    parse_markdown, parse_typst, parse_document, parse_math, expression_names,
    mtk2esm, mtk2esm_gaps, GapReport,
    broad_phase_candidates,
    # Evaluation
    evaluate_expr, TreeWalkError, BuildInspection, RecurrenceInfo,
    # Template expansion at a consumer's boundary (esm-spec §9.6.4): `flatten`
    # hands out reference-preserving expressions.
    expanded_model, expand_flattened_refs, expanded_file,
    param_map,
    parameter_classes, remake_parameters,
    DiscreteMaterializer,
    # Data refresh and providers (the concrete providers are in EarthSciIO)
    build_refresh_callback, RefreshBuffers, RefreshError,
    provider_refresh_times, provider_is_const, provider_sample,
    provider_supports_selection, provider_gate_spec, provider_is_gated,
    provider_extent_metaparameter,
    providers_from_document,
    # Streaming output, output plans and checkpoints
    build_output_callback, StateSnapshot, state_snapshot, AbstractSink, OutputError,
    sink_output_times, sink_open!, sink_write!, sink_flush!, sink_close!,
    sink_supports_partial, sink_observed_names,
    VarGridding, derive_output_gridding, scatter_grid!, build_zarr_sink,
    row_major_flat_indices,
    OutputMeta, derive_output_meta, DimCoord, plan_dimension_coordinates,
    group_gridding_by_grid,
    VarPlan, GridPlan, OutputPlan, derive_output_plan, output_var_dims,
    gather_flat!, any_of, slurm_walltime_predicate, spot_preemption_predicate,
    build_checkpoint_callback, zarr_restart_state,
    forcing_buffers, forcing_buffer_index, sync_forcing!,
    # The simulation problem (esm-libraries-spec §2.5). `solve`, `init`,
    # `remake` and the rest come from SciMLBase through the extension.
    esm_problem, EsmProblem, callbacks, SimulateError, seed_expression_ic!,
    final_state, observed_field,
    compiler, compiler_report, CompilerReport, CompilerRuleRecord,
    tier_histogram, COMPILER_VOCABULARY,
    # Inline tests (esm-spec §6.6)
    AssertionStatus, AssertionResult, PASS, FAIL, ERROR, SKIP,
    esm_root, esm_path,
    discover_esm_files, run_esm_tests, write_junit_xml,
    run_inline_tests, InlineTestOptions,
    evaluate_cellwise, field_reduce,
    # Load-time lowering: enums, expression templates, template imports
    lower_enums, lower_enums!, EnumLoweringError,
    lower_expression_templates, reject_expression_templates_pre_v04,
    ExpressionTemplateError,
    resolve_template_machinery, reject_template_imports_pre_v08,
    # Solver hints (esm-spec §2.2)
    Solver, reject_solver_pre_v11, resolve_tolerances, coerce_solver,
    reject_solver_external_pre_v13, solver_external_location, precision_source,
    SolverTimeSpan, reject_solver_time_span_pre_v13, resolve_time_span,
    time_origin, timestamp_to_seconds

"""
Register this module's own `Unitful.@unit` definitions with Unitful.

`units.jl` defines eleven units with `Unitful.@unit` — `mmHg`, `uatm`,
`Dobson`, `ft`, `mi`, `lb`, `hp`, `gal`, `inHg`, `short_ton`, `tonne`. Most are
units Unitful does not have at all. Two of them, `mi` and `lb`, Unitful DOES
have (as `Mile` and `Pound` in its own defaults), and they are defined here
anyway: esm-spec §4.8.1 makes this file the only statement of what a registry
symbol means, and a scale inherited from an upstream library is a scale no
cross-binding golden pins. The `@unit` names are distinct from Unitful's
(`InternationalMile`, `AvoirdupoisPound`), so nothing collides. That macro
stores each one's conversion factor in a table LOCAL to this module; Unitful's
`uconvert` reads a GLOBAL table, and `Unitful.register` is what copies one into
the other. Without this call the custom units resolve and carry the right
DIMENSION but throw `KeyError` the moment anyone converts them
(`uconvert(u"m", 1.0 * ft)`). `tests/conformance/unit_registry` pins the
scales.
"""
function __init__()
    _init_stdlib_dir!()
    return Unitful.register(EarthSciAST)
end

include("precompile_workload.jl")

end # module EarthSciAST
