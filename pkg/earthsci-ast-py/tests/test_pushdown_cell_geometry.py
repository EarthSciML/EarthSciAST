"""Cell-axis arrays under the projection-pushdown rewrite (CONFORMANCE_SPEC
§5.5.7 "Cell-axis arrays").

The rewrite re-points a binning aggregate's reduction range onto the compact
derived support set, which RENUMBERS the cell symbol: after it fires, that
symbol counts support positions and support position ``i`` is grid cell
``member_factor[i]``. Every array the body reads through it must be renumbered
with it — not only the four envelope bounds of the containment predicate.

Polygon allocation is the shape that makes the difference visible. Its weight is
``polygon_intersection_area(cell_ring[c], rec_ring[r]) / cell_area[c]``, so the
body reads a rank-3 ``[cells, vertex, xy]`` ring stack and a rank-1 area, and
neither is an envelope factor. Gathering only the envelopes leaves both pointing
at the full grid while the axis is compact: full-grid values read at support
positions, wrong numbers, no diagnostic anywhere. These tests hold the fix.
"""

from __future__ import annotations

import copy
import json

import numpy as np
import pytest

from earthsci_ast.problem import esm_problem, observed_field
from earthsci_ast.pushdown_rewrite import PushdownRewriteError, desugar_pushdown

NV = 5  # a closed unit square: four corners and the repeat


def _ix(f, *idx):
    return {"op": "index", "args": [f, *idx]}


def _ring(x0, y0, x1, y1):
    return [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]]


# A 2x2 grid of unit cells over [0,2]^2.
W = [0.0, 1.0, 0.0, 1.0]
S = [0.0, 0.0, 1.0, 1.0]
E = [1.0, 2.0, 1.0, 2.0]
N = [1.0, 1.0, 2.0, 2.0]
# Record 0 straddles cells 0 and 1; record 1 sits inside cell 3; record 2 is off
# the grid entirely, so it contributes to no cell and joins no support member.
RECS = [(0.5, 0.25, 1.5, 0.75), (1.2, 1.2, 1.8, 1.8), (5.0, 5.0, 6.0, 6.0)]
EMIS = [10.0, 4.0, 7.0]
SR = np.array([[1.0, 0.5], [2.0, 0.25], [3.0, 0.125], [4.0, 0.0625]])
# Cells 0 and 1 each take a quarter of record 0's 0.5 area; cell 3 takes all of
# record 1's 0.36; cell 2 is met by nothing.
EXPECT_E = [10.0 * 0.25, 10.0 * 0.25, 0.0, 4.0 * 0.36]


def _doc():
    """The polygon-allocation document: an envelope broad phase, an intersection
    area for the narrow phase, and a data-fed SR array for the mat-vec."""
    return {
        "esm": "1.0.0",
        "metadata": {"name": "pushdown_cell_geometry"},
        "data_sources": {"MockSR": {"kind": "static", "source": {"url_template": "mock://sr"}}},
        "index_sets": {
            "src_cells": {"kind": "interval", "size": 4},
            "rcv_cells": {"kind": "interval", "size": 2},
            "emis_records": {"kind": "interval", "size": 3},
            "ring_vertex": {"kind": "interval", "size": NV},
            "xy": {"kind": "interval", "size": 2},
        },
        "models": {
            "Binned": {
                "variables": {
                    "src_W": {"type": "parameter", "default": 0.0, "shape": ["src_cells"]},
                    "src_S": {"type": "parameter", "default": 0.0, "shape": ["src_cells"]},
                    "src_E": {"type": "parameter", "default": 0.0, "shape": ["src_cells"]},
                    "src_N": {"type": "parameter", "default": 0.0, "shape": ["src_cells"]},
                    "cell_area": {"type": "parameter", "default": 0.0, "shape": ["src_cells"]},
                    "cell_ring": {
                        "type": "parameter",
                        "default": 0.0,
                        "shape": ["src_cells", "ring_vertex", "xy"],
                    },
                    "rec_ring": {
                        "type": "parameter",
                        "default": 0.0,
                        "shape": ["emis_records", "ring_vertex", "xy"],
                    },
                    "rec_xmin": {"type": "parameter", "default": 0.0, "shape": ["emis_records"]},
                    "rec_ymin": {"type": "parameter", "default": 0.0, "shape": ["emis_records"]},
                    "rec_xmax": {"type": "parameter", "default": 0.0, "shape": ["emis_records"]},
                    "rec_ymax": {"type": "parameter", "default": 0.0, "shape": ["emis_records"]},
                    "emis_annual": {"type": "parameter", "default": 0.0, "shape": ["emis_records"]},
                    "SR_PM25": {
                        "type": "parameter",
                        "default": 0.0,
                        "units": "1",
                        "shape": ["src_cells", "rcv_cells"],
                        "update": {
                            "kind": "data",
                            "source": "MockSR",
                            "from": {"file_variable": "PM25"},
                        },
                    },
                    "E_PM25": {"type": "unknown", "shape": ["src_cells"]},
                    "conc_PM25": {"type": "unknown", "shape": ["rcv_cells"]},
                },
                "equations": [
                    {
                        "lhs": "E_PM25",
                        "rhs": {
                            "op": "aggregate",
                            "reduce": "+",
                            "output_idx": ["c"],
                            "ranges": {
                                "c": {"from": "src_cells"},
                                "r": {"from": "emis_records"},
                            },
                            "args": [
                                "src_W", "src_S", "src_E", "src_N",
                                "rec_xmin", "rec_ymin", "rec_xmax", "rec_ymax",
                                "cell_ring", "cell_area", "rec_ring", "emis_annual",
                            ],
                            "expr": {
                                "op": "*",
                                "args": [
                                    {
                                        "op": "ifelse",
                                        "args": [
                                            {
                                                "op": "and",
                                                "args": [
                                                    {"op": "<=", "args": [_ix("src_W", "c"), _ix("rec_xmax", "r")]},
                                                    {"op": "<=", "args": [_ix("rec_xmin", "r"), _ix("src_E", "c")]},
                                                    {"op": "<=", "args": [_ix("src_S", "c"), _ix("rec_ymax", "r")]},
                                                    {"op": "<=", "args": [_ix("rec_ymin", "r"), _ix("src_N", "c")]},
                                                ],
                                            },
                                            1.0,
                                            0.0,
                                        ],
                                    },
                                    {
                                        "op": "*",
                                        "args": [
                                            _ix("emis_annual", "r"),
                                            {
                                                "op": "/",
                                                "args": [
                                                    {
                                                        "op": "polygon_intersection_area",
                                                        "manifold": "planar",
                                                        "args": [_ix("cell_ring", "c"), _ix("rec_ring", "r")],
                                                    },
                                                    _ix("cell_area", "c"),
                                                ],
                                            },
                                        ],
                                    },
                                ],
                            },
                        },
                    },
                    {
                        "lhs": "conc_PM25",
                        "rhs": {
                            "op": "aggregate",
                            "reduce": "+",
                            "output_idx": ["rcv"],
                            "ranges": {"rcv": {"from": "rcv_cells"}, "s": {"from": "src_cells"}},
                            "args": ["SR_PM25", "E_PM25"],
                            "expr": {
                                "op": "*",
                                "args": [_ix("SR_PM25", "s", "rcv"), _ix("E_PM25", "s")],
                            },
                        },
                    },
                ],
            }
        },
    }


class MockGated:
    """A pushdown-capable provider: it records whether the engine asked for a
    selection or took the whole array."""

    supports_selection = True

    def __init__(self, full):
        self.full = np.asarray(full, dtype=float)
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


def _const_arrays():
    base = {
        "src_W": W, "src_S": S, "src_E": E, "src_N": N,
        "cell_area": [1.0] * 4,
        "cell_ring": [_ring(W[c], S[c], E[c], N[c]) for c in range(4)],
        "rec_ring": [_ring(*r) for r in RECS],
        "rec_xmin": [r[0] for r in RECS], "rec_ymin": [r[1] for r in RECS],
        "rec_xmax": [r[2] for r in RECS], "rec_ymax": [r[3] for r in RECS],
        "emis_annual": EMIS,
    }
    # The flattened consumer is `<Model>.<parameter>`; the pushdown path aliases
    # bare names onto it, the dense path does not.
    out = dict(base)
    out.update({"Binned." + k: v for k, v in base.items()})
    return out


# --------------------------------------------------------------------------- #
# Emission
# --------------------------------------------------------------------------- #


def test_every_cell_axis_array_is_gathered_rank_preserving():
    """§5.5.7: the gather family is every array declared over the cell set that
    the body subscripts with the cell symbol — bounds, area AND ring stack —
    and each keeps its trailing axes."""
    out = desugar_pushdown(_doc(), "Binned")
    v = out["models"]["Binned"]["variables"]
    gathers = {k: v[k]["shape"] for k in v if k.startswith("pd_cell__")}
    assert set(gathers) == {
        "pd_cell__src_cells__src_W",
        "pd_cell__src_cells__src_S",
        "pd_cell__src_cells__src_E",
        "pd_cell__src_cells__src_N",
        "pd_cell__src_cells__cell_area",
        "pd_cell__src_cells__cell_ring",
    }
    # RANK-PRESERVING: only the first axis moves onto the derived set.
    assert gathers["pd_cell__src_cells__cell_ring"] == [
        "pd_support__src_cells",
        "ring_vertex",
        "xy",
    ]
    assert gathers["pd_cell__src_cells__cell_area"] == ["pd_support__src_cells"]

    defs = {e["lhs"]: e["rhs"] for e in out["models"]["Binned"]["equations"] if isinstance(e.get("lhs"), str)}
    ring = defs["pd_cell__src_cells__cell_ring"]
    # A MAP, not a reduction: every range is an output index.
    assert ring["output_idx"] == ["c", "pd_t0", "pd_t1"]
    assert set(ring["ranges"]) == {"c", "pd_t0", "pd_t1"}
    assert ring["ranges"]["pd_t0"]["from"] == "ring_vertex"
    assert ring["ranges"]["pd_t1"]["from"] == "xy"
    assert ring["expr"]["args"][0] == "cell_ring"
    assert ring["expr"]["args"][2:] == ["pd_t0", "pd_t1"]
    # The rank-1 arm is byte-identical to what it always emitted.
    assert defs["pd_cell__src_cells__src_W"]["output_idx"] == ["c"]


def test_body_reads_are_repointed_onto_the_gathers():
    """The polygon operand and the area divisor follow the envelopes onto the
    compact axis — the substitution is by NAME, so the sliced spelling
    `index(cell_ring, c)` is untouched apart from the base."""
    out = desugar_pushdown(_doc(), "Binned")
    body = next(
        e["rhs"] for e in out["models"]["Binned"]["equations"] if e.get("lhs") == "E_PM25"
    )
    assert body["ranges"]["c"]["from"] == "pd_support__src_cells"

    bases = set()

    def walk(n):
        if isinstance(n, dict):
            if n.get("op") == "index" and isinstance(n.get("args"), list) and n["args"]:
                if isinstance(n["args"][0], str):
                    bases.add(n["args"][0])
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for x in n:
                walk(x)

    walk(body)
    # NOTHING in the rewritten body still reads a full-grid cell-axis array.
    assert not bases & {"cell_ring", "cell_area", "src_W", "src_S", "src_E", "src_N"}
    assert "pd_cell__src_cells__cell_ring" in bases
    assert "pd_cell__src_cells__cell_area" in bases

    # The polygon operand keeps its SLICED spelling: the base name changed and
    # nothing else did, which is what rank preservation buys.
    found = []

    def find_pia(n):
        if isinstance(n, dict):
            if n.get("op") == "polygon_intersection_area":
                found.append(n)
            for v in n.values():
                find_pia(v)
        elif isinstance(n, list):
            for x in n:
                find_pia(x)

    find_pia(body)
    assert len(found) == 1
    assert found[0]["args"][0] == {
        "op": "index",
        "args": ["pd_cell__src_cells__cell_ring", "c"],
    }
    assert found[0]["args"][1] == {"op": "index", "args": ["rec_ring", "r"]}


def test_computed_cell_position_is_refused_loudly():
    """A cell-axis array read at `c + 1` cannot be re-pointed: the compact axis
    is a renumbering and no arithmetic on a support position survives it. That
    is a hard error naming the array and the subscript — declining silently
    would hide an ungated fetch, and emitting anyway would be wrong numbers."""
    doc = _doc()
    body = doc["models"]["Binned"]["equations"][0]["rhs"]["expr"]["args"][1]["args"][1]
    body["args"][1] = _ix("cell_area", {"op": "+", "args": ["c", 1]})
    with pytest.raises(PushdownRewriteError) as exc:
        desugar_pushdown(doc, "Binned")
    msg = str(exc.value)
    assert "cell_area" in msg and "+(c, 1)" in msg
    assert "COMPUTED cell position" in msg


def test_an_array_off_the_cell_axis_is_left_alone():
    """A flat-offset gather into ANOTHER axis is not on the cell axis: it stays
    full-grid, and it is still correct after the rewrite because nothing about
    it moved. Gathering it would be the bug in the other direction."""
    doc = _doc()
    m = doc["models"]["Binned"]
    doc["index_sets"]["all_cells"] = {"kind": "interval", "size": 8}
    m["variables"]["temperature"] = {
        "type": "parameter",
        "default": 0.0,
        "shape": ["all_cells"],
    }
    body = m["equations"][0]["rhs"]
    body["args"].append("temperature")
    body["expr"] = {
        "op": "*",
        "args": [body["expr"], _ix("temperature", {"op": "+", "args": ["c", 4]})],
    }
    out = desugar_pushdown(doc, "Binned")
    v = out["models"]["Binned"]["variables"]
    assert "pd_cell__src_cells__temperature" not in v
    rewritten = json.dumps(
        next(e["rhs"] for e in out["models"]["Binned"]["equations"] if e.get("lhs") == "E_PM25")
    )
    assert '"temperature"' in rewritten


# --------------------------------------------------------------------------- #
# Numerics — the reason any of this matters
# --------------------------------------------------------------------------- #


def test_rewritten_polygon_allocation_matches_the_dense_evaluation():
    """End to end: the compact run must agree with the dense one. `E` is
    compared at the support cells (it is shorter by construction) and `conc`,
    which is on the full receptor axis, exactly."""
    ca = _const_arrays()

    dense_prep = esm_problem(copy.deepcopy(_doc()), (0.0, 1.0), const_arrays=dict(ca, **{"Binned.SR_PM25": SR}))
    dense = {v: np.asarray(observed_field(dense_prep, v)) for v in ("E_PM25", "conc_PM25")}
    # The dense arm is itself checked against a hand oracle, so a shared bug in
    # both arms cannot pass this test by agreeing with itself.
    assert np.allclose(dense["E_PM25"], EXPECT_E)
    assert np.allclose(dense["conc_PM25"], np.asarray(EXPECT_E) @ SR)

    gated = MockGated(SR)
    push_prep = esm_problem(copy.deepcopy(_doc()), (0.0, 1.0), const_arrays=ca, providers={"Binned.SR_PM25": gated}, pushdown_rewrite=True)
    push = {v: np.asarray(observed_field(push_prep, v)) for v in ("E_PM25", "conc_PM25")}

    mf = np.asarray(push_prep.const_arrays["pd_member_factor__src_cells"], dtype=int)
    assert mf.tolist() == [1, 2, 4]  # 1-based; cell 3 is met by no record
    assert np.allclose(push["E_PM25"], np.asarray(EXPECT_E)[mf - 1])
    assert np.allclose(push["conc_PM25"], dense["conc_PM25"])

    # And the gate did its job: the SR rows were selected, not taken wholesale.
    assert not [c for c in gated.calls if c[0] == "wholesale"]
    assert [c for c in gated.calls if c[0] == "selection"] == [("selection", [[0, 1, 3], "all"])]
