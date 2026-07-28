"""CROSS-LANGUAGE conformance for the projection-pushdown spatial OVERLAP
join-gate (CONFORMANCE_SPEC §5.5.6, Phase 2a). Proves the Python engine derives
the SAME support-set members as the Julia reference and the Rust engine from the
SAME shared fixture geometry.

The gate replaces uniform-grid bin-EQUALITY (``join.on [[l, r]]``) with envelope
CANDIDACY built on the Phase-3a broad phase: the producer admits a contracted
``(point, cell)`` tuple iff its two range positions are in the candidate set
computed ONCE from the two envelope factor arrays. A rectangle-containment
``filter`` is the narrow phase. Materialising the producer's ``distinct`` set is
then the EXACT set of cells containing at least one point.

Mirrors ``earthsci-ast-rs/tests/overlap_gate_conformance.rs`` case for case, and
asserts the same Julia goldens verbatim:

  (a) ISRM L1 (3x3 grid, points in cells {1,2,4,9}) — the headline support set
      ``[1,2,4,9]``, from the SHARED fixture
      ``earthsci-ast-rs/tests/fixtures/pushdown/overlap_gate_point_in_rect.esm``.

  (b) point-in-rectangle micro fixture (5 points x 4 cells) — the Julia golden
      ``[1,2]``, including the broad-phase candidate set being a CONSERVATIVE
      SUPERSET of the true strict containments, with the narrow filter dropping
      the boundary pairs.

Determinism: integer keys, §5.5 sorted total order — the member list is
byte-identical across languages. Note the Rust broad phase reports 0-based pairs
while Julia and Python report 1-based positions (the enumeration bindings are
1-based); the pair SETS correspond exactly under that shift.
"""

from __future__ import annotations

import json
import os

import numpy as np
import pytest

from earthsci_ast import broad_phase
from earthsci_ast.value_invention import (
    _VI_ENUM_VISITS,
    ValueInventionError,
    materialize_value_invention,
)

# The fixture lives in the Rust package (it is the shared cross-language copy).
FIXTURE = os.path.normpath(
    os.path.join(
        os.path.dirname(__file__),
        "..",
        "..",
        "earthsci-ast-rs",
        "tests",
        "fixtures",
        "pushdown",
        "overlap_gate_point_in_rect.esm",
    )
)


def model_with_index_sets(doc: dict, model_name: str) -> dict:
    """A model view carrying the document-scoped ``index_sets`` (mirrors the
    value-invention front-door's merge, and the Rust test's helper of the same
    name)."""
    model = dict(doc["models"][model_name])
    model.setdefault("index_sets", doc.get("index_sets", {}))
    return model


def l1_const_arrays() -> dict[str, np.ndarray]:
    """The ISRM L1 geometry: a 3x3 grid of 2x2 cells (cell k = (row-1)*3 + col)
    and 5 emission points placed by hand in cells {1, 2, 4, 9}."""
    return {
        # Cell rectangles [W,S,E,N], row-major k = 1..9.
        "W": np.array([0.0, 2.0, 4.0, 0.0, 2.0, 4.0, 0.0, 2.0, 4.0]),
        "E": np.array([2.0, 4.0, 6.0, 2.0, 4.0, 6.0, 2.0, 4.0, 6.0]),
        "S": np.array([0.0, 0.0, 0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0]),
        "N": np.array([2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 6.0, 6.0, 6.0]),
        # Points: e1(1,1)->c1, e2(3,1)->c2, e3(1,3)->c4, e4(5,5)->c9, e5(1.5,1.5)->c1.
        "X": np.array([1.0, 3.0, 1.0, 5.0, 1.5]),
        "Y": np.array([1.0, 1.0, 3.0, 5.0, 1.5]),
    }


# --------------------------------------------------------------------------- #
# (a) HEADLINE — the shared ISRM L1 fixture
# --------------------------------------------------------------------------- #


def test_l1_overlap_producer_members_match_julia_golden():
    """The ISRM L1 point-in-rectangle producer materialises to EXACTLY the Julia
    support set ``[1,2,4,9]``, from the shared ``.esm`` fixture."""
    with open(FIXTURE) as fh:
        doc = json.load(fh)
    model = model_with_index_sets(doc, "ISRM")

    vi = materialize_value_invention(model, const_arrays=l1_const_arrays())

    # skolem("cell", [c]) is a single-component key => the scalar cell index; the
    # distinct set is the exact hand-computed containing cells.
    assert vi.members["emis_src_cells_faq"] == [1, 2, 4, 9], (
        "Python overlap-gate support set must equal the Julia L1 golden [1,2,4,9]"
    )
    assert vi.extents["emis_src_cells_faq"] == 4


def test_l1_broad_phase_is_conservative_superset_of_containments():
    """The L1 broad-phase candidate set is a CONSERVATIVE SUPERSET of the true
    strict containments. (All 5 L1 points land strictly interior to a single
    cell, so here the broad phase already equals the containments.)"""
    g = l1_const_arrays()
    src = broad_phase.envelope_vectors(["X", "Y"], g)
    tgt = broad_phase.envelope_vectors(["W", "S", "E", "N"], g)
    cs = broad_phase.broad_phase_candidates(src, tgt, eps=0.0)

    # True containments, 1-based (point, cell): e1->c1, e2->c2, e3->c4, e4->c9, e5->c1.
    for pair in [(1, 1), (2, 2), (3, 4), (4, 9), (5, 1)]:
        assert pair in cs, f"broad phase missed a true containment {pair}"
    assert cs == sorted(cs), "candidate pairs must be sorted ascending by (qi, cj)"
    assert len(cs) == len(set(cs)), "candidate pairs must be unique"


def test_l1_overlap_gate_drives_enumeration_not_full_product():
    """The gated producer VISITS O(|candidates|) tuples, not the full
    O(n_points * n_cells) product — the Wall #1 pushdown, not just a filter."""
    with open(FIXTURE) as fh:
        doc = json.load(fh)
    model = model_with_index_sets(doc, "ISRM")
    g = l1_const_arrays()
    n_cands = len(
        broad_phase.broad_phase_candidates(
            broad_phase.envelope_vectors(["X", "Y"], g),
            broad_phase.envelope_vectors(["W", "S", "E", "N"], g),
        )
    )

    _VI_ENUM_VISITS[0] = 0
    materialize_value_invention(model, const_arrays=g)
    visits = _VI_ENUM_VISITS[0]

    assert visits == n_cands, f"expected {n_cands} candidate-driven visits, got {visits}"
    assert visits < 5 * 9, "the gate must not enumerate the full points x cells product"


# --------------------------------------------------------------------------- #
# (b) point-in-rectangle MICRO fixture
# --------------------------------------------------------------------------- #


def micro_const_arrays() -> dict[str, np.ndarray]:
    # cells (rects [W,S,E,N]): c1=[0,0,2,2] c2=[2,2,4,4] c3=[4,4,6,6] c4=[6,6,8,8]
    # points [X,Y]: p1(1,1) p2(3,3) p3(2,2) p4(10,10) p5(6,6)
    return {
        "X": np.array([1.0, 3.0, 2.0, 10.0, 6.0]),
        "Y": np.array([1.0, 3.0, 2.0, 10.0, 6.0]),
        "W": np.array([0.0, 2.0, 4.0, 6.0]),
        "S": np.array([0.0, 2.0, 4.0, 6.0]),
        "E": np.array([2.0, 4.0, 6.0, 8.0]),
        "N": np.array([2.0, 4.0, 6.0, 8.0]),
    }


MICRO_DOC = {
    "esm": "0.9.0",
    "metadata": {"name": "overlap_gate_point_in_rect_micro"},
    "index_sets": {
        "points": {"kind": "interval", "size": 5},
        "cells": {"kind": "interval", "size": 4},
        "present_cells": {"kind": "derived", "from_faq": "cells_with_points"},
    },
    "models": {
        "PointInRect": {
            "variables": {
                "X": {"type": "parameter", "shape": ["points"]},
                "Y": {"type": "parameter", "shape": ["points"]},
                "W": {"type": "parameter", "shape": ["cells"]},
                "S": {"type": "parameter", "shape": ["cells"]},
                "E": {"type": "parameter", "shape": ["cells"]},
                "N": {"type": "parameter", "shape": ["cells"]},
                "cell_present": {"type": "state", "shape": ["present_cells"]},
            },
            "equations": [
                {
                    "lhs": {"op": "index", "args": ["cell_present", "m"]},
                    "rhs": {
                        "op": "aggregate",
                        "id": "cells_with_points",
                        "semiring": "bool_and_or",
                        "distinct": True,
                        "output_idx": ["m"],
                        "ranges": {"i": {"from": "points"}, "j": {"from": "cells"}},
                        "join": [
                            {
                                "overlap": {
                                    "src_env": ["X", "Y"],
                                    "tgt_env": ["W", "S", "E", "N"],
                                    "eps": 0.0,
                                }
                            }
                        ],
                        # strict rectangle interior: (X-W)(E-X)(Y-S)(N-Y) > 0
                        "filter": {
                            "op": ">",
                            "args": [
                                {
                                    "op": "*",
                                    "args": [
                                        {
                                            "op": "*",
                                            "args": [
                                                {
                                                    "op": "-",
                                                    "args": [
                                                        {"op": "index", "args": ["X", "i"]},
                                                        {"op": "index", "args": ["W", "j"]},
                                                    ],
                                                },
                                                {
                                                    "op": "-",
                                                    "args": [
                                                        {"op": "index", "args": ["E", "j"]},
                                                        {"op": "index", "args": ["X", "i"]},
                                                    ],
                                                },
                                            ],
                                        },
                                        {
                                            "op": "*",
                                            "args": [
                                                {
                                                    "op": "-",
                                                    "args": [
                                                        {"op": "index", "args": ["Y", "i"]},
                                                        {"op": "index", "args": ["S", "j"]},
                                                    ],
                                                },
                                                {
                                                    "op": "-",
                                                    "args": [
                                                        {"op": "index", "args": ["N", "j"]},
                                                        {"op": "index", "args": ["Y", "i"]},
                                                    ],
                                                },
                                            ],
                                        },
                                    ],
                                },
                                0.0,
                            ],
                        },
                        "args": ["X", "Y", "W", "S", "E", "N"],
                        "key": {"op": "skolem", "label": "cell", "args": ["j"]},
                        "expr": {"op": "true", "args": []},
                    },
                }
            ],
        }
    },
}


def test_micro_broad_phase_matches_julia_candidate_golden():
    """The candidate set equals the Julia golden (1-based) and is a conservative
    superset of the true strict containments — p3 and p5 are candidates for two
    cells each, and only the narrow filter drops them."""
    g = micro_const_arrays()
    cs = broad_phase.broad_phase_candidates(
        broad_phase.envelope_vectors(["X", "Y"], g),
        broad_phase.envelope_vectors(["W", "S", "E", "N"], g),
    )
    assert cs == [(1, 1), (2, 2), (3, 1), (3, 2), (5, 3), (5, 4)]
    for pair in [(1, 1), (2, 2)]:
        assert pair in cs, f"true containment {pair} is not a candidate"


def test_micro_overlap_producer_members_match_julia_golden():
    model = model_with_index_sets(MICRO_DOC, "PointInRect")
    vi = materialize_value_invention(model, const_arrays=micro_const_arrays())
    assert vi.members["cells_with_points"] == [1, 2], (
        "point-in-rect micro support set must equal the Julia golden [1,2]"
    )
    assert vi.extents["cells_with_points"] == 2


# --------------------------------------------------------------------------- #
# Broad-phase contract (§5.5.6): closed predicate, eps monotonicity, arity
# --------------------------------------------------------------------------- #


def test_broad_phase_predicate_is_closed():
    """Edge-touching boxes ARE candidates (the per-axis predicate is <=, not <)."""
    a = [(0.0, 0.0, 1.0, 1.0)]
    b = [(1.0, 0.0, 2.0, 1.0)]  # shares the x=1 edge
    assert broad_phase.broad_phase_candidates(a, b) == [(1, 1)]


def test_broad_phase_eps_is_monotone():
    """candidates(eps=d) is a superset of candidates(eps=0) for d >= 0, and eps
    inflates BOTH envelopes outward (a gap of 1.0 closes at eps=0.5)."""
    a = [(0.0, 0.0, 1.0, 1.0)]
    b = [(2.0, 0.0, 3.0, 1.0)]  # 1.0 gap in x
    assert broad_phase.broad_phase_candidates(a, b, eps=0.0) == []
    assert broad_phase.broad_phase_candidates(a, b, eps=0.49) == []
    assert broad_phase.broad_phase_candidates(a, b, eps=0.5) == [(1, 1)]
    base = set(broad_phase.broad_phase_candidates(a, b, eps=0.0))
    assert base <= set(broad_phase.broad_phase_candidates(a, b, eps=1.0))


def test_broad_phase_empty_side_yields_no_candidates():
    assert broad_phase.broad_phase_candidates([], [(0.0, 0.0, 1.0, 1.0)]) == []
    assert broad_phase.broad_phase_candidates([(0.0, 0.0, 1.0, 1.0)], []) == []


def test_envelope_arity_two_is_a_degenerate_point_envelope():
    g = {"X": np.array([1.0, 2.0]), "Y": np.array([3.0, 4.0])}
    envs = broad_phase.envelope_vectors(["X", "Y"], g)
    assert envs.tolist() == [[1.0, 3.0, 1.0, 3.0], [2.0, 4.0, 2.0, 4.0]]


def test_envelope_arity_one_is_a_ring_bbox():
    # one position, a triangle ring [pos, verts, coord]
    rings = np.array([[[0.0, 0.0], [3.0, 1.0], [1.0, 4.0]]])
    envs = broad_phase.envelope_vectors_from_cols(["ring"], [rings])
    assert envs.tolist() == [[0.0, 0.0, 3.0, 4.0]]


def test_envelope_arity_three_is_rejected():
    with pytest.raises(broad_phase.BroadPhaseError, match="1 \\(rings\\), 2 .*or 4"):
        broad_phase.envelope_vectors_from_cols(["A", "B", "C"], [[1.0], [2.0], [3.0]])


def test_missing_envelope_factor_is_a_named_error():
    with pytest.raises(broad_phase.BroadPhaseError, match="not bound in const_arrays"):
        broad_phase.envelope_vectors(["X", "Y"], {"X": np.array([1.0])})


def test_negative_eps_is_rejected():
    """eps inflates OUTWARD and must grow the candidate set monotonically; a
    negative value would shrink it and break the conservativeness guarantee."""
    doc = json.loads(json.dumps(MICRO_DOC))
    doc["models"]["PointInRect"]["equations"][0]["rhs"]["join"][0]["overlap"]["eps"] = -1.0
    model = model_with_index_sets(doc, "PointInRect")
    with pytest.raises(ValueInventionError, match="eps must be >= 0"):
        materialize_value_invention(model, const_arrays=micro_const_arrays())


def test_clause_with_both_on_and_overlap_is_rejected():
    doc = json.loads(json.dumps(MICRO_DOC))
    doc["models"]["PointInRect"]["equations"][0]["rhs"]["join"][0]["on"] = [["X", "W"]]
    model = model_with_index_sets(doc, "PointInRect")
    with pytest.raises(ValueInventionError, match="not both"):
        materialize_value_invention(model, const_arrays=micro_const_arrays())
