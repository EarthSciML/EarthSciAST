"""PLANAR spatial-index broad phase — conservative candidate generation.

Python mirror of the Julia reference ``EarthSciAST.jl/src/broad_phase.jl`` and
the Rust ``earthsci-ast-rs/src/broad_phase.rs``, implementing the normative
broad-phase contract of CONFORMANCE_SPEC §5.5.6 (projection-pushdown Phase 2a/3a).

:func:`broad_phase_candidates` returns a CONSERVATIVE SUPERSET of the
``(query x cell)`` index pairs whose 2-D bounding boxes (envelopes) intersect.
It is consumed by the value-invention ``join.overlap`` gate
(:mod:`earthsci_ast.value_invention`), which replaces uniform-grid bin-equality
with envelope candidacy. The narrow phase (the exact rectangle / polygon test)
stays as the aggregate's ``filter``; this module is ONLY the conservative broad
phase.

ENVELOPE CONVENTION. A feature envelope is ``(xmin, ymin, xmax, ymax)``. Note
this ORDER differs from a ring bbox's natural ``(xmin, xmax, ymin, ymax)``, so
:func:`ring_envelopes` remaps. The intersection predicate is CLOSED — edge-touching
boxes ARE candidates:

    q.xmin <= c.xmax and c.xmin <= q.xmax and q.ymin <= c.ymax and c.ymin <= q.ymax

``eps`` SEMANTICS. Both envelopes of a pair are inflated OUTWARD by ``eps``
(``xmin -= eps, ymin -= eps, xmax += eps, ymax += eps``) before testing. ``eps >= 0``
grows the candidate set monotonically: ``candidates(eps=d) >= candidates(eps=0)``.

DETERMINISM. The result is sorted ascending by ``(qi, cj)`` with 1-based positions.
Julia's STRtree fast path and Rust's rstar R*-tree are both required to return a
set byte-identical to this brute-force oracle for the same ``eps``; this module
IS the oracle, so the Python engine is byte-identical to both by construction.
Because the emitted relational keys are INTEGER (§5.5.1), the ``distinct`` member
set a gated producer materialises is byte-identical across bindings regardless of
which candidate-generation backend an engine uses.
"""

from __future__ import annotations

from typing import Any, Mapping, Sequence

import numpy as np

from .errors import EarthSciAstError

__all__ = [
    "BroadPhaseError",
    "broad_phase_candidates",
    "envelope_vectors_from_cols",
    "envelope_vectors",
    "overlap_candidate_set",
    "ring_envelopes",
]


class BroadPhaseError(EarthSciAstError):
    """A malformed overlap-join envelope specification."""


def _envs_array(envs: Sequence[Any]) -> np.ndarray:
    """Coerce a sequence of 4-element envelopes to an ``(n, 4)`` float array."""
    arr = np.asarray(envs, dtype=float)
    if arr.size == 0:
        return np.empty((0, 4), dtype=float)
    if arr.ndim != 2 or arr.shape[1] != 4:
        raise BroadPhaseError(
            f"broad-phase envelopes must be (n, 4) (xmin, ymin, xmax, ymax); got shape {arr.shape}"
        )
    return arr


def broad_phase_candidates(
    query_envs: Sequence[Any],
    cell_envs: Sequence[Any],
    eps: float = 0.0,
) -> list[tuple[int, int]]:
    """Every ``(qi, cj)`` — 1-based positions — whose 2-D envelopes intersect
    after inflating BOTH outward by ``eps``, sorted ascending by ``(qi, cj)``.

    Envelopes are ``(xmin, ymin, xmax, ymax)``. The per-axis predicate is CLOSED
    (edge-touching admitted). This is the brute-force ``O(nq*nc)`` reference
    oracle of CONFORMANCE_SPEC §5.5.6; it is conservative (a SUPERSET of true
    geometric overlaps — an envelope contains its geometry, so missing a true
    overlap is impossible by construction) and monotone in ``eps``.

    The comparisons are exact float predicates, so vectorising them over the
    cell axis is bit-identical to the scalar double loop — no reassociation is
    involved, and the emitted pair set is therefore backend-independent.
    """
    q = _envs_array(query_envs)
    c = _envs_array(cell_envs)
    out: list[tuple[int, int]] = []
    if q.shape[0] == 0 or c.shape[0] == 0:
        return out
    e = float(eps)
    # Inflate once; both sides move outward by eps (spec: BOTH envelopes).
    cxmin = c[:, 0] - e
    cymin = c[:, 1] - e
    cxmax = c[:, 2] + e
    cymax = c[:, 3] + e
    for qi in range(q.shape[0]):
        qxmin = q[qi, 0] - e
        qymin = q[qi, 1] - e
        qxmax = q[qi, 2] + e
        qymax = q[qi, 3] + e
        hit = (qxmin <= cxmax) & (cxmin <= qxmax) & (qymin <= cymax) & (cymin <= qymax)
        for cj in np.flatnonzero(hit):
            out.append((qi + 1, int(cj) + 1))
    # Emitted in (qi, cj) ascending order already; the sort pins the determinism
    # contract independent of loop structure.
    out.sort()
    return out


def ring_envelopes(rings: Any) -> np.ndarray:
    """A ``[pos, verts, coord]`` 3-D ring factor → one ``(xmin, ymin, xmax, ymax)``
    AABB per position (the single-factor ``env`` arity of §5.5.6)."""
    arr = np.asarray(rings, dtype=float)
    if arr.ndim != 3:
        raise BroadPhaseError(
            f"overlap-join single-factor env expects a [pos, verts, coord] 3-D ring "
            f"array; got a {arr.ndim}-D factor"
        )
    if arr.shape[2] < 2:
        raise BroadPhaseError(
            f"overlap-join ring factor needs at least 2 coordinate columns (x, y); "
            f"got {arr.shape[2]}"
        )
    x = arr[:, :, 0]
    y = arr[:, :, 1]
    return np.column_stack((x.min(axis=1), y.min(axis=1), x.max(axis=1), y.max(axis=1)))


def envelope_vectors_from_cols(env_names: Sequence[Any], cols: Sequence[Any]) -> np.ndarray:
    """Per-position ``(xmin, ymin, xmax, ymax)`` envelopes from named const-array
    envelope factors (§5.5.6 arity rules):

    * **4 names** -> rectangles ``[xmin, ymin, xmax, ymax]`` (e.g. cells ``[W,S,E,N]``);
    * **2 names** -> points ``[x, y]`` -> the degenerate envelope ``(x, y, x, y)``;
    * **1 name**  -> a ``[pos, verts, coord]`` ring factor -> its axis-aligned bbox.
    """
    k = len(env_names)
    if k == 4:
        a, b, c, d = (np.asarray(col, dtype=float).reshape(-1) for col in cols)
        return np.column_stack((a, b, c, d))
    if k == 2:
        x, y = (np.asarray(col, dtype=float).reshape(-1) for col in cols)
        return np.column_stack((x, y, x, y))
    if k == 1:
        return ring_envelopes(cols[0])
    raise BroadPhaseError(
        f"overlap-join env must name 1 (rings), 2 (point [x,y]), or 4 "
        f"(rect [xmin,ymin,xmax,ymax]) const-array factors; got {k}"
    )


def envelope_vectors(env_names: Sequence[Any], arrays: Mapping[str, Any]) -> np.ndarray:
    """Look each env-factor name up in a const-array registry -> envelope array.

    Names are stringified so ``str`` keys resolve regardless of the caller's key
    type. A missing factor is a hard, named error: the gate cannot silently fall
    back to a full product, because that would change the cost class without
    changing the answer and so would hide the bug.
    """
    cols = []
    for n in env_names:
        name = str(n)
        if name not in arrays:
            raise BroadPhaseError(
                f"overlap-join envelope factor {name!r} is not bound in const_arrays "
                f"(have: {sorted(str(k) for k in arrays)})"
            )
        cols.append(arrays[name])
    return envelope_vectors_from_cols(list(env_names), cols)


def overlap_candidate_set(
    src_envs: Any,
    tgt_envs: Any,
    eps: float = 0.0,
) -> set[tuple[int, int]]:
    """The OVERLAP join-gate candidate set: every ``(src_pos, tgt_pos)`` whose
    envelopes intersect (inflated outward by ``eps``), with ``src_env`` the query
    side and ``tgt_env`` the indexed cell side. Built ONCE per gate node, then
    consulted by membership per contracted tuple.
    """
    return set(broad_phase_candidates(src_envs, tgt_envs, eps=eps))
