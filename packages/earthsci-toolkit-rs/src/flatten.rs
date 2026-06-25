//! Coupled system flattening per spec §4.7.5 + §4.7.6 (Rust Core tier).
//!
//! This module implements [`flatten`] — the canonical pipeline that turns an
//! [`EsmFile`] with multiple coupled components into a single [`FlattenedSystem`]
//! with dot-namespaced variables and real [`Expr`]-tree equations.
//!
//! The Rust implementation targets the **Core tier** only: it supports
//! `broadcast` and `identity` dimension mappings and raises
//! [`FlattenError::UnsupportedMapping`] if the source file requires `slice`,
//! `project`, or `regrid`. Spatial differential operators (`grad`, `div`,
//! `laplacian`, or `D` with `wrt != "t"`) likewise raise
//! `UnsupportedMapping` because the downstream Rust simulator
//! (`gt-rust-simulate`, a diffsol-backed ODE solver) cannot consume PDE output.
//! Higher tiers will be added when Rust gains PDE capability.

use crate::types::{
    ContinuousEvent, CouplingEntry, DiscreteEvent, Domain, Equation, EsmFile, Expr, ExpressionNode,
    Model, ModelVariable, ReactionSystem, VariableType,
};
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
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
    /// Flattened equations in processing order. Every variable reference is
    /// dot-namespaced.
    pub equations: Vec<Equation>,
    /// Continuous events from every component, LHS rewritten to namespaced form.
    pub continuous_events: Vec<ContinuousEvent>,
    /// Discrete events from every component, LHS rewritten to namespaced form.
    pub discrete_events: Vec<DiscreteEvent>,
    /// The file's named domain sections, passed through.
    pub domains: Option<std::collections::HashMap<String, Domain>>,
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
        equations.extend(block.equations);
        continuous_events.extend(block.continuous_events);
        discrete_events.extend(block.discrete_events);
    }

    // Apply post-collection variable_map parameter removals.
    if let Some(entries) = &file.coupling {
        for entry in entries {
            if let CouplingEntry::VariableMap { to, transform, .. } = entry
                && matches!(transform.as_str(), "param_to_var" | "conversion_factor")
            {
                parameters.shift_remove(to);
            }
        }
    }

    Ok(FlattenedSystem {
        independent_variables: vec!["t".to_string()],
        state_variables,
        parameters,
        observed_variables,
        brownian_variables,
        equations,
        continuous_events,
        discrete_events,
        domains: file.domains.clone(),
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
        models: Some(models),
        reaction_systems: None,
        data_loaders: None,
        operators: None,
        enums: None,
        coupling: None,
        domains: None,
        interfaces: None,
        grids: None,
        staggering_rules: None,
        discretizations: None,
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
            region: eq.region.clone(),
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
            region: eq.region.clone(),
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
fn namespace_expr(expr: &Expr, system_name: &str) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) => {
            if name.contains('.') || name == "t" {
                Expr::Variable(name.clone())
            } else {
                Expr::Variable(format!("{system_name}.{name}"))
            }
        }
        Expr::Operator(node) => Expr::Operator(ExpressionNode {
            op: node.op.clone(),
            args: node
                .args
                .iter()
                .map(|a| namespace_expr(a, system_name))
                .collect(),
            wrt: node.wrt.as_ref().map(|w| {
                if w.contains('.') || w == "t" {
                    w.clone()
                } else {
                    format!("{system_name}.{w}")
                }
            }),
            dim: node.dim.clone(),
            ..Default::default()
        }),
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

/// Scan an expression tree and raise [`FlattenError::UnsupportedMapping`] if
/// it contains any spatial differential operator. Per spec §4.7.6, Rust Core
/// tier does not implement spatial derivatives — the downstream diffsol
/// simulator is ODE-only.
fn reject_spatial_operators(expr: &Expr) -> Result<(), FlattenError> {
    match expr {
        Expr::Number(_) | Expr::Integer(_) | Expr::Variable(_) => Ok(()),
        Expr::Operator(node) => {
            match node.op.as_str() {
                "grad" | "div" | "laplacian" | "curl" | "∇" => {
                    return Err(FlattenError::UnsupportedMapping {
                        mapping_type: node.op.clone(),
                        reason: format!("spatial operator '{}' requires PDE support", node.op),
                    });
                }
                "D" => {
                    if let Some(wrt) = &node.wrt
                        && wrt != "t"
                    {
                        return Err(FlattenError::UnsupportedMapping {
                            mapping_type: format!("D(wrt={wrt})"),
                            reason: format!(
                                "non-time derivative 'D(_, {wrt})' requires PDE support"
                            ),
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
                region: None,
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
    transform: &str,
    factor: Option<f64>,
    per_system: &mut [SystemBlock],
) {
    let replacement = match (transform, factor) {
        ("conversion_factor", Some(f)) => Expr::Operator(ExpressionNode {
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
    }
}

/// Substitute every occurrence of the variable named `target` with the
/// expression `replacement` in `expr`.
fn substitute_var(expr: &Expr, target: &str, replacement: &Expr) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) if name == target => replacement.clone(),
        Expr::Variable(name) => Expr::Variable(name.clone()),
        Expr::Operator(node) => Expr::Operator(ExpressionNode {
            op: node.op.clone(),
            args: node
                .args
                .iter()
                .map(|a| substitute_var(a, target, replacement))
                .collect(),
            wrt: node.wrt.clone(),
            dim: node.dim.clone(),
            ..Default::default()
        }),
    }
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
            esm: "0.1.0".to_string(),
            metadata: make_metadata(),
            models: None,
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            domains: None,
            interfaces: None,
            grids: None,
            staggering_rules: None,
            discretizations: None,
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
                regrid: None,
                name: Some("System".to_string()),
                domain: None,
                index_sets: None,
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
                boundary_conditions: None,
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
