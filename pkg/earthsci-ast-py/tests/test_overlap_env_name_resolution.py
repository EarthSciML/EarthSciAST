"""Overlap-gate envelope-factor NAME resolution (§5.5.6).

An ``join.overlap`` clause names its envelope factors with the name the AUTHOR
wrote (``src_W``), while a flattened build keys every array under its owning
component (``ISRM.src_W``). Resolution is by dot-suffix — and SEVERAL suffix
matches are not automatically an ambiguity, which is what these tests pin.

The live defect: the projection-pushdown rewrite's MIRROR arm (a per-record
binning aggregate ``P[r] = Σ_c [contains(cell_c, pt_r)]·f(c)``) deliberately
keeps the document's OWN full-grid rect factors — its cell axis is not
re-pointed onto the compact ``pd_cell__*`` gathers the forward arm gets. When
the document ALSO declares those rects on a data loader, the coupling publishes
one array under two names (``ISRM_Grid.src_W`` and ``ISRM.src_W``, the same
object by reference), and a plain-uniqueness rule then reported a factor that is
bound TWICE as "not bound as build-time const-array data" — dropping the mirror
and every observed downstream of it. isrm.esm is exactly that shape.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import numpy as np
import pytest

from earthsci_ast.numpy_interpreter import _same_binding, _scoped_array_name
from earthsci_ast.prepare import observed_field, prepare
from earthsci_ast.simulation_array import BuildInspection

from test_prepare_pushdown import (  # noqa: F401 — `oracle` is a fixture
    LVARS,
    MockConst,
    MockGated,
    _FIXTURE,
    oracle,
)


# --------------------------------------------------------------------------- #
# The rule, stated directly.
# --------------------------------------------------------------------------- #
def test_scoped_array_name_exact_match_wins():
    a, b = np.arange(3.0), np.arange(3.0)
    reg = {"src_W": a, "ISRM.src_W": b}
    assert _scoped_array_name("src_W", reg) == "src_W"


def test_scoped_array_name_unique_suffix_binds():
    reg = {"ISRM.src_W": np.arange(3.0), "ISRM.src_S": np.arange(3.0)}
    assert _scoped_array_name("src_W", reg) == "ISRM.src_W"


def test_scoped_array_name_one_array_two_names_is_not_ambiguous():
    """THE REGRESSION. A coupling `variable_map` surfaces one loader array under
    both the loader key and the consuming model's name, by REFERENCE. Two keys
    naming one object are one binding, not a conflict."""
    shared = np.array([1.0, 2.0, 3.0])
    reg = {"ISRM_Grid.src_W": shared, "ISRM.src_W": shared}
    key = _scoped_array_name("src_W", reg)
    assert key is not None
    assert reg[key] is shared


def test_scoped_array_name_two_different_arrays_stay_ambiguous():
    """The fail-closed half: same depth, DIFFERENT arrays is a real ambiguity
    and must still return None so the caller raises its named error."""
    reg = {"A.src_W": np.array([1.0]), "B.src_W": np.array([2.0])}
    assert _scoped_array_name("src_W", reg) is None


def test_scoped_array_name_shallowest_scope_wins():
    """A name written inside a model means that model's variable, not a nested
    one that happens to share a tail."""
    outer, inner = np.array([1.0]), np.array([2.0])
    reg = {"ISRM.src_W": outer, "ISRM.Sub.src_W": inner}
    assert _scoped_array_name("src_W", reg) == "ISRM.src_W"


def test_same_binding_is_identity_for_arrays_and_equality_otherwise():
    a = np.array([1.0, 2.0])
    b = np.array([1.0, 2.0])
    assert _same_binding(a, a)
    # Equal CONTENTS are not one binding: name resolution must not depend on data.
    assert not _same_binding(a, b)
    # A declared shape is a list of index-set names; two spellings of one
    # variable declare one shape.
    assert _same_binding(["src_cells"], ["src_cells"])
    assert not _same_binding(["src_cells"], ["rcv_cells"])


# --------------------------------------------------------------------------- #
# End to end: the isrm.esm shape, through the public `prepare` surface.
# --------------------------------------------------------------------------- #
def _definition(model: dict, name: str) -> dict:
    """The right-hand side of ``name``'s defining equation — where esm 1.0.0
    keeps what 0.x wrote in ``variables[name]["expression"]`` (esm-spec §6.3.1)."""
    for eq in model["equations"]:
        if eq.get("lhs") == name:
            return eq["rhs"]
    raise KeyError(f"{name} has no defining equation")


def _add_mirror_observed(doc: dict, name: str = "rec_cell_W") -> None:
    """Give ``doc`` a MIRRORED per-record binning aggregate built from its own
    forward binner: same containment predicate, same two ranges, but reduced
    over the CELL axis with the RECORD axis as output. Its value factor is
    cell-indexed (``src_W[c]``), so it is the "which cell am I in" read that
    isrm.esm's ``stack_layer`` performs — and, being a mirror, it keeps the
    document's own full-grid rect factors as its gate envelopes."""
    model = doc["models"]["ISRM"]
    agg = copy.deepcopy(_definition(model, "E_VOC"))
    agg["output_idx"] = ["r"]
    pred = agg["expr"]["args"][0]  # the ifelse carrying the containment
    agg["expr"] = {"op": "*", "args": [pred, {"op": "index", "args": ["src_W", "c"]}]}
    agg["args"] = ["src_W", "src_S", "src_E", "src_N", "X", "Y"]
    model["variables"][name] = {
        "type": "unknown",
        "units": "m",
        "shape": ["emis_records"],
    }
    model["equations"].append({"lhs": name, "rhs": agg})


@pytest.mark.parametrize("rect_keys", [("ISRM.{}",), ("MockGrid.{}", "ISRM.{}")])
def test_mirror_arm_resolves_its_envelope_factors(oracle, rect_keys):  # noqa: F811
    """The mirrored aggregate must resolve ``src_W``… whether the rects reach the
    build under ONE namespaced key or under TWO aliasing the same array.

    The two-key case is isrm.esm's: the rects are a loader's variables AND the
    model's parameters, so ``_inject_pushdown_aliases`` publishes one object
    under both names. Before the fix this raised "join 'overlap' envelope factor
    'src_W' is not bound as build-time const-array data" and the tolerant hoist
    dropped the mirror plus every observed downstream of it.
    """
    doc = json.loads(_FIXTURE.read_text())
    _add_mirror_observed(doc)

    rects = {"src_W": oracle["W"], "src_S": oracle["S"], "src_E": oracle["E"], "src_N": oracle["N"]}
    ca: dict[str, np.ndarray] = {}
    for bare, arr in rects.items():
        arr = np.asarray(arr, dtype=float)  # ONE object, published under each key
        for tmpl in rect_keys:
            ca[tmpl.format(bare)] = arr

    providers = {
        "MockSR.TotalPop": MockConst(oracle["total_pop"]),
        "MockSR.MortalityRate": MockConst(oracle["mortality"]),
        "MockPts.lon": MockConst(oracle["lon"]),
        "MockPts.lat": MockConst(oracle["lat"]),
        "MockPts.annual": MockConst(oracle["emis_annual"]),
        "MockPts.vVOC": MockConst(oracle["masks"]["SOA"]),
        "MockPts.vNOx": MockConst(oracle["masks"]["pNO3"]),
        "MockPts.vNH3": MockConst(oracle["masks"]["pNH4"]),
        "MockPts.vSOx": MockConst(oracle["masks"]["pSO4"]),
        "MockPts.vPM25": MockConst(oracle["masks"]["PrimaryPM25"]),
    }
    for v in LVARS:
        providers[f"MockSR.{v}"] = MockGated(oracle["full_sr"][v])

    insp = BuildInspection()
    prep = prepare(
        doc, providers=providers, const_arrays=ca, inspect=insp, pushdown_rewrite=True
    )

    # Nothing was dropped by the tolerant hoist.
    assert not getattr(prep.build, "static_skip_reasons", {})

    # The mirror's own answer: the W bound of the cell each record falls in,
    # 0 for a record outside every cell (the semiring identity).
    W, S, E, N = oracle["W"], oracle["S"], oracle["E"], oracle["N"]
    # The record coordinates the model itself projected — the same X/Y the
    # mirror's own containment reads, so this pins the GATHER, not the LCC.
    px = np.asarray(observed_field(prep, "X"))
    py = np.asarray(observed_field(prep, "Y"))
    want = np.array(
        [
            sum(W[c] for c in range(len(W)) if W[c] <= px[r] < E[c] and S[c] <= py[r] < N[c])
            for r in range(len(px))
        ]
    )
    np.testing.assert_allclose(observed_field(prep, "rec_cell_W"), want)

    # The forward arm is untouched by the mirror riding alongside it.
    np.testing.assert_allclose(
        observed_field(prep, "E_VOC"), oracle["oracle_E"](oracle["masks"]["SOA"])
    )
    np.testing.assert_allclose(observed_field(prep, "deathsK"), oracle["oracle_deaths"](1.06))
