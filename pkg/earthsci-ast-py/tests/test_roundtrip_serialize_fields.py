"""Round-trip regression tests for fields serialize used to drop.

Guards the parse/serialize symmetry fixed for:
- aggregate ``join``/``filter``/``distinct``/``key`` (RFC §5.3 / §5.5)
- reaction-system ``constraint_equations`` (esm-spec §11.4)
- component-owned events (schema nests events inside models/reaction
  systems; serialize used to hoist them to schema-forbidden top-level keys)
"""

import json
from pathlib import Path

import jsonschema
import pytest
from conftest import REPO_ROOT, VALID_DIR

from earthsci_ast import load, save

_VALID = VALID_DIR


def _schema():
    return json.loads((REPO_ROOT / "esm-schema.json").read_text())


def _roundtrip(fixture: Path) -> dict:
    """load → save → validate against schema → parse back to a dict."""
    saved = save(load(fixture.read_text()))
    data = json.loads(saved)
    jsonschema.validate(instance=data, schema=_schema())
    return data


def _find_nodes(node, predicate, found=None):
    """Collect all dict nodes in a JSON tree satisfying ``predicate``."""
    if found is None:
        found = []
    if isinstance(node, dict):
        if predicate(node):
            found.append(node)
        for v in node.values():
            _find_nodes(v, predicate, found)
    elif isinstance(node, list):
        for v in node:
            _find_nodes(v, predicate, found)
    return found


@pytest.mark.parametrize("fixture_name", ["join_filter.esm", "join_disaggregation_m2m.esm"])
def test_roundtrip_preserves_join_and_filter(fixture_name):
    fixture = _VALID / "aggregate" / fixture_name
    original = json.loads(fixture.read_text())
    orig_joins = _find_nodes(original, lambda n: "join" in n and "op" in n)
    assert orig_joins, f"{fixture_name} carries no join nodes; bad fixture pick"

    data = _roundtrip(fixture)
    saved_joins = _find_nodes(data, lambda n: "join" in n and "op" in n)
    assert len(saved_joins) == len(orig_joins)
    for orig, new in zip(orig_joins, saved_joins):
        assert new["join"] == orig["join"]
        if "filter" in orig:
            assert "filter" in new


def test_roundtrip_preserves_distinct_and_key():
    """distinct/key survive a load→save cycle on a real fixture."""
    fixture = _VALID / "aggregate" / "skolem_distinct_rank.esm"
    original = json.loads(fixture.read_text())
    orig_nodes = _find_nodes(original, lambda n: "op" in n and ("distinct" in n or "key" in n))
    assert orig_nodes, "fixture carries no distinct/key nodes; bad fixture pick"

    data = _roundtrip(fixture)
    saved_nodes = _find_nodes(data, lambda n: "op" in n and ("distinct" in n or "key" in n))
    assert len(saved_nodes) == len(orig_nodes)
    for orig, new in zip(orig_nodes, saved_nodes):
        assert new.get("distinct") == orig.get("distinct")
        assert new.get("key") == orig.get("key")


def test_roundtrip_preserves_constraint_equations():
    doc = {
        "esm": "0.1.0",
        "metadata": {"name": "constraint_equations round-trip"},
        "reaction_systems": {
            "rs": {
                "species": {"A": {"units": "mol/m^3", "default": 1.0}},
                "parameters": {"k": {"units": "1/s", "default": 0.1}},
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "A", "stoichiometry": 1}],
                        "products": None,
                        "rate": "k",
                    }
                ],
                "constraint_equations": [{"lhs": "A", "rhs": {"op": "*", "args": [2, "k"]}}],
            }
        },
    }
    data = json.loads(save(load(json.dumps(doc))))
    rs = data["reaction_systems"]["rs"]
    assert rs["constraint_equations"] == [{"lhs": "A", "rhs": {"op": "*", "args": [2, "k"]}}]


def test_roundtrip_keeps_events_nested_in_owner():
    """Events stay inside their owning component and never leak to the
    schema-forbidden top level; the saved document validates."""
    fixture = _VALID / "events_all_types.esm"
    original = json.loads(fixture.read_text())
    data = _roundtrip(fixture)

    assert "continuous_events" not in data
    assert "discrete_events" not in data
    for kind in ("models", "reaction_systems"):
        for name, comp in (original.get(kind) or {}).items():
            for key in ("continuous_events", "discrete_events"):
                if comp.get(key):
                    saved_events = data[kind][name].get(key) or []
                    assert len(saved_events) == len(comp[key]), (
                        f"{kind}/{name}/{key}: {len(comp[key])} events in, {len(saved_events)} out"
                    )
