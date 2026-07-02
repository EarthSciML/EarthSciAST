//! Coupled system flattening per spec §4.7.5 + §4.7.6 (Rust Core tier).
//!
//! This module implements [`flatten`] — the canonical pipeline that turns an
//! [`EsmFile`] with multiple coupled components into a single [`FlattenedSystem`]
//! with dot-namespaced variables and real [`Expr`]-tree equations.
//!
//! The Rust implementation targets the **Core tier** only: it supports
//! `broadcast` and `identity` dimension mappings and raises
//! [`FlattenError::UnsupportedMapping`] if the source file requires `slice`,
//! `project`, or `regrid`. Unlowered rewrite-target operators (the sugar ops
//! `grad` / `div` / `laplacian` / `curl` / `∇`, or a spatial `D` with
//! `wrt != "t"`) raise [`FlattenError::UnloweredOperator`] with the uniform
//! `unlowered_operator` code (esm-spec §4.2 / §9.6.8): they must be lowered to a
//! stencil by a `match` rewrite rule before evaluation, and the downstream
//! diffsol-backed ODE solver has no evaluator for them. Higher tiers will be
//! added when Rust gains PDE capability.

use crate::types::{
    ContinuousEvent, CouplingEntry, DiscreteEvent, Domain, Equation, EsmFile, Expr, ExpressionNode,
    IndexSet, Model, ModelVariable, RangeSpec, ReactionSystem, VariableType,
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

    /// Dimension promotion could not be completed given the available
    /// interface rules (Core tier).
    #[error("Dimension promotion failed: {message}")]
    DimensionPromotion { message: String },

    /// Two systems of differing dimensionality were coupled without an
    /// `Interface` naming their dimension mapping.
    #[error(
        "Unmapped domain: systems {systems:?} have different dimensionality but no Interface defines their dimension mapping; candidate target domains: {candidate_targets:?}"
    )]
    UnmappedDomain {
        systems: Vec<String>,
        candidate_targets: Vec<String>,
    },

    /// A `dimension_mapping` type or spatial operator that is not supported
    /// at the current (Rust Core) tier was encountered. The specific type
    /// name is included — e.g. `"slice"`, `"project"`, `"regrid"`, `"grad"`.
    #[error(
        "Unsupported mapping type '{mapping_type}' at Rust Core tier (supported: broadcast, identity). Reason: {reason}"
    )]
    UnsupportedMapping {
        mapping_type: String,
        reason: String,
    },

    /// A rewrite-target operator (a spatial / right-hand-side `D`, or the
    /// optional sugar ops `grad` / `div` / `laplacian` / `curl` / `∇`) reached
    /// flattening without being lowered to a stencil by a `match` rewrite rule
    /// (esm-spec §4.2 / §9.6.8). Flattening is part of the compile pipeline, so
    /// this fires before evaluation (loading stays permissive). Carries the
    /// uniform `unlowered_operator` code that supersedes the former per-binding
    /// spatial-operator errors; the scalar / array simulators surface the same
    /// code via [`crate::compile_error::CompileError::UnloweredOperatorError`].
    #[error(
        "unlowered_operator: rewrite-target operator '{op}' reached compilation without being \
         lowered to a stencil by a rewrite rule (esm-spec §4.2 / §9.6.8). Discretization rules \
         live in EarthSciDiscretizations, not this format."
    )]
    UnloweredOperator { op: String },

    /// Incompatible units across a shared independent variable.
    #[error(
        "Domain unit mismatch on independent variable '{variable}': source units '{source_units}' vs target units '{target_units}'"
    )]
    DomainUnitMismatch {
        variable: String,
        source_units: String,
        target_units: String,
    },

    /// Coordinate extent mismatch on a shared independent variable under the
    /// `identity` mapping.
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

    /// Wrapped reaction-lowering failure.
    #[error("Reaction lowering failed: {0}")]
    Reaction(#[from] crate::reactions::DeriveError),

    /// The file contains no models or reaction systems to flatten.
    #[error("No models or reaction systems to flatten")]
    Empty,
}

// ============================================================================
// Output types — spec §4.7.5 FlattenedSystem shape
// ============================================================================

/// Record of a dimension promotion applied during flattening.
///
/// Populated in [`FlattenMetadata::dimension_promotions_applied`] whenever a
/// `broadcast` or `identity` mapping rewrites a variable onto a different
/// spatial domain. Rust Core tier currently only populates this for
/// `broadcast` (identity is a no-op) and only if the source file defines
/// matching spatial domains — a practical no-op for the ODE-only Rust v1.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DimensionPromotionRecord {
    pub variable: String,
    pub source_domain: String,
    pub target_domain: String,
    /// `"broadcast"` | `"identity"` — slice/project/regrid raise
    /// [`FlattenError::UnsupportedMapping`] instead of being recorded here.
    pub mapping_type: String,
}

/// Provenance metadata for a flattening pipeline run.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FlattenMetadata {
    /// Names of every component system that contributed equations.
    pub source_systems: Vec<String>,
    /// Human-readable descriptions of the coupling rules applied, in order.
    pub coupling_rules_applied: Vec<String>,
    /// Every dimension promotion applied during flattening (Core tier:
    /// broadcast and identity).
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
    /// Independent variables. `["t"]` for pure ODE — Rust v1 only ever
    /// produces this, since PDE output raises [`FlattenError::UnsupportedMapping`].
    pub independent_variables: Vec<String>,
    /// Dot-namespaced state variables with full metadata.
    pub state_variables: IndexMap<String, ModelVariable>,
    /// Dot-namespaced parameters. `variable_map` with `param_to_var` or
    /// `conversion_factor` transform removes entries from this map.
    pub parameters: IndexMap<String, ModelVariable>,
    /// Dot-namespaced observed variables.
    pub observed_variables: IndexMap<String, ModelVariable>,
    /// Dot-namespaced brownian noise sources (Wiener processes). Non-empty
    /// implies the flattened system is an SDE rather than an ODE — runtimes
    /// that consume this should target an SDESystem (Julia/MTK) or equivalent.
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub brownian_variables: IndexMap<String, ModelVariable>,
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
    /// Provenance metadata.
    pub metadata: FlattenMetadata,
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
/// 3. Reject spatial operators and unsupported dimension mappings
///    ([`FlattenError::UnsupportedMapping`]).
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
    let has_models = file.models.as_ref().is_some_and(|m| !m.is_empty());
    let has_rs = file
        .reaction_systems
        .as_ref()
        .is_some_and(|rs| !rs.is_empty());

    if !has_models && !has_rs {
        return Err(FlattenError::Empty);
    }

    // Phase 1: collect per-system lowered equations and namespaced variables.
    let mut source_systems = Vec::new();
    let mut per_system: Vec<SystemBlock> = Vec::new();

    // Models first (spec §4.7.5 step 2) — sorted for deterministic output.
    if let Some(models) = &file.models {
        let mut keys: Vec<&String> = models.keys().collect();
        keys.sort();
        for name in keys {
            let block = build_model_block(name, &models[name])?;
            source_systems.push(name.clone());
            per_system.push(block);
        }
    }

    // Reaction systems next — lowered to ODE equations then namespaced.
    if let Some(rsystems) = &file.reaction_systems {
        let mut keys: Vec<&String> = rsystems.keys().collect();
        keys.sort();
        for name in keys {
            let block = build_reaction_block(name, &rsystems[name])?;
            source_systems.push(name.clone());
            per_system.push(block);
        }
    }

    // Phase 2: reject spatial operators in any equation (Core tier = ODE only).
    for block in &per_system {
        for eq in &block.equations {
            reject_spatial_operators(&eq.lhs)?;
            reject_spatial_operators(&eq.rhs)?;
        }
    }

    // Phase 3: apply coupling rules, collecting rule descriptions.
    let mut coupling_rules_applied = Vec::new();
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

    if let Some(entries) = &file.coupling {
        for entry in entries {
            apply_coupling_entry(entry, &mut per_system, &mut coupling_rules_applied)?;
        }
    }

    // Phase 4: conflict detection after coupling — every pair of equations
    // with the same D(X, t) LHS across systems that were NOT jointly named
    // in an operator_compose entry is a ConflictingDerivative.
    let mut lhs_targets: IndexMap<String, Vec<String>> = IndexMap::new();
    for block in &per_system {
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

    // Phase 5: collect into the final FlattenedSystem.
    let mut state_variables: IndexMap<String, ModelVariable> = IndexMap::new();
    let mut parameters: IndexMap<String, ModelVariable> = IndexMap::new();
    let mut observed_variables: IndexMap<String, ModelVariable> = IndexMap::new();
    let mut brownian_variables: IndexMap<String, ModelVariable> = IndexMap::new();
    let mut equations: Vec<Equation> = Vec::new();
    let mut continuous_events: Vec<ContinuousEvent> = Vec::new();
    let mut discrete_events: Vec<DiscreteEvent> = Vec::new();

    // Scoped-reference / array `ic` equations (esm-spec §11.4.1) are classified
    // out of the ordinary equation list here — the downstream simulator folds
    // them into `u0` from the data-Provider seam rather than treating them as
    // state ODEs. Collected as `(target_state, rhs)`.
    let mut field_ics: Vec<(String, Expr)> = Vec::new();

    for block in per_system {
        for (name, var) in block.state_vars {
            state_variables.insert(name, var);
        }
        for (name, var) in block.parameters {
            parameters.insert(name, var);
        }
        for (name, var) in block.observed_vars {
            observed_variables.insert(name, var);
        }
        for (name, var) in block.brownian_vars {
            brownian_variables.insert(name, var);
        }
        for eq in block.equations {
            if let Some(target) = extract_ic_target(&eq.lhs) {
                field_ics.push((target, eq.rhs));
            } else {
                equations.push(eq);
            }
        }
        continuous_events.extend(block.continuous_events);
        discrete_events.extend(block.discrete_events);
    }

    // Apply post-collection variable_map parameter removals. A `param_to_var`
    // that binds a LOADED field (its producer's owning system is a top-level
    // `data_loaders` entry) onto a grid-shaped consumer parameter records the
    // producer name + rank so the pointwise lift indexes the loaded field per
    // grid cell (esm-spec §11.5 "BCs from data"). The loaded producer is NOT
    // added to `parameters`: it is served at runtime through the data-Provider
    // forcing seam, not as a scalar parameter (which the array evaluator would
    // otherwise resolve ahead of the forcing buffer).
    let loader_names: HashSet<String> = file
        .data_loaders
        .as_ref()
        .map(|dl| dl.keys().cloned().collect())
        .unwrap_or_default();
    let mut loaded_producers: HashMap<String, usize> = HashMap::new();
    if let Some(entries) = &file.coupling {
        for entry in entries {
            if let CouplingEntry::VariableMap {
                from,
                to,
                transform,
                ..
            } = entry
                && matches!(transform.as_str(), "param_to_var" | "conversion_factor")
            {
                let consumer_shape_rank = parameters
                    .get(to)
                    .and_then(|v| v.shape.as_ref())
                    .map(|s| s.len())
                    .filter(|r| *r > 0);
                parameters.shift_remove(to);
                let from_owner = from.split('.').next().unwrap_or("");
                if let Some(rank) = consumer_shape_rank
                    && loader_names.contains(from_owner)
                    && !parameters.contains_key(from)
                {
                    loaded_producers.insert(from.clone(), rank);
                }
            }
        }
    }

    // Step 5b: pointwise spatial lift (esm-spec §10.5). `operator_compose` has
    // merged each reaction/model state ODE with the spatial operator's advection
    // makearray; array-ify those merged equations onto the operator's grid so the
    // lifted reaction network runs pointwise. No-op unless an `operator_compose`
    // entry declares `lifting: "pointwise"` and a merged equation carries an
    // operator makearray.
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
        apply_pointwise_lift(&mut equations, &mut state_variables, &loaded_producers)?;
    }

    Ok(FlattenedSystem {
        independent_variables: vec!["t".to_string()],
        state_variables,
        parameters,
        observed_variables,
        brownian_variables,
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
        metadata: FlattenMetadata {
            source_systems,
            coupling_rules_applied,
            dimension_promotions_applied: Vec::new(),
            implicit_interface_inferred: false,
        },
    })
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

    let mut models = std::collections::HashMap::new();
    models.insert(system_name, model.clone());

    let file = EsmFile {
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
        data_loaders: None,
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
    parameters: IndexMap<String, ModelVariable>,
    observed_vars: IndexMap<String, ModelVariable>,
    brownian_vars: IndexMap<String, ModelVariable>,
    equations: Vec<Equation>,
    continuous_events: Vec<ContinuousEvent>,
    discrete_events: Vec<DiscreteEvent>,
}

fn build_model_block(system_name: &str, model: &Model) -> Result<SystemBlock, FlattenError> {
    let mut state_vars = IndexMap::new();
    let mut parameters = IndexMap::new();
    let mut observed_vars = IndexMap::new();
    let mut brownian_vars = IndexMap::new();

    let mut var_names: Vec<&String> = model.variables.keys().collect();
    var_names.sort();
    for var_name in var_names {
        let var = &model.variables[var_name];
        let namespaced = format!("{system_name}.{var_name}");
        let mut cloned = var.clone();
        if let Some(expr) = cloned.expression {
            cloned.expression = Some(namespace_expr(&expr, system_name));
        }
        match var.var_type {
            VariableType::State => {
                state_vars.insert(namespaced, cloned);
            }
            VariableType::Parameter => {
                parameters.insert(namespaced, cloned);
            }
            VariableType::Observed => {
                observed_vars.insert(namespaced, cloned);
            }
            VariableType::Brownian => {
                brownian_vars.insert(namespaced, cloned);
            }
        }
    }

    let equations: Vec<Equation> = model
        .equations
        .iter()
        .map(|eq| Equation {
            lhs: namespace_expr(&eq.lhs, system_name),
            rhs: namespace_expr(&eq.rhs, system_name),
        })
        .collect();

    let continuous_events = model
        .continuous_events
        .clone()
        .unwrap_or_default()
        .into_iter()
        .map(|e| namespace_continuous_event(e, system_name))
        .collect();
    let discrete_events = model
        .discrete_events
        .clone()
        .unwrap_or_default()
        .into_iter()
        .map(|e| namespace_discrete_event(e, system_name))
        .collect();

    Ok(SystemBlock {
        name: system_name.to_string(),
        state_vars,
        parameters,
        observed_vars,
        brownian_vars,
        equations,
        continuous_events,
        discrete_events,
    })
}

fn build_reaction_block(
    system_name: &str,
    rs: &ReactionSystem,
) -> Result<SystemBlock, FlattenError> {
    let mut state_vars = IndexMap::new();
    let mut parameters = IndexMap::new();

    let mut species_names: Vec<&String> = rs.species.keys().collect();
    species_names.sort();
    for species_name in species_names {
        let species = &rs.species[species_name];
        let namespaced = format!("{system_name}.{species_name}");
        state_vars.insert(
            namespaced,
            ModelVariable {
                var_type: VariableType::State,
                units: species.units.clone(),
                default: species.default,
                description: species.description.clone(),
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );
    }

    let mut param_names: Vec<&String> = rs.parameters.keys().collect();
    param_names.sort();
    for param_name in param_names {
        let param = &rs.parameters[param_name];
        let namespaced = format!("{system_name}.{param_name}");
        parameters.insert(
            namespaced,
            ModelVariable {
                var_type: VariableType::Parameter,
                units: param.units.clone(),
                default: param.default,
                description: param.description.clone(),
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );
    }

    let lowered = crate::reactions::lower_reactions_to_equations(&rs.reactions, &rs.species)?;
    let equations = lowered
        .into_iter()
        .map(|eq| Equation {
            lhs: namespace_expr(&eq.lhs, system_name),
            rhs: namespace_expr(&eq.rhs, system_name),
        })
        .collect();

    Ok(SystemBlock {
        name: system_name.to_string(),
        state_vars,
        parameters,
        observed_vars: IndexMap::new(),
        brownian_vars: IndexMap::new(),
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
/// `semiring`, `join`, `shape`, …). Every such field is preserved and the
/// expression-bearing ones are recursively namespaced, so a discretized
/// `arrayop` survives coupling. Loop-index symbols introduced by an enclosing
/// `arrayop`/`aggregate` (`output_idx` + `ranges` keys) or `integral`
/// (`int_var`) are component-local — the array interpreter resolves them
/// positionally against `loop_binds`, never against the variable registry — so
/// they are excluded from namespacing within that node's scope (ess-14f.8).
fn namespace_expr(expr: &Expr, system_name: &str) -> Expr {
    namespace_expr_scoped(expr, system_name, &HashSet::new())
}

fn namespace_expr_scoped(expr: &Expr, system_name: &str, bound: &HashSet<String>) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) => {
            if name.contains('.') || name == "t" || bound.contains(name) {
                Expr::Variable(name.clone())
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

            // Clone to preserve EVERY structural/metadata field verbatim, then
            // re-namespace only the expression-bearing children. The previous
            // `..Default::default()` form silently dropped `expr`, `ranges`,
            // `output_idx`, `reduce`, … — corrupting every array node the
            // moment a model was flattened.
            let mut out = node.clone();
            out.args = node
                .args
                .iter()
                .map(|a| namespace_expr_scoped(a, system_name, &child_bound))
                .collect();
            out.wrt = node.wrt.as_ref().map(|w| {
                if w.contains('.') || w == "t" || child_bound.contains(w) {
                    w.clone()
                } else {
                    format!("{system_name}.{w}")
                }
            });
            out.expr = node
                .expr
                .as_ref()
                .map(|e| Box::new(namespace_expr_scoped(e, system_name, &child_bound)));
            out.filter = node
                .filter
                .as_ref()
                .map(|e| Box::new(namespace_expr_scoped(e, system_name, &child_bound)));
            out.lower = node
                .lower
                .as_ref()
                .map(|e| Box::new(namespace_expr_scoped(e, system_name, &child_bound)));
            out.upper = node
                .upper
                .as_ref()
                .map(|e| Box::new(namespace_expr_scoped(e, system_name, &child_bound)));
            out.values = node.values.as_ref().map(|vs| {
                vs.iter()
                    .map(|v| namespace_expr_scoped(v, system_name, &child_bound))
                    .collect()
            });
            out.axes = node.axes.as_ref().map(|axes| {
                axes.iter()
                    .map(|(k, v)| {
                        (
                            k.clone(),
                            namespace_expr_scoped(v, system_name, &child_bound),
                        )
                    })
                    .collect()
            });
            Expr::Operator(out)
        }
    }
}

fn namespace_continuous_event(mut event: ContinuousEvent, system_name: &str) -> ContinuousEvent {
    event.conditions = event
        .conditions
        .into_iter()
        .map(|c| namespace_expr(&c, system_name))
        .collect();
    event.affects = event
        .affects
        .into_iter()
        .map(|mut a| {
            a.lhs = namespace_plain(&a.lhs, system_name);
            a.rhs = namespace_expr(&a.rhs, system_name);
            a
        })
        .collect();
    if let Some(neg) = event.affect_neg.take() {
        event.affect_neg = Some(
            neg.into_iter()
                .map(|mut a| {
                    a.lhs = namespace_plain(&a.lhs, system_name);
                    a.rhs = namespace_expr(&a.rhs, system_name);
                    a
                })
                .collect(),
        );
    }
    event
}

fn namespace_discrete_event(mut event: DiscreteEvent, system_name: &str) -> DiscreteEvent {
    use crate::types::DiscreteEventTrigger;
    event.trigger = match event.trigger {
        DiscreteEventTrigger::Condition { expression } => DiscreteEventTrigger::Condition {
            expression: namespace_expr(&expression, system_name),
        },
        other => other,
    };
    if let Some(affects) = event.affects.take() {
        event.affects = Some(
            affects
                .into_iter()
                .map(|mut a| {
                    a.lhs = namespace_plain(&a.lhs, system_name);
                    a.rhs = namespace_expr(&a.rhs, system_name);
                    a
                })
                .collect(),
        );
    }
    event
}

fn namespace_plain(name: &str, system_name: &str) -> String {
    if name.contains('.') {
        name.to_string()
    } else {
        format!("{system_name}.{name}")
    }
}

/// Scan an expression-tree RHS and reject any unlowered rewrite-target operator
/// (esm-spec §4.2 / §9.6.8) with the uniform [`FlattenError::UnloweredOperator`]
/// (`unlowered_operator`) code. These are the optional sugar ops
/// `grad` / `div` / `laplacian` / `curl` / `∇`, and a spatial `D` — a `D` whose
/// `wrt` is a spatial axis (e.g. `"x"`, `"lon"`) rather than the time variable
/// `"t"`. `wrt` is now open (any declared differentiation variable); the
/// structural equation-LHS `D(u, t)` stays evaluable-core and is untouched. A
/// rewrite rule must lower these to a stencil before evaluation; this format
/// ships no such rules (they live in EarthSciDiscretizations).
fn reject_spatial_operators(expr: &Expr) -> Result<(), FlattenError> {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => Ok(()),
        Expr::Operator(node) => {
            match node.op.as_str() {
                "grad" | "div" | "laplacian" | "curl" | "∇" => {
                    return Err(FlattenError::UnloweredOperator {
                        op: node.op.clone(),
                    });
                }
                "D" => {
                    // A spatial `D` (`wrt` != "t") is a rewrite-target; only the
                    // structural time derivative `D(_, t)` is evaluable-core.
                    if let Some(wrt) = &node.wrt
                        && wrt != "t"
                    {
                        return Err(FlattenError::UnloweredOperator {
                            op: node.op.clone(),
                        });
                    }
                }
                _ => {}
            }
            for arg in &node.args {
                reject_spatial_operators(arg)?;
            }
            Ok(())
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
            description,
            ..
        } => {
            apply_operator_compose(systems, per_system)?;
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
            apply_couple(systems, connector, per_system);
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
            apply_variable_map(from, to, transform, *factor, per_system);
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
    }
    Ok(())
}

/// Apply an `operator_compose` rule: sum matching `D(x, t) = rhs_A + rhs_B`
/// equations across the listed systems. Per spec §4.7.5 step 3.a + §4.7.1.
fn apply_operator_compose(
    systems: &[String],
    per_system: &mut [SystemBlock],
) -> Result<(), FlattenError> {
    if systems.len() < 2 {
        return Ok(());
    }

    // Gather the indices of the named systems.
    let mut indices: Vec<usize> = Vec::new();
    for wanted in systems {
        if let Some(i) = per_system.iter().position(|b| b.name == *wanted) {
            indices.push(i);
        }
    }
    if indices.len() < 2 {
        return Ok(());
    }

    // Build a map of dependent variable -> (block_idx, equation_idx) for all
    // D(x, t) equations in the participating systems.
    let mut targets: IndexMap<String, Vec<(usize, usize)>> = IndexMap::new();
    for &i in &indices {
        for (j, eq) in per_system[i].equations.iter().enumerate() {
            if let Some(dep) = extract_ddt_dependent(&eq.lhs) {
                targets.entry(dep).or_default().push((i, j));
            }
        }
    }

    // For every dependent variable that appears in more than one participating
    // system, merge the RHS terms into the first listed block's equation and
    // mark the others for removal.
    let mut to_remove: Vec<(usize, usize)> = Vec::new();
    for (_, locations) in &targets {
        if locations.len() < 2 {
            continue;
        }
        let (keeper_block, keeper_eq) = locations[0];
        let mut merged_rhs = per_system[keeper_block].equations[keeper_eq].rhs.clone();
        for &(bi, ei) in &locations[1..] {
            merged_rhs = sum_exprs(merged_rhs, per_system[bi].equations[ei].rhs.clone());
            to_remove.push((bi, ei));
        }
        per_system[keeper_block].equations[keeper_eq].rhs = merged_rhs;
    }

    // Remove merged equations from owning blocks. Sort in reverse to preserve
    // indices during removal.
    to_remove.sort_unstable_by(|a, b| b.cmp(a));
    for (bi, ei) in to_remove {
        per_system[bi].equations.remove(ei);
    }

    Ok(())
}

fn sum_exprs(a: Expr, b: Expr) -> Expr {
    Expr::Operator(ExpressionNode {
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
) {
    let Some(eqs_json) = connector.get("equations").and_then(|e| e.as_array()) else {
        return;
    };
    let block_name = format!("couple({})", systems.join(","));
    let mut new_equations = Vec::new();
    for eq_val in eqs_json {
        let lhs = eq_val
            .get("lhs")
            .cloned()
            .and_then(|v| serde_json::from_value::<Expr>(v).ok());
        let rhs = eq_val
            .get("rhs")
            .cloned()
            .and_then(|v| serde_json::from_value::<Expr>(v).ok());
        if let (Some(lhs), Some(rhs)) = (lhs, rhs) {
            new_equations.push(Equation {
                lhs,
                rhs,
            });
        }
    }
    if !new_equations.is_empty() {
        per_system.push(SystemBlock {
            name: block_name,
            state_vars: IndexMap::new(),
            parameters: IndexMap::new(),
            observed_vars: IndexMap::new(),
            brownian_vars: IndexMap::new(),
            equations: new_equations,
            continuous_events: Vec::new(),
            discrete_events: Vec::new(),
        });
    }
}

/// Apply a `variable_map` rule by substituting `from` for `to` in every
/// equation's expression tree (and scaling by `factor` where applicable).
/// Parameter removal for `param_to_var`/`conversion_factor` happens in the
/// collection phase to keep this function purely expression-rewriting.
fn apply_variable_map(
    from: &str,
    to: &str,
    _transform: &str,
    factor: Option<f64>,
    per_system: &mut [SystemBlock],
) {
    // `factor` is a scaling coefficient; the schema restricts it to the scaling
    // transforms (additive / multiplicative / conversion_factor), so apply it
    // uniformly whenever present. This matches Python and Julia — Rust previously
    // scaled only for `conversion_factor`, silently dropping the factor for
    // additive / multiplicative. A factor of 1.0 is a no-op and left unwrapped.
    // (Parameter removal for param_to_var/conversion_factor is in the collection
    // phase, so this function no longer needs `transform`.)
    let replacement = match factor {
        Some(f) if f != 1.0 => Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![Expr::Variable(from.to_string()), Expr::Number(f)],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
        _ => Expr::Variable(from.to_string()),
    };
    for block in per_system.iter_mut() {
        for eq in &mut block.equations {
            eq.lhs = substitute_var(&eq.lhs, to, &replacement);
            eq.rhs = substitute_var(&eq.rhs, to, &replacement);
        }
        // A `variable_map` also removes the mapped parameter from the system, so
        // it must reach OBSERVED-variable expressions too — otherwise an observed
        // defined by its `expression` (e.g. a `wind_speed` reading a coupled
        // ground-level wind, or a `surface_heat_flux` reading a coupled flux
        // field) keeps a dangling reference to the now-removed parameter and
        // evaluates to NaN. Mirrors the equation rewrite above.
        for var in block.observed_vars.values_mut() {
            if let Some(expr) = &var.expression {
                var.expression = Some(substitute_var(expr, to, &replacement));
            }
        }
    }
}

/// Substitute every occurrence of the variable named `target` with the
/// expression `replacement` in `expr`.
///
/// Array nodes (`makearray`/`arrayop`/`aggregate`/`integral`/…) carry their
/// value/body sub-expressions in out-of-band fields (`values`, `expr`, `filter`,
/// `lower`, `upper`) plus structural metadata (`regions`, `output_idx`, `ranges`,
/// …). Every field is preserved by cloning first, then the expression-bearing
/// ones are recursively substituted — otherwise a `variable_map` binding could
/// not reach a loaded inflow field referenced inside a `makearray`'s `values`
/// (the boundary stencil), and the `..Default::default()` rebuild would silently
/// drop `regions`/`values` and corrupt the discretized operator.
fn substitute_var(expr: &Expr, target: &str, replacement: &Expr) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) if name == target => replacement.clone(),
        Expr::Variable(name) => Expr::Variable(name.clone()),
        Expr::Operator(node) => {
            let mut out = node.clone();
            out.args = node
                .args
                .iter()
                .map(|a| substitute_var(a, target, replacement))
                .collect();
            out.expr = node
                .expr
                .as_ref()
                .map(|e| Box::new(substitute_var(e, target, replacement)));
            out.filter = node
                .filter
                .as_ref()
                .map(|e| Box::new(substitute_var(e, target, replacement)));
            out.lower = node
                .lower
                .as_ref()
                .map(|e| Box::new(substitute_var(e, target, replacement)));
            out.upper = node
                .upper
                .as_ref()
                .map(|e| Box::new(substitute_var(e, target, replacement)));
            out.values = node.values.as_ref().map(|vs| {
                vs.iter()
                    .map(|v| substitute_var(v, target, replacement))
                    .collect()
            });
            Expr::Operator(out)
        }
    }
}

// ============================================================================
// Scoped-reference `ic` classification (esm-spec §11.4.1)
// ============================================================================

/// If `lhs` is `ic(target)` — an `ic` operator over a single variable argument —
/// return the target state name, else `None`.
fn extract_ic_target(lhs: &Expr) -> Option<String> {
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
fn detect_lift_loops(ma: &ExpressionNode, lifted: &HashSet<String>, rank: usize) -> Option<Vec<String>> {
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
            ext[d] = ext[d].max(r[1]);
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
            let mut out = node.clone();
            out.args = node
                .args
                .iter()
                .map(|a| lift_rhs_to_cell(a, arrayvars, loops))
                .collect();
            Expr::Operator(out)
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
    Expr::Operator(ExpressionNode {
        op: "index".to_string(),
        args,
        ..Default::default()
    })
}

/// Build `index(<makearray>, loops…)`.
fn index_makearray(ma: &ExpressionNode, loops: &[String]) -> Expr {
    let mut args = Vec::with_capacity(loops.len() + 1);
    args.push(Expr::Operator(ma.clone()));
    for l in loops {
        args.push(Expr::Variable(l.clone()));
    }
    Expr::Operator(ExpressionNode {
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
        let loops = loops.ok_or_else(|| FlattenError::UnsupportedMapping {
            mapping_type: "pointwise".to_string(),
            reason: format!(
                "could not determine the spatial loop variables for species '{species}' from its operator makearray"
            ),
        })?;

        let extents = makearray_extents(first_ma);

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

        // Promote the species to the grid shape (a synthetic shape axis per dim)
        // so downstream consumers see an array state. The array simulator infers
        // the concrete extent from the lifted equations regardless.
        if let Some(var) = state_variables.get_mut(&species) {
            var.shape = Some(loops.iter().map(|l| format!("_lift_{l}")).collect());
        }

        let idx_species = index_node(&species, &loops);
        let d_body = Expr::Operator(ExpressionNode {
            op: "D".to_string(),
            args: vec![idx_species],
            wrt: Some("t".to_string()),
            ..Default::default()
        });
        let new_lhs = Expr::Operator(ExpressionNode {
            op: "aggregate".to_string(),
            output_idx: Some(loops.clone()),
            ranges: Some(ranges.clone()),
            expr: Some(Box::new(d_body)),
            ..Default::default()
        });
        let new_rhs = Expr::Operator(ExpressionNode {
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
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: make_metadata(),
            models: None,
            reaction_systems: None,
            data_loaders: None,
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
        let mut vars = HashMap::new();
        vars.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("m".to_string()),
                default: Some(0.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );
        vars.insert(
            "k".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: None,
                default: Some(1.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        let mut models = HashMap::new();
        models.insert(
            "sys".to_string(),
            Model {
                name: Some("System".to_string()),
                coupletype: None,
                subsystems: None,
                reference: None,
                variables: vars,
                equations: vec![Equation {
                    lhs: Expr::Operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("k".to_string()),
                    ..Default::default()
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
        let expr = Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![
                Expr::Variable("decay_rate".to_string()),
                Expr::Variable("t".to_string()),
            ],
            ..Default::default()
        });
        let out = namespace_expr(&expr, "ExponentialDecay");
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
}
