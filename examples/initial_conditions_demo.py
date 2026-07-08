#!/usr/bin/env python3
"""
Demo of Initial Condition Setup and Validation System

This example demonstrates the new initial condition setup system including:
- Field initialization from various sources
- Compatibility checking with governing equations
- Constraint validation and enforcement
"""

import sys
import os
from typing import Dict, List

# Add the earthsci_ast package to path for direct import
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../pkg/earthsci-ast-py/src'))

# Define the types we need directly (to avoid import issues)
from dataclasses import dataclass
from enum import Enum

class InitialConditionType(Enum):
    """Types of initial conditions."""
    CONSTANT = "constant"
    FUNCTION = "function"
    DATA = "data"

@dataclass
class InitialCondition:
    """Initial condition specification."""
    type: InitialConditionType
    value: float = None
    function: str = None
    data_source: str = None

@dataclass
class ModelVariable:
    """Model variable specification."""
    type: str
    units: str = None
    default: float = None
    description: str = None

# Import our new initial conditions setup system
from earthsci_ast.initial_conditions_setup import (
    InitialConditionProcessor,
    InitialConditionConfig,
    FieldConstraint,
    ConstraintOperator,
    setup_initial_conditions,
    create_atmospheric_constraints,
    InitialConditionSetupError
)

def create_atmospheric_chemistry_model() -> Dict[str, ModelVariable]:
    """Create a simple atmospheric chemistry model for demonstration."""
    return {
        "O3": ModelVariable(
            type="state",
            units="mol/mol",
            default=40e-9,  # 40 ppb
            description="Ozone mixing ratio"
        ),
        "NO": ModelVariable(
            type="state",
            units="mol/mol",
            default=0.1e-9,  # 0.1 ppb
            description="Nitric oxide mixing ratio"
        ),
        "NO2": ModelVariable(
            type="state",
            units="mol/mol",
            default=1.0e-9,  # 1 ppb
            description="Nitrogen dioxide mixing ratio"
        ),
        "HO2": ModelVariable(
            type="state",
            units="mol/mol",
            default=1e-12,  # 1 ppt
            description="Hydroperoxyl radical mixing ratio"
        ),
        "OH": ModelVariable(
            type="state",
            units="mol/mol",
            default=1e-12,  # 1 ppt
            description="Hydroxyl radical mixing ratio"
        ),
        # Parameters (not state variables)
        "T": ModelVariable(
            type="parameter",
            units="K",
            default=298.15,
            description="Temperature"
        ),
        "P": ModelVariable(
            type="parameter",
            units="Pa",
            default=101325.0,
            description="Pressure"
        )
    }

def demo_constant_initialization():
    """Demonstrate constant initial condition setup."""
    print("=== Demo 1: Constant Initial Conditions ===")

    variables = create_atmospheric_chemistry_model()

    # Set all state variables to a constant value
    ic = InitialCondition(
        type=InitialConditionType.CONSTANT,
        value=5e-9  # 5 ppb for all species
    )

    processor = InitialConditionProcessor()

    # Validate the initial conditions
    errors = processor.validate_initial_conditions(ic, variables)
    if errors:
        print(f"Validation errors: {errors}")
        return

    # Set up the initial field values
    field_values = processor.setup_initial_fields(ic, variables)

    print("Initial field values:")
    for var, value in field_values.items():
        var_info = variables[var]
        print(f"  {var}: {value:.2e} {var_info.units} ({var_info.description})")

    print("✓ Constant initialization successful\n")

def demo_constraint_enforcement():
    """Demonstrate constraint enforcement."""
    print("=== Demo 2: Constraint Enforcement ===")

    variables = create_atmospheric_chemistry_model()

    # Use atmospheric constraints
    constraints = create_atmospheric_constraints()

    # Set unrealistically high initial values
    ic = InitialCondition(
        type=InitialConditionType.CONSTANT,
        value=1e-2  # 10,000 ppm - way too high!
    )

    # Setup with constraints
    field_values, warnings = setup_initial_conditions(
        ic, variables, constraints=constraints
    )

    print("Constrained field values:")
    for var, value in field_values.items():
        var_info = variables[var]
        constraint = next((c for c in constraints if c.variable == var), None)
        if constraint:
            print(f"  {var}: {value:.2e} {var_info.units} (max allowed: {constraint.max_value:.2e})")
        else:
            print(f"  {var}: {value:.2e} {var_info.units} (unconstrained)")

    if warnings:
        print(f"Warnings: {warnings}")

    print("✓ Constraint enforcement successful\n")

def demo_custom_constraints():
    """Demonstrate custom constraint definitions."""
    print("=== Demo 3: Custom Constraints ===")

    variables = create_atmospheric_chemistry_model()
    processor = InitialConditionProcessor()

    # Add custom constraints
    processor.add_constraint(FieldConstraint(
        variable="OH",
        min_value=1e-14,
        max_value=1e-10,
        operator=ConstraintOperator.CLAMP,
        description="OH radical realistic bounds"
    ))

    processor.add_constraint(FieldConstraint(
        variable="HO2",
        min_value=1e-14,
        max_value=1e-9,
        operator=ConstraintOperator.WARN,
        description="HO2 radical realistic bounds"
    ))

    # Test with values that trigger constraints
    ic = InitialCondition(
        type=InitialConditionType.CONSTANT,
        value=1e-8  # High value to trigger constraints
    )

    field_values = processor.setup_initial_fields(ic, variables)

    print("Custom constrained field values:")
    for var, value in field_values.items():
        var_info = variables[var]
        print(f"  {var}: {value:.2e} {var_info.units}")

    print("✓ Custom constraints successful\n")

def demo_validation_errors():
    """Demonstrate validation error handling."""
    print("=== Demo 4: Validation Error Handling ===")

    variables = create_atmospheric_chemistry_model()

    # Create invalid initial condition (missing required field)
    ic = InitialCondition(
        type=InitialConditionType.CONSTANT,
        value=None  # Missing required value!
    )

    processor = InitialConditionProcessor()
    errors = processor.validate_initial_conditions(ic, variables)

    if errors:
        print("Expected validation errors:")
        for error in errors:
            print(f"  - {error}")

    # Try to setup with invalid IC (should raise exception)
    try:
        field_values = processor.setup_initial_fields(ic, variables)
        print("✗ Expected setup to fail but it didn't!")
    except InitialConditionSetupError as e:
        print(f"✓ Setup correctly failed with error: {e}")

    print()

def demo_error_constraint():
    """Demonstrate error-mode constraints."""
    print("=== Demo 5: Error-Mode Constraints ===")

    variables = create_atmospheric_chemistry_model()
    processor = InitialConditionProcessor()

    # Add constraint that errors on violation
    processor.add_constraint(FieldConstraint(
        variable="O3",
        max_value=1e-6,  # 1 ppm maximum
        operator=ConstraintOperator.ERROR,
        description="O3 safety limit"
    ))

    # Create test values that violate the constraint
    test_values = {"O3": 1e-5}  # 10 ppm - above safety limit

    try:
        processor.apply_constraints(test_values)
        print("✗ Expected constraint to raise error but it didn't!")
    except InitialConditionSetupError as e:
        print(f"✓ Safety constraint correctly raised error: {e}")

    print()

def main():
    """Run all demonstrations."""
    print("Initial Condition Setup and Validation System Demo")
    print("=" * 50)
    print()

    try:
        demo_constant_initialization()
        demo_constraint_enforcement()
        demo_custom_constraints()
        demo_validation_errors()
        demo_error_constraint()

        print("🎉 All demonstrations completed successfully!")
        print("The initial condition setup and validation system is working correctly.")

    except Exception as e:
        print(f"❌ Demo failed with error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()