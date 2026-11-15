"""Expressions quoted in messages, and expressions compared as values.

A message that quotes an expression or an equation prints it as Typst math with
:func:`~earthsci_ast.print_math`, under the names it uses
(:func:`~earthsci_ast.expression_names`). Two expressions are the same when
their canonical JSON is: the form ``canonicalize_document`` writes (API_SPEC
§5.4), numbers in their canonical kind (CONFORMANCE §5.5.3.1).
"""

from __future__ import annotations

import json
from typing import Any

from .esm_types import Expr


def _plain(expr: Any) -> Any:
    """The JSON form of an expression: an ``ExprNode`` serialized, a JSON value
    as it is."""
    if isinstance(expr, (dict, list)):
        return expr
    from .serialize import _serialize_expression

    return _serialize_expression(expr)


def _show(value: Any) -> str:
    from .document import expression_names, print_math

    try:
        return print_math(value, expression_names(value), "typst")
    except Exception:  # noqa: BLE001 - a message must not fail to be built
        return json.dumps(value, sort_keys=True, ensure_ascii=False, default=repr)


def show_expr(expr: Expr) -> str:
    """An expression as Typst math, for a message."""
    return _show(_plain(expr))


def show_equation(lhs: Expr, rhs: Expr) -> str:
    """An equation ``lhs = rhs`` as Typst math, for a message."""
    return _show({"lhs": _plain(lhs), "rhs": _plain(rhs)})


def canonical_key(expr: Expr) -> str:
    """The canonical JSON text of an expression: equal for two expressions
    exactly when they are the same expression in the form
    ``canonicalize_document`` writes (API_SPEC §5.4), numbers in their canonical
    kind (CONFORMANCE §5.5.3.1)."""
    from .canonicalize import canonicalize_document

    return json.dumps(
        canonicalize_document(_plain(expr)), sort_keys=True, ensure_ascii=False, allow_nan=True
    )
