"""
Markdown documents: printing and parsing.

Port of `formal/Esm/Document/Source/MarkdownDoc.lean` (Rust
`document::source::markdown_doc`). The layers compose: the skeleton
(`to_doc` / `of_doc`), the math entries as LaTeX (`raw_doc` / `cook_doc`), the
construct sequence (`items` / `unitems`), and the text (front matter, then the
constructs separated by blank lines).
"""
module SMarkdownDoc

using ..DJson
using ..DLimits: refused_at!
import ..DMath
import ..DYaml
import ..MLatex
using ..MToken: SF_LATEX
using ..MExpr: Sym, name_ok
using ..DStrings: esc_char, is_ident
using ..SEquation: eq_expr, eq_sides
using ..SSkeleton
using ..SSkeleton: to_doc
import ..SSkeleton: front_key, desc, comp_name, decl_name, attr, eqn, rxn, plot, tm
using ..SItems
using ..SItems: canon_segs, ck_mx, cook_doc, items, mathify_doc, parse_items, pr_mx, raw_doc, unitems
using ..SLines: decode_text
using ..SMarkdown: DASHES, FENCE, attr_ok, item_ok, lex,
    name_latex, render, rxn_ok, tm_lex
using ..SMultiLine: cook_rows
using ..SText: blank, no_stop, split_line, string_of, until_stop

# ## Equations in LaTeX

"""`Md.latexOf`: an equation's LaTeX under the symbol table `s`."""
latex_of(s::Sym, e::Eqn) = collect(Char, DMath.print_latex_eqn(s, eq_expr(e)))

"""`Md.prMd`: an equation's math text: its `_comment` as a LaTeX comment line,
then the equation."""
function pr_md(s::Sym, e::Eqn)
    l = DMath.print_latex_eqn(s, eq_expr(e))
    return e.comment === nothing ? l : string("% ", e.comment, "\n", l)
end

"""`Md.envs`: the multi-line environments: `true` when all rows are one
equation."""
const ENVS = (
    ("aligned", false), ("align", false), ("align*", false), ("gathered", false),
    ("split", true), ("multline", true), ("multline*", true),
)

"""`Md.isWsC`."""
is_ws_c(c::Char) = c == ' ' || c == '\n' || c == '\t'

"""`Md.envOf`: a display that is one multi-line environment: whether its rows
are one equation, and the environment's body; or `nothing`."""
function env_of(body)
    i, j = 1, length(body)
    while i <= j && is_ws_c(body[i])
        i += 1
    end
    while j >= i && is_ws_c(body[j])
        j -= 1
    end
    b = view(body, i:j)
    for (e, one) in ENVS
        o = collect(Char, "\\begin{$e}")
        c = collect(Char, "\\end{$e}")
        lb, lo, lc = length(b), length(o), length(c)
        if lb >= lo && lb >= lc && b[1:lo] == o && b[(lb - lc + 1):lb] == c
            n = max(lb - (lo + lc), 0)
            return one, collect(Char, view(b, (lo + 1):(lo + n)))
        end
    end
    return nothing
end

"""`Md.withComment`: the comment goes to the first equation of a display."""
function with_comment(c, es::Vector{Eqn})
    isempty(es) || (es[1] = Eqn(c, es[1].lhs, es[1].rhs))
    return es
end

"""`Md.oneMd`: one display in LaTeX: a multi-line environment, or one
equation."""
function one_md(s::Sym, c, body)
    eo = env_of(body)
    if eo !== nothing
        one, inner = eo
        ts = MLatex.lex(inner)
        ts === nothing && return nothing
        es = cook_rows(SF_LATEX, s, one, ts)
        es === nothing && return nothing
        return with_comment(c, es)
    end
    j = DMath.parse_latex(s, string_of(body))
    j === nothing && return nothing
    lr = eq_sides(j)
    lr === nothing && return nothing
    return Eqn[Eqn(c, lr[1], lr[2])]
end

"""`Md.ckMd`: read the math text of a display equation: an optional leading
comment line `% …`, then the equation."""
function ck_md(s::Sym, raw::AbstractString)
    cs = collect(Char, raw)
    if length(cs) >= 2 && cs[1] == '%' && cs[2] == ' '
        c, rest = split_line(drop(cs, 2))
        return one_md(s, string_of(c), rest)
    end
    return one_md(s, nothing, cs)
end

"""`Md.prMdx`: a math entry's text."""
pr_mdx(s::Sym, m) = pr_mx(pr_md, (s, j) -> DMath.print_latex(s, j), s, m)

"""`Md.ckMdx`: read a math entry's text."""
ck_mdx(s::Sym, m) = ck_mx(ck_md, (s, raw) -> DMath.parse_latex(s, raw), s, m)

"""`Md.commentOK`."""
comment_ok(c) = c === nothing || (!occursin('\n', c) && !occursin('$', c))

# ## What Markdown spells natively

"""`Md.dqOK`: a string whose characters the YAML printer writes as themselves
and without `&`; any other value."""
function dq_ok(v)
    v isa String || return true
    e = Char[]
    for c in v
        empty!(e)
        esc_char(false, c, e)
        (length(e) == 1 && e[1] == c && c != '&') || return false
    end
    return true
end

"""`Md.capsMd`: the Markdown container's predicates."""
struct CapsMd <: Caps end

front_key(::CapsMd, k) = true

function desc(::CapsMd, s)
    t = push!(collect(Char, s), '\n')
    for ind in ("", " ", "  ", "   ")
        no_stop(ind * FENCE, t) || return false
    end
    return !occursin('\r', s)
end

comp_name(::CapsMd, n) = !occursin(']', n) && !occursin('\n', n)

decl_name(::CapsMd, n) =
    name_ok(n) && !('$' in name_latex(n)) && !occursin(']', n) && !occursin('\n', n)

attr(::CapsMd, a) = is_ident(a.first) && dq_ok(a.second)

function eqn(::CapsMd, s::Sym, e::Eqn)
    l = latex_of(s, e)
    comment_ok(e.comment) || return false
    ('$' in l || '\n' in l) && return false
    (!isempty(l) && l[1] == '%') && return false
    env_of(l) === nothing || return false
    return tm_lex(collect(Char, pr_md(s, e))) === nothing
end

rxn(::CapsMd, s::Sym, x::Rxn) =
    rxn_ok(Rxn(x.id, x.subs, x.prods, DMath.print_latex(s, x.rate), x.attrs))

plot(::CapsMd, a) = all(attr_ok, a) && all(kv -> dq_ok(kv.second), a)

function tm(::CapsMd, s::Sym, t::Tm)
    # A rule's match pattern is printed with no templates in the table.
    ms = Sym(s.names, Tuple{String, Vector{String}}[])
    lhs = t.lhs === nothing ? nothing : DMath.print_latex(ms, t.lhs)
    r = Tm(t.name, t.params, lhs, DMath.print_latex(s, t.body), t.attrs)
    return item_ok(RTm(r)) && all(kv -> dq_ok(kv.second), t.attrs)
end

"""`Md.frontMd`: the front matter."""
function front_md(front)
    out = collect(Char, DASHES)
    push!(out, '\n')
    append!(out, DYaml.encode(JObj(Kvs(front))))
    append!(out, DASHES)
    push!(out, '\n')
    return out
end

"""`Md.printMd`: print a document as Markdown."""
function print_md(d)
    doc = to_doc(CapsMd(), d)
    out = front_md(doc.front)
    append!(out, render(canon_segs(items(mathify_doc((s, j) -> DMath.print_latex(s, j), DYaml.plain_math_ok, raw_doc(pr_mdx, doc))))))
    return String(out)
end

"""`Md.lexDoc`: read the front matter and the constructs."""
function lex_doc(s::Chars)
    starts(s, "---\n") || return refused_at!("the front matter", s)
    x = until_stop(DASHES, drop(s, 4))
    x === nothing && return refused_at!("the front matter", s)
    body, sl, rest = x
    blank(sl) || return refused_at!("the front matter", s)
    v = DYaml.decode(body)
    v isa JObj || return refused_at!("the front matter", s)
    its = lex(true, rest)
    its === nothing && return nothing
    return v.kvs, its
end

"""`Md.parseMd`: read a Markdown document, after `decodeText`."""
function parse_md(s::AbstractString)
    x = lex_doc(decode_text(collect(Char, s)))
    x === nothing && return nothing
    return parse_items_md(x[1], x[2])
end

"""`Md.parseItemsMd`."""
parse_items_md(front::Kvs, its) = parse_items(ck_mdx, (s, raw) -> DMath.parse_latex(s, raw), front, its)

end # module SMarkdownDoc
