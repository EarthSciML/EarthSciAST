"""
Code generation for the ESM format

This module generates a self-contained, *illustrative* Julia script from an
ESM file (compatible with ModelingToolkit, Catalyst, EarthSciMLBase, and
OrdinaryDiffEq).
"""

"""
    _generate_script(file::EsmFile; language, imports, model_emitter,
                     reaction_system_emitter, emit_data_loaders=false)

Script driver behind [`to_julia_code`](@ref): header → imports → models →
reaction systems → coupling → domain → data loaders. The language-specific
pieces (imports, per-model / per-reaction-system emitters) are passed
explicitly so the skeleton lives in one place.

Note: events are handled within individual models, not at the file level.
Coupling, domain, and data-loader sections are comment-only placeholders
(their codegen is not yet implemented).
"""
function _generate_script(file::EsmFile;
                          language::String,
                          imports::Vector{String},
                          model_emitter::Function,
                          reaction_system_emitter::Function,
                          emit_data_loaders::Bool=false)
    lines = String[]

    # Header comment
    push!(lines, "# Generated $language script from ESM file")
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
    append!(lines, imports)
    push!(lines, "")

    # Generate models
    if !isnothing(file.models) && !isempty(file.models)
        push!(lines, "# Models")
        for (name, model) in file.models
            append!(lines, model_emitter(name, model))
            push!(lines, "")
        end
    end

    # Generate reaction systems
    if !isnothing(file.reaction_systems) && !isempty(file.reaction_systems)
        push!(lines, "# Reaction Systems")
        for (name, reaction_system) in file.reaction_systems
            append!(lines, reaction_system_emitter(name, reaction_system))
            push!(lines, "")
        end
    end

    # Generate coupling placeholders (codegen not yet implemented)
    if !isnothing(file.coupling) && !isempty(file.coupling)
        push!(lines, "# Coupling")
        for coupling in file.coupling
            append!(lines, generate_coupling_placeholder(coupling))
        end
        push!(lines, "")
    end

    # Generate domain placeholder (codegen not yet implemented)
    if !isnothing(file.domain)
        push!(lines, "# Domain")
        append!(lines, generate_domain_placeholder(file.domain))
        push!(lines, "")
    end

    # Generate data loader placeholders (codegen not yet implemented)
    if emit_data_loaders && !isnothing(file.data_loaders) && !isempty(file.data_loaders)
        push!(lines, "# Data Loaders")
        for (name, data_loader) in file.data_loaders
            append!(lines, generate_data_loader_placeholder(name, data_loader))
        end
        push!(lines, "")
    end

    return join(lines, "\n")
end

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
    return _generate_script(file;
        language = "Julia",
        imports = [
            "using ModelingToolkit",
            "using Catalyst",
            "using EarthSciMLBase",
            "using OrdinaryDiffEq",
            "using Unitful",
        ],
        model_emitter = generate_model_code,
        reaction_system_emitter = generate_reaction_system_code,
        emit_data_loaders = true)
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
            elseif variable.type == ParameterVariable || variable.type == DiscreteVariable
                # A discrete variable is a refresh-fed buffer the solver never
                # differentiates — it emits as an MTK parameter (`@parameters`),
                # written by the cadence/loader refresh callback.
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
    generate_coupling_placeholder(coupling::CouplingEntry)

Emit comment-only placeholder lines describing a coupling entry, with
Julia-specific implementation notes (coupling codegen is not yet implemented).
"""
function generate_coupling_placeholder(coupling::CouplingEntry)
    lines = String[]
    if coupling isa CouplingOperatorCompose
        push!(lines, "# Coupling (operator_compose): compose systems $(join(coupling.systems, ", "))")
        push!(lines, "#   Needs: ConnectorSystem to match LHS time derivatives and add RHS terms")
    elseif coupling isa CouplingCouple
        push!(lines, "# Coupling (couple): bidirectional coupling of $(join(coupling.systems, ", "))")
        push!(lines, "#   Needs: connector equations via compose()")
    elseif coupling isa CouplingVariableMap
        push!(lines, "# Coupling (variable_map): $(coupling.from) → $(coupling.to) via $(coupling.transform)")
        if !isnothing(coupling.factor)
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
    generate_domain_placeholder(domain::Domain)

Emit comment-only placeholder lines describing the domain (domain codegen is
not yet implemented). The comment syntax is identical in Julia and Python, so
one generator serves both emitters. v0.8.0 has a single shared top-level
`domain` (not a map of named domains), so the heading is fixed.
"""
function generate_domain_placeholder(domain::Domain)
    lines = String[]
    push!(lines, "# Domain: domain")
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
    lhs = format_julia_expression(equation.lhs)
    rhs = format_julia_expression(equation.rhs)
    return "$lhs ~ $rhs"
end

# Render one side (substrates or products) of a reaction from the ordered
# StoichiometryEntry vector (see raw_substrates/raw_products — the
# backward-compat Dict property shim loses author order). Thin wrapper over
# display.jl's shared `_format_stoichiometry_side` with code-emitter
# formatting: bare species names, `<coeff>*` prefixes, ∅ for empty sides.
_format_reaction_side(entries::Union{Vector{StoichiometryEntry},Nothing}) =
    _format_stoichiometry_side(entries; format_coefficient = c -> "$(c)*")

function format_reaction(reaction::Reaction)
    rate = isnothing(reaction.rate) ? "1.0" : format_julia_expression(reaction.rate)

    reactants = _format_reaction_side(raw_substrates(reaction))
    products = _format_reaction_side(raw_products(reaction))

    return "Reaction($rate, [$reactants], [$products])"
end

# ---------------------------------------------------------------------------
# Precedence-aware parenthesization for emitted Julia code
#
# Adapted from display.jl's `get_operator_precedence` / `needs_parentheses`,
# but tuned for CODE that is *executed*, not just read: the table must match
# Julia's parser so the emitted script re-parses to the same AST.
# ---------------------------------------------------------------------------

# Julia surface syntax: ||, && loosest; ^ tightest and right-associative.
const _JULIA_CODEGEN_PRECEDENCE = Dict{String,Int}(
    "or" => 1, "and" => 2,
    "==" => 3, "!=" => 3, "<" => 3, ">" => 3, "<=" => 3, ">=" => 3,
    "+" => 4, "-" => 4,
    "*" => 5, "/" => 5,
    "^" => 7,
)

# Function calls / atoms: effectively infinite precedence, never parenthesized.
const _CODEGEN_FUNCTION_PRECEDENCE = 8

_codegen_precedence(table::Dict{String,Int}, op::String) =
    get(table, op, _CODEGEN_FUNCTION_PRECEDENCE)

# Should `child`, rendered as an operand of infix `parent_op`, be parenthesized?
function _codegen_needs_parens(table::Dict{String,Int}, parent_op::String,
                               child::ASTExpr, is_right::Bool)
    child isa OpExpr || return false
    parent_prec = _codegen_precedence(table, parent_op)
    # Function-call parents wrap their args in (...) already.
    parent_prec == _CODEGEN_FUNCTION_PRECEDENCE && return false
    child_prec = _codegen_precedence(table, child.op)
    child_prec < parent_prec && return true
    child_prec > parent_prec && return false
    # Equal precedence:
    parent_op in ("-", "/") && return is_right   # left-associative, non-commutative
    # `^` right-associative: parenthesize the LEFT operand. NOTE deliberate
    # divergence from display.jl `needs_parentheses`, which parenthesizes the
    # RIGHT operand of `^` — that rule is frozen by the cross-language
    # pretty-printer contract (pretty-print.ts, pinned by the tests/display
    # fixtures). Emitted code must instead re-parse correctly in Julia, so the
    # emitter wraps the left. Do not reconcile.
    parent_op == "^" && return !is_right
    # Chained comparisons mean something different in Julia — wrap.
    parent_op in ("==", "!=", "<", ">", "<=", ">=") && return true
    return false
end

# Render the operand of a unary minus, parenthesizing children that bind
# looser than multiplication (so `-(a + b)` never degrades to `-a + b`).
function _format_unary_minus_operand(arg::ASTExpr, table::Dict{String,Int}, fmt::Function)
    inner = fmt(arg)
    if arg isa OpExpr && _codegen_precedence(table, arg.op) <= table["+"]
        return "($inner)"
    end
    return inner
end

# Julia-source emitter. Named `format_julia_expression` (not the bare
# `format_expression`) so it cannot be confused with display.jl's same-named
# pretty-printer, whose 2-arg method renders notation rather than executable
# code.
function format_julia_expression(expr::ASTExpr)
    if isa(expr, IntExpr)
        return string(expr.value)
    elseif isa(expr, NumExpr)
        return string(expr.value)
    elseif isa(expr, VarExpr)
        return expr.name
    elseif isa(expr, OpExpr)
        return format_julia_expression_node(expr)
    else
        throw(ArgumentError("Unsupported expression type: $(typeof(expr))"))
    end
end

function format_julia_expression_node(node::OpExpr)
    op = node.op
    args = node.args

    # Format one operand with precedence-aware parenthesization. In n-ary
    # chains (`a - b - c`), every operand after the first is a right operand.
    fmt(arg, is_right::Bool=false) = begin
        s = format_julia_expression(arg)
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
            return "D($(format_julia_expression(args[1])))"
        end
        return "D()"
    elseif op == "exp"
        return "exp($(join(map(format_julia_expression, args), ", ")))"
    elseif op == "ifelse"
        return "ifelse($(join(map(format_julia_expression, args), ", ")))"
    elseif op == "Pre"
        return "Pre($(join(map(format_julia_expression, args), ", ")))"
    elseif op == "^"
        return fmt_chain(" ^ ")
    elseif op == "grad"
        # grad(x,y) → Differential(y)(x)
        if length(args) >= 2
            return "Differential($(format_julia_expression(args[2])))($(format_julia_expression(args[1])))"
        elseif length(args) == 1
            return "Differential(x)($(format_julia_expression(args[1])))"
        end
        return "Differential(x)()"
    elseif op == "-"
        if length(args) == 1
            return "-$(_format_unary_minus_operand(args[1], _JULIA_CODEGEN_PRECEDENCE, format_julia_expression))"
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
        return "!($(format_julia_expression(args[1])))"
    else
        # For other operators, use function call syntax
        return "$op($(join(map(format_julia_expression, args), ", ")))"
    end
end

"""
    extract_parameter_names(expr::ASTExpr, species_names::Set{String}) -> Set{String}

Rate-expression symbols that should be emitted as `@parameters`: every free
variable of `expr` that is not a declared species. Resolving against the
declared species list (rather than guessing from naming conventions) means
single-letter species are never re-declared as parameters, while declared
parameters and undeclared symbols alike still get a `@parameters` entry so
the generated script defines them.
"""
function extract_parameter_names(expr::ASTExpr, species_names::Set{String})
    return Set{String}(name for name in free_variables(expr) if !(name in species_names))
end

