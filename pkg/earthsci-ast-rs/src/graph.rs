//! Graph utilities for analyzing model structure and coupling

use crate::{CouplingEntry, EsmFile};

/// Return a map's keys sorted lexicographically.
///
/// Node and edge order feeds rendered output (`to_dot`/`to_mermaid`/
/// `to_json_graph`), so every component/variable map is iterated in
/// sorted-key order rather than nondeterministic `HashMap` order.
fn sorted_keys<V>(map: &std::collections::HashMap<String, V>) -> Vec<&String> {
    let mut keys: Vec<&String> = map.keys().collect();
    keys.sort();
    keys
}

/// The scope a target with no owning component reports (esm-libraries-spec
/// §4.8.2). A bare `Model`/`ReactionSystem`/`Equation`/`Reaction`/`Expr` handed
/// straight to [`expression_graph`] has no document position, so its variables
/// are unscoped and belong to the pseudo-system `default`.
const DEFAULT_SYSTEM: &str = "default";

/// `equation_index` for a dependency that no positionally-numbered equation or
/// reaction produced — currently only a `variable_map` folded in by
/// [`ExpressionGraphOptions::merge_coupled`].
const NON_EQUATION_INDEX: i64 = -1;

/// Which incident edges a closure query follows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Direction {
    /// Both directions — the undirected neighbourhood.
    Both,
    /// Edges pointing AT the node.
    Incoming,
    /// Edges pointing AWAY from the node.
    Outgoing,
}

/// The neighbours of `node` reachable over `edges` in `direction`, sorted and
/// deduplicated.
///
/// `known` reports whether `node` is a registered graph node: an unknown key
/// resolves to `[]` rather than scanning. A neighbour is NOT required to be a
/// registered node — the guard is on the node being asked about, matching the
/// reference implementation.
fn neighbours<'a, I>(known: bool, edges: I, node: &str, direction: Direction) -> Vec<String>
where
    I: Iterator<Item = (&'a str, &'a str)>,
{
    if !known {
        return Vec::new();
    }
    let mut out = std::collections::BTreeSet::new();
    for (source, target) in edges {
        if direction != Direction::Incoming && source == node {
            out.insert(target.to_string());
        }
        if direction != Direction::Outgoing && target == node {
            out.insert(source.to_string());
        }
    }
    out.into_iter().collect()
}

/// Render a graph as the JSON adjacency-list export of esm-libraries-spec
/// §4.8.3: `{"nodes": [...], "edges": [...], "adjacency": {...}}`.
///
/// Every node object carries an `id` (a component node's `id`, a variable
/// node's `name`) alongside its own serialized fields; every edge is
/// `{source, target, data}`; `adjacency` maps each node key to its UNDIRECTED
/// neighbourhood.
fn render_json_graph<N, E>(
    nodes: &[N],
    node_key: impl Fn(&N) -> String,
    edges: &[E],
    edge_endpoints: impl Fn(&E) -> (String, String),
    adjacency: impl Fn(&str) -> Vec<String>,
) -> String
where
    N: serde::Serialize,
    E: serde::Serialize,
{
    let json_nodes: Vec<serde_json::Value> = nodes
        .iter()
        .map(|node| {
            let key = node_key(node);
            let mut value = serde_json::to_value(node).unwrap_or(serde_json::Value::Null);
            if let Some(object) = value.as_object_mut() {
                object.insert("id".to_string(), serde_json::Value::String(key));
            }
            value
        })
        .collect();

    let json_edges: Vec<serde_json::Value> = edges
        .iter()
        .map(|edge| {
            let (source, target) = edge_endpoints(edge);
            serde_json::json!({
                "source": source,
                "target": target,
                "data": serde_json::to_value(edge).unwrap_or(serde_json::Value::Null),
            })
        })
        .collect();

    let mut json_adjacency = serde_json::Map::new();
    for node in nodes {
        let key = node_key(node);
        let neighbours = adjacency(&key);
        json_adjacency.insert(key, serde_json::to_value(neighbours).unwrap_or_default());
    }

    let graph = serde_json::json!({
        "nodes": json_nodes,
        "edges": json_edges,
        "adjacency": serde_json::Value::Object(json_adjacency),
    });
    serde_json::to_string_pretty(&graph).unwrap_or_else(|_| "{}".to_string())
}

/// Component graph representing model structure
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ComponentGraph {
    /// Nodes in the graph (models, reaction systems)
    pub nodes: Vec<ComponentNode>,
    /// Edges representing coupling relationships
    pub edges: Vec<CouplingEdge>,
}

/// Summary counts a component node carries (esm-libraries-spec §4.8.1).
///
/// A model reports its declared variables and its equations; a reaction system
/// reports its reactions as `eq_count` and its species as `species_count` and
/// declares no `var_count`. Subsystems contribute NOTHING — the counts describe
/// the component's own body, matching the reference implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct ComponentMetadata {
    /// Declared variables (models only)
    pub var_count: usize,
    /// Equations (models) or reactions (reaction systems)
    pub eq_count: usize,
    /// Declared species (reaction systems only)
    pub species_count: usize,
}

/// Node in the component graph
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ComponentNode {
    /// Unique node identifier
    pub id: String,
    /// Type of component
    pub component_type: ComponentType,
    /// Human-readable name
    pub name: Option<String>,
    /// Summary counts (§4.8.1)
    pub metadata: ComponentMetadata,
}

/// Type of component in the graph.
///
/// There is no data-source arm. esm-libraries-spec §4.8.1 is explicit that "a
/// `data_sources` entry is not a component and is NOT a node": from 1.0.0
/// external data reaches a model as a PARAMETER whose `update` names the
/// source, so the dependency is already carried by that parameter's node.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComponentType {
    /// ODE model
    Model,
    /// Reaction system
    ReactionSystem,
}

/// Kind of coupling relationship represented by an edge
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CouplingEdgeKind {
    /// Operator composition of two named systems
    OperatorCompose,
    /// Direct coupling of two named systems
    Couple,
    /// Variable mapping between two systems
    VariableMap,
}

impl std::fmt::Display for CouplingEdgeKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            CouplingEdgeKind::OperatorCompose => "operator_compose",
            CouplingEdgeKind::Couple => "couple",
            CouplingEdgeKind::VariableMap => "variable_map",
        })
    }
}

/// Edge in the component graph
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CouplingEdge {
    /// Source component ID
    pub from: String,
    /// Target component ID
    pub to: String,
    /// Type of coupling
    pub coupling_type: CouplingEdgeKind,
    /// Human-readable edge label (§4.8.1): `compose` / `couple`, or, for a
    /// `variable_map`, the mapped variable — everything after the FIRST dot of
    /// the `from` reference.
    pub label: String,
    /// Additional coupling data
    pub data: serde_json::Value,
}

/// Build a component graph from an ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to analyze
///
/// # Returns
///
/// * Component graph showing structure and coupling
pub fn component_graph(esm_file: &EsmFile) -> ComponentGraph {
    let mut nodes = Vec::new();
    let mut edges = Vec::new();

    // Add model nodes
    if let Some(ref models) = esm_file.models {
        for id in sorted_keys(models) {
            let model = &models[id];
            nodes.push(ComponentNode {
                id: id.clone(),
                component_type: ComponentType::Model,
                name: model.name.clone(),
                metadata: ComponentMetadata {
                    var_count: model.variables.len(),
                    eq_count: model.equations.len(),
                    species_count: 0,
                },
            });
        }
    }

    // Add reaction system nodes
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for id in sorted_keys(reaction_systems) {
            let rs = &reaction_systems[id];
            nodes.push(ComponentNode {
                id: id.clone(),
                component_type: ComponentType::ReactionSystem,
                name: None,
                metadata: ComponentMetadata {
                    var_count: 0,
                    eq_count: rs.reactions.len(),
                    species_count: rs.species.len(),
                },
            });
        }
    }

    // NOTE: `data_sources` contributes NO nodes (esm-libraries-spec §4.8.1). A
    // data source is a document-scoped ingest registry exposing no variables of
    // its own; a model reaches it through a parameter whose `update` names it,
    // so the dependency it creates is already carried by that parameter.

    // Add coupling edges.
    //
    // Coupling edges only connect endpoints that are real component nodes
    // (models, reaction systems). Coupling kinds that do not name two concrete
    // components (operator_apply, callback, event, coupling_import) contribute
    // no edge to the source-level component graph.
    let node_ids: std::collections::HashSet<&str> = nodes.iter().map(|n| n.id.as_str()).collect();

    if let Some(ref coupling_entries) = esm_file.coupling {
        for entry in coupling_entries {
            // Resolve each coupling entry to a (from, to, kind, label) tuple.
            //
            // `operator_compose`/`couple` name two concrete systems;
            // `variable_map` resolves each endpoint to its owning system via the
            // scope prefix and labels the edge with the mapped variable. Kinds
            // that do not name two concrete components (operator_apply,
            // callback, event, coupling_import) contribute no edge.
            let (from, to, kind, label) = match entry {
                CouplingEntry::OperatorCompose { systems, .. } => {
                    if systems.len() >= 2 {
                        (
                            systems[0].clone(),
                            systems[1].clone(),
                            CouplingEdgeKind::OperatorCompose,
                            "compose".to_string(),
                        )
                    } else {
                        continue; // Skip invalid coupling
                    }
                }
                CouplingEntry::Couple { systems, .. } => {
                    if systems.len() == 2 {
                        (
                            systems[0].clone(),
                            systems[1].clone(),
                            CouplingEdgeKind::Couple,
                            "couple".to_string(),
                        )
                    } else {
                        continue; // Skip invalid coupling
                    }
                }
                CouplingEntry::VariableMap { from, to, .. } => {
                    // BOTH endpoints must be SCOPED (`System.variable...`): an
                    // unscoped reference names no component, so it can neither
                    // anchor an edge nor label one. The label is everything
                    // after the FIRST dot of `from`.
                    let (Some((from_system, from_var)), Some((to_system, _))) =
                        (from.split_once('.'), to.split_once('.'))
                    else {
                        continue;
                    };
                    (
                        from_system.to_string(),
                        to_system.to_string(),
                        CouplingEdgeKind::VariableMap,
                        from_var.to_string(),
                    )
                }
                // These coupling kinds do not name two concrete component nodes,
                // so they contribute no edge to the component graph.
                CouplingEntry::OperatorApply { .. }
                | CouplingEntry::Callback { .. }
                | CouplingEntry::Event { .. }
                | CouplingEntry::CouplingImport { .. } => continue,
            };

            // Only emit an edge when both endpoints are real graph nodes.
            if node_ids.contains(from.as_str()) && node_ids.contains(to.as_str()) {
                edges.push(CouplingEdge {
                    from,
                    to,
                    coupling_type: kind,
                    label,
                    data: serde_json::Value::Null,
                });
            }
        }
    }

    ComponentGraph { nodes, edges }
}

/// Check if a component exists in the ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to check
/// * `component_id` - The component ID to look for
///
/// # Returns
///
/// * `true` if the component exists, `false` otherwise
pub fn component_exists(esm_file: &EsmFile, component_id: &str) -> bool {
    get_component_type(esm_file, component_id).is_some()
}

/// Get the type of a component
///
/// A `data_sources` id is NOT a component (esm-libraries-spec §4.8.1) and
/// resolves to `None`.
///
/// # Arguments
///
/// * `esm_file` - The ESM file to check
/// * `component_id` - The component ID to look for
///
/// # Returns
///
/// * `Some(ComponentType)` if the component exists
/// * `None` if the component doesn't exist
pub fn get_component_type(esm_file: &EsmFile, component_id: &str) -> Option<ComponentType> {
    fn contains<V>(map: &Option<std::collections::HashMap<String, V>>, key: &str) -> bool {
        map.as_ref().is_some_and(|m| m.contains_key(key))
    }

    if contains(&esm_file.models, component_id) {
        Some(ComponentType::Model)
    } else if contains(&esm_file.reaction_systems, component_id) {
        Some(ComponentType::ReactionSystem)
    } else {
        None
    }
}

/// Expression graph representing variable dependencies within expressions
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ExpressionGraph {
    /// Nodes representing variables only (no operators or constants)
    pub nodes: Vec<VariableNode>,
    /// Edges representing dependencies between variables
    pub edges: Vec<DependencyEdge>,
}

/// Node representing a variable in an expression graph
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct VariableNode {
    /// Variable name, SCOPED by its owning system (`Transport.temperature`).
    /// A variable of the pseudo-system `default` — a bare target handed
    /// straight to [`expression_graph`] — is unscoped.
    pub name: String,
    /// Variable kind/type
    pub kind: VariableKind,
    /// Physical units (optional)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
    /// Which model/system owns this variable
    pub system: String,
}

/// Type/kind of variable, as the graph renders it.
///
/// These are the esm-spec §6.3.1 DERIVED categories, not declared types — esm
/// 1.0.0 declares only `unknown` and `parameter`. The mapping is fixed by
/// [`variable_kind`].
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VariableKind {
    /// An ODE state — an unknown carrying a time derivative.
    State,
    /// An unknown pinned only by an implicit algebraic constraint. Solved for
    /// like a state, but not differentiated.
    Algebraic,
    /// A constant or sampled parameter.
    Parameter,
    /// An unknown defined by a bare-variable equation — eliminable.
    Observed,
    /// A parameter whose update is `wiener` — any present promotes the model
    /// to an SDE.
    Brownian,
    /// A parameter carrying any other update: piecewise-constant between
    /// refreshes, never differentiated by the solver.
    Discrete,
    /// Chemical species
    Species,
}

/// The graph kind of one variable, derived through [`crate::classification`]
/// (esm-spec §6.3.1) rather than read off a declared type.
fn variable_kind(class: &crate::classification::Classification, name: &str) -> VariableKind {
    if class.is_observed(name) {
        VariableKind::Observed
    } else if class.is_brownian(name) {
        VariableKind::Brownian
    } else if class.is_discrete_parameter(name) {
        VariableKind::Discrete
    } else if class.ode_states.iter().any(|s| s == name) {
        VariableKind::State
    } else if class.algebraic_unknowns.iter().any(|s| s == name) {
        VariableKind::Algebraic
    } else {
        VariableKind::Parameter
    }
}

/// Edge representing dependencies between variables in an expression graph
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DependencyEdge {
    /// Source variable name (influences the target)
    pub source: String,
    /// Target variable name (is influenced by the source)
    pub target: String,
    /// How the dependency arises
    pub relationship: DependencyRelationship,
    /// Which equation/reaction index produced this edge, or `-1` when no
    /// positionally-numbered equation did (a folded `variable_map`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub equation_index: Option<i64>,
    /// The relevant subexpression (optional)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expression: Option<crate::Expr>,
}

/// PROVENANCE of a dependency — which structural site produced it, NOT a
/// classification of the operators involved. An equation edge is always
/// `Additive` (even for `w ~ u * v`) and a definition edge always
/// `Multiplicative` (even for `w ~ u + v`).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyRelationship {
    /// An RHS variable of an equation → the variable that equation defines.
    Additive,
    /// A free variable of an expression definition or a coupling variable map
    /// → the value it defines.
    Multiplicative,
    /// A reaction-rate variable → a species the reaction consumes or produces.
    Rate,
    /// A substrate species → a product species, via stoichiometry.
    Stoichiometric,
}

/// Settings for [`expression_graph_with_options`].
#[derive(Debug, Clone, Default)]
pub struct ExpressionGraphOptions {
    /// Fold `variable_map` coupling entries into cross-system dependency edges
    /// (esm-libraries-spec §4.8.2, "coupled file-level graph"). Applies to
    /// [`EsmFile`] targets only; every other target carries no coupling list.
    pub merge_coupled: bool,
}

/// Build an expression graph from various ESM components
///
/// # Arguments
///
/// * `input` - Can be an ESM file, model, reaction system, equation, reaction, or expression
///
/// # Returns
///
/// * `ExpressionGraph` - Graph showing variable dependencies
pub fn expression_graph<T>(input: &T) -> ExpressionGraph
where
    T: ExpressionGraphInput,
{
    input.build_expression_graph()
}

/// Build an expression graph with explicit [`ExpressionGraphOptions`].
///
/// # Arguments
///
/// * `input` - Can be an ESM file, model, reaction system, equation, reaction, or expression
/// * `options` - Settings; options that do not apply to `input` are ignored
///
/// # Returns
///
/// * `ExpressionGraph` - Graph showing variable dependencies
pub fn expression_graph_with_options<T>(
    input: &T,
    options: &ExpressionGraphOptions,
) -> ExpressionGraph
where
    T: ExpressionGraphInput,
{
    input.build_expression_graph_with_options(options)
}

/// Trait for types that can build expression graphs
pub trait ExpressionGraphInput {
    /// Build the graph with default options.
    fn build_expression_graph(&self) -> ExpressionGraph;

    /// Build the graph honouring `options`. The default implementation ignores
    /// them: only [`EsmFile`] carries a coupling list for `merge_coupled` to
    /// fold in.
    fn build_expression_graph_with_options(
        &self,
        _options: &ExpressionGraphOptions,
    ) -> ExpressionGraph {
        self.build_expression_graph()
    }
}

/// The growing node/edge lists of one expression-graph build, plus the dedup
/// index that keys nodes by their SCOPED name.
struct ExprGraphBuilder {
    nodes: Vec<VariableNode>,
    edges: Vec<DependencyEdge>,
    seen: std::collections::HashSet<String>,
}

impl ExprGraphBuilder {
    fn new() -> Self {
        ExprGraphBuilder {
            nodes: Vec::new(),
            edges: Vec::new(),
            seen: std::collections::HashSet::new(),
        }
    }

    /// Add a node, deduplicated by its scoped name, and return that name. A
    /// name already present keeps the kind and units it was first added with —
    /// declared variables are added before the equations that mention them, so
    /// a declaration always wins over the `parameter`/`state` fallback an
    /// equation would supply.
    fn add_node(
        &mut self,
        name: &str,
        kind: VariableKind,
        units: Option<String>,
        system: &str,
    ) -> String {
        let scoped = if system == DEFAULT_SYSTEM {
            name.to_string()
        } else {
            format!("{system}.{name}")
        };
        if self.seen.insert(scoped.clone()) {
            self.nodes.push(VariableNode {
                name: scoped.clone(),
                kind,
                units,
                system: system.to_string(),
            });
        }
        scoped
    }

    fn add_dependency(
        &mut self,
        source: String,
        target: String,
        relationship: DependencyRelationship,
        equation_index: i64,
        expression: Option<crate::Expr>,
    ) {
        self.edges.push(DependencyEdge {
            source,
            target,
            relationship,
            equation_index: Some(equation_index),
            expression,
        });
    }

    fn finish(self) -> ExpressionGraph {
        ExpressionGraph {
            nodes: self.nodes,
            edges: self.edges,
        }
    }
}

impl ExpressionGraphInput for crate::EsmFile {
    fn build_expression_graph(&self) -> ExpressionGraph {
        self.build_expression_graph_with_options(&ExpressionGraphOptions::default())
    }

    fn build_expression_graph_with_options(
        &self,
        options: &ExpressionGraphOptions,
    ) -> ExpressionGraph {
        let mut b = ExprGraphBuilder::new();

        // Sorted-key iteration: node/edge order feeds rendered output and
        // must not depend on HashMap ordering.
        if let Some(ref models) = self.models {
            for model_id in sorted_keys(models) {
                process_model_tree(&mut b, &models[model_id], model_id);
            }
        }

        if let Some(ref reaction_systems) = self.reaction_systems {
            for rs_id in sorted_keys(reaction_systems) {
                process_reaction_system_tree(&mut b, &reaction_systems[rs_id], rs_id);
            }
        }

        if options.merge_coupled
            && let Some(ref coupling) = self.coupling
        {
            process_coupling(&mut b, coupling);
        }

        b.finish()
    }
}

impl ExpressionGraphInput for crate::Model {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let mut b = ExprGraphBuilder::new();
        process_model_tree(&mut b, self, DEFAULT_SYSTEM);
        b.finish()
    }
}

impl ExpressionGraphInput for crate::ReactionSystem {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let mut b = ExprGraphBuilder::new();
        process_reaction_system_tree(&mut b, self, DEFAULT_SYSTEM);
        b.finish()
    }
}

impl ExpressionGraphInput for crate::Equation {
    fn build_expression_graph(&self) -> ExpressionGraph {
        // Delegate to the same per-equation extractor used by `process_model`
        // so a standalone equation and a model equation share one
        // `equation_index` policy. A standalone equation has no equation list,
        // hence index 0.
        let mut b = ExprGraphBuilder::new();
        process_equation(&mut b, self, 0, DEFAULT_SYSTEM);
        b.finish()
    }
}

impl ExpressionGraphInput for crate::Reaction {
    fn build_expression_graph(&self) -> ExpressionGraph {
        // Delegate to the same per-reaction extractor used by
        // `process_reaction_system` so a standalone reaction and a reaction in
        // a system share one variable classification (rate variables →
        // parameters) and one `equation_index` policy.
        let mut b = ExprGraphBuilder::new();
        process_reaction(&mut b, self, 0, DEFAULT_SYSTEM);
        b.finish()
    }
}

impl ExpressionGraphInput for crate::Expr {
    fn build_expression_graph(&self) -> ExpressionGraph {
        // esm-libraries-spec §4.8.2: for a bare expression "every variable in
        // the expression becomes a node, and the tree structure is flattened
        // into dependency edges" — so the expression's VALUE is a synthetic
        // observed node every free variable feeds.
        let mut b = ExprGraphBuilder::new();
        process_expression(&mut b, self, "expr_result", 0, DEFAULT_SYSTEM);
        b.finish()
    }
}

/// Is this `subsystems` entry an unresolved include stub (`{"ref": …}`) rather
/// than an inline component? A stub's contents are resolved elsewhere, so the
/// graph treats it as an opaque leaf and contributes nothing for it.
fn is_reference_stub(entry: &serde_json::Value) -> bool {
    entry.get("ref").is_some()
}

/// Deserialize a `subsystems` entry as a [`crate::Model`], supplying the
/// defaults a partial component omits (`variables` / `equations`) so a
/// subsystem that declares only one of them still contributes its half.
fn as_model(entry: &serde_json::Value) -> Option<crate::Model> {
    let mut value = entry.clone();
    let object = value.as_object_mut()?;
    object
        .entry("variables")
        .or_insert_with(|| serde_json::json!({}));
    object
        .entry("equations")
        .or_insert_with(|| serde_json::json!([]));
    serde_json::from_value(value).ok()
}

/// Deserialize a `subsystems` entry as a [`crate::ReactionSystem`], supplying
/// the defaults a partial component omits.
fn as_reaction_system(entry: &serde_json::Value) -> Option<crate::ReactionSystem> {
    let mut value = entry.clone();
    let object = value.as_object_mut()?;
    object
        .entry("species")
        .or_insert_with(|| serde_json::json!({}));
    object
        .entry("parameters")
        .or_insert_with(|| serde_json::json!({}));
    object
        .entry("reactions")
        .or_insert_with(|| serde_json::json!([]));
    serde_json::from_value(value).ok()
}

/// The scoped name of a child component of `system_id`. A `default` parent —
/// only reachable when a bare `Model`/`ReactionSystem` is handed straight to
/// [`expression_graph`] — yields a bare child name.
fn child_scope(system_id: &str, child_name: &str) -> String {
    if system_id == DEFAULT_SYSTEM {
        child_name.to_string()
    } else {
        format!("{system_id}.{child_name}")
    }
}

/// Add a model's own variables and equations, then recurse into its inline
/// `subsystems` (esm-libraries-spec §4.8.2). Reference stubs are skipped.
fn process_model_tree(b: &mut ExprGraphBuilder, model: &crate::Model, system_id: &str) {
    process_model(b, model, system_id);

    let Some(ref subsystems) = model.subsystems else {
        return;
    };
    for child_name in sorted_keys(subsystems) {
        let entry = &subsystems[child_name];
        if is_reference_stub(entry) {
            continue;
        }
        if let Some(child) = as_model(entry) {
            process_model_tree(b, &child, &child_scope(system_id, child_name));
        }
    }
}

/// Add a reaction system's own body, then recurse into its inline
/// `subsystems`. Reference stubs are skipped.
fn process_reaction_system_tree(
    b: &mut ExprGraphBuilder,
    rs: &crate::ReactionSystem,
    system_id: &str,
) {
    process_reaction_system(b, rs, system_id);

    let Some(ref subsystems) = rs.subsystems else {
        return;
    };
    for child_name in sorted_keys(subsystems) {
        let entry = &subsystems[child_name];
        if is_reference_stub(entry) {
            continue;
        }
        if let Some(child) = as_reaction_system(entry) {
            process_reaction_system_tree(b, &child, &child_scope(system_id, child_name));
        }
    }
}

/// Add a model's declared variables (with their DERIVED kinds) and the
/// dependency edges of its equations.
fn process_model(b: &mut ExprGraphBuilder, model: &crate::Model, system_id: &str) {
    // The node kind is DERIVED (esm-spec §6.3.1), never read off
    // `variable.type`: the format declares only `unknown` and `parameter`, so
    // classifying here is the only way the graph can distinguish a state from
    // an observed, or a Brownian parameter from a constant.
    let class = crate::classification::Classification::of(model);
    for var_name in sorted_keys(&model.variables) {
        let kind = variable_kind(&class, var_name);
        b.add_node(
            var_name,
            kind,
            model.variables[var_name].units.clone(),
            system_id,
        );
    }

    for (eq_idx, equation) in model.equations.iter().enumerate() {
        process_equation(b, equation, eq_idx as i64, system_id);
    }
}

/// Add a reaction system's species, declared parameters, reactions, and
/// constraint equations.
fn process_reaction_system(b: &mut ExprGraphBuilder, rs: &crate::ReactionSystem, system_id: &str) {
    for species_name in sorted_keys(&rs.species) {
        b.add_node(
            species_name,
            VariableKind::Species,
            rs.species[species_name].units.clone(),
            system_id,
        );
    }

    // Declared parameters are nodes in their own right, so a rate constant
    // keeps the units it was declared with instead of being fabricated
    // unit-less by the reaction that mentions it.
    for param_name in sorted_keys(&rs.parameters) {
        b.add_node(
            param_name,
            VariableKind::Parameter,
            rs.parameters[param_name].units.clone(),
            system_id,
        );
    }

    for (rxn_idx, reaction) in rs.reactions.iter().enumerate() {
        process_reaction(b, reaction, rxn_idx as i64, system_id);
    }

    // Constraint equations are numbered AFTER the reactions.
    if let Some(ref constraints) = rs.constraint_equations {
        for (idx, equation) in constraints.iter().enumerate() {
            process_equation(b, equation, (idx + rs.reactions.len()) as i64, system_id);
        }
    }
}

/// The single variable an equation LHS defines: a bare name, or the name under
/// the derivative / element-index / aggregate-output wrappers (`D(x)`,
/// `index(v, i)`, `aggregate(…, expr: D(index(v, i)))`).
///
/// Deliberately NOT [`crate::classification::lhs_form`]: that helper answers a
/// different question (which §6.3.1 CATEGORY the LHS puts the unknown in) and
/// so refuses a SPATIAL derivative and accepts `arrayop`/`broadcast` shells.
/// The graph only wants to know WHICH quantity is written, whatever kind of
/// derivative writes it.
fn lhs_target_name(lhs: &crate::Expr) -> Option<String> {
    match lhs {
        crate::Expr::Variable(name) => Some(name.clone()),
        crate::Expr::Operator(node) => match node.op.as_str() {
            "D" | "index" => node.args.first().and_then(lhs_target_name),
            "aggregate" => node.expr.as_deref().and_then(lhs_target_name),
            _ => None,
        },
        crate::Expr::Number(_) | crate::Expr::Integer(_) => None,
    }
}

/// Add the nodes and edges contributed by a single equation: one edge from
/// every free variable of the RHS to the variable the LHS defines (including
/// self-references such as `D(x)/dt = -x`).
///
/// An LHS that names no single variable — an implicit constraint like
/// `f(x, y) ~ 0` — defines nothing and contributes no edge.
fn process_equation(
    b: &mut ExprGraphBuilder,
    equation: &crate::Equation,
    eq_idx: i64,
    system_id: &str,
) {
    let Some(target_name) = lhs_target_name(&equation.lhs) else {
        return;
    };
    let lhs_var = b.add_node(&target_name, VariableKind::State, None, system_id);

    for rhs_var in extract_variables_from_expr(&equation.rhs) {
        let source = b.add_node(&rhs_var, VariableKind::Parameter, None, system_id);
        b.add_dependency(
            source,
            lhs_var.clone(),
            DependencyRelationship::Additive,
            eq_idx,
            Some(equation.rhs.clone()),
        );
    }
}

/// Add the nodes and edges contributed by a single reaction: a `rate` edge
/// from every rate variable to every substrate and product, and a
/// `stoichiometric` edge from every substrate to every product.
fn process_reaction(
    b: &mut ExprGraphBuilder,
    reaction: &crate::Reaction,
    rxn_idx: i64,
    system_id: &str,
) {
    let rate_vars = extract_variables_from_expr(&reaction.rate);

    // Substrates are consumed.
    for substrate in reaction.substrates.iter().flatten() {
        let substrate_var = b.add_node(&substrate.species, VariableKind::Species, None, system_id);
        for rate_var in &rate_vars {
            let param = b.add_node(rate_var, VariableKind::Parameter, None, system_id);
            b.add_dependency(
                param,
                substrate_var.clone(),
                DependencyRelationship::Rate,
                rxn_idx,
                Some(reaction.rate.clone()),
            );
        }
    }

    // Products are produced.
    for product in reaction.products.iter().flatten() {
        let product_var = b.add_node(&product.species, VariableKind::Species, None, system_id);
        for rate_var in &rate_vars {
            let param = b.add_node(rate_var, VariableKind::Parameter, None, system_id);
            b.add_dependency(
                param,
                product_var.clone(),
                DependencyRelationship::Rate,
                rxn_idx,
                Some(reaction.rate.clone()),
            );
        }
        for substrate in reaction.substrates.iter().flatten() {
            let substrate_var =
                b.add_node(&substrate.species, VariableKind::Species, None, system_id);
            b.add_dependency(
                substrate_var,
                product_var.clone(),
                DependencyRelationship::Stoichiometric,
                rxn_idx,
                Some(reaction.rate.clone()),
            );
        }
    }
}

/// Add one expression's free-variable → result dependency edges.
fn process_expression(
    b: &mut ExprGraphBuilder,
    expr: &crate::Expr,
    target_var: &str,
    eq_idx: i64,
    system_id: &str,
) {
    let target = b.add_node(target_var, VariableKind::Observed, None, system_id);
    for free_var in extract_variables_from_expr(expr) {
        let source = b.add_node(&free_var, VariableKind::Parameter, None, system_id);
        b.add_dependency(
            source,
            target.clone(),
            DependencyRelationship::Multiplicative,
            eq_idx,
            Some(expr.clone()),
        );
    }
}

/// Fold `variable_map` coupling entries into cross-system dependency edges
/// (esm-libraries-spec §4.8.2). Both endpoints must be scoped; either is added
/// as a `parameter` node if the components' own bodies did not already declare
/// it.
fn process_coupling(b: &mut ExprGraphBuilder, coupling: &[CouplingEntry]) {
    for entry in coupling {
        let CouplingEntry::VariableMap { from, to, .. } = entry else {
            continue;
        };
        let (Some((from_system, from_var)), Some((to_system, to_var))) =
            (from.split_once('.'), to.split_once('.'))
        else {
            continue;
        };

        let source = b.add_node(from_var, VariableKind::Parameter, None, from_system);
        let target = b.add_node(to_var, VariableKind::Parameter, None, to_system);
        b.add_dependency(
            source,
            target,
            DependencyRelationship::Multiplicative,
            NON_EQUATION_INDEX,
            Some(crate::Expr::Variable(from.clone())),
        );
    }
}

/// Extract all variable names referenced in an expression, sorted and
/// deduplicated for deterministic node/edge ordering.
///
/// Delegates to the single canonical collector
/// [`crate::expression::collect_variables`], which walks the full canonical
/// child set ([`crate::types::ExpressionNode::for_each_child`]) so variables
/// inside aggregate bodies, `filter` predicates, integral bounds, makearray
/// `values`, and `table_lookup` axes all contribute graph edges.
fn extract_variables_from_expr(expr: &crate::Expr) -> Vec<String> {
    let mut set = std::collections::HashSet::new();
    crate::expression::collect_variables(expr, &mut set);
    let mut vars: Vec<String> = set.into_iter().collect();
    vars.sort();
    vars
}

/// Escape a string for use inside a DOT double-quoted id/label.
///
/// DOT quoted strings tolerate spaces, dots, and parens verbatim; only
/// backslashes and double quotes must be escaped. Ids/labels are always emitted
/// double-quoted by the callers, so simple ids remain unchanged.
fn escape_dot(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Render a mermaid label, quoting it only when it contains characters that
/// would break unquoted mermaid text (double quotes, the shape delimiters
/// `()[]{}`, angle brackets, or the edge-label pipe).
///
/// Simple identifiers and plain names with spaces (e.g. `Test Model`) are
/// emitted verbatim so existing simple output — and the tests that assert it —
/// is unchanged; only labels with structural characters are wrapped in quotes,
/// with embedded double quotes replaced by the mermaid `#quot;` entity. (Node
/// ids themselves are emitted as-is: mermaid ids cannot be quoted, so ids with
/// structural characters remain a rendering limitation.)
fn mermaid_label(s: &str) -> String {
    if s.contains(['"', '(', ')', '[', ']', '{', '}', '<', '>', '|']) {
        format!("\"{}\"", s.replace('"', "#quot;"))
    } else {
        s.to_string()
    }
}

impl ComponentGraph {
    /// Is `id` a registered node of this graph?
    fn has_node(&self, id: &str) -> bool {
        self.nodes.iter().any(|n| n.id == id)
    }

    /// Iterate this graph's edges as `(source, target)` id pairs.
    fn endpoints(&self) -> impl Iterator<Item = (&str, &str)> {
        self.edges.iter().map(|e| (e.from.as_str(), e.to.as_str()))
    }

    /// The UNDIRECTED neighbourhood of `id` — its predecessors together with
    /// its successors (esm-libraries-spec §4.8.3), sorted. An unknown id
    /// resolves to `[]`.
    pub fn adjacency(&self, id: &str) -> Vec<String> {
        neighbours(self.has_node(id), self.endpoints(), id, Direction::Both)
    }

    /// The nodes with an edge pointing AT `id`, sorted.
    pub fn predecessors(&self, id: &str) -> Vec<String> {
        neighbours(self.has_node(id), self.endpoints(), id, Direction::Incoming)
    }

    /// The nodes `id` points at, sorted.
    pub fn successors(&self, id: &str) -> Vec<String> {
        neighbours(self.has_node(id), self.endpoints(), id, Direction::Outgoing)
    }

    /// Export graph to DOT format for Graphviz
    ///
    /// # Returns
    ///
    /// * `String` - DOT representation of the graph
    pub fn to_dot(&self) -> String {
        let mut dot = String::from("digraph ComponentGraph {\n");
        dot.push_str("  rankdir=LR;\n");
        dot.push_str("  node [shape=box];\n\n");

        // Add nodes
        for node in &self.nodes {
            let shape = match node.component_type {
                ComponentType::Model => "ellipse",
                ComponentType::ReactionSystem => "box",
            };

            let label = node.name.as_ref().unwrap_or(&node.id);
            dot.push_str(&format!(
                "  \"{}\" [label=\"{}\" shape={}];\n",
                escape_dot(&node.id),
                escape_dot(label),
                shape
            ));
        }

        dot.push('\n');

        // Add edges
        for edge in &self.edges {
            dot.push_str(&format!(
                "  \"{}\" -> \"{}\" [label=\"{}\"];\n",
                escape_dot(&edge.from),
                escape_dot(&edge.to),
                escape_dot(&edge.coupling_type.to_string())
            ));
        }

        dot.push_str("}\n");
        dot
    }

    /// Export graph to Mermaid format
    ///
    /// # Returns
    ///
    /// * `String` - Mermaid representation of the graph
    pub fn to_mermaid(&self) -> String {
        let mut mermaid = String::from("graph LR\n");

        // Add nodes with types
        for node in &self.nodes {
            let shape = match node.component_type {
                ComponentType::Model => ("(", ")"),
                ComponentType::ReactionSystem => ("[", "]"),
            };

            let label = node.name.as_ref().unwrap_or(&node.id);
            mermaid.push_str(&format!(
                "  {}{}{}{}\n",
                node.id,
                shape.0,
                mermaid_label(label),
                shape.1
            ));
        }

        // Add edges
        for edge in &self.edges {
            mermaid.push_str(&format!(
                "  {} -->|{}| {}\n",
                edge.from,
                mermaid_label(&edge.coupling_type.to_string()),
                edge.to
            ));
        }

        mermaid
    }

    /// Export graph as the JSON adjacency list of esm-libraries-spec §4.8.3.
    ///
    /// # Returns
    ///
    /// * `String` - `{"nodes": […], "edges": […], "adjacency": {…}}`
    pub fn to_json_graph(&self) -> String {
        render_json_graph(
            &self.nodes,
            |node| node.id.clone(),
            &self.edges,
            |edge| (edge.from.clone(), edge.to.clone()),
            |id| self.adjacency(id),
        )
    }
}

impl ExpressionGraph {
    /// Is `name` a registered node of this graph?
    fn has_node(&self, name: &str) -> bool {
        self.nodes.iter().any(|n| n.name == name)
    }

    /// Iterate this graph's edges as `(source, target)` name pairs.
    fn endpoints(&self) -> impl Iterator<Item = (&str, &str)> {
        self.edges
            .iter()
            .map(|e| (e.source.as_str(), e.target.as_str()))
    }

    /// The UNDIRECTED neighbourhood of `name` — its predecessors together with
    /// its successors (esm-libraries-spec §4.8.3), sorted. An unknown name
    /// resolves to `[]`.
    pub fn adjacency(&self, name: &str) -> Vec<String> {
        neighbours(self.has_node(name), self.endpoints(), name, Direction::Both)
    }

    /// The variables an edge points FROM into `name`, sorted.
    pub fn predecessors(&self, name: &str) -> Vec<String> {
        neighbours(
            self.has_node(name),
            self.endpoints(),
            name,
            Direction::Incoming,
        )
    }

    /// The variables `name` points at, sorted.
    pub fn successors(&self, name: &str) -> Vec<String> {
        neighbours(
            self.has_node(name),
            self.endpoints(),
            name,
            Direction::Outgoing,
        )
    }

    /// Export graph to DOT format for Graphviz
    ///
    /// # Returns
    ///
    /// * `String` - DOT representation of the expression graph
    pub fn to_dot(&self) -> String {
        let mut dot = String::from("digraph ExpressionGraph {\n");
        dot.push_str("  rankdir=TB;\n");
        dot.push_str("  node [shape=ellipse];\n\n");

        // Add nodes (all variables). An `algebraic` unknown renders like a
        // state: it is solved for, and it was classified `state` before the
        // kind vocabulary gained its own arm.
        for node in &self.nodes {
            let shape = match node.kind {
                VariableKind::State | VariableKind::Algebraic => "ellipse",
                VariableKind::Parameter => "box",
                VariableKind::Observed => "diamond",
                VariableKind::Brownian => "doubleoctagon",
                VariableKind::Discrete => "hexagon",
                VariableKind::Species => "circle",
            };

            dot.push_str(&format!(
                "  \"{}\" [label=\"{}\" shape={}];\n",
                escape_dot(&node.name),
                escape_dot(&node.name),
                shape
            ));
        }

        dot.push('\n');

        // Add edges
        for edge in &self.edges {
            let label = match edge.relationship {
                DependencyRelationship::Additive => "additive",
                DependencyRelationship::Multiplicative => "mult",
                DependencyRelationship::Rate => "rate",
                DependencyRelationship::Stoichiometric => "stoich",
            };
            dot.push_str(&format!(
                "  \"{}\" -> \"{}\" [label=\"{}\"];\n",
                escape_dot(&edge.source),
                escape_dot(&edge.target),
                label
            ));
        }

        dot.push_str("}\n");
        dot
    }

    /// Export graph to Mermaid format
    ///
    /// # Returns
    ///
    /// * `String` - Mermaid representation of the expression graph
    pub fn to_mermaid(&self) -> String {
        let mut mermaid = String::from("graph TD\n");

        // Add nodes with appropriate shapes
        for node in &self.nodes {
            let (shape_start, shape_end) = match node.kind {
                VariableKind::State | VariableKind::Algebraic => ("(", ")"),
                VariableKind::Parameter => ("[", "]"),
                VariableKind::Observed => ("{", "}"),
                VariableKind::Brownian => ("{{", "}}"),
                VariableKind::Discrete => ("[/", "/]"),
                VariableKind::Species => ("((", "))"),
            };

            mermaid.push_str(&format!(
                "  {}{}{}{}\n",
                node.name,
                shape_start,
                mermaid_label(&node.name),
                shape_end
            ));
        }

        // Add edges
        for edge in &self.edges {
            mermaid.push_str(&format!("  {} --> {}\n", edge.source, edge.target));
        }

        mermaid
    }

    /// Export graph as the JSON adjacency list of esm-libraries-spec §4.8.3.
    ///
    /// # Returns
    ///
    /// * `String` - `{"nodes": […], "edges": […], "adjacency": {…}}`
    pub fn to_json_graph(&self) -> String {
        render_json_graph(
            &self.nodes,
            |node| node.name.clone(),
            &self.edges,
            |edge| (edge.source.clone(), edge.target.clone()),
            |name| self.adjacency(name),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Metadata;
    use crate::{Expr, ExpressionNode as ExprNode, Model, ReactionSystem};
    use std::collections::HashMap;

    /// An `EsmFile` with every optional container empty, to be spread with
    /// `..empty_file()` so a test names only the fields it cares about.
    fn empty_file() -> EsmFile {
        EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "1.0.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,
            coupling: None,
            function_tables: None,
        }
    }

    /// An empty model carrying only a display name.
    fn test_model(name: &str) -> Model {
        Model {
            reference: None,
            subsystems: None,
            name: Some(name.to_string()),
            variables: HashMap::new(),
            equations: vec![],
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

    #[test]
    fn test_component_graph_empty() {
        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: None,
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let graph = component_graph(&esm_file);
        assert_eq!(graph.nodes.len(), 0);
        assert_eq!(graph.edges.len(), 0);
    }

    #[test]
    fn test_component_graph_with_models() {
        let mut models = HashMap::new();
        models.insert(
            "model1".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model 1".to_string()),
                variables: HashMap::new(),
                equations: vec![],
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
        models.insert(
            "model2".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model 2".to_string()),
                variables: HashMap::new(),
                equations: vec![],
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

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let graph = component_graph(&esm_file);
        assert_eq!(graph.nodes.len(), 2);

        let node1 = graph.nodes.iter().find(|n| n.id == "model1").unwrap();
        assert_eq!(node1.component_type, ComponentType::Model);
        assert_eq!(node1.name, Some("Test Model 1".to_string()));

        let node2 = graph.nodes.iter().find(|n| n.id == "model2").unwrap();
        assert_eq!(node2.component_type, ComponentType::Model);
        assert_eq!(node2.name, Some("Test Model 2".to_string()));
    }

    #[test]
    fn test_component_exists() {
        let mut models = HashMap::new();
        models.insert(
            "test_model".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables: HashMap::new(),
                equations: vec![],
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

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        assert!(component_exists(&esm_file, "test_model"));
        assert!(!component_exists(&esm_file, "nonexistent"));
    }

    #[test]
    fn test_get_component_type() {
        let mut models = HashMap::new();
        models.insert(
            "test_model".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables: HashMap::new(),
                equations: vec![],
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

        let mut reaction_systems = HashMap::new();
        reaction_systems.insert(
            "test_rs".to_string(),
            ReactionSystem {
                reference: None,
                species: HashMap::new(),
                parameters: HashMap::new(),
                reactions: vec![],
                constraint_equations: None,
                discrete_events: None,
                continuous_events: None,
                subsystems: None,
            },
        );

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: Some(reaction_systems),
            data_sources: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        assert_eq!(
            get_component_type(&esm_file, "test_model"),
            Some(ComponentType::Model)
        );
        assert_eq!(
            get_component_type(&esm_file, "test_rs"),
            Some(ComponentType::ReactionSystem)
        );
        assert_eq!(get_component_type(&esm_file, "nonexistent"), None);
    }

    #[test]
    fn test_expression_graph() {
        let expr = Expr::operator(ExprNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let graph = expression_graph(&expr);
        // Variable dependency graph: only variables as nodes, no operators or
        // constants — plus the synthetic node standing for the expression's own
        // value (esm-libraries-spec §4.8.2), which every free variable feeds.
        assert_eq!(graph.nodes.len(), 2);
        assert_eq!(graph.edges.len(), 1);

        let result = graph
            .nodes
            .iter()
            .find(|n| n.name == "expr_result")
            .expect("synthetic result node");
        assert_eq!(result.kind, VariableKind::Observed);
        assert_eq!(result.system, "default");

        let x = graph
            .nodes
            .iter()
            .find(|n| n.name == "x")
            .expect("free variable node");
        assert_eq!(x.kind, VariableKind::Parameter);

        assert_eq!(graph.edges[0].source, "x");
        assert_eq!(graph.edges[0].target, "expr_result");
        assert_eq!(
            graph.edges[0].relationship,
            DependencyRelationship::Multiplicative
        );
        assert_eq!(graph.edges[0].equation_index, Some(0));
    }

    #[test]
    fn test_component_graph_to_dot() {
        let graph = ComponentGraph {
            nodes: vec![ComponentNode {
                id: "model1".to_string(),
                component_type: ComponentType::Model,
                name: Some("Test Model".to_string()),
                metadata: ComponentMetadata::default(),
            }],
            edges: vec![],
        };

        let dot = graph.to_dot();
        assert!(dot.contains("digraph ComponentGraph"));
        assert!(dot.contains("model1"));
        assert!(dot.contains("Test Model"));
    }

    #[test]
    fn test_component_graph_to_mermaid() {
        let graph = ComponentGraph {
            nodes: vec![ComponentNode {
                id: "model1".to_string(),
                component_type: ComponentType::Model,
                name: Some("Test Model".to_string()),
                metadata: ComponentMetadata::default(),
            }],
            edges: vec![],
        };

        let mermaid = graph.to_mermaid();
        assert!(mermaid.contains("graph LR"));
        assert!(mermaid.contains("model1(Test Model)"));
    }

    #[test]
    fn test_expression_graph_to_mermaid() {
        let expr = Expr::operator(ExprNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let graph = expression_graph(&expr);
        let mermaid = graph.to_mermaid();

        assert!(mermaid.contains("graph TD"));
        assert!(mermaid.contains("x[x]")); // Parameter variable node (square brackets)
        // No constants or operators in variable dependency graph
        assert!(!mermaid.contains("const_")); // No constant nodes
        assert!(!mermaid.contains("{+}")); // No operator nodes
        // The free variable feeds the expression's synthetic result node.
        assert!(mermaid.contains("expr_result{expr_result}"));
        assert!(mermaid.contains("x --> expr_result"));
    }

    #[test]
    fn test_component_graph_variable_map_edge_extraction() {
        let mut models = HashMap::new();
        models.insert(
            "source".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Source System".to_string()),
                variables: HashMap::new(),
                equations: vec![],
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
        models.insert(
            "target".to_string(),
            Model {
                reference: None,
                subsystems: None,
                name: Some("Target System".to_string()),
                variables: HashMap::new(),
                equations: vec![],
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

        let coupling_entries = vec![crate::CouplingEntry::VariableMap {
            from: "source.var".to_string(),
            to: "target.param".to_string(),
            transform: crate::types::VariableMapTransform::Named("identity".to_string()),
            factor: None,
            description: None,
        }];

        let esm_file = EsmFile {
            coordinates: None,
            expression_templates: None,
            metaparameters: None,
            coupling_roles: None,
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
                description: None,
                authors: None,
                created: None,
                modified: None,
                license: None,
                tags: None,
                references: None,
                system_class: None,
                dae_info: None,
                discretized_from: None,
            },
            models: Some(models),
            reaction_systems: None,
            data_sources: None,
            operators: None,
            enums: None,

            coupling: Some(coupling_entries),
            function_tables: None,
        };

        let graph = component_graph(&esm_file);

        // Should have 2 nodes (source and target systems)
        assert_eq!(graph.nodes.len(), 2);

        // Should have 1 edge for the variable mapping
        assert_eq!(graph.edges.len(), 1);

        let edge = &graph.edges[0];

        // Edge should connect system names, not full scoped references
        assert_eq!(edge.from, "source"); // Not "source.var"
        assert_eq!(edge.to, "target"); // Not "target.param"
        assert_eq!(edge.coupling_type, CouplingEdgeKind::VariableMap);
        // The label is everything after the FIRST dot of `from`.
        assert_eq!(edge.label, "var");
    }

    /// A `variable_map` whose endpoints are not SCOPED names the no component,
    /// so it anchors no edge (esm-libraries-spec §4.8.1).
    #[test]
    fn test_component_graph_variable_map_requires_scoped_endpoints() {
        let mut models = HashMap::new();
        for id in ["source", "target"] {
            models.insert(id.to_string(), test_model(id));
        }

        let esm_file = EsmFile {
            coupling: Some(vec![crate::CouplingEntry::VariableMap {
                from: "source".to_string(),
                to: "target".to_string(),
                transform: crate::types::VariableMapTransform::Named("identity".to_string()),
                factor: None,
                description: None,
            }]),
            models: Some(models),
            ..empty_file()
        };

        let graph = component_graph(&esm_file);
        assert_eq!(graph.nodes.len(), 2);
        assert!(graph.edges.is_empty());
    }

    /// esm-libraries-spec §4.8.1: "A `data_sources` entry is not a component
    /// and is NOT a node."
    #[test]
    fn test_data_sources_contribute_no_nodes() {
        let json = r#"{
            "esm": "1.0.0",
            "metadata": { "name": "ds" },
            "data_sources": {
                "GEOSFP": {
                    "kind": "grid",
                    "source": { "url_template": "file:///data/GEOSFP/{date:%Y%m%d_%H%M}.nc" }
                }
            }
        }"#;
        let esm_file: EsmFile = serde_json::from_str(json).expect("parses");

        let graph = component_graph(&esm_file);
        assert!(graph.nodes.is_empty());
        assert!(graph.edges.is_empty());
        assert_eq!(get_component_type(&esm_file, "GEOSFP"), None);
        assert!(!component_exists(&esm_file, "GEOSFP"));
    }

    /// The §4.8.3 closure lookups, on a two-node one-edge graph.
    #[test]
    fn test_component_graph_closure() {
        let mut models = HashMap::new();
        for id in ["source", "target"] {
            models.insert(id.to_string(), test_model(id));
        }

        let esm_file = EsmFile {
            coupling: Some(vec![crate::CouplingEntry::VariableMap {
                from: "source.var".to_string(),
                to: "target.param".to_string(),
                transform: crate::types::VariableMapTransform::Named("identity".to_string()),
                factor: None,
                description: None,
            }]),
            models: Some(models),
            ..empty_file()
        };

        let graph = component_graph(&esm_file);
        assert_eq!(graph.adjacency("source"), vec!["target".to_string()]);
        assert_eq!(graph.successors("source"), vec!["target".to_string()]);
        assert!(graph.predecessors("source").is_empty());
        assert_eq!(graph.adjacency("target"), vec!["source".to_string()]);
        assert_eq!(graph.predecessors("target"), vec!["source".to_string()]);
        assert!(graph.successors("target").is_empty());
        // An unknown key resolves to [] rather than panicking.
        assert!(graph.adjacency("nonexistent").is_empty());
    }

    /// The §4.8.3 JSON adjacency-list export: three top-level keys, an `id` on
    /// every node, `{source, target, data}` edges, and an adjacency map.
    #[test]
    fn test_to_json_graph_is_an_adjacency_list() {
        let mut models = HashMap::new();
        for id in ["source", "target"] {
            models.insert(id.to_string(), test_model(id));
        }

        let esm_file = EsmFile {
            coupling: Some(vec![crate::CouplingEntry::VariableMap {
                from: "source.var".to_string(),
                to: "target.param".to_string(),
                transform: crate::types::VariableMapTransform::Named("identity".to_string()),
                factor: None,
                description: None,
            }]),
            models: Some(models),
            ..empty_file()
        };

        let json: serde_json::Value =
            serde_json::from_str(&component_graph(&esm_file).to_json_graph()).expect("valid JSON");

        let mut keys: Vec<&String> = json.as_object().expect("object").keys().collect();
        keys.sort();
        assert_eq!(keys, vec!["adjacency", "edges", "nodes"]);

        let nodes = json["nodes"].as_array().expect("nodes array");
        assert_eq!(nodes[0]["id"], "source");
        let edges = json["edges"].as_array().expect("edges array");
        assert_eq!(edges[0]["source"], "source");
        assert_eq!(edges[0]["target"], "target");
        assert_eq!(edges[0]["data"]["coupling_type"], "variable_map");
        assert_eq!(json["adjacency"]["source"][0], "target");
        assert_eq!(json["adjacency"]["target"][0], "source");
    }
}
