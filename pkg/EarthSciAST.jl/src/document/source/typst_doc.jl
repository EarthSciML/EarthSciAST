"""
Typst documents: printing and parsing.

Port of `formal/Esm/Document/Source/TypstDoc.lean` (Rust
`document::source::typst_doc`), composed exactly as the Markdown documents
(`SMarkdownDoc`).
"""
module STypstDoc

using ..DJson
using ..DLimits: refused_at!
import ..DMath
import ..DTypstDict
import ..MTypst
using ..MToken: SF_TYPST
using ..MExpr: Sym, name_ok
using ..DStrings: bare_key
using ..SEquation: eq_expr, eq_sides
using ..SSkeleton
using ..SSkeleton: to_doc
import ..SSkeleton: front_key, desc, comp_name, decl_name, attr, eqn, rxn, plot, tm
using ..SItems
using ..SItems: canon_segs, ck_mx, cook_doc, items, mathify_doc, parse_items, pr_mx, raw_doc, unitems
using ..SLines: decode_text
using ..SMarkdownDoc: comment_ok, with_comment
using ..SMultiLine: cook_rows
using ..SText: pre, pre_s, split_line, string_of
using ..STypst: HEADER, arg_ok, args_first_t, item_ok, lex,
    line_end, name_typ, p_args_first, render, rxn_ok, tm_lex_t

"""`Typ.typOf`: an equation's Typst math under the symbol table `s`."""
typ_of(s::Sym, e::Eqn) = collect(Char, DMath.print_typst(s, eq_expr(e)))

"""`Typ.prT`: its `_comment` as a `//` comment line, then the equation."""
function pr_t(s::Sym, e::Eqn)
    t = DMath.print_typst(s, eq_expr(e))
    return e.comment === nothing ? t : string("// ", e.comment, "\n", t)
end

"""`Typ.oneT`: one equation, or several rows separated by `\\` with `&`
alignment."""
function one_t(s::Sym, c, body)
    j = DMath.parse_typst(s, string_of(body))
    lr = j === nothing ? nothing : eq_sides(j)
    lr === nothing || return Eqn[Eqn(c, lr[1], lr[2])]
    ts = MTypst.lex(body)
    ts === nothing && return nothing
    es = cook_rows(SF_TYPST, s, false, ts)
    es === nothing && return nothing
    return with_comment(c, es)
end

"""`Typ.ckT`: read the math text of a display equation."""
function ck_t(s::Sym, raw::AbstractString)
    cs = collect(Char, raw)
    if starts(cs, "// ")
        c, rest = split_line(drop(cs, 3))
        return one_t(s, string_of(c), rest)
    end
    return one_t(s, nothing, cs)
end

"""`Typ.prTx`."""
pr_tx(s::Sym, m) = pr_mx(pr_t, (s, j) -> DMath.print_typst(s, j), s, m)

"""`Typ.ckTx`."""
ck_tx(s::Sym, m) = ck_mx(ck_t, (s, raw) -> DMath.parse_typst(s, raw), s, m)

"""`Typ.capsT`: the Typst container's predicates."""
struct CapsT <: Caps end

front_key(::CapsT, k) = bare_key(DTypstDict.reserved, k)
desc(::CapsT, s) = true
comp_name(::CapsT, n) = true
decl_name(::CapsT, n) = name_ok(n) && !('$' in name_typ(n))
attr(::CapsT, a) = bare_key(DTypstDict.reserved, a.first)

function eqn(::CapsT, s::Sym, e::Eqn)
    t = typ_of(s, e)
    comment_ok(e.comment) || return false
    '$' in t && return false
    pre("//", t) && return false
    return tm_lex_t(collect(Char, pr_t(s, e))) === nothing
end

rxn(::CapsT, s::Sym, x::Rxn) =
    rxn_ok(Rxn(x.id, x.subs, x.prods, DMath.print_typst(s, x.rate), x.attrs))

plot(::CapsT, a) = all(arg_ok, a)

function tm(::CapsT, s::Sym, t::Tm)
    # A rule's match pattern is printed with no templates in the table.
    ms = Sym(s.names, Tuple{String, Vector{String}}[])
    lhs = t.lhs === nothing ? nothing : DMath.print_typst(ms, t.lhs)
    return item_ok(RTm(Tm(t.name, t.params, lhs, DMath.print_typst(s, t.body), t.attrs)))
end

"""`Typ.headerT`."""
function header_t(front)
    out = collect(Char, HEADER)
    args_first_t(front, out)
    push!(out, ')', '\n')
    return out
end

"""`Typ.printTyp`: print a document as Typst."""
function print_typ(d)
    doc = to_doc(CapsT(), d)
    out = header_t(doc.front)
    append!(out, render(canon_segs(items(mathify_doc((s, j) -> DMath.print_typst(s, j), Returns(true), raw_doc(pr_tx, doc))))))
    return String(out)
end

"""`Typ.lexDoc`: read the header and the constructs."""
function lex_doc(s::Chars)
    pre_s(HEADER, s) || return refused_at!("the header", s)
    x = p_args_first(drop(s, length(HEADER)))
    x === nothing && return refused_at!("the header", s)
    front, r = x
    r1 = line_end(r)
    r1 === nothing && return refused_at!("the header", s)
    its = lex(true, r1)
    its === nothing && return nothing
    return front, its
end

"""`Typ.parseTyp`: read a Typst document, after `decodeText`."""
function parse_typ(s::AbstractString)
    x = lex_doc(decode_text(collect(Char, s)))
    x === nothing && return nothing
    return parse_items_t(x[1], x[2])
end

"""`Typ.parseItemsT`."""
parse_items_t(front::Kvs, its) = parse_items(ck_tx, (s, raw) -> DMath.parse_typst(s, raw), front, its)

end # module STypstDoc
