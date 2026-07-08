# Quick Start Guide

Get up and running with ESM format in 5 minutes! This guide shows you how to create, validate, and work with your first ESM file.

## What is ESM Format?

The ESM (`.esm`) format is a JSON-based serialization format for Earth System Models. It's designed to be:
- **Language-agnostic** — Works with Julia, TypeScript, Python, Rust, and more
- **Human-readable** — Easy to understand and version control
- **Self-describing** — All equations and variables are fully specified

## Your First ESM File

Let's create a simple atmospheric chemistry model. Save this as `simple-model.esm`:

```json
{
  "esm": "0.1.0",
  "metadata": {
    "name": "Simple Atmospheric Chemistry",
    "description": "Basic ozone photolysis example",
    "author": "Your Name",
    "created": "2026-02-15"
  },
  "models": {
    "atmosphere": {
      "name": "atmosphere",
      "variables": [
        {
          "name": "O3",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Ozone concentration"
        },
        {
          "name": "O2",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Oxygen concentration"
        },
        {
          "name": "O",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Atomic oxygen concentration"
        }
      ],
      "equations": [
        {
          "lhs": "O3",
          "rhs": {
            "op": "*",
            "args": ["-1.2e-4", "O3"]
          },
          "description": "Ozone photolysis: O3 → O2 + O"
        }
      ]
    }
  }
}
```

## Working with Your ESM File

### Julia
```julia
using EarthSciAST

# Load and parse
esm_file = load_esm("simple-model.esm")
println("Loaded model: ", esm_file.metadata.name)

# Convert to ModelingToolkit for simulation
mtk_system = to_mtk(esm_file)
```

### TypeScript/JavaScript
```typescript
import { load, validate, toUnicode } from '@earthsciml/ast';

// Load and validate
const esm_file = load(fs.readFileSync('simple-model.esm', 'utf8'));
const result = validate(esm_file);

if (result.isValid) {
  console.log('Valid ESM file!');

  // Pretty-print the equation
  const equation = esm_file.models.atmosphere.equations[0];
  console.log('Equation:', toUnicode(equation.rhs));
}
```

### Python
```python
from earthsci_ast import load_esm, validate, to_unicode

# Load and validate
esm_file = load_esm('simple-model.esm')
validation_result = validate(esm_file)

if validation_result.is_valid:
    print(f"Loaded: {esm_file.metadata.name}")

    # Display equation in readable form
    equation = esm_file.models['atmosphere'].equations[0]
    print(f"Equation: {to_unicode(equation.rhs)}")
```

### Rust/CLI
```bash
# Validate the file
esm validate simple-model.esm

# Pretty-print equations
esm pretty-print simple-model.esm --format unicode

# Get file information
esm info simple-model.esm
```

## Validation and Error Checking

All ESM libraries provide comprehensive validation:

```typescript
// TypeScript example
const result = validate(esm_file);
if (!result.isValid) {
  result.errors.forEach(error => {
    console.error(`Error at ${error.path}: ${error.message}`);
  });
}
```

Common validation checks include:
- ✅ Schema compliance (required fields, correct types)
- ✅ Unit consistency across equations
- ✅ Variable reference validity
- ✅ Expression syntax correctness

## Next Steps

Now that you have your first ESM file working:

1. **Explore Examples** — See [Real-World Examples](../examples/) for more complex models
2. **Learn the Format** — Browse the [Standard Library](../standard_library/) and [registered functions](../registered_functions/)
3. **Choose Your Language** — Check the language-specific getting started guides:
   - [Julia Guide](julia.md) — For simulation and ModelingToolkit integration
   - [TypeScript Guide](typescript.md) — For web applications and visualization
   - [Python Guide](python.md) — For scientific computing workflows
   - [Rust Guide](rust.md) — For high-performance CLI tools

## Common Patterns

### Adding More Variables
```json
{
  "name": "NO2",
  "type": "state",
  "units": "molec/cm^3",
  "description": "Nitrogen dioxide concentration",
  "initial_value": "1e12"
}
```

### Complex Expressions
```json
{
  "op": "+",
  "args": [
    {"op": "*", "args": ["k1", "A", "B"]},
    {"op": "*", "args": ["k2", "C"]}
  ]
}
```

### Adding Parameters
```json
{
  "name": "j_O3",
  "type": "parameter",
  "units": "1/s",
  "value": "1.2e-4",
  "description": "Ozone photolysis rate constant"
}
```

Ready to dive deeper? Choose your next step from the navigation above!