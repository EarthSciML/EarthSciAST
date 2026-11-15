"""
Typeset unit spellings: LaTeX and Typst, with no unit package.

Port of `formal/Esm/Units/Typeset.lean` (Rust `document::math::units`), with
the `Esm.Units` helpers it uses (`numFactors`, `denFactors` from
Factors.lean, `digs`, `symOK` from Canonical.lean, `isIdent`, `isDigitC` from
Grammar.lean).

**LaTeX**: the canonical spelling's layout inside `\\mathrm{…}`: numerator
factors joined by `\\,`, a denominator after `/` (parenthesized when it has
more than one factor), exponents as braced superscripts, `_` and `%` escaped.

**Typst**: one `upright("sym")^(exp)` per factor with its signed exponent,
factors separated by ` thin `.
"""
module MUnits

using ..DJson

"""`Esm.Units.Factor`: a unit symbol and its (signed, rational) exponent."""
const Factor = Tuple{String, Rational{BigInt}}

const ONE = Rational{BigInt}(1)

"""`Esm.Units.isDigitC`."""
is_digit_c(c::Char) = '0' <= c <= '9'

"""`Esm.Units.isIdent`: characters that may occur in a symbol run."""
is_ident(c::Char) = ('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') || c == '_'

"""`Esm.Units.numFactors`: the factors with a positive exponent."""
num_factors(l) = Factor[f for f in l if f[2] > 0]

"""`Esm.Units.denFactors`: the factors with a nonpositive exponent."""
den_factors(l) = Factor[f for f in l if !(f[2] > 0)]

"""`Esm.Units.symRunB` (Canonical.lean)."""
sym_run_b(s::AbstractString) = !isempty(s) && all(is_ident, s) && !all(is_digit_c, s)

"""`Esm.Units.symOK` (Canonical.lean): `%`, or a symbol run, and not
`dimensionless`."""
sym_ok(s::AbstractString) = (s == "%" || sym_run_b(s)) && s != "dimensionless"

"""`Esm.Units.digs`: the decimal digits of `n` (empty for `0`)."""
digs(n::Integer) = iszero(n) ? Char[] : collect(Char, string(n))

"""`Esm.Units.pDigits`: a nonempty digit run and its value."""
function p_digits(cs::Chars)
    n = 0
    while is_digit_c(at(cs, n + 1))
        n += 1
    end
    n == 0 && return nothing
    v = BigInt(0)
    for i in 1:n
        v = v * 10 + (UInt32(cs[i]) - 48)
    end
    return v, drop(cs, n)
end

"""`Esm.Units.joinWith`."""
function join_with(pr, sep, l)
    out = Char[]
    for (i, f) in enumerate(l)
        i > 1 && append!(out, sep)
        append!(out, pr(f))
    end
    return out
end

"""`Esm.Units.pSepBy`: items read by `pf`, separated by `sep`."""
function p_sep_by(pf, sep::AbstractString, cs::Chars)
    out = Factor[]
    while true
        x = pf(cs)
        x === nothing && return nothing
        f, r = x
        push!(out, f)
        r2 = strip_prefix(r, sep)
        r2 === nothing && return out, r
        cs = r2
    end
    return nothing
end

# `p / d` as Lean's rational division (`x / 0 = 0`).
ratio(p::Rational{BigInt}, d::BigInt) = iszero(d) ? Rational{BigInt}(0) : p / d
rat(p::Integer) = Rational{BigInt}(BigInt(p))

# ## LaTeX

"""`Esm.Units.latexSym`: `_` and `%` escaped with a backslash."""
function latex_sym(cs)
    out = Char[]
    for c in cs
        (c == '_' || c == '%') && push!(out, '\\')
        push!(out, c)
    end
    return out
end

"""`Esm.Units.latexExp`: a positive exponent as a braced superscript (nothing
for 1)."""
function latex_exp(q::Rational{BigInt})
    q == ONE && return Char[]
    out = Char['^', '{']
    append!(out, digs(abs(numerator(q))))
    if denominator(q) != 1
        push!(out, '/')
        append!(out, digs(denominator(q)))
    end
    push!(out, '}')
    return out
end

"""`Esm.Units.latexFactor`: one factor, with the absolute value of its
exponent."""
function latex_factor(f::Factor)
    out = latex_sym(f[1])
    append!(out, latex_exp(abs(f[2])))
    return out
end

"""`Esm.Units.latexSep`."""
const LATEX_SEP = "\\,"

"""`Esm.Units.latexBody`: the body of `\\mathrm{…}`."""
function latex_body(l)
    nf = num_factors(l)
    out = isempty(nf) ? Char['1'] : join_with(latex_factor, LATEX_SEP, nf)
    df = den_factors(l)
    if length(df) == 1
        push!(out, '/')
        append!(out, latex_factor(df[1]))
    elseif length(df) > 1
        push!(out, '/', '(')
        append!(out, join_with(latex_factor, LATEX_SEP, df))
        push!(out, ')')
    end
    return out
end

"""`Esm.Units.mathrmOpen`."""
const MATHRM_OPEN = "\\mathrm{"

"""`Esm.Units.latex`: the LaTeX form of a canonical factor list."""
function latex(l)
    out = collect(Char, MATHRM_OPEN)
    append!(out, latex_body(l))
    push!(out, '}')
    return out
end

"""`Esm.Units.pLSym`: identifier characters, `%`, and the escapes `\\_`,
`\\%` (the symbol and the rest)."""
function p_l_sym(cs::Chars)
    out = Char[]
    while true
        c = at(cs)
        if c != EOFC && (is_ident(c) || c == '%')
            push!(out, c)
            cs = drop(cs)
        elseif c == '\\' && (at(cs, 2) == '_' || at(cs, 2) == '%')
            push!(out, cs[2])
            cs = drop(cs, 2)
        else
            return out, cs
        end
    end
    return out, cs
end

"""`Esm.Units.pLExp`: a braced superscript, or nothing (exponent 1)."""
function p_l_exp(cs::Chars)
    if at(cs) == '^' && at(cs, 2) == '{'
        x = p_digits(drop(cs, 2))
        x === nothing && return nothing
        p, r = x
        if at(r) == '}'
            return rat(p), drop(r)
        elseif at(r) == '/'
            y = p_digits(drop(r))
            (y === nothing || at(y[2]) != '}') && return nothing
            return ratio(rat(p), y[1]), drop(y[2])
        end
        return nothing
    end
    return ONE, cs
end

"""`Esm.Units.pLFactor`."""
function p_l_factor(cs::Chars)
    s, r = p_l_sym(cs)
    isempty(s) && return nothing
    x = p_l_exp(r)
    x === nothing && return nothing
    return (String(s), x[1]), x[2]
end

"""`Esm.Units.pLDen`: a LaTeX denominator (after the `/`)."""
function p_l_den(r::Chars)
    if at(r) == '('
        x = p_sep_by(p_l_factor, LATEX_SEP, drop(r))
        (x !== nothing && length(x[2]) == 1 && x[2][1] == ')') || return nothing
        return x[1]
    end
    x = p_sep_by(p_l_factor, LATEX_SEP, r)
    (x !== nothing && isempty(x[2]) && length(x[1]) == 1) || return nothing
    return x[1]
end

"""`Esm.Units.parseLatex`: a LaTeX unit back to its two-sided factor list."""
function parse_latex(s::Chars)
    body = strip_prefix(s, MATHRM_OPEN)
    body === nothing && return nothing
    (!isempty(body) && last(body) == '}') || return nothing
    b = view(body, 1:(length(body) - 1))
    x = p_sep_by(p_l_factor, LATEX_SEP, b)
    x === nothing && return nothing
    num, rest = x
    if length(num) == 1 && num[1][1] == "1" && num[1][2] == ONE
        num = Factor[]
    end
    isempty(rest) && return num
    if at(rest) == '/'
        den = p_l_den(drop(rest))
        den === nothing && return nothing
        out = copy(num)
        for (sy, q) in den
            push!(out, (sy, -q))
        end
        return out
    end
    return nothing
end

# ## Typst

"""`Esm.Units.uprightOpen`."""
const UPRIGHT_OPEN = "upright(\""
"""`Esm.Units.uprightClose`."""
const UPRIGHT_CLOSE = "\")"
"""`Esm.Units.thinSep`."""
const THIN_SEP = " thin "

"""`Esm.Units.typstExp`: a signed exponent: nothing for 1, `^n`, `^(-n)`,
`^(p\\/q)`, `^(-p\\/q)`."""
function typst_exp(q::Rational{BigInt})
    q == ONE && return Char[]
    n = digs(abs(numerator(q)))
    if denominator(q) == 1
        if q > 0
            return vcat(Char['^'], n)
        end
        return vcat(Char['^', '(', '-'], n, Char[')'])
    end
    out = Char['^', '(']
    q < 0 && push!(out, '-')
    append!(out, n)
    push!(out, '\\', '/')
    append!(out, digs(denominator(q)))
    push!(out, ')')
    return out
end

"""`Esm.Units.typstFactor`: `upright("sym")` and its signed exponent."""
function typst_factor(f::Factor)
    out = collect(Char, UPRIGHT_OPEN)
    append!(out, f[1])
    append!(out, UPRIGHT_CLOSE)
    append!(out, typst_exp(f[2]))
    return out
end

"""`Esm.Units.typst`: the Typst form of a canonical factor list (`1` when
empty)."""
function typst(l)
    isempty(l) && return Char['1']
    ordered = vcat(num_factors(l), den_factors(l))
    return join_with(typst_factor, THIN_SEP, ordered)
end

"""`Esm.Units.pTParen`: after `^(`: `'-'? digits (')' | '\\/' digits ')')`."""
function p_t_paren(cs::Chars)
    neg = at(cs) == '-'
    cs2 = neg ? drop(cs) : cs
    x = p_digits(cs2)
    x === nothing && return nothing
    p, r = x
    sp = neg ? -rat(p) : rat(p)
    if at(r) == ')'
        return sp, drop(r)
    elseif at(r) == '\\' && at(r, 2) == '/'
        y = p_digits(drop(r, 2))
        (y === nothing || at(y[2]) != ')') && return nothing
        return ratio(sp, y[1]), drop(y[2])
    end
    return nothing
end

"""`Esm.Units.pTExp`: an optional exponent (none means 1)."""
function p_t_exp(cs::Chars)
    if at(cs) == '^'
        r = drop(cs)
        at(r) == '(' && return p_t_paren(drop(r))
        isempty(r) && return nothing
        x = p_digits(r)
        x === nothing && return nothing
        return rat(x[1]), x[2]
    end
    return ONE, cs
end

"""`Esm.Units.pTFactor`."""
function p_t_factor(cs::Chars)
    r = strip_prefix(cs, UPRIGHT_OPEN)
    r === nothing && return nothing
    n = 0
    while n < length(r) && r[n + 1] != '"'
        n += 1
    end
    sym = String(r[1:n])
    r2 = strip_prefix(drop(r, n), UPRIGHT_CLOSE)
    r2 === nothing && return nothing
    x = p_t_exp(r2)
    x === nothing && return nothing
    return (sym, x[1]), x[2]
end

"""`Esm.Units.parseTypst`: a Typst unit back to its two-sided factor list."""
function parse_typst(s::Chars)
    (length(s) == 1 && s[1] == '1') && return Factor[]
    x = p_sep_by(p_t_factor, THIN_SEP, s)
    (x !== nothing && isempty(x[2])) || return nothing
    return x[1]
end

end # module MUnits
