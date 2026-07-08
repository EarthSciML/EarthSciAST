# Getting Started with ESM Format in Julia

Julia provides the most complete ESM format implementation with full ModelingToolkit integration, enabling you to simulate models directly from ESM files.

## Installation

### From Package Registry
```julia
using Pkg
Pkg.add("EarthSciAST")
```

### Development Installation
```julia
using Pkg
Pkg.add(url="https://github.com/EarthSciML/EarthSciAST", subdir="pkg/EarthSciAST.jl")
```

## Core Capabilities

The Julia implementation provides **Full** tier capabilities:
- ✅ Parse, serialize, validate ESM files
- ✅ Pretty-print mathematical expressions
- ✅ Unit checking and dimensional analysis
- ✅ Direct ModelingToolkit conversion
- ✅ Catalyst integration for reaction networks
- ✅ Numerical simulation and solving

## Basic Usage

### Loading and Validating ESM Files

```julia
using EarthSciAST

# Load from file
esm_file = load_esm("model.esm")
println("Loaded: ", esm_file.metadata.name)

# Load from string
json_str = """{"esm": "0.1.0", "metadata": {...}}"""
esm_file = parse_esm(json_str)

# Validate structure and semantics
result = validate(esm_file)
if result.is_valid
    println("✓ Valid ESM file")
else
    for error in result.errors
        println("✗ ", error.message)
    end
end
```

### Working with Expressions

```julia
using EarthSciAST

# Parse mathematical expression
expr = parse_expression("""{"op": "+", "args": ["x", {"op": "^", "args": ["y", "2"]}]}""")

# Pretty-print in different formats
println("Unicode: ", to_unicode(expr))      # x + y²
println("LaTeX:   ", to_latex(expr))        # x + y^{2}
println("ASCII:   ", to_ascii(expr))        # x + y^2

# Analyze expression
vars = free_variables(expr)                  # ["x", "y"]
println("Variables: ", vars)

# Substitute values
substituted = substitute(expr, Dict("x" => "2", "y" => "t"))
println("After substitution: ", to_unicode(substituted))  # 2 + t²
```

## ModelingToolkit Integration

The Julia implementation excels at converting ESM models to ModelingToolkit systems for numerical simulation:

```julia
using EarthSciAST, ModelingToolkit, DifferentialEquations

# Load atmospheric chemistry model
esm_file = load_esm("atmospheric_model.esm")

# Convert to ModelingToolkit ODESystem
mtk_system = to_mtk(esm_file)
println("System: ", mtk_system)

# Set up and solve the ODE problem
prob = ODEProblem(mtk_system, [], (0.0, 86400.0))  # 24 hours
sol = solve(prob, Tsit5())

# Plot results
using Plots
plot(sol, vars=[1, 2, 3], xlabel="Time (s)", ylabel="Concentration")
```

### Advanced ModelingToolkit Features

```julia
# Get system information
println("States: ", states(mtk_system))
println("Parameters: ", parameters(mtk_system))
println("Equations: ", equations(mtk_system))

# Simplify system
simplified = structural_simplify(mtk_system)

# Generate optimized functions
f = ODEFunction(simplified, jac=true, sparse=true)
```

## Catalyst Integration for Reaction Networks

For models with chemical reactions, ESM Format integrates with Catalyst.jl:

```julia
using EarthSciAST, Catalyst

# Load reaction system model
esm_file = load_esm("reaction_network.esm")

# Convert to Catalyst ReactionSystem
catalyst_system = to_catalyst(esm_file)

# Work with the reaction network
reactions = reactioncomplexes(catalyst_system)
println("Reaction complexes: ", length(reactions))

# Convert to jump process for stochastic simulation
jump_prob = JumpProblem(catalyst_system, DiscreteProblem(catalyst_system, [], (0.0, 100.0)))
jump_sol = solve(jump_prob, SSAStepper())
```

## Model Building and Manipulation

### Creating Models Programmatically

```julia
using EarthSciAST

# Create a new ESM file
esm_file = ESMFile(
    esm = "0.1.0",
    metadata = Metadata(
        name = "Atmospheric Chemistry",
        description = "Simple ozone photolysis",
        author = "Julia User",
        created = "2026-02-15"
    )
)

# Add a model
model = Model(
    name = "atmosphere",
    variables = [
        ModelVariable(
            name = "O3",
            type = "state",
            units = "molec/cm^3",
            description = "Ozone concentration"
        )
    ],
    equations = [
        ModelEquation(
            lhs = "O3",
            rhs = parse_expression("""{"op": "*", "args": ["-k", "O3"]}"""),
            description = "First-order decay"
        )
    ]
)

# Add model to ESM file
esm_file.models["atmosphere"] = model

# Save to file
save_esm(esm_file, "new_model.esm")
```

### Model Composition and Coupling

```julia
# Load multiple models
atm_model = load_esm("atmosphere.esm")
ocean_model = load_esm("ocean.esm")

# Create coupled system
coupled_esm = ESMFile(
    esm = "0.1.0",
    metadata = Metadata(name = "Coupled System"),
    models = merge(atm_model.models, ocean_model.models),
    coupling = [
        CouplingEntry(
            source_model = "atmosphere",
            source_variable = "CO2_flux",
            target_model = "ocean",
            target_variable = "atmospheric_CO2",
            coupling_function = parse_expression("""{"op": "*", "args": ["flux", "area"]}""")
        )
    ]
)
```

## Unit Analysis and Validation

```julia
using EarthSciAST

# Load model with units
esm_file = load_esm("model_with_units.esm")

# Check dimensional consistency
unit_result = validate_units(esm_file)
if !unit_result.is_valid
    for error in unit_result.errors
        println("Unit error: ", error.message)
        println("  Expected: ", error.expected_units)
        println("  Found: ", error.actual_units)
    end
end

# Get units for expressions
expr = parse_expression("""{"op": "*", "args": ["k", "A", "B"]}""")
units = infer_units(expr, esm_file)
println("Expression units: ", units)
```

## Performance Optimization

### Efficient Loading
```julia
# Use streaming for large files
esm_file = load_esm("large_model.esm", streaming=true)

# Parallel validation
result = validate(esm_file, parallel=true)

# Memory-mapped loading for very large files
esm_file = load_esm_mmap("huge_model.esm")
```

### Compiled System Generation
```julia
# Pre-compile ModelingToolkit system for faster repeated solving
mtk_system = to_mtk(esm_file)
compiled_system = compile(mtk_system)

# Use compiled system in tight loops
for parameter_set in parameter_sets
    prob = remake(prob, p=parameter_set)
    sol = solve(prob, Tsit5(), compiled_system)
end
```

## Debugging and Introspection

```julia
# Inspect parsed structure
esm_file = load_esm("debug_model.esm")
@show typeof(esm_file)
@show fieldnames(typeof(esm_file))

# Debug expression parsing
expr_str = """{"op": "+", "args": ["x", "y"]}"""
expr = parse_expression(expr_str)
@show expr.op
@show expr.args

# Trace ModelingToolkit conversion
mtk_system = to_mtk(esm_file, verbose=true)
```

## Integration with Julia Ecosystem

### Plotting with Plots.jl
```julia
using Plots

# Solve and plot
sol = solve(prob, Tsit5())
plot(sol, xlabel="Time", ylabel="Concentration",
     title="Atmospheric Chemistry Model")
```

### Data Analysis with DataFrames.jl
```julia
using DataFrames

# Convert solution to DataFrame
df = DataFrame(sol)
println(first(df, 5))

# Statistical analysis
mean_concentrations = combine(df, valuecols(df) .=> mean)
```

### Parameter Estimation
```julia
using DiffEqFlux, Optimization

# Set up parameter estimation problem
function loss(params)
    prob_new = remake(prob, p=params)
    sol = solve(prob_new, Tsit5(), saveat=measurement_times)
    return sum(abs2, sol .- measurements)
end

# Optimize
optfunc = OptimizationFunction(loss)
optprob = OptimizationProblem(optfunc, initial_params)
result = solve(optprob, ADAM())
```

## Next Steps

- **Try the Examples** — Work through [Real-World Examples](../examples/)
- **Reference** — Browse the [Julia API Reference](../api/julia/)
- **Standard Library** — See the [Standard Library](../standard_library/) for shipped subsystems
- **Contribute** — Help improve the Julia implementation

## Common Patterns

### Error Handling
```julia
try
    esm_file = load_esm("model.esm")
    mtk_system = to_mtk(esm_file)
catch e
    if isa(e, ESMParseError)
        println("Parse error: ", e.message)
    elseif isa(e, ValidationError)
        println("Validation error: ", e.message)
    else
        rethrow(e)
    end
end
```

### Custom Model Components
```julia
# Define custom operators
register_operator("custom_kinetics", (k, A, B) -> k * A * B / (1 + A))

# Use in ESM expressions
expr = parse_expression("""
{
  "op": "custom_kinetics",
  "args": ["k1", "CO", "OH"]
}
""")
```

Ready to simulate? Check out our [Tutorial Series](../tutorial/) for step-by-step model building!