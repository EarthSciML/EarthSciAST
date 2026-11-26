"""
The Typst container: markup plus the functions of the `esm` Typst package.

Port of `formal/Esm/Document/Source/Typst.lean` (namespace `Source.Typ`; Rust
`document::source::typst`). The lexer reads a construct where one starts at
the beginning of a line (a declaration anywhere) and otherwise drops one
character of prose. The Lean fuel (the input length plus one, tripled for
values) is never exhausted, since every step consumes a character, so the port
loops without it.
"""
module STypst

using ..DJson
using ..DLimits: refused_at!
import ..DMath
import ..DTypstDict
using ..MExpr: Sym, jwf, name_ok
using ..DStrings: bare_key, is_ident, parse_quoted, quote_str, read_ident
using ..SSkeleton
using ..SItems
using ..SItems: Seg, SegItem, SegProse, is_block, render_segs
using ..SReaction: RSurf, after, id_char, id_ok, p_piece, p_side, side_ok, side_txt
using ..SText: after_s, blank, has_sub, pre_s, split_line, string_of, take_while, sdrop

# ## Spellings

const O_DESC = "#description"
const O_BLOCK = "#esm-block("
const O_MODEL = "#model("
const O_RS = "#reaction-system("
const O_EQ = "\$ "
const O_VAR = "#var("
const O_PARAM = "#param("
const O_SPECIES = "#species("
const O_CE = "#ce["
const O_RXN = "#reaction("
const O_INIT = "#initialization["
const O_CONS = "#constraints["
const O_PLOT = "#plot("
const O_SUB = "#subsystem("
const O_TMPL = "#template("
const O_RULE = "#rule("

"""`Typ.oRole`."""
o_role(r::Role) = r == R_INIT ? O_INIT : r == R_CONS ? O_CONS : O_EQ

"""`Typ.header`: the header's first line and the start of its second."""
const HEADER = "#import \"@preview/esm:0.1.0\": *\n#show: esm-document.with("

# ## Description text
#
# A description is written verbatim as Typst markup, `#description[…]`, when
# `verb_ok` says that markup is safe to typeset, and as a Typst string,
# `#description("…")`, otherwise (`Typ.itemT`). The reader reads a content
# block as Typst does: a backslash escapes the next character and brackets nest.

"""`Typ.alnumA`: an ASCII letter or digit."""
alnum_a(c) = c isa Char && isascii(c) && (isletter(c) || isdigit(c))

"""`Typ.verbOK`: whether a description is written verbatim: none of
`# \$ @ \\ < *`, no `//` or `/*`, every `_` between two ASCII letters or digits,
balanced brackets and an even number of backticks."""
function verb_ok(cs::AbstractVector{Char})
    depth = 0
    ticks = 0
    n = length(cs)
    for i in 1:n
        c = cs[i]
        c in ('#', '\$', '@', '\\', '<', '*') && return false
        nxt = i < n ? cs[i + 1] : nothing
        c == '/' && (nxt == '/' || nxt == '*') && return false
        if c == '_'
            (i > 1 && alnum_a(cs[i - 1]) && alnum_a(nxt)) || return false
        elseif c == '`'
            ticks += 1
        elseif c == '['
            depth += 1
        elseif c == ']'
            depth == 0 && return false
            depth -= 1
        end
    end
    return depth == 0 && iseven(ticks)
end

"""`Typ.readVerb 0`: the text of a content block up to the `]` that closes it,
each backslash escape read as the character it escapes."""
function read_verb(s::Chars)
    out = Char[]
    depth = 0
    while true
        c = at(s)
        c == EOFC && return nothing
        if c == ']'
            depth == 0 && return out, drop(s)
            depth -= 1
        elseif c == '['
            depth += 1
        elseif c == '\\' && length(s) >= 2
            push!(out, s[2])
            s = drop(s, 2)
            continue
        end
        push!(out, c)
        s = drop(s)
    end
    return nothing
end

"""`Typ.argT`: `key: value`."""
function arg_t(a, out::Vector{Char})
    append!(out, a.first)
    push!(out, ':', ' ')
    append!(out, DTypstDict.encode(a.second))
    return out
end

"""`Typ.pArg`: one named argument at its key."""
function p_arg(s::Chars)
    id, rest = read_ident(s)
    k = string_of(id)
    (!is_ident(id) || DTypstDict.reserved(k)) && return nothing
    starts(rest, ": ") || return nothing
    x = DTypstDict.p_val(drop(rest, 2))
    x === nothing && return nothing
    return (k => x[1]), x[2]
end

"""`Typ.pArgsMore`: `, key: value` repeated, up to `)`."""
function p_args_more(s::Chars)
    out = Kvs()
    while true
        if at(s) == ')'
            return out, drop(s)
        elseif starts(s, ", ")
            a = p_arg(drop(s, 2))
            a === nothing && return nothing
            push!(out, a[1])
            s = a[2]
        else
            return nothing
        end
    end
    return nothing
end

"""`Typ.pArgsFirst`: arguments directly after `(`."""
function p_args_first(s::Chars)
    at(s) == ')' && return Kvs(), drop(s)
    a = p_arg(s)
    a === nothing && return nothing
    y = p_args_more(a[2])
    y === nothing && return nothing
    as_ = y[1]
    pushfirst!(as_, a[1])
    return as_, y[2]
end

"""`Typ.argsMoreT`: each `, key: value`."""
function args_more_t(as_, out::Vector{Char})
    for a in as_
        push!(out, ',', ' ')
        arg_t(a, out)
    end
    return out
end

"""`Typ.argsFirstT`: arguments directly after `(`."""
function args_first_t(as_, out::Vector{Char})
    isempty(as_) && return out
    arg_t(as_[1], out)
    args_more_t(view(as_, 2:length(as_)), out)
    return out
end

"""`Typ.argOK`: an identifier key that is not a keyword, and a well-formed
value."""
arg_ok(a) = bare_key(DTypstDict.reserved, a.first) && jwf(a.second)

# ## Constructs

"""`Typ.nameTyp`: a name as Typst math under the empty symbol table."""
name_typ(n::AbstractString) = collect(Char, DMath.print_typst(Sym(), String(n)))

"""`Typ.dkw`."""
dkw(k::DKind) = k == D_VAR ? O_VAR : k == D_PARAM ? O_PARAM : k == D_SPECIES ? O_SPECIES : O_SUB

"""`Typ.declT`: `#var(\$N\$, default: 100)`."""
function decl_t(d::Decl)
    out = collect(Char, dkw(d.kind))
    push!(out, '$')
    append!(out, name_typ(d.name))
    push!(out, '$')
    args_more_t(d.attrs, out)
    push!(out, ')')
    return out
end

"""`Typ.lineEnd`: the rest of a construct's line must be blank."""
function line_end(t::Chars)
    l, r = split_line(t)
    return blank(l) ? r : nothing
end

# ## Reactions

"""`Typ.typR`: Typst math under the empty symbol table."""
const TYP_R = RSurf(
    s -> DMath.parse_typst(Sym(), s),
    j -> collect(Char, DMath.print_typst(Sym(), j)),
    collect(Char, "emptyset"),
)

const ARROW_L = " ->[\$"
const ARROW_R = "] "

"""`Typ.coreT`: the sides and the rate over the arrow."""
function core_t(x::Rxn)
    out = side_txt(TYP_R, x.subs)
    append!(out, ARROW_L)
    append!(out, x.rate)
    push!(out, '$')
    append!(out, ARROW_R)
    append!(out, side_txt(TYP_R, x.prods))
    return out
end

"""`Typ.rxnT`: `#ce[…] <id>`, or `#reaction(…)[#ce[…]] <id>`."""
function rxn_t(x::Rxn)
    out = Char[]
    if isempty(x.attrs)
        append!(out, O_CE)
        append!(out, core_t(x))
        push!(out, ']', ' ', '<')
    else
        append!(out, O_RXN)
        args_first_t(x.attrs, out)
        append!(out, ")[#ce[")
        append!(out, core_t(x))
        push!(out, ']', ']', ' ', '<')
    end
    append!(out, x.id)
    push!(out, '>', '\n')
    return out
end

"""`Typ.coreAt`: subs, rate, prods, and the text after."""
function core_at(u::Chars)
    x = p_side(TYP_R, u)
    x === nothing && return nothing
    subs, u1 = x
    u2 = after_s(ARROW_L, u1)
    u2 === nothing && return nothing
    y = p_piece(u2)
    y === nothing && return nothing
    rate, u2b = y
    u3 = after_s(ARROW_R, u2b)
    u3 === nothing && return nothing
    z = p_side(TYP_R, u3)
    z === nothing && return nothing
    return subs, rate, z[1], z[2]
end

"""`Typ.labelAt`: the label `<id>` and the end of the line."""
function label_at(u::Chars)
    at(u) == '<' || return nothing
    id, w = take_while(drop(u), id_char)
    at(w) == '>' || return nothing
    isempty(id) && return nothing
    r = line_end(drop(w))
    return r === nothing ? nothing : (string_of(id), r)
end

"""`Typ.ceAt`: a reaction after `#ce[`."""
function ce_at(u::Chars)
    x = core_at(u)
    x === nothing && return nothing
    subs, rate, prods, u4 = x
    u5 = after_s("] ", u4)
    u5 === nothing && return nothing
    y = label_at(u5)
    y === nothing && return nothing
    return RRxn(Rxn(y[1], subs, prods, string_of(rate), Kvs())), y[2]
end

"""`Typ.rxnAtT`: a reaction after `#reaction(`."""
function rxn_at_t(u::Chars)
    a = p_args_first(u)
    a === nothing && return nothing
    as_, u1 = a
    u2 = after_s("[#ce[", u1)
    u2 === nothing && return nothing
    x = core_at(u2)
    x === nothing && return nothing
    subs, rate, prods, u4 = x
    u5 = after_s("]] ", u4)
    u5 === nothing && return nothing
    y = label_at(u5)
    y === nothing && return nothing
    return RRxn(Rxn(y[1], subs, prods, string_of(rate), as_)), y[2]
end

# ## Templates and rules

const TM_OP = "op("
const TM_PAR = ")("
const TM_DEF_T = ") := "
const SEP_D = ", \$"

"""`Typ.paramsT`."""
function params_t(ps, out::Vector{Char})
    for (i, p) in enumerate(ps)
        i > 1 && push!(out, ',', ' ')
        append!(out, name_typ(p))
    end
    return out
end

"""`Typ.tmRawT`: the math text of a template display (one line)."""
function tm_raw_t(t::Tm)
    out = collect(Char, TM_OP)
    append!(out, quote_str(true, t.name))
    append!(out, TM_PAR)
    params_t(t.params, out)
    append!(out, TM_DEF_T)
    append!(out, t.body)
    return out
end

"""`Typ.nameLenT`: the length of a parameter name's Typst math: up to the first
`,` or `)` outside parentheses and string literals."""
function name_len_t(s)
    d, q, n, i = 0, false, 0, 1
    len = length(s)
    while i <= len
        c = s[i]
        if q
            if c == '\\'
                i < len || return n + 1
                n += 2
                i += 2
            else
                n += 1
                q = c != '"'
                i += 1
            end
        elseif c == '"'
            n += 1
            q = true
            i += 1
        elseif c == '('
            n += 1
            d += 1
            i += 1
        elseif c == ')'
            d == 0 && return n
            n += 1
            d -= 1
            i += 1
        elseif c == ',' && d == 0
            return n
        else
            n += 1
            i += 1
        end
    end
    return n
end

"""`Typ.pNameT`: a parameter name in a template header."""
function p_name_t(s::Chars)
    k = min(name_len_t(s), length(s))
    n = DMath.parse_typst(Sym(), string_of(view(s, 1:k)))
    return n isa String ? (n, drop(s, k)) : nothing
end

"""`Typ.pParamsT`: the parameters up to `) := `."""
function p_params_t(s::Chars)
    out = String[]
    while true
        r0 = after_s(TM_DEF_T, s)
        r0 === nothing || return out, r0
        x = p_name_t(s)
        x === nothing && return nothing
        n, r = x
        push!(out, n)
        r1 = after_s(TM_DEF_T, r)
        r1 === nothing || return out, r1
        starts(r, ", ") || return nothing
        s = drop(r, 2)
    end
    return nothing
end

"""`Typ.tmLexT`: read the math text of a display as a template: its name,
parameters and body text; or `nothing`."""
function tm_lex_t(raw::Chars)
    u = after_s(TM_OP, raw)
    u === nothing && return nothing
    x = parse_quoted(true, u)
    x === nothing && return nothing
    n, u1 = x
    u2 = after_s(TM_PAR, u1)
    u2 === nothing && return nothing
    y = p_params_t(u2)
    y === nothing && return nothing
    return n, y[1], collect(Char, y[2])
end

"""`Typ.itemT`: the text of a construct."""
function item_t(it::RItem)
    out = Char[]
    if it isa RDesc
        append!(out, O_DESC)
        cs = collect(Char, it.s)
        if verb_ok(cs)
            push!(out, '[')
            append!(out, cs)
            push!(out, ']', '\n')
        else
            push!(out, '(')
            append!(out, quote_str(true, it.s))
            push!(out, ')', '\n')
        end
    elseif it isa RBlock
        append!(out, O_BLOCK)
        append!(out, quote_str(true, it.k))
        push!(out, ',', ' ')
        append!(out, DTypstDict.encode(it.v))
        push!(out, ')', '\n')
    elseif it isa RComp
        append!(out, it.kind == K_MODEL ? O_MODEL : O_RS)
        append!(out, quote_str(true, it.name))
        push!(out, ')', '\n')
    elseif it isa RDecl
        d = it.d
        if d.kind == D_SUB
            append!(out, O_SUB)
            append!(out, quote_str(true, d.name))
            args_more_t(d.attrs, out)
            push!(out, ')', '\n')
        else
            out = decl_t(d)
        end
    elseif it isa REqn
        append!(out, O_EQ)
        append!(out, it.s)
        push!(out, ' ', '$', '\n')
    elseif it isa REqx
        append!(out, o_role(it.role))
        append!(out, O_EQ)
        append!(out, it.s)
        push!(out, ' ', '$', ']', '\n')
    elseif it isa RRxn
        out = rxn_t(it.x)
    elseif it isa RPlot
        append!(out, O_PLOT)
        args_first_t(it.a, out)
        push!(out, ')', '\n')
    elseif it isa RTm
        t = it.t
        if t.lhs !== nothing
            append!(out, O_RULE)
            append!(out, quote_str(true, t.name))
            append!(out, SEP_D)
            append!(out, t.lhs)
            push!(out, '$')
            append!(out, SEP_D)
            append!(out, t.body)
            push!(out, '$')
            args_more_t(t.attrs, out)
            push!(out, ')', '\n')
        elseif isempty(t.attrs)
            append!(out, O_EQ)
            append!(out, tm_raw_t(t))
            push!(out, ' ', '$', '\n')
        else
            append!(out, O_TMPL)
            args_first_t(t.attrs, out)
            push!(out, ')', '[')
            append!(out, O_EQ)
            append!(out, tm_raw_t(t))
            push!(out, ' ', '$', ']', '\n')
        end
    end
    return out
end

"""`Typ.labelOK`: nothing, or `<id>`, with spaces around."""
function label_ok(sl::Chars)
    _, t = take_while(sl, c -> c == ' ')
    isempty(t) && return true
    at(t) == '<' || return false
    r = drop(t)
    (!isempty(r) && r[end] == '>') || return false
    inner = view(r, 1:(length(r) - 1))
    return !('>' in inner) && !('<' in inner)
end

# ## The lexer

const BLOCK_OPENERS = (
    O_DESC, O_BLOCK, O_MODEL, O_RS, O_EQ, O_CE, O_RXN, O_INIT, O_CONS, O_PLOT, O_SUB, O_TMPL, O_RULE,
)

"""`Typ.blockOpen`."""
block_open(s::Chars) = any(o -> pre_s(o, s), BLOCK_OPENERS)

"""`Typ.declOpen`."""
decl_open(s::Chars) = pre_s(O_VAR, s) || pre_s(O_PARAM, s) || pre_s(O_SPECIES, s)

"""`Typ.descAt`: a description after `#description`: a content block, or a
string in parentheses."""
function desc_at(u::Chars)
    if at(u) == '['
        x = read_verb(drop(u))
        x === nothing && return nothing
        t, r = String(x[1]), x[2]
    elseif at(u) == '('
        x = parse_quoted(true, drop(u))
        (x === nothing || at(x[2]) != ')') && return nothing
        t, r = x[1], drop(x[2])
    else
        return nothing
    end
    r1 = line_end(r)
    return r1 === nothing ? nothing : (RDesc(t), r1)
end

"""`Typ.blockAtT`: a path block after `#esm-block(`."""
function block_at_t(u::Chars)
    x = parse_quoted(true, u)
    x === nothing && return nothing
    k, w = x
    starts(w, ", ") || return nothing
    y = DTypstDict.p_val(drop(w, 2))
    y === nothing && return nothing
    v, r = y
    at(r) == ')' || return nothing
    r1 = line_end(drop(r))
    return r1 === nothing ? nothing : (RBlock(k, v), r1)
end

"""`Typ.compAt`."""
function comp_at(k::Kind, u::Chars)
    x = parse_quoted(true, u)
    x === nothing && return nothing
    n, r = x
    at(r) == ')' || return nothing
    r1 = line_end(drop(r))
    return r1 === nothing ? nothing : (RComp(k, n), r1)
end

"""`Typ.dispItem`: a template when the display reads as one, else an
equation."""
function disp_item(raw::Chars)
    x = tm_lex_t(raw)
    x === nothing && return REqn(string_of(raw))
    n, ps, b = x
    return RTm(Tm(n, ps, nothing, String(b), Kvs()))
end

"""`Typ.eqAt`: a display after its `\$ `."""
function eq_at(u::Chars)
    body, r0 = take_while(u, c -> c != '$')
    at(r0) == '$' || return nothing
    l, rest = split_line(drop(r0))
    (!isempty(body) && body[end] == ' ' && label_ok(l)) || return nothing
    return disp_item(view(body, 1:(length(body) - 1))), rest
end

"""`Typ.tmplAtT`: a template with other fields, after `#template(`."""
function tmpl_at_t(u::Chars)
    a = p_args_first(u)
    a === nothing && return nothing
    as_, u1 = a
    u2 = after("[\$ ", u1)
    u2 === nothing && return nothing
    x = p_piece(u2)
    x === nothing && return nothing
    p, r0 = x
    (!isempty(p) && p[end] == ' ' && at(r0) == ']') || return nothing
    y = tm_lex_t(view(p, 1:(length(p) - 1)))
    y === nothing && return nothing
    n, ps, bd = y
    r1 = line_end(drop(r0))
    r1 === nothing && return nothing
    return RTm(Tm(n, ps, nothing, String(bd), as_)), r1
end

"""`Typ.ruleAtT`: a rule, after `#rule(`."""
function rule_at_t(u::Chars)
    x = parse_quoted(true, u)
    x === nothing && return nothing
    n, r = x
    r1 = after_s(SEP_D, r)
    r1 === nothing && return nothing
    y = p_piece(r1)
    y === nothing && return nothing
    l, r2 = y
    r3 = after_s(SEP_D, r2)
    r3 === nothing && return nothing
    z = p_piece(r3)
    z === nothing && return nothing
    b, r4 = z
    w = p_args_more(r4)
    w === nothing && return nothing
    as_, r5 = w
    r6 = line_end(r5)
    r6 === nothing && return nothing
    return RTm(Tm(n, String[], string_of(l), string_of(b), as_)), r6
end

"""`Typ.eqxAt`: an equation in a container after its opener: `\$ … \$]`."""
function eqx_at(ro::Role, u::Chars)
    v = after_s(O_EQ, u)
    v === nothing && return nothing
    x = p_piece(v)
    x === nothing && return nothing
    p, r0 = x
    (!isempty(p) && p[end] == ' ' && at(r0) == ']') || return nothing
    r1 = line_end(drop(r0))
    r1 === nothing && return nothing
    return REqx(ro, string_of(view(p, 1:(length(p) - 1)))), r1
end

"""`Typ.subAtT`: a subsystem directive after `#subsystem(`."""
function sub_at_t(u::Chars)
    x = parse_quoted(true, u)
    x === nothing && return nothing
    n, r = x
    y = p_args_more(r)
    y === nothing && return nothing
    a, r1 = y
    r2 = line_end(r1)
    r2 === nothing && return nothing
    return RDecl(Decl(D_SUB, n, a)), r2
end

"""`Typ.plotAtT`: a plot directive after `#plot(`."""
function plot_at_t(u::Chars)
    x = p_args_first(u)
    x === nothing && return nothing
    a, r = x
    r1 = line_end(r)
    r1 === nothing && return nothing
    return RPlot(a), r1
end

"""`Typ.blockAt`: read the block construct that starts here."""
function block_at(s::Chars)
    d(o) = drop(s, length(o))
    pre_s(O_DESC, s) && return desc_at(d(O_DESC))
    pre_s(O_BLOCK, s) && return block_at_t(d(O_BLOCK))
    pre_s(O_MODEL, s) && return comp_at(K_MODEL, d(O_MODEL))
    pre_s(O_RS, s) && return comp_at(K_RS, d(O_RS))
    pre_s(O_CE, s) && return ce_at(d(O_CE))
    pre_s(O_RXN, s) && return rxn_at_t(d(O_RXN))
    pre_s(O_INIT, s) && return eqx_at(R_INIT, d(O_INIT))
    pre_s(O_CONS, s) && return eqx_at(R_CONS, d(O_CONS))
    pre_s(O_PLOT, s) && return plot_at_t(d(O_PLOT))
    pre_s(O_SUB, s) && return sub_at_t(d(O_SUB))
    pre_s(O_TMPL, s) && return tmpl_at_t(d(O_TMPL))
    pre_s(O_RULE, s) && return rule_at_t(d(O_RULE))
    return eq_at(sdrop(s, length(O_EQ)))
end

"""`Typ.declBody`: a declaration after its opener."""
function decl_body(k::DKind, s::Chars)
    at(s) == '$' || return nothing
    name, u0 = take_while(drop(s), c -> c != '$')
    at(u0) == '$' || return nothing
    n = DMath.parse_typst(Sym(), string_of(name))
    n isa String || return nothing
    x = p_args_more(drop(u0))
    x === nothing && return nothing
    return RDecl(Decl(k, n, x[1])), x[2]
end

"""`Typ.declAt`."""
function decl_at(s::Chars)
    pre_s(O_VAR, s) && return decl_body(D_VAR, drop(s, length(O_VAR)))
    pre_s(O_PARAM, s) && return decl_body(D_PARAM, drop(s, length(O_PARAM)))
    return decl_body(D_SPECIES, sdrop(s, length(O_SPECIES)))
end

"""`Typ.lex`: the constructs of a text, skipping prose one character at a
time."""
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
        else
            bol = c == '\n'
            s = drop(s)
        end
    end
    return out
end

# ## What each construct needs to read back

"""`Typ.typsiumOK`: no `//` or `/*` in the chemistry."""
function typsium_ok(x::Rxn)
    t = side_txt(TYP_R, x.subs)
    append!(t, x.rate)
    append!(t, side_txt(TYP_R, x.prods))
    return !has_sub("//", t) && !has_sub("/*", t)
end

"""`Typ.rxnOK`: a reaction the Typst syntax can hold."""
rxn_ok(x::Rxn) =
    side_ok(TYP_R, x.subs) && side_ok(TYP_R, x.prods) && !occursin('$', x.rate) &&
    !occursin('\n', x.rate) && id_ok(x.id) && all(arg_ok, x.attrs) && typsium_ok(x)

"""`Typ.declOK`."""
decl_ok(d::Decl) = name_ok(d.name) && !('$' in name_typ(d.name)) && all(arg_ok, d.attrs)

"""`Typ.render`."""
render(segs) = render_segs(item_t, segs)

"""`Typ.itemOK`: what each construct's content must satisfy for its text to
read back."""
function item_ok(it::RItem)
    (it isa RDesc || it isa RComp) && return true
    it isa RBlock && return wfmb(it.v)
    it isa RDecl && return it.d.kind == D_SUB ? all(arg_ok, it.d.attrs) : decl_ok(it.d)
    it isa REqn && return !occursin('$', it.s) && tm_lex_t(collect(Char, it.s)) === nothing
    it isa REqx && return it.role != R_EQN && !occursin('$', it.s)
    it isa RRxn && return rxn_ok(it.x)
    it isa RPlot && return all(arg_ok, it.a)
    if it isa RTm
        t = it.t
        all(arg_ok, t.attrs) || return false
        if t.lhs !== nothing
            return !occursin('$', t.lhs) && !occursin('$', t.body) && isempty(t.params)
        end
        raw = tm_raw_t(t)
        '$' in raw && return false
        lx = tm_lex_t(raw)
        lx === nothing && return false
        return lx[1] == t.name && lx[2] == t.params && lx[3] == collect(Char, t.body)
    end
    return false
end

end # module STypst
