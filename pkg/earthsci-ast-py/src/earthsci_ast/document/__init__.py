"""ESM documents as Markdown and Typst source text (CONFORMANCE_SPEC §5.58).

An ``.esm`` document can be written as Markdown (LaTeX math, remark-directive
directives, YAML front matter and container bodies) or as Typst (Typst math,
``esm`` package functions, Typst dictionaries). Both formats are lossless:
printing a document and reading it back gives the document again, and prose
between the constructs never changes what is read.

The specification of both formats is the Lean model in ``formal/``:
``formal/Esm/Document/Notation.lean`` is the notation table, and this package is a
port of the executable definitions under ``formal/Esm/Document/`` (by way of the
Rust binding's ``document`` module), laid out file by file:

================= ==========================================================
Python            Lean
================= ==========================================================
``value``         ``Json.lean`` (the value representation, canonical numbers)
``number``        ``Number.lean``
``strings``       ``Strings.lean``
``yaml_codec``    ``Yaml.lean``
``typst_dict``    ``TypstDict.lean``
``math``          ``Math/*.lean``
``source``        ``Source/*.lean``
================= ==========================================================

The golden set every binding reproduces is ``tests/conformance/document_format/``.
"""

from __future__ import annotations

import sys
from collections.abc import Callable, Iterable
from enum import Enum
from typing import Any

from ..errors import ParseError
from . import math as _math
from . import limits
from .math.expr import Sym
from .number import print_num
from .source.items import eq_sides
from .source.markdown import parse_md, print_md
from .source.typst import parse_typ, print_typ
from .value import MISSING, Obj, from_plain, look, sort_obj, to_plain

__all__ = [
    "DocumentFormat",
    "expression_names",
    "parse_document",
    "parse_markdown",
    "parse_math",
    "parse_typst",
    "print_document",
    "print_markdown",
    "print_math",
    "print_typst",
]


class DocumentFormat(str, Enum):
    """Which source format a document is written in. A plain string
    (``"markdown"`` / ``"typst"``) is accepted wherever a format is."""

    MARKDOWN = "markdown"
    TYPST = "typst"


#: The Python frames a read may need above its caller. The readers hold at most
#: ``limits.MAX_NESTING`` constructs open, and the deepest text they accept (a
#: chain of 61 ``\\max(k, …)`` or ``\\esm`` arguments, about 13 frames per
#: level) needs about 840 frames; every document of the corpus needs under 300.
#: The interpreter's default limit of 1000 covers that only for a caller less
#: than about 160 frames deep, so a read lifts the limit to give itself this
#: headroom while it runs, and puts it back afterwards. Printing needs no
#: headroom: the deepest document a read returns prints in under 300 frames.
_READ_FRAMES = 1000


def _stack_depth() -> int:
    n = 0
    f = sys._getframe(1)
    while f is not None:
        n += 1
        f = f.f_back
    return n


def _format(fmt: Any) -> DocumentFormat:
    try:
        return DocumentFormat(fmt)
    except ValueError:
        raise ValueError(
            f"unknown document format {fmt!r}: expected 'markdown' or 'typst'"
        ) from None


def _printable(doc: Any) -> Any:
    """The document value the printers take: ``canonicalize_document`` applied,
    then every object's keys sorted, as the Lean printers require
    (``Source.canonDoc``)."""
    from ..canonicalize import canonicalize_document

    if not isinstance(doc, dict):
        raise TypeError("an ESM document is a JSON object (a dict)")
    return sort_obj(from_plain(canonicalize_document(doc)))


def print_markdown(doc: dict) -> str:
    """Print an ESM document as Markdown (``Source.Md.printMd``).

    ``doc`` is the decoded JSON document. It is put in canonical form first
    (:func:`~earthsci_ast.canonicalize_document`), so two documents that
    canonicalize alike print alike, and ``parse_markdown(print_markdown(d))`` is
    ``canonicalize_document(d)``.
    """
    return print_md(_printable(doc))


def print_typst(doc: dict) -> str:
    """Print an ESM document as Typst (``Source.Typ.printTyp``). See
    :func:`print_markdown`."""
    return print_typ(_printable(doc))


def print_document(doc: dict, format: DocumentFormat | str) -> str:
    """Print an ESM document in the given format (``"markdown"`` or
    ``"typst"``)."""
    if _format(format) is DocumentFormat.MARKDOWN:
        return print_markdown(doc)
    return print_typst(doc)


def print_math(expr: Any, names: Iterable[str], format: DocumentFormat | str) -> str:
    """Print one expression, or one equation, as math under a set of declared
    names: LaTeX for ``"markdown"`` (``Math.printLatex``), Typst math for
    ``"typst"`` (``Math.printTypst``).

    ``expr`` is an ESM expression (a number, a name or an operator node) or an
    equation, a dict with ``lhs`` and ``rhs`` (other fields, such as
    ``_comment``, are not printed). An equation prints as in a document
    (``Source.eqExpr``, ``Math.printLatexEqn`` / ``Math.printTypstEqn``): its two
    sides around ``=``, except that an equation ``x = faq`` whose ``faq`` has
    output indices prints in its defining form when that reads back as exactly
    the equation, the output indices on the left and their ranges after the right
    side (Typst ``y_j = sum_(i in S) w_(i, j), j in C``). An expression whose top
    is ``==`` is a comparison and prints as any expression does, never in the
    defining form. ``names`` plays the part of the
    variables a component declares: a name in it prints in its declared shape,
    and the printer avoids spellings that would collide with it. The result is
    what a document display holds, without its delimiters; it is meant for
    showing one expression outside a document, so no template is in scope.
    """
    from ..canonicalize import canonicalize_document

    fmt = _format(format)
    e = sort_obj(from_plain(canonicalize_document(expr)))
    eqn = False
    if type(e) is Obj:
        lhs, rhs = look("lhs", e), look("rhs", e)
        if lhs is not MISSING and rhs is not MISSING:
            e = Obj([("args", [lhs, rhs]), ("op", "==")])
            eqn = True
    sym = Sym(frozenset(names), ())
    if fmt is DocumentFormat.MARKDOWN:
        return (_math.print_latex_eqn if eqn else _math.print_latex)(sym, e)
    return (_math.print_typst_eqn if eqn else _math.print_typst)(sym, e)


def expression_names(expr: Any) -> list[str]:
    """The variable names an expression or an equation uses, in order of first
    use: its string leaves under ``lhs``, ``rhs`` and ``args``. These are the
    ``names`` to give :func:`print_math` to show an expression on its own, with
    its names declared.

    ``expr`` is an expression or equation in its JSON form (a number, a str, a
    list or a dict).
    """
    out: list[str] = []
    seen: set[str] = set()
    stack = [expr]
    while stack:
        v = stack.pop()
        if isinstance(v, str):
            if v not in seen:
                seen.add(v)
                out.append(v)
        elif isinstance(v, (list, tuple)):
            stack.extend(reversed(v))
        elif isinstance(v, dict):
            stack.extend(v[k] for k in ("args", "rhs", "lhs") if k in v)
    return out


def _error(code: str, message: str) -> ParseError:
    err = ParseError(f"{code}: {message}")
    err.code = code  # type: ignore[attr-defined]
    return err


def _refusal(removed_op: str | None, fmt: DocumentFormat) -> ParseError:
    """The diagnostic for a text the reader refused. The Lean reader refuses every
    bad input alike; the code comes from the specification: a removed operator
    the math writes in the call form or the escape form is refused by name
    (CONFORMANCE §7.1), everything else is a parse error."""
    from ..error_handling import PARSE_ERROR, REMOVED_OP

    if removed_op is not None:
        return _error(REMOVED_OP, f"`{removed_op}` was removed from the format (esm-spec §4.2)")
    what = "Markdown" if fmt is DocumentFormat.MARKDOWN else "Typst"
    return _error(PARSE_ERROR, f"not an ESM {what} document")


def _with_headroom(f: Callable[[], Any]) -> tuple[Any, limits.Findings]:
    """Run one read inside the reader limits, with :data:`_READ_FRAMES` of
    stack above the caller."""
    need = _stack_depth() + _READ_FRAMES
    old = sys.getrecursionlimit()
    if old < need:
        sys.setrecursionlimit(need)
    try:
        return limits.reading(f)
    finally:
        if old < need:
            sys.setrecursionlimit(old)


def _checked(d: Any, found: limits.Findings, fmt: DocumentFormat) -> Any:
    """The plain value of a read's result, or the diagnostic for a read that ran
    past a reader limit or was refused (``None``)."""
    from ..error_handling import PARSE_ERROR

    if found.too_deep or (d is not None and limits.json_depth(d) > limits.MAX_JSON_DEPTH):
        raise _error(
            PARSE_ERROR,
            "the document nests too deeply for the reader (at most "
            f"{limits.MAX_NESTING} constructs open at once, and "
            f"{limits.MAX_JSON_DEPTH} levels of arrays and objects)",
        )
    if d is None:
        raise _refusal(found.removed_op, fmt)
    big = limits.out_of_range(d)
    if big is not None:
        raise _error(PARSE_ERROR, f"the number `{print_num(big)}` is outside the binary64 range")
    return to_plain(d)


def _read(text: str, fmt: DocumentFormat) -> dict:
    if not isinstance(text, str):
        raise TypeError("a document source is a str")
    d, found = _with_headroom(
        lambda: parse_md(text) if fmt is DocumentFormat.MARKDOWN else parse_typ(text)
    )
    if type(d) is not Obj:
        d = None
    return _checked(d, found, fmt)


def parse_math(text: str, names: Iterable[str], format: DocumentFormat | str) -> Any:
    """Read one expression, or one equation, written as math under a set of
    declared names: LaTeX for ``"markdown"`` (``Math.parseLatex``), Typst math
    for ``"typst"`` (``Math.parseTypst``). The inverse of :func:`print_math`:
    ``parse_math(print_math(e, names, f), names, f)`` is ``e`` in canonical form.

    ``text`` is what a document display holds, without its delimiters. Text whose
    top is ``=`` reads as an equation, a dict with ``lhs`` and ``rhs``, as a
    display does (``Source.eqSides``), and so does an equation in its defining
    form, ``y_j = … , j in C``, whose right side reads as the ``faq`` with output
    indices it writes (``Math.unlift``); any other text reads as an expression (a
    number, a name or an operator node, in canonical form). ``names`` plays the
    part of the variables a component declares: it decides how a run of letters
    reads (in LaTeX, ``RT`` is the name ``RT`` when it is declared, the product
    of ``R`` and ``T`` when they are). No template is in scope.

    Raises :class:`~earthsci_ast.errors.ParseError` whose ``code`` is
    ``removed_op`` when the math uses an operator removed from the format (spec
    §4.2), and ``parse_error`` for any other text that is not math, and for one
    past a bound of the reader (:mod:`.limits`): nested too deeply, or holding a
    number beyond the binary64 range.
    """
    from ..error_handling import PARSE_ERROR

    if not isinstance(text, str):
        raise TypeError("a math source is a str")
    fmt = _format(format)
    sym = Sym(frozenset(names), ())
    e, found = _with_headroom(
        lambda: (
            _math.parse_latex(sym, text)
            if fmt is DocumentFormat.MARKDOWN
            else _math.parse_typst(sym, text)
        )
    )
    if e is not None:
        sides = eq_sides(e)
        if sides is not None:
            e = Obj([("lhs", sides[0]), ("rhs", sides[1])])
    elif found.removed_op is None and not found.too_deep:
        what = "LaTeX" if fmt is DocumentFormat.MARKDOWN else "Typst"
        raise _error(PARSE_ERROR, f"not an ESM expression in {what} math")
    return _checked(e, found, fmt)


def parse_markdown(text: str) -> dict:
    """Read a Markdown ESM document (``Source.Md.parseMd``). The result is the
    decoded JSON document, in canonical form (CONFORMANCE §5.5.3.1: an integral
    number in Int64 is an ``int``, any other a ``float``).

    Raises :class:`~earthsci_ast.errors.ParseError` whose ``code`` is
    ``removed_op`` when the text uses an operator removed from the format (spec
    §4.2), and ``parse_error`` for any other text that is not a Markdown ESM
    document.
    """
    return _read(text, DocumentFormat.MARKDOWN)


def parse_typst(text: str) -> dict:
    """Read a Typst ESM document (``Source.Typ.parseTyp``). See
    :func:`parse_markdown`."""
    return _read(text, DocumentFormat.TYPST)


def parse_document(text: str, format: DocumentFormat | str) -> dict:
    """Read an ESM document written in the given format (``"markdown"`` or
    ``"typst"``). See :func:`parse_markdown`."""
    return _read(text, _format(format))
