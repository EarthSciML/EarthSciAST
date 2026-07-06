"""
Code generation for the ESM format

This module provides functions to generate self-contained scripts
from ESM files in multiple target languages:
- Julia: compatible with ModelingToolkit, Catalyst, EarthSciMLBase, and OrdinaryDiffEq
- Python: compatible with SymPy, earthsci_toolkit, and SciPy
"""

"""
    to_julia_code(file::EsmFile)

Generate a Julia script from an ESM file.
Returns a string containing Julia code.

The output is *illustrative scaffolding*: it sketches the MTK/Catalyst system
definitions implied by the file (variables, parameters, equations, reactions)
but is not guaranteed to run unmodified against the current ModelingToolkit
release (e.g. variable default/unit metadata syntax, SDE noise equations).
"""
function to_julia_code(file::EsmFile)
    lines = String[]

    # Header comment
    push!(lines, "# Generated Julia script from ESM file")
    push!(lines, "# ESM version: $(file.esm)")
    if !isnothing(file.metadata) && !isnothing(file.metadata.name)
        push!(lines, "# Title: $(file.metadata.name)")
    end
    if !isnothing(file.metadata) && !isnothing(file.metadata.description)
        push!(lines, "# Description: $(file.metadata.description)")
    end
    push!(lines, "")

    # Using statements
    push!(lines, "# Package imports")
    push!(lines, "using ModelingToolkit")
    push!(lines, "using Catalyst")
    push!(lines, "using EarthSciMLBase")
    push!(lines, "using OrdinaryDiffEq")
    push!(lines, "using Unitful")
    push!(lines, "")

    # Generate models
    if !isnothing(file.models) && !isempty(file.models)
        push!(lines, "# Models")
        for (name, model) in file.models
            append!(lines, generate_model_code(name, model))
            push!(lines, "")
        end
    end

    # Generate reaction systems
    if !isnothing(file.reaction_systems) && !isempty(file.reaction_systems)
        push!(lines, "# Reaction Systems")
        for (name, reaction_system) in file.reaction_systems
            append!(lines, generate_reaction_system_code(name, reaction_system))
            push!(lines, "")
        end
    end

    # Note: Events are handled within individual models, not at the file level

    # Generate coupling placeholders (codegen not yet implemented)
    if !isnothing(file.coupling) && !isempty(file.coupling)
        push!(lines, "# Coupling")
        for coupling in file.coupling
            append!(lines, generate_coupling_placeholder(coupling))
        end
        push!(lines, "")
    end

    # Generate domain placeholder (codegen not yet implemented). v0.8.0: a
    # single shared top-level `domain`, not a map of named domains.
    if !isnothing(file.domain)
        push!(lines, "# Domain")
        append!(lines, generate_domain_placeholder("domain", file.domain))
        push!(lines, "")
    end

    # Generate data loader placeholders (codegen not yet implemented)
    if !isnothing(file.data_loaders) && !isempty(file.data_loaders)
        push!(lines, "# Data Loaders")
        for (name, data_loader) in file.data_loaders
            append!(lines, generate_data_loader_placeholder(name, data_loader))
        end
        push!(lines, "")
    end

    return join(lines, "\n")
end

"""
    to_python_code(file::EsmFile)

Generate a Python script from an ESM file.
Returns a string containing Python code.

Like [`to_julia_code`](@ref), the output is illustrative scaffolding for a
SymPy/earthsci_toolkit workflow, not guaranteed-runnable code.
"""
function to_python_code(file::EsmFile)
    lines = String[]

    # Header comment
    push!(lines, "# Generated Python script from ESM file")
    push!(lines, "# ESM version: $(file.esm)")
    if !isnothing(file.metadata) && !isnothing(file.metadata.name)
        push!(lines, "# Title: $(file.metadata.name)")
    end
    if !isnothing(file.metadata) && !isnothing(file.metadata.description)
        push!(lines, "# Description: $(file.metadata.description)")
    end
    push!(lines, "")

    # Import statements
    push!(lines, "# Package imports")
    push!(lines, "import sympy as sp")
    push!(lines, "import earthsci_toolkit as esm")
    push!(lines, "import scipy")
    push!(lines, "from sympy import Function")
    push!(lines, "")

    # Generate models
    if !isnothing(file.models) && !isempty(file.models)
        push!(lines, "# Models")
        for (name, model) in file.models
            append!(lines, generate_python_model_code(name, model))
            push!(lines, "")
        end
    end

    # Generate reaction systems
    if !isnothing(file.reaction_systems) && !isempty(file.reaction_systems)
        push!(lines, "# Reaction Systems")
        for (name, reaction_system) in file.reaction_systems
            append!(lines, generate_python_reaction_system_code(name, reaction_system))
            push!(lines, "")
        end
    end

    # Generate simulation setup
    push!(lines, "# Simulation setup")
    push!(lines, "tspan = (0, 10)  # time span")
    push!(lines, "parameters = {}  # parameter values")
    push!(lines, "initial_conditions = {}  # initial values")
    push!(lines, "")
    push!(lines, "# result = esm.simulate(tspan=tspan, parameters=parameters, initial_conditions=initial_conditions)")
    push!(lines, "")

    # Generate coupling placeholders (codegen not yet implemented)
    if !isnothing(file.coupling) && !isempty(file.coupling)
        push!(lines, "# Coupling")
        for coupling in file.coupling
            append!(lines, generate_coupling_placeholder(coupling; lang=:python))
        end
        push!(lines, "")
    end

    # Generate domain placeholder (codegen not yet implemented). v0.8.0: a
    # single shared top-level `domain`, not a map of named domains.
    if !isnothing(file.domain)
        push!(lines, "# Domain")
        append!(lines, generate_domain_placeholder("domain", file.domain))
        push!(lines, "")
    end

    return join(lines, "\n")
end

# Helper functions for Julia code generation

function generate_model_code(name::String, model::Model)
    lines = String[]

    push!(lines, "# Model: $name")

    # Collect state variables, parameters, and brownian (Wiener) noise sources.
    # Brownian variables map to MTK `@brownians` and promote the system to
    # an SDESystem (vs ODESystem). See spec ModelVariable.type = "brownian".
    state_vars = Tuple{String, ModelVariable}[]
    parameters = Tuple{String, ModelVariable}[]
    brownians = Tuple{String, ModelVariable}[]

    if !isnothing(model.variables) && !isempty(model.variables)
        for (var_name, variable) in model.variables
            if variable.type == StateVariable
                push!(state_vars, (var_name, variable))
            elseif variable.type == ParameterVariable
                push!(parameters, (var_name, variable))
            elseif variable.type == BrownianVariable
                push!(brownians, (var_name, variable))
            end
        end
    end

    # Generate @variables declaration
    if !isempty(state_vars)
        var_decls = join(map(x -> format_variable_declaration(x[1], x[2]), state_vars), " ")
        push!(lines, "@variables t $var_decls")
    end

    # Generate @parameters declaration
    if !isempty(parameters)
        param_decls = join(map(x -> format_variable_declaration(x[1], x[2]), parameters), " ")
        push!(lines, "@parameters $param_decls")
    end

    # Generate @brownians declaration (MTK Wiener processes)
    if !isempty(brownians)
        push!(lines, "@brownians $(join(first.(brownians), " "))")
    end

    # Generate equations
    if !isnothing(model.equations) && !isempty(model.equations)
        push!(lines, "")
        push!(lines, "eqs = [")
        for equation in model.equations
            push!(lines, "    $(format_equation(equation)),")
        end
        push!(lines, "]")
    end

    # Generate @named system. Brownian variables present => SDESystem; otherwise
    # ODESystem. Modern MTK requires the independent variable as second argument.
    push!(lines, "")
    if !isempty(brownians)
        push!(lines, "@named $(name)_system = SDESystem(eqs, t)")
    else
        push!(lines, "@named $(name)_system = ODESystem(eqs, t)")
    end

    return lines
end

function generate_reaction_system_code(name::String, reaction_system::ReactionSystem)
    lines = String[]

    push!(lines, "# Reaction System: $name")

    # Split species by the Species.constant flag: ordinary state species get
    # @species, reservoir species (constant=true) are emitted as @parameters
    # with the Catalyst isconstantspecies=true metadata. Catalyst's @species
    # macro rejects isconstantspecies metadata ("can only be used with
    # parameters"), so the metadata must travel with a @parameters declaration.
    state_species = !isnothing(reaction_system.species) ?
        filter(s -> s.constant !== true, reaction_system.species) : Species[]
    const_species = !isnothing(reaction_system.species) ?
        filter(s -> s.constant === true, reaction_system.species) : Species[]

    if !isempty(state_species)
        species_decls = join(map(format_species_declaration, state_species), " ")
        push!(lines, "@species $species_decls")
    end

    # Generate @parameters for rate-expression symbols plus reservoir species.
    # Rate symbols are resolved against the declared species list: anything a
    # rate references that is not a species is emitted as a parameter (this
    # covers declared parameters and undeclared symbols alike, and never
    # re-declares a species).
    species_names = !isnothing(reaction_system.species) ?
        Set(s.name for s in reaction_system.species) : Set{String}()
    reaction_params = Set{String}()
    if !isnothing(reaction_system.reactions) && !isempty(reaction_system.reactions)
        for reaction in reaction_system.reactions
            if !isnothing(reaction.rate)
                union!(reaction_params, extract_parameter_names(reaction.rate, species_names))
            end
        end
    end

    if !isempty(reaction_params)
        push!(lines, "@parameters $(join(sort!(collect(reaction_params)), " "))")
    end
    if !isempty(const_species)
        reservoir_decls = join([string(s.name, " [isconstantspecies=true]") for s in const_species], " ")
        push!(lines, "@parameters $reservoir_decls")
    end

    # Generate reactions
    if !isnothing(reaction_system.reactions) && !isempty(reaction_system.reactions)
        push!(lines, "")
        push!(lines, "rxs = [")
        for reaction in reaction_system.reactions
            push!(lines, "    $(format_reaction(reaction)),")
        end
        push!(lines, "]")
    end

    # Generate @named ReactionSystem
    push!(lines, "")
    push!(lines, "@named $(name)_system = ReactionSystem(rxs)")

    return lines
end

"""
    generate_coupling_placeholder(coupling::CouplingEntry; lang::Symbol=:julia)

Emit comment-only placeholder lines describing a coupling entry (coupling
codegen is not yet implemented). Shared by the Julia and Python emitters;
`lang=:julia` adds Julia-specific implementation notes.
"""
function generate_coupling_placeholder(coupling::CouplingEntry; lang::Symbol=:julia)
    lines = String[]
    if coupling isa CouplingOperatorCompose
        push!(lines, "# Coupling (operator_compose): compose systems $(join(coupling.systems, ", "))")
        lang === :julia &&
            push!(lines, "#   Needs: ConnectorSystem to match LHS time derivatives and add RHS terms")
    elseif coupling isa CouplingCouple
        push!(lines, "# Coupling (couple): bidirectional coupling of $(join(coupling.systems, ", "))")
        lang === :julia &&
            push!(lines, "#   Needs: connector equations via compose()")
    elseif coupling isa CouplingVariableMap
        push!(lines, "# Coupling (variable_map): $(coupling.from) → $(coupling.to) via $(coupling.transform)")
        if lang === :julia && !isnothing(coupling.factor)
            push!(lines, "#   Factor: $(coupling.factor)")
        end
    elseif coupling isa CouplingOperatorApply
        push!(lines, "# Coupling (operator_apply): register operator $(coupling.operator)")
    elseif coupling isa CouplingCallback
        push!(lines, "# Coupling (callback): $(coupling.callback_id)")
    elseif coupling isa CouplingEvent
        push!(lines, "# Coupling (event): $(coupling.event_type) with $(length(coupling.affects)) affect(s)")
    else
        push!(lines, "# Coupling: $(typeof(coupling))")
    end
    if !isnothing(coupling.description)
        push!(lines, "#   $(coupling.description)")
    end
    return lines
end

"""
    generate_domain_placeholder(name::String, domain::Domain)

Emit comment-only placeholder lines describing the domain (domain codegen is
not yet implemented). The comment syntax is identical in Julia and Python, so
one generator serves both emitters.
"""
function generate_domain_placeholder(name::String, domain::Domain)
    lines = String[]
    push!(lines, "# Domain: $name")
    if !isnothing(domain.temporal)
        temporal = domain.temporal
        tstart = get(temporal, "start", nothing)
        tend = get(temporal, "end", nothing)
        if !isnothing(tstart) && !isnothing(tend)
            push!(lines, "#   Temporal range: $tstart to $tend")
        end
    end
    return lines
end

function generate_data_loader_placeholder(name::String, data_loader::DataLoader)
    lines = String[]
    push!(lines, "# Data loader: $name")
    push!(lines, "#   Kind: $(data_loader.kind)")
    push!(lines, "#   Source: $(data_loader.source.url_template)")
    var_names = sort(collect(keys(data_loader.variables)))
    push!(lines, "#   Variables: $(join(var_names, ", "))")
    return lines
end

function format_variable_declaration(var_name::String, variable::ModelVariable)
    decl = var_name

    # Add default value and units if present
    parts = String[]
    if !isnothing(variable.default)
        default_val = variable.default
        if isa(default_val, Int)
            push!(parts, "$(default_val).0")
        else
            push!(parts, string(default_val))
        end
    end

    if !isnothing(variable.units)
        push!(parts, "u\"$(variable.units)\"")
    end

    if !isempty(parts)
        decl *= "($(join(parts, ", ")))"
    end

    return decl
end

function format_species_declaration(species::Species)
    # Initial values are set during system configuration, not here.
    # Reservoir species (constant=true) are emitted as @parameters with
    # isconstantspecies=true metadata elsewhere, so they should not reach
    # this formatter.
    return string(species.name)
end

function format_equation(equation::Equation)
    lhs = format_expression(equation.lhs)
    rhs = format_expression(equation.rhs)
    return "$lhs ~ $rhs"
end

# Render one side (substrates or products) of a reaction from the ordered
# StoichiometryEntry vector (accessed via getfield to bypass the
# backward-compat Dict property shim, whose iteration order is nondeterministic).
function _format_reaction_side(entries::Union{Vector{StoichiometryEntry},Nothing})
    if entries === nothing || isempty(entries)
        return "∅"
    end
    return join(["$(entry.stoichiometry != 1 ? "$(entry.stoichiometry)*" : "")$(entry.species)"
                 for entry in entries], " + ")
end

function format_reaction(reaction::Reaction)
    rate = isnothing(reaction.rate) ? "1.0" : format_expression(reaction.rate)

    reactants = _format_reaction_side(getfield(reaction, :substrates))
    products = _format_reaction_side(getfield(reaction, :products))

    return "Reaction($rate, [$reactants], [$products])"
end

# ---------------------------------------------------------------------------
# Precedence-aware parenthesization for emitted code
#
# Adapted from display.jl's `get_operator_precedence` / `needs_parentheses`,
# but per target language: generated code is *executed*, not just read, so the
# tables must match each language's parser. In particular the Python emitter
# renders `and`/`or` as bitwise `&`/`|`, which bind *tighter* than comparisons
# in Python — the opposite of Julia's `&&`/`||`.
# ---------------------------------------------------------------------------

# Julia surface syntax: ||, && loosest; ^ tightest and right-associative.
const _JULIA_CODEGEN_PRECEDENCE = Dict{String,Int}(
    "or" => 1, "and" => 2,
    "==" => 3, "!=" => 3, "<" => 3, ">" => 3, "<=" => 3, ">=" => 3,
    "+" => 4, "-" => 4,
    "*" => 5, "/" => 5,
    "^" => 7,
)

# Python surface syntax for the SymPy emitter: comparisons bind looser than
# `|`/`&`; `**` is right-associative.
const _PYTHON_CODEGEN_PRECEDENCE = Dict{String,Int}(
    "==" => 1, "!=" => 1, "<" => 1, ">" => 1, "<=" => 1, ">=" => 1,
    "or" => 2,   # emitted as |
    "and" => 3,  # emitted as &
    "+" => 4, "-" => 4,
    "*" => 5, "/" => 5,
    "^" => 7,    # emitted as **
)

# Function calls / atoms: effectively infinite precedence, never parenthesized.
const _CODEGEN_FUNCTION_PRECEDENCE = 8

_codegen_precedence(table::Dict{String,Int}, op::String) =
    get(table, op, _CODEGEN_FUNCTION_PRECEDENCE)

# Should `child`, rendered as an operand of infix `parent_op`, be parenthesized?
function _codegen_needs_parens(table::Dict{String,Int}, parent_op::String,
                               child::Expr, is_right::Bool)
    child isa OpExpr || return false
    parent_prec = _codegen_precedence(table, parent_op)
    # Function-call parents wrap their args in (...) already.
    parent_prec == _CODEGEN_FUNCTION_PRECEDENCE && return false
    child_prec = _codegen_precedence(table, child.op)
    child_prec < parent_prec && return true
    child_prec > parent_prec && return false
    # Equal precedence:
    parent_op in ("-", "/") && return is_right   # left-associative, non-commutative
    parent_op == "^" && return !is_right         # right-associative (Julia ^, Python **)
    # Chained comparisons mean something different in both languages — wrap.
    parent_op in ("==", "!=", "<", ">", "<=", ">=") && return true
    return false
end

# Render the operand of a unary minus, parenthesizing children that bind
# looser than multiplication (so `-(a + b)` never degrades to `-a + b`).
function _format_unary_minus_operand(arg::Expr, table::Dict{String,Int}, fmt::Function)
    inner = fmt(arg)
    if arg isa OpExpr && _codegen_precedence(table, arg.op) <= table["+"]
        return "($inner)"
    end
    return inner
end

function format_expression(expr::Expr)
    if isa(expr, IntExpr)
        return string(expr.value)
    elseif isa(expr, NumExpr)
        return string(expr.value)
    elseif isa(expr, VarExpr)
        return expr.name
    elseif isa(expr, OpExpr)
        return format_expression_node(expr)
    else
        error("Unsupported expression type: $(typeof(expr))")
    end
end

function format_expression_node(node::OpExpr)
    op = node.op
    args = node.args

    # Format one operand with precedence-aware parenthesization. In n-ary
    # chains (`a - b - c`), every operand after the first is a right operand.
    fmt(arg, is_right::Bool=false) = begin
        s = format_expression(arg)
        _codegen_needs_parens(_JULIA_CODEGEN_PRECEDENCE, op, arg, is_right) ? "($s)" : s
    end
    fmt_chain(sep) = join([fmt(args[1]); [fmt(a, true) for a in args[2:end]]], sep)

    # Apply expression mappings for Julia
    if op == "+"
        return fmt_chain(" + ")
    elseif op == "*"
        return fmt_chain(" * ")
    elseif op == "D"
        # D(x,t) → D(x) (remove time parameter)
        if length(args) >= 1
            return "D($(format_expression(args[1])))"
        end
        return "D()"
    elseif op == "exp"
        return "exp($(join(map(format_expression, args), ", ")))"
    elseif op == "ifelse"
        return "ifelse($(join(map(format_expression, args), ", ")))"
    elseif op == "Pre"
        return "Pre($(join(map(format_expression, args), ", ")))"
    elseif op == "^"
        return fmt_chain(" ^ ")
    elseif op == "grad"
        # grad(x,y) → Differential(y)(x)
        if length(args) >= 2
            return "Differential($(format_expression(args[2])))($(format_expression(args[1])))"
        elseif length(args) == 1
            return "Differential(x)($(format_expression(args[1])))"
        end
        return "Differential(x)()"
    elseif op == "-"
        if length(args) == 1
            return "-$(_format_unary_minus_operand(args[1], _JULIA_CODEGEN_PRECEDENCE, format_expression))"
        else
            return fmt_chain(" - ")
        end
    elseif op == "/"
        return fmt_chain(" / ")
    elseif op in ["<", ">", "<=", ">=", "==", "!="]
        return fmt_chain(" $op ")
    elseif op == "and"
        return fmt_chain(" && ")
    elseif op == "or"
        return fmt_chain(" || ")
    elseif op == "not"
        return "!($(format_expression(args[1])))"
    else
        # For other operators, use function call syntax
        return "$op($(join(map(format_expression, args), ", ")))"
    end
end

"""
    extract_parameter_names(expr::Expr, species_names::Set{String}) -> Set{String}

Rate-expression symbols that should be emitted as `@parameters`: every free
variable of `expr` that is not a declared species. Resolving against the
declared species list (rather than guessing from naming conventions) means
single-letter species are never re-declared as parameters, while declared
parameters and undeclared symbols alike still get a `@parameters` entry so
the generated script defines them.
"""
function extract_parameter_names(expr::Expr, species_names::Set{String})
    return Set{String}(name for name in free_variables(expr) if !(name in species_names))
end

# Helper functions for Python code generation

function generate_python_model_code(name::String, model::Model)
    lines = String[]

    push!(lines, "# Model: $name")

    # Collect state variables and parameters
    state_vars = Tuple{String, ModelVariable}[]
    parameters = Tuple{String, ModelVariable}[]

    if !isnothing(model.variables) && !isempty(model.variables)
        for (var_name, variable) in model.variables
            if variable.type == StateVariable
                push!(state_vars, (var_name, variable))
            elseif variable.type == ParameterVariable
                push!(parameters, (var_name, variable))
            end
        end
    end

    # Generate time symbol if needed
    has_derivatives = !isnothing(model.equations) &&
        any(eq -> has_derivative_in_expression(eq.lhs) || has_derivative_in_expression(eq.rhs),
            model.equations)

    if has_derivatives
        push!(lines, "# Time variable")
        push!(lines, "t = sp.Symbol('t')")
        push!(lines, "")
    end

    # Generate symbol/function definitions
    if !isempty(state_vars)
        push!(lines, "# State variables")
        for (var_name, variable) in state_vars
            comment = isnothing(variable.units) ? "" : "  # $(variable.units)"
            if has_derivatives
                push!(lines, "$var_name = sp.Function('$var_name')$comment")
            else
                push!(lines, "$var_name = sp.Symbol('$var_name')$comment")
            end
        end
        push!(lines, "")
    end

    if !isempty(parameters)
        push!(lines, "# Parameters")
        for (param_name, parameter) in parameters
            comment = isnothing(parameter.units) ? "" : "  # $(parameter.units)"
            push!(lines, "$param_name = sp.Symbol('$param_name')$comment")
        end
        push!(lines, "")
    end

    # Generate equations
    if !isnothing(model.equations) && !isempty(model.equations)
        push!(lines, "# Equations")
        for (i, equation) in enumerate(model.equations)
            lhs = format_python_expression(equation.lhs)
            rhs = format_python_expression(equation.rhs)
            push!(lines, "eq$i = sp.Eq($lhs, $rhs)")
        end
    end

    return lines
end

function generate_python_reaction_system_code(name::String, reaction_system::ReactionSystem)
    lines = String[]

    push!(lines, "# Reaction System: $name")

    # Generate species symbols
    if !isnothing(reaction_system.species) && !isempty(reaction_system.species)
        push!(lines, "# Species")
        for species in reaction_system.species
            push!(lines, "$(species.name) = sp.Symbol('$(species.name)')")
        end
        push!(lines, "")
    end

    # Generate reaction rate expressions
    if !isnothing(reaction_system.reactions) && !isempty(reaction_system.reactions)
        push!(lines, "# Rate expressions")
        for (i, reaction) in enumerate(reaction_system.reactions)
            if !isnothing(reaction.rate)
                rate_expr = format_python_expression(reaction.rate)
                push!(lines, "reaction_$(i)_rate = $rate_expr")
            end
        end
        push!(lines, "")

        push!(lines, "# Stoichiometry")
        for (i, reaction) in enumerate(reaction_system.reactions)
            push!(lines, "# Reaction $i:")
            substrates = getfield(reaction, :substrates)
            if !isnothing(substrates) && !isempty(substrates)
                reactant_str = join(["$(entry.stoichiometry != 1 ? "$(entry.stoichiometry)*" : "")$(entry.species)"
                                     for entry in substrates], " + ")
                push!(lines, "#   Reactants: $reactant_str")
            end
            products = getfield(reaction, :products)
            if !isnothing(products) && !isempty(products)
                product_str = join(["$(entry.stoichiometry != 1 ? "$(entry.stoichiometry)*" : "")$(entry.species)"
                                    for entry in products], " + ")
                push!(lines, "#   Products: $product_str")
            end
        end
    end

    return lines
end

function format_python_expression(expr::Expr)
    if isa(expr, IntExpr)
        return string(expr.value)
    elseif isa(expr, NumExpr)
        return string(expr.value)
    elseif isa(expr, VarExpr)
        return expr.name
    elseif isa(expr, OpExpr)
        return format_python_expression_node(expr)
    else
        error("Unsupported expression type: $(typeof(expr))")
    end
end

function format_python_expression_node(node::OpExpr)
    op = node.op
    args = node.args

    # Format one operand with precedence-aware parenthesization (Python table).
    fmt(arg, is_right::Bool=false) = begin
        s = format_python_expression(arg)
        _codegen_needs_parens(_PYTHON_CODEGEN_PRECEDENCE, op, arg, is_right) ? "($s)" : s
    end
    fmt_chain(sep) = join([fmt(args[1]); [fmt(a, true) for a in args[2:end]]], sep)

    # Apply expression mappings for Python
    if op == "+"
        return fmt_chain(" + ")
    elseif op == "*"
        return fmt_chain(" * ")
    elseif op == "D"
        # D(x,t) → Derivative(x(t), t)
        if length(args) >= 1
            var_name = format_python_expression(args[1])
            return "sp.Derivative($(var_name)(t), t)"
        end
        return "sp.Derivative()"
    elseif op == "exp"
        return "sp.exp($(join(map(format_python_expression, args), ", ")))"
    elseif op == "ifelse"
        # ifelse(condition, true_val, false_val) → sp.Piecewise((true_val, condition), (false_val, True))
        if length(args) >= 3
            condition = format_python_expression(args[1])
            true_val = format_python_expression(args[2])
            false_val = format_python_expression(args[3])
            return "sp.Piecewise(($true_val, $condition), ($false_val, True))"
        end
        return "sp.Piecewise((0, True))"
    elseif op == "Pre"
        return "Function('Pre')($(join(map(format_python_expression, args), ", ")))"
    elseif op == "^"
        return fmt_chain(" ** ")
    elseif op == "grad"
        # grad(x,y) → sp.Derivative(x, y)
        if length(args) >= 2
            func = format_python_expression(args[1])
            var = format_python_expression(args[2])
            return "sp.Derivative($func, $var)"
        elseif length(args) == 1
            return "sp.Derivative($(format_python_expression(args[1])), x)"
        end
        return "sp.Derivative()"
    elseif op == "-"
        if length(args) == 1
            return "-$(_format_unary_minus_operand(args[1], _PYTHON_CODEGEN_PRECEDENCE, format_python_expression))"
        else
            return fmt_chain(" - ")
        end
    elseif op == "/"
        return fmt_chain(" / ")
    elseif op in ["<", ">", "<=", ">=", "==", "!="]
        return fmt_chain(" $op ")
    elseif op == "and"
        return fmt_chain(" & ")
    elseif op == "or"
        return fmt_chain(" | ")
    elseif op == "not"
        return "~($(format_python_expression(args[1])))"
    else
        # For other operators, use function call syntax
        return "$op($(join(map(format_python_expression, args), ", ")))"
    end
end

function has_derivative_in_expression(expr::Expr)
    if isa(expr, OpExpr) && expr.op == "D"
        return true
    elseif isa(expr, OpExpr)
        return any(has_derivative_in_expression, expr.args)
    end
    return false
end
