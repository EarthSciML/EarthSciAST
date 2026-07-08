"""Canonical ExprNode child traversal.

This module is the ONE definition of which :class:`~.esm_types.ExprNode`
fields carry child expressions. Every AST traversal in this package must go
through :func:`iter_children` / :func:`map_children` / :func:`any_child` /
:func:`walk` rather than enumerating fields by hand — hand-rolled walkers
have historically each covered a different subset and missed variables
hidden in aggregate bodies, ``filter`` predicates, integral bounds, or
``table_lookup`` axes (bead esm-6ka documents one such bug).

Mirrors the Rust binding's ``ExpressionNode::for_each_child`` /
``map_children`` (types.rs), which visits ``args``, ``lower``, ``upper``,
``expr``, ``filter``, ``values``, then ``axes`` sorted by axis name. Python
additionally visits ``key`` (the RFC §5.5 Skolem-term expression, parsed as
a nested Expression) between ``filter`` and ``values``.

Note: this enumerates *children* only. ``output_idx``, ``ranges``, and
``wrt`` bind index symbols for the node's body; callers that resolve
variable names decide how to treat bound symbols.
"""

from dataclasses import replace
from typing import Any, Callable, Iterator

from .esm_types import Expr, ExprNode

__all__ = ["iter_children", "any_child", "map_children", "walk"]

# Single-child expression slots, in canonical visit order (args come first,
# values after these, then table_axes; see iter_children).
_SINGLE_CHILD_FIELDS = ("lower", "upper", "expr", "filter", "key")


def iter_children(node: ExprNode) -> Iterator[Expr]:
    """Yield every expression-bearing child of ``node`` in deterministic
    order: ``args``, then ``lower``/``upper``/``expr``/``filter``/``key``,
    then ``values``, then ``table_axes`` entries sorted by axis name."""
    for a in node.args:
        yield a
    for field_name in _SINGLE_CHILD_FIELDS:
        child = getattr(node, field_name)
        if child is not None:
            yield child
    if node.values is not None:
        for v in node.values:
            yield v
    if node.table_axes is not None:
        for k in sorted(node.table_axes):
            yield node.table_axes[k]


def any_child(node: ExprNode, predicate: Callable[[Expr], bool]) -> bool:
    """True if ``predicate`` holds for any child of ``node``."""
    return any(predicate(child) for child in iter_children(node))


def map_children(node: ExprNode, fn: Callable[[Expr], Expr]) -> ExprNode:
    """Rebuild ``node`` with ``fn`` applied to every child expression.

    Uses :func:`dataclasses.replace`, so every non-child sidecar field
    (``op``, ``wrt``, ``dim``, ``ranges``, ``regions``, ``reduce``,
    ``semiring``, ``join``, ``distinct``, ``shape``, ``perm``, ``axis``,
    ``fn``, ``id``, ``manifold``, ``handler_id``, ``name``, ``value``,
    ``table``, ``output`` — and any field added later) is preserved
    automatically. Never rebuild an ExprNode by listing fields by hand.
    """
    updates: dict = {"args": [fn(a) for a in node.args]}
    for field_name in _SINGLE_CHILD_FIELDS:
        child = getattr(node, field_name)
        if child is not None:
            updates[field_name] = fn(child)
    if node.values is not None:
        updates["values"] = [fn(v) for v in node.values]
    if node.table_axes is not None:
        updates["table_axes"] = {k: fn(v) for k, v in node.table_axes.items()}
    return replace(node, **updates)


def walk(expr: Any) -> Iterator[Any]:
    """Pre-order walk over an expression tree, yielding every node —
    the root first, including ``str`` leaves and numeric literals."""
    yield expr
    if isinstance(expr, ExprNode):
        for child in iter_children(expr):
            yield from walk(child)
