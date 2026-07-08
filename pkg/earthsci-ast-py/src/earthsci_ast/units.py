"""
Unit validation and dimensional analysis for ESM Format.

Provides unit validation functionality using the pint library to ensure
dimensional consistency across models, reaction systems, and expressions.
"""

from typing import Dict, List, Optional, Union, Any
from dataclasses import dataclass, field

try:
    import pint

    PINT_AVAILABLE = True
    ureg = pint.UnitRegistry()
    UnitsContainer = pint.util.UnitsContainer

    # ESM-specific units standard (docs/units-standard.md).
    # Mole-fraction family: dimensionless with scale factors; ppmv/ppbv/pptv
    # are volume-mixing-ratio aliases that equal ppm/ppb/ppt under the
    # ideal-gas approximation, so every binding must treat them as identical.
    #
    # pint form: `name = <scale>` (omitting the reference unit) registers a
    # pure scaling of the empty dimension — this avoids a pint bug where
    # `name = <scale> * dimensionless` stores `dimensionless` as a reference
    # name and then fails conversion with KeyError: ''.
    ureg.define("ppm = 1e-6 = ppmv")
    ureg.define("ppb = 1e-9 = ppbv")
    ureg.define("ppt = 1e-12 = pptv")
    # `molec` is the schema-doc spelling of pint's predefined `molecule`.
    ureg.define("@alias molecule = molec")
    ureg.define("molecule_cm3 = 1 / cm**3")
    # Dobson unit: areal number density of ozone molecules.
    # 1 Dobson = 2.6867e20 molec/m^2 = 2.6867e16 molec/cm^2 (per standard).
    ureg.define("Dobson = 2.6867e16 * molecule * cm**(-2)")

except ImportError:
    PINT_AVAILABLE = False
    ureg = None
    UnitsContainer = Any

try:
    from .esm_types import EsmFile, Model, ReactionSystem, Expr, ExprNode
except ImportError:
    # For direct imports when testing
    from esm_types import EsmFile, Model, ReactionSystem, Expr, ExprNode


@dataclass
class UnitValidationResult:
    """Result of unit validation check."""

    is_valid: bool
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    unit_registry: Dict[str, str] = field(default_factory=dict)  # variable_name -> unit_string
    dimensional_analysis: Dict[str, Any] = field(default_factory=dict)


@dataclass
class UnitConversionResult:
    """Result of unit conversion operation."""

    success: bool
    converted_value: Optional[float] = None
    conversion_factor: Optional[float] = None
    error_message: Optional[str] = None


class UnitValidator:
    """Validator for dimensional consistency in ESM format structures."""

    def __init__(self):
        """Initialize the unit validator."""
        if not PINT_AVAILABLE:
            raise ImportError(
                "pint library is required for unit validation. Install with: pip install pint"
            )

        self.ureg = ureg
        self.known_units: Dict[str, pint.Quantity] = {}

    def validate_esm_file(self, esm_file: EsmFile) -> UnitValidationResult:
        """
        Validate unit consistency across an entire ESM file.

        Args:
            esm_file: The ESM file to validate

        Returns:
            UnitValidationResult with validation status and any issues found
        """
        result = UnitValidationResult(is_valid=True)

        if esm_file.models:
            self._merge_component_results(
                esm_file.models.values(), self.validate_model, "Model", result
            )

        if esm_file.reaction_systems:
            self._merge_component_results(
                esm_file.reaction_systems.values(),
                self.validate_reaction_system,
                "ReactionSystem",
                result,
            )

        # Check for cross-system unit consistency
        self._check_cross_system_consistency(esm_file, result)

        result.is_valid = len(result.errors) == 0
        return result

    def _merge_component_results(self, components, validator, prefix, result):
        """Validate each component and fold its errors/warnings/registry into
        ``result``, prefixing every message with ``"{prefix} {name}: "``."""
        for component in components:
            sub = validator(component)
            result.errors.extend(f"{prefix} {component.name}: {e}" for e in sub.errors)
            result.warnings.extend(f"{prefix} {component.name}: {w}" for w in sub.warnings)
            result.unit_registry.update(sub.unit_registry)

    def validate_model(self, model: Model) -> UnitValidationResult:
        """
        Validate unit consistency within a model.

        Args:
            model: The model to validate

        Returns:
            UnitValidationResult for the model
        """
        result = UnitValidationResult(is_valid=True)

        if not model.variables:
            return result

        # Build unit registry for this model
        for var_name, var_info in model.variables.items():
            if var_info.units:
                try:
                    unit = self.ureg(var_info.units)
                    result.unit_registry[var_name] = var_info.units
                    self.known_units[var_name] = unit
                except Exception as e:
                    result.errors.append(
                        f"Invalid unit '{var_info.units}' for variable '{var_name}': {e}"
                    )

        # Validate equations
        if model.equations:
            for i, equation in enumerate(model.equations):
                eq_result = self.validate_equation(equation, f"eq_{i}")
                result.errors.extend(eq_result.errors)
                result.warnings.extend(eq_result.warnings)

        # Validate variable expressions
        for var_name, var_info in model.variables.items():
            if hasattr(var_info, "expression") and var_info.expression:
                expr_result = self.validate_expression(var_info.expression, var_name)
                if expr_result.errors:
                    result.errors.extend([f"Variable {var_name}: {e}" for e in expr_result.errors])

        result.is_valid = len(result.errors) == 0
        return result

    def validate_reaction_system(self, rs: ReactionSystem) -> UnitValidationResult:
        """
        Validate unit consistency within a reaction system.

        Args:
            rs: The reaction system to validate

        Returns:
            UnitValidationResult for the reaction system
        """
        result = UnitValidationResult(is_valid=True)

        # Register species units
        if rs.species:
            for species in rs.species:
                if species.units:
                    try:
                        unit = self.ureg(species.units)
                        result.unit_registry[species.name] = species.units
                        self.known_units[species.name] = unit
                    except Exception as e:
                        result.errors.append(
                            f"Invalid unit '{species.units}' for species '{species.name}': {e}"
                        )

        # Register parameter units
        if rs.parameters:
            for param in rs.parameters:
                if param.units:
                    try:
                        unit = self.ureg(param.units)
                        result.unit_registry[param.name] = param.units
                        self.known_units[param.name] = unit
                    except Exception as e:
                        result.errors.append(
                            f"Invalid unit '{param.units}' for parameter '{param.name}': {e}"
                        )

        # Validate reactions
        if rs.reactions:
            for reaction in rs.reactions:
                reaction_result = self._validate_reaction(reaction)
                result.errors.extend(reaction_result.errors)
                result.warnings.extend(reaction_result.warnings)

        result.is_valid = len(result.errors) == 0
        return result

    def validate_equation(self, equation, equation_id: str) -> UnitValidationResult:
        """
        Validate dimensional consistency of an equation.

        Args:
            equation: The equation to validate
            equation_id: Identifier for the equation (for error reporting)

        Returns:
            UnitValidationResult for the equation
        """
        result = UnitValidationResult(is_valid=True)

        try:
            lhs_dim = self._get_expression_dimension(equation.lhs)
            rhs_dim = self._get_expression_dimension(equation.rhs)

            if lhs_dim is not None and rhs_dim is not None:
                if not self._dimensions_compatible(lhs_dim, rhs_dim):
                    result.errors.append(
                        f"Equation {equation_id}: Dimensional mismatch - "
                        f"LHS has dimension {lhs_dim}, RHS has dimension {rhs_dim}"
                    )
        except Exception as e:
            result.warnings.append(f"Could not validate dimensions for equation {equation_id}: {e}")

        result.is_valid = len(result.errors) == 0
        return result

    def validate_expression(self, expr: Expr, context: str = "") -> UnitValidationResult:
        """
        Validate dimensional consistency of an expression.

        Args:
            expr: The expression to validate
            context: Context string for error reporting

        Returns:
            UnitValidationResult for the expression
        """
        result = UnitValidationResult(is_valid=True)

        try:
            dimension = self._get_expression_dimension(expr)
            if dimension is not None:
                result.dimensional_analysis[context] = str(dimension)
        except Exception as e:
            result.errors.append(f"Expression validation failed for {context}: {e}")

        result.is_valid = len(result.errors) == 0
        return result

    def convert_units(self, value: float, from_unit: str, to_unit: str) -> UnitConversionResult:
        """
        Convert a value from one unit to another.

        Args:
            value: The numeric value to convert
            from_unit: Source unit string
            to_unit: Target unit string

        Returns:
            UnitConversionResult with converted value or error information
        """
        try:
            from_quantity = self.ureg.Quantity(value, from_unit)
            to_quantity = from_quantity.to(to_unit)

            return UnitConversionResult(
                success=True,
                converted_value=float(to_quantity.magnitude),
                conversion_factor=float(to_quantity.magnitude) / value if value != 0 else None,
            )
        except Exception as e:
            return UnitConversionResult(success=False, error_message=str(e))

    def _get_expression_dimension(self, expr: Expr) -> Optional[UnitsContainer]:
        """Get the dimensional analysis of an expression."""
        if isinstance(expr, (int, float)):
            return self.ureg.dimensionless.dimensionality

        elif isinstance(expr, str):
            # Variable lookup
            if expr in self.known_units:
                return self.known_units[expr].dimensionality
            else:
                # Unknown variable - assume dimensionless for now
                return None

        elif isinstance(expr, ExprNode):
            return self._get_expr_node_dimension(expr)

        return None

    def _get_expr_node_dimension(self, node: ExprNode) -> Optional[UnitsContainer]:
        """Get dimension of an expression node (operator with arguments)."""
        if not node.args:
            return None

        arg_dims = [self._get_expression_dimension(arg) for arg in node.args]

        # Filter out None dimensions
        valid_dims = [d for d in arg_dims if d is not None]

        if not valid_dims:
            return None

        # Handle different operators
        if node.op in ["+", "-"]:
            # Addition/subtraction: all operands must have same dimension
            first_dim = valid_dims[0]
            for dim in valid_dims[1:]:
                if not self._dimensions_compatible(first_dim, dim):
                    raise ValueError(f"Incompatible dimensions in {node.op}: {first_dim} vs {dim}")
            return first_dim

        elif node.op == "*":
            # Multiplication: multiply dimensions
            result_dim = self.ureg.dimensionless.dimensionality
            for dim in valid_dims:
                result_dim = result_dim * dim
            return result_dim

        elif node.op == "/":
            # Division: divide dimensions
            if len(valid_dims) >= 2:
                result_dim = valid_dims[0]
                for dim in valid_dims[1:]:
                    result_dim = result_dim / dim
                return result_dim
            return valid_dims[0] if valid_dims else None

        elif node.op == "^":
            # Power: first argument's dimension raised to power
            if len(valid_dims) >= 1:
                base_dim = valid_dims[0]
                if len(node.args) > 1 and isinstance(node.args[1], (int, float)):
                    exponent = node.args[1]
                    return base_dim**exponent
                return base_dim
            return None

        # For other operators (sin, cos, exp, etc.), assume dimensionless result
        return self.ureg.dimensionless.dimensionality

    def _dimensions_compatible(self, dim1: UnitsContainer, dim2: UnitsContainer) -> bool:
        """Check if two dimensions are compatible (same or convertible)."""
        try:
            # Create dummy quantities and try to convert
            q1 = self.ureg.Quantity(1.0, dim1)
            q2 = self.ureg.Quantity(1.0, dim2)
            q1.to(q2.units)
            return True
        except pint.DimensionalityError:
            return False
        except Exception:
            # If we can't determine compatibility, assume they're compatible
            return True

    def _validate_reaction(self, reaction) -> UnitValidationResult:
        """Validate unit consistency in a single reaction."""
        result = UnitValidationResult(is_valid=True)

        # Check that rate constant has appropriate units
        if hasattr(reaction, "rate_constant") and reaction.rate_constant:
            if isinstance(reaction.rate_constant, (int, float, str)):
                # For now, just warn if no units specified
                result.warnings.append(
                    f"Reaction {reaction.name}: Rate constant has no explicit units"
                )
            elif isinstance(reaction.rate_constant, ExprNode):
                # Validate the rate constant expression
                expr_result = self.validate_expression(
                    reaction.rate_constant, f"rate_constant_{reaction.name}"
                )
                result.errors.extend(expr_result.errors)
                result.warnings.extend(expr_result.warnings)

        result.is_valid = len(result.errors) == 0
        return result

    def _check_cross_system_consistency(self, esm_file: EsmFile, result: UnitValidationResult):
        """Check unit consistency between different systems in the ESM file."""
        # This is where you'd implement checks for variables that appear
        # in multiple models or are shared between models and reaction systems
        pass


def validate_units(target: Union[EsmFile, Model, ReactionSystem]) -> UnitValidationResult:
    """
    Convenience function to validate units of an ESM structure.

    Args:
        target: The ESM file, model, or reaction system to validate

    Returns:
        UnitValidationResult with validation status and issues
    """
    validator = UnitValidator()

    if isinstance(target, EsmFile):
        return validator.validate_esm_file(target)
    elif isinstance(target, Model):
        return validator.validate_model(target)
    elif isinstance(target, ReactionSystem):
        return validator.validate_reaction_system(target)
    else:
        raise ValueError(f"Unsupported type for unit validation: {type(target)}")


def convert_units(value: float, from_unit: str, to_unit: str) -> UnitConversionResult:
    """
    Convenience function to convert units.

    Args:
        value: Numeric value to convert
        from_unit: Source unit string
        to_unit: Target unit string

    Returns:
        UnitConversionResult with conversion result
    """
    validator = UnitValidator()
    return validator.convert_units(value, from_unit, to_unit)
