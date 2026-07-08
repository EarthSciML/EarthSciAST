"""Cross-language REFRESH-PATH conformance (CONFORMANCE_SPEC.md §5.10).

Shared fixture + analytic golden live under ``tests/conformance/refresh/`` (repo
root); the Julia (``refresh_conformance_test.jl``) and Rust
(``refresh_conformance.rs``) runners reproduce the same golden.

A discretized, COUPLED, non-PDE model reads forcing from data loaders at a
discrete cadence and REGRIDS it from the coarse 6-cell native grid onto the
3-cell sim grid — IN-MODEL, as a const-``W`` coupling contraction
(``F_tgt[j] = sum_i W[i,j]*F_src[i]``), NOT through a regrid seam (the obsolete
regrid seam was removed in v0.8.0). ``F_src`` is DISCRETE (loader ``emis`` has a
``temporal`` block) so ``F_tgt`` refreshes at each cadence anchor; ``scale_src``
is CONST (loader ``factors``, no temporal) so ``scale_tgt`` is build-once.
``D(c[j]) = scale_tgt[j]*F_tgt[j]``, ``D(d[j]) = c[j]``.

TWO-VIEW contract: the loader-fed ``F_src``/``scale_src`` are declared
``discrete``+``data_ingest`` for the cadence classifier, but ``flatten`` drops
those declarations (the simulate view is free) and leaves bare ``M.F_src``/
``M.scale_src`` in the RHS, resolved through the array pathway's ``loader_arrays``
seam. This adapter is the user-owned segmented driver: it writes the native
6-cell forcings from ``golden.native_fields`` at each ``refresh_times`` anchor,
threads state across segments, and asserts two bands — the in-model regridded
fields (``F_tgt``/``scale_tgt``) and the integrated trajectory."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.flatten import flatten
from earthsci_ast.parse import load
from earthsci_ast.simulation_array import BuildInspection, _simulate_with_numpy

_ROOT = Path(__file__).resolve().parents[3] / "tests" / "conformance" / "refresh"
_FIXTURE = _ROOT / "fixtures" / "coupled_refresh_regrid.esm"
_GOLDEN = _ROOT / "golden" / "coupled_refresh_regrid.json"

_STATES = tuple(f"M.{s}[{j}]" for s in ("c", "d") for j in (1, 2, 3))
_FKEY, _SKEY = "M.F_src", "M.scale_src"  # forcing-buffer keys (namespaced post-flatten)

_FIELD_RTOL, _FIELD_ATOL = 1e-9, 1e-11
_TRAJ_RTOL, _TRAJ_ATOL = 1e-4, 1e-6


def _golden() -> dict:
    return json.loads(_GOLDEN.read_text())


def _anchor_key(by_anchor: dict, anchor: float) -> str:
    k = f"{anchor:.1f}"
    return k if k in by_anchor else str(anchor)


def test_flatten_strips_discrete_and_keeps_regrid_observeds() -> None:
    flat = flatten(load(str(_FIXTURE)))
    # `flatten` drops the loader-fed `discrete` decls (the simulate-view strip is
    # free); the in-model regrid observeds and coupled states survive.
    for obs in ("M.W", "M.F_tgt", "M.scale_tgt"):
        assert obs in flat.observed_variables, list(flat.observed_variables)
    for st in ("M.c", "M.d"):
        assert st in flat.state_variables, list(flat.state_variables)
    assert "M.F_src" not in flat.state_variables
    assert "M.F_src" not in flat.observed_variables


def test_refresh_regrid_band_matches_golden() -> None:
    """The in-model regrid reproduces the golden regridded fields (regrid band)."""
    golden = _golden()
    flat = flatten(load(str(_FIXTURE)))
    scale_native = np.asarray(golden["native_fields"][_SKEY]["values"], dtype=float)
    fsrc_by = golden["native_fields"][_FKEY]["by_anchor"]
    ftgt_by = golden["regridded_fields"]["M.F_tgt"]["by_anchor"]
    scale_tgt_want = golden["regridded_fields"]["M.scale_tgt"]

    anchors = sorted(float(k) for k in fsrc_by)
    for anchor in anchors:
        insp = BuildInspection()
        fsrc = np.asarray(fsrc_by[_anchor_key(fsrc_by, anchor)], dtype=float)
        res = _simulate_with_numpy(
            flat, (anchor, anchor + 1.0), {}, {}, "LSODA", rtol=1e-10, atol=1e-12,
            loader_arrays={_SKEY: scale_native, _FKEY: fsrc}, inspect=insp,
        )
        assert res.success, res.message
        ftgt_want = ftgt_by[_anchor_key(ftgt_by, anchor)]
        got_ftgt = np.asarray(insp.setup_arrays["M.F_tgt"]).ravel()
        assert np.allclose(got_ftgt, ftgt_want, rtol=_FIELD_RTOL, atol=_FIELD_ATOL), (
            f"F_tgt @ {anchor}: got {got_ftgt}, want {ftgt_want}"
        )
        got_scale = np.asarray(insp.setup_arrays["M.scale_tgt"]).ravel()
        assert np.allclose(got_scale, scale_tgt_want, rtol=_FIELD_RTOL, atol=_FIELD_ATOL)


def test_refresh_trajectory_band_matches_golden() -> None:
    """Segmented refresh solve reproduces the golden trajectory (trajectory band)."""
    golden = _golden()
    flat = flatten(load(str(_FIXTURE)))
    scale_native = np.asarray(golden["native_fields"][_SKEY]["values"], dtype=float)
    fsrc_by = golden["native_fields"][_FKEY]["by_anchor"]

    t0, t1 = (float(x) for x in golden["cadence"]["tspan"])
    refresh_times = [float(t) for t in golden["cadence"]["refresh_times"]]
    endpoints = [t0] + [t for t in refresh_times if t0 < t < t1] + [t1]

    ics = {s: 0.0 for s in _STATES}
    states = {t0: dict(ics)}
    for a, b in zip(endpoints[:-1], endpoints[1:]):
        fsrc = np.asarray(fsrc_by[_anchor_key(fsrc_by, a)], dtype=float)
        res = _simulate_with_numpy(
            flat, (a, b), {}, ics, "LSODA", rtol=1e-10, atol=1e-12,
            loader_arrays={_SKEY: scale_native, _FKEY: fsrc},
        )
        assert res.success, res.message
        idx = {n: k for k, n in enumerate(res.vars)}
        ics = {
            s: float(res.y[idx[s if s in idx else s.split(".")[-1]]][-1]) for s in _STATES
        }
        states[b] = dict(ics)

    traj = golden["trajectory"]
    for tk, expected in traj.items():
        if tk == "comment":
            continue
        got = states[float(tk)]
        for st, want in expected.items():
            assert got[st] == pytest.approx(want, rel=_TRAJ_RTOL, abs=_TRAJ_ATOL)
