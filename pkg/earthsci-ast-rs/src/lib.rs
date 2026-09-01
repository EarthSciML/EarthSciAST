//! # earthsci-ast - Rust Implementation
//!
//! This crate provides Rust types and utilities for the EarthSciML Abstract Syntax Tree Format (ESM).
//!
//! ## Features
//!
//! - **Core**: Parse, serialize, pretty-print, substitute, validate schema
//! - **Analysis**: Unit checking, equation counting, structural validation
//! - **CLI Tool**: Command-line interface for validation and conversion
//! - **WASM**: WebAssembly compilation for web use
//!
//! ## Example
//!
//! ```rust
//! use earthsci_ast::{EsmFile, load_string, to_json};
//!
//! // Load an ESM file
//! let esm_data = r#"
//! {
//!   "esm": "1.0.0",
//!   "metadata": {
//!     "name": "test_model"
//!   },
//!   "models": {
//!     "simple": {
//!       "variables": {},
//!       "equations": []
//!     }
//!   }
//! }
//! "#;
//! let esm_file: EsmFile = load_string(esm_data)?;
//!
//! // Save back to JSON
//! let json = to_json(&esm_file)?;
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

// Without the `solve` feature the crate keeps the whole build half —
// parse, validate, flatten, classify, `esm_problem` — but every item that
// only the solver reaches is compiled out. The pieces those items were the
// sole callers of are then unreachable BY CONSTRUCTION, which is the point of
// the feature, not a defect to chase per-item.
#![cfg_attr(not(feature = "solve"), allow(dead_code, unused_imports))]
// H-3 demoted ~45 modules to `pub(crate)`, so a doc link from a PUBLIC item to
// an item that is now crate-private is expected and pervasive (74 sites). The
// links are still correct — they resolve under `cargo doc
// --document-private-items` and when reading the source, which is who reads
// them now. Rewriting them all as inert code spans would delete working
// navigation to buy silence, so the lint is turned off instead.
#![allow(rustdoc::private_intra_doc_links)]

// Conformance-harness argument parsing; callable by the conformance binaries but
// hidden from the published rustdoc API surface.
#[doc(hidden)]
pub mod adapter_support;
pub(crate) mod aggregate;
/// Pure, I/O-free structural and expression analysis helpers for the `esm` CLI.
pub(crate) mod analysis;
/// Planar spatial-index broad phase (rstar R*-tree + brute-force oracle) for the
/// projection-pushdown overlap join-gate.
pub(crate) mod broad_phase;
pub(crate) mod cadence;
pub(crate) mod canonicalize;
pub(crate) mod classification;
pub(crate) mod coupling;
pub(crate) mod coupling_imports;
pub(crate) mod dae;
/// Flat→gridded simulation-output derivation (streaming-output-sinks RFC
/// §7–§9): the Rust mirror of `EarthSciAST.jl`'s `src/data_output.jl`. Pure and
/// wasm32-clean — it plans a dataset, it never writes one.
pub(crate) mod data_output;
pub(crate) mod diagnostic;
pub(crate) mod display;
pub(crate) mod edit;
pub(crate) mod error;
// The tier-2 EXTENSION SEAM (API_SPEC.md §3): the one deliberately-named place
// where a Rust-only internal is handed to a caller. Everything reachable from
// outside this crate is either a root `pub use` above/below (the stable tier,
// pinned symbol-by-symbol by api-surface.json) or a member of this module.
pub(crate) mod expression;
pub mod extension;
pub(crate) mod flatten;
pub(crate) mod geometry;
pub(crate) mod graph;
pub mod intern;
pub(crate) mod join;
pub(crate) mod json_visit;
pub(crate) mod lower_enums;
pub(crate) mod lower_expression_templates;
pub(crate) mod migration;
pub(crate) mod op_registry;
pub(crate) mod parse;
/// Text→AST parsing of the INFIX expression surface `display::to_ascii` emits
/// (the inverse of that printer). Pure and wasm32-clean.
pub(crate) mod parse_expression;
pub mod provider;
pub(crate) mod reactions;
pub(crate) mod ref_loading;
pub(crate) mod reference_resolution;
pub(crate) mod registered_functions;
pub(crate) mod relational;
pub(crate) mod serialize;
pub(crate) mod structural;
pub(crate) mod substitute;
pub(crate) mod template_imports;
#[cfg(test)]
pub(crate) mod test_support;
pub(crate) mod types;
pub(crate) mod unit_conversion;
pub(crate) mod units;
pub(crate) mod validate;

#[cfg(feature = "wasm")]
pub mod wasm;

pub mod performance;

// Non-gated: the `CompileError` type is also named by the WASM-compiled
// `aggregate` / `join` passes, so it cannot live inside the gated solver module.
pub(crate) mod compile_error;

// Scalar ODE simulation (gt-5ws). Compiled for wasm too: its diffsol/Faer path
// is pure Rust (spike S1). The `simulate_array` (spatial) backend it dispatches
// into stays native-only, so the wasm build runs pure-ODE / 0-D box models and
// the array/spatial dispatch branch in `simulate::simulate` is `cfg`-gated off.
pub(crate) mod simulate;

// Compiled for wasm too (EarthSciAST-akz): the array/PDE runtime is
// wasm-clean — planar / geometry-free PDEs run client-side; only spherical
// geometry degrades to a runtime `GeometryError` stub (native-only s2 kernel).
pub mod simulate_array;

// §6.6.5 inline PDE tests over the array simulation pathway (field
// reductions, analytic references, coordinate-expression evaluation) —
// native-only like the `simulate_array` runtime it drives.
#[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
pub(crate) mod pde_inline_tests;

// `polygon_area` as a sum_product FAQ over the clip ring — evaluated through the
// array simulator, so native-only like `simulate_array` (the wasm regridder keeps
// the imperative `geometry::polygon_area`).
#[cfg(not(target_arch = "wasm32"))]
pub(crate) mod area_faq;

// Build-time value-invention front-door — derived index-sets (skolem/distinct/
// rank) resolved via the relational engine, ONCE at setup (RFC §6.1 / §5.5).
pub(crate) mod value_invention;

// Automatic projection-pushdown desugar (the Julia/Python `desugar_pushdown`
// port): a raw-document → raw-document transform + the record-derived provider
// gate helpers the `prepare` entry point consumes. Raw-JSON side by design —
// see the module docs.
pub(crate) mod pushdown_rewrite;

// The deterministic-per-document BUILD PIPELINE — rewrite → value-invention →
// member-factor feedback → gated fetch → observed-graph evaluation, all
// engine-side. It used to be the public `prepare`/`Prepared` entry point;
// `esm-libraries-spec.md` §2.5.1 folds it into EsmProblem construction, so what is
// public here is the provider contract and the build-observability seam.
// Native-only (drives `simulate_array`).
#[cfg(not(target_arch = "wasm32"))]
pub(crate) mod prepare;

// The EsmProblem / `solve` surface (`esm-libraries-spec.md` §2.5): one noun and
// one verb. Construction does NOT require the solver — only `solve` / `init` /
// `solve_to_completion` do, and those are behind the `solve` feature.
pub(crate) mod problem;

// OPT-IN EarthSciIO bridge: a `CadenceProvider` backed by a real EarthSciIO
// `Provider`. Behind the `esio` feature so the default build does not link
// EarthSciIO — the two rigs stay decoupled, exactly as on the Python side
// (`earthsci_ast.data_sources.esio_provider`), and a caller opts in.
#[cfg(feature = "esio")]
pub mod esio_provider;

// Re-export main types
pub use cadence::{
    Cadence, CadenceError, ClassSummary, MaterializationPoint, Partition, classify, compute_fold,
    partition_model,
};
pub use canonicalize::{CanonicalizeError, canonical_json, canonicalize, format_canonical_float};
// The esm-spec §6.3.1 classification API. esm 1.0.0 declares two variable
// types and DERIVES the rest, so these are the only sanctioned way to ask
// which unknowns are ODE states, which are observed, and which parameters are
// Brownian / discrete / sampled / constant.
pub use classification::{
    Classification, LhsForm, SystemKind, algebraic_unknowns, brownian_parameters,
    constant_parameters, discrete_parameters, is_ode_state, observed_definition_json,
    observed_definitions, observed_unknowns, ode_states, sampled_parameters, system_kind,
};
pub use coupling_imports::{
    CouplingImportOptions, expand_coupling_imports, has_coupling_import, is_coupling_library_doc,
};
pub use dae::{DaeError, DiscretizeOptions, apply_dae_contract, default_dae_support, discretize};
pub use data_output::{
    CoordPlan, GridPlan, OutputError, OutputMeta, OutputPlan, VarGridding, VarPlan,
    derive_output_gridding, derive_output_meta, derive_output_plan, group_gridding_by_grid,
    parse_cell_key, plan_dimension_coordinates,
};
pub use display::{to_ascii, to_latex, to_unicode};
#[cfg(not(target_arch = "wasm32"))]
pub use expression::evaluate;
pub use expression::{contains, free_parameters, free_variables, simplify};
pub use flatten::{
    DimensionPromotionRecord, FlattenError, FlattenMetadata, FlattenedSystem, LoaderField, flatten,
    flatten_model, flatten_with_options,
};
pub use geometry::{
    GeometryError, Manifold, SLIVER_ATOL_FACTOR, area_tolerance_ok, intersect_polygon,
    polygon_area, shoelace_area, shoelace_signed_area, sliver_atol,
};
pub use graph::{
    ComponentGraph, ComponentMetadata, ComponentNode, ComponentType, CouplingEdge, DependencyEdge,
    DependencyRelationship, ExpressionGraph, ExpressionGraphInput, ExpressionGraphOptions, Graph,
    VariableKind, VariableNode, component_exists, component_graph, expression_graph,
    expression_graph_with_options, get_component_type, to_dot, to_json_graph, to_mermaid,
};
pub use parse::{
    LoadOptions, load_document, load_document_with_options, load_path, load_path_with_options,
    load_string, load_string_with_options,
};
pub use parse_expression::{ExpressionParseError, parse_equation, parse_expression};
pub use reactions::{
    DeriveError, derive_odes, lower_reactions_to_equations, stoichiometric_matrix,
};
pub use ref_loading::{
    resolve_subsystem_refs, resolve_subsystem_refs_raw, resolve_subsystem_refs_with_metaparameters,
};
pub use reference_resolution::{
    EdgeKind, ReferenceEdge, ReferenceGraph, ReferenceResolutionError, ReferenceVertex, VertexKind,
    build_reference_graph, resolve_references,
};
// Deprecated alias of `build_reference_graph`, kept for one minor per
// API_SPEC.md §10 (§8 item 17 folded the registry into a trailing argument).
#[allow(deprecated)]
pub use reference_resolution::build_reference_graph_with_index_sets;
// Deprecated alias of `ReferenceResolutionError`, kept for one minor per
// API_SPEC.md §10 (§8 item 10 renamed it). Re-exported behind
// `allow(deprecated)` so the re-export itself does not warn.
#[allow(deprecated)]
pub use reference_resolution::ReferenceError;
pub use registered_functions::{
    ClosedArg, ClosedFunctionError, ClosedValue, closed_function_names, evaluate_closed_function,
};
pub use relational::{
    FloatKeyError, Key, Num, Ranking, SemiringOp, canonical_index_set_json, distinct,
    group_aggregate, rank, rank_with_base, serialize_keys, serialize_pairs, skolem, skolem_edge,
};
pub use serialize::{to_json, to_json_compact, write_path};
pub use substitute::{
    ScopedContext, substitute, substitute_in_model, substitute_in_model_with_context,
    substitute_in_reaction_system, substitute_in_reaction_system_with_context,
    substitute_with_context,
};
pub use template_imports::{
    apply_scope_injections, is_template_library_doc, reject_template_imports_pre_v08,
    resolve_template_machinery,
};
pub use types::{
    AffectEquation, AutoRecords, ContinuousEvent, Coordinate, CouplingEntry, CouplingRole,
    CovarianceMatrix, DaeInfo, DataSource, DataSourceBinding, DataSourceDeterminism,
    DataSourceKind, DataSourceLocation, DataSourceMetadata, DataSourceTemporal, DiscreteEvent,
    DiscreteEventTrigger, DiscretizedFrom, Distribution, DistributionParam, Domain, Equation,
    EsmFile, Expr, ExpressionNode, FunctionalUpdate, Metadata, Model, ModelTest,
    ModelTestAssertion, ModelVariable, Operator, ParameterUpdate, ParameterUpdateSpec, Reaction,
    ReactionSystem, RecordsPerFile, RegionBound, Species, StoichiometricEntry, TimeSpan, Tolerance,
    UnitConversion, UpdateValue, VariableMapTransform, VariableType,
};
pub use validate::{
    SchemaError, StructuralError, StructuralErrorCode, UnitWarning, ValidationResult, validate,
    validate_text,
};
// Deprecated alias of `validate_text`, kept for one minor per API_SPEC.md §10
// (§8 item 13 named the text convenience `validate_text`).
#[allow(deprecated)]
pub use validate::validate_complete;
pub use value_invention::{
    BoundaryKind, ValueInventionError, ValueInventionResult, apply_value_invention,
    materialize_value_invention,
};

pub use pushdown_rewrite::{
    GateAxis, ProviderGate, PushdownRewriteError, desugar_pushdown, pushdown_coupling_pairs,
    pushdown_provider_gates, pushdown_record,
};
// `Flow` is deliberately absent: the build pipeline re-exports the SAME `Flow`
// the solver uses, and the crate root already carries it from `simulate`.
// `prepare` / `Prepared` / `PrepareOptions` are GONE (esm-libraries-spec §2.5.1
// — replaced by `esm_problem` / `EsmProblem` / `ProblemOptions`); what remains is
// the build-time provider contract and the build-observability seam.
#[cfg(not(target_arch = "wasm32"))]
pub use prepare::{
    AxisSel, PrepareError, PreparePhase, PrepareProgress, PrepareProgressFn, PrepareProvider,
};

pub use edit::{
    EditError, add_coupling, add_equation, add_model, add_reaction, add_reaction_system,
    add_species, add_variable, remove_coupling, remove_equation, remove_model, remove_reaction,
    remove_species, remove_variable, replace_coupling, replace_equation, update_model_metadata,
};
pub use error::EsmError;
// The central diagnostic-code registry (phase-6 H-2). `diagnostic::codes` is
// the per-code constant form that raise sites reference; `ERROR_CODES` is its
// enumerable `(name, value)` table, the Rust twin of Julia's `ERROR_CODES`
// NamedTuple, TypeScript's `ERROR_CODES` object and Go's `codes.go`.
pub use diagnostic::{ERROR_CODES, error_code_names};
pub use lower_enums::{EnumLoweringError, lower_enums, lower_enums_mut, lower_enums_raw};
pub use migration::{MigrationError, can_migrate, migrate, supported_migration_targets};
// Deprecated alias of `supported_migration_targets`, kept for one minor per
// API_SPEC.md §10 (phase-6 G-2 dropped the `get_` prefix).
#[allow(deprecated)]
pub use migration::get_supported_migration_targets;

pub use compile_error::CompileError;

#[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
pub use pde_inline_tests::{
    BuildProviderFactory, PdeAssertionResult, ephemeral_injected_file, evaluate_cellwise,
    field_reduce, run_pde_tests, run_pde_tests_with_base_dir, run_pde_tests_with_providers,
    state_cells,
};
pub use performance::{CompactExpr, PerformanceError};
#[cfg(feature = "parallel")]
pub use reactions::stoichiometric_matrix_parallel;
pub use simulate::{
    Alg, Compiled, DEFAULT_ABSTOL, DEFAULT_RELTOL, Flow, Progress, ProgressFn, ResolvedExpr,
    ReturnCode, SimulateError, Solution, SolutionMetadata, SolveOptions, compile_array,
    fold_constant_expr, interpret,
};

// The EsmProblem / `solve` surface. `simulate` is deleted in all its forms.
pub use problem::{
    CallbackFn, CallbackSet, Compile, EnsembleProblem, EsmProblem, ProblemInput, ProblemOptions,
    Remake, callbacks, compose, esm_problem, observed_field, remake,
};
#[cfg(feature = "solve")]
pub use problem::{
    Integrator, StepStatus, init, observed_trajectories, observed_trajectory, solve,
    solve_ensemble, solve_to_completion, step,
};
pub use units::{
    Dimension, Rational, UNIT_FINDING_ANALYSIS, UNIT_FINDING_DIMENSIONAL_MISMATCH,
    UNIT_FINDING_UNPARSEABLE, Unit, UnitError, UnitFinding, UnitParseFailure, UnitSeverity,
    build_unit_env, check_dimensional_consistency, check_equation_dimensions,
    check_expression_dimensions, convert_units, parse_unit, validate_equation_dimensions,
};

#[cfg(feature = "parallel")]
pub use performance::ParallelEvaluator;

#[cfg(feature = "custom_alloc")]
pub use performance::ModelAllocator;

/// This crate's OWN version — NOT the `.esm` format version, which is
/// [`SCHEMA_VERSION`]. The two are unrelated numbers and used to share a
/// name: `VERSION` meant the package version here and the SCHEMA version in
/// TypeScript, so the same identifier read two different things depending on
/// which binding you were in. `VERSION` is gone; every binding now exposes
/// exactly `SCHEMA_VERSION` and `LIBRARY_VERSION`.
pub const LIBRARY_VERSION: &str = env!("CARGO_PKG_VERSION");
/// ESM schema version supported by this implementation. Must track the
/// version in `esm-schema.json`'s `$id` / esm-spec.md; the
/// `schema_version_matches_bundled_schema` test enforces it, and
/// `parse::library_version()` (major-compat gating) derives from it.
pub const SCHEMA_VERSION: &str = "1.0.0";

#[cfg(test)]
mod version_tests {
    /// SCHEMA_VERSION must track the version embedded in the bundled schema's
    /// `$id` (and therefore esm-spec.md).
    #[test]
    fn schema_version_matches_bundled_schema() {
        let schema: serde_json::Value =
            serde_json::from_str(include_str!("esm-schema.json")).expect("bundled schema parses");
        let id = schema["$id"].as_str().expect("schema has an $id");
        assert!(
            id.contains(&format!("/{}/", crate::SCHEMA_VERSION)),
            "SCHEMA_VERSION {} does not match schema $id {}",
            crate::SCHEMA_VERSION,
            id
        );
    }
}
