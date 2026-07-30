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

**Where both the operand and the result carry declared index-set names, align by
NAME; reject what cannot be aligned. Everywhere else, keep the existing
positional behaviour.**

Concretely, for an operand declared over axes ``A`` used in a result declared
over axes ``T``:

* ``A ⊆ T`` — the operand broadcasts along the axes of ``T`` it does not carry.
  A ``[lat]`` operand in a ``[lon, lat, lev]`` result replicates along ``lon``
  and ``lev``, which is exactly what the explicit ``aggregate`` spelling
  (``index(w1, j)``) computes. The aggregate path is the correctness oracle and
  is not touched by any of this.
* Axis ORDER is irrelevant — ``A`` is matched to ``T`` by name, so a
  ``[lat, lon]`` operand in a ``[lon, lat, lev]`` result TRANSPOSES into the
  result's frame. It is never reinterpreted.
* An operand carrying an axis ABSENT from ``T`` cannot be aligned at all. That
  is a hard structural error from ``validate()`` (``index_set_misalignment``),
  not a run-time size error and not a warning: shapes are fully known statically
  from ``ModelVariable.shape`` plus the document ``index_sets``, so there is
  nothing to wait for.

The scope boundary
------------------

Name-based alignment applies ONLY where names exist. The results of ``reshape``,
``transpose``, ``concat``, ``makearray``, ``index``, ``aggregate``, ``fn`` and
literal arrays are ANONYMOUS — they have shapes but no index-set names — and
they keep NumPy's positional semantics (and, under ``broadcast``, that op's
established Julia-parity left-align). :data:`ELEMENTWISE_OPS` is what encodes
the boundary: the walk descends through the scalar element-wise layer, where an
operand is combined cell-wise with its siblings and so must share their frame,
and stops at every op that RESHAPES or RE-INDEXES its operands, where the
operand's axes are the op's business rather than the result's.

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

from dataclasses import replace
from typing import Any

from . import op_registry
from .esm_types import ExprNode

__all__ = [
    "ELEMENTWISE_OPS",
    "align_expression",
    "alignment_plan",
    "axis_sizes",
    "declared_axes",
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
#: array ops (``index``/``aggregate``/``makearray``/``reshape``/``transpose``/
#: ``concat``), the relational and geometry ops, ``fn``, ``D`` — terminates the
#: walk, because it re-indexes or reshapes its operands rather than combining
#: them cell-wise, and so its operands are NOT in the enclosing result's frame.
ELEMENTWISE_OPS: frozenset[str] = frozenset({"broadcast"}).union(
    *(op_registry.by_category(c) for c in op_registry.SCALAR_FN_CATEGORIES)
)


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
    ``index`` / ``aggregate`` / reshaping op — where it is NOT an operand of the
    enclosing element-wise expression — is correctly skipped.
    """
    stack = [expr]
    while stack:
        node = stack.pop()
        if isinstance(node, str):
            axes = var_axes.get(node)
            if axes:
                yield node, axes
            continue
        op, args = _op_and_args(node)
        if op is not None and op in ELEMENTWISE_OPS:
            stack.extend(args)


def unalignable_axes(axes: tuple[str, ...], target_axes: tuple[str, ...]) -> tuple[str, ...]:
    """The operand axes that do not appear in the result — empty if alignable.

    A non-empty result is the ``index_set_misalignment`` defect: there is no
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
    name: str,
    axes: tuple[str, ...],
    target_axes: tuple[str, ...],
    sizes: dict[str, int],
) -> Any:
    """``name``, wrapped in the transpose/reshape that puts it in the result's
    frame. Returns the bare name unchanged when nothing is needed."""
    perm, present = alignment_plan(axes, target_axes)
    node: Any = name
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

    A no-op — returning ``expr`` itself, not a copy — when there is nothing to
    do: no target frame, a target axis of unknown extent, or every operand
    already declared in the result's own order. Operands that cannot be aligned
    are left alone here; ``validate()`` owns that diagnostic
    (:func:`unalignable_axes`), and leaving them untouched keeps this rewrite
    total.
    """
    if not target_axes or not var_axes:
        return expr
    if any(t not in sizes for t in target_axes):
        return expr

    def rewrite(node: Any) -> Any:
        if isinstance(node, str):
            axes = var_axes.get(node)
            if not axes or axes == target_axes:
                return node
            if unalignable_axes(axes, target_axes) or any(a not in sizes for a in axes):
                return node
            return _align_leaf(node, axes, target_axes, sizes)
        op, args = _op_and_args(node)
        if op is None or op not in ELEMENTWISE_OPS or not args:
            return node
        new_args = [rewrite(a) for a in args]
        if all(new is old for new, old in zip(new_args, args)):
            return node
        if isinstance(node, ExprNode):
            return replace(node, args=new_args)
        return {**node, "args": new_args}

    return rewrite(expr)
