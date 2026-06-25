//! Expression substitution utilities

use crate::types::{
    AffectEquation, ContinuousEvent, DiscreteEvent, DiscreteEventTrigger, Equation, ExpressionNode,
    Reaction,
};
use crate::{EsmFile, Expr, Model, ReactionSystem};
use std::collections::HashMap;

/// Substitute variables in an expression
///
/// # Arguments
///
/// * `expr` - The expression to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New expression with substitutions applied
pub fn substitute(expr: &Expr, substitutions: &std::collections::HashMap<String, Expr>) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(var_name) => {
            if let Some(replacement) = substitutions.get(var_name) {
                replacement.clone()
            } else {
                Expr::Variable(var_name.clone())
            }
        }
        Expr::Operator(op_node) => {
            let new_args: Vec<Expr> = op_node
                .args
                .iter()
                .map(|arg| substitute(arg, substitutions))
                .collect();

            Expr::Operator(ExpressionNode {
                op: op_node.op.clone(),
                args: new_args,
                wrt: op_node.wrt.clone(),
                dim: op_node.dim.clone(),
                ..Default::default()
            })
        }
    }
}

/// Substitute variables in a discrete event trigger
///
/// # Arguments
///
/// * `trigger` - The discrete event trigger to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New discrete event trigger with substitutions applied
pub fn substitute_in_discrete_event_trigger(
    trigger: &DiscreteEventTrigger,
    substitutions: &std::collections::HashMap<String, Expr>,
) -> DiscreteEventTrigger {
    match trigger {
        DiscreteEventTrigger::Condition { expression } => DiscreteEventTrigger::Condition {
            expression: substitute(expression, substitutions),
        },
        DiscreteEventTrigger::Periodic {
            interval,
            initial_offset,
        } => {
            // Periodic triggers have no expressions to substitute
            DiscreteEventTrigger::Periodic {
                interval: *interval,
                initial_offset: *initial_offset,
            }
        }
        DiscreteEventTrigger::PresetTimes { times } => {
            // Preset times have no expressions to substitute
            DiscreteEventTrigger::PresetTimes {
                times: times.clone(),
            }
        }
    }
}

/// Substitute variables in an affect equation
///
/// # Arguments
///
/// * `affect` - The affect equation to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New affect equation with substitutions applied
pub fn substitute_in_affect_equation(
    affect: &AffectEquation,
    substitutions: &std::collections::HashMap<String, Expr>,
) -> AffectEquation {
    AffectEquation {
        lhs: affect.lhs.clone(), // LHS is a variable name string, not an expression
        rhs: substitute(&affect.rhs, substitutions),
    }
}

/// Substitute variables in a discrete event
///
/// # Arguments
///
/// * `event` - The discrete event to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New discrete event with substitutions applied
pub fn substitute_in_discrete_event(
    event: &DiscreteEvent,
    substitutions: &std::collections::HashMap<String, Expr>,
) -> DiscreteEvent {
    DiscreteEvent {
        name: event.name.clone(),
        trigger: substitute_in_discrete_event_trigger(&event.trigger, substitutions),
        affects: event.affects.as_ref().map(|affects| {
            affects
                .iter()
                .map(|affect| substitute_in_affect_equation(affect, substitutions))
                .collect()
        }),
        functional_affect: event.functional_affect.clone(), // TODO: Could also substitute in functional affects if needed
        discrete_parameters: event.discrete_parameters.clone(),
        reinitialize: event.reinitialize,
        description: event.description.clone(),
    }
}

/// Substitute variables in a continuous event
///
/// # Arguments
///
/// * `event` - The continuous event to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New continuous event with substitutions applied
pub fn substitute_in_continuous_event(
    event: &ContinuousEvent,
    substitutions: &std::collections::HashMap<String, Expr>,
) -> ContinuousEvent {
    ContinuousEvent {
        name: event.name.clone(),
        conditions: event
            .conditions
            .iter()
            .map(|condition| substitute(condition, substitutions))
            .collect(),
        affects: event
            .affects
            .iter()
            .map(|affect| substitute_in_affect_equation(affect, substitutions))
            .collect(),
        affect_neg: event.affect_neg.as_ref().map(|affects| {
            affects
                .iter()
                .map(|affect| substitute_in_affect_equation(affect, substitutions))
                .collect()
        }),
        root_find: event.root_find.clone(),
        reinitialize: event.reinitialize,
        discrete_parameters: event.discrete_parameters.clone(),
        priority: event.priority,
        description: event.description.clone(),
    }
}

/// Substitute variables in all expressions within a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New model with substitutions applied
pub fn substitute_in_model(
    model: &Model,
    substitutions: &std::collections::HashMap<String, Expr>,
) -> Model {
    let new_equations = model
        .equations
        .iter()
        .map(|eq| Equation {
            lhs: substitute(&eq.lhs, substitutions),
            rhs: substitute(&eq.rhs, substitutions),
            region: eq.region.clone(),
        })
        .collect();

    Model {
        regrid: None,
        name: model.name.clone(),
        domain: model.domain.clone(),
        index_sets: model.index_sets.clone(),
        coupletype: model.coupletype.clone(),
        reference: model.reference.clone(),
        variables: model.variables.clone(),
        equations: new_equations,
        discrete_events: model.discrete_events.as_ref().map(|events| {
            events
                .iter()
                .map(|event| substitute_in_discrete_event(event, substitutions))
                .collect()
        }),
        continuous_events: model.continuous_events.as_ref().map(|events| {
            events
                .iter()
                .map(|event| substitute_in_continuous_event(event, substitutions))
                .collect()
        }),
        subsystems: model.subsystems.clone(),
        description: model.description.clone(),
        tolerance: model.tolerance.clone(),
        tests: model.tests.clone(),
        boundary_conditions: model.boundary_conditions.clone(),
        initialization_equations: model.initialization_equations.clone(),
        guesses: model.guesses.clone(),
        system_kind: model.system_kind.clone(),
    }
}

/// Substitute variables in all expressions within a reaction system
///
/// # Arguments
///
/// * `reaction_system` - The reaction system to modify
/// * `substitutions` - Map from variable names to replacement expressions
///
/// # Returns
///
/// * New reaction system with substitutions applied
pub fn substitute_in_reaction_system(
    reaction_system: &ReactionSystem,
    substitutions: &std::collections::HashMap<String, Expr>,
) -> ReactionSystem {
    let new_reactions = reaction_system
        .reactions
        .iter()
        .map(|rxn| Reaction {
            id: rxn.id.clone(),
            name: rxn.name.clone(),
            substrates: rxn.substrates.clone(),
            products: rxn.products.clone(),
            rate: substitute(&rxn.rate, substitutions),
            reference: rxn.reference.clone(),
        })
        .collect();

    ReactionSystem {
        domain: reaction_system.domain.clone(),
        coupletype: reaction_system.coupletype.clone(),
        reference: reaction_system.reference.clone(),
        species: reaction_system.species.clone(),
        parameters: reaction_system.parameters.clone(),
        reactions: new_reactions,
        constraint_equations: reaction_system.constraint_equations.clone(),
        discrete_events: reaction_system.discrete_events.clone(),
        continuous_events: reaction_system.continuous_events.clone(),
        subsystems: reaction_system.subsystems.clone(),
    }
}

/// Context for hierarchical scoped reference resolution
#[derive(Debug, Clone)]
pub struct ScopedContext {
    /// Available models in the ESM file
    pub models: HashMap<String, Model>,
    /// Available reaction systems in the ESM file
    pub reaction_systems: HashMap<String, ReactionSystem>,
    /// Current scope path (e.g., ["Model", "Subsystem"])
    pub current_scope: Vec<String>,
}

impl ScopedContext {
    /// Create a new scoped context from an ESM file
    pub fn from_esm_file(esm_file: &EsmFile) -> Self {
        let models = esm_file.models.clone().unwrap_or_default();
        let reaction_systems = esm_file.reaction_systems.clone().unwrap_or_default();

        ScopedContext {
            models,
            reaction_systems,
            current_scope: vec![],
        }
    }

    /// Create a scoped context with specific current scope
    pub fn with_scope(mut self, scope: Vec<String>) -> Self {
        self.current_scope = scope;
        self
    }

    /// Resolve a scoped reference to its full path
    /// Handles hierarchical resolution according to ESM Spec Section 2.3.3
    pub fn resolve_scoped_reference(&self, scoped_ref: &str) -> Option<String> {
        let components: Vec<&str> = scoped_ref.split('.').collect();

        // If it's already a fully qualified name with at least 2 components, try direct lookup
        if components.len() >= 2 && self.can_resolve_full_path(&components) {
            return Some(scoped_ref.to_string());
        }

        // Try resolving relative to current scope
        if !self.current_scope.is_empty() {
            let mut full_path = self.current_scope.clone();
            full_path.extend(components.iter().map(|s| s.to_string()));
            let full_path_str = full_path.join(".");

            if self.can_resolve_full_path(&full_path.iter().map(|s| s.as_str()).collect::<Vec<_>>())
            {
                return Some(full_path_str);
            }
        }

        // If direct resolution fails, try to find it in any available model/system
        self.search_in_available_contexts(&components)
    }

    /// Check if a full path can be resolved in the current context
    fn can_resolve_full_path(&self, components: &[&str]) -> bool {
        if components.is_empty() {
            return false;
        }

        // Check if it starts with a known model
        if let Some(model) = self.models.get(components[0]) {
            return self.resolve_in_model(model, &components[1..]);
        }

        // Check if it starts with a known reaction system
        if let Some(rs) = self.reaction_systems.get(components[0]) {
            return self.resolve_in_reaction_system(rs, &components[1..]);
        }

        false
    }

    /// Resolve remaining components within a model
    fn resolve_in_model(&self, model: &Model, remaining: &[&str]) -> bool {
        if remaining.is_empty() {
            return false; // Need at least a variable name
        }

        if remaining.len() == 1 {
            // Direct variable lookup
            return model.variables.contains_key(remaining[0]);
        }

        // For nested subsystems, we'd need more complex resolution logic
        // For now, we treat the full remaining path as a single variable name
        // This is a simplification but covers the main use cases
        let full_var_name = remaining.join(".");
        model.variables.contains_key(&full_var_name)
    }

    /// Resolve remaining components within a reaction system
    fn resolve_in_reaction_system(&self, rs: &ReactionSystem, remaining: &[&str]) -> bool {
        if remaining.is_empty() {
            return false;
        }

        if remaining.len() == 1 {
            // Check species (species name is the HashMap key)
            if rs.species.contains_key(remaining[0]) {
                return true;
            }
            // Check parameters
            if rs.parameters.contains_key(remaining[0]) {
                return true;
            }
        }

        // For nested paths in reaction systems
        let full_name = remaining.join(".");
        rs.parameters.contains_key(&full_name)
    }

    /// Search for the reference in all available contexts
    fn search_in_available_contexts(&self, components: &[&str]) -> Option<String> {
        // Search in models
        for (model_name, model) in &self.models {
            if components.len() == 1 && model.variables.contains_key(components[0]) {
                return Some(format!("{}.{}", model_name, components[0]));
            }

            // Check for nested variable names
            let nested_name = components.join(".");
            if model.variables.contains_key(&nested_name) {
                return Some(format!("{model_name}.{nested_name}"));
            }
        }

        // Search in reaction systems
        for (rs_name, rs) in &self.reaction_systems {
            if components.len() == 1 {
                if rs.species.contains_key(components[0]) {
                    return Some(format!("{}.{}", rs_name, components[0]));
                }
                if rs.parameters.contains_key(components[0]) {
                    return Some(format!("{}.{}", rs_name, components[0]));
                }
            }
        }

        None
    }
}

/// Substitute variables in an expression with scoped reference resolution
///
/// # Arguments
///
/// * `expr` - The expression to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New expression with substitutions applied using scoped resolution
pub fn substitute_with_context(
    expr: &Expr,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(var_name) => {
            // First try direct substitution
            if let Some(replacement) = substitutions.get(var_name) {
                return replacement.clone();
            }

            // If not found, try scoped resolution
            if let Some(resolved_name) = context.resolve_scoped_reference(var_name) {
                if let Some(replacement) = substitutions.get(&resolved_name) {
                    return replacement.clone();
                }
                // Return the resolved name if no substitution found
                return Expr::Variable(resolved_name);
            }

            // Return original if no resolution possible
            Expr::Variable(var_name.clone())
        }
        Expr::Operator(op_node) => {
            let new_args: Vec<Expr> = op_node
                .args
                .iter()
                .map(|arg| substitute_with_context(arg, substitutions, context))
                .collect();

            Expr::Operator(ExpressionNode {
                op: op_node.op.clone(),
                args: new_args,
                wrt: op_node.wrt.clone(),
                dim: op_node.dim.clone(),
                ..Default::default()
            })
        }
    }
}

/// Substitute variables in all expressions within a model using scoped reference resolution
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New model with substitutions applied using scoped resolution
pub fn substitute_in_model_with_context(
    model: &Model,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> Model {
    let new_equations = model
        .equations
        .iter()
        .map(|eq| Equation {
            lhs: substitute_with_context(&eq.lhs, substitutions, context),
            rhs: substitute_with_context(&eq.rhs, substitutions, context),
            region: eq.region.clone(),
        })
        .collect();

    Model {
        regrid: None,
        name: model.name.clone(),
        domain: model.domain.clone(),
        index_sets: model.index_sets.clone(),
        coupletype: model.coupletype.clone(),
        reference: model.reference.clone(),
        variables: model.variables.clone(),
        equations: new_equations,
        discrete_events: model.discrete_events.as_ref().map(|events| {
            events
                .iter()
                .map(|event| {
                    substitute_in_discrete_event_with_context(event, substitutions, context)
                })
                .collect()
        }),
        continuous_events: model.continuous_events.as_ref().map(|events| {
            events
                .iter()
                .map(|event| {
                    substitute_in_continuous_event_with_context(event, substitutions, context)
                })
                .collect()
        }),
        subsystems: model.subsystems.clone(),
        description: model.description.clone(),
        tolerance: model.tolerance.clone(),
        tests: model.tests.clone(),
        boundary_conditions: model.boundary_conditions.clone(),
        initialization_equations: model.initialization_equations.clone(),
        guesses: model.guesses.clone(),
        system_kind: model.system_kind.clone(),
    }
}

/// Substitute variables in a discrete event trigger using scoped reference resolution
///
/// # Arguments
///
/// * `trigger` - The discrete event trigger to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New discrete event trigger with substitutions applied using scoped resolution
pub fn substitute_in_discrete_event_trigger_with_context(
    trigger: &DiscreteEventTrigger,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> DiscreteEventTrigger {
    match trigger {
        DiscreteEventTrigger::Condition { expression } => DiscreteEventTrigger::Condition {
            expression: substitute_with_context(expression, substitutions, context),
        },
        DiscreteEventTrigger::Periodic {
            interval,
            initial_offset,
        } => {
            // Periodic triggers have no expressions to substitute
            DiscreteEventTrigger::Periodic {
                interval: *interval,
                initial_offset: *initial_offset,
            }
        }
        DiscreteEventTrigger::PresetTimes { times } => {
            // Preset times have no expressions to substitute
            DiscreteEventTrigger::PresetTimes {
                times: times.clone(),
            }
        }
    }
}

/// Substitute variables in an affect equation using scoped reference resolution
///
/// # Arguments
///
/// * `affect` - The affect equation to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New affect equation with substitutions applied using scoped resolution
pub fn substitute_in_affect_equation_with_context(
    affect: &AffectEquation,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> AffectEquation {
    AffectEquation {
        lhs: affect.lhs.clone(), // LHS is a variable name string, not an expression
        rhs: substitute_with_context(&affect.rhs, substitutions, context),
    }
}

/// Substitute variables in a discrete event using scoped reference resolution
///
/// # Arguments
///
/// * `event` - The discrete event to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New discrete event with substitutions applied using scoped resolution
pub fn substitute_in_discrete_event_with_context(
    event: &DiscreteEvent,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> DiscreteEvent {
    DiscreteEvent {
        name: event.name.clone(),
        trigger: substitute_in_discrete_event_trigger_with_context(
            &event.trigger,
            substitutions,
            context,
        ),
        affects: event.affects.as_ref().map(|affects| {
            affects
                .iter()
                .map(|affect| {
                    substitute_in_affect_equation_with_context(affect, substitutions, context)
                })
                .collect()
        }),
        functional_affect: event.functional_affect.clone(), // TODO: Could also substitute in functional affects if needed
        discrete_parameters: event.discrete_parameters.clone(),
        reinitialize: event.reinitialize,
        description: event.description.clone(),
    }
}

/// Substitute variables in a continuous event using scoped reference resolution
///
/// # Arguments
///
/// * `event` - The continuous event to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New continuous event with substitutions applied using scoped resolution
pub fn substitute_in_continuous_event_with_context(
    event: &ContinuousEvent,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> ContinuousEvent {
    ContinuousEvent {
        name: event.name.clone(),
        conditions: event
            .conditions
            .iter()
            .map(|condition| substitute_with_context(condition, substitutions, context))
            .collect(),
        affects: event
            .affects
            .iter()
            .map(|affect| {
                substitute_in_affect_equation_with_context(affect, substitutions, context)
            })
            .collect(),
        affect_neg: event.affect_neg.as_ref().map(|affects| {
            affects
                .iter()
                .map(|affect| {
                    substitute_in_affect_equation_with_context(affect, substitutions, context)
                })
                .collect()
        }),
        root_find: event.root_find.clone(),
        reinitialize: event.reinitialize,
        discrete_parameters: event.discrete_parameters.clone(),
        priority: event.priority,
        description: event.description.clone(),
    }
}

/// Substitute variables in all expressions within a reaction system using scoped reference resolution
///
/// # Arguments
///
/// * `reaction_system` - The reaction system to modify
/// * `substitutions` - Map from variable names to replacement expressions
/// * `context` - Scoped context for hierarchical resolution
///
/// # Returns
///
/// * New reaction system with substitutions applied using scoped resolution
pub fn substitute_in_reaction_system_with_context(
    reaction_system: &ReactionSystem,
    substitutions: &std::collections::HashMap<String, Expr>,
    context: &ScopedContext,
) -> ReactionSystem {
    let new_reactions = reaction_system
        .reactions
        .iter()
        .map(|rxn| Reaction {
            id: rxn.id.clone(),
            name: rxn.name.clone(),
            substrates: rxn.substrates.clone(),
            products: rxn.products.clone(),
            rate: substitute_with_context(&rxn.rate, substitutions, context),
            reference: rxn.reference.clone(),
        })
        .collect();

    ReactionSystem {
        domain: reaction_system.domain.clone(),
        coupletype: reaction_system.coupletype.clone(),
        reference: reaction_system.reference.clone(),
        species: reaction_system.species.clone(),
        parameters: reaction_system.parameters.clone(),
        reactions: new_reactions,
        constraint_equations: reaction_system.constraint_equations.clone(),
        discrete_events: reaction_system.discrete_events.clone(),
        continuous_events: reaction_system.continuous_events.clone(),
        subsystems: reaction_system.subsystems.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ModelVariable;
    use std::collections::HashMap;

    #[test]
    fn test_substitute_variable() {
        let mut subs = HashMap::new();
        subs.insert("x".to_string(), Expr::Number(42.0));

        let expr = Expr::Variable("x".to_string());
        let result = substitute(&expr, &subs);

        match result {
            Expr::Number(n) => assert_eq!(n, 42.0),
            _ => panic!("Expected number"),
        }
    }

    #[test]
    fn test_substitute_no_match() {
        let subs = HashMap::new();
        let expr = Expr::Variable("y".to_string());
        let result = substitute(&expr, &subs);

        match result {
            Expr::Variable(name) => assert_eq!(name, "y"),
            _ => panic!("Expected variable"),
        }
    }

    #[test]
    fn test_substitute_in_operator() {
        let mut subs = HashMap::new();
        subs.insert("x".to_string(), Expr::Number(2.0));
        subs.insert("y".to_string(), Expr::Number(3.0));

        let expr = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![
                Expr::Variable("x".to_string()),
                Expr::Variable("y".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let result = substitute(&expr, &subs);

        match result {
            Expr::Operator(op_node) => {
                assert_eq!(op_node.op, "+");
                assert_eq!(op_node.args.len(), 2);
                match &op_node.args[0] {
                    Expr::Number(n) => assert_eq!(*n, 2.0),
                    _ => panic!("Expected number"),
                }
                match &op_node.args[1] {
                    Expr::Number(n) => assert_eq!(*n, 3.0),
                    _ => panic!("Expected number"),
                }
            }
            _ => panic!("Expected operator"),
        }
    }

    #[test]
    fn test_scoped_context_creation() {
        use crate::{EsmFile, Metadata, VariableType};

        let mut models = HashMap::new();
        let mut model_variables = HashMap::new();
        model_variables.insert(
            "temperature".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("K".to_string()),
                default: Some(298.15),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "Atmosphere".to_string(),
            Model {
                regrid: None,
                name: Some("Atmosphere".to_string()),
                domain: None,
                index_sets: None,
                coupletype: None,
                subsystems: None,
                reference: None,
                variables: model_variables,
                equations: vec![],
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

        let esm_file = EsmFile {
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
            domains: None,
            interfaces: None,
            grids: None,
            staggering_rules: None,
            discretizations: None,
            function_tables: None,
        };

        let context = ScopedContext::from_esm_file(&esm_file);
        assert!(context.models.contains_key("Atmosphere"));
        assert!(
            context
                .models
                .get("Atmosphere")
                .unwrap()
                .variables
                .contains_key("temperature")
        );
    }

    #[test]
    fn test_scoped_reference_resolution() {
        use crate::{EsmFile, Metadata, VariableType};

        let mut models = HashMap::new();
        let mut model_variables = HashMap::new();
        model_variables.insert(
            "temperature".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("K".to_string()),
                default: Some(298.15),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "Atmosphere".to_string(),
            Model {
                regrid: None,
                name: Some("Atmosphere".to_string()),
                domain: None,
                index_sets: None,
                coupletype: None,
                subsystems: None,
                reference: None,
                variables: model_variables,
                equations: vec![],
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

        let esm_file = EsmFile {
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
            domains: None,
            interfaces: None,
            grids: None,
            staggering_rules: None,
            discretizations: None,
            function_tables: None,
        };

        let context = ScopedContext::from_esm_file(&esm_file);

        // Test fully qualified reference
        let resolved = context.resolve_scoped_reference("Atmosphere.temperature");
        assert_eq!(resolved, Some("Atmosphere.temperature".to_string()));

        // Test partial reference - should find it in available models
        let resolved_partial = context.resolve_scoped_reference("temperature");
        assert_eq!(resolved_partial, Some("Atmosphere.temperature".to_string()));

        // Test non-existent reference
        let resolved_none = context.resolve_scoped_reference("NonExistent.var");
        assert_eq!(resolved_none, None);
    }

    #[test]
    fn test_substitute_with_scoped_context() {
        use crate::{EsmFile, Metadata, VariableType};

        let mut models = HashMap::new();
        let mut model_variables = HashMap::new();
        model_variables.insert(
            "temperature".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("K".to_string()),
                default: Some(298.15),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "Atmosphere".to_string(),
            Model {
                regrid: None,
                name: Some("Atmosphere".to_string()),
                domain: None,
                index_sets: None,
                coupletype: None,
                subsystems: None,
                reference: None,
                variables: model_variables,
                equations: vec![],
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

        let esm_file = EsmFile {
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
            domains: None,
            interfaces: None,
            grids: None,
            staggering_rules: None,
            discretizations: None,
            function_tables: None,
        };

        let context = ScopedContext::from_esm_file(&esm_file);

        // Test substitution with scoped reference
        let expr = Expr::Variable("Atmosphere.temperature".to_string());
        let mut substitutions = HashMap::new();
        substitutions.insert("Atmosphere.temperature".to_string(), Expr::Number(273.15));

        let result = substitute_with_context(&expr, &substitutions, &context);
        match result {
            Expr::Number(n) => assert_eq!(n, 273.15),
            _ => panic!("Expected number after substitution"),
        }
    }

    #[test]
    fn test_hierarchical_scoped_substitution() {
        use crate::{EsmFile, Metadata, VariableType};

        // Create a more complex model with hierarchical scoped references
        let mut models = HashMap::new();
        let mut model_variables = HashMap::new();
        model_variables.insert(
            "Chemistry.FastChem.O3".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("mol/L".to_string()),
                default: Some(40e-9),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );
        model_variables.insert(
            "Chemistry.FastChem.k_rate".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: Some("s-1".to_string()),
                default: Some(1.8e-12),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "Atmosphere".to_string(),
            Model {
                regrid: None,
                name: Some("Atmosphere".to_string()),
                domain: None,
                index_sets: None,
                coupletype: None,
                subsystems: None,
                reference: None,
                variables: model_variables,
                equations: vec![],
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

        let esm_file = EsmFile {
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
            domains: None,
            interfaces: None,
            grids: None,
            staggering_rules: None,
            discretizations: None,
            function_tables: None,
        };

        let context = ScopedContext::from_esm_file(&esm_file);

        // Test complex expression with multiple scoped references
        let complex_expr = Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![
                Expr::Variable("Atmosphere.Chemistry.FastChem.k_rate".to_string()),
                Expr::Variable("Atmosphere.Chemistry.FastChem.O3".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let mut substitutions = HashMap::new();
        substitutions.insert(
            "Atmosphere.Chemistry.FastChem.k_rate".to_string(),
            Expr::Number(2.0e-12),
        );
        substitutions.insert(
            "Atmosphere.Chemistry.FastChem.O3".to_string(),
            Expr::Variable("local_O3".to_string()),
        );

        let result = substitute_with_context(&complex_expr, &substitutions, &context);

        // Verify the result structure
        match result {
            Expr::Operator(op_node) => {
                assert_eq!(op_node.op, "*");
                assert_eq!(op_node.args.len(), 2);
                // First arg should be substituted with number
                match &op_node.args[0] {
                    Expr::Number(n) => assert_eq!(*n, 2.0e-12),
                    _ => panic!("Expected number for first arg"),
                }
                // Second arg should be substituted with variable
                match &op_node.args[1] {
                    Expr::Variable(name) => assert_eq!(name, "local_O3"),
                    _ => panic!("Expected variable for second arg"),
                }
            }
            _ => panic!("Expected operator expression"),
        }
    }

    #[test]
    fn test_substitute_in_discrete_event() {
        let mut substitutions = HashMap::new();
        substitutions.insert("x".to_string(), Expr::Number(10.0));
        substitutions.insert("y".to_string(), Expr::Variable("z".to_string()));

        // Create a discrete event with condition trigger and affects
        let event = DiscreteEvent {
            name: Some("test_event".to_string()),
            trigger: DiscreteEventTrigger::Condition {
                expression: Expr::Variable("x".to_string()),
            },
            affects: Some(vec![AffectEquation {
                lhs: "target".to_string(),
                rhs: Expr::Variable("y".to_string()),
            }]),
            functional_affect: None,
            discrete_parameters: None,
            reinitialize: None,
            description: None,
        };

        let result = substitute_in_discrete_event(&event, &substitutions);

        // Verify trigger expression was substituted
        match &result.trigger {
            DiscreteEventTrigger::Condition { expression } => match expression {
                Expr::Number(n) => assert_eq!(*n, 10.0),
                _ => panic!("Expected number after substitution"),
            },
            _ => panic!("Expected condition trigger"),
        }

        // Verify affects expressions were substituted
        let affects = result.affects.unwrap();
        assert_eq!(affects.len(), 1);
        assert_eq!(affects[0].lhs, "target");
        match &affects[0].rhs {
            Expr::Variable(name) => assert_eq!(name, "z"),
            _ => panic!("Expected variable after substitution"),
        }
    }

    #[test]
    fn test_substitute_in_continuous_event() {
        let mut substitutions = HashMap::new();
        substitutions.insert("threshold".to_string(), Expr::Number(5.0));
        substitutions.insert("action_value".to_string(), Expr::Number(100.0));

        // Create a continuous event with conditions and affects
        let event = ContinuousEvent {
            name: Some("continuous_test".to_string()),
            conditions: vec![Expr::Variable("threshold".to_string())],
            affects: vec![AffectEquation {
                lhs: "output".to_string(),
                rhs: Expr::Variable("action_value".to_string()),
            }],
            affect_neg: None,
            root_find: None,
            reinitialize: None,
            discrete_parameters: None,
            priority: None,
            description: None,
        };

        let result = substitute_in_continuous_event(&event, &substitutions);

        // Verify conditions were substituted
        assert_eq!(result.conditions.len(), 1);
        match &result.conditions[0] {
            Expr::Number(n) => assert_eq!(*n, 5.0),
            _ => panic!("Expected number after substitution"),
        }

        // Verify affects were substituted
        assert_eq!(result.affects.len(), 1);
        assert_eq!(result.affects[0].lhs, "output");
        match &result.affects[0].rhs {
            Expr::Number(n) => assert_eq!(*n, 100.0),
            _ => panic!("Expected number after substitution"),
        }
    }

    #[test]
    fn test_substitute_in_model_with_events() {
        use crate::{ModelVariable, VariableType};

        let mut substitutions = HashMap::new();
        substitutions.insert("param".to_string(), Expr::Number(42.0));

        // Create a model with discrete and continuous events
        let model = Model {
            regrid: None,
            name: Some("TestModel".to_string()),
            domain: None,
            index_sets: None,
            coupletype: None,
            subsystems: None,
            reference: None,
            variables: {
                let mut vars = HashMap::new();
                vars.insert(
                    "state_var".to_string(),
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
                vars
            },
            equations: vec![],
            discrete_events: Some(vec![DiscreteEvent {
                name: Some("discrete_test".to_string()),
                trigger: DiscreteEventTrigger::Condition {
                    expression: Expr::Variable("param".to_string()),
                },
                affects: Some(vec![AffectEquation {
                    lhs: "state_var".to_string(),
                    rhs: Expr::Variable("param".to_string()),
                }]),
                functional_affect: None,
                discrete_parameters: None,
                reinitialize: None,
                description: None,
            }]),
            continuous_events: Some(vec![ContinuousEvent {
                name: Some("continuous_test".to_string()),
                conditions: vec![Expr::Variable("param".to_string())],
                affects: vec![AffectEquation {
                    lhs: "state_var".to_string(),
                    rhs: Expr::Variable("param".to_string()),
                }],
                affect_neg: None,
                root_find: None,
                reinitialize: None,
                discrete_parameters: None,
                priority: None,
                description: None,
            }]),
            description: None,
            tolerance: None,
            tests: None,
            boundary_conditions: None,
            initialization_equations: None,
            guesses: None,
            system_kind: None,
        };

        let result = substitute_in_model(&model, &substitutions);

        // Verify discrete events were substituted
        let discrete_events = result.discrete_events.unwrap();
        assert_eq!(discrete_events.len(), 1);
        match &discrete_events[0].trigger {
            DiscreteEventTrigger::Condition { expression } => match expression {
                Expr::Number(n) => assert_eq!(*n, 42.0),
                _ => panic!("Expected number after substitution in discrete event trigger"),
            },
            _ => panic!("Expected condition trigger"),
        }

        let discrete_affects = discrete_events[0].affects.as_ref().unwrap();
        match &discrete_affects[0].rhs {
            Expr::Number(n) => assert_eq!(*n, 42.0),
            _ => panic!("Expected number after substitution in discrete event affect"),
        }

        // Verify continuous events were substituted
        let continuous_events = result.continuous_events.unwrap();
        assert_eq!(continuous_events.len(), 1);
        match &continuous_events[0].conditions[0] {
            Expr::Number(n) => assert_eq!(*n, 42.0),
            _ => panic!("Expected number after substitution in continuous event condition"),
        }

        match &continuous_events[0].affects[0].rhs {
            Expr::Number(n) => assert_eq!(*n, 42.0),
            _ => panic!("Expected number after substitution in continuous event affect"),
        }
    }
}
