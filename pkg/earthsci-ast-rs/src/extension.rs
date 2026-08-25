//! # The tier-2 extension seam
//!
//! `API_SPEC.md` §3 splits every exported symbol into three tiers: **stable
//! API** (harmonized across bindings, breaks only at a major), **extension
//! seam** (named and documented, may differ between bindings, may break at a
//! minor), and **private** (unreachable).
//!
//! The crate root is the stable tier: every `earthsci_ast::<name>` path is a
//! `pub use` in `lib.rs` and is pinned symbol-by-symbol by `api-surface.json`.
//! This module is the tier-2 half of the same contract — the ONE place where a
//! Rust-only internal is deliberately handed to a caller. Every entry here is
//! reachable on purpose, was demanded by a real consumer, and carries **no**
//! cross-binding promise: it may be renamed or removed in a minor release.
//!
//! Everything not re-exported here or from the crate root is `pub(crate)` and
//! genuinely unreachable — the module list in `lib.rs` is no longer a de-facto
//! API.
//!
//! ## Membership rule
//!
//! An item belongs here when it is not in the root re-export list AND either:
//!
//! 1. a real consumer names it — a test, a bench, an example, or one of the
//!    `src/bin` binaries, all of which link this crate from outside; or
//! 2. it has no in-crate caller at all. A `pub fn` nobody in the crate calls
//!    existed only to be called from OUTSIDE the crate, so demoting it would
//!    not encapsulate it — it would delete it, and `rustc` would say so with a
//!    `dead_code` warning. Those are re-exported here rather than silenced
//!    with `allow(dead_code)`, which would leave them alive but unreachable.
//!
//! An item with in-crate callers and no outside consumer is neither: it is
//! private, and it stays private.
//!
//! ## What is NOT here
//!
//! Four seams keep their own top-level module path because `API_SPEC.md` §3/§7
//! already names them that way, and one more is a build-harness detail:
//!
//! - [`crate::intern`], [`crate::performance`], [`crate::simulate_array`] —
//!   named verbatim in §3 as `earthsci_ast::intern::*`, `::performance::*`,
//!   `::simulate_array::*`.
//! - [`crate::provider`] — §7's "Runtime I/O" family: the provider/refresh
//!   protocol a host binds to, whose concrete implementations live in
//!   EarthSciIO.
//! - `crate::esio_provider` (feature `esio`) and `crate::wasm`
//!   (feature `wasm`) — opt-in bridges whose whole purpose is to be called
//!   from outside; the wasm one is a `wasm_bindgen` ABI and cannot be
//!   `pub(crate)` at all.
//! - `crate::adapter_support` — `#[doc(hidden)]` argument parsing for the
//!   conformance-adapter *binaries*, which are separate crate targets and so
//!   cannot see `pub(crate)`.
//!
//! ## Naming
//!
//! Submodules mirror the private module a symbol comes from, so provenance
//! survives the demotion and generic names (`expand`, `gather`) do not
//! collide.

/// Aggregate (`sum_product` / semiring FAQ) range resolution.
pub mod aggregate {
    pub use crate::aggregate::{
        ReduceKind, Semiring, resolve_aggregate_ranges, resolve_expr_ranges_with_extents,
    };
}

/// `polygon_area` expressed as a `sum_product` FAQ over the clip ring,
/// evaluated through the array simulator. Native-only, like the runtime it
/// drives; the wasm regridder keeps the imperative `polygon_area`.
#[cfg(not(target_arch = "wasm32"))]
pub mod area_faq {
    pub use crate::area_faq::polygon_area_faq;
}

/// Pure, I/O-free structural and expression analysis helpers. Written for the
/// `esm` CLI's `analyze` subcommand, which is a separate crate target.
pub mod analysis {
    pub use crate::analysis::{
        collect_unit_types, collect_variables, contains_common_subexpressions,
        contains_expensive_operations, contains_redundant_operations, count_expression_nodes,
        count_numerical_values, count_operations, expression_depth, expressions_numerically_equal,
        find_longest_dependency_chain, find_strongly_connected_components,
    };
}

/// Planar spatial-index broad phase behind the overlap join-gate, plus the
/// brute-force oracle and the visit counter the scaling tests assert on.
pub mod broad_phase {
    pub use crate::broad_phase::{
        OverlapIndex, broad_phase_candidates, broad_phase_candidates_bruteforce, envelope_vectors,
        overlap_enum_visits, reset_overlap_enum_visits,
    };
}

/// Refresh-cadence partitioning internals, including the five predicates the
/// cross-language cadence corpus is written against.
pub mod cadence {
    pub use crate::cadence::{
        assert_no_continuous_relational, check_expect_cadence, has_continuous,
        materialization_frontier, model_with_loaders, tally_classes,
    };
}

/// Classification queries with no cross-binding counterpart. The esm-spec
/// section 6.3.1 family itself is the stable tier, at the crate root.
pub mod classification {
    pub use crate::classification::inlined_unknowns;
}

/// Simulation-output derivation internals.
pub mod data_output {
    pub use crate::data_output::{DTYPE_FLOAT64, gather, scatter};
}

/// The structured diagnostic carrier every raise site funnels through.
pub mod diagnostic {
    pub use crate::diagnostic::DiagnosticError;
}

/// Document-editing operations with no root re-export. The four event
/// operations are `stable` in the four OTHER bindings (`api-surface.json`);
/// Rust implements them but has never named them at the crate root, so they
/// live here rather than silently becoming dead code. Promoting them to the
/// stable tier is a manifest change, not an encapsulation one — see the H-3
/// report.
pub mod edit {
    pub use crate::edit::{
        EditResult, add_continuous_event, add_discrete_event, remove_continuous_event,
        remove_discrete_event,
    };
}

/// Flatten-pass internals.
pub mod flatten {
    pub use crate::flatten::reject_unlowered_operators;
}

/// Geometry kernels with no cross-binding counterpart.
pub mod geometry {
    pub use crate::geometry::{DEFAULT_LAT_ATOL, densify_parallel_edges, spherical_area};
}

/// The load-time `expression_templates` rewrite (esm-spec §9.6). Raw-JSON by
/// design — see item 14 of `API_SPEC.md` §8.
pub mod lower_expression_templates {
    pub use crate::lower_expression_templates::{
        ExpressionTemplateError, MAX_TEMPLATE_EXPANSION_DEPTH, emit_document, emit_esm_string,
        expand, flatten_template_registries, lower_expression_templates,
    };
}

/// Scalar-simulation internals. The `EsmProblem` / `solve` surface itself is
/// the stable tier, at the crate root.
pub mod simulate {
    pub use crate::simulate::algebraic_state_names;
}

/// Event-level substitution. The model-level entry points are the stable tier
/// (`substitute`, `substitute_in_model`, ...); these reach one event, trigger
/// or affect at a time and are Rust-only.
pub mod substitute {
    pub use crate::substitute::{
        substitute_in_affect_equation, substitute_in_affect_equation_with_context,
        substitute_in_continuous_event, substitute_in_continuous_event_with_context,
        substitute_in_discrete_event, substitute_in_discrete_event_trigger,
        substitute_in_discrete_event_trigger_with_context,
        substitute_in_discrete_event_with_context,
    };
}

/// A data loader's declared `unit_conversion` (esm-spec section 8.5). `stable`
/// in Julia and Python; in Rust its only in-crate caller is the feature-gated
/// `esio_provider`, so without this re-export the whole module is dead on a
/// default build.
pub mod unit_conversion {
    pub use crate::unit_conversion::{
        UnitConversionError, apply_unit_conversion, parse_unit_conversion,
    };
}

/// Projection-pushdown desugar internals.
pub mod pushdown_rewrite {
    pub use crate::pushdown_rewrite::pushdown_diagnostics;
}

/// Build-time value invention (derived index sets). The `apply_*` /
/// `materialize_*` entry points are the stable tier, at the crate root; this
/// predicate has no native caller left and none at all on wasm32.
pub mod value_invention {
    pub use crate::value_invention::is_value_invention_assignment;
}

/// Document types that are part of the serialized schema but are not in the
/// stable root re-export list — reachable so a caller can name them in a
/// signature, not promised across bindings.
pub mod types {
    pub use crate::types::{AssertionReference, IndexSet, Parameter, RangeSpec};
}
