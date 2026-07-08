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

# Load from file
esm_file = load("path/to/model.esm")

# Load from JSON string
json_str = """{"version": "1.0", "models": {...}}"""
esm_file = EarthSciAST.parse(json_str)
```

### Working with Models

```julia
# Access models by name
atm_model = esm_file.models["atmosphere"]

# Inspect model structure
println("Variables: ", keys(atm_model.variables))
println("Equations: ", length(atm_model.equations))

# Access specific variables
temperature = atm_model.variables["temperature"]
println("Variable type: ", temperature.type)
```

### Validation

```julia
# Validate against JSON schema
result = validate_schema(esm_file)
if !result.valid
    println("Schema errors: ", result.errors)
end

# Structural validation
struct_result = validate_structural(esm_file)
if !struct_result.valid
    println("Structural errors: ", struct_result.errors)
end
```

### Serialization

```julia
# Save to file
save("output.esm", esm_file)

# Convert to JSON string
json_string = EarthSciAST.serialize(esm_file)
```

## Next Steps

- Check out the [API Reference](api/types.md) for detailed documentation
- See [Examples](examples/basic.md) for more complex usage scenarios
- Read the [Developer Guide](developer.md) to contribute to the project