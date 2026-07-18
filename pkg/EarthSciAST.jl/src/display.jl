"""
Pretty-printing formatters for ESM format expressions, equations, models, and files.

Implements display methods for various ESM format types:
- Base.show(io::IO, ::MIME"text/plain", expr::ASTExpr): Unicode display with chemical subscripts
- Base.show(io::IO, ::MIME"text/latex", expr::ASTExpr): LaTeX mathematical notation
- Base.show(io::IO, ::MIME"text/ascii", expr::ASTExpr): Plain ASCII mathematical notation
- Base.show(io::IO, ::MIME"text/plain", model::Model): Model summary display
- Base.show(io::IO, ::MIME"text/plain", esm_file::EsmFile): Structured ESM file summary per spec Section 6.3
- Base.show(io::IO, ::MIME"text/plain", reaction_system::ReactionSystem): Chemical reaction notation
- 2-arg Base.show for Model/EsmFile/ReactionSystem prints a compact one-liner
  suitable for reprs and collection display.

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

# ── Greek-letter conversion (mirrors pretty-print.ts convertGreekLetters) ──
# Named Greek spellings (lowercase + selected capitalized). Used to decide
# whether a bare variable is a Greek letter that must pass through the LaTeX
# `\mathrm{}` wrap untouched (the `convert_greek_letters` step maps it later).
const GREEK_NAMES = Set([
    "alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota",
    "kappa","lambda","mu","nu","xi","omicron","pi","rho","sigma","tau",
    "upsilon","phi","chi","psi","omega",
    "Gamma","Delta","Theta","Lambda","Xi","Pi","Sigma","Upsilon","Phi","Psi","Omega",
])

# name / unicode-symbol → LaTeX command.
const GREEK_TO_LATEX = Dict{String,String}(
    "alpha"=>"\\alpha","beta"=>"\\beta","gamma"=>"\\gamma","delta"=>"\\delta",
    "epsilon"=>"\\epsilon","zeta"=>"\\zeta","eta"=>"\\eta","theta"=>"\\theta",
    "iota"=>"\\iota","kappa"=>"\\kappa","lambda"=>"\\lambda","mu"=>"\\mu",
    "nu"=>"\\nu","xi"=>"\\xi","omicron"=>"\\omicron","pi"=>"\\pi","rho"=>"\\rho",
    "sigma"=>"\\sigma","tau"=>"\\tau","upsilon"=>"\\upsilon","phi"=>"\\phi",
    "chi"=>"\\chi","psi"=>"\\psi","omega"=>"\\omega",
    "Gamma"=>"\\Gamma","Delta"=>"\\Delta","Theta"=>"\\Theta","Lambda"=>"\\Lambda",
    "Xi"=>"\\Xi","Pi"=>"\\Pi","Sigma"=>"\\Sigma","Upsilon"=>"\\Upsilon",
    "Phi"=>"\\Phi","Psi"=>"\\Psi","Omega"=>"\\Omega",
    "α"=>"\\alpha","β"=>"\\beta","γ"=>"\\gamma","δ"=>"\\delta","ε"=>"\\epsilon",
    "ζ"=>"\\zeta","η"=>"\\eta","θ"=>"\\theta","ι"=>"\\iota","κ"=>"\\kappa",
    "λ"=>"\\lambda","μ"=>"\\mu","ν"=>"\\nu","ξ"=>"\\xi","ο"=>"\\omicron",
    "π"=>"\\pi","ρ"=>"\\rho","σ"=>"\\sigma","τ"=>"\\tau","υ"=>"\\upsilon",
    "φ"=>"\\phi","χ"=>"\\chi","ψ"=>"\\psi","ω"=>"\\omega",
)

# named Greek → unicode symbol.
const GREEK_NAME_TO_UNICODE = Dict{String,String}(
    "phi"=>"φ","theta"=>"θ","gamma"=>"γ","alpha"=>"α","beta"=>"β","delta"=>"δ",
    "epsilon"=>"ε","zeta"=>"ζ","eta"=>"η","iota"=>"ι","kappa"=>"κ","lambda"=>"λ",
    "mu"=>"μ","nu"=>"ν","xi"=>"ξ","omicron"=>"ο","pi"=>"π","rho"=>"ρ",
    "sigma"=>"σ","tau"=>"τ","upsilon"=>"υ","chi"=>"χ","psi"=>"ψ","omega"=>"ω",
)

# unicode symbol → ascii name.
const GREEK_UNICODE_TO_ASCII = Dict{String,String}(
    "φ"=>"phi","θ"=>"theta","γ"=>"gamma","α"=>"alpha","β"=>"beta","δ"=>"delta",
    "ε"=>"epsilon","ζ"=>"zeta","η"=>"eta","ι"=>"iota","κ"=>"kappa","λ"=>"lambda",
    "μ"=>"mu","ν"=>"nu","ξ"=>"xi","ο"=>"omicron","π"=>"pi","ρ"=>"rho","σ"=>"sigma",
    "τ"=>"tau","υ"=>"upsilon","χ"=>"chi","ψ"=>"psi","ω"=>"omega",
)

const _GREEK_NAME_ALT = "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega"
# Character class spans the two Greek ranges Α-Ω (U+0391..03A9) and α-ω
# (U+03B1..03C9) using literal characters (PCRE's ALT_BSUX rejects \x{…}).
const _GREEK_CLASS = "[Α-Ωα-ω]"
# The negative lookbehind `(?<![\\A-Za-z])` leaves a name that is already part
# of a control word (`\theta`) or a longer identifier untouched, so a
# pre-formatted `\theta` is not turned into `\\theta`.
const GREEK_LATEX_RE = Regex("$(_GREEK_CLASS)|(?<![\\\\A-Za-z])(?:$(_GREEK_NAME_ALT))(?![A-Z}])")
# The negative lookbehind `(?<![\\A-Za-z])` leaves a name already part of a
# control word (`\theta`) or a longer identifier untouched, so a pre-formatted
# `\theta` is not turned into `\θ` on the unicode path.
const GREEK_NAME_RE = Regex("(?<![\\\\A-Za-z])(?:$(_GREEK_NAME_ALT))(?![A-Z])")
const GREEK_UNICODE_RE = Regex(_GREEK_CLASS)

"""
    convert_greek_letters(text, format::Symbol) -> String

Convert Greek letters between spellings for the given output format, mirroring
pretty-print.ts `convertGreekLetters`: LaTeX maps names/symbols → `\\phi`;
unicode maps names → symbols; ascii maps symbols → names. Negative lookaheads
avoid converting a chemical prefix (uppercase-follows) or a `\\mathrm{}`-wrapped
segment (`}`-follows) in the LaTeX form.
"""
function convert_greek_letters(text::AbstractString, format::Symbol)
    if format == :latex
        return replace(text, GREEK_LATEX_RE => m -> get(GREEK_TO_LATEX, String(m), String(m)))
    elseif format == :unicode
        return replace(text, GREEK_NAME_RE => m -> get(GREEK_NAME_TO_UNICODE, String(m), String(m)))
    elseif format == :ascii
        return replace(text, GREEK_UNICODE_RE => m -> get(GREEK_UNICODE_TO_ASCII, String(m), String(m)))
    end
    return String(text)
end

"""
    _scan_element_tokens(on_element, on_other, variable::String) -> Bool

Greedy element-token scanner shared by [`has_element_pattern`](@ref) and
[`format_chemical_subscripts`](@ref): at each position, try a 2-character
element symbol before a 1-character one (per spec Section 6.1), then consume
the digit run following a match. Calls `on_element(element, digits)` for each
recognized element (with its possibly-empty trailing digit string) and
`on_other(c)` for every other character. Returns `true` when at least one
element was found. Works on a `Char` vector: byte-indexing a String with
`1:length(...)` bounds throws `StringIndexError` for non-ASCII names like "α2".
"""
function _scan_element_tokens(on_element::Function, on_other::Function, variable::String)
    chars = collect(variable)
    n = length(chars)
    i = 1
    found = false

    while i <= n
        # Try 2-character element first (greedy matching), then 1-character.
        len = if i + 1 <= n && String(chars[i:i+1]) in ELEMENTS
            2
        elseif string(chars[i]) in ELEMENTS
            1
        else
            0
        end

        if len == 0
            # Not an element: emit the character and move to the next one.
            on_other(chars[i])
            i += 1
            continue
        end

        found = true
        element = String(chars[i:i+len-1])
        i += len
        digit_start = i
        while i <= n && isdigit(chars[i])
            i += 1
        end
        on_element(element, String(chars[digit_start:i-1]))
    end

    return found
end

"""
    has_element_pattern(variable) -> Bool

True when `variable` is a PURE chemical formula: it contains at least one
recognized element symbol and no non-element ASCII letter (mirrors
pretty-print.ts `hasElementPattern`). Underscores are stripped first; Greek and
other non-ASCII letters are treated as separators (NOT disqualifiers), so
`"αH2O"` is a formula but `"xyz"` is not. Uses the greedy 2-char-before-1-char
tokenizer (see [`_scan_element_tokens`](@ref)).
"""
function has_element_pattern(variable::AbstractString)
    clean = replace(String(variable), "_" => "")
    hasel = Ref(false)
    disq = Ref(false)
    _scan_element_tokens(
        (element, digits) -> (hasel[] = true),
        c -> (('A' <= c <= 'Z' || 'a' <= c <= 'z') && (disq[] = true)),
        clean)
    return hasel[] && !disq[]
end

# ── Chemical / variable subscript formatting (mirrors pretty-print.ts) ────────
# The LaTeX and Unicode variable renderers are a faithful port of pretty-print.ts
# `formatChemicalLatex` / `formatChemicalUnicode`, including single-digit
# subscripts left BARE (`O_3`, `x_1`) with only multi-digit runs braced
# (`C_6H_{12}O_6`, `T_{298}`), mixed non-element-prefix + chemical-suffix
# splitting (`jNO2` → `j_{\mathrm{NO_2}}`), and underscore-segmented names
# (`rate_OH_NO2` → `\mathrm{rate}_{\mathrm{OH}}_{\mathrm{NO_2}}`). A trailing
# ionic CHARGE (`Ca2+`, `SO4-2`) renders as a Unicode superscript per the
# rendering contract (`Ca²⁺`, `SO₄²⁻`).

"""Convert every digit run of a formula to its LaTeX subscript (`H2O`→`H_2O`,
`CO12`→`CO_{12}`): single digit bare, multi-digit braced. No `\\mathrm{}` wrap."""
latex_chemical_inner(formula::AbstractString) =
    replace(String(formula), r"(\d+)" => s -> length(s) == 1 ? "_$s" : "_{$s}")

"""Peel one leading `\\mathrm{` and one trailing `}` (each independently)."""
function strip_outer_mathrm(s::AbstractString)
    inner = startswith(s, "\\mathrm{") ? s[9:end] : s
    return endswith(inner, "}") ? inner[1:prevind(inner, lastindex(inner))] : String(inner)
end

"""
    get_chemical_suffix(variable) -> Union{Tuple{String,String},Nothing}

Split a variable into a non-element `prefix` and a chemical `suffix` (the largest
trailing element-bearing part), or `nothing`. Mirrors pretty-print.ts
`getChemicalSuffix`: for `k_NO_O3` → (`k`, `NO_O3`); for `jNO2` → (`j`, `NO2`).
"""
function get_chemical_suffix(variable::AbstractString)
    v = String(variable)
    if occursin("_", v)
        parts = split(v, "_")
        if length(parts) == 2
            pre, suf = String(parts[1]), String(parts[2])
            has_element_pattern(suf) && !has_element_pattern(pre) && return (pre, suf)
        end
        if length(parts) == 3
            pre = String(parts[1]); suf = join(parts[2:end], "_")
            has_element_pattern(suf) && !has_element_pattern(pre) && return (pre, suf)
        end
    end
    # Character-based split (byte slicing throws on multi-byte names like "α2").
    chars = collect(v)
    for i in 1:length(chars)-1
        pre = String(chars[1:i]); suf = String(chars[i+1:end])
        has_element_pattern(suf) && !has_element_pattern(pre) && return (pre, suf)
    end
    return nothing
end

"""Inner content (no `\\mathrm{}` wrapper) of a chemical suffix embedded in a
larger variable's subscript (mirrors pretty-print.ts `formatChemicalSuffixInner`)."""
function format_chemical_suffix_inner(variable::AbstractString)
    if get_chemical_suffix(variable) !== nothing
        return strip_outer_mathrm(format_chemical_latex(variable))
    end
    if variable in ELEMENTS && !occursin(r"\d", variable)
        return String(variable)
    end
    return latex_chemical_inner(variable)
end

"""
    is_preformatted_latex(variable) -> Bool

Whether a variable name is ALREADY LaTeX and should render verbatim rather than
be re-wrapped (which only mangles it), mirroring pretty-print.ts
`isPreformattedLatex`. Three shapes qualify: a roman-wrapped species
(`\\mathrm{...}`); a bare control word with no group (`\\theta`); or a name that
carries its own `{...}` grouping but no command (`k_{NO_O3}`). A different
`\\command{...}` atom such as `\\mathbf{v}` is NOT pre-formatted — it still takes
the generic `\\mathrm{...}` wrap.
"""
function is_preformatted_latex(variable::AbstractString)
    startswith(variable, "\\mathrm{") && return true
    occursin("\\", variable) && return !occursin("{", variable)
    return occursin(r"[{}]", variable)
end

"""LaTeX chemical/variable subscript formatting (mirrors pretty-print.ts `formatChemicalLatex`)."""
function format_chemical_latex(variable::AbstractString)
    v = String(variable)
    # A trailing ionic charge is a superscript, not a subscript: `Ca2+`→`Ca^{2+}`,
    # `SO4-2`→`\mathrm{SO_4}^{2-}` (mirrors pretty-print.ts).
    ch = split_charge(v)
    if ch !== nothing && has_element_pattern(ch[1])
        return "$(format_chemical_latex(ch[1]))^{$(ch[2])}"
    end
    # A name that is already LaTeX passes through untouched.
    is_preformatted_latex(v) && return v
    hasel = has_element_pattern(v)

    ci = get_chemical_suffix(v)
    if ci !== nothing
        pre, suf = ci
        if occursin("_", suf)
            segs = split(suf, "_")
            should_split = occursin(r"\d$", segs[1]) || length(pre) > 1
            if should_split
                result = (length(pre) == 1 && occursin(r"[A-Za-z]", pre)) ? pre : "\\mathrm{$pre}"
                for seg in segs
                    if has_element_pattern(seg)
                        result *= "_{\\mathrm{$(latex_chemical_inner(seg))}}"
                    else
                        result *= "_\\mathrm{$seg}"
                    end
                end
                return result
            end
        end
        inner = format_chemical_suffix_inner(suf)
        fpre = length(pre) > 1 ? "\\mathrm{$pre}" : pre
        return "$(fpre)_{\\mathrm{$inner}}"
    end

    if hasel
        # A bare element symbol without digits (e.g. "B", "C", "N") is a variable
        # name, not a chemical formula — italic, unwrapped.
        if v in ELEMENTS && !occursin(r"\d", v)
            return v
        end
        return "\\mathrm{$(latex_chemical_inner(v))}"
    end

    # Regular (non-chemical) variable.
    # Greek name → pass through unchanged (convert_greek_letters maps it later).
    if v in GREEK_NAMES
        return v
    end
    # Single letter (Latin/Greek) + digits → italic with subscript (T_{298}, x_1).
    m = match(r"^([A-Za-zΑ-Ωα-ω])(\d+)$", v)
    if m !== nothing
        letter, digits = m.captures[1], m.captures[2]
        return length(digits) == 1 ? "$(letter)_$(digits)" : "$(letter)_{$(digits)}"
    end
    # Single character → italic, no wrapping.
    if length(v) == 1
        return v
    end
    # Underscore-separated variable with mixed chemical / non-chemical segments.
    if occursin("_", v)
        parts = split(v, "_")
        if any(has_element_pattern, parts)
            base = parts[1]
            result = (length(base) == 1 && occursin(r"[A-Za-z]", base)) ? String(base) :
                     has_element_pattern(base) ? format_chemical_latex(base) : "\\mathrm{$base}"
            for i in 2:length(parts)
                part = parts[i]
                if has_element_pattern(part)
                    result *= "_{\\mathrm{$(latex_chemical_inner(part))}}"
                else
                    result *= "_\\mathrm{$part}"
                end
            end
            return result
        end
        return "\\mathrm{$(replace(v, "_" => "\\_"))}"
    end
    # A symbol with no lowercase letters (e.g. "RT", "-E") is a math variable,
    # not a descriptive name — leave it italic instead of wrapping in \mathrm{}.
    if !occursin(r"[a-z]", v)
        return v
    end
    # Multi-character non-chemical variable → upright.
    return "\\mathrm{$v}"
end

"""
    split_charge(variable) -> Union{Tuple{String,String},Nothing}

Detect a trailing ionic charge and return `(body, charge)`, or `nothing`
(mirrors pretty-print.ts `splitCharge`). `charge` is the magnitude-then-sign
string with the sign LAST regardless of source order: `Ca2+` → (`Ca`, `2+`),
`SO4-2` → (`SO4`, `2-`), `Na+` → (`Na`, `+`). Callers render it as a Unicode
superscript (`to_superscript`) or a LaTeX superscript (`^{…}`).
"""
function split_charge(variable::AbstractString)
    v = String(variable)
    m = match(r"^(.+?)(\d+)([+-])$", v)    # digits-then-sign, e.g. "Ca2+"
    m !== nothing && return (String(m.captures[1]), m.captures[2] * m.captures[3])
    m = match(r"^(.+?)([+-])(\d+)$", v)    # sign-then-digits, e.g. "SO4-2"
    m !== nothing && return (String(m.captures[1]), m.captures[3] * m.captures[2])
    m = match(r"^(.+?)([+-])$", v)         # bare sign, e.g. "Na+"
    m !== nothing && return (String(m.captures[1]), String(m.captures[2]))
    return nothing
end

"""Unicode chemical/variable subscript formatting (mirrors pretty-print.ts `formatChemicalUnicode`)."""
function format_chemical_unicode(variable::AbstractString)
    v = String(variable)
    # A name that already carries a LaTeX command (a backslash) is passed through
    # verbatim — `\mathrm{O_3}`, `\theta` — rather than chemical-/Greek-converted.
    # (A `{…}`-only name like `k_{NO_O3}` is NOT verbatim here: it still takes the
    # subscript pass, matching the Rust reference `k_{NO_O₃}`.)
    occursin("\\", v) && return v
    # Trailing ionic charge → superscript on the formatted body.
    ch = split_charge(v)
    if ch !== nothing && has_element_pattern(ch[1])
        return format_chemical_unicode(ch[1]) * to_superscript(ch[2])
    end

    if !has_element_pattern(v)
        ci = get_chemical_suffix(v)
        if ci !== nothing
            pre, suf = ci
            chem = format_chemical_unicode(suf)
            return occursin("_", v) ? "$(pre)_$(chem)" : "$(pre)$(chem)"
        end
        if occursin("_", v)
            parts = split(v, "_")
            if any(has_element_pattern, parts)
                return join((has_element_pattern(p) ? format_chemical_unicode(String(p)) : String(p)
                             for p in parts), "_")
            end
        end
        return v
    end

    # Pure formula: element digits AND stray digits (e.g. after `)`) become subscripts.
    buf = IOBuffer()
    _scan_element_tokens(
        (element, digits) -> begin
            print(buf, element)
            for d in digits
                print(buf, SUBSCRIPT_MAP[d])
            end
        end,
        c -> print(buf, (isdigit(c) && haskey(SUBSCRIPT_MAP, c)) ? SUBSCRIPT_MAP[c] : c),
        v)
    return String(take!(buf))
end

"""
    format_chemical_subscripts(variable, format::Symbol) -> String

Apply element-aware chemical subscript formatting to a variable name, dispatching
to the per-format implementation (mirrors pretty-print.ts). ASCII is a passthrough
(no subscripts).
"""
function format_chemical_subscripts(variable::AbstractString, format::Symbol)
    format == :latex && return format_chemical_latex(variable)
    format == :ascii && return String(variable)
    return format_chemical_unicode(variable)
end

"""
    format_number(num::Real, format::Symbol) -> String

Format a number in scientific notation with appropriate formatting.
"""
function format_number(num::Real, format::Symbol)
    # Non-finite values are RENDERED, never stringified (RENDERING_CONTRACT.md).
    if !isfinite(num)
        if isnan(num)
            return format == :latex ? "\\text{NaN}" : "NaN"
        elseif num > 0
            return format == :unicode ? "∞" : format == :latex ? "\\infty" : "inf"
        else
            return format == :unicode ? "−∞" : format == :latex ? "-\\infty" : "-inf"
        end
    end

    num == 0 && return "0"

    # Unicode uses U+2212 MINUS SIGN; latex/ascii use ASCII '-'.
    _uni_minus(s) = (format == :unicode && startswith(s, "-")) ? "−" * s[2:end] : s

    absnum = abs(num)
    # Scientific notation for very small / very large magnitudes (spec §6.1).
    if absnum < 0.01 || absnum >= 10000
        exp = floor(Int, log10(absnum))
        mant = num / exp10(exp)
        # Normalize the mantissa into [1, 10) (guards log10 rounding at exact powers).
        while abs(mant) >= 10
            exp += 1; mant = num / exp10(exp)
        end
        while abs(mant) < 1
            exp -= 1; mant = num / exp10(exp)
        end
        # Strip floating-point noise so a clean mantissa round-trips (`9.999`, not
        # `9.998999…`) while preserving genuine precision.
        mant = parse(Float64, string(round(mant, sigdigits=15)))
        ms = string(mant)
        if format == :unicode
            return "$(_uni_minus(ms))×10$(to_superscript(string(exp)))"
        elseif format == :latex
            return "$(ms) \\times 10^{$(exp)}"
        else
            # ASCII: no '+' on a positive exponent.
            return "$(ms)e$(exp)"
        end
    end

    if isinteger(num)
        return _uni_minus(string(Int64(num)))
    end
    return _uni_minus(string(num))
end

# Display-notation operator precedence (mirrors pretty-print.ts), DERIVED
# from the op registry's `display_prec` column (src/op_registry.jl; pinned
# literal-for-literal by test/op_registry_test.jl). Hoisted to a module const:
# `get_operator_precedence` runs for every operand rendered.
const _DISPLAY_OP_PRECEDENCE = let d = Dict{String,Int}()
    for s in _OP_TABLE
        s.display_prec === nothing || (d[s.name] = s.display_prec)
    end
    # "=" is the wire alias of "==" (rendered identically by
    # `_INFIX_SEPARATORS`) and carries the same precedence in the reference
    # registry (pkg/earthsci-ast-ts/src/op-registry.ts) — without it, an `=`
    # node bound atom-tight and e.g. `not(x = 0)` rendered unparenthesized
    # (`¬x = 0`), diverging from the pinned `¬(x = 0)` of
    # tests/display/all_operators.json. It is an alias HERE rather than an
    # `_OP_TABLE` row because registry membership is behavior elsewhere
    # (`_op_in_T` classifies unregistered ops as open-namespace rewrite
    # targets).
    d["="] = d["=="]
    d
end

# Function calls / atoms bind tightest — anything without an explicit infix
# precedence above (mirrors codegen.jl's `_CODEGEN_FUNCTION_PRECEDENCE = 8`).
const _DISPLAY_FUNCTION_PRECEDENCE = 8

"""
    get_operator_precedence(op::String) -> Int

Get operator precedence for proper parenthesization.
"""
get_operator_precedence(op::String) =
    get(_DISPLAY_OP_PRECEDENCE, op, _DISPLAY_FUNCTION_PRECEDENCE)

"""
    is_function_call_op(op::String) -> Bool

True when the operator renders as a function call (no infix precedence). Mirrors
pretty-print.ts `isFunctionCallOp`: the infix operators carry an explicit
precedence (1–7); everything else (elementary/trig functions, `min`/`max`, …)
binds tightest and is a function-call op.
"""
is_function_call_op(op::String) =
    get_operator_precedence(op) == _DISPLAY_FUNCTION_PRECEDENCE

"""
    needs_parentheses(parent_op::String, child::ASTExpr, is_right_operand::Bool=false) -> Bool

Check if parentheses are needed around a subexpression, mirroring
pretty-print.ts `needsParentheses`. A function-call argument is parenthesized
only when it is a logical-`or` (loosest precedence).
"""
function needs_parentheses(parent_op::String, child::ASTExpr, is_right_operand::Bool=false)
    if isa(child, NumExpr) || isa(child, IntExpr) || isa(child, VarExpr)
        return false
    end

    if !isa(child, OpExpr)
        return false
    end

    parent_prec = get_operator_precedence(parent_op)
    child_prec = get_operator_precedence(child.op)

    # Function arguments already sit inside the call's own parentheses — only
    # parenthesize the loosest-binding (logical-or) child expressions.
    if is_function_call_op(parent_op)
        return child_prec <= 1
    end

    if child_prec < parent_prec
        return true
    end
    if child_prec > parent_prec
        return false
    end

    # Same precedence. `^` is right-associative, so a NESTED `^` operand is
    # parenthesized at BOTH positions to keep the reading unambiguous:
    # `(a^b)^c` (left) and `a^(b^c)` (right) — RENDERING_CONTRACT.md
    # "Associativity and parenthesization". (In LaTeX the exponent sits in
    # `{}`, so the right `^` operand is rendered without `needs_parentheses`
    # and needs no extra parens: `a^{b^{c}}`.) The left-associative `-`/`/`
    # parenthesize only their RIGHT operand (`a - (b - c)`, `a / (b / c)`).
    if parent_op == "^"
        return true
    end
    if is_right_operand && (parent_op == "-" || parent_op == "/")
        return true
    end

    return false
end

"""
    Base.show(io::IO, ::MIME"text/plain", expr::ASTExpr)

Unicode display: chemical subscripts via element-aware tokenizer, ∂x/∂t derivatives,
· for multiplication, − for unary minus, scientific notation with Unicode superscripts.
"""
function Base.show(io::IO, ::MIME"text/plain", expr::ASTExpr)
    print(io, format_expression_unicode(expr))
end

"""
    Base.show(io::IO, ::MIME"text/latex", expr::ASTExpr)

LaTeX display: \\frac{}{}, \\partial, \\mathrm{} for species.
"""
function Base.show(io::IO, ::MIME"text/latex", expr::ASTExpr)
    print(io, format_expression_latex(expr))
end

"""
    Base.show(io::IO, ::MIME"text/ascii", expr::ASTExpr)

ASCII display: plain ASCII mathematical notation with standard operators (*, /, ^).
"""
function Base.show(io::IO, ::MIME"text/ascii", expr::ASTExpr)
    print(io, format_expression_ascii(expr))
end

"""
    format_expression(expr::ASTExpr, format::Symbol) -> String

Format an expression in the given notation (`:unicode`, `:latex`, or `:ascii`).
"""
function format_expression(expr::ASTExpr, format::Symbol)
    format in (:unicode, :latex, :ascii) ||
        throw(ArgumentError("Unsupported format: $format"))

    if isa(expr, NumExpr)
        return format_number(expr.value, format)
    end

    if isa(expr, IntExpr)
        return format_number(expr.value, format)
    end

    if isa(expr, VarExpr)
        return convert_greek_letters(format_chemical_subscripts(expr.name, format), format)
    end

    if isa(expr, OpExpr)
        return format_operator_expression(expr, format)
    end

    throw(ArgumentError("Unsupported expression type: $(typeof(expr))"))
end

"""
    format_expression_unicode(expr::ASTExpr) -> String

Format an expression as Unicode mathematical notation.
"""
format_expression_unicode(expr::ASTExpr) = format_expression(expr, :unicode)

"""
    format_expression_latex(expr::ASTExpr) -> String

Format an expression as LaTeX mathematical notation.
"""
format_expression_latex(expr::ASTExpr) = format_expression(expr, :latex)

"""
    format_expression_ascii(expr::ASTExpr) -> String

Format an expression as plain ASCII mathematical notation.
"""
format_expression_ascii(expr::ASTExpr) = format_expression(expr, :ascii)

# ── Structural / array-query op rendering (mirrors pretty-print.ts) ──────────
# The closed evaluable-core ops whose defining data lives in fields OTHER than
# `args` (esm-spec §4.2) plus `integral`. `format_structural_op` returns a
# fully-formatted string, or `nothing` for ops handled by the scalar-op dispatch
# (arithmetic, elementary functions, comparisons, D, Pre, …) or by the generic
# fallback (open-tier sugar grad/div/laplacian, unknown user ops, skolem/rank).

"""Escape LaTeX-special underscores in a bare operator / identifier name."""
latex_name(name::AbstractString) = replace(String(name), "_" => "\\_")

"""Parenthesize a sub-expression only when it is an operator node."""
function wrap_if_op(e, format::Symbol)
    s = format_expression(e, format)
    return e isa OpExpr ? "($s)" : s
end

# Raw name for an `enum` type/member arg (the leaf identifier, not its rendered
# form — the whole `Type.Member` label is wrapped once in LaTeX).
_enum_name(e) = e isa VarExpr ? e.name :
                e isa IntExpr ? string(e.value) :
                e isa NumExpr ? format_number(e.value, :ascii) :
                format_expression(e, :ascii)

"""Format a `const` node's literal value (scalar number or nested array)."""
function format_const_value(value, format::Symbol)
    if value isa AbstractVector
        return "[" * join([format_const_value(v, format) for v in value], ", ") * "]"
    elseif value isa Bool
        return string(value)
    elseif value isa Integer
        s = string(value)
        return (format == :unicode && startswith(s, "-")) ? "−" * s[2:end] : s
    elseif value isa AbstractFloat
        return format_number(value, format)
    else
        return string(value)
    end
end

# A structural integer bound (region / shape / range entry): plain integer,
# symbolic dimension string, or a metaparameter Expression node.
function format_bound(value, format::Symbol)
    if value isa Integer
        return string(value)
    elseif value isa AbstractString
        return String(value)
    elseif value isa ASTExpr
        return format_expression(value, format)
    else
        return string(value)
    end
end

"""Big-operator symbol for an `aggregate` reduction (semiring supersedes reduce)."""
function aggregate_symbol(semiring, reduce, format::Symbol)
    fam = if semiring !== nothing
        (semiring == "max_product" || semiring == "max_sum") ? :max :
        semiring == "min_sum" ? :min :
        semiring == "bool_and_or" ? :bool : :plus
    else
        reduce == "*" ? :times :
        reduce == "max" ? :max :
        reduce == "min" ? :min : :plus
    end
    tbl = Dict(
        :plus => ("Σ", "\\sum", "sum"),
        :times => ("Π", "\\prod", "prod"),
        :max => ("max", "\\max", "max"),
        :min => ("min", "\\min", "min"),
        :bool => ("⋁", "\\bigvee", "any"),
    )
    u, l, a = tbl[fam]
    return format == :unicode ? u : format == :latex ? l : a
end

"""Render the ` where {…}` range clause shared by aggregate and argmin/argmax."""
function format_ranges_clause(ranges, format::Symbol)
    in_sym = format == :latex ? " \\in " : format == :unicode ? "∈" : " in "
    parts = String[]
    for k in sort(collect(keys(ranges)))
        rng = ranges[k]
        rng_str = if rng isa AbstractVector
            join([format_bound(x, format) for x in rng], ":")
        elseif rng isa IndexSetRef
            isempty(rng.of) ? rng.from : "$(rng.from)($(join(rng.of, ", ")))"
        else
            string(rng)
        end
        push!(parts, "$k$in_sym$rng_str")
    end
    return format == :latex ?
        " \\text{ where } \\{$(join(parts, ", "))\\}" :
        " where {$(join(parts, ", "))}"
end

"""Render an `aggregate` node per the rendering contract."""
function format_aggregate(node::OpExpr, format::Symbol)
    r(e) = format_expression(e, format)
    out_idx = node.output_idx === nothing ? Any[] : node.output_idx
    out_str = join([string(o) for o in out_idx], ", ")
    expr_str = node.expr_body === nothing ? "" : r(node.expr_body)
    semiring = node.semiring
    reduce = node.reduce === nothing ? "+" : node.reduce
    sym = aggregate_symbol(semiring, reduce, format)
    idx_part = format == :latex ? "_{$out_str}" : "[$out_str]"
    out = "$sym$idx_part ($expr_str)"
    if node.ranges !== nothing && !isempty(node.ranges)
        out *= format_ranges_clause(node.ranges, format)
    end
    if node.join !== nothing && !isempty(node.join)
        clauses = join(
            [join(["$(p[1])=$(p[2])" for p in clause], ", ") for clause in node.join],
            "; ")
        out *= " join($clauses)"
    end
    if node.filter !== nothing
        out *= " if $(r(node.filter))"
    end
    if node.distinct === true
        out *= " distinct"
    end
    if node.key !== nothing
        out *= " key=$(r(node.key))"
    end
    if semiring !== nothing && semiring != "sum_product"
        out *= " [semiring=$semiring]"
    end
    return out
end

"""Render an `argmin` / `argmax` arg-witness node per the rendering contract."""
function format_arg_witness(node::OpExpr, format::Symbol)
    r(e) = format_expression(e, format)
    arg = node.arg === nothing ? "" : node.arg
    expr_str = node.expr_body === nothing ? "" : r(node.expr_body)
    idx_part = format == :latex ? "_{$arg}" : "[$arg]"
    name = format == :latex ? "\\mathrm{$(node.op)}" : node.op
    out = "$name$idx_part ($expr_str)"
    if node.ranges !== nothing && !isempty(node.ranges)
        out *= format_ranges_clause(node.ranges, format)
    end
    return out
end

"""
    format_structural_op(node::OpExpr, format::Symbol) -> Union{String,Nothing}

Render the closed-core structural / array-query ops, or return `nothing` for
ops handled elsewhere. See tests/display/RENDERING_CONTRACT.md.
"""
function format_structural_op(node::OpExpr, format::Symbol)
    op = node.op
    args = node.args
    r(e) = format_expression(e, format)

    if op == "const"
        return format_const_value(node.value, format)
    elseif op == "true"
        return "true"
    elseif op == "fn"
        name = node.name === nothing ? "" : node.name
        inner = join([r(a) for a in args], ", ")
        return format == :latex ? "\\mathrm{$(latex_name(name))}($inner)" : "$name($inner)"
    elseif op == "enum"
        length(args) >= 2 || return nothing
        label = "$(_enum_name(args[1])).$(_enum_name(args[2]))"
        return format == :latex ? "\\mathrm{$(latex_name(label))}" : label
    elseif op == "index"
        isempty(args) && return nothing
        arr = args[1]
        idx = args[2:end]
        return "$(wrap_if_op(arr, format))[$(join([r(i) for i in idx], ", "))]"
    elseif op == "broadcast"
        node.fn === nothing && return nothing
        return format_operator_expression(OpExpr(node.fn, args), format)
    elseif op == "integral"
        isempty(args) && return nothing
        f = r(args[1])
        v = node.int_var === nothing ? "x" : node.int_var
        lo = node.lower === nothing ? "" : r(node.lower)
        hi = node.upper === nothing ? "" : r(node.upper)
        if format == :latex
            return "\\int_{$lo}^{$hi} $f \\, d$v"
        elseif format == :unicode
            return "∫[$lo, $hi] $f d$v"
        else
            return "integral($f, $v, $lo, $hi)"
        end
    elseif op == "table_lookup"
        table = node.table === nothing ? "" : node.table
        axes = node.table_axes === nothing ? Dict{String,ASTExpr}() : node.table_axes
        eq = format == :latex ? " = " : "="
        bindings = join(["$k$eq$(r(axes[k]))" for k in sort(collect(keys(axes)))], ", ")
        outv = node.output
        out_str = outv === nothing ? "" : ":$(outv)"
        name = format == :latex ? "\\mathrm{$(latex_name(table))}" : table
        return "$name[$bindings]$out_str"
    elseif op == "apply_expression_template"
        name = node.name === nothing ? "" : node.name
        binds = node.bindings === nothing ? Dict{String,ASTExpr}() : node.bindings
        eq = format == :latex ? " = " : "="
        inner = join(["$k$eq$(r(binds[k]))" for k in sort(collect(keys(binds)))], ", ")
        if format == :latex
            return "\\mathrm{$(latex_name(name))}\\langle $inner \\rangle"
        elseif format == :unicode
            return "$name⟨$inner⟩"
        else
            return "$name<$inner>"
        end
    elseif op == "makearray"
        regions = node.regions === nothing ? Vector{Vector{Vector{Int}}}() : node.regions
        values = node.values === nothing ? ASTExpr[] : node.values
        parts = String[]
        for (i, region) in enumerate(regions)
            reg_str = join(
                ["$(format_bound(dim[1], format)):$(format_bound(dim[2], format))"
                 for dim in region], ", ")
            val = i <= length(values) ? r(values[i]) : "?"
            push!(parts, "[$reg_str] = $val")
        end
        name = format == :latex ? "\\mathrm{makearray}" : "makearray"
        return "$name($(join(parts, ", ")))"
    elseif op == "reshape"
        isempty(args) && return nothing
        shape = node.shape === nothing ? Any[] : node.shape
        shp = join([format_bound(s, format) for s in shape], ", ")
        name = format == :latex ? "\\mathrm{reshape}" : "reshape"
        return "$name($(r(args[1])), [$shp])"
    elseif op == "transpose"
        isempty(args) && return nothing
        perm = node.perm
        if perm !== nothing && !isempty(perm)
            name = format == :latex ? "\\mathrm{transpose}" : "transpose"
            return "$name($(r(args[1])), [$(join(perm, ", "))])"
        end
        a = wrap_if_op(args[1], format)
        if format == :latex
            return "$a^{T}"
        elseif format == :unicode
            return "$(a)ᵀ"
        else
            return "transpose($(r(args[1])))"
        end
    elseif op == "concat"
        inner = join([r(a) for a in args], ", ")
        axis = node.axis === nothing ? 0 : node.axis
        name = format == :latex ? "\\mathrm{concat}" : "concat"
        return "$name($inner, axis=$axis)"
    elseif op == "intersect_polygon" || op == "polygon_intersection_area"
        inner = join([r(a) for a in args], ", ")
        manifold = node.manifold === nothing ? "" : node.manifold
        name = format == :latex ? "\\mathrm{$(latex_name(op))}" : op
        return "$name($inner, manifold=$manifold)"
    elseif op == "aggregate"
        return format_aggregate(node, format)
    elseif op == "argmin" || op == "argmax"
        return format_arg_witness(node, format)
    else
        return nothing
    end
end

# ── Scalar operator rendering ─────────────────────────────────────────────
# `format_operator_expression` dispatches to `_format_infix_op` (binary infix),
# `_format_unary_op`, and `_format_nary_op` (ifelse + n-ary chains); each
# helper returns `nothing` for ops it does not handle, falling through to the
# generic function-call rendering.

# Infix separator per op → (ascii, unicode, latex), DERIVED from the op
# registry's `infix_sep` column (src/op_registry.jl; pinned literal-for-
# literal by test/op_registry_test.jl). Ops with special per-format structure
# (`/` → \frac, `^` → superscripts) and ops whose separator is uniform across
# formats ("+", "<", ">") have no `infix_sep` and are handled directly in
# `_format_infix_op`. Field names match the format Symbols so lookups are
# `getproperty(row, format)`. "=" is the wire alias of "==" (see the
# `_DISPLAY_OP_PRECEDENCE` note): same separators, no registry row.
const _INFIX_SEPARATORS =
    let d = Dict{String,NamedTuple{(:ascii, :unicode, :latex),NTuple{3,String}}}()
        for s in _OP_TABLE
            s.infix_sep === nothing && continue
            d[s.name] = NamedTuple{(:ascii, :unicode, :latex)}(s.infix_sep)
        end
        d["="] = d["=="]
        d
    end

_infix_separator(op::String, format::Symbol) =
    getproperty(_INFIX_SEPARATORS[op], format)

# LaTeX product separator: a product whose factors are already-typeset LaTeX
# STRING operands (e.g. `\mathrm{O_3}`) is written by implicit juxtaposition (a
# space), while a product of plain symbols uses ` \cdot ` to stay unambiguous
# (`a \cdot b`) — mirrors pretty-print.ts `*` renderer.
_latex_product_sep(args) =
    any(a -> a isa VarExpr && occursin("\\", a.name), args) ? " " : " \\cdot "

"""Format one operand of `op`, parenthesizing per [`needs_parentheses`](@ref)."""
function _format_operand(op::String, arg::ASTExpr, format::Symbol,
                         is_right_operand::Bool=false)
    result = format_expression(arg, format)
    return needs_parentheses(op, arg, is_right_operand) ? "($result)" : result
end

# LaTeX function-call: `\left( \right)` only when the argument is tall
# (contains a \frac), else plain parentheses.
function _latex_func(name::AbstractString, arg::ASTExpr)
    la = format_expression_latex(arg)
    return occursin("\\frac", la) ? "$name\\left($la\\right)" : "$name($la)"
end

"""Render a binary infix operator node, or `nothing` for non-infix ops."""
function _format_infix_op(node::OpExpr, format::Symbol)
    op = node.op
    left, right = node.args
    fa(arg, is_right_operand=false) = _format_operand(op, arg, format, is_right_operand)

    if op == "+"
        # Simplify `a + (-b)` → `a - b` by rendering as a binary subtraction
        # (mirrors pretty-print.ts), keeping the subtraction formatting in one place.
        if isa(right, OpExpr) && right.op == "-" && length(right.args) == 1
            return format_operator_expression(OpExpr("-", ASTExpr[left, right.args[1]]), format)
        end
        return "$(fa(left)) + $(fa(right, true))"
    elseif op == "/"
        if format == :latex
            return "\\frac{$(format_expression_latex(left))}{$(format_expression_latex(right))}"
        elseif format == :unicode
            return "$(fa(left))/$(fa(right, true))"
        else
            return "$(fa(left)) / $(fa(right, true))"
        end
    elseif op == "^"
        if format == :latex
            return "$(fa(left))^{$(format_expression_latex(right))}"
        elseif format == :unicode && isa(right, IntExpr)
            return "$(fa(left))$(to_superscript(string(right.value)))"
        elseif format == :unicode && isa(right, NumExpr) && isinteger(right.value)
            return "$(fa(left))$(to_superscript(string(Int(right.value))))"
        else
            return "$(fa(left))^$(fa(right, true))"
        end
    elseif op in [">", "<"]
        return "$(fa(left)) $op $(fa(right, true))"
    elseif op == "*"
        sep = format == :latex ? _latex_product_sep(node.args) : _infix_separator(op, format)
        return "$(fa(left))$sep$(fa(right, true))"
    elseif haskey(_INFIX_SEPARATORS, op)
        sep = _infix_separator(op, format)
        return "$(fa(left))$sep$(fa(right, true))"
    elseif op == "atan2"
        if format == :latex
            return "\\mathrm{atan2}($(format_expression_latex(left)), $(format_expression_latex(right)))"
        else
            return "atan2($(fa(left)), $(fa(right)))"
        end
    end

    return nothing
end

"""Render a unary operator node, or `nothing` for ops without a unary form."""
function _format_unary_op(node::OpExpr, format::Symbol)
    op = node.op
    arg = node.args[1]
    fa(a) = _format_operand(op, a, format)

    if op == "-"
        return format == :unicode ? "−$(fa(arg))" : "-$(fa(arg))"
    elseif op == "not"
        if format == :unicode
            return "¬$(fa(arg))"
        elseif format == :latex
            return "\\neg $(fa(arg))"
        else
            return "not $(fa(arg))"
        end
    elseif op in ["exp", "sin", "cos", "tan", "sinh", "cosh", "tanh"]
        return format == :latex ? _latex_func("\\$op", arg) : "$op($(fa(arg)))"
    elseif op == "log"
        if format == :unicode
            return "ln($(fa(arg)))"
        elseif format == :latex
            return _latex_func("\\ln", arg)
        else
            return "log($(fa(arg)))"
        end
    elseif op == "log10"
        if format == :unicode
            return "log₁₀($(fa(arg)))"
        elseif format == :latex
            return _latex_func("\\log_{10}", arg)
        else
            return "log10($(fa(arg)))"
        end
    elseif op == "sqrt"
        if format == :unicode
            argstr = format_expression_unicode(arg)
            return isa(arg, OpExpr) ? "√($argstr)" : "√$argstr"
        elseif format == :latex
            return "\\sqrt{$(format_expression_latex(arg))}"
        else
            return "sqrt($(fa(arg)))"
        end
    elseif op == "abs"
        if format == :unicode
            return "|$(fa(arg))|"
        elseif format == :latex
            return "|$(format_expression_latex(arg))|"
        else
            return "abs($(fa(arg)))"
        end
    elseif op == "sign"
        if format == :unicode
            return "sgn($(fa(arg)))"
        elseif format == :latex
            return "\\mathrm{sgn}($(format_expression_latex(arg)))"
        else
            return "sign($(fa(arg)))"
        end
    elseif op == "floor"
        if format == :unicode
            return "⌊$(fa(arg))⌋"
        elseif format == :latex
            return "\\lfloor $(format_expression_latex(arg)) \\rfloor"
        else
            return "floor($(fa(arg)))"
        end
    elseif op == "ceil"
        if format == :unicode
            return "⌈$(fa(arg))⌉"
        elseif format == :latex
            return "\\lceil $(format_expression_latex(arg)) \\rceil"
        else
            return "ceil($(fa(arg)))"
        end
    elseif op in ["asin", "acos", "atan"]
        arc = replace(op, "a" => "arc"; count=1)
        if format == :unicode
            return "$arc($(fa(arg)))"
        elseif format == :latex
            return "\\$arc($(format_expression_latex(arg)))"
        else
            return "$op($(fa(arg)))"
        end
    elseif op in ["asinh", "acosh", "atanh"]
        hyp = replace(op, "a" => ""; count=1)
        if format == :unicode
            # `$(hyp)` (not `$hyp`) — the superscript chars are identifier
            # continuation chars, so `$hyp⁻¹` would interpolate `hyp⁻¹`.
            return "$(hyp)⁻¹($(fa(arg)))"
        elseif format == :latex
            return "\\$hyp^{-1}($(format_expression_latex(arg)))"
        else
            return "$op($(fa(arg)))"
        end
    elseif op == "Pre"
        return format == :latex ?
            "\\mathrm{Pre}($(format_expression_latex(arg)))" :
            "Pre($(fa(arg)))"
    elseif op == "D"
        wrt_var = isnothing(node.wrt) ? "t" : node.wrt
        # The differentiated operand is parenthesized when it is an operator node
        # (`∂(x + y)/∂t`, never `∂x + y/∂t`) — RENDERING_CONTRACT.md.
        if format == :unicode
            return "∂$(wrap_if_op(arg, :unicode))/∂$wrt_var"
        elseif format == :latex
            return "\\frac{\\partial $(wrap_if_op(arg, :latex))}{\\partial $wrt_var}"
        else
            return "D($(format_expression_ascii(arg)))/D$wrt_var"
        end
    end

    return nothing
end

"""Render ternary `ifelse` and n-ary (≥ 3) `+`/`*`/`or` chains, or `nothing`."""
function _format_nary_op(node::OpExpr, format::Symbol)
    op = node.op
    args = node.args
    fa(arg, is_right_operand=false) = _format_operand(op, arg, format, is_right_operand)

    if length(args) == 3 && op == "ifelse"
        cond, thenx, elsex = args
        if format == :latex
            return "\\begin{cases} $(format_expression_latex(thenx)) & \\text{if } $(format_expression_latex(cond)) \\\\ $(format_expression_latex(elsex)) & \\text{otherwise} \\end{cases}"
        end
        return "ifelse($(fa(cond)), $(fa(thenx)), $(fa(elsex)))"
    end

    if length(args) >= 3
        if op == "+"
            return join([fa(arg) for arg in args], " + ")
        elseif op == "*"
            sep = format == :latex ? _latex_product_sep(args) : _infix_separator(op, format)
            return join([fa(arg) for arg in args], sep)
        elseif op == "or"
            return join([fa(arg) for arg in args], _infix_separator(op, format))
        end
    end

    return nothing
end

"""
    format_operator_expression(node::OpExpr, format::Symbol) -> String

Format an OpExpr (operator with arguments).
"""
function format_operator_expression(node::OpExpr, format::Symbol)
    op = node.op
    args = node.args

    # Closed-core structural / array-query ops render specially.
    structural = format_structural_op(node, format)
    structural === nothing || return structural

    # min/max: function-call notation for any arity ≥ 2 (esm-spec §4.2)
    if (op == "min" || op == "max") && length(args) >= 2
        if format == :latex
            arg_list = join([format_expression_latex(arg) for arg in args], ", ")
            return "\\$op($arg_list)"
        else
            arg_list = join([format_expression(arg, format) for arg in args], ", ")
            return "$op($arg_list)"
        end
    end

    # Binary operators
    if length(args) == 2
        rendered = _format_infix_op(node, format)
        rendered === nothing || return rendered
    end

    # Unary operators
    if length(args) == 1
        rendered = _format_unary_op(node, format)
        rendered === nothing || return rendered
    end

    # Ternary / n-ary operators
    rendered = _format_nary_op(node, format)
    rendered === nothing || return rendered

    # Generic fallback: function-call notation for open-tier sugar
    # (grad/div/laplacian), skolem/rank, and any unknown user op. Only `args`
    # are shown; a non-`args` field (e.g. grad's `dim`) is NOT rendered.
    arg_list = join([format_expression(arg, format) for arg in args], ", ")
    return format == :latex ? "\\mathrm{$(latex_name(op))}($arg_list)" : "$op($arg_list)"
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

Compact one-line Model display (used in reprs and collections).
The multi-line summary lives on the `MIME"text/plain"` method.
"""
function Base.show(io::IO, model::Model)
    print(io, "Model(", length(model.variables), " variables, ",
          length(model.equations), " equations)")
end

"""
    Base.show(io::IO, ::MIME"text/plain", model::Model)

Model display: prints variable and equation lists per spec Section 6.3.
"""
function Base.show(io::IO, ::MIME"text/plain", model::Model)
    println(io, "Model:")
    println(io, "  Variables ($(length(model.variables))):")
    for (name, var) in model.variables
        # Total over the enum. The old three-way ternary fell through to
        # "observed" for anything else, so a BROWNIAN printed as "observed" and a
        # DISCRETE would too — a display that quietly lies about the kind.
        var_type_str = _variable_type_word(var.type)
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
            affects_str = join(["$(affect.lhs) = $(format_expression_unicode(affect.rhs))" for affect in event.affects], ", ")
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

Compact one-line EsmFile display (used in reprs and collections).
The multi-line summary lives on the `MIME"text/plain"` method.
"""
function Base.show(io::IO, esm_file::EsmFile)
    print(io, "EsmFile(v", esm_file.esm, ", \"", esm_file.metadata.name, "\")")
end

"""
    Base.show(io::IO, ::MIME"text/plain", esm_file::EsmFile)

EsmFile display: prints structured summary per spec Section 6.3.
"""
function Base.show(io::IO, ::MIME"text/plain", esm_file::EsmFile)
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

    if !isempty(components)
        println(io, "Components: $(join(components, ", "))")
    end

    if !isnothing(esm_file.domain)
        println(io, "Domain: configured")
    end
end

"""
    Base.show(io::IO, reaction_system::ReactionSystem)

Compact one-line ReactionSystem display (used in reprs and collections).
The multi-line summary lives on the `MIME"text/plain"` method.
"""
function Base.show(io::IO, reaction_system::ReactionSystem)
    print(io, "ReactionSystem(", length(reaction_system.species), " species, ",
          length(reaction_system.reactions), " reactions)")
end

"""
    _format_stoichiometry_side(entries; format_species=identity,
                               format_coefficient=string, empty="∅") -> String

Render one side (substrates or products) of a reaction from the ordered
`StoichiometryEntry` vector — get it via [`raw_substrates`](@ref) /
[`raw_products`](@ref), which preserve author order (the `get_reactants_dict` /
`get_products_dict` Dict views do not). Entries join with
`" + "`; an entry with stoichiometry 1 renders as the bare species, otherwise
`format_coefficient(stoichiometry)` is prefixed (the formatter supplies any
coefficient/species separator itself, e.g. `"2*"` for code emitters or `"2"`
for chemical notation). `empty` is returned for a `nothing`/empty side.
Shared by the ReactionSystem summary below and codegen.jl's reaction emitters.
"""
function _format_stoichiometry_side(entries::Union{Vector{StoichiometryEntry},Nothing};
                                    format_species::Function = identity,
                                    format_coefficient::Function = string,
                                    empty::String = "∅")
    if entries === nothing || isempty(entries)
        return empty
    end
    return join(
        [(entry.stoichiometry == 1 ? "" : format_coefficient(entry.stoichiometry)) *
         format_species(entry.species)
         for entry in entries], " + ")
end

"""
    Base.show(io::IO, ::MIME"text/plain", reaction_system::ReactionSystem)

ReactionSystem display: reactions in chemical notation.
"""
function Base.show(io::IO, ::MIME"text/plain", reaction_system::ReactionSystem)
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
    # Chemical-notation formatters: species get unicode subscripts; integral
    # stoichiometric coefficients print without the trailing ".0" (2.0 → "2").
    unicode_species(s) = format_chemical_subscripts(s, :unicode)
    chem_coefficient(c) = isinteger(c) ? string(Int(c)) : string(c)
    for (i, reaction) in enumerate(reaction_system.reactions)
        # raw_substrates/raw_products: the ordered StoichiometryEntry vectors
        # (the `get_reactants_dict`/`get_products_dict` Dict views lose author
        # order).
        reactants_str = _format_stoichiometry_side(raw_substrates(reaction);
            format_species=unicode_species, format_coefficient=chem_coefficient,
            empty="")
        products_str = _format_stoichiometry_side(raw_products(reaction);
            format_species=unicode_species, format_coefficient=chem_coefficient,
            empty="")

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
to_ascii(target) =
    throw(ArgumentError("Unsupported type for ASCII formatting: $(typeof(target))"))

to_ascii(::Nothing) = "nothing"

to_ascii(target::Real) = format_number(target, :ascii)

# JSON has no non-finite number literals, so the corpus (and the wider ESM
# world) carries ±Infinity / NaN as STRINGS. When a bare string denotes one of
# them, render it as the non-finite NUMBER it names (∞ / −∞ / NaN) per
# RENDERING_CONTRACT.md, not as a variable/chemical name.
const _NONFINITE_TOKENS = Dict{String,Float64}(
    "Infinity" => Inf, "-Infinity" => -Inf, "NaN" => NaN)

_maybe_nonfinite(target::AbstractString, format::Symbol) =
    haskey(_NONFINITE_TOKENS, target) ? format_number(_NONFINITE_TOKENS[target], format) : nothing

function to_ascii(target::String)
    r = _maybe_nonfinite(target, :ascii)
    r === nothing || return r
    return convert_greek_letters(format_chemical_subscripts(target, :ascii), :ascii)
end

to_ascii(target::ASTExpr) = format_expression_ascii(target)

to_ascii(target::Equation) =
    "$(format_expression_ascii(target.lhs)) = $(format_expression_ascii(target.rhs))"

# Simple ASCII summaries for container types
to_ascii(target::Model) =
    "Model($(length(target.variables)) variables, $(length(target.equations)) equations)"

to_ascii(target::ReactionSystem) =
    "ReactionSystem($(length(target.species)) species, $(length(target.reactions)) reactions)"

to_ascii(target::EsmFile) = "ESM v$(target.esm): $(target.metadata.name)"

"""
    to_unicode(target) -> String
    to_latex(target) -> String

Format `target` as Unicode / LaTeX mathematical notation. Parallel to
[`to_ascii`](@ref) for `Nothing`, `Real`, `String`, `ASTExpr`, and `Equation`
targets, sharing its naming convention across the language bindings (see
tests/display/RENDERING_CONTRACT.md). Unlike `to_ascii`, there are no
summary methods for `Model`/`ReactionSystem`/`EsmFile` — those types throw
`ArgumentError` here.
"""
to_unicode(target) =
    throw(ArgumentError("Unsupported type for Unicode formatting: $(typeof(target))"))
to_unicode(::Nothing) = "nothing"
to_unicode(target::Real) = format_number(target, :unicode)
function to_unicode(target::String)
    r = _maybe_nonfinite(target, :unicode)
    r === nothing || return r
    return convert_greek_letters(format_chemical_subscripts(target, :unicode), :unicode)
end
to_unicode(target::ASTExpr) = format_expression_unicode(target)
to_unicode(target::Equation) =
    "$(format_expression_unicode(target.lhs)) = $(format_expression_unicode(target.rhs))"

to_latex(target) =
    throw(ArgumentError("Unsupported type for LaTeX formatting: $(typeof(target))"))
to_latex(::Nothing) = "nothing"
to_latex(target::Real) = format_number(target, :latex)
function to_latex(target::String)
    r = _maybe_nonfinite(target, :latex)
    r === nothing || return r
    return convert_greek_letters(format_chemical_subscripts(target, :latex), :latex)
end
to_latex(target::ASTExpr) = format_expression_latex(target)
to_latex(target::Equation) =
    "$(format_expression_latex(target.lhs)) = $(format_expression_latex(target.rhs))"