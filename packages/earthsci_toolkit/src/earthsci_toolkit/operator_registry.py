"""
Operator registry for custom operator registration with validation.

This module provides functionality to register, validate, and manage custom operators
for Earth System Model applications. It enables domain-specific operator extensions
with signature validation, documentation requirements, and runtime type checking.
"""

from typing import Dict, List, Optional, Any, Union, Callable, Type
from dataclasses import dataclass, field
import inspect
from .esm_types import Operator


@dataclass
class OperatorSignature:
    """Signature information for a custom operator."""
    input_vars: List[str]
    output_vars: List[str]
    parameters: Dict[str, Any] = field(default_factory=dict)
    description: str = ""
    version: str = "1.0"


@dataclass
class RegisteredOperator:
    """A registered operator with its implementation and metadata."""
    name: str
    operator_class: Type
    signature: OperatorSignature
    version: str = "1.0"
    documentation: str = ""


class OperatorRegistryError(Exception):
    """Base exception for operator registry errors."""
    pass


class OperatorValidationError(OperatorRegistryError):
    """Exception raised when operator validation fails."""
    pass


class OperatorRegistry:
    """
    Registry for custom operators with validation and documentation.

    Provides functionality to:
    - Register custom operators with signature validation
    - Validate operator implementations
    - Create operator instances with runtime type checking
    - Manage operator versions and documentation
    """

    def __init__(self):
        """Initialize the operator registry."""
        self._operators: Dict[str, Dict[str, RegisteredOperator]] = {}

    def register(
        self,
        name: str,
        operator_class: Type,
        input_vars: List[str],
        output_vars: List[str],
        parameters: Optional[Dict[str, Any]] = None,
        description: str = "",
        version: str = "1.0",
        documentation: str = ""
    ) -> None:
        """
        Register a custom operator with validation.

        Args:
            name: Unique operator name
            operator_class: Class implementing the operator
            input_vars: List of required input variable names
            output_vars: List of output variable names
            parameters: Optional parameter specifications
            description: Brief description of the operator
            version: Version string (semantic versioning recommended)
            documentation: Detailed documentation

        Raises:
            OperatorValidationError: If operator fails validation
            OperatorRegistryError: If registration fails
        """
        parameters = parameters or {}

        # Validate the operator class
        self._validate_operator_class(operator_class, input_vars, output_vars)

        # Create signature
        signature = OperatorSignature(
            input_vars=input_vars,
            output_vars=output_vars,
            parameters=parameters,
            description=description,
            version=version
        )

        # Create registered operator
        registered_op = RegisteredOperator(
            name=name,
            operator_class=operator_class,
            signature=signature,
            version=version,
            documentation=documentation
        )

        # Store in registry
        if name not in self._operators:
            self._operators[name] = {}
        self._operators[name][version] = registered_op

    def _validate_operator_class(
        self,
        operator_class: Type,
        input_vars: List[str],
        output_vars: List[str]
    ) -> None:
        """
        Validate that an operator class meets requirements.

        Args:
            operator_class: The operator class to validate
            input_vars: Expected input variables
            output_vars: Expected output variables

        Raises:
            OperatorValidationError: If validation fails
        """
        # Check if class is callable
        if not callable(operator_class):
            raise OperatorValidationError(f"Operator class {operator_class} is not callable")

        # Check constructor signature
        try:
            sig = inspect.signature(operator_class.__init__)
        except (TypeError, ValueError) as e:
            raise OperatorValidationError(f"Cannot inspect operator constructor: {e}")

        # Must accept at least (self, config) parameters
        params = list(sig.parameters.keys())
        if len(params) < 2 or params[1] != 'config':
            raise OperatorValidationError(
                f"Operator constructor must accept 'config' parameter. "
                f"Found parameters: {params}"
            )

        # Check for required methods based on operator type
        required_methods = self._determine_required_methods(input_vars, output_vars)
        for method_name in required_methods:
            if not hasattr(operator_class, method_name):
                raise OperatorValidationError(
                    f"Operator class {operator_class.__name__} missing required method: {method_name}"
                )

    def _determine_required_methods(
        self,
        input_vars: List[str],
        output_vars: List[str]
    ) -> List[str]:
        """
        Determine required methods based on operator signature.

        This is a simplified heuristic - in practice, you might have
        more sophisticated rules based on operator types.
        """
        # All operators must expose __str__. Per-operator-type requirements
        # (apply/process/execute/...) can be layered on here in the future.
        return ['__str__']

    def has_operator(self, name: str, version: Optional[str] = None) -> bool:
        """
        Check if an operator is registered.

        Args:
            name: Operator name
            version: Optional version (checks any version if None)

        Returns:
            True if operator exists
        """
        if name not in self._operators:
            return False

        if version is None:
            return len(self._operators[name]) > 0
        else:
            return version in self._operators[name]

    def get_operator_class(self, name: str, version: Optional[str] = None) -> Type:
        """
        Get the operator class for a registered operator.

        Args:
            name: Operator name
            version: Version (uses latest if None)

        Returns:
            The operator class

        Raises:
            OperatorRegistryError: If operator not found
        """
        if not self.has_operator(name):
            raise OperatorRegistryError(f"Operator '{name}' not found")

        if version is None:
            # Get latest version
            version = self._get_latest_version(name)

        if version not in self._operators[name]:
            available_versions = list(self._operators[name].keys())
            raise OperatorRegistryError(
                f"Operator '{name}' version '{version}' not found. "
                f"Available versions: {available_versions}"
            )

        return self._operators[name][version].operator_class

    def _get_latest_version(self, name: str) -> str:
        """Get the latest version of an operator."""
        versions = list(self._operators[name].keys())
        if not versions:
            raise OperatorRegistryError(f"No versions found for operator '{name}'")

        # Simple version sorting - in practice you might want semantic version sorting
        return sorted(versions)[-1]

    def create_operator(self, config: Operator) -> Any:
        """
        Create an operator instance from configuration.

        Args:
            config: Operator configuration

        Returns:
            Operator instance

        Raises:
            OperatorRegistryError: If creation fails
        """
        operator_name = config.operator_id

        if not self.has_operator(operator_name):
            raise OperatorRegistryError(f"Operator '{operator_name}' not registered")

        operator_class = self.get_operator_class(operator_name)

        try:
            return operator_class(config)
        except Exception as e:
            raise OperatorRegistryError(f"Failed to create operator '{operator_name}': {e}")

    def create_operator_by_name(
        self,
        name: str,
        needed_vars: List[str],
        modifies: Optional[List[str]] = None,
        config: Optional[Dict[str, Any]] = None,
        description: Optional[str] = None,
        version: Optional[str] = None
    ) -> Any:
        """
        Create an operator instance by name with parameters.

        Args:
            name: Operator name
            needed_vars: Required input variables
            modifies: Variables that the operator modifies
            config: Configuration parameters
            description: Optional description
            version: Specific version to use

        Returns:
            Operator instance
        """
        config = config or {}

        # Create Operator configuration
        operator_config = Operator(
            operator_id=name,
            needed_vars=needed_vars,
            modifies=modifies,
            config=config,
            description=description
        )

        return self.create_operator(operator_config)

    def get_operator_info(self, name: str) -> Dict[str, Any]:
        """
        Get information about a registered operator.

        Args:
            name: Operator name

        Returns:
            Dictionary with operator information

        Raises:
            OperatorRegistryError: If operator not found
        """
        if not self.has_operator(name):
            raise OperatorRegistryError(f"Operator '{name}' not found")

        versions = list(self._operators[name].keys())
        latest_version = self._get_latest_version(name)
        latest_op = self._operators[name][latest_version]

        return {
            'name': name,
            'versions': versions,
            'default_version': latest_version,
            'class_name': latest_op.operator_class.__name__,
            'description': latest_op.signature.description,
            'documentation': latest_op.documentation,
            'input_vars': latest_op.signature.input_vars,
            'output_vars': latest_op.signature.output_vars,
            'parameters': latest_op.signature.parameters
        }

    def list_all_operators(self) -> Dict[str, Dict[str, Any]]:
        """
        List all registered operators with their information.

        Returns:
            Dictionary mapping operator names to their info
        """
        result = {}
        for name in self._operators:
            try:
                result[name] = self.get_operator_info(name)
            except OperatorRegistryError:
                # Skip operators with issues
                continue
        return result

    def list_operators_by_prefix(self, prefix: str) -> List[str]:
        """
        List operators whose names start with a given prefix.

        Args:
            prefix: Name prefix to match

        Returns:
            List of matching operator names
        """
        return [name for name in self._operators if name.startswith(prefix)]

    def unregister(self, name: str, version: Optional[str] = None) -> None:
        """
        Unregister an operator.

        Args:
            name: Operator name
            version: Specific version (removes all versions if None)

        Raises:
            OperatorRegistryError: If operator not found
        """
        if not self.has_operator(name):
            raise OperatorRegistryError(f"Operator '{name}' not found")

        if version is None:
            # Remove all versions
            del self._operators[name]
        else:
            if version not in self._operators[name]:
                raise OperatorRegistryError(
                    f"Operator '{name}' version '{version}' not found"
                )
            del self._operators[name][version]

            # Remove operator entirely if no versions left
            if not self._operators[name]:
                del self._operators[name]


# Global operator registry instance
_global_registry = OperatorRegistry()


# Convenience functions that use the global registry
def register_operator(
    name: str,
    operator_class: Type,
    input_vars: List[str],
    output_vars: List[str],
    parameters: Optional[Dict[str, Any]] = None,
    description: str = "",
    version: str = "1.0",
    documentation: str = ""
) -> None:
    """Register an operator with the global registry."""
    _global_registry.register(
        name, operator_class, input_vars, output_vars,
        parameters, description, version, documentation
    )


def has_operator(name: str, version: Optional[str] = None) -> bool:
    """Check if an operator exists in the global registry."""
    return _global_registry.has_operator(name, version)


def get_operator_registry() -> OperatorRegistry:
    """Get the global operator registry instance."""
    return _global_registry


def create_operator(config: Operator) -> Any:
    """Create an operator instance using the global registry."""
    return _global_registry.create_operator(config)


def create_operator_by_name(
    name: str,
    needed_vars: List[str],
    modifies: Optional[List[str]] = None,
    config: Optional[Dict[str, Any]] = None,
    description: Optional[str] = None,
    version: Optional[str] = None
) -> Any:
    """Create an operator instance by name using the global registry."""
    return _global_registry.create_operator_by_name(
        name, needed_vars, modifies, config, description, version
    )


def list_all_operators() -> Dict[str, Dict[str, Any]]:
    """List all operators in the global registry."""
    return _global_registry.list_all_operators()


def get_operator_info(name: str) -> Dict[str, Any]:
    """Get operator information from the global registry."""
    return _global_registry.get_operator_info(name)


def unregister_operator(name: str, version: Optional[str] = None) -> None:
    """Unregister an operator from the global registry."""
    _global_registry.unregister(name, version)