"""Manifest-driven adapter for ``tests/conformance/classification``.

esm-spec §6.3.1 requires every binding to expose the SAME pure functions
recovering the finer solver categories from the two declared variable types.
Five bindings deriving that independently is five chances to disagree, so the
shared fixtures pin one answer per model node and this module is the Python
side of that contract.

Driven entirely by ``manifest.json`` + each fixture's golden: adding a fixture
upstream needs no change here.
"""

from __future__ import annotations

import json

import pytest
from conftest import CONFORMANCE_DIR, REPO_ROOT, VALID_DIR

from earthsci_ast import classification as C
from earthsci_ast.parse import load

MANIFEST = CONFORMANCE_DIR / "classification" / "manifest.json"

#: The keys a golden pins for each model node. ``declared_system_kind`` is
#: optional in a golden (it is only interesting where a model carries the
#: field), so it is compared when present and skipped when not.
_KEYS = (
    "ode_states",
    "observed_unknowns",
    "algebraic_unknowns",
    "brownian_parameters",
    "discrete_parameters",
    "sampled_parameters",
    "constant_parameters",
    "system_kind",
    "declared_system_kind",
)


def _classify(model) -> dict:
    return {
        "ode_states": C.ode_states(model),
        "observed_unknowns": C.observed_unknowns(model),
        "algebraic_unknowns": C.algebraic_unknowns(model),
        "brownian_parameters": C.brownian_parameters(model),
        "discrete_parameters": C.discrete_parameters(model),
        "sampled_parameters": C.sampled_parameters(model),
        "constant_parameters": C.constant_parameters(model),
        "system_kind": C.system_kind(model),
        "declared_system_kind": C.declared_system_kind(model),
    }


def _manifest() -> dict:
    assert MANIFEST.is_file(), f"conformance manifest not found: {MANIFEST}"
    return json.loads(MANIFEST.read_text())


def _cases() -> list[dict]:
    return _manifest()["fixtures"]


CASES = _cases()
IDS = [c["id"] for c in CASES]


@pytest.fixture(params=CASES, ids=IDS)
def case(request):
    entry = request.param
    base = CONFORMANCE_DIR / "classification"
    doc = json.loads((base / entry["fixture"]).read_text())
    golden = json.loads((base / entry["golden"]).read_text())
    return entry, doc, golden


def test_python_is_a_required_binding():
    """The manifest names python; if that ever changes this adapter is dead
    weight and should be deleted rather than silently kept passing."""
    assert "python" in _manifest()["bindings_required"]


def test_classification_matches_the_golden(case):
    """Every §6.3.1 set, per model node, against the shared golden."""
    _entry, doc, golden = case
    produced = {path: _classify(model) for path, model in C.model_nodes(doc)}

    assert set(produced) == set(golden["models"]), (
        "the set of model nodes must match the golden's dot-paths exactly"
    )
    for name, want in golden["models"].items():
        got = produced[name]
        for key in _KEYS:
            if key not in want:
                continue
            assert got[key] == want[key], f"{name}.{key}: got {got[key]!r}, want {want[key]!r}"


def test_the_sets_partition(case):
    """The manifest's `partitions` contract, asserted rather than assumed."""
    _entry, doc, _golden = case
    for _path, model in C.model_nodes(doc):
        C.assert_partitions(model)


def test_is_ode_state_agrees_with_ode_states(case):
    """The membership test and the set must not drift apart."""
    _entry, doc, golden = case
    for path, model in C.model_nodes(doc):
        want = set(golden["models"][path]["ode_states"])
        for name in C.unknowns(model) + C.parameters(model):
            assert C.is_ode_state(model, name) is (name in want), name


def test_classification_agrees_across_the_dict_and_dataclass_spellings(case):
    """The binding carries both a raw-dict and a parsed-dataclass model
    representation; ONE derivation must serve both, or the two paths can
    silently disagree about which nodes fold."""
    _entry, doc, _golden = case
    parsed = load(doc)
    for name, model in parsed.models.items():
        assert _classify(model) == _classify(doc["models"][name]), name


@pytest.mark.parametrize(
    "fixture",
    [
        "cadence/observed_leaf_seeds.esm",
        "minimal.esm",
        "brownian_motion.esm",
    ],
)
def test_the_sets_partition_on_the_shared_corpus(fixture):
    """The partition property is not a fixture-local accident."""
    path = VALID_DIR / fixture
    if not path.is_file():
        pytest.skip(f"{fixture} not present in the shared corpus")
    doc = json.loads(path.read_text())
    for _name, model in C.model_nodes(doc):
        C.assert_partitions(model)


def test_every_valid_corpus_model_partitions():
    """Sweep the whole shared valid corpus: a derived partition can break
    silently on a shape no hand-written fixture covers."""
    checked = 0
    for path in sorted((REPO_ROOT / "tests" / "valid").rglob("*.esm")):
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        if not isinstance(doc, dict):
            continue
        for _name, model in C.model_nodes(doc):
            C.assert_partitions(model)
            checked += 1
    assert checked > 50, f"only {checked} model nodes swept — the corpus glob is wrong"
