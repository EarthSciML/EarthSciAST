//! Expression substitution utilities.
//!
//! All entry points funnel through one generic core, [`substitute_expr`],
//! which resolves variable leaves via a caller-supplied closure and rebuilds
//! operator nodes with [`crate::types::ExpressionNode::map_children`] — so
//! sidecar expressions (`expr`, `filter`, `lower`, `upper`, `values`, `axes`)
//! are traversed and every non-expression field (`regions`, `ranges`,
//! `output_idx`, …) is preserved. The `*_with_context` family differs only in
//! its leaf resolver (scoped-reference fallback per esm-spec §2.3.3).

use crate::types::{
    AffectEquation, ContinuousEvent, DiscreteEvent, DiscreteEventTrigger, Equation, Reaction,
};
use crate::{EsmFile, Expr, Model, ReactionSystem};
use std::collections::HashMap;

// ============================================================================
// Generic core
// ============================================================================

/// Recursively rewrite `expr`, replacing each variable leaf with
/// `resolve(name)` when it returns `Some` (leaving the variable untouched
/// otherwise).
///
/// Bound index symbols (`output_idx`, `ranges` keys, `int_var`) are not
/// shadow-checked: callers must not substitute names that collide with loop
/// indices — the same contract as the flatten pass and the Julia/Python
/// bindings.
fn substitute_expr(expr: &Expr, resolve: &mut dyn FnMut(&str) -> Option<Expr>) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) => resolve(name).unwrap_or_else(|| Expr::Variable(name.clone())),
        Expr::Operator(node) => {
            Expr::Operator(node.map_children(&mut |child| substitute_expr(child, resolve)))
        }
    }
}

// Structure-preserving expression maps over the container types. Each applies
// `m` to every expression position and clones everything else, so the plain
// and `_with_context` substitution families share one traversal.

fn map_exprs_in_trigger(
    trigger: &DiscreteEventTrigger,
    m: &mut dyn FnMut(&Expr) -> Expr,
) -> DiscreteEventTrigger {
    match trigger {
        DiscreteEventTrigger::Condition { expression } => DiscreteEventTrigger::Condition {
            expression: m(expression),
        },
        // Periodic and preset-time triggers carry no expressions to substitute.
        other => other.clone(),
    }
}

fn map_exprs_in_affect(
    affect: &AffectEquation,
    m: &mut dyn FnMut(&Expr) -> Expr,
) -> AffectEquation {
    AffectEquation {
        lhs: affect.lhs.clone(), // LHS is a variable name string, not an expression
        rhs: m(&affect.rhs),
    }
}

fn map_exprs_in_discrete_event(
    event: &DiscreteEvent,
    m: &mut dyn FnMut(&Expr) -> Expr,
) -> DiscreteEvent {
    DiscreteEvent {
        name: event.name.clone(),
        trigger: map_exprs_in_trigger(&event.trigger, m),
        affects: event.affects.as_ref().map(|affects| {
            affects
                .iter()
                .map(|affect| map_exprs_in_affect(affect, m))
                .collect()
        }),
        // Functional affects are opaque platform snippets, carried verbatim
        // rather than substituted (matching the sibling bindings).
        functional_affect: event.functional_affect.clone(),
        discrete_parameters: event.discrete_parameters.clone(),
        reinitialize: event.reinitialize,
        description: event.description.clone(),
    }
}

fn map_exprs_in_continuous_event(
    event: &ContinuousEvent,
    m: &mut dyn FnMut(&Expr) -> Expr,
) -> ContinuousEvent {
    ContinuousEvent {
        name: event.name.clone(),
        conditions: event.conditions.iter().map(&mut *m).collect(),
        affects: event
            .affects
            .iter()
            .map(|affect| map_exprs_in_affect(affect, m))
            .collect(),
        affect_neg: event.affect_neg.as_ref().map(|affects| {
            affects
                .iter()
                .map(|affect| map_exprs_in_affect(affect, m))
                .collect()
        }),
        root_find: event.root_find.clone(),
        reinitialize: event.reinitialize,
        discrete_parameters: event.discrete_parameters.clone(),
        priority: event.priority,
        description: event.description.clone(),
    }
}

fn map_exprs_in_model(model: &Model, m: &mut dyn FnMut(&Expr) -> Expr) -> Model {
    Model {
        equations: model
            .equations
            .iter()
            .map(|eq| Equation {
                lhs: m(&eq.lhs),
                rhs: m(&eq.rhs),
            })
            .collect(),
        discrete_events: model.discrete_events.as_ref().map(|events| {
            events
                .iter()
                .map(|event| map_exprs_in_discrete_event(event, m))
                .collect()
        }),
        continuous_events: model.continuous_events.as_ref().map(|events| {
            events
                .iter()
                .map(|event| map_exprs_in_continuous_event(event, m))
                .collect()
        }),
        ..model.clone()
    }
}

fn map_exprs_in_reaction_system(
    reaction_system: &ReactionSystem,
    m: &mut dyn FnMut(&Expr) -> Expr,
) -> ReactionSystem {
    ReactionSystem {
        reactions: reaction_system
            .reactions
            .iter()
            .map(|rxn| Reaction {
                id: rxn.id.clone(),
                name: rxn.name.clone(),
                substrates: rxn.substrates.clone(),
                products: rxn.products.clone(),
                rate: m(&rxn.rate),
                reference: rxn.reference.clone(),
            })
            .collect(),
        ..reaction_system.clone()
    }
}

// ============================================================================
// Plain substitution (exact-name lookup)
// ============================================================================

/// Substitute variables in an expression, returning a new expression.
///
/// Traverses the full expression tree — including aggregate/arrayop bodies,
/// `filter` predicates, integral bounds, makearray `values`, and
/// `table_lookup` axes — and preserves all operator-node metadata.
pub fn substitute(expr: &Expr, substitutions: &HashMap<String, Expr>) -> Expr {
    substitute_expr(expr, &mut |name| substitutions.get(name).cloned())
}

/// Substitute variables in a discrete event trigger.
pub fn substitute_in_discrete_event_trigger(
    trigger: &DiscreteEventTrigger,
    substitutions: &HashMap<String, Expr>,
) -> DiscreteEventTrigger {
    map_exprs_in_trigger(trigger, &mut |e| substitute(e, substitutions))
}

/// Substitute variables in an affect equation (RHS only; the LHS is a
/// variable name string, not an expression).
pub fn substitute_in_affect_equation(
    affect: &AffectEquation,
    substitutions: &HashMap<String, Expr>,
) -> AffectEquation {
    map_exprs_in_affect(affect, &mut |e| substitute(e, substitutions))
}

/// Substitute variables in every expression of a discrete event.
pub fn substitute_in_discrete_event(
    event: &DiscreteEvent,
    substitutions: &HashMap<String, Expr>,
) -> DiscreteEvent {
    map_exprs_in_discrete_event(event, &mut |e| substitute(e, substitutions))
}

/// Substitute variables in every expression of a continuous event.
pub fn substitute_in_continuous_event(
    event: &ContinuousEvent,
    substitutions: &HashMap<String, Expr>,
) -> ContinuousEvent {
    map_exprs_in_continuous_event(event, &mut |e| substitute(e, substitutions))
}

/// Substitute variables in all expressions within a model (equations plus
/// discrete/continuous events; other model fields are cloned unchanged).
pub fn substitute_in_model(model: &Model, substitutions: &HashMap<String, Expr>) -> Model {
    map_exprs_in_model(model, &mut |e| substitute(e, substitutions))
}

/// Substitute variables in all reaction-rate expressions within a reaction
/// system.
pub fn substitute_in_reaction_system(
    reaction_system: &ReactionSystem,
    substitutions: &HashMap<String, Expr>,
) -> ReactionSystem {
    map_exprs_in_reaction_system(reaction_system, &mut |e| substitute(e, substitutions))
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
/// (esm-spec §2.3.3).
///
/// Resolution order per variable leaf: exact-name substitution, then scoped
/// resolution of the name via `context` (substituting the resolved name if it
/// has a binding, else rewriting the leaf to the resolved name), else the
/// leaf is left unchanged. Traversal and metadata preservation are identical
/// to [`substitute`].
pub fn substitute_with_context(
    expr: &Expr,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> Expr {
    substitute_expr(expr, &mut |name| {
        if let Some(replacement) = substitutions.get(name) {
            return Some(replacement.clone());
        }
        if let Some(resolved_name) = context.resolve_scoped_reference(name) {
            if let Some(replacement) = substitutions.get(&resolved_name) {
                return Some(replacement.clone());
            }
            // No binding for the resolved name: rewrite the leaf to it.
            return Some(Expr::Variable(resolved_name));
        }
        None
    })
}

/// [`substitute_in_model`] with scoped reference resolution.
pub fn substitute_in_model_with_context(
    model: &Model,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> Model {
    map_exprs_in_model(model, &mut |e| {
        substitute_with_context(e, substitutions, context)
    })
}

/// [`substitute_in_discrete_event_trigger`] with scoped reference resolution.
pub fn substitute_in_discrete_event_trigger_with_context(
    trigger: &DiscreteEventTrigger,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> DiscreteEventTrigger {
    map_exprs_in_trigger(trigger, &mut |e| {
        substitute_with_context(e, substitutions, context)
    })
}

/// [`substitute_in_affect_equation`] with scoped reference resolution.
pub fn substitute_in_affect_equation_with_context(
    affect: &AffectEquation,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> AffectEquation {
    map_exprs_in_affect(affect, &mut |e| {
        substitute_with_context(e, substitutions, context)
    })
}

/// [`substitute_in_discrete_event`] with scoped reference resolution.
pub fn substitute_in_discrete_event_with_context(
    event: &DiscreteEvent,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> DiscreteEvent {
    map_exprs_in_discrete_event(event, &mut |e| {
        substitute_with_context(e, substitutions, context)
    })
}

/// [`substitute_in_continuous_event`] with scoped reference resolution.
pub fn substitute_in_continuous_event_with_context(
    event: &ContinuousEvent,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> ContinuousEvent {
    map_exprs_in_continuous_event(event, &mut |e| {
        substitute_with_context(e, substitutions, context)
    })
}

/// [`substitute_in_reaction_system`] with scoped reference resolution.
pub fn substitute_in_reaction_system_with_context(
    reaction_system: &ReactionSystem,
    substitutions: &HashMap<String, Expr>,
    context: &ScopedContext,
) -> ReactionSystem {
    map_exprs_in_reaction_system(reaction_system, &mut |e| {
        substitute_with_context(e, substitutions, context)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ModelVariable;
    use crate::types::ExpressionNode;
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
                name: Some("Atmosphere".to_string()),
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
                name: Some("Atmosphere".to_string()),
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
                name: Some("Atmosphere".to_string()),
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
                name: Some("Atmosphere".to_string()),
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
            name: Some("TestModel".to_string()),
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
