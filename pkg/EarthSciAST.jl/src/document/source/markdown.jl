"""
The Markdown container: CommonMark with `\$…\$` / `\$\$…\$\$` LaTeX math, fenced
blocks, YAML front matter and remark directives.

Port of `formal/Esm/Document/Source/Markdown.lean` (namespace `Source.Md`;
Rust `document::source::markdown`). The lexer reads a construct where one
starts and otherwise drops one character of prose; a code span is skipped
whole. The Lean functions carry fuel that the document reader gives as the
input length plus one, and every step consumes a character, so the port loops
without it.
"""
module SMarkdown

using ..DJson
import ..DMath
import ..DYaml
using ..DLimits: nested, refused_at!
using ..MExpr: Sym, name_ok, jwf
using ..DStrings: esc_char, hex4, is_ident, parse_key, parse_quoted, print_key, read_ident
using ..SSkeleton
using ..SItems
using ..SItems: Seg, SegItem, SegProse, is_block, render_segs
using ..SReaction: RSurf, id_char, id_ok, p_piece, p_side, side_ok, side_txt
using ..SText: after_s, blank, has_sub, no_stop, pre, pre_s, split_line, string_of, take_while,
    until_stop, sdrop

# ## Spellings

const FENCE_ESM = "```esm:"
const FENCE = "```"
const DD = "\$\$"
const D_MODEL = "::model["
const D_RS = "::reaction-system["
const DASHES = "---"
const DESC_INFO = "description"
const D_PLOT = "::plot{"
const D_RXN = "\$\$\\ce{"
const D_INIT = ":::initialization"
const D_CONS = ":::constraints"
const D_END = ":::"
const D_SUBSYS = "::subsystem["

"""`Md.dRole`."""
d_role(r::Role) = r == R_INIT ? D_INIT : r == R_CONS ? D_CONS : D_END

"""`Md.dkw`: the directive keyword of a declaration."""
dkw(k::DKind) = k == D_VAR ? "var" : k == D_PARAM ? "param" : k == D_SPECIES ? "species" :
    "subsystem"

# ## Path-block keys

"""`Md.escKey`: the JSON escape, and the backtick as `\\u0060`."""
function esc_key(c::Char, out::Vector{Char})
    if c == '`'
        push!(out, '\\', 'u', hex4(UInt32(c))...)
    else
        esc_char(false, c, out)
    end
    return out
end

"""`Md.keyMd`: a path block's key in the fence's info string."""
function key_md(k::AbstractString)
    is_ident(k) && k != DESC_INFO && return collect(Char, k)
    out = Char['"']
    for c in k
        esc_key(c, out)
    end
    push!(out, '"')
    return out
end

"""`Md.parseKeyMd`: a path block's key from the whole info string."""
function parse_key_md(info::Chars)
    if at(info) == '"'
        x = parse_quoted(false, info)
        (x === nothing || !isempty(x[2])) && return nothing
        return x[1]
    end
    s = string_of(info)
    return (is_ident(info) && s != DESC_INFO) ? s : nothing
end

# ## Declarations

"""`Md.nameLatex`: a declared name as LaTeX math under the empty symbol table."""
name_latex(n::AbstractString) = collect(Char, DMath.print_latex(Sym(), String(n)))

# ## Attribute values: YAML scalars and flow collections

"""`Md.flow`: a value as a YAML scalar or flow collection."""
function flow(v, out::Vector{Char})
    if v isa JArr && !isempty(v.xs)
        push!(out, '[')
        for (i, x) in enumerate(v.xs)
            i > 1 && push!(out, ',', ' ')
            flow(x, out)
        end
        push!(out, ']')
    elseif v isa JObj && !isempty(v.kvs)
        push!(out, '{')
        for (i, (k, x)) in enumerate(v.kvs)
            i > 1 && push!(out, ',', ' ')
            append!(out, print_key(false, DYaml.reserved, k))
            push!(out, ':', ' ')
            flow(x, out)
        end
        push!(out, '}')
    else
        append!(out, DYaml.inline(v))
    end
    return out
end

"""[`flow`](@ref) as a new vector."""
flow_v(v) = flow(v, Char[])

"""`Md.pFlow`: a flow collection at `[` or `{`, else a scalar."""
p_flow(s::Chars) = nested(_p_flow, s)

# The body of `p_flow`, with its construct open (Rust `Nest::enter`).
function _p_flow(s::Chars)
    c = at(s)
    c == EOFC && return nothing
    if c == '['
        r = drop(s)
        at(r) == ']' && return JArr(), drop(r)
        x = p_flow(r)
        x === nothing && return nothing
        y = p_items_f(x[2])
        y === nothing && return nothing
        xs = y[1]
        pushfirst!(xs, x[1])
        return JArr(xs), y[2]
    elseif c == '{'
        r = drop(s)
        at(r) == '}' && return JObj(), drop(r)
        e = p_entry_f(r)
        e === nothing && return nothing
        y = p_entries_f(e[2])
        y === nothing && return nothing
        es = y[1]
        pushfirst!(es, e[1])
        return JObj(es), y[2]
    end
    return DYaml.p_inline(s)
end

"""`Md.pItemsF`: the elements after the first, each after `, `, up to `]`."""
function p_items_f(s::Chars)
    out = Any[]
    while true
        if at(s) == ']'
            return out, drop(s)
        elseif at(s) == ',' && at(s, 2) == ' '
            x = p_flow(drop(s, 2))
            x === nothing && return nothing
            push!(out, x[1])
            s = x[2]
        else
            return nothing
        end
    end
    return nothing
end

"""`Md.pEntryF`: one entry, `key: value`."""
function p_entry_f(s::Chars)
    x = parse_key(false, DYaml.reserved, s)
    x === nothing && return nothing
    k, r = x
    (at(r) == ':' && at(r, 2) == ' ') || return nothing
    y = p_flow(drop(r, 2))
    y === nothing && return nothing
    return (k => y[1]), y[2]
end

"""`Md.pEntriesF`: the entries after the first, each after `, `, up to `}`."""
function p_entries_f(s::Chars)
    out = Kvs()
    while true
        if at(s) == '}'
            return out, drop(s)
        elseif at(s) == ',' && at(s, 2) == ' '
            e = p_entry_f(drop(s, 2))
            e === nothing && return nothing
            push!(out, e[1])
            s = e[2]
        else
            return nothing
        end
    end
    return nothing
end

"""`Md.isColl`."""
is_coll(v) = v isa JArr || v isa JObj

"""`Md.sqEsc`: `'` as `&#39;` and `&` as `&amp;`."""
function sq_esc(cs)
    out = Char[]
    for c in cs
        if c == '\''
            append!(out, "&#39;")
        elseif c == '&'
            append!(out, "&amp;")
        else
            push!(out, c)
        end
    end
    return out
end

"""`Md.sqUnesc`: undo `sqEsc`."""
function sq_unesc(cs::Chars)
    out = Char[]
    while !isempty(cs)
        if starts(cs, "&#39;")
            push!(out, '\'')
            cs = drop(cs, 5)
        elseif starts(cs, "&amp;")
            push!(out, '&')
            cs = drop(cs, 5)
        else
            push!(out, cs[1])
            cs = drop(cs)
        end
    end
    return out
end

"""`Md.attrVal`: a scalar as its YAML, a list or object single-quoted."""
function attr_val(v)
    is_coll(v) || return flow_v(v)
    out = Char['\'']
    append!(out, sq_esc(flow_v(v)))
    push!(out, '\'')
    return out
end

"""`Md.attrMd`: `key=value`."""
function attr_md(a, out::Vector{Char})
    append!(out, a.first)
    push!(out, '=')
    append!(out, attr_val(a.second))
    return out
end

"""`Md.attrsMd`: the attributes, separated by spaces."""
function attrs_md(attrs, out::Vector{Char})
    for (i, a) in enumerate(attrs)
        i > 1 && push!(out, ' ')
        attr_md(a, out)
    end
    return out
end

"""`Md.declMd`: `:var[\$N\$]{default=100 units="mol"}`."""
function decl_md(d::Decl)
    out = Char[':']
    append!(out, dkw(d.kind))
    push!(out, '[', '$')
    append!(out, name_latex(d.name))
    push!(out, '$', ']', '{')
    attrs_md(d.attrs, out)
    push!(out, '}')
    return out
end

"""`Md.pQuoted`: a single-quoted value after its opening quote."""
function p_quoted(u::Chars)
    inner, r = take_while(u, c -> c != '\'')
    at(r) == '\'' || return nothing
    y = sq_unesc(inner)
    x = p_flow(y)
    (x === nothing || !isempty(x[2])) && return nothing
    return x[1], drop(r)
end

"""`Md.pAttr`: one attribute."""
function p_attr(s::Chars)
    id, rest = read_ident(s)
    is_ident(id) || return nothing
    k = string_of(id)
    at(rest) == '=' || return nothing
    x = at(rest, 2) == '\'' ? p_quoted(drop(rest, 2)) : p_flow(drop(rest))
    x === nothing && return nothing
    return (k => x[1]), x[2]
end

"""`Md.pAttrsMore`: the attributes after the first, each after a space, up to
the closing brace."""
function p_attrs_more(s::Chars)
    out = Kvs()
    while true
        c = at(s)
        if c == '}'
            return out, drop(s)
        elseif c == ' '
            a = p_attr(drop(s))
            a === nothing && return nothing
            push!(out, a[1])
            s = a[2]
        else
            return nothing
        end
    end
    return nothing
end

"""`Md.pAttrs`: the attributes after the opening brace, up to the closing one."""
function p_attrs(s::Chars)
    at(s) == '}' && return Kvs(), drop(s)
    a = p_attr(s)
    a === nothing && return nothing
    y = p_attrs_more(a[2])
    y === nothing && return nothing
    as_ = y[1]
    pushfirst!(as_, a[1])
    return as_, y[2]
end

"""`Md.declBody`: a declaration after its `[`."""
function decl_body(k::DKind, s::Chars)
    at(s) == '$' || return nothing
    name, r = take_while(drop(s), c -> c != '$')
    starts(r, "\$]{") || return nothing
    n = DMath.parse_latex(Sym(), string_of(name))
    n isa String || return nothing
    a = p_attrs(drop(r, 3))
    a === nothing && return nothing
    return RDecl(Decl(k, n, a[1])), a[2]
end

# ## Block constructs

"""`Md.fenceItem`: a fenced block's construct, from its info string and body."""
function fence_item(info::Chars, body::Chars)
    if string_of(info) == DESC_INFO
        (!isempty(body) && body[end] == '\n') || return nothing
        return RDesc(string_of(view(body, 1:(length(body) - 1))))
    end
    k = parse_key_md(info)
    k === nothing && return nothing
    v = DYaml.decode(body)
    v === nothing && return nothing
    return RBlock(k, v)
end

"""`Md.labelOK`: nothing, or `{#id}`, with spaces around."""
function label_ok(sl::Chars)
    _, t = take_while(sl, c -> c == ' ')
    isempty(t) && return true
    starts(t, "{#") || return false
    r = drop(t, 2)
    (!isempty(r) && r[end] == '}') || return false
    return !('}' in view(r, 1:(length(r) - 1)))
end

"""`Md.fenceAt`: a fenced block after ```` ```esm: ````."""
function fence_at(u::Chars)
    info, after = split_line(u)
    x = until_stop(FENCE, after)
    x === nothing && return nothing
    body, sl, rest = x
    blank(sl) || return nothing
    it = fence_item(info, body)
    return it === nothing ? nothing : (it, rest)
end

# ## Templates and rules

const D_TMPL = ":::template{"
const D_RULE_C = ":::rule{"
const TM_HEAD_L = "\\operatorname{"
const TM_DEF = ") \\coloneqq "
const RULE_HEAD_L = "\\text{rule } \\operatorname{"
const RULE_SEP = ": \\; "
const RULE_ARROW = " \\Rightarrow "

"""`Md.paramsTxt`: the parameters of a template header, separated by `, `."""
function params_txt(ps, out::Vector{Char})
    for (i, p) in enumerate(ps)
        i > 1 && push!(out, ',', ' ')
        append!(out, name_latex(p))
    end
    return out
end

"""`Md.tmRaw`: the math text of a template or rule display (one line)."""
function tm_raw(t::Tm)
    name = collect(Char, t.name)
    out = Char[]
    if t.lhs === nothing
        append!(out, TM_HEAD_L)
        append!(out, DMath.esc_t(name))
        push!(out, '}', '(')
        params_txt(t.params, out)
        append!(out, TM_DEF)
        append!(out, t.body)
    else
        append!(out, RULE_HEAD_L)
        append!(out, DMath.esc_t(name))
        push!(out, '}')
        append!(out, RULE_SEP)
        append!(out, t.lhs)
        append!(out, RULE_ARROW)
        append!(out, t.body)
    end
    return out
end

"""`Md.pName`: one parameter, up to the next `,` or `)`."""
function p_name(s::Chars)
    a, rest = take_while(s, c -> c != ',' && c != ')')
    n = DMath.parse_latex(Sym(), string_of(a))
    return n isa String ? (n, rest) : nothing
end

"""`Md.pParams`: the parameters after `(`, up to `) \\coloneqq `."""
function p_params(s::Chars)
    out = String[]
    while true
        r0 = after_s(TM_DEF, s)
        r0 === nothing || return out, r0
        x = p_name(s)
        x === nothing && return nothing
        n, r = x
        push!(out, n)
        r1 = after_s(TM_DEF, r)
        r1 === nothing || return out, r1
        (at(r) == ',' && at(r, 2) == ' ') || return nothing
        s = drop(r, 2)
    end
    return nothing
end

"""`Md.splitAt`: split at the first occurrence of `sep`."""
function split_at(sep::AbstractString, s::Chars)
    for i in 0:(length(s) - 1)
        if pre_s(sep, drop(s, i))
            return view(s, 1:i), drop(s, i + length(sep))
        end
    end
    return nothing
end

"""`Md.tmLex`: read the math text of a display as a template or rule: the
name, the parameters, a rule's left-hand side (`nothing` for a template) and
the body; or `nothing`."""
function tm_lex(raw::Chars)
    u = after_s(RULE_HEAD_L, raw)
    if u !== nothing
        x = DMath.raw_b(0, u)
        x === nothing && return nothing
        nm, u1 = x
        u2 = after_s(RULE_SEP, u1)
        u2 === nothing && return nothing
        y = split_at(RULE_ARROW, u2)
        y === nothing && return nothing
        l, b = y
        return string_of(DMath.unesc_t(nm)), String[], collect(Char, l), collect(Char, b)
    end
    u = after_s(TM_HEAD_L, raw)
    u === nothing && return nothing
    x = DMath.raw_b(0, u)
    x === nothing && return nothing
    nm, u1 = x
    at(u1) == '(' || return nothing
    y = p_params(drop(u1))
    y === nothing && return nothing
    return string_of(DMath.unesc_t(nm)), y[1], nothing, collect(Char, y[2])
end

"""`Md.mathAt`: a display after its opening `\$\$`: a template or rule when its
math reads as one, otherwise an equation (optionally labelled)."""
function math_at(u::Chars)
    first_line, after = split_line(u)
    blank(first_line) || return nothing
    x = until_stop(DD, after)
    x === nothing && return nothing
    body, sl, rest = x
    (!isempty(body) && body[end] == '\n') || return nothing
    b = view(body, 1:(length(body) - 1))
    t = tm_lex(b)
    if t !== nothing
        n, ps, l, bd = t
        blank(sl) || return nothing
        return RTm(Tm(n, ps, l === nothing ? nothing : String(l), String(bd), Kvs())), rest
    end
    label_ok(sl) || return nothing
    return REqn(string_of(b)), rest
end

"""`Md.tmContAt`: a template or rule with other fields, after `:::template{`
or `:::rule{`."""
function tm_cont_at(u::Chars)
    x = p_attrs(u)
    x === nothing && return nothing
    as_, r = x
    at(r) == '\n' || return nothing
    r1 = drop(r)
    pre_s(DD, r1) || return nothing
    y = math_at(drop(r1, 2))
    y === nothing && return nothing
    it, r2 = y
    it isa RTm || return nothing
    l, r3 = split_line(sdrop(r2, 3))
    (pre_s(D_END, r2) && blank(l)) || return nothing
    t = it.t
    return RTm(Tm(t.name, t.params, t.lhs, t.body, as_)), r3
end

"""`Md.dirAt`: a component directive after its `[`."""
function dir_at(k::Kind, u::Chars)
    name, t = take_while(u, c -> c != ']' && c != '\n')
    at(t) == ']' || return nothing
    l, r = split_line(drop(t))
    blank(l) || return nothing
    return RComp(k, string_of(name)), r
end

# ## Reactions

"""`Md.latexR`: LaTeX under the empty symbol table."""
const LATEX_R = RSurf(
    s -> DMath.parse_latex(Sym(), s),
    j -> collect(Char, DMath.print_latex(Sym(), j)),
    collect(Char, "\\varnothing"),
)

const ARROW_L = " ->[{\$"
const ARROW_R = "}] "
const RXN_END = "}\$\$ {#"

"""`Md.rxnBody`: the text of a reaction line after `\$\$\\ce{`."""
function rxn_body(x::Rxn)
    out = side_txt(LATEX_R, x.subs)
    append!(out, ARROW_L)
    append!(out, x.rate)
    push!(out, '$')
    append!(out, ARROW_R)
    append!(out, side_txt(LATEX_R, x.prods))
    append!(out, RXN_END)
    append!(out, x.id)
    for b in x.attrs
        push!(out, ' ')
        attr_md(b, out)
    end
    push!(out, '}', '\n')
    return out
end

"""`Md.rxnAt`: a reaction line after its `\$\$\\ce{`."""
function rxn_at(u::Chars)
    x = p_side(LATEX_R, u)
    x === nothing && return nothing
    subs, u1 = x
    u2 = after_s(ARROW_L, u1)
    u2 === nothing && return nothing
    y = p_piece(u2)
    y === nothing && return nothing
    rate, u2b = y
    u3 = after_s(ARROW_R, u2b)
    u3 === nothing && return nothing
    z = p_side(LATEX_R, u3)
    z === nothing && return nothing
    prods, u4 = z
    u5 = after_s(RXN_END, u4)
    u5 === nothing && return nothing
    id, u5b = take_while(u5, id_char)
    w = p_attrs_more(u5b)
    w === nothing && return nothing
    attrs, u6 = w
    l, r = split_line(u6)
    (isempty(id) || !blank(l)) && return nothing
    return RRxn(Rxn(string_of(id), subs, prods, string_of(rate), attrs)), r
end

"""`Md.subAt`: a subsystem directive after its `::subsystem[`."""
function sub_at(u::Chars)
    name, t = take_while(u, c -> c != ']' && c != '\n')
    starts(t, "]{") || return nothing
    x = p_attrs(drop(t, 2))
    x === nothing && return nothing
    a, r = x
    l, r1 = split_line(r)
    blank(l) || return nothing
    return RDecl(Decl(D_SUB, string_of(name), a)), r1
end

"""`Md.plotAt`: a plot directive after its `::plot{`."""
function plot_at(u::Chars)
    x = p_attrs(u)
    x === nothing && return nothing
    a, r = x
    l, r1 = split_line(r)
    blank(l) || return nothing
    return RPlot(a), r1
end

# ## Containers of initialization equations and constraints

"""`Md.contBody`: the displays of a container, up to its closing `:::` line;
blank lines between them are skipped."""
function cont_body(ro::Role, s::Chars)
    out = RItem[]
    while true
        if pre_s(D_END, s)
            l, r = split_line(drop(s, 3))
            blank(l) || return nothing
            return out, r
        elseif pre_s(DD, s)
            x = math_at(drop(s, 2))
            (x === nothing || !(x[1] isa REqn)) && return nothing
            push!(out, REqx(ro, x[1].s))
            s = x[2]
        elseif at(s) == '\n'
            s = drop(s)
        else
            return nothing
        end
    end
    return nothing
end

"""`Md.contOpen`: a container starts here."""
cont_open(s::Chars) = pre_s(D_INIT, s) || pre_s(D_CONS, s)

"""`Md.contAt`: a container, at its opening line."""
function cont_at(s::Chars)
    ro, n = pre_s(D_INIT, s) ? (R_INIT, length(D_INIT)) : (R_CONS, length(D_CONS))
    l, r = split_line(sdrop(s, n))
    return blank(l) ? cont_body(ro, r) : nothing
end

# ## The lexer

"""`Md.blockOpen`: a block construct starts here."""
block_open(s::Chars) =
    pre_s(FENCE_ESM, s) || pre_s(DD, s) || pre_s(D_MODEL, s) || pre_s(D_RS, s) ||
    pre_s(D_PLOT, s) || pre_s(D_SUBSYS, s) || pre_s(D_TMPL, s) || pre_s(D_RULE_C, s)

"""`Md.declOpen`: a declaration starts here."""
decl_open(s::Chars) = pre_s(":var[", s) || pre_s(":param[", s) || pre_s(":species[", s)

"""`Md.blockAt`: read the block construct that starts here."""
function block_at(s::Chars)
    pre_s(FENCE_ESM, s) && return fence_at(sdrop(s, length(FENCE_ESM)))
    pre_s(D_RXN, s) && return rxn_at(sdrop(s, length(D_RXN)))
    pre_s(DD, s) && return math_at(sdrop(s, length(DD)))
    pre_s(D_MODEL, s) && return dir_at(K_MODEL, sdrop(s, length(D_MODEL)))
    pre_s(D_PLOT, s) && return plot_at(sdrop(s, length(D_PLOT)))
    pre_s(D_SUBSYS, s) && return sub_at(sdrop(s, length(D_SUBSYS)))
    pre_s(D_TMPL, s) && return tm_cont_at(sdrop(s, length(D_TMPL)))
    pre_s(D_RULE_C, s) && return tm_cont_at(sdrop(s, length(D_RULE_C)))
    return dir_at(K_RS, sdrop(s, length(D_RS)))
end

"""`Md.declAt`: read the declaration that starts here."""
function decl_at(s::Chars)
    pre_s(":var[", s) && return decl_body(D_VAR, sdrop(s, length(":var[")))
    pre_s(":param[", s) && return decl_body(D_PARAM, sdrop(s, length(":param[")))
    return decl_body(D_SPECIES, sdrop(s, length(":species[")))
end

# ## The declarations table (an accepted input variant)

const TABLE_OPEN = "| decl | name |"

"""`Md.trimCell`: a cell without its surrounding spaces."""
trim_cell(s::AbstractString) = String(strip(==(' '), s))

"""`Md.headerCells`: the line split at `|`, each cell trimmed."""
header_cells(s::Chars) = map(trim_cell, split(string_of(take_while(s, c -> c != '\n')[1]), '|'))

"""`Md.rateTable`: a line starting with `|` that has a cell `rate`."""
rate_table(s::Chars) = at(s) == '|' && any(==("rate"), header_cells(s))

"""`Md.pCols`: the attribute columns of the header, up to its newline."""
function p_cols(s::Chars)
    out = String[]
    while true
        c = at(s)
        if c == '\n'
            return out, drop(s)
        elseif c == ' '
            id, rest = read_ident(drop(s))
            is_ident(id) || return nothing
            starts(rest, " |") || return nothing
            push!(out, string_of(id))
            s = drop(rest, 2)
        else
            return nothing
        end
    end
    return nothing
end

"""`Md.pCell`: ` value |`, or ` |` when the attribute is absent: `(value or
nothing, rest)`, or `nothing` when malformed."""
function p_cell(s::Chars)
    starts(s, " |") && return nothing, drop(s, 2)
    at(s) == ' ' || return nothing
    x = p_flow(drop(s))
    x === nothing && return nothing
    v, r = x
    starts(r, " |") || return nothing
    return v, drop(r, 2)
end

"""`Md.pCells`: the cells of a row, one per attribute column."""
function p_cells(cols, s::Chars)
    out = Kvs()
    for k in cols
        x = p_cell(s)
        x === nothing && return nothing
        v, r = x
        v === nothing || push!(out, k => v)
        s = r
    end
    return out, s
end

"""`Md.kindOf`: the directive keyword of a row."""
function kind_of(w)
    s = string_of(w)
    s == "var" && return D_VAR
    s == "param" && return D_PARAM
    s == "species" && return D_SPECIES
    s == "subsystem" && return D_SUB
    return nothing
end

"""`Md.pRow`: `| var | \$N\$ |` and the cells, then a newline."""
function p_row(cols, s::Chars)
    starts(s, "| ") || return nothing
    w, rest = read_ident(drop(s, 2))
    k = kind_of(w)
    k === nothing && return nothing
    starts(rest, " | \$") || return nothing
    name, u2 = take_while(drop(rest, 4), c -> c != '$')
    starts(u2, "\$ |") || return nothing
    n = DMath.parse_latex(Sym(), string_of(name))
    n isa String || return nothing
    x = p_cells(cols, drop(u2, 3))
    x === nothing && return nothing
    a, r = x
    at(r) == '\n' || return nothing
    return Decl(k, n, a), drop(r)
end

"""`Md.pRows`: the rows, as long as lines start with `| `."""
function p_rows(cols, s::Chars)
    out = Decl[]
    while starts(s, "| ")
        x = p_row(cols, s)
        x === nothing && return nothing
        push!(out, x[1])
        s = x[2]
    end
    return out, s
end

"""`Md.sepOK`: the separator row."""
sep_ok(l) = all(c -> c == '|' || c == '-' || c == ' ' || c == ':', l)

"""`Md.tableAt`: a declarations table, at its `| decl | name |`."""
function table_at(s::Chars)
    x = p_cols(sdrop(s, length(TABLE_OPEN)))
    x === nothing && return nothing
    cols, r = x
    l, r1 = split_line(r)
    sep_ok(l) || return nothing
    y = p_rows(cols, r1)
    y === nothing && return nothing
    return RItem[RDecl(d) for d in y[1]], y[2]
end

# ## Code spans

"""`Md.afterRun`: the text after the first occurrence of `n` backticks."""
function after_run(n::Int, s::Chars)
    len = length(s)
    for i in 0:(len - 1)
        if len - i >= n && all(j -> s[i + j] == '`', 1:n)
            return drop(s, i + n)
        end
    end
    return nothing
end

"""`Md.skipCode`: the text after the code span that starts here."""
function skip_code(s::Chars)
    run, rest = take_while(s, c -> c == '`')
    r = after_run(length(run), rest)
    return r === nothing ? rest : r
end

"""`Md.lex`: the constructs of a text, skipping prose one character at a time
and code spans whole. A malformed construct is an error (`nothing`)."""
function lex(bol::Bool, s::Chars)
    out = RItem[]
    while !isempty(s)
        c = s[1]
        if bol && block_open(s)
            x = block_at(s)
            x === nothing && return refused_at!("the block", s)
            push!(out, x[1])
            s = x[2]
            bol = true
        elseif decl_open(s)
            x = decl_at(s)
            x === nothing && return refused_at!("the declaration", s)
            push!(out, x[1])
            s = x[2]
            bol = false
        elseif bol && pre_s(TABLE_OPEN, s)
            x = table_at(s)
            x === nothing && return refused_at!("the declarations table", s)
            append!(out, x[1])
            s = x[2]
            bol = true
        elseif bol && cont_open(s)
            x = cont_at(s)
            x === nothing && return refused_at!("the container", s)
            append!(out, x[1])
            s = x[2]
            bol = true
        elseif bol && rate_table(s)
            return refused_at!("a reaction table, which the format does not read,", s)
        elseif c == '`'
            s = skip_code(s)
            bol = false
        else
            bol = c == '\n'
            s = drop(s)
        end
    end
    return out
end

# ## What each construct needs to read back

"""`Md.attrOK`."""
attr_ok(a) = is_ident(a.first) && jwf(a.second)

"""`Md.declOK`."""
decl_ok(d::Decl) = name_ok(d.name) && !('$' in name_latex(d.name)) && all(attr_ok, d.attrs)

"""`Md.mhchemOK`: no escaped brace anywhere inside `\\ce{…}`."""
function mhchem_ok(x::Rxn)
    t = side_txt(LATEX_R, x.subs)
    append!(t, x.rate)
    append!(t, side_txt(LATEX_R, x.prods))
    return !has_sub("\\{", t) && !has_sub("\\}", t)
end

"""`Md.rxnOK`: a reaction the Markdown syntax can hold."""
rxn_ok(x::Rxn) =
    side_ok(LATEX_R, x.subs) && side_ok(LATEX_R, x.prods) && !occursin('$', x.rate) &&
    !occursin('\n', x.rate) && id_ok(x.id) && all(attr_ok, x.attrs) && mhchem_ok(x)

"""`Md.subMd`."""
function sub_md(d::Decl)
    out = collect(Char, D_SUBSYS)
    append!(out, d.name)
    push!(out, ']', '{')
    attrs_md(d.attrs, out)
    push!(out, '}', '\n')
    return out
end

"""`Md.subOK`."""
sub_ok(d::Decl) = !occursin(']', d.name) && !occursin('\n', d.name) && all(attr_ok, d.attrs)

"""`Md.itemMd`: the text of a construct."""
function item_md(it::RItem)
    out = Char[]
    if it isa RDesc
        append!(out, FENCE_ESM)
        append!(out, DESC_INFO)
        push!(out, '\n')
        append!(out, it.s)
        push!(out, '\n')
        append!(out, FENCE)
        push!(out, '\n')
    elseif it isa RBlock
        append!(out, FENCE_ESM)
        append!(out, key_md(it.k))
        push!(out, '\n')
        append!(out, DYaml.encode(it.v))
        append!(out, FENCE)
        push!(out, '\n')
    elseif it isa RComp
        append!(out, it.kind == K_MODEL ? D_MODEL : D_RS)
        append!(out, it.name)
        push!(out, ']', '\n')
    elseif it isa RDecl
        out = it.d.kind == D_SUB ? sub_md(it.d) : decl_md(it.d)
    elseif it isa REqn
        append!(out, DD)
        push!(out, '\n')
        append!(out, it.s)
        push!(out, '\n')
        append!(out, DD)
        push!(out, '\n')
    elseif it isa REqx
        append!(out, d_role(it.role))
        push!(out, '\n')
        append!(out, DD)
        push!(out, '\n')
        append!(out, it.s)
        push!(out, '\n')
        append!(out, DD)
        push!(out, '\n')
        append!(out, D_END)
        push!(out, '\n')
    elseif it isa RRxn
        append!(out, D_RXN)
        append!(out, rxn_body(it.x))
    elseif it isa RPlot
        append!(out, D_PLOT)
        attrs_md(it.a, out)
        push!(out, '}', '\n')
    elseif it isa RTm
        t = it.t
        if isempty(t.attrs)
            append!(out, DD)
            push!(out, '\n')
            append!(out, tm_raw(t))
            push!(out, '\n')
            append!(out, DD)
            push!(out, '\n')
        else
            append!(out, t.lhs === nothing ? D_TMPL : D_RULE_C)
            attrs_md(t.attrs, out)
            push!(out, '}', '\n')
            append!(out, DD)
            push!(out, '\n')
            append!(out, tm_raw(t))
            push!(out, '\n')
            append!(out, DD)
            push!(out, '\n')
            append!(out, D_END)
            push!(out, '\n')
        end
    end
    return out
end

"""`Md.render`: the text of a document body."""
render(segs) = render_segs(item_md, segs)

with_nl(s::AbstractString) = push!(collect(Char, s), '\n')

"""`Md.itemOK`: what each construct's content must satisfy for its text to read
back."""
function item_ok(it::RItem)
    it isa RDesc && return no_stop(FENCE, with_nl(it.s))
    it isa RBlock && return wfmb(it.v)
    it isa RComp && return !occursin(']', it.name) && !occursin('\n', it.name)
    it isa RDecl && return it.d.kind == D_SUB ? sub_ok(it.d) : decl_ok(it.d)
    if it isa REqn
        return no_stop(DD, with_nl(it.s)) && tm_lex(collect(Char, it.s)) === nothing
    end
    if it isa REqx
        return it.role != R_EQN && no_stop(DD, with_nl(it.s)) &&
            tm_lex(collect(Char, it.s)) === nothing
    end
    it isa RRxn && return rxn_ok(it.x)
    it isa RPlot && return all(attr_ok, it.a)
    if it isa RTm
        t = it.t
        raw = tm_raw(t)
        no_stop(DD, push!(copy(raw), '\n')) || return false
        '\n' in raw && return false
        lx = tm_lex(raw)
        lx === nothing && return false
        want_l = t.lhs === nothing ? nothing : collect(Char, t.lhs)
        (
            lx[1] == t.name && lx[2] == t.params && lx[3] == want_l &&
                lx[4] == collect(Char, t.body)
        ) || return false
        return all(attr_ok, t.attrs)
    end
    return false
end

end # module SMarkdown
