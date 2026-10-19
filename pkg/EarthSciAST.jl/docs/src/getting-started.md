# Getting Started

This guide will walk you through the basics of using EarthSciAST.jl.

## Installation

EarthSciAST.jl is registered in the Julia General Registry and can be installed using:

```julia
using Pkg
Pkg.add("EarthSciAST")
```

For development versions:

```julia
using Pkg
Pkg.add(url="https://github.com/EarthSciML/EarthSciAST.git", subdir="pkg/EarthSciAST.jl")
```

## Basic Usage

### Loading ESM Files

```julia
using EarthSciAST

# Load from a file
esm_file = load_path("path/to/model.esm")

# Load from a JSON string
json_str = """
{
  "esm": "1.0.0",
  "metadata": {"name": "Decay"},
  "models": {
    "Decay": {
      "variables": {
        "N": {"type": "unknown", "units": "mol", "default": 100.0},
        "lambda": {"type": "parameter", "units": "1/s", "default": 0.1}
      },
      "equations": [
        {"lhs": {"op": "D", "args": ["N"], "wrt": "t"},
         "rhs": {"op": "*", "args": [{"op": "-", "args": ["lambda"]}, "N"]}}
      ]
    }
  }
}
"""
esm_file = load_string(json_str)
```

Both raise a `ParseError` on text that is not JSON and a
`SchemaValidationError` on JSON that does not match the schema.

### Working with Models

```julia
# Access models by name
model = esm_file.models["Decay"]

# Inspect model structure
println("Unknowns: ", unknowns(model))      # ["N"]
println("Parameters: ", parameters(model))  # ["lambda"]
println("Equations: ", length(model.equations))

# Access specific variables
N = model.variables["N"]
println("Variable type: ", N.type)          # UnknownVariable

# Display an equation
println(to_unicode(model.equations[1]))     # ∂N/∂t = (−λ)·N
```

### Validation

```julia
# Schema and structural validation in one pass
result = validate(esm_file)
if !result.is_valid
    println("Schema errors: ", result.schema_errors)
    println("Structural errors: ", result.structural_errors)
end

# Or validate a file on disk directly
result = validate_path("path/to/model.esm")
```

### Serialization

```julia
# Convert to a JSON string
json_string = to_json(esm_file)

# Write to a file
write_path(esm_file, "output.esm")
```

### Simulation

```julia
using OrdinaryDiffEqTsit5

prob = esm_problem(esm_file, (0.0, 10.0))
sol = solve(prob, Tsit5())
sol[Symbol("Decay.N")]                      # the state's trajectory, by name
```

## Next Steps

- See [Simulation Runners](simulation-runners.md) for building and solving models
- Read [`esm-spec.md`](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)
  for the authoritative format definition
- See [CONTRIBUTING.md](https://github.com/EarthSciML/EarthSciAST/blob/main/CONTRIBUTING.md)
  to contribute to the project