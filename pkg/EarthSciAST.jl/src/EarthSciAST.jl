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
using LinearAlgebra   # wall2 Phase D: BLAS `mul!` accelerator for linear mat-vec observeds
# The threaded RHS tier needs a thread dispatch that does NOT allocate a task
# per call (see access_kernel.jl, "Threaded cell axis"). Base
# `Threads.@threads :static` allocates ~1.6 kB per dispatch; Polyester reuses a
# persistent, spin-then-sleep pool. Polyester is a WEAK dependency: loading it
# activates `EarthSciASTPolyesterExt`, which installs the batch runner via
# `_set_batch_runner!`. Without Polyester loaded the RHS stays on the serial
# path, so the common (unthreaded) case carries no mandatory dependency.
using RuntimeGeneratedFunctions
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
# Core data model + validation
include("types.jl")
# Derived variable classification (esm-spec §6.3.1). Must follow types.jl (it
# is stated over `Model`) and precede every consumer, which is nearly all of
# them: from esm 1.0.0 there are only two declared variable types, so ODE
# state / observed / algebraic / brownian / discrete / sampled / constant are
# all questions only this module may answer.
include("classification.jl")
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
# Version-marker migration (esm-libraries-spec §8.3). Needs only `EsmFile` and
# `SCHEMA_VERSION` from types.jl; placed beside the wire I/O it belongs
# with. The TS twin is pkg/earthsci-ast-ts/src/migration.ts.
include("migration.jl")
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
# The INFIX-TEXT expression parser — the inverse of `to_ascii`, so it must
# follow display.jl (it sources operator precedence from the same registry
# lookup the printer uses).
include("parse_expression_text.jl")
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
include("unit_conversion.jl")
include("data_refresh.jl")
include("data_output.jl")
include("simulate.jl")
include("reference_graph.jl")
include("cadence.jl")
include("value_invention.jl")
# Phase 4: the automatic projection-pushdown desugar (recognises the
# +-aggregate / sparse-binned-factor pattern and generates the Phase-2b
# derived-set + producer + member_factor + gated_select constructs).
include("pushdown_rewrite.jl")
# Inline-test runners (spec §6.6; called as API by downstream model repos)
include("run_tests.jl")
include("pde_inline_tests.jl")

export
    # Root of the exception hierarchy (H-1): every exception this package
    # raises subtypes `EarthSciASTError`, so one `catch e; e isa
    # EarthSciASTError` covers the whole surface. `ERROR_CODES` is the central
    # registry of the diagnostic code STRINGS those errors carry — a
    # cross-binding contract, mirroring TypeScript's `ERROR_CODES` object and
    # Python's `ErrorCode` enum.
    EarthSciASTError, ERROR_CODES, error_code_names,
    # Reference resolution — semiring-FAQ node addressing (RFC §6.1).
    # The graph-query methods (dependencies/dependents/detect_cycle/
    # topological_order/edges_of_kind) are intentionally NOT exported: they are
    # generic names (e.g. `dependencies` collides with `Pkg.dependencies`) and
    # are reached as `EarthSciAST.dependencies(graph, key)`.
    ReferenceGraph, ReferenceVertex, ReferenceEdge, ReferenceResolutionError,
    build_reference_graph, resolve_references,
    # Expression types
    ASTExpr, NumExpr, IntExpr, VarExpr, OpExpr,
    # Data-loader unit conversion (esm-spec §8.5)
    UnitConversionError, parse_unit_conversion,
    apply_unit_conversion, apply_unit_conversion!,
    # Literal predicates (RFC §5.4.1 int/float distinction)
    is_literal, literal_value,
    # Equation types
    Equation, AffectEquation,
    # Model component types
    ModelVariableType, UnknownVariable, ParameterVariable,
    ModelVariable, Model, SubsystemRef, Species, Parameter, Reaction, ReactionSystem,
    # Parameter value model (esm-spec §5.4, §5.5, §6.3)
    Distribution, ParameterUpdate, FunctionalUpdate, DataSourceBinding,
    PARAMETER_UPDATE_KINDS, SHAPE_REQUIRING_UPDATE_KINDS,
    # Derived classification (esm-spec §6.3.1) — the ONLY sanctioned way to ask
    # which unknowns are ODE states / observed / algebraic and which parameters
    # are Brownian / discrete / sampled / constant.
    unknown_names, parameter_names,
    ode_states, is_ode_state, observed_unknowns, algebraic_unknowns,
    solver_unknowns,
    observed_definitions, observed_definition,
    brownian_parameters, discrete_parameters, sampled_parameters,
    constant_parameters,
    system_kind, declared_system_kind_mismatch,
    has_spatial_derivative, has_time_derivative,
    assert_classification_partitions,
    # Event types
    EventType, ContinuousEvent, DiscreteEvent, DiscreteEventTrigger,
    ConditionTrigger, PeriodicTrigger, PresetTimesTrigger,
    # Data-source registry types (esm-spec §8)
    DataSource, DataSourceLocation, DataSourceTemporal, DataSourceDeterminism,
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
    # JSON functionality. `load` took a `String` that meant a FILE PATH here
    # and in Go but JSON TEXT in TypeScript and Rust — one name, one argument
    # type, opposite meanings — and `save` WROTE here while returning the
    # payload and touching nothing in TypeScript and Rust. Both are split into
    # entry points that say which they are; no function both writes and returns
    # the payload. `to_json` is listed with the graph exports below, which it
    # shares by dispatch. `SCHEMA_VERSION` is the old `ESM_FORMAT_VERSION`
    # under the name the other four bindings already used; `LIBRARY_VERSION` is
    # this package's own version, which Julia did not expose at all.
    load_path, load_string, load_document,
    to_json_compact, write_path,
    ParseError, SchemaValidationError, SchemaError, validate_schema,
    expression_from_json, SCHEMA_VERSION, LIBRARY_VERSION,
    # Version-marker migration (esm-libraries-spec §8.3). `migrate` is a pure
    # `esm`-field bump along the ADDITIVE line `1.0.0 … SCHEMA_VERSION`;
    # nothing crosses the 1.0.0 clean break, so every 0.x source has no
    # supported target. `supported_migration_targets` drops the `get` prefix
    # its TypeScript twin carries.
    migrate, can_migrate, supported_migration_targets, MigrationError,
    # Infix-text expression parsing (src/parse_expression_text.jl) — the
    # inverse of `to_ascii`. Distinct from `expression_from_json`, which
    # decodes the JSON wire form.
    parse_expression, parse_equation, ExpressionParseError,
    # Subsystem reference resolution
    resolve_subsystem_refs!, SubsystemRefError,
    # Coupling serialization functions
    serialize_coupling_entry, coerce_coupling_entry,
    # Structural validation
    StructuralError, ValidationResult, UnitWarning, validate_structural, validate,
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
    to_dot, to_mermaid,
    # `to_json` carries BOTH the graph method (graph.jl) and the document
    # serializer (serialize.jl); they dispatch on their argument type.
    to_json,
    # Chemical subscript rendering
    render_chemical_formula, format_node_label,
    # Unit validation
    parse_units, parse_units_reason, get_expression_dimensions, validate_equation_dimensions,
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
    # Public template-expansion seam (esm-spec §9.6.4 Option B): the typed
    # model exactly as `build_evaluator` sees it post-expansion, for
    # downstream analyzers (EarthSciASTDiff differentiates this tree). Two
    # halves of ONE seam, one per differentiable input shape:
    # `expanded_model(file, name)` for a single `Model` inside an `EsmFile`,
    # `expand_flattened_refs(flat)` for a coupled document's `FlattenedSystem`
    # — whose surviving references resolve against the flattener's MERGED
    # `template_registry` (§9.6.4 rule 7), not a per-model
    # `component_templates` entry, so `expanded_model` cannot serve there.
    # `flatten` ALWAYS hands its consumers reference-preserving expressions, so
    # any consumer without its own template handling must call this at its
    # entry ("Expand at your boundary", RFC out-of-line-expression-templates
    # §7.7) — the MTK `System`/`PDESystem` constructors and EarthSciASTDiff's
    # `sysview` both do.
    expanded_model, expand_flattened_refs,
    # Parameter-vector ABI: name → position in a `p` that is an AbstractVector
    # (the `p`-side mirror of `var_map`). See `param_map`'s docstring for why it
    # is a function of `p` and not a sixth `build_evaluator` return value.
    param_map,
    # The parameter PARTITION (differentiability plan §3 Phase 5): which
    # parameters are `:numeric` (in the runtime `p` — differentiable, and
    # overridable at solve time), which are `:structural` (read at build time,
    # so changing one is a re-`prepare`), and which never reach `p` at all
    # (`:const_folded` / `:forcing`). `remake_parameters` is the `p`-swap that
    # applies the numeric half — the SciML `remake` shape, deliberately NOT a
    # rebuild.
    parameter_classes, remake_parameters,
    DiscreteMaterializer,
    # Discrete-cadence loader refresh (ess-14f.4, JL-J1; callback ctor in the
    # DiffEqCallbacks/SciMLBase extension). The Provider protocol has concrete
    # impls in the data binding (EarthSciIO); regrid is an in-model coupling
    # expression the RHS evaluates (the obsolete RegridApplier seam was removed).
    build_refresh_callback, RefreshBuffers, RefreshError,
    provider_refresh_times, provider_is_const, provider_sample,
    provider_supports_selection, provider_gate_spec, provider_is_gated,
    provider_extent_metaparameter,
    # Document-declared provider construction (Phase 1 clean consolidation;
    # implemented by the EarthSciIO extension, stub errors without it).
    providers_from_document,
    # Streaming output sinks (streaming-output-sinks RFC §16, Wave 1; callback
    # ctor in the DiffEqCallbacks/SciMLBase extension). The OUTPUT mirror of the
    # Provider/refresh input seam: a `PresetTimeCallback` snapshots state and
    # pushes it to a Sink at each output boundary, so the trajectory streams to
    # disk instead of accumulating in RAM. Concrete sinks live in the data binding
    # (EarthSciIO) or a test mock; `state_snapshot` is the host-gather v1 seam.
    build_output_callback, StateSnapshot, state_snapshot, AbstractSink, OutputError,
    sink_output_times, sink_open!, sink_write!, sink_flush!, sink_close!,
    sink_supports_partial, sink_observed_names,
    # Flat→gridded inversion (RFC §7) + the concrete Zarr sink constructor
    # (implemented in the EarthSciIO extension, mirror of build_output_callback).
    VarGridding, derive_output_gridding, scatter_grid!, build_zarr_sink,
    row_major_flat_indices,
    # Document-derived output metadata (RFC §7–§8): real dim names + CF
    # coordinate emission (dimension coordinates from the `coordinates` registry).
    OutputMeta, derive_output_meta, DimCoord, plan_dimension_coordinates,
    group_gridding_by_grid,
    # The derived output PLAN (RFC §7–§9) — the writer-facing shape, and the
    # artifact the cross-language derivation conformance corpus compares.
    VarPlan, GridPlan, OutputPlan, derive_output_plan, output_var_dims,
    # Checkpoint / restart (RFC §10, §16.7): flat-gather (restart-read inverse of
    # scatter), predicate constructors + OR-combinator, and the predicate-driven
    # checkpoint callback (DiscreteCallback in the DiffEqCallbacks extension).
    gather_flat!, any_of, slurm_walltime_predicate, spot_preemption_predicate,
    build_checkpoint_callback, zarr_restart_state,
    # Out-of-place RHS explicit-buffers surface (perf-plan B2): the traced-
    # argument binding of the live forcing buffers, plus the refresh-side hook
    # that mirrors a host refresh into the compiled program's argument arrays.
    rhs_with_buffers, forcing_buffers, forcing_buffer_index, sync_forcing!,
    # Trace-time `(tensor, window)` read-interning counters (ess-oop-intern):
    # the engagement witness for the out-of-place emitter's traced read memo.
    oop_intern_stats, oop_intern_stats_reset!,
    # One-call run entry (load → discretize → build_evaluator → seed → refresh →
    # solve); the solve lives in the SciMLBase extension (JL-J3, Phase 5).
    # `prepare` runs the deterministic-per-document pipeline ONCE into a cached
    # `PreparedModel`; `simulate(prep, tspan; …)` skips prep/build entirely.
    simulate, SimulationResult, SimulateError, seed_expression_ic!, final_state,
    prepare, PreparedModel, observed_field,
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

"""
Register this module's own `Unitful.@unit` definitions with Unitful.

`units.jl` defines six units Unitful does not have — `mmHg`, `uatm`, `Dobson`,
`ft`, `short_ton`, `tonne` — with `Unitful.@unit`. That macro stores each one's
conversion factor in a table LOCAL to this module; Unitful's `uconvert` reads a
GLOBAL table, and `Unitful.register` is what copies one into the other. Without
this call the custom units resolve and carry the right DIMENSION but throw
`KeyError` the moment anyone converts them — `uconvert(u"m", 1.0 * ft)` fails,
and so does the exact `DU` -> `molec/m^2` conversion units.jl's own comment
promises. That went unnoticed for as long as nothing converted a custom unit;
`tests/conformance/unit_registry`, which pins SCALES and not only dimensions, is
what converts them.
"""
function __init__()
    Unitful.register(EarthSciAST)
end

end # module EarthSciAST
