"""
The printer: expressions to tokens.

Port of `formal/Esm/Document/Math/Print.lean` (Rust `document::math::print`).
[`pr`](@ref) prints an expression with its precedence level;
[`out_at`](@ref) wraps it for a position that needs a level at least `L`. The
levels, loosest first (spec §4.1.1):

| level | construct |
|---|---|
| 1 | `or` chain |
| 2 | `and` chain |
| 3 | a comparison |
| 4 | `+` chain, binary `-` |
| 5 | `*` chain, unary `-` |
| 6 | `not`; a derivative applied to a parenthesized operand; a `\\nabla` form (its operand at level 9) |
| 7 | Typst fraction; a negative literal and a quantity |
| 8 | power |
| 9 | index |
| 10 | atoms |

Which notation a node gets is decided from its exact JSON shape; anything
without a native or call notation prints in the generic escape form.
"""
module MPrint

using ..DJson
using ..MToken
using ..MUnits: Factor
import ..MUnits
import ..DNumber
import ..DStrings
using ..MExpr: DEPRECATED_OPS, REMOVED_OPS, Sym, is_e, is_formula, is_id_char, is_id_start, is_single,
    keys_sorted, name_ok, pieces, seg_ok, split_dots, sub_parts, num_ok

# The package the document module sits in: its unit grammar reads a units
# string's factors (`factors_of`) and spells them.
const HOST = parentmodule(parentmodule(@__MODULE__))

kw(k::Kw) = TKw(k)

"""Concatenate token lists into a fresh `Vector{Tok}`."""
function tc(parts...)
    out = Tok[]
    for p in parts
        append!(out, p)
    end
    return out
end

const s_of = str_of

# ## Text pieces

"""`Math.escSet`: the characters escaped by a backslash inside `\\mathit{}`,
`\\operatorname{}`, `\\esm{}` and a name subscript's `\\mathrm{}`."""
esc_set(c::Char) = c == '_' || c == '^' || c == '\\' || c == '{' || c == '}'

"""`Math.escT`: escape the text of `\\mathit{}` and the like."""
function esc_t(cs)
    out = Char[]
    for c in cs
        esc_set(c) && push!(out, '\\')
        push!(out, c)
    end
    return out
end

"""`Math.unescT`: undo [`esc_t`](@ref) (drop the backslash of every `\\c`
pair)."""
function unesc_t(cs)
    v = collect(Char, cs)
    out = Char[]
    i = 1
    n = length(v)
    while i <= n
        if v[i] == '\\' && i < n
            push!(out, v[i + 1])
            i += 2
        else
            push!(out, v[i])
            i += 1
        end
    end
    return out
end

"""`Math.keySpecial`."""
key_special(c::Char) = c in ('$', '%', '&', '#', '~', '^', '\\')

"""`Math.dig3`: three decimal digits."""
dig3(n::Integer) = (
    DNumber.digit_char(n ÷ 100 % 10), DNumber.digit_char(n ÷ 10 % 10),
    DNumber.digit_char(n % 10),
)

"""`Math.escK`: escape a field key for `\\mathrm{}`."""
function esc_k(cs)
    out = Char[]
    for c in cs
        if key_special(c)
            append!(out, "{\\char")
            push!(out, dig3(UInt32(c))...)
            push!(out, '}')
        elseif c == '_' || c == '{' || c == '}'
            push!(out, '\\', c)
        else
            push!(out, c)
        end
    end
    return out
end

"""`Number.charDigit`: `c.toNat - 48`, saturating (any character, not only a
digit)."""
char_digit_nat(c::Char) = UInt64(max(Int64(UInt32(c)) - 48, 0))

"""Lean's `Char.ofNat`: an invalid code point is `'\\0'` (`DStrings.char_of`)."""
const char_of_nat = DStrings.char_of

"""`Math.unescK`: undo [`esc_k`](@ref)."""
function unesc_k(cs)
    v = view(collect(Char, cs), :)
    out = Char[]
    while !isempty(v)
        if starts(v, "{\\char") && length(v) >= 10 && v[10] == '}'
            push!(
                out, char_of_nat(
                    100 * char_digit_nat(v[7]) + 10 * char_digit_nat(v[8]) + char_digit_nat(v[9])
                )
            )
            v = drop(v, 10)
        elseif v[1] == '\\' && length(v) >= 2
            push!(out, v[2])
            v = drop(v, 2)
        else
            push!(out, v[1])
            v = drop(v, 1)
        end
    end
    return out
end

# ## The printing context

"""`Math.Ctx`: the surface and the symbol table."""
struct Ctx
    sf::Sf
    s::Sym
end

"""`Math.rpG`: the closing token of a grouping parenthesis."""
rp_g(sf::Sf) = kw(sf == SF_LATEX ? KRpg : KRp)

"""`Math.grp`: grouping parentheses."""
grp(sf::Sf, ts) = tc((kw(KLpg),), ts, (rp_g(sf),))

"""`Math.sepBy`: items joined by a separator."""
function sep_by(sep, xs)
    out = Tok[]
    for (i, x) in enumerate(xs)
        i > 1 && append!(out, sep)
        append!(out, x)
    end
    return out
end

# ## Names

"""`Math.baseTok`: a single letter or a Greek name as a token."""
function base_tok(g)
    cs = collect(Char, g)
    return length(cs) == 1 ? TLetter(cs[1]) : TGreek(String(cs))
end

"""`Math.subTxt`: the subscript text of a name, upright."""
function sub_txt(sf::Sf, r)
    if sf == SF_LATEX
        return Tok[kw(KUs), kw(KLb), TRm(s_of(esc_t(r))), kw(KRb)]
    end
    return Tok[kw(KUs), kw(KLpg), TUps([(s_of(r), "")]), kw(KRp)]
end

"""`Math.formulaRaw`: the raw `\\mathrm{}` content of a formula (counts as
`_{n}`)."""
function formula_raw(g)
    out = Char[]
    for (a, b) in pieces(g)
        append!(out, a)
        if !isempty(b)
            push!(out, '_', '{')
            append!(out, b)
            push!(out, '}')
        end
    end
    return out
end

"""`Math.formTok`: a formula name."""
function form_tok(sf::Sf, g)
    sf == SF_LATEX && return TRm(s_of(formula_raw(g)))
    return TUps([(s_of(a), s_of(b)) for (a, b) in pieces(g)])
end

"""`Math.segToks`: one segment of a name, by its shape."""
function seg_toks(sf::Sf, g)
    is_single(g) && return Tok[base_tok(g)]
    sp = sub_parts(g)
    if sp !== nothing
        b, r = sp
        return tc((base_tok(b),), sub_txt(sf, r))
    end
    is_formula(g) && return Tok[form_tok(sf, g)]
    return Tok[TIt(s_of(g))]
end

"""`Math.explicitName`: an undeclared `e` or `d` prints in the explicit form."""
explicit_name(s::Sym, n::AbstractString) = (n == "e" || n == "d") && !(n in s.names)

"""`Math.nameToks`: the tokens of a name."""
function name_toks(c::Ctx, s::AbstractString)
    explicit_name(c.s, s) && return Tok[TIt(String(s))]
    return sep_by((kw(KSdot),), [seg_toks(c.sf, g) for g in split_dots(collect(Char, s))])
end

"""`Math.plainLast`: the last segment of a name prints with no subscript."""
function plain_last(s::AbstractString)
    segs = split_dots(collect(Char, s))
    isempty(segs) && return false
    g = last(segs)
    return is_single(g) || (sub_parts(g) === nothing && !is_formula(g))
end

# ## JSON inside escape nodes (LaTeX)

"""`Math.jsonToks`."""
json_toks(j) = json_toks_into(j, Tok[])

function json_toks_into(j, out::Vector{Tok})
    if j isa JNull
        push!(out, TWord("null"))
    elseif j === true
        push!(out, TWord("true"))
    elseif j === false
        push!(out, TWord("false"))
    elseif j isa JNum
        push!(out, TNum(j))
    elseif j isa String
        push!(out, TJstr(j))
    elseif j isa JArr
        push!(out, kw(KLbk))
        for (i, x) in enumerate(j.xs)
            i > 1 && push!(out, kw(KComma))
            json_toks_into(x, out)
        end
        push!(out, kw(KRbk))
    elseif j isa JObj
        push!(out, kw(KLb))
        for (i, (k, v)) in enumerate(j.kvs)
            i > 1 && push!(out, kw(KComma))
            push!(out, TJstr(k))
            push!(out, kw(KColon))
            json_toks_into(v, out)
        end
        push!(out, kw(KRb))
    end
    return out
end

# ## Operator tables

"""`Math.fnKw`: unary functions with a native spelling, and their keyword."""
const FN_KW = (
    ("exp", KExp), ("log", KLn), ("sin", KSin), ("cos", KCos), ("tan", KTan),
    ("asin", KAsin), ("acos", KAcos), ("atan", KAtan), ("sinh", KSinh), ("cosh", KCosh),
    ("tanh", KTanh),
)

"""`Math.cmpKw`: comparisons and their token."""
const CMP_KW = (("<", KLt), ("<=", KLe), (">", KGt), (">=", KGe), ("==", KEq), ("!=", KNe))

"""`Math.callOps`: core operators in the call form."""
const CALL_OPS = ("sign", "atan2", "asinh", "acosh", "atanh", "Pre", "enum")

"""`Math.fieldCallOps`: core operators with no notation of their own that print
in the call form, their fields as named arguments after `;` (when no field
annotates the node)."""
const FIELD_CALL_OPS =
    ("broadcast", "reshape", "transpose", "concat", "faq", "makearray", "const")

"""`Math.reservedOpn`: names `\\operatorname{…}` never means a template or an
open operator by."""
reserved_opn(n::AbstractString) =
    n in CALL_OPS || n == "D" || n in DEPRECATED_OPS || n in REMOVED_OPS

"""`Math.coreOps` (`coreOpNames` of `Notation`)."""
const CORE_OPS = Set{String}(
    [
        "+", "-", "*", "/", "^", "pow", "neg", "<", "<=", ">", ">=", "==", "!=", "and", "or",
        "not", "true", "false", "ifelse", "exp", "log", "log10", "sqrt", "abs", "sign", "floor",
        "ceil", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh",
        "acosh", "atanh", "atan2", "min", "max", "D", "ic", "Pre", "enum", "const", "faq",
        "makearray", "index", "broadcast", "reshape", "transpose", "concat",
        "apply_operator",
    ]
)

"""`Math.opnOK`: a name `\\operatorname{…}` can carry: identifier characters and
dots."""
function opn_ok(s::AbstractString)
    isempty(s) && return false
    c = first(s)
    is_id_start(c) || return false
    for (i, d) in enumerate(s)
        i == 1 && continue
        (is_id_char(d) || d == '.') || return false
    end
    return true
end

"""`Math.annotKeys`: the fields that annotate a node
(`Notation.annotatedNodeFields`): the package's
`EXPRESSION_NODE_ANNOTATIONS`."""
const ANNOT_KEYS = HOST.EXPRESSION_NODE_ANNOTATIONS

"""`Math.callFormOK`: an operator prints in the call form: an open operator, or
a core operator of `fieldCallOps` none of whose fields annotates it."""
call_form_ok(o::AbstractString, fs) =
    !(o in CORE_OPS) || (o in FIELD_CALL_OPS && all(kv -> !(kv.first in ANNOT_KEYS), fs))

"""`Math.mathKeys`: the fields of a core operator in the call form that hold an
expression; the others print as JSON, even a string that is a name."""
const MATH_KEYS = ("expr", "filter", "key")

"""`Math.mathField`: a field of a call-form node prints as math: its value is
an expression and, for a core operator, the field holds one. An open operator's
fields are all read as math when they can be."""
math_field(o::AbstractString, kv::Pair) =
    is_e(kv.second) && (!(o in CORE_OPS) || kv.first in MATH_KEYS)

"""`Math.keyOK`: a field key printed upright in a call: an identifier."""
key_ok(s::AbstractString) = seg_ok(collect(Char, s))

"""`Math.insKV`: sorted insertion by key."""
function ins_kv(kv::Pair, l)
    kv = Pair{String, Any}(kv.first, kv.second)
    l = Kvs(l)
    i = findfirst(e -> kv.first < e.first, l)
    insert!(l, i === nothing ? length(l) + 1 : i, kv)
    return l
end

"""`Math.fieldsOf`: the fields of a node other than `op` and `args`."""
fields_of(kvs) = Kvs([kv for kv in kvs if kv.first != "op" && kv.first != "args"])

"""`Math.mkNode`: a node from its operator, operands and other fields."""
mk_node(o::AbstractString, args::Vector{Any}, fs) =
    JObj(ins_kv("args" => JArr(args), ins_kv("op" => String(o), fs)))

"""`Math.node`: the plain two-field node."""
node(o::AbstractString, args::Vector{Any}) = JObj(Kvs(["args" => JArr(args), "op" => String(o)]))

"""`Math.isNegNum`."""
is_neg_num(j) = (j isa JInt && j.z < 0) || (j isa JDec && j.neg)

"""`Math.simpleTok`: Typst exponent and subscript tokens that need no
parentheses."""
function simple_tok(t::Tok)
    if t isa TNum
        n = t.n
        n isa JInt && return 0 <= n.z
        return !n.neg && -4 <= n.e10 <= 5
    end
    return t isa TLetter || t isa TGreek
end

"""`Math.startsNum`."""
starts_num(ts) = !isempty(ts) && first(ts) isa TNum

"""`Math.tparams`: the template parameter list, when the symbol table knows
it."""
function tparams(s::Sym, n::AbstractString)
    for t in s.templates
        t[1] == n && return t[2]
    end
    return nothing
end

function nodup(xs)
    for i in eachindex(xs), j in 1:(i - 1)
        xs[j] == xs[i] && return false
    end
    return true
end

"""`Math.positional`: positional template arguments."""
function positional(s::Sym, n::AbstractString, bs)
    ps = tparams(s, n)
    ps === nothing && return nothing
    if nodup(ps) && length(ps) == length(bs) && all(p -> look(p, bs) !== nothing, ps)
        return copy(ps)
    end
    return nothing
end

"""`Math.rawB`: balanced text up to the `}` that closes depth 0; `\\x` is one
unit. The text and the rest after the `}`, or `nothing`."""
function raw_b(d::Integer, cs::Chars)
    out = Char[]
    while true
        c = at(cs)
        if c == '\\' && length(cs) >= 2
            push!(out, '\\', cs[2])
            cs = drop(cs, 2)
        elseif c == '}'
            d == 0 && return out, drop(cs)
            d -= 1
            push!(out, '}')
            cs = drop(cs)
        elseif c == '{'
            d += 1
            push!(out, '{')
            cs = drop(cs)
        elseif !isempty(cs)
            push!(out, c)
            cs = drop(cs)
        else
            return nothing
        end
    end
    return nothing
end

"""`Math.balOK`: raw text that [`raw_b`](@ref) reads back whole."""
function bal_ok(raw)
    cs = vcat(collect(Char, raw), '}')
    x = raw_b(0, cs)
    return x !== nothing && x[1] == collect(Char, raw) && isempty(x[2])
end

"""`Math.factorsOf`: the two-sided factor list of a units string (`[]` when it
does not parse): the parse's factors normalized per side (`Esm.Units.norm2`),
positive exponents first."""
function factors_of(u::AbstractString)
    isempty(u) && return Factor[]
    l = HOST._canonical_unit_factors(u)
    return l === nothing ? Factor[] : l
end

"""`Esm.Units.spell`: the canonical spelling of a factor list."""
spell_unit_factors(l) = HOST._spell_unit_factors(l)

"""`Math.unitsOK`: the units of a quantity print typeset."""
function units_ok(sf::Sf, u::AbstractString)
    l = factors_of(u)
    isempty(l) && return false
    spell_unit_factors(l) == u || return false
    all(f -> MUnits.sym_ok(f[1]) && !iszero(f[2]), l) || return false
    if sf == SF_LATEX
        return MUnits.parse_latex(MUnits.latex(l)) == l && bal_ok(MUnits.latex_body(l))
    end
    return vcat(MUnits.num_factors(l), MUnits.den_factors(l)) == l
end

# ## The printer

"""`Math.wrap`: wrap a printed form for a position needing level `L`."""
wrap(sf::Sf, l::Int, lvl::Int, ts) = l <= lvl ? collect(Tok, ts) : grp(sf, ts)

"""`Math.mulToks`: a `*` chain: juxtaposition, `\\cdot` before a factor that
starts with a number."""
function mul_toks(xs)
    out = Tok[]
    for (i, y) in enumerate(xs)
        (i > 1 && starts_num(y)) && push!(out, kw(KCdot))
        append!(out, y)
    end
    return out
end

"""`Math.OpK`: the printer kind of a plain node's operator: a tag and, for
`Cmp`, `Un` and `Mm`, the keyword."""
struct OpK
    tag::Symbol
    k::Union{Kw, Nothing}
end
OpK(tag::Symbol) = OpK(tag, nothing)

"""`Math.unKw`: unary functions with a native spelling (`log10` is
`\\log_{10}`)."""
function un_kw(o::AbstractString)
    for (n, k) in FN_KW
        n == o && return k
    end
    for (n, k) in (("log10", KLog), ("sqrt", KSqrt), ("abs", KAbs), ("floor", KFloor), ("ceil", KCeil))
        n == o && return k
    end
    return nothing
end

"""`Math.kindTable`: the plain-node operators with their own notation."""
const KIND_TABLE = (
    ("-", OpK(:Minus)), ("/", OpK(:Div)), ("^", OpK(:Pow)), ("not", OpK(:Lnot)),
    ("true", OpK(:Tru)), ("false", OpK(:Fls)), ("ifelse", OpK(:Ite)), ("ic", OpK(:Ic)),
    ("index", OpK(:Index)), ("+", OpK(:Plus)), ("*", OpK(:Times)), ("and", OpK(:Land)),
    ("or", OpK(:Lor)), ("min", OpK(:Mm, KMin)), ("max", OpK(:Mm, KMax)),
    ("grad", OpK(:Nab)), ("div", OpK(:Nab)), ("laplacian", OpK(:Nab)), ("curl", OpK(:Nab)),
)

"""`Math.kindOf`."""
function kind_of(o::AbstractString)
    for (n, k) in CMP_KW
        n == o && return OpK(:Cmp, k)
    end
    k = un_kw(o)
    k !== nothing && return OpK(:Un, k)
    for (n, kk) in KIND_TABLE
        n == o && return kk
    end
    return o in CALL_OPS ? OpK(:Call) : OpK(:Other)
end

"""`Math.Out`: the printed form of an expression and its level. `crow` is the
form as the last rows of a `cases` block."""
struct Out
    lvl::Int
    toks::Vector{Tok}
    crow::Vector{Tok}
end

"""`Math.mkOut`."""
function mk_out(l::Int, t::Vector{Tok})
    crow = copy(t)
    push!(crow, kw(KAmp), TTxt("otherwise"))
    return Out(l, t, crow)
end

"""`Math.Out.at`."""
out_at(o::Out, sf::Sf, l::Int) = wrap(sf, l, o.lvl, o.toks)

"""`Math.escToks`: the escape form: LaTeX `\\esm{op}{fields}{args}`, Typst
`esm.node("op", #(fields), args)`."""
function esc_toks(sf::Sf, o::AbstractString, fs::Kvs, args)
    if sf == SF_LATEX
        out = Tok[TEsc(String(o)), kw(KLb)]
        append!(out, json_toks(JObj(fs)))
        push!(out, kw(KRb), kw(KLb))
        append!(out, sep_by((kw(KComma),), args))
        push!(out, kw(KRb))
        return out
    end
    out = Tok[kw(KEsmnode), kw(KLp), TTxt(String(o)), kw(KComma), TCode(JObj(fs))]
    for a in args
        push!(out, kw(KComma))
        append!(out, a)
    end
    push!(out, kw(KRp))
    return out
end

"""`Math.lpC`: the call parenthesis."""
lp_c(::Sf) = kw(KLp)

"""`Math.callToks`: `name(args)` with call parentheses."""
function call_toks(sf::Sf, head, args)
    out = collect(Tok, head)
    push!(out, lp_c(sf))
    append!(out, sep_by((kw(KComma),), args))
    push!(out, kw(KRp))
    return out
end

"""`Math.unToks`: a unary function applied to the printed operand `t`."""
function un_toks(sf::Sf, k::Kw, t)
    if sf == SF_LATEX
        k == KSqrt && return tc((kw(KSqrt), kw(KLb)), t, (kw(KRb),))
        k == KAbs && return tc((kw(KLabs),), t, (kw(KRabs),))
        k == KFloor && return tc((kw(KLfloor),), t, (kw(KRfloor),))
        k == KCeil && return tc((kw(KLceil),), t, (kw(KRceil),))
        if k == KLog
            out = Tok[kw(KLog), kw(KUs), kw(KLb), TNum(JInt(10)), kw(KRb)]
            append!(out, call_toks(sf, Tok[], [t]))
            return out
        end
    elseif k == KLog
        out = Tok[kw(KLog), kw(KUs), TNum(JInt(10))]
        append!(out, call_toks(sf, Tok[], [t]))
        return out
    end
    return call_toks(sf, Tok[kw(k)], [t])
end

"""`Math.caseRow`: one cases row, `value & \\text{if } condition`, then the row
break."""
function case_row(sf::Sf, v, cnd)
    out = collect(Tok, v)
    push!(out, kw(KAmp), TTxt("if "))
    append!(out, cnd)
    push!(out, kw(sf == SF_LATEX ? KNl : KComma))
    return out
end

"""`Math.casesToks`."""
function cases_toks(sf::Sf, rows)
    sf == SF_LATEX && return tc((kw(KBcases),), rows, (kw(KEcases),))
    return tc((kw(KCases), kw(KLp)), rows, (kw(KRp),))
end

"""`Math.icTail`: `t_{0}` in an initial condition `N(t_{0})`."""
function ic_tail(sf::Sf)
    sf == SF_LATEX &&
        return Tok[kw(KLp), TLetter('t'), kw(KUs), kw(KLb), TNum(JInt(0)), kw(KRb), kw(KRp)]
    return Tok[kw(KLp), TLetter('t'), kw(KUs), TNum(JInt(0)), kw(KRp)]
end

"""`Math.subList`: a subscript list: LaTeX `_{a, b}`; Typst `_a` for one simple
token, else `_(a, b)`."""
function sub_list(sf::Sf, simp, args)
    sf == SF_LATEX && return tc((kw(KUs), kw(KLb)), sep_by((kw(KComma),), args), (kw(KRb),))
    simp !== nothing && return Tok[kw(KUs), simp]
    return tc((kw(KUs), kw(KLpg)), sep_by((kw(KComma),), args), (kw(KRp),))
end

"""`Math.simpleE`: the one token a Typst exponent or subscript may be written as
without parentheses."""
function simple_e(c::Ctx, j)
    if j isa JNum
        t = TNum(j)
        return simple_tok(t) ? t : nothing
    elseif j isa String
        ts = name_toks(c, j)
        (length(ts) == 1 && simple_tok(ts[1])) && return ts[1]
    end
    return nothing
end

"""`Math.simpleArg`."""
simple_arg(c::Ctx, xs) = length(xs) == 1 ? simple_e(c, xs[1]) : nothing

"""`Math.subOK`: the index prints with a subscript."""
function sub_ok(s::Sym, base, is)
    base isa String || return false
    b = base
    (name_ok(b) && plain_last(b) && !explicit_name(s, b)) || return false
    if length(is) == 1 && is[1] isa String
        xc = collect(Char, is[1])
        return !(length(split_dots(xc)) == 1 && is_formula(xc))
    elseif length(is) == 1 && is[1] isa JInt
        n = is[1].z
        nm = string(b, "_", n)
        return !(0 <= n && nm in s.names)
    end
    return true
end

"""`Math.subPat4`: four tokens of an upright name subscript."""
function sub_pat4(sf::Sf, t1, t2, t3, t4)
    if iskw(t1, KUs) && iskw(t2, KLb) && t3 isa TRm && iskw(t4, KRb)
        return sf == SF_LATEX
    end
    if iskw(t1, KUs) && iskw(t2, KLpg) && t3 isa TUps && iskw(t4, KRp) &&
            length(t3.ps) == 1 && isempty(t3.ps[1][2])
        return sf == SF_TYPST
    end
    return false
end

"""`Math.subPat`: an upright name subscript at the front."""
sub_pat(sf::Sf, ts) = length(ts) >= 4 && sub_pat4(sf, ts[1], ts[2], ts[3], ts[4])

"""`Math.inlineD`: derivative operand printed inline."""
inline_d(o::Out) = 9 <= o.lvl

"""`Math.keyToks`: a field key, upright."""
function key_toks(sf::Sf, k::AbstractString)
    sf == SF_LATEX && return Tok[TRm(s_of(esc_k(k)))]
    return Tok[TUps([(String(k), "")])]
end

"""`Math.jsonVal`: a field value that is not an expression, as JSON."""
json_val(sf::Sf, v) = sf == SF_LATEX ? json_toks(v) : Tok[TCode(v)]

"""`Math.openToks`: the open-operator call."""
function open_toks(sf::Sf, o::AbstractString, args, fields)
    out = Tok[TOpn(String(o)), lp_c(sf)]
    append!(out, sep_by((kw(KComma),), args))
    if !isempty(fields)
        push!(out, kw(KSemi))
        append!(out, sep_by((kw(KComma),), fields))
    end
    push!(out, kw(KRp))
    return out
end

"""`Math.dTime`: the time derivative."""
function d_time(sf::Sf, a::Out)
    a1 = out_at(a, sf, 1)
    if sf == SF_LATEX
        if inline_d(a)
            return mk_out(
                10, tc(
                    (kw(KFrac), kw(KLb), TRm("d")), a1,
                    (kw(KRb), kw(KLb), TRm("d"), TLetter('t'), kw(KRb)),
                )
            )
        end
        return mk_out(
            6, tc(
                (kw(KFrac), kw(KLb), TRm("d"), kw(KRb), kw(KLb), TRm("d"), TLetter('t'), kw(KRb)),
                grp(sf, a1),
            )
        )
    end
    if inline_d(a)
        return mk_out(
            7, tc(
                (kw(KLpg), kw(KDif)), a1,
                (kw(KRp), kw(KSlash), kw(KLpg), kw(KDif), TLetter('t'), kw(KRp)),
            )
        )
    end
    return mk_out(
        6, tc(
            (kw(KLpg), kw(KDif), kw(KRp), kw(KSlash), kw(KLpg), kw(KDif), TLetter('t'), kw(KRp)),
            grp(sf, a1),
        )
    )
end

"""`Math.dSpace`: `partial` with one operand, along the axis printed `w`."""
function d_space(sf::Sf, w, a::Out)
    a1 = out_at(a, sf, 1)
    if sf == SF_LATEX
        if inline_d(a)
            return mk_out(
                10, tc(
                    (kw(KFrac), kw(KLb), kw(KPdiff)), a1, (kw(KRb), kw(KLb), kw(KPdiff)), w,
                    (kw(KRb),),
                )
            )
        end
        return mk_out(
            6, tc(
                (kw(KFrac), kw(KLb), kw(KPdiff), kw(KRb), kw(KLb), kw(KPdiff)), w, (kw(KRb),),
                grp(sf, a1),
            )
        )
    end
    if inline_d(a)
        return mk_out(
            7, tc(
                (kw(KLpg), kw(KPdiff)), a1, (kw(KRp), kw(KSlash), kw(KLpg), kw(KPdiff)), w,
                (kw(KRp),),
            )
        )
    end
    return mk_out(
        6, tc(
            (kw(KLpg), kw(KPdiff), kw(KRp), kw(KSlash), kw(KLpg), kw(KPdiff)), w, (kw(KRp),),
            grp(sf, a1),
        )
    )
end

"""`Math.dCall`: `partial` with trailing operands: `\\partial_{x}(u, a, b)` /
`partial_(x)(u, a, b)`."""
function d_call(sf::Sf, w, args)
    open = sf == SF_LATEX ? KLb : KLpg
    close = sf == SF_LATEX ? KRb : KRp
    out = Tok[kw(KPdiff), kw(KUs), kw(open)]
    append!(out, w)
    push!(out, kw(close))
    append!(out, call_toks(sf, Tok[], args))
    return out
end

"""`Math.nabHead`: what a `\\nabla` form writes before its operand (`o` is `grad`,
`div`, `laplacian` or `curl`): `\\nabla`, `\\nabla \\cdot`, `\\nabla^{2}`, `\\nabla \\times`
(Typst `nabla`, `nabla dot`, `nabla^2`, `nabla times`)."""
function nab_head(sf::Sf, o::AbstractString)
    o == "grad" && return Tok[kw(KNabla)]
    o == "div" && return Tok[kw(KNabla), kw(KCdot)]
    o == "curl" && return Tok[kw(KNabla), kw(KTimes)]
    sf == SF_LATEX && return Tok[kw(KNabla), kw(KCaret), kw(KLb), TNum(JInt(2)), kw(KRb)]
    return Tok[kw(KNabla), kw(KCaret), TNum(JInt(2))]
end

"""`Math.nabArg`: the operand of a `\\nabla` form: another `\\nabla` form as it is
(`\\nabla \\cdot \\nabla u` is `div(grad(u))`), anything else at the level of a power
base; after the `\\times` of a curl, an operand that starts with a number in
parentheses (`Math.nabArg9`)."""
function nab_arg(sf::Sf, o::AbstractString, a::Out)
    if !isempty(a.toks) && iskw(a.toks[1], KNabla) && 6 <= a.lvl
        return a.toks
    end
    t = out_at(a, sf, 9)
    return (o == "curl" && starts_num(t)) ? grp(sf, t) : t
end

"""`Math.qtyToks`: the quantity: the number, then the unit as one token."""
qty_toks(n::JNum, l::Vector{Factor}) = Tok[TNum(n), TUnits(l)]

# ## Constant arrays

"""`Math.numsOf`: the entries of a list that are all well-formed numbers."""
function nums_of(xs)
    out = JNum[]
    for x in xs
        (x isa JNum && num_ok(x)) || return nothing
        push!(out, x)
    end
    return out
end

"""`Math.rowsOf`: the rows of a list of number lists."""
function rows_of(xs)
    out = Vector{Vector{JNum}}()
    for x in xs
        x isa JArr || return nothing
        r = nums_of(x.xs)
        r === nothing && return nothing
        push!(out, r)
    end
    return out
end

"""`Math.AForm`: the two array shapes with a native spelling: `:col` with
`ns::Vector{JNum}`, or `:mat` with `rs::Vector{Vector{JNum}}`."""
struct AForm
    tag::Symbol
    ns::Vector{JNum}
    rs::Vector{Vector{JNum}}
end

"""`Math.arrForm`: a constant array printed natively."""
function arr_form(j)
    j isa JArr || return nothing
    xs = j.xs
    ns = nums_of(xs)
    if ns !== nothing
        isempty(ns) || return AForm(:col, ns, Vector{JNum}[])
        return nothing
    end
    rs = rows_of(xs)
    (rs === nothing || isempty(rs)) && return nothing
    r = rs[1]
    if 2 <= length(r) && all(q -> length(q) == length(r), @view rs[2:end])
        return AForm(:mat, JNum[], rs)
    end
    return nothing
end

"""`Math.numToks`."""
num_toks(ns) = [Tok[TNum(n)] for n in ns]

"""`Math.bmatCols`: the most columns a LaTeX `bmatrix` has (amsmath's
`MaxMatrixCols`); a wider matrix is an `array` with one `c` per column."""
const BMAT_COLS = 10

"""`Math.arrToks`: LaTeX `bmatrix` (`\\left[\\begin{array}{c…c} … \\end{array}\\right]`
when wider than `BMAT_COLS`), Typst `vec(…)` / `mat(…)`."""
function arr_toks(sf::Sf, a::AForm)
    if a.tag === :col
        sf == SF_LATEX && return tc((kw(KBmat),), sep_by((kw(KNl),), num_toks(a.ns)), (kw(KEmat),))
        return tc((kw(KVec), kw(KLp)), sep_by((kw(KComma),), num_toks(a.ns)), (kw(KRp),))
    end
    if sf == SF_LATEX
        rows = sep_by((kw(KNl),), [sep_by((kw(KAmp),), num_toks(r)) for r in a.rs])
        n = length(a.rs[1])
        n <= BMAT_COLS && return tc((kw(KBmat),), rows, (kw(KEmat),))
        return tc((kw(KLbkg), TArrCols(n)), rows, (kw(KEarr), kw(KRbkg)))
    end
    return tc(
        (kw(KMat), kw(KLp)),
        sep_by((kw(KSemi),), [sep_by((kw(KComma),), num_toks(r)) for r in a.rs]),
        (kw(KRp),),
    )
end

"""`Math.unitToks`: the unit after a number or an array."""
unit_toks(l::Vector{Factor}) = Tok[TUnits(l)]

# ## Reductions (`faq`)

"""`Math.jbeq`: structural equality of JSON values."""
jbeq(a, b) = a == b

"""`Math.idxBase`: the array an `index` node reads, when it names one."""
function idx_base(kvs)
    o = look("op", kvs)
    xs = look("args", kvs)
    if o isa String && xs isa JArr && o == "index"
        (!isempty(xs.xs) && xs.xs[1] isa String) && return xs.xs[1]
    end
    return nothing
end

"""`Math.basesJ`: the arrays an expression indexes, in first-use order
(appended to `acc`)."""
function bases_j(j, acc::Vector{String})
    if j isa JObj
        s = idx_base(j.kvs)
        (s !== nothing && !(s in acc)) && push!(acc, s)
        for (_, v) in j.kvs
            bases_j(v, acc)
        end
    elseif j isa JArr
        for x in j.xs
            bases_j(x, acc)
        end
    end
    return acc
end

"""`Math.bases`."""
bases(e) = bases_j(e, String[])

"""The native reductions: each one's name, keyword and `reduce` field
(`nothing` for the default sum). `redk_kw`, `redk_field`, `faq_cand`'s reading of
`reduce` and the parser's `red_of` are all read from it."""
const RED_TABLE = ((:sum, KSum, nothing), (:prod, KProd, "*"), (:max, KMax, "max"), (:min, KMin, "min"))

"""`Math.RedK.kw`."""
redk_kw(r::Symbol) = RED_TABLE[findfirst(x -> x[1] === r, RED_TABLE)][2]

"""`Math.RedK.field`."""
function redk_field(r::Symbol)
    f = RED_TABLE[findfirst(x -> x[1] === r, RED_TABLE)][3]
    return f === nothing ? Kvs() : Kvs(["reduce" => f])
end

"""`Math.FaqForm`: a `faq` node with a native spelling, by its parts. `filter`
is `nothing` when absent. `marked`: `args` lists the arrays the body indexes;
otherwise `args` is `set` (empty, or names printed as a superscript set)."""
struct FaqForm
    red::Symbol
    marked::Bool
    out::Vector{Any}
    ranges::Kvs
    expr::Any
    filter::Any
    set::Vector{String}
end

"""`Math.FaqForm.args`: the `args` of a native `faq`."""
faq_args(f::FaqForm) = f.marked ? Any[s for s in bases(f.expr)] : Any[s for s in f.set]

"""`Math.FaqForm.sup`: the names a superscript set shows: `set` when `args` is
not the body's arrays."""
faq_sup(f::FaqForm) = f.marked ? String[] : f.set

"""`Math.faqJson`."""
function faq_json(f::FaqForm)
    kvs = Kvs(["args" => JArr(faq_args(f)), "expr" => f.expr])
    f.filter !== nothing && push!(kvs, "filter" => f.filter)
    push!(kvs, "op" => "faq")
    push!(kvs, "output_idx" => JArr(copy(f.out)))
    isempty(f.ranges) || push!(kvs, "ranges" => JObj(copy(f.ranges)))
    append!(kvs, redk_field(f.red))
    return JObj(kvs)
end

"""`Math.strsOf`: the strings of a list of JSON values, when they are all
strings."""
function strs_of(xs)
    out = String[]
    for x in xs
        x isa String || return nothing
        push!(out, x)
    end
    return out
end

"""`Math.faqCand`: the parts a `faq` node would have."""
function faq_cand(kvs)
    e = look("expr", kvs)
    out = look("output_idx", kvs)
    args = look("args", kvs)
    (e !== nothing && out isa JArr && args isa JArr) || return nothing
    r = look("reduce", kvs)
    i = findfirst(x -> r === nothing ? x[3] === nothing : (x[3] !== nothing && r == x[3]), RED_TABLE)
    i === nothing && return nothing
    red = RED_TABLE[i][1]
    rr = look("ranges", kvs)
    rs = if rr isa JObj
        copy(rr.kvs)
    elseif rr === nothing
        Kvs()
    else
        return nothing
    end
    as = args.xs
    ak = if isempty(as)
        (false, String[])
    elseif jbeq(as, Any[s for s in bases(e)])
        (true, String[])
    else
        st = strs_of(as)
        st === nothing && return nothing
        (false, st)
    end
    return FaqForm(red, ak[1], copy(out.xs), rs, e, look("filter", kvs), ak[2])
end

"""`Math.faqForm`: the parts of a `faq` node, when it is exactly the node they
rebuild."""
function faq_form(kvs)
    f = faq_cand(kvs)
    f === nothing && return nothing
    return jbeq(faq_json(f), JObj(collect(kvs))) ? f : nothing
end

"""`Math.rangeOK`: a range a row can spell."""
function range_ok(j)
    if j isa JArr
        return length(j.xs) == 2 && is_e(j.xs[1]) && is_e(j.xs[2])
    elseif j isa JObj
        kvs = j.kvs
        if length(kvs) == 1 && kvs[1].first == "from" && kvs[1].second isa String
            return name_ok(kvs[1].second)
        elseif length(kvs) == 2 && kvs[1].first == "from" && kvs[1].second isa String &&
                kvs[2].first == "of" && kvs[2].second isa JArr
            ps = kvs[2].second.xs
            return name_ok(kvs[1].second) && !isempty(ps) &&
                all(p -> p isa String && name_ok(p), ps)
        end
        return false
    end
    return false
end

"""`Math.outNames`."""
out_names(out) = String[j for j in out if j isa String]

"""`Math.outOK`: an output entry: a name, or the singleton dimension `1`."""
out_ok(j) = (j isa String && name_ok(j)) || (j isa JInt && j.z == 1)

"""`Math.occursJ`: a bare name occurs in an expression."""
function occurs_j(k::AbstractString, j)
    j isa String && return j == k
    j isa JArr && return any(x -> occurs_j(k, x), j.xs)
    j isa JObj && return any(kv -> occurs_j(k, kv.second), j.kvs)
    return false
end

"""`Math.faqOK`: the conditions under which the native spelling reads back."""
function faq_ok(f::FaqForm)
    names = out_names(f.out)
    is_e(f.expr) || return false
    (f.filter === nothing || is_e(f.filter)) || return false
    all(out_ok, f.out) || return false
    nodup(names) || return false
    all(name_ok, f.set) || return false
    keys_sorted(f.ranges) || return false
    return all(f.ranges) do (k, v)
        name_ok(k) && range_ok(v) &&
            (k in names || occurs_j(k, f.expr) || (f.filter !== nothing && occurs_j(k, f.filter)))
    end
end

"""`Math.rowToks`: a range row: `a \\le k \\le b`, `k \\in S`, `k \\in S(i, j)`."""
function row_toks(c::Ctx, k::AbstractString, v)
    if v isa JArr && length(v.xs) == 2
        return tc(pa(c, 4, v.xs[1]), (kw(KLe),), name_toks(c, k), (kw(KLe),), pa(c, 4, v.xs[2]))
    elseif v isa JObj
        kvs = v.kvs
        if length(kvs) == 1 && kvs[1].first == "from" && kvs[1].second isa String
            return tc(name_toks(c, k), (kw(KInn),), name_toks(c, kvs[1].second))
        elseif length(kvs) == 2 && kvs[1].first == "from" && kvs[1].second isa String &&
                kvs[2].first == "of" && kvs[2].second isa JArr
            return tc(
                name_toks(c, k), (kw(KInn),), name_toks(c, kvs[1].second), (kw(KLp),),
                sep_by(
                    (kw(KComma),),
                    [p isa String ? name_toks(c, p) : Tok[] for p in kvs[2].second.xs]
                ),
                (kw(KRp),),
            )
        end
        return Tok[]
    end
    return Tok[]
end

"""`Math.redRanges`: the ranges of indices that are not output indices."""
function red_ranges(f::FaqForm)
    names = out_names(f.out)
    return Kvs([kv for kv in f.ranges if !(kv.first in names)])
end

"""`Math.subRows`: the rows of the subscript: the reduced ranges, then the
filter."""
function sub_rows(c::Ctx, f::FaqForm)
    rows = Vector{Tok}[row_toks(c, k, v) for (k, v) in red_ranges(f)]
    f.filter !== nothing && push!(rows, pa(c, 1, f.filter))
    return rows
end

"""`Math.headToks`: the operator, marked when `args` is listed."""
function head_toks(sf::Sf, f::FaqForm)
    if sf == SF_LATEX
        out = Tok[kw(redk_kw(f.red))]
        f.marked && push!(out, kw(KLimitsL))
        return out
    end
    f.marked && return Tok[kw(KLimits), kw(KLp), kw(redk_kw(f.red)), kw(KRp)]
    return Tok[kw(redk_kw(f.red))]
end

"""`Math.subToksL`: the LaTeX subscript: none, one row, a lone dense range
`_{k=a}^{b}` (not when `args` is a superscript set), or `\\substack`."""
function sub_toks_l(c::Ctx, f::FaqForm)
    rr = red_ranges(f)
    if length(rr) == 1 && rr[1].second isa JArr && f.filter === nothing &&
            length(rr[1].second.xs) == 2 && isempty(faq_sup(f))
        k = rr[1].first
        ab = rr[1].second.xs
        return tc(
            (kw(KUs), kw(KLb)), name_toks(c, k), (kw(KEq),), pa(c, 4, ab[1]),
            (kw(KRb), kw(KCaret), kw(KLb)), pa(c, 1, ab[2]), (kw(KRb),),
        )
    end
    rows = sub_rows(c, f)
    isempty(rows) && return Tok[]
    length(rows) == 1 && return tc((kw(KUs), kw(KLb)), rows[1], (kw(KRb),))
    return tc(
        (kw(KUs), kw(KLb), kw(KSubstack), kw(KLb)), sep_by((kw(KNl),), rows),
        (kw(KRb), kw(KRb)),
    )
end

"""`Math.subToksT`: the Typst subscript: rows in `_( … )`, stacked with `\\`."""
function sub_toks_t(c::Ctx, f::FaqForm)
    rows = sub_rows(c, f)
    isempty(rows) && return Tok[]
    return tc((kw(KUs), kw(KLpg)), sep_by((kw(KNl),), rows), (kw(KRp),))
end

"""`Math.subToks`."""
sub_toks(c::Ctx, f::FaqForm) = c.sf == SF_LATEX ? sub_toks_l(c, f) : sub_toks_t(c, f)

"""`Math.supToks`: the superscript set of names: LaTeX `^{\\{f, g\\}}`, Typst
`^({f, g})`."""
function sup_toks(c::Ctx, ns)
    body = sep_by((kw(KComma),), [name_toks(c, n) for n in ns])
    c.sf == SF_LATEX && return tc((kw(KCaret), kw(KLb), kw(KLset)), body, (kw(KRset), kw(KRb)))
    return tc((kw(KCaret), kw(KLpg), kw(KLset)), body, (kw(KRset), kw(KRp)))
end

"""`Math.supT`: the `args` set of a `faq`, as a superscript, when it is one."""
sup_t(c::Ctx, f::FaqForm) = isempty(faq_sup(f)) ? Tok[] : sup_toks(c, faq_sup(f))

"""`Math.redToks`: operator, subscript, the superscript set (on the operator
only when there are no output indices), body at level 5."""
red_toks(c::Ctx, f::FaqForm) = tc(
    head_toks(c.sf, f), sub_toks(c, f), isempty(f.out) ? sup_t(c, f) : Tok[], pa(c, 5, f.expr)
)

"""`Math.entryToks`: an output entry: its range row when it has one."""
function entry_toks(c::Ctx, f::FaqForm, j)
    if j isa String
        v = look(j, f.ranges)
        return v !== nothing ? row_toks(c, j, v) : name_toks(c, j)
    end
    return Tok[TNum(JInt(1))]
end

"""`Math.faqOut`: the native `faq`, wrapped with its output indices when it has
some. A superscript set goes on the bracket, before its subscript; the form is
then a power's level (a power of it, or an index into it, is parenthesized: no
double superscript)."""
function faq_out(c::Ctx, f::FaqForm)
    isempty(f.out) && return mk_out(5, red_toks(c, f))
    es = sep_by((kw(KComma),), [entry_toks(c, f, j) for j in f.out])
    sup = sup_t(c, f)
    l = isempty(sup) ? 10 : 8
    if c.sf == SF_LATEX
        return mk_out(
            l, tc(
                (kw(KLbkg),), red_toks(c, f), (kw(KRbkg),), sup, (kw(KUs), kw(KLb)), es,
                (kw(KRb),),
            )
        )
    end
    return mk_out(
        l, tc(
            (kw(KLr), kw(KLp), kw(KLbk)), red_toks(c, f), (kw(KRbk), kw(KRp)), sup,
            (kw(KUs), kw(KLpg)), es, (kw(KRp),),
        )
    )
end

# ## Block assembly (`makearray`)

"""`Math.MkForm`: a `makearray` node with a native spelling, by its parts: the
output indices (empty when the node has no `output_idx`), and the regions
(each a vector of bound pairs) with their values."""
struct MkForm
    out::Vector{String}
    regions::Vector{Vector{Tuple{Any, Any}}}
    values::Vector{Any}
end

"""`Math.regionJson`."""
region_json(r) = JArr(Any[JArr(Any[p[1], p[2]]) for p in r])

"""`Math.mkJson`."""
function mk_json(m::MkForm)
    kvs = Kvs(["args" => JArr(Any[]), "op" => "makearray"])
    isempty(m.out) || push!(kvs, "output_idx" => JArr(Any[o for o in m.out]))
    push!(kvs, "regions" => JArr(Any[region_json(r) for r in m.regions]))
    push!(kvs, "values" => JArr(copy(m.values)))
    return JObj(kvs)
end

"""`Math.pairsOf`: the bound pairs of a region."""
function pairs_of(xs)
    out = Tuple{Any, Any}[]
    for x in xs
        (x isa JArr && length(x.xs) == 2) || return nothing
        push!(out, (x.xs[1], x.xs[2]))
    end
    return out
end

"""`Math.regionsOf`: the regions of a `regions` list."""
function regions_of(xs)
    out = Vector{Tuple{Any, Any}}[]
    for x in xs
        x isa JArr || return nothing
        q = pairs_of(x.xs)
        q === nothing && return nothing
        push!(out, q)
    end
    return out
end

"""`Math.mkCand`: the parts a `makearray` node would have."""
function mk_cand(kvs)
    rs = look("regions", kvs)
    vs = look("values", kvs)
    (rs isa JArr && vs isa JArr) || return nothing
    o = look("output_idx", kvs)
    out = if o === nothing
        String[]
    elseif o isa JArr
        strs_of(o.xs)
    else
        nothing
    end
    out === nothing && return nothing
    regs = regions_of(rs.xs)
    regs === nothing && return nothing
    return MkForm(out, regs, copy(vs.xs))
end

"""`Math.mkForm`: the parts of a `makearray` node, when it is exactly the node
they rebuild: `args` empty, `regions` and `values`, and an `output_idx` of names
or none."""
function mk_form(kvs)
    m = mk_cand(kvs)
    m === nothing && return nothing
    return jbeq(mk_json(m), JObj(collect(kvs))) ? m : nothing
end

"""`Math.mkOK`: the conditions under which the native spelling reads back: one
value per region, at least one region, each region a nonempty list of bound
pairs, values and bounds expressions, output indices names."""
mk_ok(m::MkForm) =
    !isempty(m.values) && length(m.regions) == length(m.values) && all(is_e, m.values) &&
    all(r -> !isempty(r) && all(p -> is_e(p[1]) && is_e(p[2]), r), m.regions) &&
    all(name_ok, m.out)

"""`Math.cellSep`: the cell separator of the table."""
cell_sep(sf::Sf) = sf == SF_LATEX ? KAmp : KComma

"""`Math.rowSep`: the row separator of the table."""
row_sep(sf::Sf) = sf == SF_LATEX ? KNl : KSemi

"""`Math.pairToks`: a bound pair: `a, b` (its brackets are written around it)."""
pair_toks(c::Ctx, p) = tc(pa(c, 1, p[1]), (kw(KComma),), pa(c, 1, p[2]))

"""`Math.regToks`: a region: `[a, b] \\times [c, d]`, one bound pair per
dimension."""
function reg_toks(c::Ctx, r)
    isempty(r) && return Tok[]
    out = tc((kw(KLbk),), pair_toks(c, r[1]), (kw(KRbk),))
    for q in @view r[2:end]
        push!(out, kw(KTimes), kw(KLbk))
        append!(out, pair_toks(c, q))
        push!(out, kw(KRbk))
    end
    return out
end

"""`Math.mkRow`: a row of the table: the value, then the region it fills."""
mk_row(c::Ctx, v, r) = tc(pa(c, 1, v), (kw(cell_sep(c.sf)),), reg_toks(c, r))

"""`Math.matHead`: the Typst table head: `mat(delim: "[", augment: #1,`."""
const MAT_HEAD = (
    TKw(KMat), TKw(KLp), TWord("delim"), TKw(KColon), TTxt("["), TKw(KComma),
    TWord("augment"), TKw(KColon), TCode(JInt(1)), TKw(KComma),
)

"""`Math.mkSub`: the output indices as the bracket's subscript."""
function mk_sub(c::Ctx, out)
    isempty(out) && return Tok[]
    body = sep_by((kw(KComma),), [name_toks(c, o) for o in out])
    c.sf == SF_LATEX && return tc((kw(KUs), kw(KLb)), body, (kw(KRb),))
    return tc((kw(KUs), kw(KLpg)), body, (kw(KRp),))
end

"""`Math.mkOutT`: the native `makearray`: a bracketed two-column table, value
then region, one row per region in order; LaTeX
`\\left[\\begin{array}{l|l} v & [a, b] \\\\ … \\end{array}\\right]`, Typst
`mat(delim: "[", augment: #1, v, [a, b]; …)`; the output indices as its
subscript."""
function mk_out_t(c::Ctx, m::MkForm)
    rows = sep_by((kw(row_sep(c.sf)),), [mk_row(c, v, r) for (v, r) in zip(m.values, m.regions)])
    if c.sf == SF_LATEX
        return mk_out(10, tc((kw(KLbkg), kw(KBarr)), rows, (kw(KEarr), kw(KRbkg)), mk_sub(c, m.out)))
    end
    return mk_out(10, tc(MAT_HEAD, rows, (kw(KRp),), mk_sub(c, m.out)))
end

"""Not in Lean: part of `Math.callCond` (its call-form, name and template
conditions). The operator `o` with the fields `fs` has the call form:
[`call_form_ok`](@ref), a name `\\operatorname` can spell, and no template of
that name in scope."""
call_form_head(c::Ctx, o::AbstractString, fs) =
    call_form_ok(o, fs) && opn_ok(o) && tparams(c.s, o) === nothing

"""Not in Lean: part of `Math.callCond` with `Math.fieldsOK`.
[`pr_opn`](@ref) prints the operator `o` with the fields
`fs` in the call form: [`call_form_head`](@ref) and every key an identifier."""
call_form(c::Ctx, o::AbstractString, fs) =
    call_form_head(c, o, fs) && all(kv -> key_ok(kv.first), fs)

"""`Math.tnameOK`."""
tname_ok(n::AbstractString) = opn_ok(n) && !reserved_opn(n)

# `Math.pr`'s escape-form fallback.
function pr_esc(c::Ctx, kvs)
    o = look("op", kvs)
    args = look("args", kvs)
    if o isa String && args isa JArr
        return mk_out(10, esc_toks(c.sf, o, fields_of(kvs), [pa(c, 1, a) for a in args.xs]))
    end
    return mk_out(10, Tok[])
end

# `Math.pr`'s open-operator fallback.
function pr_opn(c::Ctx, kvs)
    sf = c.sf
    o = look("op", kvs)
    args = look("args", kvs)
    if o isa String && args isa JArr
        fs = fields_of(kvs)
        if call_form(c, o, fs)
            return mk_out(
                10, open_toks(
                    sf, o, [pa(c, 4, a) for a in args.xs],
                    [
                        tc(
                            key_toks(sf, kv.first), (kw(KEq),),
                            math_field(o, kv) ? pa(c, 4, kv.second) : json_val(sf, kv.second),
                        ) for kv in fs
                    ],
                )
            )
        end
        return pr_esc(c, kvs)
    end
    return pr_esc(c, kvs)
end

"""`Math.pr`: the printer."""
function pr(c::Ctx, e)
    sf = c.sf
    if e isa JNum
        return mk_out(is_neg_num(e) ? 7 : 10, Tok[TNum(e)])
    elseif e isa String
        return mk_out(10, name_toks(c, e))
    elseif !(e isa JObj)
        return mk_out(10, Tok[])
    end
    kvs = e.kvs
    field(i, k) = (i <= length(kvs) && kvs[i].first == k) ? kvs[i].second : nothing
    str_at(i, k, v) = (x = field(i, k); x isa String && x == v)
    empty_args() = (x = field(1, "args"); x isa JArr && isempty(x.xs))
    n = length(kvs)
    if n == 2
        args, o = field(1, "args"), field(2, "op")
        if args isa JArr && o isa String
            return pr_plain(c, o, args.xs, kvs)
        end
    elseif n == 3
        args, w = field(1, "args"), field(3, "wrt")
        if args isa JArr && str_at(2, "op", "D") && w isa String
            as = args.xs
            (length(as) == 1 && w == "t") && return d_time(sf, pr(c, as[1]))
            return pr_esc(c, kvs)
        elseif args isa JArr && str_at(2, "op", "partial") && w isa String
            as = args.xs
            if length(as) == 1
                (w != "t" && name_ok(w)) && return d_space(sf, name_toks(c, w), pr(c, as[1]))
                return pr_opn(c, kvs)
            elseif length(as) >= 2
                if w != "t" && name_ok(w)
                    return mk_out(10, d_call(sf, name_toks(c, w), [pa(c, 4, x) for x in as]))
                end
                return pr_opn(c, kvs)
            end
            return pr_opn(c, kvs)
        end
    elseif n == 4
        if empty_args()
            bs, nm = field(2, "bindings"), field(3, "name")
            if bs isa JObj && nm isa String && str_at(4, "op", "apply_operator")
                return pr_template(c, nm, bs.kvs, kvs)
            end
        end
    end
    q = const_out(sf, kvs)
    q !== nothing && return q
    f = native_faq(kvs)
    f !== nothing && return faq_out(c, f)
    m = native_mk(kvs)
    m !== nothing && return mk_out_t(c, m)
    return pr_opn(c, kvs)
end

"""Not in Lean: the `const` arms of `Math.nativeK`. The parts of a `const` node
with a native spelling: its
array form (`nothing` for a quantity) and its unit (`nothing` when it has none);
`nothing` when the node has no native spelling (it then prints in the call
form)."""
function const_form(sf::Sf, kvs)
    n = length(kvs)
    (3 <= n <= 4 && kvs[1].first == "args" && kvs[1].second isa JArr) || return nothing
    isempty(kvs[1].second.xs) || return nothing
    (kvs[2].first == "op" && kvs[2].second == "const") || return nothing
    if n == 3
        v = kvs[3].first == "value" ? kvs[3].second : nothing
        v isa JArr || return nothing
        af = arr_form(v)
        return af === nothing ? nothing : (af, nothing)
    end
    (kvs[3].first == "units" && kvs[4].first == "value") || return nothing
    u, v = kvs[3].second, kvs[4].second
    (u isa String && units_ok(sf, u)) || return nothing
    v isa JNum && return nothing, u
    v isa JArr || return nothing
    af = arr_form(v)
    return af === nothing ? nothing : (af, u)
end

"""Not in Lean (the `const` arm of `Math.pr`): the native spelling of a `const`
node: an array as a matrix
or column vector, a quantity, an array with its unit ([`const_form`](@ref))."""
function const_out(sf::Sf, kvs)
    q = const_form(sf, kvs)
    q === nothing && return nothing
    af, u = q
    af === nothing && return mk_out(7, qty_toks(kvs[4].second, factors_of(u)))
    u === nothing && return mk_out(10, arr_toks(sf, af))
    return mk_out(7, tc(arr_toks(sf, af), unit_toks(factors_of(u))))
end

"""Not in Lean: the `faq` arm of `Math.nativeK`. The parts of a `faq` node that
prints natively."""
function native_faq(kvs)
    f = faq_form(kvs)
    return (f !== nothing && faq_ok(f)) ? f : nothing
end

"""Not in Lean: the `makearray` arm of `Math.nativeK`. The parts of a
`makearray` node that prints natively."""
function native_mk(kvs)
    m = mk_form(kvs)
    return (m !== nothing && mk_ok(m)) ? m : nothing
end

"""Not in Lean: `Math.callCond` over a whole node. The node is one [`pr`](@ref)
gives the call form with
named fields: [`call_form_head`](@ref) holds and no native spelling of a
`const`, `faq` or `makearray` applies. The reader accepts the call form with `;`
only for such a node. Keys are not checked: a key the printer would not write
upright still reads."""
function call_form_node(c::Ctx, kvs)
    o = look("op", kvs)
    (o isa String && look("args", kvs) isa JArr) || return false
    call_form_head(c, o, fields_of(kvs)) || return false
    return const_form(c.sf, kvs) === nothing && native_faq(kvs) === nothing &&
        native_mk(kvs) === nothing
end

# The `[("args", .arr as), ("op", .str o)]` case of `Math.pr`.
function pr_plain(c::Ctx, o::String, args::Vector{Any}, kvs)
    sf = c.sf
    function chain(l, sep, lvl)
        parts = [pa(c, l, x) for x in args]
        sep === nothing && return mk_out(lvl, mul_toks(parts))
        return mk_out(lvl, sep_by((kw(sep),), parts))
    end
    k = kind_of(o)
    tag = k.tag
    na = length(args)
    if tag === :Minus && na == 1
        t = pa(c, 5, args[1])
        body = starts_num(t) ? grp(sf, t) : t
        return mk_out(5, tc((kw(KMinus),), body))
    elseif tag === :Minus && na == 2
        return mk_out(4, tc(pa(c, 4, args[1]), (kw(KMinus),), pa(c, 5, args[2])))
    elseif tag === :Div && na == 2
        a, b = args
        if sf == SF_LATEX
            return mk_out(
                10, tc((kw(KFrac), kw(KLb)), pa(c, 1, a), (kw(KRb), kw(KLb)), pa(c, 1, b), (kw(KRb),))
            )
        end
        return mk_out(7, tc(pa(c, 8, a), (kw(KSlash),), pa(c, 8, b)))
    elseif tag === :Pow && na == 2
        a, b = args
        ex = if sf == SF_LATEX
            tc((kw(KLb),), pa(c, 1, b), (kw(KRb),))
        else
            t = simple_e(c, b)
            t !== nothing ? Tok[t] : grp(sf, pr(c, b).toks)
        end
        return mk_out(8, tc(pa(c, 9, a), (kw(KCaret),), ex))
    elseif tag === :Lnot && na == 1
        return mk_out(6, tc((kw(KLnot),), pa(c, 6, args[1])))
    elseif tag === :Tru && na == 0
        return mk_out(10, Tok[TTxt("true")])
    elseif tag === :Fls && na == 0
        return mk_out(10, Tok[TTxt("false")])
    elseif tag === :Ite && na == 3
        cnd, a, b = args
        rows = case_row(sf, pa(c, 1, a), pa(c, 1, cnd))
        append!(rows, pr(c, b).crow)
        return Out(10, cases_toks(sf, rows), rows)
    elseif tag === :Un && na == 1
        return mk_out(10, un_toks(sf, k.k, pa(c, 1, args[1])))
    elseif tag === :Ic && na == 1 && args[1] isa String
        nm = args[1]
        name_ok(nm) && return mk_out(10, tc(name_toks(c, nm), ic_tail(sf)))
        return pr_esc(c, kvs)
    elseif tag === :Index && na >= 2
        base = args[1]
        is = args[2:end]
        subs() = [pa(c, 1, x) for x in is]
        sl = sub_list(sf, simple_arg(c, is), subs())
        if sub_ok(c.s, base, is) && !sub_pat(sf, sl)
            b = base isa String ? base : ""
            return mk_out(9, tc(name_toks(c, b), sl))
        end
        return mk_out(
            9, tc(pa(c, 10, base), (kw(KLbk),), sep_by((kw(KComma),), subs()), (kw(KRbk),))
        )
    elseif tag === :Cmp && na == 2
        return mk_out(3, tc(pa(c, 4, args[1]), (kw(k.k),), pa(c, 4, args[2])))
    elseif tag === :Plus
        return 2 <= na ? chain(5, KPlus, 4) : pr_opn(c, kvs)
    elseif tag === :Times
        return 2 <= na ? chain(6, nothing, 5) : pr_opn(c, kvs)
    elseif tag === :Land
        return 2 <= na ? chain(3, KLand, 2) : pr_opn(c, kvs)
    elseif tag === :Lor
        return 2 <= na ? chain(2, KLor, 1) : pr_opn(c, kvs)
    elseif tag === :Mm
        2 <= na || return pr_opn(c, kvs)
        return mk_out(10, call_toks(sf, Tok[kw(k.k)], [pa(c, 1, x) for x in args]))
    elseif tag === :Nab && na == 1
        return mk_out(6, tc(nab_head(sf, o), nab_arg(sf, o, pr(c, args[1]))))
    elseif tag === :Call
        return mk_out(10, call_toks(sf, Tok[TOpn(o)], [pa(c, 4, x) for x in args]))
    end
    return pr_opn(c, kvs)
end

# The `apply_operator` case of `Math.pr`.
function pr_template(c::Ctx, n::String, bs, kvs)
    sf = c.sf
    if !(tname_ok(n) && keys_sorted(bs) && all(kv -> is_e(kv.second), bs))
        return pr_esc(c, kvs)
    end
    vals = [(k, pa(c, 4, v)) for (k, v) in bs]
    ps = positional(c.s, n, bs)
    if ps !== nothing
        args = map(ps) do p
            i = findfirst(kv -> kv[1] == p, vals)
            i === nothing ? Tok[] : copy(vals[i][2])
        end
        return mk_out(10, call_toks(sf, Tok[TOpn(n)], args))
    end
    if !isempty(bs) && all(kv -> name_ok(kv.first), bs)
        return mk_out(
            10, call_toks(sf, Tok[TOpn(n)], [tc(name_toks(c, k), (kw(KEq),), v) for (k, v) in vals])
        )
    end
    isempty(bs) && return mk_out(5, Tok[TOpn(n)])
    return pr_esc(c, kvs)
end

"""`Math.pa`: the tokens of an expression for a position needing level `L`."""
pa(c::Ctx, l::Int, e) = out_at(pr(c, e), c.sf, l)

"""`Math.print`: the tokens of a whole expression."""
print(sf::Sf, s::Sym, e) = pa(Ctx(sf, s), 1, e)

end # module MPrint
