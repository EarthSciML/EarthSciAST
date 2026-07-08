"""
Editing operations for ESM Format structures.

Provides functions to modify ESM files, models, reaction systems, and their
components in a safe and consistent manner.
"""

from typing import Dict, List, Optional, Union, Any
from dataclasses import dataclass, field, replace
from copy import deepcopy

try:
    from .esm_types import (
        EsmFile,
        Model,
        ReactionSystem,
        ModelVariable,
        Species,
        Reaction,
        Equation,
        Expr,
        ExprNode,
        ContinuousEvent,
        DiscreteEvent,
        CouplingEntry,
        Metadata,
    )
    from .validation import validate, ValidationResult
except ImportError:
    # For direct imports when testing
    from esm_types import (
        EsmFile,
        Model,
        ReactionSystem,
        ModelVariable,
        Species,
        Reaction,
        Equation,
        Expr,
        ExprNode,
        ContinuousEvent,
        DiscreteEvent,
        CouplingEntry,
        Metadata,
    )


@dataclass
class EditOperation:
    """Represents an editing operation that can be applied to an ESM structure."""

    operation_type: str  # 'add', 'remove', 'modify', 'rename'
    target_type: str  # 'model', 'reaction_system', 'variable', 'equation', etc.
    target_id: str  # identifier for the target
    data: Dict[str, Any] = field(default_factory=dict)
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class EditResult:
    """Result of an editing operation."""

    success: bool
    modified_object: Any = None
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    validation_result: Optional[ValidationResult] = None


class ESMEditor:
    """Editor for ESM format structures with validation and safety checks."""

    def __init__(self, validate_after_edit: bool = True):
        """
        Initialize the ESM editor.

        Args:
            validate_after_edit: Whether to validate structures after editing
        """
        self.validate_after_edit = validate_after_edit

    def apply_operation(
        self, target: Union[EsmFile, Model, ReactionSystem], operation: EditOperation
    ) -> EditResult:
        """
        Apply an editing operation to a target structure.

        Args:
            target: The structure to edit
            operation: The editing operation to apply

        Returns:
            EditResult indicating success/failure and any issues
        """
        try:
            # Make a deep copy to avoid modifying the original
            modified = deepcopy(target)

            if isinstance(target, EsmFile):
                result = self._apply_esm_file_operation(modified, operation)
            elif isinstance(target, Model):
                result = self._apply_model_operation(modified, operation)
            elif isinstance(target, ReactionSystem):
                result = self._apply_reaction_system_operation(modified, operation)
            else:
                return EditResult(
                    success=False, errors=[f"Unsupported target type: {type(target)}"]
                )

            if result.success and self.validate_after_edit:
                try:
                    validation_result = validate(result.modified_object)
                    result.validation_result = validation_result
                    if not validation_result.is_valid:
                        result.warnings.append("Modified structure has validation issues")
                except Exception as e:
                    result.warnings.append(f"Validation failed: {e}")

            return result

        except Exception as e:
            return EditResult(success=False, errors=[f"Edit operation failed: {e}"])

    def remove_variable(self, model: Model, var_name: str) -> EditResult:
        """Remove a variable from a model."""
        operation = EditOperation(
            operation_type="remove", target_type="variable", target_id=var_name
        )
        return self.apply_operation(model, operation)

    def add_variable(self, model: Model, var_name: str, var_info: ModelVariable) -> EditResult:
        """Add a variable to a model."""
        operation = EditOperation(
            operation_type="add",
            target_type="variable",
            target_id=var_name,
            data={"variable": var_info},
        )
        return self.apply_operation(model, operation)

    def modify_variable(self, model: Model, var_name: str, **updates) -> EditResult:
        """Modify a variable in a model."""
        operation = EditOperation(
            operation_type="modify", target_type="variable", target_id=var_name, data=updates
        )
        return self.apply_operation(model, operation)

    def add_equation(self, model: Model, equation: Equation) -> EditResult:
        """Add an equation to a model."""
        operation = EditOperation(
            operation_type="add",
            target_type="equation",
            target_id=f"eq_{len(model.equations) if model.equations else 0}",
            data={"equation": equation},
        )
        return self.apply_operation(model, operation)

    def remove_equation(self, model: Model, index: int) -> EditResult:
        """Remove an equation from a model by index."""
        operation = EditOperation(
            operation_type="remove", target_type="equation", target_id=str(index)
        )
        return self.apply_operation(model, operation)

    def add_species(self, reaction_system: ReactionSystem, species: Species) -> EditResult:
        """Add a species to a reaction system."""
        operation = EditOperation(
            operation_type="add",
            target_type="species",
            target_id=species.name,
            data={"species": species},
        )
        return self.apply_operation(reaction_system, operation)

    def add_reaction(self, reaction_system: ReactionSystem, reaction: Reaction) -> EditResult:
        """Add a reaction to a reaction system."""
        operation = EditOperation(
            operation_type="add",
            target_type="reaction",
            target_id=reaction.name,
            data={"reaction": reaction},
        )
        return self.apply_operation(reaction_system, operation)

    def remove_reaction(self, reaction_system: ReactionSystem, reaction_name: str) -> EditResult:
        """Remove a reaction from a reaction system."""
        operation = EditOperation(
            operation_type="remove", target_type="reaction", target_id=reaction_name
        )
        return self.apply_operation(reaction_system, operation)

    def remove_species(self, reaction_system: ReactionSystem, species_name: str) -> EditResult:
        """Remove a species from a reaction system."""
        operation = EditOperation(
            operation_type="remove", target_type="species", target_id=species_name
        )
        return self.apply_operation(reaction_system, operation)

    def add_continuous_event(self, model: Model, event: ContinuousEvent) -> EditResult:
        """Add a continuous event to a model."""
        operation = EditOperation(
            operation_type="add",
            target_type="continuous_event",
            target_id=event.name,
            data={"event": event},
        )
        return self.apply_operation(model, operation)

    def add_discrete_event(self, model: Model, event: DiscreteEvent) -> EditResult:
        """Add a discrete event to a model."""
        operation = EditOperation(
            operation_type="add",
            target_type="discrete_event",
            target_id=event.name,
            data={"event": event},
        )
        return self.apply_operation(model, operation)

    def remove_event(self, model: Model, event_name: str) -> EditResult:
        """Remove an event from a model (searches both continuous and discrete events)."""
        operation = EditOperation(
            operation_type="remove", target_type="event", target_id=event_name
        )
        return self.apply_operation(model, operation)

    def add_coupling(self, esm_file: EsmFile, coupling: CouplingEntry) -> EditResult:
        """Add a coupling entry to an ESM file."""
        operation = EditOperation(
            operation_type="add",
            target_type="coupling",
            target_id=f"coupling_{len(esm_file.coupling) if esm_file.coupling else 0}",
            data={"coupling": coupling},
        )
        return self.apply_operation(esm_file, operation)

    def remove_coupling(self, esm_file: EsmFile, index: int) -> EditResult:
        """Remove a coupling entry from an ESM file by index."""
        operation = EditOperation(
            operation_type="remove", target_type="coupling", target_id=str(index)
        )
        return self.apply_operation(esm_file, operation)

    def substitute_in_expression(self, expr: Expr, substitutions: Dict[str, Expr]) -> Expr:
        """
        Substitute variables in an expression.

        Args:
            expr: The expression to modify
            substitutions: Dict mapping variable names to replacement expressions

        Returns:
            Modified expression with substitutions applied
        """
        if isinstance(expr, str):
            return substitutions.get(expr, expr)

        elif isinstance(expr, (int, float)):
            return expr

        elif isinstance(expr, ExprNode):
            # Recursively substitute in arguments
            new_args = [self.substitute_in_expression(arg, substitutions) for arg in expr.args]
            return replace(expr, args=new_args)

        return expr

    def rename_variable(
        self, target: Union[Model, ReactionSystem], old_name: str, new_name: str
    ) -> EditResult:
        """
        Rename a variable throughout a model or reaction system.

        Args:
            target: The model or reaction system to modify
            old_name: Current variable name
            new_name: New variable name

        Returns:
            EditResult with the modified structure
        """
        operation = EditOperation(
            operation_type="rename",
            target_type="variable",
            target_id=old_name,
            data={"new_name": new_name},
        )
        return self.apply_operation(target, operation)

    def merge(self, file_a: EsmFile, file_b: EsmFile) -> EditResult:
        """
        Merge two ESM files.

        Args:
            file_a: First ESM file
            file_b: Second ESM file (takes precedence in conflicts)

        Returns:
            EditResult with the merged ESM file
        """
        try:
            # Make deep copies to avoid modifying originals
            merged_file = deepcopy(file_a)

            # Merge models (dict merge)
            if file_b.models:
                if not merged_file.models:
                    merged_file.models = {}
                merged_file.models.update(file_b.models)

            # Merge reaction systems (dict merge)
            if file_b.reaction_systems:
                if not merged_file.reaction_systems:
                    merged_file.reaction_systems = {}
                merged_file.reaction_systems.update(file_b.reaction_systems)

            # Merge events (list extend)
            if file_b.events:
                if not merged_file.events:
                    merged_file.events = []
                merged_file.events.extend(file_b.events)

            # Merge data_loaders (dict merge; file_b takes precedence on key collision)
            if file_b.data_loaders:
                if not merged_file.data_loaders:
                    merged_file.data_loaders = {}
                merged_file.data_loaders.update(file_b.data_loaders)

            # Merge operators (list extend)
            if file_b.operators:
                if not merged_file.operators:
                    merged_file.operators = []
                merged_file.operators.extend(file_b.operators)

            # Merge coupling (list extend)
            if file_b.coupling:
                if not merged_file.coupling:
                    merged_file.coupling = []
                merged_file.coupling.extend(file_b.coupling)

            # Other fields from file_b take precedence
            if hasattr(file_b, "metadata") and file_b.metadata:
                merged_file.metadata = file_b.metadata
            if getattr(file_b, "domain", None) is not None:
                merged_file.domain = file_b.domain

            return EditResult(success=True, modified_object=merged_file)

        except Exception as e:
            return EditResult(success=False, errors=[f"Merge failed: {e}"])

    def extract(self, esm_file: EsmFile, component_name: str) -> EditResult:
        """
        Extract a single component into a standalone ESM file.

        Args:
            esm_file: The source ESM file
            component_name: Name of the component to extract

        Returns:
            EditResult with the extracted ESM file
        """
        try:
            # Create a new ESM file with only the specified component
            # Use minimal metadata for the extracted file
            extracted_metadata = Metadata(
                title=f"Extracted: {component_name}",
                description=f"Component '{component_name}' extracted from {esm_file.metadata.title if esm_file.metadata else 'source file'}",
            )

            extracted_file = EsmFile(
                version=esm_file.version,
                metadata=extracted_metadata,
                models={},
                reaction_systems={},
                coupling=[],
            )

            found_component = False

            # Find and extract the component from models
            if esm_file.models and component_name in esm_file.models:
                extracted_file.models[component_name] = deepcopy(esm_file.models[component_name])
                found_component = True

            # Find and extract the component from reaction systems
            if esm_file.reaction_systems and component_name in esm_file.reaction_systems:
                extracted_file.reaction_systems[component_name] = deepcopy(
                    esm_file.reaction_systems[component_name]
                )
                found_component = True

            # Find relevant coupling entries that involve the extracted component
            if esm_file.coupling:
                for coupling in esm_file.coupling:
                    # Check if coupling involves the extracted component
                    should_include = False

                    # Check systems field (for operator_compose, couple)
                    if coupling.systems and component_name in coupling.systems:
                        should_include = True

                    # Check from_var/to_var fields (for variable_map)
                    if coupling.from_var and coupling.from_var.startswith(f"{component_name}."):
                        should_include = True
                    if coupling.to_var and coupling.to_var.startswith(f"{component_name}."):
                        should_include = True

                    # Check operator field (for operator_apply)
                    if coupling.operator and coupling.operator == component_name:
                        should_include = True

                    if should_include:
                        extracted_file.coupling.append(deepcopy(coupling))

            # Copy relevant events that might belong to this component
            if esm_file.events:
                for event in esm_file.events:
                    # This is a simple heuristic - include events that might be related
                    # A more sophisticated implementation would check variable references
                    extracted_file.events.append(deepcopy(event))

            if not found_component:
                return EditResult(
                    success=False,
                    errors=[f"Component '{component_name}' not found in the ESM file"],
                )

            return EditResult(success=True, modified_object=extracted_file)

        except Exception as e:
            return EditResult(success=False, errors=[f"Extract failed: {e}"])

    def _apply_esm_file_operation(self, esm_file: EsmFile, operation: EditOperation) -> EditResult:
        """Apply an operation to an ESM file."""
        if operation.target_type == "coupling":
            if operation.operation_type == "add":
                coupling = operation.data.get("coupling")
                if not coupling:
                    return EditResult(success=False, errors=["No coupling data provided"])

                if not esm_file.coupling:
                    esm_file.coupling = []

                esm_file.coupling.append(coupling)
                return EditResult(success=True, modified_object=esm_file)

            elif operation.operation_type == "remove":
                try:
                    index = int(operation.target_id)
                    if not esm_file.coupling or index < 0 or index >= len(esm_file.coupling):
                        return EditResult(
                            success=False, errors=[f"Coupling index {index} out of bounds"]
                        )

                    del esm_file.coupling[index]
                    return EditResult(success=True, modified_object=esm_file)
                except ValueError:
                    return EditResult(success=False, errors=["Invalid coupling index"])

        return EditResult(
            success=False,
            errors=[
                f"Unsupported operation: {operation.operation_type} on {operation.target_type}"
            ],
        )

    def _apply_model_operation(self, model: Model, operation: EditOperation) -> EditResult:
        """Apply an operation to a model."""
        if operation.target_type == "variable":
            if operation.operation_type == "add":
                variable = operation.data.get("variable")
                if not variable:
                    return EditResult(success=False, errors=["No variable data provided"])

                if not model.variables:
                    model.variables = {}

                if operation.target_id in model.variables:
                    return EditResult(
                        success=False, errors=[f"Variable '{operation.target_id}' already exists"]
                    )

                model.variables[operation.target_id] = variable
                return EditResult(success=True, modified_object=model)

            elif operation.operation_type == "remove":
                if not model.variables or operation.target_id not in model.variables:
                    return EditResult(
                        success=False, errors=[f"Variable '{operation.target_id}' not found"]
                    )

                del model.variables[operation.target_id]
                return EditResult(success=True, modified_object=model)

            elif operation.operation_type == "modify":
                if not model.variables or operation.target_id not in model.variables:
                    return EditResult(
                        success=False, errors=[f"Variable '{operation.target_id}' not found"]
                    )

                # Apply updates to the variable
                current_var = model.variables[operation.target_id]
                for key, value in operation.data.items():
                    if hasattr(current_var, key):
                        setattr(current_var, key, value)

                return EditResult(success=True, modified_object=model)

            elif operation.operation_type == "rename":
                new_name = operation.data.get("new_name")
                if not new_name:
                    return EditResult(success=False, errors=["No new name provided"])

                if not model.variables or operation.target_id not in model.variables:
                    return EditResult(
                        success=False, errors=[f"Variable '{operation.target_id}' not found"]
                    )

                if new_name in model.variables:
                    return EditResult(
                        success=False, errors=[f"Variable '{new_name}' already exists"]
                    )

                # Rename the variable
                var_info = model.variables.pop(operation.target_id)
                model.variables[new_name] = var_info

                # Update references in equations
                if model.equations:
                    substitutions = {operation.target_id: new_name}
                    for i, equation in enumerate(model.equations):
                        new_lhs = self.substitute_in_expression(equation.lhs, substitutions)
                        new_rhs = self.substitute_in_expression(equation.rhs, substitutions)
                        model.equations[i] = replace(equation, lhs=new_lhs, rhs=new_rhs)

                return EditResult(success=True, modified_object=model)

        elif operation.target_type == "equation":
            if operation.operation_type == "add":
                equation = operation.data.get("equation")
                if not equation:
                    return EditResult(success=False, errors=["No equation data provided"])

                if not model.equations:
                    model.equations = []

                model.equations.append(equation)
                return EditResult(success=True, modified_object=model)

            elif operation.operation_type == "remove":
                try:
                    index = int(operation.target_id)
                    if not model.equations or index < 0 or index >= len(model.equations):
                        return EditResult(
                            success=False, errors=[f"Equation index {index} out of bounds"]
                        )

                    del model.equations[index]
                    return EditResult(success=True, modified_object=model)
                except ValueError:
                    return EditResult(success=False, errors=["Invalid equation index"])

        elif operation.target_type == "continuous_event":
            if operation.operation_type == "add":
                event = operation.data.get("event")
                if not event:
                    return EditResult(success=False, errors=["No event data provided"])

                if not hasattr(model, "continuous_events") or not model.continuous_events:
                    model.continuous_events = []

                model.continuous_events.append(event)
                return EditResult(success=True, modified_object=model)

        elif operation.target_type == "discrete_event":
            if operation.operation_type == "add":
                event = operation.data.get("event")
                if not event:
                    return EditResult(success=False, errors=["No event data provided"])

                if not hasattr(model, "discrete_events") or not model.discrete_events:
                    model.discrete_events = []

                model.discrete_events.append(event)
                return EditResult(success=True, modified_object=model)

        elif operation.target_type == "event":
            if operation.operation_type == "remove":
                event_name = operation.target_id
                removed = False

                # Remove from continuous events
                if hasattr(model, "continuous_events") and model.continuous_events:
                    original_count = len(model.continuous_events)
                    model.continuous_events = [
                        e for e in model.continuous_events if e.name != event_name
                    ]
                    removed = removed or len(model.continuous_events) < original_count

                # Remove from discrete events
                if hasattr(model, "discrete_events") and model.discrete_events:
                    original_count = len(model.discrete_events)
                    model.discrete_events = [
                        e for e in model.discrete_events if e.name != event_name
                    ]
                    removed = removed or len(model.discrete_events) < original_count

                if not removed:
                    return EditResult(success=False, errors=[f"Event '{event_name}' not found"])

                return EditResult(success=True, modified_object=model)

        return EditResult(
            success=False,
            errors=[
                f"Unsupported operation: {operation.operation_type} on {operation.target_type}"
            ],
        )

    def _apply_reaction_system_operation(
        self, rs: ReactionSystem, operation: EditOperation
    ) -> EditResult:
        """Apply an operation to a reaction system."""
        if operation.target_type == "species":
            if operation.operation_type == "add":
                species = operation.data.get("species")
                if not species:
                    return EditResult(success=False, errors=["No species data provided"])

                if not rs.species:
                    rs.species = []

                # Check for duplicate names
                if any(s.name == species.name for s in rs.species):
                    return EditResult(
                        success=False, errors=[f"Species '{species.name}' already exists"]
                    )

                rs.species.append(species)
                return EditResult(success=True, modified_object=rs)

            elif operation.operation_type == "remove":
                species_name = operation.target_id
                if not rs.species:
                    return EditResult(success=False, errors=["No species to remove"])

                original_count = len(rs.species)
                rs.species = [s for s in rs.species if s.name != species_name]

                if len(rs.species) == original_count:
                    return EditResult(success=False, errors=[f"Species '{species_name}' not found"])

                return EditResult(success=True, modified_object=rs)

        elif operation.target_type == "reaction":
            if operation.operation_type == "add":
                reaction = operation.data.get("reaction")
                if not reaction:
                    return EditResult(success=False, errors=["No reaction data provided"])

                if not rs.reactions:
                    rs.reactions = []

                # Check for duplicate names
                if any(r.name == reaction.name for r in rs.reactions):
                    return EditResult(
                        success=False, errors=[f"Reaction '{reaction.name}' already exists"]
                    )

                rs.reactions.append(reaction)
                return EditResult(success=True, modified_object=rs)

            elif operation.operation_type == "remove":
                reaction_name = operation.target_id
                if not rs.reactions:
                    return EditResult(success=False, errors=["No reactions to remove"])

                original_count = len(rs.reactions)
                rs.reactions = [r for r in rs.reactions if r.name != reaction_name]

                if len(rs.reactions) == original_count:
                    return EditResult(
                        success=False, errors=[f"Reaction '{reaction_name}' not found"]
                    )

                return EditResult(success=True, modified_object=rs)

        elif operation.target_type == "parameter":
            if operation.operation_type == "add":
                parameter = operation.data.get("parameter")
                if not parameter:
                    return EditResult(success=False, errors=["No parameter data provided"])

                if not rs.parameters:
                    rs.parameters = []

                # Check for duplicate names
                if any(p.name == parameter.name for p in rs.parameters):
                    return EditResult(
                        success=False, errors=[f"Parameter '{parameter.name}' already exists"]
                    )

                rs.parameters.append(parameter)
                return EditResult(success=True, modified_object=rs)

        return EditResult(
            success=False,
            errors=[
                f"Unsupported operation: {operation.operation_type} on {operation.target_type}"
            ],
        )


# Convenience functions
def add_variable_to_model(
    model: Model, var_name: str, var_info: ModelVariable, validate: bool = True
) -> EditResult:
    """Add a variable to a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_variable(model, var_name, var_info)


def rename_variable_in_model(
    model: Model, old_name: str, new_name: str, validate: bool = True
) -> EditResult:
    """Rename a variable in a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.rename_variable(model, old_name, new_name)


def remove_variable_from_model(model: Model, var_name: str, validate: bool = True) -> EditResult:
    """Remove a variable from a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.remove_variable(model, var_name)


def add_equation_to_model(model: Model, equation: Equation, validate: bool = True) -> EditResult:
    """Add an equation to a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_equation(model, equation)


def remove_equation_from_model(model: Model, index: int, validate: bool = True) -> EditResult:
    """Remove an equation from a model by index."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.remove_equation(model, index)


def add_reaction_to_system(
    reaction_system: ReactionSystem, reaction: Reaction, validate: bool = True
) -> EditResult:
    """Add a reaction to a reaction system."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_reaction(reaction_system, reaction)


def remove_reaction_from_system(
    reaction_system: ReactionSystem, reaction_name: str, validate: bool = True
) -> EditResult:
    """Remove a reaction from a reaction system."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.remove_reaction(reaction_system, reaction_name)


def add_species_to_system(
    reaction_system: ReactionSystem, species: Species, validate: bool = True
) -> EditResult:
    """Add a species to a reaction system."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_species(reaction_system, species)


def remove_species_from_system(
    reaction_system: ReactionSystem, species_name: str, validate: bool = True
) -> EditResult:
    """Remove a species from a reaction system."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.remove_species(reaction_system, species_name)


def add_continuous_event_to_model(
    model: Model, event: ContinuousEvent, validate: bool = True
) -> EditResult:
    """Add a continuous event to a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_continuous_event(model, event)


def add_discrete_event_to_model(
    model: Model, event: DiscreteEvent, validate: bool = True
) -> EditResult:
    """Add a discrete event to a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_discrete_event(model, event)


def remove_event_from_model(model: Model, event_name: str, validate: bool = True) -> EditResult:
    """Remove an event from a model."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.remove_event(model, event_name)


def add_coupling_to_file(
    esm_file: EsmFile, coupling: CouplingEntry, validate: bool = True
) -> EditResult:
    """Add a coupling entry to an ESM file."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.add_coupling(esm_file, coupling)


def remove_coupling_from_file(esm_file: EsmFile, index: int, validate: bool = True) -> EditResult:
    """Remove a coupling entry from an ESM file."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.remove_coupling(esm_file, index)


def merge_esm_files(file_a: EsmFile, file_b: EsmFile, validate: bool = True) -> EditResult:
    """Merge two ESM files."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.merge(file_a, file_b)


def extract_component_from_file(
    esm_file: EsmFile, component_name: str, validate: bool = True
) -> EditResult:
    """Extract a single component into a standalone ESM file."""
    editor = ESMEditor(validate_after_edit=validate)
    return editor.extract(esm_file, component_name)
