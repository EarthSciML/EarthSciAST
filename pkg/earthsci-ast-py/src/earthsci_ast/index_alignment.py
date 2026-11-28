"""Align array-level operands by index-set NAME (esm-spec §4.3; issue #100).

The defect this closes
----------------------

An array-level expression such as ``{"op": "*", "args": ["w1", "ones3"]}`` used
to be handed straight to NumPy, which aligns operand shapes POSITIONALLY and
RIGHT-to-left. So a ``w1`` declared over ``shape: ["lat"]`` (extent 2), combined
against a ``[lon, lat, lev]`` field in a ``lon=3, lat=2, lev=2`` grid, was
replicated along ``lon`` and ``lat`` and varied along **``lev``** — an axis it
was never declared over. The run reported ``valid=True``, ``success=True`` and
zero warnings; only the numbers were wrong, and they were wrong in a way no
amount of reading the document could predict. Whether the mistake surfaced at
all depended on nothing but arithmetic luck: an operand whose element count
happened not to divide the state's got a loud size error, and one whose count
happened to match got silent corruption.

The equal-rank case was corrupted the same way. An operand declared
``shape: ["lat", "lon"]`` used in a ``[lon, lat]`` result was reinterpreted
rather than transposed, so it came out silently TRANSPOSED.

The rule
--------

Where the operand and the result carry index-set names, align by name. An
undeclared result takes the union of its operands' named axes in operand
order. Anonymous operands align positionally.

Concretely, for an operand declared over axes ``A`` used in a result declared
over axes ``T``:

* ``A ⊆ T`` — the operand broadcasts along the axes of ``T`` it does not carry.
  A ``[lat]`` operand in a ``[lon, lat, lev]`` result replicates along ``lon``
  and ``lev``, which is exactly what the explicit ``faq`` spelling
  (``index(w1, j)``) computes. The aggregate path is the correctness oracle and
  is not touched by any of this.
* Axis ORDER is irrelevant — ``A`` is matched to ``T`` by name, so a
  ``[lat, lon]`` operand in a ``[lon, lat, lev]`` result TRANSPOSES into the
  result's frame. It is never reinterpreted.
* An operand carrying an axis ABSENT from ``T`` cannot be aligned at all. That
  is a hard structural error from ``validate()`` (``array_shape_mismatch``),
  not a run-time size error and not a warning: shapes are fully known statically
  from ``ModelVariable.shape`` plus the document ``index_sets``, so there is
  nothing to wait for.

The scope boundary
------------------

The scalar elementwise layer combines cells in a shared frame. A whole-array
consumer, such as ``index`` or ``reshape``, holds each operand in the operand's
own frame. If one of those operands is elementwise, its named operands still
align with each other. Anonymous operands in a named frame use the same
left-aligned positional rule as explicit ``broadcast``.

How the alignment is applied
----------------------------

By a STATIC rewrite of the expression, performed once at build time, not by a
check on the per-step hot path. Each named leaf that is not already in the
result's frame is wrapped in the ``transpose`` (reorder) and ``reshape``
(rank-lift with size-1 axes) it needs; NumPy's own broadcasting then does the
replication. A leaf already in the result's frame — the overwhelmingly common
case — is returned untouched, so a document that was already unambiguous
produces a byte-identical tree and byte-identical numbers.

Both representations are handled by one walk: the raw ``dict`` form the
``validate()`` checks see, and the typed :class:`~earthsci_ast.esm_types.ExprNode`
form the simulator sees.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import replace
from graphlib import CycleError, TopologicalSorter
from typing import TYPE_CHECKING, Any

from . import op_registry
from .esm_types import ExprNode

if TYPE_CHECKING:
    from .flatten import FlattenedSystem

__all__ = [
    "ELEMENTWISE_OPS",
    "align_expression",
    "alignment_plan",
    "axis_sizes",
    "declared_axes",
    "faq_bare_array_operand_message",
    "faq_bare_array_operands",
    "faq_bare_exempt_names",
    "first_unalignable_operand",
    "iter_named_operands",
    "unalignable_axes",
]


#: The ops through which a declared index-set frame propagates: the scalar
#: element-wise layer (arithmetic, elementary functions, comparisons, the
#: logical connectives, ``ifelse``) plus ``broadcast``, which is notation for
#: exactly that layer (esm-spec §4.3.4).
#:
#: DERIVED from the op registry rather than hand-listed, so an element-wise op
#: added there is covered here automatically. Every op NOT in this set — the
#: array ops (``index``/``faq``/``makearray``/``reshape``/``transpose``/
#: ``concat``), the relational and geometry ops, ``fn``, ``D`` — terminates the
#: walk, because it re-indexes or reshapes its operands rather than combining
#: them cell-wise, and so its operands are NOT in the enclosing result's frame.
#:
#: CROSS-BINDING: this is Python's counterpart to Rust's
#: ``op_registry::is_elementwise_node``. Both descend through ``broadcast``
#: (esm-spec §4.3.4: the rule governs an array-level expression "whether
#: spelled with an explicit `broadcast` node or written bare"), and they agree
#: on every op that occurs in a document. The differences are spellings Rust
#: never sees:
#:
#: * ``pow`` / ``**`` — registry ALIASES of ``^``, equally elementwise. Python
#:   descends; Rust matches raw op strings and lists only ``^``.
#: * ``true`` / ``false`` / ``=`` — Python-side only, and inert: the literals
#:   are nullary (descending yields no operands) and ``=`` is an alias of ``==``.
ELEMENTWISE_OPS: frozenset[str] = frozenset({"broadcast"}).union(
    *(op_registry.by_category(c) for c in op_registry.SCALAR_FN_CATEGORIES)
)
_BROADCAST_FNS = op_registry.scalar_fn_names()


def _op_and_args(node: Any) -> tuple[str | None, list]:
    """``(op, args)`` for either representation; ``(None, [])`` for a non-node."""
    if isinstance(node, ExprNode):
        return node.op, list(node.args or [])
    if isinstance(node, dict):
        op = node.get("op")
        args = node.get("args")
        return (op if isinstance(op, str) else None), (args if isinstance(args, list) else [])
    return None, []


def declared_axes(shape: Any) -> tuple[str, ...] | None:
    """A variable's declared ``shape`` as an axis-NAME tuple, or ``None``.

    ``None`` — meaning "no usable name frame, fall back to positional" — for a
    scalar (no shape), a shape carrying integer extents rather than index-set
    names, or a shape that repeats an axis name (which no permutation can
    resolve unambiguously).
    """
    if not isinstance(shape, (list, tuple)) or not shape:
        return None
    if not all(isinstance(s, str) for s in shape):
        return None
    axes = tuple(shape)
    if len(set(axes)) != len(axes):
        return None
    return axes


def axis_sizes(index_sets: Any) -> dict[str, int]:
    """``index-set name -> extent`` for every set with a statically known size.

    Only ``kind: "interval"`` sets qualify. A ``derived`` set's extent is
    data-dependent (it is materialized at setup from a FAQ), so an operand over
    one cannot be rank-lifted statically and is left positional — the NAME check
    still applies to it, since that needs no sizes.
    """
    out: dict[str, int] = {}
    for name, entry in (index_sets or {}).items():
        if isinstance(entry, dict) and entry.get("kind") == "interval":
            size = entry.get("size")
            if isinstance(size, int) and not isinstance(size, bool):
                out[name] = int(size)
    return out


def iter_named_operands(expr: Any, var_axes: dict[str, tuple[str, ...]]):
    """Yield ``(name, axes)`` for each bare-name leaf in ``expr``'s own frame.

    Descends only through :data:`ELEMENTWISE_OPS`, so a name appearing under an
    ``index`` / ``faq`` / reshaping op — where it is NOT an operand of the
    enclosing element-wise expression — is correctly skipped.

    Yields in LEFT-TO-RIGHT pre-order. The order is observable — it decides
    which operand a multi-operand defect is reported against — and Rust's
    equivalent walk (``structural::collect_bare_array_operands``) is a
    left-to-right recursive descent, so the stack is fed reversed to match it.
    """
    for name in _elementwise_names(expr):
        axes = var_axes.get(name)
        if axes:
            yield name, axes


def _elementwise_names(expr: Any) -> Iterator[str]:
    stack = [expr]
    while stack:
        node = stack.pop()
        if isinstance(node, str):
            yield node
            continue
        op, args = _op_and_args(node)
        if op is not None and op in ELEMENTWISE_OPS:
            stack.extend(reversed(args))


def _expression_axes(
    expr: Any,
    axes: dict[str, tuple[str, ...]],
    target: str = "",
    include_anonymous: bool = False,
) -> tuple[str, ...]:
    """Union the named axes on the elementwise value path in operand order.

    The operands are the named variables and the ``faq``/``makearray``
    producers that path reaches, at any depth: ``k * faq(...)`` spans the
    producer's index sets, as Julia's ``_expr_axes`` reads it (esm-spec §4.3.4,
    "An undeclared result takes the union").
    """
    return tuple(
        dict.fromkeys(
            axis
            for frame in _value_path_frames(expr, axes, target, include_anonymous)
            for axis in frame
        )
    )


def _value_path_frames(
    expr: Any, axes: dict[str, tuple[str, ...]], target: str, include_anonymous: bool
) -> Iterator[tuple[str, ...]]:
    """Each operand frame on ``expr``'s elementwise value path, left to right."""
    for _, frame in _value_path_operands(expr, axes, target, include_anonymous):
        yield frame


def _value_path_operands(
    expr: Any, axes: dict[str, tuple[str, ...]], target: str, include_anonymous: bool
) -> Iterator[tuple[Any, tuple[str, ...]]]:
    if isinstance(expr, str):
        frame = axes.get(expr)
        if frame:
            yield expr, frame
        return
    produced = _producer_axes(expr, target, include_anonymous)
    if produced:
        yield expr, produced
        return
    op, args = _op_and_args(expr)
    if op is not None and op in ELEMENTWISE_OPS:
        for arg in args:
            yield from _value_path_operands(arg, axes, target, include_anonymous)


def first_unalignable_operand(
    expr: Any, target_axes: tuple[str, ...], var_axes: dict[str, tuple[str, ...]]
) -> tuple[Any, tuple[str, ...], str] | None:
    """``(operand, operand_axes, first_foreign_axis)`` for the first operand on
    ``expr``'s value path (a named variable or a nested ``faq``/``makearray``)
    carrying an index set ``target_axes`` lacks — the ``array_shape_mismatch``
    of esm-spec §4.3.4 rule 1 — or ``None`` when every operand aligns."""
    for operand, frame in _value_path_operands(expr, var_axes, "", False):
        extra = unalignable_axes(frame, target_axes)
        if extra:
            return operand, frame, extra[0]
    return None


def _producer_axes(rhs: Any, target: str, include_anonymous: bool) -> tuple[str, ...]:
    """Index sets declared by a producer, or labels for an inline FAQ box."""
    op = _faq_field(rhs, "op")
    if op not in {"faq", "makearray"}:
        return ()
    ranges = _faq_field(rhs, "ranges") or {}
    outputs = _faq_field(rhs, "output_idx") or []
    if not outputs or not all(isinstance(sym, str) for sym in outputs):
        return ()
    operands = [ranges.get(sym) for sym in outputs]
    if all(isinstance(r, dict) and isinstance(r.get("from"), str) for r in operands):
        return tuple(r["from"] for r in operands)
    if include_anonymous and all(
        isinstance(r, list) and len(r) == 2 and r[0] == 1 for r in operands
    ):
        return tuple(f"{target}__{sym}" for sym in outputs)
    return ()


def promoted_axes(
    flat: FlattenedSystem, *, include_anonymous: bool = False
) -> dict[str, tuple[str, ...]]:
    """Declared frames and the frames inferred from bare observed definitions.

    Look up earlier or later definitions on demand so visiting equations in a
    different order cannot change an inferred frame. An explicit empty shape
    declares a scalar. When checking for a bare array read inside `faq`, the
    caller also needs labels for known anonymous arrays.
    """
    axes: dict[str, tuple[str, ...]] = {}
    for table in (flat.state_variables, flat.observed_variables, flat.parameters):
        for name, var in table.items():
            shape = getattr(var, "shape", None)
            if shape is not None:
                axes[name] = (
                    tuple(str(axis) for axis in shape)
                    if include_anonymous
                    else declared_axes(shape) or ()
                )
    definitions = {
        eq.lhs: eq.rhs for eq in flat.equations if isinstance(eq.lhs, str) and eq.lhs not in axes
    }
    order = TopologicalSorter(
        {
            name: {ref for ref in _elementwise_names(rhs) if ref in definitions}
            for name, rhs in definitions.items()
        }
    )
    try:
        order.prepare()
    except CycleError:
        # The observed-graph builder diagnoses cycles. Infer the frames of
        # independent definitions here even if another part of the graph cycles.
        pass
    while order.is_active():
        ready = order.get_ready()
        for name in ready:
            rhs = definitions[name]
            axes[name] = _expression_axes(rhs, axes, name, include_anonymous)
        order.done(*ready)
    return {name: shape for name, shape in axes.items() if shape}


def _faq_field(node: Any, name: str) -> Any:
    if isinstance(node, ExprNode):
        return getattr(node, name, None)
    if isinstance(node, dict):
        return node.get(name)
    return None


def _faq_children(node: Any):
    if isinstance(node, ExprNode):
        from .expr_walk import iter_children

        yield from iter_children(node)
    elif isinstance(node, dict):
        from .json_walk import iter_child_values

        for _, child in iter_child_values(node):
            yield child


def faq_bare_array_operand_message(field_name: str, name: str, axes: tuple[str, ...]) -> str:
    """The ``faq_bare_array_operand`` message, shared by ``validate`` and the
    build front door."""
    return (
        f"faq `{field_name}` reads {name!r}, declared over [{', '.join(axes)}], by "
        f"bare name. A faq names its axes by its range symbols, and its "
        f"`{field_name}` is evaluated once per index tuple, so a whole array there "
        f"does not say which symbol each of its axes is. Read it through `index`, "
        f"e.g. index({name}, <symbol>…) (esm-spec §4.3.1)"
    )


def faq_bare_array_operands(
    expr: Any, var_axes: dict[str, tuple[str, ...]]
) -> list[tuple[str, str, tuple[str, ...]]]:
    """``faq_bare_array_operand`` (esm-spec §4.3.1, issue #441): every
    ``(field, name, axes)`` where a ``faq`` node's ``expr`` or ``filter`` reads a
    shaped variable by BARE name in an elementwise position.

    A ``faq`` names its axes by its range symbols and evaluates its body and
    filter once per index tuple, so a whole array there does not say which
    symbol each of its axes is. Evaluators each gave it a meaning, and they
    disagreed: Rust's reference aligned an array filter to the output box by
    position and kept every term on a rank mismatch (a filter silently ignored
    once the node had two output indices), and this binding's whole-box tiers
    let numpy broadcasting align the array with the LAST box axis, a different
    symbol whenever the extents coincide. So the read is refused: it must be
    ``index(name, i, …)``.

    The descent is :func:`iter_named_operands`' (elementwise ops only), a name
    bound as a loop symbol by this node or an enclosing one shadows the
    declaration, nested ``faq`` nodes are checked in their own right, and an
    ``apply_expression_template`` application is opaque: an array bound to one
    of its arguments is not a bare read here. Works on the raw dict form and on
    typed :class:`ExprNode` trees alike. Order is pre-order over nodes, ``expr``
    before ``filter``, matching Rust's
    ``structural::faq_bare_array_operand_errors``.
    """
    shaped = {n: a for n, a in var_axes.items() if a}
    found: list[tuple[str, str, tuple[str, ...]]] = []
    if not shaped:
        return found

    def walk(node: Any, bound: frozenset[str]) -> None:
        op = _faq_field(node, "op")
        if op is None or op == "apply_operator":
            return
        if op == "faq":
            syms = set(_faq_field(node, "output_idx") or [])
            syms |= set((_faq_field(node, "ranges") or {}).keys())
            bound = bound | {str(s) for s in syms}
            for field_name in ("expr", "filter"):
                part = _faq_field(node, field_name)
                if part is None:
                    continue
                seen: set[str] = set()
                for name, axes in iter_named_operands(part, shaped):
                    if name in bound or name in seen:
                        continue
                    seen.add(name)
                    found.append((field_name, name, axes))
        for child in _faq_children(node):
            walk(child, bound)

    walk(expr, frozenset())
    return found


def faq_bare_exempt_names(lhs: Any, names: set[str]) -> set[str]:
    """The names ``faq_bare_array_operand`` skips for an equation whose
    left-hand side is ``lhs`` and names ``names``: all of them for an observed
    or recurrence definition, whose bare self-read ``recurrence_not_wellfounded``
    or ``observed_cycle`` reports; none for a derivative — ``D(y)``, or the
    array-equation ``faq[i](D(y[i]))`` — whose bare state read no other check
    reports."""

    def holds_derivative(node: Any) -> bool:
        if _faq_field(node, "op") == "D":
            return True
        return any(holds_derivative(child) for child in _faq_children(node))

    return set() if holds_derivative(lhs) else names


def unalignable_axes(axes: tuple[str, ...], target_axes: tuple[str, ...]) -> tuple[str, ...]:
    """The operand axes that do not appear in the result — empty if alignable.

    A non-empty result is the ``array_shape_mismatch`` defect: there is no
    replication, transpose or reshape that can put such an operand into the
    result's frame, so the expression has no meaning under name-based alignment.
    """
    target = set(target_axes)
    return tuple(a for a in axes if a not in target)


def alignment_plan(
    axes: tuple[str, ...], target_axes: tuple[str, ...]
) -> tuple[tuple[int, ...], tuple[bool, ...]]:
    """How to move an operand over ``axes`` into the ``target_axes`` frame.

    Returns ``(perm, present)``:

    * ``perm`` — a 0-based permutation of the operand's OWN dimensions that puts
      them in target-relative order (identity when the declared order already
      agrees); and
    * ``present`` — one flag per target axis, ``True`` where the operand carries
      that axis. The aligned operand's shape is the target extent where ``True``
      and ``1`` where ``False``, which is what makes NumPy replicate it along
      the axes it does not carry.

    Caller must have checked :func:`unalignable_axes` first.
    """
    position = {name: i for i, name in enumerate(target_axes)}
    perm = tuple(sorted(range(len(axes)), key=lambda i: position[axes[i]]))
    present = tuple(t in set(axes) for t in target_axes)
    return perm, present


def _align_leaf(
    operand: Any,
    axes: tuple[str, ...],
    target_axes: tuple[str, ...],
    sizes: dict[str, int],
) -> Any:
    """``operand`` (a name or a ``faq``/``makearray`` producer), wrapped in the
    transpose/reshape that puts it in the result's frame. Returns it unchanged
    when nothing is needed."""
    perm, present = alignment_plan(axes, target_axes)
    node: Any = operand
    if perm != tuple(range(len(axes))):
        node = ExprNode(op="transpose", args=[node], perm=list(perm))
    # Post-transpose shape vs. the shape the result's frame calls for.
    ordered = [axes[i] for i in perm]
    current = [sizes[a] for a in ordered]
    wanted = [sizes[t] if p else 1 for t, p in zip(target_axes, present)]
    if current != wanted:
        node = ExprNode(op="reshape", args=[node], shape=wanted)
    return node


def align_expression(
    expr: Any,
    target_axes: tuple[str, ...] | None,
    var_axes: dict[str, tuple[str, ...]],
    sizes: dict[str, int],
) -> Any:
    """Rewrite ``expr`` so every named element-wise operand sits in
    ``target_axes``.

    If no frame is given, use the named union of the elementwise operands.
    Operands that cannot be aligned are left alone here; ``validate()`` owns that diagnostic
    (:func:`unalignable_axes`), and leaving them untouched keeps this rewrite
    total.
    """
    if not var_axes:
        return expr

    def rewrite(node: Any, frame: tuple[str, ...] | None) -> Any:
        if isinstance(node, str):
            axes = var_axes.get(node)
            if not frame or not axes or axes == frame:
                return node
            if unalignable_axes(axes, frame) or any(a not in sizes for a in frame):
                return node
            return _align_leaf(node, axes, frame, sizes)
        produced = _producer_axes(node, "", False)
        if produced:
            # A producer consumes its own operands whole (they get no frame);
            # its value is placed in the enclosing frame by the sets it names.
            inner = rewrite_node(node, None)
            if (
                not frame
                or produced == frame
                or unalignable_axes(produced, frame)
                or any(a not in sizes for a in frame)
            ):
                return inner
            return _align_leaf(inner, produced, frame, sizes)
        return rewrite_node(node, frame)

    def rewrite_node(node: Any, frame: tuple[str, ...] | None) -> Any:
        op, args = _op_and_args(node)
        if not args:
            return node
        if op in ELEMENTWISE_OPS:
            # An enclosing elementwise result supplies the frame. A whole-array
            # consumer gives its operands each their own frame instead.
            frame = frame or _expression_axes(node, var_axes)
        else:
            frame = None
        new_args = [rewrite(a, frame) for a in args]
        if (
            frame
            and all(axis in sizes for axis in frame)
            and op in _BROADCAST_FNS
            and len(args) > 1
        ):
            # Named operands already have the frame's rank. An anonymous array
            # alongside them must left-align too. The explicit broadcast node
            # applies that positional rule and the same scalar operator.
            operand_axes = [_expression_axes(arg, var_axes) for arg in args]
            if any(operand_axes) and any(
                not axes and isinstance(arg, (str, ExprNode, dict))
                for arg, axes in zip(args, operand_axes)
            ):
                if isinstance(node, ExprNode):
                    return replace(node, op="broadcast", fn=op, args=new_args)
                return {**node, "op": "broadcast", "fn": op, "args": new_args}
        if all(new is old for new, old in zip(new_args, args)):
            return node
        if isinstance(node, ExprNode):
            return replace(node, args=new_args)
        return {**node, "args": new_args}

    return rewrite(expr, target_axes)
