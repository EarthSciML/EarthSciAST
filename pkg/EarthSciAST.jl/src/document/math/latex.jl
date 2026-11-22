"""
LaTeX math: spelling and lexing of tokens.

Port of `formal/Esm/Document/Math/Latex.lean` (Rust `document::math::latex`).
[`render`](@ref) spells a token list as LaTeX math, writing a space between two
tokens where the reader needs one (`needSpace`) and where it reads better
(`pretty`); [`lex`](@ref) reads it back, skipping spaces and the spacing
commands.
"""
module MLatex

using ..DJson
using ..MToken
using ..MUnits: Factor
import ..MUnits
import ..DNumber
import ..DStrings
using ..MParse: atom_start, units_of_raw
using ..MPrint: char_digit_nat, char_of_nat, dig3, esc_t, key_special, raw_b, unesc_t
using ..MSurface: drop_p, is_bin, lex_signed, render_toks, sci_split
using ..MExpr: is_dig, is_greek, is_letter, let_run

# ## Spelling

"""`Latex.fixUs`: undo the `\\_` of `escCharL` up to the closing quote."""
function fix_us(cs::Chars)
    out = Char[]
    while true
        c = at(cs)
        if c == '\\' && at(cs, 2) == '_'
            push!(out, '_')
            cs = drop(cs, 2)
        elseif c == '\\' && length(cs) >= 2
            push!(out, '\\', cs[2])
            cs = drop(cs, 2)
        elseif c == '"'
            append!(out, cs)
            return out
        elseif !isempty(cs)
            push!(out, c)
            cs = drop(cs)
        else
            return out
        end
    end
    return out
end

"""`Latex.strPlain`: a character of a JSON string written as itself inside
`\\text{…}`."""
function str_plain(c::Char)
    n = UInt32(c)
    return 32 <= n <= 126 && !key_special(c) && c != '_' && c != '{' && c != '}'
end

"""`Latex.dig7`: seven decimal digits."""
dig7(n::Integer) = ntuple(i -> DNumber.digit_char(n ÷ 10^(7 - i) % 10), 7)

"""`Latex.escS`: the spelling of a JSON string's characters inside
`\\text{"…"}`."""
function esc_s(cs)
    out = Char[]
    for c in cs
        if str_plain(c)
            push!(out, c)
        elseif c == '_' || c == '{' || c == '}'
            push!(out, '\\', c)
        elseif UInt32(c) < 1000
            append!(out, "{\\char")
            push!(out, dig3(UInt32(c))...)
            push!(out, '}')
        else
            append!(out, "{\\char")
            push!(out, dig7(UInt32(c))...)
            push!(out, '}')
        end
    end
    return out
end

"""`Latex.unescS`: undo [`esc_s`](@ref)."""
function unesc_s(cs)
    v = view(collect(Char, cs), :)
    out = Char[]
    d(c) = char_digit_nat(c)
    while !isempty(v)
        if starts(v, "{\\char") && length(v) >= 10 && v[10] == '}'
            push!(out, char_of_nat(100 * d(v[7]) + 10 * d(v[8]) + d(v[9])))
            v = drop(v, 10)
        elseif starts(v, "{\\char") && length(v) >= 14 && v[14] == '}'
            push!(
                out, char_of_nat(
                    1_000_000 * d(v[7]) + 100_000 * d(v[8]) + 10_000 * d(v[9]) +
                        1000 * d(v[10]) + 100 * d(v[11]) + 10 * d(v[12]) + d(v[13])
                )
            )
            v = drop(v, 14)
        elseif v[1] == '\\' && length(v) >= 2
            push!(out, v[2])
            v = drop(v, 2)
        else
            push!(out, v[1])
            v = drop(v)
        end
    end
    return out
end

"""`Latex.strL`: a JSON string in LaTeX: `\\text{"…"}`."""
function str_l(s::AbstractString)
    out = collect(Char, "\\text{\"")
    append!(out, esc_s(s))
    push!(out, '"', '}')
    return out
end

"""`Latex.textTok`: the token of `\\text{raw}`: a JSON string when the text is
double-quoted, else text."""
function text_tok(raw)
    r = collect(Char, raw)
    if length(r) >= 2 && r[1] == '"' && r[end] == '"'
        return TJstr(String(unesc_s(r[2:(end - 1)])))
    end
    return TTxt(String(r))
end

"""`Latex.timesTen`."""
const TIMES_TEN = " \\times 10^{"

"""`Latex.numChars`."""
function num_chars(n::JNum)
    s = sci_split(n)
    s === nothing && return DNumber.print(n)
    m, e = s
    out = copy(m)
    append!(out, TIMES_TEN)
    append!(out, DNumber.print_int(e))
    push!(out, '}')
    return out
end

const KW_CHARS = Dict{Kw, String}(
    KPlus => "+", KMinus => "-", KEq => "=", KNe => "\\ne", KLt => "<", KGt => ">",
    KLe => "\\le", KGe => "\\ge", KLand => "\\land", KLor => "\\lor", KLnot => "\\lnot",
    KCdot => "\\cdot", KTimes => "\\times", KSlash => "/", KCaret => "^", KUs => "_",
    KLp => "(", KRp => ")", KLpg => "\\left(", KRpg => "\\right)", KLb => "{", KRb => "}",
    KLbk => "[", KRbk => "]", KComma => ",", KSemi => ";", KColon => ":", KAmp => "&",
    KNl => "\\\\", KSdot => ".", KFrac => "\\frac", KSqrt => "\\sqrt", KExp => "\\exp",
    KLn => "\\ln", KLog => "\\log", KSin => "\\sin", KCos => "\\cos", KTan => "\\tan",
    KAsin => "\\arcsin", KAcos => "\\arccos", KAtan => "\\arctan", KSinh => "\\sinh",
    KCosh => "\\cosh", KTanh => "\\tanh", KMin => "\\min", KMax => "\\max",
    KLabs => "\\left|", KRabs => "\\right|", KLfloor => "\\lfloor", KRfloor => "\\rfloor",
    KLceil => "\\lceil", KRceil => "\\rceil", KPdiff => "\\partial", KDotacc => "\\dot",
    KNabla => "\\nabla",
    KBcases => "\\begin{cases}", KEcases => "\\end{cases}", KBmat => "\\begin{bmatrix}",
    KEmat => "\\end{bmatrix}", KSum => "\\sum", KProd => "\\prod", KInn => "\\in",
    KSubstack => "\\substack", KLimitsL => "\\limits", KLbkg => "\\left[",
    KRbkg => "\\right]", KBarr => "\\begin{array}{l|l}", KEarr => "\\end{array}",
    KLset => "\\{", KRset => "\\}",
)

"""`Latex.kwChars`."""
kw_chars(k::Kw) = get(KW_CHARS, k, "")

function wrap_brace(open::AbstractString, body)
    out = collect(Char, open)
    append!(out, body)
    push!(out, '}')
    return out
end

"""`Latex.tokChars`."""
function tok_chars(t::Tok)
    t isa TNum && return num_chars(t.n)
    t isa TLetter && return Char[t.c]
    t isa TGreek && return vcat(Char['\\'], collect(Char, t.s))
    t isa TWord && return collect(Char, t.s)
    t isa TIt && return wrap_brace("\\mathit{", esc_t(t.s))
    t isa TRm && return wrap_brace("\\mathrm{", t.s)
    t isa TOpn && return wrap_brace("\\operatorname{", esc_t(t.s))
    t isa TTxt && return wrap_brace("\\text{", t.s)
    t isa TJstr && return str_l(t.s)
    t isa TEsc && return wrap_brace("\\esm{", esc_t(t.s))
    t isa TUnits && return wrap_brace("\\,\\mathrm{", MUnits.latex_body(t.fs))
    t isa TKw && return collect(Char, kw_chars(t.k))
    t isa TArrCols && return vcat(collect(Char, "\\begin{array}{"), fill('c', t.n), Char['}'])
    return Char[]
end

# ## Spacing

"""`Latex.endsAlpha`: `t` ends with letters a following letter would extend."""
function ends_alpha(t::Tok)
    (t isa TLetter || t isa TWord || t isa TGreek) && return true
    if t isa TKw
        s = kw_chars(t.k)
        return !isempty(s) && is_letter(last(s))
    end
    return false
end

"""`Latex.merges`: a space is needed between `t` and a following token starting
with `c`."""
merges(t::Tok, c::Char) =
    (ends_alpha(t) && is_letter(c)) || (t isa TNum && (is_dig(c) || c == '.' || c == 'e')) ||
    (iskw(t, KMinus) && is_dig(c))

"""`Latex.needSpace`."""
function need_space(t1::Tok, t2::Tok)
    cs = tok_chars(t2)
    isempty(cs) && return false
    return merges(t1, cs[1])
end

const ATOM_END_KWS = (KRp, KRpg, KRb, KRbk, KRabs, KRfloor, KRceil, KEcases)

"""`Latex.atomEnd`: tokens that end an operand."""
function atom_end(t::Tok)
    (
        t isa TNum || t isa TLetter || t isa TGreek || t isa TWord || t isa TIt || t isa TRm ||
            t isa TUps || t isa TTxt || t isa TJstr || t isa TCode || t isa TUnits
    ) && return true
    t isa TKw && return t.k in ATOM_END_KWS
    return false
end

"""`Latex.pretty`: spacing for reading."""
pretty(p, t1::Tok, t2::Tok) =
    is_bin(t1) || is_bin(t2) || iskw(t1, KComma) || iskw(t1, KColon) || iskw(t1, KSemi) ||
    (iskw(t2, KMinus) && atom_end(t1)) ||
    (iskw(t1, KMinus) && p !== nothing && atom_end(p)) ||
    (atom_end(t1) && atom_start(t2) && !(iskw(t2, KLp) || iskw(t2, KLbk))) ||
    iskw(t1, KBarr) || iskw(t2, KEarr)

"""`Latex.sp`."""
sp(p, t1::Tok, t2::Tok) = need_space(t1, t2) || pretty(p, t1, t2)

"""`Latex.render`: the LaTeX spelling of a token list (`renderAux`), as
characters."""
render(ts) = render_toks(tok_chars, sp, ts)

# ## Lexing

"""`Latex.ctrlKw`: control words that are keywords, with the variants read on
input. Derived from `KW_CHARS`: every spelling that is a backslash and letters,
plus the three input variants `\\neq`, `\\leq`, `\\geq`."""
const CTRL_KW = let d = Dict{String, Kw}("neq" => KNe, "leq" => KLe, "geq" => KGe)
    for (k, w) in KW_CHARS
        (length(w) >= 2 && w[1] == '\\' && all(isletter, w[2:end])) && (d[w[2:end]] = k)
    end
    d
end

"""Not in Lean: after `\\begin`: `{array}{` and one or more `c`, then
`}`: the opener of a wide constant matrix, with its column count."""
function array_cols(r::Chars)
    r2 = drop_p("{array}{", r)
    r2 === nothing && return nothing
    n = 0
    while at(r2, n + 1) == 'c'
        n += 1
    end
    (n >= 1 && at(r2, n + 1) == '}') || return nothing
    return TArrCols(n), drop(r2, n + 1)
end

"""`Latex.ctrlTok`: after a control word: its token and the rest."""
function ctrl_tok(w::String, r::Chars)
    if w in ("mathit", "mathrm", "operatorname", "text", "esm")
        at(r) == '{' || return nothing
        x = raw_b(0, drop(r))
        x === nothing && return nothing
        raw, rest = x
        s = String(raw)
        u = String(unesc_t(raw))
        t = if w == "mathit"
            TIt(u)
        elseif w == "mathrm"
            TRm(s)
        elseif w == "operatorname"
            TOpn(u)
        elseif w == "text"
            text_tok(raw)
        else
            TEsc(u)
        end
        return t, rest
    elseif w in ("left", "bigl", "Bigl")
        c = at(r)
        c == '(' && return TKw(KLpg), drop(r)
        c == '[' && return TKw(w == "left" ? KLbkg : KLbk), drop(r)
        c == '|' && return w == "left" ? (TKw(KLabs), drop(r)) : nothing
        return nothing
    elseif w in ("right", "bigr", "Bigr")
        c = at(r)
        c == ')' && return TKw(KRpg), drop(r)
        c == ']' && return TKw(w == "right" ? KRbkg : KRbk), drop(r)
        c == '|' && return w == "right" ? (TKw(KRabs), drop(r)) : nothing
        return nothing
    elseif w == "begin"
        r2 = drop_p("{cases}", r)
        r2 !== nothing && return TKw(KBcases), r2
        r2 = drop_p("{bmatrix}", r)
        r2 !== nothing && return TKw(KBmat), r2
        r2 = drop_p("{array}{l|l}", r)
        r2 !== nothing && return TKw(KBarr), r2
        return array_cols(r)
    elseif w == "end"
        r2 = drop_p("{cases}", r)
        r2 !== nothing && return TKw(KEcases), r2
        r2 = drop_p("{bmatrix}", r)
        r2 !== nothing && return TKw(KEmat), r2
        r2 = drop_p("{array}", r)
        return r2 === nothing ? nothing : (TKw(KEarr), r2)
    elseif is_greek(w)
        return TGreek(w), r
    end
    k = get(CTRL_KW, w, nothing)
    return k === nothing ? nothing : (TKw(k), r)
end

"""`Latex.isWsL`: white space."""
is_ws_l(c::Char) = c == ' ' || c == '\n' || c == '\t' || c == '\r'

"""`Latex.skipSp`: skip white space and the two-character spacing commands,
inside a scientific tail."""
function skip_sp(cs::Chars)
    while true
        c = at(cs)
        if is_ws_l(c)
            cs = drop(cs)
        elseif c == '\\' && at(cs, 2) in (';', ':', '!', ' ', ',')
            cs = drop(cs, 2)
        else
            return cs
        end
    end
    return cs
end

"""`Latex.sciExp`: the scientific tail `\\times 10^{exponent}` after a mantissa,
with any spacing between its parts."""
function sci_exp(r::Chars)
    r1 = drop_p("\\times", skip_sp(r))
    r1 === nothing && return nothing
    is_letter(at(r1)) && return nothing
    r2 = drop_p("10", skip_sp(r1))
    r2 === nothing && return nothing
    r3 = skip_sp(r2)
    at(r3) == '^' || return nothing
    r4 = skip_sp(drop(r3))
    at(r4) == '{' || return nothing
    x = DNumber.parse_int(skip_sp(drop(r4)))
    x === nothing && return nothing
    z, r5 = x
    r6 = skip_sp(r5)
    at(r6) == '}' || return nothing
    return z, drop(r6)
end

"""`Latex.unitTok`: after `\\,`: a unit `\\mathrm{…}`, with white space
between."""
function unit_tok(r::Chars)
    n = 0
    while is_ws_l(at(r, n + 1))
        n += 1
    end
    r1 = drop_p(MUnits.MATHRM_OPEN, drop(r, n))
    r1 === nothing && return nothing
    x = raw_b(0, r1)
    x === nothing && return nothing
    raw, r2 = x
    l = units_of_raw(raw)
    return l === nothing ? nothing : (l, r2)
end

# The one-character spellings of `KW_CHARS`, inverted.
const PUNCT = Dict{Char, Kw}(only(w) => k for (k, w) in KW_CHARS if length(w) == 1)

"""`Latex.punct`."""
punct(c::Char) = get(PUNCT, c, nothing)

"""`Latex.lexOne`: one token at the front of the input."""
function lex_one(cs::Chars)
    c = at(cs)
    c == EOFC && return nothing
    if c == '\\' && length(cs) >= 2
        d = cs[2]
        r = drop(cs, 2)
        if is_letter(d)
            w, rest = let_run(drop(cs))
            return ctrl_tok(String(w), rest)
        elseif d == ','
            x = unit_tok(r)
            return x === nothing ? nothing : (TUnits(x[1]), x[2])
        elseif d == '\\'
            return TKw(KNl), r
        elseif d == '{'
            return TKw(KLset), r
        elseif d == '}'
            return TKw(KRset), r
        end
        return nothing
    elseif c == '"'
        r = drop(cs)
        fixed = fix_us(r)
        x = DStrings.unquote_body(false, fixed)
        x === nothing && return nothing
        body, rest = x
        n = length(rest)
        return TJstr(String(body)), view(r, (length(r) - n + 1):length(r))
    end
    r = drop(cs)
    if is_dig(c) || (c == '-' && is_dig(at(r)))
        return lex_signed(sci_exp, cs)
    elseif is_letter(c)
        w, rest = let_run(cs)
        length(w) == 1 && return TLetter(w[1]), rest
        return TWord(String(w)), rest
    end
    k = punct(c)
    return k === nothing ? nothing : (TKw(k), r)
end

"""`Latex.skipWs`: skip spaces and the spacing commands (`\\,` too, unless a
unit follows it)."""
function skip_ws(cs::Chars)
    while true
        c = at(cs)
        if is_ws_l(c)
            cs = drop(cs)
        elseif c == '\\' && length(cs) >= 2
            d = cs[2]
            r2 = drop(cs, 2)
            if d in (';', ':', '!', ' ')
                cs = r2
            elseif d == ','
                unit_tok(r2) !== nothing && return cs
                cs = r2
            else
                w, rest = let_run(drop(cs))
                if w == ['q', 'u', 'a', 'd'] || w == ['q', 'q', 'u', 'a', 'd']
                    cs = rest
                else
                    return cs
                end
            end
        else
            return cs
        end
    end
    return cs
end

"""`Latex.lex`: read LaTeX math into tokens (`lexAux`)."""
function lex(cs::Chars)
    out = Tok[]
    while true
        cs2 = skip_ws(cs)
        isempty(cs2) && return out
        x = lex_one(cs2)
        x === nothing && return nothing
        push!(out, x[1])
        cs = x[2]
    end
    return out
end

end # module MLatex
