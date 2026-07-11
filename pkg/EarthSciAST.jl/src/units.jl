"""
Unit validation functionality using Unitful.jl.

This module provides dimensional analysis and unit validation for ESM format
expressions, equations, and models as specified in ESM Libraries Spec Section 3.3.
"""

using Unitful

# ESM-specific dimensionless mole-fraction units (see docs/units-standard.md).
# All elements are dimensionally-equivalent to Unitful.NoUnits; the scale factor
# listed in the canonical doc is applied only during conversion, not dimensional
# checking.
const _ESM_DIMENSIONLESS_UNITS = Set([
    "mol/mol", "ppm", "ppmv", "ppb", "ppbv", "ppt", "pptv",
])

# Unit strings we have already warned about. `parse_units` is called inside
# per-reaction / per-equation loops, so warn only once per distinct string.
# NOTE: this cache grows monotonically for the lifetime of the process (it is
# never cleared; bounded in practice by the number of distinct unparseable
# unit strings encountered) and is NOT thread-safe — concurrent `parse_units`
# calls may race on the Set (worst case: a duplicate warning, or an undefined
# mutation race). Acceptable for the current single-threaded validation paths.
const _WARNED_UNIT_STRINGS = Set{String}()

"""
Parse a unit string into a Unitful.Units object.

Handles common scientific units and compositions used in Earth system models.
"""
function parse_units(unit_str::AbstractString)::Union{Unitful.Units, Nothing}
    if isempty(unit_str) || unit_str == "dimensionless" || unit_str == "1"
        return Unitful.NoUnits
    end

    # ESM-specific mole-fraction family: all dimensionless.
    if unit_str in _ESM_DIMENSIONLESS_UNITS
        return Unitful.NoUnits
    end

    # Dobson unit: areal number density of ozone molecules.
    # 1 Dobson = 2.6867e20 molec/m^2 — dimension is [length]^-2 since the
    # ESM standard treats `molec` as a dimensionless count atom.
    if unit_str == "Dobson"
        return Unitful.unit(1.0 * u"m"^-2)
    end

    try
        # Replace the ESM-specific `molec` count atom with `1` so Unitful can
        # parse composite forms like `molec/cm^3` → `1/cm^3`. Only replace
        # whole-word occurrences to avoid clobbering substrings.
        normalized = replace(unit_str, r"\bmolec\b" => "1")

        # Try to parse with Unitful
        parsed = uparse(normalized)
        # Handle both FreeUnits (for unit strings like "mol/L") and Quantity (for strings like "1/s")
        if isa(parsed, Unitful.Units)
            return parsed  # Already units
        else
            return unit(parsed)  # Extract units from quantity
        end
    catch e
        if !(unit_str in _WARNED_UNIT_STRINGS)
            push!(_WARNED_UNIT_STRINGS, unit_str)
            @warn "Unable to parse unit string: '$unit_str'" exception=e
        end
        return nothing
    end
end

# ---------------------------------------------------------------------------
# Per-operator dimensional rules for `get_expression_dimensions`.
#
# Each rule is `(expr::OpExpr, var_units) -> Union{Unitful.Units, Nothing}` and
# is dispatched through the const `_DIMENSION_RULES` table below. Warning texts
# and returned values are byte-identical to the historical op-string chain.
# ---------------------------------------------------------------------------

# Same-dimensions core shared by the "+"/"-" rule and the "min"/"max" rule
# (historically two duplicated branches): every argument whose dimensions can
# be determined must agree, and the result carries them. `describe(first_dim,
# dim)` renders the op-family-specific inconsistency warning.
function _same_dimensions_over(args, var_units, describe)
    arg_dims = [get_expression_dimensions(arg, var_units) for arg in args]

    # Filter out nothing values
    valid_dims = filter(d -> d !== nothing, arg_dims)

    if isempty(valid_dims)
        return nothing
    end

    # Check all dimensions are the same
    first_dim = valid_dims[1]
    for dim in valid_dims[2:end]
        if dimension(dim) != dimension(first_dim)
            @warn describe(first_dim, dim)
            return nothing
        end
    end

    return first_dim
end

# "+" / "-": all arguments must have the same dimensions. (Subtraction has
# always warned with the addition text — it historically delegated to the "+"
# branch.)
_same_dimension_rule(expr, var_units) =
    _same_dimensions_over(expr.args, var_units,
        (first_dim, dim) -> "Dimensional inconsistency in addition: $(dimension(first_dim)) + $(dimension(dim))")

# "min" / "max" (esm-spec §4.2): all arguments must share dimensions; the
# result carries them.
_minmax_rule(expr, var_units) =
    _same_dimensions_over(expr.args, var_units,
        (first_dim, dim) -> "Dimensional inconsistency in $(expr.op): $(dimension(first_dim)) vs $(dimension(dim))")

# "*": multiply dimensions (arguments of unknown dimension are skipped).
function _product_rule(expr, var_units)
    result = Unitful.NoUnits
    for arg in expr.args
        arg_dim = get_expression_dimensions(arg, var_units)
        if arg_dim !== nothing
            result = result * arg_dim
        end
    end
    return result
end

# "/": divide dimensions.
function _quotient_rule(expr, var_units)
    if length(expr.args) != 2
        @warn "Division operator requires exactly 2 arguments"
        return nothing
    end

    num_dim = get_expression_dimensions(expr.args[1], var_units)
    den_dim = get_expression_dimensions(expr.args[2], var_units)

    if num_dim !== nothing && den_dim !== nothing
        return num_dim / den_dim
    end

    return nothing
end

# "^" / "pow": raise dimension to power (exponent must be dimensionless).
function _power_rule(expr, var_units)
    if length(expr.args) != 2
        @warn "Power operator requires exactly 2 arguments"
        return nothing
    end

    base_dim = get_expression_dimensions(expr.args[1], var_units)
    exp_dim = get_expression_dimensions(expr.args[2], var_units)

    if base_dim !== nothing && exp_dim !== nothing
        # Exponent should be dimensionless
        if dimension(exp_dim) != dimension(Unitful.NoUnits)
            @warn "Exponent in power operation should be dimensionless, got: $(dimension(exp_dim))"
            return nothing
        end

        # For now, assume integer powers - could be extended for fractional powers
        if expr.args[2] isa IntExpr
            return base_dim^Int(expr.args[2].value)
        elseif expr.args[2] isa NumExpr
            power = expr.args[2].value
            if power isa Number && isinteger(power)
                return base_dim^Int(power)
            end
        end

        @warn "Power operation with non-integer exponent not fully supported"
        return base_dim  # Fallback
    end

    return nothing
end

# Transcendental functions: argument should be dimensionless, result is
# dimensionless.
function _dimensionless_arg_rule(expr, var_units)
    if length(expr.args) != 1
        @warn "Function $(expr.op) requires exactly 1 argument"
        return nothing
    end

    arg_dim = get_expression_dimensions(expr.args[1], var_units)
    if arg_dim !== nothing && dimension(arg_dim) != dimension(Unitful.NoUnits)
        @warn "Argument to $(expr.op) should be dimensionless, got: $(dimension(arg_dim))"
        return nothing
    end

    return Unitful.NoUnits
end

# "ifelse": ifelse(cond, a, b) — branches must share dimensions; the condition
# is boolean and dimensionally irrelevant.
function _ifelse_rule(expr, var_units)
    length(expr.args) == 3 || return nothing
    t_dim = get_expression_dimensions(expr.args[2], var_units)
    f_dim = get_expression_dimensions(expr.args[3], var_units)
    (t_dim === nothing || f_dim === nothing) && return nothing
    if dimension(t_dim) != dimension(f_dim)
        @warn "Dimensional inconsistency in ifelse branches: $(dimension(t_dim)) vs $(dimension(f_dim))"
        return nothing
    end
    return t_dim
end

# "sign": strips dimensions — the result is a dimensionless -1/0/+1.
_dimensionless_result_rule(expr, var_units) = Unitful.NoUnits

# "abs": preserves dimensions.
function _preserve_dimension_rule(expr, var_units)
    length(expr.args) == 1 || return nothing
    return get_expression_dimensions(expr.args[1], var_units)
end

# "D": derivative — dimensions of the differentiated variable over the
# dimensions of the `wrt` variable (defaulting to time in seconds).
function _derivative_rule(expr, var_units)
    if length(expr.args) != 1
        @warn "Derivative operator D requires exactly 1 argument"
        return nothing
    end

    # Get dimensions of the variable being differentiated
    var_dim = get_expression_dimensions(expr.args[1], var_units)

    # Check what we're differentiating with respect to
    wrt = expr.wrt !== nothing ? expr.wrt : "t"  # Default to time
    wrt_unit_str = get(var_units, wrt, "s")  # Default to seconds
    wrt_dim = parse_units(wrt_unit_str)

    if var_dim !== nothing && wrt_dim !== nothing
        return var_dim / wrt_dim
    end

    return nothing
end

# The transcendental / dimensionless-argument function names. Deliberately NOT
# derived from the op registry (`_ops_with` / `_op_spec`): the registry's
# unary `:elementary` rows include dimension-PRESERVING ops (`abs`, `sign`,
# `floor`, `ceil`) and omit the spec-adjacent spellings this rule has always
# accepted (`ln`, `log2`, `expm1`), so the memberships differ.
const _TRANSCENDENTAL_OPS = Set(["sin", "cos", "tan", "exp", "log", "ln", "sqrt",
                                 "log10", "log2", "tanh", "sinh", "cosh",
                                 "asin", "acos", "atan", "expm1"])

# Operator name → dimensional rule. Ops absent from this table have no
# dimensional rule and degrade silently to `nothing` (see
# `get_expression_dimensions`).
const _DIMENSION_RULES = let rules = Dict{String, Function}(
        "+"      => _same_dimension_rule,
        "-"      => _same_dimension_rule,
        "*"      => _product_rule,
        "/"      => _quotient_rule,
        "^"      => _power_rule,
        "pow"    => _power_rule,
        "min"    => _minmax_rule,
        "max"    => _minmax_rule,
        "ifelse" => _ifelse_rule,
        "sign"   => _dimensionless_result_rule,
        "abs"    => _preserve_dimension_rule,
        "D"      => _derivative_rule,
    )
    for op in _TRANSCENDENTAL_OPS
        rules[op] = _dimensionless_arg_rule
    end
    rules
end

"""
Get the dimensions of an expression by propagating units through operations.

This performs dimensional analysis to determine the units that result from
evaluating an expression, assuming all variables have known units.

Returns `nothing` when the dimensions cannot be determined — in particular for
variables absent from `var_units` (unknown, NOT assumed dimensionless) and for
operators without a dimensional rule. `nothing` propagates upward through
enclosing operations, but note that the callers do not uniformly treat it as
"skip": [`validate_equation_dimensions`](@ref) warns and reports `false` for an
equation whose side comes back `nothing`, and [`validate_model_dimensions`](@ref)
seeds variables with no declared units as `""` (dimensionless) before checking.
"""
function get_expression_dimensions(expr::Expr, var_units::AbstractDict)::Union{Unitful.Units, Nothing}
    if expr isa NumExpr || expr isa IntExpr
        # Numbers are dimensionless unless specified otherwise
        return Unitful.NoUnits
    elseif expr isa VarExpr
        # Look up variable units; a variable we know nothing about has
        # *unknown* dimensions, not dimensionless ones.
        unit_str = get(var_units, expr.name, nothing)
        unit_str === nothing && return nothing
        return parse_units(unit_str)
    elseif expr isa OpExpr
        rule = get(_DIMENSION_RULES, expr.op, nothing)
        rule !== nothing && return rule(expr, var_units)
        # Operator without a dimensional rule (comparisons, aggregate ops,
        # registered-function calls, …): degrade silently — the result is
        # unknown, not an authoring error worth a warning per evaluation.
        @debug "No dimensional rule for operator: $(expr.op)"
        return nothing
    else
        @warn "Unknown expression type: $(typeof(expr))"
        return nothing
    end
end

"""
Validate that an equation is dimensionally consistent.

Checks that the left-hand side and right-hand side have the same dimensions.
"""
function validate_equation_dimensions(eq::Equation, var_units::AbstractDict)::Bool
    lhs_dim = get_expression_dimensions(eq.lhs, var_units)
    rhs_dim = get_expression_dimensions(eq.rhs, var_units)

    # `get_expression_dimensions` returns `nothing` for UNKNOWN dimensions (a
    # variable without declared units, an unsupported op) — NOT for provably-
    # wrong ones. A validator can only flag a PROVABLE inconsistency, so an
    # equation whose dimensions cannot be fully determined is SKIPPED (counted
    # consistent) rather than failed.
    if lhs_dim === nothing || rhs_dim === nothing
        return true
    end

    if dimension(lhs_dim) != dimension(rhs_dim)
        @warn "Dimensional inconsistency in equation: $(eq.lhs) = $(eq.rhs)"
        @warn "  LHS dimensions: $(dimension(lhs_dim))"
        @warn "  RHS dimensions: $(dimension(rhs_dim))"
        return false
    end

    return true
end

"""
Validate dimensions for all equations in a model.

Returns true if all equations are dimensionally consistent.
"""
function validate_model_dimensions(model::Model)::Bool
    # Build variable units dictionary. A variable with no declared units is
    # left OUT — so `get_expression_dimensions` treats it as unknown (`nothing`),
    # consistent with `validate_equation_dimensions` skipping unknowns rather
    # than assuming dimensionless.
    var_units = Dict{String, String}()
    for (name, var) in model.variables
        var.units !== nothing && (var_units[name] = var.units)
    end

    # Validate each equation
    all_valid = true
    for (i, equation) in enumerate(model.equations)
        if !validate_equation_dimensions(equation, var_units)
            @warn "Equation $i failed dimensional validation"
            all_valid = false
        end
    end

    return all_valid
end

"""
Validate dimensions for all reactions in a reaction system.

Enforces the mass-action dimensional constraint from spec §7.4 by delegating
to [`validate_reaction_rate_units`](@ref) in validate.jl — the single shared
implementation of the rule (also used by `validate_structural`) — so the two
entry points cannot drift apart. Each finding is logged as a warning; returns
`true` when no dimensional inconsistencies are found.
"""
function validate_reaction_system_dimensions(rxn_sys::ReactionSystem)::Bool
    errors = validate_reaction_rate_units(rxn_sys, "/reaction_system")
    for err in errors
        @warn err.message
    end
    return isempty(errors)
end

"""
Validate dimensions for all components in an ESM file.

Returns true if all models and reaction systems pass dimensional validation.
"""
function validate_file_dimensions(file::EsmFile)::Bool
    all_valid = true

    if file.models !== nothing
        for (name, model) in file.models
            @info "Validating dimensions for model: $name"
            if !validate_model_dimensions(model)
                @warn "Model $name failed dimensional validation"
                all_valid = false
            end
        end
    end

    if file.reaction_systems !== nothing
        for (name, rxn_sys) in file.reaction_systems
            @info "Validating dimensions for reaction system: $name"
            if !validate_reaction_system_dimensions(rxn_sys)
                @warn "Reaction system $name failed dimensional validation"
                all_valid = false
            end
        end
    end

    return all_valid
end

"""
Infer appropriate units for a variable based on its usage in equations.

This can help suggest units when they are not explicitly specified.
"""
function infer_variable_units(var_name::AbstractString, equations::Vector{Equation}, known_units::AbstractDict)::Union{String, Nothing}
    # Look for equations where this variable appears
    for eq in equations
        lhs_vars = free_variables(eq.lhs)
        rhs_vars = free_variables(eq.rhs)

        if var_name in lhs_vars
            # Variable appears on LHS - its units should match RHS
            rhs_dim = get_expression_dimensions(eq.rhs, known_units)
            if rhs_dim !== nothing
                return string(rhs_dim)
            end
        elseif var_name in rhs_vars
            # Variable appears on RHS - need more sophisticated analysis
            # This is more complex and would require symbolic manipulation
            continue
        end
    end

    return nothing
end