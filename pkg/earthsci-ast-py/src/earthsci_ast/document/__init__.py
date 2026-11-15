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
from collections.abc import Iterable
from enum import Enum
from typing import Any

from ..errors import ParseError
from . import math as _math
from . import limits
from .math.expr import Sym
from .number import print_num
from .source.markdown import parse_md, print_md
from .source.typst import parse_typ, print_typ
from .value import MISSING, Obj, from_plain, look, sort_obj, to_plain

__all__ = [
    "DocumentFormat",
    "parse_document",
    "parse_markdown",
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


#: The recursive readers spend about ten Python frames per nesting level of an
#: expression (one per precedence level), so the interpreter's default limit of
#: 1000 caps a readable expression near 90 levels. The limit is raised to this
#: floor (never lowered), which every document of the corpus is far below.
_RECURSION_FLOOR = 10000


def _deep() -> None:
    if sys.getrecursionlimit() < _RECURSION_FLOOR:
        sys.setrecursionlimit(_RECURSION_FLOOR)


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
    _deep()
    return print_md(_printable(doc))


def print_typst(doc: dict) -> str:
    """Print an ESM document as Typst (``Source.Typ.printTyp``). See
    :func:`print_markdown`."""
    _deep()
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
    ``_comment``, are not printed), which prints as its two sides around ``=``
    as in a document (``Source.eqExpr``). ``names`` plays the part of the
    variables a component declares: a name in it prints in its declared shape,
    and the printer avoids spellings that would collide with it. The result is
    what a document display holds, without its delimiters; it is meant for
    showing one expression outside a document, so no template is in scope.
    """
    from ..canonicalize import canonicalize_document

    fmt = _format(format)
    _deep()
    e = sort_obj(from_plain(canonicalize_document(expr)))
    if type(e) is Obj:
        lhs, rhs = look("lhs", e), look("rhs", e)
        if lhs is not MISSING and rhs is not MISSING:
            e = Obj([("args", [lhs, rhs]), ("op", "==")])
    sym = Sym(frozenset(names), ())
    if fmt is DocumentFormat.MARKDOWN:
        return _math.print_latex(sym, e)
    return _math.print_typst(sym, e)


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


def _read(text: str, fmt: DocumentFormat) -> dict:
    from ..error_handling import PARSE_ERROR

    if not isinstance(text, str):
        raise TypeError("a document source is a str")
    _deep()
    d, found = limits.reading(
        lambda: parse_md(text) if fmt is DocumentFormat.MARKDOWN else parse_typ(text)
    )
    if type(d) is not Obj:
        d = None
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
