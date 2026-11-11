"""Value-invention evaluator front-door — Python binding (bead ess-3lj.2, F2).

Port-parity counterpart of the Julia reference test
``value_invention_frontdoor_test.jl`` (F1, ess-3lj.1). RFC
``semiring-faq-unified-ir`` §6.1 (cadence-partition) / §5.5 (determinism) /
§7.3 (edge enumeration); ``CONFORMANCE_SPEC.md`` §5.5 / §5.7.

The front-door sizes what the ``numpy_interpreter`` resolver would otherwise refuse
with ``derived_index_set_unmaterialized`` (as the Julia resolver does): a
``kind:"derived"`` index set whose ``from_faq`` names a ``distinct`` aggregate is
materialized ONCE at setup through the relational engine and its cardinality
handed to the index-set resolver as the dense extent ``[1, n]``.

A ``distinct`` key is a scalar integer (the ``pair_key`` / ``edge_key`` templates
of ``lib/relational.esm`` encode a tuple as one). The models here spell the key
inline as ``10 a + b`` so the members read as the edges they encode.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    _resolve_range_spec,
)
from earthsci_ast.simulation_array import _binning_coord_arrays
from earthsci_ast.value_invention import (
    ValueInventionError,
    materialize_value_invention,
)

#: The unique undirected edges of the two-triangle mesh (faces 1-2-3, 2-3-4),
#: each encoded ``10 a + b`` with ``a < b``, in sorted order.
EDGE_KEYS = [12, 13, 23, 24, 34]


def _idx(name: str, *subs) -> dict:
    return {"op": "index", "args": [name, *subs]}


def _edge_model() -> dict:
    """A ``distinct`` producer enumerating each face's vertex pairs ``a < b``
    over the ragged ``face_vertices`` set, keyed ``10 a + b``."""
    index_sets = {
        "faces": {"kind": "interval", "size": 2},
        "face_vertices": {
            "kind": "ragged",
            "of": ["faces"],
            "offsets": "n_verts_on_face",
            "values": "verts_on_face",
        },
        "edges": {"kind": "derived", "from_faq": "edge_set"},
    }
    return {
        "index_sets": index_sets,
        "variables": {
            "n_verts_on_face": {"type": "parameter", "shape": ["faces"]},
            "verts_on_face": {"type": "parameter", "shape": ["faces", "local_verts"]},
            "edge_exists": {"type": "unknown", "shape": ["edges"]},
        },
        "equations": [
            {
                "lhs": _idx("edge_exists", "edge"),
                "rhs": {
                    "op": "faq",
                    "id": "edge_set",
                    "args": ["faces"],
                    "semiring": "bool_and_or",
                    "distinct": True,
                    "output_idx": ["edge"],
                    "ranges": {
                        "f": {"from": "faces"},
                        "a": {"from": "face_vertices", "of": ["f"]},
                        "b": {"from": "face_vertices", "of": ["f"]},
                    },
                    "filter": {"op": "<", "args": ["a", "b"]},
                    "key": {"op": "+", "args": [{"op": "*", "args": [10, "a"]}, "b"]},
                    "expr": {"op": "true", "args": []},
                },
            }
        ],
    }


def _empty_ctx(index_sets: dict, derived_extents: dict) -> EvalContext:
    """A minimal EvalContext for exercising the index-set resolver directly."""
    return EvalContext(
        state_layout={},
        state_shapes={},
        param_values={},
        observed_values={},
        y=np.zeros(0),
        t=0.0,
        index_sets=index_sets,
        derived_extents=derived_extents,
    )


_MESH = {
    "n_verts_on_face": np.array([3.0, 3.0]),
    "verts_on_face": np.array([[1.0, 2.0, 3.0], [2.0, 3.0, 4.0]]),
}


# --------------------------------------------------------------------------- #
# (1) edge-enumeration: the relational front-door materializes the derived set
# --------------------------------------------------------------------------- #


def test_edge_enumeration_materializes_sorted_distinct_keys() -> None:
    vi = materialize_value_invention(_edge_model(), _MESH, {})
    assert vi.extents["edge_set"] == 5
    assert vi.members["edge_set"] == EDGE_KEYS
    # the producer's LHS var is dropped from the ODE (materialized at setup).
    assert vi.vi_var_names == {"edge_exists"}


def test_edge_enumeration_adversarial_inputs_collapse() -> None:
    """§5.5.4: permuted faces / reversed winding all yield the identical
    canonically-sorted edge set (the relational engine's job)."""
    rev = {
        "n_verts_on_face": np.array([3.0, 3.0]),
        "verts_on_face": np.array([[3.0, 2.0, 1.0], [4.0, 3.0, 2.0]]),
    }
    swapped = {
        "n_verts_on_face": np.array([3.0, 3.0]),
        "verts_on_face": np.array([[2.0, 3.0, 4.0], [1.0, 2.0, 3.0]]),
    }
    for ca in (_MESH, rev, swapped):
        assert materialize_value_invention(_edge_model(), ca, {}).members["edge_set"] == EDGE_KEYS


# --------------------------------------------------------------------------- #
# (2) candidate set: an equi-join on integer bin columns (§A.8 broad phase)
# --------------------------------------------------------------------------- #


def _candidate_model() -> dict:
    """``candidate_set = distinct {(i, j) : src_bin[i] == tgt_bin[j]}``, keyed
    ``10 i + j``, with each bin column ``floor(lon / dx)`` a plain per-cell
    ``faq`` the front door materializes for the join."""

    def bin_column(var: str, lon: str, cells: str) -> dict:
        return {
            "lhs": _idx(var, "c"),
            "rhs": {
                "op": "faq",
                "output_idx": ["c"],
                "ranges": {"c": {"from": cells}},
                "expr": {"op": "floor", "args": [{"op": "/", "args": [_idx(lon, "c"), "dx"]}]},
            },
        }

    return {
        "index_sets": {
            "src": {"kind": "interval", "size": 3},
            "tgt": {"kind": "interval", "size": 3},
            "candidates": {"kind": "derived", "from_faq": "candidate_set"},
        },
        "variables": {
            "dx": {"type": "parameter", "default": 1.0},
            "src_lon": {"type": "parameter", "shape": ["src"]},
            "tgt_lon": {"type": "parameter", "shape": ["tgt"]},
            "src_bin": {"type": "unknown", "shape": ["src"]},
            "tgt_bin": {"type": "unknown", "shape": ["tgt"]},
            "pair_exists": {"type": "unknown", "shape": ["candidates"]},
        },
        "equations": [
            bin_column("src_bin", "src_lon", "src"),
            bin_column("tgt_bin", "tgt_lon", "tgt"),
            {
                "lhs": _idx("pair_exists", "p"),
                "rhs": {
                    "op": "faq",
                    "id": "candidate_set",
                    "args": ["src_bin", "tgt_bin"],
                    "semiring": "bool_and_or",
                    "distinct": True,
                    "output_idx": ["p"],
                    "ranges": {"i": {"from": "src"}, "j": {"from": "tgt"}},
                    "join": [{"on": [["src_bin", "tgt_bin"]]}],
                    "key": {"op": "+", "args": [{"op": "*", "args": [10, "i"]}, "j"]},
                    "expr": {"op": "true", "args": []},
                },
            },
        ],
    }


def test_candidate_set_bin_column_equijoin() -> None:
    aligned = {"src_lon": np.array([0.2, 1.2, 2.2]), "tgt_lon": np.array([0.2, 1.2, 2.2])}
    vi = materialize_value_invention(_candidate_model(), aligned, {"dx": 1.0})
    assert vi.members["candidate_set"] == [11, 22, 33]
    assert vi.extents["candidate_set"] == 3
    # The bin columns stay ordinary observeds; only the producer leaves the ODE.
    assert vi.vi_var_names == {"pair_exists"}

    # Shifted target grid: only the overlapping bins join (the broad phase is
    # load-bearing — it is NOT the full cross product).
    shifted = {"src_lon": np.array([0.2, 1.2, 2.2]), "tgt_lon": np.array([1.2, 2.2, 9.9])}
    vi2 = materialize_value_invention(_candidate_model(), shifted, {"dx": 1.0})
    assert vi2.members["candidate_set"] == [21, 32]


def test_nan_key_is_named_out_of_range() -> None:
    """A key that evaluates to NaN is ``value_invention_key_out_of_range``,
    naming the producer (esm-spec §9.6.6)."""
    model = _edge_model()
    model["equations"][0]["rhs"]["key"] = {"op": "/", "args": [0.0, 0.0]}
    with pytest.raises(ValueInventionError) as excinfo:
        materialize_value_invention(model, _MESH, {})
    assert excinfo.value.code == "value_invention_key_out_of_range"
    assert "edge_set" in str(excinfo.value)


# --------------------------------------------------------------------------- #
# (3) evaluator integration: the resolver resolves the derived set via the
#     materialized extent (replacing the "not materialized" raise)
# --------------------------------------------------------------------------- #


def test_resolver_resolves_derived_set_via_value_invention_extent() -> None:
    model = _edge_model()
    vi = materialize_value_invention(model, _MESH, {})
    # The front-door injects the producer cardinality keyed by `from_faq` id.
    ctx = _empty_ctx(index_sets=model["index_sets"], derived_extents=vi.extents)
    assert _resolve_range_spec({"from": "edges"}, ctx) == [1, 5]


def test_resolver_still_raises_without_materialization() -> None:
    """Sanity: a derived set whose producer was never materialized still raises
    (a typo cannot silently become an empty set)."""
    ctx = _empty_ctx(index_sets=_edge_model()["index_sets"], derived_extents={})
    with pytest.raises(
        NumpyInterpreterError, match=r"^derived_index_set_unmaterialized: .*not materialized"
    ):
        _resolve_range_spec({"from": "edges"}, ctx)


# --------------------------------------------------------------------------- #
# (4) guards & no-op
# --------------------------------------------------------------------------- #


def test_continuous_relational_node_is_rejected() -> None:
    """§5.7 guard 2: a distinct producer whose key reads a hot-path unknown
    classifies CONTINUOUS and must be refused — the relational engine may not run
    per step. ``u`` is an unknown that no bare-variable equation defines, so
    §6.3.1 leaves it a SOLVED-FOR quantity and the cadence pass seeds it
    continuous."""
    model = {
        "index_sets": {
            "items": {"kind": "interval", "size": 2},
            "tags": {"kind": "derived", "from_faq": "tag_set"},
        },
        "variables": {
            "u": {"type": "unknown", "shape": ["items"]},
            "tag": {"type": "unknown", "shape": ["tags"]},
        },
        "equations": [
            {
                "lhs": _idx("tag", "p"),
                "rhs": {
                    "op": "faq",
                    "id": "tag_set",
                    "semiring": "bool_and_or",
                    "distinct": True,
                    "output_idx": ["p"],
                    "ranges": {"i": {"from": "items"}},
                    # key reads the continuous state `u` ⇒ CONTINUOUS
                    "key": {"op": "floor", "args": [_idx("u", "i")]},
                    "expr": {"op": "true", "args": []},
                },
            }
        ],
    }
    with pytest.raises(ValueInventionError):
        materialize_value_invention(model, {"u": np.array([1.0, 2.0])}, {})


def test_no_op_for_plain_model() -> None:
    """A model with no value-invention node returns empty results, so a plain
    model flows through the evaluator byte-identically."""
    plain = {
        "variables": {"x": {"type": "unknown", "shape": []}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": -1.0}],
    }
    vi = materialize_value_invention(plain, {}, {})
    assert not vi.extents
    assert not vi.members
    assert not vi.vi_var_names


# ---------------------------------------------------------------------------
# Producer setup pre-pass: only the producers' dependency closure is
# materialized (a join-free reduction over a join-carrying observed must not
# crash setup)
# ---------------------------------------------------------------------------


def test_producer_prepass_skips_reductions_over_join_carrying_observeds() -> None:
    """The setup pre-pass (:func:`simulation_array._binning_coord_arrays`)
    materializes ONLY the join-free observeds a ``distinct`` producer
    transitively reads, not every join-free observed. A join-free observed that
    itself reads a join-CARRYING observed (``total = sum(rg_A)``) is
    unresolvable at setup time, so it is skipped and resolves later in the RHS
    path, while the producer's own inputs ARE materialized."""
    from earthsci_ast.esm_types import ExprNode

    coord = ExprNode(op="const", args=[], value=5.0)  # join-free producer input
    rg_A = ExprNode(
        op="const",
        args=[],
        value=[1.0],  # join-CARRYING observed
        join=[{"on": [["src_bin", "tgt_bin"]]}],
    )
    total = ExprNode(op="+", args=["rg_A", 1.0])  # join-free reduction over rg_A
    ordered = [("coord", coord), ("rg_A", rg_A), ("total", total)]
    producer = ExprNode(op="+", args=["coord", 1.0])

    coords = _binning_coord_arrays(ordered, {}, {}, {}, {}, 0, producer_seed_nodes=[producer])

    assert float(coords["coord"]) == 5.0
    assert "total" not in coords
    assert "rg_A" not in coords
