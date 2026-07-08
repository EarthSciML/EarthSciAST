//! Graph utilities for analyzing model structure and coupling

use crate::{CouplingEntry, EsmFile};

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
    /// Operator
    Operator,
}

/// Edge in the component graph
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CouplingEdge {
    /// Source component ID
    pub from: String,
    /// Target component ID
    pub to: String,
    /// Type of coupling
    pub coupling_type: String,
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

    // Node order is part of the rendered output (`to_dot`/`to_mermaid`/
    // `to_json_graph`), so iterate every component map in sorted-key order
    // rather than nondeterministic HashMap order.
    fn sorted_keys<V>(map: &std::collections::HashMap<String, V>) -> Vec<&String> {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        keys
    }

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

    // Add operator nodes
    if let Some(ref operators) = esm_file.operators {
        for id in sorted_keys(operators) {
            nodes.push(ComponentNode {
                id: id.clone(),
                component_type: ComponentType::Operator,
                name: None, // Operators typically don't have human names
            });
        }
    }

    // Add coupling edges
    if let Some(ref coupling_entries) = esm_file.coupling {
        for entry in coupling_entries {
            // Extract coupling relationships based on the coupling type
            let (from, to, coupling_type_str) = match entry {
                CouplingEntry::OperatorCompose { systems, .. } => {
                    if systems.len() >= 2 {
                        (
                            systems[0].clone(),
                            systems[1].clone(),
                            "operator_compose".to_string(),
                        )
                    } else {
                        continue; // Skip invalid coupling
                    }
                }
                CouplingEntry::Couple { systems, .. } => {
                    if systems.len() >= 2 {
                        (systems[0].clone(), systems[1].clone(), "couple".to_string())
                    } else {
                        continue; // Skip invalid coupling
                    }
                }
                CouplingEntry::VariableMap { from, to, .. } => {
                    // Parse scoped references to extract system names
                    let from_system = from.split('.').next().unwrap_or(from).to_string();
                    let to_system = to.split('.').next().unwrap_or(to).to_string();
                    (from_system, to_system, "variable_map".to_string())
                }
                CouplingEntry::OperatorApply { operator, .. } => (
                    operator.clone(),
                    "unknown_target".to_string(),
                    "operator_apply".to_string(),
                ),
                CouplingEntry::Callback { callback_id, .. } => (
                    callback_id.clone(),
                    "unknown_target".to_string(),
                    "callback".to_string(),
                ),
                CouplingEntry::Event { name, affects, .. } => {
                    // Extract system names from affect variable references (e.g., "System1.var")
                    let systems: Vec<String> = affects
                        .as_ref()
                        .map(|affects| {
                            affects
                                .iter()
                                .filter_map(|affect| {
                                    if affect.lhs.contains('.') {
                                        Some(affect.lhs.split('.').next().unwrap_or("").to_string())
                                    } else {
                                        None
                                    }
                                })
                                .collect()
                        })
                        .unwrap_or_default();

                    if systems.len() >= 2 {
                        (systems[0].clone(), systems[1].clone(), "event".to_string())
                    } else if systems.len() == 1 {
                        let event_name = name.as_deref().unwrap_or("unknown_event");
                        (
                            event_name.to_string(),
                            systems[0].clone(),
                            "event".to_string(),
                        )
                    } else {
                        let event_name = name.as_deref().unwrap_or("unknown_event");
                        (
                            event_name.to_string(),
                            "unknown".to_string(),
                            "event".to_string(),
                        )
                    }
                }
            };

            edges.push(CouplingEdge {
                from,
                to,
                coupling_type: coupling_type_str,
                data: serde_json::Value::Null, // Simplified for now
            });
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
    } else if contains(&esm_file.operators, component_id) {
        Some(ComponentType::Operator)
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
            let mut ids: Vec<&String> = models.keys().collect();
            ids.sort();
            for model_id in ids {
                let (model_nodes, model_edges) = extract_from_model(&models[model_id], model_id);
                merge_variable_nodes(&mut nodes, model_nodes);
                edges.extend(model_edges);
            }
        }

        // Process all reaction systems
        if let Some(ref reaction_systems) = self.reaction_systems {
            let mut ids: Vec<&String> = reaction_systems.keys().collect();
            ids.sort();
            for rs_id in ids {
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
        let mut nodes = Vec::new();
        let mut edges = Vec::new();

        // Extract LHS variable (the one being differentiated)
        let lhs_vars = extract_variables_from_expr(&self.lhs);
        let rhs_vars = extract_variables_from_expr(&self.rhs);

        // Create nodes for all variables
        for var in &lhs_vars {
            if !nodes.iter().any(|n: &VariableNode| n.name == *var) {
                nodes.push(VariableNode {
                    name: var.clone(),
                    kind: VariableKind::State, // Assume LHS variables are state variables
                    units: None,
                    system: "unknown".to_string(),
                });
            }
        }

        for var in &rhs_vars {
            if !nodes.iter().any(|n: &VariableNode| n.name == *var) {
                nodes.push(VariableNode {
                    name: var.clone(),
                    kind: VariableKind::Parameter, // Assume RHS variables are parameters
                    units: None,
                    system: "unknown".to_string(),
                });
            }
        }

        // Create edges from RHS variables to LHS variables (self-references,
        // e.g. D(x)/dt = -x, produce an edge like any other dependency). A
        // standalone equation has no equation list, hence index 0.
        for lhs_var in &lhs_vars {
            for rhs_var in &rhs_vars {
                edges.push(DependencyEdge {
                    source: rhs_var.clone(),
                    target: lhs_var.clone(),
                    relationship: DependencyRelationship::Additive,
                    equation_index: Some(0),
                    expression: Some(self.rhs.clone()),
                });
            }
        }

        ExpressionGraph { nodes, edges }
    }
}

impl ExpressionGraphInput for crate::Reaction {
    fn build_expression_graph(&self) -> ExpressionGraph {
        let mut nodes = Vec::new();
        let mut edges = Vec::new();

        // Extract variables from rate expression
        let rate_vars = extract_variables_from_expr(&self.rate);

        // Create nodes for all variables found in rate expression
        for var in &rate_vars {
            if !nodes.iter().any(|n: &VariableNode| n.name == *var) {
                nodes.push(VariableNode {
                    name: var.clone(),
                    kind: VariableKind::Species, // Rate variables are typically species or rate constants
                    units: None,
                    system: "unknown".to_string(),
                });
            }
        }

        // Add substrate and product species as nodes
        for species in self.substrates.iter().flatten() {
            if !nodes.iter().any(|n| n.name == species.species) {
                nodes.push(VariableNode {
                    name: species.species.clone(),
                    kind: VariableKind::Species,
                    units: None,
                    system: "unknown".to_string(),
                });
            }
        }

        for species in self.products.iter().flatten() {
            if !nodes.iter().any(|n| n.name == species.species) {
                nodes.push(VariableNode {
                    name: species.species.clone(),
                    kind: VariableKind::Species,
                    units: None,
                    system: "unknown".to_string(),
                });
            }
        }

        // Create rate dependencies: rate variables influence product concentrations
        for rate_var in &rate_vars {
            for product in self.products.iter().flatten() {
                edges.push(DependencyEdge {
                    source: rate_var.clone(),
                    target: product.species.clone(),
                    relationship: DependencyRelationship::Rate,
                    equation_index: None,
                    expression: Some(self.rate.clone()),
                });
            }
            // Rate variables also influence substrate depletion
            for substrate in self.substrates.iter().flatten() {
                edges.push(DependencyEdge {
                    source: rate_var.clone(),
                    target: substrate.species.clone(),
                    relationship: DependencyRelationship::Rate,
                    equation_index: None,
                    expression: Some(self.rate.clone()),
                });
            }
        }

        // Stoichiometric dependencies: substrates influence products
        for substrate in self.substrates.iter().flatten() {
            for product in self.products.iter().flatten() {
                edges.push(DependencyEdge {
                    source: substrate.species.clone(),
                    target: product.species.clone(),
                    relationship: DependencyRelationship::Stoichiometric,
                    equation_index: None,
                    expression: None,
                });
            }
        }

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
    let mut var_names: Vec<&String> = model.variables.keys().collect();
    var_names.sort();
    for var_name in var_names {
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

    // Process equations to create dependency edges
    for (eq_idx, equation) in model.equations.iter().enumerate() {
        let lhs_vars = extract_variables_from_expr(&equation.lhs);
        let rhs_vars = extract_variables_from_expr(&equation.rhs);

        // Ensure all variables in equations exist as nodes
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

        // Create edges from RHS variables to LHS variables
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

    (nodes, edges)
}

/// Helper function to extract nodes and edges from a reaction system
fn extract_from_reaction_system(
    rs: &crate::ReactionSystem,
    system_id: &str,
) -> (Vec<VariableNode>, Vec<DependencyEdge>) {
    let mut nodes = Vec::new();
    let mut edges = Vec::new();

    // Add species as nodes (sorted so node order is deterministic)
    let mut species_names: Vec<&String> = rs.species.keys().collect();
    species_names.sort();
    for species_name in species_names {
        nodes.push(VariableNode {
            name: species_name.clone(),
            kind: VariableKind::Species,
            units: rs.species[species_name].units.clone(),
            system: system_id.to_string(),
        });
    }

    // Process reactions to create dependency edges
    for (rxn_idx, reaction) in rs.reactions.iter().enumerate() {
        let rate_vars = extract_variables_from_expr(&reaction.rate);

        // Ensure rate variables exist as nodes
        for var in &rate_vars {
            if !nodes.iter().any(|n: &VariableNode| n.name == *var) {
                nodes.push(VariableNode {
                    name: var.clone(),
                    kind: VariableKind::Parameter, // Rate constants are typically parameters
                    units: None,
                    system: system_id.to_string(),
                });
            }
        }

        // Create rate dependencies: rate variables influence concentrations
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

        // Stoichiometric dependencies: substrates -> products
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

    (nodes, edges)
}

/// Extract all variable names from an expression
fn extract_variables_from_expr(expr: &crate::Expr) -> Vec<String> {
    let mut vars = Vec::new();
    collect_variables(expr, &mut vars);
    vars.sort();
    vars.dedup();
    vars
}

/// Recursively collect variable names from an expression, covering the full
/// canonical child set ([`crate::types::ExpressionNode::for_each_child`]) so
/// variables inside aggregate bodies, `filter` predicates, integral bounds,
/// makearray `values`, and `table_lookup` axes all contribute graph edges.
fn collect_variables(expr: &crate::Expr, vars: &mut Vec<String>) {
    match expr {
        crate::Expr::Variable(var) => {
            vars.push(var.clone());
        }
        crate::Expr::Operator(op) => {
            op.for_each_child(&mut |arg| collect_variables(arg, vars));
        }
        crate::Expr::Number(_) | crate::Expr::Integer(_) => {
            // Numbers are not variables, skip
        }
    }
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
                ComponentType::Operator => "hexagon",
            };

            let label = node.name.as_ref().unwrap_or(&node.id);
            dot.push_str(&format!(
                "  \"{}\" [label=\"{}\" shape={}];\n",
                node.id, label, shape
            ));
        }

        dot.push('\n');

        // Add edges
        for edge in &self.edges {
            dot.push_str(&format!(
                "  \"{}\" -> \"{}\" [label=\"{}\"];\n",
                edge.from, edge.to, edge.coupling_type
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
                ComponentType::Operator => ("((", "))"),
            };

            let label = node.name.as_ref().unwrap_or(&node.id);
            mermaid.push_str(&format!("  {}{}{}{}\n", node.id, shape.0, label, shape.1));
        }

        // Add edges
        for edge in &self.edges {
            mermaid.push_str(&format!(
                "  {} -->|{}| {}\n",
                edge.from, edge.coupling_type, edge.to
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
                node.name, node.name, shape
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
                edge.source, edge.target, label
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
                node.name, shape_start, node.name, shape_end
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
                coupletype: None,
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
                coupletype: None,
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
                coupletype: None,
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
                coupletype: None,
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
                coupletype: None,
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
                coupletype: None,
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
                coupletype: None,
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
        assert_eq!(edge.coupling_type, "variable_map");
    }
}
