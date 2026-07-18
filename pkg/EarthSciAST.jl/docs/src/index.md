```@meta
CurrentModule = EarthSciAST
```

# EarthSciAST.jl

Documentation for [EarthSciAST.jl](https://github.com/EarthSciML/EarthSciAST).

EarthSciAST.jl is a Julia library for working with the EarthSciML Serialization Format (ESM format),
a JSON-based serialization format for earth science model components, their composition, and runtime configuration.

## Features

- **Complete Type System**: Rich type hierarchy for earth science models
- **JSON Serialization**: Parse and serialize ESM format files
- **Expression Support**: Mathematical expressions with variables and operators
- **Model Composition**: Coupling multiple earth science model components
- **Schema Validation**: Built-in JSON schema validation
- **MTK Integration**: Convert to/from ModelingToolkit.jl systems
- **Catalyst Integration**: Support for reaction network models
- **Unit Validation**: Dimensional analysis and unit checking
- **Graph Analysis**: Dependency and coupling graph generation

## Installation

```julia
using Pkg
Pkg.add("EarthSciAST")
```

## Quick Start

```julia
using EarthSciAST

# Load an ESM format file
esm_file = load("model.esm")

# Access model components
model = esm_file.models["atmosphere"]
println("Model has $(length(model.variables)) variables")

# Convert to ModelingToolkit via package extension (1.9+)
using ModelingToolkit
sys = ModelingToolkit.System(model; name=:AtmosphereModel)
# Or, for models with spatial derivatives:
# pde = ModelingToolkit.PDESystem(model; name=:AtmosphereModel)

# Validate the model
result = validate(esm_file)
if result.is_valid
    println("Model is valid!")
else
    println("Validation errors: ", result.structural_errors)
end
```

## Simulation runners

EarthSciAST.jl ships two official ESS Julia simulation runners that
consume the canonical-form AST emitted by [`discretize`](@ref):

- **ModelingToolkit (MTK)** — the default. Production runtime via the
  `EarthSciASTMTKExt` package extension.
- **`tree_walk`** — alternate runtime ([`build_evaluator`](@ref)) for very
  large discretized PDE systems whose scalar count exceeds MTK's
  `structural_simplify` / tearing / codegen ceiling. Compile time is
  independent of system size.

See [Simulation Runners](@ref) for when to choose each, performance
characteristics, supported ops, and the public API.

## ModelingToolkit / Catalyst integration

ModelingToolkit and Catalyst are **weak dependencies**. They are loaded only
when the user `using`s them directly. The constructors for `ModelingToolkit.
System`, `ModelingToolkit.PDESystem`, and `Catalyst.ReactionSystem` on ESM
types are defined in package extensions (`EarthSciASTMTKExt`,
`EarthSciASTCatalystExt`) that activate automatically.

Without these packages loaded, the package is still fully usable:
[`flatten`](@ref) produces a pure-Julia [`FlattenedSystem`](@ref) snapshot,
and the MTK-free tree-walk runtime ([`build_evaluator`](@ref),
[`simulate`](@ref)) runs models end to end. Only the symbolic
`ModelingToolkit`/`Catalyst` constructors require the weak dependencies —
calling one without its package loaded throws an `ArgumentError` naming
what to load.

```@index
```

```@autodocs
Modules = [EarthSciAST]
```