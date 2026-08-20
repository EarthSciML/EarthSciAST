"""Unit tests for the Phase-3 pushdown engine hooks (simulation_array):

1. member_factor feedback (``_feed_back_vi_members``) — Julia build hook 1;
2. gated-provider deferral fetch (``_fetch_gated_providers``) — hook 2, both
   the pushdown-capable and the fetch-whole-then-slice fallback paths;
3. binning-coordinate seeding from overlap producers
   (``_binning_coord_arrays(producer_seed_nodes=…)``) — the build-time
   evaluation of the in-model projection coordinates;

plus the raw-dict rewrite's guard behaviours (semiring soundness, idempotency)
that the golden corpus cannot express as fixtures.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.parse import _parse_expression
from earthsci_ast.pushdown_rewrite import (
    _inject_pushdown_aliases,
    _pushdown_provider_gates,
    desugar_pushdown,
)
from earthsci_ast.simulation_array import (
    _binning_coord_arrays,
    _feed_back_vi_members,
    _fetch_gated_providers,
    _neutral_selection_to_native,
)
from earthsci_ast.sympy_bridge import SimulationError

_FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "tests"
    / "conformance"
    / "pushdown"
    / "fixtures"
    / "pushdown_l1.esm"
)


# --------------------------------------------------------------------------- #
# Hook 1: member_factor feedback
# --------------------------------------------------------------------------- #


def test_feed_back_vi_members_registers_factor_under_aliases():
    index_sets = {
        "supp": {"kind": "derived", "from_faq": "faq1", "member_factor": "mf"},
        "plain": {"kind": "interval", "size": 3},
    }
    out = _feed_back_vi_members(index_sets, {"faq1": [2, 5, 9]}, ["M.mf", "M.other"])
    assert sorted(out) == ["M.mf", "mf"]
    np.testing.assert_array_equal(out["mf"], [2.0, 5.0, 9.0])
    assert out["mf"] is out["M.mf"]


def test_feed_back_vi_members_no_factor_or_unmaterialized_is_noop():
    index_sets = {"supp": {"kind": "derived", "from_faq": "faq1"}}
    assert _feed_back_vi_members(index_sets, {"faq1": [1]}, []) == {}
    index_sets = {"supp": {"kind": "derived", "from_faq": "faq1", "member_factor": "mf"}}
    assert _feed_back_vi_members(index_sets, {"other": [1]}, []) == {}


def test_feed_back_vi_members_composite_member_raises():
    index_sets = {"supp": {"kind": "derived", "from_faq": "faq1", "member_factor": "mf"}}
    with pytest.raises(SimulationError, match="SCALAR members"):
        _feed_back_vi_members(index_sets, {"faq1": [(1, 2)]}, [])


# --------------------------------------------------------------------------- #
# Hook 2: gated-provider deferral fetch
# --------------------------------------------------------------------------- #


class _GatedMock:
    supports_selection = True

    def __init__(self, full):
        self.full = np.asarray(full, dtype=float)
        self.calls = []

    def sample(self, t, selection=None):
        self.calls.append(selection)
        if selection is None:
            return self.full
        out = self.full
        for axis, a in enumerate(selection):
            if a != "all":
                out = np.take(out, np.asarray(a, dtype=int), axis=axis)
        return out


class _WholeMock:
    """No selection support: the engine must fall back to whole-fetch+slice."""

    def __init__(self, full):
        self.full = np.asarray(full, dtype=float)
        self.calls = []

    def sample(self, t):
        self.calls.append("whole")
        return self.full


_IDX = {"supp": {"kind": "derived", "from_faq": "faq1", "member_factor": "mf"}}
_GATE = {
    "axes": [{"fixed": [0]}, {"gated_by": "supp"}, "all"],
    "applies_to": ["SR"],
}


def _full(n_layer=2, n_src=6, n_rcv=3):
    return np.arange(n_layer * n_src * n_rcv, dtype=float).reshape(n_layer, n_src, n_rcv)


def test_gated_fetch_pushdown_path():
    prov = _GatedMock(_full())
    out = _fetch_gated_providers(
        {"L.SR": (prov, _GATE)}, _IDX, {"faq1": [2, 4, 6]}, {"faq1": 3}, 0.0, ["M.SR"]
    )
    assert prov.calls == [[[0], [1, 3, 5], "all"]]  # 0-based; never wholesale
    assert sorted(out) == ["M.SR", "SR"]
    np.testing.assert_array_equal(out["SR"], _full()[0][[1, 3, 5], :])


def test_gated_fetch_fallback_slices_wholesale():
    prov = _WholeMock(_full())
    out = _fetch_gated_providers(
        {"L.SR": (prov, _GATE)}, _IDX, {"faq1": [2, 4, 6]}, {"faq1": 3}, 0.0, []
    )
    assert prov.calls == ["whole"]
    np.testing.assert_array_equal(out["SR"], _full()[0][[1, 3, 5], :])


def test_gated_fetch_extent_mismatch_raises():
    prov = _GatedMock(_full())
    with pytest.raises(SimulationError, match="gating set extent"):
        _fetch_gated_providers(
            {"L.SR": (prov, _GATE)}, _IDX, {"faq1": [2, 4, 6]}, {"faq1": 7}, 0.0, []
        )


def test_gated_fetch_malformed_axis_and_missing_set():
    prov = _GatedMock(_full())
    bad = {"axes": [{"fixed": [0]}, {"bogus": 1}, "all"], "applies_to": ["SR"]}
    with pytest.raises(SimulationError, match="malformed"):
        _fetch_gated_providers({"L.SR": (prov, bad)}, _IDX, {"faq1": [1]}, {}, 0.0, [])
    gate = {"axes": [{"gated_by": "nope"}, "all", "all"], "applies_to": ["SR"]}
    with pytest.raises(SimulationError, match="not a\n?.*derived index set|derived index set"):
        _fetch_gated_providers({"L.SR": (prov, gate)}, _IDX, {"faq1": [1]}, {}, 0.0, [])


def test_gated_fetch_sibling_loaders_do_not_overwrite_each_other():
    """Sibling loaders exposing the SAME variable name are DIFFERENT slabs.

    ``isrm.esm`` states plume rise by fetching one zarr array at three emission
    layers through three sibling loaders — ``ISRM_SR_L0.SOA``,
    ``ISRM_SR_L1.SOA``, ``ISRM_SR_L2.SOA`` — differing in nothing but the
    ``{"fixed": [layer]}`` axis of their ``gated_select``. Publishing each
    fetched slab under every same-TAIL alias made all three providers claim all
    three keys, so whichever was written last silently won for all of them and
    every layer of the model was contracted against one arbitrary sibling's
    slab. Measured on isrm.esm at ISRM_FIRSTN=200 that moved sum(deathsK) 6.6%.
    """
    full = _full(n_layer=3, n_src=6, n_rcv=3)
    names = [f"SR_L{L}.SOA" for L in range(3)]
    provs = {L: _GatedMock(full) for L in range(3)}
    gated = {
        f"SR_L{L}.SOA": (
            provs[L],
            {
                "axes": [{"fixed": [L]}, {"gated_by": "supp"}, "all"],
                "applies_to": ["SOA"],
            },
        )
        for L in range(3)
    }
    out = _fetch_gated_providers(
        gated, _IDX, {"faq1": [2, 4, 6]}, {"faq1": 3}, 0.0, names
    )
    for L in range(3):
        np.testing.assert_array_equal(out[f"SR_L{L}.SOA"], full[L][[1, 3, 5], :])
    # the three slabs really do differ, so no overwrite could hide in an
    # accidental equality
    assert not np.array_equal(out["SR_L0.SOA"], out["SR_L1.SOA"])
    assert not np.array_equal(out["SR_L1.SOA"], out["SR_L2.SOA"])
    # the bare tail is claimed by all three and owned by none: left unwritten
    # rather than arbitrarily assigned
    assert "SOA" not in out


def test_neutral_selection_to_native():
    assert _neutral_selection_to_native(["all", [0, 2], [1]]) == {
        "axes": ["all", {"indices": [0, 2]}, {"indices": [1]}]
    }


# --------------------------------------------------------------------------- #
# Hook 3: binning-coordinate seeding from overlap producers
# --------------------------------------------------------------------------- #


def _obs(expr_json):
    return _parse_expression(expr_json)


def test_binning_coords_seeded_from_overlap_producer():
    # A join-free observed coordinate (X = 2*lon) that ONLY the producer's
    # overlap envelope references; no skolem bin_specs at all.
    x_expr = _obs(
        {
            "op": "aggregate",
            "output_idx": ["e"],
            "ranges": {"e": {"from": "recs"}},
            "args": ["lon"],
            "expr": {"op": "*", "args": [{"op": "index", "args": ["lon", "e"]}, 2.0]},
        }
    )
    producer = _obs(
        {
            "op": "aggregate",
            "output_idx": ["m"],
            "ranges": {"r": {"from": "recs"}, "c": {"from": "cells"}},
            "expr": {"op": "true", "args": []},
            "distinct": True,
            "semiring": "bool_and_or",
            "id": "faq1",
            "join": [{"overlap": {"src_env": ["X", "Y"], "tgt_env": ["W", "S", "E", "N"], "eps": 0.0}}],
            "key": {"op": "skolem", "label": "cell", "args": ["c"]},
            "args": ["X", "Y", "W", "S", "E", "N"],
        }
    )
    index_sets = {"recs": {"kind": "interval", "size": 3}, "cells": {"kind": "interval", "size": 2}}
    out = _binning_coord_arrays(
        [("X", x_expr)],
        [],  # no bin specs
        index_sets,
        {},
        {},
        {},
        0,
        producer_seed_nodes=[producer],
        input_arrays={"lon": np.array([1.0, 2.0, 3.0])},
    )
    np.testing.assert_array_equal(out["X"], [2.0, 4.0, 6.0])


def test_binning_coords_seeded_producer_missing_input_degrades():
    # Without `lon` the seeded-only closure must NOT hard-fail (fail-closed:
    # the VI front-door then degrades to maps_only exactly as before).
    x_expr = _obs(
        {
            "op": "aggregate",
            "output_idx": ["e"],
            "ranges": {"e": {"from": "recs"}},
            "args": ["lon"],
            "expr": {"op": "*", "args": [{"op": "index", "args": ["lon", "e"]}, 2.0]},
        }
    )
    producer = _obs(
        {
            "op": "aggregate",
            "output_idx": ["m"],
            "ranges": {"r": {"from": "recs"}},
            "expr": {"op": "true", "args": []},
            "distinct": True,
            "join": [{"overlap": {"src_env": ["X", "Y"], "tgt_env": ["W"], "eps": 0.0}}],
            "args": ["X"],
        }
    )
    out = _binning_coord_arrays(
        [("X", x_expr)],
        [],
        {"recs": {"kind": "interval", "size": 3}},
        {},
        {},
        {},
        0,
        producer_seed_nodes=[producer],
        input_arrays={},
    )
    assert "X" not in out


def test_binning_coords_no_specs_no_seeds_is_noop():
    assert _binning_coord_arrays([], [], {}, {}, {}, {}, 0) == {}


# --------------------------------------------------------------------------- #
# Rewrite guards + record-derived gates (beyond the golden corpus)
# --------------------------------------------------------------------------- #


def _l1_doc():
    return json.loads(_FIXTURE.read_text())


def test_desugar_semiring_guard_blocks_non_additive():
    doc = _l1_doc()
    # An observed unknown's defining expression is its bare-variable-LHS
    # equation's RHS from esm 1.0.0 -- there is no `variables[v].expression` to
    # reach into.
    for eq in doc["models"]["ISRM"]["equations"]:
        rhs = eq.get("rhs")
        if isinstance(rhs, dict) and rhs.get("reduce") == "+":
            rhs["reduce"] = "max"  # same shape, different semiring
    assert desugar_pushdown(doc, model_name="ISRM") is doc


def test_desugar_no_models_or_unknown_model_is_noop():
    assert desugar_pushdown({"esm": "1.0.0"}) == {"esm": "1.0.0"}
    doc = _l1_doc()
    assert desugar_pushdown(doc, model_name="NoSuchModel") is doc


def test_pushdown_provider_gates_from_record_and_template():
    doc = desugar_pushdown(_l1_doc(), model_name="ISRM")
    # A provider key is "<Source>.<parameter>": from esm 1.0.0 the parameter IS
    # the loaded field, so it is the parameter -- not a loader variable -- that
    # a provider serves and that the rewrite record gates.
    providers = {f"ISRM.SR_{v}": object() for v in ["SOA", "pNO3"]}
    providers["ISRM.emis_lon"] = object()  # not one of the gated arrays
    gates = _pushdown_provider_gates(doc, providers)
    assert sorted(gates) == ["ISRM.SR_SOA", "ISRM.SR_pNO3"]
    g = gates["ISRM.SR_SOA"]
    # the source template's fixed layer survives; the STALE gated_by name is
    # replaced by the record's generated set. The template is parsed through the
    # shared §8.9.2 selector vocabulary, so the emitted `fixed` is the spec's
    # SCALAR index (the authored `{"fixed": [0]}` list spelling is still
    # accepted on input, exactly as the Rust peer accepts it).
    assert g["axes"] == [
        {"fixed": 0},
        {"gated_by": "pd_support__src_cells"},
        "all",
    ]
    # `applies_to` names the MODEL ARRAY the fetched slab binds to. From 1.0.0
    # that is the consuming PARAMETER: it IS the loaded field, so there is no
    # coupling edge and no loader-variable name standing in for it.
    assert g["applies_to"] == ["SR_SOA"]
    assert _pushdown_provider_gates(doc, None) == {}
    assert _pushdown_provider_gates(_l1_doc(), providers) == {}  # no record


def test_pushdown_provider_gates_template_axis_mismatch_raises():
    doc = desugar_pushdown(_l1_doc(), model_name="ISRM")
    tpl = doc["data_sources"]["MockSR"]["metadata"]["x_esd"]["gated_select"]
    tpl["axes"] = ["all", {"fixed": [0]}, {"gated_by": "stale"}]  # gated at nonfixed pos 1
    from earthsci_ast.pushdown_rewrite import PushdownRewriteError

    with pytest.raises(PushdownRewriteError, match="disagree"):
        _pushdown_provider_gates(doc, {"ISRM.SR_SOA": object()})


def test_inject_pushdown_aliases():
    dst = {"src_W": 1, "ISRM.lon": 2, "already.there": 3}
    _inject_pushdown_aliases(
        dst,
        ["ISRM.src_W", "ISRM.emis_lon", "already.there"],
        [("ISRM.lon", "ISRM.emis_lon")],
    )
    assert dst["ISRM.src_W"] == 1  # bare → flattened suffix alias
    assert dst["ISRM.emis_lon"] == 2  # coupling from → to alias
    assert dst["already.there"] == 3  # never overwritten
