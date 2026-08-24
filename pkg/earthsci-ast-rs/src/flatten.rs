//! Coupled system flattening per spec §4.7.5 + §4.7.6 (Rust Core tier).
//!
//! This module implements [`flatten`] — the canonical pipeline that turns an
//! [`EsmFile`] with multiple coupled components into a single [`FlattenedSystem`]
//! with dot-namespaced variables and real [`Expr`]-tree equations.
//!
//! The Rust implementation targets the **Core tier** only. It does NOT inspect
//! `dimension_mapping` declarations at all: there is no `slice` / `project` /
//! `regrid` handling, and no dimension-promotion graph is built. The removed
//! Interface construct (v0.8.0) means dimension-mapping validation via an
//! Interface does not exist, so [`FlattenError::UnsupportedMapping`],
//! [`FlattenError::UnmappedDomain`], [`FlattenError::DomainExtentMismatch`], and
//! [`DimensionPromotionRecord`] stay reserved for cross-language parity —
//! defined so a sibling binding (or a future Rust tier) can raise / populate
//! them under the same names, but never currently constructed by this crate.
//! Two of the former "reserved" variants ARE now raised for cross-binding
//! parity, independent of the removed Interface machinery:
//! [`FlattenError::DomainUnitMismatch`] is the `variable_map` `identity`-transform
//! unit check (mirrors Julia's `_check_variable_map_units`), and
//! [`FlattenError::DimensionPromotion`] is raised by the pointwise spatial lift
//! (esm-spec §10.5) when the grid loop variables cannot be determined (mirrors
//! Julia / Python `DimensionPromotionError`).
//! **Flattening does not refuse a PDE.** An undiscretized spatial operator (the
//! sugar ops `grad` / `div` / `laplacian` / `curl` / `∇`, or a spatial `D` with
//! `wrt != "t"`) flattens like any other, and the spatial axes it names are
//! recorded in [`FlattenedSystem::independent_variables`] by §4.7.6's
//! independent-variable derivation — which is precisely what decides whether a
//! downstream constructor builds an `ODESystem` or a `PDESystem`, and what makes
//! esm-spec §6.3.1's `"pde"` `system_kind` reachable. This module used to raise
//! [`FlattenError::UnloweredOperator`] here instead; that was this binding's own
//! stricter behaviour, not the format's, and it put Rust alone against Python,
//! Go, TypeScript and §4.7.6 itself.
//!
//! The `unlowered_operator` gate (esm-spec §4.2 / §9.6.8) still applies where
//! discretization is genuinely required: such an operator must be lowered to an
//! `arrayop` stencil by a `match` rewrite rule (an `expression_templates`
//! discretization applied during the load-time rewrite fixpoint) before it can
//! be EVALUATED, and the scalar and array simulators reject a survivor at
//! compile time with [`crate::compile_error::CompileError::UnloweredOperatorError`].
//! Once discretized, the spatial axis folds into the array index (so §4.7.6
//! derives `["t"]` again) and the system simulates natively through the array-op
//! backend — Rust runs discretized PDEs alongside Julia and Python
//! (CONFORMANCE_SPEC §5.9). A consumer that needs a discretized system up front
//! can demand one with [`reject_unlowered_operators`].

use crate::types::{
    ContinuousEvent, CouplingEntry, DiscreteEvent, Domain, Equation, EsmFile, Expr, ExpressionNode,
    IndexSet, JoinClause, Model, ModelVariable, OverlapClause, RangeSpec, ReactionSystem,
    VariableMapTransform, VariableType,
};
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use thiserror::Error;

// ============================================================================
// Error taxonomy — spec §4.7.6 conflict-detection errors
// ============================================================================

/// Errors raised by [`flatten`] and [`flatten_model`] during spec-compliant
/// coupled-system flattening.
///
/// Variant names are deliberately cross-language-compatible so Julia, Python,
/// and Rust agents can report the same failure using the same error name.
#[derive(Error, Debug)]
pub enum FlattenError {
    /// A species participates in a reaction AND has an explicit `D(X, t)`
    /// equation — the two derivative sources would need to be merged by an
    /// explicit `operator_compose`, and no such rule was supplied.
    #[error(
        "Conflicting derivative for species {species:?}: explicit D(X, t) equation and reaction participation both present without an operator_compose rule to merge them"
    )]
    ConflictingDerivative { species: Vec<String> },

    /// Dimension promotion failed.
    ///
    /// Raised by the pointwise spatial lift (esm-spec §10.5) when a lifted
    /// species' operator `makearray` carries no full-rank interior-stencil
    /// `index(...)` gather, so the grid loop variables cannot be determined and
    /// the merged reaction/operator ODE cannot be array-ified onto the operator
    /// grid. Mirrors the Julia / Python `DimensionPromotionError` raised for the
    /// same case (pointwise_lift.jl / shape_promotion.jl, flatten.py). The
    /// removed Interface / `dimension_mapping` promotion graph (v0.8.0) never
    /// raised it; this crate still builds no such graph.
    #[error("Dimension promotion failed: {message}")]
    DimensionPromotion { message: String },

    /// Two systems of differing dimensionality were coupled without an
    /// `Interface` naming their dimension mapping.
    ///
    /// **Reserved / parity-only — never currently raised.** This crate does not
    /// compare system dimensionality or resolve Interfaces, so it never
    /// constructs this variant; defined for cross-language parity.
    #[error(
        "Unmapped domain: systems {systems:?} have different dimensionality but no Interface defines their dimension mapping; candidate target domains: {candidate_targets:?}"
    )]
    UnmappedDomain {
        systems: Vec<String>,
        candidate_targets: Vec<String>,
    },

    /// The channel for a `dimension_mapping` type unsupported at the current
    /// (Rust Core) tier — e.g. `"slice"`, `"project"`, `"regrid"`.
    ///
    /// **Reserved / parity-only — never currently raised.** This crate never
    /// inspects `dimension_mapping` declarations, so it does not construct this
    /// variant; it exists so a sibling binding (or a future Rust tier) reports
    /// the same failure under the same name. An unlowered spatial operator is
    /// not rejected by [`flatten`] at all — §4.7.6 records the axis it names in
    /// [`FlattenedSystem::independent_variables`] instead.
    #[error(
        "Unsupported mapping type '{mapping_type}' at Rust Core tier (supported: broadcast, identity). Reason: {reason}"
    )]
    UnsupportedMapping {
        mapping_type: String,
        reason: String,
    },

    /// A rewrite-target operator (a spatial / right-hand-side `D`, or the
    /// optional sugar ops `grad` / `div` / `laplacian` / `curl` / `∇`) survived
    /// into a position that REQUIRES it to have been lowered to a stencil by a
    /// `match` rewrite rule (esm-spec §4.2 / §9.6.8).
    ///
    /// [`flatten`] does not raise this: a PDE is a legitimate flattened system
    /// (§4.7.6 records its spatial axes in
    /// [`FlattenedSystem::independent_variables`]). It is raised by
    /// [`reject_unlowered_operators`], the explicit check a consumer that needs
    /// a DISCRETIZED system runs; the scalar / array simulators enforce the same
    /// rule at compile time and surface the same uniform `unlowered_operator`
    /// code via [`crate::compile_error::CompileError::UnloweredOperatorError`].
    #[error(
        "unlowered_operator: rewrite-target operator '{op}' reached compilation without being \
         lowered to a stencil by a rewrite rule (esm-spec §4.2 / §9.6.8). Discretization rules \
         live in EarthSciDiscretizations, not this format."
    )]
    UnloweredOperator { op: String },

    /// A `variable_map` `identity` transform bridges two variables that carry
    /// declared, non-empty, and DIFFERING unit strings (esm-spec §10.4).
    ///
    /// Raised by the identity-transform unit check (mirrors Julia's
    /// `_check_variable_map_units`, coupling_apply.jl): an `identity` map asserts
    /// the `from` and `to` variables are the same quantity, so incompatible
    /// declared units are a modeling error. `param_to_var` / `conversion_factor`
    /// / expression transforms are exempt, and a missing or empty unit on either
    /// side is the valid (unchecked) case. `variable` names the entry's `from`.
    #[error(
        "Domain unit mismatch on variable '{variable}': source units '{source_units}' vs target units '{target_units}'"
    )]
    DomainUnitMismatch {
        variable: String,
        source_units: String,
        target_units: String,
    },

    /// Coordinate extent mismatch on a shared independent variable under the
    /// `identity` mapping.
    ///
    /// **Reserved / parity-only — never currently raised.** This crate performs
    /// no coordinate-extent checking; defined for cross-language parity.
    #[error("Domain extent mismatch on independent variable '{variable}' under identity mapping")]
    DomainExtentMismatch { variable: String },

    /// A slice coordinate lies outside the source domain.
    ///
    /// Defined for cross-language parity; only raised if `slice` is ever
    /// implemented in a future Rust tier upgrade.
    #[error(
        "Slice out of domain: slice coordinate '{coordinate}' = {value} lies outside the source domain extent"
    )]
    SliceOutOfDomain { coordinate: String, value: String },

    /// A cyclic promotion graph was detected (A promotes to B, B promotes
    /// back to A on a different axis).
    ///
    /// Defined for cross-language parity. Not raised by Core-tier Rust
    /// because no promotion graph is built.
    #[error("Cyclic promotion detected involving variables {variables:?}")]
    CyclicPromotion { variables: Vec<String> },

    /// A `variable_map` expression transform carries a `factor` — the
    /// expression spells its own arithmetic, so a separate scaling slot is a
    /// modeling error (esm-spec §10.4). Mirrors the Julia / Python
    /// construction-time rejection.
    #[error(
        "variable_map({from} -> {to}): an expression `transform` takes no `factor` (fold the scaling into the expression)"
    )]
    VariableMapFactorWithExpression { from: String, to: String },

    /// A `variable_map` expression transform does not reference the entry's
    /// `from` variable — the data-flow edge the entry declares (esm-spec
    /// §10.4).
    #[error(
        "variable_map({from} -> {to}): expression transform does not reference the entry's 'from' variable '{from}' (esm-spec §10.4)"
    )]
    VariableMapExpressionMissingFrom { from: String, to: String },

    /// Wrapped reaction-lowering failure.
    #[error("Reaction lowering failed: {0}")]
    Reaction(#[from] crate::reactions::DeriveError),

    /// A `coupling_import` entry failed to resolve or expand (esm-spec
    /// §10.9–§10.11). Carries the stable diagnostic `code` + message.
    #[error("{0}")]
    CouplingImport(#[from] crate::diagnostic::DiagnosticError),

    /// A `couple` connector equation carried an `lhs`/`rhs` that was absent or
    /// failed to deserialize as an [`Expr`] (esm-spec §4.7.2). Rather than
    /// silently dropping the malformed equation, flattening reports it so the
    /// coupling is not quietly degraded.
    #[error(
        "Malformed connector equation in couple({systems}): '{side}' is absent or did not deserialize as an expression"
    )]
    MalformedConnectorEquation { systems: String, side: String },

    /// A `couple` connector equation applies the `multiplicative` transform to
    /// a `to` target that has NO `D(to)` tendency in the flattened system — a
    /// parameter, an observed, an algebraic unknown, or an undefined name
    /// (esm-spec §10.3, esm-libraries-spec §4.7.2).
    ///
    /// Both sections define `multiplicative` against the target's EXISTING ODE
    /// right-hand side, so with no tendency there is nothing to multiply and
    /// the operation has no meaning. Rust used to SKIP the connector equation
    /// in that case, which is the one outcome a coupling mis-specification must
    /// not have: the document declares a coupling, the flattened system carries
    /// no trace of it, and nothing downstream can distinguish "applied" from
    /// "ignored".
    ///
    /// `additive` deliberately has no counterpart error — zero is the additive
    /// identity, so an additive term against an absent tendency simply BECOMES
    /// the tendency. There is no multiplicative identity that would do the same.
    #[error(
        "couple_multiplicative_no_tendency: couple connector 'multiplicative' transform targets \
         '{target}', which has no tendency (D({target})) to multiply (esm-spec §10.3). To scale a \
         constant parameter by a factor, use a variable_map entry with an Expression transform \
         (esm-spec §10.4) instead."
    )]
    CoupleMultiplicativeNoTendency { target: String },

    /// A model subsystem that structurally declares itself a [`DataSource`] —
    /// it carries the discriminating `kind` / `source` keys — failed to
    /// deserialize as one. Distinguished from a nested model or a
    /// `{ "ref": … }` reference, which are legitimately not loaders and are
    /// left for the array runtime (esm-spec §4.6; RFC `pure-io-data-loaders`
    /// §4.3).
    #[error(
        "Malformed data-loader subsystem '{subsystem}' in model '{system}': carries loader keys but did not deserialize as a DataSource: {reason}"
    )]
    MalformedLoaderSubsystem {
        system: String,
        subsystem: String,
        reason: String,
    },

    /// The file contains no models or reaction systems to flatten.
    #[error("No models or reaction systems to flatten")]
    Empty,
}

// ============================================================================
// Output types — spec §4.7.5 FlattenedSystem shape
// ============================================================================

/// Record of a dimension promotion applied during flattening.
///
/// **Reserved / parity-only — never currently populated.** [`flatten`] always
/// emits an empty [`FlattenMetadata::dimension_promotions_applied`]: this crate
/// inspects no `dimension_mapping` declarations and rewrites no variable onto a
/// different spatial domain. The struct is defined so the metadata shape matches
/// the sibling bindings (which may populate it) and so a future Rust tier can
/// fill it without a wire-format change.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DimensionPromotionRecord {
    pub variable: String,
    pub source_domain: String,
    pub target_domain: String,
    /// `"broadcast"` | `"identity"` (parity value set). Never recorded in
    /// practice — see the struct-level note.
    pub mapping_type: String,
}

/// Provenance metadata for a flattening pipeline run.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FlattenMetadata {
    /// Names of every component system that contributed equations.
    pub source_systems: Vec<String>,
    /// Human-readable descriptions of the coupling rules applied, in order.
    pub coupling_rules_applied: Vec<String>,
    /// Every dimension promotion applied during flattening. Always empty at the
    /// Rust Core tier — see [`DimensionPromotionRecord`] (reserved / parity-only).
    pub dimension_promotions_applied: Vec<DimensionPromotionRecord>,
    /// Whether the pipeline had to synthesize an implicit Interface because
    /// the source file didn't declare one. Always `false` at Rust Core tier.
    pub implicit_interface_inferred: bool,
}

/// Spec-compliant flattened coupled system (§4.7.5).
///
/// The shape matches the Julia [`gt-xnr`] and Python [`gt-268`] siblings:
/// real [`Expr`]-tree equations (not strings), ordered variable maps for
/// deterministic iteration, and full provenance metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlattenedSystem {
    /// Independent variables, derived per esm-libraries-spec §4.7.6
    /// "Independent-variable computation": `["t"]` for a 0-D system or a
    /// DISCRETIZED one (whose spatial axes have been folded into `arrayop`
    /// dimensions and so name no axis any more), and `["t", <spatial axes>]`
    /// for a system still carrying undiscretized spatial differentials.
    ///
    /// This is what decides whether a downstream constructor builds an
    /// `ODESystem` or a `PDESystem`, so an undiscretized spatial operator must
    /// REACH this struct rather than be rejected before it. `t` comes first;
    /// the spatial axes follow in LEXICOGRAPHIC order — the one place the
    /// document-order rule does not apply, because the axes are discovered by
    /// scanning the equations rather than declared in any order.
    pub independent_variables: Vec<String>,
    /// Dot-namespaced state variables with full metadata.
    pub state_variables: IndexMap<String, ModelVariable>,
    /// Dot-namespaced parameters. `variable_map` with `param_to_var` or
    /// `conversion_factor` transform removes entries from this map.
    pub parameters: IndexMap<String, ModelVariable>,
    /// Dot-namespaced observed variables.
    pub observed_variables: IndexMap<String, ModelVariable>,
    /// Unknowns constrained ONLY by an expression-LHS equation (`H*H*SO4 ~ Ksp`,
    /// esm-spec §6.3.1). A **SUBSET** of [`Self::state_variables`], not a
    /// sibling bucket: `state_variables` is the SOLVED-FOR VECTOR and a DAE
    /// solves for its algebraic unknowns, so removing them from that map would
    /// emit a `u` vector that silently omits them
    /// (esm-libraries-spec §4.7.5 step 4).
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub algebraic_variables: IndexMap<String, ModelVariable>,
    /// Dot-namespaced Brownian noise sources — parameters whose `update.kind`
    /// is `"wiener"`. A **SUBSET** of [`Self::parameters`]: esm-spec §6.3.1 says
    /// the four parameter sets *partition the parameters*, so a wiener entry IS
    /// a parameter and also appears here. Excluding it from `parameters` would
    /// make the parameter vector's LENGTH depend on whether the model happens
    /// to be stochastic, and leave the four sets partitioning nothing.
    /// Non-empty is exactly what §6.3.1's `system_kind` derivation tests FIRST,
    /// so carrying this map is what keeps the flattened form able to report
    /// `"sde"`.
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub brownian_parameters: IndexMap<String, ModelVariable>,
    /// Dot-namespaced DISCRETE parameters — any OTHER `update`, i.e.
    /// piecewise-constant between refreshes. Likewise a **SUBSET** of
    /// [`Self::parameters`].
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub discrete_parameters: IndexMap<String, ModelVariable>,
    /// Deferred scoped-reference / array `ic` equations (esm-spec §11.4.1),
    /// classified out of `equations` by [`flatten`]. Each entry is
    /// `(target_state, rhs)` where `target_state` names the (post-lift, grid-
    /// shaped) state variable and `rhs` is the initial-field expression — a bare
    /// reference to a provider-served loaded field (e.g. `InitialConditions.O3_init`)
    /// or a broadcast constant. The array simulator folds these into `u0` cell-by-
    /// cell at build time, reading the loaded field from the data-Provider seam
    /// (DESIGN pde_simulation_pipeline §2 R2). Empty for a system with no `ic`
    /// equations, so the ordinary ODE path is unaffected.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub field_ics: Vec<(String, Expr)>,
    /// Flattened equations in processing order. Every variable reference is
    /// dot-namespaced.
    pub equations: Vec<Equation>,
    /// Continuous events from every component, LHS rewritten to namespaced form.
    pub continuous_events: Vec<ContinuousEvent>,
    /// Discrete events from every component, LHS rewritten to namespaced form.
    pub discrete_events: Vec<DiscreteEvent>,
    /// The file's single shared domain, passed through (v0.8.0).
    pub domain: Option<Domain>,
    /// The document-scoped `index_sets` registry (esm-spec v0.8.0), passed
    /// through verbatim from the source [`EsmFile`]. Carried so a coupled
    /// (multi-model) array system reaching the array runtime via
    /// [`crate::simulate_array::ArrayCompiled::from_flattened`] can resolve
    /// `aggregate`/`arrayop` `ranges` `{ "from": <set> }`, `join.on` gates, and
    /// derived-set references against it — exactly as the single-model
    /// `from_file` path resolves them against `file.index_sets`. Empty for a
    /// file that declares no index sets, so the ordinary ODE path is unaffected.
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub index_sets: IndexMap<String, IndexSet>,
    /// The document-scoped `function_tables` registry (esm-spec §9.5), copied
    /// from the source [`EsmFile`] in document order. Carried so a surviving
    /// `table_lookup` node resolves without re-reading the source document
    /// (esm-libraries-spec §4.7.5 step 4).
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub function_tables: IndexMap<String, crate::types::FunctionTable>,
    /// The MERGED expression-template registry (esm-spec §9.6.4 rule 7, §10.7;
    /// esm-libraries-spec §4.7.5 step 4): the union of the per-component
    /// registries with each model's carried bodies component-SCOPED first,
    /// deep-equal same-name entries deduplicated at first occurrence, and a
    /// non-deep-equal same-name collision renamed to `<ComponentPath>.<name>`
    /// in every owning component with the rename propagated along the
    /// reference DAG. See [`merged_template_registry`].
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub template_registry: IndexMap<String, serde_json::Value>,
    /// The provider-served loaded fields this system consumes (esm-spec §8.5):
    /// one descriptor per PARAMETER carrying a `data`-kind `update`, in the
    /// document order of [`Self::parameters`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub loader_fields: Vec<LoaderField>,
    /// Concrete integer grid shapes assigned by the pointwise spatial lift
    /// (esm-spec §10.5) to each lifted state variable, e.g.
    /// `{"Chemistry.O3": [4, 2]}`. Empty when no lift ran.
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub lifted_shapes: IndexMap<String, Vec<i64>>,
    /// Provenance metadata.
    pub metadata: FlattenMetadata,
}

impl FlattenedSystem {
    /// The flattened system's DERIVED kind (esm-spec §6.3.1) — `"sde"` /
    /// `"pde"` / `"nonlinear"` / `"ode"`, tested in that order.
    ///
    /// Available on the flattened form precisely because
    /// [`Self::brownian_parameters`] survives flattening: the derivation's first
    /// row is "any parameter in `brownian_parameters`", so a `FlattenedSystem`
    /// that dropped the bucket could not report `"sde"` and a consumer would
    /// integrate a stochastic system as a deterministic one
    /// (esm-libraries-spec §4.7.5 step 4).
    pub fn system_kind(&self) -> crate::classification::SystemKind {
        let mut view: IndexMap<String, ModelVariable> = IndexMap::new();
        for (name, var) in &self.state_variables {
            view.insert(name.clone(), var.clone());
        }
        for (name, var) in &self.observed_variables {
            view.entry(name.clone()).or_insert_with(|| var.clone());
        }
        for (name, var) in &self.parameters {
            view.entry(name.clone()).or_insert_with(|| var.clone());
        }
        crate::classification::Classification::from_parts(&view, &self.equations).system_kind
    }
}

/// One provider-served loaded field the flattened system consumes
/// (esm-spec §8.5; esm-libraries-spec §4.7.5 step 4 `loader_fields`).
///
/// From esm 1.0.0 a data source is not a component: there is no loader
/// subsystem and no coupling edge. A model consumes a source by declaring a
/// PARAMETER whose `update` is `{kind: "data", source: <key>, from:
/// {file_variable}}` — the parameter IS the loaded field and owns the units.
/// Flatten records this descriptor per such parameter so a consumer can
/// execute the source at its cadence and bind the resulting array into the RHS
/// as a read-only input, without re-reading the source document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoaderField {
    /// The namespaced parameter symbol, e.g. `"Advection.u_wind"`.
    pub name: String,
    /// The owning component's namespace prefix, e.g. `"Advection"`.
    pub owner: String,
    /// The `data_sources` key the parameter's `update` names.
    pub source: String,
    /// The source-file variable the binding names.
    pub file_variable: String,
    /// `"const"` (the source declares no `temporal` block — read once before
    /// integration) or `"discrete"` (time-varying — refreshed at its cadence).
    /// The source-seeded cadence refinement of CONFORMANCE_SPEC §5.7.2.
    pub cadence: String,
}

// ============================================================================
// Public entry points
// ============================================================================

/// Flatten a coupled [`EsmFile`] into a single unified [`FlattenedSystem`].
///
/// Implements spec §4.7.5 + §4.7.6 at the Core tier. Pipeline:
///
/// 1. Lower every reaction system to ODE equations ([`crate::reactions::lower_reactions_to_equations`]).
/// 2. Namespace every variable, parameter, and equation by dot-notation.
/// 3. Derive [`FlattenedSystem::independent_variables`] from the flattened
///    equations (§4.7.6) — an undiscretized spatial operator names an axis
///    here, it is NOT rejected. No `dimension_mapping` inspection is performed:
///    `slice` / `project` / `regrid` are not checked at this tier.
/// 4. Apply coupling rules in order: `operator_compose`, `couple`,
///    `variable_map` (see §4.7.1–§4.7.4).
/// 5. Detect [`FlattenError::ConflictingDerivative`] — species that end up
///    with both an explicit `D(X, t)` equation and reaction-derived rate
///    without an explicit `operator_compose` to merge them.
/// 6. Collect into [`FlattenedSystem`] with metadata provenance.
///
/// # Errors
///
/// Returns [`FlattenError`] per §4.7.6.10 error taxonomy.
pub fn flatten(file: &EsmFile) -> Result<FlattenedSystem, FlattenError> {
    flatten_with_options(
        file,
        &crate::coupling_imports::CouplingImportOptions::default(),
    )
}

/// Flatten with explicit [`CouplingImportOptions`] controlling how
/// `coupling_import` `ref`s resolve (esm-spec §10.10.3). When the file carries
/// no `coupling_import` entry this is identical to [`flatten`]; otherwise the
/// import entries are expanded into concrete edges — spliced in position — as a
/// §4.7.5 sub-step *before* the coupling-rule step, and flattening proceeds over
/// the expanded coupling sequence. The `coupling_import` source entry is not
/// mutated on the caller's `file`; the expansion operates on an internal clone.
///
/// # Errors
///
/// Returns [`FlattenError::CouplingImport`] (carrying a stable §10.11
/// diagnostic code) if any `coupling_import` fails to resolve or expand;
/// otherwise the [`FlattenError`] taxonomy of [`flatten`].
pub fn flatten_with_options(
    file: &EsmFile,
    options: &crate::coupling_imports::CouplingImportOptions,
) -> Result<FlattenedSystem, FlattenError> {
    // §4.7.5 expansion sub-step: expand `coupling_import` edges before the
    // coupling-rule step. Only clone the file when an import is actually
    // present, so the common (no-import) path is untouched.
    if crate::coupling_imports::has_coupling_import(file) {
        let expanded = crate::coupling_imports::expand_coupling_imports(file, options)?;
        let mut cloned = file.clone();
        cloned.coupling = expanded;
        flatten_impl(&cloned)
    } else {
        flatten_impl(file)
    }
}

/// The core flattening algorithm, operating over an already-`coupling_import`-
/// expanded [`EsmFile`] (see [`flatten_with_options`]).
fn flatten_impl(file: &EsmFile) -> Result<FlattenedSystem, FlattenError> {
    let has_models = file.models.as_ref().is_some_and(|m| !m.is_empty());
    let has_rs = file
        .reaction_systems
        .as_ref()
        .is_some_and(|rs| !rs.is_empty());

    if !has_models && !has_rs {
        return Err(FlattenError::Empty);
    }

    // Preflight (esm-spec §10.4): a `variable_map` `identity` transform must not
    // bridge two variables carrying declared, non-empty, and differing units.
    // Mirrors Julia's `_check_variable_map_units` (coupling_apply.jl), run before
    // collection so an incoherent identity map fails fast.
    check_variable_map_units(file)?;

    // Phase 1: collect per-system lowered equations and namespaced variables.
    let (source_systems, mut per_system) = collect_component_systems(file)?;

    // NOTE: flatten does NOT reject an undiscretized spatial operator. It used
    // to, and that was this binding's own stricter behaviour rather than the
    // format's: esm-libraries-spec §4.7.6 "Independent-variable computation" is
    // a normative algorithm that DERIVES `[:t, :x, :y, …]` from exactly those
    // operators, and says the result "is what determines whether the downstream
    // constructor produces an ODESystem or a PDESystem" — which refusing makes
    // unreachable, along with §6.3.1's `"pde"` `system_kind`. Python, Go and
    // TypeScript all flatten such a document and agree on the ordered lists.
    // See `derive_independent_variables` below.
    //
    // The `unlowered_operator` gate still fires where discretization is
    // genuinely required — the scalar and array simulators reject a surviving
    // rewrite-target op at COMPILE time via
    // [`crate::compile_error::CompileError::UnloweredOperatorError`] — and a
    // consumer that needs a discretized system can demand one explicitly with
    // [`reject_unlowered_operators`].

    // Phase 3: apply coupling rules, collecting rule descriptions.
    let coupling_rules_applied = apply_coupling_entries(file, &mut per_system)?;

    // Phase 4: conflict detection after coupling.
    detect_conflicts(file, &per_system)?;

    // Phase 5: collect into the final FlattenedSystem shape.
    let mut parts = assemble_output(per_system);

    // Phase 5a: post-collection variable_map parameter removals, plus the
    // source-fed array parameters that replace them from esm 1.0.0.
    let mut loaded_producers = apply_variable_map_removals(file, &mut parts);
    loaded_producers.extend(source_fed_producers(&parts));

    // Phase 5b: pointwise spatial lift (esm-spec §10.5).
    maybe_apply_pointwise_lift(file, &mut parts, &loaded_producers)?;

    // Phase 5c: the §6.3.1 SUBSET maps, re-derived over the FINISHED system so
    // they see the equations coupling and the pointwise lift actually produced
    // rather than the ones the document declared. Each is a subset of the map
    // it classifies, in that map's document order.
    let class = flattened_classification(&parts);
    let algebraic_variables = in_document_order(
        &class.algebraic_unknowns,
        &[&parts.state_variables, &parts.observed_variables],
    );
    let brownian_parameters = in_document_order(&class.brownian_parameters, &[&parts.parameters]);
    let discrete_parameters = in_document_order(&class.discrete_parameters, &[&parts.parameters]);

    // Phase 5d: the provider-served loaded fields (esm-spec §8.5).
    let loader_fields = collect_loader_fields(file, &parts.parameters);

    // Phase 5e: the §4.7.6 independent-variable derivation, over the FINISHED
    // equation set (post-coupling, post-lift) plus the `ic` equations that were
    // classified out of it — the oracle derives before splitting `field_ics`
    // off, so scanning both keeps the two passes seeing the same expressions.
    let independent_variables = derive_independent_variables(&parts);

    let AssembledParts {
        state_variables,
        parameters,
        observed_variables,
        field_ics,
        equations,
        continuous_events,
        discrete_events,
        lifted_shapes,
    } = parts;

    Ok(FlattenedSystem {
        independent_variables,
        state_variables,
        parameters,
        observed_variables,
        algebraic_variables,
        brownian_parameters,
        discrete_parameters,
        field_ics,
        equations,
        continuous_events,
        discrete_events,
        domain: file.domain.clone(),
        index_sets: file
            .index_sets
            .as_ref()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            .unwrap_or_default(),
        function_tables: file
            .function_tables
            .as_ref()
            .map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            .unwrap_or_default(),
        template_registry: merged_template_registry(file),
        loader_fields,
        lifted_shapes,
        metadata: FlattenMetadata {
            source_systems,
            coupling_rules_applied,
            dimension_promotions_applied: Vec::new(),
            implicit_interface_inferred: false,
        },
    })
}

/// The MERGED expression-template registry of the flattened representation
/// (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4).
///
/// Union of the per-component registries [captured at load]
/// (`EsmFile::component_templates`), in this order:
///
/// 1. **Scope, THEN union.** Each MODEL block's bodies are component-scoped
///    first ([`scope_template_body`]), because the dedup below compares
///    POST-scoping bodies. Step 4 calls this an ordering requirement rather
///    than a parenthetical, and it is load-bearing: two components importing
///    one library each supply their own free `inv_dx`, so their carried entries
///    are byte-identical pre-scoping and deduplicate to a single body that is
///    correct for NEITHER. Scoping also makes them non-deep-equal, which is
///    what routes them into the collision rename and keeps an entry per owner.
///    Reaction-system blocks pass through UNSCOPED by policy, mirroring the
///    Julia reference and the Python oracle: a rate-law reference is expanded
///    eagerly at collect, so a reaction-system entry is never resolved against
///    the post-flatten scope.
/// 2. **Deep-equal dedup at first occurrence.**
/// 3. **Collision rename** to `<ComponentPath>.<name>` in EVERY owning
///    component, propagated along the reference DAG
///    ([`crate::lower_expression_templates::registry_collision_names`]) so no
///    surviving body holds a reference the merged registry cannot resolve.
///
/// `match` rules are excluded: only match-less templates are referenceable
/// (§9.6.2), so only they can be merged.
///
/// Components are walked in DOCUMENT order (models in file order, then reaction
/// systems), which is what step 4's ordering rule requires and what makes
/// "first occurrence" mean the first occurrence in the file.
///
/// Rust's typed build path expands every surviving reference at load (RFC
/// out-of-line-expression-templates §7.7), so no equation reaching here carries
/// an `apply_expression_template` node and the rename has no COMPONENT
/// reference site left to rewrite — step 4's "Applicability" paragraph says
/// exactly this. The registry is still carried, because the field is normative
/// and a consumer must be able to reconstitute the reference-preserving
/// document from the flattened form alone.
pub fn merged_template_registry(file: &EsmFile) -> IndexMap<String, serde_json::Value> {
    let Some(component_templates) = &file.component_templates else {
        return IndexMap::new();
    };

    // Document order: models as the file declares them, then reaction systems,
    // then any captured component the typed file no longer holds.
    let mut ordered: Vec<String> = Vec::new();
    if let Some(models) = &file.models {
        ordered.extend(models.keys().map(|n| format!("models.{n}")));
    }
    if let Some(rs) = &file.reaction_systems {
        ordered.extend(rs.keys().map(|n| format!("reaction_systems.{n}")));
    }
    for key in component_templates.keys() {
        if !ordered.contains(key) {
            ordered.push(key.clone());
        }
    }

    // name -> [(component_path, declaration), ...], in document order.
    let mut byname: Vec<(String, Vec<(String, serde_json::Value)>)> = Vec::new();
    for compkey in &ordered {
        let Some(block) = component_templates.get(compkey).and_then(|v| v.as_object()) else {
            continue;
        };
        let (section, cname) = compkey.split_once('.').unwrap_or(("", compkey.as_str()));
        let model = (section == "models")
            .then(|| file.models.as_ref().and_then(|m| m.get(cname)))
            .flatten();
        for (tname, decl) in block {
            if decl.get("match").is_some_and(|m| !m.is_null()) {
                continue; // match rules are not referenceable, so not merged
            }
            let scoped = match (model, decl.get("body")) {
                (Some(model), Some(body)) => {
                    let params: HashSet<String> = decl
                        .get("params")
                        .and_then(|p| p.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|v| v.as_str().map(str::to_string))
                                .collect()
                        })
                        .unwrap_or_default();
                    let mut locals: HashSet<String> = model.variables.keys().cloned().collect();
                    if let Some(subs) = &model.subsystems {
                        locals.extend(subs.keys().cloned());
                    }
                    for p in &params {
                        locals.remove(p);
                    }
                    match serde_json::from_value::<Expr>(body.clone()) {
                        Ok(parsed) => {
                            let scoped_body =
                                scope_template_body(&parsed, cname, &locals, &HashSet::new());
                            match serde_json::to_value(&scoped_body) {
                                Ok(v) => {
                                    let mut d = decl.clone();
                                    if let Some(obj) = d.as_object_mut() {
                                        obj.insert("body".to_string(), v);
                                    }
                                    d
                                }
                                // A body that will not re-serialize is carried
                                // verbatim rather than dropped: the registry is
                                // provenance, and losing an entry is worse than
                                // carrying an unscoped one.
                                Err(_) => decl.clone(),
                            }
                        }
                        Err(_) => decl.clone(),
                    }
                }
                _ => decl.clone(),
            };
            match byname.iter_mut().find(|(k, _)| k == tname) {
                Some((_, occ)) => occ.push((cname.to_string(), scoped)),
                None => byname.push((tname.clone(), vec![(cname.to_string(), scoped)])),
            }
        }
    }

    let collide = crate::lower_expression_templates::registry_collision_names(&byname);
    let mut merged: IndexMap<String, serde_json::Value> = IndexMap::new();
    let mut rename: HashMap<String, HashMap<String, String>> = HashMap::new();
    for (name, occ) in &byname {
        if collide.contains(name) {
            for (path, decl) in occ {
                let newname = format!("{path}.{name}");
                merged.insert(newname.clone(), decl.clone());
                rename
                    .entry(path.clone())
                    .or_default()
                    .insert(name.clone(), newname);
            }
        } else {
            merged.insert(name.clone(), occ[0].1.clone()); // deep-equal dedup
        }
    }
    // A renamed body's own nested references follow its OWNER's map, so a
    // per-owner wrapper reaches its owner's leaf and never the other owner's.
    for per_owner in rename.values() {
        for new in per_owner.values() {
            if let Some(decl) = merged.get_mut(new) {
                crate::lower_expression_templates::rename_apply_refs(decl, per_owner);
            }
        }
    }
    merged
}

/// Component-scope ONE carried template body: prefix exactly the references
/// that name one of the OWNING component's locals.
///
/// Unlike [`namespace_expr`] — which prefixes every bare reference except an
/// explicit leave-alone set — this is a WHITELIST, matching the Julia
/// `namespace_expr(body, cname, local_names)` and the Python oracle's
/// `_scope_template_body`: a body legitimately references its own formal
/// `params`, loop symbols, and document-scoped index sets, none of which is a
/// component local and none of which may be prefixed. The caller removes the
/// template's `params` from `locals` before calling.
fn scope_template_body(
    expr: &Expr,
    prefix: &str,
    locals: &HashSet<String>,
    bound: &HashSet<String>,
) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) => {
            if bound.contains(name) {
                return Expr::Variable(name.clone());
            }
            let head = name.split('.').next().unwrap_or(name.as_str());
            if locals.contains(head) {
                Expr::Variable(format!("{prefix}.{name}"))
            } else {
                Expr::Variable(name.clone())
            }
        }
        Expr::Operator(node) => {
            let mut child_bound = bound.clone();
            if let Some(output_idx) = &node.output_idx {
                child_bound.extend(output_idx.iter().cloned());
            }
            if let Some(ranges) = &node.ranges {
                child_bound.extend(ranges.keys().cloned());
            }
            let mut out =
                node.map_children(&mut |c| scope_template_body(c, prefix, locals, &child_bound));
            if let Some(join) = &node.join {
                let mut binders: HashSet<&str> = HashSet::new();
                if let Some(output_idx) = &node.output_idx {
                    binders.extend(output_idx.iter().map(String::as_str));
                }
                if let Some(ranges) = &node.ranges {
                    binders.extend(ranges.keys().map(String::as_str));
                }
                if let Some(ns) = namespace_join_names(join, &binders, prefix, locals) {
                    out.join = Some(ns);
                }
            }
            Expr::operator(out)
        }
    }
}

/// Phase 5e of [`flatten`]: the independent variables of the flattened system
/// (esm-libraries-spec §4.7.6 "Independent-variable computation").
///
/// The spec's three steps:
///
/// 1. **Start with `["t"]`.** Time is always an independent variable.
/// 2. **Scan every equation for spatial operators** — `grad` / `div` /
///    `laplacian` (and any other undiscretized differential), or a `D` whose
///    `wrt` is not the time variable — and add each spatial dimension they
///    reference.
/// 3. **Scan every `domains` entry for spatial axes** and add them. VACUOUS
///    since v0.8.0: `Domain.spatial` was removed, and the surviving `domain`
///    carries only `independent_variable` / `temporal` / `element_type` /
///    `array_type`. There is no spatial domain left to scan, so the operators
///    in the equations are the whole signal — esm-spec §6.3.1 makes the same
///    point about the `"pde"` `system_kind` test.
///
/// Step 2's signal is harvested STRUCTURALLY, from the axis-naming `dim` scalar
/// field (esm-spec §4.9.1) and from a spatial `wrt` — never from a hardcoded
/// op-name list, so the sugar ops carry no spatial-detection privilege over a
/// custom rewrite-target op. A DISCRETIZED system has folded its spatial axes
/// into array dimensions and carries no such node, so it yields nothing and
/// stays a pure ODE with `["t"]`.
///
/// **Ordering.** `t` first, then the spatial axes LEXICOGRAPHIC. This is the one
/// The axes follow DOCUMENT ORDER, like every other ordered field in step 4 —
/// the order the scan first encounters them, which is the order the document
/// names them (`full_coupled` → `["t", "lon", "lat", "lev"]`). This used to
/// collect into a `BTreeSet`, i.e. sorted, on the reasoning that a scanned list
/// has no document order to preserve. That was wrong: the axis order is the
/// order a downstream array layout follows, so sorting silently permutes the
/// modeller's axes.
fn derive_independent_variables(parts: &AssembledParts) -> Vec<String> {
    // First-encounter order, deduplicated. `out` doubles as the seen-set: it
    // starts with "t", which also drops a spatial `wrt` naming time.
    let mut out = vec!["t".to_string()];
    let mut scan = |e: &Expr| collect_spatial_dims(e, &mut out);
    for eq in &parts.equations {
        scan(&eq.lhs);
        scan(&eq.rhs);
    }
    for (_, rhs) in &parts.field_ics {
        scan(rhs);
    }
    // Step 3 is vacuous — see the doc comment.
    out
}

/// Collect the spatial dimension labels an UNDISCRETIZED differential names
/// anywhere in `expr`. Helper of [`derive_independent_variables`].
fn collect_spatial_dims(expr: &Expr, out: &mut Vec<String>) {
    let Expr::Operator(node) = expr else { return };
    // The axis a `grad` / `div` / `laplacian` (or any custom differential)
    // iterates over. Only an undiscretized differential carries it; no
    // evaluable-core op uses `dim`.
    if let Some(dim) = &node.dim
        && !out.iter().any(|d| d == dim)
    {
        out.push(dim.clone());
    }
    // A SPATIAL `D`: `wrt` naming an axis other than time. The structural
    // `D(u, t)` of an ODE is excluded, as is a `D` with no `wrt` (time by
    // default).
    if let Some(wrt) = &node.wrt
        && wrt != "t"
        && !out.iter().any(|d| d == wrt)
    {
        out.push(wrt.clone());
    }
    node.for_each_child(&mut |child| collect_spatial_dims(child, out));
}

/// Demand that `flat` carry NO undiscretized rewrite-target operator, reporting
/// the first offender as [`FlattenError::UnloweredOperator`] (the uniform
/// `unlowered_operator` code, esm-spec §4.2 / §9.6.8).
///
/// [`flatten`] itself does NOT run this: a PDE is a legitimate flattened system
/// whose spatial axes §4.7.6 records in
/// [`FlattenedSystem::independent_variables`], and refusing it would make
/// `PDESystem` construction and the `"pde"` `system_kind` unreachable. This is
/// for a consumer that genuinely REQUIRES a discretized system and wants to say
/// so before it starts work; the scalar and array simulators enforce the same
/// rule at compile time on their own, through
/// [`crate::compile_error::CompileError::UnloweredOperatorError`].
///
/// The tier decision is delegated wholesale to [`crate::op_registry`], so this
/// keeps no hand-maintained op-name list.
pub fn reject_unlowered_operators(flat: &FlattenedSystem) -> Result<(), FlattenError> {
    match first_unlowered_operator(flat) {
        Some(op) => Err(FlattenError::UnloweredOperator { op }),
        None => Ok(()),
    }
}

/// The name of the first undiscretized rewrite-target operator in `flat`, or
/// `None` when the system is fully discretized.
///
/// The query form of [`reject_unlowered_operators`], for a caller that already
/// has its own error type — the scalar and array simulators use it to report a
/// PDE that reached them with the uniform `unlowered_operator` code
/// ([`crate::compile_error::CompileError::UnloweredOperatorError`]) rather than
/// the vaguer "unsupported dimensionality", preserving the cross-binding
/// diagnostic esm-spec §4.2 / §9.6.8 specifies.
pub fn first_unlowered_operator(flat: &FlattenedSystem) -> Option<String> {
    for eq in &flat.equations {
        for side in [&eq.lhs, &eq.rhs] {
            if let Err(FlattenError::UnloweredOperator { op }) = reject_spatial_operators(side) {
                return Some(op);
            }
        }
    }
    None
}

/// Phase 5d of [`flatten`]: the provider-served loaded fields
/// (esm-spec §8.5; esm-libraries-spec §4.7.5 step 4 `loader_fields`).
///
/// One descriptor per flattened PARAMETER carrying a `data`-kind `update`, in
/// the document order of `parameters`. `cadence` follows the source-seeded
/// refinement of CONFORMANCE_SPEC §5.7.2: a source WITH a `temporal` block is
/// time-varying (`"discrete"`), one without it is read once (`"const"`).
fn collect_loader_fields(
    file: &EsmFile,
    parameters: &IndexMap<String, ModelVariable>,
) -> Vec<LoaderField> {
    let mut out = Vec::new();
    for (name, var) in parameters {
        let Some(spec) = &var.update else { continue };
        let rules: &[crate::types::ParameterUpdate] = match spec {
            crate::types::ParameterUpdateSpec::Single(rule) => std::slice::from_ref(rule),
            crate::types::ParameterUpdateSpec::Several(rules) => rules,
        };
        for rule in rules {
            let Some(source) = rule.data_source() else {
                continue;
            };
            let Some(binding) = rule.value().and_then(|v| v.from.as_ref()) else {
                continue;
            };
            let has_temporal = file
                .data_sources
                .as_ref()
                .and_then(|ds| ds.get(source))
                .is_some_and(|ds| ds.temporal.is_some());
            out.push(LoaderField {
                name: name.clone(),
                owner: name
                    .rsplit_once('.')
                    .map(|(owner, _)| owner.to_string())
                    .unwrap_or_default(),
                source: source.to_string(),
                file_variable: binding.file_variable.clone(),
                cadence: if has_temporal { "discrete" } else { "const" }.to_string(),
            });
            break; // one parameter is fed by one source
        }
    }
    out
}

/// Phase 1 of [`flatten`]: build one [`SystemBlock`] per component — models
/// first (spec §4.7.5 step 2), then reaction systems lowered to ODE
/// equations — each with dot-namespaced variables and equations. Component
/// names are sorted within each kind for deterministic output. Returns the
/// contributing system names (provenance) alongside the blocks.
fn collect_component_systems(
    file: &EsmFile,
) -> Result<(Vec<String>, Vec<SystemBlock>), FlattenError> {
    let mut source_systems = Vec::new();
    let mut per_system: Vec<SystemBlock> = Vec::new();

    // Models first (spec §4.7.5 step 2), in the order the DOCUMENT declares
    // them (esm-libraries-spec §4.7.5 step 4, "Ordering"). Sorting the keys —
    // what this used to do — is observable in the flattened parameter vector.
    if let Some(models) = &file.models {
        for (name, model) in models {
            let block = build_model_block(name, model)?;
            source_systems.push(name.clone());
            per_system.push(block);
        }
    }

    // Reaction systems next — lowered to ODE equations then namespaced.
    if let Some(rsystems) = &file.reaction_systems {
        for (name, rs) in rsystems {
            let block = build_reaction_block(name, rs)?;
            source_systems.push(name.clone());
            per_system.push(block);
        }
    }

    Ok((source_systems, per_system))
}

/// Phase 3 of [`flatten`]: apply the file's coupling entries in declaration
/// order (`operator_compose`, `couple`, `variable_map` — §4.7.1–§4.7.4),
/// mutating the per-system blocks. Returns the human-readable descriptions of
/// the rules applied, in order, for [`FlattenMetadata`].
fn apply_coupling_entries(
    file: &EsmFile,
    per_system: &mut Vec<SystemBlock>,
) -> Result<Vec<String>, FlattenError> {
    let mut coupling_rules_applied = Vec::new();
    let Some(entries) = &file.coupling else {
        return Ok(coupling_rules_applied);
    };

    // BY KIND, not by array position. §4.7.1 runs before §4.7.2 and §4.7.3 so
    // that placeholder expansion and the RHS merge happen before a `couple`
    // connector term or a `variable_map` substitution rewrites the dependent
    // variable names out from under them — the operator terms belong to the
    // ODE the component authored, and folding a connector term in first would
    // stack the two contributions in the wrong order (a visible divergence:
    // `advanced_coupling` declares `couple` first and `operator_compose`
    // third, and the oracle still emits the transport terms ahead of the
    // deposition sink). Within a kind, array order is preserved.
    //
    // `coupling_rules_applied` stays in DECLARATION order: it is provenance
    // for the document as authored, not a trace of the application schedule.
    let kind_rank = |entry: &CouplingEntry| match entry {
        CouplingEntry::OperatorCompose { .. } => 0,
        CouplingEntry::Couple { .. } => 1,
        _ => 2,
    };
    let mut descriptions: Vec<Option<String>> = vec![None; entries.len()];
    for rank in 0..=2 {
        for (i, entry) in entries.iter().enumerate() {
            if kind_rank(entry) != rank {
                continue;
            }
            let mut one = Vec::new();
            apply_coupling_entry(entry, per_system, &mut one)?;
            descriptions[i] = one.into_iter().next();
        }
    }
    coupling_rules_applied.extend(descriptions.into_iter().flatten());
    Ok(coupling_rules_applied)
}

/// Phase 4 of [`flatten`]: conflict detection after coupling — every pair of
/// equations with the same D(X, t) LHS across systems that were NOT jointly
/// named in an `operator_compose` entry is a
/// [`FlattenError::ConflictingDerivative`].
fn detect_conflicts(file: &EsmFile, per_system: &[SystemBlock]) -> Result<(), FlattenError> {
    let operator_compose_systems: Vec<Vec<String>> = file
        .coupling
        .as_ref()
        .map(|entries| {
            entries
                .iter()
                .filter_map(|e| match e {
                    CouplingEntry::OperatorCompose { systems, .. } => Some(systems.clone()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default();

    let mut lhs_targets: IndexMap<String, Vec<String>> = IndexMap::new();
    for block in per_system {
        for eq in &block.equations {
            if let Some(dep) = extract_ddt_dependent(&eq.lhs) {
                lhs_targets.entry(dep).or_default().push(block.name.clone());
            }
        }
    }

    let mut conflicting_species: Vec<String> = Vec::new();
    for (species, owning_systems) in &lhs_targets {
        if owning_systems.len() < 2 {
            continue;
        }
        let was_composed = operator_compose_systems
            .iter()
            .any(|compose_systems| owning_systems.iter().all(|s| compose_systems.contains(s)));
        if !was_composed {
            conflicting_species.push(species.clone());
        }
    }
    if !conflicting_species.is_empty() {
        conflicting_species.sort();
        conflicting_species.dedup();
        return Err(FlattenError::ConflictingDerivative {
            species: conflicting_species,
        });
    }
    Ok(())
}

/// The [`FlattenedSystem`]-shaped accumulation produced by phase 5
/// ([`assemble_output`]) and refined by the post-collection passes
/// ([`apply_variable_map_removals`], [`maybe_apply_pointwise_lift`]).
struct AssembledParts {
    state_variables: IndexMap<String, ModelVariable>,
    parameters: IndexMap<String, ModelVariable>,
    observed_variables: IndexMap<String, ModelVariable>,
    field_ics: Vec<(String, Expr)>,
    equations: Vec<Equation>,
    continuous_events: Vec<ContinuousEvent>,
    discrete_events: Vec<DiscreteEvent>,
    lifted_shapes: IndexMap<String, Vec<i64>>,
}

/// Phase 5 of [`flatten`]: merge the per-system blocks (in block order) into
/// the final variable maps, equation list, and event lists.
///
/// Scoped-reference / array `ic` equations (esm-spec §11.4.1) are classified
/// out of the ordinary equation list here — the downstream simulator folds
/// them into `u0` from the data-Provider seam rather than treating them as
/// state ODEs. Collected as `(target_state, rhs)`.
fn assemble_output(per_system: Vec<SystemBlock>) -> AssembledParts {
    let mut parts = AssembledParts {
        state_variables: IndexMap::new(),
        parameters: IndexMap::new(),
        observed_variables: IndexMap::new(),
        field_ics: Vec::new(),
        equations: Vec::new(),
        continuous_events: Vec::new(),
        discrete_events: Vec::new(),
        lifted_shapes: IndexMap::new(),
    };

    for block in per_system {
        for (name, var) in block.state_vars {
            parts.state_variables.insert(name, var);
        }
        for (name, var) in block.parameters {
            parts.parameters.insert(name, var);
        }
        for (name, var) in block.observed_vars {
            parts.observed_variables.insert(name, var);
        }
        for eq in block.equations {
            if let Some(target) = extract_ic_target(&eq.lhs) {
                parts.field_ics.push((target, eq.rhs));
            } else {
                parts.equations.push(eq);
            }
        }
        parts.continuous_events.extend(block.continuous_events);
        parts.discrete_events.extend(block.discrete_events);
    }
    parts
}

/// Phase 5a of [`flatten`]: apply post-collection `variable_map` parameter
/// removals. A `param_to_var` that binds a LOADED field (its producer's
/// owning system is a top-level `data_sources` entry) onto a grid-shaped
/// consumer parameter records the producer name + rank so the pointwise lift
/// indexes the loaded field per grid cell (esm-spec §11.5 "BCs from data").
/// The loaded producer is NOT added to `parameters`: it is served at runtime
/// through the data-Provider forcing seam, not as a scalar parameter (which
/// the array evaluator would otherwise resolve ahead of the forcing buffer).
/// Returns the loaded-producer name → rank map consumed by
/// [`maybe_apply_pointwise_lift`].
/// The grid-shaped fields fed from OUTSIDE the model — every discrete
/// parameter with a non-empty declared `shape`, keyed by its flattened name and
/// mapped to its rank.
///
/// This is the esm 1.0.0 successor of [`apply_variable_map_removals`]'s
/// `param_to_var` result. Before 1.0.0 a loaded field arrived as a coupling
/// edge from a loader component to a model parameter, and that EDGE is what
/// told the pointwise lift which operands were grid-shaped external fields.
/// The edge is gone: the loaded field IS a parameter carrying an `update` that
/// names its source (esm-spec §8.5). The same fact is therefore read off the
/// declaration — a discrete parameter with a shape — instead of off a coupling
/// entry, and the lift indexes it per cell exactly as before. Without this a
/// grid-shaped wind field stays a whole ARRAY inside a per-cell expression and
/// the tendency evaluates to `NaN`.
fn source_fed_producers(parts: &AssembledParts) -> HashMap<String, usize> {
    let class = flattened_classification(parts);
    parts
        .parameters
        .iter()
        .filter(|(name, _)| class.is_discrete_parameter(name))
        .filter_map(|(name, var)| {
            var.shape
                .as_ref()
                .filter(|s| !s.is_empty())
                .map(|s| (name.clone(), s.len()))
        })
        .collect()
}

/// The esm-spec §6.3.1 classification of the FLATTENED system.
///
/// Re-derived over the flattened maps and equations rather than lifted from the
/// per-component answers, because flattening moves the ground under it:
/// `operator_compose` merges two RHSs into one equation, `variable_map` deletes
/// a parameter and promotes a variable in its place, and the pointwise lift
/// rewrites a scalar state ODE into an `aggregate`. Every membership decision
/// is delegated to [`crate::classification`] — the binding's only sanctioned
/// answer to these questions — so no `update.kind == "wiener"` test is spelled
/// here. Mirrors Python's `_classification_view` / `_classify_flattened`.
fn flattened_classification(parts: &AssembledParts) -> crate::classification::Classification {
    let mut view: IndexMap<String, ModelVariable> = IndexMap::new();
    for (name, var) in &parts.state_variables {
        view.insert(name.clone(), var.clone());
    }
    for (name, var) in &parts.observed_variables {
        view.entry(name.clone()).or_insert_with(|| var.clone());
    }
    for (name, var) in &parts.parameters {
        view.entry(name.clone()).or_insert_with(|| var.clone());
    }
    crate::classification::Classification::from_parts(&view, &parts.equations)
}

/// Select `names` out of `maps`, keeping each map's DOCUMENT order.
///
/// The classification accessors return lexicographically sorted name lists — a
/// set-valued answer spelled as a list. esm-libraries-spec §4.7.5 step 4
/// requires document order of every map on the flattened system, so membership
/// comes from the accessor and POSITION comes from the already-document-ordered
/// map being filtered. Sorting here instead would be observable.
fn in_document_order(
    names: &[String],
    maps: &[&IndexMap<String, ModelVariable>],
) -> IndexMap<String, ModelVariable> {
    let wanted: HashSet<&str> = names.iter().map(String::as_str).collect();
    let mut out = IndexMap::new();
    for m in maps {
        for (name, var) in *m {
            if wanted.contains(name.as_str()) && !out.contains_key(name) {
                out.insert(name.clone(), var.clone());
            }
        }
    }
    out
}

fn apply_variable_map_removals(
    file: &EsmFile,
    parts: &mut AssembledParts,
) -> HashMap<String, usize> {
    let loader_names: HashSet<String> = file
        .data_sources
        .as_ref()
        .map(|dl| dl.keys().cloned().collect())
        .unwrap_or_default();
    let mut loaded_producers: HashMap<String, usize> = HashMap::new();
    if let Some(entries) = &file.coupling {
        for entry in entries {
            let CouplingEntry::VariableMap {
                from,
                to,
                transform,
                ..
            } = entry
            else {
                continue;
            };
            match transform {
                VariableMapTransform::Named(name)
                    if matches!(name.as_str(), "param_to_var" | "conversion_factor") =>
                {
                    let consumer_shape_rank = parts
                        .parameters
                        .get(to)
                        .and_then(|v| v.shape.as_ref())
                        .map(|s| s.len())
                        .filter(|r| *r > 0);
                    parts.parameters.shift_remove(to);
                    let from_owner = from.split('.').next().unwrap_or("");
                    if let Some(rank) = consumer_shape_rank
                        && loader_names.contains(from_owner)
                        && !parts.parameters.contains_key(from)
                    {
                        loaded_producers.insert(from.clone(), rank);
                    }
                }
                // Expression transform (esm-spec §10.4): the entry binds the
                // target to a DERIVED value. Remove the `to` parameter and
                // introduce in its place an observed variable — same name,
                // units, shape, description — whose defining expression is the
                // transform VERBATIM (its references are, by contract, already
                // fully scoped, so no namespacing is applied). References to
                // `to` in the equations are left intact: they now resolve to
                // the observed, exactly as if the author had declared it.
                VariableMapTransform::Expression(node) => {
                    let removed = parts.parameters.shift_remove(to);
                    let (units, shape, description) = removed
                        .map(|p| (p.units, p.shape, p.description))
                        .unwrap_or((None, None, None));
                    parts.observed_variables.insert(
                        to.clone(),
                        ModelVariable {
                            var_type: VariableType::Unknown,
                            units,
                            default: None,
                            default_units: None,
                            description,
                            shape,
                            location: None,
                            distribution: None,
                            update: None,
                        },
                    );
                    // The DEFINITION is an equation with a bare-variable LHS —
                    // esm 1.0.0 has no `expression` field on a variable, and it
                    // is that equation form that makes `to` an observed unknown
                    // (esm-spec §6.3.1).
                    parts.equations.push(Equation {
                        lhs: Expr::Variable(to.clone()),
                        rhs: Expr::operator(node.clone()),
                    });
                }
                VariableMapTransform::Named(_) => {}
            }
        }
    }
    loaded_producers
}

/// Phase 5b of [`flatten`]: pointwise spatial lift trigger (esm-spec §10.5).
/// `operator_compose` has merged each reaction/model state ODE with the
/// spatial operator's advection makearray; array-ify those merged equations
/// onto the operator's grid so the lifted reaction network runs pointwise.
/// No-op unless an `operator_compose` entry declares `lifting: "pointwise"`
/// and a merged equation carries an operator makearray.
fn maybe_apply_pointwise_lift(
    file: &EsmFile,
    parts: &mut AssembledParts,
    loaded_producers: &HashMap<String, usize>,
) -> Result<(), FlattenError> {
    let pointwise = file
        .coupling
        .as_ref()
        .map(|entries| {
            entries.iter().any(|e| {
                matches!(e, CouplingEntry::OperatorCompose { lifting: Some(l), .. } if l == "pointwise")
            })
        })
        .unwrap_or(false);
    if pointwise {
        apply_pointwise_lift(
            &mut parts.equations,
            &mut parts.state_variables,
            &mut parts.lifted_shapes,
            loaded_producers,
        )?;
    }
    Ok(())
}

/// Flatten a single [`Model`] as a convenience wrapper around [`flatten`].
///
/// The model is wrapped in a synthetic single-component [`EsmFile`] under the
/// name `"model"` (or its declared `name` field if present) and run through
/// the full pipeline — so the result is still dot-namespaced and has real
/// [`FlattenMetadata`]. Use this when you want the spec-compliant output for
/// a standalone component without hand-building an [`EsmFile`].
pub fn flatten_model(model: &Model) -> Result<FlattenedSystem, FlattenError> {
    use crate::types::Metadata;

    let system_name = model.name.clone().unwrap_or_else(|| "model".to_string());

    let mut models = IndexMap::new();
    models.insert(system_name, model.clone());

    let file = EsmFile {
        component_templates: None,
        coordinates: None,
        coupling_roles: None,
        // A synthesized single-system view: it declares no templates and no
        // metaparameters of its own (the source document's survive on IT).
        expression_templates: None,
        metaparameters: None,
        esm: crate::SCHEMA_VERSION.to_string(),
        metadata: Metadata {
            name: None,
            description: None,
            authors: None,
            license: None,
            created: None,
            modified: None,
            tags: None,
            references: None,
            system_class: None,
            dae_info: None,
            discretized_from: None,
        },
        index_sets: None,
        models: Some(models),
        reaction_systems: None,
        data_sources: None,
        operators: None,
        enums: None,
        coupling: None,
        domain: None,
        function_tables: None,
    };

    flatten(&file)
}

// ============================================================================
// Internal plumbing
// ============================================================================

/// Per-system intermediate representation built during phase 1. Carries the
/// namespaced variables, parameters, events, and equations for a single
/// component so that coupling can operate on structured data rather than
/// strings.
struct SystemBlock {
    name: String,
    state_vars: IndexMap<String, ModelVariable>,
    /// EVERY parameter of the component, in declaration order and of every
    /// cadence. The wiener / discrete subsets are re-derived over the FLATTENED
    /// system in [`classify_flattened`]; they are not carved out here, because
    /// esm-spec §6.3.1's four sets partition `parameters` rather than sitting
    /// beside it.
    parameters: IndexMap<String, ModelVariable>,
    observed_vars: IndexMap<String, ModelVariable>,
    equations: Vec<Equation>,
    continuous_events: Vec<ContinuousEvent>,
    discrete_events: Vec<DiscreteEvent>,
}

fn build_model_block(system_name: &str, model: &Model) -> Result<SystemBlock, FlattenError> {
    let mut state_vars = IndexMap::new();
    let mut parameters = IndexMap::new();
    let mut observed_vars = IndexMap::new();

    // The component's own declared names — the gate for namespacing the
    // plain-string references a `join` clause carries (§5.5.6).
    // Mirrors Julia `_collect_model!`'s `local_names`.
    //
    // From esm 1.0.0 a data source can no longer be mounted as a SUBSYSTEM
    // (RFC unified-variable-model D2: a source is not a component), so there
    // are no loader-subsystem keys to add here and no loader observeds to
    // synthesise. A model reads external data through a PARAMETER whose
    // `update` names the source, which lands in `parameters` below like any
    // other parameter.
    //
    // A model's SUBSYSTEM keys join the gate: a reference rooted at one of
    // them (`Photochemistry.NO2_photo` written inside the parent) is
    // subsystem-LOCAL, not an already-absolute cross-component reference, and
    // must be lifted to the lowered subsystem name `<parent>.<sub>.<var>`.
    // Mirrors the Python oracle's `sub_keys` / `locals_` in `_collect_model`.
    let sub_keys: HashSet<String> = model
        .subsystems
        .as_ref()
        .map(|subs| subs.keys().cloned().collect())
        .unwrap_or_default();
    let locals: HashSet<String> = model
        .variables
        .keys()
        .cloned()
        .chain(sub_keys.iter().cloned())
        .collect();

    // Which unknowns are ODE states and which are observed is DERIVED from
    // this model's equations (esm-spec §6.3.1), once, before namespacing.
    let class = crate::classification::Classification::of(model);

    // DOCUMENT ORDER (esm-libraries-spec §4.7.5 step 4, "Ordering"): the
    // component's variables in the order the component declares them. A
    // parameter vector is positional, so lexicographic sorting here would be
    // observable — and non-conforming.
    for (var_name, var) in &model.variables {
        let namespaced = format!("{system_name}.{var_name}");
        let mut cloned = var.clone();
        // A parameter's `update` carries Expressions (trigger, value,
        // unit conversion) over the model's own symbols, so they namespace
        // exactly as the equations do.
        cloned.for_each_expression_mut(&mut |expr| {
            *expr = namespace_expr(expr, system_name, &sub_keys, &locals);
        });
        match var.var_type {
            // An unknown lands in the bucket its EQUATIONS put it in.
            // `observed_variables` is the INLINED form specifically — the
            // strict `y ~ f(…)` a bare-variable LHS defines, which is
            // substituted into every consumer and contributes no output of its
            // own. Every OTHER unknown is SOLVED FOR and joins `state_vars`:
            // an ODE state; an algebraic unknown (not eliminable, and the
            // consumers that integrate this bucket already tolerate an unknown
            // with no derivative equation — that is what `dae.rs` handles); and
            // an ARRAYED definition (`y[i] ~ f(i)`), which is observed by
            // §6.3.1 but materializes into a buffer its consumers index rather
            // than being inlined, so the solver must allocate it.
            //
            // Gating on `is_observed` — the broader semantic set — instead left
            // an arrayed observed OUT of the solved-for vector entirely, the
            // same class of defect esm-libraries-spec 45fa534a0 corrected for
            // `algebraic_variables`.
            VariableType::Unknown => {
                if class.is_inlined(var_name) {
                    observed_vars.insert(namespaced, cloned);
                } else {
                    state_vars.insert(namespaced, cloned);
                }
            }
            // EVERY parameter lands in `parameters`, whatever its cadence.
            // esm-spec §6.3.1: `brownian_parameters` / `discrete_parameters` /
            // `sampled_parameters` / `constant_parameters` PARTITION the
            // parameters, so a wiener-updated entry is a parameter that ALSO
            // appears in the Brownian subset — see [`classify_flattened`].
            VariableType::Parameter => {
                parameters.insert(namespaced, cloned);
            }
        }
    }

    let equations: Vec<Equation> = model
        .equations
        .iter()
        .map(|eq| Equation {
            lhs: namespace_expr(&eq.lhs, system_name, &sub_keys, &locals),
            rhs: namespace_expr(&eq.rhs, system_name, &sub_keys, &locals),
        })
        .collect();

    let continuous_events = model
        .continuous_events
        .clone()
        .unwrap_or_default()
        .into_iter()
        .map(|e| namespace_continuous_event(e, system_name, &sub_keys, &locals))
        .collect();
    let discrete_events = model
        .discrete_events
        .clone()
        .unwrap_or_default()
        .into_iter()
        .map(|e| namespace_discrete_event(e, system_name, &sub_keys, &locals))
        .collect();

    let mut block = SystemBlock {
        name: system_name.to_string(),
        state_vars,
        parameters,
        observed_vars,
        equations,
        continuous_events,
        discrete_events,
    };

    // NESTED SUBSYSTEMS (esm-spec §6.2). A subsystem is an ordinary model
    // mounted under a key, lowered with the compound prefix
    // `<parent>.<key>` and FOLDED INTO the parent block — the flattened
    // system has no separate component for it, exactly as the Python oracle's
    // `_collect_model` recursion + `_ComponentSystem.merge` produce. Rust
    // ignored `subsystems` entirely, which silently dropped every nested
    // variable, parameter, and equation from the flattened system
    // (`tests/scoping/bare_reference_resolution.esm` lost `NO2_photo` and its
    // ODE, leaving an `ic` equation pointing at a state that did not exist).
    //
    // Order matters and is the oracle's: the parent's own tables first, the
    // subsystems' appended in declaration order.
    //
    // EVENTS ARE DELIBERATELY NOT lifted: the document's event view aggregates
    // only TOP-LEVEL components' events (parse.py's `EsmFile.events`), so a
    // subsystem-owned event is not part of the flattened system in any
    // binding. Folding them in here would make Rust the outlier.
    if let Some(subs) = &model.subsystems {
        for (sub_name, sub_value) in subs {
            // A `{ "ref": … }` entry (or any non-model mount) is not a
            // subsystem to lower: reference resolution runs before flattening,
            // so anything still unresolved here contributes nothing.
            let Ok(sub_model) = serde_json::from_value::<Model>(sub_value.clone()) else {
                continue;
            };
            let sub_block = build_model_block(&format!("{system_name}.{sub_name}"), &sub_model)?;
            block.state_vars.extend(sub_block.state_vars);
            block.parameters.extend(sub_block.parameters);
            block.observed_vars.extend(sub_block.observed_vars);
            block.equations.extend(sub_block.equations);
        }
    }

    Ok(block)
}

fn build_reaction_block(
    system_name: &str,
    rs: &ReactionSystem,
) -> Result<SystemBlock, FlattenError> {
    let mut state_vars = IndexMap::new();
    let mut parameters = IndexMap::new();

    // Document order (see [`build_model_block`]).
    for (species_name, species) in &rs.species {
        let namespaced = format!("{system_name}.{species_name}");
        // Reservoir species (`constant: true`, §7.4): held fixed, no ODE
        // (`lower_reactions_to_equations` skips its equation), so it is a
        // PARAMETER whose value is the species' `default`, not a state. It still
        // resolves as a concentration factor wherever a rate law references it.
        // Mirrors the Julia reference (namespacing.jl `_collect_reaction_system!`,
        // `target = sp.constant === true ? params : states`).
        let var = ModelVariable {
            var_type: if species.constant == Some(true) {
                VariableType::Parameter
            } else {
                VariableType::Unknown
            },
            units: species.units.clone(),
            default: species.default,
            default_units: None,
            description: species.description.clone(),
            shape: None,
            location: None,
            distribution: None,
            update: None,
        };
        if species.constant == Some(true) {
            parameters.insert(namespaced, var);
        } else {
            state_vars.insert(namespaced, var);
        }
    }

    for (param_name, param) in &rs.parameters {
        let namespaced = format!("{system_name}.{param_name}");
        parameters.insert(
            namespaced,
            ModelVariable {
                var_type: VariableType::Parameter,
                units: param.units.clone(),
                default: param.default,
                default_units: None,
                description: param.description.clone(),
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );
    }

    // Declared local names for the §5.5.6 `join` gate: a reaction system's
    // species and parameters. Mirrors Julia `_collect_reaction_system!`.
    let locals: HashSet<String> = rs
        .species
        .keys()
        .chain(rs.parameters.keys())
        .cloned()
        .collect();

    let lowered = crate::reactions::lower_reactions_to_equations(&rs.reactions, &rs.species)?;
    let equations = lowered
        .into_iter()
        .map(|eq| Equation {
            lhs: namespace_expr(&eq.lhs, system_name, &HashSet::new(), &locals),
            rhs: namespace_expr(&eq.rhs, system_name, &HashSet::new(), &locals),
        })
        .collect();

    Ok(SystemBlock {
        name: system_name.to_string(),
        state_vars,
        parameters,
        observed_vars: IndexMap::new(),
        equations,
        continuous_events: Vec::new(),
        discrete_events: Vec::new(),
    })
}

/// Dot-prefix every un-namespaced variable reference in `expr` with
/// `system_name`. Variables already containing a `.` are left alone so that
/// cross-system references (e.g. an equation explicitly referencing
/// `GEOSFP.T` in a `SimpleOzone` equation) survive unchanged. The independent
/// variable `t` is never namespaced — it's a global symbol resolved to
/// [`ResolvedExpr::Time`] during compile, not a component-scoped name.
///
/// Array nodes (`arrayop`/`aggregate`/`makearray`/`integral`/…) carry their
/// body in out-of-band fields (`expr`, `filter`, `lower`, `upper`, `values`,
/// `axes`) plus structural metadata (`output_idx`, `ranges`, `reduce`,
/// `semiring`, `shape`, …). Every such field is preserved and the
/// expression-bearing ones are recursively namespaced, so a discretized
/// `arrayop` survives coupling. Loop-index symbols introduced by an enclosing
/// `arrayop`/`aggregate` (`output_idx` + `ranges` keys) or `integral`
/// (`int_var`) are component-local — the array interpreter resolves them
/// positionally against `loop_binds`, never against the variable registry — so
/// they are excluded from namespacing within that node's scope (ess-14f.8).
///
/// The ONE structural field that is not merely preserved is `join`
/// (CONFORMANCE_SPEC §5.5.6): a `join.overlap`'s `src_env`/`tgt_env` envelope
/// factors, and a `join.on` key column, are *variable references that happen to
/// be encoded as plain strings rather than as `Expr::Variable` children* — the
/// value-invention materializer resolves each one against the variable registry
/// (`vi_join_index_sym` → `ctx.variables`, `broad_phase::envelope_vectors` →
/// `ctx.const_arrays`), which after flattening is the NAMESPACED registry. They
/// are therefore namespaced by [`namespace_join_names`], under the same
/// declared-local gate Julia's `_namespace_join` uses, so a name that is a loop
/// symbol or a document-scoped index set passes through untouched.
fn namespace_expr(
    expr: &Expr,
    system_name: &str,
    subsys: &HashSet<String>,
    locals: &HashSet<String>,
) -> Expr {
    namespace_expr_scoped(expr, system_name, &HashSet::new(), subsys, locals)
}

/// Dot-prefix the plain-string names carried by a node's `join` clauses
/// (CONFORMANCE_SPEC §5.5.6). Applies the SAME rule [`namespace_expr_scoped`]
/// applies to an `Expr::Variable`, gated on `locals` — the component's own
/// declared variable names plus its subsystem keys:
///
/// * a name this node BINDS as a loop symbol (an `output_idx` entry or a
///   `ranges` key) is left alone — **even when a local variable of the same
///   name is declared**. Index symbols are local to the enclosing `aggregate`
///   and shadow any coincident variable name (esm-spec §4.3.1: "a given string
///   can be a variable reference in most contexts but serves as an index symbol
///   inside `aggregate.output_idx`, `aggregate.expr`, and `aggregate.ranges`
///   keys"), and an `on` key column is resolved against THIS node's ranges
///   ([`crate::value_invention`]'s `vi_join_index_sym`, the interpreter's
///   `join_sym_for_key`) — so prefixing a shadowed symbol makes it resolve to
///   nothing. This check comes FIRST for that reason;
/// * otherwise a bare name that IS a declared local variable gets the prefix;
/// * a dotted name whose head is a local subsystem gets the prefix;
/// * anything else — a document-scoped index set named by an `on` key column
///   (§5.3), an already-qualified cross-component reference — is left alone.
///
/// Mirrors Julia `namespacing.jl::_namespace_join`. Returns `None` when nothing
/// changed, so a join-free (or fully external) node is byte-identical.
fn namespace_join_names(
    join: &[JoinClause],
    binders: &HashSet<&str>,
    system_name: &str,
    locals: &HashSet<String>,
) -> Option<Vec<JoinClause>> {
    let ns = |n: &String| -> String {
        if binders.contains(n.as_str()) {
            n.clone()
        } else if let Some((head, _)) = n.split_once('.') {
            if locals.contains(head) {
                return format!("{system_name}.{n}");
            }
            n.clone()
        } else if locals.contains(n) {
            format!("{system_name}.{n}")
        } else {
            n.clone()
        }
    };
    let out: Vec<JoinClause> = join
        .iter()
        .map(|c| JoinClause {
            on: c.on.iter().map(|[l, r]| [ns(l), ns(r)]).collect(),
            overlap: c.overlap.as_ref().map(|ov| OverlapClause {
                src_env: ov.src_env.iter().map(&ns).collect(),
                tgt_env: ov.tgt_env.iter().map(&ns).collect(),
                eps: ov.eps,
                // Range symbols the node itself binds, not variable references
                // — namespacing must leave them alone.
                sym_src: ov.sym_src.clone(),
                sym_tgt: ov.sym_tgt.clone(),
            }),
        })
        .collect();
    (out != join).then_some(out)
}

fn namespace_expr_scoped(
    expr: &Expr,
    system_name: &str,
    bound: &HashSet<String>,
    subsys: &HashSet<String>,
    locals: &HashSet<String>,
) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) => {
            // `t` is the independent variable and `_var` the §6.4 operator
            // placeholder; both are global symbols, neither is component-scoped.
            if name == "t" || name == VAR_PLACEHOLDER || bound.contains(name) {
                Expr::Variable(name.clone())
            } else if name.contains('.') {
                // A dotted reference is already-namespaced UNLESS its head is a
                // subsystem key, in which case it is a subsystem-local reference
                // (`raw.k`) that must be lifted to `<system>.raw.k`.
                let head = name.split('.').next().unwrap_or("");
                if subsys.contains(head) {
                    Expr::Variable(format!("{system_name}.{name}"))
                } else {
                    Expr::Variable(name.clone())
                }
            } else {
                Expr::Variable(format!("{system_name}.{name}"))
            }
        }
        Expr::Operator(node) => {
            // Extend the bound-index set with the loop symbols this node
            // introduces so its body / filter / bound expressions skip them.
            // `ranges` keys cover both the output and contracted indices of an
            // `arrayop`/`aggregate`; `output_idx` is added defensively; an
            // `integral` binds its `int_var`.
            let mut child_bound = bound.clone();
            if let Some(output_idx) = &node.output_idx {
                child_bound.extend(output_idx.iter().cloned());
            }
            if let Some(ranges) = &node.ranges {
                child_bound.extend(ranges.keys().cloned());
            }
            if let Some(int_var) = &node.int_var {
                child_bound.insert(int_var.clone());
            }

            // Re-namespace every expression-bearing child through the crate's
            // ONE canonical child-walker (`ExpressionNode::map_children`) rather
            // than hand-listing fields. `map_children` clones the node first —
            // preserving EVERY structural/metadata field verbatim, just like the
            // old explicit clone — and covers the FULL child set, including the
            // aggregate grouping `key` and template `bindings` that the previous
            // hand-rolled enumeration silently omitted (leaving their variable
            // references un-namespaced when flattening a coupled system).
            let mut out = node.map_children(&mut |c| {
                namespace_expr_scoped(c, system_name, &child_bound, subsys, locals)
            });

            // `wrt` is a differentiation-variable *string*, not a child `Expr`,
            // so it is a node-local rewrite the child-walker does not (and must
            // not) cover; apply it to the rebuilt node exactly as before.
            // `wrt` is a differentiation-variable *string*, not a child `Expr`.
            // A SPATIAL `wrt` names a document-scoped AXIS (esm-libraries-spec
            // §4.7.6 harvests it as an independent variable), so it is prefixed
            // only when it actually names one of this component's own locals —
            // the same whitelist rule `namespace_join_names` applies to a plain
            // string that may be a document-scoped index set. Prefixing it
            // unconditionally produced axes like `m.x` in
            // `independent_variables`; nothing observed that before, because an
            // undiscretized spatial `D` could not reach a FlattenedSystem at all
            // until flatten stopped refusing PDEs.
            out.wrt = node.wrt.as_ref().map(|w| {
                if w.contains('.')
                    || w == "t"
                    || w == VAR_PLACEHOLDER
                    || child_bound.contains(w)
                    || !locals.contains(w)
                {
                    w.clone()
                } else {
                    format!("{system_name}.{w}")
                }
            });
            // `join` likewise carries variable references as plain strings
            // (§5.5.6). The child-walker preserves the field verbatim; the
            // names inside it must follow the registry they resolve against.
            //
            // The binder set is THIS node's own loop symbols, not `child_bound`
            // (which also holds enclosing nodes'). A join column is resolved
            // against this node's `ranges`, so its own binders are the exact
            // shadowing set — and keeping the set node-local is what lets every
            // binding implement the identical rule without threading a scope.
            if let Some(join) = &node.join {
                let mut binders: HashSet<&str> = HashSet::new();
                if let Some(output_idx) = &node.output_idx {
                    binders.extend(output_idx.iter().map(String::as_str));
                }
                if let Some(ranges) = &node.ranges {
                    binders.extend(ranges.keys().map(String::as_str));
                }
                if let Some(ns) = namespace_join_names(join, &binders, system_name, locals) {
                    out.join = Some(ns);
                }
            }
            Expr::operator(out)
        }
    }
}

fn namespace_continuous_event(
    mut event: ContinuousEvent,
    system_name: &str,
    subsys: &HashSet<String>,
    locals: &HashSet<String>,
) -> ContinuousEvent {
    event.conditions = event
        .conditions
        .into_iter()
        .map(|c| namespace_expr(&c, system_name, subsys, locals))
        .collect();
    event.affects = event
        .affects
        .into_iter()
        .map(|mut a| {
            a.lhs = namespace_plain(&a.lhs, system_name);
            a.rhs = namespace_expr(&a.rhs, system_name, subsys, locals);
            a
        })
        .collect();
    if let Some(neg) = event.affect_neg.take() {
        event.affect_neg = Some(
            neg.into_iter()
                .map(|mut a| {
                    a.lhs = namespace_plain(&a.lhs, system_name);
                    a.rhs = namespace_expr(&a.rhs, system_name, subsys, locals);
                    a
                })
                .collect(),
        );
    }
    event
}

fn namespace_discrete_event(
    mut event: DiscreteEvent,
    system_name: &str,
    subsys: &HashSet<String>,
    locals: &HashSet<String>,
) -> DiscreteEvent {
    use crate::types::DiscreteEventTrigger;
    event.trigger = match event.trigger {
        DiscreteEventTrigger::Condition { expression } => DiscreteEventTrigger::Condition {
            expression: namespace_expr(&expression, system_name, subsys, locals),
        },
        other => other,
    };
    if let Some(affects) = event.affects.take() {
        event.affects = Some(
            affects
                .into_iter()
                .map(|mut a| {
                    a.lhs = namespace_plain(&a.lhs, system_name);
                    a.rhs = namespace_expr(&a.rhs, system_name, subsys, locals);
                    a
                })
                .collect(),
        );
    }
    event
}

/// The operator-model placeholder (esm-spec §6.4). A GLOBAL sentinel, not a
/// component-scoped name: `operator_compose` substitutes it with each matching
/// ODE state of the TARGET system, so prefixing it with the operator model's
/// own namespace destroys the very name the substitution looks for. Treated
/// exactly like the independent variable `t` everywhere namespacing happens.
const VAR_PLACEHOLDER: &str = "_var";

fn namespace_plain(name: &str, system_name: &str) -> String {
    if name.contains('.') || name == VAR_PLACEHOLDER {
        name.to_string()
    } else {
        format!("{system_name}.{name}")
    }
}

/// Scan an expression-tree RHS and reject any unlowered rewrite-target operator
/// (esm-spec §4.2 / §9.6.8) with the uniform [`FlattenError::UnloweredOperator`]
/// (`unlowered_operator`) code.
///
/// The tier decision is delegated wholesale to [`crate::op_registry`], the
/// single source of truth for the operator vocabulary — this gate keeps NO
/// hand-maintained op-name list of its own. A node the registry classifies
/// [`crate::op_registry::OpError::Unlowered`] is a rewrite target: the optional
/// sugar ops (`grad`/`div`/`laplacian`/`curl`/`∇`/`integral`), a SPATIAL `D` (a
/// `D` whose `wrt` is a spatial axis rather than the time variable `"t"`), or
/// ANY op not in the evaluable core — an unregistered user discretization op
/// (`godunov_hamiltonian`) is treated exactly like the named sugar ops, with no
/// privileged status. The structural equation-LHS `D(u, t)` stays
/// evaluable-core and is untouched. A rewrite rule must lower these to a stencil
/// before evaluation; this format ships no such rules (they live in
/// EarthSciDiscretizations).
///
/// Malformed-CORE problems (a wrong arity, an inverted `makearray` region) are
/// not this gate's concern — the compile / eval stages report those with their
/// own diagnostics — so only the `Unlowered` classification is surfaced here.
fn reject_spatial_operators(expr: &Expr) -> Result<(), FlattenError> {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => Ok(()),
        Expr::Operator(node) => {
            if let Err(crate::op_registry::OpError::Unlowered { op }) =
                crate::op_registry::check_node(node)
            {
                return Err(FlattenError::UnloweredOperator { op });
            }
            // Recurse through the crate's ONE canonical child-walker so the gate
            // sees operators hidden in EVERY expression-bearing sidecar field
            // (`aggregate.expr` bodies, `filter` predicates, integral `lower`/
            // `upper` bounds, `makearray.values`, `key`, `axes`, `bindings`) and
            // not merely `args` — an `args`-only walk let a spatial/sugar op
            // buried in a sidecar escape the gate entirely. The first error is
            // captured and propagated unchanged, preserving the byte-identical
            // `FlattenError::UnloweredOperator` diagnostic the callers expect.
            let mut first_err: Option<FlattenError> = None;
            node.for_each_child(&mut |child| {
                if first_err.is_none()
                    && let Err(e) = reject_spatial_operators(child)
                {
                    first_err = Some(e);
                }
            });
            match first_err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        }
    }
}

/// Extract the dependent variable name from an `LHS = D(X, t)` pattern.
/// Returns `None` for any other LHS shape.
fn extract_ddt_dependent(lhs: &Expr) -> Option<String> {
    let Expr::Operator(node) = lhs else {
        return None;
    };
    if node.op != "D" {
        return None;
    }
    if node.wrt.as_deref() != Some("t") {
        return None;
    }
    if node.args.len() != 1 {
        return None;
    }
    match &node.args[0] {
        Expr::Variable(name) => Some(name.clone()),
        _ => None,
    }
}

/// Apply a single coupling entry to the per-system blocks, mutating
/// `coupling_rules_applied` with a human-readable description.
fn apply_coupling_entry(
    entry: &CouplingEntry,
    per_system: &mut Vec<SystemBlock>,
    coupling_rules_applied: &mut Vec<String>,
) -> Result<(), FlattenError> {
    match entry {
        CouplingEntry::OperatorCompose {
            systems,
            translate,
            description,
            ..
        } => {
            apply_operator_compose(systems, translate.as_ref(), per_system)?;
            coupling_rules_applied.push(
                description
                    .clone()
                    .unwrap_or_else(|| format!("operator_compose({})", systems.join(" + "))),
            );
        }
        CouplingEntry::Couple {
            systems,
            connector,
            description,
        } => {
            apply_couple(systems, connector, per_system)?;
            coupling_rules_applied.push(
                description
                    .clone()
                    .unwrap_or_else(|| format!("couple({})", systems.join(" <-> "))),
            );
        }
        CouplingEntry::VariableMap {
            from,
            to,
            transform,
            factor,
            description,
        } => {
            match transform {
                VariableMapTransform::Named(_) => {
                    apply_variable_map(from, to, *factor, per_system);
                }
                // Expression transform (esm-spec §10.4): no substitution —
                // references to `to` stay intact and resolve to the observed
                // introduced in the collection phase. Validated here so a bad
                // entry fails before any rewriting: an expression transform
                // spells its own arithmetic (no `factor` slot) and MUST
                // reference the entry's `from` variable — the data-flow edge
                // the entry declares.
                VariableMapTransform::Expression(node) => {
                    if factor.is_some() {
                        return Err(FlattenError::VariableMapFactorWithExpression {
                            from: from.clone(),
                            to: to.clone(),
                        });
                    }
                    if !node.any_child(&mut |e| crate::expression::contains(e, from)) {
                        return Err(FlattenError::VariableMapExpressionMissingFrom {
                            from: from.clone(),
                            to: to.clone(),
                        });
                    }
                }
            }
            coupling_rules_applied.push(description.clone().unwrap_or_else(|| {
                let factor_str = factor.map(|f| format!(" [factor={f}]")).unwrap_or_default();
                format!("variable_map({from} -> {to}, {transform}){factor_str}")
            }));
        }
        CouplingEntry::OperatorApply {
            operator,
            description,
        } => {
            coupling_rules_applied.push(
                description
                    .clone()
                    .unwrap_or_else(|| format!("operator_apply({operator})")),
            );
        }
        CouplingEntry::Callback {
            callback_id,
            description,
            ..
        } => {
            coupling_rules_applied.push(
                description
                    .clone()
                    .unwrap_or_else(|| format!("callback({callback_id})")),
            );
        }
        CouplingEntry::Event {
            event_type,
            name,
            description,
            ..
        } => {
            coupling_rules_applied.push(description.clone().unwrap_or_else(|| {
                format!(
                    "event({}: {})",
                    event_type,
                    name.as_deref().unwrap_or("unnamed")
                )
            }));
        }
        // `coupling_import` entries are expanded into concrete edges by
        // `flatten_with_options` before `flatten_impl` runs, so one never
        // reaches the rule-application step. Treat as a no-op for robustness.
        CouplingEntry::CouplingImport { .. } => {}
    }
    Ok(())
}

/// The dependent variable an equation defines, for `operator_compose` matching
/// (esm-libraries-spec §4.7.1 step 1).
///
/// `D(x, t)` yields `x`; a bare-variable LHS yields itself; the `index` /
/// `aggregate` shells peel to the variable they write. An LHS that is a
/// composite expression (an algebraic constraint, an `ic` seed) defines no
/// single variable and yields `None`, so it never participates in a match and
/// is preserved unchanged by step 5.
///
/// Delegates to the crate's canonical [`crate::classification::lhs_form`]
/// rather than re-deriving the shapes, matching the oracle's
/// `_lhs_dependent_var`.
fn compose_dependent(lhs: &Expr) -> Option<String> {
    match crate::classification::lhs_form(lhs) {
        crate::classification::LhsForm::Derivative(name)
        | crate::classification::LhsForm::Bare(name) => Some(name),
        crate::classification::LhsForm::Expression => None,
    }
}

/// Normalize an `operator_compose` `translate` map, **INVERTED** for matching
/// (esm-libraries-spec §4.7.1 step 2, esm-spec §10.2).
///
/// The authored direction is normative and is NOT symmetric: for
/// `"systems": [A, B]` every KEY names a variable of `A` and every VALUE names
/// a variable of `B`. Step 3 walks *B's* equations, so the matching loop needs
/// the map the other way round; this returns the inverse
/// `{b_name: (a_name, factor)}`.
///
/// Indexing the authored (A-keyed) map by B's dependent variable is the bug
/// this function exists to prevent — a correctly spelled `translate` map then
/// matches nothing at all and the whole coupling entry is a silent no-op.
///
/// A value is either a plain string (`"B.O3"`) or an object carrying the target
/// and an optional conversion factor (`{"var": "B.O3", "factor": 1e-9}`); the
/// `to` / `target` spellings of that key are accepted alongside `var`, as in
/// the oracle. Anything else is ignored.
fn build_translate_map(
    translate: Option<&serde_json::Value>,
    a_system: &str,
    b_system: &str,
) -> HashMap<String, (String, f64)> {
    let mut out: HashMap<String, (String, f64)> = HashMap::new();
    let Some(obj) = translate.and_then(|v| v.as_object()) else {
        return out;
    };
    for (a_name, value) in obj {
        let a_q = qualify_translate_endpoint(a_name, a_system);
        match value {
            serde_json::Value::String(b_name) => {
                out.insert(qualify_translate_endpoint(b_name, b_system), (a_q, 1.0));
            }
            serde_json::Value::Object(spec) => {
                let b_name = ["var", "to", "target"]
                    .iter()
                    .find_map(|k| spec.get(*k).and_then(|v| v.as_str()));
                let factor = spec.get("factor").and_then(|f| f.as_f64()).unwrap_or(1.0);
                if let Some(b_name) = b_name {
                    out.insert(qualify_translate_endpoint(b_name, b_system), (a_q, factor));
                }
            }
            _ => {}
        }
    }
    out
}

/// Put one `translate` endpoint into the NAMESPACED form the matcher uses
/// (esm-libraries-spec §4.7.1 step 2, esm-spec §10.2).
///
/// `translate` endpoints are authored in either form — bare (`"O3"`) or fully
/// scoped (`"ChemistrySystem.O3"`) — and §10.2 admits both, but matching runs
/// against the namespaced dependent variable of a flattened equation. An
/// endpoint left bare can therefore never match, which is why a correctly
/// spelled bare map was a silent no-op: the lookup missed, and the bare-name
/// fallback then searched A for B's short name and missed too.
///
/// A bare endpoint is qualified with the system it belongs to under §10.2's
/// direction rule — a KEY against `systems[0]`, a VALUE against `systems[1]`.
/// An endpoint that already carries a dot is left ALONE: it is either already
/// namespaced or names a subsystem path, and re-prefixing it would break it.
///
/// `_var` is exempt in both positions. It is a GLOBAL sentinel (esm-spec §6.4),
/// never namespaced; a value of `"B._var"` is the redundant spelling §10.2
/// requires to stay harmless, and it stays harmless because placeholder
/// expansion has already turned that equation into a DIRECT match, which takes
/// precedence over this map.
fn qualify_translate_endpoint(name: &str, system: &str) -> String {
    if name.is_empty()
        || name == VAR_PLACEHOLDER
        || name.ends_with(&format!(".{VAR_PLACEHOLDER}"))
        || name.contains('.')
        || system.is_empty()
    {
        return name.to_string();
    }
    format!("{system}.{name}")
}

/// Expand the `_var` placeholder (esm-spec §6.4) in B's equations against A's
/// solved-for variables — esm-libraries-spec §4.7.1 step 3, "Placeholder
/// expansion".
///
/// An operator model writes ONE equation over the sentinel `_var`
/// (`D(_var, t) = -u·grad(_var)`); composing it with A means CLONING that
/// equation once per variable A solves for, with `_var` substituted for that
/// variable's namespaced name. `_var` is a GLOBAL sentinel and is never
/// namespaced (see [`VAR_PLACEHOLDER`]), so the substitution is a plain
/// single-name rewrite through the crate's canonical
/// [`crate::substitute::substitute`] — which reaches the sidecar expression
/// fields (`aggregate.expr`, `filter`, integral bounds) a hand-rolled `args`
/// walk would miss.
///
/// Runs BEFORE matching, which is what makes an expanded equation a DIRECT
/// match in step 3 and keeps a redundant `translate: {"A.x": "B._var"}` entry
/// harmless (§10.2's redundancy invariant).
fn expand_placeholder_equations(a_idx: usize, b_idx: usize, per_system: &mut [SystemBlock]) {
    let a_states: Vec<String> = per_system[a_idx].state_vars.keys().cloned().collect();
    if a_states.is_empty() {
        return;
    }
    let b_equations = std::mem::take(&mut per_system[b_idx].equations);
    let mut expanded: Vec<Equation> = Vec::with_capacity(b_equations.len());
    for eq in b_equations {
        if crate::expression::contains(&eq.lhs, VAR_PLACEHOLDER)
            || crate::expression::contains(&eq.rhs, VAR_PLACEHOLDER)
        {
            for state in &a_states {
                let subs: HashMap<String, Expr> =
                    std::iter::once((VAR_PLACEHOLDER.to_string(), Expr::Variable(state.clone())))
                        .collect();
                expanded.push(Equation {
                    lhs: crate::substitute::substitute(&eq.lhs, &subs),
                    rhs: crate::substitute::substitute(&eq.rhs, &subs),
                });
            }
        } else {
            expanded.push(eq);
        }
    }
    per_system[b_idx].equations = expanded;
}

/// Apply an `operator_compose` rule (esm-libraries-spec §4.7.1, all five
/// steps): merge system B's equations into system A by matching dependent
/// variables and summing right-hand sides.
///
/// For `"systems": [A, B]`, A is `systems[0]` and B is `systems[1]`. The five
/// steps run in order:
///
/// 1. **Extract dependent variables** — [`compose_dependent`].
/// 2. **Apply translations** — [`build_translate_map`] builds the INVERSE
///    (B → A) map the matching loop needs.
/// 3. **Match equations**, in the spec's precedence order: DIRECT first, then
///    TRANSLATION, then the bare-name fallback. Placeholder expansion
///    ([`expand_placeholder_equations`]) has already run, so an expanded
///    equation carries A's own variable name and is a DIRECT match.
///    Direct-first is load-bearing rather than cosmetic: consulting
///    `translate` first would let an A-keyed map hit spuriously on that
///    rewritten name and redirect the match to a target that does not exist,
///    turning a working composition into an over-determination error (§10.2's
///    redundancy invariant).
/// 4. **Combine matched equations** — A keeps its LHS, and the RHS becomes
///    `rhs_A + factor * rhs_B`. On a TRANSLATION match only, B's dependent
///    variable is rewritten to A's target throughout `rhs_B` first: a
///    `translate` pair names two spellings of the SAME quantity, and leaving
///    `rhs_B` in B's spelling would strand that variable as an unknown nothing
///    defines, because its own defining equation was just consumed. B's other
///    variables — its parameters, its observeds — keep their names. On a
///    direct or placeholder match the two names are already equal, so the
///    rewrite is the identity.
/// 5. **Preserve unmatched equations** — a B equation with no A counterpart
///    stays in B's block, in place and unchanged.
///
/// This function previously merged only equations whose dependent variable was
/// byte-identical across two blocks. Because flattening namespaces every
/// variable (`A.O3` vs `B.O3`), that can essentially never happen, so it was a
/// total no-op: neither placeholder expansion nor `translate` was implemented
/// at all, and `translate` was destructured away unread.
fn apply_operator_compose(
    systems: &[String],
    translate: Option<&serde_json::Value>,
    per_system: &mut [SystemBlock],
) -> Result<(), FlattenError> {
    if systems.len() < 2 {
        return Ok(());
    }
    let Some(a_idx) = per_system.iter().position(|b| b.name == systems[0]) else {
        return Ok(());
    };
    let Some(b_idx) = per_system.iter().position(|b| b.name == systems[1]) else {
        return Ok(());
    };
    if a_idx == b_idx {
        return Ok(());
    }

    // Step 3's placeholder expansion, run first so the expanded equations are
    // ordinary direct matches below.
    expand_placeholder_equations(a_idx, b_idx, per_system);

    // Step 2: the INVERSE (B -> A) translation map, both endpoints put into
    // NAMESPACED form first (`qualify_translate_endpoint`) — matching runs
    // against a flattened equation's namespaced dependent variable, so a bare
    // endpoint that is not qualified here can never match.
    let translate = build_translate_map(translate, &systems[0], &systems[1]);

    // Step 1: A's equations, indexed by dependent variable.
    let mut a_index: IndexMap<String, usize> = IndexMap::new();
    for (i, eq) in per_system[a_idx].equations.iter().enumerate() {
        if let Some(dep) = compose_dependent(&eq.lhs) {
            a_index.insert(dep, i);
        }
    }

    let b_equations = std::mem::take(&mut per_system[b_idx].equations);
    let mut surviving: Vec<Equation> = Vec::new();
    // `b_dep -> target_dep` for every match that RENAMED the dependent variable
    // (step 4's "the merged-away name does not survive"). Insertion-ordered so
    // the prune below is deterministic.
    let mut merged_away: IndexMap<String, String> = IndexMap::new();
    for b_eq in b_equations {
        let Some(b_dep) = compose_dependent(&b_eq.lhs) else {
            surviving.push(b_eq);
            continue;
        };

        // Step 3, in precedence order: direct, then translation, then the
        // bare-name fallback.
        let mut target = b_dep.clone();
        let mut factor = 1.0_f64;
        if a_index.contains_key(&b_dep) {
            // Direct match: `target` is already right.
        } else if let Some((a_name, f)) = translate.get(&b_dep) {
            target = a_name.clone();
            factor = *f;
        } else {
            let short = b_dep.split_once('.').map(|(_, s)| s).unwrap_or(&b_dep);
            let suffix = format!(".{short}");
            if let Some(hit) = a_index.keys().find(|k| k.ends_with(&suffix)) {
                target = hit.clone();
            }
        }

        // Step 5: no counterpart in A, so the equation stays in B untouched.
        let Some(&i) = a_index.get(&target) else {
            surviving.push(b_eq);
            continue;
        };

        // Step 4. B's dependent variable is rewritten to A's target throughout
        // `rhs_B`. On a direct or placeholder match the two names are already
        // equal, so this is the identity and no renaming happens; it bites on a
        // TRANSLATION match (and on the bare-name fallback, which is a
        // translation by another route), where the two names are two spellings
        // of ONE quantity and B's own defining equation is being consumed right
        // here — leaving `rhs_B` in B's spelling would strand that variable as
        // an unknown nothing defines. ONLY the dependent variable moves; B's
        // parameters and observeds keep their names.
        let mut rhs_b = if target == b_dep {
            b_eq.rhs
        } else {
            let subs: HashMap<String, Expr> =
                std::iter::once((b_dep.clone(), Expr::Variable(target.clone()))).collect();
            crate::substitute::substitute(&b_eq.rhs, &subs)
        };
        if factor != 1.0 {
            rhs_b = Expr::operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![Expr::Number(factor), rhs_b],
                ..Default::default()
            });
        }
        let rhs_a = std::mem::replace(&mut per_system[a_idx].equations[i].rhs, Expr::Integer(0));
        per_system[a_idx].equations[i].rhs = sum_exprs(rhs_a, rhs_b);
        if target != b_dep {
            merged_away.insert(b_dep, target);
        }
    }
    per_system[b_idx].equations = surviving;

    // Step 4, second half: a RENAMING match — a translation match, or the
    // bare-name fallback, which is a name-based translation — has just consumed
    // B's defining equation for `b_dep`, so B's declaration of that name is left
    // constraining nothing. An unknown with no defining equation classifies as
    // ALGEBRAIC (esm-spec §6.3.1), so keeping it would hand the solver a state
    // with no constraint — a structurally singular system, which is exactly what
    // the rhs rewrite above exists to prevent; this prune is its other half.
    //
    // §10.2 says a `translate` pair names ONE physical quantity under two
    // spellings, so only A's spelling survives: every remaining reference is
    // retargeted at it FIRST, then the stranded declaration is dropped. The
    // retarget is DOCUMENT-WIDE, not B-local — a third system is free to
    // reference `B.x` by its scoped name, and pruning the declaration while
    // leaving that reference dangling would trade one broken system for another.
    if !merged_away.is_empty() {
        retarget_merged_names(per_system, &merged_away);
        for gone in merged_away.keys() {
            per_system[b_idx].state_vars.shift_remove(gone);
            per_system[b_idx].observed_vars.shift_remove(gone);
        }
    }

    Ok(())
}

/// Rewrite every reference to a merged-away dependent variable, EVERYWHERE
/// (esm-libraries-spec §4.7.1 step 4).
///
/// Applied after an `operator_compose` renaming match folds `B.x` into `A.y`:
/// the two spellings named one quantity, only `A.y` still exists, so every
/// equation side in the whole document is rewritten off the dead name. An
/// observed variable's defining expression is one of those equations (it is not
/// carried on the variable record), so this covers it too.
fn retarget_merged_names(per_system: &mut [SystemBlock], renames: &IndexMap<String, String>) {
    let subs: HashMap<String, Expr> = renames
        .iter()
        .map(|(from, to)| (from.clone(), Expr::Variable(to.clone())))
        .collect();
    for block in per_system.iter_mut() {
        for eq in block.equations.iter_mut() {
            eq.lhs = crate::substitute::substitute(&eq.lhs, &subs);
            eq.rhs = crate::substitute::substitute(&eq.rhs, &subs);
        }
    }
}

fn sum_exprs(a: Expr, b: Expr) -> Expr {
    Expr::operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![a, b],
        wrt: None,
        dim: None,
        ..Default::default()
    })
}

/// Apply a `couple` rule by injecting the connector equations (if any) into
/// a synthetic system block. The connector is an opaque JSON value in the
/// Rust type model — we look for an `equations` array of `{lhs, rhs}`
/// pairs, each of which may be a JSON-encoded [`Expr`].
fn apply_couple(
    systems: &[String],
    connector: &serde_json::Value,
    per_system: &mut Vec<SystemBlock>,
) -> Result<(), FlattenError> {
    let Some(eqs_json) = connector.get("equations").and_then(|e| e.as_array()) else {
        return Ok(());
    };
    let block_name = format!("couple({})", systems.join(","));
    let mut new_equations = Vec::new();
    for eq_val in eqs_json {
        // esm-spec §4.7.2 gives a connector equation TWO spellings, and a
        // document may mix them:
        //
        //   * EXPLICIT — `{lhs, rhs}` — a new equation of its own, collected
        //     into a synthetic `couple(...)` block below;
        //   * INJECTED — `{from, to, transform, expression}` — a source/sink
        //     TERM folded into the equation that already defines `to`.
        //
        // Only the explicit form was implemented, so every fixture using the
        // injected one hard-failed with `MalformedConnectorEquation`. That went
        // unnoticed because the spatial-operator refusal fired first on all
        // three corpus documents that carry it.
        if eq_val.get("lhs").is_some() || eq_val.get("rhs").is_some() {
            let lhs = parse_connector_side(eq_val, "lhs", systems)?;
            let rhs = parse_connector_side(eq_val, "rhs", systems)?;
            new_equations.push(Equation { lhs, rhs });
        } else if eq_val.get("to").is_some() {
            inject_connector_term(eq_val, systems, per_system)?;
        } else {
            return Err(FlattenError::MalformedConnectorEquation {
                systems: systems.join(","),
                side: "lhs".to_string(),
            });
        }
    }
    if !new_equations.is_empty() {
        per_system.push(SystemBlock {
            name: block_name,
            state_vars: IndexMap::new(),
            parameters: IndexMap::new(),
            observed_vars: IndexMap::new(),
            equations: new_equations,
            continuous_events: Vec::new(),
            discrete_events: Vec::new(),
        });
    }
    Ok(())
}

/// Fold one INJECTED connector equation — `{from, to, transform, expression}`
/// (esm-spec §4.7.2) — into the equation that already defines its `to` target.
///
/// `from` / `to` are scoped references (`A.x`) and the `expression`'s own
/// references are, by contract, already fully scoped, so nothing is namespaced
/// here — the term is used verbatim, exactly as the Python oracle uses it.
///
/// The target equation is found by its LHS DEPENDENT VARIABLE, read through the
/// crate's canonical [`crate::classification::lhs_form`], so `D(x, t)`,
/// `D(x[i], t)`, a bare `x`, and the `aggregate`-wrapped spellings all resolve
/// to `x`. For an `additive` or `replacement` transform a `to` that names no
/// equation's LHS is SKIPPED, not an error — the oracle skips it too.
///
/// `transform` selects how the term combines with the existing RHS: `additive`
/// sums, `multiplicative` multiplies, `replacement` overwrites. An absent or
/// unrecognised transform falls through to `additive`, mirroring the oracle.
///
/// `multiplicative` is the ONE transform with a precondition: esm-spec §10.3
/// and esm-libraries-spec §4.7.2 define it against the target's EXISTING ODE
/// right-hand side, so a `to` with no `D(to)` tendency raises
/// [`FlattenError::CoupleMultiplicativeNoTendency`] rather than taking the
/// skip. The check runs BEFORE the skip and is keyed on a TENDENCY
/// specifically, not on "some equation defines `to`" — an observed or an
/// algebraic unknown has a defining equation and still has nothing to multiply.
fn inject_connector_term(
    eq_val: &serde_json::Value,
    systems: &[String],
    per_system: &mut [SystemBlock],
) -> Result<(), FlattenError> {
    let Some(target) = eq_val.get("to").and_then(|v| v.as_str()) else {
        return Ok(());
    };

    let transform = eq_val.get("transform").and_then(|v| v.as_str());
    if transform == Some("multiplicative") {
        let has_tendency = per_system
            .iter()
            .flat_map(|b| b.equations.iter())
            .any(|eq| {
                matches!(
                    crate::classification::lhs_form(&eq.lhs),
                    crate::classification::LhsForm::Derivative(ref name) if name == target
                )
            });
        if !has_tendency {
            return Err(FlattenError::CoupleMultiplicativeNoTendency {
                target: target.to_string(),
            });
        }
    }

    // The term: the declared `expression`, or a bare reference to `from` when
    // the entry carries none.
    let term = match eq_val.get("expression") {
        Some(v) => serde_json::from_value::<Expr>(v.clone()).map_err(|_| {
            FlattenError::MalformedConnectorEquation {
                systems: systems.join(","),
                side: "expression".to_string(),
            }
        })?,
        None => match eq_val.get("from").and_then(|v| v.as_str()) {
            Some(from) => Expr::Variable(from.to_string()),
            None => {
                return Err(FlattenError::MalformedConnectorEquation {
                    systems: systems.join(","),
                    side: "from".to_string(),
                });
            }
        },
    };

    for block in per_system.iter_mut() {
        for eq in block.equations.iter_mut() {
            let dep = match crate::classification::lhs_form(&eq.lhs) {
                crate::classification::LhsForm::Derivative(name)
                | crate::classification::LhsForm::Bare(name) => name,
                crate::classification::LhsForm::Expression => continue,
            };
            if dep != target {
                continue;
            }
            let existing = std::mem::replace(&mut eq.rhs, Expr::Integer(0));
            eq.rhs = match transform {
                Some("multiplicative") => Expr::operator(ExpressionNode {
                    op: "*".to_string(),
                    args: vec![existing, term],
                    ..Default::default()
                }),
                Some("replacement") => term,
                // `additive`, absent, or unrecognised.
                _ => sum_exprs(existing, term),
            };
            return Ok(());
        }
    }
    // No equation defines `to` — nothing to inject into. See the doc comment.
    Ok(())
}

/// Deserialize one side (`lhs` / `rhs`) of a `couple` connector equation as an
/// [`Expr`]. An absent side or a value that does not parse is a
/// [`FlattenError::MalformedConnectorEquation`] rather than a silent drop.
fn parse_connector_side(
    eq_val: &serde_json::Value,
    side: &str,
    systems: &[String],
) -> Result<Expr, FlattenError> {
    eq_val
        .get(side)
        .cloned()
        .and_then(|v| serde_json::from_value::<Expr>(v).ok())
        .ok_or_else(|| FlattenError::MalformedConnectorEquation {
            systems: systems.join(","),
            side: side.to_string(),
        })
}

/// Apply a NAMED-transform `variable_map` rule by substituting `from` for
/// `to` in every equation's expression tree (and scaling by `factor` where
/// applicable). Parameter removal for `param_to_var`/`conversion_factor`
/// happens in the collection phase to keep this function purely
/// expression-rewriting. Expression transforms (esm-spec §10.4) never reach
/// here — they perform no substitution at all (the target becomes an
/// observed in the collection phase).
fn apply_variable_map(from: &str, to: &str, factor: Option<f64>, per_system: &mut [SystemBlock]) {
    // `factor` is a scaling coefficient; the schema restricts it to the scaling
    // transforms (additive / multiplicative / conversion_factor), so apply it
    // uniformly whenever present. This matches Python and Julia — Rust previously
    // scaled only for `conversion_factor`, silently dropping the factor for
    // additive / multiplicative. A factor of 1.0 is a no-op and left unwrapped.
    // (Parameter removal for param_to_var/conversion_factor is in the collection
    // phase, so this function no longer needs `transform`.)
    let replacement = match factor {
        Some(f) if f != 1.0 => Expr::operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![Expr::Variable(from.to_string()), Expr::Number(f)],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
        _ => Expr::Variable(from.to_string()),
    };
    // One single-target substitution map, reused across equations, observeds,
    // AND events through the canonical `crate::substitute` traversal (which
    // preserves every array-node metadata field via `map_children`). Hand-rolled
    // walkers previously drifted — the local `substitute_var` covered equations
    // and observeds but not events, so an event condition / affect RHS
    // referencing the removed `to` parameter kept a dangling reference.
    let subs: HashMap<String, Expr> = std::iter::once((to.to_string(), replacement)).collect();
    for block in per_system.iter_mut() {
        for eq in &mut block.equations {
            eq.lhs = crate::substitute::substitute(&eq.lhs, &subs);
            eq.rhs = rename_join_names(&crate::substitute::substitute(&eq.rhs, &subs), to, from);
        }
        // A `variable_map` also removes the mapped parameter from the system, so
        // it must reach every remaining Expression a VARIABLE carries — the
        // trigger and value expressions of a parameter `update` — otherwise one
        // keeps a dangling reference to the now-removed parameter and evaluates
        // to NaN. (An observed unknown's defining expression is an equation from
        // esm 1.0.0, already rewritten by the loop above.)
        for var in block
            .observed_vars
            .values_mut()
            .chain(block.parameters.values_mut())
        {
            var.for_each_expression_mut(&mut |expr| {
                *expr = rename_join_names(&crate::substitute::substitute(expr, &subs), to, from);
            });
        }
        // ...and event conditions / affect RHS (continuous + discrete), for the
        // same reason: an event whose condition or affect referenced the removed
        // `to` parameter would otherwise keep a dangling reference. The event
        // helpers rewrite conditions, affect RHS, affect_neg RHS, and the trigger
        // expression, leaving affect LHS (a bare variable name) untouched.
        for ev in &mut block.continuous_events {
            *ev = crate::substitute::substitute_in_continuous_event(ev, &subs);
        }
        for ev in &mut block.discrete_events {
            *ev = crate::substitute::substitute_in_discrete_event(ev, &subs);
        }
    }
}

/// True iff any node in `expr` carries a non-empty `join`.
fn contains_join(expr: &Expr) -> bool {
    match expr {
        Expr::Operator(node) => {
            node.join.as_ref().is_some_and(|j| !j.is_empty()) || node.any_child(&mut contains_join)
        }
        _ => false,
    }
}

/// Rename `to` → `from` in every plain-string name a `join` clause carries
/// (CONFORMANCE_SPEC §5.5.6), the join-side companion of the `variable_map`
/// substitution above.
///
/// `crate::substitute` walks expression CHILDREN, so it cannot see these names;
/// but they are references in the same namespaced scope as everything else
/// (that is exactly what makes them namespaceable). A `param_to_var` /
/// `conversion_factor` map REMOVES `to` from the flattened parameter registry,
/// so a join still naming it points at a variable that no longer exists and
/// materialisation dies with `join references unknown variable`. Mirrors Julia
/// `coupling_apply.jl::_rename_join_names`.
///
/// The exact case this exists for: an overlap-gated value-invention producer
/// over a coupled rectangle buffer, where `tgt_env = [ISRM.src_W, …]` while an
/// `ISRM_SR.src_W -> ISRM.src_W` map has already removed `ISRM.src_W`.
fn rename_join_names(expr: &Expr, to: &str, from: &str) -> Expr {
    // Scan BEFORE the rebuild: `map_children` clones, and this runs over every
    // equation of every block for every `variable_map` entry. Almost no model
    // carries a join, and those must stay free of an extra whole-tree copy on
    // top of the substitution's. The scan is once per tree, not per node — the
    // recursion below is the unguarded `rename_join_names_in`.
    if !contains_join(expr) {
        return expr.clone();
    }
    rename_join_names_in(expr, to, from)
}

fn rename_join_names_in(expr: &Expr, to: &str, from: &str) -> Expr {
    let Expr::Operator(node) = expr else {
        return expr.clone();
    };
    let mut out = node.map_children(&mut |c| rename_join_names_in(c, to, from));
    if let Some(join) = &node.join {
        let ren = |n: &String| -> String { if n == to { from.to_string() } else { n.clone() } };
        out.join = Some(
            join.iter()
                .map(|c| JoinClause {
                    on: c.on.iter().map(|[l, r]| [ren(l), ren(r)]).collect(),
                    overlap: c.overlap.as_ref().map(|ov| OverlapClause {
                        src_env: ov.src_env.iter().map(&ren).collect(),
                        tgt_env: ov.tgt_env.iter().map(&ren).collect(),
                        eps: ov.eps,
                        // Range symbols the node itself binds, not variable
                        // references — renaming must leave them alone.
                        sym_src: ov.sym_src.clone(),
                        sym_tgt: ov.sym_tgt.clone(),
                    }),
                })
                .collect(),
        );
    }
    Expr::operator(out)
}

/// Preflight (esm-spec §10.4): walk every `variable_map` coupling entry whose
/// transform is the named `identity` and raise [`FlattenError::DomainUnitMismatch`]
/// when the `from` and `to` variables both carry DECLARED, non-empty, and
/// DIFFERING unit strings. Mirrors Julia's `_check_variable_map_units`
/// (coupling_apply.jl): an `identity` map asserts the two ends are the same
/// quantity, so incompatible declared units are a modeling error.
/// `param_to_var` / `conversion_factor` / expression transforms are exempt (the
/// conversion is declared, or the mapping does not imply unit equivalence at the
/// site), and a missing or empty unit on either side is the valid (unchecked)
/// case.
fn check_variable_map_units(file: &EsmFile) -> Result<(), FlattenError> {
    let Some(entries) = &file.coupling else {
        return Ok(());
    };
    for entry in entries {
        let CouplingEntry::VariableMap {
            from,
            to,
            transform,
            ..
        } = entry
        else {
            continue;
        };
        if transform.as_named() != Some("identity") {
            continue;
        }
        let (Some(source_units), Some(target_units)) = (
            lookup_variable_units(file, from),
            lookup_variable_units(file, to),
        ) else {
            continue;
        };
        if source_units.is_empty() || target_units.is_empty() {
            continue;
        }
        if source_units != target_units {
            return Err(FlattenError::DomainUnitMismatch {
                variable: from.clone(),
                source_units,
                target_units,
            });
        }
    }
    Ok(())
}

/// Look up a dot-qualified variable's declared units across models, subsystems,
/// and reaction systems (species + parameters). Returns `None` when the
/// variable is missing or carries no declared units. Mirrors Julia's
/// `_lookup_variable_units` (coupling_apply.jl).
pub(crate) fn lookup_variable_units(file: &EsmFile, qualified: &str) -> Option<String> {
    let (root, tail) = qualified.split_once('.')?;
    if let Some(models) = &file.models
        && let Some(model) = models.get(root)
    {
        return lookup_model_units(model, tail);
    }
    if let Some(rsystems) = &file.reaction_systems
        && let Some(rsys) = rsystems.get(root)
    {
        return lookup_rsys_units(rsys, tail);
    }
    None
}

/// Resolve a variable's declared units within a [`Model`], recursing into
/// Model subsystems for nested names like `"Inner.T"`. A present variable's
/// units are returned as-is (possibly `None`); the subsystem recursion is only
/// tried when the variable is absent from this model's own `variables`.
fn lookup_model_units(model: &Model, name: &str) -> Option<String> {
    if let Some(var) = model.variables.get(name) {
        return var.units.clone();
    }
    if let Some((head, rest)) = name.split_once('.')
        && let Some(subs) = &model.subsystems
        && let Some(sub_val) = subs.get(head)
        && let Ok(sub_model) = serde_json::from_value::<Model>(sub_val.clone())
    {
        return lookup_model_units(&sub_model, rest);
    }
    None
}

/// Resolve a variable's declared units within a [`ReactionSystem`] — species
/// first, then parameters, then nested subsystems — mirroring Julia's
/// `_lookup_rsys_units`.
fn lookup_rsys_units(rsys: &ReactionSystem, name: &str) -> Option<String> {
    if let Some(sp) = rsys.species.get(name) {
        return sp.units.clone();
    }
    if let Some(p) = rsys.parameters.get(name) {
        return p.units.clone();
    }
    if let Some((head, rest)) = name.split_once('.')
        && let Some(subs) = &rsys.subsystems
        && let Some(sub_val) = subs.get(head)
        && let Ok(sub_rsys) = serde_json::from_value::<ReactionSystem>(sub_val.clone())
    {
        return lookup_rsys_units(&sub_rsys, rest);
    }
    None
}

// ============================================================================
// Scoped-reference `ic` classification (esm-spec §11.4.1)
// ============================================================================

/// If `lhs` is `ic(target)` — an `ic` operator over a single variable argument —
/// return the target state name, else `None`. `pub(crate)` so the single-model
/// array-compile path ([`crate::simulate_array::ArrayCompiled::from_model`])
/// classifies `ic` equations identically to this flatten pass.
pub(crate) fn extract_ic_target(lhs: &Expr) -> Option<String> {
    let Expr::Operator(node) = lhs else {
        return None;
    };
    if node.op != "ic" || node.args.len() != 1 {
        return None;
    }
    match &node.args[0] {
        Expr::Variable(v) => Some(v.clone()),
        _ => None,
    }
}

// ============================================================================
// Pointwise spatial lift of merged state ODEs (esm-spec §10.5)
// ============================================================================
//
// Reaction ODE-gen and `operator_compose` both run at the AST level and IN THAT
// ORDER (reactions → generic `D(sp)=Σ terms`, then `operator_compose` merges each
// species' reaction ODE with the spatial operator's advection contribution). What
// operator_compose does NOT do is array-ify the result: the merged
// `D(sp) = <reaction in scalar sp> + <-u·makearray(grad(sp))>` still has a SCALAR
// `sp` while its advection `makearray` indexes `sp` per grid cell. This pass
// performs the `lifting:"pointwise"` promotion — it wraps each such merged state
// ODE in an `aggregate` over the grid, indexing the bare reaction species per cell
// and each operator makearray per cell, so the reaction network runs pointwise on
// the grid through the existing array evaluator. Mirrors the Julia reference
// `_apply_pointwise_lift!` (flatten.jl).

/// Collect every `makearray` node reachable from `expr`.
fn collect_makearrays<'a>(acc: &mut Vec<&'a ExpressionNode>, expr: &'a Expr) {
    let Expr::Operator(node) = expr else {
        return;
    };
    if node.op == "makearray" {
        acc.push(node);
    }
    for a in &node.args {
        collect_makearrays(acc, a);
    }
    if let Some(e) = &node.expr {
        collect_makearrays(acc, e);
    }
    if let Some(vs) = &node.values {
        for v in vs {
            collect_makearrays(acc, v);
        }
    }
}

/// First `Variable` leaf name in an index-argument expression (the loop variable
/// of that index position), or `None` for a constant position.
fn index_arg_loop(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Variable(v) => Some(v.clone()),
        Expr::Operator(node) => {
            for a in &node.args {
                if let Some(v) = index_arg_loop(a) {
                    return Some(v);
                }
            }
            None
        }
        _ => None,
    }
}

/// Determine the ordered spatial loop variables of a lowered spatial operator by
/// reading an `index(<lifted species>, a1, …, aRank)` gather inside `ma` whose
/// every position carries a loop variable (the interior stencil). Returns the
/// loop names in index-position (dim) order, or `None`.
fn detect_lift_loops(
    ma: &ExpressionNode,
    lifted: &HashSet<String>,
    rank: usize,
) -> Option<Vec<String>> {
    fn walk(expr: &Expr, lifted: &HashSet<String>, rank: usize, out: &mut Option<Vec<String>>) {
        if out.is_some() {
            return;
        }
        let Expr::Operator(node) = expr else {
            return;
        };
        if node.op == "index"
            && node.args.len() == rank + 1
            && let Some(Expr::Variable(name)) = node.args.first()
            && lifted.contains(name)
        {
            let mut loops = Vec::with_capacity(rank);
            let mut ok = true;
            for a in node.args.iter().skip(1) {
                match index_arg_loop(a) {
                    Some(lv) => loops.push(lv),
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if ok {
                *out = Some(loops);
                return;
            }
        }
        for a in &node.args {
            walk(a, lifted, rank, out);
        }
        if let Some(e) = &node.expr {
            walk(e, lifted, rank, out);
        }
        if let Some(vs) = &node.values {
            for v in vs {
                walk(v, lifted, rank, out);
            }
        }
    }
    let mut out = None;
    for a in &ma.args {
        walk(a, lifted, rank, &mut out);
    }
    if let Some(vs) = &ma.values {
        for v in vs {
            walk(v, lifted, rank, &mut out);
        }
    }
    out
}

/// Per-dimension grid extent of a lowered spatial operator: the largest cell
/// index addressed in each `regions` dimension.
fn makearray_extents(ma: &ExpressionNode) -> Vec<i64> {
    let Some(regions) = &ma.regions else {
        return Vec::new();
    };
    let Some(first) = regions.first() else {
        return Vec::new();
    };
    let rank = first.len();
    let mut ext = vec![0i64; rank];
    for region in regions {
        if region.len() != rank {
            continue;
        }
        for (d, r) in region.iter().enumerate() {
            // An unfolded bound contributes no extent (it cannot: §9.7.6 folds
            // every bound to an integer before this pass runs).
            if let Some(hi) = r[1].as_i64() {
                ext[d] = ext[d].max(hi);
            }
        }
    }
    ext
}

/// Rewrite a scalar (merged reaction + operator) RHS into its per-cell form over
/// the spatial `loops`: a bare reference to an array variable becomes
/// `index(var, loops…)`, and each spatial-operator `makearray` becomes
/// `index(makearray, loops…)` (its region values already index per cell).
/// Self-contained nodes (`index`/`aggregate`/`arrayop`) are left untouched;
/// elementwise ops recurse.
fn lift_rhs_to_cell(expr: &Expr, arrayvars: &HashSet<String>, loops: &[String]) -> Expr {
    match expr {
        Expr::Variable(name) if arrayvars.contains(name) => index_node(name, loops),
        Expr::Variable(_) | Expr::Number(_) | Expr::Integer(_) => expr.clone(),
        Expr::Operator(node) => {
            if node.op == "makearray" {
                return index_makearray(node, loops);
            }
            if matches!(node.op.as_str(), "index" | "aggregate" | "arrayop") {
                return expr.clone();
            }
            let mut out = ExpressionNode::clone(node);
            out.args = node
                .args
                .iter()
                .map(|a| lift_rhs_to_cell(a, arrayvars, loops))
                .collect();
            Expr::operator(out)
        }
    }
}

/// Build `index(name, loops…)`.
fn index_node(name: &str, loops: &[String]) -> Expr {
    let mut args = Vec::with_capacity(loops.len() + 1);
    args.push(Expr::Variable(name.to_string()));
    for l in loops {
        args.push(Expr::Variable(l.clone()));
    }
    Expr::operator(ExpressionNode {
        op: "index".to_string(),
        args,
        ..Default::default()
    })
}

/// Build `index(<makearray>, loops…)`.
fn index_makearray(ma: &ExpressionNode, loops: &[String]) -> Expr {
    let mut args = Vec::with_capacity(loops.len() + 1);
    args.push(Expr::operator(ma.clone()));
    for l in loops {
        args.push(Expr::Variable(l.clone()));
    }
    Expr::operator(ExpressionNode {
        op: "index".to_string(),
        args,
        ..Default::default()
    })
}

/// Pointwise spatial lift (esm-spec §10.5). Promotes every state ODE that
/// `operator_compose` merged with a spatial operator (its merged RHS carries an
/// operator `makearray`) from a 0-D scalar to the operator's grid shape, and
/// rewrites the equation into an `aggregate` over the grid. `loaded_producers`
/// maps loaded field name → rank; a producer whose rank equals the grid rank is
/// indexed per cell alongside the lifted species.
fn apply_pointwise_lift(
    equations: &mut [Equation],
    state_variables: &mut IndexMap<String, ModelVariable>,
    lifted_shapes: &mut IndexMap<String, Vec<i64>>,
    loaded_producers: &HashMap<String, usize>,
) -> Result<(), FlattenError> {
    // A species is lifted iff its state ODE's merged RHS carries a spatial-operator
    // makearray (the advection contribution operator_compose added).
    let mut lifted: HashSet<String> = HashSet::new();
    for eq in equations.iter() {
        let Some(species) = extract_ddt_dependent(&eq.lhs) else {
            continue;
        };
        let mut mas: Vec<&ExpressionNode> = Vec::new();
        collect_makearrays(&mut mas, &eq.rhs);
        if !mas.is_empty() {
            lifted.insert(species);
        }
    }
    if lifted.is_empty() {
        return Ok(());
    }

    for eq in equations.iter_mut() {
        let Some(species) = extract_ddt_dependent(&eq.lhs) else {
            continue;
        };
        if !lifted.contains(&species) {
            continue;
        }
        let mut mas: Vec<&ExpressionNode> = Vec::new();
        collect_makearrays(&mut mas, &eq.rhs);
        let Some(first_ma) = mas.first() else {
            continue;
        };
        let regions = match &first_ma.regions {
            Some(r) if !r.is_empty() => r,
            _ => continue,
        };
        let rank = regions[0].len();

        // Loop variables of the grid iteration, read from an interior stencil.
        let mut loops: Option<Vec<String>> = None;
        for ma in &mas {
            loops = detect_lift_loops(ma, &lifted, rank);
            if loops.is_some() {
                break;
            }
        }
        // No full-rank interior-stencil gather in any operator makearray → the
        // grid loop variables are unknown, so the merged reaction/operator ODE
        // cannot be array-ified onto the operator grid. Mirrors the Julia /
        // Python `DimensionPromotionError` message for this same case
        // (pointwise_lift.jl `_pointwise_lift_loops`, flatten.py).
        let loops = loops.ok_or_else(|| FlattenError::DimensionPromotion {
            message: format!(
                "pointwise lift: could not determine the spatial loop variables \
                 for species '{species}' from its operator makearray"
            ),
        })?;

        let extents = makearray_extents(first_ma);
        // The post-lift grid shape, recorded as a first-class flattened field
        // (esm-libraries-spec §4.7.5 step 4 `lifted_shapes`) so a consumer need
        // not re-infer it from the lifted equations' index use.
        lifted_shapes.insert(species.clone(), extents.clone());

        // Operands to index per cell: the lifted species plus any loaded producer
        // whose rank matches the grid rank (e.g. a grid-shaped wind field).
        let mut arrayvars: HashSet<String> = lifted.clone();
        for (name, r) in loaded_producers {
            if *r == rank {
                arrayvars.insert(name.clone());
            }
        }

        // Grid ranges: dense `[1, extent]` intervals keyed by the loop symbols.
        let mut ranges: HashMap<String, RangeSpec> = HashMap::new();
        for (d, loop_name) in loops.iter().enumerate() {
            ranges.insert(loop_name.clone(), RangeSpec::Interval([1, extents[d]]));
        }

        // The species' DECLARED shape is left alone. A synthetic `_lift_<loop>`
        // axis used to be written here so downstream consumers saw an array
        // state, but that fabricates a `shape` the document never declared —
        // and step 4 requires each map to carry the DECLARED variable. The real
        // post-lift grid shape now travels in `lifted_shapes` above, which is
        // the field the spec provides for exactly this, and the array simulator
        // infers the concrete extent from the lifted equations regardless.
        let _ = &state_variables;

        let idx_species = index_node(&species, &loops);
        let d_body = Expr::operator(ExpressionNode {
            op: "D".to_string(),
            args: vec![idx_species],
            wrt: Some("t".to_string()),
            ..Default::default()
        });
        let new_lhs = Expr::operator(ExpressionNode {
            op: "aggregate".to_string(),
            output_idx: Some(loops.clone()),
            ranges: Some(ranges.clone()),
            expr: Some(Box::new(d_body)),
            ..Default::default()
        });
        let new_rhs = Expr::operator(ExpressionNode {
            op: "aggregate".to_string(),
            output_idx: Some(loops.clone()),
            ranges: Some(ranges),
            expr: Some(Box::new(lift_rhs_to_cell(&eq.rhs, &arrayvars, &loops))),
            ..Default::default()
        });
        eq.lhs = new_lhs;
        eq.rhs = new_rhs;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Equation, Metadata, Model, ModelVariable, VariableType};
    use std::collections::HashMap;

    fn make_metadata() -> Metadata {
        Metadata {
            name: None,
            description: None,
            authors: None,
            license: None,
            created: None,
            modified: None,
            tags: None,
            references: None,
            system_class: None,
            dae_info: None,
            discretized_from: None,
        }
    }

    fn empty_file() -> EsmFile {
        EsmFile {
            component_templates: None,
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: make_metadata(),
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        }
    }

    #[test]
    fn test_flatten_empty_file_errors() {
        let err = flatten(&empty_file()).unwrap_err();
        assert!(matches!(err, FlattenError::Empty));
    }

    #[test]
    fn test_flatten_single_model_namespaces_variables() {
        let mut vars = IndexMap::new();
        vars.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::Unknown,
                units: Some("m".to_string()),
                default: Some(0.0),
                default_units: None,
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );
        vars.insert(
            "k".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: None,
                default: Some(1.0),
                default_units: None,
                description: None,
                shape: None,
                location: None,
                distribution: None,
                update: None,
            },
        );

        let mut models = IndexMap::new();
        models.insert(
            "sys".to_string(),
            Model {
                name: Some("System".to_string()),
                subsystems: None,
                reference: None,
                variables: vars,
                equations: vec![Equation {
                    lhs: Expr::operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("k".to_string()),
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let file = EsmFile {
            component_templates: None,
            coordinates: None,
            coupling_roles: None,
            models: Some(models),
            ..empty_file()
        };

        let flat = flatten(&file).unwrap();
        assert_eq!(flat.independent_variables, vec!["t".to_string()]);
        assert!(flat.state_variables.contains_key("sys.x"));
        assert!(flat.parameters.contains_key("sys.k"));
        assert_eq!(flat.equations.len(), 1);
        assert_eq!(
            extract_ddt_dependent(&flat.equations[0].lhs).unwrap(),
            "sys.x"
        );
        assert_eq!(flat.equations[0].rhs, Expr::Variable("sys.k".to_string()));
        assert_eq!(flat.metadata.source_systems, vec!["sys".to_string()]);
    }

    // gt-vx74: `t` is the global independent variable and must stay bare
    // after flatten (never `sys.t`). Observed expressions in tests/simulation
    // fixtures — notably python_scipy_integration.esm's ExponentialDecay
    // analytical_solution — reference `t` directly, and the downstream
    // resolver only recognizes bare `t` as [`ResolvedExpr::Time`].
    #[test]
    fn test_namespace_expr_preserves_bare_t() {
        let expr = Expr::operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![
                Expr::Variable("decay_rate".to_string()),
                Expr::Variable("t".to_string()),
            ],
            ..Default::default()
        });
        let out = namespace_expr(&expr, "ExponentialDecay", &HashSet::new(), &HashSet::new());
        match out {
            Expr::Operator(node) => {
                assert_eq!(
                    node.args[0],
                    Expr::Variable("ExponentialDecay.decay_rate".to_string())
                );
                assert_eq!(node.args[1], Expr::Variable("t".to_string()));
            }
            _ => panic!("expected operator node"),
        }
    }

    // ---- Test helpers for the variable_map unit check + pointwise lift ----

    fn var(vt: VariableType, units: Option<&str>) -> ModelVariable {
        ModelVariable {
            var_type: vt,
            units: units.map(|u| u.to_string()),
            default: None,
            default_units: None,
            description: None,
            shape: None,
            location: None,
            distribution: None,
            update: None,
        }
    }

    fn ddt(target: &str, rhs: Expr) -> Equation {
        Equation {
            lhs: Expr::operator(ExpressionNode {
                op: "D".to_string(),
                args: vec![Expr::Variable(target.to_string())],
                wrt: Some("t".to_string()),
                ..Default::default()
            }),
            rhs,
        }
    }

    fn make_model(vars: Vec<(&str, ModelVariable)>, equations: Vec<Equation>) -> Model {
        let mut variables = IndexMap::new();
        for (name, v) in vars {
            variables.insert(name.to_string(), v);
        }
        Model {
            name: None,
            subsystems: None,
            reference: None,
            variables,
            equations,
            discrete_events: None,
            continuous_events: None,
            description: None,
            tolerance: None,
            tests: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        }
    }

    /// Two models coupled by an `identity` variable_map from `src.T` (units
    /// `from_units`) onto the parameter `dst.temp` (units `to_units`).
    fn identity_map_file(from_units: Option<&str>, to_units: Option<&str>) -> EsmFile {
        let src = make_model(
            vec![("T", var(VariableType::Unknown, from_units))],
            vec![ddt("T", Expr::Number(0.0))],
        );
        let dst = make_model(
            vec![
                ("temp", var(VariableType::Parameter, to_units)),
                ("y", var(VariableType::Unknown, Some("K"))),
            ],
            vec![ddt("y", Expr::Variable("temp".to_string()))],
        );
        let mut models = IndexMap::new();
        models.insert("src".to_string(), src);
        models.insert("dst".to_string(), dst);

        EsmFile {
            component_templates: None,
            coordinates: None,
            models: Some(models),
            coupling: Some(vec![CouplingEntry::VariableMap {
                from: "src.T".to_string(),
                to: "dst.temp".to_string(),
                transform: VariableMapTransform::Named("identity".to_string()),
                factor: None,
                description: None,
            }]),
            ..empty_file()
        }
    }

    // C1: an `identity` variable_map bridging a K-unit source and a degC-unit
    // target (both declared, non-empty, differing) raises DomainUnitMismatch —
    // mirrors Julia's `_check_variable_map_units`.
    #[test]
    fn test_variable_map_identity_unit_mismatch_errors() {
        let file = identity_map_file(Some("K"), Some("degC"));
        match flatten(&file).unwrap_err() {
            FlattenError::DomainUnitMismatch {
                variable,
                source_units,
                target_units,
            } => {
                assert_eq!(variable, "src.T");
                assert_eq!(source_units, "K");
                assert_eq!(target_units, "degC");
            }
            other => panic!("expected DomainUnitMismatch, got {other:?}"),
        }
    }

    // C1: matching declared units under `identity` is the valid case — no error.
    #[test]
    fn test_variable_map_identity_matching_units_ok() {
        let file = identity_map_file(Some("K"), Some("K"));
        assert!(flatten(&file).is_ok());
    }

    // C1: an absent unit on either side is exempt (the unchecked valid case),
    // even when the other side declares one.
    #[test]
    fn test_variable_map_identity_missing_unit_ok() {
        assert!(flatten(&identity_map_file(None, Some("degC"))).is_ok());
        assert!(flatten(&identity_map_file(Some("K"), None)).is_ok());
    }

    // C2: a pointwise-lift merged ODE whose operator makearray carries no
    // full-rank interior-stencil `index(...)` gather cannot resolve its grid
    // loop variables, and now surfaces DimensionPromotion (the reserved variant,
    // reused here for cross-binding parity) rather than the removed
    // PointwiseLiftFailed.
    #[test]
    fn test_pointwise_lift_failure_yields_dimension_promotion() {
        let makearray = Expr::operator(ExpressionNode {
            op: "makearray".to_string(),
            regions: Some(vec![vec![[
                crate::types::RegionBound::Int(1),
                crate::types::RegionBound::Int(3),
            ]]]),
            // Constant body — no `index(C, i)` interior stencil to read loops from.
            args: vec![Expr::Number(0.0)],
            ..Default::default()
        });
        let mut equations = vec![ddt("C", makearray)];
        let mut state_variables: IndexMap<String, ModelVariable> = IndexMap::new();
        state_variables.insert("C".to_string(), var(VariableType::Unknown, None));
        let loaded_producers: HashMap<String, usize> = HashMap::new();

        let mut lifted_shapes: IndexMap<String, Vec<i64>> = IndexMap::new();
        let err = apply_pointwise_lift(
            &mut equations,
            &mut state_variables,
            &mut lifted_shapes,
            &loaded_producers,
        )
        .unwrap_err();
        match err {
            FlattenError::DimensionPromotion { message } => {
                assert!(message.contains("pointwise lift"), "message: {message}");
                assert!(message.contains("'C'"), "message: {message}");
            }
            other => panic!("expected DimensionPromotion, got {other:?}"),
        }
    }

    // Bug F regression: the unlowered-operator gate must descend into
    // expression-bearing sidecar fields, not merely `args`. A spatial/sugar op
    // buried in an `aggregate.expr` body — unreachable from `args` — previously
    // escaped `reject_spatial_operators` entirely. It must now be rejected with
    // the byte-identical `UnloweredOperator` diagnostic.
    #[test]
    fn test_reject_spatial_operator_hidden_in_aggregate_body() {
        let grad = Expr::operator(ExpressionNode {
            op: "grad".to_string(),
            args: vec![Expr::Variable("u".to_string())],
            ..Default::default()
        });
        let aggregate = Expr::operator(ExpressionNode {
            op: "aggregate".to_string(),
            // Nothing reachable through `args`; the op lives only in `expr`.
            args: vec![],
            expr: Some(Box::new(grad)),
            output_idx: Some(vec!["i".to_string()]),
            reduce: Some("+".to_string()),
            ..Default::default()
        });
        let err = reject_spatial_operators(&aggregate).unwrap_err();
        assert!(
            matches!(&err, FlattenError::UnloweredOperator { op } if op == "grad"),
            "expected UnloweredOperator{{grad}}, got {err:?}"
        );

        // A spatial `D` (wrt a spatial axis) hidden in a `filter` predicate is
        // likewise caught now that recursion goes through `for_each_child`.
        let spatial_d = Expr::operator(ExpressionNode {
            op: "D".to_string(),
            args: vec![Expr::Variable("u".to_string())],
            wrt: Some("x".to_string()),
            ..Default::default()
        });
        let filtered = Expr::operator(ExpressionNode {
            op: "aggregate".to_string(),
            args: vec![Expr::Variable("w".to_string())],
            filter: Some(Box::new(spatial_d)),
            reduce: Some("+".to_string()),
            ..Default::default()
        });
        let err = reject_spatial_operators(&filtered).unwrap_err();
        assert!(
            matches!(&err, FlattenError::UnloweredOperator { op } if op == "D"),
            "expected UnloweredOperator{{D}}, got {err:?}"
        );
    }

    // Bug E regression: `namespace_expr_scoped` must namespace variable
    // references inside an aggregate grouping `key` (a sidecar the previous
    // hand-rolled field enumeration omitted), while still honoring the bound
    // loop indices introduced by `output_idx`.
    #[test]
    fn test_namespace_expr_covers_aggregate_key() {
        let key = Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![
                // A model variable — must be namespaced.
                Expr::Variable("region".to_string()),
                // A bound loop index — must stay bare.
                Expr::Variable("i".to_string()),
            ],
            ..Default::default()
        });
        let aggregate = Expr::operator(ExpressionNode {
            op: "aggregate".to_string(),
            args: vec![Expr::Variable("w".to_string())],
            output_idx: Some(vec!["i".to_string()]),
            key: Some(Box::new(key)),
            reduce: Some("+".to_string()),
            ..Default::default()
        });
        let out = namespace_expr(&aggregate, "sys", &HashSet::new(), &HashSet::new());
        match out {
            Expr::Operator(node) => {
                assert_eq!(node.args[0], Expr::Variable("sys.w".to_string()));
                let key = node.key.clone().expect("aggregate key preserved");
                match *key {
                    Expr::Operator(k) => {
                        assert_eq!(k.args[0], Expr::Variable("sys.region".to_string()));
                        assert_eq!(k.args[1], Expr::Variable("i".to_string()));
                    }
                    other => panic!("expected operator key, got {other:?}"),
                }
            }
            other => panic!("expected operator node, got {other:?}"),
        }
    }
}
