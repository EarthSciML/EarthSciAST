"""Build and evaluation cost of the flat-entry native tiers grow LINEARLY in N.

Python is exempt from the cross-binding scaling tier (tests/conformance/scaling),
so the two shapes issues #534 and #535 added to its native compiler carry their
own evidence here, in the manner of ``test_overlap_dense_scaling.py``:

* a RAGGED neighbour sum ``D(u[i]) = Σ_{k ∈ nbrs(i)} w[i,k] · u[cellsOnCell[i,k]]``
  over an unstructured mesh with 5..7 neighbours per cell (the ``ragged-csr``
  tier), and
* an OVERLAP-gated containment binning — a construction-time observed
  ``B[c] = Σ_p [inside(c, p)] · V[p]`` and a right-hand side that bins the
  state the same way (the ``overlap-driven`` tier, with the binned broad phase
  that builds its candidates).

Each is built at two sizes eight times apart. Linear work costs about 8x, and the
quadratic forms these tiers replace (a padded or masked dense box, a per-query
broad-phase loop) cost 64x; the bound sits between them, loose enough that a
contended CI machine does not trip it. Native is checked against the
interpreter bit for bit at the small size.
"""

from __future__ import annotations

import time

import numpy as np
import pytest

from earthsci_ast.problem import esm_problem

GROWTH = 8
RATIO_BOUND = 24.0


def _ix(f, *idx):
    return {"op": "index", "args": [f, *idx]}


def _op(o, *args):
    return {"op": o, "args": list(args)}


def _param(shape):
    return {"type": "parameter", "default": 0.0, "shape": list(shape)}


def _best(fn, repeats: int = 5) -> float:
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        fn()
        best = min(best, time.perf_counter() - t0)
    return best


def _check_linear(name: str, small: float, large: float) -> None:
    ratio = large / max(small, 1e-9)
    assert ratio < RATIO_BOUND, (
        f"{name} looks super-linear: {small:.4f}s -> {large:.4f}s, {ratio:.1f}x for a "
        f"{GROWTH}x increase in N"
    )


# --------------------------------------------------------------------------- #
# Ragged neighbour sum (#534)
# --------------------------------------------------------------------------- #


def _ragged_case(n: int):
    rng = np.random.default_rng(534)
    perm = rng.permutation(n)
    n_nbr = rng.integers(5, 8, n)
    nbr = np.zeros((n, 7))
    for k in range(7):
        nbr[:, k] = perm[(np.arange(n) + k + 1) % n] + 1
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": "ragged_scaling"},
        "index_sets": {
            "cells": {"kind": "interval", "size": n},
            "maxEdges": {"kind": "interval", "size": 7},
            "nbrs": {
                "kind": "ragged",
                "of": ["cells"],
                "offsets": "nEdgesOnCell",
                "values": "cellsOnCell",
            },
        },
        "models": {
            "Rag": {
                "variables": {
                    "nEdgesOnCell": _param(["cells"]),
                    "cellsOnCell": _param(["cells", "maxEdges"]),
                    "w": _param(["cells", "maxEdges"]),
                    "u": {"type": "unknown", "default": 1.0, "shape": ["cells"]},
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                        "rhs": {
                            "op": "faq",
                            "semiring": "sum_product",
                            "output_idx": ["i"],
                            "ranges": {
                                "i": {"from": "cells"},
                                "k": {"from": "nbrs", "of": ["i"]},
                            },
                            "args": ["w", "u", "cellsOnCell"],
                            "expr": _op(
                                "*",
                                _ix("w", "i", "k"),
                                _ix("u", _ix("cellsOnCell", "i", "k")),
                            ),
                        },
                    }
                ],
            }
        },
    }
    ca = {
        "Rag.nEdgesOnCell": n_nbr.astype(float),
        "Rag.cellsOnCell": nbr,
        "Rag.w": rng.standard_normal((n, 7)),
    }
    return doc, ca


def _build_ragged(n: int, compiler: str = "native"):
    doc, ca = _ragged_case(n)
    return esm_problem(doc, (0.0, 1.0), const_arrays=ca, model_name="Rag", compiler=compiler)


def _rhs_call(prob):
    b = prob.build
    y = np.sqrt(np.arange(1.0, b.total_size + 1.0))
    return lambda: b.rhs_function(0.0, y)


def test_ragged_native_rhs_is_the_interpreters_bit_for_bit():
    nat = _build_ragged(300)
    ref = _build_ragged(300, compiler="interpreter")
    assert "ragged-csr" in nat.compiler_report.tiers()
    a = np.asarray(_rhs_call(nat)(), dtype=float)
    b = np.asarray(_rhs_call(ref)(), dtype=float)
    assert np.array_equal(a.view(np.uint64), b.view(np.uint64))


def test_ragged_build_and_evaluation_grow_linearly():
    small_n, large_n = 10_000, 10_000 * GROWTH
    _build_ragged(200)  # warm imports and caches
    build_small = _best(lambda: _build_ragged(small_n), repeats=3)
    build_large = _best(lambda: _build_ragged(large_n), repeats=3)
    _check_linear("ragged build", build_small, build_large)
    eval_small = _best(_rhs_call(_build_ragged(small_n)))
    eval_large = _best(_rhs_call(_build_ragged(large_n)))
    _check_linear("ragged RHS evaluation", eval_small, eval_large)


# --------------------------------------------------------------------------- #
# Overlap-gated binning (#535)
# --------------------------------------------------------------------------- #


def _inside(c, p):
    return _op(
        "and",
        _op("<=", _ix("W", c), _ix("X", p)),
        _op("<", _ix("X", p), _ix("E", c)),
        _op("<=", _ix("S", c), _ix("Y", p)),
        _op("<", _ix("Y", p), _ix("N", c)),
    )


def _binning(weight):
    return {
        "op": "faq",
        "semiring": "sum_product",
        "output_idx": ["c"],
        "ranges": {"c": {"from": "cells"}, "p": {"from": "points"}},
        "join": [{"overlap": {"src_env": ["X", "Y"], "tgt_env": ["W", "S", "E", "N"], "eps": 0.0}}],
        "args": ["W", "S", "E", "N", "X", "Y", "V"],
        "expr": _op("*", _op("ifelse", _inside("c", "p"), 1.0, 0.0), weight),
    }


def _overlap_case(n_side: int):
    """``n_side x n_side`` unit cells and one point per cell, a quarter of
    them on a cell edge (so the broad phase admits several cells for it)."""
    rng = np.random.default_rng(535)
    n = n_side * n_side
    k = np.arange(n)
    a = (k // n_side).astype(float)
    b = (k % n_side).astype(float)
    x = a + rng.uniform(0.05, 0.95, n)
    y = b + rng.uniform(0.05, 0.95, n)
    edge = rng.random(n) < 0.25
    x[edge] = a[edge]
    doc = {
        "esm": "1.1.0",
        "metadata": {"name": "overlap_scaling"},
        "index_sets": {
            "points": {"kind": "interval", "size": n},
            "cells": {"kind": "interval", "size": n},
        },
        "models": {
            "Bin": {
                "variables": {
                    **{v: _param(["points"]) for v in ("X", "Y", "V")},
                    **{v: _param(["cells"]) for v in ("W", "S", "E", "N")},
                    "B": {"type": "unknown", "shape": ["cells"]},
                    "s": {"type": "unknown", "default": 0.0, "shape": ["cells"]},
                },
                "equations": [
                    {"lhs": "B", "rhs": _binning(_ix("V", "p"))},
                    {
                        "lhs": {"op": "D", "args": ["s"], "wrt": "t"},
                        "rhs": _op(
                            "+",
                            _binning(_op("*", _ix("V", "p"), _ix("s", "c"))),
                            "B",
                        ),
                    },
                ],
            }
        },
    }
    ca = {"Bin.X": x, "Bin.Y": y, "Bin.V": np.sqrt(np.arange(1.0, n + 1.0))}
    ca.update({"Bin.W": a, "Bin.S": b, "Bin.E": a + 1.0, "Bin.N": b + 1.0})
    return doc, ca


def _build_overlap(n_side: int, compiler: str = "native"):
    doc, ca = _overlap_case(n_side)
    return esm_problem(doc, (0.0, 1.0), const_arrays=ca, model_name="Bin", compiler=compiler)


def test_overlap_native_rhs_is_the_interpreters_bit_for_bit():
    nat = _build_overlap(15)
    ref = _build_overlap(15, compiler="interpreter")
    assert set(nat.compiler_report.tiers()) >= {"overlap-driven"}
    a = np.asarray(_rhs_call(nat)(), dtype=float)
    b = np.asarray(_rhs_call(ref)(), dtype=float)
    assert np.array_equal(a.view(np.uint64), b.view(np.uint64))
    assert np.count_nonzero(a) > 0


@pytest.mark.parametrize("phase", ["build", "evaluation"])
def test_overlap_build_and_evaluation_grow_linearly(phase):
    # Cell counts 100^2 and 283^2: a factor of ~8 in N.
    small_side, large_side = 100, 283
    _build_overlap(10)  # warm imports and caches
    if phase == "build":
        small = _best(lambda: _build_overlap(small_side), repeats=3)
        large = _best(lambda: _build_overlap(large_side), repeats=3)
    else:
        small = _best(_rhs_call(_build_overlap(small_side)))
        large = _best(_rhs_call(_build_overlap(large_side)))
    _check_linear(f"overlap {phase}", small, large)
