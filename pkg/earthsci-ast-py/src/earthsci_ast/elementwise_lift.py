"""Elementwise application of an expression template over array arguments.

esm-spec §9.6.11, carried out as a per-cell lift at build time, after flatten.

A template written for scalar inputs (the ``lib/interp.esm`` lookups are the
motivating case) reads a scalar-role parameter inside a reduction body (a
``faq`` with no output index) or an ``index`` subscript. Bound to an array, by
the author or by a coupling that feeds an array into a parameter the component
declared scalar, the substituted expansion reads a whole array where the body
needs one value. §9.6.11 gives the application its elementwise meaning: it is
evaluated once per element of the array argument.

This binding expands every template reference at load, so the rule is applied
to its trace on the expanded, flattened equations: an observed equation whose
right-hand side reads a shaped variable by bare name in a *scalar slot* (inside
the body or filter of a reduction ``faq``, or inside an ``index`` subscript) is
rewritten into a ``faq`` over the result's index sets whose body is the
right-hand side with every bare shaped read gathered at that cell, aligned by
index-set name (§4.3.4). An equation with no such read is left as it was. The
Rust binding (``src/elementwise_lift.rs``) runs the same walk.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Callable

from .esm_types import Expr, ExprNode
from .flatten import Contribution, FlattenedSystem, _union_origins
from .op_registry import resolve_alias, scalar_fn_names

_WHOLE_ARRAY_FN_ARGS: dict[str, tuple[int, ...]] = {
    "interp.linear": (0, 1),
    "interp.bilinear": (0, 1, 2),
    "interp.searchsorted": (1,),
}


class ElementwiseLiftError(ValueError):
    """``array_shape_mismatch`` (esm-spec §9.6.11, §4.3.4)."""

    code = "array_shape_mismatch"


def _is_elementwise(node: ExprNode) -> bool:
    op = node.fn if node.op == "broadcast" and getattr(node, "fn", None) else node.op
    return resolve_alias(op) in _SCALAR_OPS or op in _SCALAR_OPS


_SCALAR_OPS = scalar_fn_names() | {"ifelse"}


def _is_rank0_faq(node: ExprNode) -> bool:
    return node.op == "faq" and not any(isinstance(s, str) for s in (node.output_idx or []))


def _faq_bound(node: ExprNode, bound: frozenset[str]) -> frozenset[str]:
    return bound | frozenset((node.ranges or {}).keys())


def _visit_reads(
    expr: Expr,
    shapes: dict[str, list[str]],
    bound: frozenset[str],
    slot: bool,
    f: Callable[[str, bool], None],
) -> None:
    """Call ``f(name, slot)`` for every bare shaped read of ``expr`` in VALUE
    position; ``slot`` is True inside a reduction body or filter or an ``index``
    subscript. An ``index`` base and every operand an op consumes whole (an
    array-producing ``faq``, ``makearray``, the shape, geometry and relational
    ops) are not visited."""
    if isinstance(expr, str):
        if expr not in bound and shapes.get(expr):
            f(expr, slot)
        return
    if not isinstance(expr, ExprNode):
        return
    op = expr.op
    if op == "index":
        for a in expr.args[1:]:
            _visit_reads(a, shapes, bound, True, f)
    elif op == "faq":
        if not _is_rank0_faq(expr):
            return
        inner = _faq_bound(expr, bound)
        for b in (expr.expr, expr.filter):
            if b is not None:
                _visit_reads(b, shapes, inner, True, f)
    elif op == "fn":
        whole = _WHOLE_ARRAY_FN_ARGS.get(expr.name or "", ())
        for i, a in enumerate(expr.args):
            if i not in whole:
                _visit_reads(a, shapes, bound, slot, f)
    elif _is_elementwise(expr):
        for a in expr.args:
            _visit_reads(a, shapes, bound, slot, f)


def _reads(expr: Expr, shapes: dict[str, list[str]]) -> list[tuple[str, bool]]:
    """Every ``(name, slot)`` :func:`_visit_reads` reports for ``expr``."""
    out: list[tuple[str, bool]] = []
    _visit_reads(expr, shapes, frozenset(), False, lambda n, s: out.append((n, s)))
    return out


def _union_axes(reads: list[str], shapes: dict[str, list[str]], lhs: str) -> list[str] | None:
    acc: list[str] | None = None
    for n in reads:
        s = shapes.get(n)
        if not s:
            continue
        if acc is None or set(acc) <= set(s) and not set(s) <= set(acc):
            acc = list(s)
        elif not set(s) <= set(acc):
            raise ElementwiseLiftError(
                f"array_shape_mismatch: '{lhs}': array arguments over {acc} and {s} (from "
                f"'{n}'): neither one's index sets contain the other's, so there is no "
                "elementwise result shape (esm-spec §9.6.11, §4.3.4)"
            )
    return acc


def _names_in(expr: Expr, out: set[str]) -> None:
    if isinstance(expr, str):
        out.add(expr)
    elif isinstance(expr, ExprNode):
        for a in expr.args:
            _names_in(a, out)
        for b in (expr.expr, expr.filter):
            if b is not None:
                _names_in(b, out)
        out.update((expr.ranges or {}).keys())
        out.update(s for s in (expr.output_idx or []) if isinstance(s, str))


def _fresh_loops(expr: Expr, n: int) -> list[str]:
    used: set[str] = set()
    _names_in(expr, used)
    prefix = "_p"
    while True:
        loops = [f"{prefix}{d}" for d in range(n)]
        if not used.intersection(loops):
            return loops
        prefix = "_" + prefix


def _at_cell(
    expr: Expr,
    shapes: dict[str, list[str]],
    axes: list[str],
    loops: list[str],
    lhs: str,
    bound: frozenset[str] = frozenset(),
) -> Expr:
    def rec(a: Expr, b: frozenset[str] = bound) -> Expr:
        return _at_cell(a, shapes, axes, loops, lhs, b)

    if isinstance(expr, str):
        shape = shapes.get(expr)
        if expr in bound or not shape:
            return expr
        args: list[Expr] = [expr]
        for d, axis in enumerate(shape):
            if axis not in axes or axis in shape[:d]:
                raise ElementwiseLiftError(
                    f"array_shape_mismatch: '{lhs}': '{expr}' (shape {shape}) is an array "
                    f"argument of an elementwise application over {axes}, which is not "
                    f"shaped over its index set '{axis}' exactly once (esm-spec §9.6.11, "
                    "§4.3.4)"
                )
            args.append(loops[axes.index(axis)])
        return ExprNode(op="index", args=args)
    if not isinstance(expr, ExprNode):
        return expr
    op = expr.op
    if op == "index":
        return dataclasses.replace(expr, args=[expr.args[0], *(rec(a) for a in expr.args[1:])])
    if op == "faq":
        if not _is_rank0_faq(expr):
            return expr
        inner = _faq_bound(expr, bound)
        return dataclasses.replace(
            expr,
            expr=None if expr.expr is None else rec(expr.expr, inner),
            filter=None if expr.filter is None else rec(expr.filter, inner),
        )
    if op == "fn":
        whole = _WHOLE_ARRAY_FN_ARGS.get(expr.name or "", ())
        return dataclasses.replace(
            expr, args=[a if i in whole else rec(a) for i, a in enumerate(expr.args)]
        )
    if _is_elementwise(expr):
        return dataclasses.replace(expr, args=[rec(a) for a in expr.args])
    return expr


def lift_elementwise_applications(flat: FlattenedSystem) -> FlattenedSystem:
    """Lift every observed equation of ``flat`` that reads a shaped variable in a
    scalar slot (see the module docstring). A lifted variable declared without a
    ``shape`` takes the lift's index sets. Returns ``flat`` itself when nothing
    is lifted, else a shallow copy with the rewritten equations and variables.

    Repeats until no equation changes, so a chain of applications is lifted
    link by link.

    Raises :class:`ElementwiseLiftError` (``array_shape_mismatch``) when the
    array arguments of a lifted right-hand side have no common index sets.
    """
    variables = {**flat.parameters, **flat.state_variables, **flat.observed_variables}
    shapes: dict[str, list[str]] = {n: list(v.shape) for n, v in variables.items() if v.shape}
    unshaped = {n for n, v in variables.items() if v.shape is None}
    equations = list(flat.equations)
    lifted: dict[str, list[str]] = {}
    changed = True
    passes = 0
    while changed and passes <= len(equations) + 1:
        changed = False
        passes += 1
        for k, eq in enumerate(equations):
            lhs = eq.lhs
            if not isinstance(lhs, str):
                continue
            reads = _reads(eq.rhs, shapes)
            if not any(slot for _, slot in reads):
                if lhs in unshaped and lhs not in shapes:
                    try:
                        axes0 = _union_axes([n for n, slot in reads if not slot], shapes, lhs)
                    except ElementwiseLiftError:
                        axes0 = None
                    if axes0:
                        shapes[lhs] = axes0
                        changed = True
                continue
            declared = variables[lhs].shape if lhs in variables else None
            if declared:
                axes = list(declared)
            else:
                axes = _union_axes([n for n, _ in reads], shapes, lhs) or []
            if len(set(axes)) != len(axes):
                raise ElementwiseLiftError(
                    f"array_shape_mismatch: '{lhs}': the elementwise application is over "
                    f"{axes}, which names one index set twice (esm-spec §9.6.11)"
                )
            loops = _fresh_loops(eq.rhs, len(axes))
            body = _at_cell(eq.rhs, shapes, axes, loops, lhs)
            rhs = ExprNode(
                op="faq",
                args=[],
                output_idx=list(loops),
                ranges={lp: {"from": a} for lp, a in zip(loops, axes)},
                expr=body,
            )
            equations[k] = dataclasses.replace(
                eq,
                rhs=rhs,
                rhs_str="",
                contributions=[Contribution(rhs, _union_origins(eq.contributions))],
            )
            if not declared:
                shapes[lhs] = axes
                lifted[lhs] = axes
            changed = True
    if not any(e is not o for e, o in zip(equations, flat.equations)):
        return flat
    out = dataclasses.replace(flat, equations=equations)
    for part in ("state_variables", "parameters", "observed_variables"):
        reg = getattr(flat, part)
        if any(n in lifted for n in reg):
            setattr(
                out,
                part,
                type(reg)(
                    (n, dataclasses.replace(v, shape=list(lifted[n])) if n in lifted else v)
                    for n, v in reg.items()
                ),
            )
    return out
