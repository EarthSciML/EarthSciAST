"""Recurrence groups (esm-spec §4.3.1.2), evaluated by their stacked reduction.

A recurrence GROUP is several array observeds, each defined by a ``faq`` over one
shared cell frame, that read one another — and themselves — only at strictly
earlier positions along one shared axis. §4.3.1.2 defines its value by a
reduction: the group is the single §4.3.1.1 recurrence of the members STACKED on
a trailing member axis ``m ∈ 1..M`` (members in equation order), whose cell body
at ``m = p`` is member ``p``'s cell body with every ``index(V_q, i…)`` read of a
member rewritten to ``index(S, i…, q)``; then ``V_p[k…] = S[k…, p]``.

:func:`stack_recurrence_groups` performs that rewrite on the observed equations
before they are ordered, so every route that materializes an observed sweeps a
group through the ONE recurrence implementation it already has
(:func:`earthsci_ast.numpy_interpreter.sweep_recurrence`; CONFORMANCE_SPEC
§5.19.3b). Nothing downstream knows a group exists, except that
:func:`earthsci_ast.recurrence.analyze_recurrence` admits a constant index on the
member axis (:data:`~earthsci_ast.recurrence.MEMBER_SYM`) and nowhere else.

Group RECOGNITION here mirrors the validator's
(:func:`earthsci_ast.structural_checks.recurrence_groups`) on the flattened
observed equations: a strongly connected component of two or more observeds,
with self-edges dropped, each defined by a ``faq`` with a non-empty frame, whose
internal edges are each carried by an ``index`` read. The validator has already
judged well-foundedness on the document as authored; the sweep re-checks the
stacked recurrence as it would any other.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import replace
from typing import Any

from .esm_types import Expr, ExprNode
from .expr_walk import iter_children, map_children
from .recurrence import MEMBER_SYM, RecurrenceError, cell_restricted_body

#: Prefix of the stacked array's name. Never authored.
STACK_PREFIX = "__esm_recurrence_group__"


def _reads_through_index(e: Expr, name: str) -> bool:
    stack: list[Any] = [e]
    while stack:
        n = stack.pop()
        if isinstance(n, ExprNode):
            if n.op == "index" and n.args and n.args[0] == name:
                return True
            stack.extend(iter_children(n))
    return False


def _reads_offset(e: Expr, name: str) -> bool:
    stack: list[Any] = [e]
    while stack:
        n = stack.pop()
        if isinstance(n, ExprNode):
            if (
                n.op == "index"
                and n.args
                and n.args[0] == name
                and any(not isinstance(a, str) for a in n.args[1:])
            ):
                return True
            stack.extend(iter_children(n))
    return False


def _sccs(deps: dict[str, set[str]]) -> list[set[str]]:
    """Strongly connected components (Kosaraju, iterative)."""
    visited: set[str] = set()
    finish: list[str] = []
    for root in deps:
        if root in visited:
            continue
        visited.add(root)
        stack = [(root, iter(sorted(deps[root])))]
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                finish.append(node)
                stack.pop()
            elif nxt in deps and nxt not in visited:
                visited.add(nxt)
                stack.append((nxt, iter(sorted(deps[nxt]))))
    rev: dict[str, list[str]] = {}
    for u, vs in deps.items():
        for v in vs:
            rev.setdefault(v, []).append(u)
    assigned: set[str] = set()
    out: list[set[str]] = []
    for root in reversed(finish):
        if root in assigned:
            continue
        assigned.add(root)
        comp, stack2 = set(), [root]
        while stack2:
            n = stack2.pop()
            comp.add(n)
            for p in rev.get(n, ()):
                if p not in assigned:
                    assigned.add(p)
                    stack2.append(p)
        out.append(comp)
    return out


def _frame(rhs: Expr) -> tuple[list[str], dict[str, Any]] | None:
    if isinstance(rhs, ExprNode) and rhs.op == "faq" and rhs.output_idx:
        ranges = rhs.ranges if isinstance(rhs.ranges, dict) else {}
        return [str(s) for s in rhs.output_idx], ranges
    return None


def _stack_reads(e: Expr, members: list[str], stacked: str) -> Expr:
    if isinstance(e, str) and e in members:
        raise RecurrenceError(
            "recurrence_not_wellfounded",
            f"'{e}' is read bare inside its recurrence group. A bare read names the whole "
            f"array, which does not exist while the group sweeps it (esm-spec §4.3.1.2).",
        )
    if not isinstance(e, ExprNode):
        return e
    if e.op == "index" and e.args and isinstance(e.args[0], str) and e.args[0] in members:
        q = members.index(e.args[0]) + 1
        return replace(
            e,
            args=[stacked, *(_stack_reads(a, members, stacked) for a in e.args[1:]), q],
        )
    return map_children(e, lambda c: _stack_reads(c, members, stacked))


def _reads_same_cell(e: Expr, peer: str, idx_names: list[str]) -> bool:
    stack: list[Any] = [e]
    while stack:
        n = stack.pop()
        if isinstance(n, ExprNode):
            if (
                n.op == "index"
                and n.args
                and n.args[0] == peer
                and [str(a) if isinstance(a, str) else None for a in n.args[1:]] == idx_names
            ):
                return True
            stack.extend(iter_children(n))
    return False


def _order_within_cell(members: list[str], rhs_of: dict[str, Expr]) -> list[str]:
    """The members in the order §4.3.1.2 fixes for the member axis: a member
    another reads at the cell being written comes before it (rule 1), ties in
    equation order (``members`` arrives in equation order)."""
    frames = {m: _frame(rhs_of[m]) for m in members}
    deps = {
        m: {p for p in members if p != m and _reads_same_cell(rhs_of[m], p, frames[m][0])}
        for m in members
    }
    order: list[str] = []
    while len(order) < len(members):
        nxt = next((m for m in members if m not in order and deps[m] <= set(order)), None)
        if nxt is None:
            raise RecurrenceError(
                "recurrence_not_wellfounded",
                f"the members of the recurrence group {members} read one another at the cell "
                f"being written in a cycle (esm-spec §4.3.1.2 rule 1).",
            )
        order.append(nxt)
    return order


def stack_recurrence_groups(
    observed_eqs: list[tuple[str, Expr]],
    element_types: Callable[[str], str | None] | None = None,
) -> list[tuple[str, Expr]]:
    """``observed_eqs`` with every recurrence group replaced by its stacked
    recurrence followed by one slice per member (module docs). A list with no
    group — every document that does not use the construct — is returned as is
    after one dependency pass."""
    names = [n for n, _ in observed_eqs]
    rhs_of = dict(observed_eqs)
    if len(rhs_of) < 2:
        return observed_eqs
    produced = set(rhs_of)
    deps: dict[str, set[str]] = {}
    for name, rhs in observed_eqs:
        refs: set[str] = set()
        stack: list[Any] = [rhs]
        while stack:
            n = stack.pop()
            if isinstance(n, str):
                refs.add(n)
            elif isinstance(n, ExprNode):
                stack.extend(iter_children(n))
        deps[name] = (refs & produced) - {name}
    groups: list[list[str]] = []
    for comp in _sccs(deps):
        if len(comp) < 2:
            continue
        if not all(_frame(rhs_of[m]) is not None for m in comp):
            continue
        if not all(
            _reads_through_index(rhs_of[u], v) for u in comp for v in deps[u] if v in comp
        ):
            continue
        if not any(_reads_offset(rhs_of[u], v) for u in comp for v in comp):
            continue
        groups.append(_order_within_cell([n for n in names if n in comp], rhs_of))
    if not groups:
        return observed_eqs

    out = list(observed_eqs)
    for members in groups:
        frames = [_frame(rhs_of[m]) for m in members]
        idx_names, ranges = frames[0]
        for m, (idx, rng) in zip(members[1:], frames[1:]):
            if idx != idx_names or any(rng.get(s) != ranges.get(s) for s in idx):
                raise RecurrenceError(
                    "recurrence_group_axis_mismatch",
                    f"'{m}' and '{members[0]}' form a recurrence group but do not sweep the "
                    f"same cell frame (esm-spec §4.3.1.2).",
                )
        if element_types is not None and len({element_types(m) for m in members}) > 1:
            raise RecurrenceError(
                "recurrence_unsupported_form",
                f"the members of the recurrence group {members} declare different "
                f"`element_type`s; this binding sweeps a group at one working precision.",
            )
        if MEMBER_SYM in idx_names:
            raise RecurrenceError(
                "recurrence_unsupported_form",
                f"'{MEMBER_SYM}' is reserved for the member axis of a recurrence group.",
            )
        stacked = STACK_PREFIX + "__".join(members)
        while stacked in rhs_of:
            stacked += "_"
        body: Expr | None = None
        for p in range(len(members), 0, -1):
            rhs = rhs_of[members[p - 1]]
            cell = cell_restricted_body(rhs, idx_names, lambda fields, r=rhs: replace(r, **fields))
            cell = _stack_reads(cell, members, stacked)
            body = (
                cell
                if body is None
                else ExprNode(
                    op="ifelse",
                    args=[ExprNode(op="==", args=[MEMBER_SYM, p]), cell, body],
                )
            )
        stacked_rhs = ExprNode(
            op="faq",
            args=[],
            output_idx=[*idx_names, MEMBER_SYM],
            ranges={**ranges, MEMBER_SYM: [1, len(members)]},
            expr=body,
        )
        slices = {
            m: ExprNode(
                op="faq",
                args=[],
                output_idx=list(idx_names),
                ranges=dict(ranges),
                expr=ExprNode(op="index", args=[stacked, *idx_names, p]),
            )
            for p, m in enumerate(members, start=1)
        }
        first = min(i for i, (n, _) in enumerate(out) if n in members)
        out = [(n, slices.get(n, r)) for n, r in out]
        out.insert(first, (stacked, stacked_rhs))
    return out
