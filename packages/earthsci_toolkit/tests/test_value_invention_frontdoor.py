"""Value-invention evaluator front-door — Python binding (bead ess-3lj.2, F2).

Port-parity counterpart of the Julia reference test
``value_invention_frontdoor_test.jl`` (F1, ess-3lj.1). RFC
``semiring-faq-unified-ir`` §6.1 (cadence-partition) / §5.5 (determinism) /
§7.3 (edge enumeration); ``CONFORMANCE_SPEC.md`` §5.5 / §5.7.

The front-door replaces the ``numpy_interpreter`` "derived index set … is not
materialized" raise (the analog of Julia's ``E_TREEWALK_DERIVED_INDEX_SET``): a
``kind:"derived"`` index set whose ``from_faq`` names a value-invention aggregate
(skolem/distinct/rank) is materialized ONCE at setup through the relational
engine and its cardinality handed to the index-set resolver as the dense extent
``[1, n]`` — generalizing the geometry clip-ring handoff to the relational
engine.

Two proof cases, both **byte-identical to the landed M3 goldens** — the SAME
canonical index-set JSON the Julia and Rust bindings assert, which is what makes
the value-invention .esm run end-to-end byte-identical across all three:
  (1) the §7.3 edge-enumeration .esm — ``edges`` materializes to the determinism
      golden ``[[1,2],[1,3],[2,3],[2,4],[3,4]]``;
  (2) the conservative-regridder overlap-join .esm — ``candidate_pairs``
      materializes via the bin-Skolem equi-join to ``[[1,1],[2,2],[3,3]]``.
"""

from __future__ import annotations

import json
import numpy as np
import pytest
from conftest import REPO_ROOT

from earthsci_toolkit import relational
from earthsci_toolkit.numpy_interpreter import (
    EvalContext,
    NumpyInterpreterError,
    _resolve_range_spec,
)
from earthsci_toolkit.value_invention import (
    ValueInventionError,
    materialize_value_invention,
)

# The shared M3 goldens — the byte-for-byte canonical index-set JSON every
# binding (Julia / Rust / Python) must reproduce. Byte-identity to these IS the
# cross-binding conformance contract (§5.5.3).
EDGE_GOLDEN = "[[1,2],[1,3],[2,3],[2,4],[3,4]]"
CANDIDATE_GOLDEN = "[[1,1],[2,2],[3,3]]"


def _load_model(rel: str, model_name: str) -> dict:
    doc = json.loads((REPO_ROOT / rel).read_text())
    model = doc["models"][model_name]
    # index_sets is document-scoped (v0.8.0): it lives at the top level of the
    # document, not on the model. Thread the shared registry into the raw model
    # dict the value-invention engine / range resolver operate on.
    if "index_sets" in doc and "index_sets" not in model:
        model = {**model, "index_sets": doc["index_sets"]}
    return model


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


# --------------------------------------------------------------------------- #
# (1) edge-enumeration: the relational front-door materializes the derived set
# --------------------------------------------------------------------------- #


def test_edge_enumeration_materializes_to_m3_golden() -> None:
    mj = _load_model(
        "tests/valid/aggregate/edge_enumeration_area_eff.esm", "EdgeEnumerationAreaEff"
    )
    # Canonical 2-triangle mesh connectivity (the ragged face_vertices factors).
    ca = {
        "n_verts_on_face": np.array([3.0, 3.0]),
        "verts_on_face": np.array([[1.0, 2.0, 3.0], [2.0, 3.0, 4.0]]),
        "n_edges_on_cell": np.array([3.0, 3.0]),
        "edges_on_cell": np.array([[1.0, 2.0, 3.0], [3.0, 4.0, 5.0]]),
        "dc": np.array([2.0, 3.0, 5.0, 7.0, 11.0]),
        "dv": np.array([13.0, 17.0, 19.0, 23.0, 29.0]),
    }
    vi = materialize_value_invention(mj, ca, {})

    # The derived `edges` set materializes via the relational engine,
    # BYTE-IDENTICAL to the M3 determinism golden.
    assert vi.extents["edge_set"] == 5
    assert vi.members["edge_set"] == [(1, 2), (1, 3), (2, 3), (2, 4), (3, 4)]
    assert relational.canonical_index_set_json(vi.members["edge_set"]) == EDGE_GOLDEN
    # the skolem/rank LHS vars are dropped from the ODE (materialized at setup).
    assert vi.vi_var_names == {"edge_exists", "edge_dense_id"}


def test_edge_enumeration_adversarial_inputs_collapse_to_golden() -> None:
    """§5.5.4: permuted faces / reversed winding all yield the identical
    canonically-sorted edge set (the relational engine's job)."""
    mj = _load_model(
        "tests/valid/aggregate/edge_enumeration_area_eff.esm", "EdgeEnumerationAreaEff"
    )
    base = {
        "n_verts_on_face": np.array([3.0, 3.0]),
        "verts_on_face": np.array([[1.0, 2.0, 3.0], [2.0, 3.0, 4.0]]),
    }
    # reversed winding of each face (same undirected edges)
    rev = {
        "n_verts_on_face": np.array([3.0, 3.0]),
        "verts_on_face": np.array([[3.0, 2.0, 1.0], [4.0, 3.0, 2.0]]),
    }
    for ca in (base, rev):
        vi = materialize_value_invention(mj, ca, {})
        assert relational.canonical_index_set_json(vi.members["edge_set"]) == EDGE_GOLDEN


# --------------------------------------------------------------------------- #
# (2) regridder: candidate_pairs = bin-Skolem equi-join (§A.8 broad phase)
# --------------------------------------------------------------------------- #


def test_regridder_candidate_set_bin_skolem_equijoin() -> None:
    mj = _load_model(
        "tests/valid/geometry/conservative_regrid_overlap_join.esm", "ConservativeRegridOverlapJoin"
    )
    params = {"dx": 1.0, "dy": 1.0, "atol": 1e-12}

    # Aligned grids: src/tgt cell i share bin (i-1, 0) ⇒ candidate set is the
    # diagonal {(1,1),(2,2),(3,3)}.
    aligned = {
        "src_lon": np.array([0.2, 1.2, 2.2]),
        "src_lat": np.array([0.0, 0.0, 0.0]),
        "tgt_lon": np.array([0.2, 1.2, 2.2]),
        "tgt_lat": np.array([0.0, 0.0, 0.0]),
    }
    vi = materialize_value_invention(mj, aligned, params)
    assert vi.members["candidate_set"] == [(1, 1), (2, 2), (3, 3)]
    assert vi.extents["candidate_set"] == 3
    assert relational.canonical_index_set_json(vi.members["candidate_set"]) == CANDIDATE_GOLDEN
    assert vi.vi_var_names == {"src_bin", "tgt_bin", "pair_exists"}

    # Shifted target grid: only the overlapping bins join (the broad phase is
    # load-bearing — it is NOT the full cross product).
    shifted = {
        "src_lon": np.array([0.2, 1.2, 2.2]),
        "src_lat": np.array([0.0, 0.0, 0.0]),
        "tgt_lon": np.array([1.2, 2.2, 9.9]),
        "tgt_lat": np.array([0.0, 0.0, 0.0]),
    }
    vi2 = materialize_value_invention(mj, shifted, params)
    assert vi2.members["candidate_set"] == [(2, 1), (3, 2)]

    # Permuting the cell order must NOT change the canonical candidate set
    # (order-independence, §5.5 rule 2).
    assert (
        materialize_value_invention(mj, aligned, params).members["candidate_set"]
        == materialize_value_invention(mj, aligned, params).members["candidate_set"]
    )


# --------------------------------------------------------------------------- #
# (3) evaluator integration: the resolver resolves the derived set via the
#     materialized extent (replacing the "not materialized" raise)
# --------------------------------------------------------------------------- #


def test_resolver_resolves_derived_set_via_value_invention_extent() -> None:
    mj = _load_model(
        "tests/valid/aggregate/edge_enumeration_area_eff.esm", "EdgeEnumerationAreaEff"
    )
    ca = {
        "n_verts_on_face": np.array([3.0, 3.0]),
        "verts_on_face": np.array([[1.0, 2.0, 3.0], [2.0, 3.0, 4.0]]),
    }
    vi = materialize_value_invention(mj, ca, {})

    # The front-door injects the producer cardinality keyed by `from_faq` id.
    ctx = _empty_ctx(index_sets=mj["index_sets"], derived_extents=vi.extents)
    # The `edges` derived set (from_faq:"edge_set") now resolves to the dense
    # extent [1, 5] — the resolver no longer raises "not materialized".
    assert _resolve_range_spec({"from": "edges"}, ctx) == [1, 5]


def test_resolver_still_raises_without_materialization() -> None:
    """Sanity: a derived set whose producer was never materialized still raises
    (the geometry clip-ring path is untouched, and a typo cannot silently become
    an empty set)."""
    mj = _load_model(
        "tests/valid/aggregate/edge_enumeration_area_eff.esm", "EdgeEnumerationAreaEff"
    )
    ctx = _empty_ctx(index_sets=mj["index_sets"], derived_extents={})
    with pytest.raises(NumpyInterpreterError, match="not materialized"):
        _resolve_range_spec({"from": "edges"}, ctx)


# --------------------------------------------------------------------------- #
# (4) guards & no-op
# --------------------------------------------------------------------------- #


def test_continuous_relational_node_is_rejected() -> None:
    """§5.7 guard 2: a distinct producer whose key reads a genuine state variable
    classifies CONTINUOUS and must be refused — the relational engine may not run
    per step."""
    model = {
        "index_sets": {
            "items": {"kind": "interval", "size": 2},
            "tags": {"kind": "derived", "from_faq": "tag_set"},
        },
        "variables": {
            "u": {"type": "state", "shape": ["items"]},
            "tag": {"type": "state", "shape": ["tags"]},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["tag", "p"]},
                "rhs": {
                    "op": "aggregate",
                    "id": "tag_set",
                    "semiring": "bool_and_or",
                    "distinct": True,
                    "output_idx": ["p"],
                    "ranges": {"i": {"from": "items"}},
                    # key reads the continuous state `u` ⇒ CONTINUOUS
                    "key": {"op": "skolem", "args": ["t", {"op": "index", "args": ["u", "i"]}]},
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
        "variables": {"x": {"type": "state", "shape": []}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": -1.0}],
    }
    vi = materialize_value_invention(plain, {}, {})
    assert not vi.extents
    assert not vi.vi_var_names
    assert not vi.assignments


# --------------------------------------------------------------------------- #
# (5) arg-witness reducer (bead ess-os1, §5.7 rule 6) — the integer
#     nearest-generator INDEX buffer, byte-identical to the Julia / Rust
#     port-parity tests: the SAME coordinate factors → the SAME buffer.
# --------------------------------------------------------------------------- #

ARGMIN_REL = "tests/valid/aggregate/nearest_generator_argmin.esm"


def test_argmin_nearest_generator_smallest_id_tiebreak() -> None:
    mj = _load_model(ARGMIN_REL, "NearestGeneratorArgmin")
    # Generators on the x-axis at 0,1,2; point 3 (1.5,0) is EXACTLY 0.25 from
    # generators 2 (1.0) and 3 (2.0) — the deliberate equidistant tie.
    ca = {
        "gx": np.array([0.0, 1.0, 2.0]),
        "gy": np.array([0.0, 0.0, 0.0]),
        "px": np.array([0.0, 1.0, 1.5, 2.0]),
        "py": np.array([0.0, 0.5, 0.0, 0.0]),
    }
    vi = materialize_value_invention(mj, ca, {})
    # 1-based nearest-generator ids; the tie at point 3 resolves to the SMALLER id (2).
    assert vi.assignments["assign"] == [1, 2, 2, 3]
    assert vi.vi_var_names == {"assign"}
    assert not vi.extents
    # pure function of inputs — re-running is identical.
    assert materialize_value_invention(mj, ca, {}).assignments["assign"] == [1, 2, 2, 3]


def test_argmin_binned_same_bin_candidate_join() -> None:
    """The argmin's bin-Skolem `join` restricts each point's candidates to its
    bin (the SCVT broad phase, §5.3)."""
    mj = _load_model(ARGMIN_REL, "NearestGeneratorBinned")
    # binw=1 ⇒ each point's join keeps only its same-bin generator → [1,2,3,2].
    ca = {
        "gx": np.array([0.0, 1.0, 2.0]),
        "gy": np.array([0.0, 0.0, 0.0]),
        "px": np.array([0.1, 1.1, 2.1, 1.9]),
        "py": np.array([0.0, 0.0, 0.0, 0.0]),
    }
    vi = materialize_value_invention(mj, ca, {"binw": 1.0})
    assert vi.assignments["assign_binned"] == [1, 2, 3, 2]
    assert vi.vi_var_names == {"point_bin", "gen_bin", "assign_binned"}


def test_argmax_farthest_generator_smallest_id_tiebreak() -> None:
    """Mirror op: argmax keeps the GREATEST distance. Point 2 (1.0) is dist 1
    from both generator 1 (0.0) and generator 3 (2.0) → tie to the SMALLER id."""
    model = {
        "index_sets": {
            "points": {"kind": "interval", "size": 2},
            "generators": {"kind": "interval", "size": 3},
        },
        "variables": {
            "gx": {"type": "parameter", "shape": ["generators"]},
            "px": {"type": "parameter", "shape": ["points"]},
            "far": {"type": "state", "shape": ["points"]},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["far", "i"]},
                "rhs": {
                    "op": "aggregate",
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {
                        "op": "argmax",
                        "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "expr": {
                            "op": "*",
                            "args": [
                                {
                                    "op": "-",
                                    "args": [
                                        {"op": "index", "args": ["px", "i"]},
                                        {"op": "index", "args": ["gx", "g"]},
                                    ],
                                },
                                {
                                    "op": "-",
                                    "args": [
                                        {"op": "index", "args": ["px", "i"]},
                                        {"op": "index", "args": ["gx", "g"]},
                                    ],
                                },
                            ],
                        },
                    },
                },
            }
        ],
    }
    ca = {"gx": np.array([0.0, 1.0, 2.0]), "px": np.array([0.0, 1.0])}
    vi = materialize_value_invention(model, ca, {})
    assert vi.assignments["far"] == [3, 1]


def test_argmin_empty_candidate_set_is_error() -> None:
    """A filter that excludes every candidate leaves the argmin undefined."""
    model = {
        "index_sets": {
            "points": {"kind": "interval", "size": 1},
            "generators": {"kind": "interval", "size": 2},
        },
        "variables": {
            "gx": {"type": "parameter", "shape": ["generators"]},
            "px": {"type": "parameter", "shape": ["points"]},
            "assign": {"type": "state", "shape": ["points"]},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["assign", "i"]},
                "rhs": {
                    "op": "aggregate",
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {
                        "op": "argmin",
                        "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "filter": {"op": "false", "args": []},
                        "expr": {
                            "op": "*",
                            "args": [
                                {"op": "index", "args": ["gx", "g"]},
                                {"op": "index", "args": ["gx", "g"]},
                            ],
                        },
                    },
                },
            }
        ],
    }
    with pytest.raises(ValueInventionError):
        materialize_value_invention(model, {"gx": np.array([0.0, 1.0]), "px": np.array([0.5])}, {})


def test_argmin_continuous_assignment_is_rejected() -> None:
    """§5.7 guard 2: an argmin whose distance reads a genuine `state` coordinate
    classifies CONTINUOUS — a per-step assignment is out of scope for v1."""
    model = {
        "index_sets": {
            "points": {"kind": "interval", "size": 1},
            "generators": {"kind": "interval", "size": 2},
        },
        "variables": {
            "gx": {"type": "state", "shape": ["generators"]},
            "px": {"type": "parameter", "shape": ["points"]},
            "assign": {"type": "state", "shape": ["points"]},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["assign", "i"]},
                "rhs": {
                    "op": "aggregate",
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "expr": {
                        "op": "argmin",
                        "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "expr": {
                            "op": "*",
                            "args": [
                                {"op": "index", "args": ["gx", "g"]},
                                {"op": "index", "args": ["gx", "g"]},
                            ],
                        },
                    },
                },
            }
        ],
    }
    with pytest.raises(ValueInventionError):
        materialize_value_invention(model, {"gx": np.array([0.0, 1.0]), "px": np.array([0.5])}, {})


# --------------------------------------------------------------------------- #
# Grouped-aggregate centroid front-door (bead ess-2u5, mpas-scvt)
# --------------------------------------------------------------------------- #
# RFC semiring-faq-unified-ir §5.5 rule 5 (group-by aggregate) + §5.7 rule 6.
# The SCVT centroid-update STEP: a grouped `sum_product` reduction whose group KEY
# is the data-dependent argmin assignment buffer (E1, ess-os1). The FIRST time the
# value-invention front-door drives `relational.group_aggregate` (previously a
# library helper only). The fixture factors here are IDENTICAL to the Julia / Rust
# port-parity tests — agreement on num / den / centroid IS the conformance proof.

CENTROID_REL = "tests/valid/aggregate/nearest_generator_centroid.esm"


def test_centroid_group_aggregate_over_argmin_key() -> None:
    mj = _load_model(CENTROID_REL, "NearestGeneratorCentroid")
    # Generators at 0,1,2; points at 0,0.75,1.25,2.0 (exact dyadics, no ties) ⇒
    # assign = [1,2,2,3]; density rho = [1,1,3,4]. Generator 2 owns points 2,3 ⇒
    # centroid 4.5/4 = 1.125 (moved from its seed at 1.0).
    ca = {
        "gx": np.array([0.0, 1.0, 2.0]),
        "px": np.array([0.0, 0.75, 1.25, 2.0]),
        "rho": np.array([1.0, 1.0, 3.0, 4.0]),
    }
    vi = materialize_value_invention(mj, ca, {})
    # The argmin group key (E1) — byte-identical integer buffer.
    assert vi.assignments["assign"] == [1, 2, 2, 3]
    # The grouped sum_product buffers — bit-exact (exact-dyadic inputs).
    assert vi.groups["num"] == [0.0, 4.5, 8.0]
    assert vi.groups["den"] == [1.0, 4.0, 4.0]
    # The derived centroid buffer — the next Lloyd / SCVT generator positions.
    assert vi.groups["centroid"] == [0.0, 1.125, 2.0]
    # assign + the three grouped/derived buffers all leave the ODE (build-time).
    assert vi.vi_var_names == {"assign", "num", "den", "centroid"}
    # Pure function of inputs — re-running is identical.
    assert materialize_value_invention(mj, ca, {}).groups["centroid"] == [0.0, 1.125, 2.0]


def test_centroid_empty_group_folds_to_zerobar() -> None:
    """Generators with no assigned point fold to the empty-⊕ identity 0; the
    centroid 0/0 is NaN (an unattended generator — the caller keeps the old seed)."""
    mj = _load_model(CENTROID_REL, "NearestGeneratorCentroid")
    ca = {
        "gx": np.array([0.0, 1.0, 2.0]),
        "px": np.array([0.0, 0.1, 0.2, 0.3]),
        "rho": np.array([2.0, 1.0, 1.0, 1.0]),
    }
    vi = materialize_value_invention(mj, ca, {})
    assert vi.assignments["assign"] == [1, 1, 1, 1]
    assert vi.groups["den"] == [5.0, 0.0, 0.0]  # 0̄ for the empty groups
    assert vi.groups["num"][1] == 0.0 and vi.groups["num"][2] == 0.0
    assert np.isnan(vi.groups["centroid"][1]) and np.isnan(vi.groups["centroid"][2])


def test_regridder_aggregates_are_not_grouped_value_invention() -> None:
    """Regression guard (ess-2u5): the conservative regridder's `A_j` joins two bin
    buffers to EACH OTHER (neither to its output index `j`) and `mass_tgt` is a
    scalar reduction — neither is the SCVT grouped/derived centroid shape, so the
    chain must stay empty and they remain on the simulate path."""
    mj = _load_model(
        "tests/valid/geometry/conservative_regrid_overlap_join.esm", "ConservativeRegridOverlapJoin"
    )
    params = {"dx": 1.0, "dy": 1.0, "atol": 1e-12}
    aligned = {
        "src_lon": np.array([0.2, 1.2, 2.2]),
        "src_lat": np.array([0.0, 0.0, 0.0]),
        "tgt_lon": np.array([0.2, 1.2, 2.2]),
        "tgt_lat": np.array([0.0, 0.0, 0.0]),
    }
    vi = materialize_value_invention(mj, aligned, params)
    assert not vi.groups, "regridder must mint no grouped buffers"
    assert "A_j" not in vi.vi_var_names
    assert "mass_tgt" not in vi.vi_var_names


def test_centroid_grouped_reduction_reading_state_is_rejected() -> None:
    """§5.7 guard 2: `rho` retyped to `state` ⇒ the grouped numerator reads a
    hot-path quantity; a build-time reduction's inputs must be CONST/DISCRETE."""
    model = {
        "index_sets": {
            "points": {"kind": "interval", "size": 2},
            "generators": {"kind": "interval", "size": 1},
        },
        "variables": {
            "gx": {"type": "parameter", "shape": ["generators"]},
            "px": {"type": "parameter", "shape": ["points"]},
            "rho": {"type": "state", "shape": ["points"]},
            "assign": {"type": "state", "shape": ["points"]},
            "num": {"type": "state", "shape": ["generators"]},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["assign", "i"]},
                "rhs": {
                    "op": "aggregate",
                    "output_idx": ["i"],
                    "ranges": {"i": {"from": "points"}},
                    "args": ["px", "gx"],
                    "expr": {
                        "op": "argmin",
                        "args": ["px", "gx"],
                        "arg": "g",
                        "ranges": {"g": {"from": "generators"}},
                        "expr": {
                            "op": "*",
                            "args": [
                                {
                                    "op": "-",
                                    "args": [
                                        {"op": "index", "args": ["px", "i"]},
                                        {"op": "index", "args": ["gx", "g"]},
                                    ],
                                },
                                {
                                    "op": "-",
                                    "args": [
                                        {"op": "index", "args": ["px", "i"]},
                                        {"op": "index", "args": ["gx", "g"]},
                                    ],
                                },
                            ],
                        },
                    },
                },
            },
            {
                "lhs": {"op": "index", "args": ["num", "g"]},
                "rhs": {
                    "op": "aggregate",
                    "output_idx": ["g"],
                    "ranges": {"g": {"from": "generators"}, "p": {"from": "points"}},
                    "semiring": "sum_product",
                    "join": [{"on": [["assign", "g"]]}],
                    "args": ["assign", "rho"],
                    "expr": {"op": "index", "args": ["rho", "p"]},
                },
            },
        ],
    }
    with pytest.raises(ValueInventionError):
        materialize_value_invention(model, {"gx": np.array([0.0]), "px": np.array([0.0, 1.0])}, {})


# ---------------------------------------------------------------------------
# Join-key setup pre-pass: only the bins' dependency closure is materialized
# (a join-free reduction over a join-CARRYING observed must not crash setup)
# ---------------------------------------------------------------------------


def test_join_key_prepass_skips_reductions_over_join_carrying_observeds() -> None:
    """``_materialize_join_key_buffers`` materializes ONLY the join-free
    observeds the broad-phase bins transitively read, not every join-free
    observed. A join-free observed that itself reads a join-CARRYING observed
    (the natural spelling of a reduction like ``total = sum(rg_A)``) is
    unresolvable at bin-setup time — the join-carrying observed is not available
    there. Before the fix the pre-pass evaluated every join-free observed and
    raised ``NumpyInterpreterError`` on such a reduction, forcing the state-RHS
    workaround; now the reduction is skipped here and resolves later in the RHS
    path where the join buffers exist, while the bin buffers are unchanged."""
    from earthsci_toolkit.esm_types import ExprNode
    from earthsci_toolkit.simulation import _materialize_join_key_buffers

    coord = ExprNode(op="const", args=[], value=5.0)  # join-free bin input
    rg_A = ExprNode(
        op="const",
        args=[],
        value=[1.0],  # join-CARRYING observed
        join=[{"on": [["src_bin", "tgt_bin"]]}],
    )
    total = ExprNode(op="+", args=["rg_A", 1.0])  # join-free reduction over rg_A
    ordered = [("coord", coord), ("rg_A", rg_A), ("total", total)]
    bin_specs = [("src_bin", ExprNode(op="+", args=["coord", 1.0]), None)]

    buffers, _idx = _materialize_join_key_buffers(ordered, bin_specs, {}, {}, {}, {}, 0)

    # The bin (which reads `coord`) is materialized correctly; the reduction over
    # the join-carrying observed is NOT evaluated at setup (no crash).
    assert list(buffers["src_bin"]) == [6.0]
    assert "total" not in buffers
