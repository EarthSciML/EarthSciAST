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

/// Component graph representing model structure
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ComponentGraph {
    /// Nodes in the graph (models, reaction systems, etc.)
    pub nodes: Vec<ComponentNode>,
    /// Edges representing coupling relationships
    pub edges: Vec<CouplingEdge>,
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
}

/// Type of component in the graph
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum ComponentType {
    /// ODE model
    Model,
    /// Reaction system
    ReactionSystem,
    /// Data loader
    DataLoader,
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
            nodes.push(ComponentNode {
                id: id.clone(),
                component_type: ComponentType::Model,
                name: models[id].name.clone(),
            });
        }
    }

    // Add reaction system nodes
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for id in sorted_keys(reaction_systems) {
            nodes.push(ComponentNode {
                id: id.clone(),
                component_type: ComponentType::ReactionSystem,
                name: None,
            });
        }
    }

    // Add data loader nodes
    if let Some(ref data_loaders) = esm_file.data_loaders {
        for id in sorted_keys(data_loaders) {
            nodes.push(ComponentNode {
                id: id.clone(),
                component_type: ComponentType::DataLoader,
                name: None, // Data loaders typically don't have human names
            });
        }
    }

    // Add coupling edges.
    //
    // Coupling edges only connect endpoints that are real component nodes
    // (models, reaction systems, data loaders). Coupling kinds that do not name
    // two concrete components (operator_apply, callback, event, coupling_import)
    // contribute no edge to the source-level component graph.
    let node_ids: std::collections::HashSet<&str> =
        nodes.iter().map(|n| n.id.as_str()).collect();

    if let Some(ref coupling_entries) = esm_file.coupling {
        for entry in coupling_entries {
            // Resolve each coupling entry to a (from, to, kind) triple.
            //
            // `operator_compose`/`couple` name two concrete systems (arity-2);
            // `variable_map` resolves each endpoint to its owning system via the
            // scope prefix. Kinds that do not name two concrete components
            // (operator_apply, callback, event, coupling_import) contribute no
            // edge to the source-level component graph.
            let (from, to, kind) = match entry {
                CouplingEntry::OperatorCompose { systems, .. } => {
                    if systems.len() >= 2 {
                        (
                            systems[0].clone(),
                            systems[1].clone(),
                            CouplingEdgeKind::OperatorCompose,
                        )
                    } else {
                        continue; // Skip invalid coupling
                    }
                }
                CouplingEntry::Couple { systems, .. } => {
                    if systems.len() >= 2 {
                        (
                            systems[0].clone(),
                            systems[1].clone(),
                            CouplingEdgeKind::Couple,
                        )
                    } else {
                        continue; // Skip invalid coupling
                    }
                }
                CouplingEntry::VariableMap { from, to, .. } => {
                    // Parse scoped references to extract system names
                    let from_system = from.split('.').next().unwrap_or(from).to_string();
                    let to_system = to.split('.').next().unwrap_or(to).to_string();
                    (from_system, to_system, CouplingEdgeKind::VariableMap)
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
    } else if contains(&esm_file.data_loaders, component_id) {
        Some(ComponentType::DataLoader)
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
    /// Variable name
    pub name: String,
    /// Variable kind/type
    pub kind: VariableKind,
    /// Physical units (optional)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,
    /// Which model/system owns this variable
    pub system: String,
}

/// Type/kind of variable
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VariableKind {
    /// State variable
    State,
    /// Parameter (constant)
    Parameter,
    /// Observed quantity (computed)
    Observed,
    /// Brownian (Wiener) noise source — any present promotes model to SDE
    Brownian,
    /// Chemical species
    Species,
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
    /// Which equation/reaction index produced this edge
    #[serde(skip_serializing_if = "Option::is_none")]
    pub equation_index: Option<usize>,
    /// The relevant subexpression (optional)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expression: Option<crate::Expr>,
}

/// Type of dependency relationship
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyRelationship {
    /// Additive relationship (e.g., in D(x)/dt = ... + f(y) + ...)
    Additive,
    /// Multiplicative relationship
    Multiplicative,
    /// Rate relationship (in reactions)
    Rate,
    /// Stoichiometric relationship (in reactions)
    Stoichiometric,
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

/// Trait for types that can build expression graphs
pub trait ExpressionGraphInput {
    fn build_expression_graph(&self) -> ExpressionGraph;
}

impl ExpressionGraphInput for crate::EsmFile {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let mut nodes = Vec::new();
        let mut edges = Vec::new();

        // Sorted-key iteration: node/edge order feeds rendered output and
        // must not depend on HashMap ordering.
        // Process all models
        if let Some(ref models) = self.models {
            for model_id in sorted_keys(models) {
                let (model_nodes, model_edges) = extract_from_model(&models[model_id], model_id);
                merge_variable_nodes(&mut nodes, model_nodes);
                edges.extend(model_edges);
            }
        }

        // Process all reaction systems
        if let Some(ref reaction_systems) = self.reaction_systems {
            for rs_id in sorted_keys(reaction_systems) {
                let (rs_nodes, rs_edges) =
                    extract_from_reaction_system(&reaction_systems[rs_id], rs_id);
                merge_variable_nodes(&mut nodes, rs_nodes);
                edges.extend(rs_edges);
            }
        }

        ExpressionGraph { nodes, edges }
    }
}

impl ExpressionGraphInput for crate::Model {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let (nodes, edges) = extract_from_model(self, "unknown");
        ExpressionGraph { nodes, edges }
    }
}

impl ExpressionGraphInput for crate::ReactionSystem {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let (nodes, edges) = extract_from_reaction_system(self, "unknown");
        ExpressionGraph { nodes, edges }
    }
}

impl ExpressionGraphInput for crate::Equation {
    fn build_expression_graph(&self) -> ExpressionGraph {
        // Delegate to the same per-equation extractor used by `extract_from_model`
        // so a standalone equation and a model equation share one variable
        // classification and one `equation_index` policy. A standalone equation
        // has no equation list, hence index 0.
        let mut nodes = Vec::new();
        let mut edges = Vec::new();
        extract_from_equation(&mut nodes, &mut edges, self, "unknown", 0);
        ExpressionGraph { nodes, edges }
    }
}

impl ExpressionGraphInput for crate::Reaction {
    fn build_expression_graph(&self) -> ExpressionGraph {
        // Delegate to the same per-reaction extractor used by
        // `extract_from_reaction_system` so a standalone reaction and a reaction
        // in a system share one variable classification (rate variables →
        // parameters) and one `equation_index` policy. A standalone reaction has
        // no reaction list, hence index 0.
        let mut nodes = Vec::new();
        let mut edges = Vec::new();
        extract_from_reaction(&mut nodes, &mut edges, self, "unknown", 0);
        ExpressionGraph { nodes, edges }
    }
}

impl ExpressionGraphInput for crate::Expr {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let mut nodes = Vec::new();

        // For a standalone expression, just extract variables
        let vars = extract_variables_from_expr(self);

        for var in vars {
            if !nodes.iter().any(|n: &VariableNode| n.name == var) {
                nodes.push(VariableNode {
                    name: var,
                    kind: VariableKind::Parameter, // Default to parameter for standalone expressions
                    units: None,
                    system: "unknown".to_string(),
                });
            }
        }

        // For a standalone expression, there are no variable-to-variable dependencies
        ExpressionGraph {
            nodes,
            edges: Vec::new(),
        }
    }
}

/// Helper function to extract nodes and edges from a model
fn extract_from_model(
    model: &crate::Model,
    system_id: &str,
) -> (Vec<VariableNode>, Vec<DependencyEdge>) {
    let mut nodes = Vec::new();
    let mut edges = Vec::new();

    // Add variable declarations as nodes with proper types (sorted so node
    // order is deterministic).
    for var_name in sorted_keys(&model.variables) {
        let var_def = &model.variables[var_name];
        let kind = match var_def.var_type {
            crate::VariableType::State => VariableKind::State,
            crate::VariableType::Parameter => VariableKind::Parameter,
            crate::VariableType::Observed => VariableKind::Observed,
            crate::VariableType::Brownian => VariableKind::Brownian,
        };

        nodes.push(VariableNode {
            name: var_name.clone(),
            kind,
            units: var_def.units.clone(),
            system: system_id.to_string(),
        });
    }

    // Process equations to create dependency edges. Any equation variable not
    // already declared above is fabricated as a state node by the helper.
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        extract_from_equation(&mut nodes, &mut edges, equation, system_id, eq_idx);
    }

    (nodes, edges)
}

/// Append the nodes and edges contributed by a single equation.
///
/// This is the single per-equation extractor shared by [`extract_from_model`]
/// and the `ExpressionGraphInput for crate::Equation` impl. Any LHS/RHS variable
/// not already present in `nodes` is added as a state variable (the default for
/// undeclared equation variables); declared variables added by the caller keep
/// their real kind. A RHS→LHS additive edge (including self-references such as
/// `D(x)/dt = -x`) is created for every `(lhs, rhs)` pair and tagged with
/// `eq_idx`. Nodes are deduplicated by name.
fn extract_from_equation(
    nodes: &mut Vec<VariableNode>,
    edges: &mut Vec<DependencyEdge>,
    equation: &crate::Equation,
    system_id: &str,
    eq_idx: usize,
) {
    let lhs_vars = extract_variables_from_expr(&equation.lhs);
    let rhs_vars = extract_variables_from_expr(&equation.rhs);

    // Ensure all variables in the equation exist as nodes.
    for var in lhs_vars.iter().chain(rhs_vars.iter()) {
        if !nodes.iter().any(|n: &VariableNode| n.name == *var) {
            nodes.push(VariableNode {
                name: var.clone(),
                kind: VariableKind::State, // Default for undeclared variables
                units: None,
                system: system_id.to_string(),
            });
        }
    }

    // Create edges from RHS variables to LHS variables.
    for lhs_var in &lhs_vars {
        for rhs_var in &rhs_vars {
            edges.push(DependencyEdge {
                source: rhs_var.clone(),
                target: lhs_var.clone(),
                relationship: DependencyRelationship::Additive,
                equation_index: Some(eq_idx),
                expression: Some(equation.rhs.clone()),
            });
        }
    }
}

/// Helper function to extract nodes and edges from a reaction system
fn extract_from_reaction_system(
    rs: &crate::ReactionSystem,
    system_id: &str,
) -> (Vec<VariableNode>, Vec<DependencyEdge>) {
    let mut nodes = Vec::new();
    let mut edges = Vec::new();

    // Add declared species as nodes (sorted so node order is deterministic).
    // These carry their declared units; species referenced only by a reaction
    // are fabricated (without units) by the helper below.
    for species_name in sorted_keys(&rs.species) {
        nodes.push(VariableNode {
            name: species_name.clone(),
            kind: VariableKind::Species,
            units: rs.species[species_name].units.clone(),
            system: system_id.to_string(),
        });
    }

    // Process reactions to create dependency edges.
    for (rxn_idx, reaction) in rs.reactions.iter().enumerate() {
        extract_from_reaction(&mut nodes, &mut edges, reaction, system_id, rxn_idx);
    }

    (nodes, edges)
}

/// Append the nodes and edges contributed by a single reaction.
///
/// This is the single per-reaction extractor shared by
/// [`extract_from_reaction_system`] and the `ExpressionGraphInput for
/// crate::Reaction` impl. Rate-expression variables not already present are
/// classified as parameters (rate constants); substrate and product species not
/// already present are classified as species. Rate edges (rate variable →
/// substrate/product) and stoichiometric edges (substrate → product) are tagged
/// with `rxn_idx`. Nodes are deduplicated by name, so declared species added by
/// the caller keep their declared units.
fn extract_from_reaction(
    nodes: &mut Vec<VariableNode>,
    edges: &mut Vec<DependencyEdge>,
    reaction: &crate::Reaction,
    system_id: &str,
    rxn_idx: usize,
) {
    let rate_vars = extract_variables_from_expr(&reaction.rate);

    // Rate-expression variables (rate constants) → parameters.
    for var in &rate_vars {
        if !nodes.iter().any(|n: &VariableNode| n.name == *var) {
            nodes.push(VariableNode {
                name: var.clone(),
                kind: VariableKind::Parameter,
                units: None,
                system: system_id.to_string(),
            });
        }
    }

    // Substrate and product species → species nodes (endpoints of the edges
    // below must exist as nodes).
    for species in reaction
        .substrates
        .iter()
        .flatten()
        .chain(reaction.products.iter().flatten())
    {
        if !nodes.iter().any(|n| n.name == species.species) {
            nodes.push(VariableNode {
                name: species.species.clone(),
                kind: VariableKind::Species,
                units: None,
                system: system_id.to_string(),
            });
        }
    }

    // Rate dependencies: rate variables influence product and substrate species.
    for rate_var in &rate_vars {
        for product in reaction.products.iter().flatten() {
            edges.push(DependencyEdge {
                source: rate_var.clone(),
                target: product.species.clone(),
                relationship: DependencyRelationship::Rate,
                equation_index: Some(rxn_idx),
                expression: Some(reaction.rate.clone()),
            });
        }
        for substrate in reaction.substrates.iter().flatten() {
            edges.push(DependencyEdge {
                source: rate_var.clone(),
                target: substrate.species.clone(),
                relationship: DependencyRelationship::Rate,
                equation_index: Some(rxn_idx),
                expression: Some(reaction.rate.clone()),
            });
        }
    }

    // Stoichiometric dependencies: substrates -> products.
    for substrate in reaction.substrates.iter().flatten() {
        for product in reaction.products.iter().flatten() {
            edges.push(DependencyEdge {
                source: substrate.species.clone(),
                target: product.species.clone(),
                relationship: DependencyRelationship::Stoichiometric,
                equation_index: Some(rxn_idx),
                expression: None,
            });
        }
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

/// Merge variable nodes, avoiding duplicates
fn merge_variable_nodes(existing: &mut Vec<VariableNode>, new_nodes: Vec<VariableNode>) {
    for new_node in new_nodes {
        if !existing
            .iter()
            .any(|n: &VariableNode| n.name == new_node.name && n.system == new_node.system)
        {
            existing.push(new_node);
        }
    }
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
                ComponentType::DataLoader => "diamond",
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
                ComponentType::DataLoader => ("{", "}"),
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

    /// Export graph to JSON format
    ///
    /// # Returns
    ///
    /// * `String` - JSON representation of the graph
    pub fn to_json_graph(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }
}

impl ExpressionGraph {
    /// Export graph to DOT format for Graphviz
    ///
    /// # Returns
    ///
    /// * `String` - DOT representation of the expression graph
    pub fn to_dot(&self) -> String {
        let mut dot = String::from("digraph ExpressionGraph {\n");
        dot.push_str("  rankdir=TB;\n");
        dot.push_str("  node [shape=ellipse];\n\n");

        // Add nodes (all variables)
        for node in &self.nodes {
            let shape = match node.kind {
                VariableKind::State => "ellipse",
                VariableKind::Parameter => "box",
                VariableKind::Observed => "diamond",
                VariableKind::Brownian => "doubleoctagon",
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
                VariableKind::State => ("(", ")"),
                VariableKind::Parameter => ("[", "]"),
                VariableKind::Observed => ("{", "}"),
                VariableKind::Brownian => ("{{", "}}"),
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

    /// Export graph to JSON format
    ///
    /// # Returns
    ///
    /// * `String` - JSON representation of the graph
    pub fn to_json_graph(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Metadata;
    use crate::{Expr, ExpressionNode as ExprNode, Model, ReactionSystem};
    use std::collections::HashMap;

    #[test]
    fn test_component_graph_empty() {
        let esm_file = EsmFile {
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
            data_loaders: None,
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
            data_loaders: None,
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
            data_loaders: None,
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
            data_loaders: None,
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
        let expr = Expr::Operator(ExprNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let graph = expression_graph(&expr);
        // Variable dependency graph: only variables as nodes, no operators/constants
        assert_eq!(graph.nodes.len(), 1); // Only 'x' variable
        assert_eq!(graph.edges.len(), 0); // No variable-to-variable dependencies for standalone expression

        // Check the variable node
        assert_eq!(graph.nodes[0].name, "x");
        assert_eq!(graph.nodes[0].kind, VariableKind::Parameter);
    }

    #[test]
    fn test_component_graph_to_dot() {
        let graph = ComponentGraph {
            nodes: vec![ComponentNode {
                id: "model1".to_string(),
                component_type: ComponentType::Model,
                name: Some("Test Model".to_string()),
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
            }],
            edges: vec![],
        };

        let mermaid = graph.to_mermaid();
        assert!(mermaid.contains("graph LR"));
        assert!(mermaid.contains("model1(Test Model)"));
    }

    #[test]
    fn test_expression_graph_to_mermaid() {
        let expr = Expr::Operator(ExprNode {
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
        // No edges for standalone expression
        assert!(!mermaid.contains("-->")); // No edges
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
            data_loaders: None,
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
    }
}
