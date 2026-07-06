"""Tests for the build-time cadence-partition pass — the dependency-partition
classifier, the two-threshold frontier cut, the guards, and the cross-binding
cadence contract (``CONFORMANCE_SPEC.md`` §5.7 = RFC ``semiring-faq-unified-ir``
§6.1).

The golden is the committed cross-binding manifest
(``tests/conformance/cadence/manifest.json``) — the same one the embedded
reference classifier (``scripts/run-cadence-conformance.py --self-test``) and the
Julia / Rust sibling producers assert on. The Python pass MUST reproduce, for
each §6.1 fixture, every annotated node's class, the materialization-point
threshold multiset, and the byte-identical ``const``-folded buffers.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from conftest import CONFORMANCE_DIR, INVALID_DIR, REPO_ROOT

from earthsci_toolkit.cadence import (
    CadenceError,
    canonical_serialize,
    classify,
    compute_fold,
    fold_edge_enumeration,
    model_from_doc,
    partition,
)

MANIFEST = CONFORMANCE_DIR / "cadence" / "manifest.json"
RUNNER = REPO_ROOT / "scripts" / "run-cadence-conformance.py"
SRC_DIR = Path(__file__).resolve().parents[1] / "src"


def _load_manifest() -> dict:
    with MANIFEST.open() as f:
        return json.load(f)


def _load_model(fixture: dict) -> dict:
    # model_from_doc attaches the document's top-level `data_loaders` so the
    # loader-seeded cadence refinement (§5.7.2) resolves a discrete variable's
    # data_ingest source loader.
    doc = json.loads((REPO_ROOT / fixture["fixture"]).read_text())
    return model_from_doc(doc, fixture["model"])


def _fixtures():
    return _load_manifest()["fixtures"]


def _ids(fx):
    return fx["id"]


# ── classification + materialization vs the golden ──────────────────────────


@pytest.mark.parametrize("fixture", _fixtures(), ids=_ids)
def test_class_summary_matches_golden(fixture):
    """The derived class of every annotated node, tallied, equals the golden
    class summary (the gather rule splits the stencil correctly)."""
    result = partition(_load_model(fixture))
    assert result.class_summary == fixture["class_summary"], fixture["id"]


@pytest.mark.parametrize("fixture", _fixtures(), ids=_ids)
def test_materialization_thresholds_match_golden(fixture):
    """The materialization-point threshold *multiset* (expr-edge cuts +
    output-buffer folds) equals the golden — where the frontier cut fires."""
    result = partition(_load_model(fixture))
    want = sorted(m["threshold"] for m in fixture["materialization_points"])
    assert result.thresholds == want, fixture["id"]


@pytest.mark.parametrize("fixture", _fixtures(), ids=_ids)
def test_hot_tree_and_handler_emptiness_match_golden(fixture):
    """A pure-topology rule has an empty hot tree; a rule with no discrete
    materialization has an empty per-event handler (§5.7.5)."""
    result = partition(_load_model(fixture))
    assert result.hot_tree_empty == fixture["hot_tree_empty"], fixture["id"]
    assert result.event_handler_empty == fixture["event_handler_empty"], fixture["id"]


@pytest.mark.parametrize("fixture", _fixtures(), ids=_ids)
def test_const_fold_buffers_byte_identical(fixture):
    """Each ``const``-folded buffer serialises byte-for-byte to the golden — the
    topology FAQ folded through the real relational engine."""
    const_fold = fixture.get("const_fold") or {}
    inputs = const_fold.get("inputs", {})
    for label, spec in (const_fold.get("expected") or {}).items():
        produced = canonical_serialize(compute_fold(label, spec, inputs))
        assert produced == spec["serialized"], f"{fixture['id']}/{label}"


@pytest.mark.parametrize("fixture", _fixtures(), ids=_ids)
def test_expect_cadence_annotations_agree(fixture):
    """Every fixture's own ``expect_cadence`` assertions agree with the derived
    class — the pass does not raise on a conforming fixture (guard 3)."""
    # ``partition`` runs check_expect_cadence and raises on disagreement.
    partition(_load_model(fixture))


# ── loader-seeded cadence: a DataLoader's `temporal` block drives the seed ───


def test_loader_temporal_seeds_discrete_no_temporal_seeds_const():
    """§5.7.2 / RFC pure-io-data-loaders §4.6: a discrete variable fed by a
    ``data_ingest`` refresh resolves through its source loader's ``temporal``
    block — DISCRETE when the loader is time-varying, CONST (folds at bind) when
    it is not. The SAME variable declaration; only the loader differs."""
    variables = {
        "c": {"type": "state", "shape": ["cells"]},
        "bc": {
            "type": "discrete",
            "shape": ["cells"],
            "refresh": {"kind": "data_ingest", "source": "bc_loader"},
        },
    }
    bc = {"op": "index", "args": ["bc", "i"]}

    with_temporal = {
        "variables": variables,
        "data_loaders": {"bc_loader": {"kind": "grid", "temporal": {"frequency": "PT6H"}}},
    }
    assert classify(bc, with_temporal) == "discrete"

    no_temporal = {
        "variables": variables,
        "data_loaders": {"bc_loader": {"kind": "static"}},
    }
    assert classify(bc, no_temporal) == "const"

    # No loaders attached / unresolvable source → keeps the declared DISCRETE seed.
    assert classify(bc, {"variables": variables}) == "discrete"


def test_model_from_doc_attaches_loaders():
    """model_from_doc lifts the document's top-level ``data_loaders`` onto the
    model so the refinement resolves the source loader — without mutating the
    parsed document."""
    doc = {
        "models": {"M": {"variables": {}, "equations": []}},
        "data_loaders": {"bc_loader": {"kind": "static"}},
    }
    model = model_from_doc(doc, "M")
    assert "bc_loader" in model["data_loaders"]
    assert "data_loaders" not in doc["models"]["M"]  # original document untouched


# ── the adapter: byte-identical to the golden ───────────────────────────────


def test_adapter_matches_golden_manifest():
    """The Python adapter's output equals the committed golden — class summary,
    threshold multiset, and byte-identical ``const`` folds (so it matches the
    reference classifier and, by construction, the Julia / Rust producers)."""
    from earthsci_toolkit.cli.cadence_adapter import _compute_fixture

    for fixture in _fixtures():
        produced = _compute_fixture(fixture, REPO_ROOT)
        assert produced["class_summary"] == fixture["class_summary"], fixture["id"]

        got_thr = sorted(m["threshold"] for m in produced["materialization_points"])
        want_thr = sorted(m["threshold"] for m in fixture["materialization_points"])
        assert got_thr == want_thr, fixture["id"]

        assert produced["hot_tree_empty"] == fixture["hot_tree_empty"], fixture["id"]
        assert produced["event_handler_empty"] == fixture["event_handler_empty"], fixture["id"]

        exp = (fixture.get("const_fold") or {}).get("expected", {})
        for label, spec in exp.items():
            assert produced["const_fold_buffers"][label] == spec["serialized"], (
                f"{fixture['id']}/{label}"
            )


# ── the guards REJECT non-conforming input ──────────────────────────────────


def test_guard_expect_cadence_mismatch_rejected():
    """A wrong ``expect_cadence`` annotation is rejected (guard 3)."""
    manifest = _load_manifest()
    mixed = next(f for f in manifest["fixtures"] if f["id"] == "mixed_stencil")
    model = _load_model(mixed)

    def flip(node) -> bool:
        if isinstance(node, dict):
            if node.get("expect_cadence") == "const":
                node["expect_cadence"] = "continuous"
                return True
            return any(flip(v) for v in node.values())
        if isinstance(node, list):
            return any(flip(v) for v in node)
        return False

    bad = copy.deepcopy(model)
    assert flip(bad), "could not build the negative control"
    with pytest.raises(CadenceError, match="expect_cadence"):
        partition(bad)


def test_guard_continuous_relational_rejected():
    """A state-dependent ``distinct`` that classifies CONTINUOUS is rejected —
    the relational engine may not run on the hot path (guard 2)."""
    bad_model = {
        "variables": {"u": {"type": "state"}, "lo": {"type": "parameter"}},
        "index_sets": {"faces": {"kind": "interval", "size": 4}},
        "equations": [
            {
                "lhs": {"op": "index", "args": ["edge_exists", "e"]},
                "rhs": {
                    "op": "aggregate",
                    "distinct": True,
                    "semiring": "bool_and_or",
                    "output_idx": ["e"],
                    "ranges": {"f": {"from": "faces"}},
                    # the key reads state u → the distinct node classifies CONTINUOUS
                    "key": {"op": "skolem", "args": ["edge", {"op": "index", "args": ["u", "f"]}]},
                    "expr": {"op": "true", "args": []},
                },
            }
        ],
    }
    with pytest.raises(CadenceError, match="CONTINUOUS"):
        partition(bad_model)


def test_continuous_relational_fixture_rejected():
    """The shared invalid fixture tests/invalid/aggregate/continuous_relational_node.esm
    — a relational/value-invention node whose Skolem key reads a `state` var — is
    SCHEMA-VALID (Go / TS accept it, marked resolver_only) but the partition pass
    rejects it (guard 2). The same fixture is rejected by the Julia and Rust
    siblings, so all three evaluators agree (bead ess-my4.3.11)."""
    path = INVALID_DIR / "aggregate" / "continuous_relational_node.esm"
    model = json.loads(path.read_text())["models"]["ContinuousRelationalNode"]
    with pytest.raises(CadenceError, match="CONTINUOUS"):
        partition(model)


def test_guard_from_faq_cycle_rejected():
    """A ``from_faq`` cycle in the ≤DISCRETE index-set graph is an implicit
    solve, out of scope (guard 1)."""
    cyclic = {
        "variables": {},
        "index_sets": {
            "setA": {"kind": "derived", "from_faq": "nodeA"},
            "setB": {"kind": "derived", "from_faq": "nodeB"},
        },
        "equations": [
            {
                "lhs": {"op": "index", "args": ["a", "x"]},
                "rhs": {
                    "op": "aggregate",
                    "id": "nodeA",
                    "distinct": True,
                    "semiring": "bool_and_or",
                    "output_idx": ["x"],
                    "ranges": {"y": {"from": "setB"}},
                    "expr": {"op": "true", "args": []},
                },
            },
            {
                "lhs": {"op": "index", "args": ["b", "x"]},
                "rhs": {
                    "op": "aggregate",
                    "id": "nodeB",
                    "distinct": True,
                    "semiring": "bool_and_or",
                    "output_idx": ["x"],
                    "ranges": {"y": {"from": "setA"}},
                    "expr": {"op": "true", "args": []},
                },
            },
        ],
    }
    with pytest.raises(CadenceError, match="cycle"):
        partition(cyclic)


def test_guard_float_topology_key_rejected():
    """A float component in a topology key is rejected by the fold (§5.5 rule 1
    surfaced through the cadence pass)."""
    with pytest.raises(CadenceError, match="float"):
        fold_edge_enumeration([[1.5]], [[2]], "undirected")


# ── the gather rule splits the stencil ──────────────────────────────────────


def test_gather_rule_splits_the_stencil():
    """``index(u, index(nbr,i,k))`` classes CONTINUOUS while the inner topology
    selection ``index(nbr,i,k)`` classes CONST — the index expression is classed
    independently of the array (§5.7.3)."""
    mixed = next(f for f in _fixtures() if f["id"] == "mixed_stencil")
    model = _load_model(mixed)
    outer = {
        "op": "index",
        "args": ["u", {"op": "index", "args": ["nbr", "i", "k"]}],
    }
    assert classify(outer, model) == "continuous"
    assert classify(outer["args"][1], model) == "const"


def test_continuous_t_forcing_stays_continuous():
    """``sin(omega·t)`` is CONTINUOUS — an analytic continuous-``t`` forcing is
    not piecewise-constant between events, so it may not class DISCRETE (§5.7.1)."""
    model = {"variables": {"omega": {"type": "parameter"}}}
    forcing = {"op": "sin", "args": [{"op": "*", "args": ["omega", "t"]}]}
    assert classify(forcing, model) == "continuous"


# ── numpy_interpreter build-phase hook ──────────────────────────────────────


def test_numpy_interpreter_build_partition_delegates():
    """The interpreter build phase exposes the partition pass (additive; the hot
    tree for existing rules is unchanged)."""
    from earthsci_toolkit.numpy_interpreter import build_partition

    mixed = next(f for f in _fixtures() if f["id"] == "mixed_stencil")
    result = build_partition(_load_model(mixed))
    assert result.class_summary == mixed["class_summary"]


# ── end-to-end through the real cross-binding runner ────────────────────────


@pytest.mark.skipif(not RUNNER.is_file(), reason="cadence runner not present")
def test_cadence_runner_accepts_python_adapter(tmp_path):
    """End-to-end: drive the real cross-binding runner with this adapter and
    assert it reports the Python binding as conformant to the golden."""
    env = dict(os.environ)
    env["EARTHSCI_CADENCE_ADAPTER_PYTHON"] = (
        f"{sys.executable} -m earthsci_toolkit.cli.cadence_adapter"
    )
    env["PYTHONPATH"] = os.pathsep.join([str(SRC_DIR), env.get("PYTHONPATH", "")]).rstrip(
        os.pathsep
    )
    report = tmp_path / "report.json"
    proc = subprocess.run(
        [sys.executable, str(RUNNER), "--bindings", "python", "--output", str(report)],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"runner failed:\n{proc.stdout}\n{proc.stderr}"
    data = json.loads(report.read_text())
    py = data["bindings"]["python"]
    assert py["status"] == "ok", py
    for fid in ("mixed_stencil", "pure_topology", "pure_pointwise"):
        assert py["fixtures"][fid]["status"] == "ok", py["fixtures"][fid]


@pytest.mark.skipif(not RUNNER.is_file(), reason="cadence runner not present")
def test_cadence_self_test_still_green():
    """The embedded reference classifier + golden self-test remains green
    (the additive Python producer does not perturb the static contract)."""
    proc = subprocess.run(
        [sys.executable, str(RUNNER), "--self-test"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, f"self-test failed:\n{proc.stdout}\n{proc.stderr}"
