# Coupling Iteration and Convergence Control

This document describes the coupling iteration and convergence control functionality implemented for ESM Format.

## Overview

The coupling iteration module provides sophisticated control for iterative coupling between multiple Earth system components, including:

- **Convergence checking** with multiple criteria (absolute, relative, residual, mixed)
- **Iteration limits** and early termination conditions
- **Relaxation methods** for numerical stability (fixed, adaptive, Aitken)
- **Convergence acceleration** techniques (Aitken, Anderson mixing, simplified Newton)

## Key Classes

### CouplingIterator

The main class that manages the iterative coupling process.

```python
from earthsci_ast import CouplingIterator, ConvergenceConfig, RelaxationConfig, AccelerationConfig

# Create configuration objects
convergence_config = ConvergenceConfig(
    method=ConvergenceMethod.MIXED,
    absolute_tolerance=1e-6,
    relative_tolerance=1e-4,
    max_iterations=100
)

relaxation_config = RelaxationConfig(
    method=RelaxationMethod.FIXED,
    relaxation_factor=0.5
)

acceleration_config = AccelerationConfig(
    method=AccelerationMethod.AITKEN
)

# Create iterator
iterator = CouplingIterator(convergence_config, relaxation_config, acceleration_config)
```

### Configuration Classes

#### ConvergenceConfig
- `method`: Convergence checking method (ABSOLUTE, RELATIVE, RESIDUAL, MIXED)
- `absolute_tolerance`: Absolute error tolerance
- `relative_tolerance`: Relative error tolerance
- `residual_tolerance`: Residual error tolerance
- `max_iterations`: Maximum number of iterations
- `min_iterations`: Minimum number of iterations
- `check_variables`: Optional list of variables to check (None = all)

#### RelaxationConfig
- `method`: Relaxation method (NONE, FIXED, ADAPTIVE, AITKEN)
- `relaxation_factor`: Fixed relaxation factor (0 < factor < 1)
- `adaptive_range`: Range for adaptive relaxation
- `aitken_damping`: Damping factor for Aitken relaxation

#### AccelerationConfig
- `method`: Acceleration method (NONE, AITKEN, ANDERSON, SIMPLIFIED_NEWTON)
- `anderson_depth`: Depth for Anderson acceleration
- `anderson_beta`: Beta parameter for Anderson mixing
- `newton_jacobian_update_freq`: Jacobian update frequency

## Usage Example

```python
from earthsci_ast import create_default_coupling_iterator
from earthsci_ast.types import EsmFile, Metadata

# Create a simple coupling iterator with sensible defaults
iterator = create_default_coupling_iterator(
    max_iterations=100,
    tolerance=1e-6,
    relaxation_factor=0.5,
    use_acceleration=True
)

# Define your coupling function
def my_coupling_function(variables, **kwargs):
    # Implement your coupling logic here
    # Return (updated_variables, residuals)
    updated_vars = {}
    residuals = {}

    # Your coupling calculations...
    for var, value in variables.items():
        # Example: simple iterative update
        updated_vars[var] = some_coupling_calculation(value)
        residuals[var] = updated_vars[var] - value

    return updated_vars, residuals

# Set up initial conditions
initial_variables = {
    'temperature': 298.15,
    'pressure': 101325.0,
    'concentration_O3': 40e-9
}

# Create ESM file (simplified for example)
esm_file = EsmFile(
    version="0.1.0",
    metadata=Metadata(title="Coupling Example"),
    models=[],
    reaction_systems=[],
    couplings=[]
)

# Run coupling iteration
result = iterator.iterate_coupling(
    esm_file=esm_file,
    initial_variables=initial_variables,
    coupling_function=my_coupling_function
)

# Check results
if result.converged:
    print(f"Converged in {result.total_iterations} iterations")
    print(f"Final values: {result.final_state.variables}")
else:
    print(f"Did not converge: {result.convergence_reason}")
```

## Convergence Methods

### ABSOLUTE
Checks if the absolute change in variables is below the tolerance:
`|x_new - x_old| < absolute_tolerance`

### RELATIVE
Checks if the relative change in variables is below the tolerance:
`|x_new - x_old| / |x_old| < relative_tolerance`

### RESIDUAL
Checks if the residuals are below the tolerance:
`|F(x)| < residual_tolerance`

### MIXED
Requires all criteria (absolute, relative, and residual) to be satisfied.

## Relaxation Methods

### FIXED
Uses a constant relaxation factor:
`x_new = α * x_coupling + (1-α) * x_old`

### ADAPTIVE
Adjusts the relaxation factor based on convergence behavior.

### AITKEN
Uses Aitken's Δ² method to compute optimal relaxation factors.

## Acceleration Methods

### AITKEN
Applies Aitken's Δ² acceleration to extrapolate convergence.

### ANDERSON
Uses Anderson mixing (DIIS) for acceleration with multiple previous iterations.

### SIMPLIFIED_NEWTON
Uses approximate Jacobian information for Newton-like acceleration.

## Convenience Functions

### create_default_coupling_iterator
Creates an iterator with sensible defaults for most applications.

### create_adaptive_coupling_iterator
Creates an iterator with adaptive relaxation and Anderson acceleration for challenging problems.

## Advanced Features

### Iteration History
The `CouplingResult` contains the full iteration history:

```python
result = iterator.iterate_coupling(...)

# Access iteration history
for i, state in enumerate(result.iteration_history):
    print(f"Iteration {state.iteration}: {state.variables}")
    if state.convergence_metrics:
        print(f"  Convergence metrics: {state.convergence_metrics}")
```

### Custom Convergence Checking
You can implement custom convergence checkers by subclassing `ConvergenceChecker`.

### Performance Monitoring
The result includes execution time and detailed convergence metrics for performance analysis.

## Error Handling

The implementation includes comprehensive error handling:
- Invalid configuration parameters are caught at initialization
- Coupling function errors are caught and reported
- Numerical issues (division by zero, singular matrices) are handled gracefully
- Fallback methods are used when advanced algorithms fail

## Integration with ESM Format

The coupling iteration system is fully integrated with the ESM Format ecosystem:
- Uses `CouplingGraph` for dependency analysis
- Compatible with existing `simulation` module
- Works with `ScopedReferenceResolver` for variable resolution
- Supports all ESM Format component types

This implementation provides robust, production-ready coupling iteration control suitable for complex Earth system modeling applications.