"""Typst documents: markup plus the functions of the ``esm`` Typst package.

Port of ``formal/Esm/Document/Source/Typst.lean`` and ``TypstDoc.lean``
(namespace ``Source.Typ``), composed exactly as the Markdown documents
(:mod:`.markdown`). The lexer reads a construct where one starts at the beginning
of a line (a declaration anywhere) and otherwise drops one character of prose.
"""

from __future__ import annotations

from typing import Any

from .. import typst_dict
from ..math import EMPTY_SYM, parse_typst, print_typst
from ..math import token as K
from ..math import typst as mtypst
from ..math.expr import Sym, name_ok
from ..strings import bare_key, is_ident, parse_quoted, quote, read_ident
from ..value import wf
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
from .markdown import comment_ok, with_comment
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
from .text import blank, decode_text, split_line, take_while

# ## Spellings

O_DESC = "#description["
O_BLOCK = "#esm-block("
O_MODEL = "#model("
O_RS = "#reaction-system("
O_EQ = "$ "
O_VAR = "#var("
O_PARAM = "#param("
O_SPECIES = "#species("
O_CE = "#ce["
O_RXN = "#reaction("
O_INIT = "#initialization["
O_CONS = "#constraints["
O_PLOT = "#plot("
O_SUB = "#subsystem("
O_TMPL = "#template("
O_RULE = "#rule("

O_ROLE = {INIT: O_INIT, CONS: O_CONS, EQN: O_EQ}
DKW = {VAR: O_VAR, PARAM: O_PARAM, SPECIES: O_SPECIES, SUB: O_SUB}

#: ``Typ.header``: the header's first line and the start of its second.
HEADER = '#import "@preview/esm:0.1.0": *\n#show: esm-document.with('

# ## Description text

_ALWAYS_ESC = frozenset("\\[]#$*_`<>@~")


def esc_t(bol: bool, s: str) -> str:
    """``Typ.escT``: a description's text in a content block (``Typ.mustEsc``
    decides which characters are escaped)."""
    out = []
    b = bol
    n = len(s)
    for i, c in enumerate(s):
        nxt = s[i + 1] if i + 1 < n else ""
        if c in _ALWAYS_ESC or (b and c in "=-+") or (c == "/" and nxt in ("/", "*") and nxt):
            out.append("\\")
        out.append(c)
        b = c == "\n"
    return "".join(out)


def _read_esc(s: str, i: int):
    """``Typ.readEsc``: the text of a content block up to its unescaped ``]``."""
    out: list = []
    n = len(s)
    while True:
        if i >= n:
            return None
        c = s[i]
        if c == "]":
            return "".join(out), i + 1
        if c == "\\" and i + 1 < n:
            out.append(s[i + 1])
            i += 2
        elif c == "[":
            return None
        else:
            out.append(c)
            i += 1


def arg_t(a: tuple) -> str:
    """``Typ.argT``: ``key: value``."""
    return a[0] + ": " + typst_dict.encode(a[1])


def _p_arg(s: str, i: int):
    """``Typ.pArg``: one named argument at its key."""
    j = read_ident(s, i)
    k = s[i:j]
    if not is_ident(k) or typst_dict.reserved(k) or not s.startswith(": ", j):
        return None
    r = typst_dict.p_val(s, j + 2)
    return None if r is None else ((k, r[0]), r[1])


def p_args_more(s: str, i: int):
    """``Typ.pArgsMore``: ``, key: value`` repeated, up to ``)``."""
    out: list = []
    while True:
        if s.startswith(")", i):
            return out, i + 1
        if not s.startswith(", ", i):
            return None
        r = _p_arg(s, i + 2)
        if r is None:
            return None
        out.append(r[0])
        i = r[1]


def p_args_first(s: str, i: int):
    """``Typ.pArgsFirst``: arguments directly after ``(``."""
    if s.startswith(")", i):
        return [], i + 1
    r = _p_arg(s, i)
    if r is None:
        return None
    m = p_args_more(s, r[1])
    return None if m is None else ([r[0], *m[0]], m[1])


def args_more_t(as_: list) -> str:
    """``Typ.argsMoreT``: each ``, key: value``."""
    return "".join(", " + arg_t(a) for a in as_)


def args_first_t(as_: list) -> str:
    """``Typ.argsFirstT``: arguments directly after ``(``."""
    return ", ".join(arg_t(a) for a in as_)


def arg_ok(a: tuple) -> bool:
    """``Typ.argOK``: an identifier key that is not a keyword, and a well-formed
    value."""
    return bare_key(typst_dict.reserved, a[0]) and wf(a[1])


# ## Constructs


def name_typ(n: str) -> str:
    """``Typ.nameTyp``: a name as Typst math under the empty symbol table."""
    return print_typst(EMPTY_SYM, n)


def _decl_t(d: Decl) -> str:
    """``Typ.declT``: ``#var($N$, default: 100)``."""
    return DKW[d.kind] + "$" + name_typ(d.name) + "$" + args_more_t(d.attrs) + ")"


def _line_end(s: str, i: int):
    """``Typ.lineEnd``: the rest of a construct's line must be blank."""
    a, b = split_line(s, i)
    return b if blank(s[i:a]) else None


# ## Reactions

TYP_R = RSurf(lambda s: parse_typst(EMPTY_SYM, s), lambda j: print_typst(EMPTY_SYM, j), "emptyset")

ARROW_L = " ->[$"
ARROW_R = "] "


def _core_t(x: Rxn) -> str:
    """``Typ.coreT``: the sides and the rate over the arrow."""
    return side_txt(TYP_R, x.subs) + ARROW_L + x.rate + "$" + ARROW_R + side_txt(TYP_R, x.prods)


def _rxn_t(x: Rxn) -> str:
    """``Typ.rxnT``: ``#ce[…] <id>``, or ``#reaction(…)[#ce[…]] <id>``."""
    if not x.attrs:
        return O_CE + _core_t(x) + "] <" + x.id + ">\n"
    return O_RXN + args_first_t(x.attrs) + ")[#ce[" + _core_t(x) + "]] <" + x.id + ">\n"


def _core_at(s: str, i: int):
    """``Typ.coreAt``: subs, rate, prods, and the position after."""
    r = p_side(TYP_R, s, i)
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
    r = p_side(TYP_R, s, j + len(ARROW_R))
    if r is None:
        return None
    return subs, rate, r[0], r[1]


def _label_at(s: str, i: int):
    """``Typ.labelAt``: the label ``<id>`` and the end of the line."""
    if not s.startswith("<", i):
        return None
    j = take_while(s, i + 1, id_char)
    if not s.startswith(">", j) or j == i + 1:
        return None
    r = _line_end(s, j + 1)
    return None if r is None else (s[i + 1 : j], r)


def _ce_at(s: str, i: int):
    """``Typ.ceAt``: a reaction after ``#ce[``."""
    c = _core_at(s, i)
    if c is None or not s.startswith("] ", c[3]):
        return None
    lb = _label_at(s, c[3] + 2)
    if lb is None:
        return None
    return ("rxn", Rxn(lb[0], c[0], c[2], c[1], [])), lb[1]


def _rxn_at_t(s: str, i: int):
    """``Typ.rxnAtT``: a reaction after ``#reaction(``."""
    r = p_args_first(s, i)
    if r is None or not s.startswith("[#ce[", r[1]):
        return None
    c = _core_at(s, r[1] + 5)
    if c is None or not s.startswith("]] ", c[3]):
        return None
    lb = _label_at(s, c[3] + 3)
    if lb is None:
        return None
    return ("rxn", Rxn(lb[0], c[0], c[2], c[1], r[0])), lb[1]


# ## Templates and rules

TM_OP = "op("
TM_PAR = ")("
TM_DEF_T = ") := "
SEP_D = ", $"


def tm_raw_t(t: Tm) -> str:
    """``Typ.tmRawT``: the math text of a template display (one line)."""
    return (
        TM_OP
        + quote(True, t.name)
        + TM_PAR
        + ", ".join(name_typ(p) for p in t.params)
        + TM_DEF_T
        + t.body
    )


def _name_len_t(s: str, i: int) -> int:
    """``Typ.nameLenT``: the length of a parameter name's Typst math: up to the
    first ``,`` or ``)`` outside parentheses and string literals."""
    d, q, n = 0, False, 0
    m = len(s)
    while i < m:
        c = s[i]
        if q:
            if c == "\\":
                if i + 1 < m:
                    n += 2
                    i += 2
                else:
                    return n + 1
            else:
                n += 1
                q = c != '"'
                i += 1
        elif c == '"':
            n += 1
            q = True
            i += 1
        elif c == "(":
            n += 1
            d += 1
            i += 1
        elif c == ")":
            if d == 0:
                return n
            n += 1
            d -= 1
            i += 1
        elif c == "," and d == 0:
            return n
        else:
            n += 1
            i += 1
    return n


def _p_name_t(s: str, i: int):
    """``Typ.pNameT``: a parameter name in a template header."""
    k = min(_name_len_t(s, i), len(s) - i)
    n = parse_typst(EMPTY_SYM, s[i : i + k])
    return (n, i + k) if type(n) is str else None


def _p_params_t(s: str, i: int):
    """``Typ.pParamsT``: the parameters up to ``) := ``."""
    out: list = []
    while True:
        if s.startswith(TM_DEF_T, i):
            return out, i + len(TM_DEF_T)
        r = _p_name_t(s, i)
        if r is None:
            return None
        out.append(r[0])
        j = r[1]
        if s.startswith(TM_DEF_T, j):
            return out, j + len(TM_DEF_T)
        if not s.startswith(", ", j):
            return None
        i = j + 2


def tm_lex_t(raw: str):
    """``Typ.tmLexT``: read the math text of a display as a template: its name,
    parameters and body text."""
    if not raw.startswith(TM_OP):
        return None
    r = parse_quoted(True, raw, len(TM_OP))
    if r is None or not raw.startswith(TM_PAR, r[1]):
        return None
    p = _p_params_t(raw, r[1] + len(TM_PAR))
    if p is None:
        return None
    return r[0], p[0], raw[p[1] :]


def item_t(it: tuple) -> str:
    """``Typ.itemT``: the text of a construct."""
    tag = it[0]
    if tag == "desc":
        return O_DESC + esc_t(True, it[1]) + "]\n"
    if tag == "block":
        return O_BLOCK + quote(True, it[1]) + ", " + typst_dict.encode(it[2]) + ")\n"
    if tag == "comp":
        return (O_MODEL if it[1] == MODEL else O_RS) + quote(True, it[2]) + ")\n"
    if tag == "decl":
        d = it[1]
        if d.kind == SUB:
            return O_SUB + quote(True, d.name) + args_more_t(d.attrs) + ")\n"
        return _decl_t(d)
    if tag == "eqn":
        return O_EQ + it[1] + " $\n"
    if tag == "eqx":
        return O_ROLE[it[1]] + O_EQ + it[2] + " $]\n"
    if tag == "rxn":
        return _rxn_t(it[1])
    if tag == "plot":
        return O_PLOT + args_first_t(it[1]) + ")\n"
    t = it[1]
    if t.lhs is not None:
        return (
            O_RULE + quote(True, t.name) + SEP_D + t.lhs + "$" + SEP_D + t.body + "$"
            + args_more_t(t.attrs) + ")\n"
        )  # fmt: skip
    if not t.attrs:
        return O_EQ + tm_raw_t(t) + " $\n"
    return O_TMPL + args_first_t(t.attrs) + ")[" + O_EQ + tm_raw_t(t) + " $]\n"


def _label_ok(sl: str) -> bool:
    """``Typ.labelOK``: nothing, or ``<id>``, with spaces around."""
    t = sl.lstrip(" ")
    if t == "":
        return True
    if t.startswith("<") and t.endswith(">") and len(t) >= 2:
        inner = t[1:-1]
        return ">" not in inner and "<" not in inner
    return False


# ## The lexer

_BLOCK_OPENS = (
    O_DESC, O_BLOCK, O_MODEL, O_RS, O_EQ, O_CE, O_RXN, O_INIT, O_CONS, O_PLOT, O_SUB, O_TMPL,
    O_RULE,
)  # fmt: skip


def _desc_at(s: str, i: int):
    r = _read_esc(s, i)
    if r is None:
        return None
    e = _line_end(s, r[1])
    return None if e is None else (("desc", r[0]), e)


def _block_at_t(s: str, i: int):
    """``Typ.blockAtT``: a path block after ``#esm-block(``."""
    r = parse_quoted(True, s, i)
    if r is None or not s.startswith(", ", r[1]):
        return None
    v = typst_dict.p_val(s, r[1] + 2)
    if v is None or not s.startswith(")", v[1]):
        return None
    e = _line_end(s, v[1] + 1)
    return None if e is None else (("block", r[0], v[0]), e)


def _comp_at(k: str, s: str, i: int):
    r = parse_quoted(True, s, i)
    if r is None or not s.startswith(")", r[1]):
        return None
    e = _line_end(s, r[1] + 1)
    return None if e is None else (("comp", k, r[0]), e)


def _disp_item(raw: str) -> tuple:
    """``Typ.dispItem``: a template when the display reads as one, else an
    equation."""
    tl = tm_lex_t(raw)
    if tl is not None:
        return ("tm", Tm(tl[0], tl[1], None, tl[2], []))
    return ("eqn", raw)


def _eq_at(s: str, i: int):
    """``Typ.eqAt``: a display after its ``$ ``."""
    j = s.find("$", i)
    if j < 0:
        return None
    a, b = split_line(s, j + 1)
    body = s[i:j]
    if body.endswith(" ") and _label_ok(s[j + 1 : a]):
        return _disp_item(body[:-1]), b
    return None


def _tmpl_at_t(s: str, i: int):
    """``Typ.tmplAtT``: a template with other fields, after ``#template(``."""
    r = p_args_first(s, i)
    if r is None or not s.startswith("[$ ", r[1]):
        return None
    p = p_piece(s, r[1] + 3)
    if p is None:
        return None
    body, j = p
    if not body.endswith(" ") or not s.startswith("]", j):
        return None
    tl = tm_lex_t(body[:-1])
    if tl is None:
        return None
    e = _line_end(s, j + 1)
    return None if e is None else (("tm", Tm(tl[0], tl[1], None, tl[2], r[0])), e)


def _rule_at_t(s: str, i: int):
    """``Typ.ruleAtT``: a rule, after ``#rule(``."""
    r = parse_quoted(True, s, i)
    if r is None or not s.startswith(SEP_D, r[1]):
        return None
    fs = p_piece(s, r[1] + len(SEP_D))
    if fs is None or not s.startswith(SEP_D, fs[1]):
        return None
    b = p_piece(s, fs[1] + len(SEP_D))
    if b is None:
        return None
    m = p_args_more(s, b[1])
    if m is None:
        return None
    e = _line_end(s, m[1])
    return None if e is None else (("tm", Tm(r[0], [], fs[0], b[0], m[0])), e)


def _eqx_at(ro: str, s: str, i: int):
    """``Typ.eqxAt``: an equation in a container after its opener: ``$ … $]``."""
    if not s.startswith(O_EQ, i):
        return None
    p = p_piece(s, i + len(O_EQ))
    if p is None:
        return None
    body, j = p
    if not body.endswith(" ") or not s.startswith("]", j):
        return None
    e = _line_end(s, j + 1)
    return None if e is None else (("eqx", ro, body[:-1]), e)


def _sub_at_t(s: str, i: int):
    r = parse_quoted(True, s, i)
    if r is None:
        return None
    m = p_args_more(s, r[1])
    if m is None:
        return None
    e = _line_end(s, m[1])
    return None if e is None else (("decl", Decl(SUB, r[0], m[0])), e)


def _plot_at_t(s: str, i: int):
    r = p_args_first(s, i)
    if r is None:
        return None
    e = _line_end(s, r[1])
    return None if e is None else (("plot", r[0]), e)


def _block_at(s: str, i: int):
    """``Typ.blockAt``: read the block construct that starts here."""
    st = s.startswith
    if st(O_DESC, i):
        return _desc_at(s, i + len(O_DESC))
    if st(O_BLOCK, i):
        return _block_at_t(s, i + len(O_BLOCK))
    if st(O_MODEL, i):
        return _comp_at(MODEL, s, i + len(O_MODEL))
    if st(O_RS, i):
        return _comp_at(RS, s, i + len(O_RS))
    if st(O_CE, i):
        return _ce_at(s, i + len(O_CE))
    if st(O_RXN, i):
        return _rxn_at_t(s, i + len(O_RXN))
    if st(O_INIT, i):
        return _eqx_at(INIT, s, i + len(O_INIT))
    if st(O_CONS, i):
        return _eqx_at(CONS, s, i + len(O_CONS))
    if st(O_PLOT, i):
        return _plot_at_t(s, i + len(O_PLOT))
    if st(O_SUB, i):
        return _sub_at_t(s, i + len(O_SUB))
    if st(O_TMPL, i):
        return _tmpl_at_t(s, i + len(O_TMPL))
    if st(O_RULE, i):
        return _rule_at_t(s, i + len(O_RULE))
    return _eq_at(s, min(i + len(O_EQ), len(s)))


def _decl_body(k: str, s: str, i: int):
    """``Typ.declBody``: a declaration after its opener."""
    if not s.startswith("$", i):
        return None
    j = s.find("$", i + 1)
    if j < 0:
        return None
    n = parse_typst(EMPTY_SYM, s[i + 1 : j])
    if type(n) is not str:
        return None
    m = p_args_more(s, j + 1)
    return None if m is None else (("decl", Decl(k, n, m[0])), m[1])


def _decl_at(s: str, i: int):
    if s.startswith(O_VAR, i):
        return _decl_body(VAR, s, i + len(O_VAR))
    if s.startswith(O_PARAM, i):
        return _decl_body(PARAM, s, i + len(O_PARAM))
    return _decl_body(SPECIES, s, min(i + len(O_SPECIES), len(s)))


def lex(bol: bool, s: str, i: int):
    """``Typ.lex``: the constructs of a text, skipping prose one character at a
    time (``None`` for a malformed construct)."""
    out = []
    n = len(s)
    st = s.startswith
    while i < n:
        c = s[i]
        if bol and (c == "#" or c == "$") and st(_BLOCK_OPENS, i):
            r = _block_at(s, i)
            if r is None:
                return None
            out.append(r[0])
            i = r[1]
            bol = True
        elif c == "#" and (st(O_VAR, i) or st(O_PARAM, i) or st(O_SPECIES, i)):
            r = _decl_at(s, i)
            if r is None:
                return None
            out.append(r[0])
            i = r[1]
            bol = False
        else:
            bol = c == "\n"
            i += 1
    return out


# ## What each construct needs to read back


def _typsium_ok(x: Rxn) -> bool:
    """``Typ.typsiumOK``: no ``//`` or ``/*`` in the chemistry."""
    t = side_txt(TYP_R, x.subs) + x.rate + side_txt(TYP_R, x.prods)
    return "//" not in t and "/*" not in t


def rxn_ok(x: Rxn) -> bool:
    """``Typ.rxnOK``: a reaction the Typst syntax can hold."""
    return (
        side_ok(TYP_R, x.subs)
        and side_ok(TYP_R, x.prods)
        and "$" not in x.rate
        and "\n" not in x.rate
        and id_ok(x.id)
        and all(arg_ok(a) for a in x.attrs)
        and _typsium_ok(x)
    )


def _item_ok_tm(t: Tm) -> bool:
    """The template case of ``Typ.itemOK``."""
    if not all(arg_ok(a) for a in t.attrs):
        return False
    if t.lhs is not None:
        return "$" not in t.lhs and "$" not in t.body and not t.params
    raw = tm_raw_t(t)
    return "$" not in raw and tm_lex_t(raw) == (t.name, list(t.params), t.body)


# ## Equations in Typst (TypstDoc.lean)


def typ_of(s: Sym, e: Eqn) -> str:
    """``Typ.typOf``: an equation's Typst math under the symbol table ``s``."""
    return print_typst(s, eq_expr(e))


def pr_t(s: Sym, e: Eqn) -> str:
    """``Typ.prT``: its ``_comment`` as a ``//`` comment line, then the
    equation."""
    out = typ_of(s, e)
    return out if e.comment is None else "// " + e.comment + "\n" + out


def _one_t(s: Sym, c, body: str):
    """``Typ.oneT``: one equation, or several rows separated by ``\\`` with ``&``
    alignment."""
    e = parse_typst(s, body)
    sides = None if e is None else eq_sides(e)
    if sides is not None:
        return [Eqn(c, sides[0], sides[1])]
    ts = mtypst.lex(body)
    if ts is None:
        return None
    es = cook_rows(K.TYPST, s, False, ts)
    return None if es is None else with_comment(c, es)


def ck_t(s: Sym, raw: str):
    """``Typ.ckT``: read the math text of a display equation."""
    if raw.startswith("// "):
        a, b = split_line(raw, 3)
        return _one_t(s, raw[3:a], raw[b:])
    return _one_t(s, None, raw)


def _pr_tx(s: Sym, m: tuple) -> tuple:
    return pr_mx(pr_t, print_typst, s, m)


def _ck_tx(s: Sym, m: tuple):
    return ck_mx(ck_t, parse_typst, s, m)


class CapsT(Caps):
    """``Typ.capsT``: the Typst container's predicates."""

    def front_key(self, k: str) -> bool:
        return bare_key(typst_dict.reserved, k)

    def desc(self, s: str) -> bool:
        return True

    def comp_name(self, n: str) -> bool:
        return True

    def decl_name(self, n: str) -> bool:
        return name_ok(n) and "$" not in name_typ(n)

    def attr(self, a: tuple) -> bool:
        return bare_key(typst_dict.reserved, a[0])

    def eqn(self, s: Sym, e: Eqn) -> bool:
        t = typ_of(s, e)
        if not comment_ok(e.comment) or "$" in t or t.startswith("//"):
            return False
        p = t if e.comment is None else "// " + e.comment + "\n" + t
        return tm_lex_t(p) is None

    def rxn(self, s: Sym, x: Rxn) -> bool:
        return rxn_ok(x.with_rate(print_typst(s, x.rate)))

    def plot(self, a: list) -> bool:
        return all(arg_ok(kv) for kv in a)

    def tm(self, s: Sym, t: Tm) -> bool:
        lhs = None if t.lhs is None else print_typst(Sym(s.names, ()), t.lhs)
        return _item_ok_tm(Tm(t.name, t.params, lhs, print_typst(s, t.body), t.attrs))


CAPS_T = CapsT()


def _is_block(it: tuple) -> bool:
    return it[0] != "decl" or it[1].kind == SUB


def _any_math(_t: str) -> bool:
    """Typst math content needs no test beyond ``math_ok``."""
    return True


def print_typ(d: Any) -> str:
    """``Typ.printTyp``: print a document as Typst."""
    doc = to_doc(CAPS_T, d)
    out = [HEADER + args_first_t(doc.front) + ")\n"]
    for it in items(mathify_doc(print_typst, _any_math, raw_doc(_pr_tx, doc))):
        out.append("\n")
        out.append(item_t(it))
        if not _is_block(it):
            out.append("\n")
    return "".join(out)


def parse_typ(text: str):
    """``Typ.parseTyp``: read a Typst document, after ``decodeText`` (``None`` when
    it is not one)."""
    s = decode_text(text)
    if not s.startswith(HEADER):
        return None
    r = p_args_first(s, len(HEADER))
    if r is None:
        return None
    e = _line_end(s, r[1])
    if e is None:
        return None
    its = lex(True, s, e)
    if its is None:
        return None
    sk = unitems(r[0], its)
    if sk is None:
        return None
    sk = cook_doc_blocks(parse_typst, sk)
    if sk is None:
        return None
    d = cook_doc(_ck_tx, sk)
    return None if d is None else of_doc(d)
