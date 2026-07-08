# Minimal Example

The simplest valid ESM file demonstrates the core structure and required fields. This example shows a basic mathematical model with one equation.

## The Minimal ESM File

Save this as `minimal.esm`:

```json
{
  "esm": "0.1.0",
  "metadata": {
    "name": "Minimal Example",
    "description": "The simplest valid ESM file",
    "author": "ESM Documentation",
    "created": "2026-02-15"
  },
  "models": {
    "simple": {
      "name": "simple",
      "variables": [
        {
          "name": "x",
          "type": "state",
          "units": "dimensionless",
          "description": "State variable",
          "initial_value": "1.0"
        }
      ],
      "equations": [
        {
          "lhs": "x",
          "rhs": {
            "op": "*",
            "args": ["-0.1", "x"]
          },
          "description": "Exponential decay: dx/dt = -0.1 * x"
        }
      ]
    }
  }
}
```

## Understanding the Structure

### Top-Level Fields

```json
{
  "esm": "0.1.0",          // Format version (required)
  "metadata": { ... },      // Model information (required)
  "models": { ... }         // Model definitions (at least one section required)
}
```

### Metadata Section

```json
"metadata": {
  "name": "Minimal Example",           // Human-readable name (required)
  "description": "...",                // What this model does (optional but recommended)
  "author": "ESM Documentation",       // Who created it (optional)
  "created": "2026-02-15"              // When it was created (optional)
}
```

### Model Definition

```json
"models": {
  "simple": {                          // Model identifier
    "name": "simple",                  // Model name (should match key)
    "variables": [ ... ],              // Variable definitions (required)
    "equations": [ ... ]               // Mathematical equations (required)
  }
}
```

### Variable Definition

```json
{
  "name": "x",                         // Variable name (required)
  "type": "state",                     // Variable type (required)
  "units": "dimensionless",            // Physical units (recommended)
  "description": "State variable",      // What it represents (recommended)
  "initial_value": "1.0"              // Starting value (optional)
}
```

### Equation Definition

```json
{
  "lhs": "x",                          // Left-hand side variable (required)
  "rhs": {                             // Right-hand side expression (required)
    "op": "*",                         // Mathematical operator
    "args": ["-0.1", "x"]              // Operands
  },
  "description": "Exponential decay"   // Human explanation (recommended)
}
```

## Working with the Minimal Example

### Julia
```julia
using EarthSciAST, ModelingToolkit, DifferentialEquations

# Load the minimal example
esm_file = load_esm("minimal.esm")
println("Loaded: ", esm_file.metadata.name)

# Convert to ModelingToolkit system
mtk_system = to_mtk(esm_file)

# Solve the differential equation
prob = ODEProblem(mtk_system, [], (0.0, 10.0))
sol = solve(prob, Tsit5())

# The solution should show exponential decay
println("Initial value: ", sol[1])
println("Final value: ", sol[end])
println("Decay factor: ", sol[end] / sol[1])  # Should be ≈ exp(-1)
```

### TypeScript
```typescript
import { load, validate, toUnicode } from '@earthsciml/ast';
import fs from 'fs';

// Load and validate
const esmData = fs.readFileSync('minimal.esm', 'utf8');
const esmFile = load(esmData);

console.log('Loaded:', esmFile.metadata.name);

// Validation
const result = validate(esmFile);
if (result.isValid) {
  console.log('✓ Valid ESM file');
} else {
  console.log('Validation errors:', result.errors);
}

// Pretty-print the equation
const equation = esmFile.models.simple.equations[0];
console.log('Equation:', `d${equation.lhs}/dt =`, toUnicode(equation.rhs));
// Output: dx/dt = -0.1⋅x
```

### Python
```python
from earthsci_ast import load_esm, validate, to_unicode
import numpy as np
from scipy.integrate import odeint
import matplotlib.pyplot as plt

# Load and validate
esm_file = load_esm('minimal.esm')
print(f"Loaded: {esm_file.metadata.name}")

validation = validate(esm_file)
if validation.is_valid:
    print("✓ Valid ESM file")
else:
    print(f"Validation errors: {validation.errors}")

# Manual numerical solution (ESM→SciPy integration)
def model(x, t):
    return -0.1 * x  # From the equation: dx/dt = -0.1 * x

# Initial condition and time points
x0 = 1.0
t = np.linspace(0, 10, 100)

# Solve ODE
solution = odeint(model, x0, t)

# Plot results
plt.figure(figsize=(8, 5))
plt.plot(t, solution, label='Numerical solution')
plt.plot(t, np.exp(-0.1 * t), '--', label='Analytical solution')
plt.xlabel('Time')
plt.ylabel('x')
plt.title('Exponential Decay: dx/dt = -0.1x')
plt.legend()
plt.grid(True)
plt.show()

# Pretty-print equation
equation = esm_file.models['simple'].equations[0]
print(f"Equation: d{equation.lhs}/dt = {to_unicode(equation.rhs)}")
```

### Rust CLI
```bash
# Validate the file
esm validate minimal.esm

# Show file information
esm info minimal.esm

# Pretty-print equations
esm pretty-print minimal.esm --format unicode

# Convert to compact JSON
esm convert minimal.esm -o minimal_compact.json -f compact-json
```

## Key Learning Points

### 1. Required Structure
Every ESM file must have:
- `esm` version field
- `metadata` with at least a `name`
- At least one model in `models`, `reaction_systems`, or other component sections

### 2. Self-Describing
The equation `dx/dt = -0.1 * x` is fully specified in the JSON:
- Variable `x` is defined with its type and units
- The equation shows the rate of change of `x`
- No external dependencies or undefined symbols

### 3. Language Agnostic
The same `.esm` file works identically across:
- Julia (converts to ModelingToolkit)
- TypeScript (web visualization)
- Python (SciPy integration)
- Rust (high-performance validation)

### 4. Human and Machine Readable
- Humans can read the JSON structure and understand the model
- Machines can parse, validate, and simulate automatically
- Version control systems can track changes meaningfully

## Variations

### With Parameters
```json
{
  "models": {
    "simple": {
      "name": "simple",
      "variables": [
        {
          "name": "x",
          "type": "state",
          "units": "dimensionless",
          "initial_value": "1.0"
        }
      ],
      "parameters": [
        {
          "name": "k",
          "value": "0.1",
          "units": "1/s",
          "description": "Decay rate constant"
        }
      ],
      "equations": [
        {
          "lhs": "x",
          "rhs": {
            "op": "*",
            "args": [{"op": "-", "args": ["k"]}, "x"]
          },
          "description": "Parameterized decay"
        }
      ]
    }
  }
}
```

### With Multiple Variables
```json
{
  "models": {
    "simple": {
      "name": "simple",
      "variables": [
        {
          "name": "x",
          "type": "state",
          "units": "dimensionless",
          "initial_value": "1.0"
        },
        {
          "name": "y",
          "type": "state",
          "units": "dimensionless",
          "initial_value": "0.0"
        }
      ],
      "equations": [
        {
          "lhs": "x",
          "rhs": {"op": "*", "args": ["-0.1", "x"]},
          "description": "x decays"
        },
        {
          "lhs": "y",
          "rhs": {"op": "*", "args": ["0.1", "x"]},
          "description": "y grows from x decay"
        }
      ]
    }
  }
}
```

## Next Steps

Now that you understand the basic structure:

1. **Try More Complex Examples** — See [Atmospheric Chemistry](atmospheric-chemistry.md)
2. **Understand Validation** — Read the [Validation Errors](../troubleshooting/validation-errors/) guide
3. **Browse Standard Library** — See the [Standard Library](../standard_library/) for shipped subsystems

## Common Mistakes

❌ **Missing required fields**
```json
{
  "esm": "0.1.0"
  // Missing metadata - will fail validation
}
```

❌ **Undefined variables in equations**
```json
{
  "equations": [
    {
      "lhs": "x",
      "rhs": {"op": "+", "args": ["y", "z"]}  // y and z not defined
    }
  ]
}
```

❌ **Invalid expression syntax**
```json
{
  "rhs": {"op": "+", "args": ["x"]}  // + requires 2 arguments
}
```

✅ **Correct minimal structure**
- All required fields present
- Variables defined before use in equations
- Valid expression syntax
- Consistent naming

Ready to build more complex models? Try the [Atmospheric Chemistry Example](atmospheric-chemistry.md)!