# Getting Started with ESM Format in Julia

The Julia implementation is the reference implementation. It provides the
complete format surface plus ModelingToolkit and Catalyst integration and a
tree-walk simulation engine that runs discretized PDEs at scale.

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

- ✅ Parse, serialize, validate ESM files
- ✅ Mathematical expression manipulation and rendering
- ✅ Unit checking and dimensional analysis
- ✅ ModelingToolkit `System` / `PDESystem` construction, and the reverse
- ✅ Catalyst `ReactionSystem` construction, and the reverse
- ✅ Simulation of ODE and post-discretize PDE systems
- ✅ Component and expression graph analysis

## Basic Usage

### Loading and Validating ESM Files

```julia
using EarthSciAST

# From a file
esm_file = load_path("model.esm")

# From a JSON string, or an already-parsed dictionary
esm_file = load_string(json_string)
esm_file = load_document(dict)

# Inspect the document
println("Models: ", collect(keys(esm_file.models)))
model = esm_file.models["ExponentialDecay"]
println("Variables: ", collect(keys(model.variables)))
println("Equations: ", length(model.equations))

# Validate — `ValidationResult` has is_valid, schema_errors,
# structural_errors, unit_warnings
result = validate(esm_file)
if result.is_valid
    println("Valid")
else
    foreach(println, vcat(result.schema_errors, result.structural_errors))
end

# Unit findings are warnings, never errors
foreach(w -> println("units: ", w.message), result.unit_warnings)

# Write back out
write_path(esm_file, "output.esm")
println(to_json(esm_file))
```

`load_path` also takes `metaparameters=` to close a metaparameterized document
and `base_path=` to resolve `$ref` targets from another directory.

### Working with Expressions

```julia
using EarthSciAST

expr = parse_expression("k * A * B")     # -> OpExpr

println(to_unicode(expr))                # k·A·B
println(to_latex(expr))                  # k \cdot A \cdot B
println(to_ascii(expr))
println(sort(collect(free_variables(expr))))   # ["A", "B", "k"]

println(to_unicode(simplify(parse_expression("x + 0"))))   # x

# Substitution takes name => expression
bound = substitute(expr, Dict("k" => parse_expression("2")))
println(to_unicode(bound))
```

`parse_equation` parses a full equation, and `canonical_json` gives the
canonical serialization two documents are compared by.

## ModelingToolkit Integration

Conversion is by **constructor**, in both directions.

```julia
using EarthSciAST, ModelingToolkit

esm_file = load_path("model.esm")
model = esm_file.models["ExponentialDecay"]

# ESM -> MTK. The Model method flattens first, then builds the system.
sys = ModelingToolkit.System(model; name = :decay)

# Or flatten yourself when you want the intermediate
flat = flatten(esm_file)
sys = ModelingToolkit.System(flat; name = :decay)

simplified = structural_simplify(sys)
```

A flattened system that still carries spatial independent variables is
rejected with a redirect to `PDESystem`:

```julia
pde = ModelingToolkit.PDESystem(flat; name = :transport)
```

### Back to ESM

```julia
using EarthSciAST, ModelingToolkit

model = EarthSciAST.Model(sys)      # MTK system -> ESM Model
```

`mtk2esm` and `mtk2esm_gaps` wrap the same conversion and additionally report
constructs that have no ESM representation, which is the safer entry point when
you are converting a system you did not author.

## Catalyst Integration for Reaction Networks

```julia
using EarthSciAST, Catalyst

esm_file = load_path("chemistry.esm")
rsys = esm_file.reaction_systems["SimpleOzone"]

# ESM -> Catalyst
crn = Catalyst.ReactionSystem(rsys; name = :ozone)

# Catalyst -> ESM
back = EarthSciAST.ReactionSystem(crn)
```

Reaction systems also lower to plain ODEs without Catalyst:

```julia
model = derive_odes(rsys)                    # ReactionSystem -> Model
S = stoichiometric_matrix(rsys)              # species × reactions
```

## Simulation

`esm_problem` builds, and SciML's `solve` runs it. The algorithm comes from the
caller, so you load whichever solver package you want.

```julia
using EarthSciAST, SciMLBase, OrdinaryDiffEqTsit5

prob = esm_problem("simple_ode.esm", (0.0, 10.0))
sol  = solve(prob, Tsit5(); saveat = [0.0, 5.0, 10.0])

println(sol.retcode)      # Success
println(sol.t)            # [0.0, 5.0, 10.0]
println(sol.u[end])       # [36.78794769550938]
println(prob.var_map)     # Dict("ExponentialDecay.N" => 1)
```

`prob.var_map` maps a fully-qualified variable name to its index in the state
vector, which is how you pick a series out of `sol.u`.

For a parameter sweep, rebuild the problem per sample:

```julia
using EarthSciAST, SciMLBase, OrdinaryDiffEqTsit5

for λ in range(0.01, 0.10; length = 10)
    prob = esm_problem("model.esm", (0.0, 3600.0); parameter_overrides = Dict("lambda" => λ))
    sol  = solve(prob, Tsit5())
    println(λ, " -> ", sol.u[end])
end
```

## Model Building and Manipulation

### Creating Models Programmatically

`ModelVariable` takes its type positionally; everything else is a keyword.
`Model(variables, equations)` is the short constructor — the model's *name* is
the key it is stored under in `EsmFile.models`, not a field on the model.

```julia
using EarthSciAST

variables = Dict(
    "N" => ModelVariable(UnknownVariable; units = "mol", description = "amount"),
    "k" => ModelVariable(ParameterVariable; units = "1/s", default = 0.05),
)

equations = [
    Equation(
        OpExpr("D", [VarExpr("N")]; wrt = "t"),
        OpExpr("-", [OpExpr("*", [VarExpr("k"), VarExpr("N")])]),
    ),
]

model = Model(variables, equations)
```

The editing helpers return a new model rather than mutating:

```julia
model = add_variable(model, "T", ModelVariable(ParameterVariable; units = "K"))
model = add_equation(model, eq)
model = rename_variable(model, "N", "amount")
model = remove_variable(model, "T")
```

### Model Composition and Coupling

```julia
using EarthSciAST

esm_file = load_path("coupled.esm")

graph = component_graph(esm_file)     # Graph{ComponentNode, CouplingEdge}
println(to_mermaid(graph))
println(to_dot(graph))

flat = flatten(esm_file)              # one system, references resolved
println(flat.independent_variables)   # [:t]
```

`expression_graph` gives the finer-grained dependency graph between
expressions, and `build_reference_graph` the `$ref` resolution graph.

## Unit Analysis and Validation

```julia
using EarthSciAST

esm_file = load_path("model.esm")

validate_file_dimensions(esm_file)         # whole-file dimensional analysis
model_unit_findings(model)                # per-model findings
equation_unit_findings(model, eq)         # per-equation findings

# Infer units for one variable the author did not declare, from the equations
# it appears in plus the units already known
infer_variable_units("N", model.equations, Dict("k" => "1/s"))

# Parse a unit string into its dimensional form
parse_units("kg/m^3")        # kg m^-3

# Apply a data source's declared `unit_conversion` (a number or an expression
# on the loader variable) to a loaded array
conv = parse_unit_conversion(1000.0; variable_name = "rho")
apply_unit_conversion([1.0, 2.0], conv; variable_name = "rho")
```

Unit problems are reported as findings and warnings; they do not make a
document invalid.

## Performance

### Loading

`load_path` parses, resolves references, and applies the template-rewrite
fixpoint. Hold the resulting `EsmFile` rather than re-reading per operation.

```julia
esm_file = load_path("model.esm")     # once
for _ in 1:100
    validate(esm_file)                # reuse
end
```

### Compiled evaluation

`build_evaluator` compiles a flattened system into a right-hand-side function,
bypassing ModelingToolkit entirely, so build time does not grow with the system
size. This is the path `esm_problem` takes internally and the one to reach for
on discretized PDEs whose scalar count exceeds MTK's codegen ceiling.

```julia
using EarthSciAST

f!, u0, p, tspan, var_map = build_evaluator(model)
```

The returned `f!` is zero-allocation at `Float64` and eltype-generic, so
ForwardDiff differentiates through it over the state or the parameters.
`build_evaluator(model; form = :oop)` returns an out-of-place `f(u, p, t)`
instead — that form exists to be *traced* by XLA/Reactant, not to be faster.

## Debugging and Introspection

```julia
using EarthSciAST

esm_file = load_path("model.esm")
model = esm_file.models["ExponentialDecay"]

println(ode_states(model))              # variables carrying a time derivative
println(observed_definitions(model))    # name => defining expression
println(unknowns(model))
println(parameters(model))
println(system_kind(model))             # :ode, :dae, ...

# Evaluate an expression against explicit bindings
evaluate_expr(parse_expression("k * 2"), Dict("k" => 3.0))
```

Errors all subtype `EarthSciASTError` and carry a diagnostic code from
`ERROR_CODES`, so one `catch e; e isa EarthSciASTError` covers the surface:

```julia
try
    esm_file = load_path("broken.esm")
    validate(esm_file)
catch e
    if e isa EarthSciASTError
        println("ESM error: ", e)
    else
        rethrow()
    end
end
```

## Integration with the Julia Ecosystem

### Plotting

```julia
using EarthSciAST, SciMLBase, OrdinaryDiffEqTsit5, Plots

prob = esm_problem("model.esm", (0.0, 3600.0))
sol  = solve(prob, Tsit5())

idx = prob.var_map["ExponentialDecay.N"]
plot(sol.t, [u[idx] for u in sol.u], xlabel = "time (s)", label = "N")
```

### DataFrames

```julia
using EarthSciAST, SciMLBase, OrdinaryDiffEqTsit5, DataFrames

prob = esm_problem("model.esm", (0.0, 3600.0))
sol  = solve(prob, Tsit5())

df = DataFrame(t = sol.t)
for (name, idx) in prob.var_map
    df[!, name] = [u[idx] for u in sol.u]
end
```

## Next Steps

- Read the [format specification](https://github.com/EarthSciML/EarthSciAST/blob/main/esm-spec.md)
- Browse the [examples](../../examples/)
- See the [troubleshooting guide](../../troubleshooting/)
- The package's own docs are under
  [`pkg/EarthSciAST.jl/docs/`](https://github.com/EarthSciML/EarthSciAST/tree/main/pkg/EarthSciAST.jl/docs)
