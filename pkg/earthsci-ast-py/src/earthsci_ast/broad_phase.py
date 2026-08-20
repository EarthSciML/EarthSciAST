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

from collections.abc import Mapping, Sequence
from typing import Any

import numpy as np

from .errors import EarthSciAstError

__all__ = [
    "BroadPhaseError",
    "ENUM_VISITS",
    "OverlapIndex",
    "broad_phase_candidates",
    "envelope_vectors_from_cols",
    "envelope_vectors",
    "overlap_candidate_set",
    "overlap_drive_plan",
    "overlap_driver",
    "overlap_restrict",
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


# =========================================================================== #
# CANDIDATE-DRIVEN ENUMERATION (projection-pushdown Wall #1) — the SHARED
# driver policy behind BOTH overlap-gated enumeration paths.
#
# An overlap gate resolves its ENTIRE admissible pair set once. Enumerating the
# full cartesian product and membership-testing each tuple therefore does
# ``O(PROD ranges)`` work to reach ``O(|candidates|)`` surviving tuples. Driving
# from the candidate set instead collapses the cost to
# ``O(|candidates| * PROD ungated)``.
#
# The two consumers differ ONLY in loop shape, never in policy:
#
#   * the value-invention producer (``value_invention._vi_enumerate_join``)
#     enumerates ranges LAZILY (a ragged ``of`` bound depends on its parent
#     binding), so it recurses; BOTH gated symbols are contracted there.
#   * the dense aggregate expansion (``numpy_interpreter._eval_arrayop_scalar``)
#     walks the contracted cartesian product once per OUTPUT cell, and that
#     output cell has usually already bound one of the two gated symbols.
#
# :func:`overlap_drive_plan` is the one implementation of the decision both
# make: which symbol(s) the gate drives, and with which values. Everything a
# caller then does is bind those values and recurse / product as it always did.
#
# The driver is a PURE OPTIMISATION. Both callers still run the full membership
# test on every leaf, so a shape the planner declines to drive (``"none"``) falls
# back to the untouched full product and the admitted leaf SET is identical
# either way.
# =========================================================================== #

#: Instrumentation: number of leaf bindings an OVERLAP-GATED enumerator VISITED
#: (a tuple its callback was invoked on / a product tuple its unroll entered).
#: Reset by callers / tests; proves that an overlap-gated walk — the
#: value-invention producer AND the dense aggregate expansion alike — visits
#: ``O(|candidates| * PROD ungated)`` tuples, NOT the full ``O(PROD ranges)``
#: product (projection-pushdown Wall #1).
#:
#: Counted ONLY when an overlap gate is present, so every ungated / bin-equality
#: expansion (the overwhelming majority, and the engine's hottest loop) keeps its
#: exact current instruction stream.
ENUM_VISITS = [0]

_NO_PARTNERS: list[int] = []


class OverlapIndex:
    """A resolved overlap gate's candidate pair set, plus the derived views the
    enumeration driver needs, built LAZILY and cached.

    A gate is resolved ONCE per node but consulted once per OUTPUT CELL, so
    rebuilding the sorted pair list or an adjacency map per cell would reinstate
    exactly the cost being removed. Membership (``in``), ``len`` and truthiness
    forward to the raw set, so every existing use site reads unchanged.

    ``__contains__`` is TOTAL: a probe that is not a hashable ``(int, int)``
    answers ``False`` rather than raising, matching the plain ``set`` this
    replaced (a categorical range would otherwise turn a rejected binding into
    a crash).
    """

    __slots__ = ("pairs", "_sorted", "_adj_l", "_adj_r")

    def __init__(self, pairs: Any) -> None:
        self.pairs: set[tuple[int, int]] = pairs if isinstance(pairs, set) else set(pairs)
        self._sorted: list[tuple[int, int]] | None = None
        self._adj_l: dict[int, list[int]] | None = None
        self._adj_r: dict[int, list[int]] | None = None

    def __contains__(self, probe: Any) -> bool:
        try:
            return probe in self.pairs
        except TypeError:  # unhashable probe — not a candidate, not a crash
            return False

    def __len__(self) -> int:
        return len(self.pairs)

    def __bool__(self) -> bool:
        return bool(self.pairs)

    def __iter__(self):
        return iter(self.pairs)

    def sorted_pairs(self) -> list[tuple[int, int]]:
        """The pairs ascending by ``(pos_src, pos_tgt)`` — the deterministic
        PAIR-drive order. Built once, cached."""
        if self._sorted is None:
            self._sorted = sorted(self.pairs)
        return self._sorted

    def adjacency(self, side: str) -> dict[int, list[int]]:
        """``side == "l"`` -> ``pos_l -> sorted pos_r``s; ``side == "r"`` ->
        ``pos_r -> sorted pos_l``s. Built once per side, cached."""
        cached = self._adj_l if side == "l" else self._adj_r
        if cached is not None:
            return cached
        adj: dict[int, list[int]] = {}
        for pl, pr in self.pairs:
            k, v = (pl, pr) if side == "l" else (pr, pl)
            adj.setdefault(k, []).append(v)
        for v_list in adj.values():
            v_list.sort()
        if side == "l":
            self._adj_l = adj
        else:
            self._adj_r = adj
        return adj

    def partners(self, side: str, pos: int) -> list[int]:
        """The SORTED partner positions of ``pos`` on the side opposite ``side``
        (``side`` names the side ``pos`` itself lives on). Empty when none."""
        return self.adjacency(side).get(int(pos), _NO_PARTNERS)


def overlap_driver(gates: Any) -> Any:
    """The first OVERLAP gate (the one carrying a prebuilt candidate index)
    among a resolved gate sequence, or ``None``. Shared by both enumeration
    paths: this is the gate whose candidates DRIVE enumeration. A bin-equality
    gate cannot drive (its admissible pair set is never materialised) and is
    left as a filter."""
    if gates is None:
        return None
    for g in gates:
        if getattr(g, "candidates", None) is not None:
            return g
    return None


def overlap_restrict(vals: Any, parts: Sequence[int]) -> list[int] | None:
    """``vals`` restricted to ``parts``, ASCENDING — or ``None`` when ``vals``
    is not an ascending contiguous integer range and the restriction therefore
    cannot be proven to be the same SUBSEQUENCE the membership test would have
    admitted.

    Preserving the subsequence (not merely the set) is what makes the driven
    walk BIT-IDENTICAL to the filtered full product: the terms it drops are
    exactly the gate-rejected ones, in the same relative order, and each of
    those contributes the semiring identity. A shape this cannot prove returns
    ``None``, and the caller falls back to the full product.
    """
    if not parts:
        return []
    # NEVER materialise `vals`: this runs once per OUTPUT CELL, and copying the
    # contracted axis each time would reinstate the O(N_out * N_contract) cost
    # the driver exists to remove (1520 * 43,650 on isrm.esm). Random access is
    # all the proof below needs, so a sized, indexable range is used in place.
    try:
        n = len(vals)
    except TypeError:  # a bare iterator has no length — materialise that one
        vals = list(vals)
        n = len(vals)
    if n == 0:
        return None
    lo, hi = int(vals[0]), int(vals[-1])
    if n != hi - lo + 1:
        return None  # stepped / permuted => decline
    out: list[int] = []
    for p in parts:
        p = int(p)
        if not (lo <= p <= hi):
            continue
        if int(vals[p - lo]) != p:
            return None  # not 1-strided ascending => decline
        out.append(p)
    return out


def overlap_drive_plan(
    gate: Any,
    free_syms: Sequence[str],
    bound: Mapping[str, int],
    valuesof: Any,
) -> tuple:
    """Decide how ``gate`` drives an enumeration whose FREE (still-to-be-
    enumerated) symbols are ``free_syms`` and whose already-bound symbols are
    ``bound`` (symbol -> 1-based position). Returns one of:

    * ``("none",)`` — do not drive; walk the full product.
    * ``("reject",)`` — both gated symbols are already bound and the pair is not
      a candidate: NO leaf is admitted.
    * ``("pairs", sym_l, sym_r, pairs)`` — both gated symbols are free: bind
      them together from the candidate ``pairs``, product the rest.
    * ``("restrict", sym, vals)`` — one gated symbol is free and the other is
      bound: the free one enumerates only ``vals``.

    ``valuesof(sym)`` supplies a free symbol's full value range; it is consulted
    only for the ``"restrict"`` shape (to prove the restriction is
    order-preserving).
    """
    if gate is None:
        return ("none",)
    oi = getattr(gate, "candidates", None)
    if oi is None:
        return ("none",)
    l_sym, r_sym = gate.sym_l, gate.sym_r
    lf = l_sym in free_syms
    rf = r_sym in free_syms
    if lf and rf:
        return ("pairs", l_sym, r_sym, oi.sorted_pairs())
    if lf or rf:
        free = l_sym if lf else r_sym
        fixed = r_sym if lf else l_sym
        if fixed not in bound:
            return ("none",)  # unbound => nothing to drive on
        parts = oi.partners("r" if lf else "l", int(bound[fixed]))
        vals = overlap_restrict(valuesof(free), parts)
        if vals is None:
            return ("none",)
        return ("restrict", free, vals)
    if l_sym not in bound or r_sym not in bound:
        return ("none",)
    return ("none",) if (int(bound[l_sym]), int(bound[r_sym])) in oi else ("reject",)
