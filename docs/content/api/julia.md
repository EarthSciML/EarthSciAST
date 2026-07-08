# Julia API Reference

Complete API reference for the ESM Format Julia library.

## ModelingToolkit / Catalyst Integration (v0.0.2+)

ModelingToolkit and Catalyst integration is provided via **package extensions**.
The public API is **constructor dispatch** on the foreign types:

```julia
using EarthSciAST, ModelingToolkit, Catalyst

# Flatten first (always) — then dispatch on FlattenedSystem
flat = flatten(esm_file)

# Pure-ODE path
sys = ModelingToolkit.System(flat; name=:Atmosphere)

# PDE path (when flat.independent_variables includes spatial dims)
pde = ModelingToolkit.PDESystem(flat; name=:Atmosphere)

# Reaction system → Catalyst
cat = Catalyst.ReactionSystem(esm_file.reaction_systems["Chem"]; name=:Chem)

# Reverse direction
model = EarthSciAST.Model(sys)
```

Calling `ModelingToolkit.System` on a PDE-shaped flattened system throws
`ArgumentError` pointing at `ModelingToolkit.PDESystem`, and vice versa.

Without `ModelingToolkit`/`Catalyst` loaded, the same pattern works via
`MockMTKSystem`, `MockPDESystem`, and `MockCatalystSystem` from the main
package — no availability check needed.

**Removed** (breaking change): `to_mtk_system`, `to_catalyst_system`,
`from_mtk_system`, `from_catalyst_system`, `check_mtk_availability`,
`check_catalyst_availability`. Use the constructor API above instead.

## Functions

### Base

**File:** `pkg/EarthSciAST.jl/src/display.jl:300`

```julia
function Base.show(io::IO, ::MIME"text/plain", expr::Expr)
```

Base.show(io::IO, ::MIME"text/plain", expr::Expr)

Unicode display: chemical subscripts via element-aware tokenizer, ∂x/∂t derivatives,
· for multiplication, − for unary minus, scientific notation with Unicode superscripts.

---

### Base

**File:** `pkg/EarthSciAST.jl/src/display.jl:309`

```julia
function Base.show(io::IO, ::MIME"text/latex", expr::Expr)
```

Base.show(io::IO, ::MIME"text/latex", expr::Expr)

LaTeX display: \\frac{}{}, \\partial, \\mathrm{} for species.

---

### Base

**File:** `pkg/EarthSciAST.jl/src/display.jl:574`

```julia
function Base.show(io::IO, equation::Equation)
```

Base.show(io::IO, equation::Equation)

Display equation in Unicode format.

---

### Base

**File:** `pkg/EarthSciAST.jl/src/display.jl:585`

```julia
function Base.show(io::IO, model::Model)
```

Base.show(io::IO, model::Model)

Model display: show(Model) prints equation list per spec Section 6.3.

---

### Base

**File:** `pkg/EarthSciAST.jl/src/display.jl:642`

```julia
function Base.show(io::IO, esm_file::EsmFile)
```

Base.show(io::IO, esm_file::EsmFile)

EsmFile display: show(EsmFile) prints structured summary per spec Section 6.3.

---

### Base

**File:** `pkg/EarthSciAST.jl/src/display.jl:696`

```julia
function Base.show(io::IO, reaction_system::ReactionSystem)
```

Base.show(io::IO, reaction_system::ReactionSystem)

ReactionSystem display: reactions in chemical notation.

---

### adapt_configuration_parameters

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:451`

```julia
function adapt_configuration_parameters(config::SolverConfiguration, metrics::PerformanceMetrics, learning_rate::Float64)::SolverConfiguration
```

adapt_configuration_parameters(config::SolverConfiguration, metrics::PerformanceMetrics, learning_rate::Float64) -> SolverConfiguration

Adapt configuration parameters based on performance metrics.

---

### adapt_for_problem_characteristics

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:398`

```julia
function adapt_for_problem_characteristics(config_dict::Dict{String,Any}, characteristics::ProblemCharacteristics)::SolverConfiguration
```

adapt_for_problem_characteristics(config_dict::Dict{String,Any}, characteristics::ProblemCharacteristics) -> SolverConfiguration

Adapt configuration based on problem characteristics.

---

### add_continuous_event

**File:** `pkg/EarthSciAST.jl/src/edit.jl:333`

```julia
function add_continuous_event(model::Model, event::ContinuousEvent)::Model
```

add_continuous_event(model::Model, event::ContinuousEvent) -> Model

Add a continuous event to a model.

---

### add_coupling

**File:** `pkg/EarthSciAST.jl/src/edit.jl:404`

```julia
function add_coupling(file::EsmFile, entry::CouplingEntry)::EsmFile
```

add_coupling(file::EsmFile, entry::CouplingEntry) -> EsmFile

Add a coupling entry to an ESM file.

---

### add_discrete_event

**File:** `pkg/EarthSciAST.jl/src/edit.jl:352`

```julia
function add_discrete_event(model::Model, event::DiscreteEvent)::Model
```

add_discrete_event(model::Model, event::DiscreteEvent) -> Model

Add a discrete event to a model.

---

### add_equation

**File:** `pkg/EarthSciAST.jl/src/edit.jl:131`

```julia
function add_equation(model::Model, equation::Equation)::Model
```

add_equation(model::Model, equation::Equation) -> Model

Add a new equation to a model.

Appends the equation to the end of the equations list.

---

### add_error!

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:167`

```julia
function add_error!(collector::ErrorCollector, error::ESMError)
```

add_error!(collector, error)

Add an error to the collection.

---

### add_reaction

**File:** `pkg/EarthSciAST.jl/src/edit.jl:217`

```julia
function add_reaction(system::ReactionSystem, reaction::Reaction)::ReactionSystem
```

add_reaction(system::ReactionSystem, reaction::Reaction) -> ReactionSystem

Add a new reaction to a reaction system.

---

### add_species

**File:** `pkg/EarthSciAST.jl/src/edit.jl:266`

```julia
function add_species(system::ReactionSystem, name::String, species::Species)::ReactionSystem
```

add_species(system::ReactionSystem, name::String, species::Species) -> ReactionSystem

Add a new species to a reaction system.

---

### add_variable

**File:** `pkg/EarthSciAST.jl/src/edit.jl:18`

```julia
function add_variable(model::Model, name::String, variable::ModelVariable)::Model
```

add_variable(model::Model, name::String, variable::ModelVariable) -> Model

Add a new variable to a model.

Creates a new model with the additional variable. Warns if variable already exists.

---

### adjacency

**File:** `pkg/EarthSciAST.jl/src/graph.jl:69`

```julia
function adjacency(graph::Graph{N, E}, node::N) where {N, E}
```

Get all adjacent nodes (both predecessors and successors).

---

### analyze_coupling_issues

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:571`

```julia
function analyze_coupling_issues(esm_file, error_collector)
```

analyze_coupling_issues(esm_file, error_collector)

Analyze coupling-related issues and provide debugging info.

---

### apply_advanced_mtk_features

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1091`

```julia
function apply_advanced_mtk_features(sys, metadata::Dict)
```

apply_advanced_mtk_features(sys, metadata::Dict) -> ODESystem

Apply advanced MTK features like algebraic reduction and optimization hints.

---

### apply_translations

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:304`

```julia
function apply_translations(vars::Vector{String}, translate)
```

apply_translations(vars::Vector{String}, translate)

Apply translation mappings to variable names.

---

### apply_variable_transform

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:435`

```julia
function apply_variable_transform(coupled_system, from_resolution, to_resolution, coupling)
```

apply_variable_transform(coupled_system, from_resolution, to_resolution, coupling)

Apply the specified transform operation between variables.

---

### auto_tune_solver

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:518`

```julia
function auto_tune_solver(base_solver::Solver, problem_characteristics::ProblemCharacteristics;
```

auto_tune_solver(base_solver::Solver, problem_characteristics::ProblemCharacteristics;
                    max_iterations=20) -> Solver

Automatically tune solver parameters based on problem characteristics.
Returns an optimized solver configuration.

---

### calculate_performance_score

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:188`

```julia
function calculate_performance_score(metrics::PerformanceMetrics)::Float64
```

calculate_performance_score(metrics::PerformanceMetrics) -> Float64

Calculate a composite performance score (higher is better).

---

### coerce_affect_equation

**File:** `pkg/EarthSciAST.jl/src/parse.jl:269`

```julia
function coerce_affect_equation(data::Any)::AffectEquation
```

coerce_affect_equation(data::Any) -> AffectEquation

Coerce JSON data into AffectEquation type.

---

### coerce_callback

**File:** `pkg/EarthSciAST.jl/src/parse.jl:482`

```julia
function coerce_callback(data::AbstractDict)::CouplingCallback
```

coerce_callback(data::AbstractDict) -> CouplingCallback

Parse callback coupling entry.

---

### coerce_couple

**File:** `pkg/EarthSciAST.jl/src/parse.jl:420`

```julia
function coerce_couple(data::AbstractDict)::CouplingCouple
```

coerce_couple(data::AbstractDict) -> CouplingCouple

Parse couple coupling entry.

---

### coerce_coupling_entry

**File:** `pkg/EarthSciAST.jl/src/parse.jl:374`

```julia
function coerce_coupling_entry(data::Any)::CouplingEntry
```

coerce_coupling_entry(data::Any) -> CouplingEntry

Coerce JSON data into concrete CouplingEntry subtype based on the 'type' field.

---

### coerce_data_loader

**File:** `pkg/EarthSciAST.jl/src/parse.jl:346`

```julia
function coerce_data_loader(data::Any)::DataLoader
```

coerce_data_loader(data::Any) -> DataLoader

Coerce JSON data into DataLoader type.

---

### coerce_domain

**File:** `pkg/EarthSciAST.jl/src/parse.jl:561`

```julia
function coerce_domain(data::Any)::Domain
```

coerce_domain(data::Any) -> Domain

Coerce JSON data into Domain type.

---

### coerce_equation

**File:** `pkg/EarthSciAST.jl/src/parse.jl:235`

```julia
function coerce_equation(data::Any)::Equation
```

coerce_equation(data::Any) -> Equation

Coerce JSON data into Equation type.

---

### coerce_esm_file

**File:** `pkg/EarthSciAST.jl/src/parse.jl:99`

```julia
function coerce_esm_file(data::Any)::EsmFile
```

coerce_esm_file(data::Any) -> EsmFile

Coerce raw JSON data into properly typed EsmFile with custom union type handling.

---

### coerce_event

**File:** `pkg/EarthSciAST.jl/src/parse.jl:246`

```julia
function coerce_event(data::Any)::EventType
```

coerce_event(data::Any) -> EventType

Coerce JSON data into EventType (ContinuousEvent or DiscreteEvent).

---

### coerce_event

**File:** `pkg/EarthSciAST.jl/src/parse.jl:502`

```julia
function coerce_event(data::AbstractDict)::CouplingEvent
```

coerce_event(data::AbstractDict) -> CouplingEvent

Parse event coupling entry.

---

### coerce_functional_affect

**File:** `pkg/EarthSciAST.jl/src/parse.jl:280`

```julia
function coerce_functional_affect(data::Any)::FunctionalAffect
```

coerce_functional_affect(data::Any) -> FunctionalAffect

Coerce JSON data into FunctionalAffect type.

---

### coerce_metadata

**File:** `pkg/EarthSciAST.jl/src/parse.jl:162`

```julia
function coerce_metadata(data::Any)::Metadata
```

coerce_metadata(data::Any) -> Metadata

Coerce JSON data into Metadata type.

---

### coerce_model

**File:** `pkg/EarthSciAST.jl/src/parse.jl:201`

```julia
function coerce_model(data::Any)::Model
```

coerce_model(data::Any) -> Model

Coerce JSON data into Model type.

---

### coerce_model_variable

**File:** `pkg/EarthSciAST.jl/src/parse.jl:218`

```julia
function coerce_model_variable(data::Any)::ModelVariable
```

coerce_model_variable(data::Any) -> ModelVariable

Coerce JSON data into ModelVariable type.

---

### coerce_operator

**File:** `pkg/EarthSciAST.jl/src/parse.jl:360`

```julia
function coerce_operator(data::Any)::Operator
```

coerce_operator(data::Any) -> Operator

Coerce JSON data into Operator type.

---

### coerce_operator_apply

**File:** `pkg/EarthSciAST.jl/src/parse.jl:466`

```julia
function coerce_operator_apply(data::AbstractDict)::CouplingOperatorApply
```

coerce_operator_apply(data::AbstractDict) -> CouplingOperatorApply

Parse operator_apply coupling entry.

---

### coerce_operator_compose

**File:** `pkg/EarthSciAST.jl/src/parse.jl:403`

```julia
function coerce_operator_compose(data::AbstractDict)::CouplingOperatorCompose
```

coerce_operator_compose(data::AbstractDict) -> CouplingOperatorCompose

Parse operator_compose coupling entry.

---

### coerce_parameter

**File:** `pkg/EarthSciAST.jl/src/parse.jl:332`

```julia
function coerce_parameter(data::Any)::Parameter
```

coerce_parameter(data::Any) -> Parameter

Coerce JSON data into Parameter type.

---

### coerce_reaction

**File:** `pkg/EarthSciAST.jl/src/parse.jl:318`

```julia
function coerce_reaction(data::Any)::Reaction
```

coerce_reaction(data::Any) -> Reaction

Coerce JSON data into Reaction type.

---

### coerce_reaction_system

**File:** `pkg/EarthSciAST.jl/src/parse.jl:292`

```julia
function coerce_reaction_system(data::Any)::ReactionSystem
```

coerce_reaction_system(data::Any) -> ReactionSystem

Coerce JSON data into ReactionSystem type.

---

### coerce_reference

**File:** `pkg/EarthSciAST.jl/src/parse.jl:187`

```julia
function coerce_reference(data::Any)::Reference
```

coerce_reference(data::Any) -> Reference

Coerce JSON data into Reference type.

---

### coerce_solver

**File:** `pkg/EarthSciAST.jl/src/parse.jl:574`

```julia
function coerce_solver(data::Any)::Solver
```

coerce_solver(data::Any) -> Solver

Coerce JSON data into Solver type.
Supports both old format (algorithm field) and new format (strategy/config fields).

---

### coerce_solver_configuration

**File:** `pkg/EarthSciAST.jl/src/parse.jl:635`

```julia
function coerce_solver_configuration(data)::SolverConfiguration
```

coerce_solver_configuration(data::Any) -> SolverConfiguration

Coerce JSON data into SolverConfiguration type.

---

### coerce_species

**File:** `pkg/EarthSciAST.jl/src/parse.jl:305`

```julia
function coerce_species(data::Any)::Species
```

coerce_species(data::Any) -> Species

Coerce JSON data into Species type.

---

### coerce_variable_map

**File:** `pkg/EarthSciAST.jl/src/parse.jl:441`

```julia
function coerce_variable_map(data::AbstractDict)::CouplingVariableMap
```

coerce_variable_map(data::AbstractDict) -> CouplingVariableMap

Parse variable_map coupling entry.

---

### component_graph

**File:** `pkg/EarthSciAST.jl/src/graph.jl:133`

```julia
function component_graph(file::EsmFile)::Graph{ComponentNode, CouplingEdge}
```

component_graph(file::EsmFile) -> Graph{ComponentNode, CouplingEdge}

Generate component-level graph showing systems and their couplings.

Creates nodes for each model, reaction system, data loader, and operator.
Creates edges based on coupling entries with appropriate types and labels.

# Arguments
- `file::EsmFile`: Input ESM file

# Returns
- `Graph{ComponentNode, CouplingEdge}`: Component graph with coupling relationships

# Example
```julia
graph = component_graph(file)
# Access nodes and edges
for node in graph.nodes
    println("Component: \$(node.name) (\$(node.type))")
end
for edge in graph.edges
    println("Coupling: \$(edge.from) --[\$(edge.label)]--> \$(edge.to)")
end
```

---

### compose

**File:** `pkg/EarthSciAST.jl/src/edit.jl:453`

```julia
function compose(file::EsmFile, system_a::String, system_b::String)::EsmFile
```

compose(file::EsmFile, system_a::String, system_b::String) -> EsmFile

Convenience function to create an operator_compose coupling entry.

---

### contains

**File:** `pkg/EarthSciAST.jl/src/expression.jl:119`

```julia
function contains(expr::NumExpr, var::String)::Bool
```

contains(expr::Expr, var::String)::Bool

Check if an expression contains a specific variable name.
Returns true if the variable appears anywhere in the expression.

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
contains(sum_expr, "x")  # true
contains(sum_expr, "z")  # false
```

---

### convert_operator_enhanced

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:909`

```julia
function convert_operator_enhanced(op::String, args::Vector, wrt::Union{String,Nothing}, advanced_features::Bool)
```

convert_operator_enhanced(op::String, args::Vector, wrt::Union{String,Nothing}, advanced_features::Bool) -> Any

Enhanced operator conversion supporting more functions and advanced features.

---

### couple

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:341`

```julia
function couple(coupled_system::MockCoupledSystem, coupling::CouplingCouple)
```

couple(coupled_system::MockCoupledSystem, coupling::CouplingCouple)

Implement bi-directional coupling via explicit ConnectorSystem equations:
1. Read connector equations from the coupling specification
2. Resolve scoped references in connector equations
3. Apply transform operations (additive/multiplicative/replacement)

---

### create_auto_tuning_optimizer

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:494`

```julia
function create_auto_tuning_optimizer(; strategy="adaptive", max_evaluations=50)::SolverOptimizer
```

create_auto_tuning_optimizer(;strategy="adaptive", max_evaluations=50) -> SolverOptimizer

Create a solver optimizer with sensible defaults for auto-tuning.

---

### create_equation_imbalance_error

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:397`

```julia
function create_equation_imbalance_error(model_name::String, num_equations::Int, num_unknowns::Int,
```

create_equation_imbalance_error(model_name, num_equations, num_unknowns, state_variables)

Create equation-unknown imbalance error with detailed suggestions.

---

### create_json_parse_error

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:362`

```julia
function create_json_parse_error(message::String, file_path::String="", line_number::Union{Int, Nothing}=nothing)
```

create_json_parse_error(message, file_path="", line_number=nothing)

Create a JSON parse error with fix suggestions.

---

### create_mock_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:393`

```julia
function create_mock_catalyst_system(rsys::ReactionSystem, name::String, advanced_features::Bool)
```

create_mock_catalyst_system(rsys::ReactionSystem, name::String, advanced_features::Bool) -> MockCatalystSystem

Create a mock Catalyst system for testing when Catalyst is not available.

---

### create_mock_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:232`

```julia
function create_mock_catalyst_system(rs::ReactionSystem)
```

create_mock_catalyst_system(rs::ReactionSystem) -> MockCatalystSystem

Create a mock Catalyst system for testing when Catalyst.jl is not available.
Preserves all the structural information in a testable format.

---

### create_mock_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:201`

```julia
function create_mock_mtk_system(model::Model, name::String, advanced_features::Bool)
```

create_mock_mtk_system(model::Model, name::String, advanced_features::Bool) -> MockMTKSystem

Create a mock MTK system for testing when ModelingToolkit is not available.

---

### create_mock_mtk_system_basic

**File:** `pkg/EarthSciAST.jl/src/mtk.jl:93`

```julia
function create_mock_mtk_system_basic(model::Model, name::String)
```

create_mock_mtk_system_basic(model::Model, name::String) -> MockMTKSystem

Create a mock MTK system for testing when ModelingToolkit is not available.

---

### create_performance_warning

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:501`

```julia
function create_performance_warning(operation::String, duration::Float64, threshold::Float64=1.0)
```

create_performance_warning(operation, duration, threshold=1.0)

Create performance warning with optimization suggestions.

---

### create_real_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:269`

```julia
function create_real_catalyst_system(rsys::ReactionSystem, name::String, advanced_features::Bool)
```

create_real_catalyst_system(rsys::ReactionSystem, name::String, advanced_features::Bool) -> ReactionSystem

Create a real Catalyst ReactionSystem from an ESM reaction system.

---

### create_real_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:93`

```julia
function create_real_catalyst_system(rs::ReactionSystem)
```

create_real_catalyst_system(rs::ReactionSystem) -> ReactionSystem

Create a real Catalyst.jl ReactionSystem from an ESM ReactionSystem.
Handles the full conversion pipeline with proper symbolic mathematics.

---

### create_real_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:104`

```julia
function create_real_mtk_system(model::Model, name::String, advanced_features::Bool)
```

create_real_mtk_system(model::Model, name::String, advanced_features::Bool) -> ODESystem

Create a real ModelingToolkit ODESystem from an ESM model.

---

### create_solver_with_method

**File:** `pkg/EarthSciAST.jl/src/types.jl:620`

```julia
function create_solver_with_method(strategy_str::String, method_str::String; kwargs...)::Solver
```

create_solver_with_method(strategy_str::String, method_str::String; kwargs...) -> Solver

Convenience constructor to create a solver with recommended settings for a given
strategy and numerical method combination.

---

### create_undefined_reference_error

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:443`

```julia
function create_undefined_reference_error(reference::String, available_variables::Vector{String}=String[],
```

create_undefined_reference_error(reference, available_variables=String[], scope_path="")

Create undefined reference error with smart suggestions.

---

### dict_to_solver_config

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:353`

```julia
function dict_to_solver_config(config_dict::Dict{String,Any})::SolverConfiguration
```

dict_to_solver_config(config_dict::Dict{String,Any}) -> SolverConfiguration

Convert dictionary back to SolverConfiguration.

---

### end_timer!

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:311`

```julia
function end_timer!(profiler::PerformanceProfiler, operation::String)
```

end_timer!(profiler, operation)

End timing an operation and return duration.

---

### esm_to_symbolic

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:322`

```julia
function esm_to_symbolic(expr::Expr, var_dict::Dict)
```

esm_to_symbolic(expr::Expr, var_dict::Dict) -> Any

Convert ESM expression to symbolic form for Catalyst.jl.
Handles the expression mapping required for rate expressions.

---

### esm_to_symbolic_enhanced

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:877`

```julia
function esm_to_symbolic_enhanced(expr::Expr, var_dict::Dict, advanced_features::Bool)
```

esm_to_symbolic_enhanced(expr::Expr, var_dict::Dict, advanced_features::Bool) -> Any

Enhanced ESM to symbolic conversion with support for advanced features and better error handling.

---

### esm_to_symbolic_enhanced

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst_enhanced.jl:418`

```julia
function esm_to_symbolic_enhanced(expr::EarthSciAST.Expr, var_dict::Dict, advanced_features::Bool)
```

esm_to_symbolic_enhanced(expr::EarthSciAST.Expr, var_dict::Dict, advanced_features::Bool) -> Any

Enhanced ESM to symbolic conversion with support for advanced features.

---

### evaluate

**File:** `pkg/EarthSciAST.jl/src/expression.jl:183`

```julia
function evaluate(expr::NumExpr, bindings::Dict{String,Float64})::Float64
```

evaluate(expr::Expr, bindings::Dict{String,Float64})::Float64

Numerically evaluate an expression using provided variable bindings.
Throws UnboundVariableError if any variable is not found in bindings.

# Arguments
- `expr`: The expression to evaluate
- `bindings`: Dictionary mapping variable names to numeric values

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
bindings = Dict("x" => 2.0, "y" => 3.0)
result = evaluate(sum_expr, bindings)  # 5.0
```

# Supported Operations
- Arithmetic: "+", "-", "*", "/", "^"
- Mathematical functions: "sin", "cos", "tan", "exp", "log", "sqrt", "abs"
- Constants: "π", "e"

---

### expr_to_string

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:467`

```julia
function expr_to_string(expr::Expr)
```

expr_to_string(expr::Expr) -> String

Convert ESM expression to string representation for mock systems.

---

### expression_graph

**File:** `pkg/EarthSciAST.jl/src/graph.jl:330`

```julia
function expression_graph(file::EsmFile)::Graph{VariableNode, DependencyEdge}
```

expression_graph(file::EsmFile) -> Graph{VariableNode, DependencyEdge}
    expression_graph(model::Model) -> Graph{VariableNode, DependencyEdge}
    expression_graph(system::ReactionSystem) -> Graph{VariableNode, DependencyEdge}
    expression_graph(equation::Equation) -> Graph{VariableNode, DependencyEdge}
    expression_graph(reaction::Reaction) -> Graph{VariableNode, DependencyEdge}
    expression_graph(expr::Expr) -> Graph{VariableNode, DependencyEdge}

Generate expression-level dependency graph showing variable relationships.

Creates nodes for variables and edges for dependencies based on expressions.
Supports different scoping levels from individual expressions to full files.

# Arguments
- Input can be EsmFile, Model, ReactionSystem, Equation, Reaction, or Expr

# Returns
- `Graph{VariableNode, DependencyEdge}`: Variable dependency graph

# Examples
```julia
# File-level analysis
graph = expression_graph(file)

# Model-level analysis
graph = expression_graph(model)

# Single equation analysis
graph = expression_graph(equation)
```

---

### extract

**File:** `pkg/EarthSciAST.jl/src/edit.jl:515`

```julia
function extract(file::EsmFile, component_name::String)::EsmFile
```

extract(file::EsmFile, component_name::String) -> EsmFile

Extract a single component into a standalone ESM file.

Creates a new file containing only the specified component and any
coupling entries that reference it.

---

### extract_dependent_variables

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:278`

```julia
function extract_dependent_variables(system)
```

extract_dependent_variables(system)

Extract dependent variables (LHS of differential equations) from a system.

---

### extract_variable_name

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1206`

```julia
function extract_variable_name(symbolic_var)
```

extract_variable_name(symbolic_var) -> String

Extract variable name from a symbolic variable, handling various formats.

---

### find_subsystem

**File:** `pkg/EarthSciAST.jl/src/types.jl:851`

```julia
function find_subsystem(system::Model, name::String)::Union{Model,Nothing}
```

find_subsystem(system::Union{Model,ReactionSystem}, name::String) -> Union{Model,ReactionSystem,Nothing}

Find a subsystem by name within a Model or ReactionSystem.
Returns the subsystem or nothing if not found.

---

### find_top_level_system

**File:** `pkg/EarthSciAST.jl/src/types.jl:821`

```julia
function find_top_level_system(esm_file::EsmFile, name::String)
```

find_top_level_system(esm_file::EsmFile, name::String) -> (Union{Model,ReactionSystem,DataLoader,Operator,Nothing}, Symbol)

Find a top-level system by name in models, reaction_systems, data_loaders, or operators.
Returns the system and its type, or (nothing, :none) if not found.

---

### format_chemical_subscripts

**File:** `pkg/EarthSciAST.jl/src/display.jl:128`

```julia
function format_chemical_subscripts(variable::String, format::Symbol)
```

format_chemical_subscripts(variable::String, format::Symbol) -> String

Apply element-aware chemical subscript formatting to a variable name.
Uses greedy 2-char-before-1-char matching for element detection per spec Section 6.1.

# Arguments
- `variable::String`: Variable name to format
- `format::Symbol`: Output format (:unicode or :latex)

---

### format_expression_latex

**File:** `pkg/EarthSciAST.jl/src/display.jl:339`

```julia
function format_expression_latex(expr::Expr)
```

format_expression_latex(expr::Expr) -> String

Format an expression as LaTeX mathematical notation.

---

### format_expression_unicode

**File:** `pkg/EarthSciAST.jl/src/display.jl:318`

```julia
function format_expression_unicode(expr::Expr)
```

format_expression_unicode(expr::Expr) -> String

Format an expression as Unicode mathematical notation.

---

### format_node_label

**File:** `pkg/EarthSciAST.jl/src/graph.jl:736`

```julia
function format_node_label(name::String, node_type::String="")::String
```

format_node_label(name::String, node_type::String="") -> String

Format node label with chemical subscript rendering if applicable.
Detects chemical formulas and applies subscript formatting.

---

### format_number

**File:** `pkg/EarthSciAST.jl/src/display.jl:197`

```julia
function format_number(num::Real, format::Symbol)
```

format_number(num::Real, format::Symbol) -> String

Format a number in scientific notation with appropriate formatting.

---

### format_operator_expression

**File:** `pkg/EarthSciAST.jl/src/display.jl:360`

```julia
function format_operator_expression(node::OpExpr, format::Symbol)
```

format_operator_expression(node::OpExpr, format::Symbol) -> String

Format an OpExpr (operator with arguments).

---

### format_user_friendly

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:215`

```julia
function format_user_friendly(error::ESMError)
```

format_user_friendly(error)

Format error message for end users.

---

### free_variables

**File:** `pkg/EarthSciAST.jl/src/expression.jl:77`

```julia
function free_variables(expr::NumExpr)::Set{String}
```

free_variables(expr::Expr)::Set{String}

Extract all free (unbound) variable names from an expression.
Returns a set of variable names that appear in the expression.

# Examples
```julia
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
vars = free_variables(sum_expr)  # Set(["x", "y"])

nested = OpExpr("*", [OpExpr("+", [x, NumExpr(1.0)]), y])
vars = free_variables(nested)  # Set(["x", "y"])
```

---

### from_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:573`

```julia
function from_catalyst_system(rs, name::String)
```

from_catalyst_system(rs, name::String) -> ReactionSystem

Convert a Catalyst ReactionSystem or MockCatalystSystem back to ESM ReactionSystem format.
Extracts species, parameters, reactions, and events from Catalyst symbolic form.

This function implements reverse conversion: taking Catalyst systems and reconstructing
ESM ReactionSystems with proper species mapping, parameter extraction, and reaction
reconstruction. Maps Catalyst Reaction objects to ESM Reaction format with proper
stoichiometry and rate expressions.

---

### from_mock_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1163`

```julia
function from_mock_catalyst_system(sys::MockCatalystSystem, name::String)
```

from_mock_catalyst_system(sys::MockCatalystSystem, name::String) -> ReactionSystem

Convert a MockCatalystSystem back to ESM ReactionSystem format.
This handles the case when Catalyst is not available but we have mock systems.

---

### from_mock_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1112`

```julia
function from_mock_mtk_system(sys::MockMTKSystem, name::String)
```

from_mock_mtk_system(sys::MockMTKSystem, name::String) -> Model

Convert a MockMTKSystem back to ESM Model format.
This handles the case when MTK is not available but we have mock systems.

---

### from_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:422`

```julia
function from_mtk_system(sys, name::String)
```

from_mtk_system(sys, name::String) -> Model

Convert a ModelingToolkit ODESystem or MockMTKSystem back to ESM Model format.
Extracts variables, equations, and events from MTK symbolic form.

This function implements reverse conversion: taking MTK systems and reconstructing
ESM Models with proper variable classification, equation extraction, and event handling.
Maps Differential(t)(var) → D(var,t), symbolic operations → OpExpr, and detects
state vs parameter vs observed variable types.

---

### get_best_configuration

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:224`

```julia
function get_best_configuration(optimizer::SolverOptimizer)
```

get_best_configuration(optimizer::SolverOptimizer) -> Union{SolverConfiguration, Nothing}

Get the current best solver configuration.

---

### get_expression_dimensions

**File:** `pkg/EarthSciAST.jl/src/units.jl:45`

```julia
function get_expression_dimensions(expr::EarthSciAST.Expr, var_units::Dict{String, String})::Union{Unitful.Units, Nothing}
```

Get the dimensions of an expression by propagating units through operations.

This performs dimensional analysis to determine the units that result from
evaluating an expression, assuming all variables have known units.

---

### get_operator_precedence

**File:** `pkg/EarthSciAST.jl/src/display.jl:242`

```julia
function get_operator_precedence(op::String)
```

get_operator_precedence(op::String) -> Int

Get operator precedence for proper parenthesization.

---

### get_performance_report

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:332`

```julia
function get_performance_report(profiler::PerformanceProfiler)
```

get_performance_report(profiler)

Get performance report.

---

### get_recommended_algorithms

**File:** `pkg/EarthSciAST.jl/src/types.jl:587`

```julia
function get_recommended_algorithms(strategy::SolverStrategy, method::NumericalMethod)::Dict{String,String}
```

get_recommended_algorithms(strategy::SolverStrategy, method::NumericalMethod) -> Dict{String,String}

Get recommended algorithm combinations for a given strategy and numerical method.

---

### get_summary

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:194`

```julia
function get_summary(collector::ErrorCollector)
```

get_summary(collector)

Get a summary of all collected errors and warnings.

---

### has_element_pattern

**File:** `pkg/EarthSciAST.jl/src/display.jl:71`

```julia
function has_element_pattern(variable::String)
```

has_element_pattern(variable::String) -> Bool

Check if a variable has element patterns (for chemical formula detection).
Uses greedy matching algorithm per spec Section 6.1.

---

### infer_variable_units

**File:** `pkg/EarthSciAST.jl/src/units.jl:309`

```julia
function infer_variable_units(var_name::String, equations::Vector{Equation}, known_units::Dict{String, String})::Union{String, Nothing}
```

Infer appropriate units for a variable based on its usage in equations.

This can help suggest units when they are not explicitly specified.

---

### is_better_performance

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:165`

```julia
function is_better_performance(new_metrics::PerformanceMetrics, current_best::PerformanceMetrics)::Bool
```

is_better_performance(new_metrics::PerformanceMetrics, current_best::PerformanceMetrics) -> Bool

Determine if new performance metrics are better than current best.
Priority: success > stability > speed > memory efficiency

---

### is_valid_identifier

**File:** `pkg/EarthSciAST.jl/src/types.jl:932`

```julia
function is_valid_identifier(name::String)::Bool
```

is_valid_identifier(name::String) -> Bool

Check if a string is a valid identifier (letters, numbers, underscores, no leading digit).

---

### load

**File:** `pkg/EarthSciAST.jl/src/parse.jl:697`

```julia
function load(path::String)::EsmFile
```

load(path::String) -> EsmFile

Load and parse an ESM file from a file path.

---

### load

**File:** `pkg/EarthSciAST.jl/src/parse.jl:708`

```julia
function load(io::IO)::EsmFile
```

load(io::IO) -> EsmFile

Load and parse an ESM file from an IO stream.

---

### map_variable

**File:** `pkg/EarthSciAST.jl/src/edit.jl:463`

```julia
function map_variable(file::EsmFile, from::String, to::String, transform::Union{EarthSciAST.Expr,Nothing}=nothing)::EsmFile
```

map_variable(file::EsmFile, from::String, to::String, transform::Union{Expr,Nothing}=nothing) -> EsmFile

Convenience function to create a variable_map coupling entry.

---

### merge

**File:** `pkg/EarthSciAST.jl/src/edit.jl:478`

```julia
function merge(file_a::EsmFile, file_b::EsmFile)::EsmFile
```

merge(file_a::EsmFile, file_b::EsmFile) -> EsmFile

Merge two ESM files.

Combines all components from both files. In case of conflicts, components
from file_b take precedence.

---

### needs_parentheses

**File:** `pkg/EarthSciAST.jl/src/display.jl:261`

```julia
function needs_parentheses(parent_op::String, child::Expr, is_right_operand::Bool=false)
```

needs_parentheses(parent_op::String, child::Expr, is_right_operand::Bool=false) -> Bool

Check if parentheses are needed around a subexpression.

---

### numerical_method_to_string

**File:** `pkg/EarthSciAST.jl/src/types.jl:518`

```julia
function numerical_method_to_string(method::NumericalMethod)::String
```

numerical_method_to_string(method::NumericalMethod) -> String

Convert numerical method enum to string representation.

---

### operator_apply

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:472`

```julia
function operator_apply(coupled_system::MockCoupledSystem, coupling::CouplingOperatorApply, file::EsmFile)
```

operator_apply(coupled_system::MockCoupledSystem, coupling::CouplingOperatorApply, file::EsmFile)

Register an Operator in CoupledSystem.ops for runtime execution.

---

### operator_compose

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:225`

```julia
function operator_compose(coupled_system::MockCoupledSystem, coupling::CouplingOperatorCompose)
```

operator_compose(coupled_system::MockCoupledSystem, coupling::CouplingOperatorCompose)

Implement the operator_compose algorithm from specification Section 4.7.1:
1. Extract dependent variables from both systems
2. Apply translation mappings if specified
3. Match equations (direct, translation, _var placeholder expansion)
4. Combine matched RHS terms by addition
5. Preserve unmatched equations

---

### parse_expression

**File:** `pkg/EarthSciAST.jl/src/parse.jl:31`

```julia
function parse_expression(data::Any)::Expr
```

parse_expression(data::Any) -> Expr

Parse JSON data into an Expression (NumExpr, VarExpr, or OpExpr).
Handles the oneOf discriminated union based on JSON structure.

---

### parse_mock_expression

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1230`

```julia
function parse_mock_expression(expr_str::String)
```

parse_mock_expression(expr_str::String) -> Expr

Parse a string representation of an expression into an ESM Expr.
This is a simple parser for mock system string representations.

---

### parse_mock_reaction

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1282`

```julia
function parse_mock_reaction(rxn_str::String)
```

parse_mock_reaction(rxn_str::String) -> Union{Reaction, Nothing}

Parse a string representation of a reaction into an ESM Reaction.
Expected format: "A + 2B -> C + D, rate: k1" or "A -> B"

---

### parse_model_variable_type

**File:** `pkg/EarthSciAST.jl/src/parse.jl:62`

```julia
function parse_model_variable_type(data::String)::ModelVariableType
```

parse_model_variable_type(data::String) -> ModelVariableType

Parse string into ModelVariableType enum.

---

### parse_numerical_method

**File:** `pkg/EarthSciAST.jl/src/types.jl:496`

```julia
function parse_numerical_method(method_str::String)::NumericalMethod
```

parse_numerical_method(method_str::String) -> NumericalMethod

Parse numerical method string to enum value.

---

### parse_solver_strategy

**File:** `pkg/EarthSciAST.jl/src/types.jl:462`

```julia
function parse_solver_strategy(strategy_str::String)::SolverStrategy
```

parse_solver_strategy(strategy_str::String) -> SolverStrategy

Parse solver strategy string to enum value.

---

### parse_species_list

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1347`

```julia
function parse_species_list(species_str::String)
```

parse_species_list(species_str::String) -> Dict{String, Int}

Parse a species list like "A + 2B + C" into a dictionary of species and stoichiometry.
Handles special case "∅" for empty (null) reactants/products.

---

### parse_trigger

**File:** `pkg/EarthSciAST.jl/src/parse.jl:79`

```julia
function parse_trigger(data::Dict)::DiscreteEventTrigger
```

parse_trigger(data::Dict) -> DiscreteEventTrigger

Parse JSON data into a DiscreteEventTrigger based on discriminator fields.

---

### parse_units

**File:** `pkg/EarthSciAST.jl/src/units.jl:15`

```julia
function parse_units(unit_str::String)::Union{Unitful.Units, Nothing}
```

Parse a unit string into a Unitful.Units object.

Handles common scientific units and compositions used in Earth system models.

---

### predecessors

**File:** `pkg/EarthSciAST.jl/src/graph.jl:84`

```julia
function predecessors(graph::Graph{N, E}, node::N) where {N, E}
```

Get nodes that point to this node.

---

### process_connector_equation

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:375`

```julia
function process_connector_equation(coupled_system, equation, systems)
```

process_connector_equation(coupled_system, equation, systems)

Process a single connector equation, resolving scoped references and applying transforms.

---

### process_event_affects

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:1047`

```julia
function process_event_affects(affects, symbolic_vars::Dict, advanced_features::Bool)
```

process_event_affects(affects, symbolic_vars::Dict, advanced_features::Bool)

Process event affects for MTK callbacks.

---

### process_events_enhanced

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:992`

```julia
function process_events_enhanced(events::Vector{EventType}, symbolic_vars::Dict, advanced_features::Bool)
```

process_events_enhanced(events::Vector{EventType}, symbolic_vars::Dict, advanced_features::Bool)

Enhanced event processing with comprehensive MTK callback support.

---

### process_reaction_events

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:388`

```julia
function process_reaction_events(events::Vector, var_dict::Dict)
```

process_reaction_events(events::Vector, var_dict::Dict) -> (Vector, Vector)

Process ESM events for inclusion in Catalyst ReactionSystem.
Returns (continuous_events, discrete_events).

---

### record_performance!

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:145`

```julia
function record_performance!(optimizer::SolverOptimizer, config::SolverConfiguration, metrics::PerformanceMetrics)
```

record_performance!(optimizer::SolverOptimizer, config::SolverConfiguration, metrics::PerformanceMetrics)

Record a performance measurement for a given configuration.

---

### remove_coupling

**File:** `pkg/EarthSciAST.jl/src/edit.jl:426`

```julia
function remove_coupling(file::EsmFile, index::Int)::EsmFile
```

remove_coupling(file::EsmFile, index::Int) -> EsmFile

Remove a coupling entry by index.

---

### remove_equation

**File:** `pkg/EarthSciAST.jl/src/edit.jl:153`

```julia
function remove_equation(model::Model, index::Int)::Model
```

remove_equation(model::Model, index::Int) -> Model
    remove_equation(model::Model, lhs_pattern::Expr) -> Model

Remove an equation from a model.

Can remove by index (1-based) or by matching the left-hand side expression.

---

### remove_event

**File:** `pkg/EarthSciAST.jl/src/edit.jl:373`

```julia
function remove_event(model::Model, name::String)::Model
```

remove_event(model::Model, name::String) -> Model

Remove an event by name from a model.

Searches both continuous and discrete events.

---

### remove_reaction

**File:** `pkg/EarthSciAST.jl/src/edit.jl:238`

```julia
function remove_reaction(system::ReactionSystem, id::String)::ReactionSystem
```

remove_reaction(system::ReactionSystem, id::String) -> ReactionSystem

Remove a reaction by its ID.

Note: This assumes reactions have an `id` field. If not available,
this function will search by reaction equality.

---

### remove_species

**File:** `pkg/EarthSciAST.jl/src/edit.jl:297`

```julia
function remove_species(system::ReactionSystem, name::String)::ReactionSystem
```

remove_species(system::ReactionSystem, name::String) -> ReactionSystem

Remove a species from a reaction system.

Warns about dependent reactions but does not automatically update them.

---

### remove_variable

**File:** `pkg/EarthSciAST.jl/src/edit.jl:45`

```julia
function remove_variable(model::Model, name::String)::Model
```

remove_variable(model::Model, name::String) -> Model

Remove a variable from a model.

Creates a new model without the specified variable. Warns about dependencies
but does not automatically update equations that reference the variable.

---

### rename_variable

**File:** `pkg/EarthSciAST.jl/src/edit.jl:86`

```julia
function rename_variable(model::Model, old_name::String, new_name::String)::Model
```

rename_variable(model::Model, old_name::String, new_name::String) -> Model

Rename a variable throughout the model.

Updates the variable definition and all references in equations.

---

### render_chemical_formula

**File:** `pkg/EarthSciAST.jl/src/graph.jl:703`

```julia
function render_chemical_formula(formula::String)::String
```

render_chemical_formula(formula::String) -> String

Convert chemical formula to format with subscripts for visualization.
Replaces numeric digits with Unicode subscript characters.

# Examples
```julia
render_chemical_formula("CO2") # "CO₂"
render_chemical_formula("H2SO4") # "H₂SO₄"
render_chemical_formula("CH3OH") # "CH₃OH"
```

---

### resolve_qualified_reference

**File:** `pkg/EarthSciAST.jl/src/types.jl:766`

```julia
function resolve_qualified_reference(esm_file::EsmFile, reference::String)::ReferenceResolution
```

resolve_qualified_reference(esm_file::EsmFile, reference::String) -> ReferenceResolution

Resolve a qualified reference string using hierarchical dot notation.

The reference string is split on dots to produce segments [s₁, s₂, …, sₙ].
The final segment sₙ is the variable name. The preceding segments [s₁, …, sₙ₋₁]
form a path through the subsystem hierarchy.

## Algorithm
1. Split reference on "." to get segments
2. First segment must match a top-level system (models, reaction_systems, data_loaders, operators)
3. Each subsequent segment must match a key in the parent system's subsystems map
4. Final segment is the variable name to resolve

## Examples
- `"SuperFast.O3"` → Variable `O3` in top-level model `SuperFast`
- `"SuperFast.GasPhase.O3"` → Variable `O3` in subsystem `GasPhase` of model `SuperFast`
- `"Atmosphere.Chemistry.FastChem.NO2"` → Variable `NO2` in nested subsystems

## Throws
- `QualifiedReferenceError` if reference cannot be resolved

---

### save

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:620`

```julia
function save(file::EsmFile, path::String)
```

save(file::EsmFile, path::String)

Save an EsmFile object to a JSON file at the specified path.

---

### save

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:631`

```julia
function save(file::EsmFile, io::IO)
```

save(file::EsmFile, io::IO)

Save an EsmFile object to a JSON stream.

---

### serialize_affect_equation

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:109`

```julia
function serialize_affect_equation(affect::AffectEquation)::Dict{String,Any}
```

serialize_affect_equation(affect::AffectEquation) -> Dict{String,Any}

Serialize AffectEquation to JSON-compatible format.

---

### serialize_callback

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:391`

```julia
function serialize_callback(entry::CouplingCallback)::Dict{String,Any}
```

serialize_callback(entry::CouplingCallback) -> Dict{String,Any}

Serialize callback coupling entry.

---

### serialize_couple

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:333`

```julia
function serialize_couple(entry::CouplingCouple)::Dict{String,Any}
```

serialize_couple(entry::CouplingCouple) -> Dict{String,Any}

Serialize couple coupling entry.

---

### serialize_coupling_entry

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:292`

```julia
function serialize_coupling_entry(entry::CouplingEntry)::Dict{String,Any}
```

serialize_coupling_entry(entry::CouplingEntry) -> Dict{String,Any}

Serialize CouplingEntry to JSON-compatible format based on concrete type.

---

### serialize_data_loader

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:254`

```julia
function serialize_data_loader(loader::DataLoader)::Dict{String,Any}
```

serialize_data_loader(loader::DataLoader) -> Dict{String,Any}

Serialize DataLoader to JSON-compatible format.

---

### serialize_domain

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:501`

```julia
function serialize_domain(domain::Domain)::Dict{String,Any}
```

serialize_domain(domain::Domain) -> Dict{String,Any}

Serialize Domain to JSON-compatible format.

---

### serialize_equation

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:158`

```julia
function serialize_equation(eq::Equation)::Dict{String,Any}
```

serialize_equation(eq::Equation) -> Dict{String,Any}

Serialize Equation to JSON-compatible format.

---

### serialize_esm_file

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:584`

```julia
function serialize_esm_file(file::EsmFile)::Dict{String,Any}
```

serialize_esm_file(file::EsmFile) -> Dict{String,Any}

Serialize EsmFile to JSON-compatible format.

---

### serialize_event

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:80`

```julia
function serialize_event(event::EventType)::Dict{String,Any}
```

serialize_event(event::EventType) -> Dict{String,Any}

Serialize EventType to JSON-compatible format.

---

### serialize_event

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:409`

```julia
function serialize_event(entry::CouplingEvent)::Dict{String,Any}
```

serialize_event(entry::CouplingEvent) -> Dict{String,Any}

Serialize event coupling entry.

---

### serialize_expression

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:15`

```julia
function serialize_expression(expr::Expr)
```

serialize_expression(expr::Expr) -> Any

Serialize an Expression to JSON-compatible format.
Handles the union type discrimination.

---

### serialize_functional_affect

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:121`

```julia
function serialize_functional_affect(affect::FunctionalAffect)::Dict{String,Any}
```

serialize_functional_affect(affect::FunctionalAffect) -> Dict{String,Any}

Serialize FunctionalAffect to JSON-compatible format.

---

### serialize_metadata

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:468`

```julia
function serialize_metadata(metadata::Metadata)::Dict{String,Any}
```

serialize_metadata(metadata::Metadata) -> Dict{String,Any}

Serialize Metadata to JSON-compatible format.

---

### serialize_model

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:170`

```julia
function serialize_model(model::Model)::Dict{String,Any}
```

serialize_model(model::Model) -> Dict{String,Any}

Serialize Model to JSON-compatible format.

---

### serialize_model_variable

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:137`

```julia
function serialize_model_variable(var::ModelVariable)::Dict{String,Any}
```

serialize_model_variable(var::ModelVariable) -> Dict{String,Any}

Serialize ModelVariable to JSON-compatible format.

---

### serialize_model_variable_type

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:42`

```julia
function serialize_model_variable_type(var_type::ModelVariableType)::String
```

serialize_model_variable_type(var_type::ModelVariableType) -> String

Serialize ModelVariableType enum to string.

---

### serialize_operator

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:273`

```julia
function serialize_operator(op::Operator)::Dict{String,Any}
```

serialize_operator(op::Operator) -> Dict{String,Any}

Serialize Operator to JSON-compatible format.

---

### serialize_operator_apply

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:376`

```julia
function serialize_operator_apply(entry::CouplingOperatorApply)::Dict{String,Any}
```

serialize_operator_apply(entry::CouplingOperatorApply) -> Dict{String,Any}

Serialize operator_apply coupling entry.

---

### serialize_operator_compose

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:315`

```julia
function serialize_operator_compose(entry::CouplingOperatorCompose)::Dict{String,Any}
```

serialize_operator_compose(entry::CouplingOperatorCompose) -> Dict{String,Any}

Serialize operator_compose coupling entry.

---

### serialize_parameter

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:202`

```julia
function serialize_parameter(param::Parameter)::Dict{String,Any}
```

serialize_parameter(param::Parameter) -> Dict{String,Any}

Serialize Parameter to JSON-compatible format.

---

### serialize_reaction

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:221`

```julia
function serialize_reaction(reaction::Reaction)::Dict{String,Any}
```

serialize_reaction(reaction::Reaction) -> Dict{String,Any}

Serialize Reaction to JSON-compatible format.

---

### serialize_reaction_system

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:238`

```julia
function serialize_reaction_system(rs::ReactionSystem)::Dict{String,Any}
```

serialize_reaction_system(rs::ReactionSystem) -> Dict{String,Any}

Serialize ReactionSystem to JSON-compatible format.

---

### serialize_reference

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:446`

```julia
function serialize_reference(ref::Reference)::Dict{String,Any}
```

serialize_reference(ref::Reference) -> Dict{String,Any}

Serialize Reference to JSON-compatible format.

---

### serialize_solver

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:517`

```julia
function serialize_solver(solver::Solver)::Dict{String,Any}
```

serialize_solver(solver::Solver) -> Dict{String,Any}

Serialize Solver to JSON-compatible format matching the ESM schema.

---

### serialize_solver_configuration

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:534`

```julia
function serialize_solver_configuration(config::SolverConfiguration)::Dict{String,Any}
```

serialize_solver_configuration(config::SolverConfiguration) -> Dict{String,Any}

Serialize SolverConfiguration to JSON-compatible format.

---

### serialize_species

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:186`

```julia
function serialize_species(species::Species)::Dict{String,Any}
```

serialize_species(species::Species) -> Dict{String,Any}

Serialize Species to JSON-compatible format.

---

### serialize_trigger

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:59`

```julia
function serialize_trigger(trigger::DiscreteEventTrigger)::Dict{String,Any}
```

serialize_trigger(trigger::DiscreteEventTrigger) -> Dict{String,Any}

Serialize DiscreteEventTrigger to JSON-compatible format.

---

### serialize_variable_map

**File:** `pkg/EarthSciAST.jl/src/serialize.jl:353`

```julia
function serialize_variable_map(entry::CouplingVariableMap)::Dict{String,Any}
```

serialize_variable_map(entry::CouplingVariableMap) -> Dict{String,Any}

Serialize variable_map coupling entry.

---

### set_problem_characteristics!

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:135`

```julia
function set_problem_characteristics!(optimizer::SolverOptimizer, characteristics::ProblemCharacteristics)
```

set_problem_characteristics!(optimizer::SolverOptimizer, characteristics::ProblemCharacteristics)

Set the problem characteristics for the optimizer to use in parameter selection.

---

### simplify

**File:** `pkg/EarthSciAST.jl/src/expression.jl:338`

```julia
function simplify(expr::NumExpr)::Expr
```

simplify(expr::Expr)::Expr

Perform constant folding and algebraic simplification on an expression.
Returns a new simplified Expr object (non-mutating).

# Simplification Rules
- Constant folding: `2 + 3` → `5`
- Additive identity: `x + 0` → `x`, `0 + x` → `x`
- Multiplicative identity: `x * 1` → `x`, `1 * x` → `x`
- Multiplicative zero: `x * 0` → `0`, `0 * x` → `0`
- Exponentiation: `x^0` → `1`, `x^1` → `x`

# Examples
```julia
# Constant folding
expr = OpExpr("+", [NumExpr(2.0), NumExpr(3.0)])
result = simplify(expr)  # NumExpr(5.0)

# Identity elimination
expr = OpExpr("*", [VarExpr("x"), NumExpr(1.0)])
result = simplify(expr)  # VarExpr("x")
```

---

### solver_config_to_dict

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:322`

```julia
function solver_config_to_dict(config::SolverConfiguration)::Dict{String,Any}
```

solver_config_to_dict(config::SolverConfiguration) -> Dict{String,Any}

Convert SolverConfiguration to dictionary for manipulation.

---

### solver_strategy_to_string

**File:** `pkg/EarthSciAST.jl/src/types.jl:481`

```julia
function solver_strategy_to_string(strategy::SolverStrategy)::String
```

solver_strategy_to_string(strategy::SolverStrategy) -> String

Convert solver strategy enum to string representation.

---

### start_timer!

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:302`

```julia
function start_timer!(profiler::PerformanceProfiler, operation::String)
```

start_timer!(profiler, operation)

Start timing an operation.

---

### substitute

**File:** `pkg/EarthSciAST.jl/src/expression.jl:42`

```julia
function substitute(expr::NumExpr, bindings::Dict{String,Expr})::Expr
```

substitute(expr::Expr, bindings::Dict{String,Expr})::Expr

Recursively replace variables in an expression with provided bindings.
Supports scoped reference resolution - if a variable is not found in bindings,
it remains unchanged. Returns a new Expr object (non-mutating).

# Arguments
- `expr`: The expression to perform substitution on
- `bindings`: Dictionary mapping variable names to replacement expressions

# Examples
```julia
# Simple substitution
x = VarExpr("x")
y = VarExpr("y")
sum_expr = OpExpr("+", [x, y])
bindings = Dict("x" => NumExpr(2.0))
result = substitute(sum_expr, bindings)  # OpExpr("+", [NumExpr(2.0), VarExpr("y")])

# Nested substitution
nested = OpExpr("*", [OpExpr("+", [x, NumExpr(1.0)]), y])
result = substitute(nested, bindings)  # OpExpr("*", [OpExpr("+", [NumExpr(2.0), NumExpr(1.0)]), VarExpr("y")])
```

---

### substitute_in_equations

**File:** `pkg/EarthSciAST.jl/src/edit.jl:191`

```julia
function substitute_in_equations(model::Model, bindings::Dict{String, EarthSciAST.Expr})::Model
```

substitute_in_equations(model::Model, bindings::Dict{String, Expr}) -> Model

Apply substitutions across all equations in a model.

Replaces variables according to the bindings dictionary.

---

### successors

**File:** `pkg/EarthSciAST.jl/src/graph.jl:97`

```julia
function successors(graph::Graph{N, E}, node::N) where {N, E}
```

Get nodes that this node points to.

---

### suggest_adaptive_configuration

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:284`

```julia
function suggest_adaptive_configuration(strategy::AdaptiveStrategy, history::OptimizationHistory,
```

suggest_adaptive_configuration(strategy::AdaptiveStrategy, history::OptimizationHistory,
                                  base_solver::Solver, problem_chars::Union{ProblemCharacteristics,Nothing}) -> SolverConfiguration

Suggest next configuration using adaptive strategy.

---

### suggest_grid_search_configuration

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:253`

```julia
function suggest_grid_search_configuration(strategy::GridSearchStrategy, history::OptimizationHistory,
```

suggest_grid_search_configuration(strategy::GridSearchStrategy, history::OptimizationHistory, base_solver::Solver) -> SolverConfiguration

Suggest next configuration using grid search strategy.

---

### suggest_model_improvements

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:616`

```julia
function suggest_model_improvements(esm_file, errors)
```

suggest_model_improvements(esm_file, errors)

Suggest improvements based on error patterns.

---

### suggest_next_configuration

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:233`

```julia
function suggest_next_configuration(optimizer::SolverOptimizer, base_solver::Solver)::SolverConfiguration
```

suggest_next_configuration(optimizer::SolverOptimizer, base_solver::Solver) -> SolverConfiguration

Suggest the next configuration to try based on optimization strategy and history.

---

### symbolic_to_esm

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:775`

```julia
function symbolic_to_esm(symbolic_expr)
```

symbolic_to_esm(symbolic_expr) -> Expr

Convert Symbolics/MTK symbolic expression back to ESM form.

---

### to_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:249`

```julia
function to_catalyst_system(reaction_system::ReactionSystem, name::String; advanced_features=false)
```

to_catalyst_system(reaction_system::ReactionSystem, name::String; advanced_features=false) -> Union{ReactionSystem, MockCatalystSystem}

Convert an ESM ReactionSystem to a Catalyst ReactionSystem with comprehensive features.

# Arguments
- `reaction_system::ReactionSystem`: ESM reaction system to convert
- `name::String`: Name for the resulting system
- `advanced_features::Bool`: Enable advanced features

# Enhanced Features
- Species and parameter registration with metadata preservation
- Rate law expression translation with kinetics detection
- Conservation law preservation
- Mass action vs. general kinetics handling
- Event system support for reaction systems
- Performance optimization hints for large systems

---

### to_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst_enhanced.jl:94`

```julia
function to_catalyst_system(rsys::ReactionSystem, name::String; advanced_features=false)
```

to_catalyst_system(rsys::ReactionSystem, name::String; advanced_features=false) -> Union{ReactionSystem, MockCatalystSystem}

Convert an ESM ReactionSystem to a Catalyst ReactionSystem with enhanced features.

# Arguments
- `rsys::ReactionSystem`: ESM reaction system to convert
- `name::String`: Name for the resulting system
- `advanced_features::Bool`: Enable advanced features

# Features
- Species and parameter registration with metadata
- Rate law expression translation with kinetics detection
- Conservation law preservation
- Mass action vs. general kinetics handling
- Event system support
- Performance optimization hints

---

### to_catalyst_system

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:73`

```julia
function to_catalyst_system(rs::ReactionSystem)
```

to_catalyst_system(rs::ReactionSystem)::Union{ReactionSystem, MockCatalystSystem}

Convert an ESM ReactionSystem to a Catalyst.jl ReactionSystem.

This function implements the ESM → Catalyst system conversion task by:
1. Mapping ESM species to @species declarations
2. Converting ESM parameters to @parameters declarations
3. Translating ESM reactions to Reaction() objects
4. Handling null substrates for source reactions (no reactants)
5. Handling null products for sink reactions (no products)
6. Converting rate expressions via symbolic expression mapping
7. Processing constraint_equations as additional equations (if present)
8. Copying events (if present in the ReactionSystem)

# Arguments
- `rs::ReactionSystem`: ESM ReactionSystem to convert

# Returns
- `Union{ReactionSystem, MockCatalystSystem}`: Catalyst ReactionSystem or mock equivalent

# Examples
```julia
# Simple A → B reaction
species = [Species("A"), Species("B")]
parameters = [Parameter("k", 0.1)]
reactions = [Reaction(Dict("A" => 1), Dict("B" => 1), VarExpr("k"))]
rs = ReactionSystem(species, reactions; parameters=parameters)

catalyst_sys = to_catalyst_system(rs)
```

# Error Handling
- Gracefully falls back to mock implementation if Catalyst.jl unavailable
- Warns about unsupported features but continues processing
- Validates species and parameter references in reactions

---

### to_coupled_system

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:170`

```julia
function to_coupled_system(file::EsmFile)::MockCoupledSystem
```

to_coupled_system(file::EsmFile)::MockCoupledSystem

Convert an ESM file with coupling rules into a coupled system.
This implements the Full tier capability for coupled system assembly
handling operator_compose, couple, variable_map, and operator_apply.

The algorithm processes coupling entries in array order for deterministic naming
and applies the four main coupling operations:
1. operator_compose - Compose systems by matching equations
2. couple - Bidirectional coupling via connector equations
3. variable_map - Map variables between systems with transforms
4. operator_apply - Register operators for runtime

Returns a MockCoupledSystem that would be compatible with OrdinaryDiffEq.jl
in a real implementation with EarthSciMLBase.

---

### to_dot

**File:** `pkg/EarthSciAST.jl/src/graph.jl:752`

```julia
function to_dot(graph::Graph{ComponentNode, CouplingEdge})::String
```

Export graph to DOT format for Graphviz rendering.

---

### to_json

**File:** `pkg/EarthSciAST.jl/src/graph.jl:896`

```julia
function to_json(graph::Graph{N, E})::String where {N, E}
```

Export graph to JSON adjacency list format.

---

### to_mermaid

**File:** `pkg/EarthSciAST.jl/src/graph.jl:829`

```julia
function to_mermaid(graph::Graph{ComponentNode, CouplingEdge})::String
```

Export graph to Mermaid format for markdown embedding.

---

### to_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:84`

```julia
function to_mtk_system(model::Model, name::String; advanced_features=false)
```

to_mtk_system(model::Model, name::String; advanced_features=false) -> Union{ODESystem, MockMTKSystem}

Convert an ESM Model to a ModelingToolkit ODESystem with comprehensive features.

# Arguments
- `model::Model`: ESM model to convert
- `name::String`: Name for the resulting system
- `advanced_features::Bool`: Enable advanced features like algebraic reduction

# Enhanced Features
- Parameter/variable mapping with proper scoping and metadata preservation
- Event system translation (continuous/discrete) with full MTK compatibility
- Initial condition and boundary condition handling
- Symbolic differentiation integration with enhanced expression support
- Hierarchical system composition for complex models
- Cross-system coupling via MTK connectors
- Automated algebraic reduction where possible
- Numerical method selection optimization
- Performance profiling integration

---

### to_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst_enhanced.jl:62`

```julia
function to_mtk_system(model::Model, name::String; advanced_features=false)
```

to_mtk_system(model::Model, name::String; advanced_features=false) -> Union{ODESystem, MockMTKSystem}

Convert an ESM Model to a ModelingToolkit ODESystem with enhanced features.

# Arguments
- `model::Model`: ESM model to convert
- `name::String`: Name for the resulting system
- `advanced_features::Bool`: Enable advanced features like algebraic reduction

# Features
- Full variable type support (state, parameter, observed)
- Event system translation (continuous/discrete)
- Hierarchical system composition support
- Cross-system coupling via connectors
- Automated algebraic reduction (optional)
- Performance profiling integration

---

### to_mtk_system

**File:** `pkg/EarthSciAST.jl/src/mtk.jl:72`

```julia
function to_mtk_system(model::Model, name::Union{String,Nothing}=nothing)
```

to_mtk_system(model::Model, name::Union{String,Nothing}=nothing)

Convert an ESM Model to a ModelingToolkit ODESystem or MockMTKSystem.

# Arguments
- `model::Model`: ESM model containing variables, equations, and events
- `name::Union{String,Nothing}`: Optional name for the system (defaults to :anonymous)

# Returns
- `ODESystem` or `MockMTKSystem`: Real or mock system depending on availability

# Expression mapping:
- `OpExpr('+')` → +
- `OpExpr('D', wrt='t')` → Differential(t)(var)
- `OpExpr('exp')` → exp
- `OpExpr('Pre')` → Pre
- `OpExpr('grad', dim='y')` → Differential(y)(var)
- `OpExpr('ifelse')` → ifelse
- `NumExpr` → literal
- `VarExpr` → @variables/@parameters based on type

Creates symbolic variables for state vars as functions of t, parameters as plain symbols.
Maps equations to MTK ~ syntax. Maps continuous events to SymbolicContinuousCallback,
discrete events to SymbolicDiscreteCallback.

---

### to_subscript

**File:** `pkg/EarthSciAST.jl/src/display.jl:45`

```julia
function to_subscript(n::Integer)
```

to_subscript(n::Integer) -> String

Convert integer to Unicode subscript representation.

---

### to_superscript

**File:** `pkg/EarthSciAST.jl/src/display.jl:61`

```julia
function to_superscript(text::String)
```

to_superscript(text::String) -> String

Convert text to Unicode superscript representation.

---

### validate

**File:** `pkg/EarthSciAST.jl/src/validate.jl:148`

```julia
function validate(file::EsmFile)::ValidationResult
```

validate(file::EsmFile) -> ValidationResult

Complete validation combining schema, structural, and unit validation.
Returns ValidationResult with all errors and warnings.

---

### validate_coupling_references

**File:** `pkg/EarthSciAST.jl/src/validate.jl:306`

```julia
function validate_coupling_references(file::EsmFile, coupling_entry::CouplingEntry, path::String)::Vector{StructuralError}
```

validate_coupling_references(file::EsmFile, coupling_entry::CouplingEntry, path::String) -> Vector{StructuralError}

Validate coupling references - placeholder implementation.

---

### validate_equation_dimensions

**File:** `pkg/EarthSciAST.jl/src/units.jl:190`

```julia
function validate_equation_dimensions(eq::Equation, var_units::Dict{String, String})::Bool
```

Validate that an equation is dimensionally consistent.

Checks that the left-hand side and right-hand side have the same dimensions.

---

### validate_event_consistency

**File:** `pkg/EarthSciAST.jl/src/validate.jl:446`

```julia
function validate_event_consistency(model::Model, path::String)::Vector{StructuralError}
```

validate_event_consistency(model::Model, path::String) -> Vector{StructuralError}

Validate event consistency: continuous conditions are expressions,
discrete conditions produce booleans, affect variables declared,
functional affect refs valid.

---

### validate_event_references

**File:** `pkg/EarthSciAST.jl/src/validate.jl:317`

```julia
function validate_event_references(file::EsmFile, event::EventType, path::String)::Vector{StructuralError}
```

validate_event_references(file::EsmFile, event::EventType, path::String) -> Vector{StructuralError}

Validate event variable references.

---

### validate_expression_references

**File:** `pkg/EarthSciAST.jl/src/validate.jl:268`

```julia
function validate_expression_references(file::EsmFile, expr::Expr, path::String)::Vector{StructuralError}
```

validate_expression_references(file::EsmFile, expr::Expr, path::String) -> Vector{StructuralError}

Validate that all variable references in an expression can be resolved.

---

### validate_file_dimensions

**File:** `pkg/EarthSciAST.jl/src/units.jl:280`

```julia
function validate_file_dimensions(file::EsmFile)::Bool
```

Validate dimensions for all components in an ESM file.

Returns true if all models and reaction systems pass dimensional validation.

---

### validate_model_balance

**File:** `pkg/EarthSciAST.jl/src/validate.jl:170`

```julia
function validate_model_balance(model::Model, path::String)::Vector{StructuralError}
```

validate_model_balance(model::Model, path::String) -> Vector{StructuralError}

Validate equation-unknown balance for a model.
Each model should have equations for all state variables.

---

### validate_model_dimensions

**File:** `pkg/EarthSciAST.jl/src/units.jl:214`

```julia
function validate_model_dimensions(model::Model)::Bool
```

Validate dimensions for all equations in a model.

Returns true if all equations are dimensionally consistent.

---

### validate_model_references

**File:** `pkg/EarthSciAST.jl/src/validate.jl:241`

```julia
function validate_model_references(file::EsmFile, model::Model, path::String)::Vector{StructuralError}
```

validate_model_references(file::EsmFile, model::Model, path::String) -> Vector{StructuralError}

Validate variable references within a model.

---

### validate_reaction_consistency

**File:** `pkg/EarthSciAST.jl/src/validate.jl:354`

```julia
function validate_reaction_consistency(rs::ReactionSystem, path::String)::Vector{StructuralError}
```

validate_reaction_consistency(rs::ReactionSystem, path::String) -> Vector{StructuralError}

Validate reaction system consistency: species declared, positive stoichiometries,
no null-null reactions, rate references declared.

---

### validate_reaction_system_dimensions

**File:** `pkg/EarthSciAST.jl/src/units.jl:239`

```julia
function validate_reaction_system_dimensions(rxn_sys::ReactionSystem)::Bool
```

Validate dimensions for all reactions in a reaction system.

For reactions, validates that rate expressions have appropriate dimensions
(typically concentration/time for elementary reactions).

---

### validate_reference_integrity

**File:** `pkg/EarthSciAST.jl/src/validate.jl:218`

```julia
function validate_reference_integrity(file::EsmFile)::Vector{StructuralError}
```

validate_reference_integrity(file::EsmFile) -> Vector{StructuralError}

Validate that all variable references can be resolved through the hierarchy.

---

### validate_reference_syntax

**File:** `pkg/EarthSciAST.jl/src/types.jl:901`

```julia
function validate_reference_syntax(reference::String)::Bool
```

validate_reference_syntax(reference::String) -> Bool

Validate that a reference string follows proper dot notation syntax.

---

### validate_schema

**File:** `pkg/EarthSciAST.jl/src/validate.jl:85`

```julia
function validate_schema(data::Any)::Vector{SchemaError}
```

validate_schema(data::Any) -> Vector{SchemaError}

Validate data against the ESM schema.
Returns empty vector if valid, otherwise returns validation errors.
Each error contains the path, message, and keyword for debugging.

---

### validate_solver_compatibility

**File:** `pkg/EarthSciAST.jl/src/types.jl:534`

```julia
function validate_solver_compatibility(solver::Solver)::Bool
```

validate_solver_compatibility(solver::Solver) -> Bool

Check compatibility between solver strategy and configuration.
Returns true if configuration is compatible with strategy.

---

### validate_structural

**File:** `pkg/EarthSciAST.jl/src/validate.jl:112`

```julia
function validate_structural(file::EsmFile)::Vector{StructuralError}
```

validate_structural(file::EsmFile) -> Vector{StructuralError}

Validate structural consistency of ESM file according to spec Section 3.2.
Checks equation-unknown balance, reference integrity, reaction consistency,
and event consistency.

---

### variable_exists_in_system

**File:** `pkg/EarthSciAST.jl/src/types.jl:869`

```julia
function variable_exists_in_system(system::Model, variable_name::String)::Bool
```

variable_exists_in_system(system, variable_name::String) -> Bool

Check if a variable exists in the given system.

---

### variable_map

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:404`

```julia
function variable_map(coupled_system::MockCoupledSystem, coupling::CouplingVariableMap, file::EsmFile)
```

variable_map(coupled_system::MockCoupledSystem, coupling::CouplingVariableMap, file::EsmFile)

Implement variable mapping with transform operations:
1. Resolve from/to scoped references using the qualified reference system
2. Apply transform: param_to_var, identity, additive, multiplicative, conversion_factor

---

## Types

### AdaptiveStrategy

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:82`

```julia
struct AdaptiveStrategy <: OptimizationStrategy
```

AdaptiveStrategy <: OptimizationStrategy

Adaptive parameter adjustment based on performance feedback.

---

### AffectEquation

**File:** `pkg/EarthSciAST.jl/src/types.jl:80`

```julia
struct AffectEquation
```

AffectEquation(lhs::String, rhs::Expr)

Assignment equation for discrete events.
- `lhs`: target variable name (string)
- `rhs`: expression for the new value

---

### ComponentNode

**File:** `pkg/EarthSciAST.jl/src/graph.jl:21`

```julia
struct ComponentNode
```

Component-level node representing a model, reaction system, data loader, or operator.

---

### ConditionTrigger

**File:** `pkg/EarthSciAST.jl/src/types.jl:108`

```julia
struct ConditionTrigger <: DiscreteEventTrigger
```

ConditionTrigger(expression::Expr)

Trigger based on boolean condition expression.

---

### ContinuousEvent

**File:** `pkg/EarthSciAST.jl/src/types.jl:160`

```julia
struct ContinuousEvent <: EventType
```

ContinuousEvent <: EventType

Event triggered by zero-crossing of condition expressions.

---

### CouplingCallback

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:93`

```julia
struct CouplingCallback <: CouplingEntry
```

CouplingCallback <: CouplingEntry

Register a callback for simulation events.

---

### CouplingCouple

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:44`

```julia
struct CouplingCouple <: CouplingEntry
```

CouplingCouple <: CouplingEntry

Bi-directional coupling via explicit ConnectorSystem equations.

---

### CouplingEdge

**File:** `pkg/EarthSciAST.jl/src/graph.jl:33`

```julia
struct CouplingEdge
```

Edge representing coupling between components.

---

### CouplingEntry

**File:** `pkg/EarthSciAST.jl/src/types.jl:315`

```julia
abstract type CouplingEntry end
```

abstract type CouplingEntry end

Abstract base type for coupling entries that connect model components.

---

### CouplingEvent

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:108`

```julia
struct CouplingEvent <: CouplingEntry
```

CouplingEvent <: CouplingEntry

Cross-system event involving variables from multiple coupled systems.

---

### CouplingOperatorApply

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:79`

```julia
struct CouplingOperatorApply <: CouplingEntry
```

CouplingOperatorApply <: CouplingEntry

Register an Operator to run during simulation.

---

### CouplingOperatorCompose

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:27`

```julia
struct CouplingOperatorCompose <: CouplingEntry
```

CouplingOperatorCompose <: CouplingEntry

Match LHS time derivatives and add RHS terms together.
Implements operator composition algorithm from specification Section 4.7.1.

---

### CouplingVariableMap

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:61`

```julia
struct CouplingVariableMap <: CouplingEntry
```

CouplingVariableMap <: CouplingEntry

Replace a parameter in one system with a variable from another.

---

### DataLoader

**File:** `pkg/EarthSciAST.jl/src/types.jl:323`

```julia
struct DataLoader
```

DataLoader

External data source registration (by reference).
Runtime-specific data loading functionality.

---

### DependencyEdge

**File:** `pkg/EarthSciAST.jl/src/graph.jl:56`

```julia
struct DependencyEdge
```

Edge representing dependency between variables.

---

### DiscreteEvent

**File:** `pkg/EarthSciAST.jl/src/types.jl:175`

```julia
struct DiscreteEvent <: EventType
```

DiscreteEvent <: EventType

Event triggered by discrete triggers with functional affects.

---

### DiscreteEventTrigger

**File:** `pkg/EarthSciAST.jl/src/types.jl:101`

```julia
abstract type DiscreteEventTrigger end
```

abstract type DiscreteEventTrigger end

Abstract base type for discrete event triggers.

---

### Domain

**File:** `pkg/EarthSciAST.jl/src/types.jl:360`

```julia
struct Domain
```

Domain

Spatial and temporal domain specification.

---

### ESMError

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:127`

```julia
struct ESMError
```

ESMError

Comprehensive error representation with diagnostics and suggestions.

---

### Equation

**File:** `pkg/EarthSciAST.jl/src/types.jl:68`

```julia
struct Equation
```

Equation(lhs::Expr, rhs::Expr)

Mathematical equation with left-hand side and right-hand side expressions.
Used for differential equations and algebraic constraints.

---

### ErrorCollector

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:154`

```julia
mutable struct ErrorCollector
```

ErrorCollector

Collects and manages errors during ESM processing.

---

### ErrorContext

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:86`

```julia
struct ErrorContext
```

ErrorContext

Additional context information for errors.

---

### EsmFile

**File:** `pkg/EarthSciAST.jl/src/types.jl:691`

```julia
struct EsmFile
```

EsmFile

Main ESM file structure containing all components.

---

### EventType

**File:** `pkg/EarthSciAST.jl/src/types.jl:94`

```julia
abstract type EventType end
```

abstract type EventType end

Abstract base type for all event types in the ESM format.

---

### Expr

**File:** `pkg/EarthSciAST.jl/src/types.jl:18`

```julia
abstract type Expr end
```

abstract type Expr end

Abstract base type for all mathematical expressions in the ESM format.
Expressions can be numeric literals, variable references, or operator nodes.

---

### FixSuggestion

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:112`

```julia
struct FixSuggestion
```

FixSuggestion

Actionable suggestion for fixing an error.

---

### FunctionalAffect

**File:** `pkg/EarthSciAST.jl/src/types.jl:141`

```julia
struct FunctionalAffect
```

FunctionalAffect

Functional affect for discrete events.

---

### Graph

**File:** `pkg/EarthSciAST.jl/src/graph.jl:13`

```julia
struct Graph{N, E}
```

Generic graph structure with nodes and edges.

---

### GridSearchStrategy

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:69`

```julia
struct GridSearchStrategy <: OptimizationStrategy
```

GridSearchStrategy <: OptimizationStrategy

Grid search over predefined parameter ranges.

---

### Metadata

**File:** `pkg/EarthSciAST.jl/src/types.jl:664`

```julia
struct Metadata
```

Metadata

Authorship, provenance, and description metadata.

---

### MockCatalystSystem

**File:** `pkg/EarthSciAST.jl/src/mtk_catalyst.jl:858`

```julia
struct MockCatalystSystem
```

MockCatalystSystem

Mock Catalyst system for testing and fallback when Catalyst is unavailable.

---

### MockCatalystSystem

**File:** `pkg/EarthSciAST.jl/src/catalyst.jl:306`

```julia
struct MockCatalystSystem
```

MockCatalystSystem

Mock Catalyst system for testing and fallback when Catalyst.jl is unavailable.
Preserves all structural information from the ESM ReactionSystem.

---

### MockCoupledSystem

**File:** `pkg/EarthSciAST.jl/src/coupled.jl:138`

```julia
struct MockCoupledSystem
```

MockCoupledSystem

Mock implementation of EarthSciMLBase.CoupledSystem for demonstration.
This would be replaced with real EarthSciMLBase integration.

---

### Model

**File:** `pkg/EarthSciAST.jl/src/types.jl:230`

```julia
struct Model
```

Model

ODE-based model component containing variables, equations, and optional subsystems.
Supports hierarchical composition through subsystems.

---

### ModelVariable

**File:** `pkg/EarthSciAST.jl/src/types.jl:208`

```julia
struct ModelVariable
```

ModelVariable

Structure defining a model variable with its type, default value, and optional expression.

---

### NumExpr

**File:** `pkg/EarthSciAST.jl/src/types.jl:25`

```julia
struct NumExpr <: Expr
```

NumExpr(value::Float64)

Numeric literal expression containing a floating-point value.

---

### OpExpr

**File:** `pkg/EarthSciAST.jl/src/types.jl:47`

```julia
struct OpExpr <: Expr
```

OpExpr(op::String, args::Vector{Expr}, wrt::Union{String,Nothing}, dim::Union{String,Nothing})

Operator expression node containing:
- `op`: operator name (e.g., "+", "*", "log", "D")
- `args`: vector of argument expressions
- `wrt`: variable name for differentiation (optional)
- `dim`: dimension for spatial operators (optional)

---

### Operator

**File:** `pkg/EarthSciAST.jl/src/types.jl:340`

```julia
struct Operator
```

Operator

Registered runtime operator (by reference).
Platform-specific computational kernels and operations.

---

### OptimizationHistory

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:100`

```julia
mutable struct OptimizationHistory
```

OptimizationHistory

Tracks the history of parameter configurations and their performance.

---

### OptimizationStrategy

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:62`

```julia
abstract type OptimizationStrategy end
```

OptimizationStrategy

Abstract base type for different parameter optimization strategies.

---

### Parameter

**File:** `pkg/EarthSciAST.jl/src/types.jl:262`

```julia
struct Parameter
```

Parameter

Model parameter with name, default value, and optional metadata.

---

### ParseError

**File:** `pkg/EarthSciAST.jl/src/parse.jl:17`

```julia
struct ParseError <: Exception
```

ParseError

Exception thrown when JSON parsing fails.

---

### PerformanceMetrics

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:17`

```julia
struct PerformanceMetrics
```

PerformanceMetrics

Stores performance metrics from solver execution.

---

### PerformanceProfiler

**File:** `pkg/EarthSciAST.jl/src/error_handling.jl:275`

```julia
mutable struct PerformanceProfiler
```

PerformanceProfiler

Performance profiling tool for ESM operations.

---

### PeriodicTrigger

**File:** `pkg/EarthSciAST.jl/src/types.jl:119`

```julia
struct PeriodicTrigger <: DiscreteEventTrigger
```

PeriodicTrigger(period::Float64, phase::Float64)

Trigger that fires periodically.
- `period`: time interval between triggers
- `phase`: time offset for first trigger

---

### PresetTimesTrigger

**File:** `pkg/EarthSciAST.jl/src/types.jl:132`

```julia
struct PresetTimesTrigger <: DiscreteEventTrigger
```

PresetTimesTrigger(times::Vector{Float64})

Trigger that fires at preset times.

---

### ProblemCharacteristics

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:37`

```julia
struct ProblemCharacteristics
```

ProblemCharacteristics

Characterizes the mathematical properties of the problem being solved.

---

### QualifiedReferenceError

**File:** `pkg/EarthSciAST.jl/src/types.jl:724`

```julia
struct QualifiedReferenceError <: Exception
```

QualifiedReferenceError

Exception thrown when qualified reference resolution fails.
Contains detailed error information.

---

### Reaction

**File:** `pkg/EarthSciAST.jl/src/types.jl:278`

```julia
struct Reaction
```

Reaction

Chemical reaction with reactants, products, and rate expression.

---

### ReactionSystem

**File:** `pkg/EarthSciAST.jl/src/types.jl:294`

```julia
struct ReactionSystem
```

ReactionSystem

Collection of chemical reactions with associated species, supporting hierarchical composition.

---

### Reference

**File:** `pkg/EarthSciAST.jl/src/types.jl:648`

```julia
struct Reference
```

Reference

Academic citation or data source reference.

---

### ReferenceResolution

**File:** `pkg/EarthSciAST.jl/src/types.jl:736`

```julia
struct ReferenceResolution
```

ReferenceResolution

Result of qualified reference resolution containing the resolved variable
and its location information.

---

### SchemaError

**File:** `pkg/EarthSciAST.jl/src/validate.jl:16`

```julia
struct SchemaError
```

SchemaError

Represents a validation error with detailed information.
Contains path, message, and keyword from JSON Schema validation.

---

### SchemaValidationError

**File:** `pkg/EarthSciAST.jl/src/validate.jl:57`

```julia
struct SchemaValidationError <: Exception
```

SchemaValidationError

Exception thrown when schema validation fails.
Contains detailed error information including paths and messages.

---

### Solver

**File:** `pkg/EarthSciAST.jl/src/types.jl:441`

```julia
struct Solver
```

Solver

Enhanced solver strategy and configuration supporting different numerical methods,
solver parameters, convergence criteria, and method compatibility checking.

---

### SolverConfiguration

**File:** `pkg/EarthSciAST.jl/src/types.jl:402`

```julia
struct SolverConfiguration
```

SolverConfiguration

Strategy-specific configuration for solver methods.
Contains method-specific parameters, tolerances, and algorithms.

---

### SolverOptimizer

**File:** `pkg/EarthSciAST.jl/src/solver_optimization.jl:115`

```julia
mutable struct SolverOptimizer
```

SolverOptimizer

Main optimization controller that manages parameter tuning.

---

### Species

**File:** `pkg/EarthSciAST.jl/src/types.jl:247`

```julia
struct Species
```

Species

Chemical species definition with name and optional properties.

---

### StructuralError

**File:** `pkg/EarthSciAST.jl/src/validate.jl:28`

```julia
struct StructuralError
```

StructuralError

Represents a structural validation error with detailed information.
Contains path, message, and error type for structural issues.

---

### UnboundVariableError

**File:** `pkg/EarthSciAST.jl/src/expression.jl:152`

```julia
struct UnboundVariableError <: Exception
```

UnboundVariableError

Exception thrown when trying to evaluate an expression with unbound variables.

---

### ValidationResult

**File:** `pkg/EarthSciAST.jl/src/validate.jl:40`

```julia
struct ValidationResult
```

ValidationResult

Combined validation result containing schema errors, structural errors,
unit warnings, and overall validation status.

---

### VarExpr

**File:** `pkg/EarthSciAST.jl/src/types.jl:34`

```julia
struct VarExpr <: Expr
```

VarExpr(name::String)

Variable or parameter reference expression containing a name string.

---

### VariableNode

**File:** `pkg/EarthSciAST.jl/src/graph.jl:46`

```julia
struct VariableNode
```

Variable-level node for expression graphs.

---

