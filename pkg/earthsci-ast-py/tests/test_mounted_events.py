"""A top-level ``{ref}`` mount carries the leaf component's events.

esm-spec §4.7: a ``models.<k>`` or ``reaction_systems.<k>`` ``{ref}`` mount
loads to the same document as the inline copy of the leaf's component. That
includes the component's ``discrete_events`` and ``continuous_events``, which
must reach both the flat ``EsmFile.events`` view and the flattened system.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from earthsci_ast import flatten, load_path

_DISCRETE = {
    "name": "double",
    "trigger": {"type": "periodic", "interval": 1.0},
    "affects": [{"lhs": "A", "rhs": {"op": "*", "args": [{"op": "Pre", "args": ["A"]}, 2.0]}}],
}

_CONTINUOUS = {
    "name": "floor",
    "conditions": [{"op": "-", "args": ["A", 0.5]}],
    "affects": [{"lhs": "A", "rhs": 1.0}],
}

_MODEL = {
    "variables": {
        "A": {"type": "unknown", "units": "1", "default": 1.0},
        "k": {"type": "parameter", "units": "1/s", "default": 0.1},
    },
    "equations": [
        {
            "lhs": {"op": "D", "args": ["A"], "wrt": "t"},
            "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "A"]},
        }
    ],
    "discrete_events": [_DISCRETE],
    "continuous_events": [_CONTINUOUS],
}

_REACTION_SYSTEM = {
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
    "discrete_events": [_DISCRETE],
    "continuous_events": [_CONTINUOUS],
}

_FORMS = [
    pytest.param("models", _MODEL, id="models"),
    pytest.param("reaction_systems", _REACTION_SYSTEM, id="reaction_systems"),
]


def _doc(name: str, block: str, body: dict) -> dict:
    return {"esm": "1.0.0", "metadata": {"name": name}, block: {"Leaf": copy.deepcopy(body)}}


def _write(path: Path, payload: dict) -> Path:
    path.write_text(json.dumps(payload))
    return path


def _load_pair(tmp_path: Path, block: str, body: dict):
    _write(tmp_path / "leaf.esm", _doc("leaf", block, body))
    mounted = load_path(
        _write(
            tmp_path / "host.esm",
            {"esm": "1.0.0", "metadata": {"name": "host"}, block: {"Leaf": {"ref": "./leaf.esm"}}},
        )
    )
    inline = load_path(_write(tmp_path / "inline.esm", _doc("inline", block, body)))
    return mounted, inline


def _event_names(events) -> list[tuple[str, str]]:
    return [(type(ev).__name__, ev.name) for ev in events]


@pytest.mark.parametrize(("block", "body"), _FORMS)
def test_mounted_component_events_reach_the_flat_view(tmp_path, block, body):
    mounted, inline = _load_pair(tmp_path, block, body)
    leaf = getattr(mounted, block)["Leaf"]
    assert [ev.name for ev in leaf.discrete_events] == ["double"]
    assert [ev.name for ev in leaf.continuous_events] == ["floor"]
    assert _event_names(mounted.events) == _event_names(inline.events)
    assert len(mounted.events) == 2
    # The flat view holds the component's own event objects, so a serializer
    # still finds them owned by the component rather than as orphans.
    owned = {id(ev) for ev in leaf.discrete_events + leaf.continuous_events}
    assert {id(ev) for ev in mounted.events} == owned


@pytest.mark.parametrize(("block", "body"), _FORMS)
def test_mounted_component_events_reach_the_flattened_system(tmp_path, block, body):
    mounted, inline = _load_pair(tmp_path, block, body)
    flat_mounted = flatten(mounted)
    flat_inline = flatten(inline)
    assert [ev.name for ev in flat_mounted.discrete_events] == ["double"]
    assert [ev.name for ev in flat_mounted.continuous_events] == ["floor"]
    assert flat_mounted.discrete_events == flat_inline.discrete_events
    assert flat_mounted.continuous_events == flat_inline.continuous_events
