//! Immutable editing operations for ESM models

use crate::{
    ContinuousEvent, CouplingEntry, DiscreteEvent, Equation, EsmFile, Expr, ExpressionNode, Model,
    ModelVariable, Reaction, ReactionSystem, Species,
};
use std::collections::HashMap;

/// Result type for editing operations
pub type EditResult<T> = Result<T, EditError>;

/// Errors that can occur during editing operations
#[derive(Debug, Clone, PartialEq)]
pub enum EditError {
    /// Component not found
    ComponentNotFound(String),
    /// Invalid operation
    InvalidOperation(String),
    /// Variable already exists
    VariableExists(String),
    /// Equation index out of bounds
    EquationIndexError(usize),
    /// Species not found
    SpeciesNotFound(String),
    /// Reaction not found
    ReactionNotFound(String),
    /// Event index out of bounds
    EventIndexError(usize),
    /// Coupling index out of bounds
    CouplingIndexError(usize),
}

impl std::fmt::Display for EditError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EditError::ComponentNotFound(name) => write!(f, "Component not found: {name}"),
            EditError::InvalidOperation(msg) => write!(f, "Invalid operation: {msg}"),
            EditError::VariableExists(name) => write!(f, "Variable already exists: {name}"),
            EditError::EquationIndexError(idx) => {
                write!(f, "Equation index out of bounds: {idx}")
            }
            EditError::SpeciesNotFound(name) => write!(f, "Species not found: {name}"),
            EditError::ReactionNotFound(name) => write!(f, "Reaction not found: {name}"),
            EditError::EventIndexError(idx) => write!(f, "Event index out of bounds: {idx}"),
            EditError::CouplingIndexError(idx) => {
                write!(f, "Coupling index out of bounds: {idx}")
            }
        }
    }
}

impl std::error::Error for EditError {}

/// Remove the element at `index` from an optional vector, collapsing the field
/// back to `None` once it becomes empty. Produces `index_error(index)` when the
/// vector is absent or the index is out of range.
fn remove_from_optional_vec<T>(
    field: &mut Option<Vec<T>>,
    index: usize,
    index_error: impl Fn(usize) -> EditError,
) -> EditResult<()> {
    let items = field.as_mut().ok_or_else(|| index_error(index))?;
    if index >= items.len() {
        return Err(index_error(index));
    }
    items.remove(index);
    if items.is_empty() {
        *field = None;
    }
    Ok(())
}

/// Add a new model to an ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to modify
/// * `model_id` - Unique identifier for the new model
/// * `model` - The model to add
///
/// # Returns
///
/// * `EditResult<EsmFile>` - New ESM file with the added model
pub fn add_model(esm_file: &EsmFile, model_id: &str, model: Model) -> EditResult<EsmFile> {
    let mut new_file = esm_file.clone();

    // Initialize models map if it doesn't exist
    if new_file.models.is_none() {
        new_file.models = Some(HashMap::new());
    }

    // Check if model already exists
    if new_file.models.as_ref().unwrap().contains_key(model_id) {
        return Err(EditError::InvalidOperation(format!(
            "Model '{model_id}' already exists"
        )));
    }

    // Add the new model
    new_file
        .models
        .as_mut()
        .unwrap()
        .insert(model_id.to_string(), model);

    Ok(new_file)
}

/// Remove a model from an ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to modify
/// * `model_id` - Identifier of the model to remove
///
/// # Returns
///
/// * `EditResult<EsmFile>` - New ESM file without the model
pub fn remove_model(esm_file: &EsmFile, model_id: &str) -> EditResult<EsmFile> {
    let mut new_file = esm_file.clone();

    if let Some(ref mut models) = new_file.models {
        if models.remove(model_id).is_none() {
            return Err(EditError::ComponentNotFound(model_id.to_string()));
        }
    } else {
        return Err(EditError::ComponentNotFound(model_id.to_string()));
    }

    Ok(new_file)
}

/// Add a variable to a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `var_name` - Name of the new variable
/// * `variable` - The variable to add
///
/// # Returns
///
/// * `EditResult<Model>` - New model with the added variable
pub fn add_variable(model: &Model, var_name: &str, variable: ModelVariable) -> EditResult<Model> {
    let mut new_model = model.clone();

    if new_model.variables.contains_key(var_name) {
        return Err(EditError::VariableExists(var_name.to_string()));
    }

    new_model.variables.insert(var_name.to_string(), variable);
    Ok(new_model)
}

/// Remove a variable from a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `var_name` - Name of the variable to remove
///
/// # Returns
///
/// * `EditResult<Model>` - New model without the variable
pub fn remove_variable(model: &Model, var_name: &str) -> EditResult<Model> {
    let mut new_model = model.clone();

    if new_model.variables.remove(var_name).is_none() {
        return Err(EditError::ComponentNotFound(var_name.to_string()));
    }

    Ok(new_model)
}

/// Add an equation to a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `equation` - The equation to add
///
/// # Returns
///
/// * `EditResult<Model>` - New model with the added equation
pub fn add_equation(model: &Model, equation: Equation) -> EditResult<Model> {
    let mut new_model = model.clone();
    new_model.equations.push(equation);
    Ok(new_model)
}

/// Remove an equation from a model by index
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `index` - Index of the equation to remove
///
/// # Returns
///
/// * `EditResult<Model>` - New model without the equation
pub fn remove_equation(model: &Model, index: usize) -> EditResult<Model> {
    if index >= model.equations.len() {
        return Err(EditError::EquationIndexError(index));
    }

    let mut new_model = model.clone();
    new_model.equations.remove(index);
    Ok(new_model)
}

/// Replace an equation in a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `index` - Index of the equation to replace
/// * `equation` - The new equation
///
/// # Returns
///
/// * `EditResult<Model>` - New model with the replaced equation
pub fn replace_equation(model: &Model, index: usize, equation: Equation) -> EditResult<Model> {
    if index >= model.equations.len() {
        return Err(EditError::EquationIndexError(index));
    }

    let mut new_model = model.clone();
    new_model.equations[index] = equation;
    Ok(new_model)
}

/// Add a reaction system to an ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to modify
/// * `system_id` - Unique identifier for the new reaction system
/// * `system` - The reaction system to add
///
/// # Returns
///
/// * `EditResult<EsmFile>` - New ESM file with the added reaction system
pub fn add_reaction_system(
    esm_file: &EsmFile,
    system_id: &str,
    system: ReactionSystem,
) -> EditResult<EsmFile> {
    let mut new_file = esm_file.clone();

    // Initialize reaction_systems map if it doesn't exist
    if new_file.reaction_systems.is_none() {
        new_file.reaction_systems = Some(HashMap::new());
    }

    // Check if reaction system already exists
    if new_file
        .reaction_systems
        .as_ref()
        .unwrap()
        .contains_key(system_id)
    {
        return Err(EditError::InvalidOperation(format!(
            "Reaction system '{system_id}' already exists"
        )));
    }

    // Add the new reaction system
    new_file
        .reaction_systems
        .as_mut()
        .unwrap()
        .insert(system_id.to_string(), system);

    Ok(new_file)
}

/// Add a species to a reaction system
///
/// # Arguments
///
/// * `system` - The reaction system to modify
/// * `name` - Unique species name (used as the map key)
/// * `species` - The species to add
///
/// # Returns
///
/// * `EditResult<ReactionSystem>` - New reaction system with the added species
pub fn add_species(
    system: &ReactionSystem,
    name: &str,
    species: Species,
) -> EditResult<ReactionSystem> {
    let mut new_system = system.clone();

    if new_system.species.contains_key(name) {
        return Err(EditError::InvalidOperation(format!(
            "Species '{name}' already exists"
        )));
    }

    new_system.species.insert(name.to_string(), species);
    Ok(new_system)
}

/// Remove a species from a reaction system
///
/// # Arguments
///
/// * `system` - The reaction system to modify
/// * `species_name` - Name of the species to remove
///
/// # Returns
///
/// * `EditResult<ReactionSystem>` - New reaction system without the species
pub fn remove_species(system: &ReactionSystem, species_name: &str) -> EditResult<ReactionSystem> {
    let mut new_system = system.clone();

    if new_system.species.remove(species_name).is_none() {
        return Err(EditError::SpeciesNotFound(species_name.to_string()));
    }

    Ok(new_system)
}

/// Add a reaction to a reaction system
///
/// # Arguments
///
/// * `system` - The reaction system to modify
/// * `reaction` - The reaction to add
///
/// # Returns
///
/// * `EditResult<ReactionSystem>` - New reaction system with the added reaction
pub fn add_reaction(system: &ReactionSystem, reaction: Reaction) -> EditResult<ReactionSystem> {
    let mut new_system = system.clone();
    new_system.reactions.push(reaction);
    Ok(new_system)
}

/// Remove a reaction from a reaction system by index
///
/// # Arguments
///
/// * `system` - The reaction system to modify
/// * `index` - Index of the reaction to remove
///
/// # Returns
///
/// * `EditResult<ReactionSystem>` - New reaction system without the reaction
pub fn remove_reaction(system: &ReactionSystem, index: usize) -> EditResult<ReactionSystem> {
    if index >= system.reactions.len() {
        return Err(EditError::InvalidOperation(format!(
            "Reaction index {index} out of bounds"
        )));
    }

    let mut new_system = system.clone();
    new_system.reactions.remove(index);
    Ok(new_system)
}

/// Update model metadata
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `name` - New name (None to keep current)
/// * `description` - New description (None to keep current)
///
/// # Returns
///
/// * `EditResult<Model>` - New model with updated metadata
pub fn update_model_metadata(
    model: &Model,
    name: Option<String>,
    description: Option<String>,
) -> EditResult<Model> {
    let mut new_model = model.clone();

    if let Some(new_name) = name {
        new_model.name = Some(new_name);
    }

    if let Some(new_desc) = description {
        new_model.description = Some(new_desc);
    }

    Ok(new_model)
}

/// Create a copy of an expression with variable substitution
///
/// # Arguments
///
/// * `expr` - The expression to modify
/// * `substitutions` - Map of variable names to replacement expressions
///
/// # Returns
///
/// * `Expr` - New expression with substitutions applied
pub fn substitute_in_expression(expr: &Expr, substitutions: &HashMap<String, Expr>) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(var) => {
            if let Some(replacement) = substitutions.get(var) {
                replacement.clone()
            } else {
                Expr::Variable(var.clone())
            }
        }
        Expr::Operator(node) => {
            let new_args = node
                .args
                .iter()
                .map(|arg| substitute_in_expression(arg, substitutions))
                .collect();

            Expr::Operator(ExpressionNode {
                op: node.op.clone(),
                args: new_args,
                wrt: node.wrt.clone(),
                dim: node.dim.clone(),
                ..Default::default()
            })
        }
    }
}

/// Add a discrete event to a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `event` - The discrete event to add
///
/// # Returns
///
/// * `EditResult<Model>` - New model with the added discrete event
pub fn add_discrete_event(model: &Model, event: DiscreteEvent) -> EditResult<Model> {
    let mut new_model = model.clone();
    new_model
        .discrete_events
        .get_or_insert_with(Vec::new)
        .push(event);
    Ok(new_model)
}

/// Remove a discrete event from a model by index
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `index` - Index of the discrete event to remove
///
/// # Returns
///
/// * `EditResult<Model>` - New model without the discrete event
pub fn remove_discrete_event(model: &Model, index: usize) -> EditResult<Model> {
    let mut new_model = model.clone();
    remove_from_optional_vec(
        &mut new_model.discrete_events,
        index,
        EditError::EventIndexError,
    )?;
    Ok(new_model)
}

/// Add a continuous event to a model
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `event` - The continuous event to add
///
/// # Returns
///
/// * `EditResult<Model>` - New model with the added continuous event
pub fn add_continuous_event(model: &Model, event: ContinuousEvent) -> EditResult<Model> {
    let mut new_model = model.clone();
    new_model
        .continuous_events
        .get_or_insert_with(Vec::new)
        .push(event);
    Ok(new_model)
}

/// Remove a continuous event from a model by index
///
/// # Arguments
///
/// * `model` - The model to modify
/// * `index` - Index of the continuous event to remove
///
/// # Returns
///
/// * `EditResult<Model>` - New model without the continuous event
pub fn remove_continuous_event(model: &Model, index: usize) -> EditResult<Model> {
    let mut new_model = model.clone();
    remove_from_optional_vec(
        &mut new_model.continuous_events,
        index,
        EditError::EventIndexError,
    )?;
    Ok(new_model)
}

/// Add a coupling entry to an ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to modify
/// * `coupling` - The coupling entry to add
///
/// # Returns
///
/// * `EditResult<EsmFile>` - New ESM file with the added coupling entry
pub fn add_coupling(esm_file: &EsmFile, coupling: CouplingEntry) -> EditResult<EsmFile> {
    let mut new_file = esm_file.clone();
    new_file
        .coupling
        .get_or_insert_with(Vec::new)
        .push(coupling);
    Ok(new_file)
}

/// Remove a coupling entry from an ESM file by index
///
/// # Arguments
///
/// * `esm_file` - The ESM file to modify
/// * `index` - Index of the coupling entry to remove
///
/// # Returns
///
/// * `EditResult<EsmFile>` - New ESM file without the coupling entry
pub fn remove_coupling(esm_file: &EsmFile, index: usize) -> EditResult<EsmFile> {
    let mut new_file = esm_file.clone();
    remove_from_optional_vec(&mut new_file.coupling, index, EditError::CouplingIndexError)?;
    Ok(new_file)
}

/// Replace a coupling entry in an ESM file
///
/// # Arguments
///
/// * `esm_file` - The ESM file to modify
/// * `index` - Index of the coupling entry to replace
/// * `coupling` - The new coupling entry
///
/// # Returns
///
/// * `EditResult<EsmFile>` - New ESM file with the replaced coupling entry
pub fn replace_coupling(
    esm_file: &EsmFile,
    index: usize,
    coupling: CouplingEntry,
) -> EditResult<EsmFile> {
    let mut new_file = esm_file.clone();

    if let Some(ref mut coupling_entries) = new_file.coupling {
        if index >= coupling_entries.len() {
            return Err(EditError::CouplingIndexError(index));
        }
        coupling_entries[index] = coupling;
    } else {
        return Err(EditError::CouplingIndexError(index));
    }

    Ok(new_file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Metadata, VariableType};
    use std::collections::HashMap;

    fn create_empty_esm_file() -> EsmFile {
        EsmFile {
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
        }
    }

    fn create_simple_model() -> Model {
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
        }
    }

    #[test]
    fn test_add_model() {
        let esm_file = create_empty_esm_file();
        let model = create_simple_model();

        let result = add_model(&esm_file, "test_model", model);
        assert!(result.is_ok());

        let new_file = result.unwrap();
        assert!(new_file.models.is_some());
        assert!(new_file.models.as_ref().unwrap().contains_key("test_model"));
    }

    #[test]
    fn test_add_duplicate_model() {
        let esm_file = create_empty_esm_file();
        let model = create_simple_model();

        let result1 = add_model(&esm_file, "test_model", model.clone());
        assert!(result1.is_ok());

        let new_file = result1.unwrap();
        let result2 = add_model(&new_file, "test_model", model);
        assert!(result2.is_err());
        assert!(matches!(
            result2.unwrap_err(),
            EditError::InvalidOperation(_)
        ));
    }

    #[test]
    fn test_add_variable() {
        let model = create_simple_model();
        let variable = ModelVariable {
            var_type: VariableType::Parameter,
            units: Some("mol/L".to_string()),
            default: Some(1.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        };

        let result = add_variable(&model, "test_var", variable);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert!(new_model.variables.contains_key("test_var"));
    }

    #[test]
    fn test_add_duplicate_variable() {
        let mut model = create_simple_model();
        model.variables.insert(
            "existing_var".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: None,
                default: None,
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        let variable = ModelVariable {
            var_type: VariableType::State,
            units: Some("mol/L".to_string()),
            default: Some(1.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        };

        let result = add_variable(&model, "existing_var", variable);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), EditError::VariableExists(_)));
    }

    #[test]
    fn test_add_equation() {
        let model = create_simple_model();
        let equation = Equation {
            lhs: Expr::Variable("x".to_string()),
            rhs: Expr::Number(1.0),
        };

        let result = add_equation(&model, equation);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert_eq!(new_model.equations.len(), 1);
    }

    #[test]
    fn test_remove_equation() {
        let mut model = create_simple_model();
        model.equations.push(Equation {
            lhs: Expr::Variable("x".to_string()),
            rhs: Expr::Number(1.0),
        });

        let result = remove_equation(&model, 0);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert_eq!(new_model.equations.len(), 0);

        // Test out of bounds
        let result = remove_equation(&model, 1);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            EditError::EquationIndexError(_)
        ));
    }

    #[test]
    fn test_substitute_in_expression() {
        let expr = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let mut substitutions = HashMap::new();
        substitutions.insert("x".to_string(), Expr::Number(5.0));

        let result = substitute_in_expression(&expr, &substitutions);

        if let Expr::Operator(node) = result {
            assert_eq!(node.op, "+");
            assert_eq!(node.args.len(), 2);
            assert!(matches!(node.args[0], Expr::Number(5.0)));
            assert!(matches!(node.args[1], Expr::Number(1.0)));
        } else {
            panic!("Expected operator expression");
        }
    }

    #[test]
    fn test_add_discrete_event() {
        use crate::{AffectEquation, DiscreteEventTrigger};

        let model = create_simple_model();
        let event = DiscreteEvent {
            name: Some("test_discrete_event".to_string()),
            trigger: DiscreteEventTrigger::Condition {
                expression: Expr::Variable("x".to_string()),
            },
            affects: Some(vec![AffectEquation {
                lhs: "state_var".to_string(),
                rhs: Expr::Number(1.0),
            }]),
            functional_affect: None,
            discrete_parameters: None,
            reinitialize: None,
            description: None,
        };

        let result = add_discrete_event(&model, event);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert!(new_model.discrete_events.is_some());
        assert_eq!(new_model.discrete_events.as_ref().unwrap().len(), 1);
        assert_eq!(
            new_model.discrete_events.as_ref().unwrap()[0].name,
            Some("test_discrete_event".to_string())
        );
    }

    #[test]
    fn test_remove_discrete_event() {
        use crate::{AffectEquation, DiscreteEventTrigger};

        let mut model = create_simple_model();
        model.discrete_events = Some(vec![DiscreteEvent {
            name: Some("event_to_remove".to_string()),
            trigger: DiscreteEventTrigger::Condition {
                expression: Expr::Variable("x".to_string()),
            },
            affects: Some(vec![AffectEquation {
                lhs: "state_var".to_string(),
                rhs: Expr::Number(1.0),
            }]),
            functional_affect: None,
            discrete_parameters: None,
            reinitialize: None,
            description: None,
        }]);

        // Test successful removal
        let result = remove_discrete_event(&model, 0);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert!(new_model.discrete_events.is_none()); // Should be None when empty

        // Test out of bounds error
        let result = remove_discrete_event(&model, 1);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), EditError::EventIndexError(1)));

        // Test error when no events exist
        let empty_model = create_simple_model();
        let result = remove_discrete_event(&empty_model, 0);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), EditError::EventIndexError(0)));
    }

    #[test]
    fn test_add_continuous_event() {
        use crate::AffectEquation;

        let model = create_simple_model();
        let event = ContinuousEvent {
            name: Some("test_continuous_event".to_string()),
            conditions: vec![Expr::Variable("x".to_string())],
            affects: vec![AffectEquation {
                lhs: "state_var".to_string(),
                rhs: Expr::Number(2.0),
            }],
            affect_neg: None,
            root_find: None,
            reinitialize: None,
            discrete_parameters: None,
            priority: None,
            description: None,
        };

        let result = add_continuous_event(&model, event);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert!(new_model.continuous_events.is_some());
        assert_eq!(new_model.continuous_events.as_ref().unwrap().len(), 1);
        assert_eq!(
            new_model.continuous_events.as_ref().unwrap()[0].name,
            Some("test_continuous_event".to_string())
        );
    }

    #[test]
    fn test_remove_continuous_event() {
        use crate::AffectEquation;

        let mut model = create_simple_model();
        model.continuous_events = Some(vec![ContinuousEvent {
            name: Some("event_to_remove".to_string()),
            conditions: vec![Expr::Variable("x".to_string())],
            affects: vec![AffectEquation {
                lhs: "state_var".to_string(),
                rhs: Expr::Number(2.0),
            }],
            affect_neg: None,
            root_find: None,
            reinitialize: None,
            discrete_parameters: None,
            priority: None,
            description: None,
        }]);

        // Test successful removal
        let result = remove_continuous_event(&model, 0);
        assert!(result.is_ok());

        let new_model = result.unwrap();
        assert!(new_model.continuous_events.is_none()); // Should be None when empty

        // Test out of bounds error
        let result = remove_continuous_event(&model, 1);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), EditError::EventIndexError(1)));

        // Test error when no events exist
        let empty_model = create_simple_model();
        let result = remove_continuous_event(&empty_model, 0);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), EditError::EventIndexError(0)));
    }

    #[test]
    fn test_multiple_discrete_events() {
        use crate::{AffectEquation, DiscreteEventTrigger};

        let model = create_simple_model();

        let event1 = DiscreteEvent {
            name: Some("event1".to_string()),
            trigger: DiscreteEventTrigger::Condition {
                expression: Expr::Variable("x".to_string()),
            },
            affects: None,
            functional_affect: None,
            discrete_parameters: None,
            reinitialize: None,
            description: None,
        };

        let event2 = DiscreteEvent {
            name: Some("event2".to_string()),
            trigger: DiscreteEventTrigger::Periodic {
                interval: 1.0,
                initial_offset: Some(0.5),
            },
            affects: Some(vec![AffectEquation {
                lhs: "y".to_string(),
                rhs: Expr::Number(5.0),
            }]),
            functional_affect: None,
            discrete_parameters: None,
            reinitialize: Some(true),
            description: Some("Periodic event".to_string()),
        };

        // Add first event
        let result1 = add_discrete_event(&model, event1);
        assert!(result1.is_ok());
        let model_with_one = result1.unwrap();

        // Add second event
        let result2 = add_discrete_event(&model_with_one, event2);
        assert!(result2.is_ok());
        let model_with_two = result2.unwrap();

        assert!(model_with_two.discrete_events.is_some());
        assert_eq!(model_with_two.discrete_events.as_ref().unwrap().len(), 2);

        // Remove middle event (index 0)
        let result3 = remove_discrete_event(&model_with_two, 0);
        assert!(result3.is_ok());
        let model_with_one_removed = result3.unwrap();

        assert!(model_with_one_removed.discrete_events.is_some());
        assert_eq!(
            model_with_one_removed
                .discrete_events
                .as_ref()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            model_with_one_removed.discrete_events.as_ref().unwrap()[0].name,
            Some("event2".to_string())
        );
    }

    #[test]
    fn test_add_coupling() {
        let esm_file = create_empty_esm_file();
        let coupling = CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["system1".to_string(), "system2".to_string()],
            translate: None,
            description: Some("Test coupling".to_string()),
        };

        let result = add_coupling(&esm_file, coupling);
        assert!(result.is_ok());

        let new_file = result.unwrap();
        assert!(new_file.coupling.is_some());
        assert_eq!(new_file.coupling.as_ref().unwrap().len(), 1);

        match &new_file.coupling.as_ref().unwrap()[0] {
            CouplingEntry::OperatorCompose {
                systems,
                description,
                ..
            } => {
                assert_eq!(systems, &vec!["system1", "system2"]);
                assert_eq!(description, &Some("Test coupling".to_string()));
            }
            _ => panic!("Expected OperatorCompose coupling entry"),
        }
    }

    #[test]
    fn test_add_multiple_couplings() {
        let esm_file = create_empty_esm_file();

        let coupling1 = CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["system1".to_string(), "system2".to_string()],
            translate: None,
            description: None,
        };

        let coupling2 = CouplingEntry::VariableMap {
            from: "model1.x".to_string(),
            to: "model2.y".to_string(),
            transform: crate::types::VariableMapTransform::Named("identity".to_string()),
            factor: None,
            description: Some("Variable mapping".to_string()),
        };

        // Add first coupling
        let result1 = add_coupling(&esm_file, coupling1);
        assert!(result1.is_ok());
        let file_with_one = result1.unwrap();

        // Add second coupling
        let result2 = add_coupling(&file_with_one, coupling2);
        assert!(result2.is_ok());
        let file_with_two = result2.unwrap();

        assert!(file_with_two.coupling.is_some());
        assert_eq!(file_with_two.coupling.as_ref().unwrap().len(), 2);
    }

    #[test]
    fn test_remove_coupling() {
        let mut esm_file = create_empty_esm_file();
        esm_file.coupling = Some(vec![
            CouplingEntry::OperatorCompose {
                lifting: None,
                systems: vec!["system1".to_string(), "system2".to_string()],
                translate: None,
                description: Some("First coupling".to_string()),
            },
            CouplingEntry::VariableMap {
                from: "model1.x".to_string(),
                to: "model2.y".to_string(),
                transform: crate::types::VariableMapTransform::Named("identity".to_string()),
                factor: None,
                description: Some("Second coupling".to_string()),
            },
        ]);

        // Test successful removal of first entry
        let result = remove_coupling(&esm_file, 0);
        assert!(result.is_ok());

        let new_file = result.unwrap();
        assert!(new_file.coupling.is_some());
        assert_eq!(new_file.coupling.as_ref().unwrap().len(), 1);

        // Verify the remaining entry is the second one
        match &new_file.coupling.as_ref().unwrap()[0] {
            CouplingEntry::VariableMap { description, .. } => {
                assert_eq!(description, &Some("Second coupling".to_string()));
            }
            _ => panic!("Expected VariableMap coupling entry"),
        }

        // Test out of bounds error
        let result = remove_coupling(&esm_file, 5);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            EditError::CouplingIndexError(5)
        ));

        // Test error when no coupling entries exist
        let empty_file = create_empty_esm_file();
        let result = remove_coupling(&empty_file, 0);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            EditError::CouplingIndexError(0)
        ));
    }

    #[test]
    fn test_remove_last_coupling() {
        let mut esm_file = create_empty_esm_file();
        esm_file.coupling = Some(vec![CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["system1".to_string(), "system2".to_string()],
            translate: None,
            description: Some("Only coupling".to_string()),
        }]);

        // Remove the only coupling entry
        let result = remove_coupling(&esm_file, 0);
        assert!(result.is_ok());

        let new_file = result.unwrap();
        assert!(new_file.coupling.is_none()); // Should be None when empty
    }

    #[test]
    fn test_replace_coupling() {
        let mut esm_file = create_empty_esm_file();
        esm_file.coupling = Some(vec![CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["old_system1".to_string(), "old_system2".to_string()],
            translate: None,
            description: Some("Old coupling".to_string()),
        }]);

        let new_coupling = CouplingEntry::VariableMap {
            from: "new_source.var".to_string(),
            to: "new_target.param".to_string(),
            transform: crate::types::VariableMapTransform::Named("linear".to_string()),
            factor: Some(2.0),
            description: Some("New coupling".to_string()),
        };

        // Test successful replacement
        let result = replace_coupling(&esm_file, 0, new_coupling);
        assert!(result.is_ok());

        let new_file = result.unwrap();
        assert!(new_file.coupling.is_some());
        assert_eq!(new_file.coupling.as_ref().unwrap().len(), 1);

        // Verify the entry was replaced
        match &new_file.coupling.as_ref().unwrap()[0] {
            CouplingEntry::VariableMap {
                from,
                to,
                transform,
                factor,
                description,
            } => {
                assert_eq!(from, "new_source.var");
                assert_eq!(to, "new_target.param");
                assert_eq!(
                    transform,
                    &crate::types::VariableMapTransform::Named("linear".to_string())
                );
                assert_eq!(factor, &Some(2.0));
                assert_eq!(description, &Some("New coupling".to_string()));
            }
            _ => panic!("Expected VariableMap coupling entry"),
        }

        // Test out of bounds error
        let dummy_coupling = CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["dummy".to_string()],
            translate: None,
            description: None,
        };
        let result = replace_coupling(&esm_file, 5, dummy_coupling);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            EditError::CouplingIndexError(5)
        ));

        // Test error when no coupling entries exist
        let empty_file = create_empty_esm_file();
        let dummy_coupling2 = CouplingEntry::OperatorCompose {
            lifting: None,
            systems: vec!["dummy".to_string()],
            translate: None,
            description: None,
        };
        let result = replace_coupling(&empty_file, 0, dummy_coupling2);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            EditError::CouplingIndexError(0)
        ));
    }

    #[test]
    fn test_coupling_with_different_entry_types() {
        let esm_file = create_empty_esm_file();

        // Test with OperatorApply coupling
        let operator_apply = CouplingEntry::OperatorApply {
            operator: "my_operator".to_string(),
            description: Some("Operator application".to_string()),
        };

        let result = add_coupling(&esm_file, operator_apply);
        assert!(result.is_ok());

        let new_file = result.unwrap();
        match &new_file.coupling.as_ref().unwrap()[0] {
            CouplingEntry::OperatorApply {
                operator,
                description,
            } => {
                assert_eq!(operator, "my_operator");
                assert_eq!(description, &Some("Operator application".to_string()));
            }
            _ => panic!("Expected OperatorApply coupling entry"),
        }

        // Test with Callback coupling
        let callback_coupling = CouplingEntry::Callback {
            callback_id: "my_callback".to_string(),
            config: Some(serde_json::json!({"param": "value"})),
            description: None,
        };

        let result2 = add_coupling(&new_file, callback_coupling);
        assert!(result2.is_ok());

        let final_file = result2.unwrap();
        assert_eq!(final_file.coupling.as_ref().unwrap().len(), 2);
    }
}
