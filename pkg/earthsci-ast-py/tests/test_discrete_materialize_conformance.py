"""Cross-language conformance: DISCRETE-CADENCE MATERIALIZATION — the middle
cadence phase (``const ⌷ discrete ⌷ continuous``; CONFORMANCE_SPEC.md §5.13).

Shared fixture + analytic golden live under
``tests/conformance/discrete_materialize/`` (repo root); the Julia runner
(``discrete_materialize_conformance_test.jl``) and the Rust runner
(``discrete_materialize_conformance.rs``) reproduce the same golden.

Model ``M`` mixes a CONST weight matrix ``W`` (an in-file ``const`` observed) with
a DISCRETE forcing field ``src`` (a bare, undeclared forcing name resolved through
the array evaluator's ``input_arrays``) inside a conservative-regrid-shaped
CONTRACTION ``g[j] = sum_i W[i,j]*src[i]`` — state-free but forcing-tainted, so it
changes only when ``src`` is refreshed at a cadence boundary. A sibling
``k[j] = sum_i W[i,j]*offset`` reads only const/parameter data, so it is
CONST-cadence and refresh-invariant. The per-cell ODE ``D(c[j]) = g[j] + k[j]``
couples both into the continuous state.

Python has no separate discrete-cache pass (that is the Julia ``DiscreteMaterializer``
cut): it re-materializes the state-free ``g`` at each segment's RHS build, with the
forcing ``src`` frozen for the segment, so the numeric result matches the Julia
materialized path. This suite is the user-owned segmented driver — it writes
``src`` from the golden's ``forcing.by_anchor`` snapshots at the golden's
``refresh_times`` (via the array pathway's ``loader_arrays`` injection seam, the
Python analogue of Rust's forcing buffer), threads state across segments, and
checks the trajectory against the analytic golden within the manifest's
trajectory band. A stale (un-refreshed) ``src`` would give a visibly wrong slope,
so the refresh is load-bearing."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load
from earthsci_ast.simulation_array import _simulate_with_numpy

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "discrete_materialize"
_FIXTURE = _ROOT / "fixtures" / "discrete_materialize_contraction.esm"
_GOLDEN = _ROOT / "golden" / "discrete_materialize_contraction.json"

_CELLS = ("M.c[1]", "M.c[2]", "M.c[3]")
_SRC_KEY = "M.src"  # forcing-buffer key the RHS looks up (namespaced post-flatten)


def _golden() -> dict:
    return json.loads(_GOLDEN.read_text())


def _snapshot_at(golden: dict, anchor: float) -> np.ndarray:
    """The ``src`` snapshot to write at a cadence anchor, from ``forcing.by_anchor``."""
    by_anchor = golden["forcing"][_SRC_KEY]["by_anchor"]
    key = f"{anchor:.1f}"
    if key not in by_anchor:
        key = str(anchor)
    return np.asarray(by_anchor[key], dtype=float)


def test_flatten_keeps_contraction_observeds_and_single_state() -> None:
    flat = flatten(load(str(_FIXTURE)))
    for obs in ("M.W", "M.g", "M.k"):
        assert obs in flat.observed_variables, (
            f"{obs} must be an observed; observeds: {list(flat.observed_variables)}"
        )
    # `c` is the only integrated state; W/g/k are observeds, not slots.
    assert "M.c" in flat.state_variables
    assert "M.g" not in flat.state_variables


def test_discrete_materialize_trajectory_matches_golden() -> None:
    golden = _golden()
    flat = flatten(load(str(_FIXTURE)))

    t0, t1 = (float(x) for x in golden["cadence"]["tspan"])
    refresh_times = [float(t) for t in golden["cadence"]["refresh_times"]]
    endpoints = [t0] + [t for t in refresh_times if t0 < t < t1] + [t1]

    # Segment-by-segment: refresh `src` at each boundary (forcing frozen for the
    # segment), integrate, thread the final state into the next.
    ics = {cell: 0.0 for cell in _CELLS}
    states = {t0: dict(ics)}
    for seg_start, seg_end in zip(endpoints[:-1], endpoints[1:]):
        snap = _snapshot_at(golden, seg_start)
        res = _simulate_with_numpy(
            flat, (seg_start, seg_end), {}, ics, "LSODA",
            rtol=1e-10, atol=1e-12, loader_arrays={_SRC_KEY: snap},
        )
        assert res.success, res.message
        idx = {name: k for k, name in enumerate(res.vars)}
        # Single-model states surface as bare slot names (`c[1]`); accept either.
        ics = {
            cell: float(res.y[idx[cell if cell in idx else cell.split(".")[-1]]][-1])
            for cell in _CELLS
        }
        states[seg_end] = dict(ics)

    traj = golden["trajectory"]
    for tk, expected in traj.items():
        if tk == "comment":
            continue
        t = float(tk)
        got = states[t]
        for cell, want in expected.items():
            assert got[cell] == pytest.approx(want, rel=1e-4, abs=1e-6)
