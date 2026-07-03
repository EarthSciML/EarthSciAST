"""
ESM Format validation module.

This module provides a standardized validation interface for cross-language
conformance testing, returning structured validation results.
"""

from dataclasses import dataclass
from typing import List, Dict, Any, Union, Set
import json
import math
import traceback

import jsonschema
from jsonschema import ValidationError as JsonSchemaValidationError

from .parse import load, SchemaValidationError, UnsupportedVersionError, _get_schema
from .error_handling import (
    ESMErrorFactory, ErrorCollector, ESMError, ErrorCode, Severity, ErrorContext, FixSuggestion
)
from .esm_types import EsmFile


@dataclass
class ValidationError:
    """Represents a single validation error."""
    path: str
    message: str
    code: str = ""
    details: Dict[str, Any] = None

    def __post_init__(self):
        if self.details is None:
            self.details = {}


@dataclass
class UnitWarning:
    """Represents a unit validation warning."""
    path: str
    message: str
    lhs_units: str = ""
    rhs_units: str = ""
    details: Dict[str, Any] = None

    def __post_init__(self):
        if self.details is None:
            self.details = {}


@dataclass
class ValidationResult:
    """Represents the result of validation."""
    is_valid: bool
    schema_errors: List[ValidationError]
    structural_errors: List[ValidationError]
    unit_warnings: List[UnitWarning] = None

    def __post_init__(self):
        if self.unit_warnings is None:
            self.unit_warnings = []


def _convert_jsonschema_error(error: JsonSchemaValidationError) -> ValidationError:
    """Convert a jsonschema ValidationError to our ValidationError format."""
    # Convert the path to a string representation
    path_parts = []
    for part in error.absolute_path:
        if isinstance(part, int):
            path_parts.append(f"[{part}]")
        else:
            path_parts.append(f".{part}" if path_parts else str(part))

    path = "".join(path_parts) if path_parts else "$"

    return ValidationError(
        path=path,
        message=error.message,
        code=error.validator or "",
        details={
            "validator": error.validator,
            "validator_value": error.validator_value,
            "schema_path": list(error.schema_path),
            "instance": error.instance
        }
    )


def validate(esm_file) -> ValidationResult:
    """
    Validate an ESM file against schema, structural, and unit requirements.

    This function implements comprehensive validation including:
    1. Equation-unknown balance
    2. Reference integrity (variable refs, scoped refs, discrete_parameters, coupling refs, operator refs)
    3. Reaction consistency (species declared, positive stoichiometries, no null-null, rate refs)
    4. Event consistency (condition types, affect vars, functional affect refs)

    Args:
        esm_file: The EsmFile object, JSON string, or dict to validate

    Returns:
        ValidationResult containing schema_errors, structural_errors, unit_warnings, and is_valid flag
    """
    # Handle JSON string or dict input by parsing first
    if isinstance(esm_file, str):
        try:
            esm_file = load(esm_file)
        except SchemaValidationError as e:
            return ValidationResult(
                is_valid=False,
                schema_errors=[ValidationError(path="$", message=str(e), code="schema")],
                structural_errors=[]
            )
        except Exception as e:
            return ValidationResult(
                is_valid=False,
                schema_errors=[ValidationError(path="$", message=str(e), code="parse")],
                structural_errors=[]
            )
    elif isinstance(esm_file, dict):
        try:
            esm_file = load(esm_file)
        except SchemaValidationError as e:
            return ValidationResult(
                is_valid=False,
                schema_errors=[ValidationError(path="$", message=str(e), code="schema")],
                structural_errors=[]
            )
        except Exception as e:
            return ValidationResult(
                is_valid=False,
                schema_errors=[ValidationError(path="$", message=str(e), code="parse")],
                structural_errors=[]
            )

    schema_errors = []
    structural_errors = []
    unit_warnings = []
    error_collector = ErrorCollector()

    try:
        # Schema validation is assumed to have been done during parsing
        # Focus on structural validation

        # 0. Check that at least one of models or reaction_systems is present
        _validate_content_presence(esm_file, error_collector)

        # 1. Equation-Unknown Balance validation
        _validate_equation_balance_enhanced(esm_file, error_collector)

        # 2. Reference Integrity validation
        _validate_reference_integrity_enhanced(esm_file, error_collector)

        # 3. Reaction Consistency validation
        _validate_reaction_consistency(esm_file, structural_errors)

        # 3b. Reaction rate/stoichiometry dimensional check (mass-action contract)
        _validate_reaction_rate_dimensions(esm_file, structural_errors)

        # 3c. Reject `ic`-op equations inside a reaction system's
        # constraint_equations (spec §11.4.1).
        _validate_reaction_system_ics(esm_file, structural_errors)

        # 4. Event Consistency validation
        _validate_event_consistency(esm_file, structural_errors)

        # 5. Unit validation (warnings only)
        _validate_units(esm_file, unit_warnings)

        # Convert enhanced errors back to old format for backward compatibility
        for error in error_collector.errors:
            structural_errors.append(ValidationError(
                path=error.context.path if error.context else "$",
                message=error.message,
                code=error.code.value,
                details=error.context.details if error.context else {}
            ))

        for warning in error_collector.warnings:
            if warning.code == ErrorCode.UNIT_MISMATCH:
                unit_warnings.append(UnitWarning(
                    path=warning.context.path if warning.context else "$",
                    message=warning.message
                ))
            else:
                structural_errors.append(ValidationError(
                    path=warning.context.path if warning.context else "$",
                    message=warning.message,
                    code=warning.code.value,
                    details=warning.context.details if warning.context else {}
                ))

    except Exception as e:
        # Catch-all for unexpected errors
        structural_errors.append(ValidationError(
            path="$",
            message=f"Validation failed with unexpected error: {str(e)}",
            code="validation_error",
            details={
                "exception_type": type(e).__name__,
                "traceback": traceback.format_exc()
            }
        ))

    is_valid = len(schema_errors) == 0 and len(structural_errors) == 0

    return ValidationResult(
        is_valid=is_valid,
        schema_errors=schema_errors,
        structural_errors=structural_errors,
        unit_warnings=unit_warnings
    )


def validate_raw(esm_data: Union[str, Dict[str, Any]]) -> ValidationResult:
    """
    Validate ESM data from raw JSON string or dictionary.

    This function provides backward compatibility by parsing the data first,
    then calling the main validate function.

    Args:
        esm_data: Either a JSON string or a dictionary containing ESM data

    Returns:
        ValidationResult containing validation status and any errors found
    """
    schema_errors = []
    structural_errors = []

    try:
        # Parse the data if it's a string
        if isinstance(esm_data, str):
            try:
                data = json.loads(esm_data)
            except json.JSONDecodeError as e:
                return ValidationResult(
                    is_valid=False,
                    schema_errors=[ValidationError(
                        path="$",
                        message=f"Invalid JSON: {e.msg}",
                        code="json_decode_error",
                        details={"line": e.lineno, "column": e.colno}
                    )],
                    structural_errors=[],
                    unit_warnings=[]
                )
        else:
            data = esm_data

        # Validate against JSON schema first
        schema = _get_schema()
        try:
            jsonschema.validate(data, schema)
        except JsonSchemaValidationError as e:
            # Collect all schema validation errors
            validator = jsonschema.Draft7Validator(schema)
            for error in validator.iter_errors(data):
                schema_errors.append(_convert_jsonschema_error(error))

        # If schema validation passed, parse and do structural validation
        if not schema_errors:
            try:
                # Parse to EsmFile and perform structural validation
                esm_file = load(json.dumps(data))
                result = validate(esm_file)
                # Merge schema errors if any occurred during parsing
                result.schema_errors.extend(schema_errors)
                return result
            except (SchemaValidationError, UnsupportedVersionError, ValueError) as e:
                structural_errors.append(ValidationError(
                    path="$",
                    message=str(e),
                    code=type(e).__name__.lower().replace("error", ""),
                    details={"exception_type": type(e).__name__}
                ))
            except Exception as e:
                # Catch any other parsing errors
                structural_errors.append(ValidationError(
                    path="$",
                    message=f"Structural validation failed: {str(e)}",
                    code="structural_error",
                    details={
                        "exception_type": type(e).__name__,
                        "traceback": traceback.format_exc()
                    }
                ))

    except Exception as e:
        # Catch-all for unexpected errors
        return ValidationResult(
            is_valid=False,
            schema_errors=[ValidationError(
                path="$",
                message=f"Validation failed with unexpected error: {str(e)}",
                code="unexpected_error",
                details={
                    "exception_type": type(e).__name__,
                    "traceback": traceback.format_exc()
                }
            )],
            structural_errors=[],
            unit_warnings=[]
        )

    return ValidationResult(
        is_valid=len(schema_errors) == 0 and len(structural_errors) == 0,
        schema_errors=schema_errors,
        structural_errors=structural_errors,
        unit_warnings=[]
    )


def _validate_content_presence(esm_file: EsmFile, error_collector: ErrorCollector) -> None:
    """
    Validate that at least one of models, reaction_systems, or data_loaders is
    present and non-empty.

    This ensures that the ESM file contains actual computational content rather than
    being empty or containing only metadata. A loader-only file (sole component
    `data_loaders`) is valid — it is referenceable as a loader subsystem
    (RFC pure-io-data-loaders §4.4 / esm-spec §4.7).
    """
    has_models = esm_file.models and len(esm_file.models) > 0
    has_reaction_systems = esm_file.reaction_systems and len(esm_file.reaction_systems) > 0
    has_data_loaders = esm_file.data_loaders and len(esm_file.data_loaders) > 0

    if not has_models and not has_reaction_systems and not has_data_loaders:
        error = ESMError(
            code=ErrorCode.MISSING_REQUIRED_FIELD,
            message="ESM file must contain at least one model, reaction system, or data loader. Empty files are not valid.",
            severity=Severity.ERROR,
            context=ErrorContext(
                path="$",
                details={
                    "models_count": len(esm_file.models) if esm_file.models else 0,
                    "reaction_systems_count": len(esm_file.reaction_systems) if esm_file.reaction_systems else 0,
                    "data_loaders_count": len(esm_file.data_loaders) if esm_file.data_loaders else 0,
                    "fix_suggestions": [
                        "Add a model with variables and equations",
                        "Add a reaction system with species and reactions",
                        "Add a data loader",
                        "Import content from existing ESM files"
                    ]
                }
            ),
            fix_suggestion=FixSuggestion("Add at least one model, reaction system, or data loader to the ESM file")
        )
        error_collector.add_error(error)


def _is_initial_condition_equation(equation) -> bool:
    """True if an equation's LHS is an ``ic`` node (an initial-condition spec).

    An ``ic`` equation (``{op:"ic", args:[state]}`` = value) pins a state's
    starting value; it is NOT a governing equation that determines an unknown, so
    it must be excluded from the equation-unknown balance count. A model may
    therefore carry one governing ``D``/algebraic equation per state PLUS any
    number of ``ic`` equations (e.g. a second-order system supplying ICs for both
    the value and its derivative) without tripping the balance check.
    """
    lhs = getattr(equation, "lhs", None)
    return getattr(lhs, "op", None) == "ic"


def _validate_equation_balance_enhanced(esm_file: EsmFile, error_collector: ErrorCollector) -> None:
    """Enhanced equation-unknown balance validation with detailed suggestions."""
    for i, model in enumerate(esm_file.models.values()):
        # Count state variables (unknowns)
        state_vars = [name for name, var in model.variables.items() if var.type == 'state']
        num_unknowns = len(state_vars)

        # Count governing equations only — `ic` equations pin initial conditions,
        # not unknowns, so they do not participate in the balance (see
        # `_is_initial_condition_equation`).
        num_equations = sum(
            1 for eq in model.equations if not _is_initial_condition_equation(eq)
        )

        if num_equations != num_unknowns:
            error = ESMErrorFactory.create_equation_imbalance_error(
                model.name, num_equations, num_unknowns, state_vars
            )
            error_collector.add_error(error)


def _validate_equation_balance(esm_file: EsmFile, structural_errors: List[ValidationError]) -> None:
    """
    Validate equation-unknown balance in models.

    Ensures each model has the right number of equations for the number of unknowns (state variables).
    """
    for i, model in enumerate(esm_file.models):
        path = f"/models/{i}"

        # Count state variables (unknowns)
        state_vars = [name for name, var in model.variables.items() if var.type == 'state']
        num_unknowns = len(state_vars)

        # Count governing equations only; `ic` equations pin initial conditions,
        # not unknowns (see `_is_initial_condition_equation`).
        num_equations = sum(
            1 for eq in model.equations if not _is_initial_condition_equation(eq)
        )

        if num_equations != num_unknowns:
            structural_errors.append(ValidationError(
                path=path,
                message=f"Equation-unknown balance error: {num_equations} equations for {num_unknowns} unknowns (state variables: {', '.join(state_vars)})",
                code="equation_unknown_imbalance",
                details={
                    "model_name": model.name,
                    "num_equations": num_equations,
                    "num_unknowns": num_unknowns,
                    "state_variables": state_vars
                }
            ))


def _validate_reference_integrity_enhanced(esm_file: EsmFile, error_collector: ErrorCollector) -> None:
    """Enhanced reference integrity validation with smart suggestions."""
    # Build comprehensive variable lookup for smart suggestions
    all_variables = {}
    all_models = {}
    all_reaction_systems = {}
    all_operators = {}

    # Collect all models and their variables
    for model in esm_file.models.values():
        all_models[model.name] = model
        for var_name, var in model.variables.items():
            scoped_name = f"{model.name}.{var_name}"
            all_variables[scoped_name] = var
            all_variables[var_name] = var  # Also allow unscoped references within model

    # Collect all reaction systems and their species/parameters
    for rs in esm_file.reaction_systems.values():
        all_reaction_systems[rs.name] = rs
        for species in rs.species:
            scoped_name = f"{rs.name}.{species.name}"
            all_variables[scoped_name] = species
        for param in rs.parameters:
            scoped_name = f"{rs.name}.{param.name}"
            all_variables[scoped_name] = param

    # Collect all operators
    for op in esm_file.operators:
        all_operators[op.operator_id] = op

    # Validate coupling references with enhanced error handling
    for i, coupling in enumerate(esm_file.coupling):
        coupling_path = f"/coupling/{i}"

        # Check source model/system existence (only if field exists)
        if hasattr(coupling, 'source_model') and coupling.source_model is not None:
            if coupling.source_model not in all_models and coupling.source_model not in all_reaction_systems:
                available_components = list(all_models.keys()) + list(all_reaction_systems.keys())
                error = ESMErrorFactory.create_undefined_reference_error(
                    coupling.source_model,
                    available_components,
                    f"{coupling_path}/source_model"
                )
                error.message = f"Source model/system '{coupling.source_model}' not found"
                error_collector.add_error(error)

        # Check target model/system existence (only if field exists)
        if hasattr(coupling, 'target_model') and coupling.target_model is not None:
            if coupling.target_model not in all_models and coupling.target_model not in all_reaction_systems:
                available_components = list(all_models.keys()) + list(all_reaction_systems.keys())
                error = ESMErrorFactory.create_undefined_reference_error(
                    coupling.target_model,
                    available_components,
                    f"{coupling_path}/target_model"
                )
                error.message = f"Target model/system '{coupling.target_model}' not found"
                error_collector.add_error(error)


def _validate_reaction_consistency(esm_file: EsmFile, structural_errors: List[ValidationError]) -> None:
    """
    Validate reaction consistency in reaction systems.

    Checks:
    - Every species in substrates/products is declared in species
    - Stoichiometries are positive
    - No reaction has both substrates: null and products: null
    - Rate expressions only reference declared parameters/species
    """
    for rs_idx, (rs_name, rs) in enumerate(esm_file.reaction_systems.items()):
        rs_path = f"/reaction_systems/{rs_idx}"

        # Build set of declared species and parameters
        species_names = {species.name for species in rs.species}
        param_names = {param.name for param in rs.parameters}

        for r_idx, reaction in enumerate(rs.reactions):
            reaction_path = f"{rs_path}/reactions/{r_idx}"

            # Check for null-null reaction
            if not reaction.reactants and not reaction.products:
                structural_errors.append(ValidationError(
                    path=reaction_path,
                    message=f"Reaction has both substrates: null and products: null",
                    code=ErrorCode.NULL_REACTION.value,
                    details={"reaction_name": reaction.name}
                ))

            # Validate reactant species exist and have positive stoichiometry
            for species_name, stoich in reaction.reactants.items():
                if species_name not in species_names:
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/reactants/{species_name}",
                        message=f"Reactant species '{species_name}' not declared in reaction system '{rs.name}'",
                        code="undeclared_species",
                        details={"species": species_name, "reaction_system": rs.name, "available_species": list(species_names)}
                    ))

                if not isinstance(stoich, (int, float)) or isinstance(stoich, bool):
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/reactants/{species_name}",
                        message=f"Reactant stoichiometry must be a number, got {type(stoich).__name__}",
                        code="invalid_stoichiometry_type",
                        details={"species": species_name, "stoichiometry": stoich, "stoichiometry_type": type(stoich).__name__}
                    ))
                elif isinstance(stoich, float) and (math.isnan(stoich) or math.isinf(stoich)):
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/reactants/{species_name}",
                        message=f"Reactant stoichiometry must be finite, got {stoich}",
                        code="invalid_stoichiometry",
                        details={"species": species_name, "stoichiometry": stoich}
                    ))
                elif stoich <= 0:
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/reactants/{species_name}",
                        message=f"Reactant stoichiometry must be positive, got {stoich}",
                        code="negative_stoichiometry",
                        details={"species": species_name, "stoichiometry": stoich}
                    ))

            # Validate product species exist and have positive stoichiometry
            for species_name, stoich in reaction.products.items():
                if species_name not in species_names:
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/products/{species_name}",
                        message=f"Product species '{species_name}' not declared in reaction system '{rs.name}'",
                        code="undeclared_species",
                        details={"species": species_name, "reaction_system": rs.name, "available_species": list(species_names)}
                    ))

                if not isinstance(stoich, (int, float)) or isinstance(stoich, bool):
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/products/{species_name}",
                        message=f"Product stoichiometry must be a number, got {type(stoich).__name__}",
                        code="invalid_stoichiometry_type",
                        details={"species": species_name, "stoichiometry": stoich, "stoichiometry_type": type(stoich).__name__}
                    ))
                elif isinstance(stoich, float) and (math.isnan(stoich) or math.isinf(stoich)):
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/products/{species_name}",
                        message=f"Product stoichiometry must be finite, got {stoich}",
                        code="invalid_stoichiometry",
                        details={"species": species_name, "stoichiometry": stoich}
                    ))
                elif stoich <= 0:
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/products/{species_name}",
                        message=f"Product stoichiometry must be positive, got {stoich}",
                        code="negative_stoichiometry",
                        details={"species": species_name, "stoichiometry": stoich}
                    ))

            # Validate rate constant references (full expression parsing)
            if hasattr(reaction, 'rate_constant') and reaction.rate_constant is not None:
                _validate_rate_expression(reaction.rate_constant, param_names, species_names, rs.name, reaction_path, structural_errors)


def _validate_reaction_system_ics(esm_file: EsmFile, structural_errors: List[ValidationError]) -> None:
    """Reject ``ic``-op equations placed inside a reaction system's
    ``constraint_equations`` (spec §11.4.1).

    A reaction system has no ``equations`` field and hosts no initial
    conditions: a species' initial value is its scalar ``species.default``, and a
    non-constant / spatial IC is declared with a scoped-reference ``ic`` equation
    in a MODEL (``ic(Chemistry.O3) ~ <field>``), never inside the reaction
    system. Such a file is SCHEMA-VALID (``constraint_equations`` is an array of
    Equation and ``ic`` is a legal op, so nothing in JSON Schema forbids it) but
    MUST be rejected structurally with code ``ic_in_reaction_system``.
    """
    for rs_name, rs in esm_file.reaction_systems.items():
        for ce_idx, eq in enumerate(rs.constraint_equations):
            lhs = getattr(eq, "lhs", None)
            if getattr(lhs, "op", None) != "ic":
                continue
            args = getattr(lhs, "args", None) or []
            species = args[0] if args and isinstance(args[0], str) else None
            structural_errors.append(ValidationError(
                path=f"/reaction_systems/{rs_name}/constraint_equations/{ce_idx}",
                message=(
                    "ic equation not allowed in a reaction system; a reaction "
                    "system has no equations field and hosts no ic equations "
                    "(ICs are model-hosted: species.default, or a scoped-reference "
                    "ic equation in a model, spec §11.4.1)"
                ),
                code="ic_in_reaction_system",
                details={
                    "system": rs_name,
                    "species": species,
                    "constraint_equation_index": ce_idx,
                },
            ))


def _validate_rate_expression(rate_expr, param_names: Set[str], species_names: Set[str],
                             reaction_system_name: str, reaction_path: str, structural_errors: List[ValidationError]) -> None:
    """
    Validate that a rate expression only references declared parameters and species.

    Args:
        rate_expr: The rate expression (string, number, or ExprNode)
        param_names: Set of declared parameter names in the reaction system
        species_names: Set of declared species names in the reaction system
        reaction_system_name: Name of the reaction system for error messages
        reaction_path: Path to the reaction for error reporting
        structural_errors: List to append validation errors to
    """
    from .expression import free_variables

    if isinstance(rate_expr, str):
        # Simple parameter reference
        if rate_expr not in param_names:
            structural_errors.append(ValidationError(
                path=f"{reaction_path}/rate_constant",
                message=f"Rate constant parameter '{rate_expr}' not declared in reaction system '{reaction_system_name}'",
                code="undeclared_parameter",
                details={
                    "parameter": rate_expr,
                    "reaction_system": reaction_system_name,
                    "available_parameters": list(param_names)
                }
            ))
    elif isinstance(rate_expr, (int, float)):
        # Numeric constant - always valid
        pass
    else:
        # Complex expression - parse and validate all variables
        try:
            referenced_vars = free_variables(rate_expr)

            # Check that all referenced variables are declared parameters or species
            for var in referenced_vars:
                if var not in param_names and var not in species_names:
                    # Variable is not declared in this reaction system
                    structural_errors.append(ValidationError(
                        path=f"{reaction_path}/rate_constant",
                        message=f"Rate expression references undeclared variable '{var}' in reaction system '{reaction_system_name}'",
                        code="undeclared_rate_variable",
                        details={
                            "variable": var,
                            "reaction_system": reaction_system_name,
                            "available_parameters": list(param_names),
                            "available_species": list(species_names),
                            "rate_expression": str(rate_expr)
                        }
                    ))

        except Exception as e:
            # Error parsing expression - report as validation error
            structural_errors.append(ValidationError(
                path=f"{reaction_path}/rate_constant",
                message=f"Could not parse rate expression in reaction system '{reaction_system_name}': {str(e)}",
                code="invalid_rate_expression",
                details={
                    "reaction_system": reaction_system_name,
                    "rate_expression": str(rate_expr),
                    "parse_error": str(e)
                }
            ))


def _validate_reaction_rate_dimensions(esm_file: EsmFile, structural_errors: List[ValidationError]) -> None:
    """
    Mass-action dimensional check for reaction rates (spec §7.4).

    For each reaction with a declared-unit rate and declared-unit substrates,
    compare the rate expression's dimensions to conc_unit^(1-total_order)/time,
    where conc_unit is the first substrate's species units. Emit
    ``unit_inconsistency`` when they disagree. Dimensionless-concentration
    systems (mole-fraction families) are skipped for Julia parity.

    Mirrors Julia's ``validate_reaction_system_dimensions`` and the Go/Rust
    ``validate_reaction_rate_units`` ports; the error payload matches the
    contract in ``tests/invalid/expected_errors.json``.
    """
    try:
        import pint
    except ImportError:
        return
    from .parse import _normalize_unit, _BUILTIN_SYMBOLS

    ureg = pint.UnitRegistry()
    time_dim = ureg("second").dimensionality
    dimensionless_dim = ureg("").dimensionality

    def parse_dim(unit_str):
        if not unit_str:
            return None
        try:
            return ureg(_normalize_unit(unit_str)).dimensionality
        except Exception:
            return None

    for rs_name, rs in esm_file.reaction_systems.items():
        species_units = {sp.name: sp.units for sp in rs.species}
        param_units = {p.name: p.units for p in rs.parameters}

        for r_idx, reaction in enumerate(rs.reactions):
            reaction_path = f"/reaction_systems/{rs_name}/reactions/{r_idx}"
            rate = reaction.rate_constant
            # Only bare-string rate refs are dimensionally checkable here;
            # compound rate expressions carry implicit unit constants that
            # defeat literal dimensional analysis.
            if not isinstance(rate, str):
                continue
            if "." in rate or rate in _BUILTIN_SYMBOLS:
                continue
            if rate in param_units:
                rate_units_str = param_units[rate]
            elif rate in species_units:
                rate_units_str = species_units[rate]
            else:
                continue  # undefined refs flagged elsewhere
            rate_dim = parse_dim(rate_units_str)
            if rate_dim is None:
                continue

            # reactants dict preserves insertion order from _parse_reaction
            if not reaction.reactants:
                continue
            substrate_names = list(reaction.reactants.keys())
            first_sp = substrate_names[0]
            first_sp_units = species_units.get(first_sp)
            first_sp_dim = parse_dim(first_sp_units)
            if first_sp_dim is None:
                continue
            if first_sp_dim == dimensionless_dim:
                # Julia parity: skip mole-fraction families.
                continue

            substrate_dim = ureg("").dimensionality
            total_order = 0
            resolvable = True
            for sp_name, stoich in reaction.reactants.items():
                try:
                    stoich_i = int(stoich)
                except (TypeError, ValueError):
                    resolvable = False
                    break
                if stoich_i != stoich:
                    resolvable = False
                    break
                sp_dim = parse_dim(species_units.get(sp_name))
                if sp_dim is None:
                    resolvable = False
                    break
                substrate_dim = substrate_dim * (sp_dim ** stoich_i)
                total_order += stoich_i
            if not resolvable:
                continue

            # Equivalent to rate_dim == first_sp_dim^(1-order) / time but
            # avoids pint's [substance]^0 * [length]^0 ≠ dimensionless quirk
            # by checking rate * prod(substrate^stoich) == first_species/time.
            expected_dim = first_sp_dim / time_dim
            full_dim = rate_dim * substrate_dim
            if full_dim != expected_dim:
                rxn_label = reaction.id if reaction.id is not None else reaction.name
                structural_errors.append(ValidationError(
                    path=reaction_path,
                    message="Reaction rate expression has incompatible units for reaction stoichiometry",
                    code="unit_inconsistency",
                    details={
                        "reaction_id": rxn_label,
                        "rate_units": rate_units_str or "",
                        "expected_rate_units": _format_expected_rate_units(first_sp_units or "", total_order),
                        "reaction_order": total_order,
                    }
                ))


def _format_expected_rate_units(species_units: str, total_order: int) -> str:
    """Compose the canonical rate-unit string from the reference species unit
    and total reaction order, matching the contract in
    ``tests/invalid/expected_errors.json``. Ports the Go/Rust implementations.

    Examples:
        ("mol/L", 2) -> "L/(mol*s)"
        ("mol/L", 1) -> "1/s"
        ("mol/L", 0) -> "mol/(L*s)"
        ("mol/m^3", 2) -> "m^3/(mol*s)"
    """
    exp = 1 - total_order
    if exp == 0:
        return "1/s"
    num, den = _split_unit_num_den(species_units)
    exp_abs = exp
    if exp < 0:
        num, den = den, num
        exp_abs = -exp
    num_str = _power_factor(num, exp_abs)
    den_factors = []
    df = _power_factor(den, exp_abs)
    if df:
        den_factors.append(df)
    den_factors.append("s")
    if not num_str:
        num_str = "1"
    if len(den_factors) == 1:
        return f"{num_str}/{den_factors[0]}"
    return f"{num_str}/({'*'.join(den_factors)})"


def _split_unit_num_den(s: str):
    """Split a unit string on its first top-level '/'. ``"mol/L"`` → ``("mol",
    "L")``; ``"mol/(L*s)"`` → ``("mol", "L*s")``. If no top-level '/' appears,
    the whole string is the numerator."""
    s = s.strip()
    if not s:
        return "", ""
    depth = 0
    for i, c in enumerate(s):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "/" and depth == 0:
            num = s[:i].strip()
            den = s[i + 1:].strip()
            if den.startswith("(") and den.endswith(")"):
                den = den[1:-1]
            return num, den
    return s, ""


def _power_factor(s: str, n: int) -> str:
    """Raise a unit factor to an integer power, rendering as a string.
    Parenthesises compound factors when the power is not 1."""
    s = s.strip()
    if not s:
        return ""
    if n == 1:
        return s
    if "*" in s or "/" in s:
        return f"({s})^{n}"
    return f"{s}^{n}"


def _validate_event_consistency(esm_file: EsmFile, structural_errors: List[ValidationError]) -> None:
    """
    Validate event consistency.

    Checks:
    - Continuous event conditions are expressions (not booleans)
    - Discrete event conditions produce boolean values
    - Variables in affects are declared
    - Variables in affect_neg (direction-dependent affects) are declared
    - Functional affect references are valid (handler_id, read_vars, read_params, modified_params)
    - discrete_parameters in coupling entries are valid
    """
    # Build variable lookup for validation
    all_variables = set()
    all_parameters = set()

    for model in esm_file.models.values():
        for var_name in model.variables:
            all_variables.add(var_name)
            all_variables.add(f"{model.name}.{var_name}")
            # Parameters are also variables
            if model.variables[var_name].type == 'parameter':
                all_parameters.add(var_name)
                all_parameters.add(f"{model.name}.{var_name}")

    for rs in esm_file.reaction_systems.values():
        for species in rs.species:
            all_variables.add(species.name)
            all_variables.add(f"{rs.name}.{species.name}")
        for param in rs.parameters:
            all_variables.add(param.name)
            all_variables.add(f"{rs.name}.{param.name}")
            all_parameters.add(param.name)
            all_parameters.add(f"{rs.name}.{param.name}")

    # Build operator/handler lookup for functional affects
    all_operators = set()
    for operator in esm_file.operators:
        all_operators.add(operator.operator_id)

    for event_idx, event in enumerate(esm_file.events):
        event_path = f"/events/{event_idx}"

        # Validate affects - check that target variables exist and functional affects are valid
        for affect_idx, affect in enumerate(event.affects):
            affect_path = f"{event_path}/affects/{affect_idx}"

            if hasattr(affect, 'lhs'):  # AffectEquation
                if affect.lhs not in all_variables:
                    structural_errors.append(ValidationError(
                        path=f"{affect_path}/lhs",
                        message=f"Variable '{affect.lhs}' in event affects/conditions is not declared",
                        code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                        details={"variable": affect.lhs, "available_variables": sorted(list(all_variables))}
                    ))
            elif hasattr(affect, 'handler_id'):  # FunctionalAffect
                # Validate handler_id exists as an operator
                if affect.handler_id not in all_operators:
                    structural_errors.append(ValidationError(
                        path=f"{affect_path}/handler_id",
                        message=f"Operator '{affect.handler_id}' is not defined",
                        code=ErrorCode.UNDEFINED_OPERATOR.value,
                        details={"operator": affect.handler_id, "available_operators": sorted(list(all_operators))}
                    ))

                # Validate read_vars exist
                for var_idx, read_var in enumerate(affect.read_vars):
                    if read_var not in all_variables:
                        structural_errors.append(ValidationError(
                            path=f"{affect_path}/read_vars/{var_idx}",
                            message=f"Variable '{read_var}' in event affects/conditions is not declared",
                            code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                            details={"variable": read_var, "available_variables": sorted(list(all_variables))}
                        ))

                # Validate read_params exist
                for param_idx, read_param in enumerate(affect.read_params):
                    if read_param not in all_parameters:
                        structural_errors.append(ValidationError(
                            path=f"{affect_path}/read_params/{param_idx}",
                            message=f"Functional affect read parameter '{read_param}' not declared",
                            code="undeclared_read_parameter",
                            details={"parameter": read_param, "available_parameters": sorted(list(all_parameters))}
                        ))

                # Validate modified_params exist
                for param_idx, mod_param in enumerate(affect.modified_params):
                    if mod_param not in all_parameters:
                        structural_errors.append(ValidationError(
                            path=f"{affect_path}/modified_params/{param_idx}",
                            message=f"Functional affect modified parameter '{mod_param}' not declared",
                            code="undeclared_modified_parameter",
                            details={"parameter": mod_param, "available_parameters": sorted(list(all_parameters))}
                        ))

        # Validate affect_neg (direction-dependent affects) if present
        if hasattr(event, 'affect_neg') and event.affect_neg is not None:
            for affect_idx, affect in enumerate(event.affect_neg):
                affect_path = f"{event_path}/affect_neg/{affect_idx}"

                if hasattr(affect, 'lhs'):  # AffectEquation
                    if affect.lhs not in all_variables:
                        structural_errors.append(ValidationError(
                            path=f"{affect_path}/lhs",
                            message=f"Variable '{affect.lhs}' in event affects/conditions is not declared",
                            code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                            details={"variable": affect.lhs, "available_variables": sorted(list(all_variables))}
                        ))
                elif hasattr(affect, 'handler_id'):  # FunctionalAffect
                    # Same validation as regular affects
                    if affect.handler_id not in all_operators:
                        structural_errors.append(ValidationError(
                            path=f"{affect_path}/handler_id",
                            message=f"Operator '{affect.handler_id}' is not defined",
                            code=ErrorCode.UNDEFINED_OPERATOR.value,
                            details={"operator": affect.handler_id, "available_operators": sorted(list(all_operators))}
                        ))

                    # Validate read_vars, read_params, modified_params for affect_neg functional affects
                    for var_idx, read_var in enumerate(affect.read_vars):
                        if read_var not in all_variables:
                            structural_errors.append(ValidationError(
                                path=f"{affect_path}/read_vars/{var_idx}",
                                message=f"Variable '{read_var}' in event affects/conditions is not declared",
                                code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                                details={"variable": read_var, "available_variables": sorted(list(all_variables))}
                            ))

                    for param_idx, read_param in enumerate(affect.read_params):
                        if read_param not in all_parameters:
                            structural_errors.append(ValidationError(
                                path=f"{affect_path}/read_params/{param_idx}",
                                message=f"Affect_neg functional affect read parameter '{read_param}' not declared",
                                code="undeclared_read_parameter",
                                details={"parameter": read_param, "available_parameters": sorted(list(all_parameters))}
                            ))

                    for param_idx, mod_param in enumerate(affect.modified_params):
                        if mod_param not in all_parameters:
                            structural_errors.append(ValidationError(
                                path=f"{affect_path}/modified_params/{param_idx}",
                                message=f"Affect_neg functional affect modified parameter '{mod_param}' not declared",
                                code="undeclared_modified_parameter",
                                details={"parameter": mod_param, "available_parameters": sorted(list(all_parameters))}
                            ))

    # Validate discrete_parameters in coupling entries
    for coupling_idx, coupling in enumerate(esm_file.coupling):
        coupling_path = f"/coupling/{coupling_idx}"

        # Check if this coupling entry has discrete_parameters
        if hasattr(coupling, 'discrete_parameters') and coupling.discrete_parameters is not None:
            for param_idx, discrete_param in enumerate(coupling.discrete_parameters):
                param_path = f"{coupling_path}/discrete_parameters/{param_idx}"

                if discrete_param not in all_parameters:
                    structural_errors.append(ValidationError(
                        path=param_path,
                        message=f"Discrete parameter '{discrete_param}' does not match a declared parameter",
                        code=ErrorCode.INVALID_DISCRETE_PARAM.value,
                        details={"parameter": discrete_param, "available_parameters": sorted(list(all_parameters))}
                    ))


def _validate_units(esm_file: EsmFile, unit_warnings: List[UnitWarning]) -> None:
    """
    Validate dimensional consistency (warnings only).

    Uses the UnitValidator from units.py to perform comprehensive dimensional analysis
    and unit validation across models and reaction systems.
    """
    try:
        from .units import UnitValidator

        # Create unit validator instance
        validator = UnitValidator()

        # Validate the entire ESM file
        unit_result = validator.validate_esm_file(esm_file)

        # Convert validation errors to warnings (as per function contract)
        for error_msg in unit_result.errors:
            unit_warnings.append(UnitWarning(
                path="unit_validation",
                message=error_msg,
                details={"validation_type": "dimensional_analysis"}
            ))

        # Convert validation warnings to our warning format
        for warning_msg in unit_result.warnings:
            unit_warnings.append(UnitWarning(
                path="unit_validation",
                message=warning_msg,
                details={"validation_type": "unit_warning"}
            ))

    except ImportError:
        # If pint is not available, add a warning about missing unit validation
        unit_warnings.append(UnitWarning(
            path="unit_validation",
            message="Unit validation skipped: pint library not available. Install with: pip install pint",
            details={"validation_type": "dependency_missing"}
        ))
    except Exception as e:
        # If unit validation fails for any reason, add a warning but don't break validation
        unit_warnings.append(UnitWarning(
            path="unit_validation",
            message=f"Unit validation failed: {str(e)}",
            details={"validation_type": "validation_error", "exception": str(e)}
        ))
