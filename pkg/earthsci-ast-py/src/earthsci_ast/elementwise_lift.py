"""Elementwise application of an expression template over array arguments.

esm-spec §9.6.11, carried out as a per-cell lift at build time, after flatten.

A template written for scalar inputs (the ``lib/interp.esm`` lookups are the
motivating case) reads a scalar-role parameter inside a reduction body (a
``faq`` with no output index) or an ``index`` subscript. Bound to an array, by
the author or by a coupling that feeds an array into a parameter the component
declared scalar, the substituted expansion reads a whole array where the body
needs one value. §9.6.11 gives the application its elementwise meaning: it is
evaluated once per element of the array argument.

This binding expands every template reference at load and marks the root of
each expansion with its template's name (``ExprNode.template_origin``). The
rule applies to those marked applications only: an observed equation whose
right-hand side holds, in elementwise position, an application whose expansion
reads a shaped variable in a value position (an operand of an elementwise
operator, a scalar argument of a closed function, the body or filter of a
reduction, an ``index`` subscript) is rewritten into a ``faq`` over the
result's index sets. Its body is the right-hand side with each such read, and
each bare shaped read outside the applications in elementwise position,
gathered at that cell, aligned by index-set name (§4.3.4). An equation with no
such application is left as it was: a shaped read an author wrote by hand in a
reduction body or a subscript is never given this meaning. The Rust binding
(``src/elementwise_lift.rs``) runs the same walk.
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


def _visit(
    expr: Expr,
    shapes: dict[str, list[str]],
    bound: frozenset[str],
    inside: bool,
    on_read: Callable[[str, bool], None],
    on_anonymous: Callable[[ExprNode], None] | None = None,
) -> None:
    """Visit every value position of ``expr`` (esm-spec §9.6.11). Outside a
    template application those are the operands of elementwise operators and
    the scalar arguments of closed functions, the positions the per-cell
    reading commutes with. Inside one (a node carrying ``template_origin``, and
    everything below it) they are also the body and filter of a reduction
    ``faq`` and the subscripts of an ``index``, where the template reads its
    scalar-role parameters. ``on_read(name, inside)`` is called for every bare
    shaped read; ``on_anonymous(node)`` for an anonymous array (a ``const`` array
    literal, a ``reshape`` result) in a value position inside an application.
    An ``index`` base and every operand an op consumes whole are array
    positions, not visited."""
    if isinstance(expr, str):
        if expr not in bound and shapes.get(expr):
            on_read(expr, inside)
        return
    if not isinstance(expr, ExprNode):
        return

    inside = inside or expr.template_origin is not None

    def rec(a: Expr, b: frozenset[str] = bound, i: bool = inside) -> None:
        _visit(a, shapes, b, i, on_read, on_anonymous)

    op = expr.op
    if op == "index":
        if inside:
            for a in expr.args[1:]:
                rec(a, i=True)
    elif op == "faq":
        if inside and _is_rank0_faq(expr):
            inner = _faq_bound(expr, bound)
            for b in (expr.expr, expr.filter):
                if b is not None:
                    rec(b, inner, True)
    elif op == "fn":
        whole = _WHOLE_ARRAY_FN_ARGS.get(expr.name or "", ())
        for i, a in enumerate(expr.args):
            if i not in whole:
                rec(a, i=inside)
    elif op in ("const", "reshape"):
        if (
            inside
            and on_anonymous is not None
            and (op == "reshape" or isinstance(expr.value, list))
        ):
            on_anonymous(expr)
    elif _is_elementwise(expr):
        for a in expr.args:
            rec(a, i=inside)


def _reads(expr: Expr, shapes: dict[str, list[str]]) -> list[tuple[str, bool]]:
    """Every ``(name, inside)`` :func:`_visit` reports for ``expr``."""
    out: list[tuple[str, bool]] = []
    _visit(expr, shapes, frozenset(), False, lambda n, i: out.append((n, i)))
    return out


def _refuse_anonymous_arrays(rhs: Expr, lhs: Expr) -> None:
    """``array_shape_mismatch`` when a template application in ``rhs`` reads an
    anonymous array in a value position: it has no index sets, so nothing says
    which element each cell reads (esm-spec §9.6.11)."""
    found: list[ExprNode] = []
    _visit(rhs, {}, frozenset(), False, lambda n, i: None, found.append)
    if found:
        name = lhs if isinstance(lhs, str) else _lhs_name(lhs)
        raise ElementwiseLiftError(
            f"array_shape_mismatch: '{name}': a template application reads an anonymous "
            f"array (a `{found[0].op}` node) where its body reads a scalar; an array "
            "argument of an elementwise application must be declared over index sets, so "
            "each cell knows which element it reads (esm-spec §9.6.11)"
        )


def _lhs_name(lhs: Expr) -> str:
    if isinstance(lhs, ExprNode) and lhs.args and isinstance(lhs.args[0], str):
        return f"{lhs.op}({lhs.args[0]})"
    return str(lhs)


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
    inside: bool = False,
) -> Expr:
    """``expr`` read at the current cell: every shaped read :func:`_visit`
    reports gathered at the loops its index sets name."""

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
    inside = inside or expr.template_origin is not None

    def rec(a: Expr, b: frozenset[str] = bound, i: bool = inside) -> Expr:
        return _at_cell(a, shapes, axes, loops, lhs, b, i)

    op = expr.op
    if op == "index":
        if not inside:
            return expr
        return dataclasses.replace(
            expr, args=[expr.args[0], *(rec(a, i=True) for a in expr.args[1:])]
        )
    if op == "faq":
        if not (inside and _is_rank0_faq(expr)):
            return expr
        inner = _faq_bound(expr, bound)
        return dataclasses.replace(
            expr,
            expr=None if expr.expr is None else rec(expr.expr, inner, True),
            filter=None if expr.filter is None else rec(expr.filter, inner, True),
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
    """Lift every observed equation of ``flat`` that applies a template
    elementwise (see the module docstring). A lifted variable declared without
    a ``shape`` takes the lift's index sets. Returns ``flat`` itself when
    nothing is lifted, else a shallow copy with the rewritten equations and
    variables.

    Repeats until no equation changes, so a chain of applications is lifted
    link by link.

    Raises :class:`ElementwiseLiftError` (``array_shape_mismatch``) when the
    array arguments of a lifted right-hand side have no common index sets, and
    when an application of any equation reads an anonymous array in a value
    position.
    """
    variables = {**flat.parameters, **flat.state_variables, **flat.observed_variables}
    shapes: dict[str, list[str]] = {n: list(v.shape) for n, v in variables.items() if v.shape}
    unshaped = {n for n, v in variables.items() if v.shape is None}
    equations = list(flat.equations)
    for eq in equations:
        _refuse_anonymous_arrays(eq.rhs, eq.lhs)
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
            if not any(inside for _, inside in reads):
                if lhs in unshaped and lhs not in shapes:
                    try:
                        axes0 = _union_axes([n for n, _ in reads], shapes, lhs)
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
