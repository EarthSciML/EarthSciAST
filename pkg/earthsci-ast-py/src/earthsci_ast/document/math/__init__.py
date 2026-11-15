"""The math surfaces: LaTeX (Markdown documents) and Typst math.

Port of ``formal/Esm/Document/Math/``. One token representation
(:mod:`.token`) serves both surfaces; :func:`.printer.print_toks` writes an
expression's tokens under a symbol table, each surface renders and lexes its own
spelling, and :func:`.parser.parse_toks` reads the tokens of either surface back.

============== ===============================================================
Python         Lean
============== ===============================================================
``expr``       ``Expr.lean``
``token``      ``Token.lean``
``surface``    ``Surface.lean``
``printer``    ``Print.lean``
``parser``     ``Parse.lean``, ``parseToks`` of ``Induct.lean``, ``need``
``latex``      ``Latex.lean``
``typst``      ``Typst.lean``
``units``      ``Units/Typeset.lean``
============== ===============================================================

An expression never reads as ``null``, so the readers here return the expression
or ``None``.
"""

from __future__ import annotations

from typing import Any

from . import latex, typst
from . import token as K
from .expr import EMPTY_SYM, Sym
from .parser import parse_toks
from .printer import print_toks

__all__ = ["EMPTY_SYM", "Sym", "parse_latex", "parse_typst", "print_latex", "print_typst"]


def print_latex(s: Sym, e: Any) -> str:
    """``Math.printLatex``."""
    return latex.render(print_toks(K.LATEX, s, e))


def parse_latex(s: Sym, text: str) -> Any:
    """``Math.parseLatex``: the expression, or ``None``."""
    toks = latex.lex(text)
    if toks is None:
        return None
    r = parse_toks(K.LATEX, s, toks)
    return None if r is None else r[0]


def print_typst(s: Sym, e: Any) -> str:
    """``Math.printTypst``."""
    return typst.render(print_toks(K.TYPST, s, e))


def parse_typst(s: Sym, text: str) -> Any:
    """``Math.parseTypst``: the expression, or ``None``."""
    toks = typst.lex(text)
    if toks is None:
        return None
    r = parse_toks(K.TYPST, s, toks)
    return None if r is None else r[0]
