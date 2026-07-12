"""Skolem `label` field vs pure key components — Python binding.

Regression for the overloaded-first-arg bug: ``skolem``'s leading positional arg
used to be stripped whenever it was a string, so it doubled as EITHER a
documentary relation tag OR a real key component. A typo — or a legitimate
leading range-symbol arg (``skolem(label="pair", args=["i", "j"])``) — silently
masqueraded as a tag and vanished from the emitted key. The fix moves the tag to
a dedicated optional ``label`` field; every ``args`` entry is now a PURE key
component. Mirrors the Julia reference ``_vi_skolem``.

These exercise the value-invention ``_vi_skolem`` directly. The cross-binding
determinism goldens ride ``relational.skolem`` (not this evaluator), so they are
unaffected by construction.
"""

from __future__ import annotations

import pytest

from earthsci_ast.value_invention import (
    ValueInventionError,
    _vi_skolem,
    _ViCtx,
)


def _ctx() -> _ViCtx:
    """A minimal context — ``_vi_skolem`` on integer / bound-symbol components
    touches none of the const-array / parameter registries."""
    return _ViCtx(const_arrays={}, params={}, index_sets={}, variables={})


def test_label_is_documentary_not_in_key() -> None:
    """``label`` names the relation but is NEVER part of the emitted key: a
    skolem with a label + pure integer components yields exactly that tuple."""
    node = {"op": "skolem", "label": "edge", "args": [1, 2]}
    assert _vi_skolem(node, _ctx(), {}) == (1, 2)


def test_leading_component_survives_no_strip() -> None:
    """The bug: a leading string arg (a bound range symbol) is a REAL key
    component now — it is resolved via bindings and NOT discarded as a tag."""
    node = {"op": "skolem", "label": "pair", "args": ["i", "j"]}
    assert _vi_skolem(node, _ctx(), {"i": 3, "j": 7}) == (3, 7)


def test_single_component_degrades_to_scalar() -> None:
    node = {"op": "skolem", "label": "edge", "args": [5]}
    assert _vi_skolem(node, _ctx(), {}) == 5


def test_missing_label_is_fine() -> None:
    """``label`` is optional; absent it, ``args`` are still pure key components."""
    node = {"op": "skolem", "args": [2, 4]}
    assert _vi_skolem(node, _ctx(), {}) == (2, 4)


def test_non_integer_component_fails_closed() -> None:
    """A non-integral component is a misuse (no float keys, §5.5.1 rule 1) — it
    fails closed rather than emitting a non-deterministic key."""
    node = {"op": "skolem", "label": "edge", "args": [1.5, 2]}
    with pytest.raises(ValueInventionError):
        _vi_skolem(node, _ctx(), {})


def test_unresolved_string_component_fails_closed() -> None:
    """An unbound / typo'd string component no longer silently vanishes as a
    tag — it reaches the key-int guard and fails closed."""
    node = {"op": "skolem", "label": "edge", "args": ["typo", 2]}
    with pytest.raises(ValueInventionError):
        _vi_skolem(node, _ctx(), {})
