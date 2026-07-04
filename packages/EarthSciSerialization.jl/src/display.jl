"""
Pretty-printing formatters for ESM format expressions, equations, models, and files.

Implements display methods for various ESM format types:
- Base.show(io::IO, ::MIME"text/plain", expr::Expr): Unicode display with chemical subscripts
- Base.show(io::IO, ::MIME"text/latex", expr::Expr): LaTeX mathematical notation
- Base.show(io::IO, ::MIME"text/ascii", expr::Expr): Plain ASCII mathematical notation
- Base.show(io::IO, model::Model): Model summary display
- Base.show(io::IO, esm_file::EsmFile): Structured ESM file summary per spec Section 6.3
- Base.show(io::IO, reaction_system::ReactionSystem): Chemical reaction notation

Based on ESM Format Specification Section 6.1 algorithms.
"""

# Element lookup table for chemical subscript detection (118 elements)
const ELEMENTS = Set([
    # Period 1
    "H", "He",
    # Period 2
    "Li", "Be", "B", "C", "N", "O", "F", "Ne",
    # Period 3
    "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
    # Period 4
    "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr",
    # Period 5
    "Rb", "Sr", "Y", "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn", "Sb", "Te", "I", "Xe",
    # Period 6
    "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb", "Lu",
    "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb", "Bi", "Po", "At", "Rn",
    # Period 7
    "Fr", "Ra", "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr",
    "Rf", "Db", "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og"
])

# Unicode subscripts for digits 0-9
const SUBSCRIPT_MAP = Dict(
    '0' => '₀', '1' => '₁', '2' => '₂', '3' => '₃', '4' => '₄',
    '5' => '₅', '6' => '₆', '7' => '₇', '8' => '₈', '9' => '₉'
)

# Unicode superscripts for digits 0-9 and signs
const SUPERSCRIPT_MAP = Dict(
    '0' => '⁰', '1' => '¹', '2' => '²', '3' => '³', '4' => '⁴',
    '5' => '⁵', '6' => '⁶', '7' => '⁷', '8' => '⁸', '9' => '⁹',
    '+' => '⁺', '-' => '⁻'
)

"""
    to_superscript(text::String) -> String

Convert text to Unicode superscript representation.
"""
function to_superscript(text::String)
    return join([get(SUPERSCRIPT_MAP, c, c) for c in text])
end

"""
    has_element_pattern(variable::String) -> Bool

Check if a variable has element patterns (for chemical formula detection).
Uses greedy matching algorithm per spec Section 6.1.
"""
function has_element_pattern(variable::String)
    i = 1
    has_element = false

    while i <= length(variable)
        # Skip non-alphabetic characters at the start
        while i <= length(variable) && !isletter(variable[i])
            i += 1
        end

        if i > length(variable)
            break
        end

        # Try 2-character element first (greedy matching)
        if i + 1 <= length(variable)
            two_char = variable[i:i+1]
            if two_char in ELEMENTS
                has_element = true
                i += 2
                # Skip digits
                while i <= length(variable) && isdigit(variable[i])
                    i += 1
                end
                continue
            end
        end

        # Try 1-character element
        one_char = string(variable[i])
        if one_char in ELEMENTS
            has_element = true
            i += 1
            # Skip digits
            while i <= length(variable) && isdigit(variable[i])
                i += 1
            end
            continue
        end

        # Not an element, move to next character
        i += 1
    end

    return has_element
end

"""
    format_chemical_subscripts(variable::String, format::Symbol) -> String

Apply element-aware chemical subscript formatting to a variable name.
Uses greedy 2-char-before-1-char matching for element detection per spec Section 6.1.

# Arguments
- `variable::String`: Variable name to format
- `format::Symbol`: Output format (:unicode or :latex)
"""
function format_chemical_subscripts(variable::String, format::Symbol)
    if format == :latex
        if has_element_pattern(variable)
            # Chemical formula: wrap in \\mathrm{} and convert digits to subscripts
            result = replace(variable, r"(\d+)" => s"_{\1}")
            return "\\mathrm{$result}"
        else
            # Regular variable: return as-is
            return variable
        end
    end

    if format == :ascii
        # For ASCII, just return as-is (no special formatting for chemical subscripts)
        return variable
    end

    if !has_element_pattern(variable)
        # No element pattern found, return as-is
        return variable
    end

    # For unicode: element-aware subscript detection
    result = ""
    i = 1

    while i <= length(variable)
        matched = false

        # Try 2-character element first (greedy matching)
        if i + 1 <= length(variable)
            two_char = variable[i:i+1]
            if two_char in ELEMENTS
                result *= two_char
                i += 2
                # Convert following digits to subscripts
                while i <= length(variable) && isdigit(variable[i])
                    result *= string(SUBSCRIPT_MAP[variable[i]])
                    i += 1
                end
                matched = true
            end
        end

        # Try 1-character element if 2-char didn't match
        if !matched && i <= length(variable)
            one_char = string(variable[i])
            if one_char in ELEMENTS
                result *= one_char
                i += 1
                # Convert following digits to subscripts
                while i <= length(variable) && isdigit(variable[i])
                    result *= string(SUBSCRIPT_MAP[variable[i]])
                    i += 1
                end
                matched = true
            end
        end

        # If not an element, copy character as-is
        if !matched
            result *= variable[i]
            i += 1
        end
    end

    return result
end

"""
    format_number(num::Real, format::Symbol) -> String

Format a number in scientific notation with appropriate formatting.
"""
function format_number(num::Real, format::Symbol)
    if isinteger(num) && abs(num) < 1e6
        return string(Int(num))
    end

    # Use standard scientific notation formatting without @sprintf
    str = string(num)
    if Base.contains(str, "e") || Base.contains(str, "E")
        # Already in scientific notation
        parts = split(lowercase(str), "e")
        mantissa = parts[1]
        exponent = parse(Int, parts[2])

        if format == :unicode
            return "$(mantissa)×10$(to_superscript(string(exponent)))"
        elseif format == :latex
            return "$(mantissa) \\times 10^{$(exponent)}"
        elseif format == :ascii
            return "$(mantissa)*10^$(exponent)"
        else
            return str # Plain scientific notation for fallback
        end
    else
        # For very large/small numbers, convert to scientific notation manually
        if abs(num) >= 1e6 || abs(num) < 1e-4
            log10_val = floor(log10(abs(num)))
            mantissa = num / (10.0^log10_val)
            exponent = Int(log10_val)

            if format == :unicode
                return "$(round(mantissa, digits=2))×10$(to_superscript(string(exponent)))"
            elseif format == :latex
                return "$(round(mantissa, digits=2)) \\times 10^{$(exponent)}"
            elseif format == :ascii
                return "$(round(mantissa, digits=2))*10^$(exponent)"
            else
                return "$(round(mantissa, digits=2))e$(exponent)"
            end
        else
            return string(num)
        end
    end
end

"""
    get_operator_precedence(op::String) -> Int

Get operator precedence for proper parenthesization.
"""
function get_operator_precedence(op::String)
    op_precedence = Dict(
        "or" => 1,
        "and" => 2,
        "==" => 3, "!=" => 3, "<" => 3, ">" => 3, "<=" => 3, ">=" => 3,
        "+" => 4, "-" => 4,
        "*" => 5, "/" => 5,
        "not" => 6,  # Unary
        "^" => 7
    )

    return get(op_precedence, op, 8)  # Functions get highest precedence
end

"""
    needs_parentheses(parent_op::String, child::Expr, is_right_operand::Bool=false) -> Bool

Check if parentheses are needed around a subexpression.
"""
function needs_parentheses(parent_op::String, child::Expr, is_right_operand::Bool=false)
    if isa(child, NumExpr) || isa(child, IntExpr) || isa(child, VarExpr)
        return false
    end

    if !isa(child, OpExpr)
        return false
    end

    parent_prec = get_operator_precedence(parent_op)
    child_prec = get_operator_precedence(child.op)

    if child_prec < parent_prec
        return true
    end
    if child_prec > parent_prec
        return false
    end

    # Same precedence: need parens if child is right operand and operator is not associative
    if is_right_operand && parent_op in ["-", "/", "^"]
        return true
    end

    # Special cases for function arguments - no parens needed for simple expressions
    if parent_op in ["sin", "cos", "tan", "exp", "log", "sqrt", "abs"]
        # Only parenthesize for very low precedence operators
        return child_prec <= 2
    end

    return false
end

"""
    Base.show(io::IO, ::MIME"text/plain", expr::Expr)

Unicode display: chemical subscripts via element-aware tokenizer, ∂x/∂t derivatives,
· for multiplication, − for unary minus, scientific notation with Unicode superscripts.
"""
function Base.show(io::IO, ::MIME"text/plain", expr::Expr)
    print(io, format_expression_unicode(expr))
end

"""
    Base.show(io::IO, ::MIME"text/latex", expr::Expr)

LaTeX display: \\frac{}{}, \\partial, \\mathrm{} for species.
"""
function Base.show(io::IO, ::MIME"text/latex", expr::Expr)
    print(io, format_expression_latex(expr))
end

"""
    Base.show(io::IO, ::MIME"text/ascii", expr::Expr)

ASCII display: plain ASCII mathematical notation with standard operators (*, /, ^).
"""
function Base.show(io::IO, ::MIME"text/ascii", expr::Expr)
    print(io, format_expression_ascii(expr))
end

"""
    format_expression(expr::Expr, format::Symbol) -> String

Format an expression in the given notation (`:unicode`, `:latex`, or `:ascii`).
"""
function format_expression(expr::Expr, format::Symbol)
    format in (:unicode, :latex, :ascii) ||
        throw(ArgumentError("Unsupported format: $format"))

    if isa(expr, NumExpr)
        return format_number(expr.value, format)
    end

    if isa(expr, IntExpr)
        return string(expr.value)
    end

    if isa(expr, VarExpr)
        return format_chemical_subscripts(expr.name, format)
    end

    if isa(expr, OpExpr)
        return format_operator_expression(expr, format)
    end

    throw(ArgumentError("Unsupported expression type: $(typeof(expr))"))
end

"""
    format_expression_unicode(expr::Expr) -> String

Format an expression as Unicode mathematical notation.
"""
format_expression_unicode(expr::Expr) = format_expression(expr, :unicode)

"""
    format_expression_latex(expr::Expr) -> String

Format an expression as LaTeX mathematical notation.
"""
format_expression_latex(expr::Expr) = format_expression(expr, :latex)

"""
    format_expression_ascii(expr::Expr) -> String

Format an expression as plain ASCII mathematical notation.
"""
format_expression_ascii(expr::Expr) = format_expression(expr, :ascii)

"""
    format_operator_expression(node::OpExpr, format::Symbol) -> String

Format an OpExpr (operator with arguments).
"""
function format_operator_expression(node::OpExpr, format::Symbol)
    op = node.op
    args = node.args
    wrt = node.wrt

    # Helper to format arguments with proper parenthesization
    format_arg = function(arg, is_right_operand=false)
        result = format_expression(arg, format)

        if needs_parentheses(op, arg, is_right_operand)
            if format == :latex
                return "\\left($result\\right)"
            else
                return "($result)"
            end
        end
        return result
    end

    # Binary operators
    if length(args) == 2
        left, right = args

        if op == "+"
            return "$(format_arg(left)) + $(format_arg(right, true))"
        elseif op == "-"
            if format == :unicode
                return "$(format_arg(left)) − $(format_arg(right, true))"
            else
                return "$(format_arg(left)) - $(format_arg(right, true))"
            end
        elseif op == "*"
            if format == :unicode
                return "$(format_arg(left))·$(format_arg(right, true))"
            elseif format == :latex
                return "$(format_arg(left)) \\cdot $(format_arg(right, true))"
            elseif format == :ascii
                return "$(format_arg(left))*$(format_arg(right, true))"
            else
                return "$(format_arg(left)) * $(format_arg(right, true))"
            end
        elseif op == "/"
            if format == :latex
                return "\\frac{$(format_expression_latex(left))}{$(format_expression_latex(right))}"
            elseif format == :ascii
                return "$(format_arg(left))/$(format_arg(right, true))"
            else
                return "$(format_arg(left))/$(format_arg(right, true))"
            end
        elseif op == "^"
            if format == :latex
                return "$(format_arg(left))^{$(format_expression_latex(right))}"
            elseif format == :unicode && isa(right, IntExpr)
                return "$(format_arg(left))$(to_superscript(string(right.value)))"
            elseif format == :unicode && isa(right, NumExpr) && isinteger(right.value)
                return "$(format_arg(left))$(to_superscript(string(Int(right.value))))"
            elseif format == :ascii
                return "$(format_arg(left))^$(format_arg(right, true))"
            else
                return "$(format_arg(left))^$(format_arg(right, true))"
            end
        elseif op in [">", "<"]
            return "$(format_arg(left)) $op $(format_arg(right, true))"
        elseif op == ">="
            if format == :unicode
                return "$(format_arg(left)) ≥ $(format_arg(right, true))"
            else
                return "$(format_arg(left)) $op $(format_arg(right, true))"
            end
        elseif op == "<="
            if format == :unicode
                return "$(format_arg(left)) ≤ $(format_arg(right, true))"
            else
                return "$(format_arg(left)) $op $(format_arg(right, true))"
            end
        elseif op == "=="
            if format == :unicode
                return "$(format_arg(left)) = $(format_arg(right, true))"
            else
                return "$(format_arg(left)) $op $(format_arg(right, true))"
            end
        elseif op == "!="
            if format == :unicode
                return "$(format_arg(left)) ≠ $(format_arg(right, true))"
            else
                return "$(format_arg(left)) $op $(format_arg(right, true))"
            end
        elseif op == "and"
            if format == :unicode
                return "$(format_arg(left)) ∧ $(format_arg(right, true))"
            else
                return "$(format_arg(left)) and $(format_arg(right, true))"
            end
        elseif op == "or"
            if format == :unicode
                return "$(format_arg(left)) ∨ $(format_arg(right, true))"
            else
                return "$(format_arg(left)) or $(format_arg(right, true))"
            end
        end
    end

    # Unary operators
    if length(args) == 1
        arg = args[1]

        if op == "-"
            # Unary minus
            if format == :unicode
                return "−$(format_arg(arg))"
            else
                return "-$(format_arg(arg))"
            end
        elseif op == "not"
            if format == :unicode
                return "¬$(format_arg(arg))"
            else
                return "not $(format_arg(arg))"
            end
        elseif op in ["exp", "sin", "cos", "tan"]
            if format == :latex
                return "\\$op\\left($(format_expression_latex(arg))\\right)"
            else
                return "$op($(format_arg(arg)))"
            end
        elseif op == "log"
            if format == :unicode
                return "ln($(format_arg(arg)))"
            elseif format == :latex
                return "\\$op\\left($(format_expression_latex(arg))\\right)"
            elseif format == :ascii
                return "log($(format_arg(arg)))"
            else
                return "$op($(format_arg(arg)))"
            end
        elseif op == "log10"
            if format == :unicode
                return "log₁₀($(format_arg(arg)))"
            elseif format == :latex
                return "\\log_{10}\\left($(format_expression_latex(arg))\\right)"
            elseif format == :ascii
                return "log10($(format_arg(arg)))"
            else
                return "$op($(format_arg(arg)))"
            end
        elseif op == "sqrt"
            if format == :unicode
                return "√$(format_arg(arg))"
            elseif format == :latex
                return "\\sqrt{$(format_expression_latex(arg))}"
            elseif format == :ascii
                return "sqrt($(format_arg(arg)))"
            else
                return "$op($(format_arg(arg)))"
            end
        elseif op == "abs"
            if format == :unicode
                return "|$(format_arg(arg))|"
            elseif format == :latex
                return "|$(format_expression_latex(arg))|"
            elseif format == :ascii
                return "abs($(format_arg(arg)))"
            else
                return "$op($(format_arg(arg)))"
            end
        elseif op == "D"
            # Derivative operator
            wrt_var = isnothing(wrt) ? "t" : wrt
            if format == :unicode
                variable = format_expression_unicode(arg)
                return "∂$variable/∂$wrt_var"
            elseif format == :latex
                return "\\frac{\\partial $(format_expression_latex(arg))}{\\partial $wrt_var}"
            elseif format == :ascii
                return "d($(format_arg(arg)))/d$wrt_var"
            else
                return "D($(format_arg(arg)))/D$wrt_var"
            end
        end
    end

    # N-ary operators
    if length(args) >= 3
        if op == "+"
            # N-ary addition
            return join([format_arg(arg) for arg in args], " + ")
        elseif op == "*"
            # N-ary multiplication
            if format == :unicode
                sep = "·"
            elseif format == :latex
                sep = " \\cdot "
            else
                sep = "*"
            end
            return join([format_arg(arg) for arg in args], sep)
        elseif op == "or"
            # N-ary or
            if format == :unicode
                return join([format_arg(arg) for arg in args], " ∨ ")
            else
                return join([format_arg(arg) for arg in args], " or ")
            end
        elseif op == "max" || op == "min"
            # N-ary max / min (esm-spec §4.2)
            arg_list = join([format_expression(arg, format) for arg in args], ", ")

            if format == :latex
                return "\\$op($arg_list)"
            else
                return "$op($arg_list)"
            end
        end
    end

    # Binary min/max (≥ 2 args) — n-ary branch handles ≥ 3
    if length(args) == 2 && (op == "min" || op == "max")
        arg_list = join([format_expression(arg, format) for arg in args], ", ")
        if format == :latex
            return "\\$op($arg_list)"
        else
            return "$op($arg_list)"
        end
    end

    # Fallback: function call notation
    arg_list = join([format_expression(arg, format) for arg in args], ", ")

    if format == :latex
        return "\\text{$op}\\left($arg_list\\right)"
    else
        return "$op($arg_list)"
    end
end

"""
    Base.show(io::IO, equation::Equation)

Display equation in Unicode format.
"""
function Base.show(io::IO, equation::Equation)
    lhs_str = format_expression_unicode(equation.lhs)
    rhs_str = format_expression_unicode(equation.rhs)
    print(io, "$lhs_str = $rhs_str")
end

"""
    Base.show(io::IO, model::Model)

Model display: show(Model) prints equation list per spec Section 6.3.
"""
function Base.show(io::IO, model::Model)
    println(io, "Model:")
    println(io, "  Variables ($(length(model.variables))):")
    for (name, var) in model.variables
        var_type_str = var.type == StateVariable ? "state" :
                      var.type == ParameterVariable ? "parameter" : "observed"
        default_str = isnothing(var.default) ? "unset" : string(var.default)
        units_str = isnothing(var.units) ? "dimensionless" : var.units
        print(io, "    $name: $var_type_str")
        if !isnothing(var.default)
            print(io, " = $default_str")
        end
        if !isnothing(var.units)
            print(io, " [$units_str]")
        end
        if !isnothing(var.description)
            print(io, " - $(var.description)")
        end
        println(io)
        if !isnothing(var.expression)
            println(io, "      expression: $(format_expression_unicode(var.expression))")
        end
    end

    println(io, "  Equations ($(length(model.equations))):")
    for (i, eq) in enumerate(model.equations)
        println(io, "    $i. $(format_expression_unicode(eq.lhs)) = $(format_expression_unicode(eq.rhs))")
    end

    # Display discrete events
    if length(model.discrete_events) > 0
        println(io, "  Discrete Events ($(length(model.discrete_events))):")
        for (i, event) in enumerate(model.discrete_events)
            trigger_str = if isa(event.trigger, ConditionTrigger)
                "when $(format_expression_unicode(event.trigger.expression))"
            elseif isa(event.trigger, PeriodicTrigger)
                "every $(event.trigger.period)s"
            elseif isa(event.trigger, PresetTimesTrigger)
                "at times [$(join(event.trigger.times, ", "))]"
            else
                "$(typeof(event.trigger))"
            end
            affects_str = join(["$(affect.target) $(affect.operation) $(format_expression_unicode(affect.expression))" for affect in event.affects], ", ")
            println(io, "    $i. $trigger_str: $affects_str")
        end
    end

    # Display continuous events
    if length(model.continuous_events) > 0
        println(io, "  Continuous Events ($(length(model.continuous_events))):")
        for (i, event) in enumerate(model.continuous_events)
            conditions_str = join([format_expression_unicode(cond) for cond in event.conditions], ", ")
            affects_str = join(["$(affect.lhs) = $(format_expression_unicode(affect.rhs))" for affect in event.affects], ", ")
            println(io, "    $i. when [$conditions_str] → [$affects_str]")
        end
    end

    if length(model.subsystems) > 0
        println(io, "  Subsystems ($(length(model.subsystems))):")
        for (name, _) in model.subsystems
            println(io, "    $name")
        end
    end
end

"""
    Base.show(io::IO, esm_file::EsmFile)

EsmFile display: show(EsmFile) prints structured summary per spec Section 6.3.
"""
function Base.show(io::IO, esm_file::EsmFile)
    println(io, "ESM v$(esm_file.esm): $(esm_file.metadata.name)")

    if !isnothing(esm_file.metadata.description)
        println(io, "Description: $(esm_file.metadata.description)")
    end

    if !isempty(esm_file.metadata.authors)
        authors_str = join(esm_file.metadata.authors, ", ")
        println(io, "Authors: $authors_str")
    end

    if !isnothing(esm_file.metadata.license)
        println(io, "License: $(esm_file.metadata.license)")
    end

    if !isempty(esm_file.metadata.tags)
        tags_str = join(esm_file.metadata.tags, ", ")
        println(io, "Tags: $tags_str")
    end

    components = String[]
    if !isnothing(esm_file.models) && !isempty(esm_file.models)
        push!(components, "$(length(esm_file.models)) models")
    end
    if !isnothing(esm_file.reaction_systems) && !isempty(esm_file.reaction_systems)
        push!(components, "$(length(esm_file.reaction_systems)) reaction systems")
    end
    if !isnothing(esm_file.data_loaders) && !isempty(esm_file.data_loaders)
        push!(components, "$(length(esm_file.data_loaders)) data loaders")
    end
    if !isnothing(esm_file.operators) && !isempty(esm_file.operators)
        push!(components, "$(length(esm_file.operators)) operators")
    end

    if !isempty(components)
        println(io, "Components: $(join(components, ", "))")
    end

    if !isnothing(esm_file.domain)
        println(io, "Domain: configured")
    end
end

"""
    Base.show(io::IO, reaction_system::ReactionSystem)

ReactionSystem display: reactions in chemical notation.
"""
function Base.show(io::IO, reaction_system::ReactionSystem)
    println(io, "ReactionSystem:")
    println(io, "  Species ($(length(reaction_system.species))):")
    for species in reaction_system.species
        print(io, "    $(format_chemical_subscripts(species.name, :unicode))")
        if !isnothing(species.units)
            print(io, " (units: $(species.units))")
        end
        if !isnothing(species.default)
            print(io, " (default: $(species.default))")
        end
        if !isnothing(species.description)
            print(io, " - $(species.description)")
        end
        println(io)
    end

    println(io, "  Parameters ($(length(reaction_system.parameters))):")
    for param in reaction_system.parameters
        print(io, "    $(param.name) = $(param.default)")
        if !isnothing(param.units)
            print(io, " [$(param.units)]")
        end
        if !isnothing(param.description)
            print(io, " - $(param.description)")
        end
        println(io)
    end

    println(io, "  Reactions ($(length(reaction_system.reactions))):")
    for (i, reaction) in enumerate(reaction_system.reactions)
        # Format substrates
        reactants_str = if reaction.substrates === nothing || isempty(reaction.substrates)
            ""
        else
            join([
                if entry.stoichiometry == 1
                    format_chemical_subscripts(entry.species, :unicode)
                else
                    coeff_str = isinteger(entry.stoichiometry) ?
                        string(Int(entry.stoichiometry)) :
                        string(entry.stoichiometry)
                    "$(coeff_str)$(format_chemical_subscripts(entry.species, :unicode))"
                end
                for entry in reaction.substrates
            ], " + ")
        end

        # Format products
        products_str = if reaction.products === nothing || isempty(reaction.products)
            ""
        else
            join([
                if entry.stoichiometry == 1
                    format_chemical_subscripts(entry.species, :unicode)
                else
                    coeff_str = isinteger(entry.stoichiometry) ?
                        string(Int(entry.stoichiometry)) :
                        string(entry.stoichiometry)
                    "$(coeff_str)$(format_chemical_subscripts(entry.species, :unicode))"
                end
                for entry in reaction.products
            ], " + ")
        end

        # Arrow type (no reversible field in new schema)
        arrow = " → "

        # Rate expression
        rate_str = format_expression_unicode(reaction.rate)

        println(io, "    $i. $reactants_str$arrow$products_str  [k = $rate_str]")
    end

    if length(reaction_system.subsystems) > 0
        println(io, "  Subsystems ($(length(reaction_system.subsystems))):")
        for (name, _) in reaction_system.subsystems
            println(io, "    $name")
        end
    end
end

"""
    to_ascii(target) -> String

Format target as plain ASCII mathematical notation.

Provides plain ASCII output for expressions, equations, models, reaction systems,
and ESM files. Uses standard ASCII operators (*, /, ^) and function call notation
for mathematical functions.

# Arguments
- `target`: Expression, equation, model, reaction system, or ESM file to format

# Returns
- Plain ASCII string representation (no Unicode symbols)

# Examples
```julia
expr = OpExpr("*", [VarExpr("x"), NumExpr(2.0)])
to_ascii(expr)  # Returns "x*2"

eq = Equation(VarExpr("y"), OpExpr("+", [VarExpr("x"), NumExpr(1.0)]))
to_ascii(eq)   # Returns "y = x + 1"
```
"""
function to_ascii(target)
    if target === nothing
        return "nothing"
    end

    if isa(target, Real)
        return format_number(target, :ascii)
    end

    if isa(target, String)
        return format_chemical_subscripts(target, :ascii)
    end

    if isa(target, Expr)
        return format_expression_ascii(target)
    end

    if isa(target, Equation)
        lhs_str = format_expression_ascii(target.lhs)
        rhs_str = format_expression_ascii(target.rhs)
        return "$lhs_str = $rhs_str"
    end

    if isa(target, Model)
        # Simple ASCII summary for models
        return "Model($(length(target.variables)) variables, $(length(target.equations)) equations)"
    end

    if isa(target, ReactionSystem)
        # Simple ASCII summary for reaction systems
        return "ReactionSystem($(length(target.species)) species, $(length(target.reactions)) reactions)"
    end

    if isa(target, EsmFile)
        # Simple ASCII summary for ESM files
        return "ESM v$(target.esm): $(target.metadata.name)"
    end

    throw(ArgumentError("Unsupported type for ASCII formatting: $(typeof(target))"))
end