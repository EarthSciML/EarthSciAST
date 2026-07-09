"""Build-time relational engine — the five value-invention primitives.

The unified-IR value-invention pass (RFC ``semiring-faq-unified-ir`` §5.5, §6.1)
runs these **once at setup**, off the per-timestep hot path, to materialise the
data-derived index sets and dense IDs the numeric stencil then consumes:

1. :func:`distinct`        — deduplicate tuples (unique mesh edges from face→vertex lists)
2. :func:`equijoin`        — value-equality equi-join (connectivity inversion, *edges of cell i*)
3. :func:`skolem` / :func:`skolem_edge` — deterministic content-addressed key from a tuple
4. :func:`rank`            — dense integer renumbering of a distinct set
5. :func:`group_aggregate` — group-by + associative/commutative semiring ``⊕`` (sum/min/max/…)

Determinism (the reason this module exists)
===========================================

``earthsci-ast`` is **parallel native implementations** (Julia, Rust,
Python) verified by a conformance suite, not one core behind FFI. So the hard
problem is **bit-for-bit determinism across the bindings**: identical deduped
sets, identical dense IDs, identical skolem keys. The governing principle
(``CONFORMANCE_SPEC.md`` §5.5 = RFC §5.7) is that *every emitted set, key, and
dense ID is a pure function of a defined total order over tuples* — **no
observable output may depend on ``set``/``dict`` iteration order or on a
language-native ``hash()`` value** (Python ``set``/``dict`` order and ``hash()``
of ``str``/``bytes`` are ``PYTHONHASHSEED``-sensitive, hence non-portable).

Concretely, per ``CONFORMANCE_SPEC.md`` §5.5.1:

- **Total order** — lexicographic over tuple fields; integers by value; strings
  by Unicode code-point (UTF-8 byte) order. Python's built-in ``sorted`` on
  ``int``/``str``/``tuple`` gives exactly this (``str`` compares by code point,
  tuples lexicographically), and Timsort is stable. **Floats are forbidden in
  keys** (rule 1) — rejected at the boundary by :class:`FloatKeyError`.
- **distinct** — sort by the total order, drop *adjacent* duplicates; output
  order *is* sorted order, never first-seen / ``set`` order (rule 2).
- **rank** — dense IDs by position in the sorted distinct sequence. Python emits
  **0-based** (the canonical numbering; ``CONFORMANCE_SPEC.md`` §5.5.1 rule 3
  pins Julia 1-based, Rust/Python 0-based).
- **skolem** — a canonical *tuple*, never a hash (rule 4): sort components for a
  symmetric relation (undirected edge ``(min, max)``), preserve order for a
  directed one.
- **join / group-by** — hashing may *bucket* only; the result is emitted **sorted
  by the canonical key** (rule 5). The semiring ``⊕`` must be associative +
  commutative; for a floating-point ``⊕`` the per-bucket reduction is done
  sequentially in canonical value order to avoid last-ULP drift.

Implementation notes
====================

Built on **NumPy** (already a hard dependency) per RFC Appendix A.4: the
integer-keyed-tuple paths — the realistic mesh-topology workload (vertex / cell
IDs, scale 10⁴–10⁷) — use ``np.unique(axis=0)`` (lexicographically-sorted unique
rows), ``np.lexsort``, and ``np.searchsorted`` for the equi-join. Categorical
(string / bool) keys take a pure-Python total-order path (NumPy would coerce a
mixed-dtype tuple); both paths are a pure function of the §5.5.1 total order and
are asserted byte-identical to the cross-binding golden in
``tests/conformance/determinism/``. ``pandas`` (dtype coercion, shifting sort
defaults) and bare ``set``/``hash()`` (``PYTHONHASHSEED``-sensitive) are
deliberately rejected (RFC Appendix A.4); DuckDB stays a throwaway *oracle* used
only while authoring the conformance golden.

Canonical serialization reuses the package's existing canonical-JSON discipline
(``canonicalize.format_canonical_float`` for floats; ``json.dumps(...,
ensure_ascii=False)`` for strings) so the bytes match ``canonicalize.jl`` /
``canonicalize.py``.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from typing import Any, Callable

import numpy as np

from .canonicalize import format_canonical_float
from .errors import EarthSciAstError

__all__ = [
    "FloatKeyError",
    "skolem",
    "skolem_edge",
    "distinct",
    "rank",
    "Ranking",
    "equijoin",
    "group_aggregate",
    "canonical_index_set_json",
    "serialize_canonical",
]


# ── Rule 1: floats are forbidden in keys ────────────────────────────────────
# Native float equality/order is not a portable basis for an index set (a raw
# float may carry -0.0 / NaN, and its repr is platform-dependent). Reject at the
# boundary so misuse fails loudly at build time rather than silently emitting a
# non-deterministic / non-conformant set. ``bool`` is intentionally allowed
# (``bool`` is an ``int`` subclass — categorical 0/1 keys); integers are exact
# and orderable, also allowed.


class FloatKeyError(EarthSciAstError):
    """Raised when a relational key contains a floating-point component.

    Violates ``CONFORMANCE_SPEC.md`` §5.5.1 rule 1 ("floats are forbidden in
    keys"). Normalise the value to an integer / categorical ID before the
    build-time relational pre-pass.
    """


def _has_float(value: Any) -> bool:
    if isinstance(value, tuple):
        return any(_has_float(component) for component in value)
    # ``np.floating`` covers np.float32/64; Python ``float`` covers the rest.
    # ``bool``/``int``/``np.integer`` are exact and explicitly allowed.
    return isinstance(value, (float, np.floating))


def _assert_key(key: Any) -> Any:
    if _has_float(key):
        raise FloatKeyError(
            f"float in relational key {key!r}; keys must be integer / "
            "categorical IDs (CONFORMANCE_SPEC.md §5.5.1 rule 1). Normalise to "
            "an ID before the build-time relational pre-pass."
        )
    return key


def _as_key(row: Any) -> Any:
    """Normalise an input row to a hashable, order-comparable key: a JSON array
    (``list``) becomes a ``tuple``; scalars pass through. Float components are
    rejected (rule 1)."""
    if isinstance(row, list):
        row = tuple(row)
    return _assert_key(row)


def _is_int_scalar(value: Any) -> bool:
    # ``bool`` is an ``int`` subclass but routes through the categorical path so
    # NumPy never coerces a True/False key into 1/0 silently.
    return isinstance(value, (int, np.integer)) and not isinstance(value, bool)


# ── Primitive 3: skolem (canonical-tuple content-addressed key) ─────────────


def skolem_edge(a: Any, b: Any) -> tuple[Any, Any]:
    """Canonical key for an **undirected** pair (a symmetric relation):
    ``(min(a, b), max(a, b))``.

    The deterministic, content-addressed identity of a mesh edge (RFC §5.5
    generalises ESI ``pack``). It is **not** a hash (rule 4) — the tuple itself
    is the key, so the dense ID later assigned by :func:`rank` is reproducible
    across bindings. ``a`` and ``b`` must be order-comparable and non-float.
    """
    _assert_key((a, b))
    return (a, b) if a <= b else (b, a)


def skolem(components: Sequence[Any], *, symmetric: bool = False) -> tuple[Any, ...]:
    """Canonical-tuple Skolem key (rule 4).

    For a ``symmetric`` relation the components are sorted (generalising
    :func:`skolem_edge` to arity > 2); for a directed relation the order is
    preserved, so ``(1, 2)`` and ``(2, 1)`` stay distinct. Never a ``hash()`` —
    the tuple *is* the content-addressed key. The dense ID then comes from
    :func:`rank`.
    """
    key = tuple(components)
    _assert_key(key)
    if not symmetric:
        return key
    return tuple(sorted(key))


# ── Primitive 1: distinct (sort + drop adjacent duplicates) ─────────────────


def distinct(rows: Iterable[Any]) -> list[Any]:
    """Set semantics over ``rows``: sort by the §5.5.1 total order, then drop
    **adjacent** duplicates (rule 2).

    The returned order **is** the sorted order — never first-seen / ``set``
    iteration order. A pure function of the input multiset, so duplicate,
    reversed, and permuted inputs all collapse to the identical output.

    ``rows`` is any iterable of order-comparable keys: integer / categorical
    scalars, or tuples thereof (a ``list`` row is normalised to a ``tuple``).
    Floats in keys raise :class:`FloatKeyError` (rule 1). Mirrors the DuckDB
    oracle ``SELECT DISTINCT … ORDER BY …``.
    """
    items = [_as_key(row) for row in rows]
    if not items:
        return []

    numpy_result = _distinct_numpy_int(items)
    if numpy_result is not None:
        return numpy_result

    # General path: Python's total order (== §5.5.1 for int / str / tuple) then
    # adjacent dedup. Equality (``!=``), not the hash, decides duplicates, so the
    # result depends only on the values, never on ``set`` iteration order.
    ordered = sorted(items)
    out: list[Any] = []
    for item in ordered:
        if not out or out[-1] != item:
            out.append(item)
    return out


def _distinct_numpy_int(items: list[Any]) -> list[Any] | None:
    """NumPy fast path for the integer mesh-topology workload (RFC Appendix
    A.4). Returns ``None`` when the rows are not homogeneous integer scalars /
    equal-arity integer tuples, so the caller falls back to the general path.

    ``np.unique`` (1-D) and ``np.unique(axis=0)`` (rows) both return
    lexicographically-sorted unique values, which is exactly rule 2's sorted
    set semantics for integers."""
    if all(_is_int_scalar(x) for x in items):
        arr = np.asarray(items, dtype=np.int64)
        return [int(x) for x in np.unique(arr)]

    if all(isinstance(x, tuple) for x in items):
        arities = {len(x) for x in items}
        if (
            len(arities) == 1
            and next(iter(arities)) > 0
            and all(_is_int_scalar(component) for x in items for component in x)
        ):
            matrix = np.asarray([list(x) for x in items], dtype=np.int64)
            # np.unique(axis=0) returns lexicographically-sorted unique rows.
            unique_rows = np.unique(matrix, axis=0)
            return [tuple(int(c) for c in row) for row in unique_rows]

    return None


# ── Primitive 4: rank (dense integer renumbering) ───────────────────────────


@dataclass
class Ranking:
    """Result of :func:`rank`.

    - ``order`` — the distinct tuples in §5.5.1 total order.
    - ``ids``   — ``ids[t]`` is the dense integer assigned to tuple ``t``.
    - ``base``  — the emission base. Python emits **0-based** (the canonical
      numbering; ``CONFORMANCE_SPEC.md`` §5.5.1 rule 3). The conformance adapter
      declares this base and the harness normalises via
      ``canonical = reported − base``.
    """

    order: list[Any]
    ids: dict[Any, int]
    base: int

    def __getitem__(self, key: Any) -> int:
        return self.ids[key]


def rank(rows: Iterable[Any], *, base: int = 0) -> Ranking:
    """Dense integer renumbering (rule 3): assign IDs by position in the sorted
    :func:`distinct` sequence.

    ``base`` is the emission base — Python's native **0-based** is the default
    (the canonical numbering the conformance suite asserts on); pass ``base=1``
    for a 1-based numbering. Equivalent to SQL ``dense_rank() OVER (ORDER BY …)``
    over the deduplicated rows.
    """
    order = distinct(rows)
    ids = {tuple_key: index + base for index, tuple_key in enumerate(order)}
    return Ranking(order=order, ids=ids, base=base)


# ── Primitive 2: equijoin (value-equality equi-join) ────────────────────────


def _identity(value: Any) -> Any:
    return value


def equijoin(
    left: Iterable[Any],
    right: Iterable[Any],
    *,
    on_left: Callable[[Any], Any] = _identity,
    on_right: Callable[[Any], Any] = _identity,
) -> list[tuple[Any, Any]]:
    """Value-equality equi-join (rule 5): emit every ``(l, r)`` pair where
    ``on_left(l) == on_right(r)``.

    Hashing / ``searchsorted`` is used **only** to match keys; the result is
    emitted **sorted by the canonical key** ``(on_left(l), l, r)``, so the output
    is independent of bucket iteration order *and* of input order. This is the
    connectivity-inversion primitive — join an edge→cell table against a cell
    table on the shared ID to recover the *edges of cell i*. Join keys must be
    non-float (rule 1).
    """
    left_rows = list(left)
    right_rows = list(right)
    left_keys = [_assert_key(on_left(left_row)) for left_row in left_rows]
    right_keys = [_assert_key(on_right(r)) for r in right_rows]

    out: list[tuple[Any, Any]] = []
    if (
        left_rows
        and right_rows
        and all(_is_int_scalar(k) for k in left_keys)
        and all(_is_int_scalar(k) for k in right_keys)
    ):
        # NumPy ``searchsorted``-based join for integer keys (RFC Appendix A.4).
        keys = np.asarray(right_keys, dtype=np.int64)
        order = np.lexsort((keys,))  # stable ascending sort of the right keys
        keys_sorted = keys[order]
        for left_row, k in zip(left_rows, left_keys):
            lo = int(np.searchsorted(keys_sorted, k, side="left"))
            hi = int(np.searchsorted(keys_sorted, k, side="right"))
            for pos in range(lo, hi):
                out.append((left_row, right_rows[int(order[pos])]))
    else:
        # General path: bucket the right side by key (hash only to bucket — the
        # output is fully re-sorted below, so bucket order is never observed).
        buckets: dict[Any, list[Any]] = {}
        for r, k in zip(right_rows, right_keys):
            buckets.setdefault(k, []).append(r)
        for left_row, k in zip(left_rows, left_keys):
            for r in buckets.get(k, ()):
                out.append((left_row, r))

    # Canonical key first so the order is well defined even when ``on_left`` is a
    # projection rather than the identity.
    out.sort(key=lambda pair: (on_left(pair[0]), pair[0], pair[1]))
    return out


# ── Primitive 5: group-by + semiring aggregate ──────────────────────────────


def group_aggregate(
    rows: Iterable[Any],
    *,
    key: Callable[[Any], Any],
    value: Callable[[Any], Any],
    op: Callable[[Any, Any], Any],
) -> list[tuple[Any, Any]]:
    """Group-by + semiring aggregate (rule 5).

    Bucket ``rows`` by ``key(row)`` (hashing only to bucket), combine the
    ``value(row)``s within each group with the semiring ``op`` (``⊕``), and emit
    ``(key, aggregate)`` pairs **sorted by the canonical key**.

    ``op`` MUST be associative + commutative (every registry ``⊕`` — ``+``,
    ``*``, ``min``, ``max``, ``&``, ``|``, count — is) so the result is
    independent of input / bucket order. For a **floating-point** ``op`` the
    per-bucket reduction is done **sequentially in canonical (sorted) value
    order** (rule 5) so the last-ULP result is reproducible; the exact / integer
    path uses the same canonical order (immaterial there, but keeps one code
    path). Group keys must be non-float (rule 1); values may be floats. Mirrors
    the DuckDB oracle ``SELECT key, ⊕(value) … GROUP BY key ORDER BY key``.
    """
    buckets: dict[Any, list[Any]] = {}
    for row in rows:
        k = _assert_key(key(row))
        buckets.setdefault(k, []).append(value(row))

    out: list[tuple[Any, Any]] = []
    for k in sorted(buckets):
        values = sorted(buckets[k])  # canonical value order ⇒ reproducible float ⊕
        acc = values[0]
        for v in values[1:]:
            acc = op(acc, v)
        out.append((k, acc))
    return out


# ── Canonical serialization (CONFORMANCE_SPEC.md §5.5.3) ─────────────────────


def serialize_canonical(rows: Sequence[Any]) -> str:
    """Canonical byte form of an **already-ordered** index set
    (``CONFORMANCE_SPEC.md`` §5.5.3): each row serialised as a JSON array (or a
    bare scalar), as **compact JSON** (``,`` / ``:`` separators, no spaces,
    UTF-8, no ``\\uXXXX`` escaping).

    Use :func:`canonical_index_set_json` for raw (unsorted) input — it runs
    :func:`distinct` first. This helper is for output already in §5.5.1 order
    (e.g. the pairs from :func:`group_aggregate`)."""
    return "[" + ",".join(_emit_token(row) for row in rows) + "]"


def canonical_index_set_json(rows: Iterable[Any]) -> str:
    """Canonical byte form of an index set (``CONFORMANCE_SPEC.md`` §5.5.3): the
    :func:`distinct` rows, each tuple serialised as a JSON array, in §5.5.1
    sorted order, as compact UTF-8 JSON.

    Two conforming bindings MUST produce byte-for-byte identical output for the
    same input multiset. This is the artifact the adversarial conformance
    harness (§5.5.4) compares byte-for-byte across duplicate / reversed /
    permuted inputs.
    """
    return serialize_canonical(distinct(rows))


def _emit_token(value: Any) -> str:
    # ``bool`` first: it is an ``int`` subclass, and JSON spells it true/false.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, np.integer)):
        return str(int(value))  # bare digits
    if isinstance(value, str):
        # JSON-escaped (matches canonicalize._json_string / canonicalize.jl).
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, tuple):
        return "[" + ",".join(_emit_token(component) for component in value) + "]"
    # Floats are forbidden in keys, but a group aggregate *value* may be a float;
    # reuse the package's canonical float formatter so it round-trips byte-identically.
    if isinstance(value, (float, np.floating)):
        return format_canonical_float(float(value))
    raise TypeError(f"cannot serialize relational token of type {type(value).__name__}")
