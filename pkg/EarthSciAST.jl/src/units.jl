"""
Unit validation functionality using Unitful.jl.

This module provides dimensional analysis and unit validation for ESM format
expressions, equations, and models as specified in ESM Libraries Spec Section 3.3.
"""

using Unitful

# ---------------------------------------------------------------------------
# THE UNIT REGISTRY (esm-spec §4.8.1).
#
# A FLAT symbol table, and deliberately so: a symbol is either in it or the
# unit string does not resolve. There is NO SI-prefix mechanism — `mm` is a row
# here, not `m` composed with `milli-`. A prefix rule would silently accept
# nonsense (`kmolec`, `nppb`) and make the set of legal unit strings unbounded
# and un-pinnable across five language bindings.
#
# This replaces a `Unitful.uparse` call. `uparse` is the wrong tool for a
# CROSS-BINDING contract for three reasons, each of which bit us:
#
#   * it has an open SI-prefix mechanism, so the accepted set is not the
#     spec's set (and cannot be, since Julia's prefix table is Julia's);
#   * its symbol meanings are Unitful's, not the ESM registry's — `u"h"` is
#     PLANCK'S CONSTANT, so `L/h` parsed as litre-per-joule-second and made
#     every pharmacokinetic fixture look dimensionally inconsistent;
#   * it knows nothing of the ESM count nouns (`molec`, `individuals`,
#     `vehicles`, `units`, `count`), which are REAL unit names in the corpus.
#     Under the §4.8.4 severity contract — where an unresolvable unit string is
#     a HARD ERROR — an incomplete registry is not a missing warning, it is a
#     FALSE REJECTION of a well-formed file. The registry must be complete, and
#     an incomplete one must never be papered over by downgrading the severity.
#
# The values are `Unitful.Units` objects, so Unitful still supplies the
# dimension algebra and the scale (`uconvert`, needed by the conversion-factor
# and physical-constant checks). Only the SPELLING is ours.
# ---------------------------------------------------------------------------

# 1 mmHg = 133.322387415 Pa exactly (BIPM). Unitful has `Torr` (101325/760 Pa)
# but not `mmHg`; the two differ by ~1.4e-7 relative, so they are NOT aliased.
# `false` = do not auto-generate SI prefixes for this symbol.
Unitful.@unit _u_mmHg "mmHg" MillimetreOfMercury 133.322387415 * Unitful.u"Pa" false

# Microatmosphere — the standard unit of seawater pCO2. Unitful defines `atm`
# without an SI-prefix mechanism, so `uatm` must be spelled out.
Unitful.@unit _u_uatm "uatm" MicroAtmosphere 1e-6 * Unitful.u"atm" false

# `Dobson` / `DU`: the areal number density of ozone in a column. One DU is a
# 10 µm-thick layer of pure O3 at STP — 2.6867e20 molec/m^2 (the Loschmidt
# constant times 10 µm). `molec` is a dimensionless COUNT, so the DIMENSION is
# [length]^-2 and the m^-2 is real, not an artefact: a Dobson unit is NOT
# dimensionless. The scale is carried too, so `uconvert` between DU and
# `molec/m^2` is exact.
Unitful.@unit _u_dobson "DU" DobsonUnit 2.6867e20 * Unitful.u"m"^-2 false

# The flat table, grouped exactly as esm-spec §4.8.1 lists it.
const _UNIT_REGISTRY = Dict{String, Unitful.Units}(
    # SI base.
    "m" => u"m", "kg" => u"kg", "s" => u"s", "mol" => u"mol",
    "K" => u"K", "A" => u"A", "cd" => u"cd", "rad" => u"rad",

    # Mass.
    "g" => u"g", "mg" => u"mg", "ug" => u"μg",

    # Length.
    "dm" => u"dm", "cm" => u"cm", "mm" => u"mm", "um" => u"μm",
    "nm" => u"nm", "km" => u"km",

    # Time. `h` is the HOUR here, not Unitful's Planck constant.
    #
    # `d` is deliberately NOT a registry symbol. The canonical spelling of the
    # day is `day`: a bare `d` reads as a deci- prefix or as a differential, so
    # §4.8.1 excludes it and the stdlib is spelled `day`.
    "ms" => u"ms", "us" => u"μs", "ns" => u"ns", "min" => u"minute",
    "h" => u"hr", "hr" => u"hr", "day" => u"d",
    "yr" => u"yr", "year" => u"yr",

    # Volume.
    "L" => u"L", "l" => u"L", "mL" => u"mL",

    # Amount of substance. `M` is molarity (mol/L).
    "kmol" => u"kmol", "mmol" => u"mmol", "umol" => u"μmol",
    "nmol" => u"nmol", "M" => u"M",

    # Derived.
    "Hz" => u"Hz", "N" => u"N", "Pa" => u"Pa", "J" => u"J", "kJ" => u"kJ",
    "cal" => u"cal", "kcal" => u"kcal", "W" => u"W", "kW" => u"kW", "MW" => u"MW",

    # Pressure.
    "atm" => u"atm", "bar" => u"bar", "hPa" => u"hPa", "kPa" => u"kPa",
    "mbar" => u"mbar", "Torr" => u"Torr", "mmHg" => _u_mmHg, "psi" => u"psi",

    # Energy.
    "erg" => u"erg", "BTU" => u"btu", "Wh" => u"W*hr", "kWh" => u"kW*hr",

    # Electromagnetic. `C` is the COULOMB, per SI — never Celsius. Binding it
    # to Celsius injects a temperature dimension into every electromagnetic
    # expression: charge × field then comes out kg*m*K/(s^3*A) instead of a
    # newton. Celsius has its own unambiguous spellings, `degC` and `°C`.
    "C" => u"C", "V" => u"V", "Ohm" => u"Ω", "F" => u"F", "T" => u"T",

    # Temperature / plane angle. The affine OFFSET of degC/degF is irrelevant
    # to dimensional analysis and is not modelled (see `_absolute_unit`).
    "degC" => u"°C", "degF" => u"°F", "deg" => u"°",

    # Mixing ratios — dimensionless. The "v" (by-volume) spellings name the
    # same quantity.
    "ppm" => u"ppm", "ppb" => u"ppb", "ppt" => u"ppt",
    "ppmv" => u"ppm", "ppbv" => u"ppb", "pptv" => u"ppt",

    # COUNT NOUNS — a count of discrete things carries no physical dimension,
    # so each is dimensionless. They are real unit names in the shared corpus
    # (`molec/cm^3`, `individuals/km^2`, `vehicles/km^2`, `units/L`), and since
    # an unresolvable unit string is now a hard error, omitting them would
    # falsely REJECT those files.
    "molec" => Unitful.NoUnits, "individuals" => Unitful.NoUnits,
    "vehicles" => Unitful.NoUnits, "units" => Unitful.NoUnits,
    "count" => Unitful.NoUnits,

    # Column amount — dimension m^-2, NOT dimensionless (see above).
    "Dobson" => _u_dobson, "DU" => _u_dobson,

    # Ratios that are dimensionless BY DEFINITION. `psu` (practical salinity)
    # is a conductivity ratio; `percent` is 1/100. Both are real, both are in
    # the corpus, and under a hard-error severity a missing row is a FALSE
    # REJECTION of a well-formed file.
    "percent" => u"percent",
    "psu" => Unitful.NoUnits,

    # Microatmosphere — the standard unit of seawater pCO2.
    "uatm" => _u_uatm,

    # Long-form spellings that occur in the corpus. Aliases, not new units.
    "molecule" => Unitful.NoUnits,   # = molec
    "meter" => u"m", "meters" => u"m",
    "hour" => u"hr",
    "Celsius" => u"°C",
    "degree" => u"°", "degrees" => u"°",
)

# ---------------------------------------------------------------------------
# SPELLING NORMALISATION, applied BEFORE the scanner (which recognises only
# ASCII). Pure spelling: every target already exists in the registry above; no
# unit is invented here.
#
# These are ORDINARY earth-science spellings — `W/m²`, `J/(kg·K)`, `cm³`,
# `μg/m^3` — not exotica. Since an unresolvable unit string is now a HARD ERROR
# (esm-spec §4.8.4), a normaliser that does not know them does not merely warn:
# it rejects a legitimate file.
# ---------------------------------------------------------------------------
const _UNIT_SPELLINGS = [
    "°C" => "degC",
    "°F" => "degF",
    "°K" => "K",
    "°"  => "deg",
    "µ"  => "u",      # U+00B5 MICRO SIGN
    "μ"  => "u",      # U+03BC GREEK SMALL LETTER MU
    "Ω"  => "Ohm",    # U+03A9 GREEK CAPITAL LETTER OMEGA
    "·"  => "*",      # U+00B7 MIDDLE DOT — multiplication
    "⋅"  => "*",      # U+22C5 DOT OPERATOR — multiplication
    "%"  => "percent",
]

# Superscript digits and the superscript minus. A RUN of these is an exponent:
# `m²` is `m^2`, `m⁻³` is `m^-3`.
const _SUPERSCRIPTS = Dict{Char,Char}(
    '⁰' => '0', '¹' => '1', '²' => '2', '³' => '3', '⁴' => '4',
    '⁵' => '5', '⁶' => '6', '⁷' => '7', '⁸' => '8', '⁹' => '9',
    '⁻' => '-',
)

function _normalize_unit_string(s::AbstractString)::String
    out = String(s)
    for (from, to) in _UNIT_SPELLINGS
        occursin(from, out) && (out = replace(out, from => to))
    end

    any(c -> haskey(_SUPERSCRIPTS, c), out) || return out

    # Rewrite each maximal run of superscript characters as `^<digits>`.
    io = IOBuffer()
    in_run = false
    for c in out
        if haskey(_SUPERSCRIPTS, c)
            in_run || (print(io, '^'); in_run = true)
            print(io, _SUPERSCRIPTS[c])
        else
            in_run = false
            print(io, c)
        end
    end
    return String(take!(io))
end

# Raised by the recursive-descent parser and caught by `parse_units`, which
# turns it into `nothing`. Callers distinguish "unresolvable" from "absent" by
# checking for `nothing`, and the structural validator promotes it to a hard
# `unit_parse_error` (esm-spec §4.8.4).
struct _UnitParseError <: Exception
    msg::String
end

mutable struct _UnitParser
    src::Vector{Char}
    pos::Int
end

# ---------------------------------------------------------------------------
# AFFINE UNITS INSIDE A COMPOSITION.
#
# Unitful refuses unit ARITHMETIC on an affine unit — `u"°C" / u"minute"` throws
# `Unitful.AffineError` — because °C's zero OFFSET makes the quotient
# meaningless. But `"°C/min"` and `"K/h"` are ordinary corpus unit strings, and
# esm-spec §4.8.1 says the offset is deliberately NOT modelled: `degC` carries
# the Kelvin dimension and its scale, nothing more.
#
# So inside a composition an affine unit is replaced by its absolute counterpart
# (°C → K). A STANDALONE affine atom keeps its identity, because
# `model_unit_findings` needs `K != °C` to catch a parameter whose
# `default_units` disagree with its declared `units`
# (tests/invalid/units_parameter_default_mismatch.esm pins exactly that).
# ---------------------------------------------------------------------------
_linear(u) = Unitful.absoluteunit(u)
_u_mul(a, b) = _linear(a) * _linear(b)
_u_div(a, b) = _linear(a) / _linear(b)
_u_pow(a, n) = _linear(a)^n

_up_eof(p::_UnitParser) = p.pos > length(p.src)

function _up_skip_space!(p::_UnitParser)
    while !_up_eof(p) && isspace(p.src[p.pos])
        p.pos += 1
    end
end

# Peek at the next non-space character, or `nothing` at end of input.
function _up_peek(p::_UnitParser)
    _up_skip_space!(p)
    _up_eof(p) ? nothing : p.src[p.pos]
end

_up_ident_start(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || c == '_'
_up_ident_cont(c::Char) = _up_ident_start(c) || ('0' <= c <= '9')
# Can `c` BEGIN an atom? This is the lookahead that drives implicit
# multiplication (`"ppb^-1 s^-1"`).
_up_starts_atom(c) = c !== nothing && (_up_ident_start(c) || ('0' <= c <= '9') || c == '(')

# unit := term (('*' | '/')? term)*
#
# Whitespace between two terms means MULTIPLICATION. Division is LEFT
# associative: "L/mol/s" is L·mol⁻¹·s⁻¹, not L/(mol/s).
function _up_unit!(p::_UnitParser)
    u = _up_term!(p)
    while true
        c = _up_peek(p)
        if c == '*' || c == '/'
            p.pos += 1
            rhs = _up_term!(p)
            u = c == '*' ? _u_mul(u, rhs) : _u_div(u, rhs)
        elseif _up_starts_atom(c)
            # Juxtaposition. The scanner is greedy over identifier characters,
            # so `ms` stays ONE symbol (millisecond) rather than m*s —
            # juxtaposition can only arise across a real token boundary.
            u = _u_mul(u, _up_term!(p))
        else
            return u
        end
    end
end

# term := atom (('^' | '**') exponent)?
function _up_term!(p::_UnitParser)
    u = _up_atom!(p)
    c = _up_peek(p)
    if c == '^'
        p.pos += 1
    elseif c == '*' && p.pos + 1 <= length(p.src) && p.src[p.pos + 1] == '*'
        # `**` is the Python/pint spelling of `^` ("Pa*m**3"). `_up_peek` has
        # already skipped whitespace, so `p.pos` is on the first `*`.
        p.pos += 2
    else
        return u
    end
    return _u_pow(u, _up_exponent!(p))
end

# atom := number | symbol | '(' unit ')'
function _up_atom!(p::_UnitParser)
    _up_skip_space!(p)
    _up_eof(p) && throw(_UnitParseError("unexpected end of input"))
    c = p.src[p.pos]

    if c == '('
        p.pos += 1
        u = _up_unit!(p)
        _up_peek(p) == ')' || throw(_UnitParseError("missing ')'"))
        p.pos += 1
        return u
    end

    if '0' <= c <= '9'
        start = p.pos
        while !_up_eof(p) && (('0' <= p.src[p.pos] <= '9') || p.src[p.pos] == '.')
            p.pos += 1
        end
        tok = String(p.src[start:(p.pos - 1)])
        tryparse(Float64, tok) === nothing && throw(_UnitParseError("invalid number '$tok'"))
        # A numeric atom is DIMENSIONALLY the dimensionless unit. Its magnitude
        # is not carried: a `Unitful.Units` object cannot hold a free scalar
        # factor, so `"1000/s"` resolves to the dimension 1/s with the 1000
        # dropped. That is exact for the only numeric atom the grammar really
        # needs (`"1"`), and dimensionally correct for any other; only a
        # CONVERSION-factor check would notice the missing magnitude, and no
        # unit string in the corpus carries one.
        return Unitful.NoUnits
    end

    _up_ident_start(c) || throw(_UnitParseError("unexpected '$c' at position $(p.pos)"))
    start = p.pos
    p.pos += 1
    while !_up_eof(p) && _up_ident_cont(p.src[p.pos])
        p.pos += 1
    end
    sym = String(p.src[start:(p.pos - 1)])
    u = get(_UNIT_REGISTRY, sym, nothing)
    u === nothing && throw(_UnitParseError("unknown unit '$sym'"))
    return u
end

# exponent := integer | decimal | '(' integer '/' integer ')'
#
# RATIONAL exponents are legitimate, not a curiosity: `1/s^0.5` is the noise
# intensity of an SDE and is already in the corpus. A grammar restricted to
# integers cannot express it, and under a hard-error severity that is a FALSE
# REJECTION of a well-formed file — so the exponent is a Rational and the
# result is `Unitful`'s rational-power representation.
function _up_exponent!(p::_UnitParser)
    _up_skip_space!(p)
    _up_eof(p) && throw(_UnitParseError("expected an exponent"))

    # Parenthesised rational: `m^(1/2)`.
    if p.src[p.pos] == '('
        p.pos += 1
        num = _up_signed_int!(p)
        _up_peek(p) == '/' || throw(_UnitParseError("expected '/' in a rational exponent"))
        p.pos += 1
        den = _up_signed_int!(p)
        den == 0 && throw(_UnitParseError("zero denominator in a rational exponent"))
        _up_peek(p) == ')' || throw(_UnitParseError("missing ')' after a rational exponent"))
        p.pos += 1
        return num // den
    end

    start = p.pos
    if p.src[p.pos] == '-' || p.src[p.pos] == '+'
        p.pos += 1
    end
    digits = p.pos
    while !_up_eof(p) && '0' <= p.src[p.pos] <= '9'
        p.pos += 1
    end
    # Decimal: `s^0.5`. A fractional part must follow the dot.
    if !_up_eof(p) && p.src[p.pos] == '.'
        p.pos += 1
        frac = p.pos
        while !_up_eof(p) && '0' <= p.src[p.pos] <= '9'
            p.pos += 1
        end
        (digits == p.pos || frac == p.pos) &&
            throw(_UnitParseError("malformed decimal exponent at position $start"))
        v = parse(Float64, String(p.src[start:(p.pos - 1)]))
        # Unitful represents a non-integer power as a Rational, not a Float.
        return rationalize(v)
    end
    digits == p.pos && throw(_UnitParseError("expected an exponent at position $start"))
    return parse(Int, String(p.src[start:(p.pos - 1)]))
end

# A bare signed integer — the components of a parenthesised rational exponent.
function _up_signed_int!(p::_UnitParser)
    _up_skip_space!(p)
    start = p.pos
    if !_up_eof(p) && (p.src[p.pos] == '-' || p.src[p.pos] == '+')
        p.pos += 1
    end
    digits = p.pos
    while !_up_eof(p) && '0' <= p.src[p.pos] <= '9'
        p.pos += 1
    end
    digits == p.pos && throw(_UnitParseError("expected an integer at position $start"))
    return parse(Int, String(p.src[start:(p.pos - 1)]))
end

"""
    parse_units(unit_str) -> Union{Unitful.Units, Nothing}

Resolve a unit string against the ESM registry (esm-spec §4.8.1) using the ESM
grammar (§4.8.2):

    unit     := term (('*' | '/')? term)*
    term     := atom (('^' | '**') exponent)?
    exponent := integer | decimal | '(' integer '/' integer ')'
    atom     := number | symbol | '(' unit ')'

Whitespace between terms is multiplication (`"ppb^-1 s^-1"`); division is
LEFT-associative (`"L/mol/s"` is L·mol⁻¹·s⁻¹); parentheses group a compound
denominator (`"J/(mol*K)"`). An exponent may be RATIONAL — `"1/s^0.5"` is the
noise intensity of an SDE and is in the corpus.

Normalised before parsing: `µ`/`μ`→`u`, `°C`→`degC`, `Ω`→`Ohm`, `·`/`⋅`→`*`,
`%`→`percent`, and superscript runs (`m²`, `cm³`, `m⁻³`) → `^n`. `""`, `"1"` and
`"dimensionless"` are the dimensionless unit.

Returns `nothing` when the string does not parse or names a symbol outside the
registry. That is a DEFECT IN THE FILE, not a limit of the checker: the
structural validator promotes it to a hard `unit_parse_error` (§4.8.4). It is
therefore silent here — the caller decides the severity, and an incomplete
registry must be fixed by extending the registry, never by downgrading this to
a warning.
"""
function parse_units(unit_str::AbstractString)::Union{Unitful.Units, Nothing}
    s = strip(unit_str)
    if isempty(s) || s == "dimensionless" || s == "1"
        return Unitful.NoUnits
    end

    p = _UnitParser(collect(_normalize_unit_string(s)), 1)
    try
        u = _up_unit!(p)
        _up_skip_space!(p)
        _up_eof(p) || throw(_UnitParseError("unexpected trailing input"))
        return u
    catch e
        e isa _UnitParseError && return nothing
        # Unitful can still reject an otherwise well-formed composition (e.g. a
        # power it cannot represent). Unresolvable is unresolvable.
        e isa ArgumentError && return nothing
        rethrow()
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
# IMPLICIT UNITS ON NUMERIC LITERALS — FABRICATION #1.
#
# A bare number has an INDETERMINATE dimension, not a dimensionless one. Nothing
# in the AST says whether `273.15` is a pure number or a temperature offset,
# whether `0.0224` is a molar volume, or whether `1.23` is a ppb→µg/m³
# conversion factor. `D(n) = 0.001 * droplet_number` (kg m⁻³ s⁻¹ = ? × m⁻³) is
# not an error: the `0.001` IS a rate constant carrying kg s⁻¹. The corpus is
# written this way throughout, and this module's sibling
# `validate_reaction_rate_units` already states the rule — "atmospheric-chemistry
# rate constants routinely carry implicit units on numeric literals, which
# defeats literal dimensional analysis" — and skips such expressions.
#
# This matters BECAUSE a dimensional finding is now a hard error (esm-spec
# §4.8.4): a checker that fails the build must not fabricate a dimension it
# cannot know. Reading `0` as dimensionless is what made `D(y) = 0` with y in kg
# — the ordinary way to say "y is held constant" — look provably inconsistent.
#
# `_expr_dimensions!` therefore returns `nothing` for a literal leaf, and the
# nothing-propagation in `*` and `/` carries the indeterminacy outward. The
# three positions where a literal's meaning IS determined are handled by their
# own rules:
#
#   * ADDITIVE position (`T - 273.15`, `1 - phi`) — dimensionally NEUTRAL: the
#     literal adopts its siblings' dimension, so `_same_dimensions_over` SKIPS
#     literal operands rather than comparing them. An all-literal sum (`1 + 2`)
#     is a pure number.
#   * an EXPONENT (`x^2`) — read by VALUE off the AST, which is what makes `^`
#     computable at all.
#   * a TRANSCENDENTAL ARGUMENT (`exp(2)`) — indeterminate, hence unconstrained,
#     and the result is dimensionless either way.
#
# Costs nothing on the invalid corpus, where every pinned inconsistency is
# stated between DECLARED quantities (`length + mass`, `ln(mass)`, `m^kg`).
# ---------------------------------------------------------------------------
_is_literal(e::ASTExpr) = e isa NumExpr || e isa IntExpr

# The numeric value of a literal AST node, or `nothing` if it is not one. The
# `^` rule reads its exponent through this rather than through the dimensional
# engine (which reports every literal as indeterminate).
function _literal_value(e::ASTExpr)
    e isa IntExpr && return e.value
    (e isa NumExpr && e.value isa Number) && return e.value
    return nothing
end

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
    # An ALL-literal sum (`1 + 2`) is a pure number: nothing carries an implicit
    # unit for the literals to adopt, so the result really is dimensionless.
    isempty(constrained) && return Unitful.NoUnits

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

# "*": multiply dimensions. A SINGLE indeterminate factor makes the whole
# product indeterminate — FABRICATION #2. Skipping the unknown factor and
# returning the product of the known ones silently asserts the unknown one is
# dimensionless, which is exactly wrong for the implicit-unit constants the
# corpus multiplies by: `conc_ppb * 1.23` is a ppb→µg/m³ conversion, and
# reporting its dimension as "ppb" manufactures a mismatch against the declared
# µg/m³. See the conservatism corollary above.
function _product_rule(expr, var_units, findings)
    result = Unitful.NoUnits
    for arg in expr.args
        arg_dim = _expr_dimensions!(findings, arg, var_units)
        arg_dim === nothing && return nothing
        result = result * arg_dim
    end
    return result
end

# "/": divide dimensions. A literal numerator or denominator is indeterminate
# (it carries implicit units), so the quotient is too.
function _quotient_rule(expr, var_units, findings)
    if length(expr.args) != 2
        # Arity is a STRUCTURAL defect, not a dimensional one — not a finding.
        @debug "Division operator requires exactly 2 arguments"
        return nothing
    end

    num_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    den_dim = _expr_dimensions!(findings, expr.args[2], var_units)
    (num_dim === nothing || den_dim === nothing) && return nothing
    return num_dim / den_dim
end

# "^" / "pow": raise the base's dimension to the power. The exponent must be
# dimensionless — a provable inconsistency when its dimension is known and
# non-trivial.
#
# FABRICATION #4: a SYMBOLIC exponent (`x^alpha` — a fitted reaction order is
# ordinary chemistry) makes the result's dimension depend on alpha's RUNTIME
# VALUE, so it is genuinely undeterminable. Assuming the base's dimension
# manufactures a clean `1/s` for `k2 * x^alpha * z^beta` and then reports a
# mismatch against the true LHS, rejecting a valid file.
function _power_rule(expr, var_units, findings)
    if length(expr.args) != 2
        @debug "Power operator requires exactly 2 arguments"
        return nothing
    end

    base_dim = _expr_dimensions!(findings, expr.args[1], var_units)

    # The exponent is read by VALUE off the AST, not through the engine: the
    # engine reports every literal as indeterminate (fabrication #1), and a
    # literal exponent is precisely the case that makes `^` computable.
    power = _literal_value(expr.args[2])

    if power === nothing
        # Non-literal exponent: it must still be dimensionless, and THAT is
        # provable whenever its dimension is known.
        exp_dim = _expr_dimensions!(findings, expr.args[2], var_units)
        if exp_dim !== nothing && dimension(exp_dim) != dimension(Unitful.NoUnits)
            push!(findings, "Exponent must be dimensionless, got '$(_ustr(exp_dim))'" *
                (base_dim === nothing ? "" : " for base with units '$(_ustr(base_dim))'"))
            return nothing
        end
        base_dim === nothing && return nothing
        # A dimensionless base stays dimensionless under ANY exponent; a
        # dimensional one has no static dimension under a symbolic exponent.
        dimension(base_dim) == dimension(Unitful.NoUnits) && return Unitful.NoUnits
        return nothing
    end

    base_dim === nothing && return nothing
    # A literal INTEGER or RATIONAL exponent is determinable (esm-spec §4.8.3).
    # Unitful represents rational powers, so `x^0.5` on `m^2` is `m`; a power it
    # cannot represent is unknown, not an inconsistency.
    try
        return isinteger(power) ? base_dim^Int(power) : base_dim^rationalize(float(power))
    catch
        return nothing
    end
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

# "sin"/"cos"/"tan": the argument is an ANGLE — `rad`, `deg`, or a plain
# dimensionless number. Anything with a real dimension (`sin(kg)`) is a provable
# inconsistency. The result is a dimensionless ratio.
#
# `rad` is dimensionless in this engine (Unitful models it as `NoDims`), so the
# angle case and the plain-number case coincide and the test below covers both.
# It is written as its own rule anyway, because a binding whose dimension vector
# carries `rad` as a BASE AXIS must accept `rad` here explicitly.
function _circular_arg_rule(expr, var_units, findings)
    if length(expr.args) != 1
        @debug "Function $(expr.op) requires exactly 1 argument"
        return nothing
    end
    arg_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    if arg_dim !== nothing && dimension(arg_dim) != dimension(Unitful.NoUnits) &&
       dimension(arg_dim) != dimension(u"rad")
        push!(findings, "Circular function argument must be an angle or " *
                        "dimensionless, got units '$(_ustr(arg_dim))' " *
                        "(function '$(expr.op)')")
        return nothing
    end
    return Unitful.NoUnits
end

# "asin"/"acos"/"atan": the argument is a dimensionless ratio; the result is an
# ANGLE. Returning "dimensionless" instead is what makes
# `solar_zenith_angle: "rad"` — computed by `acos(cos_zenith)` in the shipped
# `lib/solar.esm` — a guaranteed mismatch under any registry that treats `rad`
# as a base axis.
function _inverse_circular_rule(expr, var_units, findings)
    if length(expr.args) == 2
        # `atan2(y, x)`: the two operands need only be COMMENSURATE — their
        # ratio is the dimensionless tangent — and the result is an angle.
        _same_dimensions_over(expr.args, var_units, findings,
            (a, b) -> "atan2 operands must have the same units, got " *
                      "'$(_ustr(a))' and '$(_ustr(b))'")
        return u"rad"
    end
    if length(expr.args) != 1
        @debug "Function $(expr.op) requires exactly 1 argument"
        return nothing
    end
    arg_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    if arg_dim !== nothing && dimension(arg_dim) != dimension(Unitful.NoUnits)
        push!(findings, "Inverse circular function argument must be " *
                        "dimensionless, got units '$(_ustr(arg_dim))' " *
                        "(function '$(expr.op)')")
        return nothing
    end
    return u"rad"
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

# "<", ">", "<=", ">=", "==", "!=": the operands must be mutually commensurate
# (comparing a length to a mass is provably wrong); the result is a
# dimensionless boolean. Literal operands are dimension-neutral here for the
# same reason they are under "+" — `x > 0` says nothing about the units of 0.
function _comparison_rule(expr, var_units, findings)
    _same_dimensions_over(expr.args, var_units, findings,
        (first_dim, dim) -> "Cannot compare quantities with different units: " *
            "'$(_ustr(first_dim))' $(expr.op) '$(_ustr(dim))'")
    return Unitful.NoUnits
end

# "abs": preserves dimensions.
function _preserve_dimension_rule(expr, var_units, findings)
    length(expr.args) == 1 || return nothing
    return _expr_dimensions!(findings, expr.args[1], var_units)
end

# "D": derivative — the differentiated variable's dimension over the `wrt`
# variable's dimension.
#
# FABRICATION #3: an UNDECLARED independent variable has an unknown dimension,
# so the derivative's dimension is unknown too. Defaulting `t` to SECONDS is a
# false-positive factory: in a nondimensionalized model (state and RHS both
# declared "1", `t` undeclared) it manufactures `1/s` on the left against `1` on
# the right and reports a mismatch in a perfectly well-formed file.
#
# No coverage is lost. The EQUATION-level rule (`equation_unit_findings`) still
# rejects a derivative equation that no choice of time unit could reconcile,
# which is what the invalid corpus actually pins.
function _derivative_rule(expr, var_units, findings)
    wrt = expr.wrt !== nothing ? expr.wrt : "t"
    # esm-spec §4.2 "Arity of `D`": the STRUCTURAL time derivative is strictly
    # unary, but a REWRITE-TARGET `D` (spatial `wrt`) MAY carry trailing
    # auxiliary operands after `args[1]` — the per-face boundary/halo values a
    # discretization rule binds and consumes. They carry no evaluator semantics,
    # so the dimensional rule reads `args[1]` alone and ignores the rest.
    max_args = wrt == "t" ? 1 : typemax(Int)
    if length(expr.args) < 1 || length(expr.args) > max_args
        @debug "Derivative operator D requires exactly 1 argument"
        return nothing
    end

    var_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    haskey(var_units, wrt) || return nothing
    wrt_dim = _absolute_unit(parse_units(var_units[wrt]))

    (var_dim === nothing || wrt_dim === nothing) && return nothing
    return var_dim / wrt_dim
end

# The five dimensional-rule op classes, DERIVED from the op registry's
# `dim_class` column (src/op_registry.jl, `_ops_with_dim_class`); memberships
# are pinned literal-for-literal by test/op_registry_test.jl.
#
# The transcendental / dimensionless-argument function names.
# `sqrt` is NOT here: it halves its argument's dimension (`_sqrt_rule`) rather
# than requiring a dimensionless one. The union adds the spec-adjacent
# spellings this rule has always accepted (`ln`, `log2`, `expm1`) — they have
# NO registry row on purpose: an op absent from the registry is classified by
# `_op_in_T` (lower_expression_templates.jl) as an open-namespace rewrite
# target, and giving these spellings rows would silently change that.
const _TRANSCENDENTAL_OPS = union(_ops_with_dim_class(:transcendental),
                                  Set(["ln", "log2", "expm1"]))

# CIRCULAR functions take an ANGLE. An angle is dimensionless (a ratio of two
# lengths) — Unitful models `rad` with `NoDims`, and this rule is written so it
# stays correct under a registry that instead carries `rad` as its own axis:
# `sin` accepts an angle OR a plain dimensionless number, and REJECTS anything
# else (`sin(kg)` is still an error).
const _CIRCULAR_OPS = _ops_with_dim_class(:circular)

# INVERSE circular functions RETURN an angle. Asserting they return
# "dimensionless" is what breaks `solar_zenith_angle: "rad"` in the shipped
# stdlib (`lib/solar.esm`), where it is computed by `acos(cos_zenith)`: under a
# registry with `rad` as a base axis that is a GUARANTEED mismatch. Returning
# `rad` is right under both conventions, since `rad` is dimensionless here.
const _INVERSE_CIRCULAR_OPS = _ops_with_dim_class(:inverse_circular)

# Comparisons and the boolean connectives. Their operands must be mutually
# commensurate (esm-spec §4.8.3) and the RESULT is a dimensionless boolean.
const _COMPARISON_OPS = _ops_with_dim_class(:comparison)
const _BOOLEAN_OPS = _ops_with_dim_class(:boolean)

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
        # `Pre` PRESERVES its operand's dimension (esm-spec §4.8.3) — it names
        # the operand's value at the previous step, not a dimensionless one.
        "Pre"    => _preserve_dimension_rule,
        "D"      => _derivative_rule,
    )
    for op in _TRANSCENDENTAL_OPS
        rules[op] = _dimensionless_arg_rule
    end
    for op in _CIRCULAR_OPS
        rules[op] = _circular_arg_rule
    end
    for op in _INVERSE_CIRCULAR_OPS
        rules[op] = _inverse_circular_rule
    end
    for op in _COMPARISON_OPS
        rules[op] = _comparison_rule
    end
    for op in _BOOLEAN_OPS
        # A boolean connective's operands are already booleans; the result is a
        # dimensionless boolean either way.
        rules[op] = _dimensionless_result_rule
    end
    rules
end

# The engine proper. Returns the expression's dimension, or `nothing` when it
# cannot be determined; every PROVABLE inconsistency encountered anywhere in the
# subtree is appended to `findings`. See the invariant at the top of this block.
function _expr_dimensions!(findings::Vector{String}, expr::ASTExpr,
                           var_units::AbstractDict)::Union{Unitful.Units, Nothing}
    if expr isa NumExpr || expr isa IntExpr
        # A bare number's dimension is INDETERMINATE, not dimensionless — see
        # the implicit-units note (fabrication #1). The three positions where a
        # literal's meaning IS determined are handled by their own rules.
        return nothing
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
    # to say "y is held constant"; the literal carries the implicit units kg/s.
    # No special case is needed for it any more — a literal's dimension is
    # INDETERMINATE (fabrication #1), so `rhs_dim` below comes back `nothing`
    # and the comparison is skipped, exactly as it should be.

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
    UnitFinding

A units finding: `subpath` RELATIVE to the owning model's JSON pointer (e.g.
`"equations/0"`, `"variables/invalid_sum"`), a human-readable `message`, and the
esm-spec §4.8.4 severity `code`.

Both codes are HARD ERRORS — the type exists to distinguish *why* the file is
wrong, not to distinguish an error from a warning. An UNDETERMINABLE dimension
is never a finding at all: it is reported by returning `nothing` from the
engine, and the enclosing check is skipped.
"""
struct UnitFinding
    subpath::String
    message::String
    code::String
end

# esm-spec §4.8.4. A PROVABLE dimensional inconsistency; the structural layer
# emits it as `unit_inconsistency`.
const UNIT_DIMENSION_MISMATCH = "unit_inconsistency"
# A declared unit string that does not parse under the §4.8.2 grammar or names a
# symbol outside the §4.8.1 registry. A defect in the FILE, not a limit of the
# checker — so it is a hard error, never a warning, and never silently coerced
# to dimensionless (which would disable every dimensional check downstream of
# it: a typo like `"1/time"` or `"m/s2"` would simply turn the checker off).
const UNIT_PARSE_ERROR = "unit_parse_error"

"""
    model_unit_findings(model::Model) -> Vector{UnitFinding}

Every units finding in `model`. Callers prefix their JSON pointer and promote
each finding to a structural error under its own code; see
`validate_model_unit_consistency` in validate.jl, the single structural caller.

Four families are checked:

1. **Unresolvable unit strings** (`unit_parse_error`) — a `units` or
   `default_units` string that does not resolve against the registry.
2. **Declared vs default units** — a parameter whose `default` is supplied in
   `default_units` that are not the same unit as its declared `units`.
3. **Observed-variable defining expressions** — an inconsistency *inside* the
   `expression` of an observed variable (`length + mass`, `exp(mass)`, …).
   The declared units of the variable are deliberately NOT compared against the
   computed dimension of its expression: that comparison is a different (and
   much more false-positive-prone) rule, and the shared corpus does not pin it.
4. **Equations** — an inconsistency inside either side, or an LHS/RHS mismatch.

Subsystems are NOT recursed here (the caller owns path construction and does the
recursion), keeping this function's pointers purely model-local.

Iteration over `model.variables` is sorted by name so the finding order is
deterministic regardless of Dict hashing.
"""
function model_unit_findings(model::Model)::Vector{UnitFinding}
    # Only EXPLICITLY declared units enter the environment, and only those that
    # RESOLVE. A variable with no declared units is unknown, not dimensionless;
    # one whose declared units do not resolve is reported separately below and
    # then treated as unknown, so a single bad string cannot cascade into a
    # bogus mismatch at every site that mentions the variable.
    var_units = Dict{String, String}()
    for (name, var) in model.variables
        var.units !== nothing && !isempty(var.units) &&
            parse_units(var.units) !== nothing && (var_units[name] = var.units)
    end

    out = UnitFinding[]

    for name in sort!(collect(keys(model.variables)))
        var = model.variables[name]

        # 1. Unresolvable unit strings — a defect in the file (§4.8.4).
        for (field, str) in (("units", var.units), ("default_units", var.default_units))
            str === nothing && continue
            isempty(str) && continue
            parse_units(str) === nothing || continue
            push!(out, UnitFinding("variables/$name",
                "Unit string '$str' is not a recognised unit " *
                "(variable '$name', field '$field')", UNIT_PARSE_ERROR))
        end

        # 2. default_units vs units.
        du, u = var.default_units, var.units
        if du !== nothing && !isempty(du) && u !== nothing && !isempty(u) && du != u
            du_parsed, u_parsed = parse_units(du), parse_units(u)
            if du_parsed !== nothing && u_parsed !== nothing && du_parsed != u_parsed
                push!(out, UnitFinding("variables/$name",
                    "Parameter default value units do not match declared units " *
                    "(variable '$name', declared_units='$u', default_units='$du')",
                    UNIT_DIMENSION_MISMATCH))
            end
        end

        # 3. observed-variable defining expression.
        if var.expression !== nothing
            internal = expression_unit_findings(var.expression, var_units)
            for msg in internal
                push!(out, UnitFinding("variables/$name", "$msg (variable '$name')",
                                       UNIT_DIMENSION_MISMATCH))
            end

            # 3b. DECLARED units vs the dimension its expression actually has.
            # `{units: "m", expression: length + mass}` is exactly as wrong as
            # the equation `x = length + mass`; it just lives in the variable
            # table. Skipped unless BOTH sides are known — an undeclared unit is
            # not an error, and an unresolvable one is already reported above.
            # Only when the expression was internally clean, so one defect is
            # not reported twice.
            declared = get(var_units, name, nothing)
            if isempty(internal) && declared !== nothing
                got = _expr_dimensions!(String[], var.expression, var_units)
                want = _absolute_unit(parse_units(declared))
                if got !== nothing && want !== nothing &&
                   dimension(got) != dimension(want)
                    push!(out, UnitFinding("variables/$name",
                        "Observed variable '$name' is declared '$declared' but its " *
                        "expression has units '$(_ustr(got))'",
                        UNIT_DIMENSION_MISMATCH))
                end
            end
        end
    end

    # 4. equations.
    for (i, eq) in enumerate(model.equations)
        for msg in equation_unit_findings(eq, var_units)
            push!(out, UnitFinding("equations/$(i-1)", msg, UNIT_DIMENSION_MISMATCH))
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
    for f in findings
        @warn "Unit finding at $(f.subpath) [$(f.code)]: $(f.message)"
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