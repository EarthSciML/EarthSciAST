"""
Minimal error handling for ESM Format.
This provides only the essential error handling functionality required by validation.
"""

from enum import Enum
from dataclasses import dataclass
from typing import Optional, Dict, Any


class ErrorCode(Enum):
    """Error codes for ESM validation."""
    SCHEMA_VALIDATION_ERROR = "schema_validation_error"
    EQUATION_COUNT_MISMATCH = "equation_count_mismatch"
    UNDEFINED_VARIABLE = "undefined_variable"
    UNDEFINED_SPECIES = "undefined_species"
    UNDEFINED_PARAMETER = "undefined_parameter"
    UNDEFINED_SYSTEM = "undefined_system"
    UNRESOLVED_SCOPED_REF = "unresolved_scoped_ref"
    UNDEFINED_OPERATOR = "undefined_operator"
    INVALID_DISCRETE_PARAM = "invalid_discrete_param"
    NULL_REACTION = "null_reaction"
    MISSING_OBSERVED_EXPR = "missing_observed_expr"
    EVENT_VAR_UNDECLARED = "event_var_undeclared"
    MISSING_REQUIRED_FIELD = "missing_required_field"
    UNIT_MISMATCH = "unit_mismatch"


class Severity(Enum):
    """Error severity levels."""
    ERROR = "error"
    WARNING = "warning"
    INFO = "info"


@dataclass
class ErrorContext:
    """Context information for errors."""
    path: Optional[str] = None
    component: Optional[str] = None
    details: Optional[Dict[str, Any]] = None


@dataclass
class FixSuggestion:
    """Suggestion for fixing an error."""
    description: str
    action: Optional[str] = None


@dataclass
class ESMError:
    """ESM validation or processing error."""
    code: ErrorCode
    message: str
    severity: Severity
    context: Optional[ErrorContext] = None
    fix_suggestion: Optional[FixSuggestion] = None


class ErrorCollector:
    """Collects errors and warnings during validation."""

    def __init__(self):
        self.errors = []
        self.warnings = []

    def add_error(self, error: ESMError):
        """Add an error to the collection."""
        self.errors.append(error)


class ESMErrorFactory:
    """Factory for creating ESM errors."""

    @staticmethod
    def create_equation_imbalance_error(model_name: str, num_equations: int, num_unknowns: int, state_vars: list) -> ESMError:
        """Create an equation-unknown balance error."""
        return ESMError(
            code=ErrorCode.EQUATION_COUNT_MISMATCH,
            message=f"Equation-unknown balance error in model '{model_name}': {num_equations} equations for {num_unknowns} unknowns (state variables: {', '.join(state_vars)})",
            severity=Severity.ERROR,
            context=ErrorContext(
                component=model_name,
                details={
                    "model_name": model_name,
                    "num_equations": num_equations,
                    "num_unknowns": num_unknowns,
                    "state_variables": state_vars
                }
            )
        )

    @staticmethod
    def create_undefined_reference_error(reference: str, available_options: list, path: str) -> ESMError:
        """Create an undefined reference error."""
        return ESMError(
            code=ErrorCode.UNDEFINED_VARIABLE,
            message=f"Undefined reference '{reference}'",
            severity=Severity.ERROR,
            context=ErrorContext(
                path=path,
                details={
                    "reference": reference,
                    "available_options": available_options
                }
            )
        )