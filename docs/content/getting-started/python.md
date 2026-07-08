# Getting Started with ESM Format in Python

The Python implementation provides scientific computing integration with NumPy, SciPy, SymPy, and matplotlib, making it ideal for data analysis, visualization, and numerical modeling workflows.

## Installation

### From PyPI (when available)
```bash
pip install earthsci-ast
```

### Development Installation
```bash
git clone https://github.com/EarthSciML/EarthSciAST.git
cd EarthSciAST/pkg/earthsci-ast-py
pip install -e .
```

### With Optional Dependencies
```bash
# For visualization
pip install earthsci-ast[viz]

# For symbolic computation
pip install earthsci-ast[symbolic]

# For all optional features
pip install earthsci-ast[all]
```

## Core Capabilities

The Python implementation provides **Analysis** tier capabilities:
- ✅ Parse, serialize, validate ESM files
- ✅ Mathematical expression manipulation
- ✅ Unit checking and dimensional analysis
- ✅ SymPy integration for symbolic computation
- ✅ NumPy/SciPy integration for numerical analysis
- ✅ Matplotlib visualization
- ✅ Jupyter notebook integration

## Basic Usage

### Loading and Validating ESM Files

```python
from earthsci_ast import load_esm, save_esm, validate
import json

# Load from file
esm_file = load_esm('model.esm')
print(f"Loaded: {esm_file.metadata.name}")

# Load from string
json_string = '''{"esm": "0.1.0", "metadata": {"name": "Test"}}'''
esm_file = load_esm(json_string)

# Load from dictionary
esm_dict = json.loads(json_string)
esm_file = load_esm(esm_dict)

# Validate structure and semantics
result = validate(esm_file)
if result.is_valid:
    print("✓ Valid ESM file")
else:
    for error in result.errors:
        print(f"✗ {error.path}: {error.message}")

# Save back to file
save_esm(esm_file, 'output.esm')
```

### Working with Expressions

```python
from earthsci_ast import (
    parse_expression, to_unicode, to_latex, to_ascii,
    substitute, free_variables, simplify
)

# Parse mathematical expression
expr = parse_expression({"op": "+", "args": ["x", {"op": "^", "args": ["y", "2"]}]})

# Pretty-print in different formats
print(f"Unicode: {to_unicode(expr)}")    # x + y²
print(f"LaTeX: {to_latex(expr)}")        # x + y^{2}
print(f"ASCII: {to_ascii(expr)}")        # x + y^2

# Analyze expression
variables = free_variables(expr)          # ['x', 'y']
print(f"Free variables: {variables}")

# Substitute values
substituted = substitute(expr, {'x': '2', 'y': 't'})
print(f"After substitution: {to_unicode(substituted)}")  # 2 + t²

# Simplify expression
simplified = simplify(expr)
print(f"Simplified: {to_unicode(simplified)}")
```

## NumPy and SciPy Integration

### Numerical Analysis

```python
import numpy as np
from scipy.integrate import odeint
from earthsci_ast import load_esm, to_numpy_system

# Load atmospheric chemistry model
esm_file = load_esm('atmospheric_model.esm')

# Convert to NumPy-compatible system
system = to_numpy_system(esm_file)

# Set up initial conditions and parameters
y0 = np.array([1e12, 1e11, 1e10])  # Initial concentrations
t = np.linspace(0, 86400, 1000)    # 24 hours
params = {'k1': 1e-4, 'k2': 2e-5}

# Define ODE system
def dydt(y, t, system, params):
    return system.evaluate(y, t, params)

# Solve ODE system
solution = odeint(dydt, y0, t, args=(system, params))

print(f"Final concentrations: {solution[-1]}")
```

### Statistical Analysis

```python
import numpy as np
import pandas as pd
from scipy import stats
from earthsci_ast import load_esm, validate

# Load multiple model runs
model_results = []
for i in range(100):
    # Load model with perturbed parameters
    esm_file = load_esm(f'model_run_{i}.esm')

    # Extract results
    result = simulate_model(esm_file)
    model_results.append(result)

# Convert to DataFrame for analysis
df = pd.DataFrame(model_results)

# Statistical analysis
mean_values = df.mean()
std_values = df.std()
confidence_intervals = df.apply(lambda x: stats.t.interval(0.95, len(x)-1, loc=x.mean(), scale=stats.sem(x)))

print("Mean concentrations:", mean_values)
print("95% Confidence intervals:", confidence_intervals)
```

## SymPy Integration

### Symbolic Computation

```python
import sympy as sp
from earthsci_ast import load_esm, to_sympy_expressions

# Load model
esm_file = load_esm('symbolic_model.esm')

# Convert expressions to SymPy
sympy_exprs = to_sympy_expressions(esm_file)

# Symbolic differentiation
x, t = sp.symbols('x t')
expr = sympy_exprs['reaction_rate']

# Calculate partial derivatives
dexpr_dx = sp.diff(expr, x)
dexpr_dt = sp.diff(expr, t)

print(f"∂/∂x: {dexpr_dx}")
print(f"∂/∂t: {dexpr_dt}")

# Solve algebraic equations symbolically
equilibrium_eq = sp.Eq(dexpr_dt, 0)
equilibrium_solution = sp.solve(equilibrium_eq, x)
print(f"Equilibrium: {equilibrium_solution}")

# Generate optimized NumPy functions
expr_func = sp.lambdify((x, t), expr, 'numpy')
gradient_func = sp.lambdify((x, t), [dexpr_dx, dexpr_dt], 'numpy')
```

### Jacobian Matrix Generation

```python
import sympy as sp
from earthsci_ast import load_esm, get_state_variables, get_equations

# Load chemical kinetics model
esm_file = load_esm('kinetics_model.esm')

# Get system variables and equations
state_vars = get_state_variables(esm_file)
equations = get_equations(esm_file)

# Convert to SymPy
symbols = [sp.Symbol(var.name) for var in state_vars]
sympy_eqs = [to_sympy(eq.rhs) for eq in equations]

# Compute Jacobian matrix
jacobian = sp.Matrix([[sp.diff(eq, var) for var in symbols] for eq in sympy_eqs])

print("Jacobian matrix:")
sp.pprint(jacobian)

# Generate optimized function
jacobian_func = sp.lambdify(symbols, jacobian, 'numpy')
```

## Visualization with Matplotlib

### Time Series Plotting

```python
import matplotlib.pyplot as plt
from earthsci_ast import load_esm, simulate_model

# Load and simulate model
esm_file = load_esm('atmospheric_model.esm')
time, solution = simulate_model(esm_file, t_span=(0, 86400))

# Create comprehensive plot
fig, axes = plt.subplots(2, 2, figsize=(12, 8))

# Concentration time series
axes[0, 0].plot(time/3600, solution)  # Convert to hours
axes[0, 0].set_xlabel('Time (hours)')
axes[0, 0].set_ylabel('Concentration (molec/cm³)')
axes[0, 0].set_title('Species Concentrations')
axes[0, 0].legend(['O₃', 'NO₂', 'OH'])
axes[0, 0].set_yscale('log')

# Phase space plot
axes[0, 1].plot(solution[:, 0], solution[:, 1])
axes[0, 1].set_xlabel('[O₃] (molec/cm³)')
axes[0, 1].set_ylabel('[NO₂] (molec/cm³)')
axes[0, 1].set_title('Phase Space')

# Rate analysis
rates = calculate_reaction_rates(esm_file, solution)
axes[1, 0].plot(time/3600, rates)
axes[1, 0].set_xlabel('Time (hours)')
axes[1, 0].set_ylabel('Reaction Rate')
axes[1, 0].set_title('Reaction Rates')

# Sensitivity analysis
sensitivity = calculate_sensitivity(esm_file, solution)
axes[1, 1].imshow(sensitivity, aspect='auto', cmap='RdBu_r')
axes[1, 1].set_title('Parameter Sensitivity')
axes[1, 1].set_xlabel('Parameters')
axes[1, 1].set_ylabel('Time')

plt.tight_layout()
plt.savefig('model_analysis.png', dpi=300)
plt.show()
```

### 3D Visualization

```python
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
import numpy as np
from earthsci_ast import load_esm, parameter_sweep

# Parameter sweep
esm_file = load_esm('parameter_study.esm')
param1_range = np.linspace(1e-5, 1e-3, 20)
param2_range = np.linspace(1e-6, 1e-4, 20)

# Run parameter sweep
results = parameter_sweep(esm_file, {
    'k1': param1_range,
    'k2': param2_range
})

# Create 3D surface plot
fig = plt.figure(figsize=(10, 8))
ax = fig.add_subplot(111, projection='3d')

X, Y = np.meshgrid(param1_range, param2_range)
Z = results['final_concentration']

surface = ax.plot_surface(X, Y, Z, cmap='viridis', alpha=0.8)
ax.set_xlabel('Parameter k1')
ax.set_ylabel('Parameter k2')
ax.set_zlabel('Final [O₃] (molec/cm³)')
ax.set_title('Parameter Sensitivity Surface')

plt.colorbar(surface)
plt.show()
```

## Jupyter Notebook Integration

### Interactive Model Exploration

```python
# Jupyter notebook cell
from earthsci_ast import load_esm, interactive_plot
from ipywidgets import interact, FloatSlider, IntSlider
import matplotlib.pyplot as plt

# Load model
esm_file = load_esm('interactive_model.esm')

# Create interactive parameter explorer
@interact(
    k1=FloatSlider(value=1e-4, min=1e-6, max=1e-2, step=1e-6, description='k1'),
    k2=FloatSlider(value=2e-5, min=1e-7, max=1e-3, step=1e-7, description='k2'),
    duration=IntSlider(value=24, min=1, max=168, description='Hours')
)
def explore_parameters(k1, k2, duration):
    # Update model parameters
    modified_esm = update_parameters(esm_file, {'k1': k1, 'k2': k2})

    # Simulate
    time, solution = simulate_model(modified_esm, t_span=(0, duration*3600))

    # Plot
    plt.figure(figsize=(10, 6))
    plt.plot(time/3600, solution)
    plt.xlabel('Time (hours)')
    plt.ylabel('Concentration')
    plt.title(f'Model with k1={k1:.2e}, k2={k2:.2e}')
    plt.legend(['O₃', 'NO₂', 'OH'])
    plt.yscale('log')
    plt.grid(True)
    plt.show()
```

### Model Comparison Dashboard

```python
import pandas as pd
import seaborn as sns
from earthsci_ast import load_esm, compare_models

# Load multiple model versions
models = {
    'v1.0': load_esm('model_v1.esm'),
    'v1.1': load_esm('model_v1.1.esm'),
    'v2.0': load_esm('model_v2.esm')
}

# Compare model performance
comparison_results = compare_models(models)

# Create comparison dashboard
fig, axes = plt.subplots(2, 2, figsize=(15, 10))

# Model complexity comparison
complexity_df = pd.DataFrame({
    'Version': list(models.keys()),
    'Variables': [len(model.get_variables()) for model in models.values()],
    'Equations': [len(model.get_equations()) for model in models.values()],
    'Parameters': [len(model.get_parameters()) for model in models.values()]
})

complexity_df.set_index('Version').plot(kind='bar', ax=axes[0,0])
axes[0,0].set_title('Model Complexity')
axes[0,0].set_ylabel('Count')

# Performance comparison
performance_df = pd.DataFrame(comparison_results['performance'])
sns.boxplot(data=performance_df, ax=axes[0,1])
axes[0,1].set_title('Simulation Performance')
axes[0,1].set_ylabel('Runtime (seconds)')

# Accuracy comparison
accuracy_df = pd.DataFrame(comparison_results['accuracy'])
sns.heatmap(accuracy_df, annot=True, ax=axes[1,0], cmap='RdYlBu_r')
axes[1,0].set_title('Model Accuracy (R²)')

# Feature comparison
features_df = pd.DataFrame(comparison_results['features'])
features_df.plot(kind='barh', ax=axes[1,1])
axes[1,1].set_title('Feature Availability')

plt.tight_layout()
plt.show()
```

## Unit Testing and Validation

### PyTest Integration

```python
import pytest
from earthsci_ast import load_esm, validate, simulate_model
import numpy as np

class TestESMModel:
    @pytest.fixture
    def sample_model(self):
        return load_esm('test_data/sample_model.esm')

    def test_model_loads_correctly(self, sample_model):
        assert sample_model.metadata.name == 'Sample Model'
        assert len(sample_model.models) > 0

    def test_model_validates(self, sample_model):
        result = validate(sample_model)
        assert result.is_valid, f"Validation errors: {result.errors}"

    def test_simulation_runs(self, sample_model):
        time, solution = simulate_model(sample_model, t_span=(0, 3600))

        assert len(time) > 0
        assert solution.shape[0] == len(time)
        assert not np.any(np.isnan(solution))
        assert np.all(solution >= 0)  # Physical constraint

    @pytest.mark.parametrize("param_value", [1e-6, 1e-4, 1e-2])
    def test_parameter_sensitivity(self, sample_model, param_value):
        modified_model = update_parameters(sample_model, {'k1': param_value})
        time, solution = simulate_model(modified_model)

        # Check that results are reasonable
        final_concentrations = solution[-1]
        assert np.all(final_concentrations > 0)
        assert np.all(final_concentrations < 1e15)  # Upper bound check
```

### Property-Based Testing

```python
from hypothesis import given, strategies as st
from earthsci_ast import parse_expression, to_unicode, substitute

@given(
    variable_name=st.text(min_size=1, max_size=10, alphabet=st.characters(whitelist_categories=['Lu', 'Ll'])),
    coefficient=st.floats(min_value=1e-10, max_value=1e10, allow_nan=False, allow_infinity=False)
)
def test_linear_expression_properties(variable_name, coefficient):
    # Create linear expression: coefficient * variable
    expr = {"op": "*", "args": [str(coefficient), variable_name]}

    # Should parse without error
    parsed = parse_expression(expr)
    assert parsed is not None

    # Should render to valid unicode
    unicode_str = to_unicode(parsed)
    assert variable_name in unicode_str

    # Substitution should work
    substituted = substitute(parsed, {variable_name: "1.0"})
    result_unicode = to_unicode(substituted)
    assert "1.0" in result_unicode or str(coefficient) in result_unicode
```

## Performance Optimization

### Vectorized Operations

```python
import numpy as np
from earthsci_ast import load_esm, vectorize_system

# Load model
esm_file = load_esm('large_model.esm')

# Create vectorized system for batch processing
vectorized_system = vectorize_system(esm_file)

# Process multiple initial conditions simultaneously
initial_conditions = np.random.random((1000, len(esm_file.get_state_variables())))
time_points = np.linspace(0, 86400, 100)

# Vectorized simulation (much faster than loops)
batch_results = vectorized_system.solve_batch(initial_conditions, time_points)

print(f"Processed {len(initial_conditions)} simulations in batch")
print(f"Results shape: {batch_results.shape}")  # (1000, 100, n_variables)
```

### Caching and Memoization

```python
from functools import lru_cache
from earthsci_ast import load_esm, parse_expression

# Cache parsed expressions
@lru_cache(maxsize=1000)
def cached_parse_expression(expr_json):
    return parse_expression(expr_json)

# Cache model compilation
@lru_cache(maxsize=10)
def cached_compile_model(model_file_hash):
    esm_file = load_esm(model_file_hash)
    return compile_to_numpy(esm_file)

# Use caching in performance-critical code
def process_many_expressions(expression_list):
    results = []
    for expr_json in expression_list:
        # This will be fast for repeated expressions
        parsed = cached_parse_expression(expr_json)
        results.append(evaluate_expression(parsed))
    return results
```

## Next Steps

- **Reference** — Browse the [Python API Reference](../api/python/)
- **Examples** — Work through the [examples directory](../examples/)
- **Units** — Read the [units standard](../units-standard/)

## Common Patterns

### Model Factory Pattern
```python
class ModelFactory:
    @staticmethod
    def atmospheric_chemistry(species_list, reaction_rates):
        """Create atmospheric chemistry model from species and rates."""
        variables = [
            ModelVariable(name=species, type='state', units='molec/cm^3')
            for species in species_list
        ]

        equations = []
        for reaction, rate in reaction_rates.items():
            # Parse reaction string and create equations
            eq = create_equation_from_reaction(reaction, rate)
            equations.append(eq)

        return Model(
            name='atmospheric_chemistry',
            variables=variables,
            equations=equations
        )

    @staticmethod
    def biogeochemical_cycle(pools, fluxes):
        """Create biogeochemical cycle model."""
        # Implementation here...
        pass
```

### Data Pipeline Integration
```python
from earthsci_ast import load_esm, validate
import pandas as pd

class ESMDataPipeline:
    def __init__(self, model_path):
        self.esm_file = load_esm(model_path)
        self._validate_model()

    def _validate_model(self):
        result = validate(self.esm_file)
        if not result.is_valid:
            raise ValueError(f"Invalid model: {result.errors}")

    def process_observations(self, data_df):
        """Process observational data through the model."""
        results = []
        for idx, row in data_df.iterrows():
            # Set model parameters from observations
            model_result = self.run_model_with_params(row.to_dict())
            results.append(model_result)

        return pd.DataFrame(results)

    def parameter_estimation(self, observations):
        """Estimate parameters from observations."""
        from scipy.optimize import minimize

        def objective(params):
            predictions = self.predict(params)
            return np.sum((predictions - observations) ** 2)

        result = minimize(objective, initial_guess)
        return result.x
```

Ready to dive into scientific computing? Browse the [examples](../examples/) and the [Python API Reference](../api/python/).