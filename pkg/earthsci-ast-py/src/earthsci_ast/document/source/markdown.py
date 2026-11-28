"""Markdown documents: CommonMark with ``$…$`` / ``$$…$$`` LaTeX math, fenced
blocks, YAML front matter and remark directives.

Port of ``formal/Esm/Document/Source/Markdown.lean`` and ``MarkdownDoc.lean``
(namespace ``Source.Md``). The lexer reads a construct where one starts and
otherwise drops one character of prose; a code span is skipped whole. The layers
compose: the skeleton (``to_doc`` / ``of_doc``), the math entries as LaTeX
(``raw_doc`` / ``cook_doc``), the construct sequence (``items`` / ``unitems``),
and the text (front matter, then the constructs separated by blank lines).
"""

from __future__ import annotations

from typing import Any

from .. import limits
from .. import yaml_codec as yaml
from ..math import EMPTY_SYM, latex, parse_latex, print_latex, print_latex_eqn
from ..math import token as K
from ..math.expr import Sym, name_ok
from ..math.printer import esc_t, raw_b, unesc_t
from ..strings import esc_char, hex4, is_ident, parse_key, parse_quoted, print_key, read_ident
from ..value import Obj, wf
from .items import (
    RSurf,
    ck_mx,
    cook_doc,
    cook_doc_blocks,
    cook_rows,
    eq_expr,
    eq_sides,
    id_char,
    id_ok,
    items,
    mathify_doc,
    p_piece,
    p_side,
    pr_mx,
    raw_doc,
    side_ok,
    side_txt,
    unitems,
)
from .skeleton import (
    CONS,
    EQN,
    INIT,
    MODEL,
    PARAM,
    RS,
    SPECIES,
    SUB,
    VAR,
    Caps,
    Decl,
    Eqn,
    Rxn,
    Tm,
    of_doc,
    to_doc,
)
from .text import blank, decode_text, no_stop, split_line, take_while, until_stop

# ## Spellings

FENCE_ESM = "```esm:"
FENCE = "```"
DD = "$$"
D_MODEL = "::model["
D_RS = "::reaction-system["
DASHES = "---"
DESC_INFO = "description"
D_PLOT = "::plot{"
D_RXN = "$$\\ce{"
D_INIT = ":::initialization"
D_CONS = ":::constraints"
D_END = ":::"
D_SUB = "::subsystem["
D_TMPL = ":::template{"
D_RULE_C = ":::rule{"

D_ROLE = {INIT: D_INIT, CONS: D_CONS, EQN: D_END}
DKW = {VAR: "var", PARAM: "param", SPECIES: "species", SUB: "subsystem"}

# ## Path-block keys


def key_md(k: str) -> str:
    """``Md.keyMd``: a path block's key in the fence's info string (the backtick as
    a hex escape)."""
    if is_ident(k) and k != DESC_INFO:
        return k
    return '"' + "".join("\\u" + hex4(96) if c == "`" else esc_char(False, c) for c in k) + '"'


def parse_key_md(info: str):
    """``Md.parseKeyMd``: a path block's key from the whole info string."""
    if info.startswith('"'):
        r = parse_quoted(False, info, 0)
        return r[0] if r is not None and r[1] == len(info) else None
    if is_ident(info) and info != DESC_INFO:
        return info
    return None


def name_latex(n: str) -> str:
    """``Md.nameLatex``: a declared name as LaTeX math under the empty symbol
    table."""
    return print_latex(EMPTY_SYM, n)


# ## Attribute values: YAML scalars and flow collections


def flow(v: Any) -> str:
    """``Md.flow``: a value as a YAML scalar or flow collection."""
    t = type(v)
    if t is list and v:
        return "[" + ", ".join(flow(x) for x in v) + "]"
    if t is Obj and v:
        return (
            "{" + ", ".join(print_key(False, yaml.reserved, k) + ": " + flow(x) for k, x in v) + "}"
        )
    return yaml.inline(v)


def p_flow(s: str, i: int):
    """``Md.pFlow``: a flow collection at ``[`` or ``{``, else a scalar."""
    if not limits.enter():
        return None
    try:
        if i >= len(s):
            return None
        c = s[i]
        if c == "[":
            if s.startswith("]", i + 1):
                return [], i + 2
            r = p_flow(s, i + 1)
            if r is None:
                return None
            out = [r[0]]
            j = r[1]
            while True:
                if s.startswith("]", j):
                    return out, j + 1
                if not s.startswith(", ", j):
                    return None
                r = p_flow(s, j + 2)
                if r is None:
                    return None
                out.append(r[0])
                j = r[1]
        if c == "{":
            if s.startswith("}", i + 1):
                return Obj(), i + 2
            e = _p_entry_f(s, i + 1)
            if e is None:
                return None
            out = [e[0]]
            j = e[1]
            while True:
                if s.startswith("}", j):
                    return Obj(out), j + 1
                if not s.startswith(", ", j):
                    return None
                e = _p_entry_f(s, j + 2)
                if e is None:
                    return None
                out.append(e[0])
                j = e[1]
        return yaml.p_inline(s, i)
    finally:
        limits.leave()


def _p_entry_f(s: str, i: int):
    k = parse_key(False, yaml.reserved, s, i)
    if k is None or not s.startswith(": ", k[1]):
        return None
    r = p_flow(s, k[1] + 2)
    return None if r is None else ((k[0], r[0]), r[1])


def _is_coll(v: Any) -> bool:
    return type(v) is list or type(v) is Obj


def sq_esc(s: str) -> str:
    """``Md.sqEsc``: ``'`` as ``&#39;`` and ``&`` as ``&amp;``."""
    return s.replace("&", "&amp;").replace("'", "&#39;")


def sq_unesc(s: str) -> str:
    """``Md.sqUnesc``: undo ``sqEsc`` (left to right, one pass)."""
    if "&" not in s:
        return s
    out = []
    i, n = 0, len(s)
    while i < n:
        if s.startswith("&#39;", i):
            out.append("'")
            i += 5
        elif s.startswith("&amp;", i):
            out.append("&")
            i += 5
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def attr_val(v: Any) -> str:
    """``Md.attrVal``: a scalar as its YAML, a list or object single-quoted."""
    if _is_coll(v):
        return "'" + sq_esc(flow(v)) + "'"
    return flow(v)


def attr_md(a: tuple) -> str:
    """``Md.attrMd``: ``key=value``."""
    return a[0] + "=" + attr_val(a[1])


def attrs_md(attrs: list) -> str:
    """``Md.attrsMd``: the attributes, separated by spaces."""
    return " ".join(attr_md(a) for a in attrs)


def decl_md(d: Decl) -> str:
    """``Md.declMd``: ``:var[$N$]{default=100 units="mol"}``."""
    return ":" + DKW[d.kind] + "[$" + name_latex(d.name) + "$]{" + attrs_md(d.attrs) + "}"


def _p_quoted(s: str, i: int):
    """``Md.pQuoted``: a single-quoted value after its opening quote."""
    j = s.find("'", i)
    if j < 0:
        return None
    y = sq_unesc(s[i:j])
    r = p_flow(y, 0)
    if r is None or r[1] != len(y):
        return None
    return r[0], j + 1


def _p_attr(s: str, i: int):
    """``Md.pAttr``: one attribute."""
    j = read_ident(s, i)
    k = s[i:j]
    if not is_ident(k) or not s.startswith("=", j):
        return None
    if s.startswith("'", j + 1):
        r = _p_quoted(s, j + 2)
    else:
        r = p_flow(s, j + 1)
    return None if r is None else ((k, r[0]), r[1])


def p_attrs_more(s: str, i: int):
    """``Md.pAttrsMore``: the attributes after the first, each after a space, up to
    the closing brace."""
    out: list = []
    while True:
        if s.startswith("}", i):
            return out, i + 1
        if not s.startswith(" ", i):
            return None
        r = _p_attr(s, i + 1)
        if r is None:
            return None
        out.append(r[0])
        i = r[1]


def p_attrs(s: str, i: int):
    """``Md.pAttrs``: the attributes after the opening brace, up to the closing
    one."""
    if s.startswith("}", i):
        return [], i + 1
    r = _p_attr(s, i)
    if r is None:
        return None
    m = p_attrs_more(s, r[1])
    return None if m is None else ([r[0], *m[0]], m[1])


def _decl_body(k: str, s: str, i: int):
    """``Md.declBody``: a declaration after its ``[``."""
    if not s.startswith("$", i):
        return None
    j = s.find("$", i + 1)
    if j < 0 or not s.startswith("$]{", j):
        return None
    n = parse_latex(EMPTY_SYM, s[i + 1 : j])
    if type(n) is not str:
        return None
    r = p_attrs(s, j + 3)
    return None if r is None else (("decl", Decl(k, n, r[0])), r[1])


# ## Block constructs


def _fence_item(info: str, body: str):
    """``Md.fenceItem``: a fenced block's construct, from its info string and
    body."""
    if info == DESC_INFO:
        if body.endswith("\n"):
            return ("desc", body[:-1])
        return None
    k = parse_key_md(info)
    if k is None:
        return None
    v = yaml.decode(body)
    return None if v is None else ("block", k, v[0])


def _label_ok(sl: str) -> bool:
    """``Md.labelOK``: nothing, or ``{#id}``, with spaces around."""
    t = sl.lstrip(" ")
    if t == "":
        return True
    if t.startswith("{#") and t.endswith("}"):
        inner = t[2:-1]
        return len(t) >= 3 and "}" not in inner
    return False


def _fence_at(s: str, i: int):
    """``Md.fenceAt``: a fenced block after ```` ```esm: ````."""
    a, b = split_line(s, i)
    info = s[i:a]
    r = until_stop(FENCE, s, b)
    if r is None:
        return None
    body, sl, rest = r
    if not blank(sl):
        return None
    it = _fence_item(info, body)
    return None if it is None else (it, rest)


# ## Templates and rules

TM_HEAD_L = "\\operatorname{"
TM_DEF = ") \\coloneqq "
RULE_HEAD_L = "\\text{rule } \\operatorname{"
RULE_SEP = ": \\; "
RULE_ARROW = " \\Rightarrow "


def tm_raw(t: Tm) -> str:
    """``Md.tmRaw``: the math text of a template or rule display (one line)."""
    if t.lhs is None:
        params = ", ".join(name_latex(p) for p in t.params)
        return TM_HEAD_L + esc_t(t.name) + "}(" + params + TM_DEF + t.body
    return RULE_HEAD_L + esc_t(t.name) + "}" + RULE_SEP + t.lhs + RULE_ARROW + t.body


def _p_name(s: str, i: int):
    """``Md.pName``: one parameter, up to the next ``,`` or ``)``."""
    j = take_while(s, i, lambda c: c != "," and c != ")")
    n = parse_latex(EMPTY_SYM, s[i:j])
    return (n, j) if type(n) is str else None


def _p_params(s: str, i: int):
    """``Md.pParams``: the parameters after ``(``, up to ``) \\coloneqq ``."""
    out: list = []
    while True:
        if s.startswith(TM_DEF, i):
            return out, i + len(TM_DEF)
        r = _p_name(s, i)
        if r is None:
            return None
        out.append(r[0])
        j = r[1]
        if s.startswith(TM_DEF, j):
            return out, j + len(TM_DEF)
        if not s.startswith(", ", j):
            return None
        i = j + 2


def tm_lex(raw: str):
    """``Md.tmLex``: read the math text of a display as a template or rule:
    ``(name, params, lhs or None, body)``."""
    if raw.startswith(RULE_HEAD_L):
        r = raw_b(0, raw, len(RULE_HEAD_L))
        if r is None:
            return None
        nm, j = r
        if not raw.startswith(RULE_SEP, j):
            return None
        u2 = j + len(RULE_SEP)
        k = raw.find(RULE_ARROW, u2)
        if k < 0:
            return None
        return unesc_t(nm), [], raw[u2:k], raw[k + len(RULE_ARROW) :]
    if not raw.startswith(TM_HEAD_L):
        return None
    r = raw_b(0, raw, len(TM_HEAD_L))
    if r is None:
        return None
    nm, j = r
    if not raw.startswith("(", j):
        return None
    p = _p_params(raw, j + 1)
    if p is None:
        return None
    return unesc_t(nm), p[0], None, raw[p[1] :]


def _math_at(s: str, i: int):
    """``Md.mathAt``: a display after its opening ``$$``: a template or rule when
    its math reads as one, otherwise an equation (optionally labelled)."""
    a, b = split_line(s, i)
    if not blank(s[i:a]):
        return None
    r = until_stop(DD, s, b)
    if r is None:
        return None
    body, sl, rest = r
    if not body.endswith("\n"):
        return None
    raw = body[:-1]
    tl = tm_lex(raw)
    if tl is not None:
        if not blank(sl):
            return None
        return ("tm", Tm(tl[0], tl[1], tl[2], tl[3], [])), rest
    if not _label_ok(sl):
        return None
    return ("eqn", raw), rest


def _tm_cont_at(s: str, i: int):
    """``Md.tmContAt``: a template or rule with other fields, after
    ``:::template{`` or ``:::rule{``."""
    r = p_attrs(s, i)
    if r is None:
        return None
    as_, j = r
    if not s.startswith("\n", j) or not s.startswith(DD, j + 1):
        return None
    m = _math_at(s, j + 3)
    if m is None or m[0][0] != "tm":
        return None
    t, k = m[0][1], m[1]
    a, b = split_line(s, min(k + 3, len(s)))
    if s.startswith(D_END, k) and blank(s[min(k + 3, len(s)) : a]):
        return ("tm", Tm(t.name, t.params, t.lhs, t.body, as_)), b
    return None


def _dir_at(k: str, s: str, i: int):
    """``Md.dirAt``: a component directive after its ``[``."""
    j = take_while(s, i, lambda c: c != "]" and c != "\n")
    if not s.startswith("]", j):
        return None
    a, b = split_line(s, j + 1)
    if not blank(s[j + 1 : a]):
        return None
    return ("comp", k, s[i:j]), b


# ## Reactions

LATEX_R = RSurf(
    lambda s: parse_latex(EMPTY_SYM, s), lambda j: print_latex(EMPTY_SYM, j), "\\varnothing"
)

ARROW_L = " ->[{$"
ARROW_R = "}] "
RXN_END = "}$$ {#"


def rxn_body(x: Rxn) -> str:
    """``Md.rxnBody``: the text of a reaction line after ``$$\\ce{``."""
    out = side_txt(LATEX_R, x.subs) + ARROW_L + x.rate + "$" + ARROW_R
    out += side_txt(LATEX_R, x.prods) + RXN_END + x.id
    for b in x.attrs:
        out += " " + attr_md(b)
    return out + "}\n"


def _rxn_at(s: str, i: int):
    """``Md.rxnAt``: a reaction line after its ``$$\\ce{``."""
    r = p_side(LATEX_R, s, i)
    if r is None:
        return None
    subs, j = r
    if not s.startswith(ARROW_L, j):
        return None
    p = p_piece(s, j + len(ARROW_L))
    if p is None:
        return None
    rate, j = p
    if not s.startswith(ARROW_R, j):
        return None
    r = p_side(LATEX_R, s, j + len(ARROW_R))
    if r is None:
        return None
    prods, j = r
    if not s.startswith(RXN_END, j):
        return None
    j += len(RXN_END)
    k = take_while(s, j, id_char)
    m = p_attrs_more(s, k)
    if m is None:
        return None
    attrs, k2 = m
    a, b = split_line(s, k2)
    if k == j or not blank(s[k2:a]):
        return None
    return ("rxn", Rxn(s[j:k], subs, prods, rate, attrs)), b


def _sub_at(s: str, i: int):
    """``Md.subAt``: a subsystem directive after its ``::subsystem[``."""
    j = take_while(s, i, lambda c: c != "]" and c != "\n")
    if not s.startswith("]{", j):
        return None
    r = p_attrs(s, j + 2)
    if r is None:
        return None
    a, b = split_line(s, r[1])
    if not blank(s[r[1] : a]):
        return None
    return ("decl", Decl(SUB, s[i:j], r[0])), b


def _plot_at(s: str, i: int):
    """``Md.plotAt``: a plot directive after its ``::plot{``."""
    r = p_attrs(s, i)
    if r is None:
        return None
    a, b = split_line(s, r[1])
    if not blank(s[r[1] : a]):
        return None
    return ("plot", r[0]), b


# ## Containers of initialization equations and constraints


def _cont_body(ro: str, s: str, i: int):
    """``Md.contBody``: the displays of a container, up to its closing ``:::``
    line; blank lines between them are skipped."""
    out: list = []
    while True:
        if s.startswith(D_END, i):
            a, b = split_line(s, i + 3)
            return (out, b) if blank(s[i + 3 : a]) else None
        if s.startswith(DD, i):
            m = _math_at(s, i + 2)
            if m is None or m[0][0] != "eqn":
                return None
            out.append(("eqx", ro, m[0][1]))
            i = m[1]
        elif s.startswith("\n", i):
            i += 1
        else:
            return None


def _cont_at(s: str, i: int):
    """``Md.contAt``: a container, at its opening line."""
    if s.startswith(D_INIT, i):
        ro, n = INIT, len(D_INIT)
    else:
        ro, n = CONS, len(D_CONS)
    start = min(i + n, len(s))
    a, b = split_line(s, start)
    if not blank(s[start:a]):
        return None
    return _cont_body(ro, s, b)


# ## The lexer

_BLOCK_OPENS = (FENCE_ESM, DD, D_MODEL, D_RS, D_PLOT, D_SUB, D_TMPL, D_RULE_C)


def _block_at(s: str, i: int):
    """``Md.blockAt``: read the block construct that starts here."""
    if s.startswith(FENCE_ESM, i):
        return _fence_at(s, i + 7)
    if s.startswith(D_RXN, i):
        return _rxn_at(s, i + 6)
    if s.startswith(DD, i):
        return _math_at(s, i + 2)
    if s.startswith(D_MODEL, i):
        return _dir_at(MODEL, s, i + 8)
    if s.startswith(D_PLOT, i):
        return _plot_at(s, i + 7)
    if s.startswith(D_SUB, i):
        return _sub_at(s, i + 12)
    if s.startswith(D_TMPL, i):
        return _tm_cont_at(s, i + 12)
    if s.startswith(D_RULE_C, i):
        return _tm_cont_at(s, i + 8)
    return _dir_at(RS, s, i + 18)


def _decl_at(s: str, i: int):
    """``Md.declAt``: read the declaration that starts here."""
    if s.startswith(":var[", i):
        return _decl_body(VAR, s, i + 5)
    if s.startswith(":param[", i):
        return _decl_body(PARAM, s, i + 7)
    return _decl_body(SPECIES, s, i + 9)


# ## The declarations table (an accepted input variant)

TABLE_OPEN = "| decl | name |"


def _rate_table(s: str, i: int) -> bool:
    """``Md.rateTable``: a line starting with ``|`` that has a cell ``rate``."""
    if not s.startswith("|", i):
        return False
    j = s.find("\n", i)
    line = s[i:] if j < 0 else s[i:j]
    return any(c.strip(" ") == "rate" for c in line.split("|"))


def _p_cols(s: str, i: int):
    """``Md.pCols``: the attribute columns of the header, up to its newline."""
    out: list = []
    while True:
        if s.startswith("\n", i):
            return out, i + 1
        if not s.startswith(" ", i):
            return None
        j = read_ident(s, i + 1)
        k = s[i + 1 : j]
        if not is_ident(k) or not s.startswith(" |", j):
            return None
        out.append(k)
        i = j + 2


def _p_cell(s: str, i: int):
    """``Md.pCell``: `` value |``, or `` |`` when the attribute is absent; the
    value is wrapped in a one-tuple."""
    if s.startswith(" |", i):
        return None, i + 2
    if not s.startswith(" ", i):
        return None
    r = p_flow(s, i + 1)
    if r is None or not s.startswith(" |", r[1]):
        return None
    return (r[0],), r[1] + 2


_KIND_OF = {"var": VAR, "param": PARAM, "species": SPECIES, "subsystem": SUB}


def _p_row(cols: list, s: str, i: int):
    """``Md.pRow``: ``| var | $N$ |`` and the cells, then a newline."""
    if not s.startswith("| ", i):
        return None
    j = read_ident(s, i + 2)
    k = _KIND_OF.get(s[i + 2 : j])
    if k is None or not s.startswith(" | $", j):
        return None
    u = j + 4
    e = s.find("$", u)
    if e < 0 or not s.startswith("$ |", e):
        return None
    n = parse_latex(EMPTY_SYM, s[u:e])
    if type(n) is not str:
        return None
    attrs = []
    p = e + 3
    for col in cols:
        r = _p_cell(s, p)
        if r is None:
            return None
        if r[0] is not None:
            attrs.append((col, r[0][0]))
        p = r[1]
    if not s.startswith("\n", p):
        return None
    return Decl(k, n, attrs), p + 1


def _sep_ok(line: str) -> bool:
    return all(c in "|- :" for c in line)


def _table_at(s: str, i: int):
    """``Md.tableAt``: a declarations table, at its ``| decl | name |``."""
    r = _p_cols(s, min(i + len(TABLE_OPEN), len(s)))
    if r is None:
        return None
    cols, j = r
    a, b = split_line(s, j)
    if not _sep_ok(s[j:a]):
        return None
    out = []
    while s.startswith("| ", b):
        d = _p_row(cols, s, b)
        if d is None:
            return None
        out.append(("decl", d[0]))
        b = d[1]
    return out, b


# ## Code spans


def _skip_code(s: str, i: int) -> int:
    """``Md.skipCode``: the position after the code span that starts here."""
    j = take_while(s, i, lambda c: c == "`")
    k = s.find("`" * (j - i), j)
    return j if k < 0 else k + (j - i)


def lex(bol: bool, s: str, i: int):
    """``Md.lex``: the constructs of a text, skipping prose one character at a time
    and code spans whole. A malformed construct is an error (``None``)."""
    out = []
    n = len(s)
    startswith = s.startswith
    while i < n:
        c = s[i]
        if bol and startswith(_BLOCK_OPENS, i):
            r = _block_at(s, i)
            if r is None:
                return None
            out.append(r[0])
            i = r[1]
            bol = True
        elif c == ":" and (
            startswith(":var[", i) or startswith(":param[", i) or startswith(":species[", i)
        ):
            r = _decl_at(s, i)
            if r is None:
                return None
            out.append(r[0])
            i = r[1]
            bol = False
        elif bol and startswith(TABLE_OPEN, i):
            r = _table_at(s, i)
            if r is None:
                return None
            out.extend(r[0])
            i = r[1]
            bol = True
        elif bol and (startswith(D_INIT, i) or startswith(D_CONS, i)):
            r = _cont_at(s, i)
            if r is None:
                return None
            out.extend(r[0])
            i = r[1]
            bol = True
        elif bol and c == "|" and _rate_table(s, i):
            return None
        elif c == "`":
            i = _skip_code(s, i)
            bol = False
        else:
            bol = c == "\n"
            i += 1
    return out


# ## What each construct needs to read back


def attr_ok(a: tuple) -> bool:
    """``Md.attrOK``."""
    return is_ident(a[0]) and wf(a[1])


def _decl_ok(d: Decl) -> bool:
    return name_ok(d.name) and "$" not in name_latex(d.name) and all(attr_ok(a) for a in d.attrs)


def _mhchem_ok(x: Rxn) -> bool:
    """``Md.mhchemOK``: no escaped brace anywhere inside ``\\ce{…}``."""
    t = side_txt(LATEX_R, x.subs) + x.rate + side_txt(LATEX_R, x.prods)
    return "\\{" not in t and "\\}" not in t


def rxn_ok(x: Rxn) -> bool:
    """``Md.rxnOK``: a reaction the Markdown syntax can hold."""
    return (
        side_ok(LATEX_R, x.subs)
        and side_ok(LATEX_R, x.prods)
        and "$" not in x.rate
        and "\n" not in x.rate
        and id_ok(x.id)
        and all(attr_ok(a) for a in x.attrs)
        and _mhchem_ok(x)
    )


def _sub_md(d: Decl) -> str:
    return D_SUB + d.name + "]{" + attrs_md(d.attrs) + "}\n"


def item_md(it: tuple) -> str:
    """``Md.itemMd``: the text of a construct."""
    tag = it[0]
    if tag == "desc":
        return FENCE_ESM + DESC_INFO + "\n" + it[1] + "\n" + FENCE + "\n"
    if tag == "block":
        return FENCE_ESM + key_md(it[1]) + "\n" + yaml.encode(it[2]) + FENCE + "\n"
    if tag == "comp":
        return (D_MODEL if it[1] == MODEL else D_RS) + it[2] + "]\n"
    if tag == "decl":
        d = it[1]
        return _sub_md(d) if d.kind == SUB else decl_md(d)
    if tag == "eqn":
        return DD + "\n" + it[1] + "\n" + DD + "\n"
    if tag == "eqx":
        return D_ROLE[it[1]] + "\n" + DD + "\n" + it[2] + "\n" + DD + "\n" + D_END + "\n"
    if tag == "rxn":
        return D_RXN + rxn_body(it[1])
    if tag == "plot":
        return D_PLOT + attrs_md(it[1]) + "}\n"
    t = it[1]
    disp = DD + "\n" + tm_raw(t) + "\n" + DD + "\n"
    if not t.attrs:
        return disp
    return (D_TMPL if t.lhs is None else D_RULE_C) + attrs_md(t.attrs) + "}\n" + disp + D_END + "\n"


def _is_block(it: tuple) -> bool:
    """``Md.isBlock``: a construct that must start a line (all but
    declarations)."""
    return it[0] != "decl" or it[1].kind == SUB


def item_ok_tm(t: Tm) -> bool:
    """The template case of ``Md.itemOK``."""
    raw = tm_raw(t)
    return (
        no_stop(DD, raw + "\n")
        and "\n" not in raw
        and tm_lex(raw) == (t.name, list(t.params), t.lhs, t.body)
        and all(attr_ok(a) for a in t.attrs)
    )


# ## Equations in LaTeX (MarkdownDoc.lean)


def latex_of(s: Sym, e: Eqn) -> str:
    """``Md.latexOf``: an equation's LaTeX under the symbol table ``s``."""
    return print_latex_eqn(s, eq_expr(e))


def pr_md(s: Sym, e: Eqn) -> str:
    """``Md.prMd``: an equation's math text: its ``_comment`` as a LaTeX comment
    line, then the equation."""
    out = latex_of(s, e)
    return out if e.comment is None else "% " + e.comment + "\n" + out


#: ``Md.envs``: the multi-line environments: ``True`` when all rows are one
#: equation.
ENVS = (
    ("aligned", False),
    ("align", False),
    ("align*", False),
    ("gathered", False),
    ("split", True),
    ("multline", True),
    ("multline*", True),
)


def env_of(body: str):
    """``Md.envOf``: a display that is one multi-line environment: whether its rows
    are one equation, and the environment's body."""
    b = body.strip(" \n\t")
    for e, one in ENVS:
        o = "\\begin{" + e + "}"
        c = "\\end{" + e + "}"
        if b.startswith(o) and b.endswith(c):
            n = max(0, len(b) - len(o) - len(c))
            return one, b[len(o) : len(o) + n]
    return None


def with_comment(c, es: list) -> list:
    """``Md.withComment``: the comment goes to the first equation of a display."""
    if es:
        es[0].comment = c
    return es


def _one_md(s: Sym, c, body: str):
    env = env_of(body)
    if env is not None:
        ts = latex.lex(env[1])
        if ts is None:
            return None
        es = cook_rows(K.LATEX, s, env[0], ts)
        return None if es is None else with_comment(c, es)
    e = parse_latex(s, body)
    sides = None if e is None else eq_sides(e)
    if sides is None:
        return None
    return [Eqn(c, sides[0], sides[1])]


def ck_md(s: Sym, raw: str):
    """``Md.ckMd``: an optional leading comment line ``% …``, then the
    equation."""
    if raw.startswith("% "):
        a, b = split_line(raw, 2)
        return _one_md(s, raw[2:a], raw[b:])
    return _one_md(s, None, raw)


def _pr_mdx(s: Sym, m: tuple) -> tuple:
    return pr_mx(pr_md, print_latex, s, m)


def _ck_mdx(s: Sym, m: tuple):
    return ck_mx(ck_md, parse_latex, s, m)


def comment_ok(c) -> bool:
    """``Md.commentOK``."""
    return c is None or ("\n" not in c and "$" not in c)


def dq_ok(v: Any) -> bool:
    """``Md.dqOK``: a string whose characters the YAML printer writes as themselves
    and without ``&``; any other value."""
    if type(v) is str:
        return all(c != "&" and esc_char(False, c) == c for c in v)
    return True


_DESC_STOPS = ("```", " ```", "  ```", "   ```")


class CapsMd(Caps):
    """``Md.capsMd``: the Markdown container's predicates."""

    def front_key(self, k: str) -> bool:
        return True

    def desc(self, s: str) -> bool:
        t = s + "\n"
        return all(no_stop(stop, t) for stop in _DESC_STOPS) and "\r" not in s

    def comp_name(self, n: str) -> bool:
        return "]" not in n and "\n" not in n

    def decl_name(self, n: str) -> bool:
        return name_ok(n) and "$" not in name_latex(n) and "]" not in n and "\n" not in n

    def attr(self, a: tuple) -> bool:
        return is_ident(a[0]) and dq_ok(a[1])

    def eqn(self, s: Sym, e: Eqn) -> bool:
        line = latex_of(s, e)
        if not comment_ok(e.comment) or "$" in line or "\n" in line or line.startswith("%"):
            return False
        if env_of(line) is not None:
            return False
        p = line if e.comment is None else "% " + e.comment + "\n" + line
        return tm_lex(p) is None

    def rxn(self, s: Sym, x: Rxn) -> bool:
        return rxn_ok(x.with_rate(print_latex(s, x.rate)))

    def plot(self, a: list) -> bool:
        return all(attr_ok(kv) and dq_ok(kv[1]) for kv in a)

    def tm(self, s: Sym, t: Tm) -> bool:
        lhs = None if t.lhs is None else print_latex(Sym(s.names, ()), t.lhs)
        raw = Tm(t.name, t.params, lhs, print_latex(s, t.body), t.attrs)
        return item_ok_tm(raw) and all(dq_ok(kv[1]) for kv in t.attrs)


CAPS_MD = CapsMd()


def _front_md(front: list) -> str:
    """``Md.frontMd``: the front matter."""
    return DASHES + "\n" + yaml.encode(Obj(front)) + DASHES + "\n"


def print_md(d: Any) -> str:
    """``Md.printMd``: print a document as Markdown. Each construct comes after a
    blank line, a declaration on a line of its own (``Md.canonSegs``)."""
    doc = to_doc(CAPS_MD, d)
    out = [_front_md(doc.front)]
    for it in items(mathify_doc(print_latex, yaml.plain_math_ok, raw_doc(_pr_mdx, doc))):
        out.append("\n")
        out.append(item_md(it))
        if not _is_block(it):
            out.append("\n")
    return "".join(out)


def _lex_doc(s: str):
    """``Md.lexDoc``: read the front matter and the constructs."""
    if not s.startswith("---\n"):
        return None
    r = until_stop(DASHES, s, 4)
    if r is None:
        return None
    body, sl, rest = r
    if not blank(sl):
        return None
    v = yaml.decode(body)
    if v is None or type(v[0]) is not Obj:
        return None
    its = lex(True, s, rest)
    return None if its is None else (list(v[0]), its)


def parse_md(text: str):
    """``Md.parseMd``: read a Markdown document, after ``decodeText`` (``None``
    when it is not one)."""
    r = _lex_doc(decode_text(text))
    if r is None:
        return None
    sk = unitems(r[0], r[1])
    if sk is None:
        return None
    sk = cook_doc_blocks(parse_latex, sk)
    if sk is None:
        return None
    d = cook_doc(_ck_mdx, sk)
    return None if d is None else of_doc(d)
