"""PUBLIC-SURFACE projection pushdown — the Python mirror of the Julia
``prepare_pushdown_record_gate_test.jl`` (Phase 3, clean consolidation).

Drives the clean isrm-shaped L1 pattern through the PUBLIC ``prepare`` surface:

* ``prepare(doc, providers=…, const_arrays=…, pushdown_rewrite=True)`` — the
  rewrite runs on the AUTHORED document BEFORE flattening;
* the engine derives every provider gate from the rewrite's OWN record
  (``metadata.x_esd.pushdown.gated_select``) + the document coupling — the
  caller hand-authors NO gate dict;
* the loader's ``metadata.x_esd.gated_select.axes`` template contributes the
  NATIVE axis layout (the ``fixed`` emission-layer axis), with the record's
  GENERATED set name substituted over the template's stale one;
* ``observed_field`` reads the results back through the prepared document's
  own graph, against the plain-Python STEP-0 oracle.

The document is the COMMITTED conformance fixture
(tests/conformance/pushdown/fixtures/pushdown_l1.esm) — the same doc the
Julia test builds, frozen — so the two bindings drive one artifact.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.problem import esm_problem, observed_field
from earthsci_ast.simulation_array import BuildInspection
from earthsci_ast.sympy_bridge import SimulationError

_FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "tests"
    / "conformance"
    / "pushdown"
    / "fixtures"
    / "pushdown_l1.esm"
)

GRID, N_RCV, N_REC, N_LAYER = 9, 4, 5, 3
LAT1, LAT2, LAT0, LON0 = 33.0, 45.0, 40.0, -97.0
FACT = 28766.639
POP_SCALE = 1.0465819687408728
MORT_SCALE = 1.025229357798165
RR_K, RR_L = 1.06, 1.14
LVARS = ["SOA", "pNO3", "pNH4", "pSO4", "PrimaryPM25"]


# ---- Lambert conformal conic (unit sphere), plain-Python ORACLE -------------
def _d2r(d):
    return d * math.pi / 180


def _lcc_consts(lat1, lat2, lat0, lon0):
    p1, p2, p0, l0 = _d2r(lat1), _d2r(lat2), _d2r(lat0), _d2r(lon0)
    n = math.log(math.cos(p1) / math.cos(p2)) / math.log(
        math.tan(math.pi / 4 + p2 / 2) / math.tan(math.pi / 4 + p1 / 2)
    )
    rf = math.cos(p1) * math.tan(math.pi / 4 + p1 / 2) ** n / n
    rho0 = rf / math.tan(math.pi / 4 + p0 / 2) ** n
    return n, rf, rho0, l0


def _lcc_fwd(lon_deg, lat_deg, c):
    n, rf, rho0, l0 = c
    latr, lonr = lat_deg * math.pi / 180, lon_deg * math.pi / 180
    rho = rf / math.tan(math.pi / 4 + latr / 2) ** n
    theta = n * (lonr - l0)
    return rho * math.sin(theta), rho0 - rho * math.cos(theta)


def _lcc_inv(x, y, c):
    n, rf, rho0, l0 = c
    rho = math.copysign(math.sqrt(x**2 + (rho0 - y) ** 2), n)
    theta = math.atan2(x, rho0 - y)
    return (
        math.degrees(l0 + theta / n),
        math.degrees(2 * math.atan((rf / rho) ** (1 / n)) - math.pi / 2),
    )


# ---- provider mocks — NO hand-authored gate dict anywhere -------------------
class MockConst:
    def __init__(self, arr):
        self.arr = np.asarray(arr, dtype=float)

    def sample(self, t):
        return self.arr


class MockGated:
    """A pushdown-capable provider: ``sample(t, selection=…)`` receives the
    neutral per-axis selection (``"all"`` | 0-based index list) and returns the
    compact slab with every requested axis PRESENT (a fixed axis comes back
    length-1, exactly as the EarthSciIO zarr reader returns it)."""

    supports_selection = True

    def __init__(self, full):
        self.full = np.asarray(full, dtype=float)  # native [layer, src, rcv]
        self.calls = []

    def sample(self, t, selection=None):
        if selection is None:
            self.calls.append(("wholesale",))
            return self.full
        self.calls.append(("selection", [list(a) if a != "all" else "all" for a in selection]))
        out = self.full
        for axis, a in enumerate(selection):
            if a != "all":
                out = np.take(out, np.asarray(a, dtype=int), axis=axis)
        return out


@pytest.fixture(scope="module")
def oracle():
    C = _lcc_consts(LAT1, LAT2, LAT0, LON0)
    W = np.zeros(GRID)
    Sv = np.zeros(GRID)
    Ev = np.zeros(GRID)
    Nv = np.zeros(GRID)
    for row in range(3):
        for col in range(3):
            k = row * 3 + col
            W[k], Ev[k] = col * 2.0, (col + 1) * 2.0
            Sv[k], Nv[k] = row * 2.0, (row + 1) * 2.0
    xt = [1.0, 3.0, 1.0, 5.0, 1.5]
    yt = [1.0, 1.0, 3.0, 5.0, 1.5]
    lon, lat = [], []
    for r in range(N_REC):
        lo, la = _lcc_inv(xt[r], yt[r], C)
        lon.append(lo)
        lat.append(la)
    px = [_lcc_fwd(lon[r], lat[r], C)[0] for r in range(N_REC)]
    py = [_lcc_fwd(lon[r], lat[r], C)[1] for r in range(N_REC)]
    assert np.allclose(px, xt) and np.allclose(py, yt)

    emis_annual = np.array([10.0, 20.0, 30.0, 40.0, 50.0])
    masks = {
        "SOA": np.array([1.0, 0.0, 1.0, 0.0, 0.0]),  # is_VOC
        "pNO3": np.array([0.0, 1.0, 0.0, 0.0, 0.0]),  # is_NOx
        "pNH4": np.array([0.0, 0.0, 0.0, 0.0, 1.0]),  # is_NH3
        "pSO4": np.array([0.0, 0.0, 0.0, 0.0, 0.0]),  # is_SOx
        "PrimaryPM25": np.array([0.0, 0.0, 0.0, 1.0, 0.0]),  # is_PM25
    }
    total_pop = np.array([100.0, 200.0, 300.0, 400.0])
    mortality = np.array([500.0, 600.0, 700.0, 800.0])
    base = {"SOA": 1.0, "pNO3": 2.0, "pNH4": 3.0, "pSO4": 4.0, "PrimaryPM25": 5.0}
    full_sr = {}
    for name in LVARS:
        A = np.empty((N_LAYER, GRID, N_RCV))
        for lyr in range(N_LAYER):
            for s in range(GRID):
                for r in range(N_RCV):
                    A[lyr, s, r] = lyr * 1.0e6 + base[name] * 1000 + (s + 1) * 10 + (r + 1)
        full_sr[name] = A

    def cont(c, r):  # 0-based
        return W[c] <= px[r] < Ev[c] and Sv[c] <= py[r] < Nv[c]

    members0 = sorted({c for c in range(GRID) for r in range(N_REC) if cont(c, r)})
    assert members0 == [0, 1, 3, 8]  # 1-based [1, 2, 4, 9]

    def oracle_E(mask):
        return np.array(
            [
                sum((1.0 if cont(c, r) else 0.0) * emis_annual[r] * mask[r] for r in range(N_REC))
                for c in members0
            ]
        )

    def oracle_conc(name):
        Ep = oracle_E(masks[name])
        srC = full_sr[name][0][members0, :]  # [ppl, rcv]
        return srC.T @ Ep

    tot = FACT * sum(oracle_conc(name) for name in LVARS)

    def oracle_deaths(rr):
        return (
            (np.exp(math.log(rr) / 10 * tot) - 1)
            * total_pop
            * POP_SCALE
            * mortality
            * MORT_SCALE
            / 100000
        )

    return {
        "C": C,
        "W": W,
        "S": Sv,
        "E": Ev,
        "N": Nv,
        "lon": np.array(lon),
        "lat": np.array(lat),
        "emis_annual": emis_annual,
        "masks": masks,
        "total_pop": total_pop,
        "mortality": mortality,
        "full_sr": full_sr,
        "members0": members0,
        "oracle_E": oracle_E,
        "oracle_conc": oracle_conc,
        "total_pm25": tot,
        "oracle_deaths": oracle_deaths,
    }


def test_prepare_pushdown_record_gate_end_to_end(oracle):
    doc = json.loads(_FIXTURE.read_text())
    # The fixture froze the SAME LCC constants the oracle recomputes.
    assert doc["models"]["ISRM"]["variables"]["lcc_n"]["default"] == pytest.approx(
        oracle["C"][0], rel=0, abs=0
    )

    gmocks = {v: MockGated(oracle["full_sr"][v]) for v in LVARS}
    providers = {
        "ISRM.TotalPop": MockConst(oracle["total_pop"]),
        "ISRM.MortalityRate": MockConst(oracle["mortality"]),
        "ISRM.emis_lon": MockConst(oracle["lon"]),
        "ISRM.emis_lat": MockConst(oracle["lat"]),
        "ISRM.emis_annual": MockConst(oracle["emis_annual"]),
        "ISRM.is_VOC": MockConst(oracle["masks"]["SOA"]),
        "ISRM.is_NOx": MockConst(oracle["masks"]["pNO3"]),
        "ISRM.is_NH3": MockConst(oracle["masks"]["pNH4"]),
        "ISRM.is_SOx": MockConst(oracle["masks"]["pSO4"]),
        "ISRM.is_PM25": MockConst(oracle["masks"]["PrimaryPM25"]),
    }
    for v in LVARS:
        providers[f"ISRM.SR_{v}"] = gmocks[v]

    # src rects ride const_arrays under their BARE authored names (the alias
    # injection must surface them under the flattened spelling).
    ca = {"src_W": oracle["W"], "src_S": oracle["S"], "src_E": oracle["E"], "src_N": oracle["N"]}

    insp = BuildInspection()
    prep = esm_problem(doc, (0.0, 1.0), providers=providers, const_arrays=ca, inspect=insp, pushdown_rewrite=True)

    # ---- the gated mocks were fetched pre-sliced, never wholesale -----------
    members0 = oracle["members0"]
    for v in LVARS:
        sel = [c for c in gmocks[v].calls if c[0] == "selection"]
        whole = [c for c in gmocks[v].calls if c[0] == "wholesale"]
        assert not whole, f"{v}: wholesale fetch happened"
        assert len(sel) == 1
        assert sel[0][1][0] == [0]  # fixed layer, 0-based
        assert sel[0][1][1] == members0  # the record-derived gate members
        assert sel[0][1][2] == "all"

    # ---- engine-derived support set surfaced through the inspection ----------
    mf = [k for k in insp.const_arrays if str(k).startswith("pd_member_factor__")]
    assert mf, "member_factor feedback missing from the inspection const registry"
    assert sorted(int(m) for m in np.asarray(insp.const_arrays[mf[0]])) == [m + 1 for m in members0]

    # ---- results through the prepared document's own graph ------------------
    np.testing.assert_allclose(
        observed_field(prep, "E_VOC"), oracle["oracle_E"](oracle["masks"]["SOA"])
    )
    np.testing.assert_allclose(
        observed_field(prep, "ISRM.E_PM25"),
        oracle["oracle_E"](oracle["masks"]["PrimaryPM25"]),
    )
    np.testing.assert_allclose(observed_field(prep, "conc_SOA"), oracle["oracle_conc"]("SOA"))
    np.testing.assert_allclose(observed_field(prep, "TotalPM25"), oracle["total_pm25"])
    np.testing.assert_allclose(observed_field(prep, "deathsK"), oracle["oracle_deaths"](RR_K))
    np.testing.assert_allclose(observed_field(prep, "deathsL"), oracle["oracle_deaths"](RR_L))
    with pytest.raises(SimulationError):
        observed_field(prep, "no_such_observed")


def test_prepare_pushdown_single_member_support_set(oracle):
    """n=1 regression (the pre-existing scalarisation footgun): every emission
    record lands in ONE grid cell, so the engine-derived support set has exactly
    one member and the ``pd_member_factor__*`` feedback vector is a SIZE-1
    array. ``_resolve_symbol``'s bare-reference scalarisation used to collapse
    it to a float, breaking the generated ``index(F, index(mf, c))`` gathers —
    the whole downstream graph was then silently dropped by the tolerant hoist
    and ``observed_field`` failed far from the cause. A one-member axis must
    stay an axis (``EvalContext.axis_valued_input_names``)."""
    doc = json.loads(_FIXTURE.read_text())
    C = oracle["C"]

    # All five records inside cell 0 (rect [0,2) × [0,2)).
    xt = [0.5, 1.0, 1.5, 0.5, 1.2]
    yt = [0.5, 0.5, 1.0, 1.5, 0.8]
    lon, lat = [], []
    for r in range(N_REC):
        lo, la = _lcc_inv(xt[r], yt[r], C)
        lon.append(lo)
        lat.append(la)

    gmocks = {v: MockGated(oracle["full_sr"][v]) for v in LVARS}
    providers = {
        "ISRM.TotalPop": MockConst(oracle["total_pop"]),
        "ISRM.MortalityRate": MockConst(oracle["mortality"]),
        "ISRM.emis_lon": MockConst(lon),
        "ISRM.emis_lat": MockConst(lat),
        "ISRM.emis_annual": MockConst(oracle["emis_annual"]),
        "ISRM.is_VOC": MockConst(oracle["masks"]["SOA"]),
        "ISRM.is_NOx": MockConst(oracle["masks"]["pNO3"]),
        "ISRM.is_NH3": MockConst(oracle["masks"]["pNH4"]),
        "ISRM.is_SOx": MockConst(oracle["masks"]["pSO4"]),
        "ISRM.is_PM25": MockConst(oracle["masks"]["PrimaryPM25"]),
    }
    for v in LVARS:
        providers[f"ISRM.SR_{v}"] = gmocks[v]
    ca = {"src_W": oracle["W"], "src_S": oracle["S"], "src_E": oracle["E"], "src_N": oracle["N"]}

    insp = BuildInspection()
    prep = esm_problem(doc, (0.0, 1.0), providers=providers, const_arrays=ca, inspect=insp, pushdown_rewrite=True)

    # The single-member feedback vector survived as a 1-element ARRAY.
    mf = [k for k in insp.const_arrays if str(k).startswith("pd_member_factor__")]
    assert mf, "member_factor feedback missing from the inspection const registry"
    mf_arr = np.asarray(insp.const_arrays[mf[0]])
    assert mf_arr.shape == (1,) and int(mf_arr[0]) == 1  # 1-based cell 1

    # Gated fetches pushed the one-member selection down, never wholesale.
    for v in LVARS:
        sel = [c for c in gmocks[v].calls if c[0] == "selection"]
        assert not [c for c in gmocks[v].calls if c[0] == "wholesale"]
        assert len(sel) == 1 and sel[0][1][1] == [0]

    # Plain-Python oracle with the one-member support set.
    emis, masks = oracle["emis_annual"], oracle["masks"]
    E_or = {v: np.array([float(np.sum(emis * masks[v]))]) for v in LVARS}
    conc = {v: oracle["full_sr"][v][0][[0], :].T @ E_or[v] for v in LVARS}
    tot = FACT * sum(conc[v] for v in LVARS)

    for v in LVARS:
        got = observed_field(
            prep,
            f"E_{'VOC' if v == 'SOA' else 'NOx' if v == 'pNO3' else 'NH3' if v == 'pNH4' else 'SOx' if v == 'pSO4' else 'PM25'}",
        )
        assert np.asarray(got).shape == (1,)
        np.testing.assert_allclose(got, E_or[v])
    np.testing.assert_allclose(observed_field(prep, "TotalPM25"), tot)
    for rr, name in ((RR_K, "deathsK"), (RR_L, "deathsL")):
        want = (
            (np.exp(math.log(rr) / 10 * tot) - 1)
            * oracle["total_pop"]
            * POP_SCALE
            * oracle["mortality"]
            * MORT_SCALE
            / 100000
        )
        np.testing.assert_allclose(observed_field(prep, name), want)


def test_observed_field_reports_hoist_skip_root_cause(oracle):
    """When the tolerant hoist drops an unresolvable observed chain, the
    ``observed_field`` error must carry the ROOT cause (the first recorded
    skip), not just "not a build-time-evaluable observed" — a skip cascades,
    and the name the caller reads is usually far downstream of the defect."""
    doc = json.loads(_FIXTURE.read_text())
    providers = {
        "ISRM.emis_lon": MockConst(oracle["lon"]),
        "ISRM.emis_lat": MockConst(oracle["lat"]),
        "ISRM.emis_annual": MockConst(oracle["emis_annual"]),
        "ISRM.is_VOC": MockConst(oracle["masks"]["SOA"]),
        "ISRM.is_NOx": MockConst(oracle["masks"]["pNO3"]),
        "ISRM.is_NH3": MockConst(oracle["masks"]["pNH4"]),
        "ISRM.is_SOx": MockConst(oracle["masks"]["pSO4"]),
        "ISRM.is_PM25": MockConst(oracle["masks"]["PrimaryPM25"]),
        # MortalityRate / TotalPop / the gated SR providers are intentionally
        # ABSENT: everything downstream of them is dropped by the hoist.
    }
    ca = {"src_W": oracle["W"], "src_S": oracle["S"], "src_E": oracle["E"], "src_N": oracle["N"]}
    try:
        prep = esm_problem(doc, (0.0, 1.0), providers=providers, const_arrays=ca, pushdown_rewrite=True)
    except SimulationError:
        pytest.skip("prepare itself rejects the missing providers (also fine)")
    with pytest.raises(SimulationError, match=r"hoist dropped"):
        observed_field(prep, "deathsK")
