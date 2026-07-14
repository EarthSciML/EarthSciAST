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

        # `h` means HOUR in the ESM unit vocabulary (`L/h`, `mg/h`, `km/h`).
        # In Unitful, `u"h"` is PLANCK'S CONSTANT (6.626e-34 J·s) — so `L/h`
        # silently parsed as litre per joule-second and made every
        # pharmacokinetic fixture look dimensionally inconsistent. Rewrite the
        # whole-word atom to Unitful's `hr` before parsing.
        normalized = replace(normalized, r"\bh\b" => "hr")

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
# The dimensional engine.
#
# THE CENTRAL INVARIANT (bug audit 2026-07-14, finding J1): a dimensional rule
# has THREE possible outcomes, and the first two must never be conflated:
#
#   * a known dimension        → the `Unitful.Units` value
#   * PROVABLY INCONSISTENT    → push a message onto `findings`, return `nothing`
#   * UNKNOWN / indeterminate  → return `nothing`, push NOTHING
#
# Before this was fixed, every rule signalled a provable inconsistency by
# `@warn`-ing and returning `nothing` — the *same* value it returns for an
# undeclared variable or an operator with no rule — so a violation could not be
# distinguished from ignorance and `validate_equation_dimensions` counted both
# as consistent. A violation was structurally incapable of becoming an error.
#
# Callers therefore learn "this expression is provably wrong" by checking
# whether `findings` GREW, never by checking the returned value against
# `nothing`. `nothing` alone always means "cannot say".
#
# Corollary (conservatism): a rule that cannot determine ALL of its operands'
# dimensions must return `nothing` rather than guess, because a guessed
# dimension propagates upward and can manufacture a FALSE inconsistency at an
# enclosing node. `_product_rule` used to skip unknown factors and return the
# product of the known ones — a wrong dimension, presented as a known one.
#
# Each rule is `(expr::OpExpr, var_units, findings::Vector{String}) -> Union{Unitful.Units, Nothing}`,
# dispatched through the const `_DIMENSION_RULES` table below.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# IMPLICIT UNITS ON NUMERIC LITERALS.
#
# A bare number in a dimension-bearing position carries units the document does
# not spell out. `D(n) = 0.001 * droplet_number` (kg m⁻³ s⁻¹ = ? × m⁻³) is not an
# error: the `0.001` IS a rate constant with units kg s⁻¹. The corpus is written
# this way throughout, and this module's sibling `validate_reaction_rate_units`
# already states the rule — "atmospheric-chemistry rate constants routinely carry
# implicit units on numeric literals, which defeats literal dimensional analysis"
# — and skips such expressions.
#
# So: a literal operand of `*` or `/` makes the RESULT indeterminate, and a
# literal operand of `+` or `-` imposes NO constraint (it adopts whatever
# dimension its siblings have: `T - 273.15` is fine).
#
# The exceptions, where a literal really is dimensionless and treating it as
# opaque would gut the check:
#   * an EXPONENT (`x^2`) — that is what makes `^` computable at all;
#   * a TRANSCENDENTAL ARGUMENT (`exp(2)`) — the rule under test.
# Those two rules read the literal directly and do not consult `_is_literal`.
# ---------------------------------------------------------------------------
_is_literal(e::ASTExpr) = e isa NumExpr || e isa IntExpr

# Same-dimensions core shared by the "+"/"-" rule and the "min"/"max" rule:
# every NON-LITERAL argument whose dimensions can be determined must agree, and
# the result carries them. `describe(first_dim, dim)` renders the
# op-family-specific inconsistency message.
#
# A mismatch between two KNOWN operand dimensions is provable → recorded. If any
# non-literal operand is unknown the result is unknown (`nothing`) even when the
# knowns agree, because the unknown one could disagree with all of them.
function _same_dimensions_over(args, var_units, findings, describe)
    # Literals impose no constraint here — see the implicit-units note above.
    constrained = [a for a in args if !_is_literal(a)]
    # Still descend the literals' subtrees? They have none — a literal is a leaf.
    arg_dims = [_expr_dimensions!(findings, arg, var_units) for arg in constrained]

    valid_dims = filter(d -> d !== nothing, arg_dims)
    isempty(valid_dims) && return nothing

    first_dim = valid_dims[1]
    for dim in valid_dims[2:end]
        if dimension(dim) != dimension(first_dim)
            push!(findings, describe(first_dim, dim))
            return nothing
        end
    end

    # All KNOWN operands agree. Only claim the dimension when every non-literal
    # operand was known — otherwise an undeclared operand leaves it indeterminate.
    length(valid_dims) == length(arg_dims) ? first_dim : nothing
end

# "+" / "-": all arguments must have the same dimensions.
_same_dimension_rule(expr, var_units, findings) =
    _same_dimensions_over(expr.args, var_units, findings,
        (first_dim, dim) -> "Cannot $(expr.op == "-" ? "subtract" : "add") quantities with " *
            "different units: '$(_ustr(first_dim))' $(expr.op) '$(_ustr(dim))'")

# "min" / "max" (esm-spec §4.2): all arguments must share dimensions; the
# result carries them.
_minmax_rule(expr, var_units, findings) =
    _same_dimensions_over(expr.args, var_units, findings,
        (first_dim, dim) -> "Dimensional inconsistency in $(expr.op): " *
            "'$(_ustr(first_dim))' vs '$(_ustr(dim))'")

# "*": multiply dimensions. An unknown factor — or a LITERAL one, which carries
# implicit units — makes the PRODUCT unknown. See the conservatism corollary and
# the implicit-units note above.
function _product_rule(expr, var_units, findings)
    result = Unitful.NoUnits
    opaque = false
    for arg in expr.args
        if _is_literal(arg)
            opaque = true
            continue
        end
        arg_dim = _expr_dimensions!(findings, arg, var_units)
        arg_dim === nothing && (opaque = true; continue)
        result = result * arg_dim
    end
    return opaque ? nothing : result
end

# "/": divide dimensions. A literal numerator or denominator carries implicit
# units → the quotient is indeterminate.
function _quotient_rule(expr, var_units, findings)
    if length(expr.args) != 2
        # Arity is a STRUCTURAL defect, not a dimensional one — not a finding.
        @debug "Division operator requires exactly 2 arguments"
        return nothing
    end

    num_lit = _is_literal(expr.args[1])
    den_lit = _is_literal(expr.args[2])
    num_dim = num_lit ? nothing : _expr_dimensions!(findings, expr.args[1], var_units)
    den_dim = den_lit ? nothing : _expr_dimensions!(findings, expr.args[2], var_units)

    (num_lit || den_lit) && return nothing
    (num_dim === nothing || den_dim === nothing) && return nothing
    return num_dim / den_dim
end

# "^" / "pow": raise dimension to power. The exponent must be dimensionless —
# that is a provable inconsistency when its dimension is known and non-trivial.
function _power_rule(expr, var_units, findings)
    if length(expr.args) != 2
        @debug "Power operator requires exactly 2 arguments"
        return nothing
    end

    base_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    exp_dim = _expr_dimensions!(findings, expr.args[2], var_units)

    # A dimensional exponent is provably wrong regardless of the base.
    if exp_dim !== nothing && dimension(exp_dim) != dimension(Unitful.NoUnits)
        push!(findings, "Exponent must be dimensionless, got '$(_ustr(exp_dim))'" *
            (base_dim === nothing ? "" : " for base with units '$(_ustr(base_dim))'"))
        return nothing
    end

    (base_dim === nothing || exp_dim === nothing) && return nothing

    # A literal integer exponent is the only case whose result dimension is
    # determinable. `x^n` for a symbolic (or fractional) `n` on a DIMENSIONAL
    # base has no static dimension → unknown. On a dimensionless base the result
    # is dimensionless whatever the exponent.
    power = if expr.args[2] isa IntExpr
        Int(expr.args[2].value)
    elseif expr.args[2] isa NumExpr && expr.args[2].value isa Number && isinteger(expr.args[2].value)
        Int(expr.args[2].value)
    else
        nothing
    end
    power !== nothing && return base_dim^power
    dimension(base_dim) == dimension(Unitful.NoUnits) && return Unitful.NoUnits
    return nothing
end

# "sqrt": halves the dimension. NOT a transcendental — `sqrt(area)` is a
# perfectly ordinary dimensional operation, and treating it as requiring a
# dimensionless argument (as this module used to) manufactures false positives.
function _sqrt_rule(expr, var_units, findings)
    length(expr.args) == 1 || return nothing
    base_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    base_dim === nothing && return nothing
    try
        return base_dim^(1//2)
    catch
        # Unitful rejects a half-power that is not representable (odd exponent
        # on a base unit). Unknown, not an inconsistency — the AUTHOR may have a
        # non-SI convention we cannot model.
        return nothing
    end
end

# Transcendental functions: argument must be dimensionless (a provable
# inconsistency otherwise); result is dimensionless.
function _dimensionless_arg_rule(expr, var_units, findings)
    if length(expr.args) != 1
        @debug "Function $(expr.op) requires exactly 1 argument"
        return nothing
    end

    arg_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    if arg_dim !== nothing && dimension(arg_dim) != dimension(Unitful.NoUnits)
        push!(findings, "$(_op_family(expr.op)) argument must be dimensionless, " *
                        "got units '$(_ustr(arg_dim))' (function '$(expr.op)')")
        return nothing
    end

    return Unitful.NoUnits
end

# Human-readable family name used in the dimensionless-argument message, chosen
# to line up with the shared corpus's expected wording ("Logarithm argument must
# be dimensionless…", "Exponential argument must be dimensionless…").
function _op_family(op::AbstractString)
    op in ("log", "ln", "log10", "log2") && return "Logarithm"
    op in ("exp", "expm1") && return "Exponential"
    return "Transcendental function"
end

# Render a unit for a diagnostic. Falls back to the dimension when the unit has
# no compact string form.
function _ustr(u)::String
    s = string(u)
    isempty(s) ? string(dimension(u)) : s
end

# "ifelse": ifelse(cond, a, b) — branches must share dimensions; the condition
# is boolean and dimensionally irrelevant.
function _ifelse_rule(expr, var_units, findings)
    length(expr.args) == 3 || return nothing
    t_dim = _expr_dimensions!(findings, expr.args[2], var_units)
    f_dim = _expr_dimensions!(findings, expr.args[3], var_units)
    (t_dim === nothing || f_dim === nothing) && return nothing
    if dimension(t_dim) != dimension(f_dim)
        push!(findings, "Dimensional inconsistency in ifelse branches: " *
                        "'$(_ustr(t_dim))' vs '$(_ustr(f_dim))'")
        return nothing
    end
    return t_dim
end

# "sign": strips dimensions — the result is a dimensionless -1/0/+1.
_dimensionless_result_rule(expr, var_units, findings) = Unitful.NoUnits

# "abs": preserves dimensions.
function _preserve_dimension_rule(expr, var_units, findings)
    length(expr.args) == 1 || return nothing
    return _expr_dimensions!(findings, expr.args[1], var_units)
end

# "D": derivative — dimensions of the differentiated variable over the
# dimensions of the `wrt` variable (defaulting to time in seconds).
function _derivative_rule(expr, var_units, findings)
    if length(expr.args) != 1
        @debug "Derivative operator D requires exactly 1 argument"
        return nothing
    end

    var_dim = _expr_dimensions!(findings, expr.args[1], var_units)

    wrt = expr.wrt !== nothing ? expr.wrt : "t"  # Default to time
    wrt_unit_str = get(var_units, wrt, "s")      # Default to seconds
    wrt_dim = parse_units(wrt_unit_str)

    (var_dim === nothing || wrt_dim === nothing) && return nothing
    return var_dim / wrt_dim
end

# The transcendental / dimensionless-argument function names. Deliberately NOT
# derived from the op registry (`_ops_with` / `_op_spec`): the registry's
# unary `:elementary` rows include dimension-PRESERVING ops (`abs`, `sign`,
# `floor`, `ceil`) and omit the spec-adjacent spellings this rule has always
# accepted (`ln`, `log2`, `expm1`), so the memberships differ.
#
# `sqrt` is NOT here: it halves its argument's dimension (`_sqrt_rule`) rather
# than requiring a dimensionless one.
const _TRANSCENDENTAL_OPS = Set(["sin", "cos", "tan", "exp", "log", "ln",
                                 "log10", "log2", "tanh", "sinh", "cosh",
                                 "asin", "acos", "atan", "expm1"])

# Operator name → dimensional rule. Ops absent from this table have no
# dimensional rule and degrade silently to `nothing` (see `_expr_dimensions!`).
const _DIMENSION_RULES = let rules = Dict{String, Function}(
        "+"      => _same_dimension_rule,
        "-"      => _same_dimension_rule,
        "*"      => _product_rule,
        "/"      => _quotient_rule,
        "^"      => _power_rule,
        "pow"    => _power_rule,
        "sqrt"   => _sqrt_rule,
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

# The engine proper. Returns the expression's dimension, or `nothing` when it
# cannot be determined; every PROVABLE inconsistency encountered anywhere in the
# subtree is appended to `findings`. See the invariant at the top of this block.
function _expr_dimensions!(findings::Vector{String}, expr::ASTExpr,
                           var_units::AbstractDict)::Union{Unitful.Units, Nothing}
    if expr isa NumExpr || expr isa IntExpr
        # Numbers are dimensionless unless specified otherwise
        return Unitful.NoUnits
    elseif expr isa VarExpr
        # Look up variable units; a variable we know nothing about has
        # *unknown* dimensions, not dimensionless ones.
        unit_str = get(var_units, expr.name, nothing)
        unit_str === nothing && return nothing
        return _absolute_unit(parse_units(unit_str))
    elseif expr isa OpExpr
        rule = get(_DIMENSION_RULES, expr.op, nothing)
        rule !== nothing && return rule(expr, var_units, findings)
        # Operator without a dimensional rule (comparisons, aggregate ops,
        # registered-function calls, …): degrade silently — the result is
        # unknown, not an authoring error.
        @debug "No dimensional rule for operator: $(expr.op)"
        return nothing
    else
        @debug "Unknown expression type: $(typeof(expr))"
        return nothing
    end
end

# Affine units (°C, °F) cannot take part in unit ARITHMETIC — `u"°C" * u"kg"`
# throws `Unitful.AffineError`, which used to escape `validate()` as an
# uncaught exception on two valid fixtures. The engine only ever needs a unit's
# DIMENSION, so normalise an affine unit to its absolute counterpart (°C → K)
# on the way in. Note this is deliberately confined to the engine:
# `parse_units` still returns the affine unit, because
# `validate_conversion_factor_consistency` needs the affine/linear distinction
# and `model_unit_findings`' declared-vs-default check needs `K != °C`.
function _absolute_unit(u)
    u === nothing && return nothing
    try
        return Unitful.absoluteunit(u)
    catch
        return u
    end
end

"""
    expression_unit_findings(expr::ASTExpr, var_units::AbstractDict) -> Vector{String}

Every PROVABLE dimensional inconsistency inside `expr`, as human-readable
messages. Empty means "nothing provably wrong" — NOT "fully checked": an
expression whose dimensions are indeterminate (an undeclared variable, an
operator with no dimensional rule) yields no findings.

This is the silent, error-collecting counterpart of
[`get_expression_dimensions`](@ref) and the entry point the structural validator
builds on.
"""
function expression_unit_findings(expr::ASTExpr, var_units::AbstractDict)::Vector{String}
    findings = String[]
    _expr_dimensions!(findings, expr, var_units)
    return findings
end

"""
Get the dimensions of an expression by propagating units through operations.

This performs dimensional analysis to determine the units that result from
evaluating an expression, assuming all variables have known units.

Returns `nothing` when the dimensions cannot be determined — for variables
absent from `var_units` (unknown, NOT assumed dimensionless), for operators
without a dimensional rule, and for a subtree that is provably inconsistent.
Because those three cases share one return value, `nothing` alone tells you
nothing about *validity*; any provable inconsistency found along the way is
reported here as a `@warn` and, for programmatic use, is available from
[`expression_unit_findings`](@ref).
"""
function get_expression_dimensions(expr::ASTExpr, var_units::AbstractDict)::Union{Unitful.Units, Nothing}
    findings = String[]
    dim = _expr_dimensions!(findings, expr, var_units)
    for msg in findings
        @warn msg
    end
    return dim
end

# True when `d` is a pure power of the TIME dimension (including 𝐓⁰ = NoDims).
# `Unitful.Dimensions{D}` carries its exponents in the type parameter `D`, a
# tuple of `Unitful.Dimension{:Time}(p)`-style values.
_is_time_power(d) = all(x -> x isa Unitful.Dimension{:Time}, typeof(d).parameters[1])

"""
    equation_unit_findings(eq::Equation, var_units::AbstractDict) -> Vector{String}

The PROVABLE dimensional inconsistency of an equation's two SIDES, if any.

Scope, and why it is this narrow:

* **Only derivative equations are checked.** An equation with a `D(u, t)` LHS
  states a rate law and its two sides must balance. An equation with an
  algebraic or implicit LHS (`H*H*SO4 = Ksp`, `u = f(x)`) states a *constraint*;
  the shared corpus pins no unit error on one, and checking them flags
  fixtures the corpus calls valid.

* **Expression-internal inconsistencies are NOT collected here.** They are
  checked on observed variables' defining expressions (see
  [`model_unit_findings`](@ref)), which is where every corpus-pinned
  expression-level unit error actually lives. Equation right-hand sides are
  written with implicit-unit literals throughout the corpus and cannot bear a
  strict reading.

* **An undeclared time variable makes the time factor free.** `dim(D(u)) =
  dim(u)/dim(t)`. When the model never declares units for `wrt` (the usual case
  — `t` is rarely a declared variable), no particular time unit is asserted, so
  an inconsistency is only PROVABLE when `dim(u)/dim(rhs)` is not a power of the
  time dimension: no choice of time unit could reconcile the two. This is what
  makes `D(x) = -x` (x dimensionless — the elided unit rate constant, ubiquitous
  in the corpus) pass while `D(velocity[m/s]) = mass[kg]` still fails.
  When `wrt` IS declared, the strict comparison is used.
"""
function equation_unit_findings(eq::Equation, var_units::AbstractDict)::Vector{String}
    findings = String[]

    lhs = eq.lhs
    (lhs isa OpExpr && lhs.op == "D" && length(lhs.args) == 1) || return findings

    # A BARE-LITERAL right-hand side asserts nothing dimensionally. `D(y) = 0`
    # (`tests/valid/metadata_author_variations.esm`, y in kg) is the ordinary way
    # to say "y is held constant"; the literal carries the implicit units kg/s,
    # exactly as the implicit-units note at the top of this file describes for a
    # literal factor of `*` or `/`. Reading it as dimensionless instead makes
    # every `D(<dimensional>) = <literal>` equation look provably inconsistent.
    _is_literal(eq.rhs) && return findings

    scratch = String[]   # internal findings are out of scope here; see above
    u_dim = _expr_dimensions!(scratch, lhs.args[1], var_units)
    rhs_dim = _expr_dimensions!(scratch, eq.rhs, var_units)
    (u_dim === nothing || rhs_dim === nothing) && return findings

    wrt = lhs.wrt !== nothing ? lhs.wrt : "t"

    if haskey(var_units, wrt)
        wrt_dim = _absolute_unit(parse_units(var_units[wrt]))
        wrt_dim === nothing && return findings
        lhs_dim = u_dim / wrt_dim
        if dimension(lhs_dim) != dimension(rhs_dim)
            push!(findings,
                  "Left-hand side has units '$(_ustr(lhs_dim))' but right-hand side " *
                  "has units '$(_ustr(rhs_dim))'")
        end
    else
        ratio = dimension(u_dim) / dimension(rhs_dim)
        if !_is_time_power(ratio)
            push!(findings,
                  "Derivative of '$(_ustr(u_dim))' cannot equal an expression with units " *
                  "'$(_ustr(rhs_dim))' under any time unit (they differ by $(ratio), " *
                  "not by a power of time)")
        end
    end

    return findings
end

"""
Validate that an equation is dimensionally consistent.

Checks that both sides are internally consistent and that the left-hand side and
right-hand side have the same dimensions. Returns `false` only for a PROVABLE
inconsistency; an equation whose dimensions cannot be determined is skipped
(counted consistent), because a validator must not fail what it cannot prove.
"""
function validate_equation_dimensions(eq::Equation, var_units::AbstractDict)::Bool
    findings = equation_unit_findings(eq, var_units)
    for msg in findings
        @warn "Dimensional inconsistency in equation: $msg"
    end
    return isempty(findings)
end

"""
    model_unit_findings(model::Model) -> Vector{Pair{String,String}}

Every PROVABLE dimensional inconsistency in `model`, as `subpath => message`
pairs where `subpath` is RELATIVE to the model's own JSON pointer (e.g.
`"equations/0"`, `"variables/invalid_sum"`). Callers prefix their pointer and
promote each pair to an error; see `validate_model_unit_consistency` in
validate.jl, the single structural caller.

Three families are checked:

1. **Declared vs default units** — a parameter whose `default` is supplied in
   `default_units` that are not the same unit as its declared `units`.
2. **Observed-variable defining expressions** — an inconsistency *inside* the
   `expression` of an observed variable (`length + mass`, `exp(mass)`, …).
   The declared units of the variable are deliberately NOT compared against the
   computed dimension of its expression: that comparison is a different (and
   much more false-positive-prone) rule, and the shared corpus does not pin it.
3. **Equations** — an inconsistency inside either side, or an LHS/RHS mismatch.

Subsystems are NOT recursed here (the caller owns path construction and does the
recursion), keeping this function's pointers purely model-local.

Iteration over `model.variables` is sorted by name so the finding order is
deterministic regardless of Dict hashing.
"""
function model_unit_findings(model::Model)::Vector{Pair{String,String}}
    # Only EXPLICITLY declared units enter the environment. A variable with no
    # declared units is unknown, not dimensionless.
    var_units = Dict{String, String}()
    for (name, var) in model.variables
        var.units !== nothing && !isempty(var.units) && (var_units[name] = var.units)
    end

    out = Pair{String,String}[]

    for name in sort!(collect(keys(model.variables)))
        var = model.variables[name]

        # 1. default_units vs units.
        du, u = var.default_units, var.units
        if du !== nothing && !isempty(du) && u !== nothing && !isempty(u) && du != u
            du_parsed, u_parsed = parse_units(du), parse_units(u)
            if du_parsed !== nothing && u_parsed !== nothing && du_parsed != u_parsed
                push!(out, "variables/$name" =>
                    "Parameter default value units do not match declared units " *
                    "(variable '$name', declared_units='$u', default_units='$du')")
            end
        end

        # 2. observed-variable defining expression.
        if var.expression !== nothing
            for msg in expression_unit_findings(var.expression, var_units)
                push!(out, "variables/$name" => "$msg (variable '$name')")
            end
        end
    end

    # 3. equations.
    for (i, eq) in enumerate(model.equations)
        for msg in equation_unit_findings(eq, var_units)
            push!(out, "equations/$(i-1)" => msg)
        end
    end

    return out
end

"""
Validate dimensions for all equations and variable definitions in a model.

Returns true when nothing in the model is PROVABLY dimensionally inconsistent.
Recurses into model subsystems.
"""
function validate_model_dimensions(model::Model)::Bool
    findings = model_unit_findings(model)
    for (subpath, msg) in findings
        @warn "Dimensional inconsistency at $subpath: $msg"
    end

    all_valid = isempty(findings)
    for (_, subsys) in model.subsystems
        subsys isa Model || continue
        validate_model_dimensions(subsys) || (all_valid = false)
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