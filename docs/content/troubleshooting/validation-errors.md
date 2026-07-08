# Common Validation Errors

This guide helps you diagnose and fix the most common ESM validation errors. Each error includes the problem description, common causes, and step-by-step solutions.

## Schema Validation Errors

### Error: Missing Required Field

**Message**: `Required property 'field_name' is missing`

**Cause**: A required field is not present in your ESM file.

**Solution**:
```json
// ❌ Missing required metadata field
{
  "esm": "0.1.0"
}

// ✅ Add required metadata
{
  "esm": "0.1.0",
  "metadata": {
    "name": "My Model",
    "description": "Model description"
  }
}
```

**Common missing fields**:
- `esm` (version string)
- `metadata.name` (model name)
- `variables[].name` (variable name)
- `variables[].type` (variable type)
- `equations[].lhs` (equation left-hand side)
- `equations[].rhs` (equation right-hand side)

### Error: Invalid Field Type

**Message**: `Expected string but got number at path 'metadata.name'`

**Cause**: Field has wrong data type.

**Solution**:
```json
// ❌ Wrong type (number instead of string)
{
  "metadata": {
    "name": 123
  }
}

// ✅ Correct type (string)
{
  "metadata": {
    "name": "Model Name"
  }
}
```

### Error: Invalid Enum Value

**Message**: `Value 'invalid_type' is not allowed. Must be one of: state, parameter, algebraic`

**Cause**: Using an invalid value for an enumerated field.

**Solution**:
```json
// ❌ Invalid variable type
{
  "variables": [
    {
      "name": "x",
      "type": "invalid_type"
    }
  ]
}

// ✅ Valid variable type
{
  "variables": [
    {
      "name": "x",
      "type": "state"
    }
  ]
}
```

**Valid variable types**: `state`, `parameter`, `algebraic`, `forcing`

**Valid operators**: `+`, `-`, `*`, `/`, `^`, `sqrt`, `exp`, `log`, `sin`, `cos`, `tan`, etc.

## Expression Validation Errors

### Error: Undefined Variable Reference

**Message**: `Variable 'y' referenced in equation but not defined`

**Cause**: An equation references a variable that doesn't exist in the variables list.

**Solution**:
```json
// ❌ 'y' referenced but not defined
{
  "variables": [
    {"name": "x", "type": "state"}
  ],
  "equations": [
    {
      "lhs": "x",
      "rhs": {"op": "+", "args": ["x", "y"]}
    }
  ]
}

// ✅ Define all referenced variables
{
  "variables": [
    {"name": "x", "type": "state"},
    {"name": "y", "type": "state"}
  ],
  "equations": [
    {
      "lhs": "x",
      "rhs": {"op": "+", "args": ["x", "y"]}
    }
  ]
}
```

### Error: Invalid Expression Syntax

**Message**: `Operator '+' requires exactly 2 arguments, got 1`

**Cause**: Mathematical operator used with wrong number of arguments.

**Solution**:
```json
// ❌ Addition with only one argument
{
  "rhs": {"op": "+", "args": ["x"]}
}

// ✅ Addition with two arguments
{
  "rhs": {"op": "+", "args": ["x", "y"]}
}

// ✅ For negation, use unary minus
{
  "rhs": {"op": "-", "args": ["x"]}
}
```

**Operator argument requirements**:
- **Binary**: `+`, `-`, `*`, `/`, `^` require exactly 2 arguments
- **Unary**: `-`, `sqrt`, `exp`, `log`, `sin`, `cos` require exactly 1 argument
- **N-ary**: Some operators can take multiple arguments (implementation-specific)

### Error: Circular Variable Dependencies

**Message**: `Circular dependency detected: x → y → z → x`

**Cause**: Variables depend on each other in a loop.

**Solution**:
```json
// ❌ Circular dependency
{
  "variables": [
    {"name": "x", "type": "algebraic", "expression": {"op": "+", "args": ["y", "1"]}},
    {"name": "y", "type": "algebraic", "expression": {"op": "*", "args": ["z", "2"]}},
    {"name": "z", "type": "algebraic", "expression": {"op": "/", "args": ["x", "3"]}}
  ]
}

// ✅ Break the cycle with parameters or external inputs
{
  "variables": [
    {"name": "x", "type": "algebraic", "expression": {"op": "+", "args": ["y", "1"]}},
    {"name": "y", "type": "algebraic", "expression": {"op": "*", "args": ["z", "2"]}},
    {"name": "z", "type": "parameter", "value": "1.0"}
  ]
}
```

## Unit Validation Errors

### Error: Unit Mismatch in Equation

**Message**: `Unit mismatch in equation for 'x': left side has units 'kg/s', right side has units 'kg'`

**Cause**: The units on both sides of an equation don't match.

**Solution**:
```json
// ❌ Unit mismatch
{
  "variables": [
    {"name": "mass", "type": "state", "units": "kg"},
    {"name": "rate", "type": "parameter", "units": "kg/s"}
  ],
  "equations": [
    {
      "lhs": "mass",
      "rhs": {"op": "*", "args": ["rate", "1"]}
    }
  ]
}

// ✅ Add time dimension or fix units
{
  "variables": [
    {"name": "mass", "type": "state", "units": "kg"},
    {"name": "rate", "type": "parameter", "units": "kg/s"},
    {"name": "dt", "type": "parameter", "units": "s"}
  ],
  "equations": [
    {
      "lhs": "mass",
      "rhs": {"op": "*", "args": ["rate", "dt"]}
    }
  ]
}
```

### Error: Inconsistent Units in Expression

**Message**: `Cannot add quantities with units 'kg' and 'm': units must match for addition`

**Cause**: Adding or subtracting quantities with incompatible units.

**Solution**:
```json
// ❌ Adding incompatible units
{
  "rhs": {"op": "+", "args": ["mass", "length"]}
}

// ✅ Ensure compatible units
{
  "rhs": {"op": "+", "args": ["mass1", "mass2"]}
}

// ✅ Or use dimensionless ratios
{
  "rhs": {"op": "+", "args": [
    {"op": "/", "args": ["mass", "reference_mass"]},
    {"op": "/", "args": ["length", "reference_length"]}
  ]}
}
```

## Model Structure Errors

### Error: No Equations for State Variable

**Message**: `State variable 'x' has no governing equation`

**Cause**: A state variable is defined but has no equation describing its time evolution.

**Solution**:
```json
// ❌ State variable without equation
{
  "variables": [
    {"name": "x", "type": "state"},
    {"name": "y", "type": "state"}
  ],
  "equations": [
    {
      "lhs": "x",
      "rhs": {"op": "*", "args": ["-1", "x"]}
    }
    // Missing equation for 'y'
  ]
}

// ✅ Add equation for every state variable
{
  "variables": [
    {"name": "x", "type": "state"},
    {"name": "y", "type": "state"}
  ],
  "equations": [
    {
      "lhs": "x",
      "rhs": {"op": "*", "args": ["-1", "x"]}
    },
    {
      "lhs": "y",
      "rhs": {"op": "*", "args": ["0.5", "x"]}
    }
  ]
}
```

### Error: Equation for Non-State Variable

**Message**: `Equation provided for parameter 'k' but parameters cannot have time derivatives`

**Cause**: Trying to write a differential equation for a parameter or algebraic variable.

**Solution**:
```json
// ❌ Equation for parameter
{
  "variables": [
    {"name": "k", "type": "parameter", "value": "1.0"}
  ],
  "equations": [
    {
      "lhs": "k",
      "rhs": {"op": "*", "args": ["2", "k"]}
    }
  ]
}

// ✅ Remove equation or change variable type
{
  "variables": [
    {"name": "k", "type": "state", "initial_value": "1.0"}
  ],
  "equations": [
    {
      "lhs": "k",
      "rhs": {"op": "*", "args": ["2", "k"]}
    }
  ]
}

// ✅ Or keep as parameter without equation
{
  "variables": [
    {"name": "k", "type": "parameter", "value": "1.0"}
  ],
  "equations": []
}
```

## Coupling Validation Errors

### Error: Invalid Coupling Reference

**Message**: `Coupling references model 'ocean' which does not exist`

**Cause**: A coupling entry references a model that isn't defined.

**Solution**:
```json
// ❌ Reference to undefined model
{
  "models": {
    "atmosphere": { ... }
  },
  "coupling": [
    {
      "source_model": "atmosphere",
      "target_model": "ocean",
      "coupling_function": "..."
    }
  ]
}

// ✅ Define all referenced models
{
  "models": {
    "atmosphere": { ... },
    "ocean": { ... }
  },
  "coupling": [
    {
      "source_model": "atmosphere",
      "target_model": "ocean",
      "coupling_function": "..."
    }
  ]
}
```

### Error: Variable Not Found in Coupling

**Message**: `Variable 'temperature' not found in model 'atmosphere' for coupling`

**Cause**: Coupling references a variable that doesn't exist in the specified model.

**Solution**:
```json
// ❌ Variable not in model
{
  "models": {
    "atmosphere": {
      "variables": [
        {"name": "pressure", "type": "state"}
      ]
    }
  },
  "coupling": [
    {
      "source_model": "atmosphere",
      "source_variable": "temperature"
    }
  ]
}

// ✅ Use existing variable or add the variable
{
  "models": {
    "atmosphere": {
      "variables": [
        {"name": "pressure", "type": "state"},
        {"name": "temperature", "type": "state"}
      ]
    }
  },
  "coupling": [
    {
      "source_model": "atmosphere",
      "source_variable": "temperature"
    }
  ]
}
```

## Debugging Strategies

### 1. Use Incremental Validation

Start with a minimal model and add complexity gradually:

```json
// Start minimal
{
  "esm": "0.1.0",
  "metadata": {"name": "Test"}
}

// Add one model
{
  "esm": "0.1.0",
  "metadata": {"name": "Test"},
  "models": {
    "simple": {
      "name": "simple",
      "variables": [],
      "equations": []
    }
  }
}

// Add variables one by one...
```

### 2. Validate Early and Often

Use validation in your development workflow:

```bash
# Validate after each change
esm validate model.esm

# Use watch mode if available
esm validate model.esm --watch
```

```julia
# In Julia REPL
using EarthSciAST
esm_file = load_esm("model.esm")
result = validate(esm_file)
@show result.errors
```

### 3. Check Error Paths

Error messages include JSON paths to help you locate issues:

```
Error at models.atmosphere.variables[2].name: Required property 'name' is missing
         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
         This path shows: models → atmosphere → variables → 3rd item → name field
```

### 4. Use Schema Documentation

Refer to the JSON schema for authoritative field requirements:

```bash
# Generate schema documentation
esm schema --output schema.json

# Validate against specific schema version
esm validate model.esm --schema schema.json
```

### 5. Common Fix Patterns

**Pattern 1: Add missing fields**
```json
// Before
{"name": "x"}

// After
{"name": "x", "type": "state", "units": "dimensionless"}
```

**Pattern 2: Fix types**
```json
// Before
{"value": "123"}

// After (if numeric expected)
{"value": 123}

// Or (if string expected)
{"value": "123"}
```

**Pattern 3: Define before use**
```json
// Before: using undefined 'k'
{
  "equations": [{"rhs": {"op": "*", "args": ["k", "x"]}}]
}

// After: define 'k' first
{
  "parameters": [{"name": "k", "value": "1.0"}],
  "equations": [{"rhs": {"op": "*", "args": ["k", "x"]}}]
}
```

## Language-Specific Validation

### Julia
```julia
using EarthSciAST

esm_file = load_esm("model.esm")
result = validate(esm_file)

if !result.is_valid
    for error in result.errors
        println("Error: $(error.message)")
        println("Path: $(error.path)")
        println("Type: $(error.error_type)")
        println()
    end
end
```

### TypeScript
```typescript
import { load, validate } from '@earthsciml/ast';

const esmFile = load(esmData);
const result = validate(esmFile);

if (!result.isValid) {
  result.errors.forEach(error => {
    console.error(`${error.path}: ${error.message}`);
    console.error(`Error type: ${error.errorType}`);
  });
}
```

### Python
```python
from earthsci_ast import load_esm, validate

esm_file = load_esm('model.esm')
result = validate(esm_file)

if not result.is_valid:
    for error in result.errors:
        print(f"Error at {error.path}: {error.message}")
        print(f"Error type: {error.error_type}")
```

### Rust
```bash
# CLI validation with detailed output
esm validate model.esm --verbose

# JSON output for programmatic use
esm validate model.esm --format json
```

## Getting Help

1. **Check this guide first** for common issues
2. **Use verbose validation** to get detailed error information
3. **Test with minimal examples** to isolate problems
4. **Consult language-specific guides** for implementation details
5. **File issues** at the GitHub repository with your ESM file and error message

## Prevention Tips

✅ **Use schema validation** during development
✅ **Start simple** and add complexity incrementally
✅ **Define variables** before using them in expressions
✅ **Check units** are consistent throughout
✅ **Test examples** from documentation work in your environment
✅ **Keep backups** of working models before making changes

Ready to solve validation issues? Use this guide alongside the [Standard Library reference](../../standard_library/) for comprehensive understanding!