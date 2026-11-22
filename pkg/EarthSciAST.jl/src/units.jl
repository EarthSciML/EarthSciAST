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
# `Unitful.uparse` is not used: it is the wrong tool for a cross-binding
# contract for three reasons:
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

# The International Table BTU — exactly 1055.05585262 J (esm-spec §4.8.1), NOT
# Unitful's `btu`, which is the rounded 1055.06 J. A scale error is invisible to
# dimensional analysis, so the registry entry is defined here rather than borrowed.
Unitful.@unit _u_btu "BTU" InternationalTableBTU 1055.05585262 * Unitful.u"J" false

# Microatmosphere — the standard unit of seawater pCO2. Unitful defines `atm`
# without an SI-prefix mechanism, so `uatm` must be spelled out.
Unitful.@unit _u_uatm "uatm" MicroAtmosphere 1.0e-6 * Unitful.u"atm" false

# `Dobson` / `DU`: the areal number density of ozone in a column. One DU is a
# 10 µm-thick layer of pure O3 at STP — 2.6867e20 molec/m^2 (the Loschmidt
# constant times 10 µm). `molec` is a dimensionless COUNT, so the DIMENSION is
# [length]^-2 and the m^-2 is real, not an artefact: a Dobson unit is NOT
# dimensionless. The scale is carried too, so `uconvert` between DU and
# `molec/m^2` is exact.
Unitful.@unit _u_dobson "DU" DobsonUnit 2.6867e20 * Unitful.u"m"^-2 false

# The international foot, exact by definition since 1959: 1 ft = 0.3048 m. It is
# in the table because emission inventories are WRITTEN in it — the EPA FF10
# point-source format stores STKHGT and STKDIAM in feet — and a format for
# air-quality models that cannot spell the unit its own input files use forces
# every such column to be declared in a unit it is not stored in. Spelled out
# here rather than taken from Unitful so this table stays the only statement of
# what `ft` means. It has no long-form alias: `foot`/`feet` are pinned as
# REJECTS by tests/conformance/unit_registry.
Unitful.@unit _u_ft "ft" InternationalFoot 0.3048 * Unitful.u"m" false

# The international mile, exact by definition since the same 1959 agreement:
# 1 mi = 5280 ft = 1609.344 m. The US onroad transportation inventory is written
# in it end to end — EPA MOVES stores `link.linkLength` in miles,
# `link.linkAvgSpeed` in `mi/h`, and its whole activity model is built on
# vehicle-MILES travelled. Written as `5280 * _u_ft` — the entry ABOVE, not
# Unitful's own `mi` and not a retyped 1609.344 — so the two cannot drift
# apart; 5280 × 0.3048 is 1609.344 with no rounding in binary64. `mi/h`
# composes from this and `hr`; `mph` is deliberately not a name, and neither
# are `in` and `yd`, which no corpus column uses.
Unitful.@unit _u_mi "mi" InternationalMile 5280 * _u_ft false

# The international avoirdupois pound, exact by definition since 1959:
# 1 lb = 0.45359237 kg — and exactly `short_ton` / 2000, so the registry held
# the DERIVED unit and not the one it is defined in. US emission rates are
# tabulated in it: MOVES's NONROAD brake-specific fuel consumption is
# `lb/(hp*h)` and its gasoline density constant CMFGAS is 6.237 lb/gal.
Unitful.@unit _u_lb "lb" AvoirdupoisPound 0.45359237 * Unitful.u"kg" false

# Mechanical (imperial) horsepower — 550 ft*lbf/s = 745.6998715822702 W
# (NIST SP 811 App. B gives 7.456 999 E+02 W). Written as the ft*lbf/s product
# of the `_u_ft` and `_u_lb` DEFINED ABOVE and standard gravity — not as a
# retyped literal — so it cannot drift away from the two entries that define
# it, and emphatically NOT the metric horsepower (PS, 735.49875 W). `lbf` is
# `lb` × g0, hence the m/s^2 that turns ft*lb into ft*lbf and the third second
# that turns ft*lbf into a power. Unitful folds the product left to right, so
# the basefactor is the same bits the other four bindings compute.
# Engine ratings are the axis MOVES's NONROAD model bins on:
# `nrsourceusetype.hpAvg` is horsepower and every `nremissionrate` row is
# `g/(hp*h)`.
Unitful.@unit _u_hp "hp" MechanicalHorsepower 550 * _u_ft * _u_lb * 9.80665 * Unitful.u"m" / Unitful.u"s"^3 false

# The US liquid gallon, exact by definition: 231 in^3 = 3.785411784 L
# (NIST SP 811 App. B) — NOT the imperial gallon, which is 20% larger and which
# a dimension-only check cannot tell apart from it. US fuel data is per gallon:
# MOVES stores `fueltype.fuelDensity` in g/gal, its refuelling spill rate in
# g/gal, and its dioxin and metal emission rates in g/gal.
Unitful.@unit _u_gal "gal" USLiquidGallon 3.785411784 * Unitful.u"L" false

# Inch of mercury — exactly 25.4 mmHg, the conventional value (NIST SP 811).
# US barometric datasets store pressure in inHg; without this entry such a
# column has no honest declaration, because a unit string carries no numeric
# scale factor, so `25.4 mmHg` cannot be spelled either.
Unitful.@unit _u_inHg "inHg" InchOfMercury 3386.388640341 * Unitful.u"Pa" false

# The two tons, both spelled UNAMBIGUOUSLY and neither spelled `ton`. A bare
# `ton` is three different masses (short 907.18474 kg, metric 1000 kg, long
# 1016.0469088 kg), and a table whose job is to make a declared unit mean ONE
# thing cannot hold a name that means three. `t` is excluded for the same reason
# `d` is: a one-letter mass symbol reads as tera- to half its readers.
#
# `short_ton` is exactly 2000 international pounds, so it is written as
# `2000 * _u_lb` rather than as 907.18474: it is what a US emissions inventory
# means by "tons", and exactly InMAP's 907184740000 µg/short-ton
# emission-conversion constant. `tonne` is the metric ton, so that choosing
# between them is something a document DOES rather than something it cannot
# express.
Unitful.@unit _u_short_ton "short_ton" ShortTon 2000 * _u_lb false
Unitful.@unit _u_tonne "tonne" MetricTon 1000 * Unitful.u"kg" false

# The flat table, grouped exactly as esm-spec §4.8.1 lists it.
const _UNIT_REGISTRY = Dict{String, Unitful.Units}(
    # SI base.
    "m" => u"m", "kg" => u"kg", "s" => u"s", "mol" => u"mol",
    "K" => u"K", "A" => u"A", "cd" => u"cd", "rad" => u"rad",

    # Mass. `short_ton` / `tonne` are spelled in full on purpose (see above);
    # `ton` and `t` are deliberately NOT registry symbols.
    "g" => u"g", "mg" => u"mg", "ug" => u"μg", "ng" => u"ng", "lb" => _u_lb,
    "short_ton" => _u_short_ton, "tonne" => _u_tonne,

    # Length.
    "dm" => u"dm", "cm" => u"cm", "mm" => u"mm", "um" => u"μm",
    "nm" => u"nm", "km" => u"km", "ft" => _u_ft, "mi" => _u_mi,

    # Time. `h` is the HOUR here, not Unitful's Planck constant.
    #
    # `d` is deliberately NOT a registry symbol. The canonical spelling of the
    # day is `day`: a bare `d` reads as a deci- prefix or as a differential, so
    # §4.8.1 excludes it and the stdlib is spelled `day`.
    "ms" => u"ms", "us" => u"μs", "ns" => u"ns", "min" => u"minute",
    "h" => u"hr", "hr" => u"hr", "day" => u"d",
    "yr" => u"yr", "year" => u"yr",

    # Volume.
    "L" => u"L", "l" => u"L", "mL" => u"mL", "gal" => _u_gal,

    # Amount of substance. `M` is molarity (mol/L).
    "kmol" => u"kmol", "mmol" => u"mmol", "umol" => u"μmol",
    "nmol" => u"nmol", "M" => u"M",

    # Derived.
    "Hz" => u"Hz", "N" => u"N", "mN" => u"mN", "dyn" => u"dyn", "Pa" => u"Pa",
    "J" => u"J", "kJ" => u"kJ", "MJ" => u"MJ",
    "cal" => u"cal", "kcal" => u"kcal", "W" => u"W", "kW" => u"kW", "MW" => u"MW",
    "hp" => _u_hp,

    # Pressure.
    "atm" => u"atm", "bar" => u"bar", "hPa" => u"hPa", "kPa" => u"kPa",
    "mbar" => u"mbar", "Torr" => u"Torr", "mmHg" => _u_mmHg,
    "inHg" => _u_inHg, "psi" => u"psi",

    # Energy.
    "erg" => u"erg", "BTU" => _u_btu, "Wh" => u"W*hr", "kWh" => u"kW*hr",

    # Electromagnetic. `C` is the COULOMB, per SI — never Celsius. Binding it
    # to Celsius injects a temperature dimension into every electromagnetic
    # expression: charge × field then comes out kg*m*K/(s^3*A) instead of a
    # newton. Celsius has its own unambiguous spellings, `degC` and `°C`.
    "C" => u"C", "V" => u"V", "Ohm" => u"Ω", "F" => u"F", "T" => u"T",

    # Temperature / plane angle. The affine OFFSET of degC/degF is irrelevant
    # to dimensional analysis and is not modelled (see `_absolute_unit`).
    "degC" => u"°C", "degF" => u"°F", "deg" => u"°",

    # Solid angle — the steradian, `sr = rad^2` (esm-spec §4.8.1). `rad` is an
    # axis, so a solid angle is that axis SQUARED, not a ninth axis. Unitful
    # models both `rad` and `sr` as `NoDims`; `u"sr"` is the canonical
    # steradian and is commensurate with `u"rad"^2`. Spherical-mesh cell areas
    # (a patch of the unit sphere — MPAS Voronoi cells, Girard triangles)
    # declare `units: "sr"`, so this makes those declarations resolve.
    "sr" => u"sr",

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
#
# This is the WHOLE §4.8.2 rewrite table. A degree sign is rewritten only as
# part of `°C`/`°F`: a bare `°` (or `°K`) stays an unexpected character and the
# string does not resolve. `%` is NOT rewritten here: it is a one-character
# symbol token of its own (`_canon_lex`), so `%h` is `%`·`h`.
const _UNIT_SPELLINGS = [
    "\u00B0C" => "degC",
    "\u00B0F" => "degF",
    "\u00B5" => "u",      # MICRO SIGN
    "\u03BC" => "u",      # GREEK SMALL LETTER MU
    "\u03A9" => "Ohm",    # GREEK CAPITAL LETTER OMEGA
    "\u2126" => "Ohm",    # OHM SIGN
    "\u00B7" => "*",      # MIDDLE DOT — multiplication
    "\u22C5" => "*",      # DOT OPERATOR — multiplication
]

# Superscript digits and the superscript minus. A RUN of these is an exponent:
# `m²` is `m^2`, `m⁻³` is `m^-3`.
const _SUPERSCRIPTS = Dict{Char, Char}(
    '⁰' => '0', '¹' => '1', '²' => '2', '³' => '3', '⁴' => '4',
    '⁵' => '5', '⁶' => '6', '⁷' => '7', '⁸' => '8', '⁹' => '9',
    '⁻' => '-',
)
const _SUPERSCRIPT_DIGITS = ('⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹')

function _normalize_unit_string(s::AbstractString)::String
    out = String(s)
    for (from, to) in _UNIT_SPELLINGS
        occursin(from, out) && (out = replace(out, from => to))
    end

    any(c -> haskey(_SUPERSCRIPTS, c), out) || return out

    # A run of superscript DIGITS is one exponent (`m¹²` is `m^12`), and a
    # superscript minus is rewritten only together with the digits right after
    # it (`m⁻³` is `m^-3`). A minus anywhere else stays an unexpected
    # character, so `s⁻1` does not resolve, and `m²⁻¹` is the two exponents
    # `m^2^-1`, not one exponent `-21` (esm-spec §4.8.2, Lean `normalize`).
    cs = collect(out)
    io = IOBuffer()
    i = 1
    while i <= length(cs)
        c = cs[i]
        minus = c == '⁻' && i < length(cs) && cs[i + 1] in _SUPERSCRIPT_DIGITS
        if minus || c in _SUPERSCRIPT_DIGITS
            print(io, minus ? "^-" : "^")
            i += minus ? 1 : 0
            while i <= length(cs) && cs[i] in _SUPERSCRIPT_DIGITS
                print(io, _SUPERSCRIPTS[cs[i]])
                i += 1
            end
        else
            print(io, c)
            i += 1
        end
    end
    return String(take!(io))
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
_u_pow(a, n) = _linear(a)^n

# §4.8.2 whitespace is ASCII: space, tab, carriage return, line feed.
_up_space(c::Char) = c == ' ' || c == '\t' || c == '\r' || c == '\n'

_up_digit(c::Char) = '0' <= c <= '9'
# The §4.8.2 identifier characters: a RUN of these is one token.
_up_ident(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || _up_digit(c) || c == '_'

"""
    parse_units_reason(unit_str) -> Union{String, Nothing}

WHY [`parse_units`](@ref) returned `nothing`, or `nothing` when it did not.

`parse_units` is deliberately silent — the caller owns the severity (§4.8.4) —
but one rejection has a reason an author cannot guess from the string: a
numeric SCALING FACTOR. `"(m/s)^-1/3"` LOOKS like a rational exponent and the
§4.8.2 grammar reads it as `((m/s)^-1)/3`. This accessor exists so that reason
can be surfaced and pinned (`tests/conformance/unit_registry`) without changing
the corpus-pinned `unit_parse_error` message text.
"""
function parse_units_reason(unit_str::AbstractString)::Union{String, Nothing}
    isempty(unit_str) && return nothing
    r = _resolve_units(unit_str)
    return r isa String ? r : nothing
end

"""
    parse_units(unit_str) -> Union{Unitful.Units, Nothing}

Resolve a unit string against the ESM registry (esm-spec §4.8.1) using the ESM
grammar (§4.8.2):

    unit     := term (('*' | '/')? term)*
    term     := atom (('^' | '**') exponent)?
    exponent := '-'? (integer | decimal) | '(' '-'? integer '/' '-'? integer ')'
    atom     := '1' | symbol | '(' unit ')'

A symbol is a whole run of `[A-Za-z0-9_]` (or `%`) and must be a table key;
the only numeric atom is the literal `1`. Whitespace between terms is
multiplication (`"ppb^-1 s^-1"`); division is LEFT-associative (`"L/mol/s"` is
L·mol⁻¹·s⁻¹); parentheses group a compound denominator (`"J/(mol*K)"`). An
exponent may be RATIONAL — `"1/s^0.5"` is the noise intensity of an SDE.

Normalised before parsing: `µ`/`μ`→`u`, `°C`→`degC`, `°F`→`degF`, `Ω`→`Ohm`,
`·`/`⋅`→`*`, and superscript runs (`m²`, `cm³`, `m⁻³`) → `^n`. `""`, `"1"` and
`"dimensionless"` are the dimensionless unit.

The string is parsed once, by the parser the canonical spelling uses
(`_unit_factors`), and its factor list is resolved through the registry. A
string that is a single symbol to the first power (`"degC"`, `"(degC)"`) is the
registry entry itself, so a standalone affine unit keeps its identity; inside a
composition an affine unit is its absolute counterpart (`_linear`).

Returns `nothing` when the string does not parse or names a symbol outside the
registry. That is a DEFECT IN THE FILE, not a limit of the checker: the
structural validator promotes it to a hard `unit_parse_error` (§4.8.4). It is
silent here — the caller decides the severity.
"""
function parse_units(unit_str::AbstractString)::Union{Unitful.Units, Nothing}
    # Only "" is the empty unit. A whitespace-only string has no tokens and is
    # rejected by the grammar (§4.8.2), not read as dimensionless.
    isempty(unit_str) && return Unitful.NoUnits
    r = _resolve_units(unit_str)
    return r isa String ? nothing : r
end

# The unit `unit_str` denotes, or the reason it denotes none.
function _resolve_units(unit_str::AbstractString)
    fs = _unit_factors(unit_str)
    fs isa String && return fs
    units = Any[]
    for (sym, _) in fs
        u = sym == "%" ? u"percent" : get(_UNIT_REGISTRY, sym, nothing)
        u === nothing && return "unknown unit '$sym'"
        push!(units, u)
    end
    length(fs) == 1 && isone(fs[1][2]) && return units[1]
    out = Unitful.NoUnits
    try
        for (u, (_, q)) in zip(units, fs)
            out = _u_mul(out, _u_pow(u, _unit_exponent(q)))
        end
    catch e
        # Unitful can still reject an otherwise well-formed composition (a
        # power it cannot represent). Unresolvable is unresolvable.
        (e isa ArgumentError || e isa OverflowError || e isa InexactError) ||
            rethrow()
        return sprint(showerror, e)
    end
    return out
end

# A factor exponent as Unitful takes it: an `Int` when integral.
_unit_exponent(q::Rational{BigInt}) =
    isone(denominator(q)) ? Int(numerator(q)) : Rational{Int}(q)

# ---------------------------------------------------------------------------
# The §4.8.2 lexer and parser, ports of the Lean `Esm.Units.lex` and
# `Esm.Units.parse` (formal/Esm/Units/), and the canonical unit spelling
# (esm-spec §4.8.2 "Canonical spelling", the Lean `Esm.Units.canon`;
# tests/conformance/canonical/unit_spelling.json pins its output).
#
# The parser builds a factor list and keeps every symbol as written: resolving
# the symbols through the registry is `parse_units`' step, so the spelling
# keeps a symbol the registry does not know (`km` stays `km`, and nothing
# cancels across the fraction bar: `mol/mol` stays `mol/mol`).
# ---------------------------------------------------------------------------

# One token: `kind` is :sym, :num, :star, :dstar, :slash, :caret, :lp, :rp or
# :minus; `text` is the spelling of a symbol or number; `value` and `isint` are
# a number's exact value and whether it is an integer.
struct _CanonTok
    kind::Symbol
    text::String
    value::Rational{BigInt}
    isint::Bool
end
_CanonTok(kind::Symbol) = _CanonTok(kind, "", 0 // 1, false)

const _CANON_OPERATORS = Dict{Char, Symbol}(
    '/' => :slash, '^' => :caret, '(' => :lp, ')' => :rp, '-' => :minus,
)

_canon_digit_run(cs) = !isempty(cs) && all(_up_digit, cs)
_canon_digits_value(cs) = parse(BigInt, String(cs))

# The §4.8.2 tokens, read as the Lean lexer `Esm.Units.lex` reads them.
# `nothing` when a character is outside the token rules.
function _canon_lex(cs::Vector{Char})::Union{Vector{_CanonTok}, Nothing}
    toks = _CanonTok[]
    i, n = 1, length(cs)
    while i <= n
        c = cs[i]
        if _up_space(c)
            i += 1
        elseif c == '*'
            if i < n && cs[i + 1] == '*'
                push!(toks, _CanonTok(:dstar))
                i += 2
            else
                push!(toks, _CanonTok(:star))
                i += 1
            end
        elseif haskey(_CANON_OPERATORS, c)
            push!(toks, _CanonTok(_CANON_OPERATORS[c]))
            i += 1
        elseif c == '%'
            push!(toks, _CanonTok(:sym, "%", 0 // 1, false))
            i += 1
        elseif _up_ident(c)
            j = i
            while j <= n && _up_ident(cs[j])
                j += 1
            end
            run = cs[i:(j - 1)]
            if !_canon_digit_run(run)
                push!(toks, _CanonTok(:sym, String(run), 0 // 1, false))
                i = j
            elseif j < n && cs[j] == '.' && _up_digit(cs[j + 1])
                k = j + 1
                while k <= n && _up_ident(cs[k])
                    k += 1
                end
                frac = cs[(j + 1):(k - 1)]
                lit = String(cs[i:(k - 1)])
                if _canon_digit_run(frac)
                    v = _canon_digits_value(run) + _canon_digits_value(frac) // big(10)^length(frac)
                    push!(toks, _CanonTok(:num, lit, v, false))
                else
                    # `1.5m` is one symbol, and no table key can match it.
                    push!(toks, _CanonTok(:sym, lit, 0 // 1, false))
                end
                i = k
            else
                push!(toks, _CanonTok(:num, String(run), _canon_digits_value(run) // 1, true))
                i = j
            end
        else
            return nothing
        end
    end
    return toks
end

const _CanonFactor = Tuple{String, Rational{BigInt}}

# Thrown inside the parser on input outside the grammar, with the reason.
struct _CanonFail <: EarthSciASTError
    msg::String
end
_CanonFail() = _CanonFail("malformed unit string")

mutable struct _CanonParser
    toks::Vector{_CanonTok}
    i::Int
end

_cp_kind(p::_CanonParser, ahead::Int = 0) =
    p.i + ahead <= length(p.toks) ? p.toks[p.i + ahead].kind : :eof
function _cp_take!(p::_CanonParser)
    t = p.toks[p.i]
    p.i += 1
    return t
end

# The §4.8.2 grammar (`Esm.Units.parse`), building the factor list
# (`UExpr.factors`) as it goes: `*` and juxtaposition concatenate, `/` negates
# the exponents of its right operand, `^q` scales every exponent below it, and
# the atom `1` and the symbol `dimensionless` contribute nothing.
function _cp_unit!(p::_CanonParser)::Vector{_CanonFactor}
    acc = _cp_term!(p)
    while true
        k = _cp_kind(p)
        if k == :star
            _cp_take!(p)
            append!(acc, _cp_term!(p))
        elseif k == :slash
            _cp_take!(p)
            append!(acc, [(s, -q) for (s, q) in _cp_term!(p)])
        elseif k in (:num, :sym, :lp)
            append!(acc, _cp_term!(p))
        else
            return acc
        end
    end
    return acc
end

function _cp_term!(p::_CanonParser)::Vector{_CanonFactor}
    fs = _cp_atom!(p)
    if _cp_kind(p) in (:caret, :dstar)
        _cp_take!(p)
        q = _cp_exponent!(p)
        fs = _CanonFactor[(s, q * e) for (s, e) in fs]
    end
    return fs
end

function _cp_exponent!(p::_CanonParser)::Rational{BigInt}
    if _cp_kind(p) == :minus && _cp_kind(p, 1) == :num
        _cp_take!(p)
        return -_cp_take!(p).value
    elseif _cp_kind(p) == :num
        return _cp_take!(p).value
    elseif _cp_kind(p) == :lp
        _cp_take!(p)
        a = _cp_signed_integer!(p)
        _cp_kind(p) == :slash || throw(_CanonFail())
        _cp_take!(p)
        b = _cp_signed_integer!(p)
        (_cp_kind(p) == :rp && !iszero(b)) || throw(_CanonFail())
        _cp_take!(p)
        return a // b
    end
    throw(_CanonFail())
end

function _cp_signed_integer!(p::_CanonParser)::Rational{BigInt}
    negative = _cp_kind(p) == :minus
    j = p.i + (negative ? 1 : 0)
    (j <= length(p.toks) && p.toks[j].kind == :num && p.toks[j].isint) || throw(_CanonFail())
    p.i = j + 1
    return negative ? -p.toks[j].value : p.toks[j].value
end

function _cp_atom!(p::_CanonParser)::Vector{_CanonFactor}
    k = _cp_kind(p)
    if k == :num
        # Any number but the literal `1` (including `01` and `1.0`) is a
        # SCALING FACTOR, and a unit string denotes a unit, not a quantity:
        # `(m/s)^-1/3` reads as `((m/s)^-1)/3`, so `^(-1/3)` must be the only
        # spelling of that unit.
        _cp_take!(p).text == "1" || throw(
            _CanonFail(
                "a number other than 1 is a scaling factor, not a unit (esm-spec 4.8.2); " *
                    "a rational exponent is spelled ^(p/q)"
            )
        )
        return _CanonFactor[]
    elseif k == :sym
        name = _cp_take!(p).text
        return name == "dimensionless" ? _CanonFactor[] : _CanonFactor[(name, 1 // 1)]
    elseif k == :eof
        throw(_CanonFail("unexpected end of input"))
    elseif k == :lp
        _cp_take!(p)
        inner = _cp_unit!(p)
        _cp_kind(p) == :rp || throw(_CanonFail())
        _cp_take!(p)
        return inner
    end
    throw(_CanonFail())
end

# `Esm.Units.norm`: each symbol once with its exponents summed, zero sums
# dropped, sorted by symbol in codepoint order.
function _canon_side(fs::Vector{_CanonFactor})::Vector{_CanonFactor}
    total = Dict{String, Rational{BigInt}}()
    for (s, q) in fs
        total[s] = get(total, s, 0 // 1) + q
    end
    return _CanonFactor[(s, total[s]) for s in sort!(collect(keys(total))) if !iszero(total[s])]
end

function _canon_factor((s, q)::_CanonFactor)::String
    q = abs(q)
    isone(q) && return s
    isone(denominator(q)) && return string(s, "^", numerator(q))
    return string(s, "^(", numerator(q), "/", denominator(q), ")")
end

# `Esm.Units.symOK`: `%`, or an identifier run that is not all digits.
_canon_symbol_ok(s::String) =
    s == "%" || (!isempty(s) && all(_up_ident, s) && !_canon_digit_run(collect(s)))

# THE §4.8.2 parser's entry: the factor list of `unit` (each symbol with its
# exponent, `*` and juxtaposition concatenating, `/` negating, in the order
# written), or the reason the string is outside the grammar.
function _unit_factors(unit::AbstractString)::Union{Vector{_CanonFactor}, String}
    cs = collect(_normalize_unit_string(unit))
    toks = _canon_lex(cs)
    toks === nothing && return "unexpected character in '$(String(cs))'"
    p = _CanonParser(toks, 1)
    try
        fs = _cp_unit!(p)
        p.i == length(toks) + 1 || return "unexpected trailing input"
        return fs
    catch e
        e isa _CanonFail && return e.msg
        rethrow()
    end
end

"""
    _canonical_unit_factors(unit) -> Union{Nothing, Vector{_CanonFactor}}

The factors of the canonical spelling of `unit` (esm-spec §4.8.2): the parse's
factors normalized per side (`_canon_side`), the numerator side (positive
exponents) then the denominator side. `nothing` when the string is outside the
grammar.
"""
function _canonical_unit_factors(unit::AbstractString)::Union{Nothing, Vector{_CanonFactor}}
    fs = _unit_factors(unit)
    fs isa String && return nothing
    return vcat(_canon_side(filter(f -> f[2] > 0, fs)), _canon_side(filter(f -> !(f[2] > 0), fs)))
end

"""
    _spell_unit_factors(factors) -> String

The canonical spelling of a factor list from [`_canonical_unit_factors`](@ref):
the positive-exponent factors joined by `*` (`1` when there are none), then
`/` and the others written with their exponent's absolute value,
parenthesized when there is more than one.
"""
function _spell_unit_factors(l)::String
    num = [_canon_factor(f) for f in l if f[2] > 0]
    den = [_canon_factor(f) for f in l if !(f[2] > 0)]
    out = isempty(num) ? "1" : join(num, "*")
    if length(den) == 1
        out *= "/" * den[1]
    elseif length(den) > 1
        out *= "/(" * join(den, "*") * ")"
    end
    return out
end

"""
    _canonical_units(unit) -> String

The canonical spelling of a unit string (esm-spec §4.8.2), a port of the Lean
`Esm.Units.canon`: [`_spell_unit_factors`](@ref) of
[`_canonical_unit_factors`](@ref).

The numerator is the factors with a positive exponent, each symbol once with
its exponents summed, sorted by symbol (codepoint order) and joined by `*`. The
denominator is the factors with a negative exponent, treated the same way and
written with the exponent's absolute value; it is parenthesized when it has
more than one factor. Nothing cancels across the bar. An exponent 1 is omitted,
an integer is `^n`, any other rational is `^(p/q)` in lowest terms. An empty
numerator is `1`, so `""`, `"1"` and `"dimensionless"` all become `"1"`.

The string is returned unchanged when it does not lex or parse, when the
spelling would have to write a symbol containing `.`, and when it would drop
(exponent 0) a symbol that is not a table key.
"""
function _canonical_units(unit::AbstractString)::String
    isempty(unit) && return "1"
    factors = _unit_factors(unit)
    factors isa String && return String(unit)
    l = _canonical_unit_factors(unit)
    kept = Set{String}(first.(l))
    all(_canon_symbol_ok, kept) || return String(unit)
    # `%` is a table key in every other binding; here the resolver
    # special-cases it instead of registering it.
    all(f -> f[1] in kept || f[1] == "%" || haskey(_UNIT_REGISTRY, f[1]), factors) ||
        return String(unit)
    return _spell_unit_factors(l)
end

# ---------------------------------------------------------------------------
# The dimensional engine.
#
# THE CENTRAL INVARIANT: a dimensional rule
# has THREE possible outcomes, and the first two must never be conflated:
#
#   * a known dimension        → the `Unitful.Units` value
#   * PROVABLY INCONSISTENT    → push a message onto `findings`, return `nothing`
#   * UNKNOWN / indeterminate  → return `nothing`, push NOTHING
#
# Callers learn "this expression is provably wrong" by checking
# whether `findings` GREW, never by checking the returned value against
# `nothing`. `nothing` alone always means "cannot say".
#
# Corollary (conservatism): a rule that cannot determine ALL of its operands'
# dimensions must return `nothing` rather than guess, because a guessed
# dimension propagates upward and can manufacture a FALSE inconsistency at an
# enclosing node.
#
# Each rule is `(expr::OpExpr, var_units, findings::Vector{String}) -> Union{Unitful.Units, Nothing}`,
# dispatched through the const `_DIMENSION_RULES` table below.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# IMPLICIT UNITS ON NUMERIC LITERALS.
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
#     literal adopts its siblings' dimension, because `_same_dimensions_over`
#     skips every undeterminable operand rather than comparing it. A sum with
#     no determinable operand (`1 + 2`, `+(2)`) is itself undeterminable.
#   * an EXPONENT (`x^2`) — read by VALUE off the AST, which is what makes `^`
#     computable at all.
#   * a TRANSCENDENTAL ARGUMENT (`exp(2)`) — indeterminate, hence unconstrained,
#     and the result is dimensionless either way.
#
# Costs nothing on the invalid corpus, where every pinned inconsistency is
# stated between DECLARED quantities (`length + mass`, `ln(mass)`, `m^kg`).
# ---------------------------------------------------------------------------

# The numeric value of a literal AST node, or `nothing` if it is not one. The
# `^` rule reads its exponent through this rather than through the dimensional
# engine (which reports every literal as indeterminate).
#
# Inside a template body read through its frame (`_TplUnitEnv`), a parameter
# sentinel is read as its binding wherever a rule reads a literal by VALUE:
# `fr` is the frame the body is read in (`nothing` outside a body), and
# `_tpl_leaf` (templates/frames.jl) is the one resolver, so `x^p` with `p`
# bound to `2` folds exactly as the expansion's `x^2` does.
function _literal_value(e::ASTExpr, fr = nothing)
    e, _ = _tpl_leaf(e, fr)
    e isa IntExpr && return e.value
    (e isa NumExpr && e.value isa Number) && return e.value
    return nothing
end

# A literal exponent as an exact rational, converted the way `_power_rule`
# always converted a literal (an integral value exactly; anything else through
# `rationalize`). `nothing` for a non-finite value or a non-number.
function _exponent_rational(v)::Union{Rational{Int}, Nothing}
    (v isa Real && !(v isa Bool)) || return nothing
    isfinite(v) || return nothing
    try
        return isinteger(v) ? Rational{Int}(Int(v)) : rationalize(Int, float(v))
    catch err
        _is_resource_error(err) && rethrow()
        return nothing  # outside Int's range
    end
end

"""
    _constant_exponent_value(e, fr = nothing) -> Union{Rational{Int}, Nothing}

The exact rational value of a CONSTANT-EXPRESSION exponent (esm-spec §4.8.3
`^`), or `nothing` when it is symbolic. It folds a numeric literal; a `const`
that declares no `units`, or a dimensionless, non-angle unit at exact scale 1;
and `+`,
`*` (one or more operands), `-` (unary negation, or a left fold of two or more)
and `/` (exactly two operands, nonzero divisor) over constant expressions,
nested to any depth. Anything else — a variable, an expression containing one,
a `const` that is dimensional or scaled (`%`), any other operator, an `Int`
overflow, a division by zero — is symbolic.
"""
function _constant_exponent_value(e::ASTExpr, fr = nothing)::Union{Rational{Int}, Nothing}
    e, fr = _tpl_leaf(e, fr)
    lit = _literal_value(e)
    lit !== nothing && return _exponent_rational(lit)
    e isa OpExpr || return nothing
    op = e.op
    if op == "const"
        if e.units !== nothing
            u = parse_units(e.units)
            u === nothing && return nothing
            # An angle (`rad`, `sr`) is dimensionless to Unitful but carries
            # the angle axis the other bindings track, so it is not a number.
            (
                dimension(u) == dimension(Unitful.NoUnits) && isone(_exact_scale(u)) &&
                    !_is_angle_bearing(u)
            ) || return nothing
        end
        return _exponent_rational(e.value)
    end
    op in ("+", "*", "-", "/") || return nothing
    isempty(e.args) && return nothing
    vals = Rational{Int}[]
    for a in e.args
        v = _constant_exponent_value(a, fr)
        v === nothing && return nothing
        push!(vals, v)
    end
    return try
        if op == "+"
            return sum(vals)
        elseif op == "*"
            return prod(vals)
        elseif op == "-"
            length(vals) == 1 && return -vals[1]
            return foldl(-, vals)
        else  # "/"
            (length(vals) == 2 && !iszero(vals[2])) || return nothing
            return vals[1] / vals[2]
        end
    catch err
        err isa OverflowError && return nothing
        rethrow()
    end
end

# ---------------------------------------------------------------------------
# SCOPED REFERENCES (esm-spec §4.8.4, §4.9.2; EarthSciAST#414).
#
# After load a mounted component — `subsystems.<k>: {ref}` or a top-level
# `models.<k>: {ref}` — is the same as one written inline (§4.7 "Resolution
# timing"), so a scoped reference to one of its members carries the units the
# member declares, exactly as a local name does. Treating `Leaf.p` as
# undeterminable skipped every dimensional check across a mount edge.
# ---------------------------------------------------------------------------

# Scoped name → declared unit string, or `nothing` for a member whose unit is
# undeterminable (it declares none, or one that does not resolve — reported at
# its own declaration). A `nothing` entry still OCCUPIES its dotted name: it
# shadows a same-named path further out, and looks up as unknown.
const _ScopedUnits = Dict{String, Union{String, Nothing}}

_scoped_unit(units) =
    (units === nothing || isempty(units) || parse_units(units) === nothing) ? nothing : units

# The declared unit of every member of the scoped index `ix` (see `_ScopedUnits`).
_scoped_units(ix::_ScopedIndex)::_ScopedUnits =
    _ScopedUnits(k => _scoped_unit(d.decl.units) for (k, d) in ix.members)

# The document-wide part of the scoped map: `<System>.<member>` (and deeper)
# for every top-level model and reaction system of `file`. It does not depend
# on the component doing the referencing, so a validation pass builds it once.
_toplevel_scoped_units(file)::_ScopedUnits = _scoped_units(_scoped_index(file))

# The component-relative part: `<sub>.<member>` (and deeper) through
# `component`'s own subsystems.
_relative_scoped_units(component)::_ScopedUnits =
    component isa Union{Model, ReactionSystem} ?
    _scoped_units(_scoped_index(pairs(component.subsystems))) : _ScopedUnits()

"""
    scoped_reference_units(file, component) -> Dict{String, Union{String, Nothing}}

Scoped name → declared unit string, for every scoped reference an expression in
`component` can make (esm-spec §4.9.2): `<System>.<member>` (and deeper, through
that system's subsystems) for every top-level model and reaction system of
`file`, and `<sub>.<member>` (and deeper) relative to `component`'s own
subsystems — the relative path wins on a collision. A member whose unit is
undeterminable (no `units`, or a string that does not resolve) maps to
`nothing`, and still shadows a same-named top-level path; `file === nothing`
contributes only the relative paths.
"""
scoped_reference_units(file, component)::_ScopedUnits =
    merge(_toplevel_scoped_units(file), _relative_scoped_units(component))

# A component's unit environment: its own declared names, then its relative
# scoped paths, then the document's top-level ones. The first layer that holds
# a name decides it, so a relative entry with no unit hides a top-level one.
# Layered rather than merged so the shared top-level map is never copied per
# component.
struct _UnitEnv <: AbstractDict{String, String}
    own::Dict{String, String}
    relative::_ScopedUnits
    toplevel::_ScopedUnits
    # The document's independent variable (esm-spec §4.9.1): undeclared, it
    # has the time dimension in seconds, and a `D` with no `wrt` is taken
    # with respect to it.
    indep::String
end
_UnitEnv(own, relative, toplevel) = _UnitEnv(own, relative, toplevel, "t")

# The independent variable `var_units` types; `"t"` for a plain dictionary.
_indep_of(env::_UnitEnv) = env.indep
_indep_of(::AbstractDict) = "t"

function _lookup(env::_UnitEnv, name)::Union{String, Nothing}
    v = get(env.own, name, nothing)
    v === nothing || return v
    haskey(env.relative, name) && return env.relative[name]
    return get(env.toplevel, name, nothing)
end

function Base.get(env::_UnitEnv, name, default)
    v = _lookup(env, name)
    return v === nothing ? default : v
end
Base.haskey(env::_UnitEnv, name) = _lookup(env, name) !== nothing
function Base.getindex(env::_UnitEnv, name)
    v = _lookup(env, name)
    v === nothing && throw(KeyError(name))
    return v
end

# Iteration (display, debugging) materializes the visible bindings.
function _materialize(env::_UnitEnv)::Dict{String, String}
    out = Dict{String, String}()
    for layer in (env.toplevel, env.relative, env.own), (k, v) in layer
        if v === nothing
            delete!(out, k)
        else
            out[k] = v
        end
    end
    return out
end
Base.length(env::_UnitEnv) = length(_materialize(env))
function Base.iterate(env::_UnitEnv)
    d = _materialize(env)
    r = iterate(d)
    return r === nothing ? nothing : (r[1], (d, r[2]))
end
function Base.iterate(::_UnitEnv, (d, s))
    r = iterate(d, s)
    return r === nothing ? nothing : (r[1], (d, r[2]))
end

# ---------------------------------------------------------------------------
# EXACT UNIT SCALES (esm-spec §4.8.1 "Scales are EXACT").
#
# Unitful does the DIMENSION algebra here, and its conversion factors are
# floats (`lb` is 0.45359237 as a Float64). A scale AGREEMENT — `m + km`,
# `m/s = mi/h` — is decided on an exact number instead: a product of prime
# powers and a power of π, each with a rational exponent, so `mi` is
# 2^4 * 3^2 * 5^-3 * 11 * 127 and `sqrt(km)` is still exact. It is read off a
# Unitful unit's components (base unit, power-of-ten prefix, rational power)
# through the table below, never from Unitful's float factor.
# ---------------------------------------------------------------------------

"""
    ExactScale

The exact scale of a unit relative to SI: prime powers times a power of π, each
with a rational exponent. Compared with `==`; `Float64` is for diagnostics only.
"""
struct ExactScale
    primes::Dict{Int, Rational{Int}}
    pi::Rational{Int}
end

ExactScale() = ExactScale(Dict{Int, Rational{Int}}(), 0 // 1)

_exact_normalize(e::ExactScale) =
    ExactScale(Dict(p => x for (p, x) in e.primes if !iszero(x)), e.pi)

function _exact_integer(n::Integer)
    n > 0 || throw(ArgumentError("a unit scale must be positive, got $n"))
    primes = Dict{Int, Rational{Int}}()
    rest = Int(n)
    p = 2
    while p * p <= rest
        while rest % p == 0
            primes[p] = get(primes, p, 0 // 1) + 1
            rest ÷= p
        end
        p += p == 2 ? 1 : 2
    end
    rest > 1 && (primes[rest] = get(primes, rest, 0 // 1) + 1)
    return ExactScale(primes, 0 // 1)
end

_exact_pow10(k::Integer) =
    _exact_normalize(ExactScale(Dict(2 => Rational{Int}(k), 5 => Rational{Int}(k)), 0 // 1))

_exact_ratio(num::Integer, den::Integer) = _exact_integer(num) / _exact_integer(den)

_exact_pi() = ExactScale(Dict{Int, Rational{Int}}(), 1 // 1)

# The exact value of a positive decimal literal as the registry writes it
# ("0.3048", "2.6867e20"), read from its TEXT, never through a float.
function _exact_decimal(literal::AbstractString)
    m = match(r"^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$", literal)
    m === nothing && throw(ArgumentError("not a registry decimal: $literal"))
    frac = something(m.captures[2], "")
    mantissa = parse(Int, m.captures[1] * frac)
    exp10 = (m.captures[3] === nothing ? 0 : parse(Int, m.captures[3])) - length(frac)
    return _exact_integer(mantissa) * _exact_pow10(exp10)
end

function Base.:*(a::ExactScale, b::ExactScale)
    primes = copy(a.primes)
    for (p, x) in b.primes
        primes[p] = get(primes, p, 0 // 1) + x
    end
    return _exact_normalize(ExactScale(primes, a.pi + b.pi))
end

function Base.:/(a::ExactScale, b::ExactScale)
    primes = copy(a.primes)
    for (p, x) in b.primes
        primes[p] = get(primes, p, 0 // 1) - x
    end
    return _exact_normalize(ExactScale(primes, a.pi - b.pi))
end

function Base.:^(a::ExactScale, r::Real)
    q = r isa Rational ? Rational{Int}(r) :
        _dynamic(x -> Rational{Int}(rationalize(Int, float(x); tol = 1.0e-9)), r)::Rational{Int}
    return _exact_normalize(ExactScale(Dict(p => x * q for (p, x) in a.primes), a.pi * q))
end

Base.:(==)(a::ExactScale, b::ExactScale) = a.primes == b.primes && a.pi == b.pi
Base.hash(a::ExactScale, h::UInt) = hash(a.pi, hash(a.primes, h))
Base.isone(a::ExactScale) = isempty(a.primes) && iszero(a.pi)

function Base.Float64(a::ExactScale)
    v = Float64(π)^Float64(a.pi)
    for p in sort!(collect(keys(a.primes)))
        v *= Float64(p)^Float64(a.primes[p])
    end
    return v
end

"""
    exact_ratio_string(scale::ExactScale) -> Union{String, Nothing}

`p/q`, `p/q*pi` or `p/q*pi^k` in lowest terms (`/q` omitted when it is 1) — the
spelling `tests/conformance/unit_registry` pins. `nothing` when an exponent is
not whole (`sqrt(km)`).
"""
function exact_ratio_string(a::ExactScale)::Union{String, Nothing}
    isinteger(a.pi) || return nothing
    num, den = big(1), big(1)
    for p in sort!(collect(keys(a.primes)))
        x = a.primes[p]
        isinteger(x) || return nothing
        k = Int(x)
        pw = big(p)^abs(k)
        k > 0 ? (num *= pw) : (den *= pw)
    end
    s = string(num)
    den != 1 && (s *= "/" * string(den))
    k = Int(a.pi)
    k == 1 ? (s *= "*pi") : (k != 0 && (s *= "*pi^$k"))
    return s
end

Base.show(io::IO, a::ExactScale) =
    print(io, something(exact_ratio_string(a), string(Float64(a))))

const _EXACT_FOOT = _exact_decimal("0.3048")
const _EXACT_POUND = _exact_decimal("0.45359237")
const _EXACT_GRAVITY = _exact_decimal("9.80665")

# The exact SI scale of every base Unitful unit the registry resolves to, keyed
# by Unitful's unit NAME; the power-of-ten prefix and the power are applied by
# `_exact_scale`. A name missing here reads as exactly 1, which is why
# test/unit_exact_scale_test.jl checks every registry entry against Unitful's
# own float factor.
const _EXACT_BY_UNIT_NAME = Dict{Symbol, ExactScale}(
    :Gram => _exact_pow10(-3),
    :Minute => _exact_integer(60), :Hour => _exact_integer(3600),
    :Day => _exact_integer(86400), :Year => _exact_integer(31557600),
    :Liter => _exact_pow10(-3), :Molar => _exact_pow10(3),
    :Calorie => _exact_decimal("4.184"),
    :Atmosphere => _exact_integer(101325), :Bar => _exact_pow10(5),
    :Torr => _exact_ratio(101325, 760),
    :PoundsPerSquareInch => _EXACT_POUND * _EXACT_GRAVITY / _exact_decimal("0.0254")^2,
    :Dyne => _exact_pow10(-5),
    :Erg => _exact_pow10(-7), :InternationalTableBTU => _exact_decimal("1055.05585262"),
    :Rankine => _exact_ratio(5, 9),
    :Degree => _exact_pi() / _exact_integer(180),
    :Percent => _exact_pow10(-2),
    :Permillion => _exact_pow10(-6), :Perbillion => _exact_pow10(-9),
    :Pertrillion => _exact_pow10(-12),
    :MillimetreOfMercury => _exact_decimal("133.322387415"),
    :MicroAtmosphere => _exact_decimal("0.101325"),
    :DobsonUnit => _exact_decimal("2.6867e20"),
    :InternationalFoot => _EXACT_FOOT,
    :InternationalMile => _exact_integer(5280) * _EXACT_FOOT,
    :AvoirdupoisPound => _EXACT_POUND,
    :MechanicalHorsepower => _exact_integer(550) * _EXACT_FOOT * _EXACT_POUND * _EXACT_GRAVITY,
    :USLiquidGallon => _exact_decimal("0.003785411784"),
    :InchOfMercury => _exact_decimal("3386.388640341"),
    :ShortTon => _exact_integer(2000) * _EXACT_POUND,
    :MetricTon => _exact_pow10(3),
)

"""
    _exact_scale(u) -> ExactScale

The exact scale of a Unitful unit (esm-spec §4.8.1). An affine unit is read as
its absolute counterpart: `°F` has the scale of `Ra`, 5/9 K.
"""
function _exact_scale(u)::ExactScale
    a = _absolute_unit(u)
    scale = ExactScale()
    for x in typeof(a).parameters[1]
        base = get(_EXACT_BY_UNIT_NAME, Unitful.name(x), ExactScale())
        scale = scale * (base * _exact_pow10(x.tens))^x.power
    end
    return scale
end

# Same dimension, same exact scale and the same power of the ANGLE axis. The
# third clause is what Unitful cannot see on its own: it holds `rad` and `sr` as
# `NoDims` at scale 1, so `rad`, `sr` and `1` would otherwise all be one unit,
# and `m*rad` would be `m` (esm-spec §4.8.1 makes `rad` an axis).
_same_unit(a, b) = _same_unit_ignoring_angle(a, b) &&
    _angle_axis_exponent(a) == _angle_axis_exponent(b)

# Dimension and exact scale only — Unitful's own view, in which the angle axis
# is already removed (esm-spec §4.8.3 "An angle meets a pure number").
_same_unit_ignoring_angle(a, b) =
    dimension(a) == dimension(b) && _exact_scale(a) == _exact_scale(b)

# Do `a` and `b` agree at a position where an angle meets a pure number
# (esm-spec §4.8.3)? A pure angle against a pure number loses its angle axis and
# keeps its scale (`rad` agrees with `1`, `deg` does not); every other pair —
# two angles (`rad` against `sr`), a mixed unit (`m*rad` against `m`) — is held
# to `_same_unit`.
function _units_agree_where_angle_meets_number(a, b)::Bool
    (
        (_is_pure_angle(a) && _is_angle_free_number(b)) ||
            (_is_angle_free_number(a) && _is_pure_angle(b))
    ) &&
        return _same_unit_ignoring_angle(a, b)
    return _same_unit(a, b)
end

# The Unitful unit NAMES that denote a PLANE angle. Unitful models `rad` as
# `NoDims` (esm-spec §4.8.1 makes it an axis, and the other four bindings carry
# it as one), so this binding cannot tell an angle from a pure number by
# DIMENSION and must read the unit's own symbol. `:Steradian` is deliberately
# absent: `sr` is `rad^2`, and the circular argument is CONVERTED to radians —
# multiplying by `scale` where `scale^2` was meant would be
# silently wrong. `sr` is NOT thereby admitted as a pure number either; see
# `_ANGLE_AXIS_UNIT_NAMES` / `_is_angle_bearing` below, which is the same symbol
# read widened to the whole axis.
const _PLANE_ANGLE_UNIT_NAMES = (:Radian, :Degree)

# Is `u` a plane angle to the FIRST power (`rad`, `deg`)?
function _is_plane_angle(u)::Bool
    dimension(u) == dimension(Unitful.NoUnits) || return false
    comps = typeof(Unitful.FreeUnits(u)).parameters[1]
    length(comps) == 1 || return false
    c = comps[1]
    return Unitful.name(c) in _PLANE_ANGLE_UNIT_NAMES && c.power == 1
end

# The Unitful unit NAMES that carry the esm ANGLE axis (esm-spec §4.8.1): the
# two plane angles above, plus the steradian, which IS that axis squared.
const _ANGLE_AXIS_UNIT_NAMES = (_PLANE_ANGLE_UNIT_NAMES..., :Steradian)

# Does `u` carry the ANGLE axis at all?
#
# Unitful models every one of these as `NoDims`, so `dimension(u)` cannot see
# the axis esm-spec §4.8.1 gives `rad` — which is why this binding, alone of the
# five, accepted `sin(x [sr])`, `log(x [rad])` and `asin(x [rad])` where Rust,
# Go, Python and TypeScript all refuse them: there `rad` is a real dimension
# vector entry, so none of those arguments is dimensionless. Reading the unit's
# SYMBOL is how `_is_plane_angle` already recognises `rad`/`deg`; this is the
# same read widened to the whole family, so the axis is visible everywhere
# §4.8.3 asks whether an argument is dimensionless.
#
# A registry sweep, not a single case: the three names below are every angle
# entry the §4.8.1 registry defines (`rad` with its SI prefixes, `deg` /
# `degree` / `degrees`, and `sr`) — there is no arcminute, gradian or turn to
# miss — and the predicate is written over the whole component list, so a
# COMPOUND angle (`rad^2`, `rad*deg`) is caught as well as a bare one.
function _is_angle_bearing(u)::Bool
    dimension(u) == dimension(Unitful.NoUnits) || return false
    for c in typeof(Unitful.FreeUnits(u)).parameters[1]
        Unitful.name(c) in _ANGLE_AXIS_UNIT_NAMES && return true
    end
    return false
end

# The power of the esm ANGLE axis in `u`, whatever else `u` carries: `rad` and
# `deg` count 1 each, `sr` counts 2, so `m*rad` has 1 and `rad/deg` has 0.
function _angle_axis_exponent(u)::Rational{Int}
    p = 0 // 1
    for c in typeof(Unitful.FreeUnits(u)).parameters[1]
        n = Unitful.name(c)
        n in _PLANE_ANGLE_UNIT_NAMES && (p += c.power)
        n === :Steradian && (p += 2 * c.power)
    end
    return p
end

# The same power, for a unit with NO other dimension; zero for a unit with a
# real dimension.
_angle_axis_power(u)::Rational{Int} =
    dimension(u) == dimension(Unitful.NoUnits) ? _angle_axis_exponent(u) : 0 // 1

# A PURE ANGLE (esm-spec §4.8.3 "An angle meets a pure number"): a nonzero
# power of the angle axis and nothing else — `rad`, `deg`, `sr`, `1/rad`.
_is_pure_angle(u)::Bool = !iszero(_angle_axis_power(u))

# A PURE NUMBER in the same paragraph's sense: an EMPTY dimension at any scale
# (`1`, `%`, `ppm`), with no angle axis.
_is_angle_free_number(u)::Bool =
    dimension(u) == dimension(Unitful.NoUnits) && !_is_angle_bearing(u)

# Is `u` dimensionless **at scale 1** — a PURE NUMBER?
#
# This is what esm-spec §4.8.3's "the argument MUST be dimensionless" means for
# a strict transcendental: `ppm` and `percent` are dimensionless
# too, and `log(x [ppm])` has two defensible readings — the log of the ppm
# NUMBER, or the log of the mole fraction — that differ by `ln(1e-6) =
# 13.8155…`. Dimension alone cannot tell them apart, so the checker refuses
# rather than picking one.
_is_pure_number(u)::Bool =
    dimension(u) == dimension(Unitful.NoUnits) && isone(_exact_scale(u))

# The registry spellings of the dimensionless-but-SCALED units, most common
# first, used to NAME a scale in a diagnostic (`… (ppm); divide by 1 ppm …`).
#
# A fixed, ORDERED table rather than a reverse sweep of the registry: the
# registry is a `Dict`, so a sweep would pick `ppmv` or `ppm` depending on
# iteration order and the five bindings would print different messages for the
# same document. The same table, in the same order, is in every binding.
const _SCALED_DIMENSIONLESS_SPELLINGS = (
    ("percent", -2), ("ppm", -6),
    ("ppb", -9), ("ppt", -12),
)

# The canonical registry spelling of a dimensionless unit at `scale`, or
# `nothing` (`1/100` ⇒ "percent", `1e-6` ⇒ "ppm").
function _scaled_dimensionless_spelling(scale::ExactScale)
    for (name, k) in _SCALED_DIMENSIONLESS_SPELLINGS
        _exact_pow10(k) == scale && return name
    end
    return nothing
end

# The §4.8.3 refusal for a dimensionless-but-SCALED argument to an op that
# requires a pure number.
#
# It names the REPAIR, not only the refusal: the author states the reading by
# dividing by a quantity carrying the scale, which costs one node and records
# the decision in the document. Normalizing silently instead would change the
# numbers of every document that already passes a `percent` or a `ppm` into
# `exp`/`log`. The same sentence is in every binding.
function _scaled_dimensionless_message(op::AbstractString, scale::ExactScale)
    shown = something(exact_ratio_string(scale), string(Float64(scale)))
    name = _scaled_dimensionless_spelling(scale)
    name === nothing && return "Argument to '$(op)' must be dimensionless at scale 1, " *
        "but is dimensionless at scale $(shown); divide by a quantity carrying that " *
        "scale to state which reading is intended"
    return "Argument to '$(op)' must be dimensionless at scale 1, but is dimensionless " *
        "at scale $(shown) ($(name)); divide by 1 $(name), or by the scale you mean, " *
        "to state which reading is intended"
end

"""
    angle_normalization_factor(u) -> Union{Float64, Nothing}

The factor that brings a quantity in `u` to RADIANS, when `u` is a plane angle
at a scale other than 1 (esm-spec §4.8.3).

`nothing` for anything else — a pure number, a `rad`, a dimensional unit — so a
document that declares no scaled angle is rewritten not at all.
"""
function angle_normalization_factor(u)
    (_is_plane_angle(u) && !isone(_exact_scale(u))) || return nothing
    return Float64(_exact_scale(u))
end

# Same-dimensions core shared by "+"/"-", "min"/"max", comparisons and `atan2`
# (esm-spec §4.8.3): every operand whose unit can be determined must agree with
# the others, and the result is that unit. `describe(first_dim, dim)` renders
# the op-family-specific inconsistency message.
#
# An operand whose unit cannot be determined — a literal, a product with a
# literal factor, an undeclared variable — is skipped, never compared: it can
# neither hide nor manufacture a mismatch between the known ones. So `x + 0.5*y`
# has x's unit, and a literal adopts its siblings' unit. With no determinable
# operand at all (`1 + 2`, `min(1, 2)`) the result is undeterminable, never
# dimensionless (§4.8.4).
#
# `angle_meets_number` marks the places where an angle meets a pure number
# (esm-spec §4.8.3): `+`, `-`, `min`, `max`, the `ifelse` branches and the
# comparisons, but not `atan2`, `concat` or `makearray`. There a pure angle is
# compared with a pure number by dimension and exact scale alone (`deg` against
# `1` is still a mismatch), but two angles are still compared with each other
# by `_same_unit`: `θ [rad] + ω [sr] + n [1]` is a mismatch whichever operand
# comes first. An agreeing pure angle and pure number give the pure number's
# unit, because the angle cancels.
function _same_dimensions_over(
        args, var_units, findings, describe;
        angle_meets_number::Bool = false
    )
    arg_dims = Any[_expr_dimensions!(findings, arg, var_units) for arg in args]
    valid_dims = filter(d -> d !== nothing, arg_dims)
    isempty(valid_dims) && return nothing

    first_dim = valid_dims[1]
    first_angle = _is_pure_angle(first_dim) ? first_dim : nothing
    for dim in valid_dims[2:end]
        # Same dimension AND same exact scale (esm-spec §4.8.3): metres added to
        # kilometres are different units even though both are lengths.
        agree = angle_meets_number ?
            _units_agree_where_angle_meets_number(dim, first_dim) :
            _same_unit(dim, first_dim)
        if !agree
            push!(findings, describe(first_dim, dim))
            return nothing
        end
        if angle_meets_number && _is_pure_angle(dim)
            if first_angle === nothing
                first_angle = dim
            elseif !_same_unit(dim, first_angle)
                push!(findings, describe(first_angle, dim))
                return nothing
            end
        end
    end
    if angle_meets_number && any(_is_pure_angle, valid_dims)
        number = findfirst(_is_angle_free_number, valid_dims)
        number === nothing || return valid_dims[number]
    end
    return first_dim
end

# "+" / "-": all arguments must have the same dimensions. A unary `+` or `-`
# carries its operand's unit unchanged, so `+(2)` and `-(273.15)` are
# undeterminable, exactly as the literal is.
function _same_dimension_rule(expr, var_units, findings)
    length(expr.args) == 1 &&
        return _expr_dimensions!(findings, expr.args[1], var_units)
    return _same_dimensions_over(
        expr.args, var_units, findings,
        (first_dim, dim) -> "Cannot $(expr.op == "-" ? "subtract" : "add") quantities with " *
            "different units: '$(_ustr(first_dim))' $(expr.op) '$(_ustr(dim))'";
        angle_meets_number = true
    )
end

# "min" / "max" (esm-spec §4.2): all arguments must share dimensions; the
# result carries them.
_minmax_rule(expr, var_units, findings) =
    _same_dimensions_over(
    expr.args, var_units, findings,
    (first_dim, dim) -> "Dimensional inconsistency in $(expr.op): " *
        "'$(_ustr(first_dim))' vs '$(_ustr(dim))'"; angle_meets_number = true
)

# "*": multiply dimensions. A SINGLE indeterminate factor makes the whole
# product indeterminate. Skipping the unknown factor and returning the product
# of the known ones would assert the unknown one is dimensionless, which is wrong for the implicit-unit constants the
# corpus multiplies by: `conc_ppb * 1.23` is a ppb→µg/m³ conversion, and
# reporting its dimension as "ppb" manufactures a mismatch against the declared
# µg/m³. See the conservatism corollary above.
#
# Every factor is still WALKED, even after an indeterminate one: an
# indeterminate factor says nothing about the units of the others, and a
# provable inconsistency inside a later factor is an error whatever the
# product's unit. Stopping at the first indeterminate factor is what let
# `1000 * exp(T [degC])` through (tests/invalid/
# units_transcendental_argument_degC_under_product.esm; the other places such a
# product can sit are in units_transcendental_argument_under_product.esm).
function _product_rule(expr, var_units, findings)
    result = Unitful.NoUnits
    for arg in expr.args
        arg_dim = _expr_dimensions!(findings, arg, var_units)
        result = (result === nothing || arg_dim === nothing) ? nothing :
            result * arg_dim
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
# A SYMBOLIC exponent (`x^alpha` — a fitted reaction order is
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
    # engine reports every literal as indeterminate (esm-spec §4.8.4), and a
    # literal exponent is precisely the case that makes `^` computable. A
    # CONSTANT EXPRESSION over literals (`3/2`, `-(1)`, a unitless `const`)
    # folds to the exact rational it denotes and is used exactly as that
    # literal would be (esm-spec §4.8.3); anything else is symbolic.
    power = _constant_exponent_value(expr.args[2], _tpl_unit_frame(var_units))

    if power === nothing
        # Non-literal exponent: it must still be dimensionless, and THAT is
        # provable whenever its dimension is known. An angle is not: it stands
        # in for the angle axis the other bindings track (`_is_angle_bearing`).
        exp_dim = _expr_dimensions!(findings, expr.args[2], var_units)
        if exp_dim !== nothing && (
                dimension(exp_dim) != dimension(Unitful.NoUnits) ||
                    _is_angle_bearing(exp_dim)
            )
            push!(
                findings, "Exponent must be dimensionless, got '$(_ustr(exp_dim))'" *
                    (base_dim === nothing ? "" : " for base with units '$(_ustr(base_dim))'")
            )
            return nothing
        end
        base_dim === nothing && return nothing
        # A dimensionless base of scale 1 stays exactly that under ANY exponent;
        # a dimensional or SCALED one (`x^n` with `x` in `%`) has no static unit
        # under a symbolic exponent.
        (dimension(base_dim) == dimension(Unitful.NoUnits) && isone(_exact_scale(base_dim))) &&
            return Unitful.NoUnits
        return nothing
    end

    base_dim === nothing && return nothing
    # A literal INTEGER or RATIONAL exponent is determinable (esm-spec §4.8.3).
    # Unitful represents rational powers, so `x^0.5` on `m^2` is `m`; a power it
    # cannot represent is unknown, not an inconsistency.
    try
        return isinteger(power) ? base_dim^Int(power) : base_dim^power
    catch err
        _is_resource_error(err) && rethrow()
        return nothing
    end
end

# "sqrt": halves the dimension. NOT a transcendental — `sqrt(area)` is a
# perfectly ordinary dimensional operation, and treating it as requiring a
# dimensionless argument manufactures false positives.
function _sqrt_rule(expr, var_units, findings)
    length(expr.args) == 1 || return nothing
    base_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    base_dim === nothing && return nothing
    try
        return base_dim^(1 // 2)
    catch err
        _is_resource_error(err) && rethrow()
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
    # `_is_angle_bearing` is what stands in for the ANGLE AXIS the other four
    # bindings carry in the dimension vector: `rad` is an axis (esm-spec
    # §4.8.1). Unitful calls it `NoDims`, so the dimension test alone cannot see
    # it. A PURE angle is the exception: where an angle meets a pure number its
    # axis is removed and its scale KEPT (esm-spec §4.8.3), so `exp(x [rad])`
    # passes and `exp(x [deg])` is refused for its scale below, like `%`.
    if arg_dim !== nothing && (
            dimension(arg_dim) != dimension(Unitful.NoUnits) ||
                (_is_angle_bearing(arg_dim) && !_is_pure_angle(arg_dim))
        )
        push!(
            findings, "$(_op_family(expr.op)) argument must be dimensionless, " *
                "got units '$(_ustr(arg_dim))' (function '$(expr.op)')"
        )
        return nothing
    end
    # "Dimensionless" means dimensionless AT SCALE 1: `ppm` and
    # `percent` pass every dimension-only test, and the two readings of
    # `log(x [ppm])` differ by `ln(1e-6)`.
    if arg_dim !== nothing && !_is_pure_number(arg_dim)
        push!(findings, _scaled_argument_message(expr.op, arg_dim))
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
    # A PLANE angle is admitted at any scale and converted; every OTHER unit
    # carrying the angle axis is a dimensional mismatch, exactly as in the four
    # bindings that hold `rad` in the dimension vector. `sr` is `rad^2` and no
    # conversion turns a solid angle into a plane one (esm-spec §4.8.3), and
    # multiplying by `scale` where `scale^2` was meant would be silently wrong.
    if arg_dim !== nothing &&
            (
            (
                dimension(arg_dim) != dimension(Unitful.NoUnits) &&
                    dimension(arg_dim) != dimension(u"rad")
            ) ||
                (_is_angle_bearing(arg_dim) && !_is_plane_angle(arg_dim))
        )
        push!(
            findings, "Circular function argument must be an angle or " *
                "dimensionless, got units '$(_ustr(arg_dim))' " *
                "(function '$(expr.op)')"
        )
        return nothing
    end
    # An ANGLE is admitted WHATEVER its scale, because `deg` → `rad` is exact and
    # has no second reading: `_normalize_angle_arguments!` converts it on the
    # flatten path before anything evaluates it. Dimensionless at a scale OTHER
    # than 1 (`percent`) is REFUSED, for the same reason `log(x [ppm])` is.
    if arg_dim !== nothing && !_is_plane_angle(arg_dim) && !_is_pure_number(arg_dim)
        push!(findings, _scaled_argument_message(expr.op, arg_dim))
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
        _same_dimensions_over(
            expr.args, var_units, findings,
            (a, b) -> "atan2 operands must have the same units, got " *
                "'$(_ustr(a))' and '$(_ustr(b))'"
        )
        return u"rad"
    end
    if length(expr.args) != 1
        @debug "Function $(expr.op) requires exactly 1 argument"
        return nothing
    end
    arg_dim = _expr_dimensions!(findings, expr.args[1], var_units)
    # A unit carrying the angle axis is refused, see `_is_angle_bearing`, except
    # a PURE angle: its argument is a place where an angle meets a pure number
    # (esm-spec §4.8.3), so the axis is removed, the scale kept, and `deg` is
    # refused for its scale below.
    if arg_dim !== nothing && (
            dimension(arg_dim) != dimension(Unitful.NoUnits) ||
                (_is_angle_bearing(arg_dim) && !_is_pure_angle(arg_dim))
        )
        push!(
            findings, "Inverse circular function argument must be " *
                "dimensionless, got units '$(_ustr(arg_dim))' " *
                "(function '$(expr.op)')"
        )
        return nothing
    end
    # A dimensionless RATIO is a PURE NUMBER, not a `percent` whose reading is
    # unstated.
    if arg_dim !== nothing && !_is_pure_number(arg_dim)
        push!(findings, _scaled_argument_message(expr.op, arg_dim))
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

# The scale refusal for an argument that must be a pure number: a pure angle
# at a scale other than 1 rad (`deg`, esm-spec §4.8.3 "An angle meets a pure
# number") is named as an angle, anything else as a scaled pure number.
function _scaled_argument_message(op::AbstractString, u)
    _is_pure_angle(u) || return _scaled_dimensionless_message(op, _exact_scale(u))
    return "Argument to '$(op)' is an angle in '$(_ustr(u))', at a scale other than " *
        "1 rad; where an angle meets a pure number its scale is kept (esm-spec " *
        "§4.8.3), so convert it to rad first"
end

# Render a unit for a diagnostic. Falls back to the dimension when the unit has
# no compact string form.
function _ustr(u)::String
    s = string(u)
    return isempty(s) ? string(dimension(u)) : s
end

# "ifelse": ifelse(cond, a, b) — the two branches follow the "+" rule (esm-spec
# §4.8.3): determinable branches must share a unit and the result is that unit,
# an undeterminable branch is skipped (`ifelse(c, x, 0.5*y)` has x's unit), and
# with no determinable branch the result is undeterminable. The condition is
# walked so a finding inside it (`x [m] > y [kg]`) is reported, but its own unit
# neither enters the result nor has to be dimensionless.
function _ifelse_rule(expr, var_units, findings)
    length(expr.args) == 3 || return nothing
    _expr_dimensions!(findings, expr.args[1], var_units)
    return _same_dimensions_over(
        expr.args[2:3], var_units, findings,
        (t_dim, f_dim) -> "Unit inconsistency in ifelse branches: " *
            "'$(_ustr(t_dim))' vs '$(_ustr(f_dim))'"; angle_meets_number = true
    )
end

# "sign": the result is a dimensionless -1/0/+1 whatever the argument's unit,
# but the argument is walked so a finding inside it (`sign(exp(T [K]))`) is
# reported (esm-spec §4.8.3).
function _dimensionless_result_rule(expr, var_units, findings)
    for arg in expr.args
        _expr_dimensions!(findings, arg, var_units)
    end
    return Unitful.NoUnits
end

# "and" / "or" / "not": the result is a dimensionless boolean. The operands carry
# no unit requirement of their own, but they are walked so a mismatch inside one
# (`not(x [m] > z [kg])`) is reported (esm-spec §4.8.3).
function _boolean_rule(expr, var_units, findings)
    for arg in expr.args
        _expr_dimensions!(findings, arg, var_units)
    end
    return Unitful.NoUnits
end

# "<", ">", "<=", ">=", "==", "!=": the operands must be mutually commensurate
# (comparing a length to a mass is provably wrong); the result is a
# dimensionless boolean. Literal operands are dimension-neutral here for the
# same reason they are under "+" — `x > 0` says nothing about the units of 0.
function _comparison_rule(expr, var_units, findings)
    _same_dimensions_over(
        expr.args, var_units, findings,
        (first_dim, dim) -> "Cannot compare quantities with different units: " *
            "'$(_ustr(first_dim))' $(expr.op) '$(_ustr(dim))'"; angle_meets_number = true
    )
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
# An UNDECLARED independent variable has an unknown dimension,
# so the derivative's dimension is unknown too. Defaulting `t` to SECONDS is a
# false-positive factory: in a nondimensionalized model (state and RHS both
# declared "1", `t` undeclared) it manufactures `1/s` on the left against `1` on
# the right and reports a mismatch in a perfectly well-formed file.
#
# The EQUATION-level rule (`equation_unit_findings`) still
# rejects a derivative equation that no choice of time unit could reconcile,
# which is what the invalid corpus actually pins.
function _derivative_rule(expr, var_units, findings)
    wrt = expr.wrt !== nothing ? expr.wrt : _indep_of(var_units)
    # esm-spec §4.2 "Arity of `D`": the STRUCTURAL time derivative is strictly
    # unary, but a REWRITE-TARGET `D` (spatial `wrt`) MAY carry trailing
    # auxiliary operands after `args[1]` — the per-face boundary/halo values a
    # discretization rule binds and consumes. They carry no evaluator semantics,
    # so the dimensional rule reads `args[1]` alone and ignores the rest.
    max_args = _is_time_derivative(expr) ? 1 : typemax(Int)
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

# `partial(f, b…; wrt: x)` has the unit `[f]/[x]` (esm-spec §4.2); trailing
# operands never enter it. `integral(f; var: v, …)` has `[f]·[v]`. A coordinate
# with no declared unit makes the result undeterminable.
function _axis_unit(var_units, axis)
    axis isa AbstractString || return nothing
    haskey(var_units, axis) || return nothing
    return _absolute_unit(parse_units(var_units[axis]))
end
function _partial_rule(expr, var_units, findings)
    isempty(expr.args) && return nothing
    f = _expr_dimensions!(findings, expr.args[1], var_units)
    for a in expr.args[2:end]
        _expr_dimensions!(findings, a, var_units)
    end
    w = _axis_unit(var_units, expr.wrt)
    (f === nothing || w === nothing) && return nothing
    return f / w
end
function _integral_rule(expr, var_units, findings)
    isempty(expr.args) && return nothing
    f = _expr_dimensions!(findings, expr.args[1], var_units)
    v = _axis_unit(var_units, expr.int_var)
    (f === nothing || v === nothing) && return nothing
    return f * v
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
# `_op_in_T` (templates/rewrite.jl) as an open-namespace rewrite
# target, and giving these spellings rows would silently change that.
const _TRANSCENDENTAL_OPS = union(
    _ops_with_dim_class(:transcendental),
    Set(["ln", "log2", "expm1"])
)

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
# "const": a `const` that DECLARES its units has that unit (esm-spec §4.8.5);
# without `units` it is undeterminable, like a bare literal. An unresolvable
# string is reported at the containing expression field by `model_unit_findings`,
# not here.
# Under the esm-spec §4.8.6 literal rule a unit-less `const` types exactly as
# the bare literal it is (`_literal_unit`).
_const_units_rule(expr, var_units, findings) =
    expr.units === nothing ? _literal_unit(expr.value, var_units) :
    _absolute_unit(parse_units(expr.units))

const _DIMENSION_RULES = let rules = Dict{String, Function}(
        "+" => _same_dimension_rule,
        "-" => _same_dimension_rule,
        "*" => _product_rule,
        "/" => _quotient_rule,
        "^" => _power_rule,
        "pow" => _power_rule,
        "sqrt" => _sqrt_rule,
        "min" => _minmax_rule,
        "max" => _minmax_rule,
        "ifelse" => _ifelse_rule,
        "sign" => _dimensionless_result_rule,
        "abs" => _preserve_dimension_rule,
        # `Pre` PRESERVES its operand's dimension (esm-spec §4.8.3) — it names
        # the operand's value at the previous step, not a dimensionless one.
        "Pre" => _preserve_dimension_rule,
        # `ic(x)` names x's initial value, so it CARRIES x's unit, dimension
        # and scale (esm-spec §4.8.3) — under either literal rule.
        "ic" => _preserve_dimension_rule,
        "D" => _derivative_rule,
        # esm 2.4.0 (esm-spec §4.2): the fixed unit expressions of the defined
        # operators `partial` ([f]/[wrt]) and `integral` ([f]·[var]), which hold
        # resolved or not.
        "partial" => _partial_rule,
        "integral" => _integral_rule,
        # A `const` that DECLARES its units has that unit (esm-spec §4.8.5).
        "const" => _const_units_rule,
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
        # A boolean connective's result is a dimensionless boolean; its operands
        # are still walked for the findings inside them.
        rules[op] = _boolean_rule
    end
    rules
end

# The array operators (esm-spec §4.8.3). The CHECKER and the evaluation path
# (the angle rewrite, `_normalize_angle_expr` in flatten.jl) read them by the
# same rules, so `cos(index(lat, i))` with `lat` in `deg` is converted exactly
# where the checker says the argument is in degrees. The rules are the same,
# case for case, as the Rust binding's `propagate_array_dim` (units.rs):
#
# * `index`, `reshape`, `transpose` — the unit of the source array, `args[1]`
#   (the subscripts are walked for findings but are not part of the unit); no
#   args: undeterminable.
# * `concat` — like an n-ary `+`: determinable operands agree in dimension AND
#   scale, undeterminable ones are skipped.
# * `makearray` — its regions' `values` agree like the operands of `+`; its
#   operands are walked for findings.
# * `broadcast(fn=F, args)` — the unit of `{op: F, args}`.
# * `faq` — its `filter`, `expr` and operands are always walked for findings;
#   its own unit is decided by its ⊕ (`_faq_unit`).
# The registry's array and aggregate categories.
const _ARRAY_ELEMENT_OPS = Set(
    s.name for s in _OP_TABLE if s.category === :array || s.category === :aggregate
)

function _array_element_rule(expr, var_units, findings)
    if expr.op == "faq"
        # The `filter` is a boolean whose value never reaches the faq's unit,
        # but it is an expression like any other (EarthSciAST#414).
        expr.filter !== nothing && _expr_dimensions!(findings, expr.filter, var_units)
        body = expr.expr_body === nothing ? nothing :
            _expr_dimensions!(findings, expr.expr_body, var_units)
        for a in expr.args
            _expr_dimensions!(findings, a, var_units)
        end
        return _faq_unit(expr, body)
    elseif expr.op == "makearray"
        for a in expr.args
            _expr_dimensions!(findings, a, var_units)
        end
        expr.values === nothing && return nothing
        return _same_dimensions_over(
            expr.values, var_units, findings,
            (first_dim, dim) -> "'makearray' regions must share units: " *
                "'$(_ustr(first_dim))' vs '$(_ustr(dim))'"
        )
    elseif expr.op == "concat"
        return _same_dimensions_over(
            expr.args, var_units, findings,
            (first_dim, dim) -> "Incompatible dimensions/scales in 'concat': " *
                "'$(_ustr(first_dim))' vs '$(_ustr(dim))'"
        )
    elseif expr.op == "broadcast"
        if expr.fn === nothing
            for a in expr.args
                _expr_dimensions!(findings, a, var_units)
            end
            return nothing
        end
        return _expr_dimensions!(findings, OpExpr(expr.fn, expr.args), var_units)
    end
    # index / reshape / transpose: every operand is walked for findings, the
    # source array alone gives the unit.
    dims = [_expr_dimensions!(findings, a, var_units) for a in expr.args]
    return isempty(dims) ? nothing : dims[1]
end

# The unit of an `faq` node whose `expr` has unit `body`. The ⊗ is written by
# the author inside `expr`, so it is already typed; `join` clauses are key
# equalities and contribute no factor. What remains is the ⊕ over the
# contracted indices, from `semiring` when present, else `reduce` (default "+"):
#
# * `sum_product`, `max_product`, `min_sum`, `max_sum`, or `reduce` `+`/`max`/
#   `min` — the body's unit;
# * `reduce: "*"` — the body's unit only when it is a pure number (dimensionless
#   at exact scale 1); otherwise undeterminable, as the power is the range length;
# * `bool_and_or` — dimensionless, a boolean;
# * value invention (`distinct: true`, or a `key`) — undeterminable: the result
#   is ids, not a quantity. So is a missing `expr` and an unknown ⊕ spelling
#   (rejected elsewhere).
const _FAQ_BODY_UNIT_SEMIRINGS = ("sum_product", "max_product", "min_sum", "max_sum")
const _FAQ_BODY_UNIT_REDUCES = ("+", "max", "min")

function _faq_unit(expr, body)
    (expr.distinct === true || expr.key !== nothing) && return nothing
    expr.expr_body === nothing && return nothing
    if expr.semiring !== nothing
        expr.semiring == "bool_and_or" && return Unitful.NoUnits
        return expr.semiring in _FAQ_BODY_UNIT_SEMIRINGS ? body : nothing
    end
    r = expr.reduce === nothing ? "+" : expr.reduce
    r in _FAQ_BODY_UNIT_REDUCES && return body
    if r == "*"
        (body !== nothing && _is_pure_number(body) && !_is_angle_bearing(body)) &&
            return body
        return nothing
    end
    return nothing
end

# ---------------------------------------------------------------------------
# THE DIMENSIONLESS-LITERAL RULE (esm-spec §4.8.6), a switch on the engine.
#
# With the switch ON, a bare numeric literal, and a `const` without `units`,
# whose value is nonzero types as DIMENSIONLESS at scale 1 instead of
# undeterminable. Zero stays neutral (`D(y) = 0`, `max(x, 0)`), and so does a
# unary `-` of zero, because a unary sign carries its operand's unit. Nothing
# else changes. The switch is carried by the unit environment itself — the
# `var_units` every rule already threads through — so no rule needs a new
# argument: `_LiteralRuleEnv` wraps an environment and answers lookups exactly
# as it does. OFF (any other environment) is today's behaviour.
#
# At this stage the rule only drives the `units_dimensionless_literal_mismatch`
# WARNING (`_dimensionless_literal_findings`); validity is decided by the
# current, neutral-literal rule alone.
# ---------------------------------------------------------------------------
struct _LiteralRuleEnv{K, V, D <: AbstractDict{K, V}} <: AbstractDict{K, V}
    inner::D
end
Base.get(env::_LiteralRuleEnv, name, default) = get(env.inner, name, default)
Base.getindex(env::_LiteralRuleEnv, name) = env.inner[name]
Base.haskey(env::_LiteralRuleEnv, name) = haskey(env.inner, name)
Base.length(env::_LiteralRuleEnv) = length(env.inner)
Base.iterate(env::_LiteralRuleEnv, state...) = iterate(env.inner, state...)
_indep_of(env::_LiteralRuleEnv) = _indep_of(env.inner)

# `var_units` with the §4.8.6 literal rule switched on or off.
_with_literal_rule(var_units::AbstractDict, on::Bool) =
    on ? (var_units isa _LiteralRuleEnv ? var_units : _LiteralRuleEnv(var_units)) :
    (var_units isa _LiteralRuleEnv ? var_units.inner : var_units)

# The unit of a bare literal (or unit-less `const`) of value `v`: undeterminable
# under the current rule (esm-spec §4.8.4); under the §4.8.6 rule dimensionless
# at scale 1 unless it is zero.
function _literal_unit(v, var_units)
    var_units isa _LiteralRuleEnv || return nothing
    (v isa Real && !(v isa Bool)) || return nothing
    iszero(v) && return nothing
    return Unitful.NoUnits
end

# ---------------------------------------------------------------------------
# TEMPLATE REFERENCES (esm-spec §4.8.5 item 5, §9.6.4 rule 2).
#
# A reference has the unit of its expansion, and the engine judges it without
# expanding: the unit of a reference is the unit of its instance's prepared
# body (templates/frames.jl `_tpl_frame`), with each parameter sentinel bound
# to the unit of its binding, computed in the caller's environment. The body is
# analysed once per distinct instance — the template instance, each binding's
# unit, the value of each binding that is a constant, and the §4.8.6 literal
# switch — and the unit and the body's findings are reused at every use.
#
# The template table reaches the engine through the environment it already
# threads: `_TplUnitEnv` wraps a component's environment (`_tpl_units_env`),
# answers every lookup of a name as the environment it wraps does, and carries
# the table, the frame a body is read in and each sentinel's binding unit.
# ---------------------------------------------------------------------------

# A body finding that stands for the findings inside the binding of the
# parameter sentinel `sentinel`: the expansion has them wherever the body
# reads the parameter, so a cached body result is replayed with each use's own.
struct _TplArgFindings
    sentinel::String
end

struct _TplUnitEnv{D <: AbstractDict} <: AbstractDict{String, String}
    inner::D
    tt::_TplTable
    # The frame the body is read in; `nothing` at a component's own sites.
    frame::Union{Nothing, _TplFrame}
    # Sentinel => (the binding's unit, the findings inside the binding).
    args::Dict{String, Tuple{Any, Vector{Any}}}
    # Instance key => (unit, findings) of a body, shared by one component's walk.
    memo::Dict{Vector{Any}, Tuple{Any, Vector{Any}}}
end
Base.get(env::_TplUnitEnv, name, default) = get(env.inner, name, default)
Base.getindex(env::_TplUnitEnv, name) = env.inner[name]
Base.haskey(env::_TplUnitEnv, name) = haskey(env.inner, name)
Base.length(env::_TplUnitEnv) = length(env.inner)
Base.iterate(env::_TplUnitEnv, state...) = iterate(env.inner, state...)
_indep_of(env::_TplUnitEnv) = _indep_of(env.inner)

# `env` reading the template references of a component against the table `tt`
# (`nothing`: a component with no surviving reference, `env` unchanged).
_tpl_units_env(env::AbstractDict, ::Nothing) = env
_tpl_units_env(env::AbstractDict, tt::_TplTable) = _TplUnitEnv(
    env, tt, nothing, Dict{String, Tuple{Any, Vector{Any}}}(),
    Dict{Vector{Any}, Tuple{Any, Vector{Any}}}()
)

# The template scope of a unit environment, under the literal-rule switch.
_tpl_unit_scope(env::_LiteralRuleEnv) = _tpl_unit_scope(env.inner)
_tpl_unit_scope(env::_TplUnitEnv) = env
_tpl_unit_scope(::AbstractDict) = nothing
# The frame a site's expressions are read in, and the template table.
_tpl_unit_frame(env) = (sc = _tpl_unit_scope(env); sc === nothing ? nothing : sc.frame)
_tpl_unit_table(env) = (sc = _tpl_unit_scope(env); sc === nothing ? nothing : sc.tt)

# A parameter sentinel inside a body: its binding's unit, with a marker where
# the binding's own findings belong.
function _tpl_sentinel_unit!(findings, name::String, var_units)
    sc = _tpl_unit_scope(var_units)
    (sc === nothing || !haskey(sc.args, name)) && return nothing
    u, _ = sc.args[name]
    push!(findings, _TplArgFindings(name))
    return u
end

# Does a literal-sensitive rule read the binding `b` (in `fr`) by value?
_tpl_unit_literal(b, fr) =
    _constant_exponent_value(b, fr) !== nothing || _bare_literal_value(b, fr) !== nothing

# The unit of the reference `call`, its findings appended to `findings`.
function _tpl_call_unit!(findings, call::OpExpr, var_units)
    sc = _tpl_unit_scope(var_units)
    # No registry: a reference has no unit the engine can read.
    sc === nothing && return nothing
    fr = _tpl_frame_or_nothing(sc.tt, call, sc.frame)
    # An unresolvable reference is reported by the template checks.
    fr === nothing && return nothing
    on = var_units isa _LiteralRuleEnv
    args = Dict{String, Tuple{Any, Vector{Any}}}()
    key = Any[objectid(fr.body), on]
    for k in sort!(collect(keys(fr.args)))
        # The binding as THIS reference writes it, read in this reference's
        # frame. The frame is shared by every reference with the same binding
        # keys (`_tpl_frame`), so `fr.args[k]` may be another caller's
        # binding, written in that caller's frame (its parameter sentinels are
        # not this frame's).
        b = _tpl_call_binding(call, k)
        f = Any[]
        u = _expr_dimensions!(f, b, var_units)
        args[k] = (u, f)
        push!(key, k, u, _tpl_unit_literal(b, sc.frame) ? _tpl_bkey(sc.tt, b, sc.frame) : nothing)
    end
    hit = get(sc.memo, key, nothing)
    if hit === nothing
        benv = _TplUnitEnv(_with_literal_rule(var_units, false), sc.tt, fr, args, sc.memo)
        bf = Any[]
        u = _expr_dimensions!(bf, fr.body, on ? _LiteralRuleEnv(benv) : benv)
        hit = (u, bf)
        sc.memo[key] = hit
    end
    u, bf = hit
    for x in bf
        if x isa _TplArgFindings
            append!(findings, args[x.sentinel][2])
        else
            push!(findings, x)
        end
    end
    # esm 2.4.0 (esm-spec §4.8.3, §9.6.12): a call's unit is its definition's
    # unit expression, evaluated from the bindings' units without evaluating the
    # body; the body's unit is checked against it.
    u = _definition_call_unit!(findings, call, fr, args, u, var_units)
    # An element call's subscripts, walked as `index` walks them.
    for s in _tpl_out_bindings(call)
        _expr_dimensions!(findings, s, var_units)
    end
    return u
end

# The raw registry entry a reference names, or `nothing`.
function _tpl_decl(sc, name)
    reg = sc.tt.reg
    (reg === nothing || !(name isa AbstractString) || !haskey(reg, name)) && return nothing
    return reg[name]
end

# The unit a definition parameter stands for at one call (esm-spec §9.6.1
# `units`): the unit of what the call binds to it — an operand's unit, or, for a
# parameter in a structural position bound to an axis name, that coordinate's.
function _param_unit(p::String, call::OpExpr, args, var_units)
    a = get(args, _TPL_ARG * p, nothing)
    a === nothing || return a[1]
    b = call.bindings === nothing ? nothing : get(call.bindings, p, nothing)
    b isa VarExpr || return nothing
    haskey(var_units, b.name) || return nothing
    return _absolute_unit(parse_units(var_units[b.name]))
end

# Evaluate a unit expression (raw JSON over params, names, unit-bearing `const`,
# `*`, `/`, `^` with a constant exponent). `nothing` when undeterminable.
function _eval_unit_expr(x, params::Set{String}, punit, var_units)
    if x isa AbstractString
        s = String(x)
        s in params && return punit(s)
        haskey(var_units, s) || return nothing
        return _absolute_unit(parse_units(var_units[s]))
    elseif x isa Number && !(x isa Bool)
        return Unitful.NoUnits
    elseif _is_object(x)
        op = _raw_get(x, "op")
        args = _raw_get(x, "args")
        if op == "const"
            us = _raw_get(x, "units")
            return us isa AbstractString ? _absolute_unit(parse_units(us)) : Unitful.NoUnits
        end
        (args !== nothing && _is_array(args)) || return nothing
        if op == "*" || op == "/"
            vals = Any[_eval_unit_expr(a, params, punit, var_units) for a in args]
            any(v -> v === nothing, vals) && return nothing
            isempty(vals) && return nothing
            op == "*" && return reduce(*, vals)
            length(vals) == 2 || return nothing
            return vals[1] / vals[2]
        elseif op == "^" && length(args) == 2
            b = _eval_unit_expr(args[1], params, punit, var_units)
            e = args[2]
            (b === nothing || !(e isa Number) || e isa Bool) && return nothing
            return b^(e isa Integer ? Int(e) : rationalize(Float64(e)))
        end
    end
    return nothing
end

# The fixed unit expression of `partial` / `integral` (esm-spec §4.2) a
# definition of either must agree with, read off its `match` pattern: the
# pattern's operand over (or times) its axis field.
function _fixed_unit_expr(decl)
    m = _raw_get(decl, "match")
    (m !== nothing && _is_object(m)) || return nothing
    op = _raw_get(m, "op")
    args = _raw_get(m, "args")
    (args !== nothing && _is_array(args) && !isempty(args)) || return nothing
    if op == "partial"
        w = _raw_get(m, "wrt")
        w === nothing && return nothing
        return OrderedDict{String, Any}("op" => "/", "args" => Any[args[1], w])
    elseif op == "integral"
        v = _raw_get(m, "var")
        v === nothing && return nothing
        return OrderedDict{String, Any}("op" => "*", "args" => Any[args[1], v])
    end
    return nothing
end

# The prefix of a `definition_unit_mismatch` WARNING carried through a findings
# list (esm-spec §9.6.12: the body's unit is undeterminable). Every reader of a
# findings list sorts these out (`_split_unit_warnings`); they never count as
# a provable inconsistency.
const _DEFINITION_UNIT_WARNING = "definition_unit_mismatch (warning)"
_is_unit_warning(m) = m isa AbstractString && startswith(m, _DEFINITION_UNIT_WARNING)

# A call's unit (esm-spec §9.6.12 "Units"): the definition's unit expression when
# it has one, else the body's unit `body_u`; a disagreement between them, or
# with the fixed expression of `partial` / `integral`, is
# `definition_unit_mismatch` — an error when the body's unit is determinable, a
# warning when it is not.
function _definition_call_unit!(findings, call::OpExpr, fr, args, body_u, var_units)
    sc = _tpl_unit_scope(var_units)
    decl = _tpl_decl(sc, call.name)
    decl === nothing && return body_u
    uexpr = _raw_get(decl, "units")
    fixed = _fixed_unit_expr(decl)
    (uexpr === nothing && fixed === nothing) && return body_u
    params = Set{String}(_TemplateDecl(decl).params)
    punit = p -> _param_unit(p, call, args, var_units)
    declared = uexpr === nothing ? nothing : _eval_unit_expr(uexpr, params, punit, var_units)
    fixed_u = fixed === nothing ? nothing : _eval_unit_expr(fixed, params, punit, var_units)
    call_u = uexpr !== nothing ? declared : body_u
    for (what, want) in (("its unit expression", declared), ("the fixed unit expression of '$(_raw_get(decl, "defines"))'", fixed_u))
        want === nothing && continue
        if body_u === nothing
            push!(
                findings,
                "$(_DEFINITION_UNIT_WARNING): the body of definition '$(call.name)' has an " *
                    "undeterminable unit, so it cannot be checked against $what " *
                    "('$(_ustr(want))') (esm-spec §9.6.12)"
            )
        elseif !_same_unit(body_u, want)
            push!(
                findings,
                "definition_unit_mismatch: the body of definition '$(call.name)' has unit " *
                    "'$(_ustr(body_u))', but $what gives '$(_ustr(want))' (esm-spec §9.6.12)"
            )
        end
    end
    # A unit expression must itself agree with the fixed one of partial/integral.
    if declared !== nothing && fixed_u !== nothing && !_same_unit(declared, fixed_u)
        push!(
            findings,
            "definition_unit_mismatch: the unit expression of definition '$(call.name)' " *
                "gives '$(_ustr(declared))', but the fixed unit expression of " *
                "'$(_raw_get(decl, "defines"))' gives '$(_ustr(fixed_u))' (esm-spec §4.2)"
        )
    end
    return call_u === nothing ? (fixed === nothing ? body_u : something(fixed_u, body_u)) : call_u
end

# The engine proper. Returns the expression's dimension, or `nothing` when it
# cannot be determined; every PROVABLE inconsistency encountered anywhere in the
# subtree is appended to `findings`. See the invariant at the top of this block.
function _expr_dimensions!(
        findings::AbstractVector, expr::ASTExpr,
        var_units::AbstractDict
    )::Union{Unitful.Units, Nothing}
    if expr isa NumExpr || expr isa IntExpr
        # A bare number's dimension is INDETERMINATE, not dimensionless
        # (esm-spec §4.8.4). The three positions where a
        # literal's meaning IS determined are handled by their own rules. Under
        # the esm-spec §4.8.6 switch a nonzero one is dimensionless instead.
        return _literal_unit(expr.value, var_units)
    elseif expr isa VarExpr
        # A template parameter inside a body read through its frame.
        _tpl_is_sentinel(expr.name) && return _tpl_sentinel_unit!(findings, expr.name, var_units)
        # Look up variable units; a variable we know nothing about has
        # *unknown* dimensions, not dimensionless ones.
        unit_str = get(var_units, expr.name, nothing)
        if unit_str === nothing
            # The independent variable, undeclared, has the time dimension in
            # seconds (esm-spec §4.9.1), as in the other bindings. A derivative
            # WITH RESPECT TO it stays undeterminable (`_derivative_rule` reads
            # only declared units).
            expr.name == _indep_of(var_units) && return u"s"
            return nothing
        end
        return _absolute_unit(parse_units(unit_str))
    elseif expr isa OpExpr
        # A template reference: the unit of its expansion, read through its frame.
        _tpl_is_call(expr) && return _tpl_call_unit!(findings, expr, var_units)
        rule = get(_DIMENSION_RULES, expr.op, nothing)
        rule !== nothing && return rule(expr, var_units, findings)
        expr.op in _ARRAY_ELEMENT_OPS &&
            return _array_element_rule(expr, var_units, findings)
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
# throws `Unitful.AffineError`. The engine only ever needs a unit's
# DIMENSION, so normalise an affine unit to its absolute counterpart (°C → K)
# on the way in. Note this is deliberately confined to the engine:
# `parse_units` still returns the affine unit, because
# `validate_conversion_factor_consistency` needs the affine/linear distinction
# and `model_unit_findings`' declared-vs-default check needs `K != °C`.
function _absolute_unit(u)
    u === nothing && return nothing
    try
        return Unitful.absoluteunit(u)
    catch err
        _is_resource_error(err) && rethrow()
        return u
    end
end

"""
    expression_unit_findings(expr::ASTExpr, var_units::AbstractDict;
                             dimensionless_literals=false) -> Vector{String}

Every PROVABLE dimensional inconsistency inside `expr`, as human-readable
messages. Empty means "nothing provably wrong" — NOT "fully checked": an
expression whose dimensions are indeterminate (an undeclared variable, an
operator with no dimensional rule) yields no findings.

This is the silent, error-collecting counterpart of
[`get_expression_dimensions`](@ref) and the entry point the structural validator
builds on.

`dimensionless_literals = true` types a nonzero bare numeric literal (and a
`const` without `units`) as dimensionless at scale 1 instead of undeterminable
(esm-spec §4.8.6); zero stays neutral. Off by default: validity is decided by
the neutral-literal rule.
"""
function expression_unit_findings(
        expr::ASTExpr, var_units::AbstractDict;
        dimensionless_literals::Bool = false
    )::Vector{String}
    findings = String[]
    _expr_dimensions!(findings, expr, _with_literal_rule(var_units, dimensionless_literals))
    return filter!(!_is_unit_warning, findings)
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

`dimensionless_literals` switches on the esm-spec §4.8.6 literal rule, as for
[`expression_unit_findings`](@ref).
"""
function get_expression_dimensions(
        expr::ASTExpr, var_units::AbstractDict;
        dimensionless_literals::Bool = false
    )::Union{Unitful.Units, Nothing}
    findings = String[]
    dim = _expr_dimensions!(findings, expr, _with_literal_rule(var_units, dimensionless_literals))
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

The PROVABLE dimensional inconsistencies of a derivative equation, if any: an
operator-rule mismatch inside either side, then the mismatch between the two
SIDES (the whole equation check site, esm-spec §4.8.4, §4.8.6), which
`validate` reports for every `D(u, t) = …` equation (see
[`model_unit_findings`](@ref)).

Scope, and why it is this narrow:

* **Only derivative equations are compared here.** An equation with a `D(u, t)`
  LHS states a rate law and its two sides must balance. A defining equation
  (`u = f(x)`) is checked against the declared units of `u` by
  [`model_unit_findings`](@ref), and an algebraic or implicit LHS
  (`H*H*SO4 = Ksp`) states a *constraint* that is not compared.

* **Expression-internal inconsistencies are NOT collected here.** They are
  checked on defining equations and on parameter `update` expressions (see
  [`model_unit_findings`](@ref)).

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
    lhs = eq.lhs
    (lhs isa OpExpr && lhs.op == "D" && length(lhs.args) == 1) || return String[]
    return _site_findings(lhs, eq.rhs, var_units)
end

# THE CHECK OF ONE SITE (esm-spec §4.8.4, §4.8.6) under `var_units`'s literal
# rule: `(internal, comparison)`. `internal` is every operator-rule mismatch
# inside the site's expressions; `comparison` is the mismatch between the two
# sides of an equation, in dimension and exact scale, when both are
# determinable. A reaction rate (`lhs === nothing`) has no comparison: it is not
# compared with its stoichiometric order here.
#
# A `D(x)` left-hand side with respect to an UNDECLARED independent variable is
# undeterminable, so the two sides are not compared directly: whatever unit the
# time carries contributes only powers of TIME, so the comparison fails iff
# [x] / [rhs] has a non-time axis with nonzero power.
#
# The validator's equation checks (`model_unit_findings`) and the
# dimensionless-literal warning (`_site_findings`) both read this one function.
function _site_check(lhs, rhs, var_units)::Tuple{Vector{String}, Vector{String}}
    internal = String[]
    comparison = String[]
    left = lhs === nothing ? nothing : _expr_dimensions!(internal, lhs, var_units)
    right = _expr_dimensions!(internal, rhs, var_units)
    lhs === nothing && return internal, comparison
    state = _derivative_of_undeclared_time(lhs, var_units)
    if state !== nothing
        state_dim = _expr_dimensions!(String[], state, var_units)
        (state_dim === nothing || right === nothing) && return internal, comparison
        ratio = dimension(state_dim) / dimension(right)
        _is_time_power(ratio) || push!(
            comparison,
            "Derivative of '$(_message_ustr(state_dim))' cannot equal an expression " *
                "with units '$(_message_ustr(right))' under any time unit (they differ " *
                "by $(ratio), not by a power of time)"
        )
        return internal, comparison
    end
    (
        left === nothing || right === nothing ||
            _units_agree_where_angle_meets_number(left, right)
    ) &&
        return internal, comparison
    push!(
        comparison, "Left-hand side has units '$(_message_ustr(left))' but " *
            "right-hand side has units '$(_message_ustr(right))'"
    )
    return internal, comparison
end

# A site's verdict as esm-spec §4.8.6 states it: FAIL (nonempty) on a mismatch
# anywhere in the site, internal or between the sides.
function _site_findings(lhs, rhs, var_units)::Vector{String}
    internal, comparison = _site_check(lhs, rhs, var_units)
    return filter(!_is_unit_warning, vcat(internal, comparison))
end

# The operand `x` when `lhs` is `D(x)` taken with respect to an independent
# variable the component does not declare, else `nothing`.
function _derivative_of_undeclared_time(lhs, var_units)
    (lhs isa OpExpr && lhs.op == "D" && length(lhs.args) == 1) || return nothing
    wrt = lhs.wrt !== nothing ? lhs.wrt : _indep_of(var_units)
    get(var_units, wrt, nothing) === nothing || return nothing
    return lhs.args[1]
end

# A unit for a finding's message; a pure number reads as such rather than as
# Unitful's empty spelling.
_message_ustr(u) = (_is_pure_number(u) && !_is_angle_bearing(u)) ? "dimensionless" : _ustr(u)

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

"""
    UNIT_DIMENSION_MISMATCH::String

The [`UnitFinding`](@ref) `code` for a PROVABLE dimensional inconsistency
(esm-spec §4.8.4), such as adding metres to seconds. Its value is
`"unit_inconsistency"`, the structural error the finding is reported as by
[`validate`](@ref).
"""
const UNIT_DIMENSION_MISMATCH = ERROR_CODES.UNIT_INCONSISTENCY

# A finding the definition-unit check made (esm-spec §9.6.12) carries its own
# code, `definition_unit_mismatch`; every other is `unit_inconsistency`.
_unit_finding_code(msg::AbstractString) =
    startswith(msg, "definition_unit_mismatch:") ? ERROR_CODES.DEFINITION_UNIT_MISMATCH :
    UNIT_DIMENSION_MISMATCH

"""
    UNIT_PARSE_ERROR::String

The [`UnitFinding`](@ref) `code` for a declared unit string that does not parse
under the esm-spec §4.8.2 grammar or names a symbol outside the §4.8.1
registry. Its value is `"unit_parse_error"`, which is also the structural
error code [`validate`](@ref) reports it under.

A defect in the FILE, not a limit of the checker, so it is a hard error, never
a warning, and the unit is never coerced to dimensionless (which would turn off
every dimensional check downstream of it: a typo like `"m/s2"` would simply
disable the checker).
"""
const UNIT_PARSE_ERROR = ERROR_CODES.UNIT_PARSE_ERROR

# A model's unit environment: its variables' declared units that RESOLVE (an
# unresolvable one is reported at its declaration and left unknown here), then
# scoped references into its own subsystems and into the document's top-level
# components (esm-spec §4.8.4). The model's own bare names are never
# overwritten.
function _model_unit_env(model::Model, toplevel::_ScopedUnits; indep::AbstractString = "t")::_UnitEnv
    own_units = Dict{String, String}()
    for (name, var) in model.variables
        var.units !== nothing && !isempty(var.units) &&
            parse_units(var.units) !== nothing && (own_units[name] = var.units)
    end
    return _UnitEnv(own_units, _relative_scoped_units(model), toplevel, String(indep))
end

# A reaction system's unit environment, built as `_model_unit_env` builds a
# model's: its species' and parameters' declared units that resolve, then its
# scoped references.
function _reaction_system_unit_env(
        rs::ReactionSystem, toplevel::_ScopedUnits; indep::AbstractString = "t"
    )::_UnitEnv
    own_units = Dict{String, String}()
    for decl in Iterators.flatten((rs.species, rs.parameters))
        u = decl.units
        (u !== nothing && !isempty(u) && parse_units(u) !== nothing) &&
            (own_units[decl.name] = u)
    end
    return _UnitEnv(own_units, _relative_scoped_units(rs), toplevel, String(indep))
end

_component_unit_env(m::Model, toplevel; indep = "t") = _model_unit_env(m, toplevel; indep)
_component_unit_env(rs::ReactionSystem, toplevel; indep = "t") =
    _reaction_system_unit_env(rs, toplevel; indep)

# Is `u` an affine unit (°C, °F) standing alone? `parse_units` keeps a
# standalone affine atom (`_linear`), so a declared `K` and a default in `degC`
# can be told apart.
_is_affine_unit(u) = u isa Unitful.AffineUnits

# Are two declared unit strings the same unit: the same dimension, exact scale
# and angle power, and both affine or both not?
_same_declared_unit(a, b) =
    _is_affine_unit(a) == _is_affine_unit(b) &&
    _same_unit(_absolute_unit(a), _absolute_unit(b))

# The site kinds the units checker judges (esm-spec §4.8.4, §4.8.6): the
# equations of a model, its initialization equations, a reaction system's
# constraint equations, each reaction rate, and a parameter update's `when` and
# `expression`. Every other site kind is visited only for its unit-bearing
# `const` strings.
const _UNIT_EQUATION_SITES = Dict{Symbol, Symbol}(
    :equation_rhs => :equation_lhs,
    :initialization_rhs => :initialization_lhs,
    :constraint_rhs => :constraint_lhs,
)
const _UNIT_LHS_SITES = Set{Symbol}(values(_UNIT_EQUATION_SITES))
# The sites the esm-spec §4.8.6 literal warning compares under both rules.
const _UNIT_LITERAL_SITES = Set{Symbol}((keys(_UNIT_EQUATION_SITES)..., :rate))

# The pointer below `component` a site pointer `p` names, without its leading
# "/"; the equation sites are reported at the equation, not at its `rhs`.
function _unit_site_subpath(p::AbstractString, kind::Symbol)
    rel = p[2:end]
    haskey(_UNIT_EQUATION_SITES, kind) && return rel[1:(end - length("/rhs"))]
    kind === :rate && return rel[1:(end - length("/rate"))]
    return rel
end

"""
    _component_unit_findings!(errors, warnings, component, pointer, env)

The units checker for one model or reaction system (not its subsystems): every
finding at every unit check site, judged once.

- A `units` / `default_units` string that does not resolve is a
  `unit_parse_error` at the declaration; a model variable's `default_units`
  that are not the same unit as its `units` are a `unit_inconsistency` there.
- A unit-bearing `const` whose string does not resolve is a `unit_parse_error`
  at the containing expression field, at every expression site.
- Each equation, initialization equation, constraint equation, reaction rate
  and parameter-update `when`/`expression` is judged under the current rule
  (`_site_check`): any operator-rule mismatch inside it, and for an equation
  the comparison of its two sides, is a `unit_inconsistency`. A model
  equation whose left-hand side is a declared variable is reported at that
  variable (its internal mismatches if any, else the comparison); every other
  site at its own pointer.
- A site of `_UNIT_LITERAL_SITES` the current rule passes but the esm-spec
  §4.8.6 literal rule fails is a `units_dimensionless_literal_mismatch` pushed
  onto `warnings`, its message naming `pointer` and the site.

`errors` and `warnings` collect [`UnitFinding`](@ref)s whose `subpath` is
relative to `pointer`, the component's own JSON pointer.
"""
function _component_unit_findings!(
        errors::Vector{UnitFinding}, warnings::Vector{UnitFinding},
        c::Union{Model, ReactionSystem}, pointer::AbstractString, env
    )
    _declaration_unit_findings!(errors, c)
    lhs = Ref{Any}(nothing)
    tt = _tpl_unit_table(env)
    foreach_expression(c; subsystems = false) do e, p, kind
        for units in unresolvable_const_units(e, tt)
            push!(
                errors, UnitFinding(
                    p[2:end], "Unit string '$units' is not a recognised unit", UNIT_PARSE_ERROR
                )
            )
        end
        if kind in _UNIT_LHS_SITES
            lhs[] = e
            return
        end
        site_lhs = haskey(_UNIT_EQUATION_SITES, kind) ? lhs[] : nothing
        (site_lhs !== nothing || kind in (:rate, :update_when, :update_expression)) || return
        _unit_site!(errors, warnings, c, pointer, p, kind, site_lhs, e, env)
        return
    end
    return errors
end

function _declaration_unit_findings!(out, m::Model)
    for name in sort!(collect(keys(m.variables)))
        var = m.variables[name]
        at = _pointer("variables", name)
        for (field, str) in (("units", var.units), ("default_units", var.default_units))
            (str === nothing || isempty(str) || parse_units(str) !== nothing) && continue
            push!(
                out, UnitFinding(
                    at, "Unit string '$str' is not a recognised unit " *
                        "(variable '$name', field '$field')", UNIT_PARSE_ERROR
                )
            )
        end
        du, u = var.default_units, var.units
        (du === nothing || isempty(du) || u === nothing || isempty(u) || du == u) && continue
        du_parsed, u_parsed = parse_units(du), parse_units(u)
        (du_parsed === nothing || u_parsed === nothing) && continue
        _same_declared_unit(du_parsed, u_parsed) && continue
        push!(
            out, UnitFinding(
                at, "Parameter default value units do not match declared units " *
                    "(variable '$name', declared_units='$u', default_units='$du')",
                UNIT_DIMENSION_MISMATCH
            )
        )
    end
    return out
end

function _declaration_unit_findings!(out, rs::ReactionSystem)
    for (block, decls) in (("species", rs.species), ("parameters", rs.parameters))
        for decl in decls, (field, str) in (("units", decl.units), ("default_units", decl.default_units))
            (str === nothing || isempty(str) || parse_units(str) !== nothing) && continue
            push!(
                out, UnitFinding(
                    _pointer(block, decl.name),
                    "Unit string '$str' is not a recognised unit " *
                        "($(block == "species" ? "species" : "parameter") '$(decl.name)', field '$field')",
                    UNIT_PARSE_ERROR
                )
            )
        end
    end
    return out
end

# Judge one site (see `_component_unit_findings!`).
function _unit_site!(errors, warnings, c, pointer, p, kind, lhs, rhs, env)
    internal, comparison = _site_check(lhs, rhs, env)
    sub = _unit_site_subpath(p, kind)
    # esm-spec §9.6.12: an undeterminable definition body is a warning.
    for m in unique(filter(_is_unit_warning, internal))
        push!(warnings, UnitFinding(sub, string(pointer, "/", sub, ": ", m), ERROR_CODES.DEFINITION_UNIT_MISMATCH))
    end
    filter!(!_is_unit_warning, internal)
    if !(isempty(internal) && isempty(comparison))
        if kind === :equation_rhs && c isa Model && lhs isa VarExpr &&
                haskey(c.variables, lhs.name)
            name = lhs.name
            for msg in (isempty(internal) ? comparison : internal)
                push!(
                    errors, UnitFinding(
                        _pointer("variables", name), "$msg (variable '$name')",
                        _unit_finding_code(msg)
                    )
                )
            end
        elseif kind === :update_when || kind === :update_expression
            field = kind === :update_when ? "when" : "expression"
            for msg in internal
                push!(errors, UnitFinding(sub, "$msg ($(_update_site_label(c, p)), field '$field')", _unit_finding_code(msg)))
            end
        else
            for msg in vcat(internal, comparison)
                push!(errors, UnitFinding(sub, msg, _unit_finding_code(msg)))
            end
        end
        return
    end
    kind in _UNIT_LITERAL_SITES || return
    literals = _nonzero_literals(lhs === nothing ? (rhs,) : (lhs, rhs), _tpl_unit_table(env))
    # With no nonzero literal the two rules type the site identically.
    isempty(literals) && return
    found = _site_findings(lhs, rhs, _with_literal_rule(env, true))
    isempty(found) && return
    at = string(pointer, "/", sub)
    push!(
        warnings, UnitFinding(
            sub,
            "$at: with bare numeric literals read as dimensionless " *
                "(esm-spec §4.8.6), $(first(found)); bare literal(s): $(join(literals, ", ")). " *
                "This becomes an error in a future version of EarthSciAST; a literal that " *
                "carries a unit is written const(value, units \"...\") (esm-spec §4.8.5)",
            UNIT_FINDING_DIMENSIONLESS_LITERAL
        )
    )
    return
end

# "variable 'v'" or "parameter 'p'", with ", update rule i" when the rule list
# has more than one rule: the label of an update site's finding, read off its
# pointer (`/variables/<v>/update[/<i>]/<field>` or `/parameters/<p>/...`).
function _update_site_label(c, p::AbstractString)
    parts = split(p[2:end], '/')
    owner = parts[1] == "variables" ? "variable" : "parameter"
    name = replace(replace(parts[2], "~1" => "/"), "~0" => "~")
    label = "$owner '$name'"
    length(parts) == 5 && (label *= ", update rule $(parts[4])")
    return label
end

"""
    model_unit_findings(model::Model; file=nothing, toplevel=nothing, indep="t") -> Vector{UnitFinding}

Every unit ERROR in `model`'s own sites (not its subsystems), each with a
`subpath` relative to the model's JSON pointer: the checker
`_component_unit_findings!` documents. A scoped reference (`sub.v`,
`Leaf.p`) has the units its target declares: relative to `model`'s own
subsystems always, and to the top-level models and reaction systems of `file`
when one is given (see [`scoped_reference_units`](@ref)); a caller checking
many components passes the document-wide map
`toplevel = _toplevel_scoped_units(file)` once instead. `indep` is the
document's independent variable.
"""
function model_unit_findings(
        model::Model; file = nothing, toplevel = nothing, indep::AbstractString = "t"
    )::Vector{UnitFinding}
    env = _model_unit_env(
        model, toplevel === nothing ? _toplevel_scoped_units(file) : toplevel; indep
    )
    out = UnitFinding[]
    _component_unit_findings!(out, UnitFinding[], model, "", env)
    return out
end

"""
Validate dimensions for all equations and variable definitions in a model.

Returns true when nothing in the model or its subsystems is PROVABLY
dimensionally inconsistent.
"""
function validate_model_dimensions(model::Model)::Bool
    all_valid = true
    _foreach_component(model, "") do m, _, _
        findings = model_unit_findings(m)
        for f in findings
            @warn "Unit finding at $(f.subpath) [$(f.code)]: $(f.message)"
        end
        isempty(findings) || (all_valid = false)
    end
    return all_valid
end

"""
Validate dimensions for all reactions in a reaction system.

Enforces the mass-action dimensional constraint from spec §7.4 by delegating
to [`validate_reaction_rate_units`](@ref) in validation/unit_checks.jl — the single shared
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
    UNIT_FINDING_DIMENSIONLESS_LITERAL::String

The `UnitWarning.code` of a check site that the current neutral-literal rule
passes or skips but that fails once a bare numeric literal is read as
dimensionless at scale 1 (esm-spec §4.8.6). Its value is
`"units_dimensionless_literal_mismatch"`. A WARNING at this stage:
[`validate`](@ref) reports it on `unit_warnings` and it never changes
`is_valid`.
"""
const UNIT_FINDING_DIMENSIONLESS_LITERAL = ERROR_CODES.UNITS_DIMENSIONLESS_LITERAL_MISMATCH

# The value of a bare numeric literal, a `const` without `units`, or a unary
# `+`/`-` of one (nested to any depth); `nothing` for anything else.
# `fr` is the template frame `e` is read in, as for `_literal_value`.
function _bare_literal_value(e, fr = nothing)
    _real(v) = (v isa Real && !(v isa Bool)) ? v : nothing
    e isa ASTExpr && ((e, fr) = _tpl_leaf(e, fr))
    (e isa IntExpr || e isa NumExpr) && return _real(e.value)
    e isa OpExpr || return nothing
    e.op == "const" && e.units === nothing && return _real(e.value)
    if e.op in ("+", "-") && length(e.args) == 1
        inner = _bare_literal_value(e.args[1], fr)
        inner === nothing && return nothing
        return e.op == "-" ? -inner : inner
    end
    return nothing
end

# The distinct nonzero bare literals in `exprs`, in walk order, as text — what
# the dimensionless-literal warning names. With the template table `tt`, a
# reference is read as its expansion is: its instance body through its frame,
# each parameter where the body reads it (`_tpl_step`); each (node, frame)
# is visited once, which cannot change a list of distinct literals.
function _nonzero_literals(exprs, tt = nothing)::Vector{String}
    out = String[]
    seen = Set{Tuple{UInt, UInt}}()
    function walk(node, fr)
        _tpl_step(walk, tt, node, fr) && return
        if node isa OpExpr
            k = (objectid(node), fr === nothing ? UInt(0) : objectid(fr))
            k in seen && return
            push!(seen, k)
        end
        v = _bare_literal_value(node, fr)
        if v !== nothing
            if !iszero(v)
                text = string(v)
                text in out || push!(out, text)
            end
            return
        end
        node isa OpExpr || return
        foreach(a -> walk(a, fr), node.args)
        node.expr_body !== nothing && walk(node.expr_body, fr)
        node.filter !== nothing && walk(node.filter, fr)
        node.values !== nothing && foreach(v -> walk(v, fr), node.values)
        return
    end
    foreach(e -> walk(e, nothing), exprs)
    return out
end

# The esm-spec §4.8.6 warnings of a `validate` pass, as `(pointer, message)`
# pairs: the warning half of the units checker (`_unit_check!`, validation/unit_checks.jl).
_dimensionless_literal_findings(units)::Vector{Tuple{String, String}} =
    _unit_check!(units).warnings

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

"""
    reject_const_units_pre_v12(raw_data)

Reject declared `units` on any expression node in a document declaring `esm` <
1.2.0 (esm-spec §4.8.5 item 6), naming the first offending node. Runs on the raw
JSON before schema validation, like [`reject_solver_pre_v11`](@ref).
The rule is the `const_units` row of [`_VERSION_GATES`](@ref).
"""
reject_const_units_pre_v12(raw_data) =
    _check_version_gate(_VERSION_GATES.const_units, raw_data)

_find_units_bearing_node(node, at::String) =
    _find_json_path(n -> _raw_haskey(n, "op") && _raw_haskey(n, "units"), node, at)

"""
    unresolvable_const_units(expr::ASTExpr) -> Vector{String}

Every declared `const` unit string in `expr` that does not resolve against the
registry (esm-spec §4.8.5 item 2), in walk order. With the template table `tt`
a reference counts as its expansion does: its instance body's strings, read
through its frame and listed once per instance (reused at every use), with
each parameter's binding counted where the body reads it.
"""
function unresolvable_const_units(expr, tt = nothing)
    out = String[]
    _walk_const_units!(out, expr, tt, nothing)
    return out
end

function _walk_const_units!(out, expr, tt = nothing, fr = nothing)
    if expr isa VarExpr && fr !== nothing && _tpl_is_sentinel(expr.name)
        b, bf = _tpl_arg(fr, expr.name)
        return _walk_const_units!(out, b, tt, bf)
    end
    expr isa OpExpr || return out
    if tt !== nothing && _tpl_is_call(expr)
        sub = _tpl_frame_or_nothing(tt, expr, fr)
        if sub !== nothing
            append!(
                out, _tpl_memo(tt, sub, :unresolvable_const_units, () -> _walk_const_units!(String[], sub.body, tt, sub))
            )
            foreach(s -> _walk_const_units!(out, s, tt, fr), _tpl_out_bindings(expr))
            return out
        end
    end
    if expr.op == "const" && expr.units !== nothing && parse_units(expr.units) === nothing
        push!(out, expr.units)
    end
    foreach_child(child -> _walk_const_units!(out, child, tt, fr), expr)
    return out
end
