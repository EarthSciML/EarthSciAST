//! # earthsci-toolkit - Rust Implementation
//!
//! This crate provides Rust types and utilities for the EarthSciML Serialization Format (ESM).
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
//! use earthsci_toolkit::{EsmFile, load, save};
//!
//! // Load an ESM file
//! let esm_data = r#"
//! {
//!   "esm": "0.1.0",
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
//! let esm_file: EsmFile = load(esm_data)?;
//!
//! // Save back to JSON
//! let json = save(&esm_file)?;
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

pub mod adapter_support;
pub mod aggregate;
pub mod cadence;
pub mod canonicalize;
pub mod coupling;
pub mod dae;
pub mod diagnostic;
pub mod display;
pub mod edit;
pub mod error;
pub mod expression;
pub mod flatten;
pub mod geometry;
pub mod graph;
pub mod join;
pub mod lower_enums;
pub mod lower_expression_templates;
pub mod migration;
pub mod parse;
pub mod provider;
pub mod reactions;
pub mod ref_loading;
pub mod reference_resolution;
pub mod registered_functions;
pub mod relational;
pub mod serialize;
pub mod structural;
pub mod substitute;
pub mod template_imports;
pub mod types;
pub mod units;
pub mod validate;

#[cfg(feature = "wasm")]
pub mod wasm;

pub mod performance;

// Non-gated: the `CompileError` type is also named by the WASM-compiled
// `aggregate` / `join` passes, so it cannot live inside the gated `simulate`.
pub mod compile_error;

// Scalar ODE simulation (gt-5ws). Compiled for wasm too: its diffsol/Faer path
// is pure Rust (spike S1). The `simulate_array` (spatial) backend it dispatches
// into stays native-only, so the wasm build runs pure-ODE / 0-D box models and
// the array/spatial dispatch branch in `simulate::simulate` is `cfg`-gated off.
pub mod simulate;

#[cfg(not(target_arch = "wasm32"))]
pub mod simulate_array;

// §6.6.5 inline PDE tests over the array simulation pathway (field
// reductions, analytic references, coordinate-expression evaluation) —
// native-only like the `simulate_array` runtime it drives.
#[cfg(not(target_arch = "wasm32"))]
pub mod pde_inline_tests;

// `polygon_area` as a sum_product FAQ over the clip ring — evaluated through the
// array simulator, so native-only like `simulate_array` (the wasm regridder keeps
// the imperative `geometry::polygon_area`).
#[cfg(not(target_arch = "wasm32"))]
pub mod area_faq;

// Build-time value-invention front-door — derived index-sets (skolem/distinct/
// rank) resolved via the relational engine, ONCE at setup (RFC §6.1 / §5.5).
pub mod value_invention;

// Re-export main types
pub use cadence::{
    Cadence, CadenceError, ClassSummary, MaterializationPoint, Partition, classify, compute_fold,
    partition_model,
};
pub use canonicalize::{CanonicalizeError, canonical_json, canonicalize, format_canonical_float};
pub use dae::{DaeError, DiscretizeOptions, apply_dae_contract, default_dae_support, discretize};
pub use display::{to_ascii, to_latex, to_unicode};
#[cfg(not(target_arch = "wasm32"))]
pub use expression::evaluate;
pub use expression::{contains, free_parameters, free_variables, simplify};
pub use flatten::{
    DimensionPromotionRecord, FlattenError, FlattenMetadata, FlattenedSystem, flatten,
    flatten_model,
};
pub use geometry::{
    GeometryError, Manifold, SLIVER_ATOL_FACTOR, area_tolerance_ok, intersect_polygon,
    polygon_area, shoelace_area, shoelace_signed_area, sliver_atol,
};
pub use graph::{
    ComponentGraph, ComponentNode, ComponentType, CouplingEdge, DependencyEdge,
    DependencyRelationship, ExpressionGraph, ExpressionGraphInput, VariableKind, VariableNode,
    component_exists, component_graph, expression_graph, get_component_type,
};
pub use parse::{LoadOptions, load, load_path, load_path_with_options, load_with_options};
pub use reactions::{
    DeriveError, derive_odes, lower_reactions_to_equations, stoichiometric_matrix,
};
pub use ref_loading::resolve_subsystem_refs;
pub use reference_resolution::{
    EdgeKind, ReferenceEdge, ReferenceError, ReferenceGraph, ReferenceVertex, VertexKind,
    build_reference_graph, resolve_references,
};
pub use registered_functions::{
    ClosedArg, ClosedFunctionError, ClosedValue, closed_function_names, evaluate_closed_function,
};
pub use relational::{
    FloatKeyError, Key, Num, Ranking, SemiringOp, canonical_index_set_json, distinct, equijoin,
    group_aggregate, rank, rank_with_base, serialize_keys, serialize_pairs, skolem, skolem_edge,
};
pub use serialize::{save, save_compact};
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
    AffectEquation, AutoRecords, ContinuousEvent, CouplingEntry, DaeInfo, DataLoader,
    DataLoaderDeterminism, DataLoaderKind, DataLoaderMetadata, DataLoaderSource,
    DataLoaderTemporal, DataLoaderVariable, DiscreteEvent, DiscreteEventTrigger, Domain, Equation,
    EsmFile, Expr, ExpressionNode, FunctionalAffect, Metadata, Model, ModelTest,
    ModelTestAssertion, ModelVariable, Operator, Reaction, ReactionSystem, RecordsPerFile, Species,
    StoichiometricEntry, TimeSpan, Tolerance, UnitConversion, VariableMapTransform, VariableType,
};
pub use validate::{
    SchemaError, StructuralError, StructuralErrorCode, ValidationResult, validate,
    validate_complete,
};
pub use value_invention::{
    BoundaryKind, ValueInventionError, ValueInventionResult, apply_value_invention,
    materialize_value_invention,
};

pub use edit::{
    EditError, add_coupling, add_equation, add_model, add_reaction, add_reaction_system,
    add_species, add_variable, remove_coupling, remove_equation, remove_model, remove_reaction,
    remove_species, remove_variable, replace_coupling, replace_equation, substitute_in_expression,
    update_model_metadata,
};
pub use error::EsmError;
pub use lower_enums::{EnumLoweringError, lower_enums};
pub use migration::{MigrationError, can_migrate, get_supported_migration_targets, migrate};

pub use compile_error::CompileError;

#[cfg(not(target_arch = "wasm32"))]
pub use pde_inline_tests::{
    PdeAssertionResult, ephemeral_injected_file, evaluate_cellwise, field_reduce, run_pde_tests,
    run_pde_tests_with_base_dir, state_cells,
};
pub use performance::{CompactExpr, PerformanceError};
#[cfg(feature = "parallel")]
pub use reactions::stoichiometric_matrix_parallel;
pub use simulate::{
    Compiled, ResolvedExpr, SimulateError, SimulateOptions, Solution, SolutionMetadata,
    SolverChoice, fold_constant_expr, interpret, simulate,
};
pub use units::{
    Dimension, Unit, UnitError, build_unit_env, check_dimensional_consistency, convert_units,
    parse_unit, validate_equation_dimensions, validate_equation_dimensions_with_coords,
};

#[cfg(feature = "parallel")]
pub use performance::ParallelEvaluator;

#[cfg(feature = "custom_alloc")]
pub use performance::ModelAllocator;

/// Package version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// ESM schema version supported by this implementation. Must track the
/// version in `esm-schema.json`'s `$id` / esm-spec.md; the
/// `schema_version_matches_bundled_schema` test enforces it, and
/// `parse::LIBRARY_VERSION` (major-compat gating) derives from it.
pub const SCHEMA_VERSION: &str = "0.8.0";

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
