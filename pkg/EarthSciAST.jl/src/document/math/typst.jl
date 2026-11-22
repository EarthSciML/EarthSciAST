"""
Typst math: spelling and lexing of tokens.

Port of `formal/Esm/Document/Math/Typst.lean` (Rust `document::math::typst`).
Typst has one parenthesis: the lexer reads `(` right after a name, a digit,
`)` or `"` as a call parenthesis and any other `(` as a grouping one; the
renderer writes no space between a function name and its `(` and a space
between an operand and a following grouping `(`.
"""
module MTypst

using ..DJson
using ..MToken
using ..MUnits: Factor
import ..MUnits
import ..DNumber
import ..DStrings
import ..DTypstDict
using ..MExpr: dig_run, is_dig, is_greek, is_letter
using ..MParse: atom_start
using ..MSurface: drop_p, is_bin, lex_signed, render_toks, sci_split

# ## Spelling

"""`Typst.timesTen`."""
const TIMES_TEN = " times 10^"

"""`Typst.numChars`."""
function num_chars(n::JNum)
    s = sci_split(n)
    s === nothing && return DNumber.print(n)
    m, e = s
    out = copy(m)
    append!(out, TIMES_TEN)
    if e < 0
        push!(out, '(')
        append!(out, DNumber.print_int(e))
        push!(out, ')')
    else
        append!(out, DNumber.print_int(e))
    end
    return out
end

const KW_CHARS = Dict{Kw, String}(
    KPlus => "+", KMinus => "-", KEq => "=", KNe => "!=", KLt => "<", KGt => ">",
    KLe => "<=", KGe => ">=", KLand => "and", KLor => "or", KLnot => "not", KCdot => "dot",
    KTimes => "times", KSlash => "/", KCaret => "^", KUs => "_", KLp => "(", KLpg => "(",
    KRp => ")", KLbk => "[", KRbk => "]", KComma => ",", KSemi => ";", KColon => ":",
    KAmp => "&", KSdot => "\".\"", KSqrt => "sqrt", KExp => "exp", KLn => "ln",
    KLog => "log", KSin => "sin", KCos => "cos", KTan => "tan", KAsin => "arcsin",
    KAcos => "arccos", KAtan => "arctan", KSinh => "sinh", KCosh => "cosh", KTanh => "tanh",
    KMin => "min", KMax => "max", KAbs => "abs", KFloor => "floor", KCeil => "ceil",
    KPdiff => "partial", KNabla => "nabla", KDif => "dif", KCases => "cases",
    KEsmnode => "esm.node",
    KVec => "vec", KMat => "mat", KSum => "sum", KProd => "product", KInn => "in",
    KLimits => "limits", KLr => "lr", KNl => "\\", KLset => "{", KRset => "}",
)

"""`Typst.kwChars`."""
kw_chars(k::Kw) = get(KW_CHARS, k, "")

"""`Typst.pieceChars`."""
function piece_chars(p::Tuple{String, String})
    out = collect(Char, "upright(")
    append!(out, DStrings.quote_str(true, p[1]))
    push!(out, ')')
    if !isempty(p[2])
        push!(out, '_')
        append!(out, p[2])
    end
    return out
end

"""`Typst.unitChars`."""
function unit_chars(l)
    out = collect(Char, "thin ")
    append!(out, MUnits.join_with(MUnits.typst_factor, MUnits.THIN_SEP, l))
    return out
end

function call_chars(head::AbstractString, s::AbstractString)
    out = collect(Char, head)
    append!(out, DStrings.quote_str(true, s))
    push!(out, ')')
    return out
end

"""`Typst.tokChars`."""
function tok_chars(t::Tok)
    t isa TNum && return num_chars(t.n)
    t isa TLetter && return Char[t.c]
    t isa TGreek && return collect(Char, t.s)
    t isa TWord && return collect(Char, t.s)
    t isa TIt && return call_chars("italic(", t.s)
    if t isa TUps
        out = Char[]
        for p in t.ps
            append!(out, piece_chars(p))
        end
        return out
    end
    t isa TOpn && return call_chars("op(", t.s)
    t isa TTxt && return DStrings.quote_str(true, t.s)
    t isa TCode && return vcat(Char['#'], DTypstDict.encode(t.j))
    t isa TUnits && return unit_chars(t.fs)
    t isa TKw && return collect(Char, kw_chars(t.k))
    return Char[]
end

# ## Spacing

"""`Typst.isIdC`."""
is_id_c(c::Char) = is_letter(c) || is_dig(c)

"""`Typst.merges`: a space is needed between `t` and a following token starting
with `c`."""
function merges(t::Tok, c::Char)
    cs = tok_chars(t)
    (!isempty(cs) && is_letter(last(cs)) && is_id_c(c)) && return true
    return (t isa TNum && (is_id_c(c) || c == '.')) || (iskw(t, KMinus) && is_dig(c)) ||
        (t isa TUps && (is_dig(c) || c == 'u' || c == '_')) || (t isa TCode && is_id_c(c)) ||
        (t isa TUnits && (is_dig(c) || c == '^')) ||
        ((iskw(t, KLt) || iskw(t, KGt)) && c == '=') || (iskw(t, KSlash) && c == '/')
end

"""`Typst.callEnd`: `t` ends with a character after which `(` is a call
parenthesis."""
function call_end(t::Tok)
    cs = tok_chars(t)
    isempty(cs) && return false
    d = last(cs)
    return is_id_c(d) || d == ')' || d == '"'
end

"""`Typst.needSpace`."""
function need_space(t1::Tok, t2::Tok)
    iskw(t2, KLpg) && return call_end(t1)
    iskw(t2, KLp) && return false
    cs = tok_chars(t2)
    isempty(cs) && return false
    return merges(t1, cs[1])
end

"""`Typst.atomEnd`."""
function atom_end(t::Tok)
    (
        t isa TNum || t isa TLetter || t isa TGreek || t isa TWord || t isa TIt || t isa TUps ||
            t isa TTxt || t isa TCode || t isa TUnits
    ) && return true
    return iskw(t, KRp) || iskw(t, KRbk)
end

"""`Typst.pretty`."""
pretty(p, t1::Tok, t2::Tok) =
    is_bin(t1) || is_bin(t2) || iskw(t1, KComma) || iskw(t1, KColon) || iskw(t1, KSemi) ||
    (iskw(t2, KMinus) && atom_end(t1)) ||
    (iskw(t1, KMinus) && p !== nothing && atom_end(p)) ||
    (atom_end(t1) && atom_start(t2)) || t2 isa TUnits

"""`Typst.sp`: no space before a call parenthesis, nor before the `[` of an
index."""
sp(p, t1::Tok, t2::Tok) =
    need_space(t1, t2) ||
    (pretty(p, t1, t2) && !iskw(t2, KLp) && !(iskw(t2, KLbk) && atom_end(t1)))

"""`Typst.render` (`renderAux`), as characters."""
render(ts) = render_toks(tok_chars, sp, ts)

# ## Lexing

"""`Typst.idRun`: the maximal run of identifier characters (the run and the
rest)."""
function id_run(cs::Chars)
    n = 0
    while is_id_c(at(cs, n + 1))
        n += 1
    end
    return view(cs, 1:n), drop(cs, n)
end

"""`Typst.identKw`: the spellings of `KW_CHARS` that are a word, inverted."""
const IDENT_KW = Dict{String, Kw}(w => k for (k, w) in KW_CHARS if all(isletter, w))

"""`Typst.quotedArg`: `("…")` after a function name."""
function quoted_arg(r::Chars)
    at(r) == '(' || return nothing
    x = DStrings.parse_quoted(true, drop(r))
    (x !== nothing && at(x[2]) == ')') || return nothing
    return x[1], drop(x[2])
end

"""`Typst.pieces`: adjacent `upright("…")` pieces, each with an optional digit
subscript."""
function upright_pieces(cs::Chars)
    out = Tuple{String, String}[]
    while true
        r = drop_p("upright", cs)
        r === nothing && return out, cs
        x = quoted_arg(r)
        x === nothing && return out, cs
        s, r1 = x
        d, rest = Char[], r1
        if at(r1) == '_'
            q, r3 = dig_run(drop(r1))
            if !isempty(q)
                d, rest = collect(q), r3
            end
        end
        push!(out, (s, String(d)))
        cs = rest
    end
    return out, cs
end

"""`Typst.isWsT`."""
is_ws_t(c::Char) = c == ' ' || c == '\n' || c == '\t' || c == '\r'

function skip(cs::Chars)
    n = 0
    while is_ws_t(at(cs, n + 1))
        n += 1
    end
    return drop(cs, n)
end

"""`Typst.sciExp`: the scientific tail `times 10^exponent` after a mantissa (the
exponent bare or in parentheses), with any white space between its parts."""
function sci_exp(r::Chars)
    r1 = drop_p("times", skip(r))
    r1 === nothing && return nothing
    is_id_c(at(r1)) && return nothing
    r2 = drop_p("10", skip(r1))
    r2 === nothing && return nothing
    r3 = skip(r2)
    at(r3) == '^' || return nothing
    r4 = skip(drop(r3))
    if at(r4) == '('
        x = DNumber.parse_int(skip(drop(r4)))
        x === nothing && return nothing
        z, r5 = x
        r6 = skip(r5)
        at(r6) == ')' || return nothing
        return z, drop(r6)
    end
    return DNumber.parse_int(r4)
end

# The one-character spellings of `KW_CHARS`, inverted, except `(`: both `KLp` and
# `KLpg` print it, and the lexer reads it itself. `.` is `KSdot`, which prints
# quoted.
const PUNCT = let d = Dict{Char, Kw}(only(w) => k for (k, w) in KW_CHARS if length(w) == 1 && w != "(")
    d['.'] = KSdot
    d
end

"""`Typst.punct`."""
punct(c::Char) = get(PUNCT, c, nothing)

"""`Typst.uprightE`: `upright(e)`, Euler's number written without quotes."""
function upright_e(cs::Chars)
    r = strip_prefix(cs, "(e)")
    return r === nothing ? nothing : (TUps([("e", "")]), r)
end

"""`Typst.lexIdent`: one identifier-started token."""
function lex_ident(cs::Chars)
    w, rest = id_run(cs)
    ws = String(w)
    if ws == "upright"
        q = upright_e(rest)
        q !== nothing && return q
        ps, r = upright_pieces(cs)
        isempty(ps) && return nothing
        return TUps(ps), r
    elseif ws == "italic"
        x = quoted_arg(rest)
        return x === nothing ? nothing : (TIt(x[1]), x[2])
    elseif ws == "op"
        x = quoted_arg(rest)
        return x === nothing ? nothing : (TOpn(x[1]), x[2])
    elseif ws == "thin"
        at(rest) == ' ' || return nothing
        x = MUnits.p_sep_by(MUnits.p_t_factor, MUnits.THIN_SEP, drop(rest))
        return x === nothing ? nothing : (TUnits(x[1]), x[2])
    elseif ws == "esm"
        r = drop_p(".node", rest)
        return r === nothing ? nothing : (TKw(KEsmnode), r)
    end
    k = get(IDENT_KW, ws, nothing)
    k !== nothing && return TKw(k), rest
    is_greek(ws) && return TGreek(ws), rest
    length(w) == 1 && return TLetter(w[1]), rest
    return TWord(ws), rest
end

"""`Typst.lexOne`: one token at the front of the input; `prev` is the character
just before it, if no space came between (`nothing` otherwise)."""
function lex_one(prev, cs::Chars)
    c = at(cs)
    c == EOFC && return nothing
    if c == '('
        if prev !== nothing && (is_id_c(prev) || prev == ')' || prev == '"')
            return TKw(KLp), drop(cs)
        end
        return TKw(KLpg), drop(cs)
    elseif c == '"'
        x = DStrings.parse_quoted(true, cs)
        x === nothing && return nothing
        s, r = x
        return (s == "." ? TKw(KSdot) : TTxt(s)), r
    elseif c == '#'
        x = DTypstDict.p_val(drop(cs))
        return x === nothing ? nothing : (TCode(x[1]), x[2])
    elseif c == '<' && at(cs, 2) == '='
        return TKw(KLe), drop(cs, 2)
    elseif c == '>' && at(cs, 2) == '='
        return TKw(KGe), drop(cs, 2)
    elseif c == '!' && at(cs, 2) == '='
        return TKw(KNe), drop(cs, 2)
    end
    r = drop(cs)
    if is_dig(c) || (c == '-' && is_dig(at(r)))
        return lex_signed(sci_exp, cs)
    elseif is_letter(c)
        return lex_ident(cs)
    end
    k = punct(c)
    return k === nothing ? nothing : (TKw(k), r)
end

"""`Typst.lex`: read Typst math into tokens (`lexAux`)."""
function lex(cs::Chars)
    out = Tok[]
    prev = nothing
    while true
        prev2 = is_ws_t(at(cs)) ? nothing : prev
        cs2 = skip(cs)
        isempty(cs2) && return out
        x = lex_one(prev2, cs2)
        x === nothing && return nothing
        t, r = x
        tcs = tok_chars(t)
        prev = isempty(tcs) ? nothing : last(tcs)
        push!(out, t)
        cs = r
    end
    return out
end

end # module MTypst
