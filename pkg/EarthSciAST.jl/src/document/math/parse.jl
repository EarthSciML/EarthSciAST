"""
The parser: tokens to expressions.

Port of `formal/Esm/Document/Math/Parse.lean` (and `parseToks` from
Induct.lean); Rust `document::math::parse`. Recursive descent with one
function per precedence level (see `MPrint`), each taking fuel exactly as in
Lean: a function at fuel 0 fails, and every call passes on the fuel its Lean
definition passes. The chain loops (`orLoop`, `addLoop`, …) are loops here,
spending one unit of fuel per iteration as the Lean recursion does. The
helpers whose fuel only serves termination and is given as the input length
(`pNameLoop`, `pNames`, `pGrid`, `pCells`) loop without it.

A token list is an `AbstractVector{Tok}` (the rest of the input is a view of
it); a failed read is `nothing`.
"""
module MParse

using ..DJson
using ..MToken
using ..MUnits: Factor
import ..MUnits
using ..MExpr: DEPRECATED_OPS, REMOVED_OPS, is_formula, is_greek, is_letter, op_ok, pieces, Sym
using ..MPrint: BMAT_COLS, CALL_OPS, CMP_KW, CORE_OPS, FIELD_CALL_OPS, FN_KW, MAT_HEAD, RED_TABLE, Ctx, call_form_node, FaqForm, MkForm, faq_json,
    formula_raw, ins_kv, mk_json, mk_node, node, simple_tok, tname_ok, tparams, unesc_k,
    unesc_t, unlift, spell_unit_factors, up_set
using ..MSurface: neg_num
using ..DLimits: nested, removed_op!, shallow

const Toks = AbstractVector{<:Tok}

"""The token at `i`, or `nothing` past the end."""
@inline tk(ts::Toks, i::Int = 1) = i <= length(ts) ? @inbounds(ts[i]) : nothing

"""The tokens after the first `n`."""
@inline tdrop(ts::Toks, n::Int = 1) = @view ts[(n + 1):end]

"""The token at `i` is the keyword `k`."""
@inline kat(ts::Toks, i::Int, k::Kw) = iskw(tk(ts, i), k)

const s_of = str_of

# ## Small pieces

"""`Math.expect`."""
expect(k::Kw, ts::Toks) = kat(ts, 1, k) ? tdrop(ts) : nothing

"""`Math.close`: close an n-ary chain: one operand is itself, more make a
node."""
close_chain(o::AbstractString, xs::Vector{Any}) = length(xs) == 1 ? xs[1] : node(o, xs)

const CMP_OF = Dict{Kw, String}(k => o for (o, k) in CMP_KW)

"""`Math.cmpOf`: the comparison a token spells (the inverse of `CMP_KW`)."""
cmp_of(k::Kw) = get(CMP_OF, k, nothing)

# The inverse of `FN_KW`.
const FN_OF = Dict{Kw, String}(k => n for (n, k) in FN_KW)

"""`Math.fnOf`: the unary function a keyword spells."""
fn_of(k::Kw) = get(FN_OF, k, nothing)

const ATOM_KWS = (
    KLpg, KLp, KLbk, KLnot, KFrac, KSqrt, KExp, KLn, KLog, KSin, KCos, KTan, KAsin, KAcos,
    KAtan, KSinh, KCosh, KTanh, KMin, KMax, KLabs, KLfloor, KLceil, KAbs, KFloor, KCeil,
    KDotacc, KBcases, KCases, KEsmnode, KBmat, KVec, KMat, KSum, KProd, KLimits, KLbkg, KLr,
    KNabla, KPdiff,
)

"""`Math.atomStart`: tokens that can start an operand of a product."""
function atom_start(t::Tok)
    (
        t isa TNum || t isa TLetter || t isa TGreek || t isa TWord || t isa TIt ||
            t isa TRm || t isa TUps || t isa TOpn || t isa TTxt || t isa TEsc
    ) && return true
    t isa TKw && return t.k in ATOM_KWS
    return false
end

"""`Math.isLp`: `(` or `\\left(`."""
is_lp(t) = iskw(t, KLp) || iskw(t, KLpg)

"""`Math.isRp`: `)` or `\\right)`."""
is_rp(t) = iskw(t, KRp) || iskw(t, KRpg)

"""`Math.isKw`: the token is the keyword `k`."""
is_kw(k::Kw, t) = iskw(t, k)

# ## Names

"""`Math.decodeFormula`."""
decode_formula(raw) = Char[c for c in raw if c != '_' && c != '{' && c != '}']

"""`Math.formulaOf`: the name a formula token spells, if it is formula-shaped."""
function formula_of(sf::Sf, t)
    if t isa TRm && sf == SF_LATEX
        rc = collect(Char, t.s)
        g = decode_formula(rc)
        return (is_formula(g) && formula_raw(g) == rc) ? g : nothing
    elseif t isa TUps && sf == SF_TYPST
        g = Char[]
        for p in t.ps
            append!(g, p[1])
            append!(g, p[2])
        end
        back = [(s_of(a), s_of(b)) for (a, b) in pieces(g)]
        return (is_formula(g) && back == t.ps) ? g : nothing
    end
    return nothing
end

"""`Math.subOrPlain`: a single letter or Greek base, then an optional upright
name subscript."""
function sub_or_plain(sf::Sf, b::Vector{Char}, r::Toks)
    if sf == SF_LATEX && kat(r, 1, KUs) && kat(r, 2, KLb) && tk(r, 3) isa TRm && kat(r, 4, KRb)
        g = copy(b)
        push!(g, '_')
        append!(g, unesc_t(r[3].s))
        return g, tdrop(r, 4)
    end
    if sf == SF_TYPST && kat(r, 1, KUs) && kat(r, 2, KLpg) && tk(r, 3) isa TUps &&
            kat(r, 4, KRp) && length(r[3].ps) == 1 && isempty(r[3].ps[1][2])
        g = copy(b)
        push!(g, '_')
        append!(g, r[3].ps[1][1])
        return g, tdrop(r, 4)
    end
    return b, r
end

"""`Math.pSeg`: one name segment."""
function p_seg(sf::Sf, ts::Toks)
    t = tk(ts)
    t === nothing && return nothing
    r = tdrop(ts)
    if t isa TLetter
        return is_letter(t.c) ? sub_or_plain(sf, Char[t.c], r) : nothing
    elseif t isa TGreek
        gc = collect(Char, t.s)
        return is_greek(t.s) ? sub_or_plain(sf, gc, r) : nothing
    elseif t isa TIt
        return collect(Char, t.s), r
    end
    g = formula_of(sf, t)
    return g === nothing ? nothing : (g, r)
end

"""`Math.pName`: a name: segments joined by the scope dot."""
function p_name(sf::Sf, ts::Toks)
    x = p_seg(sf, ts)
    x === nothing && return nothing
    acc, r = x
    acc = copy(acc)
    while true
        if kat(r, 1, KSdot)
            y = p_seg(sf, tdrop(r))
            y === nothing && return nothing
            push!(acc, '.')
            append!(acc, y[1])
            r = y[2]
        else
            return String(acc), r
        end
    end
    return nothing
end

# ## JSON inside LaTeX escape nodes

"""`Math.pJson`."""
function p_json(f::Int, ts::Toks)
    f == 0 && return nothing
    return nested(_p_json, f - 1, ts)
end

# The body of `p_json`, with its construct open (Rust `Nest::enter`).
function _p_json(f::Int, ts::Toks)
    t = tk(ts)
    r = tdrop(ts, min(1, length(ts)))
    if t isa TWord && t.s == "null"
        return JNULL, r
    elseif t isa TWord && t.s == "true"
        return true, r
    elseif t isa TWord && t.s == "false"
        return false, r
    elseif t isa TNum
        return t.n, r
    elseif t isa TJstr
        return t.s, r
    elseif iskw(t, KLbk) && kat(ts, 2, KRbk)
        return JArr(), tdrop(ts, 2)
    elseif iskw(t, KLbk)
        x = p_json_items(f, r)
        (x !== nothing && kat(x[2], 1, KRbk)) || return nothing
        return JArr(x[1]), tdrop(x[2])
    elseif iskw(t, KLb) && kat(ts, 2, KRb)
        return JObj(), tdrop(ts, 2)
    elseif iskw(t, KLb)
        x = p_json_entries(f, r)
        (x !== nothing && kat(x[2], 1, KRb)) || return nothing
        return JObj(x[1]), tdrop(x[2])
    end
    return nothing
end

"""`Math.pJsonItems`."""
function p_json_items(f::Int, ts::Toks)
    out = Any[]
    while true
        f == 0 && return nothing
        f -= 1
        x = p_json(f, ts)
        x === nothing && return nothing
        v, r = x
        push!(out, v)
        if kat(r, 1, KComma)
            ts = tdrop(r)
        else
            return out, r
        end
    end
    return nothing
end

"""`Math.pJsonEntries`."""
function p_json_entries(f::Int, ts::Toks)
    out = Kvs()
    while true
        f == 0 && return nothing
        f -= 1
        (tk(ts) isa TJstr && kat(ts, 2, KColon)) || return nothing
        k = ts[1].s
        x = p_json(f, tdrop(ts, 2))
        x === nothing && return nothing
        v, r = x
        push!(out, k => v)
        if kat(r, 1, KComma)
            ts = tdrop(r)
        else
            return out, r
        end
    end
    return nothing
end

# ## Negative literals after an operand

"""`Math.negTok`: a negative literal token."""
neg_tok(t) = t isa TNum && neg_num(t.n)

"""`Math.negate`: the number with the opposite sign."""
negate(n::JInt) = JInt(-n.z)
negate(n::JDec) = JDec(!n.neg, copy(n.digits), n.e10)

"""`Math.negTail`: a negative literal right after an operand is a binary minus
and a positive number. Returns the number without its sign and the tokens
after it."""
function neg_tail(ts::Toks)
    t = tk(ts)
    t isa TNum || return nothing
    m = negate(t.n)
    (neg_num(t.n) && wfb(m)) || return nothing
    return m, tdrop(ts)
end

# ## Expressions

"""`Math.CallArg`: what `pCallArgs` read: positional (`named == false`, `k`
empty) or `name = value`."""
struct CallArg
    named::Bool
    k::String
    v::Any
end

"""`Math.allPos`."""
function all_pos(xs)
    out = Any[]
    for a in xs
        a.named && return nothing
        push!(out, a.v)
    end
    return out
end

"""`Math.allNamed`."""
function all_named(xs)
    out = Kvs()
    for a in xs
        a.named || return nothing
        push!(out, a.k => a.v)
    end
    return out
end

"""`Math.sortKV`: sort bindings by key (insertion from the right, so equal keys
keep their order)."""
function sort_kv(xs)
    out = Kvs()
    for kv in Iterators.reverse(xs)
        out = ins_kv(Pair{String, Any}(kv.first, kv.second), out)
    end
    return out
end

"""`Math.unitsOfRaw`: the unit a LaTeX `\\mathrm{…}` after a number spells."""
function units_of_raw(raw)
    s = collect(Char, MUnits.MATHRM_OPEN)
    append!(s, raw)
    push!(s, '}')
    return MUnits.parse_latex(s)
end

"""`Math.qty`: a quantity node."""
qty(n::JNum, l) = JObj(
    Kvs(
        [
            "args" => JArr(), "op" => "const", "units" => spell_unit_factors(l), "value" => n,
        ]
    )
)

"""`Math.dNode`: a time-derivative node (`d_node(x, "t")`)."""
d_node(x, w::AbstractString) = JObj(Kvs(["args" => JArr(Any[x]), "op" => "D", "wrt" => String(w)]))

"""`Math.pNode`: a `partial` node, the spatial derivative (spec §4.2)."""
p_node(x, w::AbstractString) =
    JObj(Kvs(["args" => JArr(Any[x]), "op" => "partial", "wrt" => String(w)]))

"""`Math.derivNode`: the derivative a fraction of differentials reads as: the time
derivative `D` along `t`, `partial` along any other axis."""
deriv_node(x, w::AbstractString) = w == "t" ? d_node(x, "t") : p_node(x, w)

"""`Math.tNode`: a reference node (`apply_operator`, spec §9.6.2)."""
t_node(n::AbstractString, bs::Kvs) = JObj(
    Kvs(
        [
            "args" => JArr(), "bindings" => JObj(bs), "name" => String(n),
            "op" => "apply_operator",
        ]
    )
)

"""`Math.constNode`: the value, and the units when there are some."""
function const_node(v, u)
    u === nothing && return JObj(Kvs(["args" => JArr(), "op" => "const", "value" => v]))
    return JObj(Kvs(["args" => JArr(), "op" => "const", "units" => u, "value" => v]))
end

"""`Math.pCells`: numbers separated by `sep`, up to the first other token."""
function p_cells(sep::Kw, ts::Toks)
    out = JNum[]
    while true
        t = tk(ts)
        t isa TNum || return nothing
        t2 = tk(ts, 2)
        if t2 isa TKw
            push!(out, t.n)
            if t2.k == sep
                ts = tdrop(ts, 2)
            else
                return out, tdrop(ts)
            end
        else
            push!(out, t.n)
            return out, tdrop(ts)
        end
    end
    return nothing
end

"""`Math.pGrid`: rows of numbers: cells separated by `csep`, rows by `rsep`,
closed by `close`."""
function p_grid(csep::Kw, rsep::Kw, close::Kw, ts::Toks)
    out = Vector{Vector{JNum}}()
    while true
        x = p_cells(csep, ts)
        x === nothing && return nothing
        row, r = x
        t = tk(r)
        t isa TKw || return nothing
        push!(out, row)
        if t.k == rsep
            ts = tdrop(r)
        elseif t.k == close
            return out, tdrop(r)
        else
            return nothing
        end
    end
    return nothing
end

"""`Math.gridJson`: a LaTeX `bmatrix`: one cell per row is a column (rank 1)."""
function grid_json(rows)
    if all(r -> length(r) == 1, rows)
        return JArr(Any[isempty(r) ? JInt(0) : r[1] for r in rows])
    end
    return JArr(Any[JArr(Any[n for n in r]) for r in rows])
end

"""`Math.constTail`: the unit after an array, if any."""
function const_tail(v, r::Toks)
    t = tk(r)
    t isa TUnits && return const_node(v, spell_unit_factors(t.fs)), tdrop(r)
    return const_node(v, nothing), r
end

"""`Math.icTailP`: the `ic` tail `(t_{0})` / `(t_0)`."""
function ic_tail_p(sf::Sf, ts::Toks)
    (kat(ts, 1, KLp) && tk(ts, 2) == TLetter('t') && kat(ts, 3, KUs)) || return nothing
    r = tdrop(ts, 3)
    if sf == SF_LATEX
        if kat(r, 1, KLb) && tk(r, 2) == TNum(JInt(0)) && kat(r, 3, KRb) && kat(r, 4, KRp)
            return tdrop(r, 4)
        end
        return nothing
    end
    (tk(r, 1) == TNum(JInt(0)) && kat(r, 2, KRp)) && return tdrop(r, 2)
    return nothing
end

"""`Math.jsonStart`: a LaTeX field value that is JSON starts with `{`, `[`, a
string or a word."""
function json_start(ts::Toks)
    t = tk(ts)
    return iskw(t, KLb) || iskw(t, KLbk) || t isa TJstr || t isa TWord
end

"""`Math.keyOf`: a field key: LaTeX `\\mathrm{key} =`, Typst `upright("key") =`."""
function key_of(c::Ctx, ts::Toks)
    t = tk(ts)
    if c.sf == SF_LATEX && t isa TRm && kat(ts, 2, KEq)
        return s_of(unesc_k(t.s)), tdrop(ts, 2)
    end
    if c.sf == SF_TYPST && t isa TUps && kat(ts, 2, KEq) && length(t.ps) == 1 &&
            isempty(t.ps[1][2])
        return t.ps[1][1], tdrop(ts, 2)
    end
    return nothing
end

"""`Math.dCallNode`: `partial` with trailing operands."""
d_call_node(w::AbstractString, xs::Vector{Any}) =
    JObj(Kvs(["args" => JArr(xs), "op" => "partial", "wrt" => String(w)]))

"""`Math.nabTail`: after `\\nabla`: which form it is (`\\cdot` div, `\\times` curl,
`^{2}` laplacian, nothing grad), and the tokens of its operand."""
function nab_tail(sf::Sf, r::Toks)
    kat(r, 1, KCdot) && return "div", tdrop(r)
    kat(r, 1, KTimes) && return "curl", tdrop(r)
    two = TNum(JInt(2))
    if sf == SF_LATEX && kat(r, 1, KCaret) && kat(r, 2, KLb) && tk(r, 3) == two && kat(r, 4, KRb)
        return "laplacian", tdrop(r, 4)
    elseif sf == SF_TYPST && kat(r, 1, KCaret) && tk(r, 2) == two
        return "laplacian", tdrop(r, 2)
    end
    return "grad", r
end

declared(c::Ctx, n::AbstractString) = n in c.s.names

"""`Math.eulerHead`: the input starts with Euler's number raised to a power."""
function euler_head(c::Ctx, ts::Toks)
    t = tk(ts)
    kat(ts, 2, KCaret) || return false
    t isa TRm && return t.s == "e"
    t isa TUps && return length(t.ps) == 1 && t.ps[1][1] == "e" && isempty(t.ps[1][2])
    t isa TLetter && return t.c == 'e' && !declared(c, "e")
    return false
end

"""`Math.pNamePrim`: a name, or an initial condition `N(t_{0})`."""
function p_name_prim(c::Ctx, ts::Toks)
    x = p_name(c.sf, ts)
    x === nothing && return nothing
    n, r = x
    r2 = ic_tail_p(c.sf, r)
    r2 !== nothing && return node("ic", Any[n]), r2
    return n, r
end

"""`Math.pWord`: a bare run of letters: the declared name when only it is
declared, the product of its letters when only they are."""
function p_word(c::Ctx, w::AbstractString, r::Toks)
    whole = declared(c, w)
    letters = all(ch -> declared(c, string(ch)), w)
    whole && !letters && return String(w), r
    letters && !whole && return node("*", Any[string(ch) for ch in w]), r
    return nothing
end

"""`Math.dName`: `d` then a name, up to a closing token `k`."""
function d_name(c::Ctx, k::Kw, ts::Toks)
    t = tk(ts)
    if t isa TWord && tk(ts, 2) isa TKw
        if ts[2].k == k && !declared(c, t.s)
            (!isempty(t.s) && first(t.s) == 'd') || return nothing
            return String(collect(Char, t.s)[2:end]), tdrop(ts, 2)
        end
        return nothing
    end
    if t == TLetter('d')
        x = p_name(c.sf, tdrop(ts))
        (x !== nothing && tk(x[2]) isa TKw) || return nothing
        x[2][1].k == k || return nothing
        return x[1], tdrop(x[2])
    end
    return nothing
end

"""`Math.pItalicD`: the italic-d derivative variant."""
function p_italic_d(c::Ctx, r::Toks)
    declared(c, "d") && return nothing
    if c.sf == SF_LATEX
        x = d_name(c, KRb, r)
        (x !== nothing && kat(x[2], 1, KLb)) || return nothing
        y = d_name(c, KRb, tdrop(x[2]))
        y === nothing && return nothing
        return deriv_node(x[1], y[1]), y[2]
    end
    x = d_name(c, KRp, r)
    (x !== nothing && kat(x[2], 1, KSlash) && kat(x[2], 2, KLpg)) || return nothing
    y = d_name(c, KRp, tdrop(x[2], 2))
    y === nothing && return nothing
    return deriv_node(x[1], y[1]), y[2]
end

"""`Math.Row`: a row of a reduction's subscript (`:rng`, with `k` and `v`), or
an output entry / filter (`:filt`, with `v`)."""
struct Row
    tag::Symbol
    k::String
    v::Any
end
rng(k, v) = Row(:rng, k, v)
filt(v) = Row(:filt, "", v)

"""`Math.redOf` (the inverse of `RED_TABLE`'s keyword column)."""
function red_of(k::Kw)
    i = findfirst(x -> x[2] == k, RED_TABLE)
    return i === nothing ? nothing : RED_TABLE[i][1]
end

"""`Math.pRedHead`: the operator of a reduction, whether it is marked, and the
rest."""
function p_red_head(sf::Sf, ts::Toks)
    if kat(ts, 1, KLimits) && kat(ts, 2, KLp) && tk(ts, 3) isa TKw && kat(ts, 4, KRp)
        sf == SF_TYPST || return nothing
        red = red_of(ts[3].k)
        return red === nothing ? nothing : (red, true, tdrop(ts, 4))
    end
    if tk(ts) isa TKw && kat(ts, 2, KLimitsL)
        red = red_of(ts[1].k)
        red === nothing && return nothing
        sf == SF_LATEX && return red, true, tdrop(ts, 2)
        return red, false, tdrop(ts)
    end
    if tk(ts) isa TKw
        red = red_of(ts[1].k)
        return red === nothing ? nothing : (red, false, tdrop(ts))
    end
    return nothing
end

"""`Math.pNames`: names separated by commas."""
function p_names(sf::Sf, ts::Toks)
    out = String[]
    while true
        x = p_name(sf, ts)
        x === nothing && return nothing
        n, r = x
        push!(out, n)
        if kat(r, 1, KComma)
            ts = tdrop(r)
        else
            return out, r
        end
    end
    return nothing
end

"""`Math.rowParts`: ranges, then at most one filter, last."""
function row_parts(rows::Vector{Row})
    n = length(rows)
    rg = Kvs()
    fl = nothing
    for (i, row) in enumerate(rows)
        if row.tag === :rng
            push!(rg, row.k => row.v)
        else
            i == n || return nothing
            fl = row.v
        end
    end
    return rg, fl
end

"""`Math.entryParts`: the output entries of a list of entry rows, with their
ranges."""
function entry_parts(rows::Vector{Row})
    outs = Any[]
    rs = Kvs()
    for row in rows
        if row.tag === :rng
            push!(outs, row.k)
            push!(rs, row.k => row.v)
        elseif row.v isa String
            push!(outs, row.v)
        elseif row.v isa JInt && row.v.z == 1
            push!(outs, JInt(1))
        else
            return nothing
        end
    end
    return outs, rs
end

"""`Math.withOut`: the reduction's parts with the output entries."""
function with_out(f::FaqForm, outs::Vector{Any}, ors::Kvs)
    rs = copy(ors)
    append!(rs, f.ranges)
    return FaqForm(f.red, f.marked, outs, sort_kv(rs), f.expr, f.filter, f.set)
end

"""`Math.withSup`: the reduction with the superscript set read on its output
bracket."""
with_sup(f::FaqForm, st::Vector{String}) =
    FaqForm(f.red, f.marked, f.out, f.ranges, f.expr, f.filter, st)

"""`Math.pSup`: the superscript set of a reduction or of an output form, if
there is one: LaTeX `^{\\{f, g\\}}`, Typst `^({f, g})`."""
function p_sup(sf::Sf, r::Toks)
    open, close = sf == SF_LATEX ? (KLb, KRb) : (KLpg, KRp)
    (kat(r, 1, KCaret) && kat(r, 2, open) && kat(r, 3, KLset)) || return String[], r
    x = p_names(sf, tdrop(r, 3))
    (x !== nothing && kat(x[2], 1, KRset) && kat(x[2], 2, close)) || return nothing
    return x[1], tdrop(x[2], 2)
end

"""`Math.mkTail`: the `makearray` node of a table read back, with its subscript
of output indices if one follows."""
function mk_tail(sf::Sf, rows, r::Toks)
    node_of(out) = mk_json(MkForm(out, [x[2] for x in rows], Any[x[1] for x in rows]))
    open, close = sf == SF_LATEX ? (KLb, KRb) : (KLpg, KRp)
    (kat(r, 1, KUs) && kat(r, 2, open)) || return node_of(String[]), r
    x = p_names(sf, tdrop(r, 2))
    (x !== nothing && kat(x[2], 1, close)) || return nothing
    return node_of(x[1]), tdrop(x[2])
end

# ## The level parsers

"""`Math.pOr`: level 1, an `or` chain."""
function p_or(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_and(c, f, ts)
    x === nothing && return nothing
    return or_loop(c, f, Any[x[1]], x[2])
end

"""`Math.orLoop`."""
function or_loop(c::Ctx, f::Int, acc::Vector{Any}, ts::Toks)
    while true
        f == 0 && return nothing
        f -= 1
        if kat(ts, 1, KLor)
            y = p_and(c, f, tdrop(ts))
            y === nothing && return nothing
            push!(acc, y[1])
            ts = y[2]
        else
            return close_chain("or", acc), ts
        end
    end
    return nothing
end

"""`Math.pAnd`: level 2, an `and` chain."""
function p_and(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_cmp(c, f, ts)
    x === nothing && return nothing
    return and_loop(c, f, Any[x[1]], x[2])
end

"""`Math.andLoop`."""
function and_loop(c::Ctx, f::Int, acc::Vector{Any}, ts::Toks)
    while true
        f == 0 && return nothing
        f -= 1
        if kat(ts, 1, KLand)
            y = p_cmp(c, f, tdrop(ts))
            y === nothing && return nothing
            push!(acc, y[1])
            ts = y[2]
        else
            return close_chain("and", acc), ts
        end
    end
    return nothing
end

"""`Math.pCmp`: level 3, one comparison."""
function p_cmp(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_add(c, f, ts)
    x === nothing && return nothing
    return cmp_loop(c, f, x[1], x[2])
end

"""`Math.cmpLoop`."""
function cmp_loop(c::Ctx, f::Int, x, ts::Toks)
    f == 0 && return nothing
    f -= 1
    t = tk(ts)
    if t isa TKw
        o = cmp_of(t.k)
        if o !== nothing
            y = p_add(c, f, tdrop(ts))
            y === nothing && return nothing
            return node(o, Any[x, y[1]]), y[2]
        end
    end
    return x, ts
end

"""`Math.pAdd`: level 4, `+` chains and binary `-`."""
function p_add(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_mul(c, f, ts)
    x === nothing && return nothing
    return add_loop(c, f, Any[x[1]], x[2])
end

"""`Math.addLoop`. After `negTail`, Lean parses the list with the number's sign
removed; here that list is built and the rest mapped back onto the input."""
function add_loop(c::Ctx, f::Int, acc::Vector{Any}, ts::Toks)
    while true
        f == 0 && return nothing
        f -= 1
        if kat(ts, 1, KPlus)
            y = p_mul(c, f, tdrop(ts))
            y === nothing && return nothing
            push!(acc, y[1])
            ts = y[2]
        elseif kat(ts, 1, KMinus)
            y = p_mul(c, f, tdrop(ts))
            y === nothing && return nothing
            z = shallow(node("-", Any[close_chain("+", acc), y[1]]))
            z === nothing && return nothing
            acc = Any[z]
            ts = y[2]
        else
            nt = neg_tail(ts)
            nt === nothing && return close_chain("+", acc), ts
            m, r = nt
            r1 = Tok[TNum(m)]
            append!(r1, r)
            y = p_mul(c, f, r1)
            y === nothing && return nothing
            n = length(y[2])
            r2 = view(r, (length(r) - min(n, length(r)) + 1):length(r))
            z = shallow(node("-", Any[close_chain("+", acc), y[1]]))
            z === nothing && return nothing
            acc = Any[z]
            ts = r2
        end
    end
    return nothing
end

"""`Math.pMul`: level 5, unary minus and `*` chains."""
function p_mul(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    return nested(_p_mul, c, f - 1, ts)
end

# The body of `p_mul`, with its construct open (Rust `Nest::enter`).
function _p_mul(c::Ctx, f::Int, ts::Toks)
    if kat(ts, 1, KMinus)
        x = p_mul(c, f, tdrop(ts))
        x === nothing && return nothing
        return node("-", Any[x[1]]), x[2]
    end
    x = p_not(c, f, ts)
    x === nothing && return nothing
    return mul_loop(c, f, Any[x[1]], x[2])
end

"""`Math.mulLoop`."""
function mul_loop(c::Ctx, f::Int, acc::Vector{Any}, ts::Toks)
    while true
        f == 0 && return nothing
        f -= 1
        t = tk(ts)
        if iskw(t, KCdot) || iskw(t, KTimes)
            y = p_not(c, f, tdrop(ts))
            y === nothing && return nothing
            push!(acc, y[1])
            ts = y[2]
        elseif iskw(t, KSlash)
            c.sf == SF_LATEX || return close_chain("*", acc), ts
            y = p_not(c, f, tdrop(ts))
            y === nothing && return nothing
            z = shallow(node("/", Any[close_chain("*", acc), y[1]]))
            z === nothing && return nothing
            acc = Any[z]
            ts = y[2]
        elseif t !== nothing
            (atom_start(t) && !neg_tok(t)) || return close_chain("*", acc), ts
            y = p_not(c, f, ts)
            y === nothing && return nothing
            push!(acc, y[1])
            ts = y[2]
        else
            return close_chain("*", acc), ts
        end
    end
    return nothing
end

"""`Math.pNot`: level 6, `not`, and the `\\nabla` forms, whose operand is read at
level 9."""
function p_not(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    return nested(_p_not, c, f - 1, ts)
end

# The body of `p_not`, with its construct open (Rust `Nest::enter`).
function _p_not(c::Ctx, f::Int, ts::Toks)
    if kat(ts, 1, KLnot)
        x = p_not(c, f, tdrop(ts))
        x === nothing && return nothing
        return node("not", Any[x[1]]), x[2]
    end
    if kat(ts, 1, KNabla)
        o, r = nab_tail(c.sf, tdrop(ts))
        x = p_nab_arg(c, f, r)
        x === nothing && return nothing
        return node(o, Any[x[1]]), x[2]
    end
    return p_frac(c, f, ts)
end

"""`Math.pNabArg`: the operand of a `\\nabla` form: another `\\nabla` form, or a
postfix-level operand."""
function p_nab_arg(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    kat(ts, 1, KNabla) && return p_not(c, f, ts)
    return p_post(c, f, ts)
end

"""`Math.pFrac`: level 7, the Typst fraction, grouping to the left."""
function p_frac(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_pow(c, f, ts)
    x === nothing && return nothing
    return frac_loop(c, f, x[1], x[2])
end

"""`Math.fracLoop`."""
function frac_loop(c::Ctx, f::Int, x, ts::Toks)
    while true
        f == 0 && return nothing
        f -= 1
        if kat(ts, 1, KSlash) && c.sf == SF_TYPST
            y = p_pow(c, f, tdrop(ts))
            y === nothing && return nothing
            x = shallow(node("/", Any[x, y[1]]))
            x === nothing && return nothing
            ts = y[2]
        else
            return x, ts
        end
    end
    return nothing
end

"""`Math.pPow`: level 8, a power."""
function p_pow(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_post(c, f, ts)
    x === nothing && return nothing
    if kat(x[2], 1, KCaret)
        y = p_expo(c, f, tdrop(x[2]))
        y === nothing && return nothing
        return node("^", Any[x[1], y[1]]), y[2]
    end
    return x
end

"""`Math.pExpo`: an exponent: LaTeX `{…}`; Typst `(…)` or one simple token."""
function p_expo(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    t = tk(ts)
    if c.sf == SF_LATEX && iskw(t, KLb)
        x = p_or(c, f, tdrop(ts))
        (x !== nothing && kat(x[2], 1, KRb)) || return nothing
        return x[1], tdrop(x[2])
    elseif c.sf == SF_TYPST && iskw(t, KLpg)
        x = p_or(c, f, tdrop(ts))
        (x !== nothing && is_rp(tk(x[2]))) || return nothing
        return x[1], tdrop(x[2])
    elseif c.sf == SF_TYPST && t !== nothing
        simple_tok(t) || return nothing
        y = p_prim(c, f, Tok[t])
        (y !== nothing && isempty(y[2])) || return nothing
        return y[1], tdrop(ts)
    end
    return nothing
end

"""`Math.pPost`: level 9, postfix index, `_{…}` or `[…]`."""
function p_post(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_prim(c, f, ts)
    x === nothing && return nothing
    return post_loop(c, f, x[1], x[2])
end

"""`Math.postLoop`."""
function post_loop(c::Ctx, f::Int, x, ts::Toks)
    while true
        f == 0 && return nothing
        f -= 1
        if kat(ts, 1, KUs)
            r = tdrop(ts)
            t = tk(r)
            if c.sf == SF_LATEX && iskw(t, KLb)
                y = p_list(c, f, 1, tdrop(r))
                (y !== nothing && kat(y[2], 1, KRb)) || return nothing
                isempty(y[1]) && return nothing
                x = node("index", vcat(Any[x], y[1]))
                ts = tdrop(y[2])
            elseif c.sf == SF_TYPST && iskw(t, KLpg)
                y = p_list(c, f, 1, tdrop(r))
                (y !== nothing && is_rp(tk(y[2])) && !isempty(y[1])) || return nothing
                x = node("index", vcat(Any[x], y[1]))
                ts = tdrop(y[2])
            elseif c.sf == SF_TYPST && t !== nothing && simple_tok(t)
                y = p_prim(c, f, Tok[t])
                (y !== nothing && isempty(y[2])) || return nothing
                x = node("index", Any[x, y[1]])
                ts = tdrop(r)
            else
                return nothing
            end
        elseif kat(ts, 1, KLbk)
            y = p_list(c, f, 1, tdrop(ts))
            (y !== nothing && kat(y[2], 1, KRbk)) || return nothing
            isempty(y[1]) && return nothing
            x = node("index", vcat(Any[x], y[1]))
            ts = tdrop(y[2])
        else
            return x, ts
        end
    end
    return nothing
end

"""`Math.pList`: a comma-separated list of expressions at level `L` (1 or 4),
possibly empty when the next token closes it."""
function p_list(c::Ctx, f::Int, l::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    t = tk(ts)
    t === nothing && return Any[], ts
    (is_rp(t) || iskw(t, KRb) || iskw(t, KRbk)) && return Any[], ts
    return p_items(c, f, l, ts)
end

"""`Math.pItems`."""
function p_items(c::Ctx, f::Int, l::Int, ts::Toks)
    out = Any[]
    while true
        f == 0 && return nothing
        f -= 1
        x = p_lv(c, f, l, ts)
        x === nothing && return nothing
        push!(out, x[1])
        if kat(x[2], 1, KComma)
            ts = tdrop(x[2])
        else
            return out, x[2]
        end
    end
    return nothing
end

"""`Math.pLv`: parse at level 1 or level 4."""
function p_lv(c::Ctx, f::Int, l::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    return l == 4 ? p_add(c, f, ts) : p_or(c, f, ts)
end

"""`Math.pCallArgs`: call arguments at level 4: each positional, or
`name = value`."""
function p_call_args(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    (kat(ts, 1, KRp) || kat(ts, 1, KSemi)) && return CallArg[], ts
    return p_call_items(c, f, ts)
end

"""`Math.pCallItems`."""
function p_call_items(c::Ctx, f::Int, ts::Toks)
    out = CallArg[]
    while true
        f == 0 && return nothing
        f -= 1
        x = p_add(c, f, ts)
        x === nothing && return nothing
        v0, r = x
        if v0 isa String && kat(r, 1, KEq)
            y = p_add(c, f, tdrop(r))
            y === nothing && return nothing
            push!(out, CallArg(true, v0, y[1]))
            if kat(y[2], 1, KComma)
                ts = tdrop(y[2])
            else
                return out, y[2]
            end
        elseif kat(r, 1, KComma)
            push!(out, CallArg(false, "", v0))
            ts = tdrop(r)
        else
            push!(out, CallArg(false, "", v0))
            return out, r
        end
    end
    return nothing
end

"""`Math.pFields`: open-operator fields after `;`."""
function p_fields(c::Ctx, f::Int, ts::Toks)
    out = Kvs()
    while true
        f == 0 && return nothing
        f -= 1
        x = key_of(c, ts)
        x === nothing && return nothing
        k, r = x
        y = p_val(c, f, r)
        y === nothing && return nothing
        push!(out, k => y[1])
        if kat(y[2], 1, KComma)
            ts = tdrop(y[2])
        else
            return out, y[2]
        end
    end
    return nothing
end

"""`Math.pVal`: a field value: JSON (LaTeX JSON tokens, Typst `#value`) or an
expression."""
function p_val(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    if c.sf == SF_TYPST
        t = tk(ts)
        t isa TCode && return t.j, tdrop(ts)
        return p_add(c, f, ts)
    end
    return json_start(ts) ? p_json(f, ts) : p_add(c, f, ts)
end

function nodup_keys(xs)
    for i in eachindex(xs), j in 1:(i - 1)
        xs[j].first == xs[i].first && return false
    end
    return true
end

"""`Math.pOpn`: `\\operatorname{n}(…)`: a call-form core operator, a deprecated
one (rewritten), a template (by the symbol table, positional or named), or an
open operator; a bare `\\operatorname{n}` (no `(` or `_` after it) is a template
applied with no bindings ([`bare_template`](@ref))."""
function p_opn(c::Ctx, f::Int, n::String, ts::Toks)
    f == 0 && return nothing
    f -= 1
    t0 = tk(ts)
    t0 === nothing && return bare_template(c, n, ts)
    r = tdrop(ts)
    if is_lp(t0)
        x = p_call_args(c, f, r)
        x === nothing && return nothing
        args, rr = x
        if kat(rr, 1, KRp)
            r2 = tdrop(rr)
            if n in CALL_OPS
                vs = all_pos(args)
                return vs === nothing ? nothing : (node(n, vs), r2)
            elseif n == "neg"
                vs = all_pos(args)
                (vs !== nothing && length(vs) == 1) || return nothing
                return node("-", Any[vs[1]]), r2
            elseif n == "pow"
                vs = all_pos(args)
                (vs !== nothing && length(vs) == 2) || return nothing
                return node("^", Any[vs[1], vs[2]]), r2
            elseif n in REMOVED_OPS || n == "D"
                return nothing
            end
            ps = tparams(c.s, n)
            vs = all_pos(args)
            bs = all_named(args)
            if ps !== nothing && vs !== nothing
                length(ps) == length(vs) || return nothing
                return t_node(n, sort_kv(Kvs([p => v for (p, v) in zip(ps, vs)]))), r2
            elseif bs !== nothing && !isempty(bs)
                nodup_keys(bs) || return nothing
                return t_node(n, sort_kv(bs)), r2
            elseif ps === nothing && vs !== nothing
                return mk_node(n, vs, Kvs()), r2
            end
            return nothing
        elseif kat(rr, 1, KSemi)
            r1 = tdrop(rr)
            (
                n in REMOVED_OPS || (n in CORE_OPS && !(n in FIELD_CALL_OPS)) ||
                    tparams(c.s, n) !== nothing
            ) && return nothing
            vs = all_pos(args)
            y = p_fields(c, f, r1)
            (vs !== nothing && y !== nothing && kat(y[2], 1, KRp)) || return nothing
            # The fields are the node's own: no key twice, none `op` or `args`.
            (nodup_keys(y[1]) && all(kv -> !(kv.first in ("op", "args")), y[1])) ||
                return nothing
            nd = mk_node(n, vs, y[1])
            # Only a node the printer writes in this form reads back from it.
            call_form_node(c, nd.kvs) || return nothing
            return nd, tdrop(y[2])
        end
        return nothing
    elseif iskw(t0, KUs)
        return n == "D" ? p_d_call(c, f, r) : nothing
    end
    return bare_template(c, n, ts)
end

"""Not in Lean: the reader side of `Math.bareOK`. A bare `\\operatorname{n}`:
the template `n` applied
with no bindings, as the printer writes it when no parameter list of `n` is
known or the known one is not empty. A template in scope with no parameters
prints as `\\operatorname{n}()`, so its bare name is refused."""
function bare_template(c::Ctx, n::String, ts::Toks)
    tname_ok(n) || return nothing
    ps = tparams(c.s, n)
    (ps !== nothing && isempty(ps)) && return nothing
    return t_node(n, Kvs()), ts
end

"""`Math.pDCall`: `\\partial_{x}(u, a, b)`, and the earlier
`\\operatorname{D}_{x}(u, a, b)` (read, never printed), after the `_`: `partial` with
trailing operands."""
function p_d_call(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    w = nothing
    if c.sf == SF_LATEX && kat(ts, 1, KLb)
        x = p_name(c.sf, tdrop(ts))
        if x !== nothing && kat(x[2], 1, KRb)
            w = (x[1], tdrop(x[2]))
        end
    elseif c.sf == SF_TYPST && kat(ts, 1, KLpg)
        x = p_name(c.sf, tdrop(ts))
        if x !== nothing && kat(x[2], 1, KRp)
            w = (x[1], tdrop(x[2]))
        end
    end
    w === nothing && return nothing
    wn, r = w
    t3 = tk(r)
    (t3 !== nothing && is_lp(t3)) || return nothing
    y = p_call_args(c, f, tdrop(r))
    (y !== nothing && kat(y[2], 1, KRp)) || return nothing
    xs = all_pos(y[1])
    xs === nothing && return nothing
    return d_call_node(wn, xs), tdrop(y[2])
end

op_allowed(o::AbstractString) = op_ok(o) && !(o in REMOVED_OPS) && !(o in DEPRECATED_OPS)

function paren_close(c::Ctx, f::Int, r::Toks)
    x = p_or(c, f, r)
    (x !== nothing && is_rp(tk(x[2]))) || return nothing
    return x[1], tdrop(x[2])
end

function closed(c::Ctx, f::Int, r::Toks, k::Kw, o::AbstractString)
    x = p_or(c, f, r)
    (x !== nothing && kat(x[2], 1, k)) || return nothing
    return node(o, Any[x[1]]), tdrop(x[2])
end

# Record a removed operator written in the call or escape form at the front
# of `ts`, so a refusal can name it (CONFORMANCE §7.1). Not in Lean, whose
# reader refuses every bad input alike.
function note_removed_op(ts::Toks)
    t = tk(ts)
    name = if t isa TOpn || t isa TEsc
        t.s
    elseif iskw(t, KEsmnode) && length(ts) >= 3 && ts[3] isa TTxt
        ts[3].s
    else
        return nothing
    end
    i = findfirst(==(name), REMOVED_OPS)
    i === nothing || removed_op!(REMOVED_OPS[i])
    return nothing
end

"""`Math.pPrim`: a primary."""
function p_prim(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    note_removed_op(ts)
    t1 = tk(ts)
    t2 = tk(ts, 2)
    r = tdrop(ts, min(1, length(ts)))
    k1 = t1 isa TKw ? t1.k : nothing
    if t1 isa TNum
        t2 isa TUnits && return qty(t1.n, t2.fs), tdrop(ts, 2)
        return t1.n, r
    elseif k1 == KBmat
        x = p_grid(KAmp, KNl, KEmat, r)
        (x !== nothing && all(q -> length(q) <= BMAT_COLS, x[1])) || return nothing
        return const_tail(grid_json(x[1]), x[2])
    elseif k1 == KLbkg && t2 isa TArrCols
        # A matrix wider than `bmatrix` allows: `n` columns in every row.
        n = t2.n
        n > BMAT_COLS || return nothing
        x = p_grid(KAmp, KNl, KEarr, tdrop(ts, 2))
        (x !== nothing && kat(x[2], 1, KRbkg) && all(q -> length(q) == n, x[1])) ||
            return nothing
        return const_tail(JArr(Any[JArr(Any[v for v in q]) for q in x[1]]), tdrop(x[2]))
    elseif k1 == KVec && t2 !== nothing
        is_lp(t2) || return nothing
        x = p_cells(KComma, tdrop(ts, 2))
        (x !== nothing && kat(x[2], 1, KRp)) || return nothing
        return const_tail(JArr(Any[n for n in x[1]]), tdrop(x[2]))
    elseif mat_head(ts)
        x = p_mk_rows(c, f, KComma, KSemi, KRp, tdrop(ts, length(MAT_HEAD)))
        x === nothing && return nothing
        return mk_tail(c.sf, x[1], x[2])
    elseif k1 == KMat && t2 !== nothing
        is_lp(t2) || return nothing
        x = p_grid(KComma, KSemi, KRp, tdrop(ts, 2))
        x === nothing && return nothing
        return const_tail(JArr(Any[JArr(Any[n for n in q]) for q in x[1]]), x[2])
    elseif t1 isa TTxt && t1.s == "true"
        return node("true", Any[]), r
    elseif t1 isa TTxt && t1.s == "false"
        return node("false", Any[]), r
    elseif k1 == KLpg || k1 == KLp
        if c.sf == SF_TYPST && iskw(t2, KDif)
            return p_dt(c, f, KDif, tdrop(r))
        elseif c.sf == SF_TYPST && iskw(t2, KPdiff) && kat(ts, 3, KUs)
            return paren_close(c, f, r)
        elseif c.sf == SF_TYPST && iskw(t2, KPdiff)
            return p_dt(c, f, KPdiff, tdrop(r))
        elseif c.sf == SF_TYPST && t2 == TLetter('d')
            p = p_italic_d(c, r)
            p !== nothing && return p
            return paren_close(c, f, r)
        end
        return paren_close(c, f, r)
    elseif k1 == KLbk
        x = p_or(c, f, r)
        (x !== nothing && kat(x[2], 1, KRbk)) || return nothing
        return x[1], tdrop(x[2])
    elseif k1 == KFrac && iskw(t2, KLb)
        return p_frac_l(c, f, tdrop(ts, 2))
    elseif k1 == KPdiff && iskw(t2, KUs)
        return p_d_call(c, f, tdrop(ts, 2))
    elseif k1 == KSqrt
        if c.sf == SF_LATEX && iskw(t2, KLb)
            return closed(c, f, tdrop(r), KRb, "sqrt")
        elseif c.sf == SF_TYPST && t2 !== nothing
            is_lp(t2) || return nothing
            return p_fn1(c, f, "sqrt", tdrop(r))
        end
        return nothing
    elseif k1 == KLog && iskw(t2, KUs)
        q = tdrop(ts, 2)
        if c.sf == SF_LATEX && kat(q, 1, KLb) && tk(q, 2) == TNum(JInt(10)) && kat(q, 3, KRb) &&
                tk(q, 4) !== nothing
            is_lp(q[4]) || return nothing
            return p_fn1(c, f, "log10", tdrop(q, 4))
        elseif c.sf == SF_TYPST && tk(q, 1) == TNum(JInt(10)) && tk(q, 2) !== nothing
            is_lp(q[2]) || return nothing
            return p_fn1(c, f, "log10", tdrop(q, 2))
        end
        return nothing
    elseif k1 == KLabs
        return closed(c, f, r, KRabs, "abs")
    elseif k1 == KLfloor
        return closed(c, f, r, KRfloor, "floor")
    elseif k1 == KLceil
        return closed(c, f, r, KRceil, "ceil")
    elseif (k1 == KMin || k1 == KMax) && t2 !== nothing
        if iskw(t2, KLp)
            x = p_list(c, f, 1, tdrop(ts, 2))
            (x !== nothing && kat(x[2], 1, KRp)) || return nothing
            2 <= length(x[1]) || return nothing
            return node(k1 == KMin ? "min" : "max", x[1]), tdrop(x[2])
        end
        return p_red(c, f, ts)
    elseif k1 == KLbkg && iskw(t2, KBarr)
        x = p_mk_rows(c, f, KAmp, KNl, KEarr, tdrop(ts, 2))
        (x !== nothing && kat(x[2], 1, KRbkg)) || return nothing
        return mk_tail(c.sf, x[1], tdrop(x[2]))
    elseif k1 == KSum || k1 == KProd || k1 == KLimits || k1 == KLbkg
        return p_red(c, f, ts)
    elseif k1 == KLr && iskw(t2, KLp) && kat(ts, 3, KLbk)
        return p_red(c, f, ts)
    elseif t1 isa TOpn
        return p_opn(c, f, t1.s, r)
    elseif k1 == KBcases
        return p_cases(c, f, r)
    elseif k1 == KCases && t2 !== nothing
        is_lp(t2) || return nothing
        return p_cases(c, f, tdrop(ts, 2))
    elseif t1 isa TEsc && iskw(t2, KLb)
        x = p_json(f, tdrop(ts, 2))
        (x !== nothing && x[1] isa JObj && kat(x[2], 1, KRb) && kat(x[2], 2, KLb)) ||
            return nothing
        y = p_list(c, f, 1, tdrop(x[2], 2))
        (y !== nothing && kat(y[2], 1, KRb)) || return nothing
        op_allowed(t1.s) || return nothing
        return mk_node(t1.s, y[1], x[1].kvs), tdrop(y[2])
    elseif k1 == KEsmnode && t2 !== nothing && tk(ts, 3) isa TTxt && kat(ts, 4, KComma) &&
            tk(ts, 5) isa TCode && ts[5].j isa JObj
        is_lp(t2) || return nothing
        x = p_esc_args(c, f, tdrop(ts, 5))
        x === nothing && return nothing
        o = ts[3].s
        op_allowed(o) || return nothing
        return mk_node(o, x[1], copy(ts[5].j.kvs)), x[2]
    elseif k1 == KDotacc && iskw(t2, KLb)
        x = p_or(c, f, tdrop(ts, 2))
        (x !== nothing && kat(x[2], 1, KRb)) || return nothing
        return d_node(x[1], "t"), tdrop(x[2])
    elseif k1 == KCdot && iskw(t2, KLp)
        x = p_or(c, f, tdrop(ts, 2))
        (x !== nothing && kat(x[2], 1, KRp)) || return nothing
        return d_node(x[1], "t"), tdrop(x[2])
    elseif k1 !== nothing && t2 !== nothing
        is_lp(t2) || return nothing
        rr = tdrop(ts, 2)
        k1 == KLog && return p_fn1(c, f, "log", rr)
        k1 == KAbs && return p_fn1(c, f, "abs", rr)
        k1 == KFloor && return p_fn1(c, f, "floor", rr)
        k1 == KCeil && return p_fn1(c, f, "ceil", rr)
        o = fn_of(k1)
        o !== nothing && return p_fn1(c, f, o, rr)
        return nothing
    elseif t1 isa TWord
        return p_word(c, t1.s, r)
    end
    euler_head(c, ts) && return p_euler_exp(c, f, tdrop(ts, 2))
    return p_name_prim(c, ts)
end

"""`Math.pEulerExp`: `\\exp` written as a power of e."""
function p_euler_exp(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    y = p_expo(c, f, ts)
    y === nothing && return nothing
    return node("exp", Any[y[1]]), y[2]
end

"""`Math.pSetSeg`: one segment of an index set's name: an upright word `upSet` sets
upright, or a name segment."""
function p_set_seg(sf::Sf, ts::Toks)
    t = tk(ts)
    if t isa TUps && length(t.ps) == 1 && t.ps[1][2] == ""
        g = collect(Char, t.ps[1][1])
        up_set(sf, g) && return g, tdrop(ts)
    end
    return p_seg(sf, ts)
end

"""`Math.pSet`: an index set's name, its segments joined by the scope dot."""
function p_set(sf::Sf, ts::Toks)
    x = p_set_seg(sf, ts)
    x === nothing && return nothing
    acc, r = x
    acc = copy(acc)
    while true
        if kat(r, 1, KSdot)
            y = p_set_seg(sf, tdrop(r))
            y === nothing && return nothing
            push!(acc, '.')
            append!(acc, y[1])
            r = y[2]
        else
            return String(acc), r
        end
    end
    return nothing
end

"""`Math.pRange`: a range row: `k \\in S`, `k \\in S(i, j)`, `a \\le k \\le b`."""
function p_range(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_add(c, f, ts)
    x === nothing && return nothing
    v, r = x
    if v isa String && kat(r, 1, KInn)
        y = p_set(c.sf, tdrop(r))
        y === nothing && return nothing
        s, r2 = y
        if kat(r2, 1, KLp)
            z = p_names(c.sf, tdrop(r2))
            (z !== nothing && kat(z[2], 1, KRp)) || return nothing
            return rng(v, JObj(Kvs(["from" => s, "of" => JArr(Any[p for p in z[1]])]))),
                tdrop(z[2])
        end
        return rng(v, JObj(Kvs(["from" => s]))), r2
    elseif kat(r, 1, KLe)
        y = p_add(c, f, tdrop(r))
        (y !== nothing && y[1] isa String && kat(y[2], 1, KLe)) || return nothing
        z = p_add(c, f, tdrop(y[2]))
        z === nothing && return nothing
        return rng(y[1], JArr(Any[v, z[1]])), z[2]
    end
    return nothing
end

"""`Math.pRow`: a row ending at a token `is_end` accepts: an expression read
whole first, else a range."""
function p_row(c::Ctx, f::Int, is_end, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_or(c, f, ts)
    if x !== nothing && !isempty(x[2])
        is_end(x[2][1]) && return filt(x[1]), x[2]
        return p_range(c, f, ts)
    end
    return p_range(c, f, ts)
end

"""`Math.pRows`: rows separated by `sep`, up to `close` (consumed)."""
function p_rows(c::Ctx, f::Int, sep::Kw, close::Kw, ts::Toks)
    out = Row[]
    is_end = t -> is_kw(sep, t) || is_kw(close, t)
    while true
        f == 0 && return nothing
        f -= 1
        x = p_row(c, f, is_end, ts)
        (x !== nothing && tk(x[2]) isa TKw) || return nothing
        row, r = x
        push!(out, row)
        k = r[1].k
        if k == sep
            ts = tdrop(r)
        elseif k == close
            return out, tdrop(r)
        else
            return nothing
        end
    end
    return nothing
end

# The `.obj [("args", .arr [.str k, a]), ("op", .str "==")]` pattern of
# `pRedBody`.
function lone_eq(x)
    x isa JObj || return nothing
    kvs = x.kvs
    length(kvs) == 2 || return nothing
    (
        kvs[1].first == "args" && kvs[1].second isa JArr && kvs[2].first == "op" &&
            kvs[2].second == "=="
    ) || return nothing
    xs = kvs[1].second.xs
    (length(xs) == 2 && xs[1] isa String) || return nothing
    return xs[1], xs[2]
end

"""`Math.pRedBody`: a reduction after its operator: the subscript rows, then
the body."""
function p_red_body(c::Ctx, f::Int, red::Symbol, marked::Bool, ts::Toks)
    f == 0 && return nothing
    f -= 1
    rows = if c.sf == SF_LATEX
        if kat(ts, 1, KUs) && kat(ts, 2, KLb) && kat(ts, 3, KSubstack) && kat(ts, 4, KLb)
            x = p_rows(c, f, KNl, KRb, tdrop(ts, 4))
            (x !== nothing && kat(x[2], 1, KRb)) ? (x[1], tdrop(x[2])) : nothing
        elseif kat(ts, 1, KUs) && kat(ts, 2, KLb)
            x = p_row(c, f, t -> is_kw(KRb, t), tdrop(ts, 2))
            if x !== nothing && x[1].tag === :filt && kat(x[2], 1, KRb) && kat(x[2], 2, KCaret) &&
                    kat(x[2], 3, KLb) && lone_eq(x[1].v) !== nothing && kat(x[2], 4, KLset)
                # A lone equality filter followed by a superscript set is the filter.
                ([x[1]], tdrop(x[2]))
            elseif x !== nothing && x[1].tag === :filt && kat(x[2], 1, KRb) &&
                    kat(x[2], 2, KCaret) && kat(x[2], 3, KLb) && lone_eq(x[1].v) !== nothing
                k, a = lone_eq(x[1].v)
                y = p_or(c, f, tdrop(x[2], 3))
                (y !== nothing && kat(y[2], 1, KRb)) ? ([rng(k, JArr(Any[a, y[1]]))], tdrop(y[2])) :
                    nothing
            elseif x !== nothing && kat(x[2], 1, KRb)
                ([x[1]], tdrop(x[2]))
            else
                nothing
            end
        else
            (Row[], ts)
        end
    else
        if kat(ts, 1, KUs) && kat(ts, 2, KLpg)
            p_rows(c, f, KNl, KRp, tdrop(ts, 2))
        else
            (Row[], ts)
        end
    end
    rows === nothing && return nothing
    rs, r = rows
    pp = row_parts(Row[x for x in rs])
    sup = p_sup(c.sf, r)
    (pp !== nothing && sup !== nothing) || return nothing
    # A `\\limits` head's `args` are the body's arrays: it carries no set.
    (marked && !isempty(sup[1])) && return nothing
    body = p_mul(c, f, sup[2])
    body === nothing && return nothing
    rg, fl = pp
    return FaqForm(red, marked, Any[], rg, body[1], fl, sup[1]), body[2]
end

function strip_toks(r::Toks, tail::Vector{Tok})
    length(r) >= length(tail) || return nothing
    for i in eachindex(tail)
        r[i] == tail[i] || return nothing
    end
    return tdrop(r, length(tail))
end

const LATEX_WRAP_CLOSE = Tok[TKw(KRbkg)]
const LATEX_WRAP_SUB = Tok[TKw(KUs), TKw(KLb)]
const TYPST_WRAP_CLOSE = Tok[TKw(KRbk), TKw(KRp)]
const TYPST_WRAP_SUB = Tok[TKw(KUs), TKw(KLpg)]

# The bracket form of `Math.pRed`: the reduction, the closing bracket, the
# superscript set if any, then the output entries in the subscript.
function p_red_wrapped(c::Ctx, f::Int, r::Toks, wclose::Vector{Tok}, sub::Vector{Tok}, close::Kw)
    h = p_red_head(c.sf, r)
    h === nothing && return nothing
    red, marked, r1 = h
    b = p_red_body(c, f, red, marked, r1)
    b === nothing && return nothing
    form, r2 = b
    # The set of a wrapped reduction is written on its bracket only.
    isempty(form.set) || return nothing
    r3 = strip_toks(r2, wclose)
    r3 === nothing && return nothing
    sp = p_sup(c.sf, r3)
    sp === nothing && return nothing
    st, r4 = sp
    (form.marked && !isempty(st)) && return nothing
    r5 = strip_toks(r4, sub)
    r5 === nothing && return nothing
    e = p_rows(c, f, KComma, close, r5)
    e === nothing && return nothing
    es, r6 = e
    ep = entry_parts(es)
    ep === nothing && return nothing
    return faq_json(with_sup(with_out(form, ep[1], ep[2]), st)), r6
end

"""`Math.pRed`: a rank-0 reduction, or a reduction wrapped with its output
entries."""
function p_red(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    if kat(ts, 1, KLbkg)
        return p_red_wrapped(c, f, tdrop(ts), LATEX_WRAP_CLOSE, LATEX_WRAP_SUB, KRb)
    elseif kat(ts, 1, KLr) && kat(ts, 2, KLp) && kat(ts, 3, KLbk)
        return p_red_wrapped(c, f, tdrop(ts, 3), TYPST_WRAP_CLOSE, TYPST_WRAP_SUB, KRp)
    end
    h = p_red_head(c.sf, ts)
    h === nothing && return nothing
    red, marked, r1 = h
    b = p_red_body(c, f, red, marked, r1)
    b === nothing && return nothing
    return faq_json(b[1]), b[2]
end

"""`Math.pFn1`: `f(x)` after the opening parenthesis."""
function p_fn1(c::Ctx, f::Int, o::AbstractString, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_or(c, f, ts)
    (x !== nothing && kat(x[2], 1, KRp)) || return nothing
    return node(o, Any[x[1]]), tdrop(x[2])
end

is_rm(t, s::AbstractString) = t isa TRm && t.s == s

"""`Math.pFracL`: after `\\frac{`: a time or spatial derivative, the italic-d
variant, or a quotient."""
function p_frac_l(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    t1 = tk(ts)
    if is_rm(t1, "d") && kat(ts, 2, KRb) && kat(ts, 3, KLb) && is_rm(tk(ts, 4), "d") &&
            tk(ts, 5) == TLetter('t') && kat(ts, 6, KRb)
        return p_d_apply(c, f, "t", tdrop(ts, 6))
    elseif is_rm(t1, "d")
        x = p_or(c, f, tdrop(ts))
        x === nothing && return nothing
        r = x[2]
        if kat(r, 1, KRb) && kat(r, 2, KLb) && is_rm(tk(r, 3), "d") && tk(r, 4) == TLetter('t') &&
                kat(r, 5, KRb)
            return d_node(x[1], "t"), tdrop(r, 5)
        end
        return nothing
    elseif iskw(t1, KPdiff) && kat(ts, 2, KRb) && kat(ts, 3, KLb) && kat(ts, 4, KPdiff)
        y = p_name(c.sf, tdrop(ts, 4))
        (y !== nothing && kat(y[2], 1, KRb)) || return nothing
        return p_d_apply(c, f, y[1], tdrop(y[2]))
    elseif iskw(t1, KPdiff) && kat(ts, 2, KUs)
        # `\frac{\partial_{x}(…)}{…}`: a quotient whose numerator is `partial` with
        # trailing operands.
        x = p_or(c, f, ts)
        (x !== nothing && kat(x[2], 1, KRb) && kat(x[2], 2, KLb)) || return nothing
        y = p_or(c, f, tdrop(x[2], 2))
        (y !== nothing && kat(y[2], 1, KRb)) || return nothing
        return node("/", Any[x[1], y[1]]), tdrop(y[2])
    elseif iskw(t1, KPdiff)
        x = p_or(c, f, tdrop(ts))
        x === nothing && return nothing
        r = x[2]
        (kat(r, 1, KRb) && kat(r, 2, KLb) && kat(r, 3, KPdiff)) || return nothing
        y = p_name(c.sf, tdrop(r, 3))
        (y !== nothing && kat(y[2], 1, KRb)) || return nothing
        return deriv_node(x[1], y[1]), tdrop(y[2])
    end
    p = p_italic_d(c, ts)
    p !== nothing && return p
    x = p_or(c, f, ts)
    (x !== nothing && kat(x[2], 1, KRb) && kat(x[2], 2, KLb)) || return nothing
    y = p_or(c, f, tdrop(x[2], 2))
    (y !== nothing && kat(y[2], 1, KRb)) || return nothing
    return node("/", Any[x[1], y[1]]), tdrop(y[2])
end

"""`Math.pDT`: `(dif N)/(dif t)` and `(partial u)/(partial x)` after the first
`(dif` / `(partial`."""
function p_dt(c::Ctx, f::Int, k::Kw, ts::Toks)
    f == 0 && return nothing
    f -= 1
    if kat(ts, 1, KRp) && kat(ts, 2, KSlash) && kat(ts, 3, KLpg) && tk(ts, 4) isa TKw
        ts[4].k == k || return nothing
        y = p_name(c.sf, tdrop(ts, 4))
        (y !== nothing && kat(y[2], 1, KRp)) || return nothing
        (k == KDif && y[1] != "t") && return nothing
        return p_d_apply(c, f, y[1], tdrop(y[2]))
    end
    x = p_or(c, f, ts)
    x === nothing && return nothing
    r = x[2]
    (kat(r, 1, KRp) && kat(r, 2, KSlash) && kat(r, 3, KLpg) && tk(r, 4) isa TKw) ||
        return nothing
    r[4].k == k || return nothing
    y = p_name(c.sf, tdrop(r, 4))
    (y !== nothing && kat(y[2], 1, KRp)) || return nothing
    (k == KDif && y[1] != "t") && return nothing
    return deriv_node(x[1], y[1]), tdrop(y[2])
end

"""`Math.pDApply`: a derivative operator applied to a parenthesized operand."""
function p_d_apply(c::Ctx, f::Int, w::AbstractString, ts::Toks)
    f == 0 && return nothing
    f -= 1
    kat(ts, 1, KLpg) || return nothing
    x = p_or(c, f, tdrop(ts))
    (x !== nothing && is_rp(tk(x[2]))) || return nothing
    return deriv_node(x[1], w), tdrop(x[2])
end

"""`Math.pCases`: `cases` rows; a chain re-nests to the right."""
function p_cases(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    return nested(_p_cases, c, f - 1, ts)
end

# The body of `p_cases`, with its construct open (Rust `Nest::enter`).
function _p_cases(c::Ctx, f::Int, ts::Toks)
    x = p_or(c, f, ts)
    x === nothing && return nothing
    v, r0 = x
    (kat(r0, 1, KAmp) && tk(r0, 2) isa TTxt) || return nothing
    t = r0[2].s
    r = tdrop(r0, 2)
    if t == "otherwise"
        c.sf == SF_LATEX && kat(r, 1, KEcases) && return v, tdrop(r)
        c.sf == SF_TYPST && kat(r, 1, KRp) && return v, tdrop(r)
        return nothing
    elseif t == "if "
        y = p_or(c, f, r)
        (y !== nothing && tk(y[2]) isa TKw) || return nothing
        cnd, r2 = y
        brk = c.sf == SF_LATEX ? KNl : KComma
        r2[1].k == brk || return nothing
        z = p_cases(c, f, tdrop(r2))
        z === nothing && return nothing
        return node("ifelse", Any[cnd, v, z[1]]), z[2]
    end
    return nothing
end

"""`Math.matHead`: the Typst `makearray` table head `mat(delim: "[", augment: #1,`
([`MAT_HEAD`](@ref)); `delim` and `augment` are plain words, read as the head
only at this position."""
function mat_head(ts::Toks)
    length(ts) >= length(MAT_HEAD) || return false
    for i in eachindex(MAT_HEAD)
        ts[i] == MAT_HEAD[i] || return false
    end
    return true
end

"""`Math.pPair`: a bound pair after its `[`: `a, b]`."""
function p_pair(c::Ctx, f::Int, ts::Toks)
    f == 0 && return nothing
    f -= 1
    x = p_or(c, f, ts)
    (x !== nothing && kat(x[2], 1, KComma)) || return nothing
    y = p_or(c, f, tdrop(x[2]))
    (y !== nothing && kat(y[2], 1, KRbk)) || return nothing
    return (x[1], y[1]), tdrop(y[2])
end

"""`Math.pRegTail`: the further bound pairs of a region, each after `\\times`
and its `[`. Inside a region `\\times [` after a pair is always the next pair:
the pair is read by [`p_pair`](@ref), never as a product operand."""
function p_reg_tail(c::Ctx, f::Int, ts::Toks)
    out = Tuple{Any, Any}[]
    while true
        f == 0 && return nothing
        f -= 1
        (kat(ts, 1, KTimes) && kat(ts, 2, KLbk)) || return out, ts
        x = p_pair(c, f, tdrop(ts, 2))
        x === nothing && return nothing
        push!(out, x[1])
        ts = x[2]
    end
    return nothing
end

"""`Math.pMkRows`: the rows of a `makearray` table: a value, the cell separator
`csep`, a region; rows separated by `rsep`, up to `close` (consumed)."""
function p_mk_rows(c::Ctx, f::Int, csep::Kw, rsep::Kw, close::Kw, ts::Toks)
    out = Tuple{Any, Vector{Tuple{Any, Any}}}[]
    while true
        f == 0 && return nothing
        f -= 1
        x = p_or(c, f, ts)
        (x !== nothing && kat(x[2], 1, csep) && kat(x[2], 2, KLbk)) || return nothing
        v = x[1]
        p = p_pair(c, f, tdrop(x[2], 2))
        p === nothing && return nothing
        q = p_reg_tail(c, f, p[2])
        (q !== nothing && tk(q[2]) isa TKw) || return nothing
        ps, r2 = q
        push!(out, (v, pushfirst!(ps, p[1])))
        k2 = r2[1].k
        if k2 == rsep
            ts = tdrop(r2)
        elseif k2 == close
            return out, tdrop(r2)
        else
            return nothing
        end
    end
    return nothing
end

"""`Math.pEscArgs`: Typst escape arguments: `, a` repeated, then `)`."""
function p_esc_args(c::Ctx, f::Int, ts::Toks)
    out = Any[]
    while true
        f == 0 && return nothing
        f -= 1
        if kat(ts, 1, KRp)
            return out, tdrop(ts)
        elseif kat(ts, 1, KComma)
            x = p_or(c, f, tdrop(ts))
            x === nothing && return nothing
            push!(out, x[1])
            ts = x[2]
        else
            return nothing
        end
    end
    return nothing
end

"""`Math.need` (RoundTrip.lean): the fuel a token list of length `len` is read
with at level `L`."""
need(l::Int, len::Int) = 30 * len + max(12 - l, 0)

"""`Math.parseToks` (Induct.lean): read a whole token list: an expression, or
an equation in its defining form (`x_s = …, s ∈ S`, `unlift`)."""
function parse_toks(sf::Sf, s::Sym, ts::Toks)
    c = Ctx(sf, s)
    f = need(1, length(ts))
    x = p_or(c, f, ts)
    x === nothing && return nothing
    q, r = x
    isempty(r) && return q
    kat(r, 1, KComma) || return nothing
    rows = p_tail(c, f, tdrop(r))
    rows === nothing && return nothing
    parts = row_parts(rows)
    (parts !== nothing && parts[2] === nothing) || return nothing
    return unlift(q, parts[1])
end

"""`Math.pTail`: range rows separated by commas, to the end of the input: the
ranges of a defining equation's output indices (`x_s = …, s \\in S`)."""
function p_tail(c::Ctx, f::Int, ts::Toks)
    out = Row[]
    is_end = t -> is_kw(KComma, t)
    while true
        f == 0 && return nothing
        f -= 1
        x = p_row(c, f, is_end, ts)
        x === nothing && return nothing
        row, r = x
        push!(out, row)
        isempty(r) && return out
        kat(r, 1, KComma) || return nothing
        ts = tdrop(r)
    end
    return nothing
end

end # module MParse
